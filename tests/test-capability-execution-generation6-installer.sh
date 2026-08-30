#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-6 installer.
#
# ISOLATED BY CONSTRUCTION. Every case builds a throwaway fixture tree and runs
# the installer with --fixture against it. Nothing here touches
# /usr/lib/kyri/python, /usr/libexec, /root, /etc/tmpfiles.d, /run, sudoers, or
# any authority root, and nothing here needs root. No group is created or
# modified, no tmpfiles fragment is installed, and systemd-tmpfiles is never
# executed -- the prerequisite ceremony belongs to an operator, and this suite
# only proves the installer refuses to perform it.
#
# WHAT IS PROVEN. Generation 6 adds a NEW runtime object to a set that was
# previously all replacements, and that is the whole difficulty: a rollback now
# has to REMOVE something rather than restore it, and removing the wrong thing
# is worse than leaving a failed installation in place. So failure is injected
# at each of the six commit positions, every interrupted transaction is
# replayed from every reachable journal/bytes combination, and the new
# pathname is attacked directly -- pre-existing, modified after publication,
# and inconsistent with the journal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Operator tooling, not runtime authority: the installer lives beside the
# runbook it belongs to and is never installed onto the host.
INSTALLER="${REPOSITORY}/provisioning/execution/install-generation-6.sh"
[[ -f "${INSTALLER}" ]] || { printf 'installer missing: %s\n' "${INSTALLER}" >&2; exit 1; }
# The installer pins the deployment path as a production constant. If this
# checkout is somewhere else, the two disagree and every case would fail for a
# reason that has nothing to do with the transaction logic.
# This suite drives an operator ceremony that pins its repository as
# production authority. Where the checkout is not that pin the ceremony
# would read a different repository, so the suite is host-only rather than
# failing for a reason that has nothing to do with what it tests.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${INSTALLER}"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# ===========================================================================
# Fixture-only guard
# ===========================================================================
# Snapshotted before the first case and compared after the last. The harness
# drives a root-capable installer against a host prerequisite that does not yet
# exist, so "it only touches fixtures" has to be a measured property rather
# than an intention. Everything below is read-only against these paths.
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /root/kyri-gen6-transaction
  /etc/sudoers.d/kyri-exec
  /etc/tmpfiles.d
  /run/kyri
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

# ===========================================================================
# Everything pinned, read from the installer so the two can never disagree
# ===========================================================================
mapfile -t RAW_ROWS < <(sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep '^"' | tr -d '"')
[[ "${#RAW_ROWS[@]}" -eq 6 ]] || { printf 'expected 6 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
# The installer's matrix carries an unexpanded ${LIBRARY_ROOT}. Turn it into a
# placeholder once so every fixture can bind its own root, and so the digests
# stay pinned to the installer rather than copied here.
ROWS=()
for raw in "${RAW_ROWS[@]}"; do
  ROWS+=("${raw//\$\{LIBRARY_ROOT\}/%LIB%}")
done

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${INSTALLER}" | head -1; }
GEN6_COMMIT="$(read_pin COMMIT)"
GEN5_COMMIT="$(read_pin GEN5_COMMIT)"
TMPFILES_SOURCE="$(read_pin TMPFILES_SOURCE)"
TMPFILES_TARGET_ABS="$(read_pin TMPFILES_TARGET)"
SNAPSHOT_PARENT_ABS="$(read_pin SNAPSHOT_PARENT)"
SNAPSHOT_ROOT_ABS="$(read_pin SNAPSHOT_ROOT)"
RUN_ROOT_ABS="$(read_pin RUN_ROOT)"
EXECUTION_GROUP="$(read_pin EXECUTION_GROUP)"
COORDINATOR="$(read_pin COORDINATOR)"
for name in GEN6_COMMIT GEN5_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'the installer pins no full 40-character %s\n' "${name}" >&2; exit 1; }
done
[[ -n "${TMPFILES_SOURCE}" && -n "${TMPFILES_TARGET_ABS}" && -n "${SNAPSHOT_ROOT_ABS}" ]] || {
  printf 'the installer does not pin the prerequisite paths\n' >&2; exit 1; }

field() { IFS='|' read -r -a f <<<"$1"; printf '%s' "${f[$2]}"; }
bind_target() {
  local root="$1" raw="$2"
  printf '%s' "${raw//%LIB%/${root}/usr/lib/kyri/python}"
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# The identity this suite actually runs as. A fixture tree cannot be owned by
# root:kyri-capability, so the ACCEPTING prerequisite cases rebind the
# installer's ownership expectations to this identity through the installer's
# one fixture seam. The REFUSING cases omit the seam and get the production
# expectations, which a cschott-owned tree cannot satisfy -- so the production
# comparison is the thing under test in both directions.
RUNNER="$(id -un):$(id -gn)"

# ===========================================================================
# Generation-5 fixture baseline — pinned immutable history
# ===========================================================================
# The baseline MUST NOT come from the installed tree. The Generation-5 suite
# learned this the hard way: a baseline taken from /usr/lib/kyri/python made
# the whole suite silently stop testing anything the day the next generation
# was installed, because every fixture then started at "already installed;
# nothing to do".
#
# Generation 6 has it easier than Generation 5 did. The complete Generation-5
# runtime surface is exactly one commit -- the one the Generation-5 installer
# pinned -- so the baseline is a tree read, not a per-file archaeology
# exercise. That commit is a constant read out of the installer: no caller, no
# environment variable, and no test input selects a revision or a path.
require_history() {
  local shallow object
  shallow="$(git -C "${REPOSITORY}" rev-parse --is-shallow-repository)"
  if [[ "${shallow}" == "true" ]]; then
    printf 'FAIL: this is a shallow clone; the generation-5 fixture baseline lives in history.\n' >&2
    printf '      CI checks out with fetch-depth: 0 for exactly this reason.\n' >&2
    exit 1
  fi
  local missing=0
  for object in "${GEN5_COMMIT}" "${GEN6_COMMIT}"; do
    git -C "${REPOSITORY}" cat-file -e "${object}^{commit}" 2>/dev/null || {
      printf 'FAIL: pinned commit %s is absent\n' "${object}" >&2
      missing=$((missing + 1)); }
  done
  (( missing == 0 )) || exit 1
  # The new object must be genuinely new, or "CREATE" is a lie and every case
  # below is testing the wrong operation.
  if git -C "${REPOSITORY}" cat-file -e "${GEN5_COMMIT}:tools/capability/execution/snapshot.py" 2>/dev/null; then
    fail "snapshot.py already existed at generation 5: it is not a new object"
  else
    pass "snapshot.py is absent at the pinned generation-5 commit: genuinely new"
  fi
  pass "both pinned commits are present in history"
}
require_history

materialise() {
  local commit="$1" source="$2" destination="$3" expected="${4:-}" observed
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
  [[ -n "${expected}" ]] || return 0
  observed="$(digest_of "${destination}")"
  # Fail closed rather than inventing fixture bytes: if history no longer
  # reproduces the accepted digest, the pin is wrong and the suite is
  # meaningless, not merely inconvenient.
  [[ "${observed}" == "${expected}" ]] || {
    printf 'blob for %s at %s is %s, expected %s\n' \
      "${source}" "${commit}" "${observed}" "${expected}" >&2
    exit 1; }
}

# A fixture holding the complete accepted Generation 5: the exact bytes at
# every one of the 43 library objects and all three /usr/libexec objects, the
# Generation-5 evidence the installer verifies against, and the provisioned
# host prerequisite.
#
# Nothing below reads /usr/lib/kyri/python, /usr/libexec, /etc/tmpfiles.d, or
# /run. Every byte comes from a pinned git object.
build_fixture() {
  local root="$1" row source target mode gen5 file
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/lib/kyri/python/tools/common" \
           "${root}/usr/libexec" "${root}/root" "${root}/fixture"

  # The library tree, from the generation-5 commit -- the file SET as well as
  # the bytes, so the fixture holds 43 objects and snapshot.py is absent by
  # construction rather than by deletion.
  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN5_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN5_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  local flattened
  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py; do
    materialise "${GEN5_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  chmod 0555 "${root}/usr/libexec/kyri-exec-quota"

  # Every replacement target must hold the installer's pinned generation-5
  # bytes, and the create target must not exist. Proved, not assumed.
  for row in "${ROWS[@]}"; do
    source="$(field "${row}" 0)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    mode="$(field "${row}" 2)"
    gen5="$(field "${row}" 4)"
    if [[ "${gen5}" == "ABSENT" ]]; then
      [[ ! -e "${target}" ]] || { printf 'fixture holds %s, which is absent at generation 5\n' "${target}" >&2; exit 1; }
      continue
    fi
    [[ "$(digest_of "${target}")" == "${gen5}" ]] || {
      printf 'fixture target %s is %s, expected generation-5 %s\n' \
        "${target}" "$(digest_of "${target}")" "${gen5}" >&2; exit 1; }
    chmod "${mode}" "${target}"
  done

  # Evidence generated from the fixture, with host-style pathnames, in the
  # exact `sha256sum` layout the installer parses.
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen5-library-digests.txt"
  ( cd "${root}" && sha256sum usr/libexec/kyri-exec-transition \
      usr/libexec/kyri-exec-worker.py usr/libexec/kyri-exec-quota ) \
    | sed 's#  usr/libexec/#  /usr/libexec/#' \
    > "${root}/root/kyri-gen5-helper-digests.txt"

  build_prerequisite "${root}"
}

# The provisioned host prerequisite, as systemd-tmpfiles would have left it --
# built by this suite inside its own fixture, never by running systemd-tmpfiles
# and never at a real path.
build_prerequisite() {
  local root="$1"
  mkdir -p "${root}${SNAPSHOT_ROOT_ABS}" "${root}$(dirname "${TMPFILES_TARGET_ABS}")"
  chmod 0755 "${root}${RUN_ROOT_ABS}" "${root}${SNAPSHOT_PARENT_ABS}"
  chmod 0770 "${root}${SNAPSHOT_ROOT_ABS}"
  materialise "${GEN6_COMMIT}" "${TMPFILES_SOURCE}" "${root}${TMPFILES_TARGET_ABS}"
  chmod 0644 "${root}${TMPFILES_TARGET_ABS}"
  {
    printf 'run=%s\n'      "${RUNNER}"
    printf 'kyri=%s\n'     "${RUNNER}"
    printf 'material=%s\n' "${RUNNER}"
    printf 'fragment=%s\n' "${RUNNER}"
  } > "${root}/fixture/expected-ownership"
  printf '%s\n' "${COORDINATOR}" > "${root}/fixture/coordinator-groups"
}

# A fixture with the runtime baseline but WITHOUT the prerequisite: the exact
# state of the live host today.
build_fixture_without_prerequisite() {
  local root="$1"
  build_fixture "${root}"
  rm -rf "${root}${SNAPSHOT_PARENT_ABS}" "${root}${TMPFILES_TARGET_ABS}"
}

# What generation is each target, decided from bytes alone? ABSENT is the
# generation-5 state of the create target, so "missing" is a census answer
# rather than a census failure.
census() {
  local root="$1" row target gen5 gen6 observed g5=0 g6=0 unknown=0
  for row in "${ROWS[@]}"; do
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    if [[ "${gen5}" == "ABSENT" ]]; then
      if   [[ ! -e "${target}" ]]; then g5=$((g5 + 1))
      elif [[ -f "${target}" && "$(digest_of "${target}")" == "${gen6}" ]]; then g6=$((g6 + 1))
      else unknown=$((unknown + 1)); fi
      continue
    fi
    observed="$(digest_of "${target}")"
    if   [[ "${observed}" == "${gen6}" ]]; then g6=$((g6 + 1))
    elif [[ "${observed}" == "${gen5}" ]]; then g5=$((g5 + 1))
    else unknown=$((unknown + 1)); fi
  done
  printf 'GEN5=%d GEN6=%d UNKNOWN=%d' "${g5}" "${g6}" "${unknown}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }
snapshot_path() { printf '%s' "$1/usr/lib/kyri/python/tools/capability/execution/snapshot.py"; }
snapshot_gen6_digest() {
  local row
  for row in "${ROWS[@]}"; do
    [[ "$(field "${row}" 4)" == "ABSENT" ]] || continue
    field "${row}" 5; return
  done
}
SNAPSHOT_DIGEST="$(snapshot_gen6_digest)"
[[ "${SNAPSHOT_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'the installer declares no CREATE target\n' >&2; exit 1; }

journal_state() {
  local root="$1"
  [[ -f "${root}/root/kyri-gen6-transaction/journal" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${root}/root/kyri-gen6-transaction/journal" | tail -1
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

# Reconstruct an interrupted COMMIT by hand: the first N targets published, the
# journal left COMMITTING, and prepared/backup material present or absent as
# the case requires.
stage_interrupted() {
  local root="$1" done_count="$2" keep_prepared="$3" row index=0 source target mode gen5 gen6
  mkdir -p "${root}/root/kyri-gen6-transaction"
  {
    printf 'transaction=gen6-%s\n' "${GEN6_COMMIT:0:12}"
    printf 'commit=%s\n' "${GEN6_COMMIT}"
    printf 'state=COMMITTING\n'
  } > "${root}/root/kyri-gen6-transaction/journal"
  for row in "${ROWS[@]}"; do
    index=$((index + 1))
    source="$(field "${row}" 0)"; mode="$(field "${row}" 2)"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    target="$(bind_target "${root}" "$(field "${row}" 1)")"
    [[ "${gen5}" == "ABSENT" ]] || cp -p "${target}" "${target}.kyri-gen5.old"
    materialise "${GEN6_COMMIT}" "${source}" "${target}.kyri-gen6.new" "${gen6}"
    chmod "${mode}" "${target}.kyri-gen6.new"
    if (( index <= done_count )); then
      rm -f "${target}"
      cp -p "${target}.kyri-gen6.new" "${target}"
      chmod "${mode}" "${target}"
      rm -f "${target}.kyri-gen6.new"
      printf 'progress:%d=GEN6\n' "${index}" >> "${root}/root/kyri-gen6-transaction/journal"
    elif [[ "${keep_prepared}" != "keep" ]]; then
      rm -f "${target}.kyri-gen6.new"
    fi
  done
}

# ===========================================================================
# 0. the happy path
# ===========================================================================
happy="${WORK}/happy"; build_fixture "${happy}"
if [[ "$(library_count "${happy}")" -eq 43 && ! -e "$(snapshot_path "${happy}")" ]]; then
  pass "the fixture baseline is a complete generation 5: 43 library objects, snapshot.py absent"
else
  fail "the fixture baseline is not generation 5: $(library_count "${happy}") objects"
fi

if run_installer "${happy}" "" --install; then
  state="$(census "${happy}")"
  if [[ "${state}" == "GEN5=0 GEN6=6 UNKNOWN=0" && "$(journal_state "${happy}")" == "COMMITTED" ]]; then
    pass "clean install reaches a complete Generation 6 (${state})"
  else
    fail "clean install ended at ${state}, journal $(journal_state "${happy}")"
  fi
else
  fail "clean install failed: $(tail -8 "${happy}/last-run.log")"
fi

if [[ "$(library_count "${happy}")" -eq 44 ]]; then
  pass "the installed library count moved 43 -> 44"
else
  fail "the library holds $(library_count "${happy}") objects after install, expected 44"
fi
if [[ -f "$(snapshot_path "${happy}")" \
   && "$(digest_of "$(snapshot_path "${happy}")")" == "${SNAPSHOT_DIGEST}" \
   && "$(stat -c '%a' "$(snapshot_path "${happy}")")" == "444" ]]; then
  pass "snapshot.py was created with the pinned Generation-6 bytes and mode 0444"
else
  fail "snapshot.py is wrong after a clean install"
fi
# The new object must have exactly one link: create_once publishes with link(2)
# and unlinks the prepared name, and a leftover second link would mean the
# prepared object is still reachable under a name nothing verifies.
if [[ "$(stat -c '%h' "$(snapshot_path "${happy}")")" == "1" ]]; then
  pass "the created object has a single link: the prepared name was unlinked"
else
  fail "snapshot.py has $(stat -c '%h' "$(snapshot_path "${happy}")") links after publication"
fi

# Evidence only after the complete set verifies, under new names, with the
# Generation-5 evidence preserved.
if [[ -f "${happy}/root/kyri-gen6-library-digests.txt" \
   && -f "${happy}/root/kyri-gen6-helper-digests.txt" \
   && -f "${happy}/root/kyri-gen5-library-digests.txt" \
   && -f "${happy}/root/kyri-gen5-helper-digests.txt" ]]; then
  pass "Generation-6 evidence written under new names and Generation-5 evidence preserved"
else
  fail "evidence handling is wrong after a clean install"
fi
if grep -q 'snapshot\.py$' "${happy}/root/kyri-gen6-library-digests.txt" \
   && [[ "$(grep -c . "${happy}/root/kyri-gen6-library-digests.txt")" -eq 44 ]]; then
  pass "the Generation-6 evidence records 44 objects including snapshot.py"
else
  fail "the Generation-6 evidence does not record the complete set"
fi
if find "${happy}/usr" -name '*.kyri-gen6.new' -o -name '*.kyri-gen5.old' | grep -q .; then
  fail "transaction artefacts survived a successful install"
else
  pass "transaction artefacts were removed after a successful install"
fi

# ===========================================================================
# 1. read-only modes
# ===========================================================================
baseline="${WORK}/baseline"; build_fixture "${baseline}"
if run_installer "${baseline}" "" --verify; then
  pass "--verify exits 0 on an untouched Generation-5 fixture with the prerequisite provisioned"
else
  fail "--verify failed on a valid Generation-5 fixture: $(tail -10 "${baseline}/last-run.log")"
fi
if [[ "$(census "${baseline}")" == "GEN5=6 GEN6=0 UNKNOWN=0" \
   && "$(library_count "${baseline}")" -eq 43 ]]; then
  pass "--verify mutated nothing"
else
  fail "--verify mutated the fixture"
fi

if run_installer "${happy}" "" --verify-installed; then
  pass "--verify-installed exits 0 on the installed Generation-6 fixture"
else
  fail "--verify-installed failed after a clean install: $(tail -10 "${happy}/last-run.log")"
fi
if [[ "$(census "${happy}")" == "GEN5=0 GEN6=6 UNKNOWN=0" \
   && "$(library_count "${happy}")" -eq 44 ]]; then
  pass "--verify-installed mutated nothing"
else
  fail "--verify-installed mutated the fixture"
fi

# ===========================================================================
# 2. failure injected at every commit position
# ===========================================================================
for position in 1 2 3 4 5 6; do
  root="${WORK}/inject-${position}"; build_fixture "${root}"
  if run_installer "${root}" "KYRI_GEN6_FAIL_AT=${position}" --install; then
    fail "injected failure at ${position} was reported as success"
    continue
  fi
  state="$(census "${root}")"
  journal="$(journal_state "${root}")"
  count="$(library_count "${root}")"
  if [[ "${state}" == "GEN5=6 GEN6=0 UNKNOWN=0" && "${journal}" == "ROLLED_BACK" \
     && "${count}" -eq 43 && ! -e "$(snapshot_path "${root}")" ]]; then
    pass "failure at commit ${position}: rolled back to a complete Generation 5, snapshot.py removed, 43 objects, journal ROLLED_BACK"
  else
    fail "failure at ${position} left ${state} (journal ${journal}, ${count} objects, snapshot.py $( [[ -e "$(snapshot_path "${root}")" ]] && printf present || printf absent))"
  fi
  if [[ -f "${root}/root/kyri-gen6-library-digests.txt" ]]; then
    fail "evidence was written for a rolled-back transaction at ${position}"
  fi
done
pass "no rolled-back transaction wrote Generation-6 evidence"

# ===========================================================================
# 3. interrupted transactions: recover FORWARD
# ===========================================================================
for done_count in 1 2 3 4 5; do
  root="${WORK}/crash-forward-${done_count}"; build_fixture "${root}"
  stage_interrupted "${root}" "${done_count}" keep
  before="$(census "${root}")"
  if run_installer "${root}" "" --install; then
    after="$(census "${root}")"
    if [[ "${after}" == "GEN5=0 GEN6=6 UNKNOWN=0" \
       && "$(journal_state "${root}")" == "COMMITTED" \
       && "$(library_count "${root}")" -eq 44 ]]; then
      pass "interrupted after ${done_count} publications (${before}) recovers FORWARD to ${after}, 44 objects"
    else
      fail "interrupted after ${done_count} recovered to ${after}, journal $(journal_state "${root}"), $(library_count "${root}") objects"
    fi
  else
    fail "recovery after ${done_count} publications failed: $(tail -8 "${root}/last-run.log")"
  fi
done

# ===========================================================================
# 4. interrupted transaction with prepared material lost -> ROLLBACK
# ===========================================================================
for done_count in 1 2 3 5; do
  root="${WORK}/crash-back-${done_count}"; build_fixture "${root}"
  stage_interrupted "${root}" "${done_count}" drop
  before="$(census "${root}")"
  # A rollback is a complete outcome that is deliberately NOT success: the
  # installer exits non-zero so no automation mistakes it for Generation 6.
  run_installer "${root}" "" --install && status=0 || status=$?
  after="$(census "${root}")"
  if [[ "${after}" == "GEN5=6 GEN6=0 UNKNOWN=0" \
     && "$(journal_state "${root}")" == "ROLLED_BACK" && "${status}" -ne 0 \
     && "$(library_count "${root}")" -eq 43 \
     && ! -e "$(snapshot_path "${root}")" ]] \
     && grep -q "Generation 6 was NOT installed" "${root}/last-run.log"; then
    pass "interrupted after ${done_count} with no prepared material (${before}) rolls BACK to ${after}, 43 objects"
  else
    fail "lost-prepare recovery after ${done_count} ended at ${after}, journal $(journal_state "${root}"), status ${status}, $(library_count "${root}") objects"
  fi
done

# ===========================================================================
# 5. the new pathname, attacked directly
# ===========================================================================
# 5a. Something is already there before a fresh transaction. It is not this
# transaction's, so it is neither overwritten nor adopted nor deleted. The
# refusal arrives at the earliest guard that can see it -- an unknown object is
# also a 44th library file the Generation-5 baseline does not record -- and
# what matters is that it arrives before anything is staged.
root="${WORK}/new-preexisting"; build_fixture "${root}"
printf 'somebody else was here\n' > "$(snapshot_path "${root}")"
existing="$(digest_of "$(snapshot_path "${root}")")"
if run_installer "${root}" "" --install; then
  fail "an installation started over a pre-existing snapshot.py"
else
  if [[ "$(digest_of "$(snapshot_path "${root}")")" == "${existing}" ]] \
     && ! find "${root}/usr" -name '*.kyri-gen6.new' | grep -q .; then
    pass "a pre-existing object at the create pathname is refused, left untouched, and nothing was staged"
  else
    fail "pre-existing snapshot.py handled wrongly: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 5b. The same object during RECOVERY, where the baseline count check is not
# in the way: classification must call it UNKNOWN and recovery must refuse to
# guess rather than deleting or adopting it.
root="${WORK}/new-preexisting-recover"; build_fixture "${root}"
stage_interrupted "${root}" 0 keep
rm -f "$(snapshot_path "${root}").kyri-gen6.new"
printf 'somebody else was here\n' > "$(snapshot_path "${root}")"
existing="$(digest_of "$(snapshot_path "${root}")")"
if run_installer "${root}" "" --install; then
  fail "recovery proceeded over an unknown object at the create pathname"
else
  if grep -q "UNKNOWN bytes\|refuses to guess" "${root}/last-run.log" \
     && [[ "$(digest_of "$(snapshot_path "${root}")")" == "${existing}" ]]; then
    pass "recovery classifies an unknown object at the create pathname as UNKNOWN, refuses, and never deletes it"
  else
    fail "unknown create-pathname object mishandled in recovery: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 5c. A directory at the create pathname is not a file with unexpected bytes;
# it must be classified UNKNOWN rather than digested into nothing.
root="${WORK}/new-directory"; build_fixture "${root}"
rm -f "$(snapshot_path "${root}")"
mkdir -p "$(snapshot_path "${root}")"
if run_installer "${root}" "" --install; then
  fail "an installation started over a directory at the create pathname"
else
  if [[ -d "$(snapshot_path "${root}")" ]]; then
    pass "a directory at the create pathname is refused and left in place"
  else
    fail "a directory at the create pathname was removed"
  fi
fi

# 5d. The create target is correctly Generation 6 but the journal is
# inconsistent with it (it records nothing). Classification comes from bytes,
# so with the rest of the prepared material intact this recovers FORWARD.
root="${WORK}/new-journal-mismatch"; build_fixture "${root}"
stage_interrupted "${root}" 1 keep
# The journal claims nothing was published; the filesystem says snapshot.py was.
sed -i '/^progress:/d' "${root}/root/kyri-gen6-transaction/journal"
if run_installer "${root}" "" --install; then
  if [[ "$(census "${root}")" == "GEN5=0 GEN6=6 UNKNOWN=0" \
     && "$(library_count "${root}")" -eq 44 ]]; then
    pass "a correct Generation-6 create target with an inconsistent journal is classified from bytes and recovers forward"
  else
    fail "journal-mismatch recovery ended at $(census "${root}")"
  fi
else
  fail "journal-mismatch recovery failed: $(tail -8 "${root}/last-run.log")"
fi

# 5e. The create target is correctly Generation 6, the prepared material is
# gone, so recovery must roll BACK -- which means REMOVING it.
root="${WORK}/new-rollback-removes"; build_fixture "${root}"
stage_interrupted "${root}" 1 drop
run_installer "${root}" "" --install && status=0 || status=$?
if [[ "${status}" -ne 0 && ! -e "$(snapshot_path "${root}")" \
   && "$(census "${root}")" == "GEN5=6 GEN6=0 UNKNOWN=0" \
   && "$(library_count "${root}")" -eq 43 ]]; then
  pass "rollback REMOVES the created object it published and returns 43 objects"
else
  fail "rollback did not remove the created object: $(census "${root}")"
fi

# 5f. The create target was published and then MODIFIED. Rollback must refuse
# to delete it: those bytes are no longer the ones this transaction installed,
# and deleting somebody else's file to tidy up a failed install is worse than
# the failed install.
root="${WORK}/new-modified-rollback"; build_fixture "${root}"
stage_interrupted "${root}" 2 drop
chmod u+w "$(snapshot_path "${root}")"
printf '# modified after publication\n' >> "$(snapshot_path "${root}")"
modified="$(digest_of "$(snapshot_path "${root}")")"
run_installer "${root}" "" --install && status=0 || status=$?
if [[ "${status}" -ne 0 ]] \
   && [[ -f "$(snapshot_path "${root}")" ]] \
   && [[ "$(digest_of "$(snapshot_path "${root}")")" == "${modified}" ]] \
   && grep -q "UNKNOWN bytes\|refuses to guess\|NOT removing it" "${root}/last-run.log"; then
  pass "a modified create target is never deleted by rollback; it fails closed for operator disposition"
else
  fail "a modified create target was mishandled: status ${status}, present $( [[ -e "$(snapshot_path "${root}")" ]] && printf yes || printf no)"
fi

# 5g. The create target was published with the right bytes but the wrong mode.
# Same rule: it is not what this transaction installed, so it is not removed.
root="${WORK}/new-mode-rollback"; build_fixture "${root}"
stage_interrupted "${root}" 2 drop
chmod 0644 "$(snapshot_path "${root}")"
run_installer "${root}" "" --install && status=0 || status=$?
if [[ "${status}" -ne 0 && -f "$(snapshot_path "${root}")" ]] \
   && grep -q "NOT removing it\|ROLLBACK INCOMPLETE\|mixed state" "${root}/last-run.log"; then
  pass "a create target with the wrong mode is not removed by rollback"
else
  fail "a create target with the wrong mode was mishandled: status ${status}"
fi

# ===========================================================================
# 6. UNKNOWN bytes and drift must fail closed
# ===========================================================================
root="${WORK}/unknown"; build_fixture "${root}"
chmod u+w "$(bind_target "${root}" '%LIB%/tools/capability/execution/worker.py')"
printf 'corrupted\n' >> "$(bind_target "${root}" '%LIB%/tools/capability/execution/worker.py')"
if run_installer "${root}" "" --install; then
  fail "an installation started over unknown bytes"
else
  if grep -q "unknown bytes\|drifted" "${root}/last-run.log"; then
    pass "unknown bytes at a target fail closed before any transaction starts"
  else
    fail "unknown bytes refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

root="${WORK}/unknown-recover"; build_fixture "${root}"
stage_interrupted "${root}" 3 keep
chmod u+w "$(bind_target "${root}" '%LIB%/tools/capability/execution/handoff.py')"
printf 'corrupted\n' >> "$(bind_target "${root}" '%LIB%/tools/capability/execution/handoff.py')"
if run_installer "${root}" "" --install; then
  fail "recovery proceeded over unknown bytes"
else
  if grep -q "UNKNOWN bytes\|refuses to guess" "${root}/last-run.log"; then
    pass "recovery over unknown bytes fails closed for operator disposition"
  else
    fail "recovery refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

root="${WORK}/drift"; build_fixture "${root}"
chmod u+w "${root}/usr/lib/kyri/python/tools/capability/execution/state.py"
printf '# drift\n' >> "${root}/usr/lib/kyri/python/tools/capability/execution/state.py"
if run_installer "${root}" "" --install; then
  fail "installation proceeded over a drifted unchanged runtime object"
else
  if grep -q "drifted" "${root}/last-run.log"; then
    pass "drift in an unchanged runtime object stops the transaction"
  else
    fail "drift refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# An extra library object nothing recorded is exactly what a stray snapshot.py
# would look like, and a count check alone would call it "44, close enough".
root="${WORK}/unrecorded"; build_fixture "${root}"
printf '# not in the evidence\n' > "${root}/usr/lib/kyri/python/tools/capability/stray.py"
if run_installer "${root}" "" --install; then
  fail "installation proceeded with an installed object absent from the baseline"
else
  if grep -q "43 .py files, expected 43\|expected 43\|absent from the Generation-5 evidence" "${root}/last-run.log"; then
    pass "an installed object absent from the Generation-5 baseline stops the transaction"
  else
    fail "unrecorded object refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# /usr/libexec must be byte-identical: generation 6 changes no privileged
# object, and a drifted one means the generation-5 boundary is not intact.
root="${WORK}/helper-drift"; build_fixture "${root}"
chmod u+w "${root}/usr/libexec/kyri-exec-worker.py"
printf '# drift\n' >> "${root}/usr/libexec/kyri-exec-worker.py"
if run_installer "${root}" "" --install; then
  fail "installation proceeded over a drifted privileged helper"
else
  if grep -q "privileged helper drifted\|boundary is not intact" "${root}/last-run.log"; then
    pass "drift in a /usr/libexec object stops the transaction"
  else
    fail "helper drift refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# ===========================================================================
# 7. the prerequisite: eligibility, conflicts, and the installed layout
# ===========================================================================
# 7a. The live host's exact state today: fragment absent, snapshot root absent,
# the coordinator outside the group. That is ELIGIBLE, not corruption.
root="${WORK}/prereq-eligible"; build_fixture_without_prerequisite "${root}"
if run_installer "${root}" "" --verify-prerequisite; then
  if grep -q "ELIGIBLE TO PROVISION" "${root}/last-run.log"; then
    pass "an absent fragment and absent snapshot root report ELIGIBLE TO PROVISION"
  else
    fail "eligibility reported without the ELIGIBLE verdict: $(tail -6 "${root}/last-run.log")"
  fi
else
  fail "--verify-prerequisite failed on an eligible host: $(tail -10 "${root}/last-run.log")"
fi
if [[ ! -e "${root}${SNAPSHOT_PARENT_ABS}" && ! -e "${root}${TMPFILES_TARGET_ABS}" ]]; then
  pass "--verify-prerequisite created neither the snapshot root nor the fragment"
else
  fail "--verify-prerequisite provisioned something"
fi

# 7b. The coordinator in the execution group destroys the entire 0770
# guarantee, silently. It must be refused loudly instead.
root="${WORK}/prereq-coordinator-in-group"; build_fixture_without_prerequisite "${root}"
printf '%s %s\n' "${COORDINATOR}" "${EXECUTION_GROUP}" > "${root}/fixture/coordinator-groups"
if run_installer "${root}" "" --verify-prerequisite; then
  fail "eligibility was granted with the coordinator inside the execution group"
else
  if grep -q "is a member of" "${root}/last-run.log"; then
    pass "the coordinator inside the execution group is refused"
  else
    fail "group membership refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 7c. A fragment that is not the repository artifact is somebody else's policy.
root="${WORK}/prereq-fragment-conflict"; build_fixture_without_prerequisite "${root}"
mkdir -p "${root}$(dirname "${TMPFILES_TARGET_ABS}")"
printf 'd /run/kyri/execution-material 0777 root root -\n' > "${root}${TMPFILES_TARGET_ABS}"
conflicting="$(digest_of "${root}${TMPFILES_TARGET_ABS}")"
if run_installer "${root}" "" --verify-prerequisite; then
  fail "eligibility was granted over a conflicting tmpfiles fragment"
else
  if [[ "$(digest_of "${root}${TMPFILES_TARGET_ABS}")" == "${conflicting}" ]] \
     && grep -q "is not the repository artifact\|will not be overwritten\|nothing will be overwritten" "${root}/last-run.log"; then
    pass "a conflicting tmpfiles fragment is refused and left byte-for-byte alone"
  else
    fail "conflicting fragment mishandled: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 7d. A fragment that IS the repository artifact is a completed step, not a
# conflict.
root="${WORK}/prereq-fragment-exact"; build_fixture_without_prerequisite "${root}"
mkdir -p "${root}$(dirname "${TMPFILES_TARGET_ABS}")"
materialise "${GEN6_COMMIT}" "${TMPFILES_SOURCE}" "${root}${TMPFILES_TARGET_ABS}"
chmod 0644 "${root}${TMPFILES_TARGET_ABS}"
if run_installer "${root}" "" --verify-prerequisite; then
  pass "an already byte-identical fragment is acceptable"
else
  fail "an exact fragment was refused: $(tail -8 "${root}/last-run.log")"
fi

# 7e. A regular file, and then a symlink, where the snapshot root belongs.
for shape in file symlink; do
  root="${WORK}/prereq-shape-${shape}"; build_fixture_without_prerequisite "${root}"
  if [[ "${shape}" == "file" ]]; then
    printf 'not a directory\n' > "${root}${SNAPSHOT_PARENT_ABS}"
  else
    ln -s /tmp "${root}${SNAPSHOT_PARENT_ABS}"
  fi
  if run_installer "${root}" "" --verify-prerequisite; then
    fail "eligibility was granted with a ${shape} at the snapshot parent"
  else
    if grep -q "is not the ruled directory" "${root}/last-run.log"; then
      pass "a ${shape} at the snapshot parent is refused"
    else
      fail "a ${shape} at the snapshot parent was refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
    fi
  fi
done

# 7f. A snapshot root with a broader mode than 0770 is the one thing the
# design ruled out explicitly.
root="${WORK}/prereq-mode-conflict"; build_fixture "${root}"
chmod 0777 "${root}${SNAPSHOT_ROOT_ABS}"
if run_installer "${root}" "" --verify-prerequisite-installed; then
  fail "a 0777 snapshot root was accepted"
else
  if grep -q "CONFLICT mode=777" "${root}/last-run.log"; then
    pass "a snapshot root at mode 0777 is refused"
  else
    fail "a 0777 snapshot root was refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 7g. Ownership. The fixture omits the seam, so the installer applies its
# PRODUCTION expectations -- root:root and root:kyri-capability -- to a
# cschott-owned tree. That is the real comparison, exercised in the failing
# direction.
root="${WORK}/prereq-owner-conflict"; build_fixture "${root}"
rm -f "${root}/fixture/expected-ownership"
if run_installer "${root}" "" --verify-prerequisite-installed; then
  fail "a snapshot root with the wrong ownership was accepted"
else
  if grep -q "CONFLICT owner=\|expected root:root" "${root}/last-run.log"; then
    pass "a snapshot root whose ownership is not the ruled identity is refused"
  else
    fail "wrong ownership refused for the wrong reason: $(tail -8 "${root}/last-run.log")"
  fi
fi

# 7h. The provisioned layout, exactly as ruled.
root="${WORK}/prereq-installed"; build_fixture "${root}"
if run_installer "${root}" "" --verify-prerequisite-installed; then
  pass "--verify-prerequisite-installed accepts the exact provisioned layout"
else
  fail "--verify-prerequisite-installed rejected the exact layout: $(tail -10 "${root}/last-run.log")"
fi

# 7i. Before generation 6 is installed nothing has run the worker, so a child
# under the snapshot root is an object of unknown provenance.
root="${WORK}/prereq-unexpected-child"; build_fixture "${root}"
mkdir -p "${root}${SNAPSHOT_ROOT_ABS}/CINV-000001"
if run_installer "${root}" "" --verify-prerequisite-installed; then
  fail "an unexpected child under the snapshot root was accepted"
else
  if grep -q "must be empty" "${root}/last-run.log"; then
    pass "an unexpected child under the snapshot root is refused"
  else
    fail "an unexpected child was refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# 7j. The runtime transaction must not start when the prerequisite is absent,
# and --verify must say so rather than reporting the runtime ready.
root="${WORK}/prereq-missing-verify"; build_fixture_without_prerequisite "${root}"
if run_installer "${root}" "" --verify; then
  fail "--verify reported ready with the prerequisite absent"
else
  if grep -q "PREREQUISITE IS ABSENT\|prerequisite is not installed" "${root}/last-run.log"; then
    pass "--verify refuses to report ready-to-install while the prerequisite is absent"
  else
    fail "--verify refused for the wrong reason: $(tail -8 "${root}/last-run.log")"
  fi
fi

root="${WORK}/prereq-missing-install"; build_fixture_without_prerequisite "${root}"
if run_installer "${root}" "" --install; then
  fail "--install proceeded with the prerequisite absent"
else
  if [[ "$(census "${root}")" == "GEN5=6 GEN6=0 UNKNOWN=0" \
     && "$(library_count "${root}")" -eq 43 \
     && ! -e "${root}${SNAPSHOT_PARENT_ABS}" \
     && ! -e "${root}${TMPFILES_TARGET_ABS}" ]]; then
    pass "--install refuses without the prerequisite, installs nothing, and provisions nothing"
  else
    fail "--install with an absent prerequisite left ${root} at $(census "${root}")"
  fi
fi

# ===========================================================================
# 8. structural properties of the installer
# ===========================================================================
# The installer must never perform the operator's ceremony. Read-only tests
# against the source, because these are absences and an absence cannot be
# observed by running a happy path.
mutations=0
while IFS= read -r line; do
  case "${line}" in
    *'systemd-tmpfiles'*)
      # It may be NAMED in comments and in operator instructions; it must never
      # be the command being run.
      if [[ "${line}" =~ ^[[:space:]]*(sudo[[:space:]]+)?systemd-tmpfiles ]]; then
        fail "the installer executes systemd-tmpfiles: ${line}"
        mutations=$((mutations + 1))
      fi ;;
  esac
done < "${INSTALLER}"
# The patterns are grep expressions naming installer variables; they must not
# expand here, because what is being searched for is the literal source text.
# shellcheck disable=SC2016
for forbidden in 'mkdir[^\n]*SNAPSHOT_ROOT' 'mkdir[^\n]*SNAPSHOT_PARENT' 'mkdir[^\n]*RUN_ROOT' \
                 'chown[^\n]*SNAPSHOT' 'chmod[^\n]*SNAPSHOT' 'chown[^\n]*TMPFILES' \
                 'chmod[^\n]*TMPFILES' 'cp[^\n]*TMPFILES_TARGET' 'install [^\n]*TMPFILES_TARGET' \
                 '> *"\${TMPFILES_TARGET}"' 'groupadd' 'useradd' 'usermod' 'gpasswd'; do
  if grep -qE "${forbidden}" "${INSTALLER}"; then
    fail "the installer mutates the host prerequisite or identity database: ${forbidden}"
    mutations=$((mutations + 1))
  fi
done
if (( mutations == 0 )); then
  pass "the installer creates no snapshot root, installs no fragment, runs no systemd-tmpfiles, and changes no group"
fi

if grep -Eq 'kyri-exec-transition"?[[:space:]]+CINV|--fixture.*CINV|podman|kyri-exec-worker\.py[[:space:]]+CINV' "${INSTALLER}"; then
  fail "the installer contains an invocation of the transition, worker, or Podman"
else
  pass "the installer invokes no transition, worker, Podman, or ceremony"
fi

# Failure injection is unreachable without fixture mode. The exact guard,
# asserted as a conjunction rather than by the presence of the variable name: a
# production run has no --fixture, so the branch is dead.
# The unexpanded literal IS the assertion, so it must not expand.
# shellcheck disable=SC2016
if grep -qF 'if [[ -n "${FIXTURE}" && "${KYRI_GEN6_FAIL_AT:-}" == "${index}" ]]; then' "${INSTALLER}"; then
  pass "failure injection requires -n FIXTURE and the position to match"
else
  fail "the failure-injection guard is not the reviewed conjunction"
fi
if [[ "$(grep -c 'KYRI_GEN6_FAIL_AT' "${INSTALLER}")" -eq 2 ]]; then
  pass "KYRI_GEN6_FAIL_AT appears only in its documented guard and the header"
else
  fail "KYRI_GEN6_FAIL_AT appears $(grep -c 'KYRI_GEN6_FAIL_AT' "${INSTALLER}") times; expected 2"
fi

# Every mutable root, and every prerequisite path the installer reads, is
# rebound under the fixture prefix in one block with no exceptions. The
# production-path snapshot cannot see inside /root, so this is also proven
# structurally.
missing_prefix=0
for name in LIBRARY_ROOT LIBEXEC TRANSACTION_ROOT GEN5_LIBRARY_EVIDENCE \
            GEN5_HELPER_EVIDENCE GEN6_LIBRARY_EVIDENCE GEN6_HELPER_EVIDENCE \
            TMPFILES_TARGET RUN_ROOT SNAPSHOT_PARENT SNAPSHOT_ROOT; do
  if ! grep -qE "^  ${name}=\"\\\$\{FIXTURE\}\\\$\{${name}\}\"$" "${INSTALLER}"; then
    fail "installer root ${name} is not rebound under the fixture prefix"
    missing_prefix=$((missing_prefix + 1))
  fi
done
if (( missing_prefix == 0 )); then
  pass "every installer root, including the prerequisite paths, is rebound under the fixture prefix"
fi

# The fixture seams must not be reachable from a production run.
seam_leak=0
for seam in 'fixture/coordinator-groups' 'fixture/expected-ownership'; do
  while IFS= read -r line; do
    [[ "${line}" == *"${seam}"* ]] || continue
    # The unexpanded literal IS the assertion, so it must not expand.
    # shellcheck disable=SC2016
    [[ "${line}" == *'${FIXTURE}'* || "${line}" == *'#'* ]] || {
      fail "the ${seam} seam is referenced without the fixture prefix: ${line}"
      seam_leak=$((seam_leak + 1)); }
  done < "${INSTALLER}"
done
# shellcheck disable=SC2016
if grep -qF 'if [[ -n "${FIXTURE}" && -f "${FIXTURE}/fixture/coordinator-groups" ]]; then' "${INSTALLER}" \
   && grep -qF 'id -nG "${COORDINATOR}"' "${INSTALLER}"; then
  pass "the group lookup seam requires fixture mode; production keeps the real bounded lookup"
else
  fail "the group lookup seam is not gated on fixture mode"
fi
(( seam_leak == 0 )) && pass "no fixture seam is reachable without the fixture prefix"

# The clean-tree gate still fires for production runs.
# The unexpanded literals ARE the assertion, so they must not expand.
# shellcheck disable=SC2016
if grep -qF 'if [[ -z "${FIXTURE}" ]]; then' "${INSTALLER}" \
   && grep -qF 'halt "the working tree is not clean:"' "${INSTALLER}"; then
  pass "a dirty tree halts a production run and is only noted in fixture mode"
else
  fail "the clean-tree gate is not scoped to production runs"
fi
if grep -qF 'require_source_digests' "${INSTALLER}"; then
  pass "source digests are verified in every transactional mode"
else
  fail "source digest verification is missing"
fi

# Pinned-byte materialisation: the installer must install the bytes it pins,
# not whatever the working tree holds after checking a digest elsewhere.
# shellcheck disable=SC2016
if grep -qF 'git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${source}" > "${destination}"' "${INSTALLER}" \
   && grep -qF 'materialise_gen6 "${source}" "${prepared}" "${gen6}"' "${INSTALLER}"; then
  pass "prepared objects are materialised from the pinned commit, not from the working tree"
else
  fail "prepared objects are not materialised from the pinned commit"
fi
# shellcheck disable=SC2016
if sed -n '/^prepare()/,/^}/p' "${INSTALLER}" | grep -qE 'cp -p "\$\{REPOSITORY\}|cat "\$\{REPOSITORY\}'; then
  fail "PREPARE copies working-tree source into a prepared object"
else
  pass "PREPARE never copies working-tree source into a prepared object"
fi

# Ancestry alone must not be the gate: a later runtime-source edit has to fail
# the source-digest check even though the pinned commit is still an ancestor.
# shellcheck disable=SC2016
if grep -qF 'git merge-base --is-ancestor "${COMMIT}" HEAD' "${INSTALLER}" \
   && grep -qF 'halt "${source} at ${COMMIT} is ${observed}, expected ${expected}"' "${INSTALLER}"; then
  pass "ancestry is required AND every source digest is pinned exactly"
else
  fail "ancestry or source-digest pinning is missing"
fi

# The create-once publication really is create-once.
if grep -q 'os.link(prepared, target)' "${INSTALLER}" \
   && grep -q 'except FileExistsError' "${INSTALLER}"; then
  pass "the new object is published with link(2), which fails EEXIST rather than overwriting"
else
  fail "the new object is not published create-once"
fi

# The guarantee is stated honestly: transactional and crash-recoverable, not
# atomic across six pathnames.
if grep -q 'NOT an atomic six-object installation' "${INSTALLER}" \
   && grep -q 'Transactional crash-recoverable installation' "${INSTALLER}"; then
  pass "the installer claims transactional crash-recoverable installation, not atomicity"
else
  fail "the installer's stated guarantee is missing or overstated"
fi
# And it re-proves the no-live-caller premise at run time rather than quoting it.
if grep -q 'require_no_live_caller' "${INSTALLER}"; then
  pass "the no-live-caller premise is re-proved at run time"
else
  fail "the no-live-caller premise is only asserted in prose"
fi

# The installer is operator tooling: it installs neither itself nor the harness.
if sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -qE 'install-generation|tests/|run-validation|\.github|tmpfiles'; then
  fail "the install matrix carries operator tooling, test, CI, or prerequisite material"
else
  pass "the install matrix carries six runtime objects only"
fi
matrix_creates="$(sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -c '|CREATE|')"
matrix_replaces="$(sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -c '|REPLACE|')"
if [[ "${matrix_creates}" -eq 1 && "${matrix_replaces}" -eq 5 ]]; then
  pass "the transaction is exactly 5 REPLACE and 1 CREATE"
else
  fail "the transaction is ${matrix_replaces} REPLACE and ${matrix_creates} CREATE"
fi
if sed -n '/^MATRIX=(/,/^)/p' "${INSTALLER}" | grep -q 'LIBEXEC'; then
  fail "the install matrix touches /usr/libexec"
else
  pass "the install matrix touches no /usr/libexec object"
fi

# Evidence names must not collide with any accepted gate's evidence.
for reserved in kyri-gen3 kyri-gen4 kyri-gen4c kyri-gen5; do
  if grep -qE "^GEN6_(LIBRARY|HELPER)_EVIDENCE=\"[^\"]*${reserved}" "${INSTALLER}"; then
    fail "Generation-6 evidence would overwrite ${reserved} evidence"
  fi
done
pass "Generation-6 evidence uses new names and overwrites no accepted gate's evidence"

# ===========================================================================
# 9. fixture hermeticity
# ===========================================================================
# The regression the Generation-5 suite exists to prevent: a baseline taken
# from the installed tree makes the whole suite stop testing anything the day
# the next generation is installed. Proven two ways -- what the fixture
# contains, and where the code is allowed to read from.
hermetic="${WORK}/hermetic"; build_fixture "${hermetic}"
baseline_wrong=0
for row in "${ROWS[@]}"; do
  target="$(bind_target "${hermetic}" "$(field "${row}" 1)")"
  gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
  if [[ "${gen5}" == "ABSENT" ]]; then
    [[ -e "${target}" ]] && { fail "the create target exists in a generation-5 fixture"; baseline_wrong=$((baseline_wrong + 1)); }
    continue
  fi
  observed="$(digest_of "${target}")"
  if [[ "${observed}" != "${gen5}" ]]; then
    fail "fixture target is ${observed:0:12}, expected generation-5 ${gen5:0:12}"
    baseline_wrong=$((baseline_wrong + 1))
  elif [[ "${observed}" == "${gen6}" ]]; then
    fail "generation-5 and generation-6 digests collide for $(field "${row}" 0)"
    baseline_wrong=$((baseline_wrong + 1))
  fi
done
if (( baseline_wrong == 0 )); then
  pass "every fixture target holds the installer-pinned generation-5 bytes, and the create target is absent"
fi

builder="$(sed -n '/^build_fixture()/,/^}/p;/^build_prerequisite()/,/^}/p;/^materialise()/,/^}/p' "$0")"
if printf '%s' "${builder}" | grep -qE '(cp|cat|sha256sum|find|install|ln)[[:space:]]+/(usr|etc|run)/'; then
  fail "fixture construction reads an absolute /usr, /etc, or /run path"
else
  pass "fixture construction reads no absolute /usr, /etc, or /run path: not the installed tree"
fi
if printf '%s' "${builder}" | grep -q 'cat-file blob'; then
  pass "fixture bytes come from pinned git objects"
else
  fail "fixture bytes do not come from git objects"
fi
if printf '%s' "${builder}" | grep -q 'systemd-tmpfiles'; then
  fail "fixture construction runs systemd-tmpfiles"
else
  pass "fixture construction builds the prerequisite by hand; systemd-tmpfiles is never run"
fi
# Every pinned revision is read from the installer, so no revision is selectable
# from a caller, the environment, or a test input.
if grep -qE '^(GEN5|GEN6)_COMMIT="\$\(read_pin' "$0"; then
  pass "both pinned commits are read from the installer, not restated here"
else
  fail "a pinned commit is restated in the harness and could drift from the installer"
fi
# Checked against the ASSIGNMENTS only, so this assertion cannot match itself:
# every one must be the read_pin form, with no default expansion and no
# environment override.
if grep -nE '^(GEN5|GEN6)_COMMIT=' "$0" \
   | grep -qvE '^[0-9]+:GEN(5_COMMIT="\$\(read_pin GEN5_COMMIT\)"|6_COMMIT="\$\(read_pin COMMIT\)")$'; then
  fail "a pinned commit is caller- or environment-selectable"
else
  pass "no pinned commit is caller- or environment-selectable"
fi

# Whatever the host currently runs, the fixture is generation 5. Reported, not
# asserted: the suite must not care which generation is installed.
live_state="unreadable"
if [[ -r /usr/lib/kyri/python/tools/capability/execution/worker.py ]]; then
  live_digest="$(digest_of /usr/lib/kyri/python/tools/capability/execution/worker.py)"
  for row in "${ROWS[@]}"; do
    [[ "$(field "${row}" 0)" == "tools/capability/execution/worker.py" ]] || continue
    if   [[ "${live_digest}" == "$(field "${row}" 5)" ]]; then live_state="generation 6"
    elif [[ "${live_digest}" == "$(field "${row}" 4)" ]]; then live_state="generation 5"
    else live_state="an unrecognised generation"; fi
  done
fi
printf 'note: the installed tree is %s; the fixture is generation 5 regardless\n' "${live_state}"

# ===========================================================================
# 10. registration
# ===========================================================================
name="tests/test-capability-execution-generation6-installer.sh"
if grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the suite runs in local validation and in CI"
else
  fail "the suite is not registered in local validation and CI"
fi
if grep -qE '^ *fetch-depth: 0$' "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "CI still checks out full history: the pinned fixture baseline is reachable"
else
  fail "CI no longer checks out full history"
fi
if grep -q 'install-generation-6.sh' "${REPOSITORY}/provisioning/execution/README.md"; then
  pass "the runbook documents the Generation-6 installer"
else
  fail "the runbook does not document the Generation-6 installer"
fi

# ===========================================================================
# 11. nothing outside the fixtures was touched
# ===========================================================================
PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated: installed tree, entrypoints, evidence, sudoers, /etc/tmpfiles.d, /run/kyri, /data, /var/lib/kyri"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation-6 installer transaction tests passed.\n'
else
  printf 'Generation-6 installer transaction tests FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
