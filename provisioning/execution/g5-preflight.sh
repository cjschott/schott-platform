#!/usr/bin/env bash
set -Eeuo pipefail

# READ-ONLY preflight for the ENG-0005 G5 ceremony: production image build and
# CIMP admission.
#
# THIS SCRIPT MUTATES NOTHING, IN ANY MODE. It builds no image, creates no
# authority root, runs no genesis, allocates no CIMP or CGEN, writes no sudoers
# policy, and invokes neither Podman, the transition, nor the worker. It reads
# and reports. The G5 mutation ceremony is deliberately NOT implemented here --
# see --blockers for why.
#
# WHY A PREFLIGHT EXISTS BEFORE THE CEREMONY DOES
# ===============================================
# Three decisions the G5 ceremony depends on are recorded as ruled but are not
# yet satisfiable as written. Encoding a mutation ceremony around an unruled
# decision would put the wrong thing on the host under a reviewed label. What
# IS fully ruled is the host state the ceremony must start from, and that is
# what this verifies -- so the reviewer resolves three questions rather than
# re-deriving the whole starting position.
#
# Usage:
#   g5-preflight.sh --verify-host    is this host at the ruled G5 starting state?
#   g5-preflight.sh --verify-source  may root execute the reviewed operator
#                                    modules, and from where?
#   g5-preflight.sh --blockers       what must be ruled before the ceremony runs
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.

COMMIT="cd0dc13ba3f4b45a1af01672c3a5f0e95a120234"
GEN6_COMMIT="32c3091b6457e06b4ebb86fed3e2d126cd3e7b07"
GEN5_COMMIT="cfb0edd31b3589f12b6ba583ebfa48bb64e89519"
BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
KYRI_STATE="/var/lib/kyri"
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"
SUDOERS="/etc/sudoers.d/kyri-exec"
TMPFILES_TARGET="/etc/tmpfiles.d/kyri-execution-material.conf"
SNAPSHOT_PARENT="/run/kyri"
SNAPSHOT_ROOT="/run/kyri/execution-material"

EXPECTED_LIBRARY_FILES=44
EXECUTION_USER="kyri-capability"
EXECUTION_GROUP="kyri-capability"
EXECUTION_UID=999
EXECUTION_GID=987
EXECUTION_HOME="/data/kyri/capability"
EXECUTION_RUNTIME_DIR="/run/user/999"
COORDINATOR="cschott"

TMPFILES_DIGEST="10d27e19e298ebf78d9d1d18332cf9d513c5af50b1b3f27182a38a44e02a34d9"

# The reviewed operator modules. Pinned so root is told exactly which bytes it
# would be executing, and so a later edit to any of them is visible here rather
# than at the moment it runs as root.
OPERATOR_MODULES=(
"tools/provisioning/__init__.py|f5ff47311a43e29a46e89f3856ec25638519d8852566127211fc53a86abcedc7"
"tools/provisioning/authority_bootstrap.py|9595fb3ac5c92c5dd86628c4b9b14c874b58ebbf15b28104b98f21e11ec47d44"
"tools/provisioning/authority_admission.py|65635d4ce66b2e5897a22859b990bc250e77bd425e3f5a5c85e009ab32dfa620"
"tools/provisioning/authority_disposition.py|5f950ef2f6e7a48d3507e368aa851a363737723d7e2b85d159fd855c73a2cfc7"
"tools/provisioning/provisioning_evidence.py|0a2616fb38a515f66b9116d77e22b5c52829fdc7d58ff5c47f7541b8cb4bf235"
)

# The image build material, pinned for the same reason.
IMAGE_MATERIAL=(
"provisioning/image/Containerfile|f543c458fcb1793570010b58417c175e6510fe0d90d2a295ef9d38b0cfdedcbb"
"provisioning/image/README.md|b251058847f814b6fb3aa4211d33483ed92833ac5c2d3ff6cd3e315c7584757d"
)

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-host|--verify-source|--blockers)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
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
  TMPFILES_TARGET="${FIXTURE}${TMPFILES_TARGET}"
  SNAPSHOT_PARENT="${FIXTURE}${SNAPSHOT_PARENT}"
  SNAPSHOT_ROOT="${FIXTURE}${SNAPSHOT_ROOT}"
fi

FAILURES=0
BLOCKED=0
ok()    { printf 'ok       %s\n' "$1"; }
note()  { printf 'note     %s\n' "$1"; }
bad()   { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
block() { printf 'BLOCKED  %s\n' "$1" >&2; BLOCKED=$((BLOCKED + 1)); }
halt()  { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# --- repository ------------------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now owner residue
  head_now="$(git rev-parse HEAD)"
  git merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD ${head_now}"
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  owner="$(stat -c '%U' "${REPOSITORY}")"
  if [[ "$(id -un)" == "${owner}" ]]; then
    residue="$(git -C "${REPOSITORY}" status --porcelain --untracked-files=all)"
  else
    residue="$(runuser -u "${owner}" -- git -C "${REPOSITORY}" status --porcelain --untracked-files=all)"
  fi
  if [[ -n "${residue}" ]]; then
    [[ -n "${FIXTURE}" ]] || halt "the working tree is not clean:"$'\n'"${residue}"
    note "the working tree is not clean; permitted in fixture mode only"
  fi
  ok "repository on ${BRANCH} at ${head_now} (contains ${COMMIT}), tree checked (as ${owner})"
}

# --- generation 6 is what must be running ---------------------------------
require_generation_6() {
  local installed
  installed="$(find "${LIBRARY_ROOT}" -type f -name '*.py' 2>/dev/null | wc -l)"
  [[ "${installed}" -eq "${EXPECTED_LIBRARY_FILES}" ]] \
    || bad "the installed library holds ${installed} .py files, expected ${EXPECTED_LIBRARY_FILES}"

  local drift=0 checked=0 file observed expected
  while IFS= read -r file; do
    expected="$(git -C "${REPOSITORY}" cat-file blob "${GEN6_COMMIT}:${file}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    observed="$(digest_of "${LIBRARY_ROOT}/${file}")"
    checked=$((checked + 1))
    [[ "${observed}" == "${expected}" ]] || { bad "runtime object drifted: ${file}"; drift=$((drift + 1)); }
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN6_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common | grep '\.py$' | grep -v '__pycache__')
  (( drift == 0 )) && ok "the generation-6 library surface is exact (${checked} objects from ${GEN6_COMMIT})"

  # /usr/libexec must still be Generation 5, byte for byte. Generation 6
  # changed no privileged object, and the whole boundary argument rests on it.
  local pair source target
  for pair in "provisioning/execution/kyri-exec-transition-entrypoint.py|${LIBEXEC}/kyri-exec-transition" \
              "provisioning/execution/kyri-exec-worker.py|${LIBEXEC}/kyri-exec-worker.py" \
              "provisioning/execution/kyri-exec-quota.py|${LIBEXEC}/kyri-exec-quota"; do
    source="$(field "${pair}" 0)"; target="$(field "${pair}" 1)"
    expected="$(git -C "${REPOSITORY}" cat-file blob "${GEN5_COMMIT}:${source}" | sha256sum | cut -d' ' -f1)"
    [[ "$(digest_of "${target}")" == "${expected}" ]] \
      || bad "privileged helper is not the accepted Generation-5 object: ${target}"
  done
  (( FAILURES == 0 )) && ok "/usr/libexec unchanged from Generation 5: the privileged boundary is intact"

  [[ ! -d "${LIBRARY_ROOT}/tools/provisioning" ]] \
    || bad "operator provisioning modules are installed in the runtime library"
  local residue
  residue="$(find "${LIBRARY_ROOT}" "${LIBEXEC}" -maxdepth 6 \
               \( -name '*.kyri-gen*.new' -o -name '*.kyri-gen*.old' \) 2>/dev/null | wc -l)"
  [[ "${residue}" -eq 0 ]] || bad "${residue} installation transaction artefacts remain"
  ok "no operator tooling in the runtime library, no installation residue"
}

# --- the generation-6 host prerequisite ------------------------------------
require_snapshot_root() {
  [[ "$(digest_of "${TMPFILES_TARGET}")" == "${TMPFILES_DIGEST}" ]] \
    || bad "${TMPFILES_TARGET} is not the reviewed artifact"
  [[ -d "${SNAPSHOT_PARENT}" && ! -L "${SNAPSHOT_PARENT}" ]] \
    || bad "${SNAPSHOT_PARENT} is not a directory"
  [[ -d "${SNAPSHOT_ROOT}" && ! -L "${SNAPSHOT_ROOT}" ]] \
    || bad "${SNAPSHOT_ROOT} is not a directory"
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${SNAPSHOT_PARENT}" 2>/dev/null)" == "root:root 755" ]] \
      || bad "${SNAPSHOT_PARENT} is not root:root 0755"
    [[ "$(stat -c '%U:%G %a' "${SNAPSHOT_ROOT}" 2>/dev/null)" == "root:${EXECUTION_GROUP} 770" ]] \
      || bad "${SNAPSHOT_ROOT} is not root:${EXECUTION_GROUP} 0770"
  fi
  # Emptiness is only observable by root or by the execution identity. Reported
  # honestly rather than claimed: 0770 is what makes the coordinator unable to
  # look, and a check that silently passed because it could not see would be
  # worse than one that says so.
  if [[ -r "${SNAPSHOT_ROOT}" && -x "${SNAPSHOT_ROOT}" ]]; then
    local children
    children="$(find "${SNAPSHOT_ROOT}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    if [[ "${children}" -eq 0 ]]; then
      ok "${SNAPSHOT_ROOT} is empty: no invocation snapshot exists"
    else
      bad "${SNAPSHOT_ROOT} holds ${children} entries and no worker has run"
    fi
  else
    note "${SNAPSHOT_ROOT} is not readable as $(id -un): emptiness must be confirmed as root"
  fi
  (( FAILURES == 0 )) && ok "the generation-6 snapshot-root prerequisite is exactly as ruled"
}

# --- the G5 starting position ----------------------------------------------
require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || bad "${SUDOERS} exists: G3 is not closed and G5 must not depend on it"
  [[ ! -e "${AUTHORITY_ROOT}" ]] || bad "${AUTHORITY_ROOT} already exists"
  [[ ! -e "${CONTROL_ROOT}" ]] || bad "${CONTROL_ROOT} already exists"
  ok "no sudoers policy, no authority root, no control root: no CIMP or CGEN state exists"

  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(stat -c '%U:%G %a' "${KYRI_STATE}" 2>/dev/null)" == "root:root 711" ]] \
      || bad "${KYRI_STATE} is not root:root 0711"
    ok "${KYRI_STATE} is root:root 0711: the authority parent is not coordinator-writable"
  fi
}

require_no_live_caller() {
  local callers=0 unit
  [[ ! -e "${SUDOERS}" ]] || callers=$((callers + 1))
  if [[ -z "${FIXTURE}" ]]; then
    unit="$(grep -rl 'kyri-exec' /etc/systemd/system /lib/systemd/system \
              /etc/cron.d /etc/crontab 2>/dev/null || true)"
    [[ -z "${unit}" ]] || { bad "a systemd or cron entry references kyri-exec:"$'\n'"${unit}"; callers=$((callers + 1)); }
  fi
  (( callers == 0 )) && ok "no live caller into the kyri-exec boundary"
}

require_execution_identity() {
  local uid gid home
  uid="$(getent passwd "${EXECUTION_USER}" | cut -d: -f3)"
  gid="$(getent group "${EXECUTION_GROUP}" | cut -d: -f3)"
  home="$(getent passwd "${EXECUTION_USER}" | cut -d: -f6)"
  [[ "${uid}" == "${EXECUTION_UID}" ]] || bad "${EXECUTION_USER} is uid ${uid:-absent}, expected ${EXECUTION_UID}"
  [[ "${gid}" == "${EXECUTION_GID}" ]] || bad "${EXECUTION_GROUP} is gid ${gid:-absent}, expected ${EXECUTION_GID}"
  [[ "${home}" == "${EXECUTION_HOME}" ]] || bad "${EXECUTION_USER} home is ${home:-absent}, expected ${EXECUTION_HOME}"
  if id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n' | grep -qx "${EXECUTION_GROUP}"; then
    bad "${COORDINATOR} is a member of ${EXECUTION_GROUP}"
  fi
  ok "execution identity: ${EXECUTION_USER} ${uid}:${gid}, HOME=${home}, ${COORDINATOR} excluded"
  note "the rootless store is ${EXECUTION_HOME}/.local/share/containers and ${EXECUTION_RUNTIME_DIR};"
  note "neither is readable as ${COORDINATOR}, so its inventory is an operator observation (see --blockers)"
}

# --- image build inputs ----------------------------------------------------
require_image_material() {
  local row source expected observed
  for row in "${IMAGE_MATERIAL[@]}"; do
    source="$(field "${row}" 0)"; expected="$(field "${row}" 1)"
    observed="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${observed}" == "${expected}" ]] \
      || bad "${source} is ${observed:-absent}, expected the reviewed ${expected}"
  done
  local containerfile="${REPOSITORY}/provisioning/image/Containerfile"
  # §27: the definition must name no base at all. A default here would mean the
  # image Kyri admitted and the image Kyri later built were the same text and
  # different bytes.
  grep -qE '^ARG BASE_IMAGE$' "${containerfile}" \
    || bad "the Containerfile does not declare BASE_IMAGE without a default"
  grep -qE '^ARG BASE_IMAGE=' "${containerfile}" \
    && bad "the Containerfile gives BASE_IMAGE a default"
  grep -qE '^FROM \$\{BASE_IMAGE\}$' "${containerfile}" \
    || bad "the Containerfile does not build FROM the supplied argument"
  # A floating tag anywhere in the definition is the failure §27 exists to
  # prevent, and the Track-B Alpine digest must never appear.
  grep -qiE '^(FROM|ARG BASE_IMAGE=).*(:latest|alpine)' "${containerfile}" \
    && bad "the Containerfile names a floating tag or the Track-B base"
  local banned
  for banned in apk apt-get dpkg dnf yum 'pip ' curl wget sudo ssh; do
    grep -qiE "(RUN|CMD|ENTRYPOINT).*${banned}" "${containerfile}" \
      && bad "the Containerfile invokes ${banned}"
  done
  ok "the image definition is reviewed, names no base, and pins no floating tag"
}

# --- root-execution trust model --------------------------------------------
require_operator_source() {
  local row source expected observed
  for row in "${OPERATOR_MODULES[@]}"; do
    source="$(field "${row}" 0)"; expected="$(field "${row}" 1)"
    observed="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${observed}" == "${expected}" ]] \
      || bad "${source} is ${observed:-absent}, expected the reviewed ${expected}"
  done
  ok "all five reviewed operator modules match their pinned digests"

  # The runtime half these modules import must be the same bytes the root-owned
  # runtime carries. They import ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY, both
  # schema versions and CONTAINER_INTERPRETER, and every one of those is
  # committed verbatim into an admission record -- so "which copy did root
  # import" decides what gets admitted.
  local drift=0 checked=0 file
  while IFS= read -r file; do
    checked=$((checked + 1))
    [[ "$(digest_of "${LIBRARY_ROOT}/${file}")" == "$(digest_of "${REPOSITORY}/${file}")" ]] \
      || { bad "checkout and installed runtime disagree at ${file}"; drift=$((drift + 1)); }
  done < <(cd "${LIBRARY_ROOT}" && find tools -type f -name '*.py' | sort)
  (( drift == 0 )) \
    && ok "the checkout's runtime half is byte-identical to the installed root-owned runtime (${checked} objects)"

  # Compiled bytecode is the live escalation path, and it is not hypothetical:
  # PYTHONDONTWRITEBYTECODE and -B stop root WRITING a cache, not READING one
  # the coordinator already wrote.
  local caches
  caches="$(find "${REPOSITORY}/tools" -name '__pycache__' -type d 2>/dev/null | wc -l)"
  if [[ "${caches}" -ne 0 ]]; then
    block "${caches} coordinator-owned __pycache__ directories exist under ${REPOSITORY}/tools;"
    block "  root importing from this tree would consult bytecode ${COORDINATOR} can write"
  else
    ok "no coordinator-owned bytecode cache under ${REPOSITORY}/tools"
  fi

  local mode owner
  owner="$(stat -c '%U:%G' "${REPOSITORY}/tools/provisioning" 2>/dev/null)"
  mode="$(stat -c '%a' "${REPOSITORY}/tools/provisioning" 2>/dev/null)"
  note "${REPOSITORY}/tools/provisioning is ${owner} ${mode}: writable by the coordinator"
  block "root must NOT import operator modules directly from the coordinator-writable checkout;"
  block "  see --blockers for the ruled-source staging mechanism this requires"
}

report_blockers() {
  cat <<'BLOCKERS'
Three decisions must be ruled before the G5 mutation ceremony may be written,
let alone run. Each is recorded here with what is actually true today, so the
reviewer resolves a question rather than rediscovering one.

1. NO CANDIDATE BASE IMAGE DIGEST IS RECORDED ANYWHERE.
   design §27 and provisioning/image/README.md both require admission to prove
   "the OCI base digest equals the expected candidate digest", and the
   Containerfile correctly refuses to name a base. But no expected candidate
   digest exists in this repository, so there is nothing to compare against.
   The ceremony therefore cannot be fully specified: it would have to discover
   a digest from cgr.dev at build time and admit whatever it found, which is
   the floating-tag failure wearing a digest.
   NEEDS: a reviewed candidate digest recorded in the repository, plus a
   ruling on how discovery may reach the network at all -- no build-time
   network access is currently authorised anywhere in this design.
   ALSO UNSPECIFIED: which tool produces the SBOM whose SHA-256 becomes
   `sbom_sha256`, and whether that tool's output is deterministic. The
   evidence schema requires the digest; nothing says what is hashed.

2. THE RULED AUTHORITY-NAMESPACE OWNERSHIP CANNOT BE PRODUCED AS WRITTEN.
   design §5.7 and the runbook both rule the published directories
   `root:cschott 0750` and the records `root:cschott 0440`. The reader runs as
   the coordinator and enumerates implementations/, so group read is required,
   not optional.
   But authority_bootstrap and authority_admission create every object with
   plain os.mkdir/os.open and never chown. Run as root that yields root:root,
   and the coordinator cannot read the namespace at all -- the runtime reader
   would fail and G5 could not close.
   MEASURED, not assumed: with the setgid bit on BOTH the authority root and
   staging/, group inheritance produces records at exactly the ruled
   `root:cschott 0440` and directories at `2750` rather than `0750`. Both are
   needed: implementations/ and generations/ are created directly under the
   authority root, while <CIMP>/ and <CGEN>/ are created inside staging/ and
   renamed in, and rename preserves the group it was created with.
   NEEDS: a ruling. Either accept setgid roots and amend `0750` to `2750`, or
   add an explicit ownership step to the ceremony -- but note that chowning
   after publication mutates the metadata of an object the design calls
   immutable, and a crash between publication and chown leaves the coordinator
   locked out of a namespace that already grants authority.

3. ROOT EXECUTION OF COORDINATOR-WRITABLE CODE IS NOT YET SAFE.
   The operator modules live in a checkout owned cschott:cschott, with
   tools/ and tools/provisioning/ at 0775. They import the runtime half --
   ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY, PAYLOAD_SCHEMA_VERSION,
   PROFILE_SCHEMA_VERSION, CONTAINER_INTERPRETER -- and every one of those
   constants is committed verbatim into the admission record. Whoever controls
   those bytes controls what gets admitted, which is exactly the property
   "governed values are derived, never supplied" exists to guarantee.
   Coordinator-owned __pycache__ compounds it: -B and
   PYTHONDONTWRITEBYTECODE stop root writing a cache, not reading one.
   PROPOSED, NEEDS RULING: root never executes the working tree. Instead it
   materialises the pinned commit into a root-owned 0700 directory with
   `git archive`, which reads git objects rather than the working tree, so a
   dirty or hostile tree cannot inject anything; verifies every digest there;
   and runs `python3 -I -B` with sys.path holding only that directory. That
   removes the coordinator's write authority at execution time and closes the
   verify-then-import race, which digest-checking the live checkout does not.
BLOCKERS
  printf '\n'
  block "three rulings are outstanding; the G5 mutation ceremony is not written"
}

# ===========================================================================
printf '== G5 preflight (%s) ==\n\n' "${MODE#--}"
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}"

case "${MODE}" in
--verify-host)
  require_repository
  require_generation_6
  require_snapshot_root
  require_gates_closed
  require_no_live_caller
  require_execution_identity
  require_image_material
  ;;
--verify-source)
  require_repository
  require_operator_source
  ;;
--blockers)
  report_blockers
  ;;
esac

printf '\n'
if (( FAILURES != 0 )); then
  printf 'G5 preflight %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
if (( BLOCKED != 0 )); then
  printf 'G5 preflight %s: host checks passed, %d blocker(s) outstanding.\n' \
    "${MODE#--}" "${BLOCKED}"
  printf 'Run --blockers for the full statement. The ceremony must not run yet.\n'
  exit 3
fi
printf 'G5 preflight %s: all checks passed.\n' "${MODE#--}"
printf 'Nothing was built, admitted, created, or invoked. G5 remains CLOSED.\n'
