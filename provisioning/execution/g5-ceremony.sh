#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 G5 operator ceremony: production image build and CIMP admission.
#
# NOTHING HERE HAS BEEN EXECUTED AGAINST PRODUCTION. Every mutation phase
# refuses until its own preconditions hold, and no phase runs the next one.
#
# =============================================================================
# HOW ROOT COMES TO TRUST WHAT IT EXECUTES
# =============================================================================
# The provisioning modules live in a checkout owned by the coordinator. Root
# executing them from there would mean the coordinator chooses the constants
# that get committed verbatim into an admission record -- ADAPTER_IDENTITY,
# ARGV_CONTRACT_IDENTITY, both schema versions, CONTAINER_INTERPRETER -- which
# is precisely the property "governed values are derived, never supplied"
# exists to guarantee. So root never imports the working tree.
#
#   reviewed git object -> root-owned staging -> verified manifest -> isolated
#   python
#
# Materialisation is per-file from `git cat-file blob`, NOT `git archive`.
# Inspection decided this: `git archive` applies the `text`/`eol` attributes
# recorded in the archived tree, so its output is a filtered rendering rather
# than the blob, and it emits whatever members the tree happens to carry. Blob
# extraction driven by an explicit manifest has neither property -- it cannot
# emit an unexpected member, cannot traverse a path, and cannot rewrite a byte.
#
# Git runs AS THE REPOSITORY OWNER, never as root. A git invocation reads the
# repository's own `.git/config`, and configuration can name programs to run;
# root running git inside a directory the coordinator controls would execute
# coordinator-chosen code before any boundary exists. The coordinator running
# git against the coordinator's own repository escalates nothing, and root
# treats everything it produces as untrusted input: bytes land in a root-owned
# 0700 directory the coordinator cannot enter, and every one is verified
# against the pinned manifest digest before a line of Python runs.
#
# WHAT COORDINATOR-CONTROLLED BYTES ROOT EXECUTES BEFORE THE BOUNDARY: exactly
# this script, and only after the operator has verified its SHA-256 against the
# reviewed value **in root-owned space**. See --bootstrap-instructions. This
# script sources nothing, reads no configuration file, and uses absolute paths
# for every trust-critical binary.
#
# =============================================================================
# USAGE
# =============================================================================
# Read-only:
#   --bootstrap-instructions        how to get this script into root-owned
#                                   space and verify it before running it
#   --verify-host                   the ruled G5 starting position
#   --verify-source                 the reviewed operator source, unexecuted
#   --verify-build-inputs           image definition and base approval
#   --verify-authority-prerequisites the two namespace roots, before creation
#   --verify-materialisation        prove the trust boundary end to end
#   --verify-build-context          may the build context be materialised here?
#   --verify-materialised-build-context  is the published context exactly right?
#   --print-production-build        the build command, executable as-is
#   --print-plan                    the exact mutation sequence, not executed
#
# Mutation of /run only (no Podman, no authority, no image):
#   --materialise-build-context     publish the reviewed context for the
#                                   execution identity to build from
#
# Mutation (each refuses unless its own preconditions hold; none chains):
#   --bootstrap-authority           create the roots and counters
#   --genesis                       publish CGEN-000000000000
#   --admit                         admit one production CIMP
#
# Test-only:
#   --fixture DIR   operate on a fixture tree. Owner enforcement relaxed;
#                   manifest, isolation, and refusal logic are production paths.
#   --commit SHA    the reviewed commit to materialise (required, 40 hex).

REPOSITORY="/opt/schott-platform"
BRANCH="arch/eng-0005-execution-transition"

# The canonical manifest of the operator package: every .py under tools/ that
# the ceremony may import, as `sha256  path` lines, LC_ALL=C sorted. This digest
# is the gate. The commit is supplied by the operator and checked for ancestry,
# but the commit is a name and this is the content.
MANIFEST_DIGEST="b1dd70973c1b4abddd9bab556647ec7c5088fb0f94954822ae142c3767542560"
MANIFEST_ENTRIES=46

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
KYRI_STATE="/var/lib/kyri"
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"
SUDOERS="/etc/sudoers.d/kyri-exec"
CEREMONY_ROOT="/root/kyri-g5-ceremony"
BASE_APPROVAL="/root/kyri-g5-approved-base.txt"

# Ruled identities and modes. §5.7 as amended by the setgid ruling.
EXECUTION_USER="kyri-capability"
EXECUTION_GROUP="kyri-capability"
EXECUTION_UID=999
EXECUTION_GID=987
EXECUTION_HOME="/data/kyri/capability"
EXECUTION_RUNTIME_DIR="/run/user/999"
COORDINATOR="cschott"
AUTHORITY_DIR_MODE="2750"
AUTHORITY_RECORD_MODE="440"
CONTROL_DIR_MODE="700"
STAGING_DIR_MODE="2750"

# --- the production build context ------------------------------------------
#
# WHY IT EXISTS. The first production build named the checkout as both
# --file and context and failed before Podman started:
#
#   cannot chdir to /opt/schott-platform: Permission denied
#
# /opt/schott-platform is cschott:cschott 0750. kyri-capability is in neither
# the owner nor the group, so it has no traverse bit -- which is the authority
# split working, not a misconfiguration. The fix is to give the execution
# identity a build context it CAN read, on ancestry the coordinator cannot
# touch, containing exactly the reviewed bytes.
#
# /run/kyri is root:root 0755: the coordinator cannot create, rename, or unlink
# anything inside it, and it is tmpfs, so a build context is ephemeral ceremony
# material that costs nothing to lose. It sits beside execution-material and
# never inside it.
BUILD_CONTEXT="/run/kyri/g5-build-context"
BUILD_CONTEXT_STAGING="/run/kyri/.g5-build-context.staging"
BUILD_CONTEXT_PARENT="/run/kyri"
SNAPSHOT_ROOT="/run/kyri/execution-material"
BUILD_CONTEXT_DIR_MODE="550"
BUILD_TAG="kyri-capability-execution:g5"

# Every member of the context, and nothing else. Extra or missing refuses.
#
# ONE FILE, deliberately. The Containerfile carries no COPY and no ADD, so
# nothing in the context can reach the built image; a README alongside it would
# be bytes to verify that cannot affect the result. If the definition ever
# gains a COPY, this manifest is wrong and --verify-build-context says so
# rather than quietly building from a context missing its inputs.
#
#   relative-path | repository-path | sha256 | mode
BUILD_CONTEXT_MEMBERS=(
"Containerfile|provisioning/image/Containerfile|f543c458fcb1793570010b58417c175e6510fe0d90d2a295ef9d38b0cfdedcbb|0440"
)

BASE_REPOSITORY="cgr.dev/chainguard/python"
GOVERNED_PYTHON="3.14.6"
CONTAINERFILE="provisioning/image/Containerfile"

MODE=""
FIXTURE=""
COMMIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-instructions|--verify-host|--verify-source|--verify-build-inputs|\
--verify-authority-prerequisites|--verify-materialisation|--print-plan|\
--verify-build-context|--materialise-build-context|\
--verify-materialised-build-context|--print-production-build|\
--bootstrap-authority|--genesis|--admit)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    --commit)
      COMMIT="${2:-}"; shift 2
      [[ "${COMMIT}" =~ ^[0-9a-f]{40}$ ]] || { printf 'ERROR --commit needs a full 40-character object id\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify-host}"

if [[ -n "${FIXTURE}" ]]; then
  LIBRARY_ROOT="${FIXTURE}${LIBRARY_ROOT}"
  LIBEXEC="${FIXTURE}${LIBEXEC}"
  KYRI_STATE="${FIXTURE}${KYRI_STATE}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  CEREMONY_ROOT="${FIXTURE}${CEREMONY_ROOT}"
  BASE_APPROVAL="${FIXTURE}${BASE_APPROVAL}"
  BUILD_CONTEXT="${FIXTURE}${BUILD_CONTEXT}"
  BUILD_CONTEXT_STAGING="${FIXTURE}${BUILD_CONTEXT_STAGING}"
  BUILD_CONTEXT_PARENT="${FIXTURE}${BUILD_CONTEXT_PARENT}"
  SNAPSHOT_ROOT="${FIXTURE}${SNAPSHOT_ROOT}"
fi

FAILURES=0
ok()    { printf 'ok       %s\n' "$1"; }
note()  { printf 'note     %s\n' "$1"; }
bad()   { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt()  { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

REPO_OWNER="$(stat -c '%U' "${REPOSITORY}" 2>/dev/null || printf 'root')"

# Git, always as the repository owner and never as root. See the header.
git_as_owner() {
  if [[ "$(id -un)" == "${REPO_OWNER}" ]]; then
    /usr/bin/git -C "${REPOSITORY}" "$@"
  else
    /usr/sbin/runuser -u "${REPO_OWNER}" -- /usr/bin/git -C "${REPOSITORY}" "$@"
  fi
}

require_commit() {
  [[ -n "${COMMIT}" ]] || halt "this mode requires --commit <40-hex>: the ceremony pins a reviewed commit and never trusts HEAD"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} does not exist in ${REPOSITORY}"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  local residue
  residue="$(git_as_owner status --porcelain --untracked-files=all)"
  if [[ -n "${residue}" ]]; then
    # Operator provenance: a dirty tree does not change what gets materialised
    # -- that comes from git objects -- but it means the checkout in front of
    # the operator is not the thing that was reviewed.
    [[ -n "${FIXTURE}" ]] || halt "the working tree is not clean:"$'\n'"${residue}"
    note "the working tree is not clean; permitted in fixture mode only"
  fi
  ok "reviewed commit ${COMMIT} exists, is an ancestor of HEAD, on ${BRANCH}, tree checked (as ${REPO_OWNER})"
}

# --- the manifest ----------------------------------------------------------
#
# Built from git objects, canonicalised, and gated on one pinned digest. The
# file LIST comes from the pinned commit's tree, so a substituted list changes
# the manifest and fails here rather than later.
build_manifest() {
  local path digest
  git_as_owner ls-tree -r --name-only "${COMMIT}" \
      -- tools/__init__.py tools/capability tools/common tools/provisioning \
    | grep '\.py$' | grep -v '__pycache__' | LC_ALL=C sort \
    | while IFS= read -r path; do
        digest="$(git_as_owner cat-file blob "${COMMIT}:${path}" | sha256sum | cut -d' ' -f1)"
        printf '%s  %s\n' "${digest}" "${path}"
      done
}

# Refuse a path that is anything other than an ordinary relative source file.
# Path traversal, absolute paths, and anything outside tools/ never reach a
# filesystem call.
safe_manifest_path() {
  local path="$1"
  [[ "${path}" == tools/* ]] || return 1
  [[ "${path}" == *.py ]] || return 1
  [[ "${path}" != *".."* ]] || return 1
  [[ "${path}" != /* ]] || return 1
  [[ "${path}" != *$'\n'* ]] || return 1
  [[ "${path}" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
  return 0
}

# --- materialisation -------------------------------------------------------
MATERIALISED=""

materialise() {
  require_commit
  local manifest observed
  manifest="$(build_manifest)"
  observed="$(printf '%s\n' "${manifest}" | sha256sum | cut -d' ' -f1)"
  [[ "${observed}" == "${MANIFEST_DIGEST}" ]] \
    || halt "the operator-package manifest at ${COMMIT} is ${observed}, expected ${MANIFEST_DIGEST}"
  local count
  count="$(printf '%s\n' "${manifest}" | grep -c .)"
  [[ "${count}" -eq "${MANIFEST_ENTRIES}" ]] \
    || halt "the manifest holds ${count} entries, expected ${MANIFEST_ENTRIES}"
  ok "the operator-package manifest matches the pinned digest (${count} objects at ${COMMIT})"

  local staging="${CEREMONY_ROOT}-${COMMIT:0:12}"
  [[ ! -e "${staging}" ]] \
    || halt "${staging} already exists; a previous ceremony did not clean up and its material is not adopted"
  # Every directory created below inherits this, so package subdirectories are
  # 0700 rather than whatever the invoking account's umask happens to be. A
  # umask of 002 would otherwise leave the tree group-writable, which is the
  # one property the whole boundary depends on.
  umask 077
  mkdir -p "$(dirname "${staging}")"
  mkdir -m 0700 "${staging}"
  if [[ -z "${FIXTURE}" ]]; then
    chown root:root "${staging}"
    chmod 0700 "${staging}"
  fi

  local line digest path destination
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    digest="${line%% *}"; path="${line#* }"; path="${path# }"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || halt "unparseable manifest line: ${line}"
    safe_manifest_path "${path}" \
      || halt "the manifest names an unacceptable path and nothing was written: ${path}"
    destination="${staging}/${path}"
    mkdir -p "$(dirname "${destination}")"
    [[ ! -e "${destination}" ]] || halt "duplicate manifest entry: ${path}"
    git_as_owner cat-file blob "${COMMIT}:${path}" > "${destination}"
    chmod 0400 "${destination}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${destination}"
    fi
  done <<<"${manifest}"

  # Verified AFTER the bytes are in root-owned 0700 space, not before it. The
  # coordinator cannot reach inside to change one afterwards, so what was
  # verified is what will be imported.
  local verified=0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    digest="${line%% *}"; path="${line#* }"; path="${path# }"
    [[ "$(digest_of "${staging}/${path}")" == "${digest}" ]] \
      || halt "materialised ${path} does not match the manifest"
    verified=$((verified + 1))
  done <<<"${manifest}"
  [[ "${verified}" -eq "${MANIFEST_ENTRIES}" ]] || halt "only ${verified} objects verified"

  # Nothing but directories and regular files, and nothing group- or
  # other-writable. A symlink here would let a later import escape the tree.
  local irregular writable
  irregular="$(find "${staging}" ! -type d ! -type f | head -5 || true)"
  [[ -z "${irregular}" ]] || halt "the materialised tree carries non-regular objects:"$'\n'"${irregular}"
  writable="$(find "${staging}" -perm /022 | head -5 || true)"
  [[ -z "${writable}" ]] || halt "the materialised tree is group- or other-writable:"$'\n'"${writable}"
  local strays
  strays="$(find "${staging}" -name '__pycache__' -o -name '*.pyc' | head -5 || true)"
  [[ -z "${strays}" ]] || halt "the materialised tree carries bytecode"

  # An independent anchor that does not involve the repository at all: the
  # runtime half of the package must equal the root-owned installed runtime.
  local drift=0 file
  while IFS= read -r file; do
    [[ -f "${LIBRARY_ROOT}/${file}" ]] || { bad "installed runtime lacks ${file}"; drift=$((drift + 1)); continue; }
    [[ "$(digest_of "${staging}/${file}")" == "$(digest_of "${LIBRARY_ROOT}/${file}")" ]] \
      || { bad "materialised ${file} differs from the installed runtime"; drift=$((drift + 1)); }
  done < <(cd "${staging}" && find tools -type f -name '*.py' ! -path 'tools/provisioning/*' | LC_ALL=C sort)
  (( drift == 0 )) || halt "${drift} materialised runtime objects differ from the installed runtime"

  MATERIALISED="${staging}"
  ok "materialised ${verified} objects into ${staging} (0700, root-owned, no symlinks, no bytecode)"
  ok "the materialised runtime half is byte-identical to ${LIBRARY_ROOT}"
}

discard_materialised() {
  [[ -n "${MATERIALISED}" && -d "${MATERIALISED}" ]] || return 0
  chmod -R u+w "${MATERIALISED}"
  rm -rf "${MATERIALISED}"
  ok "the root-owned ceremony tree was removed"
  MATERIALISED=""
}

# Run one Python program with the materialised tree as the ONLY import root.
#
# `env -i` drops PYTHONPATH, PYTHONHOME, PYTHONSTARTUP and everything else the
# coordinator's environment could carry. `-I` additionally ignores them even if
# something reintroduced one, keeps the user site directory out, and -- since
# 3.11 -- keeps the working directory off sys.path. `-B` writes no bytecode,
# and the tree contains none to read.
run_materialised() {
  local program="$1"; shift
  [[ -n "${MATERIALISED}" ]] || halt "no materialised tree"
  ( cd / && /usr/bin/env -i \
      PATH=/usr/bin:/bin \
      PYTHONDONTWRITEBYTECODE=1 \
      /usr/bin/python3 -I -B -c "${program}" "${MATERIALISED}" "$@" )
}

# --- the production build context ------------------------------------------
context_member() { IFS='|' read -r -a _m <<<"$1"; printf '%s' "${_m[$2]}"; }

# The Containerfile must still carry no COPY and no ADD, or a one-member
# context is no longer the whole context.
require_context_is_complete() {
  local body
  body="$(git_as_owner cat-file blob "${COMMIT}:provisioning/image/Containerfile")"
  if grep -qE '^[[:space:]]*(COPY|ADD)[[:space:]]' <<<"${body}"; then
    halt "the Containerfile at ${COMMIT} carries COPY or ADD: the one-member build-context manifest is incomplete and must be re-derived"
  fi
  ok "the image definition copies nothing in: the Containerfile is the whole context"
}

# The invariant whose violation caused the live failure, asserted the other way
# round: the checkout must REMAIN untraversable by anyone but the coordinator.
require_checkout_stays_private() {
  local mode
  mode="$(stat -c '%a' "${REPOSITORY}" 2>/dev/null)"
  [[ -n "${mode}" ]] || { bad "cannot stat ${REPOSITORY}"; return; }
  # Other must have no execute bit. If it ever gains one, somebody "fixed" the
  # build failure by opening the checkout to the execution identity.
  if (( (8#${mode} & 8#0001) != 0 )); then
    bad "${REPOSITORY} is mode ${mode}: world-traversable, so the execution identity can reach the checkout"
  else
    ok "${REPOSITORY} is mode ${mode}: the execution identity still cannot traverse the checkout"
  fi
}

classify_build_context() {
  if [[ -L "${BUILD_CONTEXT}" ]]; then printf 'CONFLICT symlink'; return; fi
  if [[ ! -e "${BUILD_CONTEXT}" ]]; then printf 'ABSENT'; return; fi
  if [[ ! -d "${BUILD_CONTEXT}" ]]; then printf 'CONFLICT not-a-directory'; return; fi
  printf 'PRESENT'
}

verify_build_context() {
  require_commit
  require_context_is_complete
  require_checkout_stays_private

  local row source expected observed
  for row in "${BUILD_CONTEXT_MEMBERS[@]}"; do
    source="$(context_member "${row}" 1)"; expected="$(context_member "${row}" 2)"
    observed="$(git_as_owner cat-file blob "${COMMIT}:${source}" | sha256sum | cut -d' ' -f1)"
    [[ "${observed}" == "${expected}" ]] \
      || bad "${source} at ${COMMIT} is ${observed}, expected the reviewed ${expected}"
  done
  (( FAILURES == 0 )) \
    && ok "every context member matches its pinned digest at ${COMMIT} (${#BUILD_CONTEXT_MEMBERS[@]} objects)"

  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${BUILD_CONTEXT_PARENT}" 2>/dev/null)" == "root:root 755" ]] \
      || bad "${BUILD_CONTEXT_PARENT} is not root:root 0755: the coordinator could rename the context"
    id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n' | grep -qx "${EXECUTION_GROUP}" \
      && bad "${COORDINATOR} is a member of ${EXECUTION_GROUP}"
  fi

  [[ ! -e "${BUILD_CONTEXT_STAGING}" ]] \
    || halt "${BUILD_CONTEXT_STAGING} exists: an earlier materialisation was interrupted and its material is not adopted; an operator disposes of it"

  case "$(classify_build_context)" in
    ABSENT)  ok "${BUILD_CONTEXT} is absent: eligible to materialise" ;;
    PRESENT) note "${BUILD_CONTEXT} already exists; --verify-materialised-build-context decides whether it is the reviewed one" ;;
    *) halt "${BUILD_CONTEXT} exists and is not a directory; nothing was changed" ;;
  esac
}

materialise_build_context() {
  [[ "$(id -u)" -eq 0 || -n "${FIXTURE}" ]] || halt "materialising the build context requires root"
  verify_build_context
  (( FAILURES == 0 )) || halt "the build context is not eligible"
  [[ "$(classify_build_context)" == "ABSENT" ]] \
    || halt "${BUILD_CONTEXT} already exists; create-once, and an existing context is disposed of by an operator rather than replaced here"

  # Same filesystem as the published name, because publication is a rename.
  umask 077
  mkdir -m 0700 "${BUILD_CONTEXT_STAGING}"
  local row relative source expected mode destination observed
  for row in "${BUILD_CONTEXT_MEMBERS[@]}"; do
    relative="$(context_member "${row}" 0)"; source="$(context_member "${row}" 1)"
    expected="$(context_member "${row}" 2)"; mode="$(context_member "${row}" 3)"
    [[ "${relative}" =~ ^[A-Za-z0-9_.-]+$ && "${relative}" != *".."* ]] \
      || halt "the manifest names an unacceptable member and nothing was written: ${relative}"
    destination="${BUILD_CONTEXT_STAGING}/${relative}"
    # Bytes come from the git object, read as the repository owner. Root never
    # runs git inside a directory the coordinator controls, and never reads a
    # working-tree file.
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${destination}"
    observed="$(digest_of "${destination}")"
    [[ "${observed}" == "${expected}" ]] \
      || halt "materialised ${relative} is ${observed}, expected ${expected}"
    chmod "${mode}" "${destination}"
    [[ -n "${FIXTURE}" ]] || chown "root:${EXECUTION_GROUP}" "${destination}"
  done

  # Nothing but the manifest, and nothing but regular files.
  local extra
  extra="$(find "${BUILD_CONTEXT_STAGING}" -mindepth 1 ! -type f | head -3 || true)"
  [[ -z "${extra}" ]] || halt "the staged context carries non-regular objects:"$'\n'"${extra}"
  local staged
  staged="$(find "${BUILD_CONTEXT_STAGING}" -mindepth 1 | wc -l)"
  [[ "${staged}" -eq "${#BUILD_CONTEXT_MEMBERS[@]}" ]] \
    || halt "the staged context holds ${staged} entries, expected ${#BUILD_CONTEXT_MEMBERS[@]}"

  # Ownership and mode are final BEFORE publication, so the published name is
  # never briefly wrong and nothing is chowned after it is visible.
  chmod "0${BUILD_CONTEXT_DIR_MODE}" "${BUILD_CONTEXT_STAGING}"
  [[ -n "${FIXTURE}" ]] || chown "root:${EXECUTION_GROUP}" "${BUILD_CONTEXT_STAGING}"
  mv -T "${BUILD_CONTEXT_STAGING}" "${BUILD_CONTEXT}"
  ok "build context published at ${BUILD_CONTEXT}"
  verify_materialised_build_context
}

verify_materialised_build_context() {
  [[ -d "${BUILD_CONTEXT}" && ! -L "${BUILD_CONTEXT}" ]] \
    || { bad "${BUILD_CONTEXT} is not a directory"; return; }
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${BUILD_CONTEXT}")" == "root:${EXECUTION_GROUP} ${BUILD_CONTEXT_DIR_MODE}" ]] \
      || bad "${BUILD_CONTEXT} is $(stat -c '%U:%G %a' "${BUILD_CONTEXT}"), expected root:${EXECUTION_GROUP} 0${BUILD_CONTEXT_DIR_MODE}"
  else
    [[ "$(stat -c '%a' "${BUILD_CONTEXT}")" == "${BUILD_CONTEXT_DIR_MODE}" ]] \
      || bad "${BUILD_CONTEXT} is mode $(stat -c '%a' "${BUILD_CONTEXT}"), expected 0${BUILD_CONTEXT_DIR_MODE}"
  fi

  local row relative expected mode observed present
  for row in "${BUILD_CONTEXT_MEMBERS[@]}"; do
    relative="$(context_member "${row}" 0)"; expected="$(context_member "${row}" 2)"
    mode="$(context_member "${row}" 3)"
    observed="$(digest_of "${BUILD_CONTEXT}/${relative}")"
    [[ "${observed}" == "${expected}" ]] \
      || bad "${relative} is ${observed:-absent}, expected ${expected}"
    [[ "$(stat -c '%a' "${BUILD_CONTEXT}/${relative}" 2>/dev/null)" == "${mode#0}" ]] \
      || bad "${relative} has the wrong mode"
    if [[ -z "${FIXTURE}" ]]; then
      [[ "$(stat -c '%U:%G' "${BUILD_CONTEXT}/${relative}" 2>/dev/null)" == "root:${EXECUTION_GROUP}" ]] \
        || bad "${relative} is not root:${EXECUTION_GROUP}"
    fi
  done

  present="$(find "${BUILD_CONTEXT}" -mindepth 1 | wc -l)"
  [[ "${present}" -eq "${#BUILD_CONTEXT_MEMBERS[@]}" ]] \
    || bad "${BUILD_CONTEXT} holds ${present} entries, expected exactly ${#BUILD_CONTEXT_MEMBERS[@]}"
  local irregular
  irregular="$(find "${BUILD_CONTEXT}" -mindepth 1 ! -type f | head -3 || true)"
  [[ -z "${irregular}" ]] || bad "${BUILD_CONTEXT} carries non-regular objects:"$'\n'"${irregular}"
  local writable
  writable="$(find "${BUILD_CONTEXT}" -perm /022 | head -3 || true)"
  [[ -z "${writable}" ]] || bad "${BUILD_CONTEXT} is group- or other-writable:"$'\n'"${writable}"

  # The ancestry is the authority. Modes on the context cannot protect it if
  # the coordinator can rename the directory out from under the build.
  if [[ -z "${FIXTURE}" ]]; then
    local walk="${BUILD_CONTEXT}" owner
    while :; do
      walk="$(dirname "${walk}")"
      [[ "${walk}" != "/" ]] || break
      owner="$(stat -c '%U:%G %a' "${walk}")"
      [[ "${owner}" == "root:root 755" ]] \
        || bad "ancestor ${walk} is ${owner}, expected root:root 0755"
    done
    ok "ancestry root-owned and not coordinator-writable: the context cannot be renamed or replaced"
    # The sibling this ceremony must not disturb.
    [[ ! -e "${SNAPSHOT_ROOT}" ]] \
      || [[ "$(stat -c '%U:%G %a' "${SNAPSHOT_ROOT}")" == "root:${EXECUTION_GROUP} 770" ]] \
      || bad "${SNAPSHOT_ROOT} changed while the build context was published"
  fi
  [[ ! -e "${BUILD_CONTEXT_STAGING}" ]] || bad "${BUILD_CONTEXT_STAGING} residue remains"
  (( FAILURES == 0 )) \
    && ok "the published build context is exactly the reviewed one, readable by ${EXECUTION_USER} and writable by nobody"
}

print_production_build() {
  local reference="<APPROVED base_image_reference>"
  if [[ -r "${BASE_APPROVAL}" ]]; then
    reference="$(grep -E '^base_image_reference=' "${BASE_APPROVAL}" | head -1 | cut -d= -f2- || true)"
    [[ -n "${reference}" ]] || reference="<APPROVED base_image_reference>"
  fi
  cat <<BUILD
The production build. It runs as ${EXECUTION_USER}, from a cwd that identity
can traverse, against a context root owns.

  cd /tmp

  sudo runuser -u ${EXECUTION_USER} -- env \\
      HOME=${EXECUTION_HOME} XDG_RUNTIME_DIR=${EXECUTION_RUNTIME_DIR} \\
      podman build \\
        --build-arg BASE_IMAGE=${reference} \\
        --file ${BUILD_CONTEXT}/Containerfile \\
        --tag ${BUILD_TAG} \\
        ${BUILD_CONTEXT}

  # Then the immutable local identity, bare 64 lowercase hex.
  sudo runuser -u ${EXECUTION_USER} -- env \\
      HOME=${EXECUTION_HOME} XDG_RUNTIME_DIR=${EXECUTION_RUNTIME_DIR} \\
      podman image inspect --format '{{.Id}}' ${BUILD_TAG}

WHY \`cd /tmp\`: runuser inherits the caller's working directory, and the
caller is standing in the checkout. That is what failed the first time --
"cannot chdir to ${REPOSITORY}: Permission denied" -- before Podman ran at all.
The execution identity cannot traverse the checkout, by design, and nothing
about that is being relaxed.

TRACK-B RESIDUE. The store holds historical Alpine artefacts. They are not
removed and they grant nothing: selection is by the exact local .Id captured
above, and an image that resolves to no admitted CIMP is not authorised no
matter how long it has been sitting there.

BUILDING IS NOT ADMITTING. After this, inspect the ID, the SBOM, and the
interpreter, then stop for review. Authority bootstrap, genesis, and admission
are later phases and none of them runs from here.
BUILD
}

# --- read-only phases ------------------------------------------------------
verify_host() {
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' 2>/dev/null | wc -l)"
  [[ "${installed}" -eq 44 ]] || bad "the installed library holds ${installed} .py files, expected 44"
  [[ ! -e "${SUDOERS}" ]] || bad "${SUDOERS} exists: G3 is not closed and G5 must not depend on it"
  [[ ! -e "${AUTHORITY_ROOT}" ]] || bad "${AUTHORITY_ROOT} already exists"
  [[ ! -e "${CONTROL_ROOT}" ]] || bad "${CONTROL_ROOT} already exists"
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${KYRI_STATE}" 2>/dev/null)" == "root:root 711" ]] \
      || bad "${KYRI_STATE} is not root:root 0711"
  fi
  local unit
  unit="$(grep -rl 'kyri-exec' /etc/systemd/system /lib/systemd/system /etc/cron.d /etc/crontab 2>/dev/null || true)"
  [[ -z "${unit}" || -n "${FIXTURE}" ]] || bad "a systemd or cron entry references kyri-exec"
  (( FAILURES == 0 )) && ok "the host is at the ruled G5 starting position: generation 6, no authority state, gates closed"
}

verify_source() {
  materialise
  # The bytes root would import, proven not to come from the working tree.
  run_materialised '
import hashlib, os, sys
root = sys.argv[1]
sys.path.insert(0, root)
import tools.provisioning.authority_bootstrap as b
import tools.provisioning.authority_admission as a
import tools.provisioning.provisioning_evidence as e
from tools.capability.execution import worker
for module in (b, a, e, worker):
    assert module.__file__.startswith(root + os.sep), (module.__name__, module.__file__)
print("      import root:", root)
print("      authority_bootstrap:", b.__file__)
assert e.GOVERNED_PYTHON_VERSION == sys.argv[2], (e.GOVERNED_PYTHON_VERSION, sys.argv[2])
print("      governed python:", e.GOVERNED_PYTHON_VERSION)
print("      container interpreter:", worker.CONTAINER_INTERPRETER)
' "${GOVERNED_PYTHON}" || halt "the materialised operator package is not importable in isolation"
  ok "every operator module resolves inside the root-owned tree, never in the checkout"
  discard_materialised
}

verify_build_inputs() {
  local containerfile="${REPOSITORY}/${CONTAINERFILE}"
  [[ -f "${containerfile}" ]] || halt "${CONTAINERFILE} is absent"
  grep -qE '^ARG BASE_IMAGE$' "${containerfile}" \
    || bad "the Containerfile does not declare BASE_IMAGE without a default"
  grep -qE '^ARG BASE_IMAGE=' "${containerfile}" && bad "the Containerfile gives BASE_IMAGE a default"
  grep -qE '^FROM \$\{BASE_IMAGE\}$' "${containerfile}" \
    || bad "the Containerfile does not build FROM the supplied argument"
  ok "the image definition names no base and cannot pin a floating tag"

  # The approved base is an operator-reviewed INPUT, recorded before the build
  # becomes eligible. It is never derived from a build result, and discovery
  # output is a candidate rather than an approval.
  if [[ ! -e "${BASE_APPROVAL}" ]]; then
    note "no approved base image is recorded at ${BASE_APPROVAL}"
    printf '\n'
    printf 'BASE IMAGE NOT APPROVED. The production build is not eligible.\n'
    printf 'Candidate discovery and base approval are a separate operator\n'
    printf 'ceremony; run --print-plan, and see\n'
    printf '  provisioning/execution/g5-supply-chain.sh --print-attestation-procedure\n'
    return 1
  fi
  # One definition of the approval schema, and it lives with the supply-chain
  # tooling that produces the values. A second copy here would be a second
  # thing to keep in agreement, and the two would drift at exactly the moment a
  # field started mattering.
  local supply="${REPOSITORY}/provisioning/execution/g5-supply-chain.sh"
  [[ -f "${supply}" ]] || { bad "the supply-chain tooling is absent"; return 1; }
  local arguments=(--verify-approval)
  [[ -z "${FIXTURE}" ]] || arguments+=(--fixture "${FIXTURE}")
  if bash "${supply}" "${arguments[@]}" | sed 's/^/         /'; then
    ok "the production base approval verifies (digest-pinned, signer-bound, SBOM committed)"
  else
    bad "the production base approval does not verify"
  fi
}

verify_authority_prerequisites() {
  [[ ! -e "${AUTHORITY_ROOT}" ]] || bad "${AUTHORITY_ROOT} already exists"
  [[ ! -e "${CONTROL_ROOT}" ]] || bad "${CONTROL_ROOT} already exists"
  [[ -d "${KYRI_STATE}" ]] || bad "${KYRI_STATE} does not exist"
  # Publication renames staged material into the published namespace, so the
  # two roots must share a filesystem. Checked on the parent, before either
  # exists.
  ok "both namespace roots are absent and will be created under ${KYRI_STATE} (one filesystem)"
  if [[ -z "${FIXTURE}" ]]; then
    local uid gid
    uid="$(getent passwd "${EXECUTION_USER}" | cut -d: -f3)"
    gid="$(getent group "${EXECUTION_GROUP}" | cut -d: -f3)"
    [[ "${uid}" == "${EXECUTION_UID}" ]] || bad "${EXECUTION_USER} is uid ${uid:-absent}"
    [[ "${gid}" == "${EXECUTION_GID}" ]] || bad "${EXECUTION_GROUP} is gid ${gid:-absent}"
    getent group "${COORDINATOR}" >/dev/null || bad "group ${COORDINATOR} does not exist"
    id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n' | grep -qx "${EXECUTION_GROUP}" \
      && bad "${COORDINATOR} is a member of ${EXECUTION_GROUP}"
  fi
  printf '\n'
  printf 'The roots this ceremony would create, and nothing else:\n'
  printf '  %-58s %s\n' "${AUTHORITY_ROOT}" "root:${COORDINATOR} ${AUTHORITY_DIR_MODE}"
  printf '  %-58s %s\n' "${CONTROL_ROOT}" "root:root ${CONTROL_DIR_MODE}"
  printf '  %-58s %s\n' "${CONTROL_ROOT}/staging" "root:${COORDINATOR} ${STAGING_DIR_MODE}"
  printf '  %-58s %s\n' "…/implementations, …/generations, …/<CIMP>, …/<CGEN>" \
    "root:${COORDINATOR} ${AUTHORITY_DIR_MODE} (inherited)"
  printf '  %-58s %s\n' "admission · retirement · authority-set · generation" \
    "root:${COORDINATOR} 0${AUTHORITY_RECORD_MODE} (inherited)"
  printf '  %-58s %s\n' "…/current-generation" "root:${COORDINATOR} 0${AUTHORITY_RECORD_MODE} (inherited)"
  printf '  %-58s %s\n' "…/cimp-counter, …/cgen-counter, …/implementation-lifecycle" "root:root 0600"
  printf '\nEverything below them inherits its group from the setgid bit. Nothing\n'
  printf 'is ever chowned after publication, so there is no window in which\n'
  printf 'authority is published and unreadable.\n'
  (( FAILURES == 0 )) && ok "the authority prerequisites hold"
}

verify_materialisation() {
  materialise
  # The isolation properties, proven rather than asserted: the interpreter must
  # ignore a hostile PYTHONPATH and PYTHONHOME, must not put the working
  # directory on sys.path, and must resolve every module inside the tree.
  PYTHONPATH="${REPOSITORY}" PYTHONHOME="/nonexistent" run_materialised '
import os, sys
root = sys.argv[1]
assert "PYTHONPATH" not in os.environ, "PYTHONPATH survived env -i"
assert "PYTHONHOME" not in os.environ, "PYTHONHOME survived env -i"
assert "" not in sys.path and "." not in sys.path, sys.path
assert os.getcwd() == "/", os.getcwd()
assert sys.dont_write_bytecode is True
sys.path.insert(0, root)
import tools.provisioning.authority_bootstrap as b
assert b.__file__.startswith(root + os.sep), b.__file__
for entry in sys.path[1:]:
    assert "schott-platform" not in entry, entry
print("      sys.path[0]:", sys.path[0])
print("      no checkout entry on sys.path")
' || halt "the isolated interpreter did not hold its properties"
  ok "isolated execution: PYTHONPATH and PYTHONHOME dropped, no cwd import, no checkout on sys.path"
  discard_materialised
}

print_plan() {
  cat <<PLAN
The G5 ceremony, in order. Every step is a stop. No command runs the next one,
and no verification phase performs a mutation.

  PHASE 0 -- BOOTSTRAP THE TRUST BOUNDARY          (see --bootstrap-instructions)
    The only coordinator-controlled bytes root executes are this script, and
    only after its SHA-256 is verified in root-owned space.

  PHASE 1 -- READ-ONLY VERIFICATION                (no mutation of any kind)
    --verify-host
    --verify-source --commit <REVIEWED>
    --verify-materialisation --commit <REVIEWED>
    --verify-authority-prerequisites
    OPERATOR REVIEW

  PHASE 2 -- CANDIDATE DISCOVERY                   (separate, network, NOT here)
    Discovery may reach the network. Its output is a CANDIDATE, never an
    approval. Record for the review: registry, repository, the tag used for
    discovery only, the immutable index/manifest digest, architecture, os,
    platform, the reported Python version, the interpreter path, any local
    Podman identity observed while inspecting, the discovery timestamp, and
    the exact commands run.
    OPERATOR REVIEW  -- the reviewer, not a script, promotes one candidate.

  PHASE 3 -- BASE APPROVAL                         (root records the decision)
    Write ${BASE_APPROVAL}, root:root 0400, holding at least:
      base_image_reference=${BASE_REPOSITORY}@sha256:<64 hex>
      sbom_source=<exact path or command whose bytes become sbom_sha256>
      approved_by=<operator>   approved_at=<ISO-8601>
    --verify-build-inputs
    OPERATOR REVIEW

  PHASE 4 -- BUILD CONTEXT                         (root; mutates /run only)
    The execution identity cannot traverse the checkout -- that is the
    authority split, and the first production build failed on it. Root
    materialises the reviewed context where that identity can read it:
      --verify-build-context --commit <REVIEWED>
      --materialise-build-context --commit <REVIEWED>
      --verify-materialised-build-context
    OPERATOR REVIEW

  PHASE 5 -- PRODUCTION BUILD                      (execution identity only)
    --print-production-build, then run what it prints. It names no checkout
    path, runs from /tmp, and consumes only the approved digest.
    OPERATOR REVIEW  -- inspect the ID, the SBOM, and the interpreter before
    anything is admitted. Building is not admitting.

  PHASE 6 -- AUTHORITY BOOTSTRAP                   (root, through the pinned tree)
    --bootstrap-authority --commit <REVIEWED>
    OPERATOR REVIEW

  PHASE 7 -- GENESIS                               (root, through the pinned tree)
    --genesis --commit <REVIEWED>
    STOP. Genesis publishes CGEN-000000000000 with an empty authority set and
    grants nothing. Review before admission.

  PHASE 8 -- ADMISSION                             (root, through the pinned tree)
    --admit --commit <REVIEWED>
    Collects three INDEPENDENT observations of the image identity and requires
    all three to agree. They are never copied from one variable.
    OPERATOR REVIEW

  PHASE 9 -- POST-ADMISSION VERIFICATION           (read-only, runtime reader)
    Namespace VALID, pending empty, the admitted CIMP resolving to the exact
    image ID, and the image present in the execution identity's store.

G5 closes only when all eleven recorded conditions hold. Building an image,
or an image merely existing in the store, closes nothing.
PLAN
}

bootstrap_instructions() {
  cat <<'BOOT'
Getting this script into root-owned space, and why that is the whole boundary.

The problem: `sudo bash /opt/schott-platform/provisioning/execution/g5-ceremony.sh`
has root execute a file the coordinator can rewrite, including between the
moment you check it and the moment sudo reads it. Verifying a digest in place
does not close that.

The remedy is three commands. The first two involve no privilege at all, and
the third executes only bytes that already live where the coordinator cannot
reach them.

  # 1. As the coordinator. Extract from the reviewed git OBJECT, not the tree.
  git -C /opt/schott-platform cat-file blob \
      <REVIEWED_COMMIT>:provisioning/execution/g5-ceremony.sh > /tmp/g5-ceremony.sh

  # 2. As root. Copy into a root-owned 0700 directory and print the digest.
  sudo install -d -m 0700 -o root -g root /root/kyri-g5-bootstrap
  sudo install -m 0500 -o root -g root /tmp/g5-ceremony.sh \
      /root/kyri-g5-bootstrap/g5-ceremony.sh
  sudo sha256sum /root/kyri-g5-bootstrap/g5-ceremony.sh

  # 3. COMPARE that digest, by eye, against the reviewed value in the runbook.
  #    Only then:
  sudo bash /root/kyri-g5-bootstrap/g5-ceremony.sh --verify-host

Why this is sufficient:

  * step 1 runs git as the coordinator against the coordinator's own
    repository, which escalates nothing. Root never runs git inside a
    directory the coordinator controls -- a repository's own .git/config can
    name programs for git to execute, and that would be arbitrary code as root
    before any boundary exists.
  * `cat-file blob <40-hex commit>:<path>` is content-addressed. Substituting
    the bytes requires a SHA-1 preimage, not a file write.
  * the digest you compare is taken from the copy in /root/kyri-g5-bootstrap,
    which is 0700 root:root. Nothing can change it between the comparison and
    the run, so there is no check-then-swap window.
  * this script sources nothing, reads no configuration file, and calls
    /usr/bin/git, /usr/sbin/runuser, and /usr/bin/python3 by absolute path.

Exactly one coordinator-authored artefact is executed by root before the
boundary exists: this script, verified by digest, from root-owned space. Every
byte after that -- the whole operator package -- is materialised from pinned
git objects and verified against a pinned manifest digest before a line of it
runs.
BOOT
}

refuse_mutation() {
  local phase="$1" reason="$2"
  printf '\n'
  printf 'MUTATION PHASE %s IS NOT ELIGIBLE.\n' "${phase}"
  printf '%s\n' "${reason}"
  printf '\nNothing was created, built, allocated, or admitted.\n'
  exit 1
}

# ===========================================================================
printf '== G5 ceremony (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

trap 'discard_materialised >/dev/null 2>&1 || true' EXIT

case "${MODE}" in
--bootstrap-instructions) bootstrap_instructions ;;
--print-plan)             print_plan ;;
--verify-host)            verify_host ;;
--verify-source)          verify_source ;;
--verify-build-inputs)    verify_build_inputs || true ;;
--verify-authority-prerequisites) verify_authority_prerequisites ;;
--verify-materialisation) verify_materialisation ;;
--verify-build-context)   verify_build_context ;;
--verify-materialised-build-context) verify_materialised_build_context ;;
--print-production-build) print_production_build ;;
--materialise-build-context) materialise_build_context ;;

--bootstrap-authority|--genesis|--admit)
  # Implemented as an explicit refusal, not as a stub that might one day run
  # by accident. Each phase names what is missing; none of them is written to
  # proceed while the base image is unapproved, because an authority namespace
  # created before there is anything to admit is a namespace that exists for
  # no reason and has to be disposed of rather than deleted.
  [[ "$(id -u)" -eq 0 || -n "${FIXTURE}" ]] || halt "mutation phases require root"
  verify_host
  (( FAILURES == 0 )) || halt "the host is not at the ruled starting position"
  if [[ ! -e "${BASE_APPROVAL}" ]]; then
    refuse_mutation "${MODE#--}" \
"No approved production base image is recorded at ${BASE_APPROVAL}.
Candidate discovery (phase 2) and base approval (phase 3) have not happened,
so there is no implementation to admit and no reason to create an authority
namespace yet. Run --print-plan."
  fi
  refuse_mutation "${MODE#--}" \
"An approved base exists, but the mutation phases are not enabled in this
build. They are prepared and reviewed; enabling them is a separate reviewed
change once the production image has been built and inspected."
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 ceremony %s: all checks passed.\n' "${MODE#--}"
  printf 'No image was built, no authority root created, no identifier allocated,\n'
  printf 'nothing admitted, and neither the transition nor the worker was invoked.\n'
else
  printf 'G5 ceremony %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
