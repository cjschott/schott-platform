#!/usr/bin/env bash
set -Eeuo pipefail

# The G11-AW identity-authority ceremony, rehearsed end to end.
#
# STATIC AND UNPRIVILEGED. It reads no file under /etc, invokes no helper,
# creates no record, executes no capability workload and uses no sudo. Every
# install below lands in a disposable root that is removed when the suite ends.
#
# WHAT THIS SUITE IS FOR
# ======================
# `tests/test-capability-execution-identity-authority.sh` and
# `tests/test-capability-execution-coordinator-authority.sh` prove the two
# GRAMMARS: what a well-formed authority is and what each reader refuses. This
# suite proves the CEREMONY -- that the two programs an operator will run on
# production install exactly the reviewed bytes at exactly the reviewed mode,
# refuse a destination that already exists, and cannot be made to install one
# role's record at the other role's pathname.
#
# The distinction matters because the two failures are different. A grammar bug
# is caught the first time anything reads the file. A ceremony bug installs
# something plausible at a pathname a privileged boundary trusts, and is caught
# by nobody.
#
# THE ASSERTION THAT MATTERS MOST
# ===============================
# Cross-role refusal, in all four directions. The two authorities are separate
# because they are separate security roles: the coordinator prepares and may
# never touch Podman; the execution principal holds rootless Podman authority
# and may never write Capability Runtime records. If a coordinator record were
# accepted at the execution pathname -- or the reverse -- that separation would
# exist in the documentation and nowhere else.
#
# THE CANDIDATES ARE DERIVED, NOT TYPED
# =====================================
# No account number appears below as an expected value. Every case resolves the
# account it names through the account database, exactly as the ceremony does,
# and the reviewed digests are the only constants -- because a reviewed digest
# is a review artifact and a uid is a deployment fact.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COORDINATOR_CEREMONY="provisioning/execution/g11-aw-freeze-coordinator-identity.sh"
EXECUTION_CEREMONY="provisioning/execution/g11-aw-freeze-execution-identity.sh"
COORDINATOR_SHA256="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
EXECUTION_SHA256="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then
      pass "${label}"
    else
      fail "${label} -- expected OK, got: ${actual}"
    fi
  else
    fail "${label} -- ${actual}"
  fi
}

check() {
  local label="$1" condition="$2"
  if [[ "${condition}" == "yes" ]]; then pass "${label}"; else fail "${label}"; fi
}

# The two readers, and the canonical rendering the ceremony uses. Written once
# and shared by every case, so no case can quietly test a different grammar.
PRELUDE="$(cat <<'PY'
import hashlib
import importlib.util
import json
import os
import pwd
import stat
import sys

sys.path.insert(0, ".")
spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)
from tools.capability.execution import identity as runtime


def canonical(document):
    """The provisioning convention: sorted keys, compact, one trailing newline."""
    return (json.dumps(document, sort_keys=True,
                       separators=(",", ":")) + "\n").encode("utf-8")


def coordinator_body(account):
    entry = pwd.getpwnam(account)
    return canonical({"coordinator_account": entry.pw_name,
                      "coordinator_uid": entry.pw_uid,
                      "schema_version": 1})


def execution_body(account):
    entry = pwd.getpwnam(account)
    return canonical({"execution_account": entry.pw_name,
                      "execution_gid": entry.pw_gid,
                      "execution_uid": entry.pw_uid,
                      "schema_version": 1})


class RootOwned:
    """The status a provisioned authority has: root's, and world-readable."""
    st_mode = stat.S_IFREG | 0o444
    st_uid = 0
    st_gid = 0


def resolver(account):
    entry = pwd.getpwnam(account)
    return entry.pw_uid, entry.pw_gid


def refused(loader, *arguments, **keywords):
    """The refusal ``loader`` makes, or None if it did not refuse."""
    try:
        loader(*arguments, **keywords)
    except (policy.TransitionRefused, runtime.ExecutionIdentityError) as error:
        return str(error)
    return None
PY
)"

printf '=== the reviewed candidates, re-derived from live account facts ===\n'

run_case "the coordinator candidate is the reviewed 76 bytes" "${PRELUDE}
body = coordinator_body('cschott')
assert len(body) == 76, len(body)
assert hashlib.sha256(body).hexdigest() == '${COORDINATOR_SHA256}', \
    hashlib.sha256(body).hexdigest()
print('OK')
"

run_case "the execution candidate is the reviewed 99 bytes" "${PRELUDE}
body = execution_body('kyri-capability')
assert len(body) == 99, len(body)
assert hashlib.sha256(body).hexdigest() == '${EXECUTION_SHA256}', \
    hashlib.sha256(body).hexdigest()
print('OK')
"

# The two ceremonies must not have drifted from each other's rendering, and the
# execution one must not have drifted from the G11-AS candidate ceremony that
# derived it first. Compared as bytes, not as prose.
run_case "both ceremonies carry the reviewed digest they install" "${PRELUDE}
for path, digest in (
        ('${COORDINATOR_CEREMONY}', '${COORDINATOR_SHA256}'),
        ('${EXECUTION_CEREMONY}', '${EXECUTION_SHA256}')):
    text = open(path, encoding='utf-8').read()
    assert f'REVIEWED_SHA256=\"{digest}\"' in text, path
print('OK')
"

run_case "the ceremony renders the same encoding the deployment already uses" "${PRELUDE}
# /etc/kyri/backing-store.json is the provisioned precedent for this directory.
# It is compact and sorted; it carries no trailing newline, and the identity
# authorities deliberately do -- the convention g11-as-execution-identity-
# candidate.sh states. Both are canonical to the repository's own parser, which
# is the property that has to hold.
from tools.capability.execution import canonical_json
for body in (coordinator_body('cschott'), execution_body('kyri-capability')):
    document = canonical_json.parse(body, maximum_bytes=4096)
    assert canonical(document) == body, body
print('OK')
"

printf '\n=== Phase 8: each ceremony rehearsed into a disposable root ===\n'

rehearse() {
  local ceremony="$1" root="$2"
  ( cd "${ROOT}" && KYRI_IDENTITY_FIXTURE="${root}" bash "${ceremony}" ) \
    > "${root}.log" 2>&1
}

COORDINATOR_ROOT="${WORK}/coordinator"
EXECUTION_ROOT="${WORK}/execution"
mkdir -p "${COORDINATOR_ROOT}" "${EXECUTION_ROOT}"

if rehearse "${COORDINATOR_CEREMONY}" "${COORDINATOR_ROOT}"; then
  pass "the coordinator ceremony completes against a disposable root"
else
  fail "the coordinator ceremony failed: $(cat "${COORDINATOR_ROOT}.log")"
fi
if rehearse "${EXECUTION_CEREMONY}" "${EXECUTION_ROOT}"; then
  pass "the execution ceremony completes against a disposable root"
else
  fail "the execution ceremony failed: $(cat "${EXECUTION_ROOT}.log")"
fi

COORDINATOR_FILE="${COORDINATOR_ROOT}/etc/kyri/coordinator-identity.json"
EXECUTION_FILE="${EXECUTION_ROOT}/etc/kyri/execution-identity.json"

check "the coordinator ceremony installs the reviewed bytes" \
  "$([[ "$(sha256sum "${COORDINATOR_FILE}" | cut -d' ' -f1)" == "${COORDINATOR_SHA256}" ]] \
    && echo yes || echo no)"
check "the execution ceremony installs the reviewed bytes" \
  "$([[ "$(sha256sum "${EXECUTION_FILE}" | cut -d' ' -f1)" == "${EXECUTION_SHA256}" ]] \
    && echo yes || echo no)"
check "the coordinator authority is installed 0444" \
  "$([[ "$(stat -c '%a' "${COORDINATOR_FILE}")" == "444" ]] && echo yes || echo no)"
check "the execution authority is installed 0444" \
  "$([[ "$(stat -c '%a' "${EXECUTION_FILE}")" == "444" ]] && echo yes || echo no)"

# Each ceremony installs ONE pathname. A ceremony that also created something
# else would be a mutation nobody accounted for.
check "the coordinator ceremony creates exactly one file" \
  "$([[ "$(find "${COORDINATOR_ROOT}" -type f | wc -l)" -eq 1 ]] && echo yes || echo no)"
check "the execution ceremony creates exactly one file" \
  "$([[ "$(find "${EXECUTION_ROOT}" -type f | wc -l)" -eq 1 ]] && echo yes || echo no)"

# And neither installs the other's record: the coordinator root must not hold an
# execution authority, nor the reverse.
check "the coordinator ceremony does not install an execution authority" \
  "$([[ ! -e "${COORDINATOR_ROOT}/etc/kyri/execution-identity.json" ]] && echo yes || echo no)"
check "the execution ceremony does not install a coordinator authority" \
  "$([[ ! -e "${EXECUTION_ROOT}/etc/kyri/coordinator-identity.json" ]] && echo yes || echo no)"

printf '\n=== Phase 8: an existing destination is refused ===\n'

if rehearse "${COORDINATOR_CEREMONY}" "${COORDINATOR_ROOT}"; then
  fail "the coordinator ceremony overwrote an existing authority"
else
  if grep -q 'already exists' "${COORDINATOR_ROOT}.log"; then
    pass "the coordinator ceremony refuses an existing destination"
  else
    fail "the coordinator ceremony failed for the wrong reason: $(cat "${COORDINATOR_ROOT}.log")"
  fi
fi
if rehearse "${EXECUTION_CEREMONY}" "${EXECUTION_ROOT}"; then
  fail "the execution ceremony overwrote an existing authority"
else
  if grep -q 'already exists' "${EXECUTION_ROOT}.log"; then
    pass "the execution ceremony refuses an existing destination"
  else
    fail "the execution ceremony failed for the wrong reason: $(cat "${EXECUTION_ROOT}.log")"
  fi
fi

# The refusal must happen BEFORE anything is rendered or installed, so a refused
# ceremony leaves the existing authority byte-identical.
check "the refused coordinator ceremony left the authority untouched" \
  "$([[ "$(sha256sum "${COORDINATOR_FILE}" | cut -d' ' -f1)" == "${COORDINATOR_SHA256}" ]] \
    && echo yes || echo no)"
check "the refused execution ceremony left the authority untouched" \
  "$([[ "$(sha256sum "${EXECUTION_FILE}" | cut -d' ' -f1)" == "${EXECUTION_SHA256}" ]] \
    && echo yes || echo no)"

# A ceremony pointed at an account this deployment does not have must refuse at
# the account database rather than install a record naming nobody.
UNKNOWN_ROOT="${WORK}/unknown"
mkdir -p "${UNKNOWN_ROOT}"
if ( cd "${ROOT}" && KYRI_IDENTITY_FIXTURE="${UNKNOWN_ROOT}" \
       bash "${EXECUTION_CEREMONY}" kyri-no-such-account ) > "${UNKNOWN_ROOT}.log" 2>&1; then
  fail "the execution ceremony installed an authority for an unknown account"
else
  if grep -q 'does not know' "${UNKNOWN_ROOT}.log"; then
    pass "the execution ceremony refuses an account the database does not know"
  else
    fail "the execution ceremony failed for the wrong reason: $(cat "${UNKNOWN_ROOT}.log")"
  fi
fi
check "the refused ceremony installed nothing" \
  "$([[ "$(find "${UNKNOWN_ROOT}" -type f | wc -l)" -eq 0 ]] && echo yes || echo no)"

# A ceremony run against a deployment whose account facts no longer render the
# reviewed bytes must refuse. Driven by naming a real account that is not the
# reviewed one, which is the same condition as a reassigned uid.
DRIFT_ROOT="${WORK}/drift"
mkdir -p "${DRIFT_ROOT}"
if ( cd "${ROOT}" && KYRI_IDENTITY_FIXTURE="${DRIFT_ROOT}" \
       bash "${EXECUTION_CEREMONY}" root ) > "${DRIFT_ROOT}.log" 2>&1; then
  fail "the execution ceremony installed bytes that are not the reviewed candidate"
else
  if grep -q 'and the reviewed candidate is' "${DRIFT_ROOT}.log"; then
    pass "the execution ceremony refuses bytes that are not the reviewed candidate"
  else
    fail "the execution ceremony failed for the wrong reason: $(cat "${DRIFT_ROOT}.log")"
  fi
fi
check "the digest-mismatch refusal installed nothing" \
  "$([[ "$(find "${DRIFT_ROOT}" -type f | wc -l)" -eq 0 ]] && echo yes || echo no)"

printf '\n=== Phase 8: malformed and alternate authorities are refused ===\n'

run_case "a malformed coordinator authority is refused" "${PRELUDE}
for body in (b'', b'{', b'[]', b'null', b'{\"coordinator_account\":\"cschott\"}',
             b'{\"coordinator_account\":\"cschott\",\"coordinator_uid\":1000,'
             b'\"coordinator_uid\":2,\"schema_version\":1}',
             coordinator_body('cschott') + b'{}'):
    assert refused(policy.load_coordinator_authority, body, RootOwned()), body
print('OK')
"

run_case "a malformed execution authority is refused by both readers" "${PRELUDE}
for body in (b'', b'{', b'[]', b'null', b'{\"execution_account\":\"kyri-capability\"}',
             execution_body('kyri-capability') + b'{}'):
    for loader in (policy.load_execution_identity, runtime.load_execution_identity):
        assert refused(loader, body, RootOwned(), resolve=resolver), (loader, body)
print('OK')
"

run_case "an authority carrying an unknown field is refused" "${PRELUDE}
entry = pwd.getpwnam('kyri-capability')
body = canonical({'execution_account': entry.pw_name,
                  'execution_gid': entry.pw_gid,
                  'execution_uid': entry.pw_uid,
                  'schema_version': 1,
                  'execution_home': '/data/kyri/capability'})
for loader in (policy.load_execution_identity, runtime.load_execution_identity):
    assert 'unknown field' in (refused(loader, body, RootOwned(), resolve=resolver) or ''), loader
print('OK')
"

run_case "an authority at an unsupported schema version is refused" "${PRELUDE}
entry = pwd.getpwnam('kyri-capability')
body = canonical({'execution_account': entry.pw_name,
                  'execution_gid': entry.pw_gid,
                  'execution_uid': entry.pw_uid,
                  'schema_version': 2})
for loader in (policy.load_execution_identity, runtime.load_execution_identity):
    assert 'schema' in (refused(loader, body, RootOwned(), resolve=resolver) or ''), loader
print('OK')
"

run_case "an authority whose numbers disagree with the account database is refused" "${PRELUDE}
entry = pwd.getpwnam('kyri-capability')
body = canonical({'execution_account': entry.pw_name,
                  'execution_gid': entry.pw_gid,
                  'execution_uid': entry.pw_uid + 1,
                  'schema_version': 1})
for loader in (policy.load_execution_identity, runtime.load_execution_identity):
    assert 'resolves' in (refused(loader, body, RootOwned(), resolve=resolver) or ''), loader
print('OK')
"

run_case "an authority root does not own is refused" "${PRELUDE}
class NotRoot(RootOwned):
    st_uid = 1000

class NotRootGroup(RootOwned):
    st_gid = 1000

class GroupWritable(RootOwned):
    st_mode = stat.S_IFREG | 0o464

for status in (NotRoot(), NotRootGroup(), GroupWritable()):
    assert refused(policy.load_coordinator_authority,
                   coordinator_body('cschott'), status), status
    for loader in (policy.load_execution_identity, runtime.load_execution_identity):
        assert refused(loader, execution_body('kyri-capability'), status,
                       resolve=resolver), (loader, status)
print('OK')
"

printf '\n=== Phase 9: a combined fixture, and cross-role refusal ===\n'

COMBINED="${WORK}/combined"
# The fixture mirrors the production authority directory's SHAPE so that the two
# records sit beside each other exactly as they will on the host. It is created
# under the disposable root and nowhere else -- asserted here rather than
# asserted in a comment, because the static backstop that flags this line is
# correct to flag it and a marker alone would only silence it.
COMBINED_KYRI="${COMBINED}/etc/kyri"
[[ "${COMBINED_KYRI}" == "${WORK}/"* && -n "${WORK}" ]] \
  || { printf 'the combined fixture escaped the disposable root\n' >&2; exit 1; }
mkdir -p "${COMBINED_KYRI}"                            # prod-path-reference
cp "${COORDINATOR_FILE}" "${COMBINED_KYRI}/coordinator-identity.json"
cp "${EXECUTION_FILE}" "${COMBINED_KYRI}/execution-identity.json"

run_case "each reader takes its own record and only its own" "${PRELUDE}
root = '${COMBINED}/etc/kyri'
coordinator = open(f'{root}/coordinator-identity.json', 'rb').read()
execution = open(f'{root}/execution-identity.json', 'rb').read()

who = policy.load_coordinator_authority(coordinator, RootOwned())
assert who.coordinator_account == 'cschott', who
assert who.coordinator_uid == pwd.getpwnam('cschott').pw_uid, who

worker = policy.load_execution_identity(execution, RootOwned(), resolve=resolver)
assert worker.account == 'kyri-capability', worker
assert (worker.uid, worker.gid) == resolver('kyri-capability'), worker

# Neither identity is the other's. This is the property the two files exist to
# create, so it is asserted rather than assumed.
assert who.coordinator_uid != worker.uid, (who, worker)
print('OK')
"

run_case "a coordinator record is refused as an execution authority" "${PRELUDE}
body = coordinator_body('cschott')
for loader in (policy.load_execution_identity, runtime.load_execution_identity):
    reason = refused(loader, body, RootOwned(), resolve=resolver)
    assert reason, loader
    assert 'unknown field' in reason or 'missing' in reason, (loader, reason)
print('OK')
"

run_case "an execution record is refused as a coordinator authority" "${PRELUDE}
body = execution_body('kyri-capability')
reason = refused(policy.load_coordinator_authority, body, RootOwned())
assert reason, 'a coordinator reader accepted an execution record'
assert 'unknown field' in reason or 'missing' in reason, reason
print('OK')
"

run_case "swapping the two installed files is refused in both directions" "${PRELUDE}
root = '${COMBINED}/etc/kyri'
# The bytes as they would be after a swap: each pathname holding the other's
# record. Read from the fixture rather than re-rendered, so this is the same
# failure a fat-fingered ceremony would produce.
coordinator = open(f'{root}/coordinator-identity.json', 'rb').read()
execution = open(f'{root}/execution-identity.json', 'rb').read()

for loader in (policy.load_execution_identity, runtime.load_execution_identity):
    assert refused(loader, coordinator, RootOwned(), resolve=resolver), loader
assert refused(policy.load_coordinator_authority, execution, RootOwned())
print('OK')
"

run_case "no field name is shared between the two schemas" "${PRELUDE}
# Cross-role refusal above holds because the schemas are closed AND disjoint. If
# they ever came to share a field, a record could satisfy both readers and the
# refusals above would start passing for the wrong reason.
shared = set(policy.COORDINATOR_AUTHORITY_SCHEMA) & set(policy.EXECUTION_AUTHORITY_SCHEMA)
assert shared == {'schema_version'}, shared
assert policy.COORDINATOR_AUTHORITY_PATH != policy.EXECUTION_AUTHORITY_PATH
print('OK')
"

printf '\n=== identity installation alone cannot open execution ===\n'

run_case "helper compatibility is decided by helper objects and nothing else" "${PRELUDE}
import ast
from tools.capability.execution import helpers

# The two authorities this ceremony installs must not appear anywhere in the
# helper compatibility decision. If they did, installing them could move the
# verdict, and the whole inertness claim would rest on prose.
source = open('tools/capability/execution/helpers.py', encoding='utf-8').read()
tree = ast.parse(source)
literals = {node.value for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)}
for path in (policy.COORDINATOR_AUTHORITY_PATH, policy.EXECUTION_AUTHORITY_PATH):
    assert not any(path in text for text in literals), path
required = [helper.path for helper in helpers.REQUIRED_HELPERS]
assert required, 'no helper is required, so compatibility decides nothing'
assert all(path.startswith('/usr/') for path in required), required
assert not set(required) & {policy.COORDINATOR_AUTHORITY_PATH,
                            policy.EXECUTION_AUTHORITY_PATH}, required
print('OK')
"

run_case "supervision readiness requires helper compatibility as well as identity" "${PRELUDE}
import ast

# Read structurally rather than by running it: the live verdict depends on the
# host, and the property being protected is that the CONJUNCTION includes helper
# compatibility -- so that two installed authorities can never, on their own,
# make this true.
tree = ast.parse(open('tools/capability/cli.py', encoding='utf-8').read())
outlook = next(node for node in ast.walk(tree)
               if isinstance(node, ast.FunctionDef) and node.name == '_supervision_outlook')
assignment = next(
    node for node in ast.walk(outlook)
    if isinstance(node, ast.Assign)
    and any(isinstance(t, ast.Subscript)
            and isinstance(t.slice, ast.Constant)
            and t.slice.value == 'supervision_ready' for t in node.targets))
conjunction = ast.dump(assignment.value)
for required in ('coordinator_identity_authority', 'execution_identity_authority',
                 'compatible'):
    assert required in conjunction, (required, conjunction)
assert 'BoolOp' in conjunction and 'And' in conjunction, conjunction
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All identity-authority ceremony checks passed.\n'
else
  printf '%d identity-authority ceremony check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
