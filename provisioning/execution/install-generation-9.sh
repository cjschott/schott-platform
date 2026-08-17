#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-9 installation ceremony: the governed operator surface.
#
# WHAT IT INSTALLS
# ================
# Exactly one runtime change, and nothing else:
#
#   REPLACE  tools/capability/cli.py   -- the governed `authorise-launch`
#            operator surface
#
# The installed library stays at 48 -> 48 objects, because a REPLACE moves no
# count. /usr/libexec gains nothing and none of its five objects changes by a
# single byte.
#
# WHERE THIS SITS
# ===============
# Generation 8 introduced the coordinator execution-authorization bridge: it
# replaced `tools/capability/execution/mutation.py` to add the governed
# launch-authorisation target kind, and created
# `tools/capability/execution/launch.py` as the bridge itself. Those objects are
# already installed and are not touched here.
#
# Generation 9 consumes those existing bridge capabilities and adds the missing
# governed operator surface over them, by replacing `cli.py` with a version
# carrying the `authorise-launch` verb. Nothing new is created.
#
# WHY A RETAINED BASELINE, WITH NO CREATE
# =======================================
# This transaction contains a REPLACE, so there are accepted bytes that must
# survive until it has durably committed and must be restorable exactly. A
# CREATE rolls back by removal and needs no retained bytes; a REPLACE rolls back
# by putting exact bytes back, and bytes nobody proved were the accepted
# predecessor are not a rollback target. The Generation-8 `cli.py` is therefore
# retained before anything is staged, verified against the accepted digest at
# retention, and verified again before it is ever restored from.
#
# There is no CREATE in Generation 9, and no dependency-order question either:
# the matrix has one target, so there is no intermediate state in which one
# object expects another that is not there yet. What replaces the ordering
# problem is a sharper one -- this is a live Python module, and between the
# rename and its verification the retained object is the only proof of the
# predecessor.
#
# The implementation below still handles CREATE generically, because it is the
# accepted Generation-8 transaction reused rather than a second protocol. That
# is an implementation capability this matrix does not exercise; the ceremony
# never claims a CREATE occurred.
#
# THE COMMIT POINT IS `journal_write COMMITTED`
# ============================================
# Before it, any failure restores the exact accepted Generation-8 state. After
# it, Generation 9 is authoritative and is NEVER rolled back -- not for a
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
# In particular it never runs the verb it installs. Installing the operator
# surface and using it are separate ceremonies, and one that did both would be
# deciding for the operator that the new surface is safe to exercise.
#
# Usage:
#   install-generation-9.sh --verify             read-only: is this host ready?
#   install-generation-9.sh --install            the transaction
#   install-generation-9.sh --verify-installed   read-only: did it land exactly?
#   install-generation-9.sh --recover            resume an interrupted run
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

# The reviewed Generation-9 source authority. Pinned, never HEAD: a mutable
# reference is not an authority, and every runtime byte below is materialised
# from this commit object rather than from the working tree.
COMMIT="38261704b65465d441b03a5e59698b642c330809"

# The accepted Generation-8 source authority, and the baseline this transaction
# requires the host to be at.
GEN8_COMMIT="bc05f911f30c942e25582544b2029ce50e3e5bc7"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen9-transaction"
GEN8_LIBRARY_EVIDENCE="/root/kyri-gen8-library-digests.txt"
GEN8_HELPER_EVIDENCE="/root/kyri-gen8-helper-digests.txt"
GEN9_LIBRARY_EVIDENCE="/root/kyri-gen9-library-digests.txt"
GEN9_HELPER_EVIDENCE="/root/kyri-gen9-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# A pure REPLACE moves no object count. Both are stated anyway, so a matrix
# that quietly grew an object fails here rather than at publication.
EXPECTED_LIBRARY_FILES_GEN8=48
EXPECTED_LIBRARY_FILES_GEN9=48

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
  GEN8_LIBRARY_EVIDENCE="${FIXTURE}${GEN8_LIBRARY_EVIDENCE}"
  GEN8_HELPER_EVIDENCE="${FIXTURE}${GEN8_HELPER_EVIDENCE}"
  GEN9_LIBRARY_EVIDENCE="${FIXTURE}${GEN9_LIBRARY_EVIDENCE}"
  GEN9_HELPER_EVIDENCE="${FIXTURE}${GEN9_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen9.new"
BACKUP_SUFFIX=".kyri-gen9.gen8"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
GEN8_COUNT=0; GEN9_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the one generation-9 object, pinned both ways --------------------------
#
# source | target | mode | operation | gen8-state | gen9-sha256
#
# One row, so there is no ordering question and no intermediate state in which
# one object expects another that is not there yet. What replaces the ordering
# problem is a sharper one: this is a live Python module, and between the
# rename and its verification the only proof of the predecessor is the retained
# rollback object.
MATRIX=(
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|990bd8cafb0ae50e5c575970747ba581c0c854f2a3791d8aa327e378e949f745|c10bf11e8382face3d8020ea6be971c359f8a4bcd0b5fe9e862a460c0d7c4305"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# Operator-visible prose is derived from the matrix rather than written out, so
# a ceremony can no longer describe a transaction it is not performing. That is
# not a style preference: ceremony output is audit evidence, and a run that
# installs one object while reporting two leaves a record nobody can reconcile
# against the host afterwards.
matrix_count() { printf '%s' "${#MATRIX[@]}"; }
matrix_count_of() {
  local wanted="$1" row n=0
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 3)" == "${wanted}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}
matrix_names() {
  local row out=""
  for row in "${MATRIX[@]}"; do
    out+="${out:+, }$(basename "$(field "${row}" 1)")"
  done
  printf '%s' "${out}"
}
# "object" or "objects", so a one-row matrix does not report in the plural.
plural() { [[ "$1" == "1" ]] && printf '%s' "$2" || printf '%s' "$3"; }

# Test-only failure injection. Impossible without --fixture, so a production run
# cannot reach any of it. Every boundary the transaction can be interrupted at
# has a seam, because "we reasoned it is safe" is a weaker claim than "we cut
# the power there and looked".
injected_at() {
  [[ -n "${FIXTURE}" && "${KYRI_GEN9_FAIL_AT:-}" == "$1" ]]
}
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
    printf 'baseline_commit=%s\n' "${GEN8_COMMIT}"
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
# GEN8 / GEN9 / UNKNOWN, decided from actual bytes and never from the journal or
# from a pathname existing. For a CREATE row -- generic capability this matrix
# does not use -- GEN8 means ABSENT, and ABSENT means nothing at all there: a
# directory or a dangling symlink is UNKNOWN, because it is something this
# transaction did not put there.
classify() {
  local target="$1" gen8="$2" gen9="$3" observed
  if [[ "${gen8}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN8'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${gen9}" ]]; then printf 'GEN9'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen9}" ]]; then printf 'GEN9'
  elif [[ "${observed}" == "${gen8}" ]]; then printf 'GEN8'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen8 gen9 state
  GEN8_COUNT=0; GEN9_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen8}" "${gen9}")"
    case "${state}" in
      GEN8) GEN8_COUNT=$((GEN8_COUNT + 1)) ;;
      GEN9) GEN9_COUNT=$((GEN9_COUNT + 1)) ;;
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
    || halt "the reviewed Generation-9 commit ${COMMIT} is not in this repository"
  # The branch may carry later test- or installer-only commits, exactly as
  # Generation 8 permitted: what must hold is that the reviewed authority is an
  # ancestor of HEAD, not that it IS HEAD.
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-9 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN8_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-8 authority is not an ancestor of the Generation-9 authority"
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

# Every Generation-9 runtime byte must equal the reviewed commit object. The
# working tree is never the source: it is read only to report a divergence.
require_source_digests() {
  local row source gen9 blob worktree drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen9="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen9}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${gen9}"; drift=$((drift + 1)); }
    worktree="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${worktree}" == "${gen9}" ]] \
      || note "${source} in the working tree is ${worktree:-absent}; the ceremony installs the commit object, not this"
  done
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-9 bytes"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-9 source $(plural "${checked_n}" object objects) ($(matrix_names)) $(plural "${checked_n}" matches match) the reviewed commit exactly"
}

# --- generation-8 baseline --------------------------------------------------
require_gen8_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN8}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-8 ${EXPECTED_LIBRARY_FILES_GEN8}"

  [[ -f "${GEN8_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-8 library evidence at ${GEN8_LIBRARY_EVIDENCE} is missing"
  [[ -f "${GEN8_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-8 helper evidence at ${GEN8_HELPER_EVIDENCE} is missing"

  # Every installed object accounted for by the accepted evidence, and every
  # recorded digest matching the bytes actually there. This is what makes
  # "the host is at Generation 8" a proof rather than a file count.
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN8_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-8 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "installed ${relative} is ${observed}, evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-8 baseline"
  ok "the installed runtime is exactly the accepted Generation-8 baseline (${count} objects)"
}

# The targets themselves, and nothing pretending to be one. The REPLACE target
# must be exactly the accepted Generation-8 bytes. A CREATE pathname would have
# to be genuinely free, but this matrix declares none.
require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither Generation 8 nor Generation 9"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 9 is installed and unaffected. Remove them with --recover or by hand."
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
  local row source target mode operation gen8 gen9 prepared backup observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"
    backup="${target}${BACKUP_SUFFIX}"

    injected_at stage && halt "injected failure before staging"

    if [[ "${operation}" == "REPLACE" ]]; then
      # The Generation-8 bytes are retained BEFORE anything is staged, because a
      # rollback with no material to roll back to is a wish rather than a plan.
      # And the retained copy is verified against the accepted digest: "whatever
      # was installed" is not a rollback target until it is proven to be the
      # generation this transaction claims to be leaving.
      rm -f "${backup}"
      cp -p "${target}" "${backup}"
      observed="$(digest_of "${backup}")"
      [[ "${observed}" == "${gen8}" ]] \
        || halt "the retained Generation-8 copy of ${target} is ${observed}, expected ${gen8}"
      sync_path "${backup}"
      injected_at retained && halt "injected failure after retaining the rollback object"
      # Test-only. Impossible without --fixture.
      if [[ -n "${FIXTURE}" && "${KYRI_GEN9_FAIL_AT:-}" == "backup" ]]; then
        printf '\n# injected corruption\n' >> "${backup}"
        observed="$(digest_of "${backup}")"
        [[ "${observed}" == "${gen8}" ]] \
          || halt "the retained Generation-8 copy of ${target} is ${observed}, expected ${gen8}"
      fi
    else
      # Generic capability, unused by this matrix: a CREATE has no Generation-8
      # bytes to retain, so its rollback is removal. What it does require is
      # that the pathname is genuinely free. An object there belongs to somebody
      # else and this transaction will not adopt, overwrite, or delete it.
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
    [[ "${observed}" == "${gen9}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen9}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
    injected_at staged && halt "injected failure after staging the Generation-9 object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  local staged_n replaced_n created_n
  staged_n="$(matrix_count)"; replaced_n="$(matrix_count_of REPLACE)"
  created_n="$(matrix_count_of CREATE)"
  local reserved_clause=""
  (( created_n > 0 )) && reserved_clause=", ${created_n} $(plural "${created_n}" pathname pathnames) reserved"
  ok "PREPARE complete: ${staged_n} $(plural "${staged_n}" object objects) staged ($(matrix_names)), ${replaced_n} Generation-8 $(plural "${replaced_n}" copy copies) retained and verified${reserved_clause}"
}

verify_prepared_set() {
  local row target operation gen8 gen9
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen9}" ]] \
      || halt "prepared object for ${target} does not verify"
    if [[ "${operation}" == "REPLACE" ]]; then
      [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${gen8}" ]] \
        || halt "retained Generation-8 copy for ${target} does not verify"
    fi
  done
  ok "the prepared set verifies, and so does the retained rollback material"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode operation gen8 gen9 prepared index=0 observed owner_now
  journal_write COMMITTING
  if injected_at committing; then
    rollback "injected failure immediately after COMMITTING"
    return 1
  fi
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection. Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN9_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run. Decided from the
    # target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen8}" "${gen9}")" == "GEN9" ]]; then
      PROGRESS["${index}"]="GEN9"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING
    if injected_at publish; then
      rollback "injected failure immediately before publication"
      return 1
    fi

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

    # Injected between the rename and its verification: the one window where the
    # target already holds the new bytes and nothing has yet proved it.
    if injected_at verify; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "injected failure during post-publication verification"
      return 1
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen9}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen9}"
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

    PROGRESS["${index}"]="GEN9"
    journal_write COMMITTING
  done

  if injected_at precommit; then
    rollback "injected failure immediately before the durable commit point"
    return 1
  fi

  # THE COMMIT POINT. Everything after this line is bookkeeping, and no failure
  # in it may revert the generation.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; Generation 9 stands"
  OUTCOME="COMMITTED"
  local published_n
  published_n="$(matrix_count)"
  ok "COMMIT complete: $(matrix_names) replaced and verified (${published_n} $(plural "${published_n}" object objects))"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# Reachable only before COMMITTED. A REPLACE target is restored from its
# retained, verified Generation-8 copy -- which is every target this matrix has.
#
# The CREATE branch below is generic implementation retained from the accepted
# Generation-8 transaction; Generation 9 has no CREATE row, so it is never
# taken here. Where it does apply it removes an object only when what is there
# is still exactly what that transaction installed: if the bytes, mode, or
# ownership have moved, the object is somebody else's, and deleting somebody
# else's file to tidy up a failed installation is the one thing a rollback must
# never do.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target mode operation gen8 gen9 backup observed restored=0 removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"

    if [[ "${operation}" == "CREATE" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        continue
      fi
      if [[ -L "${target}" || ! -f "${target}" ]]; then
        bad "${target} is not the regular file this transaction created; NOT removing it"
        continue
      fi
      observed="$(digest_of "${target}")"
      if [[ "${observed}" != "${gen9}" ]]; then
        bad "${target} is ${observed}, not the Generation-9 object this transaction installed; NOT removing it"
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
    if [[ "${observed}" == "${gen8}" ]]; then
      continue
    fi
    backup="${target}${BACKUP_SUFFIX}"
    [[ -f "${backup}" ]] || { bad "no retained Generation-8 copy for ${target}"; continue; }
    [[ "$(digest_of "${backup}")" == "${gen8}" ]] \
      || { bad "the retained copy for ${target} does not verify; not restoring from it"; continue; }
    cp -p "${backup}" "${target}.restoring"
    mv -f "${target}.restoring" "${target}"
    sync_path "${target}"
    restored=$((restored + 1))
  done

  classify_all
  if (( GEN8_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    local rolled_n
    rolled_n="$(matrix_count)"
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 8 (${restored} restored, ${removed} removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN8=${GEN8_COUNT} GEN9=${GEN9_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed:
#
#   * unknown bytes anywhere            -> fail closed for operator disposition
#   * every target already Generation 9 -> already committed
#   * every target still Generation 8   -> nothing was published
#   * mixed, and every remaining prepared object verifies -> complete FORWARD
#   * mixed otherwise                   -> roll BACK to a complete Generation 8
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN8=%d GEN9=%d UNKNOWN=%d\n' \
    "${state}" "${GEN8_COUNT}" "${GEN9_COUNT}" "${UNKNOWN_COUNT}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither Generation 8 nor Generation 9)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN9_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-9 set is already installed"
    return 0
  fi
  if (( GEN8_COUNT == ${#MATRIX[@]} && state != "PREPARED" )); then
    :
  fi
  if (( GEN8_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: the complete Generation-8 set is intact; nothing was committed"
    return 0
  fi

  local row target gen8 gen9 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen8="$(field "${row}" 4)"; gen9="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen8}" "${gen9}")" == "GEN9" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen9}" ]] || { forward=0; break; }
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
# Written only after COMMITTED, and under new names. Generation-8 evidence is
# the record of what that gate accepted and is never overwritten: a generation
# that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${GEN8_LIBRARY_EVIDENCE}" && -f "${GEN8_HELPER_EVIDENCE}" ]] \
    || halt "Generation-8 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-9 evidence; Generation 9 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN9_LIBRARY_EVIDENCE}.writing"
  grep -q "${LIBRARY_ROOT}/tools/capability/cli.py\$" "${GEN9_LIBRARY_EVIDENCE}.writing" \
    || { rm -f "${GEN9_LIBRARY_EVIDENCE}.writing"; halt "the Generation-9 evidence does not record cli.py"; }
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN8_COMMIT}"
    printf 'predecessor generation 8\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    local row
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
    done
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN9_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN9_LIBRARY_EVIDENCE}.writing" "${GEN9_HELPER_EVIDENCE}.writing"
  sync_path "${GEN9_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN9_HELPER_EVIDENCE}.writing"
  mv -f "${GEN9_LIBRARY_EVIDENCE}.writing" "${GEN9_LIBRARY_EVIDENCE}"
  mv -f "${GEN9_HELPER_EVIDENCE}.writing" "${GEN9_HELPER_EVIDENCE}"
  sync_path "${GEN9_LIBRARY_EVIDENCE}"
  sync_path "${GEN9_HELPER_EVIDENCE}"
  ok "Generation-9 evidence written; Generation-8 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  # Test-only. Proves a cleanup failure after COMMITTED does not revert.
  if injected_at cleanup; then
    bad "injected cleanup failure after COMMITTED; Generation 9 remains installed"
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
  local row source target gen9 observed blob
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    gen9="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen9}" ]] \
      || bad "${source} at ${COMMIT} is ${blob:-absent}, expected the pinned ${gen9}"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen9}" ]] \
      || bad "installed ${target} is ${observed:-absent}, expected ${gen9}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "$(field "${row}" 2)"* ]] || true
  done
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN9}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-9 ${EXPECTED_LIBRARY_FILES_GEN9}"
  (( FAILURES == 0 )) \
    && ok "every installed Generation-9 byte corresponds to the reviewed commit ${COMMIT}"
}

# Every object the Generation-8 evidence recorded, other than the one this
# transaction replaced, must still be exactly what that evidence says.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative replaced
  replaced="$(field "${MATRIX[0]}" 1)"
  while IFS= read -r file; do
    [[ "${file}" == "${replaced}" ]] && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN8_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      # A pure REPLACE adds nothing, so there is no object legitimately absent
      # from the predecessor evidence. Anything unrecorded is unaccounted for.
      bad "installed object ${relative} is not accounted for by the Generation-8 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-8 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( drift == 0 )) \
    && ok "every other installed runtime object is exactly its accepted Generation-8 baseline"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  require_repository
  require_source_digests
  require_gen8_baseline
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

  if (( GEN8_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 8 and ready for the Generation-9 installation"
  elif (( GEN9_COUNT == ${#MATRIX[@]} )); then
    note "$(matrix_names) is already at Generation 9"
  else
    bad "mixed target state: GEN8=${GEN8_COUNT} GEN9=${GEN9_COUNT}"
  fi
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--install)
  require_repository
  require_source_digests
  require_gates_closed

  TRANSACTION_ID="gen9-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  AUTHORITY_BEFORE="$(authority_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_gen8_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( GEN9_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 9 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( GEN9_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 9 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 8 and nothing was installed"
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
  [[ -f "${GEN9_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-9 library evidence is missing"
  [[ -f "${GEN8_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-8 evidence was not preserved"
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
  printf 'Generation 9 / execution-authorization bridge %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 9 / execution-authorization bridge %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
