#!/usr/bin/env bash
set -Eeuo pipefail

# The deployment execution identity authority, and the hardcodes it replaced.
#
# STATIC AND UNPRIVILEGED. No Podman, no container, no privileged path, no
# account is created, and nothing under /etc is read: every authority body here
# is a fixture and every account resolution is an injected function.
#
# WHAT THIS SUITE IS FOR
# ======================
# G11-AH removed `COORDINATOR_UID = 1000` from the privileged helper and gave
# the coordinator a deployment identity read from root-owned authority. Its
# reasoning is in the source it left behind:
#
#   "A compiled-in coordinator uid used to live at this line. It was never
#    derived and never provisioned: it was true of `schai` because `cschott`
#    happens to be uid 1000, and three suites passed on that coincidence. A
#    helper meant to be deployment-independent cannot carry one deployment's
#    account number as if it were a property of Kyri."
#
# That reasoning applied word for word to the WORKER identity and had never
# been applied to it. G11-AR proved there was no authority to apply it with and
# stopped rather than building an eighth hardcoded site; the previous version of
# this suite BOUNDED the gap at seven. G11-AS closes it, and this suite is now
# the proof that it is closed and stays closed.
#
# THE ASSERTIONS THAT MATTER MOST
# ===============================
# Two, and neither is about a number being present.
#
#   * DEPLOYMENT NEUTRALITY. Two unrelated fixture deployments -- 999:987 and
#     2203:2207 -- load, derive and govern identically. A test that only ever
#     exercised the schai values would pass just as well against a constant.
#
#   * PARSER AGREEMENT. The privileged helpers cannot import the runtime
#     package, so the grammar exists twice. Every vector below is driven through
#     BOTH implementations and required to produce the same verdict, because two
#     parsers that can disagree are a boundary that can be crossed one way and
#     not the other.

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
    fail "${label} -- raised: ${actual}"
  fi
}

PRELUDE="
import ast, importlib.util, json, re, sys
sys.path.insert(0, '.')
from pathlib import Path

TRANSITION = Path('provisioning/execution/kyri-exec-transition.py')
ACTION = Path('provisioning/execution/kyri-exec-transition-action.py')
WORKER_LIB = Path('tools/capability/execution/worker.py')
RUNTIME_IDENTITY = Path('tools/capability/execution/identity.py')
BACKEND = Path('provisioning/execution/kyri-exec-podman.py')
RECONCILE = Path('provisioning/execution/kyri-exec-reconcile.py')

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy = load('kyri_exec_transition', TRANSITION)
from tools.capability.execution import identity as runtime

# The two accepted parsers. Everything below that speaks of 'both' means these.
PARSERS = (
    ('helper', policy.load_execution_identity, policy.TransitionRefused),
    ('runtime', runtime.load_execution_identity, runtime.ExecutionIdentityError),
)

class Status:
    '''What os.fstat reports for a correctly provisioned authority.'''
    def __init__(self, mode=0o100444, uid=0, gid=0):
        self.st_mode, self.st_uid, self.st_gid = mode, uid, gid

def body(account='fixture-a', uid=999, gid=987, **overrides):
    document = dict(execution_account=account, execution_gid=gid,
                    execution_uid=uid, schema_version=1)
    for name, value in overrides.items():
        if value is _ABSENT:
            document.pop(name, None)
        else:
            document[name] = value
    return json.dumps(document, sort_keys=True,
                      separators=(',', ':')).encode('utf-8')

_ABSENT = object()

def fixed(uid, gid):
    '''An account database that answers one pair for any name.'''
    return lambda account: (uid, gid)

def both_accept(raw, status, resolve):
    '''Load through both parsers and require them to agree on the value.'''
    seen = []
    for label, loader, _ in PARSERS:
        result = loader(raw, status, resolve=resolve)
        seen.append((result.account, result.uid, result.gid))
    assert seen[0] == seen[1], ('the parsers disagree on the value', seen)
    return seen[0]

def both_refuse(raw, status, resolve, why):
    '''Require BOTH parsers to refuse. One refusing is a boundary, not a rule.'''
    for label, loader, refusal in PARSERS:
        try:
            loader(raw, status, resolve=resolve)
        except refusal:
            continue
        except Exception as error:
            raise AssertionError(
                f'{label} raised {type(error).__name__} rather than refusing '
                f'{why}: {error}')
        raise AssertionError(f'{label} ACCEPTED {why}')
"

# --- the coordinator half, which was already correct and must stay correct -----------

run_case "the coordinator identity is deployment-bound, with no fallback" "${PRELUDE}
assert policy.COORDINATOR_AUTHORITY_PATH == '/etc/kyri/coordinator-identity.json'
assert not hasattr(policy, 'COORDINATOR_UID'), \\
    'a compiled-in coordinator uid has returned'
assert policy.COORDINATOR_AUTHORITY_SCHEMA == (
    'coordinator_account', 'coordinator_uid', 'schema_version')
print('OK')
"

run_case "coordinator and executor are separate records, not one merged identity" "${PRELUDE}
# Separate paths, and neither schema names the other's fields. The two are
# different security roles -- the coordinator prepares and may never touch
# Podman; the executor holds rootless Podman authority and may never write
# Runtime records -- and one file naming both would make them editable together.
assert policy.EXECUTION_AUTHORITY_PATH != policy.COORDINATOR_AUTHORITY_PATH
assert policy.EXECUTION_AUTHORITY_SCHEMA == (
    'execution_account', 'execution_gid', 'execution_uid', 'schema_version')
shared = set(policy.EXECUTION_AUTHORITY_SCHEMA) & set(
    policy.COORDINATOR_AUTHORITY_SCHEMA)
assert shared == {'schema_version'}, shared
# And neither parser will read the other's document.
both_refuse(json.dumps({'coordinator_account': 'cschott', 'coordinator_uid': 1000,
                        'schema_version': 1}).encode(), Status(), fixed(999, 987),
            'a coordinator authority as an execution identity')
print('OK')
"

# --- deployment neutrality: the assertion a constant could not pass -----------------

run_case "two unrelated deployments load, derive and govern identically" "${PRELUDE}
# Fixture A is the shape schai happens to have. Fixture B shares no digit with
# it. If anything below were still a constant, exactly one of these would pass.
for account, uid, gid in (('fixture-a', 999, 987), ('fixture-b', 2203, 2207)):
    raw = body(account, uid, gid)
    assert both_accept(raw, Status(), fixed(uid, gid)) == (account, uid, gid)

    loaded = policy.load_execution_identity(raw, Status(), resolve=fixed(uid, gid))
    # The rootless runtime directory is DERIVED from the uid, not stored.
    environment = dict(policy.execution_environment(loaded))
    assert environment['XDG_RUNTIME_DIR'] == f'/run/user/{uid}', environment
    assert environment['HOME'] == policy.EXECUTION_HOME
    assert set(environment) == {'HOME', 'XDG_RUNTIME_DIR'}, environment

    # The launch policy becomes that identity, and so does reconciliation.
    launch = policy.policy_for(['prog', 'CINV-000042'], identity=loaded)
    assert (launch.worker_uid, launch.worker_gid) == (uid, gid)
    assert launch.worker_user == account
    reconcile = policy.reconciliation_policy_for(['prog', 'CINV-000042'],
                                                 identity=loaded)
    assert (reconcile.worker_uid, reconcile.worker_gid) == (uid, gid)
    assert dict(reconcile.environment)['XDG_RUNTIME_DIR'] == f'/run/user/{uid}'

    # And the runtime half agrees, through its own implementation.
    other = runtime.load_execution_identity(raw, Status(), resolve=fixed(uid, gid))
    assert dict(runtime.environment(other)) == environment
    from tools.capability.execution import worker as W
    W.require_worker_identity(uid=uid, gid=gid, identity=other)
print('OK')
"

run_case "one deployment's authority is refused by another's account database" "${PRELUDE}
# The stale-authority case, and the reason both halves are carried. Authority A
# names fixture-a/999:987; the host resolves that name to 2203:2207 because the
# account was recreated. A number alone could not notice, and a name alone would
# have accepted whatever NSS said.
both_refuse(body('fixture-a', 999, 987), Status(), fixed(2203, 2207),
            \"authority A under deployment B's account database\")
both_refuse(body('fixture-b', 2203, 2207), Status(), fixed(999, 987),
            \"authority B under deployment A's account database\")
# One half agreeing is not agreement.
both_refuse(body('fixture-a', 999, 987), Status(), fixed(999, 2207),
            'a uid that agrees and a gid that does not')
both_refuse(body('fixture-a', 999, 987), Status(), fixed(2203, 987),
            'a gid that agrees and a uid that does not')
print('OK')
"

run_case "an account the database does not know is a refusal, not a default" "${PRELUDE}
def missing(account):
    raise KeyError(account)
for label, loader, refusal in PARSERS:
    try:
        loader(body(), Status(), resolve=missing)
    except (refusal, KeyError):
        continue
    raise AssertionError(f'{label} accepted an unresolvable account')
# The production resolvers turn the same absence into their own refusal type.
action = load('kyri_exec_transition_action', ACTION)
for resolver, refusal in ((action.resolve_account, policy.TransitionRefused),
                          (runtime.resolve_account, runtime.ExecutionIdentityError)):
    try:
        resolver('kyri-no-such-account-exists')
    except refusal:
        continue
    raise AssertionError('an unknown account resolved to something')
print('OK')
"

# --- the closed grammar ------------------------------------------------------------

run_case "the authority document is closed, and both parsers close it the same" "${PRELUDE}
resolve = fixed(999, 987)
both_accept(body(), Status(), resolve)

vectors = [
    (body(extra='x'), 'an unknown field'),
    (body(execution_uid=_ABSENT), 'a missing uid'),
    (body(execution_gid=_ABSENT), 'a missing gid'),
    (body(execution_account=_ABSENT), 'a missing account'),
    (body(schema_version=_ABSENT), 'a missing schema version'),
    (body(schema_version=2), 'an unsupported schema version'),
    (body(schema_version='1'), 'a schema version as a string'),
    (body(schema_version=True), 'a schema version as a boolean'),
    (body(execution_uid=True), 'a uid as a boolean'),
    (body(execution_gid=False), 'a gid as a boolean'),
    (body(execution_uid=0), 'root as the execution uid'),
    (body(execution_gid=0), 'the root group as the execution gid'),
    (body(execution_uid=-1), 'a negative uid'),
    (body(execution_gid=-1), 'a negative gid'),
    (body(execution_uid=2 ** 31), 'a uid beyond the representable range'),
    (body(execution_uid='999'), 'a uid as a string'),
    (body(execution_uid=999.0), 'a uid as a float'),
    (body(execution_account=''), 'an empty account'),
    (body(execution_account=' fixture-a'), 'an account with leading space'),
    (body(execution_account='fixture a'), 'an account with an inner space'),
    (body(execution_account='fixture,a'), 'an account carrying a comma'),
    (body(execution_account='fixture\\na'), 'an account carrying a newline'),
    (body(execution_account='x' * 33), 'an account beyond 32 characters'),
    (body(execution_account=999), 'an account that is not a string'),
    (b'', 'an empty document'),
    (b'{', 'a truncated document'),
    (b'[]', 'a JSON array'),
    (b'null', 'a JSON null'),
    (b'{}{}', 'two JSON documents'),
    (b'{\"execution_account\":\"a\",\"execution_account\":\"b\"}',
     'a document repeating a field'),
    (b'{\"execution_account\": \"\\xff\"}', 'a document that is not UTF-8'),
    (b' ' * 5000, 'a document beyond the byte bound'),
    (None, 'an absent body'),
    ('{}', 'a body handed over as text rather than bytes'),
]
for raw, why in vectors:
    both_refuse(raw, Status(), resolve, why)
print('OK')
"

run_case "the authority object must be root's, and both parsers require it" "${PRELUDE}
resolve = fixed(999, 987)
raw = body()
# Root-owned, root group, and writable by nobody else. The read bits are
# deliberately unconstrained: 0400 and 0444 are both root's decision.
for mode in (0o100444, 0o100400, 0o100440):
    both_accept(raw, Status(mode=mode), resolve)
for status, why in (
        (Status(uid=1000), 'an authority owned by the coordinator'),
        (Status(uid=999), 'an authority owned by the execution principal'),
        (Status(gid=1000), 'an authority in a non-root group'),
        (Status(mode=0o100664), 'an authority writable by its group'),
        (Status(mode=0o100646), 'an authority writable by the world'),
        (Status(mode=0o100666), 'an authority writable by everyone'),
        (Status(mode=0o040755), 'a directory offered as the authority'),
        (Status(mode=0o120777), 'a symlink offered as the authority')):
    both_refuse(raw, status, resolve, why)
print('OK')
"

run_case "production cannot be aimed at an authority somebody chose" "${PRELUDE}
import inspect
# One compiled-in location on each side, and no parameter through which a
# caller could name another. A test seam that took a path would be a production
# seam that took a path.
assert runtime.EXECUTION_AUTHORITY_PATH == '/etc/kyri/execution-identity.json'
assert policy.EXECUTION_AUTHORITY_PATH == runtime.EXECUTION_AUTHORITY_PATH
assert list(inspect.signature(runtime.read_execution_identity).parameters) \\
    == ['resolve']
# The privileged reader takes a backend, never a path: the path comes from the
# policy module's constant.
action = load('kyri_exec_transition_action', ACTION)
assert list(inspect.signature(action.execution_identity).parameters) == ['backend']
tree = ast.parse(ACTION.read_text(encoding='utf-8'))
reader = [n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == 'execution_identity']
assert len(reader) == 1
assert 'module.EXECUTION_AUTHORITY_PATH' in ast.unparse(reader[0])
print('OK')
"

# --- the hardcodes are gone, and the remainder is accounted for --------------------

run_case "no production module states the execution identity" "${PRELUDE}
# The seven sites G11-AR bounded, named individually so this reads as the
# migration checklist it closes rather than as a number.
for gone in ('WORKER_USER', 'WORKER_UID', 'WORKER_GID'):
    assert not hasattr(policy, gone), (gone, 'the transition helper restated it')
from tools.capability.execution import worker as W
for gone in ('WORKER_UID', 'WORKER_GID', 'ENVIRONMENT'):
    assert not hasattr(W, gone), (gone, 'the worker library restated it')
backend = load('kyri_exec_podman', BACKEND)
assert not hasattr(backend, 'BACKEND_ENVIRONMENT'), \\
    'the runtime backend kept a default naming one deployment'

def literals(path):
    '''Every constant in the CODE. Docstrings removed; comments are not AST.'''
    tree = ast.parse(path.read_text(encoding='utf-8'))
    for node in ast.walk(tree):
        block = getattr(node, 'body', None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and block and isinstance(block[0], ast.Expr)
                and isinstance(block[0].value, ast.Constant)
                and isinstance(block[0].value.value, str)):
            del block[0]
    return [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)]

# Nothing that carries execution identity may state one. Comments may -- they
# record what was removed and cannot be executed.
for path in (TRANSITION, ACTION, WORKER_LIB, RUNTIME_IDENTITY, BACKEND,
             RECONCILE, Path('tools/capability/execution/verification.py'),
             Path('provisioning/execution/kyri-exec-worker.py'),
             Path('provisioning/execution/kyri-exec-reconcile-entrypoint.py'),
             Path('provisioning/execution/kyri-exec-reconcile-worker.py')):
    values = literals(path)
    for number in (999, 987):
        assert number not in values, (str(path), number)
    for value in values:
        if isinstance(value, str):
            assert '/run/user/9' not in value, (str(path), value)
            assert 'kyri-capability' not in value, (str(path), value)
print('OK')
"

run_case "the rootless runtime directory is derived, never written down" "${PRELUDE}
# The rootless runtime directory is a function of the identity, so a record
# that stored it could state a pair that disagreed with itself. Both sides
# derive it, and the only literal either keeps is the parent directory.
assert policy.RUNTIME_DIRECTORY_ROOT == '/run/user'
assert runtime.RUNTIME_DIRECTORY_ROOT == policy.RUNTIME_DIRECTORY_ROOT
assert 'xdg_runtime_dir' not in [f.lower() for f in policy.EXECUTION_AUTHORITY_SCHEMA]
assert 'home' not in [f.lower() for f in policy.EXECUTION_AUTHORITY_SCHEMA]
for uid in (999, 2203, 40000):
    loaded = policy.load_execution_identity(body('acct', uid, 4242), Status(),
                                            resolve=fixed(uid, 4242))
    assert dict(policy.execution_environment(loaded))['XDG_RUNTIME_DIR'] \\
        == f'/run/user/{uid}'
print('OK')
"

# --- the two implementations must not drift ---------------------------------------

run_case "the helper and the runtime state the same authority contract" "${PRELUDE}
# The helper installs beneath a root that must stay usable without the runtime
# package, so it cannot import this module and carries its own implementation.
# Two implementations that can disagree are a boundary that can be crossed one
# way and not the other, so the contract is pinned in both directions.
assert policy.EXECUTION_AUTHORITY_PATH == runtime.EXECUTION_AUTHORITY_PATH
assert policy.EXECUTION_AUTHORITY_SCHEMA == runtime.EXECUTION_AUTHORITY_SCHEMA
assert policy.SUPPORTED_EXECUTION_SCHEMA_VERSION \\
    == runtime.SUPPORTED_EXECUTION_SCHEMA_VERSION
assert policy.MAXIMUM_EXECUTION_AUTHORITY_BYTES \\
    == runtime.MAXIMUM_EXECUTION_AUTHORITY_BYTES
assert policy.EXECUTION_HOME == runtime.EXECUTION_HOME
assert policy.RUNTIME_DIRECTORY_ROOT == runtime.RUNTIME_DIRECTORY_ROOT
# And the derived environment is byte-for-byte the same object shape.
loaded = policy.load_execution_identity(body(), Status(), resolve=fixed(999, 987))
other = runtime.load_execution_identity(body(), Status(), resolve=fixed(999, 987))
assert policy.execution_environment(loaded) == runtime.environment(other)
print('OK')
"

run_case "neither side can be handed an identity it did not load" "${PRELUDE}
# The privileged side's identity is token-guarded: a look-alike carrying the
# right attributes is structurally unusable, because what root becomes must not
# be decidable by whoever constructed a mapping.
look_alike = type('Look', (), {'account': 'x', 'uid': 999, 'gid': 987})()
for wrong in (None, 999, 'kyri-capability', {'uid': 999}, look_alike):
    for builder in (policy.policy_for, policy.reconciliation_policy_for):
        try:
            builder(['prog', 'CINV-000042'], identity=wrong)
        except policy.TransitionRefused:
            continue
        raise AssertionError(f'{builder.__name__} accepted {wrong!r}')
    try:
        policy.execution_environment(wrong)
    except policy.TransitionRefused:
        pass
    else:
        raise AssertionError(f'an environment was derived from {wrong!r}')
try:
    policy.ExecutionIdentity(object(), account='x', uid=1, gid=1)
except policy.TransitionRefused:
    pass
else:
    raise AssertionError('an execution identity was constructed directly')
loaded = policy.load_execution_identity(body(), Status(), resolve=fixed(999, 987))
try:
    loaded.uid = 0
except policy.TransitionRefused:
    pass
else:
    raise AssertionError('the execution identity is mutable')
print('OK')
"

# --- host identity and container identity stay distinct ----------------------------

run_case "the host identity does not govern the container identity" "${PRELUDE}
from tools.capability.execution import profile as P
from tools.capability.execution import worker as W
# Adapter-bound and constant, whatever the deployment is. Two unrelated hosts
# govern the same container contract, which is the property that would break if
# the two identities were ever collapsed.
for account, uid, gid in (('fixture-a', 999, 987), ('fixture-b', 2203, 2207)):
    host = runtime.load_execution_identity(body(account, uid, gid), Status(),
                                           resolve=fixed(uid, gid))
    assert P.EXECUTION_UID == 65532 and P.EXECUTION_GID == 65532
    assert P.EXECUTION_UID != host.uid and P.EXECUTION_GID != host.gid
    assert P.identity_mapping(P.EXECUTION_UID) == '65532:0:1'
    assert W.CONTAINER_UID == P.EXECUTION_UID
print('OK')
"

# --- the purity backstop for the runtime module ------------------------------------

run_case "the runtime identity module starts nothing and elevates nothing" "${PRELUDE}
tree = ast.parse(RUNTIME_IDENTITY.read_text(encoding='utf-8'))
FORBIDDEN_IMPORTS = {'subprocess', 'multiprocessing', 'ctypes', 'socket',
                     'urllib', 'http', 'requests', 'asyncio', 'shutil',
                     'tempfile', 'runpy', 'signal', 'resource'}
FORBIDDEN_CALLS = {'system', 'popen', 'exec', 'eval', 'compile', 'execv',
                   'execve', 'fork', 'setuid', 'setgid', 'setgroups', 'chown',
                   'chmod', 'unlink', 'rename', 'write', 'mkdir', 'makedirs',
                   'getenv', 'putenv'}
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            assert alias.name.split('.')[0] not in FORBIDDEN_IMPORTS, alias.name
    elif isinstance(node, ast.ImportFrom):
        assert (node.module or '').split('.')[0] not in FORBIDDEN_IMPORTS, node.module
    elif isinstance(node, ast.Call):
        name = getattr(node.func, 'attr', None) or getattr(node.func, 'id', None)
        assert name not in FORBIDDEN_CALLS, name
    elif isinstance(node, ast.Attribute):
        assert node.attr not in ('environ', 'environb'), 'it reads the environment'
for node in ast.walk(tree):
    block = getattr(node, 'body', None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
            and block and isinstance(block[0], ast.Expr)
            and isinstance(block[0].value, ast.Constant)
            and isinstance(block[0].value.value, str)):
        block.pop(0)
        if not block:
            block.append(ast.Pass())
ast.fix_missing_locations(tree)
lowered = ast.unparse(tree).lower()
for token in ('podman', 'docker', 'sudo ', 'subprocess', '/bin/sh', 'setpriv'):
    assert token not in lowered, token
# NSS is reached only through the injected resolver, and the account-database
# module is imported at the one call that needs it, not bound at module scope.
imports = [n for n in ast.walk(tree)
           if isinstance(n, ast.Import) and any(a.name == 'pwd' for a in n.names)]
assert len(imports) == 1, imports
enclosing = [f.name for f in ast.walk(tree)
             if isinstance(f, ast.FunctionDef) and imports[0] in ast.walk(f)]
assert enclosing == ['resolve_account'], enclosing
print('OK')
"

# --- what the numbers still appear in, and why -------------------------------------

run_case "every remaining 999 or 987 in the tree is an operator ceremony" "${PRELUDE}
# Phase 7 asks for a classification rather than a zero. The runtime and helper
# surfaces are clean; what remains are operator ceremonies whose SUBJECT is this
# accepted host, and comments recording what was removed.
#
# The ceremonies are named individually. Migrating them to read the authority is
# correct but must follow its installation -- until then a ceremony that read it
# would refuse on every host including this one.
CEREMONIES = {
    'provisioning/execution/g5-ceremony.sh',
    'provisioning/execution/g5-preflight.sh',
    'provisioning/execution/g11-ai-image-export.sh',
    'provisioning/execution/install-generation-6.sh',
}
offenders = []
for path in sorted(Path('.').glob('**/*.py')) + sorted(Path('.').glob('**/*.sh')):
    text = str(path)
    if text.startswith(('tests/', 'docs/', '.git/')):
        continue
    if not (text.startswith('tools/') or text.startswith('provisioning/')):
        continue
    for number, line in enumerate(
            path.read_text(encoding='utf-8').splitlines(), start=1):
        # Token match, not substring: 999_999 is a sequence bound and
        # b0ff...9999d... is a digest. Neither is an execution identity, and a
        # scan that could not tell them apart would be noise rather than a
        # classification.
        if not re.search(r'(?<![\w.])(999|987)(?![\w.])', line):
            continue
        stripped = line.lstrip()
        if text in CEREMONIES:
            continue          # an operator ceremony pinned to this host
        offenders.append(f'{text}:{number}: {stripped}')
assert not offenders, offenders
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution identity authority validation passed.\n'
else
  printf 'Capability execution identity authority validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
