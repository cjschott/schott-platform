#!/usr/bin/env bash
set -Eeuo pipefail

# Transactional, crash-recoverable Generation-6 installation for ENG-0005
# Pass 4B.
#
# GENERATED, NOT EXECUTED. Nothing has run this script against the live host.
#
# WHAT THIS IS NOT
# ================
# It is NOT an atomic six-object installation, and it does not claim to be.
# Linux offers atomic replacement of ONE pathname (rename(2) on one filesystem)
# and atomic create-once of ONE pathname (link(2)), and no primitive that makes
# six independent pathnames become visible together. During COMMIT there is a
# window -- microseconds, but real -- in which some targets are Generation 6 and
# others are still Generation 5. True all-or-nothing visibility would require a
# different runtime layout: a versioned generation directory plus a single
# atomic pointer swap. That is a runtime-layout change to a privilege boundary,
# not an installer change, and it is out of scope here.
#
# WHAT THIS IS
# ============
# Transactional crash-recoverable installation:
#
#   PREPARE  -> every new object staged beside its target, on the target's own
#               filesystem, with final bytes/owner/mode, fsynced; every current
#               Generation-5 object copied aside the same way
#   JOURNAL  -> durable root-only record of intent, pinned digests, per-target
#               operation, and progress, fsynced before each irreversible step
#   COMMIT   -> one rename(2) per REPLACE target and one link(2) per CREATE
#               target, directory fsynced, bytes/owner/mode verified
#               immediately, journal updated durably
#   ROLLBACK -> on any commit-phase failure every already-replaced target is
#               restored from its retained Generation-5 copy, and every
#               already-created target is REMOVED -- but only when it still
#               carries exactly the bytes and metadata this transaction
#               installed
#   RECOVER  -> a rerun over an existing journal inspects ACTUAL bytes and
#               drives the host deterministically to one complete generation
#
# Each individual pathname operation IS atomic. The SET is crash-recoverable
# and never left in a state this script will accept as a generation.
#
# HOW GENERATION 6 DIFFERS FROM GENERATION 5
# ==========================================
#   * one runtime object is NEW (tools/capability/execution/snapshot.py), so
#     the transaction has a CREATE alongside five REPLACEs
#   * the installed library count moves 43 -> 44
#   * rollback of the new object means REMOVE, not restore -- and removing an
#     object this transaction did not install is never done
#   * /usr/libexec is untouched: the Generation-5 privileged boundary stays
#     byte-identical
#   * a host prerequisite must ALREADY be provisioned before the runtime
#     transaction may start. This script never provisions it. See below.
#
# THE HOST PREREQUISITE IS A SEPARATE, OPERATOR-DRIVEN CEREMONY
# ============================================================
# Generation-6 source materialises a worker-owned snapshot under
# /run/kyri/execution-material, which must be root-owned ancestry the
# coordinator cannot write, traverse, rename, or chmod. That root is created by
# systemd-tmpfiles from a fragment an operator installs, NOT by this script:
#
#   --verify-prerequisite            read-only: is the host eligible for the
#                                    operator to provision the snapshot root?
#   --verify-prerequisite-installed  read-only: did the operator's provisioning
#                                    produce exactly the ruled layout?
#
# Making --install create root-owned host directories as a side effect would
# hide a privilege-boundary change inside a library upgrade. It does not.
#
# GATES: installs six runtime files and nothing else. No sudoers, no authority
# state, no image, no CIMP/CGEN record, no transition, no worker, no Podman,
# and no /etc or /run mutation in any mode.
#
# Usage (all modes require root except where noted):
#   install-generation-6.sh --verify-prerequisite
#                                              read-only: eligibility for the
#                                              snapshot-root ceremony
#   install-generation-6.sh --verify-prerequisite-installed
#                                              read-only: the provisioned
#                                              snapshot root is exactly ruled
#   install-generation-6.sh --verify           read-only: is this a valid G5
#                                              host, is the prerequisite
#                                              installed, and is the G6
#                                              transaction ready?
#   install-generation-6.sh --install          transactional install, or
#                                              recovery if a journal exists
#   install-generation-6.sh --verify-installed read-only: is the complete
#                                              Generation-6 set installed?
#   install-generation-6.sh --recover          recovery only; never starts a
#                                              new transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host. Owner
#                   enforcement for runtime targets is relaxed (a fixture is
#                   not root-owned); mode, digest, journal, commit, rollback and
#                   recovery logic are the production paths.
#                   KYRI_GEN6_FAIL_AT is honoured ONLY with --fixture, so no
#                   production run can inject a failure.

# The Generation-6 source commit. Every installed byte comes from here.
COMMIT="32c3091b6457e06b4ebb86fed3e2d126cd3e7b07"
# The Generation-5 source commit. The accepted baseline this transaction starts
# from is pinned to immutable history as well as to the on-host evidence, so
# "what Generation 5 was" is never re-derived from a working tree.
GEN5_COMMIT="cfb0edd31b3589f12b6ba583ebfa48bb64e89519"
BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen6-transaction"
GEN5_LIBRARY_EVIDENCE="/root/kyri-gen5-library-digests.txt"
GEN5_HELPER_EVIDENCE="/root/kyri-gen5-helper-digests.txt"
GEN6_LIBRARY_EVIDENCE="/root/kyri-gen6-library-digests.txt"
GEN6_HELPER_EVIDENCE="/root/kyri-gen6-helper-digests.txt"

# The host prerequisite. Read in every mode, written in none.
TMPFILES_SOURCE="provisioning/execution/tmpfiles.d/kyri-execution-material.conf"
TMPFILES_TARGET="/etc/tmpfiles.d/kyri-execution-material.conf"
TMPFILES_DIGEST="10d27e19e298ebf78d9d1d18332cf9d513c5af50b1b3f27182a38a44e02a34d9"
TMPFILES_MODE="0644"
RUN_ROOT="/run"
SNAPSHOT_PARENT="/run/kyri"
SNAPSHOT_ROOT="/run/kyri/execution-material"

# The ruled runtime identity and the coordinator that must stay excluded.
EXECUTION_USER="kyri-capability"
EXECUTION_GROUP="kyri-capability"
EXECUTION_UID=999
EXECUTION_GID=987
COORDINATOR="cschott"

# Ownership expectations, named so a fixture can rebind them in one place. A
# fixture tree cannot be root-owned, and pretending otherwise would either make
# every fixture case fail or make the production comparison untestable.
EXPECTED_RUN_OWNER="root:root"
EXPECTED_PARENT_OWNER="root:root"
EXPECTED_MATERIAL_OWNER="root:${EXECUTION_GROUP}"
EXPECTED_FRAGMENT_OWNER="root:root"
EXPECTED_PARENT_MODE="755"
EXPECTED_MATERIAL_MODE="770"

EXPECTED_LIBRARY_FILES_GEN5=43
EXPECTED_LIBRARY_FILES_GEN6=44

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify|--install|--verify-installed|--recover|\
--verify-prerequisite|--verify-prerequisite-installed)
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
  GEN5_LIBRARY_EVIDENCE="${FIXTURE}${GEN5_LIBRARY_EVIDENCE}"
  GEN5_HELPER_EVIDENCE="${FIXTURE}${GEN5_HELPER_EVIDENCE}"
  GEN6_LIBRARY_EVIDENCE="${FIXTURE}${GEN6_LIBRARY_EVIDENCE}"
  GEN6_HELPER_EVIDENCE="${FIXTURE}${GEN6_HELPER_EVIDENCE}"
  TMPFILES_TARGET="${FIXTURE}${TMPFILES_TARGET}"
  RUN_ROOT="${FIXTURE}${RUN_ROOT}"
  SNAPSHOT_PARENT="${FIXTURE}${SNAPSHOT_PARENT}"
  SNAPSHOT_ROOT="${FIXTURE}${SNAPSHOT_ROOT}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen6.new"
BACKUP_SUFFIX=".kyri-gen5.old"

FAILURES=0
# The terminal outcome of a commit or recovery: COMMITTED or ROLLED_BACK. A
# successful rollback is a correct outcome and must not fall through to the
# Generation-6 verification, which would report it as six digest failures.
OUTCOME=""
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the six generation-6 objects, pinned both ways ------------------------
#
# source | target | mode | operation | gen5-sha256-or-ABSENT | gen6-sha256
#
# Both generations are pinned because recovery must classify what is actually
# on disk, and "not Generation 6" is not the same statement as "Generation 5".
# For the CREATE the Generation-5 state is the literal ABSENT: an existing
# object at that pathname is neither generation and is never overwritten.
#
# Order is dependency order, not alphabetical. snapshot.py is published first
# because worker.py imports it; worker.py is published last because it consumes
# everything above it. No caller exists at this gate, so the ordering buys
# tidiness rather than safety -- but the tidy order is also the one that would
# still be right if a caller did exist.
MATRIX=(
"tools/capability/execution/snapshot.py|${LIBRARY_ROOT}/tools/capability/execution/snapshot.py|0444|CREATE|ABSENT|d2c316c05f1f10d7bb26bb3c829978dc491e58a0adaa3c51451d3e63d58ec704"
"tools/capability/execution/types.py|${LIBRARY_ROOT}/tools/capability/execution/types.py|0444|REPLACE|dede977714f26680a7ca80d0907f39ed4061929214ac96635af8bf2eb6701364|7dc35046fafdb4e7218739cdbc86deff18ed804b2a37d66a173df58016258b5c"
"tools/capability/execution/authorisation.py|${LIBRARY_ROOT}/tools/capability/execution/authorisation.py|0444|REPLACE|191bb7b8e1553e96c27d8a29cedd5be1d30d2fdb55777fa53cf50581d58f799c|9e4e84cdcb4ed7179bb690bd277787bc6dc072d2320d19dd7a1e68f65d1d6c1e"
"tools/capability/execution/profile.py|${LIBRARY_ROOT}/tools/capability/execution/profile.py|0444|REPLACE|f2feb37a794b01f0ac7e224e7e147ef1267c527f1eea499532c1d674e53f4272|f87947fe096dc981248195a29ba18a38a30287f04091031ab59781730e2bbe97"
"tools/capability/execution/handoff.py|${LIBRARY_ROOT}/tools/capability/execution/handoff.py|0444|REPLACE|150356edd740dd9122b6de8439fc504c885b8a59be5b3fe941a1f5f5a601df2a|b557a7e6fd00ee0a63f19abb7bf7a20eddfe52fcfa2ee48f92a5bd70f08a7df7"
"tools/capability/execution/worker.py|${LIBRARY_ROOT}/tools/capability/execution/worker.py|0444|REPLACE|1678302acce4de6788c09a8bf44c19e3b47a51b9097443b57bca90536c939ef8|2e46ec066b2cd6e859d47d92e48e86269b66700dcb2be0ac17949b145a08378e"
)

# The three /usr/libexec objects. Generation 6 changes NONE of them; they are
# listed so "unchanged" is verified rather than assumed.
HELPERS=(
"${LIBEXEC}/kyri-exec-transition"
"${LIBEXEC}/kyri-exec-worker.py"
"${LIBEXEC}/kyri-exec-quota"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# fsync a file and its containing directory. Durability is the whole point of
# the journal, and a rename that is not on disk is a rename that did not happen
# as far as the next boot is concerned.
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

# Publish a prepared object at a pathname that must not already exist.
#
# rename(2) would silently overwrite, and for the NEW object "there was nothing
# there" is a property of the transaction rather than a hope: link(2) fails
# EEXIST instead of destroying whatever an operator or an earlier run left
# behind. The prepared object is unlinked afterwards, so the target ends with
# one link, its final mode and owner already set during PREPARE.
create_once() { python3 - "$1" "$2" <<'PY'
import os, sys
prepared, target = sys.argv[1], sys.argv[2]
try:
    os.link(prepared, target)
except FileExistsError:
    sys.stderr.write("target already exists: %s\n" % target)
    raise SystemExit(17)
os.unlink(prepared)
parent = os.open(os.path.dirname(os.path.abspath(target)), os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(parent)
finally: os.close(parent)
PY
}

# --- fixture-only seams ----------------------------------------------------
#
# Both are unreachable without --fixture: production takes the real lookup, and
# the real lookup is the only path a production run can execute.

# The coordinator's group memberships. The whole 0770 guarantee rests on
# cschott not being in group kyri-capability, so a fixture has to be able to
# present the failing case without touching a live group database.
coordinator_groups() {
  if [[ -n "${FIXTURE}" && -f "${FIXTURE}/fixture/coordinator-groups" ]]; then
    tr ' ' '\n' < "${FIXTURE}/fixture/coordinator-groups"
    return 0
  fi
  id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n'
}

# Ownership expectations for the prerequisite layout. A fixture cannot own
# anything as root:kyri-capability, so a fixture that wants to exercise the
# ACCEPTING path rebinds the expectations to its own identity; a fixture that
# wants to exercise the REFUSING path simply omits the file and gets the
# production expectations, which its cschott-owned tree cannot satisfy.
load_ownership_expectations() {
  local file="${FIXTURE}/fixture/expected-ownership" line key value
  [[ -n "${FIXTURE}" && -f "${file}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%=*}"; value="${line#*=}"
    case "${key}" in
      run)      EXPECTED_RUN_OWNER="${value}" ;;
      kyri)     EXPECTED_PARENT_OWNER="${value}" ;;
      material) EXPECTED_MATERIAL_OWNER="${value}" ;;
      fragment) EXPECTED_FRAGMENT_OWNER="${value}" ;;
      *) halt "unrecognised ownership expectation: ${key}" ;;
    esac
  done < "${file}"
  note "FIXTURE: ownership expectations rebound to ${EXPECTED_PARENT_OWNER} / ${EXPECTED_MATERIAL_OWNER}"
}
load_ownership_expectations

# --- journal ---------------------------------------------------------------
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN5_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
    printf 'libexec=%s\n' "${LIBEXEC}"
    local row index=0
    for row in "${MATRIX[@]}"; do
      index=$((index + 1))
      # path | operation | generation-5 expectation (or ABSENT) | generation-6
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
# GEN5 / GEN6 / UNKNOWN, decided from actual bytes and never from the journal.
#
# For the CREATE target GEN5 means ABSENT -- and ABSENT means nothing at all at
# that pathname, not "no regular file": a directory or a dangling symlink there
# is UNKNOWN, because it is something this transaction did not put there.
classify() {
  local target="$1" gen5="$2" gen6="$3" observed
  if [[ "${gen5}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN5'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${gen6}" ]]; then printf 'GEN6'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen6}" ]]; then printf 'GEN6'
  elif [[ "${observed}" == "${gen5}" ]]; then printf 'GEN5'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen5 gen6 state
  GEN5_COUNT=0; GEN6_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen5}" "${gen6}")"
    case "${state}" in
      GEN5) GEN5_COUNT=$((GEN5_COUNT + 1)) ;;
      GEN6) GEN6_COUNT=$((GEN6_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now owner residue
  head_now="$(git rev-parse HEAD)"
  # The pinned commit is where the six objects' content was reviewed and
  # accepted. A later documentation or test commit does not change a single
  # installed byte, so requiring HEAD to EQUAL it would make the installer
  # expire for a reason that cannot affect what gets installed. What must hold
  # is that the reviewed content is an ancestor of what is checked out -- and
  # then the six source digests, checked next, are the actual gate. A later
  # edit to runtime source fails there even though ancestry still passes.
  git merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD ${head_now}"
  git merge-base --is-ancestor "${GEN5_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-5 baseline ${GEN5_COMMIT} is not an ancestor of ${COMMIT}"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
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
    # legitimately runs while a developer has uncommitted work.
    if [[ -z "${FIXTURE}" ]]; then
      halt "the working tree is not clean:"$'\n'"${residue}"
    fi
    note "the working tree is not clean; permitted in fixture mode only"
  fi
  ok "repository on ${BRANCH} at ${head_now} (contains ${COMMIT}), tree checked (as ${owner})"
}

# One generation-6 object, taken from the commit that defines it.
#
# Read from the pinned commit rather than the working tree, because they are not
# the same thing once development continues: a later pass may legitimately move
# a module on to the next generation, and installing whatever the checkout
# happens to hold would put unreviewed bytes on the host under a generation-6
# label. The digest check below verifies what was actually extracted, so a
# rewritten history cannot substitute either.
materialise_gen6() {
  local source="$1" destination="$2" expected="$3" observed
  git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${source}" > "${destination}" \
    || halt "${source} is not readable at ${COMMIT}"
  observed="$(digest_of "${destination}")"
  [[ "${observed}" == "${expected}" ]] \
    || halt "${source} at ${COMMIT} is ${observed}, expected ${expected}"
}

require_source_digests() {
  local row source gen5 gen6 observed scratch
  scratch="$(mktemp)"
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    git -C "${REPOSITORY}" cat-file -e "${COMMIT}:${source}" 2>/dev/null \
      || { rm -f "${scratch}"; halt "${source} does not exist at ${COMMIT}"; }
    materialise_gen6 "${source}" "${scratch}" "${gen6}"
    # The Generation-5 side is pinned to history too, so the baseline this
    # transaction claims to start from is a fact rather than a transcription.
    if [[ "${gen5}" == "ABSENT" ]]; then
      ! git -C "${REPOSITORY}" cat-file -e "${GEN5_COMMIT}:${source}" 2>/dev/null \
        || { rm -f "${scratch}"; halt "${source} already existed at Generation 5 ${GEN5_COMMIT}: it is not new"; }
    else
      observed="$(git -C "${REPOSITORY}" cat-file blob "${GEN5_COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
      [[ "${observed}" == "${gen5}" ]] \
        || { rm -f "${scratch}"; halt "${source} at Generation 5 ${GEN5_COMMIT} is ${observed}, expected ${gen5}"; }
    fi
    observed="$(digest_of "${REPOSITORY}/${source}")"
    if [[ "${observed}" != "${gen6}" ]]; then
      note "the working tree has moved past Generation 6 at ${source}; installing the ${COMMIT} bytes"
    fi
  done
  rm -f "${scratch}"
  ok "all six Generation-6 source digests match ${COMMIT}; the five Generation-5 baselines match ${GEN5_COMMIT}"
}

# --- the tmpfiles artifact --------------------------------------------------
#
# Validated as a policy, not as a blob alone: the digest proves it is the
# reviewed file, and the structural checks below prove the reviewed file still
# says what the design ruled. Both, because a future edit that changed the
# meaning would change the digest, and an operator staring at a digest mismatch
# should be told what the file is required to contain.
require_tmpfiles_artifact() {
  local artifact="${REPOSITORY}/${TMPFILES_SOURCE}" observed
  [[ -f "${artifact}" ]] || halt "the prerequisite artifact ${TMPFILES_SOURCE} is absent"
  observed="$(digest_of "${artifact}")"
  [[ "${observed}" == "${TMPFILES_DIGEST}" ]] \
    || halt "${TMPFILES_SOURCE} is ${observed}, expected ${TMPFILES_DIGEST}"

  local directives=() line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "${line}" && "${line:0:1}" != "#" ]] || continue
    directives+=("${line}")
  done < "${artifact}"

  (( ${#directives[@]} == 2 )) \
    || halt "the prerequisite artifact carries ${#directives[@]} directives, expected exactly 2"

  local index=0 expected_type expected_path expected_mode expected_owner expected_group
  for line in "${directives[@]}"; do
    index=$((index + 1))
    # shellcheck disable=SC2206
    local fields=(${line})
    case "${index}" in
      1) expected_type="d"; expected_path="/run/kyri"
         expected_mode="0755"; expected_owner="root"; expected_group="root" ;;
      2) expected_type="d"; expected_path="/run/kyri/execution-material"
         expected_mode="0770"; expected_owner="root"; expected_group="${EXECUTION_GROUP}" ;;
      *) halt "the prerequisite artifact carries an unexpected directive ${index}" ;;
    esac
    [[ "${fields[0]}" == "${expected_type}" ]] \
      || halt "directive ${index} is type '${fields[0]}', expected '${expected_type}'"
    [[ "${fields[1]}" == "${expected_path}" ]] \
      || halt "directive ${index} names '${fields[1]}', expected '${expected_path}'"
    [[ "${fields[2]}" == "${expected_mode}" ]] \
      || halt "directive ${index} sets mode '${fields[2]}', expected '${expected_mode}'"
    [[ "${fields[3]}" == "${expected_owner}" ]] \
      || halt "directive ${index} sets owner '${fields[3]}', expected '${expected_owner}'"
    [[ "${fields[4]}" == "${expected_group}" ]] \
      || halt "directive ${index} sets group '${fields[4]}', expected '${expected_group}'"
    # Field 6 is the age. A snapshot must survive for the whole container
    # lifetime, and a timer sweeping live execution material would remove it out
    # from under a running container. Absent, or the explicit "no age" dash.
    if (( ${#fields[@]} > 5 )); then
      [[ "${#fields[@]}" -eq 6 && "${fields[5]}" == "-" ]] \
        || halt "directive ${index} carries an age or cleanup field: ${line}"
    fi
    [[ "${line}" != *"${COORDINATOR}"* ]] \
      || halt "directive ${index} names the coordinator: ${line}"
    [[ "${line}" != *"*"* && "${line}" != *"?"* ]] \
      || halt "directive ${index} carries a glob: ${line}"
    [[ "${line}" != *"/run/user"* ]] \
      || halt "directive ${index} uses a /run/user path: ${line}"
    local banned
    for banned in 0777 0775 0707 0666 0776 0757; do
      [[ "${line}" != *"${banned}"* ]] || halt "directive ${index} grants ${banned}: ${line}"
    done
  done
  ok "prerequisite artifact verified: 2 directives, ruled ownership and modes, no age, no glob"
}

# --- prerequisite eligibility ----------------------------------------------
require_execution_identity() {
  local uid gid
  uid="$(getent passwd "${EXECUTION_USER}" | cut -d: -f3)"
  gid="$(getent group "${EXECUTION_GROUP}" | cut -d: -f3)"
  [[ -n "${uid}" ]] || halt "user ${EXECUTION_USER} does not exist"
  [[ -n "${gid}" ]] || halt "group ${EXECUTION_GROUP} does not exist"
  [[ "${uid}" == "${EXECUTION_UID}" ]] \
    || halt "${EXECUTION_USER} is uid ${uid}, expected ${EXECUTION_UID}"
  [[ "${gid}" == "${EXECUTION_GID}" ]] \
    || halt "${EXECUTION_GROUP} is gid ${gid}, expected ${EXECUTION_GID}"
  ok "execution identity: ${EXECUTION_USER} uid ${uid}, ${EXECUTION_GROUP} gid ${gid}"
}

# The 0770 guarantee is exactly "the coordinator is not in this group". If it
# ever is, the snapshot root stops excluding the coordinator and Pass 4B's
# whole reason for existing evaporates -- silently.
require_coordinator_excluded() {
  if coordinator_groups | grep -qx "${EXECUTION_GROUP}"; then
    halt "${COORDINATOR} is a member of ${EXECUTION_GROUP}: 0770 would admit the coordinator"
  fi
  ok "${COORDINATOR} is not a member of ${EXECUTION_GROUP}"
}

owner_of() { stat -c '%U:%G' "$1" 2>/dev/null; }
mode_of()  { stat -c '%a' "$1" 2>/dev/null; }

require_run_root() {
  [[ -d "${RUN_ROOT}" ]] || halt "${RUN_ROOT} is not a directory"
  local owner mode
  owner="$(owner_of "${RUN_ROOT}")"; mode="$(mode_of "${RUN_ROOT}")"
  [[ "${owner}" == "${EXPECTED_RUN_OWNER}" ]] \
    || halt "${RUN_ROOT} is ${owner}, expected ${EXPECTED_RUN_OWNER}"
  # Group- or other-writable /run would let the coordinator rename the whole
  # snapshot root out from under the worker, which no mode on the root itself
  # can prevent.
  [[ "${mode:1:1}" =~ [0-5] && "${mode:2:1}" =~ [0-5] ]] \
    || halt "${RUN_ROOT} is mode ${mode}: it is group- or other-writable"
  ok "${RUN_ROOT} is ${owner} mode ${mode}: not coordinator-writable"
}

# Absent, or already exactly right. Anything else is an object this ceremony did
# not create and must not silently adopt.
classify_prerequisite_path() {
  local path="$1" expected_owner="$2" expected_mode="$3"
  if [[ -L "${path}" ]]; then printf 'CONFLICT symlink'; return; fi
  if [[ ! -e "${path}" ]]; then printf 'ABSENT'; return; fi
  if [[ ! -d "${path}" ]]; then printf 'CONFLICT not-a-directory'; return; fi
  local owner mode
  owner="$(owner_of "${path}")"; mode="$(mode_of "${path}")"
  [[ "${owner}" == "${expected_owner}" ]] || { printf 'CONFLICT owner=%s' "${owner}"; return; }
  [[ "${mode}" == "${expected_mode}" ]] || { printf 'CONFLICT mode=%s' "${mode}"; return; }
  printf 'EXACT'
}

classify_fragment() {
  if [[ -L "${TMPFILES_TARGET}" ]]; then printf 'CONFLICT symlink'; return; fi
  if [[ ! -e "${TMPFILES_TARGET}" ]]; then printf 'ABSENT'; return; fi
  if [[ ! -f "${TMPFILES_TARGET}" ]]; then printf 'CONFLICT not-a-file'; return; fi
  local observed owner mode
  observed="$(digest_of "${TMPFILES_TARGET}")"
  [[ "${observed}" == "${TMPFILES_DIGEST}" ]] || { printf 'CONFLICT digest=%s' "${observed:0:12}"; return; }
  owner="$(owner_of "${TMPFILES_TARGET}")"
  [[ "${owner}" == "${EXPECTED_FRAGMENT_OWNER}" ]] || { printf 'CONFLICT owner=%s' "${owner}"; return; }
  mode="$(mode_of "${TMPFILES_TARGET}")"
  [[ "${mode}" == "${TMPFILES_MODE#0}" ]] || { printf 'CONFLICT mode=%s' "${mode}"; return; }
  printf 'EXACT'
}

# Read-only eligibility. Nothing here creates, copies, chowns, chmods, or runs
# systemd-tmpfiles; the operator does that, after reading the output.
verify_prerequisite() {
  require_tmpfiles_artifact
  require_execution_identity
  require_coordinator_excluded
  require_run_root

  local fragment parent material
  fragment="$(classify_fragment)"
  parent="$(classify_prerequisite_path "${SNAPSHOT_PARENT}" "${EXPECTED_PARENT_OWNER}" "${EXPECTED_PARENT_MODE}")"
  material="$(classify_prerequisite_path "${SNAPSHOT_ROOT}" "${EXPECTED_MATERIAL_OWNER}" "${EXPECTED_MATERIAL_MODE}")"

  local conflict=0
  case "${fragment}" in
    ABSENT) ok "${TMPFILES_TARGET} is absent: the operator installs it" ;;
    EXACT)  ok "${TMPFILES_TARGET} is already byte-identical to the artifact" ;;
    *) bad "${TMPFILES_TARGET} exists and is not the repository artifact (${fragment})"; conflict=1 ;;
  esac
  case "${parent}" in
    ABSENT) ok "${SNAPSHOT_PARENT} is absent: systemd-tmpfiles creates it" ;;
    EXACT)  ok "${SNAPSHOT_PARENT} is already exactly ${EXPECTED_PARENT_OWNER} ${EXPECTED_PARENT_MODE}" ;;
    *) bad "${SNAPSHOT_PARENT} exists and is not the ruled directory (${parent})"; conflict=1 ;;
  esac
  case "${material}" in
    ABSENT) ok "${SNAPSHOT_ROOT} is absent: systemd-tmpfiles creates it" ;;
    EXACT)  ok "${SNAPSHOT_ROOT} is already exactly ${EXPECTED_MATERIAL_OWNER} ${EXPECTED_MATERIAL_MODE}" ;;
    *) bad "${SNAPSHOT_ROOT} exists and is not the ruled directory (${material})"; conflict=1 ;;
  esac

  if (( conflict == 1 )); then
    halt "an existing object conflicts with the ruled prerequisite layout; nothing was changed and nothing will be overwritten"
  fi

  printf '\n'
  if [[ "${fragment}" == "EXACT" && "${parent}" == "EXACT" && "${material}" == "EXACT" ]]; then
    printf 'PREREQUISITE ALREADY PROVISIONED.\n'
    printf 'Run --verify-prerequisite-installed to confirm it in full.\n'
  else
    printf 'ELIGIBLE TO PROVISION.\n'
    printf 'The operator installs the fragment and runs systemd-tmpfiles; this\n'
    printf 'script does neither. See the ceremony in provisioning/execution/README.md.\n'
  fi
}

# Read-only confirmation that the operator's provisioning produced exactly the
# ruled layout. Still mutates nothing.
verify_prerequisite_installed() {
  require_tmpfiles_artifact
  require_execution_identity
  require_coordinator_excluded
  require_run_root

  local fragment parent material
  fragment="$(classify_fragment)"
  parent="$(classify_prerequisite_path "${SNAPSHOT_PARENT}" "${EXPECTED_PARENT_OWNER}" "${EXPECTED_PARENT_MODE}")"
  material="$(classify_prerequisite_path "${SNAPSHOT_ROOT}" "${EXPECTED_MATERIAL_OWNER}" "${EXPECTED_MATERIAL_MODE}")"

  [[ "${fragment}" == "EXACT" ]] \
    || bad "${TMPFILES_TARGET}: ${fragment} (expected the byte-identical artifact, ${EXPECTED_FRAGMENT_OWNER}, ${TMPFILES_MODE})"
  [[ "${parent}" == "EXACT" ]] \
    || bad "${SNAPSHOT_PARENT}: ${parent} (expected ${EXPECTED_PARENT_OWNER} ${EXPECTED_PARENT_MODE})"
  [[ "${material}" == "EXACT" ]] \
    || bad "${SNAPSHOT_ROOT}: ${material} (expected ${EXPECTED_MATERIAL_OWNER} ${EXPECTED_MATERIAL_MODE})"

  # Ancestry, not just the leaf. A root-owned leaf under a coordinator-owned
  # parent is a leaf the coordinator can rename away.
  if command -v namei >/dev/null 2>&1; then
    printf 'ancestry (namei -l %s):\n' "${SNAPSHOT_ROOT}"
    namei -l "${SNAPSHOT_ROOT}" 2>&1 | sed 's/^/         /' || true
  fi
  local walk="${SNAPSHOT_ROOT}" owner
  while [[ "${walk}" != "/" && "${walk}" != "${FIXTURE:-/nonexistent}" && -n "${walk}" ]]; do
    walk="$(dirname "${walk}")"
    [[ "${walk}" != "/" ]] || break
    [[ -n "${FIXTURE}" && "${walk}" == "${FIXTURE}" ]] && break
    owner="$(owner_of "${walk}")"
    [[ "${owner}" == "${EXPECTED_RUN_OWNER}" ]] \
      || bad "ancestor ${walk} is ${owner}, expected ${EXPECTED_RUN_OWNER}"
  done

  # Before Generation 6 is installed nothing has run the worker, so the root
  # must be empty. A child here is an object of unknown provenance inside the
  # execution boundary.
  if [[ -d "${SNAPSHOT_ROOT}" ]]; then
    local children
    children="$(find "${SNAPSHOT_ROOT}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    if [[ "${children}" -ne 0 ]]; then
      bad "${SNAPSHOT_ROOT} holds ${children} entries; no worker has run, so it must be empty"
    else
      ok "${SNAPSHOT_ROOT} is empty: no invocation snapshot exists"
    fi
  fi

  (( FAILURES == 0 )) && ok "the prerequisite is provisioned exactly as ruled"
}

# --- generation-5 baseline --------------------------------------------------
#
# The complete accepted Generation-5 baseline, against the accepted evidence
# rather than a file count. A count cannot tell a replaced module from an
# untouched one, and it certainly cannot notice a module that was swapped for
# another of the same name.
require_gen5_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: not a provisioned host"
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES_GEN5}" ]] \
    || halt "the installed library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES_GEN5}"

  [[ -f "${GEN5_LIBRARY_EVIDENCE}" ]] || halt "Generation-5 evidence ${GEN5_LIBRARY_EVIDENCE} is absent"
  [[ -f "${GEN5_HELPER_EVIDENCE}" ]] || halt "Generation-5 evidence ${GEN5_HELPER_EVIDENCE} is absent"

  local changed=() row
  for row in "${MATRIX[@]}"; do changed+=("$(field "${row}" 1)"); done

  local checked=0 drift=0 recorded_count=0 line recorded path observed skip target
  declare -A RECORDED=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ "${recorded}" =~ ^[0-9a-f]{64}$ ]] || halt "unparseable Generation-5 evidence line: ${line}"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    recorded_count=$((recorded_count + 1))
    RECORDED["${path}"]="${recorded}"
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
  done < "${GEN5_LIBRARY_EVIDENCE}"

  (( checked > 0 )) || halt "the Generation-5 library evidence yielded no comparable entries"
  (( drift == 0 )) || halt "${drift} unchanged runtime objects drifted from Generation 5"
  [[ "${recorded_count}" -eq "${EXPECTED_LIBRARY_FILES_GEN5}" ]] \
    || halt "the Generation-5 evidence records ${recorded_count} objects, expected ${EXPECTED_LIBRARY_FILES_GEN5}"
  ok "unchanged runtime surface verified against Generation-5 evidence (${checked} objects)"

  # The evidence must ALSO account for every installed file. Comparing evidence
  # -> disk alone cannot see a file that was added to the host and never
  # recorded, which is precisely what a stray snapshot.py would be.
  local unrecorded=0 file
  while IFS= read -r file; do
    [[ -n "${RECORDED[${file}]:-}" ]] || {
      bad "installed runtime object is absent from the Generation-5 evidence: ${file}"
      unrecorded=$((unrecorded + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( unrecorded == 0 )) || halt "${unrecorded} installed objects are not in the Generation-5 baseline"

  # The five replacement targets must be recorded at exactly the Generation-5
  # digests this transaction pins, which ties the on-host evidence to the pinned
  # commit rather than trusting either alone.
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; recorded="$(field "${row}" 4)"
    if [[ "${recorded}" == "ABSENT" ]]; then
      [[ -z "${RECORDED[${target}]:-}" ]] \
        || halt "the Generation-5 evidence records ${target}, which must be absent at Generation 5"
      continue
    fi
    [[ "${RECORDED[${target}]:-}" == "${recorded}" ]] \
      || halt "the Generation-5 evidence records ${target} as ${RECORDED[${target}]:-absent}, expected ${recorded}"
  done
  ok "the Generation-5 evidence agrees with the pinned baseline at every target"

  require_helpers_unchanged

  classify_all
  ok "target classification: GEN5=${GEN5_COUNT} GEN6=${GEN6_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
}

# Generation 6 changes no /usr/libexec object. The privileged boundary --
# policy, action, entrypoint, worker entrypoint, PROFILE_FD, the seals, the
# five-element argv -- stays byte-identical, and that is verified rather than
# asserted in prose.
require_helpers_unchanged() {
  [[ -f "${GEN5_HELPER_EVIDENCE}" ]] || halt "Generation-5 helper evidence is absent"
  local line recorded path observed drift=0 seen=0
  while IFS= read -r line; do
    [[ "${line}" =~ ^[0-9a-f]{64} ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    observed="$(digest_of "${path}")"
    seen=$((seen + 1))
    if [[ "${observed}" != "${recorded}" ]]; then
      bad "privileged helper drifted: ${path} is ${observed:-absent}, Generation-5 evidence says ${recorded}"
      drift=$((drift + 1))
    fi
  done < "${GEN5_HELPER_EVIDENCE}"
  (( seen == ${#HELPERS[@]} )) \
    || halt "the Generation-5 helper evidence records ${seen} objects, expected ${#HELPERS[@]}"
  (( drift == 0 )) || halt "${drift} privileged helpers drifted: the Generation-5 boundary is not intact"
  ok "/usr/libexec unchanged: the Generation-5 privileged boundary is byte-identical (${seen} objects)"
}

require_no_eighth_delta() {
  local installed extra=0
  [[ ! -d "${LIBRARY_ROOT}/tools/provisioning" ]] \
    || bad "tools/provisioning is present in the runtime library"
  [[ ! -e "${LIBEXEC}/kyri-exec-transition-action" ]] \
    || bad "the action layer exists as a privileged executable"
  [[ ! -e "${LIBRARY_ROOT}/install-generation-6.sh" ]] \
    || bad "operator tooling is installed inside the runtime library"
  while IFS= read -r installed; do
    case "${installed}" in
      *"${PREPARED_SUFFIX}"|*"${BACKUP_SUFFIX}") extra=$((extra + 1)) ;;
    esac
  done < <(find "${LIBRARY_ROOT}" "${LIBEXEC}" -maxdepth 6 -type f 2>/dev/null || true)
  (( extra == 0 )) || note "${extra} transaction artefacts present (a prior run was interrupted)"
  ok "no unexpected runtime object, no operator tooling installed"
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

# The commit window is only operationally safe while nothing can enter the
# privilege boundary. Re-proved at run time rather than quoted from a document.
require_no_live_caller() {
  local sudoers="/etc/sudoers.d/kyri-exec" callers=0
  [[ -n "${FIXTURE}" ]] && sudoers="${FIXTURE}${sudoers}"
  [[ ! -e "${sudoers}" ]] || { bad "a sudoers policy exists: the coordinator can invoke the helper"; callers=$((callers + 1)); }
  if [[ -z "${FIXTURE}" ]]; then
    local unit
    unit="$(grep -rl 'kyri-exec' /etc/systemd/system /lib/systemd/system /etc/cron.d /etc/crontab 2>/dev/null || true)"
    [[ -z "${unit}" ]] || { bad "a systemd or cron entry references kyri-exec:"$'\n'"${unit}"; callers=$((callers + 1)); }
  fi
  (( callers == 0 )) \
    || halt "a live caller of the privilege boundary exists: sequential COMMIT visibility is NOT safe here"
  ok "no live caller: no sudoers policy, no systemd unit or cron entry naming kyri-exec"
}

# Every prepared file must land on the same filesystem as the pathname it will
# publish at, or rename(2)/link(2) is EXDEV and the whole model collapses into
# copy.
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
  ok "every prepared object shares a filesystem with its target (rename and link are possible)"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode operation gen5 gen6 prepared backup observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"
    backup="${target}${BACKUP_SUFFIX}"

    if [[ "${operation}" == "REPLACE" ]]; then
      # The Generation-5 bytes are retained BEFORE anything is staged, because
      # a rollback with no material to roll back to is a wish rather than a
      # plan.
      rm -f "${backup}"
      cp -p "${target}" "${backup}"
      observed="$(digest_of "${backup}")"
      [[ "${observed}" == "${gen5}" ]] \
        || halt "the retained Generation-5 copy of ${target} is ${observed}, expected ${gen5}"
      sync_path "${backup}"
    else
      # A CREATE has no Generation-5 bytes to retain: its rollback is removal.
      # What it does require is that the pathname is genuinely free. An object
      # here belongs to somebody else and this transaction will not adopt,
      # overwrite, or delete it.
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"
      rm -f "${backup}"
    fi

    rm -f "${prepared}"
    materialise_gen6 "${source}" "${prepared}" "${gen6}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen6}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen6}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
  done
  ok "PREPARE complete: six new objects staged, five Generation-5 copies retained, one create-once pathname reserved"
}

verify_prepared_set() {
  local row target operation gen5 gen6
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen6}" ]] \
      || halt "prepared object for ${target} does not verify"
    if [[ "${operation}" == "REPLACE" ]]; then
      [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${gen5}" ]] \
        || halt "retained Generation-5 copy for ${target} does not verify"
    fi
  done
  ok "prepared set and rollback material both verify"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode operation gen5 gen6 prepared index=0 observed owner_now
  journal_write COMMITTING
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection. Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN6_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run of this transaction.
    # Forward recovery re-enters COMMIT at position 1, and a target that is
    # already Generation 6 has had its prepared object consumed: there is
    # nothing left to rename or link, and republishing is neither possible nor
    # needed. Decided from the target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen5}" "${gen6}")" == "GEN6" ]]; then
      PROGRESS["${index}"]="GEN6"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING

    if [[ "${operation}" == "CREATE" ]]; then
      # link(2): atomic, and EEXIST rather than a silent overwrite.
      if ! create_once "${prepared}" "${target}"; then
        PROGRESS["${index}"]="CREATE_FAILED"
        journal_write COMMITTING
        rollback "create-once at ${target} failed: an object appeared at a pathname this transaction reserved"
        return 1
      fi
    else
      mv -f "${prepared}" "${target}"        # rename(2): atomic for this pathname
      sync_path "${target}"
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen6}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen6}"
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

    PROGRESS["${index}"]="GEN6"
    journal_write COMMITTING
  done
  journal_write COMMITTED
  OUTCOME="COMMITTED"
  ok "COMMIT complete: six pathnames published and verified"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# REPLACE targets are restored from their retained Generation-5 copy.
#
# The CREATE target is REMOVED -- and only when what is there is still exactly
# what this transaction installed. If the bytes, mode, or ownership have moved,
# the object is UNKNOWN: somebody else's, and deleting somebody else's file to
# tidy up a failed installation is the one thing a rollback must never do.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target mode operation gen5 gen6 backup observed restored=0 removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"

    if [[ "${operation}" == "CREATE" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        continue                              # never published, or already removed
      fi
      if [[ -L "${target}" || ! -f "${target}" ]]; then
        bad "${target} is not the regular file this transaction created; NOT removing it"
        continue
      fi
      observed="$(digest_of "${target}")"
      if [[ "${observed}" != "${gen6}" ]]; then
        bad "${target} is ${observed}, not the Generation-6 object this transaction installed; NOT removing it"
        continue
      fi
      if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
        bad "${target} has mode $(stat -c '%a' "${target}"), not ${mode#0}; NOT removing it"
        continue
      fi
      if [[ -z "${FIXTURE}" && "$(stat -c '%U:%G' "${target}")" != "root:root" ]]; then
        bad "${target} is $(stat -c '%U:%G' "${target}"), not root:root; NOT removing it"
        continue
      fi
      rm -f "${target}"
      sync_path "${target}"                   # the file is gone; its parent is fsynced
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || { bad "${target} still exists after removal"; continue; }
      removed=$((removed + 1))
      continue
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${gen5}" ]]; then
      continue
    fi
    backup="${target}${BACKUP_SUFFIX}"
    [[ -f "${backup}" ]] || { bad "no retained Generation-5 copy for ${target}"; continue; }
    [[ "$(digest_of "${backup}")" == "${gen5}" ]] \
      || { bad "the retained copy for ${target} does not verify; not restoring from it"; continue; }
    cp -p "${backup}" "${target}.restoring"
    mv -f "${target}.restoring" "${target}"
    sync_path "${target}"
    restored=$((restored + 1))
  done

  # Prove the whole set is Generation 5 again before claiming a rollback.
  classify_all
  if (( GEN5_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "ROLLBACK complete: all six targets are Generation 5 again (${restored} restored, ${removed} removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN5=${GEN5_COUNT} GEN6=${GEN6_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed:
#
#   * every remaining target's PREPARED object verifies to its pinned
#     Generation-6 digest  -> complete FORWARD
#   * otherwise -> roll BACK to a complete Generation 5
#   * unknown bytes anywhere -> fail closed for operator disposition
#
# Forward is preferred when provable because it reaches the generation the
# operator asked for; rollback is the fallback because it is always the safer
# terminal state.
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN5=%d GEN6=%d UNKNOWN=%d\n' \
    "${state}" "${GEN5_COUNT}" "${GEN6_COUNT}" "${UNKNOWN_COUNT}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither Generation 5 nor Generation 6)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN6_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-6 set is already installed"
    return 0
  fi
  if (( GEN5_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: the complete Generation-5 set is intact; nothing was committed"
    return 0
  fi

  # Mixed. Can forward completion be proven from the prepared material?
  local row target gen5 gen6 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen5="$(field "${row}" 4)"; gen6="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen5}" "${gen6}")" == "GEN6" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen6}" ]] || { forward=0; break; }
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
# New names. The Generation-3, Generation-4, G4c and Generation-5 evidence is
# never overwritten: it is the record of what those gates accepted, and a
# generation that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${GEN5_LIBRARY_EVIDENCE}" && -f "${GEN5_HELPER_EVIDENCE}" ]] \
    || halt "Generation-5 evidence vanished during installation"
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN6_LIBRARY_EVIDENCE}.writing"
  grep -q "${LIBRARY_ROOT}/tools/capability/execution/snapshot.py\$" "${GEN6_LIBRARY_EVIDENCE}.writing" \
    || { rm -f "${GEN6_LIBRARY_EVIDENCE}.writing"; halt "the Generation-6 evidence does not record snapshot.py"; }
  {
    sha256sum "${HELPERS[@]}"
    printf '%s  %s\n' "$(digest_of "${TMPFILES_TARGET}")" "${TMPFILES_TARGET}"
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN5_COMMIT}"
    printf 'transaction %s\n' "${TRANSACTION_ID}"
  } > "${GEN6_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN6_LIBRARY_EVIDENCE}.writing" "${GEN6_HELPER_EVIDENCE}.writing"
  sync_path "${GEN6_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN6_HELPER_EVIDENCE}.writing"
  mv -f "${GEN6_LIBRARY_EVIDENCE}.writing" "${GEN6_LIBRARY_EVIDENCE}"
  mv -f "${GEN6_HELPER_EVIDENCE}.writing" "${GEN6_HELPER_EVIDENCE}"
  sync_path "${GEN6_LIBRARY_EVIDENCE}"
  sync_path "${GEN6_HELPER_EVIDENCE}"
  ok "Generation-6 evidence written (44 objects, snapshot.py included); Generation-5 evidence preserved"
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
  local row target mode gen6 observed owner_now
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"; gen6="$(field "${row}" 5)"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen6}" ]] || bad "${target} is ${observed:-absent}, expected ${gen6}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "${mode#0}" ]] || bad "${target} has the wrong mode"
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}" 2>/dev/null)"
      [[ "${owner_now}" == "root:root" ]] || bad "${target} is ${owner_now:-absent}, expected root:root"
    fi
  done
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES_GEN6}" ]] \
    || bad "the library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES_GEN6}"
  (( FAILURES == 0 )) && ok "the complete Generation-6 set verifies (${installed} library objects)"
}

# The unchanged surface after installation: everything the Generation-5
# evidence records except the five replaced targets is still exactly Generation
# 5, and /usr/libexec is untouched. A count of 44 cannot say that.
verify_unchanged_surface_after() {
  local changed=() row line recorded path observed drift=0 skip target
  for row in "${MATRIX[@]}"; do changed+=("$(field "${row}" 1)"); done
  [[ -f "${GEN5_LIBRARY_EVIDENCE}" ]] || { bad "Generation-5 evidence is absent"; return; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    skip=0
    for target in "${changed[@]}"; do
      [[ "${path}" == "${target}" ]] && { skip=1; break; }
    done
    (( skip == 1 )) && continue
    observed="$(digest_of "${path}")"
    [[ "${observed}" == "${recorded}" ]] || { bad "unchanged runtime object drifted: ${path}"; drift=$((drift + 1)); }
  done < "${GEN5_LIBRARY_EVIDENCE}"
  (( drift == 0 )) && ok "the unchanged runtime surface is still exactly Generation 5"
  require_helpers_unchanged
}

verify_contract() {
  local snapshot="${LIBRARY_ROOT}/tools/capability/execution/snapshot.py"
  local worker="${LIBRARY_ROOT}/tools/capability/execution/worker.py"
  local policy="${LIBRARY_ROOT}/kyri_exec_transition.py"
  local action="${LIBRARY_ROOT}/kyri_exec_transition_action.py"
  local entry="${LIBEXEC}/kyri-exec-worker.py"

  # Generation 6: the worker owns the material the container consumes.
  grep -q 'SNAPSHOT_ROOT = "/run/kyri/execution-material"' "${snapshot}" \
    || bad "the installed snapshot module does not name the ruled snapshot root"
  grep -q 'O_NOFOLLOW' "${snapshot}" || bad "the installed snapshot module follows symlinks"
  grep -q 'O_EXCL' "${snapshot}" || bad "the installed snapshot module does not create exclusively"
  grep -q 'from .snapshot import SnapshotBinding' "${worker}" \
    || bad "the installed worker does not bind through the snapshot"
  grep -q 'a materialised snapshot is required' "${worker}" \
    || bad "the installed worker accepts an unmaterialised snapshot"
  grep -q 'src={snapshot.payload}' "${worker}" \
    || bad "the installed worker binds a payload that is not the snapshot's"
  grep -q 'src={snapshot.package}' "${worker}" \
    || bad "the installed worker binds a package that is not the snapshot's"

  # Generation 5, unchanged: the privileged boundary is byte-identical, and
  # these are the properties that boundary exists to hold.
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
  (( FAILURES == 0 )) && ok "installed contract: worker-owned snapshot, FD 3, four seals, vNext record, opaque root"
}

verify_import_boundary() {
  [[ -n "${FIXTURE}" ]] && { note "import boundary not exercised in fixture mode"; return; }
  local resolved
  resolved="$(cd / && PYTHONPATH=/tmp /usr/bin/python3 -c "
import sys
sys.path.insert(0, '${LIBRARY_ROOT}')
import kyri_exec_transition as m
from tools.capability.execution import worker as w
from tools.capability.execution import snapshot as s
print(m.__file__, w.__file__, s.__file__)
")" || { bad "the installed library is not importable"; return; }
  case "${resolved}" in
    "${LIBRARY_ROOT}"*"${LIBRARY_ROOT}"*"${LIBRARY_ROOT}"*)
      ok "policy, worker, and snapshot all resolve inside ${LIBRARY_ROOT}" ;;
    *) bad "modules resolved outside the canonical root: ${resolved}" ;;
  esac
}

require_no_transaction_residue() {
  local state
  state="$(journal_state)"
  case "${state}" in
    NONE|COMMITTED) ok "no transaction in progress (journal ${state})" ;;
    *) bad "a transaction journal is in state ${state}: the host is mid-transaction" ;;
  esac
}

# ===========================================================================
# Modes
# ===========================================================================
TRANSACTION_ID="gen6-${COMMIT:0:12}"

printf '== Generation 6 (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify-prerequisite)
  # Read-only eligibility for the operator's snapshot-root ceremony. Copies no
  # fragment, runs no systemd-tmpfiles, creates no directory, and changes no
  # ownership or mode. The expected live state right now -- fragment absent,
  # /run/kyri absent -- is ELIGIBLE, not corruption.
  require_repository
  verify_prerequisite
  ;;

--verify-prerequisite-installed)
  # Read-only confirmation after the operator provisioned it. Mutates nothing.
  require_repository
  verify_prerequisite_installed
  ;;

--verify)
  # Read-only. Proves this is a valid Generation-5 host, that the host
  # prerequisite is already installed and correct, and that the transaction is
  # ready. It does NOT check the installed tree for Generation-6 content --
  # that is what --verify-installed is for.
  require_repository
  require_source_digests
  require_tmpfiles_artifact
  require_gen5_baseline
  require_no_eighth_delta
  require_gates_closed
  require_no_live_caller
  require_same_filesystem

  # The prerequisite is not optional and not silently provisioned. If it is
  # absent, this host is not ready to install Generation 6 and saying otherwise
  # would be the whole point of the separate ceremony thrown away.
  prerequisite_ready=1
  if [[ "$(classify_fragment)" != "EXACT" ]] \
     || [[ "$(classify_prerequisite_path "${SNAPSHOT_PARENT}" "${EXPECTED_PARENT_OWNER}" "${EXPECTED_PARENT_MODE}")" != "EXACT" ]] \
     || [[ "$(classify_prerequisite_path "${SNAPSHOT_ROOT}" "${EXPECTED_MATERIAL_OWNER}" "${EXPECTED_MATERIAL_MODE}")" != "EXACT" ]]; then
    prerequisite_ready=0
  fi

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  if (( prerequisite_ready == 0 )); then
    bad "the snapshot-root prerequisite is not installed"
    printf '\n'
    printf 'RUNTIME SOURCE READY, BUT THE SNAPSHOT-ROOT PREREQUISITE IS ABSENT.\n'
    printf 'This host is NOT ready to install Generation 6.\n'
    printf 'Complete the prerequisite ceremony first:\n'
    printf '  1. bash %s --verify-prerequisite\n' "provisioning/execution/install-generation-6.sh"
    printf '  2. operator review\n'
    printf '  3. operator installs the fragment and runs systemd-tmpfiles\n'
    printf '  4. bash %s --verify-prerequisite-installed\n' "provisioning/execution/install-generation-6.sh"
    printf 'Then rerun --verify.\n'
    exit 1
  fi
  ok "the snapshot-root prerequisite is installed and verifies"

  if (( GEN5_COUNT == ${#MATRIX[@]} )); then
    ok "all six targets are Generation 5 (snapshot.py absent): the host is ready for installation"
  elif (( GEN6_COUNT == ${#MATRIX[@]} )); then
    note "all six targets are already Generation 6"
  else
    bad "mixed or unknown target state: GEN5=${GEN5_COUNT} GEN6=${GEN6_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
  fi
  ;;

--verify-installed)
  verify_installed_set
  verify_unchanged_surface_after
  verify_contract
  verify_import_boundary
  require_no_eighth_delta
  require_gates_closed
  require_no_transaction_residue
  verify_prerequisite_installed
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
    ok "nothing to recover: GEN5=${GEN5_COUNT} GEN6=${GEN6_COUNT}"
  else
    # The prerequisite is re-checked here, immediately before PREPARE, rather
    # than trusted from an earlier --verify: the two are separated by an
    # operator review, and the host can move in between.
    verify_prerequisite_installed
    (( FAILURES == 0 )) || halt "the snapshot-root prerequisite does not verify: complete the prerequisite ceremony before installing the runtime"
    require_gen5_baseline
    require_no_eighth_delta
    require_gates_closed
    require_no_live_caller
    require_same_filesystem
    (( UNKNOWN_COUNT == 0 )) || halt "unknown bytes at a target: refusing to start a transaction"
    if (( GEN6_COUNT == ${#MATRIX[@]} )); then
      OUTCOME="COMMITTED"
      ok "Generation 6 is already installed; nothing to do"
    else
      (( GEN5_COUNT == ${#MATRIX[@]} )) || halt "not a clean Generation-5 baseline: refusing to start"
      prepare
      verify_prepared_set
      journal_write PREPARED
      commit_targets || halt "installation failed and was rolled back; the host is Generation 5"
    fi
  fi

  # A rollback is a correct, complete outcome -- it is simply not Generation 6.
  # Verifying the Generation-6 set here would report the restored Generation-5
  # bytes as six digest failures and bury what actually happened.
  if [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    printf '\n'
    printf 'Generation 6 was NOT installed.\n'
    printf 'The host is a complete, verified Generation 5 and no evidence was written.\n'
    printf 'The transaction journal is at %s.\n' "${JOURNAL}"
    exit 1
  fi

  # Only now, and only if everything above held.
  verify_installed_set
  verify_unchanged_surface_after
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
  printf 'Generation 6 %s: all checks passed.\n' "${MODE#--}"
  printf 'No image built or admitted, no CIMP/CGEN state, no sudoers policy,\n'
  printf 'no tmpfiles fragment installed, no snapshot root created, and neither\n'
  printf 'the transition nor the worker was invoked.\n'
else
  printf 'Generation 6 %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
