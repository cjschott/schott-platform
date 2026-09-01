#!/usr/bin/env bash
set -Eeuo pipefail

# The two deployment identity authorities, and the boundary between them.
#
# STATIC, UNPRIVILEGED AND DEPLOYMENT-NEUTRAL. It reads no file under /etc,
# resolves no account through the host, invokes no helper and uses no sudo.
# Every authority body is rendered from fixture facts and every account
# resolution is an injected function.
#
# WHY THIS SUITE HAS NO HOST IN IT
# ================================
# The first version of this suite called `pwd.getpwnam('cschott')`. It passed on
# the production host and collapsed on a runner that has never heard of that
# account -- which was the correct outcome, because a suite that reads the
# machine's own account database is testing the machine. Worse, it is the exact
# coincidence these two authorities exist to close: `COORDINATOR_UID = 1000` and
# `WORKER_UID = 999` were true of schai because that is how the accounts happened
# to be created, and three suites passed on that coincidence.
#
# So nothing here resolves a real account. Every case runs TWO unrelated fixture
# deployments through the same code, because a case that only ever exercised one
# deployment's numbers would pass against a compiled-in constant too.
#
# The ceremony that installs these files for THIS deployment is a different
# subject with a different precondition, and is proven by
# tests/test-capability-identity-authority-ceremony.sh, which is host-only.
#
# THE ASSERTION THAT MATTERS MOST
# ===============================
# Cross-role refusal, in all four directions. The two authorities are separate
# because they are separate security roles: the coordinator prepares and may
# never touch Podman; the execution principal holds rootless Podman authority
# and may never write Capability Runtime records. If a coordinator record were
# accepted at the execution pathname -- or the reverse -- that separation would
# exist in the documentation and nowhere else.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# The two readers, the canonical rendering, and two fixture deployments that
# share no number with each other or with schai.
PRELUDE="$(cat <<'PY'
import importlib.util
import json
import stat
import sys

sys.path.insert(0, ".")
spec = importlib.util.spec_from_file_location(
    "kyri_exec_transition", "provisioning/execution/kyri-exec-transition.py")
policy = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_transition"] = policy
spec.loader.exec_module(policy)
from tools.capability.execution import identity as runtime

# Two unrelated deployments. Neither is schai, and they share no identity
# number, so a constant cannot satisfy both.
DEPLOYMENTS = (
    {"coordinator": ("alpha-operator", 4100),
     "execution": ("alpha-worker", 4101, 4102)},
    {"coordinator": ("beta-ops", 7700),
     "execution": ("beta-runner", 7701, 7702)},
)


def canonical(document):
    """The provisioning convention: sorted keys, compact, one trailing newline."""
    return (json.dumps(document, sort_keys=True,
                       separators=(",", ":")) + "\n").encode("utf-8")


def coordinator_body(deployment):
    account, uid = deployment["coordinator"]
    return canonical({"coordinator_account": account,
                      "coordinator_uid": uid,
                      "schema_version": 1})


def execution_body(deployment):
    account, uid, gid = deployment["execution"]
    return canonical({"execution_account": account,
                      "execution_gid": gid,
                      "execution_uid": uid,
                      "schema_version": 1})


def resolver_for(deployment):
    """The account database THIS fixture deployment would have."""
    account, uid, gid = deployment["execution"]

    def resolve(name):
        if name != account:
            raise runtime.ExecutionIdentityError(
                f"the account database does not know {name!r}")
        return uid, gid

    return resolve


class RootOwned:
    """The status a provisioned authority has: root's, and world-readable."""
    st_mode = stat.S_IFREG | 0o444
    st_uid = 0
    st_gid = 0


EXECUTION_READERS = (policy.load_execution_identity,
                     runtime.load_execution_identity)


def refused(loader, *arguments, **keywords):
    """The refusal ``loader`` makes, or None if it did not refuse."""
    try:
        loader(*arguments, **keywords)
    except (policy.TransitionRefused, runtime.ExecutionIdentityError) as error:
        return str(error)
    return None
PY
)"

printf '=== each reader takes its own record, on two unrelated deployments ===\n'

run_case "each reader derives its own deployment's identity" "${PRELUDE}
for deployment in DEPLOYMENTS:
    who = policy.load_coordinator_authority(
        coordinator_body(deployment), RootOwned())
    assert (who.coordinator_account, who.coordinator_uid) == deployment['coordinator'], who

    for reader in EXECUTION_READERS:
        worker = reader(execution_body(deployment), RootOwned(),
                        resolve=resolver_for(deployment))
        assert (worker.account, worker.uid, worker.gid) == deployment['execution'], worker

    # The two roles are never the same identity. Asserted rather than assumed:
    # it is the property the two files exist to create.
    assert who.coordinator_uid != deployment['execution'][1], deployment
print('OK')
"

run_case "both execution readers agree on every fixture deployment" "${PRELUDE}
for deployment in DEPLOYMENTS:
    body, resolve = execution_body(deployment), resolver_for(deployment)
    derived = [(reader(body, RootOwned(), resolve=resolve)) for reader in EXECUTION_READERS]
    assert len({(d.account, d.uid, d.gid) for d in derived}) == 1, derived
print('OK')
"

printf '\n=== cross-role refusal, in all four directions ===\n'

run_case "a coordinator record is refused as an execution authority" "${PRELUDE}
for deployment in DEPLOYMENTS:
    body = coordinator_body(deployment)
    for reader in EXECUTION_READERS:
        reason = refused(reader, body, RootOwned(), resolve=resolver_for(deployment))
        assert reason, (reader, deployment)
        assert 'unknown field' in reason or 'missing' in reason, reason
print('OK')
"

run_case "an execution record is refused as a coordinator authority" "${PRELUDE}
for deployment in DEPLOYMENTS:
    reason = refused(policy.load_coordinator_authority,
                     execution_body(deployment), RootOwned())
    assert reason, deployment
    assert 'unknown field' in reason or 'missing' in reason, reason
print('OK')
"

run_case "swapping the two records is refused in both directions" "${PRELUDE}
# The state a fat-fingered ceremony would leave: each pathname holding the
# other's record. Neither reader may make sense of what it is handed.
for deployment in DEPLOYMENTS:
    at_execution_path = coordinator_body(deployment)
    at_coordinator_path = execution_body(deployment)
    for reader in EXECUTION_READERS:
        assert refused(reader, at_execution_path, RootOwned(),
                       resolve=resolver_for(deployment)), (reader, deployment)
    assert refused(policy.load_coordinator_authority,
                   at_coordinator_path, RootOwned()), deployment
print('OK')
"

run_case "the two schemas share no field but schema_version" "${PRELUDE}
# Cross-role refusal above holds because the schemas are closed AND disjoint. If
# they ever came to share a field, a record could satisfy both readers and those
# refusals would start passing for the wrong reason.
shared = set(policy.COORDINATOR_AUTHORITY_SCHEMA) & set(policy.EXECUTION_AUTHORITY_SCHEMA)
assert shared == {'schema_version'}, shared
assert policy.COORDINATOR_AUTHORITY_PATH != policy.EXECUTION_AUTHORITY_PATH
assert runtime.EXECUTION_AUTHORITY_PATH == policy.EXECUTION_AUTHORITY_PATH
print('OK')
"

printf '\n=== malformed, altered and mis-owned authorities ===\n'

run_case "a malformed coordinator authority is refused" "${PRELUDE}
deployment = DEPLOYMENTS[0]
account, uid = deployment['coordinator']
bodies = [b'', b'{', b'[]', b'null', b'\"text\"',
          canonical({'coordinator_account': account}),
          coordinator_body(deployment) + b'{}',
          ('{\"coordinator_account\":\"%s\",\"coordinator_uid\":%d,'
           '\"coordinator_uid\":1,\"schema_version\":1}' % (account, uid)).encode()]
for body in bodies:
    assert refused(policy.load_coordinator_authority, body, RootOwned()), body
print('OK')
"

run_case "a malformed execution authority is refused by both readers" "${PRELUDE}
deployment = DEPLOYMENTS[0]
account, uid, gid = deployment['execution']
bodies = [b'', b'{', b'[]', b'null', b'\"text\"',
          canonical({'execution_account': account}),
          execution_body(deployment) + b'{}',
          ('{\"execution_account\":\"%s\",\"execution_gid\":%d,\"execution_gid\":1,'
           '\"execution_uid\":%d,\"schema_version\":1}' % (account, gid, uid)).encode()]
for body in bodies:
    for reader in EXECUTION_READERS:
        assert refused(reader, body, RootOwned(),
                       resolve=resolver_for(deployment)), (reader, body)
print('OK')
"

run_case "an authority carrying an unknown field is refused" "${PRELUDE}
for deployment in DEPLOYMENTS:
    account, uid, gid = deployment['execution']
    body = canonical({'execution_account': account, 'execution_gid': gid,
                      'execution_uid': uid, 'schema_version': 1,
                      'execution_home': '/data/kyri/capability'})
    for reader in EXECUTION_READERS:
        reason = refused(reader, body, RootOwned(), resolve=resolver_for(deployment))
        assert 'unknown field' in (reason or ''), (reader, reason)

    name, coordinator_uid = deployment['coordinator']
    body = canonical({'coordinator_account': name, 'coordinator_uid': coordinator_uid,
                      'schema_version': 1, 'coordinator_gid': 7})
    reason = refused(policy.load_coordinator_authority, body, RootOwned())
    assert 'unknown field' in (reason or ''), reason
print('OK')
"

run_case "an authority at an unsupported schema version is refused" "${PRELUDE}
for version in (0, 2, 99, True, '1', 1.0, None):
    for deployment in DEPLOYMENTS:
        account, uid, gid = deployment['execution']
        body = canonical({'execution_account': account, 'execution_gid': gid,
                          'execution_uid': uid, 'schema_version': version})
        for reader in EXECUTION_READERS:
            assert refused(reader, body, RootOwned(),
                           resolve=resolver_for(deployment)), (reader, version)

        name, coordinator_uid = deployment['coordinator']
        body = canonical({'coordinator_account': name,
                          'coordinator_uid': coordinator_uid,
                          'schema_version': version})
        assert refused(policy.load_coordinator_authority, body, RootOwned()), version
print('OK')
"

run_case "an identity number that is not a usable non-root id is refused" "${PRELUDE}
deployment = DEPLOYMENTS[0]
account, uid, gid = deployment['execution']
for bad in (0, -1, True, False, '999', 1.0, None, 2 ** 31):
    body = canonical({'execution_account': account, 'execution_gid': gid,
                      'execution_uid': bad, 'schema_version': 1})
    for reader in EXECUTION_READERS:
        assert refused(reader, body, RootOwned(),
                       resolve=resolver_for(deployment)), (reader, bad)

    name, _ = deployment['coordinator']
    body = canonical({'coordinator_account': name, 'coordinator_uid': bad,
                      'schema_version': 1})
    assert refused(policy.load_coordinator_authority, body, RootOwned()), bad
print('OK')
"

run_case "an authority whose numbers disagree with the account database is refused" "${PRELUDE}
# The failure this record exists to survive: an authority naming an account
# whose uid or gid was reassigned after the file was written.
for deployment in DEPLOYMENTS:
    account, uid, gid = deployment['execution']
    for drifted in ({'execution_uid': uid + 1}, {'execution_gid': gid + 1}):
        body = canonical({'execution_account': account, 'execution_gid': gid,
                          'execution_uid': uid, 'schema_version': 1, **drifted})
        for reader in EXECUTION_READERS:
            reason = refused(reader, body, RootOwned(),
                             resolve=resolver_for(deployment))
            assert 'resolves' in (reason or ''), (reader, reason)
print('OK')
"

run_case "an authority naming an account the database does not have is refused" "${PRELUDE}
deployment, other = DEPLOYMENTS
body = execution_body(other)
for reader in EXECUTION_READERS:
    # Rendered for the second deployment, resolved against the first's database.
    assert refused(reader, body, RootOwned(),
                   resolve=resolver_for(deployment)), reader
print('OK')
"

run_case "an authority root does not own is refused" "${PRELUDE}
class NotRootOwner(RootOwned):
    st_uid = 1000

class NotRootGroup(RootOwned):
    st_gid = 1000

class GroupWritable(RootOwned):
    st_mode = stat.S_IFREG | 0o464

class WorldWritable(RootOwned):
    st_mode = stat.S_IFREG | 0o446

class NotRegular(RootOwned):
    st_mode = stat.S_IFDIR | 0o444

for status in (NotRootOwner(), NotRootGroup(), GroupWritable(), WorldWritable(),
               NotRegular()):
    for deployment in DEPLOYMENTS:
        assert refused(policy.load_coordinator_authority,
                       coordinator_body(deployment), status), status
        for reader in EXECUTION_READERS:
            assert refused(reader, execution_body(deployment), status,
                           resolve=resolver_for(deployment)), (reader, status)
print('OK')
"

run_case "0400 is accepted: the read bits are root's decision" "${PRELUDE}
class ReadOnlyToRoot(RootOwned):
    st_mode = stat.S_IFREG | 0o400

deployment = DEPLOYMENTS[0]
who = policy.load_coordinator_authority(coordinator_body(deployment), ReadOnlyToRoot())
assert (who.coordinator_account, who.coordinator_uid) == deployment['coordinator']
for reader in EXECUTION_READERS:
    worker = reader(execution_body(deployment), ReadOnlyToRoot(),
                    resolve=resolver_for(deployment))
    assert (worker.account, worker.uid, worker.gid) == deployment['execution']
print('OK')
"

run_case "an oversized authority is refused before it is parsed" "${PRELUDE}
deployment = DEPLOYMENTS[0]
account, uid, gid = deployment['execution']
padded = canonical({'execution_account': account, 'execution_gid': gid,
                    'execution_uid': uid, 'schema_version': 1})
padded += b' ' * (policy.MAXIMUM_EXECUTION_AUTHORITY_BYTES + 1)
for reader in EXECUTION_READERS:
    assert 'exceeds' in (refused(reader, padded, RootOwned(),
                                 resolve=resolver_for(deployment)) or ''), reader
print('OK')
"

printf '\n=== the identities are immutable and cannot be constructed ===\n'

run_case "the privileged identities cannot be built without their loader" "${PRELUDE}
import dataclasses

# The two values the PRIVILEGED boundary acts on are token-guarded: they decide
# whose objects are trusted and which kernel identity root permanently becomes,
# so 'was this read from root-owned authority?' has to be answerable from the
# type rather than from trusting whoever built it.
for constructor in (policy.CoordinatorAuthority, policy.ExecutionIdentity):
    # Without the token at all, and with a token a caller could have guessed.
    for attempt in (lambda c: c(account='x', uid=1, gid=2),
                    lambda c: c(object(), account='x', uid=1, gid=2),
                    lambda c: c(None, account='x', uid=1, gid=2)):
        try:
            attempt(constructor)
        except (policy.TransitionRefused, TypeError):
            pass
        else:
            raise AssertionError(f'{constructor} was constructible')

# The runtime's is deliberately NOT the same kind of value: it is a frozen
# record on the unprivileged observation surface, constructible but immutable.
# Asserted as it is rather than as the privileged one, so the difference stays
# visible instead of being discovered later.
assert dataclasses.is_dataclass(runtime.ExecutionIdentity)
assert runtime.ExecutionIdentity.__dataclass_params__.frozen
sample = runtime.ExecutionIdentity(account='x', uid=1, gid=2)
try:
    sample.uid = 0
except dataclasses.FrozenInstanceError:
    pass
else:
    raise AssertionError('the runtime execution identity was mutable')

deployment = DEPLOYMENTS[0]
who = policy.load_coordinator_authority(coordinator_body(deployment), RootOwned())
worker = policy.load_execution_identity(execution_body(deployment), RootOwned(),
                                        resolve=resolver_for(deployment))
for value, field in ((who, 'coordinator_uid'), (worker, 'uid')):
    try:
        setattr(value, field, 0)
    except policy.TransitionRefused:
        pass
    else:
        raise AssertionError(f'{value} was mutable')
print('OK')
"

run_case "the rootless environment is derived from the identity, not stored" "${PRELUDE}
for deployment in DEPLOYMENTS:
    worker = policy.load_execution_identity(
        execution_body(deployment), RootOwned(), resolve=resolver_for(deployment))
    environment = dict(policy.execution_environment(worker))
    assert environment['XDG_RUNTIME_DIR'].endswith(f'/{worker.uid}'), environment
    assert environment['HOME'] == policy.EXECUTION_HOME, environment
    # Nothing else. No CONTAINERS_*, no storage override, no socket selector.
    assert set(environment) == {'HOME', 'XDG_RUNTIME_DIR'}, environment
print('OK')
"

printf '\n=== installing these authorities cannot open execution ===\n'

run_case "helper compatibility is decided by helper objects and nothing else" "${PRELUDE}
import ast
from tools.capability.execution import helpers

# Neither authority pathname may appear anywhere in the compatibility decision.
# If one did, installing these files could move the verdict, and the whole
# behavioural-inertness claim would rest on prose.
tree = ast.parse(open('tools/capability/execution/helpers.py', encoding='utf-8').read())
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
    and any(isinstance(target, ast.Subscript)
            and isinstance(target.slice, ast.Constant)
            and target.slice.value == 'supervision_ready' for target in node.targets))
conjunction = ast.dump(assignment.value)
for required in ('coordinator_identity_authority', 'execution_identity_authority',
                 'compatible'):
    assert required in conjunction, (required, conjunction)
assert 'BoolOp' in conjunction and 'And' in conjunction, conjunction
print('OK')
"

printf '\n=== the provisioning encoding ===\n'

run_case "the ceremony encoding round-trips through the canonical parser" "${PRELUDE}
from tools.capability.execution import canonical_json

for deployment in DEPLOYMENTS:
    for body in (coordinator_body(deployment), execution_body(deployment)):
        document = canonical_json.parse(body, maximum_bytes=4096)
        assert canonical(document) == body, body
        assert body.endswith(b'}\n'), body
        assert b': ' not in body and b', ' not in body, body
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All identity-authority schema checks passed.\n'
else
  printf '%d identity-authority schema check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
