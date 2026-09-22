# shellcheck shell=bash
# Host-only suite declaration. Sourced, never executed.
#
# Some suites in this repository do not test portable code. Their subject is the
# accepted production host: the installed Generation-12 runtime under
# /usr/lib/kyri, the governed stores under /var/lib/kyri, the operator ceremony
# reading its reviewed source from the pinned checkout at /opt/schott-platform.
# On a GitHub runner none of that exists. Such a suite cannot prove anything
# there: failing says nothing about the code, and passing would be a lie.
#
# So a suite declares what it needs. On the production host every precondition
# holds and it runs in full, exactly as before -- the local validator remains
# the authority for everything here. Anywhere else it prints one
# machine-readable line naming itself and what was missing, and exits 0 so the
# rest of the pipeline runs.
#
# The decision is made from the preconditions themselves and nothing else.
# There is deliberately no way to ASK for the skip: no CI=true, no
# SKIP_HOST_TESTS, no --force. A machine with the production layout runs these
# tests and cannot opt out; a machine without it could not run them anyway.
# That asymmetry is the point -- an environment variable that turned off
# production checks would eventually be set on the production host.
#
# A skip is not a pass. Every host-only suite is enumerated with its reason in
# tests/host-only.manifest, test-static.sh asserts that manifest matches the
# suites that actually source this file in both directions, and CI publishes
# the list to its job summary. A suite cannot become host-only quietly.

# host_only_requires <path> [<path>...]
#
# Each argument is a production path this suite's subject depends on. If every
# one is present the function returns and the suite proceeds. If any is absent
# the suite is not runnable here: report and exit 0.
host_only_requires() {
  # Names are prefixed because this runs in the caller's shell: a bare
  # `missing` would collide with a suite's own variable of that name.
  local _ho_suite _ho_path
  local -a _ho_missing=()
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  for _ho_path in "$@"; do
    [[ -e "${_ho_path}" ]] || _ho_missing+=("${_ho_path}")
  done
  (( ${#_ho_missing[@]} == 0 )) && return 0
  printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" "${_ho_missing[*]}"
  printf 'This suite tests the accepted production host and is not runnable here.\n'
  printf 'Missing: %s\n' "${_ho_missing[*]}"
  exit 0
}

# host_only_requires_pinned_checkout <ceremony-script>
#
# The operator ceremonies read their reviewed source with `git -C` against an
# absolute REPOSITORY they pin, as the repository owner, via runuser. That pin
# is production authority and is not relaxed for a test runner: a ceremony that
# accepted whatever checkout it was handed would no longer be proving what it
# claims. So a suite driving a pinned ceremony is runnable only where the
# checkout IS that pin.
host_only_requires_pinned_checkout() {
  local _ho_ceremony="$1" _ho_pinned _ho_here _ho_suite
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  _ho_pinned="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${_ho_ceremony}" | head -1)"
  _ho_here="$(cd "$(dirname "${_ho_ceremony}")/../.." && pwd)"
  [[ -n "${_ho_pinned}" ]] || {
    printf 'FAIL: %s declares no REPOSITORY pin to check\n' "${_ho_ceremony}" >&2
    exit 1
  }
  [[ "${_ho_pinned}" == "${_ho_here}" ]] && return 0
  printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" "checkout ${_ho_here} is not the pinned ${_ho_pinned}"
  printf 'This suite drives an operator ceremony pinned to %s.\n' "${_ho_pinned}"
  printf 'This checkout is %s, so the ceremony would read a different repository.\n' "${_ho_here}"
  exit 0
}

# host_only_requires_identity <uid>
#
# Some suites build a fixture the production code then authenticates by owner:
# kyri-exec-transition.py pins COORDINATOR_UID, and a launch record not owned by
# it is refused. A test cannot fabricate that ownership without being that
# identity, and the pinned uid is production authority, not a test parameter.
#
# On schai this holds because the operator account IS the coordinator identity.
# That is a coincidence the suites have always relied on silently; stating it
# here makes it a declared precondition instead.
host_only_requires_identity() {
  local _ho_want="$1" _ho_have _ho_suite
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  _ho_have="$(id -u)"
  [[ "${_ho_have}" == "${_ho_want}" ]] && return 0
  printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" "runs as uid ${_ho_have}, not the coordinator identity ${_ho_want}"
  printf 'This suite builds a fixture the production code authenticates by owner.\n'
  printf 'It must run as uid %s; this process is uid %s.\n' "${_ho_want}" "${_ho_have}"
  exit 0
}

# host_only_requires_account <account> [<account>...]
#
# A deployment identity ceremony resolves an account and installs the numbers
# the account database gives it. Which numbers those are is a fact about the
# deployment, and the reviewed candidate digest is a fact about THIS one: on a
# machine that has never heard of these accounts the ceremony cannot render its
# candidate at all, and a suite driving it would be reporting on the runner's
# /etc/passwd rather than on the ceremony.
#
# Only the ceremony needs this. The grammar the ceremony's output has to satisfy
# is deployment-neutral and is proven with injected resolvers and unrelated
# fixture deployments, which run everywhere -- because a case that only ever
# exercised one deployment's numbers would pass against a compiled-in constant
# too, which is the entire defect these authorities exist to close.
host_only_requires_account() {
  local _ho_account _ho_suite
  local -a _ho_missing=()
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  for _ho_account in "$@"; do
    getent passwd "${_ho_account}" >/dev/null 2>&1 || _ho_missing+=("${_ho_account}")
  done
  (( ${#_ho_missing[@]} == 0 )) && return 0
  printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" \
    "the account database does not know ${_ho_missing[*]}"
  printf 'This suite drives a deployment identity ceremony for %s.\n' "$*"
  printf 'Missing from the account database: %s\n' "${_ho_missing[*]}"
  exit 0
}

# host_only_requires_observable_filesystem <path> <repository-root>
#
# The backing-store fixture does not invent a filesystem UUID; it asks the
# production observation helper what filesystem the work root sits on, so the
# verification path under test is the production one. That helper resolves the
# UUID through /dev/disk/by-uuid, which answers for a real block device and not
# for a runner's ephemeral workspace. Where it cannot answer, the fixture cannot
# be built and the CLI would refuse for a reason that is about the machine
# rather than the CLI.
#
# The decision is delegated to the helper itself rather than guessed at, so this
# tracks the production code rather than a copy of its reasoning.
host_only_requires_observable_filesystem() {
  local _ho_path="$1" _ho_root="$2" _ho_suite _ho_uuid
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  _ho_uuid="$(cd "${_ho_root}" && python3 -c '
import sys
sys.path.insert(0, ".")
from tools.capability.cli import _observed_filesystem
try:
    print(_observed_filesystem(sys.argv[1]).filesystem_uuid)
except Exception:
    print("")
' "${_ho_path}" 2>/dev/null)"
  [[ -n "${_ho_uuid}" ]] && return 0
  printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" "no resolvable filesystem UUID for ${_ho_path}"
  printf 'The backing-store fixture needs the filesystem UUID of %s, which the\n' "${_ho_path}"
  printf 'production observation helper resolves through /dev/disk/by-uuid.\n'
  printf 'This machine does not report one, so the fixture cannot be built.\n'
  exit 0
}

# host_only_requires_coordinator_identity <repository-root>
#
# The deployment's coordinator identity, resolved through the authority
# production itself reads, and used as the identity this suite must run as.
#
# WHY THIS EXISTS. Suites that build a fixture the privileged helper
# authenticates by owner used to pin the identity by sed'ing a compiled-in
# `COORDINATOR_UID = 1000` out of the policy module. f9d94ce removed that
# constant -- it was true of `schai` only because `cschott` happens to be uid
# 1000 -- in favour of /etc/kyri/coordinator-identity.json. The sed then
# matched nothing, `host_only_requires_identity ""` compared "" against the
# real uid, and the suites reported HOST_ONLY_SKIP on every run since,
# including on the production host they exist to prove. A skip produced by a
# stale extraction is worse than a failure: it reads as "not applicable here"
# rather than "nobody checked".
#
# So the answer comes from `load_coordinator_authority`, the same reader the
# privileged helper uses, which judges ownership before it reads the bytes as
# authority and enforces the closed schema and the version. This helper adds no
# parsing of its own and carries no default: there is deliberately nothing for a
# failure to degrade to.
#
# THE THREE OUTCOMES ARE KEPT APART ON PURPOSE.
#   absent    -- this deployment publishes no coordinator authority, so the
#                fixture cannot be built. Not applicable here: skip, with the
#                reason stated.
#   malformed -- the deployment HAS an authority and the governed reader
#                refused it. That is a real finding about a real host and it
#                fails, because skipping here would recreate exactly the defect
#                this helper was written to remove.
#   resolved  -- compare against the running uid in the usual way.
#
# An empty or non-numeric answer is also a failure, never a skip, for the same
# reason: that empty string is the original bug.
host_only_requires_coordinator_identity() {
  local _ho_root="$1" _ho_suite _ho_answer _ho_rc
  _ho_suite="$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}")"
  # `|| _ho_rc=$?` and not a bare assignment: every suite runs under `set -e`,
  # which aborts the function on a failing command substitution before `$?` can
  # be read -- so an absent authority would kill the suite with the reader's own
  # exit status instead of skipping for a stated reason.
  _ho_rc=0
  _ho_answer="$(cd "${_ho_root}" && python3 - <<'COORDINATOR_PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)

try:
    handle = os.open(policy.COORDINATOR_AUTHORITY_PATH,
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
except OSError:
    sys.exit(2)                    # absent or unreadable: not this deployment
try:
    info = os.fstat(handle)
    body = os.read(handle, policy.MAXIMUM_COORDINATOR_AUTHORITY_BYTES + 1)
finally:
    os.close(handle)

try:
    authority = policy.load_coordinator_authority(body, info)
except Exception as error:                                   # noqa: BLE001
    print(f"{type(error).__name__}: {error}")
    sys.exit(3)                    # present but not authority: refuse loudly
print(authority.coordinator_uid)
COORDINATOR_PY
)" || _ho_rc=$?
  case "${_ho_rc}" in
    0) ;;
    2) printf 'HOST_ONLY_SKIP\t%s\t%s\n' "${_ho_suite}" \
         "this deployment publishes no coordinator identity authority"
       printf 'This suite builds a fixture the production code authenticates by owner.\n'
       printf 'The deployment coordinator identity authority is absent or unreadable,\n'
       printf 'so the identity the fixture must carry cannot be resolved.\n'
       exit 0 ;;
    *) printf 'FAIL: %s: the coordinator identity authority did not verify: %s\n' \
         "${_ho_suite}" "${_ho_answer:-the reader exited ${_ho_rc}}" >&2
       exit 1 ;;
  esac
  [[ "${_ho_answer}" =~ ^[0-9]+$ ]] || {
    printf 'FAIL: %s: the coordinator authority resolved no uid (%s)\n' \
      "${_ho_suite}" "${_ho_answer:-empty}" >&2
    exit 1
  }
  host_only_requires_identity "${_ho_answer}"
}
