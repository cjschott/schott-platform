#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the G6.1A trusted-runtime installation
# ceremony (Generation 7).
#
# ISOLATED BY CONSTRUCTION. Every case builds a throwaway fixture tree and runs
# the ceremony with --fixture against it. Nothing here touches
# /usr/lib/kyri/python, /usr/libexec, /root, /etc, /run, sudoers, or any
# authority root, and nothing here needs root. No sudoers is written, the
# transition is never invoked, the worker is never executed, and no container
# runtime is contacted.
#
# WHAT GENERATION 7 IS. The five verification-only artifacts G6.1 designed:
# two runtime modules, one flattened policy module, and -- for the first time
# since Generation 5 -- two NEW objects in /usr/libexec. Every one is a CREATE,
# so rollback is uniformly REMOVE, and removing an object this transaction did
# not install is the one thing it must never do.
#
# WHAT IS PROVEN. Failure is injected at each of the five commit positions;
# every interrupted transaction is replayed from every reachable journal/bytes
# combination; each create pathname is attacked directly (pre-existing,
# modified after publication, wrong mode, symlinked); the Generation-6 baseline
# is attacked (drift, missing evidence, unrecorded object, helper drift); and
# the installed contract is attacked by tampering with installed bytes.
#
# WHAT IT MUST NOT DO. G6.1B -- the sudoers grant and the first live crossing
# -- is a separate ceremony. This one installs runtime and libexec artifacts
# and provably ends with no grant, so the boundary it installs is not yet
# reachable by anyone.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Operator tooling, not runtime authority: the ceremony lives beside the
# runbook it belongs to and is never installed onto the host.
CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-7.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }
PINNED_REPOSITORY="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${CEREMONY}" | head -1)"
[[ "${PINNED_REPOSITORY}" == "${REPOSITORY}" ]] || {
  printf 'this checkout is %s but the ceremony pins %s\n' "${REPOSITORY}" "${PINNED_REPOSITORY}" >&2
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
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /usr/libexec/kyri-exec-verify
  /usr/libexec/kyri-exec-verify-worker.py
  /root/kyri-gen7-transaction
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
  /var/lib/kyri
  /run/kyri
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
        state[path] = "unreadable"
        continue
    entry = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
    if os.path.isdir(path) and not os.path.islink(path):
        manifest = hashlib.sha256()
        try:
            walker = os.walk(path)
            for base, directories, files in walker:
                directories.sort()
                for name in sorted(files):
                    full = os.path.join(base, name)
                    manifest.update(full.encode("utf-8"))
                    try:
                        with open(full, "rb") as handle:
                            manifest.update(hashlib.sha256(handle.read()).digest())
                    except OSError:
                        manifest.update(b"unreadable")
        except OSError:
            manifest.update(b"unwalkable")
        entry.append(manifest.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# ===========================================================================
# Everything pinned, read from the ceremony so the two can never disagree
# ===========================================================================
mapfile -t RAW_ROWS < <(sed -n '/^MATRIX=(/,/^)/p' "${CEREMONY}" | grep '^"' | tr -d '"')
[[ "${#RAW_ROWS[@]}" -eq 5 ]] || {
  printf 'expected 5 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
ROWS=()
for raw in "${RAW_ROWS[@]}"; do
  raw="${raw//\$\{LIBRARY_ROOT\}/%LIB%}"
  ROWS+=("${raw//\$\{LIBEXEC\}/%EXEC%}")
done

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
read_number() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1; }
COMMIT="$(read_pin COMMIT)"
GEN6_COMMIT="$(read_pin GEN6_COMMIT)"
GEN5_COMMIT="$(read_pin GEN5_COMMIT)"
SUDOERS_ABS="$(read_pin SUDOERS)"
VERIFY_SUDOERS_ABS="$(read_pin VERIFY_SUDOERS)"
# The Generation-6 helper evidence records this alongside the three helpers. It
# is read from the Generation-6 installer, which is what wrote that file, so the
# fixture reproduces the real record rather than a guess at it.
GEN6_INSTALLER="${REPOSITORY}/provisioning/execution/install-generation-6.sh"
TMPFILES_SOURCE="$(sed -n 's/^TMPFILES_SOURCE="\(.*\)"$/\1/p' "${GEN6_INSTALLER}" | head -1)"
TMPFILES_TARGET_ABS="$(sed -n 's/^TMPFILES_TARGET="\(.*\)"$/\1/p' "${GEN6_INSTALLER}" | head -1)"
[[ -n "${TMPFILES_SOURCE}" && "${TMPFILES_TARGET_ABS}" == /etc/* ]] || {
  printf 'the generation-6 installer does not pin the tmpfiles prerequisite\n' >&2; exit 1; }
EXPECTED_GEN6="$(read_number EXPECTED_LIBRARY_FILES_GEN6)"
EXPECTED_GEN7="$(read_number EXPECTED_LIBRARY_FILES_GEN7)"
for name in COMMIT GEN6_COMMIT GEN5_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'the ceremony pins no full 40-character %s\n' "${name}" >&2; exit 1; }
done
[[ "${EXPECTED_GEN6}" == "44" && "${EXPECTED_GEN7}" == "47" ]] || {
  printf 'unexpected library counts: gen6=%s gen7=%s\n' "${EXPECTED_GEN6}" "${EXPECTED_GEN7}" >&2
  exit 1; }
[[ -n "${SUDOERS_ABS}" && -n "${VERIFY_SUDOERS_ABS}" ]] || {
  printf 'the ceremony does not pin both sudoers pathnames\n' >&2; exit 1; }

field() { IFS='|' read -r -a f <<<"$1"; printf '%s' "${f[$2]}"; }
bind_target() {
  local root="$1" raw="$2"
  raw="${raw//%LIB%/${root}/usr/lib/kyri/python}"
  printf '%s' "${raw//%EXEC%/${root}/usr/libexec}"
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ===========================================================================
# History the fixtures are built from
# ===========================================================================
require_history() {
  local shallow object missing=0
  shallow="$(git -C "${REPOSITORY}" rev-parse --is-shallow-repository)"
  if [[ "${shallow}" == "true" ]]; then
    printf 'FAIL: this is a shallow clone; the generation-6 fixture baseline lives in history.\n' >&2
    printf '      CI checks out with fetch-depth: 0 for exactly this reason.\n' >&2
    exit 1
  fi
  for object in "${GEN5_COMMIT}" "${GEN6_COMMIT}" "${COMMIT}"; do
    git -C "${REPOSITORY}" cat-file -e "${object}^{commit}" 2>/dev/null || {
      printf 'FAIL: pinned commit %s is absent\n' "${object}" >&2
      missing=$((missing + 1)); }
  done
  (( missing == 0 )) || exit 1
  pass "all three pinned commits are present in history"

  # Every target must be genuinely new, or CREATE is a lie and every case below
  # is testing the wrong operation.
  local row source new=0
  for row in "${ROWS[@]}"; do
    source="$(field "${row}" 0)"
    if git -C "${REPOSITORY}" cat-file -e "${GEN6_COMMIT}:${source}" 2>/dev/null; then
      fail "${source} already existed at generation 6: it is not a new object"
    else
      new=$((new + 1))
    fi
    [[ "$(field "${row}" 3)" == "CREATE" ]] || fail "${source} is not declared CREATE"
    [[ "$(field "${row}" 4)" == "ABSENT" ]] || fail "${source} declares a generation-6 baseline"
  done
  (( new == 5 )) && pass "all five generation-7 objects are absent at generation 6: genuinely new"
}
require_history

materialise() {
  local commit="$1" source="$2" destination="$3" expected="${4:-}" observed
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
  [[ -n "${expected}" ]] || return 0
  observed="$(digest_of "${destination}")"
  [[ "${observed}" == "${expected}" ]] || {
    printf 'blob for %s at %s is %s, expected %s\n' \
      "${source}" "${commit}" "${observed}" "${expected}" >&2
    exit 1; }
}

# ===========================================================================
# A fixture holding the complete accepted Generation 6
# ===========================================================================
build_fixture() {
  local root="$1" row target file flattened
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/var/lib/kyri"

  # The library tree, from the generation-6 commit -- the file SET as well as
  # the bytes, so the fixture holds exactly 44 objects and the five generation-7
  # pathnames are free by construction rather than by deletion.
  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN6_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN6_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py; do
    materialise "${GEN6_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  # /usr/libexec is Generation 5, byte for byte. Generation 6 changed none of
  # it and Generation 7 must not change any of it either -- it only adds.
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  chmod 0555 "${root}/usr/libexec/kyri-exec-quota"

  for row in "${ROWS[@]}"; do
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    [[ ! -e "${target}" ]] || {
      printf 'fixture holds %s, which must be absent at generation 6\n' "${target}" >&2
      exit 1; }
  done

  # Generation-6 evidence, with host-style pathnames, in the exact `sha256sum`
  # layout the ceremony parses.
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen6-library-digests.txt"
  # The helper evidence in the shape the Generation-6 installer actually wrote
  # it, which is SEVEN lines and not three: the three /usr/libexec helpers, the
  # tmpfiles prerequisite the Generation-6 host also required, and three
  # metadata lines. A fixture that recorded only the helpers made Generation 7
  # look correct while the live file would have refused it.
  mkdir -p "${root}/etc/tmpfiles.d"
  materialise "${GEN6_COMMIT}" "${TMPFILES_SOURCE}" "${root}${TMPFILES_TARGET_ABS}"
  {
    ( cd "${root}" && sha256sum usr/libexec/kyri-exec-transition \
        usr/libexec/kyri-exec-worker.py usr/libexec/kyri-exec-quota ) \
      | sed 's#  usr/libexec/#  /usr/libexec/#'
    printf '%s  %s\n' "$(digest_of "${root}${TMPFILES_TARGET_ABS}")" "${TMPFILES_TARGET_ABS}"
    printf 'commit %s\n' "${GEN6_COMMIT}"
    printf 'baseline_commit %s\n' "${GEN5_COMMIT}"
    printf 'transaction gen6-%s\n' "${GEN6_COMMIT:0:12}"
  } > "${root}/root/kyri-gen6-helper-digests.txt"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }

census() {
  local root="$1" row target gen7 g6=0 g7=0 unknown=0
  for row in "${ROWS[@]}"; do
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    gen7="$(field "${row}" 5)"
    if   [[ ! -e "${target}" && ! -L "${target}" ]]; then g6=$((g6 + 1))
    elif [[ -f "${target}" && ! -L "${target}" && "$(digest_of "${target}")" == "${gen7}" ]]; then g7=$((g7 + 1))
    else unknown=$((unknown + 1)); fi
  done
  printf 'GEN6=%d GEN7=%d UNKNOWN=%d' "${g6}" "${g7}" "${unknown}"
}

journal_state() {
  local root="$1"
  [[ -f "${root}/root/kyri-gen7-transaction/journal" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${root}/root/kyri-gen7-transaction/journal" | tail -1
}

run_ceremony() {
  local root="$1" assignment="$2"; shift 2
  if [[ -n "${assignment}" ]]; then
    ( cd "${REPOSITORY}" && env "${assignment}" bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1
  else
    ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1
  fi
}

# Reconstruct an interrupted COMMIT by hand.
stage_interrupted() {
  local root="$1" done_count="$2" keep_prepared="$3" row index=0 source target mode gen7
  mkdir -p "${root}/root/kyri-gen7-transaction"
  {
    printf 'transaction=gen7-%s\n' "${COMMIT:0:12}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'state=COMMITTING\n'
  } > "${root}/root/kyri-gen7-transaction/journal"
  for row in "${ROWS[@]}"; do
    index=$((index + 1))
    source="$(field "${row}" 0)"; mode="$(field "${row}" 2)"; gen7="$(field "${row}" 5)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    materialise "${COMMIT}" "${source}" "${target}.kyri-gen7.new" "${gen7}"
    chmod "${mode}" "${target}.kyri-gen7.new"
    if (( index <= done_count )); then
      cp -p "${target}.kyri-gen7.new" "${target}"
      chmod "${mode}" "${target}"
      rm -f "${target}.kyri-gen7.new"
      printf 'progress:%d=GEN7\n' "${index}" >> "${root}/root/kyri-gen7-transaction/journal"
    elif [[ "${keep_prepared}" != "keep" ]]; then
      rm -f "${target}.kyri-gen7.new"
    fi
  done
}

# ===========================================================================
# 0. the baseline fixture really is generation 6
# ===========================================================================
happy="${WORK}/happy"; build_fixture "${happy}"
if [[ "$(library_count "${happy}")" -eq "${EXPECTED_GEN6}" \
      && "$(census "${happy}")" == "GEN6=5 GEN7=0 UNKNOWN=0" ]]; then
  pass "the fixture baseline is a complete generation 6: ${EXPECTED_GEN6} objects, five pathnames free"
else
  fail "the fixture baseline is not generation 6: $(library_count "${happy}") objects, $(census "${happy}")"
fi

# ===========================================================================
# 1. read-only verification of a ready host
# ===========================================================================
ready="${WORK}/ready"; build_fixture "${ready}"
if run_ceremony "${ready}" "" --verify; then
  if [[ "$(census "${ready}")" == "GEN6=5 GEN7=0 UNKNOWN=0" \
        && "$(journal_state "${ready}")" == "NONE" ]]; then
    pass "--verify accepts a ready generation-6 host and installs nothing"
  else
    fail "--verify mutated the fixture: $(census "${ready}")"
  fi
else
  fail "--verify rejected a ready host: $(tail -12 "${ready}/last-run.log")"
fi

# ===========================================================================
# 2. the happy path
# ===========================================================================
if run_ceremony "${happy}" "" --install; then
  state="$(census "${happy}")"
  if [[ "${state}" == "GEN6=0 GEN7=5 UNKNOWN=0" \
        && "$(journal_state "${happy}")" == "COMMITTED" \
        && "$(library_count "${happy}")" -eq "${EXPECTED_GEN7}" ]]; then
    pass "a clean install reaches a complete generation 7 (${state}, ${EXPECTED_GEN7} objects)"
  else
    fail "install ended at ${state}, journal $(journal_state "${happy}"), $(library_count "${happy}") objects"
  fi
else
  fail "the clean install failed: $(tail -20 "${happy}/last-run.log")"
fi

if [[ -f "${happy}/root/kyri-gen7-library-digests.txt" \
      && -f "${happy}/root/kyri-gen7-helper-digests.txt" \
      && -f "${happy}/root/kyri-gen6-library-digests.txt" \
      && -f "${happy}/root/kyri-gen6-helper-digests.txt" ]]; then
  pass "generation-7 evidence was written and generation-6 evidence preserved"
else
  fail "evidence handling is wrong after a successful install"
fi

if grep -q "${COMMIT}" "${happy}/root/kyri-gen7-helper-digests.txt"; then
  pass "the generation-7 evidence records the reviewed commit"
else
  fail "the generation-7 evidence does not name the reviewed commit"
fi

if [[ ! -e "${happy}${SUDOERS_ABS}" && ! -e "${happy}${VERIFY_SUDOERS_ABS}" ]]; then
  pass "the ceremony installed no sudoers grant: G3 and G6.1B stay closed"
else
  fail "the ceremony wrote a sudoers policy"
fi

if run_ceremony "${happy}" "" --verify-installed; then
  pass "--verify-installed accepts the freshly installed generation 7"
else
  fail "--verify-installed rejected a good install: $(tail -20 "${happy}/last-run.log")"
fi

# The production execution path is not opened by installing the verification
# boundary: the generation-5 worker entrypoint is untouched and still refuses.
if [[ "$(digest_of "${happy}/usr/libexec/kyri-exec-worker.py")" \
      == "$(git -C "${REPOSITORY}" cat-file blob "${GEN5_COMMIT}:provisioning/execution/kyri-exec-worker.py" | sha256sum | cut -d' ' -f1)" ]] \
   && grep -q 'container execution is gated at G6' "${happy}/usr/libexec/kyri-exec-worker.py"; then
  pass "the production worker entrypoint is untouched and still refuses: G6 stays closed"
else
  fail "the production worker entrypoint changed during a verification-only install"
fi

# Re-running is not a second transaction.
if run_ceremony "${happy}" "" --install \
   && grep -q "already installed" "${happy}/last-run.log"; then
  pass "a rerun on an installed host is a no-op, not a second transaction"
else
  fail "a rerun did not recognise the installed generation"
fi

# ===========================================================================
# 3. failure injected at every commit position
# ===========================================================================
for position in 1 2 3 4 5; do
  root="${WORK}/fail-${position}"; build_fixture "${root}"
  if run_ceremony "${root}" "KYRI_GEN7_FAIL_AT=${position}" --install; then
    fail "injected failure at position ${position} was reported as success"
    continue
  fi
  state="$(census "${root}")"
  if [[ "${state}" == "GEN6=5 GEN7=0 UNKNOWN=0" \
        && "$(journal_state "${root}")" == "ROLLED_BACK" \
        && "$(library_count "${root}")" -eq "${EXPECTED_GEN6}" \
        && ! -f "${root}/root/kyri-gen7-library-digests.txt" ]]; then
    pass "failure at commit position ${position} rolls back to a complete generation 6"
  else
    fail "failure at position ${position} left ${state}, journal $(journal_state "${root}"), $(library_count "${root}") objects"
  fi
done

# ===========================================================================
# 4. rollback never removes an object it did not install
# ===========================================================================
# Publish position 1, then change its bytes, then force a failure at position 2.
tamper="${WORK}/tamper"; build_fixture "${tamper}"
stage_interrupted "${tamper}" 1 keep
first_target="$(bind_target "${tamper}" "$(field "${ROWS[0]}" 1)")"
chmod u+w "${first_target}"
printf '# somebody else owns this now\n' >> "${first_target}"
if run_ceremony "${tamper}" "" --install; then
  fail "recovery proceeded with unknown bytes at a published pathname"
else
  if grep -q 'UNKNOWN' "${tamper}/last-run.log" && [[ -f "${first_target}" ]]; then
    pass "unknown bytes at a create pathname are refused, and the object is not removed"
  else
    fail "unknown bytes were mishandled: $(tail -12 "${tamper}/last-run.log")"
  fi
fi

# A pre-existing object at a reserved pathname is never adopted or overwritten.
occupied="${WORK}/occupied"; build_fixture "${occupied}"
occupied_target="$(bind_target "${occupied}" "$(field "${ROWS[4]}" 1)")"
printf '#!/bin/sh\necho not ours\n' > "${occupied_target}"
chmod 0755 "${occupied_target}"
before="$(digest_of "${occupied_target}")"
if run_ceremony "${occupied}" "" --install; then
  fail "the ceremony installed over a pathname it did not reserve"
else
  if [[ "$(digest_of "${occupied_target}")" == "${before}" ]]; then
    pass "a pre-existing object at a reserved pathname is refused and left alone"
  else
    fail "a pre-existing object was modified"
  fi
fi

# A symlink at a reserved pathname is equally never followed or replaced.
linked="${WORK}/linked"; build_fixture "${linked}"
linked_target="$(bind_target "${linked}" "$(field "${ROWS[3]}" 1)")"
ln -s /etc/shadow "${linked_target}"
if run_ceremony "${linked}" "" --install; then
  fail "the ceremony installed over a symlink"
else
  if [[ -L "${linked_target}" && "$(readlink "${linked_target}")" == "/etc/shadow" ]]; then
    pass "a symlink at a reserved pathname is refused and left intact"
  else
    fail "a symlink at a reserved pathname was disturbed"
  fi
fi

# ===========================================================================
# 5. every interrupted transaction is replayed to one complete generation
# ===========================================================================
# Nothing published and a COMMITTING journal is not a case for forward
# completion: no pathname was ever reserved in a way an operator can see, so
# the safe terminal state is the one the host is already in.
none="${WORK}/fwd-none"; build_fixture "${none}"
stage_interrupted "${none}" 0 keep
if run_ceremony "${none}" "" --install; then
  fail "an interrupted transaction that published nothing reported success"
else
  if [[ "$(census "${none}")" == "GEN6=5 GEN7=0 UNKNOWN=0" \
        && "$(journal_state "${none}")" == "ROLLED_BACK" ]]; then
    pass "an interrupted transaction that published nothing settles as a complete generation 6"
  else
    fail "recovery from nothing-published ended at $(census "${none}")"
  fi
fi

for done_count in 1 2 3 4 5; do
  root="${WORK}/fwd-${done_count}"; build_fixture "${root}"
  stage_interrupted "${root}" "${done_count}" keep
  if run_ceremony "${root}" "" --install; then
    if [[ "$(census "${root}")" == "GEN6=0 GEN7=5 UNKNOWN=0" \
          && "$(journal_state "${root}")" == "COMMITTED" ]]; then
      pass "an interrupted transaction with ${done_count} published and prepared material completes forward"
    else
      fail "forward recovery from ${done_count} ended at $(census "${root}")"
    fi
  else
    fail "forward recovery from ${done_count} failed: $(tail -12 "${root}/last-run.log")"
  fi
done

for done_count in 1 2 3 4; do
  root="${WORK}/back-${done_count}"; build_fixture "${root}"
  stage_interrupted "${root}" "${done_count}" discard
  if run_ceremony "${root}" "" --install; then
    fail "recovery from ${done_count} with no prepared material reported success"
  else
    if [[ "$(census "${root}")" == "GEN6=5 GEN7=0 UNKNOWN=0" \
          && "$(journal_state "${root}")" == "ROLLED_BACK" ]]; then
      pass "an interrupted transaction with ${done_count} published and no prepared material rolls back"
    else
      fail "backward recovery from ${done_count} ended at $(census "${root}"), journal $(journal_state "${root}")"
    fi
  fi
done

# ===========================================================================
# 6. the generation-6 baseline is verified, not assumed
# ===========================================================================
drift="${WORK}/drift"; build_fixture "${drift}"
victim="${drift}/usr/lib/kyri/python/tools/capability/execution/protocol.py"
chmod u+w "${victim}"; printf '# drift\n' >> "${victim}"
if run_ceremony "${drift}" "" --install; then
  fail "the ceremony installed onto a drifted generation-6 baseline"
else
  if grep -q 'drifted' "${drift}/last-run.log"; then
    pass "a drifted generation-6 runtime object refuses the transaction"
  else
    fail "baseline drift refused for the wrong reason: $(tail -8 "${drift}/last-run.log")"
  fi
fi

noev="${WORK}/noev"; build_fixture "${noev}"
rm -f "${noev}/root/kyri-gen6-library-digests.txt"
if run_ceremony "${noev}" "" --install; then
  fail "the ceremony installed with no generation-6 evidence"
else
  pass "absent generation-6 evidence refuses the transaction"
fi

stray="${WORK}/stray"; build_fixture "${stray}"
printf 'STRAY = 1\n' > "${stray}/usr/lib/kyri/python/tools/capability/execution/stray.py"
if run_ceremony "${stray}" "" --install; then
  fail "an installed object absent from the generation-6 evidence was accepted"
else
  pass "an installed object absent from the generation-6 evidence refuses the transaction"
fi

helper="${WORK}/helper"; build_fixture "${helper}"
chmod u+w "${helper}/usr/libexec/kyri-exec-worker.py"
printf '# drift\n' >> "${helper}/usr/libexec/kyri-exec-worker.py"
if run_ceremony "${helper}" "" --install; then
  fail "a drifted privileged helper was accepted"
else
  if grep -q 'helper drifted' "${helper}/last-run.log"; then
    pass "a drifted /usr/libexec helper refuses the transaction"
  else
    fail "helper drift refused for the wrong reason: $(tail -8 "${helper}/last-run.log")"
  fi
fi

# ===========================================================================
# 6b. the helper baseline is proven by pathname, not by counting records
# ===========================================================================
# The accepted Generation-6 helper evidence is SEVEN lines: three helper
# digests, the tmpfiles prerequisite digest, and three metadata lines. Treating
# every digest-bearing record as a helper made the live file refuse a host with
# no drift at all. What must be proven is the three ruled pathnames, and what
# must be refused is anything that would enlarge that set.

helper_evidence() { printf '%s' "$1/root/kyri-gen6-helper-digests.txt"; }

if [[ "$(grep -c . "$(helper_evidence "${happy}")")" -eq 7 \
      && "$(grep -cE '^[0-9a-f]{64}' "$(helper_evidence "${happy}")")" -eq 4 ]]; then
  pass "the fixture reproduces the real generation-6 evidence shape: 7 lines, 4 digest records"
else
  fail "the fixture evidence is not the real shape: $(grep -c . "$(helper_evidence "${happy}")") lines"
fi

# The legitimate tmpfiles record is not a helper and must not refuse anything.
# Already proven by every accepting case above, which now all carry it. Proven
# again explicitly with a SECOND non-helper record, so the rule is "not a
# helper pathname" rather than "exactly one known extra line".
extra="${WORK}/extra-nonhelper"; build_fixture "${extra}"
printf '%s  %s\n' "$(printf 'd%.0s' {1..64})" "/etc/tmpfiles.d/some-other-prerequisite.conf" \
  >> "$(helper_evidence "${extra}")"
if run_ceremony "${extra}" "" --verify; then
  pass "a non-helper digest record in the evidence is not counted and does not refuse"
else
  fail "a non-helper evidence record refused a clean host: $(tail -8 "${extra}/last-run.log")"
fi

missing="${WORK}/helper-missing"; build_fixture "${missing}"
grep -v 'kyri-exec-quota' "$(helper_evidence "${missing}")" > "${missing}/evidence.tmp"
mv "${missing}/evidence.tmp" "$(helper_evidence "${missing}")"
if run_ceremony "${missing}" "" --install; then
  fail "a helper absent from the generation-6 evidence was accepted"
else
  if grep -q 'kyri-exec-quota' "${missing}/last-run.log" \
     && [[ "$(census "${missing}")" == "GEN6=5 GEN7=0 UNKNOWN=0" ]]; then
    pass "a required helper absent from the generation-6 evidence refuses, naming it"
  else
    fail "a missing helper record was refused for the wrong reason: $(tail -8 "${missing}/last-run.log")"
  fi
fi

dup="${WORK}/helper-dup"; build_fixture "${dup}"
duplicate_line="$(grep 'kyri-exec-transition$' "$(helper_evidence "${dup}")")"
printf '%s\n' "${duplicate_line}" >> "$(helper_evidence "${dup}")"
if run_ceremony "${dup}" "" --install; then
  fail "a helper recorded twice in the generation-6 evidence was accepted"
else
  if grep -q 'more than once' "${dup}/last-run.log"; then
    pass "a required helper recorded more than once refuses the transaction"
  else
    fail "a duplicated helper record was refused for the wrong reason: $(tail -8 "${dup}/last-run.log")"
  fi
fi

enlarge="${WORK}/helper-enlarge"; build_fixture "${enlarge}"
printf '%s  %s\n' "$(printf 'e%.0s' {1..64})" "/usr/libexec/kyri-exec-something-else" \
  >> "$(helper_evidence "${enlarge}")"
if run_ceremony "${enlarge}" "" --install; then
  fail "evidence naming an extra privileged helper was accepted"
else
  if grep -q 'kyri-exec-something-else' "${enlarge}/last-run.log"; then
    pass "evidence naming an unexpected /usr/libexec/kyri-exec-* pathname refuses"
  else
    fail "an enlarged helper baseline was refused for the wrong reason: $(tail -8 "${enlarge}/last-run.log")"
  fi
fi

recorded="${WORK}/helper-recorded"; build_fixture "${recorded}"
sed -i "s#^[0-9a-f]\{64\}\(  /usr/libexec/kyri-exec-quota\)\$#$(printf 'f%.0s' {1..64})\1#" \
  "$(helper_evidence "${recorded}")"
if run_ceremony "${recorded}" "" --install; then
  fail "a helper whose recorded digest does not match the installed bytes was accepted"
else
  if grep -q 'drifted' "${recorded}/last-run.log"; then
    pass "a recorded helper digest that disagrees with the installed bytes refuses"
  else
    fail "a mismatched helper record was refused for the wrong reason: $(tail -8 "${recorded}/last-run.log")"
  fi
fi

# ===========================================================================
# 7. no live caller may exist during the commit window
# ===========================================================================
for grant in "${SUDOERS_ABS}" "${VERIFY_SUDOERS_ABS}"; do
  root="${WORK}/grant-$(basename "${grant}")"; build_fixture "${root}"
  mkdir -p "${root}$(dirname "${grant}")"
  printf 'cschott ALL=(root) NOPASSWD: /usr/libexec/kyri-exec-transition\n' > "${root}${grant}"
  if run_ceremony "${root}" "" --install; then
    fail "the ceremony installed while ${grant} existed"
  else
    if [[ "$(census "${root}")" == "GEN6=5 GEN7=0 UNKNOWN=0" ]]; then
      pass "an existing ${grant} refuses the transaction and nothing is published"
    else
      fail "a run with ${grant} present published something"
    fi
  fi
done

# ===========================================================================
# 8. the installed contract is verified from installed bytes
# ===========================================================================
contract="${WORK}/contract"; build_fixture "${contract}"
run_ceremony "${contract}" "" --install || fail "contract fixture did not install"
verification_installed="${contract}/usr/lib/kyri/python/tools/capability/execution/verification.py"
chmod u+w "${verification_installed}"
printf 'from .worker import create_argv\n' >> "${verification_installed}"
if run_ceremony "${contract}" "" --verify-installed; then
  fail "--verify-installed accepted a verification module that binds create_argv"
else
  pass "--verify-installed refuses an installed verification module that can reach create_argv"
fi

store="${WORK}/store"; build_fixture "${store}"
run_ceremony "${store}" "" --install || fail "store fixture did not install"
store_installed="${store}/usr/lib/kyri/python/tools/capability/execution/image_store.py"
chmod u+w "${store_installed}"
printf 'import subprocess\n' >> "${store_installed}"
if run_ceremony "${store}" "" --verify-installed; then
  fail "--verify-installed accepted an image store that imports subprocess"
else
  pass "--verify-installed refuses an installed image store that can start a process"
fi

aimed="${WORK}/aimed"; build_fixture "${aimed}"
run_ceremony "${aimed}" "" --install || fail "aimed fixture did not install"
policy_installed="${aimed}/usr/lib/kyri/python/kyri_exec_verify.py"
chmod u+w "${policy_installed}"
sed -i 's#^WORKER_SCRIPT = .*#WORKER_SCRIPT = "/usr/libexec/kyri-exec-worker.py"#' "${policy_installed}"
if run_ceremony "${aimed}" "" --verify-installed; then
  fail "--verify-installed accepted a verification policy aimed at the production worker"
else
  pass "--verify-installed refuses a verification policy aimed at the production worker"
fi

byte="${WORK}/byte"; build_fixture "${byte}"
run_ceremony "${byte}" "" --install || fail "byte fixture did not install"
entry_installed="${byte}/usr/libexec/kyri-exec-verify"
chmod u+w "${entry_installed}"
printf '# tampered\n' >> "${entry_installed}"
if run_ceremony "${byte}" "" --verify-installed; then
  fail "--verify-installed accepted an installed object that is not the reviewed bytes"
else
  if grep -q "${entry_installed}" "${byte}/last-run.log"; then
    pass "--verify-installed proves every installed byte against the reviewed commit"
  else
    fail "byte tampering was refused without naming the object"
  fi
fi

# ===========================================================================
# 9. what the ceremony structurally cannot do
# ===========================================================================
assert_absent_from_source() {
  local label="$1"; shift
  local body found=""
  body="$(grep -v '^[[:space:]]*#' "${CEREMONY}")"
  local token
  for token in "$@"; do
    if grep -qF -- "${token}" <<<"${body}"; then found="${found} ${token}"; fi
  done
  if [[ -z "${found}" ]]; then pass "${label}"; else fail "${label} --${found}"; fi
}

# Assembled rather than written out, so this suite does not contain the very
# tokens it asserts are absent from the file it reads.
assert_absent_from_source \
  "the ceremony invokes no container runtime, transition, or worker" \
  "pod""man " "doc""ker " "buil""dah" "kyri-exec-transition " "kyri-exec-verify-worker.py " \
  "runuser -u kyri-capability" "--admit" "--genesis" "--bootstrap-authority"

assert_absent_from_source \
  "the ceremony writes no sudoers policy and no authority state" \
  "vis""udo" ">> \${SUDOERS}" "> \${SUDOERS}" ">> \${VERIFY_SUDOERS}" \
  "> \${VERIFY_SUDOERS}" "> \${AUTHORITY_ROOT}" "> \${CONTROL_ROOT}" \
  "CIMP-" "CGEN-" "CINV-"

# Every git invocation must go through git_as_owner. Checked with the
# git_as_owner definition itself removed, since that function is the one place
# a bare `git` is correct.
git_call_sites() {
  awk '/^git_as_owner\(\) \{/{skip=1} skip && /^\}$/{skip=0; next} !skip' "${CEREMONY}" \
    | grep -v '^[[:space:]]*#' | grep -nE '(^|[^_[:alnum:]])git[[:space:]]' || true
}
if grep -q 'git_as_owner()' "${CEREMONY}" && [[ -z "$(git_call_sites)" ]]; then
  pass "every git invocation goes through git_as_owner: root never runs git in the coordinator's repository"
else
  fail "the ceremony runs git directly: $(git_call_sites | head -3)"
fi

# shellcheck disable=SC2016  # searching for literal shell text, not expanding it
if grep -q 'runuser -u "${REPO_OWNER}"' "${CEREMONY}"; then
  pass "git_as_owner drops to the repository owner when running as root"
else
  fail "git_as_owner does not drop to the repository owner"
fi

# Every mutable path the ceremony touches must be fixture-prefixable, or a
# fixture run would reach a production pathname.
# shellcheck disable=SC2016  # searching for literal shell text, not expanding it
if sed -n '/^if \[\[ -n "${FIXTURE}" \]\]; then/,/^fi$/p' "${CEREMONY}" \
     | grep -q 'TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"'; then
  pass "the transaction root is fixture-prefixed: no fixture run writes under /root"
else
  fail "the transaction root is not fixture-prefixed"
fi

# ===========================================================================
# 10. registration and live state
# ===========================================================================
name="tests/test-capability-execution-generation7-installer.sh"
if grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the generation-7 suite runs in local validation and in CI"
else
  fail "the generation-7 suite is not registered"
fi

if grep -q 'install-generation-7.sh' "${REPOSITORY}/provisioning/execution/README.md"; then
  pass "the runbook documents the G6.1A ceremony"
else
  fail "the runbook does not document the G6.1A ceremony"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  pass "this suite runs unprivileged"
else
  fail "this suite must not run as root"
fi

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path changed while this suite ran"
else
  fail "a production path changed: ${PRODUCTION_BEFORE} -> ${PRODUCTION_AFTER}"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Generation-7 (G6.1A) ceremony validation passed.\n'
else
  printf 'Generation-7 (G6.1A) ceremony validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
