#!/usr/bin/env bash
set -Eeuo pipefail

# READ-ONLY preflight for the ENG-0005 G5 ceremony: production image build and
# CIMP admission.
#
# THIS SCRIPT MUTATES NOTHING, IN ANY MODE. It builds no image, creates no
# authority root, runs no genesis, allocates no CIMP or CGEN, writes no sudoers
# policy, and invokes neither Podman, the transition, nor the worker. It reads
# and reports. The ceremony itself is provisioning/execution/g5-ceremony.sh.
#
# WHAT THIS IS FOR, NOW THAT THE CEREMONY EXISTS
# ==============================================
# The three architecture rulings that once blocked G5 are resolved, and
# --blockers records their resolution rather than the block. This stays the
# cheap, dependency-free check that the host is at the ruled starting position
# before an operator begins: it needs no commit, materialises nothing, and can
# be run by the coordinator.
#
# Usage:
#   g5-preflight.sh --verify-host    is this host at the ruled G5 starting state?
#   g5-preflight.sh --verify-source  is the root-owned execution model in place?
#   g5-preflight.sh --blockers       the three rulings, and how each was resolved
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
"tools/provisioning/authority_bootstrap.py|2e84ff0d9e9ee5b8ce4a410044055ab6ce1f234dc05b0964c8494d5749a1c5ef"
"tools/provisioning/authority_admission.py|32b484afb0798af1122ea8469f4bae47dc83153fbcebd0faadb0e0e0b84ebba0"
"tools/provisioning/authority_disposition.py|5f950ef2f6e7a48d3507e368aa851a363737723d7e2b85d159fd855c73a2cfc7"
"tools/provisioning/provisioning_evidence.py|1a392efffd2a1972752f838dde74921be1a464481a6c4ab4719a0e9f1188932c"
)

# The image build material, pinned for the same reason.
IMAGE_MATERIAL=(
"provisioning/image/Containerfile|f543c458fcb1793570010b58417c175e6510fe0d90d2a295ef9d38b0cfdedcbb"
"provisioning/image/README.md|9ca8002e7e70295aeffd8884318ef709b06d62f6e0d8d49f801379571307439d"
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

  # Compiled bytecode and a coordinator-writable checkout are both still facts
  # about this tree. They stopped being blockers when the ceremony stopped
  # importing the tree: root materialises the pinned commit from git objects
  # into a root-owned 0700 directory and runs `python3 -I -B` against that
  # alone. Reported, because an operator reading this should know why the
  # obvious hazard is not one, rather than not seeing it mentioned.
  local caches owner mode
  caches="$(find "${REPOSITORY}/tools" -name '__pycache__' -type d 2>/dev/null | wc -l)"
  owner="$(stat -c '%U:%G' "${REPOSITORY}/tools/provisioning" 2>/dev/null)"
  mode="$(stat -c '%a' "${REPOSITORY}/tools/provisioning" 2>/dev/null)"
  note "${caches} coordinator-owned __pycache__ directories exist under ${REPOSITORY}/tools"
  note "${REPOSITORY}/tools/provisioning is ${owner} ${mode}: writable by the coordinator"
  note "neither reaches root: see provisioning/execution/g5-ceremony.sh --verify-materialisation"

  local ceremony="${REPOSITORY}/provisioning/execution/g5-ceremony.sh"
  [[ -f "${ceremony}" ]] || bad "the G5 ceremony artifact is absent"
  # The unexpanded literal IS the assertion, so it must not expand.
  # shellcheck disable=SC2016
  grep -qF 'cat-file blob "${COMMIT}:' "${ceremony}" \
    || bad "the ceremony does not materialise from pinned git objects"
  grep -qF '/usr/bin/python3 -I -B -c' "${ceremony}" \
    || bad "the ceremony does not run Python in isolation"
  (( FAILURES == 0 )) \
    && ok "root-owned pinned-code execution is implemented; the checkout is never imported"
}

report_blockers() {
  cat <<'BLOCKERS'
All three architecture rulings that blocked the G5 ceremony are RESOLVED and
implemented. Recorded here so the resolution is as visible as the block was.

1. BASE IMAGE AUTHORITY -- RESOLVED IN MECHANISM, PENDING AN OPERATOR INPUT.
   Candidate discovery and production build are now two ceremonies with an
   operator review between them. Discovery may reach the network; its output is
   a CANDIDATE. Only a reviewed approval recorded at
   /root/kyri-g5-approved-base.txt (root:root 0400) makes the build eligible,
   and the build consumes that digest and nothing else. A tag, a :latest, or a
   digest derived from the build result is refused.
   STILL REQUIRED, and deliberately not chosen here: the candidate digest
   itself, and the exact SBOM bytes. Both are operator inputs.

2. AUTHORITY OWNERSHIP -- RESOLVED. Setgid inheritance is now the architecture,
   not a workaround. The authority root and staging/ carry 2750; published
   directories and records inherit group cschott with no chown anywhere, so
   there is no publish-then-chown window. provision_control_state no longer
   creates staging: it requires an operator-provisioned one, because whatever
   creates it decides what every published object inherits.

3. ROOT EXECUTION -- RESOLVED. Root materialises the pinned commit from git
   objects into a root-owned 0700 tree, verifies a pinned manifest digest and
   every file, and runs python3 -I -B with that tree as the only import root.
   Git runs as the repository owner, never as root. The single coordinator-
   authored artefact root executes before the boundary is the ceremony script
   itself, verified by digest in root-owned space.

Run: provisioning/execution/g5-ceremony.sh --print-plan
BLOCKERS
  printf '\n'
  ok "all three rulings are implemented; the ceremony is prepared"
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
