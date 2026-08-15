#!/usr/bin/env bash
set -Eeuo pipefail

# The G6.1A trusted-runtime installation ceremony (Generation 7) for ENG-0005.
#
# GENERATED, NOT EXECUTED. Nothing has run this script against the live host.
#
# WHAT THIS INSTALLS
# ==================
# The five verification-only artifacts G6.1 designed, and nothing else:
#
#   /usr/lib/kyri/python/tools/capability/execution/image_store.py   0444
#   /usr/lib/kyri/python/tools/capability/execution/verification.py  0444
#   /usr/lib/kyri/python/kyri_exec_verify.py                         0444
#   /usr/libexec/kyri-exec-verify-worker.py                          0444
#   /usr/libexec/kyri-exec-verify                                    0555
#
# The installed library moves 44 -> 47 objects. /usr/libexec gains two objects
# and none of its three existing ones changes by a single byte.
#
# WHAT THIS DOES NOT DO, AND CANNOT
# =================================
# It installs NO sudoers policy. Granting `cschott` the authority to run
# /usr/libexec/kyri-exec-verify is G6.1B: a separate ceremony that digest-binds
# the installed helper and then performs the first live
# cschott -> root -> kyri-capability -> verification-worker crossing. This one
# ends with the boundary installed and unreachable by anyone, which is exactly
# the state an operator should be able to review before granting anything.
#
# It also never invokes the transition, never executes any worker, never
# contacts a container runtime, never touches the implementation-authority
# namespace, never allocates a CIMP/CGEN/CINV, and never opens G6 production
# execution. The production worker entrypoint is a Generation-5 object here and
# stays byte-identical, so it still refuses for want of a bound runtime backend.
#
# TRUST MODEL
# ===========
# Two properties, both taken from ceremonies that already exist rather than
# invented here:
#
#   * REVIEWED SOURCE, ROOT-OWNED MATERIALISATION (from the G5 ceremony).
#     Every installed byte comes from `git cat-file blob <reviewed-commit>:path`
#     and is digest-verified before it is staged. **git never runs as root
#     inside the coordinator's repository**: it is dropped to the repository
#     owner, because git executes hooks, pagers, aliases and filters from
#     configuration that a coordinator can write. The working tree is never a
#     source of installed bytes; it is only checked for cleanliness, so that
#     "the checkout in front of the operator is what was reviewed" is a fact.
#
#   * TRANSACTIONAL, CRASH-RECOVERABLE PUBLICATION (from the Generation-6
#     installer). PREPARE stages every object beside its target on the target's
#     own filesystem with final bytes, owner and mode, fsynced. A durable
#     root-only JOURNAL records intent, pinned digests and progress before each
#     irreversible step. COMMIT publishes with one link(2) per target.
#     ROLLBACK removes what this transaction installed and nothing else.
#     RECOVER re-enters an interrupted transaction from ACTUAL bytes.
#
# This is the same installer primitive Generations 5 and 6 used, instantiated a
# third time rather than reimplemented or generalised into a framework. The
# repository's convention is that operator ceremonies source nothing and carry
# their own constants; extracting a shared library would mean refactoring two
# already-executed, accepted installations of a privilege boundary, which is a
# larger and riskier change than the one being made here.
#
# HOW GENERATION 7 DIFFERS FROM GENERATION 6
# ==========================================
#   * every target is a CREATE. There is no REPLACE, so there is no retained
#     copy and no restore: rollback is uniformly REMOVE
#   * /usr/libexec gains objects for the first time since Generation 5. Its
#     three existing objects are still required to be byte-identical
#   * the baseline is Generation 6 (44 objects) rather than Generation 5
#   * the authority namespace EXISTS now -- G5 was accepted -- so "gates
#     closed" means the sudoers grants are absent and the authority namespace is
#     untouched, not that it is absent
#
# It is NOT an atomic five-object installation and does not claim to be. Linux
# offers atomic create-once of ONE pathname (link(2)) and no primitive that
# makes five pathnames appear together. During COMMIT there is a window in
# which some targets exist and others do not. That window is only safe while
# nothing can enter the boundary, which is why no sudoers grant may exist and
# why the grant is a separate later ceremony.
#
# Usage (--install requires root; every other mode is read-only):
#   install-generation-7.sh --verify           is this a valid Generation-6
#                                              host, and is the transaction
#                                              ready?
#   install-generation-7.sh --install          transactional install, or
#                                              recovery if a journal exists
#   install-generation-7.sh --verify-installed is the complete Generation-7 set
#                                              installed, and does every byte
#                                              correspond to the reviewed
#                                              commit?
#   install-generation-7.sh --recover          recovery only; never starts a
#                                              new transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host. Owner
#                   enforcement is relaxed (a fixture is not root-owned); mode,
#                   digest, journal, commit, rollback and recovery logic are the
#                   production paths. KYRI_GEN7_FAIL_AT is honoured ONLY with
#                   --fixture, so no production run can inject a failure.

# The reviewed G6.1 source commit. Every installed byte comes from here.
COMMIT="153066a57bd2e3e0a13840c3bdd44dd7c4ef7917"
# The installed baseline. What Generation 6 is comes from immutable history as
# well as from on-host evidence, so it is never re-derived from a working tree.
GEN6_COMMIT="32c3091b6457e06b4ebb86fed3e2d126cd3e7b07"
# /usr/libexec has been Generation 5 since it was installed, and stays so.
GEN5_COMMIT="cfb0edd31b3589f12b6ba583ebfa48bb64e89519"
BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen7-transaction"
GEN6_LIBRARY_EVIDENCE="/root/kyri-gen6-library-digests.txt"
GEN6_HELPER_EVIDENCE="/root/kyri-gen6-helper-digests.txt"
GEN7_LIBRARY_EVIDENCE="/root/kyri-gen7-library-digests.txt"
GEN7_HELPER_EVIDENCE="/root/kyri-gen7-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

EXPECTED_LIBRARY_FILES_GEN6=44
EXPECTED_LIBRARY_FILES_GEN7=47

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
  GEN6_LIBRARY_EVIDENCE="${FIXTURE}${GEN6_LIBRARY_EVIDENCE}"
  GEN6_HELPER_EVIDENCE="${FIXTURE}${GEN6_HELPER_EVIDENCE}"
  GEN7_LIBRARY_EVIDENCE="${FIXTURE}${GEN7_LIBRARY_EVIDENCE}"
  GEN7_HELPER_EVIDENCE="${FIXTURE}${GEN7_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen7.new"

FAILURES=0
# The terminal outcome of a commit or recovery: COMMITTED or ROLLED_BACK. A
# successful rollback is a correct outcome and must not fall through to the
# Generation-7 verification, which would report it as five digest failures.
OUTCOME=""
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the five generation-7 objects, all new --------------------------------
#
# source | target | mode | operation | gen6-state | gen7-sha256
#
# The Generation-6 state of every one of them is the literal ABSENT: an object
# at any of these pathnames is neither generation, is somebody else's, and is
# never overwritten, adopted, or deleted.
#
# Order is dependency order. The two library modules come first because the
# worker imports them; the flattened policy module next because the entrypoint
# imports it; the worker before the entrypoint; and the ENTRYPOINT LAST,
# because it is the pathname a future sudoers grant would name and it should be
# the last thing to come into existence.
MATRIX=(
"tools/capability/execution/image_store.py|${LIBRARY_ROOT}/tools/capability/execution/image_store.py|0444|CREATE|ABSENT|996b126e5ed3d43d9c2ee4f6d285a340bf18eacbb006764fb55bbb59b2645bca"
"tools/capability/execution/verification.py|${LIBRARY_ROOT}/tools/capability/execution/verification.py|0444|CREATE|ABSENT|ed5b49ed03add16c8ba7a233d53a8c5528e5ba4d0fc23f53cdd41bb788bd2e73"
"provisioning/execution/kyri-exec-verify.py|${LIBRARY_ROOT}/kyri_exec_verify.py|0444|CREATE|ABSENT|3d70707d19c34fcc225775d7c1afd9a0f70e0615ca377f765e299730cc99853b"
"provisioning/execution/kyri-exec-verify-worker.py|${LIBEXEC}/kyri-exec-verify-worker.py|0444|CREATE|ABSENT|5a614ff73c0dd06e0a1c7441e247a6fc046eeeb059a0f08aff8335d9cc71678d"
"provisioning/execution/kyri-exec-verify-entrypoint.py|${LIBEXEC}/kyri-exec-verify|0555|CREATE|ABSENT|fad96924adbb7ec28d4c1170f104102ca656b5c04da2f129df5d77561ea6541b"
)

# The three /usr/libexec objects that already exist. Generation 7 changes NONE
# of them; they are listed so "unchanged" is verified rather than assumed.
HELPERS=(
"${LIBEXEC}/kyri-exec-transition"
"${LIBEXEC}/kyri-exec-worker.py"
"${LIBEXEC}/kyri-exec-quota"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# One installed module's executable text, with every comment and docstring
# removed.
#
# The contract checks below scan for names that must not appear. These files
# explain at length what they must not do -- "does not import snapshot", "never
# binds create_argv" -- so scanning their prose would fail them for describing
# themselves accurately. Parsed with `ast`, which reads the file and executes
# nothing, under `env -i` and `-I -B` so the parse cannot be influenced by the
# environment or leave bytecode behind.
code_of() {
  env -i /usr/bin/python3 -I -B - "$1" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in ast.walk(tree):
    body = getattr(node, "body", None)
    if not isinstance(body, list) or not body:
        continue
    if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
        continue
    first = body[0]
    if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
            and isinstance(first.value.value, str):
        body.pop(0)
        if not body:
            body.append(ast.Pass())
ast.fix_missing_locations(tree)
print(ast.unparse(tree))
PY
}

# --- git, never as root inside the coordinator's repository -----------------
#
# The G5 ceremony's ruling, applied here. `git` is not a byte reader: it
# executes hooks, pagers, aliases, and filters configured by files a
# coordinator can write. Running it as root inside a coordinator-owned
# repository hands the coordinator root, and no amount of care about WHICH
# subcommand is invoked changes that. So it runs as the repository's owner and
# root only ever sees the bytes on the far side of a pipe.
REPO_OWNER="$(stat -c '%U' "${REPOSITORY}" 2>/dev/null || printf 'root')"
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

# Publish a prepared object at a pathname that must not already exist.
#
# link(2) rather than rename(2): rename would silently overwrite, and "there
# was nothing there" must be a property of the transaction rather than a hope.
# link fails EEXIST instead of destroying whatever an operator or an earlier
# run left behind.
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

# --- journal ---------------------------------------------------------------
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN6_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
    printf 'libexec=%s\n' "${LIBEXEC}"
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
# GEN6 / GEN7 / UNKNOWN, decided from actual bytes and never from the journal.
#
# Every target is a CREATE, so GEN6 means ABSENT -- and ABSENT means nothing at
# all at that pathname, not "no regular file". A directory or a dangling
# symlink there is UNKNOWN, because it is something this transaction did not
# put there.
classify() {
  local target="$1" gen7="$2" observed
  if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN6'; return; fi
  if [[ -f "${target}" && ! -L "${target}" ]]; then
    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${gen7}" ]]; then printf 'GEN7'; return; fi
  fi
  printf 'UNKNOWN'
}

classify_all() {
  local row target gen7 state
  GEN6_COUNT=0; GEN7_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen7="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen7}")"
    case "${state}" in
      GEN6) GEN6_COUNT=$((GEN6_COUNT + 1)) ;;
      GEN7) GEN7_COUNT=$((GEN7_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# --- repository preflight --------------------------------------------------
require_repository() {
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)"
  # The pinned commit is where the five objects' content was reviewed. A later
  # documentation or test commit changes no installed byte, so requiring HEAD to
  # EQUAL it would make the ceremony expire for a reason that cannot affect what
  # gets installed. What must hold is ancestry -- and then the five source
  # digests, checked next, are the actual gate.
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} does not exist"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD ${head_now}"
  git_as_owner merge-base --is-ancestor "${GEN6_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-6 baseline ${GEN6_COMMIT} is not an ancestor of ${COMMIT}"
  git_as_owner merge-base --is-ancestor "${GEN5_COMMIT}" "${GEN6_COMMIT}" 2>/dev/null \
    || halt "the Generation-5 baseline ${GEN5_COMMIT} is not an ancestor of ${GEN6_COMMIT}"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  residue="$(git_as_owner status --porcelain --untracked-files=all)"
  if [[ -n "${residue}" ]]; then
    # A production run installs from this checkout's history, so an unreviewed
    # edit in it means the tree in front of the operator is not the thing that
    # was reviewed. A fixture run is driven by the repository's own suite, which
    # legitimately runs while a developer has uncommitted work.
    [[ -n "${FIXTURE}" ]] || halt "the working tree is not clean:"$'\n'"${residue}"
    note "the working tree is not clean; permitted in fixture mode only"
  fi
  ok "repository on ${BRANCH} at ${head_now} (contains ${COMMIT}), tree checked (as ${REPO_OWNER})"
}

# One generation-7 object, taken from the commit that defines it.
#
# Read from the pinned commit rather than the working tree, because they are not
# the same thing once development continues: installing whatever the checkout
# happens to hold would put unreviewed bytes on the host under a reviewed label.
# The digest check verifies what was actually extracted, so a rewritten history
# cannot substitute either.
materialise_gen7() {
  local source="$1" destination="$2" expected="$3" observed
  git_as_owner cat-file blob "${COMMIT}:${source}" > "${destination}" \
    || halt "${source} is not readable at ${COMMIT}"
  observed="$(digest_of "${destination}")"
  [[ "${observed}" == "${expected}" ]] \
    || halt "${source} at ${COMMIT} is ${observed}, expected ${expected}"
}

require_source_digests() {
  local row source gen7 scratch
  scratch="$(mktemp)"
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen7="$(field "${row}" 5)"
    git_as_owner cat-file -e "${COMMIT}:${source}" 2>/dev/null \
      || { rm -f "${scratch}"; halt "${source} does not exist at ${COMMIT}"; }
    materialise_gen7 "${source}" "${scratch}" "${gen7}"
    # Every object must be genuinely new. If one existed at Generation 6 then
    # this is a replacement wearing a create's clothes, and its rollback --
    # removal -- would destroy an accepted object.
    ! git_as_owner cat-file -e "${GEN6_COMMIT}:${source}" 2>/dev/null \
      || { rm -f "${scratch}"; halt "${source} already existed at Generation 6 ${GEN6_COMMIT}: it is not new"; }
  done
  rm -f "${scratch}"
  ok "all five Generation-7 source digests match ${COMMIT}, and all five are absent at ${GEN6_COMMIT}"
}

# --- generation-6 baseline --------------------------------------------------
#
# Against the accepted evidence rather than a file count. A count cannot tell a
# replaced module from an untouched one, and it certainly cannot notice a module
# that was swapped for another of the same name.
require_gen6_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: not a provisioned host"
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES_GEN6}" ]] \
    || halt "the installed library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES_GEN6}"

  [[ -f "${GEN6_LIBRARY_EVIDENCE}" ]] || halt "Generation-6 evidence ${GEN6_LIBRARY_EVIDENCE} is absent"
  [[ -f "${GEN6_HELPER_EVIDENCE}" ]] || halt "Generation-6 evidence ${GEN6_HELPER_EVIDENCE} is absent"

  local checked=0 drift=0 recorded_count=0 line recorded path observed
  declare -A RECORDED=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ "${recorded}" =~ ^[0-9a-f]{64}$ ]] || halt "unparseable Generation-6 evidence line: ${line}"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    recorded_count=$((recorded_count + 1))
    RECORDED["${path}"]="${recorded}"
    observed="$(digest_of "${path}")"
    if [[ "${observed}" != "${recorded}" ]]; then
      bad "runtime object drifted: ${path} is ${observed:-absent}, evidence says ${recorded}"
      drift=$((drift + 1))
    fi
    checked=$((checked + 1))
  done < "${GEN6_LIBRARY_EVIDENCE}"

  (( checked > 0 )) || halt "the Generation-6 library evidence yielded no comparable entries"
  (( drift == 0 )) || halt "${drift} runtime objects drifted from Generation 6"
  [[ "${recorded_count}" -eq "${EXPECTED_LIBRARY_FILES_GEN6}" ]] \
    || halt "the Generation-6 evidence records ${recorded_count} objects, expected ${EXPECTED_LIBRARY_FILES_GEN6}"
  ok "the installed runtime surface is exactly Generation 6 (${checked} objects)"

  # The evidence must ALSO account for every installed file. Comparing evidence
  # -> disk alone cannot see a file that was added to the host and never
  # recorded, and an unrecorded module in the runtime library is precisely the
  # thing this ceremony must not install on top of.
  local unrecorded=0 file
  while IFS= read -r file; do
    [[ -n "${RECORDED[${file}]:-}" ]] || {
      bad "installed runtime object is absent from the Generation-6 evidence: ${file}"
      unrecorded=$((unrecorded + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( unrecorded == 0 )) || halt "${unrecorded} installed objects are not in the Generation-6 baseline"

  # No target may already be recorded: they are new, and the evidence is the
  # statement of what Generation 6 contained.
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -z "${RECORDED[${target}]:-}" ]] \
      || halt "the Generation-6 evidence records ${target}, which must be absent at Generation 6"
  done
  ok "no Generation-7 pathname appears in the Generation-6 baseline"

  require_helpers_unchanged

  classify_all
  ok "target classification: GEN6=${GEN6_COUNT} GEN7=${GEN7_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
}

# Generation 7 changes no existing /usr/libexec object. The privileged boundary
# -- the transition entrypoint, the production worker entrypoint, the quota
# helper -- stays byte-identical, and that is verified rather than asserted.
require_helpers_unchanged() {
  [[ -f "${GEN6_HELPER_EVIDENCE}" ]] || halt "Generation-6 helper evidence is absent"
  local line recorded path observed drift=0 seen=0
  while IFS= read -r line; do
    [[ "${line}" =~ ^[0-9a-f]{64} ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    observed="$(digest_of "${path}")"
    seen=$((seen + 1))
    if [[ "${observed}" != "${recorded}" ]]; then
      bad "privileged helper drifted: ${path} is ${observed:-absent}, Generation-6 evidence says ${recorded}"
      drift=$((drift + 1))
    fi
  done < "${GEN6_HELPER_EVIDENCE}"
  (( seen == ${#HELPERS[@]} )) \
    || halt "the Generation-6 helper evidence records ${seen} objects, expected ${#HELPERS[@]}"
  (( drift == 0 )) || halt "${drift} privileged helpers drifted: the existing boundary is not intact"
  ok "the three existing /usr/libexec objects are byte-identical (${seen} objects)"
}

require_no_extra_delta() {
  local installed extra=0
  [[ ! -d "${LIBRARY_ROOT}/tools/provisioning" ]] \
    || bad "tools/provisioning is present in the runtime library"
  [[ ! -e "${LIBEXEC}/kyri-exec-transition-action" ]] \
    || bad "the action layer exists as a privileged executable"
  [[ ! -e "${LIBRARY_ROOT}/install-generation-7.sh" ]] \
    || bad "operator tooling is installed inside the runtime library"
  while IFS= read -r installed; do
    case "${installed}" in
      *"${PREPARED_SUFFIX}") extra=$((extra + 1)) ;;
    esac
  done < <(find "${LIBRARY_ROOT}" "${LIBEXEC}" -maxdepth 6 -type f 2>/dev/null || true)
  (( extra == 0 )) || note "${extra} transaction artefacts present (a prior run was interrupted)"
  ok "no operator tooling installed, no unexpected privileged executable"
}

# The gates this ceremony must leave exactly as it found them.
#
# G5 is accepted, so the authority namespace EXISTS. "Closed" here therefore
# means the two sudoers grants are absent -- G3 and G6.1B -- and the authority
# namespace is present but untouched, which is checked by comparing it across
# the run rather than by asserting anything about its contents.
AUTHORITY_STATE_BEFORE=""
authority_state() {
  local path state=""
  for path in "${AUTHORITY_ROOT}" "${CONTROL_ROOT}"; do
    if [[ -e "${path}" ]]; then
      state+="${path}:$(stat -c '%U:%G %a %Y' "${path}" 2>/dev/null || printf 'unreadable') "
    else
      state+="${path}:absent "
    fi
  done
  printf '%s' "${state}"
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || bad "${SUDOERS} exists: G3 is not closed"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || bad "${VERIFY_SUDOERS} exists: G6.1B has already run"
  AUTHORITY_STATE_BEFORE="$(authority_state)"
  ok "gates unchanged: neither sudoers grant exists"
}

require_authority_untouched() {
  [[ -n "${AUTHORITY_STATE_BEFORE}" ]] || return 0
  local now
  now="$(authority_state)"
  [[ "${now}" == "${AUTHORITY_STATE_BEFORE}" ]] \
    || bad "the implementation-authority namespace changed during this ceremony"
  [[ ! -e "${SUDOERS}" && ! -e "${VERIFY_SUDOERS}" ]] \
    || bad "a sudoers grant appeared during this ceremony"
  (( FAILURES == 0 )) \
    && ok "the implementation-authority namespace is untouched and no grant was written"
}

# The commit window is only operationally safe while nothing can enter the
# privilege boundary. Re-proved at run time rather than quoted from a document.
require_no_live_caller() {
  local callers=0 unit
  [[ ! -e "${SUDOERS}" ]] || { bad "${SUDOERS} exists: the coordinator can invoke the helper"; callers=$((callers + 1)); }
  [[ ! -e "${VERIFY_SUDOERS}" ]] || { bad "${VERIFY_SUDOERS} exists: the verification boundary is already callable"; callers=$((callers + 1)); }
  if [[ -z "${FIXTURE}" ]]; then
    unit="$(grep -rl 'kyri-exec' /etc/systemd/system /lib/systemd/system /etc/cron.d /etc/crontab 2>/dev/null || true)"
    [[ -z "${unit}" ]] || { bad "a systemd or cron entry references kyri-exec:"$'\n'"${unit}"; callers=$((callers + 1)); }
  fi
  (( callers == 0 )) \
    || halt "a live caller of the privilege boundary exists: sequential COMMIT visibility is NOT safe here"
  ok "no live caller: no sudoers grant, no systemd unit or cron entry naming kyri-exec"
}

# Every prepared file must land on the same filesystem as the pathname it will
# publish at, or link(2) is EXDEV and the whole model collapses into copy.
require_same_filesystem() {
  local row target target_dev prepared_dev
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    target_dev="$(stat -c '%d' "$(dirname "${target}")")"
    prepared_dev="$(stat -c '%d' "$(dirname "${target}${PREPARED_SUFFIX}")")"
    [[ "${target_dev}" == "${prepared_dev}" ]] \
      || halt "prepared object for ${target} would be on device ${prepared_dev}, target is on ${target_dev}"
  done
  ok "every prepared object shares a filesystem with its target (link is possible)"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode gen7 prepared observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; gen7="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # A CREATE has no baseline bytes to retain: its rollback is removal. What it
    # does require is that the pathname is genuinely free. An object here
    # belongs to somebody else and this transaction will not adopt, overwrite,
    # or delete it.
    [[ ! -e "${target}" && ! -L "${target}" ]] \
      || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"

    rm -f "${prepared}"
    materialise_gen7 "${source}" "${prepared}" "${gen7}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen7}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen7}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
  done
  ok "PREPARE complete: five new objects staged, five create-once pathnames reserved"
}

verify_prepared_set() {
  local row target gen7
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen7="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen7}" ]] \
      || halt "prepared object for ${target} does not verify"
  done
  ok "the prepared set verifies against the reviewed commit"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode gen7 prepared index=0 observed owner_now
  journal_write COMMITTING
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"; gen7="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection. Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN7_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run of this transaction.
    # Forward recovery re-enters COMMIT at position 1, and a target that is
    # already Generation 7 has had its prepared object consumed: there is
    # nothing left to link, and republishing is neither possible nor needed.
    # Decided from the target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen7}")" == "GEN7" ]]; then
      PROGRESS["${index}"]="GEN7"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING

    if ! create_once "${prepared}" "${target}"; then
      PROGRESS["${index}"]="CREATE_FAILED"
      journal_write COMMITTING
      rollback "create-once at ${target} failed: an object appeared at a pathname this transaction reserved"
      return 1
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen7}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen7}"
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

    PROGRESS["${index}"]="GEN7"
    journal_write COMMITTING
  done
  journal_write COMMITTED
  OUTCOME="COMMITTED"
  ok "COMMIT complete: five pathnames published and verified"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# Every target is a CREATE, so rollback is removal -- and removal happens only
# when what is there is still exactly what this transaction installed. If the
# bytes, mode, or ownership have moved, the object is somebody else's, and
# deleting somebody else's file to tidy up a failed installation is the one
# thing a rollback must never do.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target mode gen7 observed removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"; gen7="$(field "${row}" 5)"

    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
      continue                                # never published, or already removed
    fi
    if [[ -L "${target}" || ! -f "${target}" ]]; then
      bad "${target} is not the regular file this transaction created; NOT removing it"
      continue
    fi
    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen7}" ]]; then
      bad "${target} is ${observed}, not the Generation-7 object this transaction installed; NOT removing it"
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
    sync_path "${target}"                     # the file is gone; its parent is fsynced
    [[ ! -e "${target}" && ! -L "${target}" ]] \
      || { bad "${target} still exists after removal"; continue; }
    removed=$((removed + 1))
  done

  # Prove the whole set is Generation 6 again before claiming a rollback.
  classify_all
  if (( GEN6_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "ROLLBACK complete: all five pathnames are free again (${removed} removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN6=${GEN6_COUNT} GEN7=${GEN7_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed:
#
#   * every remaining target's PREPARED object verifies to its pinned
#     Generation-7 digest  -> complete FORWARD
#   * otherwise -> roll BACK to a complete Generation 6
#   * unknown bytes anywhere -> fail closed for operator disposition
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN6=%d GEN7=%d UNKNOWN=%d\n' \
    "${state}" "${GEN6_COUNT}" "${GEN7_COUNT}" "${UNKNOWN_COUNT}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither absent nor the Generation-7 object)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN7_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-7 set is already installed"
    return 0
  fi
  if (( GEN6_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no pathname was published; the host is a complete Generation 6"
    return 0
  fi

  # Mixed. Can forward completion be proven from the prepared material?
  local row target gen7 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen7="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen7}")" == "GEN7" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen7}" ]] || { forward=0; break; }
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
# New names. The Generation-6 evidence is never overwritten: it is the record of
# what that gate accepted, and a generation that consumed its own baseline could
# not be audited afterwards.
write_evidence() {
  [[ -f "${GEN6_LIBRARY_EVIDENCE}" && -f "${GEN6_HELPER_EVIDENCE}" ]] \
    || halt "Generation-6 evidence vanished during installation"
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN7_LIBRARY_EVIDENCE}.writing"
  local row target missing=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    case "${target}" in
      "${LIBRARY_ROOT}"/*)
        grep -q "  ${target}\$" "${GEN7_LIBRARY_EVIDENCE}.writing" || missing=$((missing + 1)) ;;
    esac
  done
  (( missing == 0 )) \
    || { rm -f "${GEN7_LIBRARY_EVIDENCE}.writing"; halt "the Generation-7 evidence does not record ${missing} installed objects"; }
  {
    sha256sum "${HELPERS[@]}"
    for row in "${MATRIX[@]}"; do
      target="$(field "${row}" 1)"
      case "${target}" in "${LIBEXEC}"/*) sha256sum "${target}" ;; esac
    done
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN6_COMMIT}"
    printf 'transaction %s\n' "${TRANSACTION_ID}"
  } > "${GEN7_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN7_LIBRARY_EVIDENCE}.writing" "${GEN7_HELPER_EVIDENCE}.writing"
  sync_path "${GEN7_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN7_HELPER_EVIDENCE}.writing"
  mv -f "${GEN7_LIBRARY_EVIDENCE}.writing" "${GEN7_LIBRARY_EVIDENCE}"
  mv -f "${GEN7_HELPER_EVIDENCE}.writing" "${GEN7_HELPER_EVIDENCE}"
  sync_path "${GEN7_LIBRARY_EVIDENCE}"
  sync_path "${GEN7_HELPER_EVIDENCE}"
  ok "Generation-7 evidence written (${EXPECTED_LIBRARY_FILES_GEN7} library objects, five new); Generation-6 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}"
  done
  ok "transaction artefacts removed"
}

# --- installed-set verification -------------------------------------------
#
# Every installed byte is proved against the reviewed commit, not against a
# constant transcribed into this file: the pinned digest and the blob at
# ${COMMIT} must agree, and then the installed object must equal both.
verify_installed_set() {
  local row source target mode gen7 observed owner_now blob
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; gen7="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen7}" ]] \
      || bad "${source} at ${COMMIT} is ${blob}, but this ceremony pins ${gen7}"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen7}" ]] \
      || bad "${target} is ${observed:-absent}, expected the ${COMMIT} bytes ${gen7}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "${mode#0}" ]] || bad "${target} has the wrong mode"
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}" 2>/dev/null)"
      [[ "${owner_now}" == "root:root" ]] || bad "${target} is ${owner_now:-absent}, expected root:root"
    fi
  done
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES_GEN7}" ]] \
    || bad "the library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES_GEN7}"
  (( FAILURES == 0 )) \
    && ok "every installed Generation-7 byte corresponds exactly to ${COMMIT} (${installed} library objects)"
}

# Everything the Generation-6 evidence records is still exactly Generation 6,
# and the three existing /usr/libexec objects are untouched. A count of 47
# cannot say that.
verify_unchanged_surface_after() {
  local line recorded path observed drift=0
  [[ -f "${GEN6_LIBRARY_EVIDENCE}" ]] || { bad "Generation-6 evidence is absent"; return; }
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    recorded="${line%% *}"
    path="${line#* }"; path="${path# }"
    [[ -n "${FIXTURE}" ]] && path="${FIXTURE}${path}"
    observed="$(digest_of "${path}")"
    [[ "${observed}" == "${recorded}" ]] || { bad "Generation-6 runtime object drifted: ${path}"; drift=$((drift + 1)); }
  done < "${GEN6_LIBRARY_EVIDENCE}"
  (( drift == 0 )) && ok "the Generation-6 runtime surface is still exactly Generation 6"
  require_helpers_unchanged
}

# The installed contract, read off the installed bytes rather than the source.
# These are the G6.1 properties an operator is being asked to accept, so they
# are checked where they will actually run.
verify_contract() {
  local verification="${LIBRARY_ROOT}/tools/capability/execution/verification.py"
  local store="${LIBRARY_ROOT}/tools/capability/execution/image_store.py"
  local policy="${LIBRARY_ROOT}/kyri_exec_verify.py"
  local entry="${LIBEXEC}/kyri-exec-verify"
  local verify_worker="${LIBEXEC}/kyri-exec-verify-worker.py"
  local production_worker="${LIBEXEC}/kyri-exec-worker.py"

  # Structural non-execution, read off the installed module's executable text.
  local code
  code="$(code_of "${verification}")" || { bad "the installed verification module does not parse"; return; }
  grep -q 'create_argv' <<<"${code}" && bad "the installed verification module names create_argv"
  grep -q 'snapshot' <<<"${code}" && bad "the installed verification module reaches the snapshot module"
  grep -q 'WORKER_MODE = .verification-only.' <<<"${code}" \
    || bad "the installed verification module does not declare the verification-only mode"
  grep -q 'verify_execution' <<<"${code}" \
    || bad "the installed verification module does not call the shared gate"
  grep -qE 'from \.worker import|from tools\.capability\.execution\.worker import' <<<"${code}" \
    || bad "the installed verification module does not import the shared gate by name"

  # The image store starts no process and consults no container runtime.
  local store_code
  store_code="$(code_of "${store}")" || { bad "the installed image store does not parse"; return; }
  grep -q 'subprocess' <<<"${store_code}" && bad "the installed image store imports subprocess"
  grep -qi 'podman' <<<"${store_code}" && bad "the installed image store names a container runtime"
  grep -q 'overlay-images' <<<"${store_code}" || bad "the installed image store reads no image index"

  # The verification policy is aimed at the verification worker and nothing
  # else, and the entrypoint compiles in that policy module.
  local policy_code entry_code
  policy_code="$(code_of "${policy}")" || { bad "the installed verification policy does not parse"; return; }
  entry_code="$(code_of "${entry}")" || { bad "the installed verification entrypoint does not parse"; return; }
  grep -q "WORKER_SCRIPT = '/usr/libexec/kyri-exec-verify-worker.py'" <<<"${policy_code}" \
    || bad "the installed verification policy does not name the verification worker"
  grep -q "POLICY_MODULE = 'kyri_exec_verify'" <<<"${entry_code}" \
    || bad "the installed verification entrypoint does not compile in the verification policy"
  grep -q 'kyri-exec-worker.py' <<<"${entry_code}" \
    && bad "the installed verification entrypoint names the production worker"
  grep -q 'kyri-exec-worker.py' <<<"${policy_code}" \
    && bad "the installed verification policy names the production worker"
  head -1 "${verify_worker}" | grep -q '^#!' \
    && bad "the installed verification worker carries a shebang"

  # And the production execution path is exactly where it was.
  grep -q 'container execution is gated at G6' "${production_worker}" \
    || bad "the installed production worker no longer refuses: G6 may have been opened"

  (( FAILURES == 0 )) \
    && ok "installed contract: verification-only mode, the shared gate, no create_argv, no snapshot, no subprocess, production still gated"
}

# The strongest available proof that the installed bytes cannot reach
# execution: import them, in isolation, and observe what the interpreter loaded.
#
# `env -i` with `-I -B` drops PYTHONPATH, PYTHONHOME, the current directory and
# bytecode writing, so the only import root is the one named here. Importing the
# verification module executes no container and creates nothing -- that is the
# property being measured.
verify_import_boundary() {
  [[ -n "${FIXTURE}" ]] && { note "import boundary not exercised in fixture mode"; return; }
  local resolved policy_file verification_file store_file loaded bound path
  resolved="$(cd / && env -i /usr/bin/python3 -I -B -c "
import sys
sys.path.insert(0, '${LIBRARY_ROOT}')
import kyri_exec_verify as p
from tools.capability.execution import verification as v
from tools.capability.execution import image_store as s
loaded = 'tools.capability.execution.snapshot' in sys.modules
bound = hasattr(v, 'create_argv') or hasattr(v, 'worker')
print(p.__file__, v.__file__, s.__file__, loaded, bound)
")" || { bad "the installed verification library is not importable"; return; }

  # Read as five fields rather than matched as one glob: the two booleans carry
  # the whole non-execution result, and a pattern that can match either of them
  # in either position is a pattern that can report the wrong one.
  read -r policy_file verification_file store_file loaded bound <<<"${resolved}"
  for path in "${policy_file}" "${verification_file}" "${store_file}"; do
    case "${path}" in
      "${LIBRARY_ROOT}"/*) ;;
      *) bad "an installed module resolved outside ${LIBRARY_ROOT}: ${path}" ;;
    esac
  done
  [[ "${loaded}" == "False" ]] \
    || bad "importing the installed verification module loaded the snapshot module"
  [[ "${bound}" == "False" ]] \
    || bad "the installed verification module binds create_argv or the worker module"
  (( FAILURES == 0 )) \
    && ok "policy, verification and image store resolve inside ${LIBRARY_ROOT}; snapshot unloaded, create_argv unbound"
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
TRANSACTION_ID="gen7-${COMMIT:0:12}"

printf '== Generation 7 / G6.1A (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  # Read-only. Proves this is a valid Generation-6 host and that the
  # transaction is ready. It does NOT check the installed tree for
  # Generation-7 content -- that is what --verify-installed is for.
  require_repository
  require_source_digests
  require_gen6_baseline
  require_no_extra_delta
  require_gates_closed
  require_no_live_caller
  require_same_filesystem

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  if (( GEN6_COUNT == ${#MATRIX[@]} )); then
    ok "all five pathnames are free: the host is ready for the G6.1A installation"
  elif (( GEN7_COUNT == ${#MATRIX[@]} )); then
    note "all five objects are already installed"
  else
    bad "mixed or unknown target state: GEN6=${GEN6_COUNT} GEN7=${GEN7_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
  fi
  require_authority_untouched
  ;;

--verify-installed)
  require_repository
  verify_installed_set
  verify_unchanged_surface_after
  verify_contract
  verify_import_boundary
  require_no_extra_delta
  require_gates_closed
  require_no_transaction_residue
  require_authority_untouched
  ;;

--recover|--install)
  [[ "$(id -u)" -eq 0 || -n "${FIXTURE}" ]] || halt "installation requires root"
  require_repository
  require_source_digests
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  journal_load_progress
  # Recorded before anything is staged, so "untouched" is measured across the
  # whole transaction rather than across the verification that follows it.
  AUTHORITY_STATE_BEFORE="$(authority_state)"

  if [[ "${state}" != "NONE" && "${state}" != "ROLLED_BACK" && "${state}" != "COMMITTED" ]]; then
    # A stale or incomplete journal never becomes a fresh installation.
    note "existing journal in state ${state}: entering recovery"
    recover "${state}" || halt "recovery did not reach a single complete generation"
  elif [[ "${MODE}" == "--recover" ]]; then
    classify_all
    if (( UNKNOWN_COUNT > 0 )); then
      halt "unknown bytes present and no transaction journal to recover from"
    fi
    ok "nothing to recover: GEN6=${GEN6_COUNT} GEN7=${GEN7_COUNT}"
  else
    # Asked from the targets' actual bytes before anything else, because an
    # already-installed host is not a Generation-6 host and checking the
    # Generation-6 baseline first would refuse a rerun for a library count that
    # is correct. A rerun is a no-op, not a second transaction.
    classify_all
    if (( GEN7_COUNT == ${#MATRIX[@]} )); then
      OUTCOME="COMMITTED"
      ok "Generation 7 is already installed; nothing to do"
    else
      require_gen6_baseline
      require_no_extra_delta
      require_gates_closed
      require_no_live_caller
      require_same_filesystem
      (( UNKNOWN_COUNT == 0 )) || halt "unknown bytes at a target: refusing to start a transaction"
      (( GEN6_COUNT == ${#MATRIX[@]} )) || halt "not a clean Generation-6 baseline: refusing to start"
      prepare
      verify_prepared_set
      journal_write PREPARED
      commit_targets || halt "installation failed and was rolled back; the host is Generation 6"
    fi
  fi

  # A rollback is a correct, complete outcome -- it is simply not Generation 7.
  # Verifying the Generation-7 set here would report the absent objects as five
  # digest failures and bury what actually happened.
  if [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    printf '\n'
    printf 'Generation 7 was NOT installed.\n'
    printf 'The host is a complete, verified Generation 6 and no evidence was written.\n'
    printf 'The transaction journal is at %s.\n' "${JOURNAL}"
    exit 1
  fi

  # Only now, and only if everything above held.
  verify_installed_set
  verify_unchanged_surface_after
  verify_contract
  verify_import_boundary
  require_no_extra_delta
  require_gates_closed
  require_authority_untouched
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
  printf 'Generation 7 / G6.1A %s: all checks passed.\n' "${MODE#--}"
  printf 'No sudoers policy was written, no transition was invoked, no worker was\n'
  printf 'executed, no container runtime was contacted, no implementation authority\n'
  printf 'was mutated, and no identifier was allocated. G6.1B -- the grant and the\n'
  printf 'first live crossing -- is a separate ceremony and has not run.\n'
else
  printf 'Generation 7 / G6.1A %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
