#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 S2e artifact-authority ceremony: publish the reviewed
# verification package into the governed artifact root.
#
# WHY THIS EXISTS. `resolve_and_stage_package` reads the manifest and the
# artefact through the descriptor-safe trusted-source primitive, which requires
# the approved root and every component beneath it to be owned by an explicitly
# supplied trusted UID and to be neither group- nor world-writable. A git
# checkout cannot satisfy that and never will: git records `100644`/`100755`
# for blobs, stores no directory objects, and carries no uid or gid anywhere in
# a tree object, so directory ownership and mode come from whoever checked the
# tree out and from their umask. `chmod`-ing the checkout would buy a passing
# check by dissolving the boundary the check exists to enforce -- the same
# correction the G5 build context already made, for the same reason.
#
# So git source and runtime artifact authority are two planes, and this is the
# deterministic materialisation between them:
#
#   reviewed commit -> git object -> root materialisation -> root-owned
#                   -> readable by the coordinator -> package resolution
#
# WHAT IT PUBLISHES. One package tree, from the pinned reviewed commit below and
# from nothing else. Bytes come from `git cat-file blob <PINNED>:<path>` read as
# the repository owner -- never from a working-tree file, and never with root
# running git inside a directory the coordinator controls.
#
# AND ONE EXECUTABLE MANIFEST, from its own pinned commit. The manifest names
# `CPKG-0001`, so it could not exist until that identity was predicted -- which
# is why it is reviewed at a different commit than the tree, and why each object
# names the commit that actually authorised it. It is published BESIDE the tree,
# never inside it: it carries the tree commitment, so a manifest within the tree
# would have to contain a digest taken over its own bytes.
#
# WHAT IT DOES NOT DO. It declares no capability package, allocates no
# identifier, creates no sequence, opens no Fabric store, stages nothing through
# package resolution, executes nothing, writes no sudoers policy, invokes no
# privileged helper, and contacts no container runtime. It publishes bytes and
# refuses.
#
# NOTHING IS REPAIRED. A published tree or manifest that disagrees with the
# pinned digests is reported, never chmod'ed, chown'ed, or replaced. Silently
# correcting authority somebody else wrote is how a ceremony becomes an attack.
# Each half is settled independently, so an already-correct tree is never
# republished, renamed, or rewritten merely because the manifest needs writing.
#
# Usage:
#   install-verification-package.sh --verify            read-only: may it publish?
#   install-verification-package.sh --install           publish tree and manifest
#   install-verification-package.sh --verify-installed  read-only: are they right?
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md  (§7, §8)
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md       (§8)

# The reviewed commit that introduced the verification package. Pinned, never
# HEAD, and deliberately not an argument: a ceremony whose source revision is
# caller-supplied pins nothing. This ceremony's own commit is necessarily later
# than the authority it publishes.
COMMIT="49c27fb63820bcdadc66d8e78f259430c09471da"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

# The governed artifact authority. Not the checkout, not the Fabric store, not
# the Capability Runtime's evidence, not the installed library, and not staging:
# it is the trusted filesystem authority package resolution reads before
# content-addressed staging happens anywhere else.
ARTIFACT_ROOT="/var/lib/kyri/artifacts"          # prod-path-reference

# The package this ceremony publishes. The name is the capability's, spelled as
# CAPDEF-0001 spells it; the version is the package's declared version and is an
# opaque exact-match token, never parsed.
PACKAGE_NAME="kyri-execution-boundary-verification"
PACKAGE_VERSION="1.0.0"

# The tree commitment `package_contract.inspect_package` derives from the
# published tree. Verified through the installed Generation-10 module, because
# a second implementation of a tree digest is a second answer to what a package
# is.
PACKAGE_TREE_SHA256="sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e"
LIBRARY_ROOT="/usr/lib/kyri/python"              # prod-path-reference

# source-relative-path | published-relative-path | mode | sha256 at COMMIT
#
# The list is pinned both ways: a substituted source path changes the digest,
# and a substituted digest fails against the object. Every published object is a
# CREATE; this ceremony replaces nothing.
MATRIX=(
"packages/${PACKAGE_NAME}/${PACKAGE_VERSION}/main.py|main.py|0444|683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd"
)

# --- the executable manifest ------------------------------------------------
#
# TWO COMMITS, AND THE REASON IS NOT UNTIDINESS. The package tree was reviewed
# at COMMIT above; the manifest did not exist there, because it names
# `CPKG-0001` and that identity was not predicted until later. Pretending one
# commit authorised both would be a pin that never held. So each object names
# the commit that actually reviewed it, and the question "which Git object
# authorised these bytes" has exactly one answer per object.
#
# MANIFEST_COMMIT contains the manifest source and nothing else. A ceremony
# cannot pin a commit that also contains the ceremony pinning it, which is why
# the source landed on its own first.
MANIFEST_COMMIT="2575c042f214ccfe160fd6d973985a4335781c1e"
MANIFEST_SOURCE="packages/${PACKAGE_NAME}/${PACKAGE_VERSION}.manifest.json"
MANIFEST_NAME="${PACKAGE_VERSION}.manifest.json"
MANIFEST_MODE="0444"
MANIFEST_SHA256="53d4624b5136fbf6a7f5c3d0c577d86419828e0dd6d12c5a031fdeeb64244d4b"

DIRECTORY_MODE="0755"
STAGING_MODE="0700"

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify|--install|--verify-installed)
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
  ARTIFACT_ROOT="${FIXTURE}${ARTIFACT_ROOT}"
fi

PACKAGE_ROOT="${ARTIFACT_ROOT}/${PACKAGE_NAME}"
PUBLISHED="${PACKAGE_ROOT}/${PACKAGE_VERSION}"
STAGING="${PACKAGE_ROOT}/.staging-${COMMIT:0:12}"
# The manifest sits BESIDE the tree, never inside it: it carries the tree
# commitment, so a manifest within the tree would have to contain a digest
# taken over its own bytes.
MANIFEST_PUBLISHED="${PACKAGE_ROOT}/${MANIFEST_NAME}"
MANIFEST_STAGING="${PACKAGE_ROOT}/.manifest-${MANIFEST_COMMIT:0:12}"

FAILURES=0
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# In production every published object is root's. Under a fixture nothing is
# chowned and the invoking account owns what it made, so the expectation is
# stated once here rather than being quietly skipped at each check.
if [[ -n "${FIXTURE}" ]]; then
  EXPECTED_OWNER="$(id -un)"
  EXPECTED_GROUP="$(id -gn)"
else
  EXPECTED_OWNER="root"
  EXPECTED_GROUP="root"
fi

REPO_OWNER="$(stat -c '%U' "${REPOSITORY}" 2>/dev/null || printf 'root')"

# Git, always as the repository owner and never as root: root running git inside
# a checkout the coordinator can write executes that checkout's hooks and config.
git_as_owner() {
  if [[ "$(id -un)" == "${REPO_OWNER}" ]]; then
    /usr/bin/git -C "${REPOSITORY}" "$@"
  else
    /usr/sbin/runuser -u "${REPO_OWNER}" -- /usr/bin/git -C "${REPOSITORY}" "$@"
  fi
}

require_commit() {
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} does not exist in ${REPOSITORY}"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  local row path
  for row in "${MATRIX[@]}"; do
    path="$(field "${row}" 0)"
    git_as_owner cat-file -e "${COMMIT}:${path}" 2>/dev/null \
      || halt "the reviewed commit does not carry ${path}"
  done
  ok "reviewed commit ${COMMIT} exists, is an ancestor of HEAD, on ${BRANCH} (read as ${REPO_OWNER})"
}

# One component of the trusted path, judged by the released primitive's rule.
#
# `trusted_source._check_directory` refuses a component that is not a directory,
# is not owned by the explicitly supplied trusted uid, or is group- or
# other-writable; opening with `O_NOFOLLOW|O_DIRECTORY` refuses a symlink and a
# non-directory before that. Those four conditions are this function, stated
# once and applied to every component.
#
# The primitive is not reused directly, and the reason is not convenience. It
# answers "may I open this whole relative path", so it requires every component
# to exist -- and during publication the version directory does not yet. A
# ceremony that has to ask "are the existing components trustworthy, so that I
# may create beneath them" cannot ask it that way. What is shared is the rule,
# not the call, and the suite proves the two agree on the same trees rather than
# leaving the alignment asserted in a comment.
check_trusted_component() {
  local path="$1" problems=0 observed
  if [[ -L "${path}" ]]; then
    bad "${path} is a symbolic link"
    return 1
  fi
  if [[ ! -d "${path}" ]]; then
    bad "${path} is not a directory"
    return 1
  fi
  observed="$(stat -c '%U' "${path}")"
  if [[ "${observed}" != "${EXPECTED_OWNER}" ]]; then
    bad "${path} is owned by ${observed}, expected ${EXPECTED_OWNER}"
    problems=$((problems + 1))
  fi
  if [[ -n "$(find "${path}" -maxdepth 0 -perm /022)" ]]; then
    observed="$(stat -c '%a' "${path}")"
    bad "${path} is writable beyond its owner (${observed})"
    problems=$((problems + 1))
  fi
  return "${problems}"
}

# Every component the runtime will walk, in the order it walks them: the
# ancestry above the root, then the root, then the package parent, then the
# published version when there is one.
#
# The earlier revision of this ceremony validated only the ancestry ABOVE the
# root. That left the intermediate package directory accepted on the strength of
# being a directory and not a symlink, so a group-writable one was published
# beneath and reported DONE and VERIFIED -- for a tree `open_trusted_directory`
# refuses at exactly that component. The provisioning boundary and the
# resolution boundary have to be one boundary.
#
# Existing components are validated and never repaired. An untrusted one is
# operator-visible evidence; chmod'ing it would erase the evidence and grant
# the trust the check exists to withhold.
require_trusted_authority() {
  local problems=0 path components=()

  path="$(dirname "${ARTIFACT_ROOT}")"
  while [[ "${path}" != "/" && "${path}" != "${FIXTURE}" && -n "${path}" ]]; do
    components=("${path}" "${components[@]}")
    path="$(dirname "${path}")"
  done
  components+=("${ARTIFACT_ROOT}" "${PACKAGE_ROOT}" "${PUBLISHED}")

  local checked=0
  for path in "${components[@]}"; do
    # Absent is not untrusted: the ceremony creates the root and the package
    # directory itself, and validates them after it does.
    [[ -e "${path}" || -L "${path}" ]] || continue
    check_trusted_component "${path}" || problems=$((problems + $?))
    checked=$((checked + 1))
  done

  (( problems == 0 )) \
    || halt "the artifact authority is not trusted; nothing was created, written, or repaired"
  ok "${checked} existing component(s) are ${EXPECTED_OWNER}-owned directories, unwritable beyond their owner, and no symlink"
}

# The tree commitment, through the installed Generation-10 authority rather than
# a second digest implementation. `-I -B` isolates the interpreter from ambient
# configuration and writes no bytecode into a read-only tree.
tree_commitment() {
  python3 -I -B -c '
import os, sys
sys.path.insert(0, sys.argv[1])
from tools.capability.execution.package_contract import inspect_package
handle = os.open(sys.argv[2],
                 os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY)
try:
    print("sha256:" + inspect_package(handle).digest)
finally:
    os.close(handle)
' "${LIBRARY_ROOT}" "$1"
}

# One published object, judged on its own inode. Ownership and mode are read
# back rather than assumed from what was requested.
check_member() {
  local path="$1" mode="$2" digest="$3" problems=0 observed
  if [[ -L "${path}" || ! -f "${path}" ]]; then
    bad "${path} is not a regular file"; return 1
  fi
  observed="$(stat -c '%U:%G' "${path}")"
  [[ "${observed}" == "${EXPECTED_OWNER}:${EXPECTED_GROUP}" ]] \
    || { bad "${path} is ${observed}, expected ${EXPECTED_OWNER}:${EXPECTED_GROUP}"; problems=$((problems + 1)); }
  observed="$(stat -c '%a' "${path}")"
  [[ "${observed}" == "${mode#0}" || "0${observed}" == "${mode}" ]] \
    || { bad "${path} is mode ${observed}, expected ${mode}"; problems=$((problems + 1)); }
  [[ "$(stat -c '%h' "${path}")" == "1" ]] \
    || { bad "${path} carries more than one link to its bytes"; problems=$((problems + 1)); }
  observed="$(digest_of "${path}")"
  [[ "${observed}" == "${digest}" ]] \
    || { bad "${path} is ${observed:0:12}…, expected ${digest:0:12}…"; problems=$((problems + 1)); }
  return "${problems}"
}

verify_published() {
  local problems=0 row published mode digest observed
  [[ -d "${PUBLISHED}" && ! -L "${PUBLISHED}" ]] \
    || { bad "${PUBLISHED} is not a published directory"; return 1; }
  observed="$(stat -c '%U:%G' "${PUBLISHED}")"
  [[ "${observed}" == "${EXPECTED_OWNER}:${EXPECTED_GROUP}" ]] \
    || { bad "${PUBLISHED} is ${observed}"; problems=$((problems + 1)); }
  [[ -z "$(find "${PUBLISHED}" -perm /022)" ]] \
    || { bad "${PUBLISHED} holds group- or other-writable objects"; problems=$((problems + 1)); }
  [[ -z "$(find "${PUBLISHED}" ! -type d ! -type f)" ]] \
    || { bad "${PUBLISHED} holds objects that are neither directories nor regular files"; problems=$((problems + 1)); }

  local expected_count=0
  for row in "${MATRIX[@]}"; do
    published="$(field "${row}" 1)"; mode="$(field "${row}" 2)"; digest="$(field "${row}" 3)"
    check_member "${PUBLISHED}/${published}" "${mode}" "${digest}" || problems=$((problems + $?))
    expected_count=$((expected_count + 1))
  done
  observed="$(find "${PUBLISHED}" -type f | wc -l)"
  [[ "${observed}" -eq "${expected_count}" ]] \
    || { bad "${PUBLISHED} holds ${observed} files, expected ${expected_count}"; problems=$((problems + 1)); }

  observed="$(tree_commitment "${PUBLISHED}" 2>/dev/null || printf 'unreadable')"
  [[ "${observed}" == "${PACKAGE_TREE_SHA256}" ]] \
    || { bad "the published tree commits to ${observed}, expected ${PACKAGE_TREE_SHA256}"; problems=$((problems + 1)); }
  return "${problems}"
}

# The published manifest, judged on its own inode and against the pinned bytes.
# It is a trusted-source FILE, so the contract is the one
# `open_trusted_regular_file` applies: a regular file, the expected owner, not
# writable beyond that owner, and exactly one link -- a second name for the same
# bytes lives outside the directory whose permissions were just checked.
verify_manifest() {
  local problems=0 observed
  if [[ -L "${MANIFEST_PUBLISHED}" || ! -f "${MANIFEST_PUBLISHED}" ]]; then
    bad "${MANIFEST_PUBLISHED} is not a regular file"
    return 1
  fi
  observed="$(stat -c '%U:%G' "${MANIFEST_PUBLISHED}")"
  [[ "${observed}" == "${EXPECTED_OWNER}:${EXPECTED_GROUP}" ]] \
    || { bad "${MANIFEST_PUBLISHED} is ${observed}, expected ${EXPECTED_OWNER}:${EXPECTED_GROUP}"; problems=$((problems + 1)); }
  observed="$(stat -c '%a' "${MANIFEST_PUBLISHED}")"
  [[ "0${observed}" == "${MANIFEST_MODE}" ]] \
    || { bad "${MANIFEST_PUBLISHED} is mode ${observed}, expected ${MANIFEST_MODE}"; problems=$((problems + 1)); }
  [[ "$(stat -c '%h' "${MANIFEST_PUBLISHED}")" == "1" ]] \
    || { bad "${MANIFEST_PUBLISHED} carries more than one link to its bytes"; problems=$((problems + 1)); }
  observed="$(digest_of "${MANIFEST_PUBLISHED}")"
  [[ "${observed}" == "${MANIFEST_SHA256}" ]] \
    || { bad "${MANIFEST_PUBLISHED} is ${observed:0:12}…, expected ${MANIFEST_SHA256:0:12}…"; problems=$((problems + 1)); }
  return "${problems}"
}

# Written beside the tree, never into it, and published by one rename so the
# visible name is never briefly wrong. The package tree is not read, opened,
# renamed, or re-verified here: installing a manifest is not a reason to touch
# an already-published artefact.
publish_manifest() {
  git_as_owner cat-file -e "${MANIFEST_COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed manifest commit ${MANIFEST_COMMIT} does not exist in ${REPOSITORY}"
  git_as_owner merge-base --is-ancestor "${MANIFEST_COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed manifest commit ${MANIFEST_COMMIT} is not an ancestor of HEAD"
  git_as_owner cat-file -e "${MANIFEST_COMMIT}:${MANIFEST_SOURCE}" 2>/dev/null \
    || halt "the reviewed manifest commit does not carry ${MANIFEST_SOURCE}"

  [[ ! -e "${MANIFEST_STAGING}" && ! -L "${MANIFEST_STAGING}" ]] \
    || halt "${MANIFEST_STAGING} is interrupted-ceremony residue and is not adopted"

  local previous_umask observed
  previous_umask="$(umask)"
  umask 077
  git_as_owner cat-file blob "${MANIFEST_COMMIT}:${MANIFEST_SOURCE}" > "${MANIFEST_STAGING}"
  observed="$(digest_of "${MANIFEST_STAGING}")"
  if [[ "${observed}" != "${MANIFEST_SHA256}" ]]; then
    rm -f "${MANIFEST_STAGING}"
    umask "${previous_umask}"
    halt "${MANIFEST_SOURCE} at ${MANIFEST_COMMIT} is ${observed}, expected ${MANIFEST_SHA256}; nothing was published"
  fi
  [[ -n "${FIXTURE}" ]] || chown root:root "${MANIFEST_STAGING}"
  chmod "${MANIFEST_MODE}" "${MANIFEST_STAGING}"
  # `-n` refuses rather than replacing, so a manifest that appeared between the
  # check above and this line is never overwritten.
  mv -n -T "${MANIFEST_STAGING}" "${MANIFEST_PUBLISHED}"
  if [[ -e "${MANIFEST_STAGING}" ]]; then
    umask "${previous_umask}"
    halt "${MANIFEST_PUBLISHED} appeared during publication; it is not replaced, and ${MANIFEST_STAGING} is left for inspection"
  fi
  sync
  umask "${previous_umask}"
  ok "published ${MANIFEST_PUBLISHED} from ${MANIFEST_COMMIT:0:12} (${MANIFEST_MODE})"
}

# Absent -> publish. Present, trusted and byte-identical -> accept, change
# nothing. Present and different in any respect -> refuse, and leave it exactly
# as it is: an untrusted manifest is operator-visible evidence, and repairing it
# would grant the trust the check exists to withhold.
settle_manifest() {
  if [[ -e "${MANIFEST_PUBLISHED}" || -L "${MANIFEST_PUBLISHED}" ]]; then
    local before="${FAILURES}"
    verify_manifest || true
    if (( FAILURES == before )); then
      ok "the manifest is already published and byte-identical; nothing to do"
      return 0
    fi
    halt "$((FAILURES - before)) problem(s): ${MANIFEST_PUBLISHED} exists and is not the reviewed manifest; it is not replaced or repaired"
  fi
  publish_manifest
}

publish() {
  require_commit
  require_trusted_authority

  [[ ! -e "${STAGING}" ]] \
    || halt "${STAGING} already exists; an interrupted ceremony left material that is not adopted"

  # Set explicitly, and restored afterwards. A umask of 002 would otherwise
  # leave every directory created below group-writable, which is the single
  # property the whole trusted-source boundary rests on.
  local previous_umask; previous_umask="$(umask)"
  umask 077

  # Existing components were validated above and are left exactly as they are.
  # A component this ceremony creates is read back afterwards rather than
  # trusted to have come out as requested: `mkdir -m` masks its mode, and a
  # directory that is not what was asked for must fail here rather than at
  # resolution.
  local created=()
  local path
  for path in "${ARTIFACT_ROOT}" "${PACKAGE_ROOT}"; do
    [[ -e "${path}" || -L "${path}" ]] && continue
    mkdir -m "${DIRECTORY_MODE}" "${path}"
    created+=("${path}")
    [[ -n "${FIXTURE}" ]] || chown root:root "${path}"
    chmod "${DIRECTORY_MODE}" "${path}"
    check_trusted_component "${path}" \
      || halt "${path} was created but does not satisfy the trusted-component contract"
  done

  mkdir -m "${STAGING_MODE}" "${STAGING}"
  [[ -n "${FIXTURE}" ]] || chown root:root "${STAGING}"
  chmod "${STAGING_MODE}" "${STAGING}"

  local row source published mode digest destination observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; published="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; digest="$(field "${row}" 3)"
    destination="${STAGING}/${published}"
    # No `-m` here: with `-p` it applies to the deepest component only, which
    # would leave any intermediate directory at whatever the umask gives. The
    # umask is 077 for the whole publication and every directory beneath the
    # staging tree is given its final mode explicitly below, so the mode is set
    # where it can be stated for all of them rather than for one.
    mkdir -p "$(dirname "${destination}")"
    [[ ! -e "${destination}" ]] || halt "duplicate published path: ${published}"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${destination}"
    observed="$(digest_of "${destination}")"
    [[ "${observed}" == "${digest}" ]] \
      || halt "${source} at ${COMMIT} is ${observed}, expected ${digest}; nothing was published"
    [[ -n "${FIXTURE}" ]] || chown root:root "${destination}"
    chmod "${mode}" "${destination}"
  done

  # Directory modes are set deepest-first, after the members are written: a
  # directory made read-only before its children exist cannot receive them.
  find "${STAGING}" -type d -print0 | sort -zr | while IFS= read -r -d '' path; do
    [[ -n "${FIXTURE}" ]] || chown root:root "${path}"
    chmod "${DIRECTORY_MODE}" "${path}"
  done

  observed="$(tree_commitment "${STAGING}" 2>/dev/null || printf 'unreadable')"
  [[ "${observed}" == "${PACKAGE_TREE_SHA256}" ]] \
    || halt "the staged tree commits to ${observed}, expected ${PACKAGE_TREE_SHA256}; nothing was published"
  ok "staged ${#MATRIX[@]} object(s), commitment ${PACKAGE_TREE_SHA256}"

  # One rename publishes the whole tree, and `rename` onto a non-empty
  # directory fails -- so this never overwrites a published version, and the
  # visible name is never briefly wrong.
  mv -T "${STAGING}" "${PUBLISHED}" \
    || halt "${PUBLISHED} already holds a published tree; it is not replaced"
  sync
  umask "${previous_umask}"
  ok "published ${PUBLISHED}"
  (( ${#created[@]} == 0 )) || ok "created ${created[*]}"
}

case "${MODE}" in
--verify)
  printf '── artifact authority: may the reviewed package be published?\n\n'
  require_commit
  require_trusted_authority
  if [[ -e "${PUBLISHED}" ]]; then
    note "${PUBLISHED} already exists; verifying it rather than proposing a publication"
    verify_published || true
    if (( FAILURES == 0 )); then
      ok "the tree is already published and exactly right"
    else
      halt "${FAILURES} problem(s): the published tree is not the reviewed tree, and nothing here repairs it"
    fi
  else
    [[ ! -e "${STAGING}" ]] || halt "${STAGING} is interrupted-ceremony residue and is not adopted"
    ok "${PUBLISHED} is absent; --install would publish ${#MATRIX[@]} object(s)"
  fi
  if [[ -e "${MANIFEST_PUBLISHED}" || -L "${MANIFEST_PUBLISHED}" ]]; then
    verify_manifest || true
    if (( FAILURES == 0 )); then
      ok "the manifest is already published and exactly right"
    else
      halt "${FAILURES} problem(s): the published manifest is not the reviewed manifest, and nothing here repairs it"
    fi
  else
    ok "${MANIFEST_PUBLISHED} is absent; --install would publish it from ${MANIFEST_COMMIT:0:12}"
  fi
  printf '\nREADY\n'
  ;;
--install)
  printf '── artifact authority: publishing the reviewed package\n\n'
  [[ "$(id -u)" == "0" || -n "${FIXTURE}" ]] \
    || halt "publication writes root-owned authority and must run as root"
  if [[ -e "${PUBLISHED}" ]]; then
    # Idempotent only where the bytes already agree. A published tree that
    # differs is reported and left exactly as it is -- and either way the tree
    # is not republished, renamed, or rewritten just because the manifest step
    # still has work to do.
    verify_published || true
    if (( FAILURES != 0 )); then
      halt "${FAILURES} problem(s): ${PUBLISHED} exists and is not the reviewed tree; it is not replaced"
    fi
    ok "the tree is already published and byte-identical; it is left untouched"
  else
    publish
    FAILURES=0
    verify_published || true
    (( FAILURES == 0 )) || halt "${FAILURES} problem(s) in the published tree"
    ok "the published tree verifies"
  fi
  settle_manifest
  FAILURES=0
  verify_manifest || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s) in the published manifest"
  ok "the published manifest verifies"
  printf '\nDONE\n'
  ;;
--verify-installed)
  printf '── artifact authority: is the published package exactly right?\n\n'
  require_trusted_authority
  verify_published || true
  verify_manifest || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s)"
  ok "${PUBLISHED} is the reviewed tree at ${COMMIT}"
  ok "${MANIFEST_PUBLISHED} is the reviewed manifest at ${MANIFEST_COMMIT}"
  printf '\nVERIFIED\n'
  ;;
esac
