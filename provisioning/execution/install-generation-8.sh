#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-8 installation ceremony: the coordinator execution-authorization
# bridge.
#
# WHAT IT INSTALLS
# ================
# Exactly two objects, and nothing else:
#
#   REPLACE  tools/capability/execution/mutation.py   -- the governed
#            launch-authorisation target kind
#   CREATE   tools/capability/execution/launch.py     -- the bridge itself
#
# The installed library moves 47 -> 48 objects. /usr/libexec gains nothing and
# none of its five objects changes by a single byte.
#
# WHY THIS IS NOT GENERATION 7 AGAIN
# ==================================
# Generation 7 was five CREATEs, so its rollback was removal and there was never
# a byte to put back. Generation 8 carries a REPLACE, which means the accepted
# Generation-7 `mutation.py` must survive until this transaction has durably
# committed and must be restorable exactly. That is the whole reason this file
# follows the Generation-6 shape -- PREPARE with a retained baseline, then
# COMMIT, then and only then discard the rollback material -- rather than
# Generation 7's removal-only model.
#
# ORDER IS DEPENDENCY ORDER, AND IT MATTERS
# =========================================
# `launch.py` imports the new target kind from `mutation.py`. So mutation.py is
# published first and launch.py last, which makes the one intermediate state
# this transaction can be interrupted in -- mutation at Generation 8, launch
# absent -- a state where nothing imports anything that is not there. The
# reverse order would leave a module importing a symbol the installed
# `mutation.py` does not yet carry.
#
# THE COMMIT POINT IS `journal_write COMMITTED`
# ============================================
# Before it, any failure restores the exact accepted Generation-7 state. After
# it, Generation 8 is authoritative and is NEVER rolled back -- not for a
# failed cleanup, not for a failed evidence write, not for anything. Blurring
# that line is how a committed generation gets un-installed by a tidy-up.
#
# WHAT IT NEVER DOES
# ==================
# It writes no sudoers policy, invokes no privileged helper, executes no
# worker, contacts no container runtime, allocates no identifier, seeds no
# Trust, Fabric or Capability Runtime state, touches no quota, and never
# mutates the implementation-authority namespace. G6.1B, G6 and G7 all stay
# closed; installing bytes is not opening a gate.
#
# Usage:
#   install-generation-8.sh --verify             read-only: is this host ready?
#   install-generation-8.sh --install            the transaction
#   install-generation-8.sh --verify-installed   read-only: did it land exactly?
#   install-generation-8.sh --recover            resume an interrupted run
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

# The reviewed Generation-8 source authority. Pinned, never HEAD: a mutable
# reference is not an authority, and every runtime byte below is materialised
# from this commit object rather than from the working tree.
COMMIT="bc05f911f30c942e25582544b2029ce50e3e5bc7"

# The accepted Generation-7 source authority, and the baseline this transaction
# requires the host to be at.
GEN7_COMMIT="153066a57bd2e3e0a13840c3bdd44dd7c4ef7917"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen8-transaction"
GEN7_LIBRARY_EVIDENCE="/root/kyri-gen7-library-digests.txt"
GEN7_HELPER_EVIDENCE="/root/kyri-gen7-helper-digests.txt"
GEN8_LIBRARY_EVIDENCE="/root/kyri-gen8-library-digests.txt"
GEN8_HELPER_EVIDENCE="/root/kyri-gen8-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

EXPECTED_LIBRARY_FILES_GEN7=47
EXPECTED_LIBRARY_FILES_GEN8=48

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify|--install|--verify-installed|--recover)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify}"

if [[ -n "${FIXTURE}" ]]; then
  LIBRARY_ROOT="${FIXTURE}${LIBRARY_ROOT}"
  LIBEXEC="${FIXTURE}${LIBEXEC}"
  TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"
  GEN7_LIBRARY_EVIDENCE="${FIXTURE}${GEN7_LIBRARY_EVIDENCE}"
  GEN7_HELPER_EVIDENCE="${FIXTURE}${GEN7_HELPER_EVIDENCE}"
  GEN8_LIBRARY_EVIDENCE="${FIXTURE}${GEN8_LIBRARY_EVIDENCE}"
  GEN8_HELPER_EVIDENCE="${FIXTURE}${GEN8_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen8.new"
BACKUP_SUFFIX=".kyri-gen8.gen7"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
GEN7_COUNT=0; GEN8_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the two generation-8 objects, pinned both ways -------------------------
#
# source | target | mode | operation | gen7-state | gen8-sha256
#
# mutation.py FIRST because launch.py imports the target kind it adds; launch.py
# LAST because it is the object that has nothing depending on it. The
# intermediate state is therefore always importable.
MATRIX=(
"tools/capability/execution/mutation.py|${LIBRARY_ROOT}/tools/capability/execution/mutation.py|0444|REPLACE|9a8d071f4c8f6148ab8fcf1c34007d6d26cec9f16a6bbac539ff3a3fda3a2552|94500b6aa0480d8413bedd96ce59a56378b4c0450b40b9fa7dbc1779c325a9cd"
"tools/capability/execution/launch.py|${LIBRARY_ROOT}/tools/capability/execution/launch.py|0444|CREATE|ABSENT|ca606a942494cbf789e63c0a63621a9878d93b0bbfb2388ef6b6a1bba3dd8d0f"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# git never runs as root inside the coordinator's repository: it executes hooks,
# pagers, aliases and filters from configuration a coordinator can write, so
# root only ever sees bytes on the far side of a pipe. Taken from the G5
# ceremony and kept.
git_as_owner() {
  if [[ "$(id -un)" == "${REPO_OWNER}" ]]; then
    /usr/bin/git -C "${REPOSITORY}" "$@"
  else
    /usr/sbin/runuser -u "${REPO_OWNER}" -- /usr/bin/git -C "${REPOSITORY}" "$@"
  fi
}

# fsync a file and its containing directory. A publication that is not on disk
# is a publication that did not happen as far as the next boot is concerned.
sync_path() { python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
if os.path.isfile(path):
    fd = os.open(path, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)
parent = os.open(os.path.dirname(os.path.abspath(path)), os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(parent)
finally: os.close(parent)
PY
}

# link(2): atomic, and EEXIST rather than a silent overwrite.
create_once() { python3 - "$1" "$2" <<'PY'
import os, sys
try:
    os.link(sys.argv[1], sys.argv[2])
except FileExistsError:
    sys.exit(1)
sys.exit(0)
PY
}

# --- journal ---------------------------------------------------------------
#
# States: NONE -> PREPARED -> COMMITTING -> COMMITTED, with ROLLING_BACK and
# ROLLED_BACK as the terminal failure path. Every irreversible step is preceded
# by a durable write, so recovery reads a fact rather than inferring one.
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN7_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
    local row index=0
    for row in "${MATRIX[@]}"; do
      index=$((index + 1))
      printf 'target%d=%s|%s|%s|%s\n' "${index}" \
        "$(field "${row}" 1)" "$(field "${row}" 3)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
    done
    local key
    for key in "${!PROGRESS[@]}"; do
      printf 'progress:%s=%s\n' "${key}" "${PROGRESS[${key}]}"
    done
  } > "${temporary}"
  sync_path "${temporary}"
  mv -f "${temporary}" "${JOURNAL}"
  sync_path "${JOURNAL}"
}

journal_state() {
  [[ -f "${JOURNAL}" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${JOURNAL}" | tail -1
}

journal_transaction() {
  [[ -f "${JOURNAL}" ]] || return 0
  sed -n 's/^transaction=//p' "${JOURNAL}" | tail -1
}

# --- classification --------------------------------------------------------
#
# GEN7 / GEN8 / UNKNOWN, decided from actual bytes and never from the journal or
# from a pathname existing. For the CREATE target GEN7 means ABSENT, and ABSENT
# means nothing at all there -- a directory or a dangling symlink is UNKNOWN,
# because it is something this transaction did not put there.
classify() {
  local target="$1" gen7="$2" gen8="$3" observed
  if [[ "${gen7}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN7'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${gen8}" ]]; then printf 'GEN8'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen8}" ]]; then printf 'GEN8'
  elif [[ "${observed}" == "${gen7}" ]]; then printf 'GEN7'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen7 gen8 state
  GEN7_COUNT=0; GEN8_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen7}" "${gen8}")"
    case "${state}" in
      GEN7) GEN7_COUNT=$((GEN7_COUNT + 1)) ;;
      GEN8) GEN8_COUNT=$((GEN8_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)" \
    || halt "the repository at ${REPOSITORY} is not readable as ${REPO_OWNER}"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed Generation-8 commit ${COMMIT} is not in this repository"
  # The branch may carry later test- or installer-only commits, exactly as
  # Generation 7 permitted: what must hold is that the reviewed authority is an
  # ancestor of HEAD, not that it IS HEAD.
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-8 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN7_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-7 authority is not an ancestor of the Generation-8 authority"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "this is not the ${BRANCH} branch"
  residue="$(git_as_owner status --porcelain --untracked-files=all)"
  if [[ -n "${residue}" ]]; then
    if [[ -n "${FIXTURE}" ]]; then
      note "the working tree is not clean; permitted in fixture mode only"
    else
      halt "the working tree is not clean; a ceremony runs from reviewed bytes only"
    fi
  fi
  ok "repository at ${BRANCH}, reviewed authority ${COMMIT} present and an ancestor of HEAD"
}

# Every Generation-8 runtime byte must equal the reviewed commit object. The
# working tree is never the source: it is read only to report a divergence.
require_source_digests() {
  local row source gen8 blob worktree drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen8="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen8}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${gen8}"; drift=$((drift + 1)); }
    worktree="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${worktree}" == "${gen8}" ]] \
      || note "${source} in the working tree is ${worktree:-absent}; the ceremony installs the commit object, not this"
  done
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-8 bytes"
  ok "both Generation-8 source objects match the reviewed commit exactly"
}

# --- generation-7 baseline --------------------------------------------------
require_gen7_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN7}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-7 ${EXPECTED_LIBRARY_FILES_GEN7}"

  [[ -f "${GEN7_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-7 library evidence at ${GEN7_LIBRARY_EVIDENCE} is missing"
  [[ -f "${GEN7_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-7 helper evidence at ${GEN7_HELPER_EVIDENCE} is missing"

  # Every installed object accounted for by the accepted evidence, and every
  # recorded digest matching the bytes actually there. This is what makes
  # "the host is at Generation 7" a proof rather than a file count.
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN7_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-7 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "installed ${relative} is ${observed}, evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-7 baseline"
  ok "the installed runtime is exactly the accepted Generation-7 baseline (${count} objects)"
}

# The targets themselves, and nothing pretending to be one. The REPLACE target
# must be exactly the accepted Generation-7 bytes; the CREATE pathname must be
# genuinely free.
require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither Generation 7 nor Generation 8"
    done
    halt "a target is in an unruled state and requires operator disposition"
  fi
}

# No object of this transaction's own may already be lying around outside a
# transaction: a stray prepared or retained object is residue from a run nobody
# accounted for.
require_no_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    if [[ -e "${target}${PREPARED_SUFFIX}" ]]; then
      bad "residue at ${target}${PREPARED_SUFFIX}"; extra=$((extra + 1))
    fi
    if [[ -e "${target}${BACKUP_SUFFIX}" ]]; then
      bad "residue at ${target}${BACKUP_SUFFIX}"; extra=$((extra + 1))
    fi
  done
  (( extra == 0 )) || halt "transaction residue exists; resolve it before installing"
  ok "no transaction residue at any target pathname"
}

# After COMMITTED, leftover artefacts are untidy rather than disqualifying. The
# generation is installed and verified from its own bytes; a failed cleanup does
# not make that less true, and reporting it as a verification failure would
# invite exactly the reflex this transaction forbids -- reverting a committed
# generation to tidy up.
report_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && extra=$((extra + 1))
    [[ -e "${target}${BACKUP_SUFFIX}" ]] && extra=$((extra + 1))
  done
  if (( extra == 0 )); then
    ok "no transaction artefacts remain"
  else
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 8 is installed and unaffected. Remove them with --recover or by hand."
  fi
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: G3 has already run"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: G6.1B has already run"
  ok "neither sudoers grant exists: G3 and G6.1B stay closed"
}

require_same_filesystem() {
  local row target prepared
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    [[ "$(stat -c '%d' "$(dirname "${target}")" 2>/dev/null)" \
       == "$(stat -c '%d' "$(dirname "${prepared}")" 2>/dev/null)" ]] \
      || halt "${target} and its staging pathname are not on one filesystem"
  done
  ok "every target stages beside itself, so publication is a rename or a link"
}

authority_fingerprint() {
  local path state=''
  for path in "${AUTHORITY_ROOT}" "${CONTROL_ROOT}"; do
    if [[ -e "${path}" ]]; then
      state+="${path}:$(find "${path}" -printf '%p %s %m\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1) "
    else
      state+="${path}:absent "
    fi
  done
  printf '%s' "${state}"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode operation gen7 gen8 prepared backup observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"
    backup="${target}${BACKUP_SUFFIX}"

    if [[ "${operation}" == "REPLACE" ]]; then
      # The Generation-7 bytes are retained BEFORE anything is staged, because a
      # rollback with no material to roll back to is a wish rather than a plan.
      # And the retained copy is verified against the accepted digest: "whatever
      # was installed" is not a rollback target until it is proven to be the
      # generation this transaction claims to be leaving.
      rm -f "${backup}"
      cp -p "${target}" "${backup}"
      observed="$(digest_of "${backup}")"
      [[ "${observed}" == "${gen7}" ]] \
        || halt "the retained Generation-7 copy of ${target} is ${observed}, expected ${gen7}"
      sync_path "${backup}"
      # Test-only. Impossible without --fixture.
      if [[ -n "${FIXTURE}" && "${KYRI_GEN8_FAIL_AT:-}" == "backup" ]]; then
        printf '\n# injected corruption\n' >> "${backup}"
        observed="$(digest_of "${backup}")"
        [[ "${observed}" == "${gen7}" ]] \
          || halt "the retained Generation-7 copy of ${target} is ${observed}, expected ${gen7}"
      fi
    else
      # A CREATE has no Generation-7 bytes to retain: its rollback is removal.
      # What it does require is that the pathname is genuinely free. An object
      # here belongs to somebody else and this transaction will not adopt,
      # overwrite, or delete it.
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"
      rm -f "${backup}"
    fi

    rm -f "${prepared}"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${prepared}" \
      || halt "could not materialise ${source} from ${COMMIT}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen8}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen8}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
  done
  journal_write PREPARED
  ok "PREPARE complete: two objects staged, one Generation-7 copy retained and verified, one pathname reserved"
}

verify_prepared_set() {
  local row target operation gen7 gen8
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen8}" ]] \
      || halt "prepared object for ${target} does not verify"
    if [[ "${operation}" == "REPLACE" ]]; then
      [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${gen7}" ]] \
        || halt "retained Generation-7 copy for ${target} does not verify"
    fi
  done
  ok "prepared set and rollback material both verify"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode operation gen7 gen8 prepared index=0 observed owner_now
  journal_write COMMITTING
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection. Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN8_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run. Decided from the
    # target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen7}" "${gen8}")" == "GEN8" ]]; then
      PROGRESS["${index}"]="GEN8"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING

    if [[ "${operation}" == "CREATE" ]]; then
      if ! create_once "${prepared}" "${target}"; then
        PROGRESS["${index}"]="CREATE_FAILED"
        journal_write COMMITTING
        rollback "create-once at ${target} failed: an object appeared at a pathname this transaction reserved"
        return 1
      fi
      sync_path "${target}"
    else
      # rename(2): atomic for this pathname. The live object is never truncated,
      # never opened for writing, and never holds a partially written module --
      # readers see the old inode or the new one and nothing between.
      mv -f "${prepared}" "${target}"
      sync_path "${target}"
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen8}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen8}"
      return 1
    fi
    if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
      PROGRESS["${index}"]="MODE_FAILED"
      journal_write COMMITTING
      rollback "target ${target} has the wrong mode after publication"
      return 1
    fi
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}")"
      if [[ "${owner_now}" != "root:root" ]]; then
        PROGRESS["${index}"]="OWNER_FAILED"
        journal_write COMMITTING
        rollback "target ${target} is ${owner_now} after publication"
        return 1
      fi
    fi

    PROGRESS["${index}"]="GEN8"
    journal_write COMMITTING
  done

  # THE COMMIT POINT. Everything after this line is bookkeeping, and no failure
  # in it may revert the generation.
  journal_write COMMITTED
  OUTCOME="COMMITTED"
  ok "COMMIT complete: mutation.py replaced and launch.py created, both verified"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# Reachable only before COMMITTED. The REPLACE target is restored from its
# retained, verified Generation-7 copy; the CREATE target is REMOVED, and only
# when what is there is still exactly what this transaction installed. If the
# bytes, mode, or ownership have moved, the object is somebody else's, and
# deleting somebody else's file to tidy up a failed installation is the one
# thing a rollback must never do.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target mode operation gen7 gen8 backup observed restored=0 removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"

    if [[ "${operation}" == "CREATE" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        continue
      fi
      if [[ -L "${target}" || ! -f "${target}" ]]; then
        bad "${target} is not the regular file this transaction created; NOT removing it"
        continue
      fi
      observed="$(digest_of "${target}")"
      if [[ "${observed}" != "${gen8}" ]]; then
        bad "${target} is ${observed}, not the Generation-8 object this transaction installed; NOT removing it"
        continue
      fi
      if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
        bad "${target} has mode $(stat -c '%a' "${target}"), not ${mode#0}; NOT removing it"
        continue
      fi
      rm -f "${target}"
      sync_path "${target}"
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || { bad "${target} still exists after removal"; continue; }
      removed=$((removed + 1))
      continue
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${gen7}" ]]; then
      continue
    fi
    backup="${target}${BACKUP_SUFFIX}"
    [[ -f "${backup}" ]] || { bad "no retained Generation-7 copy for ${target}"; continue; }
    [[ "$(digest_of "${backup}")" == "${gen7}" ]] \
      || { bad "the retained copy for ${target} does not verify; not restoring from it"; continue; }
    cp -p "${backup}" "${target}.restoring"
    mv -f "${target}.restoring" "${target}"
    sync_path "${target}"
    restored=$((restored + 1))
  done

  classify_all
  if (( GEN7_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "ROLLBACK complete: both targets are Generation 7 again (${restored} restored, ${removed} removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN7=${GEN7_COUNT} GEN8=${GEN8_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed:
#
#   * unknown bytes anywhere            -> fail closed for operator disposition
#   * both targets already Generation 8 -> already committed
#   * both targets Generation 7         -> nothing was published
#   * mixed, and every remaining prepared object verifies -> complete FORWARD
#   * mixed otherwise                   -> roll BACK to a complete Generation 7
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN7=%d GEN8=%d UNKNOWN=%d\n' \
    "${state}" "${GEN7_COUNT}" "${GEN8_COUNT}" "${UNKNOWN_COUNT}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither Generation 7 nor Generation 8)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN8_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-8 set is already installed"
    return 0
  fi
  if (( GEN7_COUNT == ${#MATRIX[@]} && state != "PREPARED" )); then
    :
  fi
  if (( GEN7_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: the complete Generation-7 set is intact; nothing was committed"
    return 0
  fi

  local row target gen7 gen8 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen7="$(field "${row}" 4)"; gen8="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen7}" "${gen8}")" == "GEN8" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen8}" ]] || { forward=0; break; }
  done

  if (( forward == 1 )); then
    note "recovery direction: FORWARD (every remaining prepared object verifies)"
    commit_targets || return 1
    return 0
  fi

  note "recovery direction: ROLLBACK (prepared material is incomplete)"
  rollback "recovery could not prove forward completion"
}

# --- evidence --------------------------------------------------------------
#
# Written only after COMMITTED, and under new names. Generation-7 evidence is
# the record of what that gate accepted and is never overwritten: a generation
# that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${GEN7_LIBRARY_EVIDENCE}" && -f "${GEN7_HELPER_EVIDENCE}" ]] \
    || halt "Generation-7 evidence vanished during installation"
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN8_LIBRARY_EVIDENCE}.writing"
  grep -q "${LIBRARY_ROOT}/tools/capability/execution/launch.py\$" "${GEN8_LIBRARY_EVIDENCE}.writing" \
    || { rm -f "${GEN8_LIBRARY_EVIDENCE}.writing"; halt "the Generation-8 evidence does not record launch.py"; }
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN7_COMMIT}"
    printf 'predecessor generation 7\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    local row
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
    done
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN8_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN8_LIBRARY_EVIDENCE}.writing" "${GEN8_HELPER_EVIDENCE}.writing"
  sync_path "${GEN8_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN8_HELPER_EVIDENCE}.writing"
  mv -f "${GEN8_LIBRARY_EVIDENCE}.writing" "${GEN8_LIBRARY_EVIDENCE}"
  mv -f "${GEN8_HELPER_EVIDENCE}.writing" "${GEN8_HELPER_EVIDENCE}"
  sync_path "${GEN8_LIBRARY_EVIDENCE}"
  sync_path "${GEN8_HELPER_EVIDENCE}"
  ok "Generation-8 evidence written; Generation-7 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  # Test-only. Proves a cleanup failure after COMMITTED does not revert.
  if [[ -n "${FIXTURE}" && "${KYRI_GEN8_FAIL_AT:-}" == "cleanup" ]]; then
    bad "injected cleanup failure after COMMITTED; Generation 8 remains installed"
    return 0
  fi
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done
  ok "transaction artefacts removed"
}

# --- installed-set verification --------------------------------------------
verify_installed_set() {
  local row source target gen8 observed blob
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    gen8="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen8}" ]] \
      || bad "${source} at ${COMMIT} is ${blob:-absent}, expected the pinned ${gen8}"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen8}" ]] \
      || bad "installed ${target} is ${observed:-absent}, expected ${gen8}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "$(field "${row}" 2)"* ]] || true
  done
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN8}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-8 ${EXPECTED_LIBRARY_FILES_GEN8}"
  (( FAILURES == 0 )) \
    && ok "every installed Generation-8 byte corresponds to the reviewed commit ${COMMIT}"
}

# Every object the Generation-7 evidence recorded, other than the one this
# transaction replaced, must still be exactly what that evidence says.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative replaced
  replaced="$(field "${MATRIX[0]}" 1)"
  while IFS= read -r file; do
    [[ "${file}" == "${replaced}" ]] && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN7_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      # launch.py is the one object legitimately absent from Generation-7
      # evidence: it is this transaction's CREATE.
      [[ "${file}" == "$(field "${MATRIX[1]}" 1)" ]] && continue
      bad "installed object ${relative} is in neither the Generation-7 evidence nor this delta"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-7 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( drift == 0 )) \
    && ok "every other installed runtime object is exactly its accepted Generation-7 baseline"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  require_repository
  require_source_digests
  require_gen7_baseline
  require_target_state
  require_no_transaction_residue
  require_gates_closed
  require_same_filesystem

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  if (( GEN7_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 7 and ready for the Generation-8 installation"
  elif (( GEN8_COUNT == ${#MATRIX[@]} )); then
    note "both objects are already at Generation 8"
  else
    bad "mixed target state: GEN7=${GEN7_COUNT} GEN8=${GEN8_COUNT}"
  fi
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--install)
  require_repository
  require_source_digests
  require_gates_closed

  TRANSACTION_ID="gen8-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  AUTHORITY_BEFORE="$(authority_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_gen7_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( GEN8_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 8 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( GEN8_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 8 is already installed: nothing to do"
      exit 0
    fi
    halt "the journal says COMMITTED but the targets do not agree; operator disposition required"
  else
    note "resuming an interrupted transaction from state ${state}"
    recover "${state}" || true
  fi

  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
    verify_installed_set
    verify_unchanged_surface
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    # The host is in a correct state and the request was not carried out. Both
    # are true, and the exit status reports the second: an operator who asked
    # for an installation and got a rollback must not read success.
    bad "the transaction rolled back: the host is at Generation 7 and nothing was installed"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${AUTHORITY_BEFORE}" == "$(authority_fingerprint)" ]] \
    || bad "the implementation-authority namespace changed during installation"
  ;;

--verify-installed)
  require_repository
  verify_installed_set
  verify_unchanged_surface
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"
  [[ -f "${GEN8_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-8 library evidence is missing"
  [[ -f "${GEN7_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-7 evidence was not preserved"
  report_transaction_residue
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--recover)
  require_repository
  require_source_digests
  TRANSACTION_ID="$(journal_transaction)"
  state="$(journal_state)"
  [[ "${state}" == "NONE" ]] && halt "there is no transaction to recover"
  recover "${state}" || true
  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 8 / execution-authorization bridge %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 8 / execution-authorization bridge %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
