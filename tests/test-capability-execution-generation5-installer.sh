#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-5 installer.
#
# ISOLATED BY CONSTRUCTION. Every case builds a throwaway fixture tree and runs
# the installer with --fixture against it. Nothing here touches
# /usr/lib/kyri/python, /usr/libexec, /root, sudoers, or any authority root,
# and nothing here needs root.
#
# WHAT IS PROVEN. Failure is injected at each of the seven commit positions and
# the fixture is required to end up ENTIRELY Generation 4 or ENTIRELY
# Generation 5 -- never a mixed set, and never a mixed set the installer would
# accept. Interrupted transactions are then replayed from every reachable
# journal/bytes combination, and unknown bytes are required to fail closed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Operator tooling, not runtime authority: the installer lives beside the
# runbook it belongs to and is never installed onto the host.
INSTALLER="${REPOSITORY}/provisioning/execution/install-generation-5.sh"
[[ -f "${INSTALLER}" ]] || { printf 'installer missing: %s\n' "${INSTALLER}" >&2; exit 1; }
# The installer pins the deployment path as a production constant. If this
# checkout is somewhere else, the two disagree and every case would fail for a
# reason that has nothing to do with the transaction logic.
PINNED_REPOSITORY="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${INSTALLER}" | head -1)"
[[ "${PINNED_REPOSITORY}" == "${REPOSITORY}" ]] || {
  printf 'this checkout is %s but the installer pins %s\n' "${REPOSITORY}" "${PINNED_REPOSITORY}" >&2
  exit 1
}

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# ===========================================================================
# Fixture-only guard
# ===========================================================================
# Snapshotted before the first case and compared after the last. The harness
# drives a root-capable installer, so "it only touches fixtures" has to be a
# measured property rather than an intention. Everything below is read-only
# against these paths.
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /root/kyri-gen5-transaction
  /etc/sudoers.d/kyri-exec
  /var/lib/kyri
  /data/kyri
)
snapshot_production() {
  python3 - "$@" <<'SNAPPY'
import hashlib, json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    except OSError:
        # /root is 0700, so an unprivileged run cannot see inside it. Recorded
        # identically on both sides; the real guard for the transaction root is
        # the structural one below, which proves it is always fixture-prefixed.
        state[path] = "unreadable"
        continue
    entry = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
    if os.path.isdir(path) and not os.path.islink(path):
        manifest = hashlib.sha256()
        for base, directories, files in os.walk(path):
            directories.sort()
            for name in sorted(files):
                full = os.path.join(base, name)
                manifest.update(full.encode("utf-8"))
                try:
                    with open(full, "rb") as handle:
                        manifest.update(hashlib.sha256(handle.read()).digest())
                except OSError:
                    manifest.update(b"unreadable")
        entry.append(manifest.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# The seven targets, in commit order, with both digests.
mapfile -t RAW_ROWS < <(sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep '^"' | tr -d '"')
[[ "${#RAW_ROWS[@]}" -eq 7 ]] || { printf 'expected 7 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
# The installer's matrix carries unexpanded ${LIBRARY_ROOT}/${LIBEXEC}. Turn
# them into placeholders once so every fixture can bind its own roots, and so
# the digests stay pinned to the installer rather than copied here.
ROWS=()
for raw in "${RAW_ROWS[@]}"; do
  raw="${raw//\$\{LIBRARY_ROOT\}/%LIB%}"
  raw="${raw//\$\{LIBEXEC\}/%EXEC%}"
  ROWS+=("${raw}")
done

# ===========================================================================
# Generation-4 fixture baseline — pinned immutable history
# ===========================================================================
# The baseline MUST NOT come from the installed tree. It did once, and that
# made the suite pass only while the host still ran generation 4: the moment
# generation 5 was installed every fixture began at GEN5=7 and each
# transactional case short-circuited with "already installed; nothing to do".
# A test whose meaning depends on which generation the host happens to run is
# not a test of the installer.
#
# These are the commits whose blob at that path reproduces the exact
# generation-4 digest the installer pins. They are constants: no caller, no
# environment variable, and no test input selects a revision or a path, and no
# revision syntax is accepted from anywhere.
gen4_commit_for() {
  case "$1" in
    tools/capability/execution/handoff.py)
      printf '%s' "1f7969ab463eef720e57c88989286711b1bf06bf" ;;
    tools/capability/execution/profile.py)
      printf '%s' "affbc86bfa212ff118afae01e086a02f8f8c5a77" ;;
    tools/capability/execution/worker.py)
      printf '%s' "affbc86bfa212ff118afae01e086a02f8f8c5a77" ;;
    provisioning/execution/kyri-exec-transition.py)
      printf '%s' "affbc86bfa212ff118afae01e086a02f8f8c5a77" ;;
    provisioning/execution/kyri-exec-transition-action.py)
      printf '%s' "2e3bede624f22d1d246cb5beacece971521c34eb" ;;
    provisioning/execution/kyri-exec-transition-entrypoint.py)
      printf '%s' "34c18a771fd9abc39bab4357999fc9ce1ba726c1" ;;
    provisioning/execution/kyri-exec-worker.py)
      printf '%s' "34c18a771fd9abc39bab4357999fc9ce1ba726c1" ;;
    *) return 1 ;;
  esac
}

field() { IFS='|' read -r -a f <<<"$1"; printf '%s' "${f[$2]}"; }
# The absolute target path inside a fixture root.
bind_target() {
  local root="$1" raw="$2"
  raw="${raw//%LIB%/${root}/usr/lib/kyri/python}"
  raw="${raw//%EXEC%/${root}/usr/libexec}"
  printf '%s' "${raw}"
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Every pinned object must be reachable before a single case runs. A shallow
# clone would otherwise turn a missing blob into a confusing mid-suite failure,
# so it is refused here with the reason and the remedy.
require_history() {
  local shallow row source commit missing=0
  shallow="$(git -C "${REPOSITORY}" rev-parse --is-shallow-repository)"
  if [[ "${shallow}" == "true" ]]; then
    printf 'FAIL: this is a shallow clone; the generation-4 fixture baseline lives in history.\n' >&2
    printf '      CI checks out with fetch-depth: 0 for exactly this reason.\n' >&2
    exit 1
  fi
  for row in "${ROWS[@]}"; do
    source="$(field "${row}" 0)"
    if ! commit="$(gen4_commit_for "${source}")"; then
      printf 'FAIL: no pinned generation-4 commit for %s\n' "${source}" >&2
      missing=$((missing + 1)); continue
    fi
    git -C "${REPOSITORY}" cat-file -e "${commit}^{commit}" 2>/dev/null || {
      printf 'FAIL: pinned commit %s is absent\n' "${commit}" >&2
      missing=$((missing + 1)); continue
    }
    git -C "${REPOSITORY}" cat-file -e "${commit}:${source}" 2>/dev/null || {
      printf 'FAIL: %s does not exist at %s\n' "${source}" "${commit}" >&2
      missing=$((missing + 1)); }
  done
  (( missing == 0 )) || exit 1
  pass "every pinned generation-4 object is present in history"
}
require_history

# One generation-4 object, extracted from immutable history and proved.
materialise_gen4() {
  local source="$1" destination="$2" expected="$3" commit observed
  commit="$(gen4_commit_for "${source}")" || {
    printf 'no pinned generation-4 commit for %s\n' "${source}" >&2; exit 1; }
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
  observed="$(digest_of "${destination}")"
  # Fail closed rather than inventing fixture bytes: if history no longer
  # reproduces the accepted digest, the pin is wrong and the suite is
  # meaningless, not merely inconvenient.
  [[ "${observed}" == "${expected}" ]] || {
    printf 'generation-4 blob for %s is %s, expected %s\n' \
      "${source}" "${observed}" "${expected}" >&2
    exit 1; }
}

# A fixture holding the exact Generation-4 bytes at every target, plus the
# Generation-4 evidence the installer verifies the unchanged surface against.
#
# Nothing below reads /usr/lib/kyri/python or /usr/libexec. The seven targets
# come from pinned history; the rest of the library tree comes from this
# checkout, where those files are byte-identical across generations 4 and 5
# because no pass changed them. The evidence file is then generated from the
# fixture itself, so the baseline is self-consistent by construction.
build_fixture() {
  local root="$1" row source target mode gen4 file relative
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/lib/kyri/python/tools/common" \
           "${root}/usr/libexec" "${root}/root"

  # The rest of the library tree, from this checkout.
  while IFS= read -r file; do
    relative="${file}"
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${relative}")"
    rm -f "${root}/usr/lib/kyri/python/${relative}"
    cp "${REPOSITORY}/${file}" "${root}/usr/lib/kyri/python/${relative}"
    chmod 0444 "${root}/usr/lib/kyri/python/${relative}"
  done < <(cd "${REPOSITORY}" && { printf 'tools/__init__.py\n'
             find tools/capability tools/common -type f -name '*.py' \
               -not -path '*__pycache__*' | sort; })
  cp "${REPOSITORY}/provisioning/execution/kyri-exec-quota.py" \
     "${root}/usr/lib/kyri/python/kyri_exec_quota.py"
  chmod 0444 "${root}/usr/lib/kyri/python/kyri_exec_quota.py"
  cp "${REPOSITORY}/provisioning/execution/kyri-exec-quota.py" \
     "${root}/usr/libexec/kyri-exec-quota"
  chmod 0555 "${root}/usr/libexec/kyri-exec-quota"

  # The seven, from pinned history, each proved against the installer's own
  # generation-4 digest before it is used.
  for row in "${ROWS[@]}"; do
    source="$(field "${row}" 0)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    mode="$(field "${row}" 2)"
    gen4="$(field "${row}" 3)"
    mkdir -p "$(dirname "${target}")"
    rm -f "${target}"
    materialise_gen4 "${source}" "${target}" "${gen4}"
    chmod "${mode}" "${target}"
  done

  # Evidence generated from the fixture, with host-style pathnames, in the
  # exact `sha256sum` layout the installer parses.
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen4-library-digests.txt"
  ( cd "${root}" && sha256sum usr/libexec/kyri-exec-transition \
      usr/libexec/kyri-exec-worker.py usr/libexec/kyri-exec-quota ) \
    | sed 's#  usr/libexec/#  /usr/libexec/#' \
    > "${root}/root/kyri-gen4-helper-digests.txt"
}

# What generation is each target, decided from bytes alone?
census() {
  local root="$1" row target gen4 gen5 observed g4=0 g5=0 unknown=0
  for row in "${ROWS[@]}"; do
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
    observed="$(digest_of "${target}")"
    if   [[ "${observed}" == "${gen5}" ]]; then g5=$((g5 + 1))
    elif [[ "${observed}" == "${gen4}" ]]; then g4=$((g4 + 1))
    else unknown=$((unknown + 1)); fi
  done
  printf 'GEN4=%d GEN5=%d UNKNOWN=%d' "${g4}" "${g5}" "${unknown}"
}

journal_state() {
  local root="$1"
  [[ -f "${root}/root/kyri-gen5-transaction/journal" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${root}/root/kyri-gen5-transaction/journal" | tail -1
}

run_installer() {
  local root="$1" assignment="$2"; shift 2
  if [[ -n "${assignment}" ]]; then
    ( cd "${REPOSITORY}" && env "${assignment}" bash "${INSTALLER}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1
  else
    ( cd "${REPOSITORY}" && bash "${INSTALLER}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1
  fi
}

# --- 0. the happy path -----------------------------------------------------
happy="${WORK}/happy"; build_fixture "${happy}"
if run_installer "${happy}" "" --install; then
  state="$(census "${happy}")"
  if [[ "${state}" == "GEN4=0 GEN5=7 UNKNOWN=0" && "$(journal_state "${happy}")" == "COMMITTED" ]]; then
    pass "clean install reaches a complete Generation 5 (${state})"
  else
    fail "clean install ended at ${state}, journal $(journal_state "${happy}")"
  fi
else
  fail "clean install failed: $(tail -5 "${happy}/last-run.log")"
fi

# Evidence only after the complete set verifies.
if [[ -f "${happy}/root/kyri-gen5-library-digests.txt" \
   && -f "${happy}/root/kyri-gen4-library-digests.txt" ]]; then
  pass "Generation-5 evidence written and Generation-4 evidence preserved"
else
  fail "evidence handling is wrong after a clean install"
fi

# --- 1. pre-install verify must pass on a Generation-4 host ----------------
baseline="${WORK}/baseline"; build_fixture "${baseline}"
if run_installer "${baseline}" "" --verify; then
  pass "--verify exits 0 on an untouched Generation-4 fixture"
else
  fail "--verify failed on a valid Generation-4 fixture: $(tail -8 "${baseline}/last-run.log")"
fi
if [[ "$(census "${baseline}")" == "GEN4=7 GEN5=0 UNKNOWN=0" ]]; then
  pass "--verify mutated nothing"
else
  fail "--verify mutated the fixture"
fi

# --- 2. failure injected at every commit position -------------------------
for position in 1 2 3 4 5 6 7; do
  root="${WORK}/inject-${position}"; build_fixture "${root}"
  if run_installer "${root}" "KYRI_GEN5_FAIL_AT=${position}" --install; then
    fail "injected failure at ${position} was reported as success"
    continue
  fi
  state="$(census "${root}")"
  journal="$(journal_state "${root}")"
  if [[ "${state}" == "GEN4=7 GEN5=0 UNKNOWN=0" ]]; then
    if [[ "${journal}" == "ROLLED_BACK" ]]; then
      pass "failure at commit ${position}: rolled back to a complete Generation 4, journal ROLLED_BACK"
    else
      fail "failure at ${position}: bytes are Generation 4 but journal says ${journal}"
    fi
  else
    fail "failure at ${position} left ${state} (journal ${journal})"
  fi
done

# --- 3. interrupted transactions: every reachable mixture -----------------
# Simulate a crash after N successful renames with the journal left COMMITTING
# and the prepared material still present -- recovery must complete FORWARD.
for done_count in 1 2 3 4 5 6; do
  root="${WORK}/crash-forward-${done_count}"; build_fixture "${root}"
  # An interrupted COMMIT, reconstructed by hand: prepared material present,
  # backups present, the first N renames done, journal left COMMITTING.
  mkdir -p "${root}/root/kyri-gen5-transaction"
  index=0
  {
    printf 'transaction=gen5-cfb0edd31b35\n'
    printf 'commit=cfb0edd31b3589f12b6ba583ebfa48bb64e89519\n'
    printf 'state=COMMITTING\n'
  } > "${root}/root/kyri-gen5-transaction/journal"
  for row in "${ROWS[@]}"; do
    index=$((index + 1))
    source="$(field "${row}" 0)"; mode="$(field "${row}" 2)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    cp -p "${target}" "${target}.kyri-gen4.old"
    install -m "${mode}" "${REPOSITORY}/${source}" "${target}.kyri-gen5.new"
    if (( index <= done_count )); then
      mv -f "${target}.kyri-gen5.new" "${target}"
      printf 'progress:%d=GEN5\n' "${index}" >> "${root}/root/kyri-gen5-transaction/journal"
    fi
  done
  before="$(census "${root}")"
  if run_installer "${root}" "" --install; then
    after="$(census "${root}")"
    if [[ "${after}" == "GEN4=0 GEN5=7 UNKNOWN=0" && "$(journal_state "${root}")" == "COMMITTED" ]]; then
      pass "interrupted after ${done_count} renames (${before}) recovers FORWARD to ${after}"
    else
      fail "interrupted after ${done_count} recovered to ${after}, journal $(journal_state "${root}")"
    fi
  else
    fail "recovery after ${done_count} renames failed: $(tail -6 "${root}/last-run.log")"
  fi
done

# --- 4. interrupted transaction with prepared material lost -> ROLLBACK ---
for done_count in 1 3 6; do
  root="${WORK}/crash-back-${done_count}"; build_fixture "${root}"
  mkdir -p "${root}/root/kyri-gen5-transaction"
  {
    printf 'transaction=gen5-cfb0edd31b35\n'
    printf 'commit=cfb0edd31b3589f12b6ba583ebfa48bb64e89519\n'
    printf 'state=COMMITTING\n'
  } > "${root}/root/kyri-gen5-transaction/journal"
  index=0
  for row in "${ROWS[@]}"; do
    index=$((index + 1))
    source="$(field "${row}" 0)"; mode="$(field "${row}" 2)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    cp -p "${target}" "${target}.kyri-gen4.old"
    if (( index <= done_count )); then
      install -m "${mode}" "${REPOSITORY}/${source}" "${target}"
    fi
    # No .kyri-gen5.new anywhere: the prepared material is gone.
  done
  before="$(census "${root}")"
  # A rollback is a complete outcome that is deliberately NOT success: the
  # installer exits non-zero so no automation mistakes it for Generation 5.
  run_installer "${root}" "" --install && status=0 || status=$?
  after="$(census "${root}")"
  if [[ "${after}" == "GEN4=7 GEN5=0 UNKNOWN=0" \
     && "$(journal_state "${root}")" == "ROLLED_BACK" && "${status}" -ne 0 ]] \
     && grep -q "Generation 5 was NOT installed" "${root}/last-run.log"; then
    pass "interrupted after ${done_count} with no prepared material (${before}) rolls BACK to ${after}"
  else
    fail "lost-prepare recovery after ${done_count} ended at ${after}, journal $(journal_state "${root}"), status ${status}"
  fi
done

# --- 5. UNKNOWN bytes must fail closed ------------------------------------
root="${WORK}/unknown"; build_fixture "${root}"
chmod u+w "${root}/usr/lib/kyri/python/tools/capability/execution/worker.py"
printf 'corrupted\n' >> "${root}/usr/lib/kyri/python/tools/capability/execution/worker.py"
if run_installer "${root}" "" --install; then
  fail "an installation started over unknown bytes"
else
  if grep -q "unknown bytes" "${root}/last-run.log"; then
    pass "unknown bytes at a target fail closed before any transaction starts"
  else
    fail "unknown bytes refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
fi

root="${WORK}/unknown-recover"; build_fixture "${root}"
mkdir -p "${root}/root/kyri-gen5-transaction"
printf 'state=COMMITTING\n' > "${root}/root/kyri-gen5-transaction/journal"
chmod u+w "${root}/usr/libexec/kyri-exec-worker.py"
printf 'corrupted\n' >> "${root}/usr/libexec/kyri-exec-worker.py"
if run_installer "${root}" "" --install; then
  fail "recovery proceeded over unknown bytes"
else
  if grep -q "UNKNOWN bytes\|refuses to guess" "${root}/last-run.log"; then
    pass "recovery over unknown bytes fails closed for operator disposition"
  else
    fail "recovery refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
fi

# --- 6. drift in the unchanged surface must stop a fresh transaction ------
root="${WORK}/drift"; build_fixture "${root}"
chmod u+w "${root}/usr/lib/kyri/python/tools/capability/execution/state.py"
printf '# drift\n' >> "${root}/usr/lib/kyri/python/tools/capability/execution/state.py"
if run_installer "${root}" "" --install; then
  fail "installation proceeded over a drifted unchanged runtime object"
else
  if grep -q "drifted" "${root}/last-run.log"; then
    pass "drift in an unchanged runtime object stops the transaction"
  else
    fail "drift refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
fi

# --- 7. failure injection is impossible without --fixture -----------------
if grep -q 'FIXTURE.*KYRI_GEN5_FAIL_AT' "${INSTALLER}"; then
  pass "failure injection is gated on fixture mode in source"
else
  fail "failure injection is not gated on fixture mode"
fi

# --- 8. the installer never invokes the privilege boundary ----------------
if grep -Eq 'kyri-exec-transition"?[[:space:]]+CINV|--fixture.*CINV|podman|kyri-exec-worker\.py[[:space:]]+CINV' "${INSTALLER}"; then
  fail "the installer contains an invocation of the transition, worker, or Podman"
else
  pass "the installer invokes no transition, worker, Podman, or ceremony"
fi

# --- 9. nothing outside the fixtures was touched --------------------------
PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated: installed tree, entrypoints, evidence, sudoers, /data, /var/lib/kyri"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

# --- 10. the installer cannot be told to install itself -------------------
if grep -q 'install-generation-5' "${REPOSITORY}/provisioning/execution/install-generation-5.sh" \
   && grep -qE '^MATRIX=\(' "${INSTALLER}"; then
  if sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -q 'install-generation-5'; then
    fail "the installer installs itself"
  else
    pass "the installer is operator tooling and installs neither itself nor the harness"
  fi
fi
if sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -qE 'tests/|run-validation|\.github'; then
  fail "the install matrix carries test or CI material"
else
  pass "the install matrix carries runtime objects only"
fi

# --- 11. failure injection is unreachable without fixture mode ------------
# The exact guard, asserted as a conjunction rather than by the presence of the
# variable name: a production run has no --fixture, so the branch is dead.
# The unexpanded literal IS the assertion, so it must not expand.
# shellcheck disable=SC2016
if grep -qF 'if [[ -n "${FIXTURE}" && "${KYRI_GEN5_FAIL_AT:-}" == "${index}" ]]; then' "${INSTALLER}"; then
  pass "failure injection requires -n FIXTURE and the position to match"
else
  fail "the failure-injection guard is not the reviewed conjunction"
fi
if [[ "$(grep -c 'KYRI_GEN5_FAIL_AT' "${INSTALLER}")" -eq 2 ]]; then
  pass "KYRI_GEN5_FAIL_AT appears only in its documented guard and the header"
else
  fail "KYRI_GEN5_FAIL_AT appears $(grep -c 'KYRI_GEN5_FAIL_AT' "${INSTALLER}") times; expected 2"
fi

# --- 12. every mutable root is fixture-prefixed in fixture mode -----------
# The snapshot above cannot see inside /root unprivileged, so the property is
# also proven structurally: each root the installer may write to is rebound
# under the fixture prefix, in one block, with no exceptions.
missing_prefix=0
for name in LIBRARY_ROOT LIBEXEC TRANSACTION_ROOT GEN4_LIBRARY_EVIDENCE \
            GEN4_HELPER_EVIDENCE GEN5_LIBRARY_EVIDENCE GEN5_HELPER_EVIDENCE; do
  if ! grep -qE "^  ${name}=\"\\\$\{FIXTURE\}\\\$\{${name}\}\"$" "${INSTALLER}"; then
    fail "installer root ${name} is not rebound under the fixture prefix"
    missing_prefix=$((missing_prefix + 1))
  fi
done
if (( missing_prefix == 0 )); then
  pass "every installer root is rebound under the fixture prefix"
fi

# --- 13. the clean-tree gate still fires for production runs --------------
# Relaxed for fixture runs only, and that relaxation must stay one branch deep:
# a production invocation installs from this checkout, so an unreviewed edit in
# it is an unreviewed edit on the host.
# The unexpanded literals ARE the assertion, so they must not expand.
# shellcheck disable=SC2016
if grep -qF 'if [[ -z "${FIXTURE}" ]]; then' "${INSTALLER}" \
   && grep -qF 'halt "the working tree is not clean:"' "${INSTALLER}"; then
  pass "a dirty tree halts a production run and is only noted in fixture mode"
else
  fail "the clean-tree gate is not scoped to production runs"
fi
# And the source digests gate both modes: they are checked before any phase.
if grep -qF 'require_source_digests' "${INSTALLER}"; then
  pass "source digests are verified in every mode"
else
  fail "source digest verification is missing"
fi

# --- 14. the guarantee is stated honestly ---------------------------------
if grep -q 'NOT an atomic seven-object installation' "${INSTALLER}" \
   && grep -q 'Transactional crash-recoverable installation' "${INSTALLER}"; then
  pass "the installer claims transactional crash-recoverable installation, not atomicity"
else
  fail "the installer's stated guarantee changed"
fi

# --- 15. the generation-4 baseline is hermetic ----------------------------
# The regression this suite exists to prevent: the baseline once came from the
# installed tree, so the whole suite silently stopped testing anything the day
# generation 5 was installed. Proven two ways -- what the fixture contains, and
# where the code is allowed to read from.
hermetic="${WORK}/hermetic"; build_fixture "${hermetic}"
baseline_wrong=0
for row in "${ROWS[@]}"; do
  target="$(bind_target "${hermetic}" "$(field "${row}" 1)")"
  gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
  observed="$(digest_of "${target}")"
  if [[ "${observed}" != "${gen4}" ]]; then
    fail "fixture target is ${observed:0:12}, expected generation-4 ${gen4:0:12}"
    baseline_wrong=$((baseline_wrong + 1))
  elif [[ "${observed}" == "${gen5}" ]]; then
    fail "generation-4 and generation-5 digests collide for $(field "${row}" 0)"
    baseline_wrong=$((baseline_wrong + 1))
  fi
done
if (( baseline_wrong == 0 )); then
  pass "every fixture target holds the installer-pinned generation-4 bytes"
fi

# Whatever the host currently runs, the fixture is generation 4. Reported, not
# asserted: the suite must not care which generation is installed.
live_state="unreadable"
if [[ -r /usr/lib/kyri/python/tools/capability/execution/worker.py ]]; then
  live_digest="$(digest_of /usr/lib/kyri/python/tools/capability/execution/worker.py)"
  for row in "${ROWS[@]}"; do
    [[ "$(field "${row}" 0)" == "tools/capability/execution/worker.py" ]] || continue
    if [[ "${live_digest}" == "$(field "${row}" 4)" ]]; then live_state="generation 5"
    elif [[ "${live_digest}" == "$(field "${row}" 3)" ]]; then live_state="generation 4"
    else live_state="an unrecognised generation"; fi
  done
fi
printf 'note: the installed tree is %s; the fixture is generation 4 regardless\n' "${live_state}"

# --- 16. fixture construction never reads the installed tree --------------
builder="$(sed -n '/^build_fixture()/,/^}/p;/^materialise_gen4()/,/^}/p' "$0")"
if printf '%s' "${builder}" | grep -qE '(cp|cat|sha256sum|find|install)[[:space:]]+/usr/'; then
  fail "fixture construction reads an absolute /usr path"
else
  pass "fixture construction reads no /usr path: not the installed tree"
fi
if printf '%s' "${builder}" | grep -q 'cat-file blob'; then
  pass "fixture generation-4 bytes come from pinned git objects"
else
  fail "fixture generation-4 bytes do not come from git objects"
fi
# Every pinned revision is a full 40-character object id and a constant: no
# caller, environment, or test input selects a revision or a path.
pins="$(sed -n '/^gen4_commit_for()/,/^}/p' "$0" | grep -oE "[0-9a-f]{40}" | sort -u)"
if [[ "$(printf '%s\n' "${pins}" | grep -c .)" -ge 4 ]]; then
  pass "generation-4 sources are pinned as full object ids"
else
  fail "generation-4 sources are not pinned as full object ids"
fi
if sed -n '/^gen4_commit_for()/,/^}/p' "$0" | grep -qE '\$[{(]|KYRI_|GEN4_COMMIT='; then
  fail "a pinned generation-4 source is caller- or environment-selectable"
else
  pass "no pinned generation-4 source is caller- or environment-selectable"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation-5 installer transaction tests passed.\n'
else
  printf 'Generation-5 installer transaction tests FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
