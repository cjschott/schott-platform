#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 S3-quater-A ceremony: publish reviewed Platform Evidence into the
# governed deployment Evidence authority.
#
# WHY THIS EXISTS. A `CapabilityHost` claims a verified resource profile, and
# `verification_reference` names the Evidence that verified it. Resolving that
# out of `platform-model/evidence/` would make a permanent, immutable governance
# record depend on a mutable Git working tree — one that can be checked out at
# another revision, edited between two reads, or absent on the machine doing the
# resolving. That is the argument the artifact authority already settled for
# package bytes, and this is the same correction for evidence.
#
# THREE EVIDENCE PLANES, and this ceremony bridges exactly two of them:
#
#   platform-model/evidence/   declarative, reviewed, Git-governed.  SOURCE
#   /var/lib/kyri/evidence     root-owned deployment authority.      DESTINATION
#   tools/observation store    dynamic collector history, and it refuses a root
#                              inside a repository. UNRELATED TO THIS CEREMONY.
#
# The dynamic store is deliberately not reused: it provisions its directories on
# construction and allocates identities from a locked sequence. Both are right
# for recording what a collector saw and wrong here — there is nothing to
# allocate for an identity the model already fixed, and a publisher that creates
# the thing it is about to describe cannot report on it honestly.
#
# THE IDENTITY IS THE LOCATION. `EVID-000001` publishes to `EVID-000001.yaml`
# and nowhere else. No sequence is created, no identity is minted, and the
# published record remains logically the same EVID it was in the repository.
#
# WHAT IT DOES NOT DO. It creates no Fabric or Trust record, allocates no
# identifier, declares no host, opens no governance store, contacts no container
# runtime, and writes no sudoers policy.
#
# NOTHING IS REPAIRED. A published record that disagrees with the pinned digest
# is reported, never chmod'ed, chown'ed, or replaced.
#
# Usage:
#   install-host-evidence.sh --verify            read-only: may it publish?
#   install-host-evidence.sh --install           publish the reviewed evidence
#   install-host-evidence.sh --verify-installed  read-only: is it right?
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   platform-model/schemas/evidence.schema.yaml
#   docs/standards/evidence-standard.md

# The reviewed commit that recorded this evidence. It is the ONLY commit that
# has ever touched the file, so it is unambiguously the reviewing commit — and
# it is pinned rather than taken from HEAD, because a ceremony whose source
# revision moves with the checkout pins nothing. Not an argument: a
# caller-selected commit or path is a caller-selected authority.
EVIDENCE_COMMIT="061a1a158575553c1e02d33c4d237e63e0a702e9"
EVIDENCE_SOURCE="platform-model/evidence/evid-000001-schai-host-architecture.yaml"
EVIDENCE_ID="EVID-000001"
EVIDENCE_SHA256="ee88f34e2f28b0bf5b8b16e85320b91d30a371496b810a6a0baa3ef4df8c5c53"
EVIDENCE_FINGERPRINT="sha256:ef8e46f8fdafd0342853b8f802665ecb9be8246c820d866373eb88cc75b30537"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"

# The governed deployment Evidence authority. Beside, never inside, the planes
# that already own their own subtrees: fabric, trust, implementation-authority
# and its control root, and artifacts.
EVIDENCE_ROOT="/var/lib/kyri/evidence"           # prod-path-reference

DIRECTORY_MODE="0755"
RECORD_MODE="0444"

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
  EVIDENCE_ROOT="${FIXTURE}${EVIDENCE_ROOT}"
fi

PUBLISHED="${EVIDENCE_ROOT}/${EVIDENCE_ID}.yaml"
STAGING="${EVIDENCE_ROOT}/.staging-${EVIDENCE_COMMIT:0:12}"

FAILURES=0
ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

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
  git_as_owner cat-file -e "${EVIDENCE_COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed commit ${EVIDENCE_COMMIT} does not exist in ${REPOSITORY}"
  git_as_owner merge-base --is-ancestor "${EVIDENCE_COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed commit ${EVIDENCE_COMMIT} is not an ancestor of HEAD"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "the checkout is not on ${BRANCH}"
  git_as_owner cat-file -e "${EVIDENCE_COMMIT}:${EVIDENCE_SOURCE}" 2>/dev/null \
    || halt "the reviewed commit does not carry ${EVIDENCE_SOURCE}"
  ok "reviewed commit ${EVIDENCE_COMMIT} carries ${EVIDENCE_ID} (read as ${REPO_OWNER})"
}

# One component of the trusted path, judged as the released trusted-source
# primitive judges it: not a symlink, a directory, the expected owner, and not
# group- or other-writable. The rule is shared with the artifact authority
# rather than restated as a second interpretation.
check_trusted_component() {
  local path="$1" problems=0 observed
  if [[ -L "${path}" ]]; then bad "${path} is a symbolic link"; return 1; fi
  if [[ ! -d "${path}" ]]; then bad "${path} is not a directory"; return 1; fi
  observed="$(stat -c '%U' "${path}")"
  [[ "${observed}" == "${EXPECTED_OWNER}" ]] \
    || { bad "${path} is owned by ${observed}, expected ${EXPECTED_OWNER}"; problems=$((problems + 1)); }
  if [[ -n "$(find "${path}" -maxdepth 0 -perm /022)" ]]; then
    bad "${path} is writable beyond its owner ($(stat -c '%a' "${path}"))"
    problems=$((problems + 1))
  fi
  return "${problems}"
}

# Every component the resolver will walk, in the order it walks them. Existing
# components are validated and never repaired: an untrusted one is
# operator-visible evidence, and repairing it would grant the trust the check
# exists to withhold.
require_trusted_authority() {
  local problems=0 path components=() checked=0
  path="$(dirname "${EVIDENCE_ROOT}")"
  while [[ "${path}" != "/" && "${path}" != "${FIXTURE}" && -n "${path}" ]]; do
    components=("${path}" "${components[@]}")
    path="$(dirname "${path}")"
  done
  components+=("${EVIDENCE_ROOT}")
  for path in "${components[@]}"; do
    [[ -e "${path}" || -L "${path}" ]] || continue
    check_trusted_component "${path}" || problems=$((problems + $?))
    checked=$((checked + 1))
  done
  (( problems == 0 )) \
    || halt "the evidence authority is not trusted; nothing was created, written, or repaired"
  ok "${checked} existing component(s) are ${EXPECTED_OWNER}-owned directories, unwritable beyond their owner, and no symlink"
}

# Schema and fingerprint, through the released model validator rather than a
# second implementation. A record that would not validate in the repository
# must not become deployment authority.
validate_record() {
  local path="$1"
  python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
from tools.common.yaml_strict import load_strict
from tools.platform_model import evidence_fingerprint

record = load_strict(sys.argv[2])
schema = load_strict(sys.argv[1] + "/platform-model/schemas/evidence.schema.yaml")

missing = [f for f in schema["required_fields"] if f not in record]
if missing:
    raise SystemExit("missing required field(s): " + ", ".join(missing))
for field, value in (schema.get("constant_fields") or {}).items():
    if record.get(field) != value:
        raise SystemExit(f"{field} must be {value!r}")
import re
if not re.fullmatch(schema["id_pattern"], str(record.get("id"))):
    raise SystemExit("id does not match the governed pattern")
if record.get("id") != sys.argv[3]:
    raise SystemExit("the record is not the identity being published")
declared = record.get("content_fingerprint")
if not evidence_fingerprint.is_well_formed(declared):
    raise SystemExit("content_fingerprint is malformed")
recomputed = evidence_fingerprint.fingerprint(record)
if recomputed != declared:
    raise SystemExit(f"content_fingerprint {declared} does not match content {recomputed}")
if record.get("status") != "success":
    raise SystemExit("evidence status is not success")
print(declared)
' "${REPOSITORY}" "${path}" "${EVIDENCE_ID}"
}

verify_published() {
  local problems=0 observed
  if [[ -L "${PUBLISHED}" || ! -f "${PUBLISHED}" ]]; then
    bad "${PUBLISHED} is not a regular file"
    return 1
  fi
  observed="$(stat -c '%U:%G' "${PUBLISHED}")"
  [[ "${observed}" == "${EXPECTED_OWNER}:${EXPECTED_GROUP}" ]] \
    || { bad "${PUBLISHED} is ${observed}, expected ${EXPECTED_OWNER}:${EXPECTED_GROUP}"; problems=$((problems + 1)); }
  observed="$(stat -c '%a' "${PUBLISHED}")"
  [[ "0${observed}" == "${RECORD_MODE}" ]] \
    || { bad "${PUBLISHED} is mode ${observed}, expected ${RECORD_MODE}"; problems=$((problems + 1)); }
  [[ "$(stat -c '%h' "${PUBLISHED}")" == "1" ]] \
    || { bad "${PUBLISHED} carries more than one link to its bytes"; problems=$((problems + 1)); }
  observed="$(digest_of "${PUBLISHED}")"
  [[ "${observed}" == "${EVIDENCE_SHA256}" ]] \
    || { bad "${PUBLISHED} is ${observed:0:12}…, expected ${EVIDENCE_SHA256:0:12}…"; problems=$((problems + 1)); }
  observed="$(validate_record "${PUBLISHED}" 2>&1)" || {
    bad "${PUBLISHED} is not valid governed evidence: ${observed}"
    problems=$((problems + 1))
    observed=""
  }
  if [[ -n "${observed}" && "${observed}" != "${EVIDENCE_FINGERPRINT}" ]]; then
    bad "${PUBLISHED} fingerprints to ${observed}, expected ${EVIDENCE_FINGERPRINT}"
    problems=$((problems + 1))
  fi
  return "${problems}"
}

publish() {
  require_commit
  require_trusted_authority

  [[ ! -e "${STAGING}" && ! -L "${STAGING}" ]] \
    || halt "${STAGING} is interrupted-ceremony residue and is not adopted"

  local previous_umask observed
  previous_umask="$(umask)"
  umask 077

  if [[ ! -e "${EVIDENCE_ROOT}" && ! -L "${EVIDENCE_ROOT}" ]]; then
    mkdir -m "${DIRECTORY_MODE}" "${EVIDENCE_ROOT}"
    [[ -n "${FIXTURE}" ]] || chown root:root "${EVIDENCE_ROOT}"
    chmod "${DIRECTORY_MODE}" "${EVIDENCE_ROOT}"
    check_trusted_component "${EVIDENCE_ROOT}" \
      || halt "${EVIDENCE_ROOT} was created but does not satisfy the trusted-component contract"
    ok "created ${EVIDENCE_ROOT}"
  fi

  git_as_owner cat-file blob "${EVIDENCE_COMMIT}:${EVIDENCE_SOURCE}" > "${STAGING}"
  observed="$(digest_of "${STAGING}")"
  if [[ "${observed}" != "${EVIDENCE_SHA256}" ]]; then
    rm -f "${STAGING}"; umask "${previous_umask}"
    halt "${EVIDENCE_SOURCE} at ${EVIDENCE_COMMIT} is ${observed}, expected ${EVIDENCE_SHA256}; nothing was published"
  fi
  # Validated BEFORE publication, so an invalid record never becomes authority
  # even briefly.
  observed="$(validate_record "${STAGING}" 2>&1)" || {
    rm -f "${STAGING}"; umask "${previous_umask}"
    halt "the reviewed evidence is not valid: ${observed}"
  }
  [[ "${observed}" == "${EVIDENCE_FINGERPRINT}" ]] || {
    rm -f "${STAGING}"; umask "${previous_umask}"
    halt "the reviewed evidence fingerprints to ${observed}, expected ${EVIDENCE_FINGERPRINT}"
  }
  ok "staged ${EVIDENCE_ID}, fingerprint ${EVIDENCE_FINGERPRINT}"

  [[ -n "${FIXTURE}" ]] || chown root:root "${STAGING}"
  chmod "${RECORD_MODE}" "${STAGING}"
  # `-n` refuses rather than replacing, so a record that appeared between the
  # check above and this line is never overwritten.
  mv -n -T "${STAGING}" "${PUBLISHED}"
  if [[ -e "${STAGING}" ]]; then
    umask "${previous_umask}"
    halt "${PUBLISHED} appeared during publication; it is not replaced, and ${STAGING} is left for inspection"
  fi
  sync
  umask "${previous_umask}"
  ok "published ${PUBLISHED} from ${EVIDENCE_COMMIT:0:12} (${RECORD_MODE})"
}

case "${MODE}" in
--verify)
  printf '── evidence authority: may the reviewed evidence be published?\n\n'
  require_commit
  require_trusted_authority
  if [[ -e "${PUBLISHED}" || -L "${PUBLISHED}" ]]; then
    verify_published || true
    if (( FAILURES == 0 )); then
      ok "already published and exactly right; --install would publish nothing"
    else
      halt "${FAILURES} problem(s): the published evidence is not the reviewed evidence, and nothing here repairs it"
    fi
  else
    [[ ! -e "${STAGING}" ]] || halt "${STAGING} is interrupted-ceremony residue and is not adopted"
    ok "${PUBLISHED} is absent; --install would publish it from ${EVIDENCE_COMMIT:0:12}"
  fi
  printf '\nREADY\n'
  ;;
--install)
  printf '── evidence authority: publishing the reviewed evidence\n\n'
  [[ "$(id -u)" == "0" || -n "${FIXTURE}" ]] \
    || halt "publication writes root-owned authority and must run as root"
  if [[ -e "${PUBLISHED}" || -L "${PUBLISHED}" ]]; then
    verify_published || true
    if (( FAILURES != 0 )); then
      halt "${FAILURES} problem(s): ${PUBLISHED} exists and is not the reviewed evidence; it is not replaced or repaired"
    fi
    ok "already published and byte-identical; nothing to do"
    printf '\nDONE (no change)\n'
    exit 0
  fi
  publish
  FAILURES=0
  verify_published || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s) in the published evidence"
  ok "the published evidence verifies"
  printf '\nDONE\n'
  ;;
--verify-installed)
  printf '── evidence authority: is the published evidence exactly right?\n\n'
  require_trusted_authority
  verify_published || true
  (( FAILURES == 0 )) || halt "${FAILURES} problem(s)"
  ok "${PUBLISHED} is the reviewed evidence at ${EVIDENCE_COMMIT}"
  printf '\nVERIFIED\n'
  ;;
esac
