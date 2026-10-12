#!/usr/bin/env bash
set -Eeuo pipefail

# Transactional, crash-recoverable Generation-5 installation for ENG-0005
# Pass 3B-i + 3B-ii.
#
# GENERATED, NOT EXECUTED. Nothing has run this script against the live host.
#
# WHAT THIS IS NOT
# ================
# It is NOT an atomic seven-object installation, and it does not claim to be.
# Linux offers atomic replacement of ONE pathname (rename(2) on one filesystem)
# and no primitive that makes seven independent pathnames become visible
# together. During COMMIT there is a window -- microseconds, but real -- in
# which some targets are Generation 5 and others are still Generation 4. True
# all-or-nothing visibility would require a different runtime layout: a
# versioned generation directory plus a single atomic pointer swap, with the
# entrypoints resolving through the pointer. That is a runtime-layout change to
# a privilege boundary, not an installer change, and it is out of scope here.
#
# WHAT THIS IS
# ============
# Transactional crash-recoverable installation:
#
#   PREPARE  -> every new object staged beside its target, on the target's own
#               filesystem, with final bytes/owner/mode, fsynced; every current
#               Generation-4 object copied aside the same way
#   JOURNAL  -> durable root-only record of intent, pinned digests, and
#               per-target progress, fsynced before each irreversible step
#   COMMIT   -> one rename(2) per target, directory fsynced, bytes/owner/mode
#               verified immediately, journal updated durably
#   ROLLBACK -> on any commit-phase failure, every already-replaced target is
#               restored from its retained Generation-4 copy and re-verified
#   RECOVER  -> a rerun over an existing journal inspects ACTUAL bytes and
#               drives the host deterministically to one complete generation
#
# Each individual pathname replacement IS atomic. The SET is crash-recoverable
# and never left in a state this script will accept as a generation.
#
# GATES: installs seven files and nothing else. No sudoers, no authority state,
# no image, no CIMP/CGEN record, no transition, no worker, no Podman.
#
# Usage (all modes require root except where noted):
#   install-generation-5.sh --verify           read-only: is this a valid G4
#                                              host and is the G5 transaction
#                                              ready?  Exits 0 on the accepted
#                                              Generation-4 host.
#   install-generation-5.sh --install          transactional install, or
#                                              recovery if a journal exists
#   install-generation-5.sh --verify-installed read-only: is the complete
#                                              Generation-5 set installed?
#   install-generation-5.sh --recover          recovery only; never starts a
#                                              new transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host. Owner
#                   enforcement is relaxed (a fixture is not root-owned); mode,
#                   digest, journal, commit, rollback and recovery logic are
#                   the production paths. KYRI_GEN5_FAIL_AT is honoured ONLY
#                   with --fixture, so no production run can inject a failure.

COMMIT="cfb0edd31b3589f12b6ba583ebfa48bb64e89519"
BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen5-transaction"
GEN4_LIBRARY_EVIDENCE="/root/kyri-gen4-library-digests.txt"
GEN4_HELPER_EVIDENCE="/root/kyri-gen4-helper-digests.txt"
GEN5_LIBRARY_EVIDENCE="/root/kyri-gen5-library-digests.txt"
GEN5_HELPER_EVIDENCE="/root/kyri-gen5-helper-digests.txt"

EXPECTED_LIBRARY_FILES=43

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
  GEN4_LIBRARY_EVIDENCE="${FIXTURE}${GEN4_LIBRARY_EVIDENCE}"
  GEN4_HELPER_EVIDENCE="${FIXTURE}${GEN4_HELPER_EVIDENCE}"
  GEN5_LIBRARY_EVIDENCE="${FIXTURE}${GEN5_LIBRARY_EVIDENCE}"
  GEN5_HELPER_EVIDENCE="${FIXTURE}${GEN5_HELPER_EVIDENCE}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen5.new"
BACKUP_SUFFIX=".kyri-gen4.old"

FAILURES=0
# The terminal outcome of a commit or recovery: COMMITTED or ROLLED_BACK.
# Without this a successful rollback fell through to the Generation-5
# verification and reported the correct result as seven digest failures.
OUTCOME=""
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the seven generation-5 objects, pinned both ways ----------------------
#
# source | target | mode | gen4-sha256 | gen5-sha256
#
# Both digests are pinned because recovery must classify what is actually on
# disk, and "not Generation 5" is not the same statement as "Generation 4".
MATRIX=(
"tools/capability/execution/handoff.py|${LIBRARY_ROOT}/tools/capability/execution/handoff.py|0444|b90e9dfc401d0866d027dc4b74c5378a7772364b55707c639aa32b2ab50180e7|150356edd740dd9122b6de8439fc504c885b8a59be5b3fe941a1f5f5a601df2a"
"tools/capability/execution/profile.py|${LIBRARY_ROOT}/tools/capability/execution/profile.py|0444|7b66f53fe8da7e7bea416bcc276f57bffe9e5bf8993be9f421970770021b643a|f2feb37a794b01f0ac7e224e7e147ef1267c527f1eea499532c1d674e53f4272"
"tools/capability/execution/worker.py|${LIBRARY_ROOT}/tools/capability/execution/worker.py|0444|d627399ddb7a3424353861c734b7364be66b05895f53190a3e4bbc86f08f7afa|1678302acce4de6788c09a8bf44c19e3b47a51b9097443b57bca90536c939ef8"
"provisioning/execution/kyri-exec-transition.py|${LIBRARY_ROOT}/kyri_exec_transition.py|0444|49822677f7a3db48bf6c4cbdb5c73c9b2df7bc1acc4b357cc63f02a3eb526260|6488044bc82428658ee8eecc00c0bc3f123f16f1f4ff10e1b47e730ca47e81b4"
"provisioning/execution/kyri-exec-transition-action.py|${LIBRARY_ROOT}/kyri_exec_transition_action.py|0444|788b1ad3a9cf8195bb1d3db894143fd86788176e6094c6b7d68e8b9f380084a8|bd32af5de4f3331d6fd107a7680e9725be9334eb5d4496839ab7cfea6ed238bd"
"provisioning/execution/kyri-exec-transition-entrypoint.py|${LIBEXEC}/kyri-exec-transition|0555|9baca081deebceac239dda2a86459a514d503fc8bd664ec2fd6407f684133760|bd31bcbf63423a9e9e418a28c974233ecb73d0d67f4b54837f8bbed2b8d5c932"
"provisioning/execution/kyri-exec-worker.py|${LIBEXEC}/kyri-exec-worker.py|0444|0a32adeb3bc5879024d6e67f42280ed154954af7da45db6ed6f005526b82b1af|64260190330b9d797937ef5be37c7e705ade90968a184e2c9e0d13a3e323956b"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# fsync a file and its containing directory. Durability is the whole point of
# the journal, and a rename that is not on disk is a rename that did not
# happen as far as the next boot is concerned.
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

# --- journal ---------------------------------------------------------------
journal_write() {
  local state="$1"; shift
  local temporary="${JOURNAL}.writing"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
    printf 'libexec=%s\n' "${LIBEXEC}"
    local row index=0
    for row in "${MATRIX[@]}"; do
      index=$((index + 1))
      printf 'target%d=%s|%s|%s|%s\n' "${index}" \
        "$(field "${row}" 1)" "$(field "${row}" 2)" \
        "$(field "${row}" 3)" "$(field "${row}" 4)"
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

declare -A PROGRESS=()

journal_load_progress() {
  [[ -f "${JOURNAL}" ]] || return 0
  local line key value
  while IFS= read -r line; do
    case "${line}" in
      progress:*)
        key="${line#progress:}"; value="${key#*=}"; key="${key%%=*}"
        PROGRESS["${key}"]="${value}" ;;
    esac
  done < "${JOURNAL}"
}

# --- classification --------------------------------------------------------
# GEN4 / GEN5 / UNKNOWN, decided from actual bytes and never from the journal.
classify() {
  local target="$1" gen4="$2" gen5="$3" observed
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen5}" ]]; then printf 'GEN5'
  elif [[ "${observed}" == "${gen4}" ]]; then printf 'GEN4'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen4 gen5 state
  GEN4_COUNT=0; GEN5_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
    state="$(classify "${target}" "${gen4}" "${gen5}")"
    case "${state}" in
      GEN4) GEN4_COUNT=$((GEN4_COUNT + 1)) ;;
      GEN5) GEN5_COUNT=$((GEN5_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# --- preflight -------------------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now owner residue
  head_now="$(git rev-parse HEAD)"
  # The pinned commit is where the seven objects' content was reviewed and
  # accepted. A later documentation commit does not change a single installed
  # byte, so requiring HEAD to EQUAL it would make the installer expire for a
  # reason that cannot affect what gets installed. What must hold is that the
  # reviewed content is an ancestor of what is checked out -- and then the
  # seven source digests, checked next, are the actual gate.
  git merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD ${head_now}"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  # As the repository owner: git run by root against a cschott-owned tree
  # reports ownership complaints rather than the state.
  owner="$(stat -c '%U' "${REPOSITORY}")"
  if [[ "$(id -un)" == "${owner}" ]]; then
    residue="$(git -C "${REPOSITORY}" status --porcelain --untracked-files=all)"
  else
    residue="$(runuser -u "${owner}" -- git -C "${REPOSITORY}" status --porcelain --untracked-files=all)"
  fi
  if [[ -n "${residue}" ]]; then
    # A production run installs from this checkout, so an unreviewed edit in it
    # is an unreviewed edit on the host: refuse. A fixture run installs nothing
    # into production and is driven by the repository's own test suite, which
    # legitimately runs while a developer has uncommitted work -- halting there
    # would make an unrelated edit fail the whole validator while proving
    # nothing. The source digests below remain the real gate in both modes.
    if [[ -z "${FIXTURE}" ]]; then
      halt "the working tree is not clean:"$'\n'"${residue}"
    fi
    note "the working tree is not clean; permitted in fixture mode only"
  fi
  ok "repository on ${BRANCH} at ${head_now} (contains ${COMMIT}), tree checked (as ${owner})"
}

# One generation-5 object, taken from the commit that defines it.
#
# Read from the pinned commit rather than the working tree, because they are
# not the same thing once development continues: a later pass may legitimately
# move `profile.py` or `worker.py` on to the next generation, and installing
# whatever the checkout happens to hold would put unreviewed bytes on the host
# under a generation-5 label. The digest check below then verifies what was
# actually extracted, so a rewritten history cannot substitute either.
materialise_gen5() {
  local source="$1" destination="$2" expected="$3" observed
  git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${source}" > "${destination}" \
    || halt "${source} is not readable at ${COMMIT}"
  observed="$(digest_of "${destination}")"
  [[ "${observed}" == "${expected}" ]] \
    || halt "${source} at ${COMMIT} is ${observed}, expected ${expected}"
}

require_source_digests() {
  local row source gen5 observed scratch
  scratch="$(mktemp)"
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen5="$(field "${row}" 4)"
    git -C "${REPOSITORY}" cat-file -e "${COMMIT}:${source}" 2>/dev/null \
      || { rm -f "${scratch}"; halt "${source} does not exist at ${COMMIT}"; }
    materialise_gen5 "${source}" "${scratch}" "${gen5}"
    observed="$(digest_of "${REPOSITORY}/${source}")"
    if [[ "${observed}" != "${gen5}" ]]; then
      note "the working tree has moved past Generation 5 at ${source}; installing the ${COMMIT} bytes"
    fi
  done
  rm -f "${scratch}"
  ok "all seven Generation-5 source digests match ${COMMIT}"
}

# The complete unchanged runtime surface, against the accepted Generation-4
# evidence rather than a file count. A count cannot tell a replaced module from
# an untouched one, and this is the check the adversarial review asked for.
require_gen4_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: not a provisioned host"
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES}" ]] \
    || halt "the installed library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES}"

  [[ -f "${GEN4_LIBRARY_EVIDENCE}" ]] || halt "Generation-4 evidence ${GEN4_LIBRARY_EVIDENCE} is absent"
  [[ -f "${GEN4_HELPER_EVIDENCE}" ]] || halt "Generation-4 evidence ${GEN4_HELPER_EVIDENCE} is absent"

  # Targets of this generation are expected to differ; everything else must be
  # byte-identical to the recorded baseline.
  local changed=() row
  for row in "${MATRIX[@]}"; do changed+=("$(field "${row}" 1)"); done

  local checked=0 drift=0 line recorded path observed skip target
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ "${recorded}" =~ ^[0-9a-f]{64}$ ]] || halt "unparseable Generation-4 evidence line: ${line}"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    skip=0
    for target in "${changed[@]}"; do
      [[ "${path}" == "${target}" ]] && { skip=1; break; }
    done
    (( skip == 1 )) && continue
    observed="$(digest_of "${path}")"
    if [[ "${observed}" != "${recorded}" ]]; then
      bad "unchanged runtime object drifted: ${path} is ${observed:-absent}, evidence says ${recorded}"
      drift=$((drift + 1))
    fi
    checked=$((checked + 1))
  done < "${GEN4_LIBRARY_EVIDENCE}"

  (( checked > 0 )) || halt "the Generation-4 library evidence yielded no comparable entries"
  (( drift == 0 )) || halt "${drift} unchanged runtime objects drifted from Generation 4"
  ok "unchanged runtime surface verified against Generation-4 evidence (${checked} objects)"

  # The seven themselves must currently be Generation 4, or this is not a
  # Generation-4 host and a fresh transaction must not be started.
  classify_all
  ok "target classification: GEN4=${GEN4_COUNT} GEN5=${GEN5_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
}

require_no_eighth_delta() {
  local row installed mapped=() extra=0
  for row in "${MATRIX[@]}"; do mapped+=("$(field "${row}" 1)"); done
  [[ ! -d "${LIBRARY_ROOT}/tools/provisioning" ]] \
    || bad "tools/provisioning is present in the runtime library"
  [[ ! -e "${LIBEXEC}/kyri-exec-transition-action" ]] \
    || bad "the action layer exists as a privileged executable"
  while IFS= read -r installed; do
    case "${installed}" in
      *"${PREPARED_SUFFIX}"|*"${BACKUP_SUFFIX}") extra=$((extra + 1)) ;;
    esac
  done < <(find "${LIBRARY_ROOT}" "${LIBEXEC}" -maxdepth 6 -type f 2>/dev/null || true)
  (( extra == 0 )) || note "${extra} transaction artefacts present (a prior run was interrupted)"
  ok "no eighth runtime object, no operator tooling installed"
}

require_gates_closed() {
  local sudoers="/etc/sudoers.d/kyri-exec"
  local authority="/var/lib/kyri/implementation-authority"
  local control="/var/lib/kyri/implementation-authority-control"
  [[ -n "${FIXTURE}" ]] && { sudoers="${FIXTURE}${sudoers}"; authority="${FIXTURE}${authority}"; control="${FIXTURE}${control}"; }
  [[ ! -e "${sudoers}" ]]  || bad "sudoers policy exists: G3 is not closed"
  [[ ! -e "${authority}" ]] || bad "authority root ${authority} exists"
  [[ ! -e "${control}" ]]   || bad "authority root ${control} exists"
  ok "gates unchanged: no sudoers, no authority roots"
}

# Every prepared file must land on the same filesystem as the pathname it will
# replace, or rename(2) is EXDEV and the whole model collapses into copy.
require_same_filesystem() {
  local row target prepared target_dev prepared_dev
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    target_dev="$(stat -c '%d' "$(dirname "${target}")")"
    prepared_dev="$(stat -c '%d' "$(dirname "${prepared}")")"
    [[ "${target_dev}" == "${prepared_dev}" ]] \
      || halt "prepared object for ${target} would be on device ${prepared_dev}, target is on ${target_dev}"
  done
  ok "every prepared object shares a filesystem with its target (rename is possible)"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode gen4 gen5 prepared backup observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
    prepared="${target}${PREPARED_SUFFIX}"
    backup="${target}${BACKUP_SUFFIX}"

    # The Generation-4 bytes are retained BEFORE anything is staged, because a
    # rollback with no material to roll back to is a wish rather than a plan.
    rm -f "${backup}"
    cp -p "${target}" "${backup}"
    observed="$(digest_of "${backup}")"
    [[ "${observed}" == "${gen4}" ]] \
      || halt "the retained Generation-4 copy of ${target} is ${observed}, expected ${gen4}"
    sync_path "${backup}"

    rm -f "${prepared}"
    materialise_gen5 "${source}" "${prepared}" "${gen5}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen5}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen5}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
  done
  ok "PREPARE complete: seven new objects staged, seven Generation-4 copies retained"
}

verify_prepared_set() {
  local row target gen4 gen5
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen5}" ]] \
      || halt "prepared object for ${target} does not verify"
    [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${gen4}" ]] \
      || halt "retained Generation-4 copy for ${target} does not verify"
  done
  ok "prepared set and rollback material both verify"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row source target mode gen4 gen5 prepared index=0 observed owner_now
  journal_write COMMITTING
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    gen4="$(field "${row}" 3)"; gen5="$(field "${row}" 4)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection. Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN5_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    PROGRESS["${index}"]="RENAMING"
    journal_write COMMITTING

    mv -f "${prepared}" "${target}"          # rename(2): atomic for this pathname
    sync_path "${target}"

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen5}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after replacement, expected ${gen5}"
      return 1
    fi
    if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
      PROGRESS["${index}"]="MODE_FAILED"
      journal_write COMMITTING
      rollback "target ${target} has the wrong mode after replacement"
      return 1
    fi
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}")"
      if [[ "${owner_now}" != "root:root" ]]; then
        PROGRESS["${index}"]="OWNER_FAILED"
        journal_write COMMITTING
        rollback "target ${target} is ${owner_now} after replacement"
        return 1
      fi
    fi

    PROGRESS["${index}"]="GEN5"
    journal_write COMMITTING
  done
  journal_write COMMITTED
  OUTCOME="COMMITTED"
  ok "COMMIT complete: seven pathnames replaced and verified"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target gen4 backup observed restored=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen4="$(field "${row}" 3)"
    backup="${target}${BACKUP_SUFFIX}"
    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${gen4}" ]]; then
      continue
    fi
    [[ -f "${backup}" ]] || { bad "no retained Generation-4 copy for ${target}"; continue; }
    [[ "$(digest_of "${backup}")" == "${gen4}" ]] \
      || { bad "the retained copy for ${target} does not verify; not restoring from it"; continue; }
    cp -p "${backup}" "${target}.restoring"
    mv -f "${target}.restoring" "${target}"
    sync_path "${target}"
    restored=$((restored + 1))
  done
  # Prove the whole set is Generation 4 again before claiming a rollback.
  classify_all
  if (( GEN4_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "ROLLBACK complete: all seven targets are Generation 4 again (${restored} restored)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN4=${GEN4_COUNT} GEN5=${GEN5_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed:
#
#   * every remaining target's PREPARED object verifies to its pinned
#     Generation-5 digest  -> complete FORWARD
#   * otherwise, every already-replaced target's RETAINED copy verifies to its
#     pinned Generation-4 digest -> roll BACK
#   * otherwise -> fail closed for operator disposition
#
# Forward is preferred when provable because it reaches the generation the
# operator asked for; rollback is the fallback because it is always the safer
# terminal state.
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN4=%d GEN5=%d UNKNOWN=%d\n' \
    "${state}" "${GEN4_COUNT}" "${GEN5_COUNT}" "${UNKNOWN_COUNT}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither Generation 4 nor Generation 5)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN5_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-5 set is already installed"
    return 0
  fi
  if (( GEN4_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: the complete Generation-4 set is intact; nothing was committed"
    return 0
  fi

  # Mixed. Can forward completion be proven from the prepared material?
  local row target gen5 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen5="$(field "${row}" 4)"
    [[ "$(digest_of "${target}")" == "${gen5}" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen5}" ]] || { forward=0; break; }
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
write_evidence() {
  [[ -f "${GEN4_LIBRARY_EVIDENCE}" && -f "${GEN4_HELPER_EVIDENCE}" ]] \
    || halt "Generation-4 evidence vanished during installation"
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN5_LIBRARY_EVIDENCE}.writing"
  {
    sha256sum "${LIBEXEC}/kyri-exec-transition" "${LIBEXEC}/kyri-exec-worker.py" \
              "${LIBEXEC}/kyri-exec-quota"
    printf 'commit %s\n' "${COMMIT}"
    printf 'transaction %s\n' "${TRANSACTION_ID}"
  } > "${GEN5_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN5_LIBRARY_EVIDENCE}.writing" "${GEN5_HELPER_EVIDENCE}.writing"
  sync_path "${GEN5_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN5_HELPER_EVIDENCE}.writing"
  mv -f "${GEN5_LIBRARY_EVIDENCE}.writing" "${GEN5_LIBRARY_EVIDENCE}"
  mv -f "${GEN5_HELPER_EVIDENCE}.writing" "${GEN5_HELPER_EVIDENCE}"
  sync_path "${GEN5_LIBRARY_EVIDENCE}"
  sync_path "${GEN5_HELPER_EVIDENCE}"
  ok "Generation-5 evidence written; Generation-4 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done
  ok "transaction artefacts removed"
}

# --- installed-set verification -------------------------------------------
verify_installed_set() {
  local row target mode gen5 observed owner_now
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"; gen5="$(field "${row}" 4)"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen5}" ]] || bad "${target} is ${observed:-absent}, expected ${gen5}"
    [[ "$(stat -c '%a' "${target}")" == "${mode#0}" ]] || bad "${target} has the wrong mode"
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}")"
      [[ "${owner_now}" == "root:root" ]] || bad "${target} is ${owner_now}, expected root:root"
    fi
  done
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES}" ]] \
    || bad "the library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES}"
  (( FAILURES == 0 )) && ok "the complete Generation-5 set verifies"
}

verify_contract() {
  local policy="${LIBRARY_ROOT}/kyri_exec_transition.py"
  local action="${LIBRARY_ROOT}/kyri_exec_transition_action.py"
  local worker="${LIBRARY_ROOT}/tools/capability/execution/worker.py"
  local entry="${LIBEXEC}/kyri-exec-worker.py"
  grep -q 'PROFILE_FD = 3' "${policy}" || bad "the installed policy does not fix PROFILE_FD"
  grep -q 'INHERITED_DESCRIPTORS = (0, 1, 2, 3)' "${policy}" || bad "descriptor set is not vNext"
  grep -q '"profile_digest"' "${policy}" || bad "the launch record is not vNext"
  grep -q 'oci_image_id' "${policy}" && bad "the installed policy still names an image identity"
  grep -q 'memfd_create' "${action}" || bad "the installed action creates no sealed object"
  grep -q 'F_ADD_SEALS' "${action}" || bad "the installed action applies no seals"
  grep -q 'F_SETFD' "${action}" || bad "the installed action never clears FD_CLOEXEC explicitly"
  grep -q 'tempfile' "${action}" && bad "the installed action carries a temporary-file fallback"
  grep -q 'F_GET_SEALS' "${worker}" || bad "the installed worker library checks no seals"
  grep -q 'profile_from_descriptor' "${entry}" || bad "the installed worker entrypoint reads no descriptor"
  (( FAILURES == 0 )) && ok "installed contract: FD 3, four seals, vNext record, opaque root"
}

verify_import_boundary() {
  [[ -n "${FIXTURE}" ]] && { note "import boundary not exercised in fixture mode"; return; }
  local resolved
  resolved="$(cd / && PYTHONPATH=/tmp /usr/bin/python3 -c "
import sys
sys.path.insert(0, '${LIBRARY_ROOT}')
import kyri_exec_transition as m
from tools.capability.execution import worker as w
print(m.__file__, w.__file__)
")" || { bad "the installed library is not importable"; return; }
  case "${resolved}" in
    "${LIBRARY_ROOT}"*"${LIBRARY_ROOT}"*) ok "both modules resolve inside ${LIBRARY_ROOT}" ;;
    *) bad "modules resolved outside the canonical root: ${resolved}" ;;
  esac
}

# ===========================================================================
# Modes
# ===========================================================================
TRANSACTION_ID="gen5-${COMMIT:0:12}"

printf '== Generation 5 (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  # Read-only. Proves this is a valid Generation-4 host and the transaction is
  # ready. It does NOT check the installed tree for Generation-5 content --
  # that is what --verify-installed is for, and conflating the two is what made
  # the previous script fail on the very host it was written for.
  require_repository
  require_source_digests
  require_gen4_baseline
  require_no_eighth_delta
  require_gates_closed
  require_same_filesystem
  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi
  if (( GEN4_COUNT == ${#MATRIX[@]} )); then
    ok "all seven targets are Generation 4: the host is ready for installation"
  elif (( GEN5_COUNT == ${#MATRIX[@]} )); then
    note "all seven targets are already Generation 5"
  else
    bad "mixed or unknown target state: GEN4=${GEN4_COUNT} GEN5=${GEN5_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
  fi
  ;;

--verify-installed)
  verify_installed_set
  verify_contract
  verify_import_boundary
  require_no_eighth_delta
  require_gates_closed
  ;;

--recover|--install)
  [[ "$(id -u)" -eq 0 || -n "${FIXTURE}" ]] || halt "installation requires root"
  require_repository
  require_source_digests
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  journal_load_progress

  if [[ "${state}" != "NONE" && "${state}" != "ROLLED_BACK" && "${state}" != "COMMITTED" ]]; then
    # A stale or incomplete journal never becomes a fresh installation.
    note "existing journal in state ${state}: entering recovery"
    recover "${state}" || halt "recovery did not reach a single complete generation"
  elif [[ "${MODE}" == "--recover" ]]; then
    classify_all
    if (( UNKNOWN_COUNT > 0 )); then
      halt "unknown bytes present and no transaction journal to recover from"
    fi
    ok "nothing to recover: GEN4=${GEN4_COUNT} GEN5=${GEN5_COUNT}"
  else
    require_gen4_baseline
    require_no_eighth_delta
    require_gates_closed
    require_same_filesystem
    (( UNKNOWN_COUNT == 0 )) || halt "unknown bytes at a target: refusing to start a transaction"
    if (( GEN5_COUNT == ${#MATRIX[@]} )); then
      OUTCOME="COMMITTED"
      ok "Generation 5 is already installed; nothing to do"
    else
      (( GEN4_COUNT == ${#MATRIX[@]} )) || halt "not a clean Generation-4 baseline: refusing to start"
      prepare
      verify_prepared_set
      journal_write PREPARED
      commit_targets || halt "installation failed and was rolled back; the host is Generation 4"
    fi
  fi

  # A rollback is a correct, complete outcome -- it is simply not Generation 5.
  # Verifying the Generation-5 set here would report the restored Generation-4
  # bytes as seven digest failures and bury what actually happened.
  if [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    printf '\n'
    printf 'Generation 5 was NOT installed.\n'
    printf 'The host is a complete, verified Generation 4 and no evidence was written.\n'
    printf 'The transaction journal is at %s.\n' "${JOURNAL}"
    exit 1
  fi

  # Only now, and only if everything above held.
  verify_installed_set
  verify_contract
  verify_import_boundary
  require_no_eighth_delta
  require_gates_closed
  if (( FAILURES == 0 )); then
    write_evidence
    cleanup_transaction_artifacts
    journal_write COMMITTED
  else
    bad "post-installation verification failed; evidence NOT written"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 5 %s: all checks passed.\n' "${MODE#--}"
  printf 'No image built or admitted, no CIMP/CGEN state, no sudoers policy,\n'
  printf 'and neither the transition nor the worker was invoked.\n'
else
  printf 'Generation 5 %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
