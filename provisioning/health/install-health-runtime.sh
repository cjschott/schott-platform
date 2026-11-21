#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0006-H18 Health runtime ceremony: the kyri-health identity, the
# approval and store roots, and the reviewed runtime, installed root-owned.
#
# NOTHING HERE HAS BEEN EXECUTED AGAINST PRODUCTION. Every mutation refuses
# until its preconditions hold, and nothing that already exists is repaired.
#
# =============================================================================
# HOW ROOT COMES TO TRUST WHAT IT INSTALLS
# =============================================================================
# The checkout is writable by the repository owner, and on a host where an
# agent has ever run, by whatever that agent was. So root never executes or
# imports anything from it (finalization §4.3):
#
#   reviewed commit -> git blob, read as the repository owner -> root-only
#   stage -> sha256 against the digests pinned below -> root-owned install
#
# Every payload byte comes from `git cat-file blob <COMMIT>:<path>`, run AS THE
# REPOSITORY OWNER through runuser, never as root: git reads the repository's
# own configuration, which can name programs to run. Root treats what git
# returns as untrusted input and installs nothing whose digest is not the
# pinned one. No payload is executed during installation.
#
# THE ONE THING ROOT RUNS BEFORE THAT BOUNDARY is this script, and only after
# the operator has copied it into root-owned space and checked its SHA-256
# against the reviewed value recorded off-host. See --bootstrap-instructions.
# It sources nothing, reads no configuration, sets PATH, umask and the working
# directory itself, and names trust-critical binaries absolutely.
#
# WHAT IT ESTABLISHES (preflight §6.3, finalization §6)
#   kyri-health                         system user, own group, no other group,
#                                       /usr/sbin/nologin, locked password,
#                                       home /nonexistent, no sudoers entry
#   /var/lib/kyri/health-approvals      root:root 0755   statements root 0444
#   /var/lib/kyri/health-approvals/.staging  root:root 0700
#   /var/lib/kyri/health                kyri-health 0700, laid out as the store
#   /usr/lib/kyri/health                root:root 0755/0444, the library closure
#   /usr/libexec/kyri-health-{approve,ingest,verify}  root:root 0555
#   /etc/systemd/system/kyri-health-verify.{service,timer}  root:root 0644
#
# No sudoers rule is written: approval runs under the operator's own
# password sudo, and ingestion under `sudo -u kyri-health`.
#
# NOTHING IS REPAIRED. Absent -> created. Present and exactly right ->
# accepted, unchanged. Present and different in any respect -> refused, left
# exactly as it is. A wrong owner or mode is operator-visible evidence;
# correcting it would erase the evidence and grant the trust being withheld.
#
# ROLLBACK (--uninstall) removes the runtime only: the helpers, the units and
# the library, each only if it is byte-for-byte the reviewed object. The
# identity, the store and the approvals are evidence and are never removed.
#
# =============================================================================
# USAGE
# =============================================================================
#   --bootstrap-instructions  how to get this script into root-owned space
#   --verify                  read-only: may the runtime be installed?
#   --install                 create what is absent, verify everything
#   --verify-installed        read-only: is the installation exactly right?
#                             Reads no repository.
#   --uninstall               remove the runtime; keep identity and evidence
#
# Test-only:
#   --fixture DIR     operate on a fixture tree: ownership is the invoking
#                     user's, the account database is DIR/etc, and systemd is
#                     not touched. Every other check is the production path.
#   --repository DIR  the checkout to read; only with --fixture.

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C
umask 077
cd /

REPOSITORY="/opt/schott-platform"
BRANCH="arch/eng-0006-health-runtime"

# The reviewed commit carrying the runtime. Pinned, never HEAD, and not an
# argument: a ceremony whose source revision is caller-supplied pins nothing.
# This script's own commit is necessarily later than the bytes it installs.
COMMIT="5131dfcff560295d5d2c83d411255c0310de9911"

SERVICE_USER="kyri-health"
SERVICE_HOME="/nonexistent"
SERVICE_SHELL="/usr/sbin/nologin"
SERVICE_COMMENT="Kyri Health runtime"

KYRI_STATE="/var/lib/kyri"                          # prod-path-reference
APPROVAL_ROOT="/var/lib/kyri/health-approvals"      # prod-path-reference
STORE_ROOT="/var/lib/kyri/health"                   # prod-path-reference
LIBRARY_PARENT="/usr/lib/kyri"
LIBRARY_ROOT="/usr/lib/kyri/health"
TIMER="kyri-health-verify.timer"
SERVICE_UNIT="kyri-health-verify.service"

# source | installed path | mode | sha256 of the blob at COMMIT
#
# The library is the import closure of tools.health.operator and nothing
# else: no Trust, Fabric or Capability module is installed here.
MATRIX=(
"tools/__init__.py|/usr/lib/kyri/health/tools/__init__.py|0444|04d746acb547b933f2746601ce418f21a3a57ca2dd24a5cf399b81565bc4d672"
"tools/common/__init__.py|/usr/lib/kyri/health/tools/common/__init__.py|0444|38bf0e8be30f28c1325ef85c38f21856a377b2647e0a4abf71e67cb2e85f3fc6"
"tools/common/canonical_json.py|/usr/lib/kyri/health/tools/common/canonical_json.py|0444|11c76d9750290e6196532984afa420084ce41b918a828079d19a1ae27742f2e4"
"tools/common/immutable_store.py|/usr/lib/kyri/health/tools/common/immutable_store.py|0444|265fc791a7cd8ca28b41876bd8c81793c5524b52053a581d6de8e8d19baa59e8"
"tools/common/trusted_source.py|/usr/lib/kyri/health/tools/common/trusted_source.py|0444|d1e8ac5933834deb7b7aa07a847312ac10d8c4e3f0c0d2d93400c6eafe04865f"
"tools/health/__init__.py|/usr/lib/kyri/health/tools/health/__init__.py|0444|483ef0f49c0ee2adadd09a9b42c3a531fca19bf831e5433938cc6f62cffda0bd"
"tools/health/conditions.py|/usr/lib/kyri/health/tools/health/conditions.py|0444|64f49703f4aeffbf6c084f02af73714acd8c19110011d96b556eccdede9a7cfd"
"tools/health/errors.py|/usr/lib/kyri/health/tools/health/errors.py|0444|323d50507522171dc1c88ff41f6bb6421e24b9a3c97759e007251403346d3e29"
"tools/health/freshness.py|/usr/lib/kyri/health/tools/health/freshness.py|0444|72fe86b0db22d4388b89d18c26a60044b849e78ce7682247760295a634048f7b"
"tools/health/hysteresis.py|/usr/lib/kyri/health/tools/health/hysteresis.py|0444|e01fc80ac5cdac92ef230d7f3af77322a799ad8ca699c6aa7260ed2f6bc4454f"
"tools/health/ingest.py|/usr/lib/kyri/health/tools/health/ingest.py|0444|e5596f00a6ff24fcafff8d1e70415e61ac2a8808c99228d59c062e62c5673d47"
"tools/health/operator.py|/usr/lib/kyri/health/tools/health/operator.py|0444|f6af67c5c93aeb6f774d00b73d8c694fffe78164e3a388c46a3a7ccc6c7598ee"
"tools/health/records.py|/usr/lib/kyri/health/tools/health/records.py|0444|d54a6b10ef724d85692e062a383de2187fd58219ec18e3f689d94cd1e377474c"
"tools/health/store.py|/usr/lib/kyri/health/tools/health/store.py|0444|cb6c27d2d3e4a149c716d218ffb1684f4c0ebef752222904b77d54b4a95d4a22"
"provisioning/health/kyri-health-approve.py|/usr/libexec/kyri-health-approve|0555|3e13df9d6a8b48339268bb6a31505862b2baa85afd058c7491829ee60e8bb5c7"
"provisioning/health/kyri-health-ingest.py|/usr/libexec/kyri-health-ingest|0555|beefcec648f12097a0ed1629f63b63858633d5879dd77b18227ab99dd54cf61b"
"provisioning/health/kyri-health-verify.py|/usr/libexec/kyri-health-verify|0555|e1c2c1a65354e84f69d0de44bbf92e849828eed9381be7692674ed58e6185fea"
"provisioning/health/kyri-health-verify.service|/etc/systemd/system/kyri-health-verify.service|0644|c7d5dfc1f2676a7e0a3b3ce69a85c351ca112e0ce59c1a047556c7e0cb6d8892"
"provisioning/health/kyri-health-verify.timer|/etc/systemd/system/kyri-health-verify.timer|0644|f6b0906a4fd948eb7fd080829fd212bd3b03d49384d962598519d1f0ce4b6295"
)

# The store's layout: `HealthStore`'s record directories and `sequences`, and
# the lock file it opens. The library refuses to create the production root,
# so the ceremony lays it out; the suite proves this list is what
# HealthStore(initialize=True) creates.
STORE_LAYOUT=(
capability-degradation-events
capability-health-envelopes
capability-health-observations
capability-health-recommendations
capability-health-states
capability-heartbeats
sequences
)
STORE_LOCK="sequences/request_identity.lock"

# Interrupted-ceremony residue, by fixed name, so it is found rather than
# guessed at. --install refuses it; --uninstall removes it.
LIBRARY_STAGING_NAME=".health-staging"
LIBRARY_REMOVING_NAME=".health-removing"
FILE_STAGING_SUFFIX=".kyri-health-staging"

MODE=""
FIXTURE=""
FIXTURE_REPOSITORY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-instructions|--verify|--install|--verify-installed|--uninstall)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2 || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      [[ "${FIXTURE}" == /* && "${FIXTURE}" != "/" && -d "${FIXTURE}" ]] \
        || { printf 'ERROR --fixture needs an existing absolute directory\n' >&2; exit 2; }
      ;;
    --repository)
      FIXTURE_REPOSITORY="${2:-}"; shift 2 || { printf 'ERROR --repository needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify}"
if [[ -n "${FIXTURE_REPOSITORY}" ]]; then
  [[ -n "${FIXTURE}" ]] || { printf 'ERROR --repository is test-only and needs --fixture\n' >&2; exit 2; }
  REPOSITORY="${FIXTURE_REPOSITORY}"
fi

FAILURES=0
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

field() { local -a _f; IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
at() { printf '%s%s' "${FIXTURE}" "$1"; }

ETC="$(at /etc)"

# Production objects are root's, and the store is the service identity's.
# Under a fixture nothing is chowned, so the invoking account owns what it
# made, and the fixture account is created with the invoking account's
# numbers: the expectation is stated once here rather than skipped per check.
if [[ -n "${FIXTURE}" ]]; then
  ROOT_IDS="$(/usr/bin/id -u):$(/usr/bin/id -g)"
else
  ROOT_IDS="0:0"
fi

# --- the account database ------------------------------------------------------
# Read from the files, not through NSS, so the fixture and production are
# judged by one parser. Production also asks NSS and sudo below.

db_count() { awk -F: -v n="$2" '$1 == n { c++ } END { print c + 0 }' "${ETC}/$1" 2>/dev/null || printf '0'; }
db_field() { awk -F: -v n="$2" -v f="$3" '$1 == n { print $f; exit }' "${ETC}/$1" 2>/dev/null || true; }

SERVICE_IDS=""
identity_problems() {
  local problems=0 uid gid shell home groups members password users
  uid="$(db_field passwd "${SERVICE_USER}" 3)"
  gid="$(db_field passwd "${SERVICE_USER}" 4)"
  home="$(db_field passwd "${SERVICE_USER}" 6)"
  shell="$(db_field passwd "${SERVICE_USER}" 7)"
  [[ "$(db_count passwd "${SERVICE_USER}")" == "1" ]] \
    || { bad "${SERVICE_USER} has $(db_count passwd "${SERVICE_USER}") passwd entries"; return 1; }
  [[ "${uid}" =~ ^[0-9]+$ && "${uid}" != "0" ]] || { bad "${SERVICE_USER} uid is ${uid}"; problems=$((problems + 1)); }
  [[ "${gid}" =~ ^[0-9]+$ && "${gid}" != "0" ]] || { bad "${SERVICE_USER} gid is ${gid}"; problems=$((problems + 1)); }
  if [[ -z "${FIXTURE}" ]] && (( uid >= 1000 )); then
    bad "${SERVICE_USER} uid ${uid} is not a system uid"; problems=$((problems + 1))
  fi
  [[ "${shell}" == "${SERVICE_SHELL}" ]] || { bad "${SERVICE_USER} shell is ${shell}"; problems=$((problems + 1)); }
  [[ "${home}" == "${SERVICE_HOME}" ]] || { bad "${SERVICE_USER} home is ${home}"; problems=$((problems + 1)); }
  [[ ! -e "$(at "${SERVICE_HOME}")" ]] || { bad "${SERVICE_HOME} exists"; problems=$((problems + 1)); }

  [[ "$(db_count group "${SERVICE_USER}")" == "1" ]] \
    || { bad "group ${SERVICE_USER} has $(db_count group "${SERVICE_USER}") entries"; problems=$((problems + 1)); }
  [[ "$(db_field group "${SERVICE_USER}" 3)" == "${gid}" ]] \
    || { bad "group ${SERVICE_USER} is not ${SERVICE_USER}'s primary group"; problems=$((problems + 1)); }
  [[ "$(awk -F: -v g="${gid}" '$3 == g { c++ } END { print c + 0 }' "${ETC}/group")" == "1" ]] \
    || { bad "gid ${gid} is shared by more than one group"; problems=$((problems + 1)); }
  [[ -z "$(db_field group "${SERVICE_USER}" 4)" ]] \
    || { bad "group ${SERVICE_USER} lists members"; problems=$((problems + 1)); }
  # No supplementary group of any kind: sudo, docker, lxd and adm included.
  groups="$(awk -F: -v n="${SERVICE_USER}" '{ k = split($4, m, ","); for (i = 1; i <= k; i++) if (m[i] == n) print $1 }' "${ETC}/group" | tr '\n' ' ')"
  [[ -z "${groups}" ]] || { bad "${SERVICE_USER} is a member of: ${groups}"; problems=$((problems + 1)); }
  [[ "$(db_count shadow "${SERVICE_USER}")" == "1" ]] \
    || { bad "${SERVICE_USER} has $(db_count shadow "${SERVICE_USER}") shadow entries"; problems=$((problems + 1)); }
  password="$(db_field shadow "${SERVICE_USER}" 2)"
  [[ "${password}" == '!'* || "${password}" == '*'* ]] \
    || { bad "${SERVICE_USER} has a usable password"; problems=$((problems + 1)); }
  if grep -rsqw -- "${SERVICE_USER}" "${ETC}/sudoers" "${ETC}/sudoers.d"; then
    bad "the sudoers policy names ${SERVICE_USER}"; problems=$((problems + 1))
  fi
  if [[ -z "${FIXTURE}" ]]; then
    users="$(/usr/bin/id -nG "${SERVICE_USER}" 2>/dev/null || true)"
    [[ "${users}" == "${SERVICE_USER}" ]] \
      || { bad "NSS reports ${SERVICE_USER}'s groups as: ${users}"; problems=$((problems + 1)); }
    members="$(/usr/bin/sudo -n -l -U "${SERVICE_USER}" 2>&1 || true)"
    [[ "${members}" == *"is not allowed to run sudo"* ]] \
      || { bad "sudo grants ${SERVICE_USER} something"; problems=$((problems + 1)); }
  fi
  (( problems == 0 )) && SERVICE_IDS="${uid}:${gid}"
  return "${problems}"
}

# absent | present (and correct) ; anything else halts.
identity_state() {
  if [[ "$(db_count passwd "${SERVICE_USER}")" == "0" ]]; then
    [[ "$(db_count group "${SERVICE_USER}")" == "0" && "$(db_count shadow "${SERVICE_USER}")" == "0" ]] \
      || halt "${SERVICE_USER} has no passwd entry but has a group or shadow entry; the account is ambiguous and is not adopted"
    printf 'absent'
    return
  fi
  identity_problems >&2 || halt "${SERVICE_USER} exists and is not the ruled identity; it is not modified"
  printf 'present'
}

create_identity() {
  if [[ -n "${FIXTURE}" ]]; then
    printf '%s:x:%s:%s:%s:%s:%s\n' "${SERVICE_USER}" "$(/usr/bin/id -u)" "$(/usr/bin/id -g)" \
      "${SERVICE_COMMENT}" "${SERVICE_HOME}" "${SERVICE_SHELL}" >> "${ETC}/passwd"
    printf '%s:x:%s:\n' "${SERVICE_USER}" "$(/usr/bin/id -g)" >> "${ETC}/group"
    printf '%s:!:20000:0:99999:7:::\n' "${SERVICE_USER}" >> "${ETC}/shadow"
  else
    /usr/sbin/useradd --system --user-group --no-create-home \
      --home-dir "${SERVICE_HOME}" --shell "${SERVICE_SHELL}" \
      --comment "${SERVICE_COMMENT}" "${SERVICE_USER}"
  fi
  identity_problems || halt "${SERVICE_USER} was created but is not the ruled identity"
  ok "created ${SERVICE_USER} (${SERVICE_IDS}): no other group, ${SERVICE_SHELL}, locked"
}

# --- paths -----------------------------------------------------------------------

# One existing directory, exactly: not a symlink, a directory, the owner and
# mode given.
check_dir() {
  local path="$1" ids="$2" mode="$3"
  [[ ! -L "${path}" && -d "${path}" ]] || { bad "${path} is not a directory"; return 1; }
  [[ "$(stat -c '%u:%g' "${path}")" == "${ids}" ]] \
    || { bad "${path} is owned $(stat -c '%u:%g' "${path}"), expected ${ids}"; return 1; }
  [[ "$(stat -c '%a' "${path}")" == "${mode}" ]] \
    || { bad "${path} is mode $(stat -c '%a' "${path}"), expected ${mode}"; return 1; }
}

# One existing file, exactly, including its bytes.
check_file() {
  local path="$1" ids="$2" mode="$3" digest="$4" problems=0
  [[ ! -L "${path}" && -f "${path}" ]] || { bad "${path} is not a regular file"; return 1; }
  [[ "$(stat -c '%u:%g' "${path}")" == "${ids}" ]] \
    || { bad "${path} is owned $(stat -c '%u:%g' "${path}"), expected ${ids}"; problems=$((problems + 1)); }
  [[ "$(stat -c '%a' "${path}")" == "${mode#0}" ]] \
    || { bad "${path} is mode $(stat -c '%a' "${path}"), expected ${mode}"; problems=$((problems + 1)); }
  [[ "$(stat -c '%h' "${path}")" == "1" ]] \
    || { bad "${path} carries more than one link"; problems=$((problems + 1)); }
  if [[ -n "${digest}" && "$(digest_of "${path}")" != "${digest}" ]]; then
    bad "${path} is not the reviewed bytes"; problems=$((problems + 1))
  fi
  return "${problems}"
}

# Every existing ancestor of a path we create or install into: a real
# directory, its ruled owner's, writable by no one else. Checked up to / (or
# the fixture). The ruled owner is root, except for the store and anything
# under it, which are the service identity's (and fail if it does not exist).
check_ancestry() {
  local path store owner problems=0
  path="$(dirname "$1")"
  store="$(at "${STORE_ROOT}")"
  while [[ -n "${path}" && "${path}" != "/" && "${path}" != "${FIXTURE}" ]]; do
    if [[ "${path}" == "${store}" || "${path}" == "${store}/"* ]]; then
      owner="${SERVICE_IDS%%:*}"
    else
      owner="${ROOT_IDS%%:*}"
    fi
    if [[ -e "${path}" || -L "${path}" ]]; then
      if [[ -L "${path}" || ! -d "${path}" ]]; then
        bad "${path} is not a directory"; problems=$((problems + 1))
      elif [[ -z "${owner}" ]]; then
        bad "${path} exists but ${SERVICE_USER} does not"; problems=$((problems + 1))
      elif [[ "$(stat -c '%u' "${path}")" != "${owner}" ]]; then
        bad "${path} is not owned by uid ${owner}"; problems=$((problems + 1))
      elif [[ -n "$(find "${path}" -maxdepth 0 -perm /022)" ]]; then
        bad "${path} is writable beyond its owner"; problems=$((problems + 1))
      fi
    fi
    path="$(dirname "${path}")"
  done
  return "${problems}"
}

# The state directories, in creation order: path | owner (root|service) | mode.
state_directories() {
  printf '%s|root|755\n' "${APPROVAL_ROOT}"
  printf '%s|root|700\n' "${APPROVAL_ROOT}/.staging"
  printf '%s|service|700\n' "${STORE_ROOT}"
  local name
  for name in "${STORE_LAYOUT[@]}"; do printf '%s|service|700\n' "${STORE_ROOT}/${name}"; done
}

ids_for() { if [[ "$1" == "root" ]]; then printf '%s' "${ROOT_IDS}"; else printf '%s' "${SERVICE_IDS}"; fi; }

# /var/lib/kyri itself is shared with the other planes and is never changed
# here: it must be root's, writable by no one else, and traversable, so the
# service identity can reach the store and the approvals.
check_kyri_state() {
  local path; path="$(at "${KYRI_STATE}")"
  [[ -e "${path}" || -L "${path}" ]] || return 0
  check_ancestry "${path}/x" || return 1
  [[ -n "$(find "${path}" -maxdepth 0 -perm -0001)" ]] \
    || { bad "${path} is not traversable by other users"; return 1; }
}

# absent | present ; a wrong existing object is a FAIL line.
state_report() {
  local row path owner mode problems=0
  check_kyri_state || problems=$((problems + 1))
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 0)")"; owner="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    check_ancestry "${path}" || problems=$((problems + 1))
    if [[ -e "${path}" || -L "${path}" ]]; then
      if [[ "${owner}" == "service" && -z "${SERVICE_IDS}" ]]; then
        bad "${path} exists but ${SERVICE_USER} does not"; problems=$((problems + 1))
      else
        check_dir "${path}" "$(ids_for "${owner}")" "${mode}" || problems=$((problems + 1))
      fi
    fi
  done < <(state_directories)
  path="$(at "${STORE_ROOT}/${STORE_LOCK}")"
  if [[ -e "${path}" || -L "${path}" ]]; then
    if [[ -z "${SERVICE_IDS}" ]]; then
      bad "${path} exists but ${SERVICE_USER} does not"; problems=$((problems + 1))
    else
      check_file "${path}" "${SERVICE_IDS}" 600 "" || problems=$((problems + 1))
    fi
  fi
  return "${problems}"
}

create_state() {
  local row path owner mode ids created=0
  path="$(at "${KYRI_STATE}")"
  if [[ ! -e "${path}" ]]; then
    /usr/bin/install -d -m 0711 "${path}"
    [[ -n "${FIXTURE}" ]] || chown 0:0 "${path}"
    created=$((created + 1))
  fi
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 0)")"; owner="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    [[ -e "${path}" ]] && continue
    ids="$(ids_for "${owner}")"
    mkdir -m "${mode}" "${path}"
    [[ -n "${FIXTURE}" ]] || chown "${ids}" "${path}"
    chmod "${mode}" "${path}"
    check_dir "${path}" "${ids}" "${mode}" || halt "${path} was created but is not as ruled"
    created=$((created + 1))
  done < <(state_directories)
  path="$(at "${STORE_ROOT}/${STORE_LOCK}")"
  if [[ ! -e "${path}" ]]; then
    : > "${path}"
    [[ -n "${FIXTURE}" ]] || chown "${SERVICE_IDS}" "${path}"
    chmod 600 "${path}"
    created=$((created + 1))
  fi
  ok "state directories in place (${created} created)"
}

# --- the runtime objects -----------------------------------------------------------

library_rows() { local row; for row in "${MATRIX[@]}"; do [[ "$(field "${row}" 1)" == "${LIBRARY_ROOT}/"* ]] && printf '%s\n' "${row}"; done; }
file_rows()    { local row; for row in "${MATRIX[@]}"; do [[ "$(field "${row}" 1)" != "${LIBRARY_ROOT}/"* ]] && printf '%s\n' "${row}"; done; }

# The library tree at $1 must hold exactly the closure: these files with
# these bytes, the directories they imply, nothing else.
check_library_at() {
  local tree="$1" row relative expected observed problems=0
  check_dir "${tree}" "${ROOT_IDS}" 755 || return 1
  expected="$(
    while IFS= read -r row; do
      relative="$(field "${row}" 1)"; relative="${relative#"${LIBRARY_ROOT}/"}"
      printf 'f|%s|%s|444|1\n' "${relative}" "${ROOT_IDS}"
      while [[ "${relative}" == */* ]]; do
        relative="${relative%/*}"
        printf 'd|%s|%s|755|-\n' "${relative}" "${ROOT_IDS}"
      done
    done < <(library_rows) | sort -u)"
  observed="$(find "${tree}" -mindepth 1 -printf '%y|%P|%U:%G|%m|%n\n' \
    | awk -F'|' '{ if ($1 == "d") $5 = "-"; print }' OFS='|' | sort)"
  [[ "${observed}" == "${expected}" ]] \
    || { bad "${tree} does not hold exactly the reviewed closure: $(diff <(printf '%s\n' "${expected}") <(printf '%s\n' "${observed}") | grep '^[<>]' | head -3 | tr '\n' ' ')"; problems=$((problems + 1)); }
  while IFS= read -r row; do
    relative="$(field "${row}" 1)"; relative="${relative#"${LIBRARY_ROOT}/"}"
    [[ ! -f "${tree}/${relative}" || "$(digest_of "${tree}/${relative}")" == "$(field "${row}" 3)" ]] \
      || { bad "${tree}/${relative} is not the reviewed bytes"; problems=$((problems + 1)); }
  done < <(library_rows)
  return "${problems}"
}

# Prints how many runtime objects are present; FAIL lines for any that differ.
runtime_report() {
  local present=0 problems=0 row path
  path="$(at "${LIBRARY_ROOT}")"
  check_ancestry "${path}" || problems=$((problems + 1))
  if [[ -e "${path}" || -L "${path}" ]]; then
    present=$((present + 1))
    check_library_at "${path}" || problems=$((problems + 1))
  fi
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 1)")"
    check_ancestry "${path}" || problems=$((problems + 1))
    [[ -d "$(dirname "${path}")" ]] || { bad "$(dirname "${path}") does not exist"; problems=$((problems + 1)); }
    if [[ -e "${path}" || -L "${path}" ]]; then
      present=$((present + 1))
      check_file "${path}" "${ROOT_IDS}" "$(field "${row}" 2)" "$(field "${row}" 3)" \
        || problems=$((problems + 1))
    fi
  done < <(file_rows)
  RUNTIME_PRESENT="${present}"
  return "${problems}"
}
RUNTIME_PRESENT=0
RUNTIME_TOTAL=$(( 1 + $(file_rows | wc -l) ))

residue() {
  local row path
  for path in "$(at "${LIBRARY_PARENT}")/${LIBRARY_STAGING_NAME}" \
              "$(at "${LIBRARY_PARENT}")/${LIBRARY_REMOVING_NAME}"; do
    [[ -e "${path}" || -L "${path}" ]] && printf '%s\n' "${path}"
  done
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 1)")"
    path="$(dirname "${path}")/.$(basename "${path}")${FILE_STAGING_SUFFIX}"
    [[ -e "${path}" || -L "${path}" ]] && printf '%s\n' "${path}"
  done < <(file_rows)
  return 0
}

# --- the reviewed source -----------------------------------------------------------

REPO_OWNER=""
git_as_owner() {
  if [[ "$(/usr/bin/id -un)" == "${REPO_OWNER}" ]]; then
    /usr/bin/git -C "${REPOSITORY}" "$@"
  else
    /usr/sbin/runuser -u "${REPO_OWNER}" -- /usr/bin/git -C "${REPOSITORY}" "$@"
  fi
}

STAGE=""
cleanup() { [[ -z "${STAGE}" ]] || rm -rf -- "${STAGE}"; }
trap cleanup EXIT

# Every payload object, read from the pinned commit as the repository owner
# into a root-only stage and checked against its pinned digest. Nothing is
# installed unless all of them agree.
fetch_payload() {
  [[ -d "${REPOSITORY}" ]] || halt "${REPOSITORY} is not a directory"
  REPO_OWNER="$(stat -c '%U' "${REPOSITORY}")"
  [[ "${REPO_OWNER}" != "root" ]] || halt "${REPOSITORY} is owned by root, so git would run as root"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} does not exist in ${REPOSITORY}"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${COMMIT} is not an ancestor of HEAD"
  if [[ -z "${FIXTURE}" ]]; then
    [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
      || halt "the checkout is not on ${BRANCH}"
  else
    note "fixture: the checkout's branch is not checked"
  fi
  local parent; parent="$(at /root)"
  [[ -d "${parent}" ]] || mkdir -m 0700 "${parent}"
  STAGE="$(mktemp -d "${parent}/kyri-health-stage.XXXXXXXX")"
  chmod 0700 "${STAGE}"
  local row index=0 source
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${STAGE}/${index}" 2>/dev/null \
      || halt "the reviewed commit does not carry ${source}"
    [[ "$(digest_of "${STAGE}/${index}")" == "$(field "${row}" 3)" ]] \
      || halt "${source} at ${COMMIT:0:12} is not the reviewed bytes; nothing was installed"
    index=$((index + 1))
  done
  ok "${#MATRIX[@]} payload objects at ${COMMIT:0:12} match their pinned digests (read as ${REPO_OWNER})"
}

staged_for() {
  local index=0 row
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 1)" == "$1" ]] && { printf '%s/%s' "${STAGE}" "${index}"; return; }
    index=$((index + 1))
  done
  halt "no staged object for $1"
}

install_library() {
  local tree staging row destination
  tree="$(at "${LIBRARY_ROOT}")"
  [[ -e "${tree}" ]] && { ok "${LIBRARY_ROOT} is already the reviewed closure"; return; }
  if [[ ! -e "$(at "${LIBRARY_PARENT}")" ]]; then
    mkdir -m 0755 "$(at "${LIBRARY_PARENT}")"
    [[ -n "${FIXTURE}" ]] || chown 0:0 "$(at "${LIBRARY_PARENT}")"
  fi
  staging="$(at "${LIBRARY_PARENT}")/${LIBRARY_STAGING_NAME}"
  mkdir -m 0700 "${staging}"
  while IFS= read -r row; do
    destination="${staging}/$(field "${row}" 1 | sed "s|^${LIBRARY_ROOT}/||")"
    mkdir -p "$(dirname "${destination}")"
    cp -- "$(staged_for "$(field "${row}" 1)")" "${destination}"
    chmod 0444 "${destination}"
  done < <(library_rows)
  find "${staging}" -type d -exec chmod 0755 {} +
  [[ -n "${FIXTURE}" ]] || chown -R 0:0 "${staging}"
  check_library_at "${staging}" || halt "the staged library is not the reviewed closure; ${staging} is left for inspection"
  # One rename publishes the whole tree; the name is never a partial library.
  mv -T -- "${staging}" "${tree}" || halt "${tree} appeared during installation; it is not replaced"
  ok "installed ${LIBRARY_ROOT} ($(library_rows | wc -l) modules)"
}

install_files() {
  local row destination staging mode
  while IFS= read -r row; do
    destination="$(at "$(field "${row}" 1)")"; mode="$(field "${row}" 2)"
    if [[ -e "${destination}" ]]; then
      ok "$(field "${row}" 1) is already the reviewed bytes"
      continue
    fi
    staging="$(dirname "${destination}")/.$(basename "${destination}")${FILE_STAGING_SUFFIX}"
    cp -- "$(staged_for "$(field "${row}" 1)")" "${staging}"
    [[ -n "${FIXTURE}" ]] || chown 0:0 "${staging}"
    chmod "${mode}" "${staging}"
    check_file "${staging}" "${ROOT_IDS}" "${mode}" "$(field "${row}" 3)" \
      || halt "${staging} is not the reviewed object; it is left for inspection"
    # -n refuses rather than replaces, so an object that appeared since the
    # check is never overwritten.
    mv -n -T -- "${staging}" "${destination}"
    [[ ! -e "${staging}" ]] || halt "${destination} appeared during installation; it is not replaced"
    ok "installed $(field "${row}" 1) (${mode})"
  done < <(file_rows)
}

systemd_enable() {
  if [[ -n "${FIXTURE}" ]]; then
    note "fixture: systemd is not touched (daemon-reload; enable --now ${TIMER})"
    return
  fi
  /usr/bin/systemctl daemon-reload
  /usr/bin/systemctl enable --now "${TIMER}"
  ok "${TIMER} enabled and started"
}

systemd_check() {
  if [[ -n "${FIXTURE}" ]]; then
    note "fixture: ${TIMER} state is not checked"
    return 0
  fi
  [[ "$(/usr/bin/systemctl is-enabled "${TIMER}" 2>/dev/null)" == "enabled" ]] \
    || bad "${TIMER} is not enabled"
  [[ "$(/usr/bin/systemctl is-active "${TIMER}" 2>/dev/null)" == "active" ]] \
    || bad "${TIMER} is not active"
}

require_root() {
  [[ -n "${FIXTURE}" || "$(/usr/bin/id -u)" == "0" ]] || halt "this mode reads the shadow and sudoers files and must run as root"
}

require_interpreter() {
  local python="/usr/bin/python3"
  [[ -x "${python}" && "$(stat -L -c '%u' "${python}")" == "0" ]] \
    || halt "${python} is not a root-owned interpreter"
  if [[ -n "${FIXTURE}" ]]; then
    # The host's interpreter is a property of the host, not of the fixture.
    note "fixture: ${python}'s isolated-mode yaml and version are not checked"
    return
  fi
  "${python}" -I -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null \
    || halt "${python} -I cannot import yaml, or is older than 3.10 (install python3-yaml)"
  ok "${python} is root-owned, 3.10 or later, and imports yaml in isolated mode"
}

# --- modes -------------------------------------------------------------------------

bootstrap_instructions() {
  cat <<EOF
Run on the production host, from a login session that hosts no agent
(check with: ps -u "\$(id -un)" -o pid,comm). Values in <> come from the
H18 review record, which is kept off this host.

  REVIEWED=<installer commit, 40 hex>
  EXPECTED=<sha256 of provisioning/health/install-health-runtime.sh at REVIEWED>

  sudo install -d -o root -g root -m 0700 /root/kyri-health-install
  git -C ${REPOSITORY} cat-file blob "\${REVIEWED}:provisioning/health/install-health-runtime.sh" \\
    | sudo tee /root/kyri-health-install/install-health-runtime.sh >/dev/null
  sudo sha256sum /root/kyri-health-install/install-health-runtime.sh
      -> must print \${EXPECTED}; if it does not, stop.
  sudo bash /root/kyri-health-install/install-health-runtime.sh --verify
  sudo bash /root/kyri-health-install/install-health-runtime.sh --install
  sudo bash /root/kyri-health-install/install-health-runtime.sh --verify-installed

git runs as you, the repository owner; only the verified copy runs as root.
The script then reads every payload from commit ${COMMIT:0:12} and refuses
any whose digest is not pinned in it.
EOF
}

preflight() {
  require_root
  require_interpreter
  fetch_payload
  local state
  state="$(identity_state)"
  if [[ "${state}" == "present" ]]; then
    identity_problems >/dev/null 2>&1 || true
    ok "${SERVICE_USER} exists and is the ruled identity (${SERVICE_IDS})"
  else
    ok "${SERVICE_USER} is absent; --install would create it"
  fi
  FAILURES=0
  state_report || true
  runtime_report || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s): existing objects are not as ruled; nothing is created, changed or repaired"
  local leftover; leftover="$(residue)"
  [[ -z "${leftover}" ]] || halt "interrupted-ceremony residue is not adopted: ${leftover//$'\n'/ } (--uninstall removes it)"
  ok "existing state and runtime objects are as ruled; ${RUNTIME_PRESENT}/${RUNTIME_TOTAL} runtime objects present"
}

verify_installed() {
  require_root
  FAILURES=0
  if [[ "$(db_count passwd "${SERVICE_USER}")" == "0" ]]; then
    bad "${SERVICE_USER} does not exist"
  else
    identity_problems || true
  fi
  local row path
  [[ -d "$(at "${KYRI_STATE}")" ]] || bad "$(at "${KYRI_STATE}") does not exist"
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 0)")"
    [[ -e "${path}" || -L "${path}" ]] || bad "${path} does not exist"
  done < <(state_directories)
  [[ -e "$(at "${STORE_ROOT}/${STORE_LOCK}")" ]] || bad "$(at "${STORE_ROOT}/${STORE_LOCK}") does not exist"
  state_report || true
  runtime_report || true
  (( RUNTIME_PRESENT == RUNTIME_TOTAL )) \
    || bad "${RUNTIME_PRESENT}/${RUNTIME_TOTAL} runtime objects are installed"
  [[ -z "$(residue)" ]] || bad "interrupted-ceremony residue present: $(residue | tr '\n' ' ')"
  systemd_check
}

case "${MODE}" in
--bootstrap-instructions)
  bootstrap_instructions
  ;;
--verify)
  printf '── Health runtime: may the reviewed runtime be installed?\n\n'
  preflight
  printf '\nREADY\n'
  ;;
--install)
  printf '── Health runtime: installing the reviewed runtime\n\n'
  preflight
  [[ "$(identity_state)" == "present" ]] || create_identity
  identity_problems >/dev/null 2>&1 || halt "${SERVICE_USER} is not the ruled identity"
  create_state
  install_library
  install_files
  systemd_enable
  verify_installed
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s) after installation"
  ok "the installation verifies"
  printf '\nDONE\n'
  ;;
--verify-installed)
  printf '── Health runtime: is the installation exactly right?\n\n'
  verify_installed
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s)"
  ok "identity, state directories and ${RUNTIME_TOTAL} runtime objects are as reviewed at ${COMMIT:0:12}"
  printf '\nVERIFIED\n'
  ;;
--uninstall)
  printf '── Health runtime: removing the runtime (identity and evidence are kept)\n\n'
  require_root
  FAILURES=0
  runtime_report || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s): an installed object is not the reviewed one; nothing is removed"
  if [[ -n "${FIXTURE}" ]]; then
    note "fixture: systemd is not touched (disable --now ${TIMER}; daemon-reload)"
  elif [[ -e "/etc/systemd/system/${TIMER}" ]]; then
    /usr/bin/systemctl disable --now "${TIMER}"
    /usr/bin/systemctl stop "${SERVICE_UNIT}" 2>/dev/null || true
    ok "${TIMER} disabled and stopped"
  fi
  while IFS= read -r row; do
    path="$(at "$(field "${row}" 1)")"
    [[ -e "${path}" ]] || continue
    rm -f -- "${path}"
    ok "removed $(field "${row}" 1)"
  done < <(file_rows)
  if [[ -z "${FIXTURE}" ]]; then
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl reset-failed "${SERVICE_UNIT}" 2>/dev/null || true
  fi
  path="$(at "${LIBRARY_ROOT}")"
  if [[ -e "${path}" ]]; then
    # Renamed first, so no helper can import a half-removed library.
    mv -T -- "${path}" "$(at "${LIBRARY_PARENT}")/${LIBRARY_REMOVING_NAME}"
    ok "removed ${LIBRARY_ROOT}"
  fi
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    rm -rf -- "${path}"
    ok "removed residue ${path}"
  done < <(residue)
  FAILURES=0
  runtime_report || true
  (( FAILURES == 0 && RUNTIME_PRESENT == 0 )) || halt "the runtime is not fully removed"
  note "kept: ${SERVICE_USER}, ${STORE_ROOT}, ${APPROVAL_ROOT} -- identity and evidence are never removed"
  printf '\nROLLED BACK\n'
  ;;
esac
