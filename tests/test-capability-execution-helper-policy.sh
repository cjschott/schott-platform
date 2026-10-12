#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T10.
#
# T10 is the POLICY logic of the future privileged transition helper, and only
# the policy. It runs entirely as the ordinary development user: no sudo, no
# root, no identity change, no helper installation, no sudoers entry, no setuid
# bit, no file capability, no runtime directory, no Podman -- and NO EXECUTION.
#
# SOURCE IS NOT INSTALLATION. This file existing in the repository does not put
# a privileged helper on the host. T11 is the first task permitted near the
# transition boundary, behind gate G2, which is closed.
#
# THE POLICY IS SEPARABLE FROM THE ACTION on purpose. Every decision the helper
# must make -- argument grammar, evidence location, launch authorisation,
# ownership and mode expectations, target identity, executable, environment,
# working directory, descriptors -- is decided here and proven without
# privilege. T11 wires the decision to the syscalls; it does not re-decide.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §6
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="provisioning/execution/kyri-exec-transition.py"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "${HELPER}"

# ===========================================================================
# The T10 policy-only backstop
# ===========================================================================
# This file lives outside tools/capability/execution/, so it gets its own
# guard rather than borrowing the package's. The guard proves the absence of
# every privileged action surface. T11 will need a different guard because
# actual privileged operations become authorised there -- this one must not be
# weakened in anticipation of that.

assert_policy_only() {
  local report
  report="$(python3 - "${ROOT}" "${HELPER}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / sys.argv[2]

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "grp", "pwd", "signal", "resource",
    "termios", "select", "threading", "concurrent", "ssl", "getpass",
}
# Every way privilege could be acquired, dropped, or acted upon.
FORBIDDEN_CALLS = {
    "system", "popen", "spawnv", "spawnl", "exec", "eval", "compile",
    "execv", "execve", "execvp", "execvpe", "execl", "execle", "execlp",
    "fork", "forkpty", "posix_spawn", "posix_spawnp",
    "setuid", "seteuid", "setreuid", "setresuid", "setgid", "setegid",
    "setregid", "setresgid", "setgroups", "initgroups", "chroot", "chdir",
    "mount", "umount", "unshare", "setns", "capset", "prctl",
    "chmod", "chown", "fchmod", "fchown", "lchown", "mkdir", "makedirs",
    "remove", "unlink", "rename", "rmdir", "write", "truncate", "fsync",
    "symlink", "link", "mkfifo", "mknod", "putenv", "unsetenv",
    "kill", "killpg", "waitpid", "getenv", "environ", "now", "today",
    "monotonic", "uuid1", "uuid4", "which", "find_executable",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo ", "runuser", "systemd",
                  "subprocess", "os.system", "shell=true", "/bin/sh",
                  "/bin/bash", "capsh", "setpriv")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

findings = []
rel = target.relative_to(root)
tree = ast.parse(target.read_text(encoding="utf-8"))
for node in ast.walk(tree):
    body = getattr(node, "body", None)
    if not isinstance(body, list) or not body:
        continue
    if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
        continue
    first = body[0]
    if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
            and isinstance(first.value.value, str):
        body.pop(0)
        if not body:
            body.append(ast.Pass())
ast.fix_missing_locations(tree)

stripped = ast.unparse(tree).lower()
for token in FORBIDDEN_TEXT:
    if token in stripped:
        findings.append(f"{rel}: forbidden token in code: {token}")

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{rel}: forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"{rel}: forbidden import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"{rel}: forbidden call: {attr}")
    elif isinstance(node, ast.Attribute) and node.attr in ("environ", "environb"):
        findings.append(f"{rel}: reads the environment")

# os is permitted only for read-only inspection assigned by the plan.
permitted_os = {"stat", "lstat", "fstat", "open", "read", "close",
                "O_RDONLY", "O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY", "path",
                "stat_result"}
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
            and node.value.id == "os" and node.attr not in permitted_os:
        findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T10 is policy-only: no privilege change, execution, or host mutation"
  else
    fail "T10 policy backstop found: ${report}"
  fi
}

assert_policy_only

# ===========================================================================
# Behaviour
# ===========================================================================

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Production roots this suite must never touch.
#
# Proven by comparing a snapshot taken before the first case with one taken
# after the last. The previous form asserted these paths did not exist, which
# only ever asked whether G4 had run -- not a property of this suite, and false
# from the moment provisioning completed. Non-mutation is the actual claim, and
# it is checkable on a clean host and a provisioned one alike.
PRODUCTION_PATHS=(
  /data/kyri/capability-handoff
  /data/kyri/capability-runtime/execution
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
)
PRODUCTION_BEFORE="${WORK}/production-before.json"
snapshot_production() {
  python3 -c '
import json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    state[path] = [info.st_mode, info.st_uid, info.st_gid, info.st_size,
                   info.st_mtime_ns, info.st_ctime_ns]
print(json.dumps(state, sort_keys=True))
' "$@"
}
snapshot_production "${PRODUCTION_PATHS[@]}" > "${PRODUCTION_BEFORE}"

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && WORKDIR="${WORK}" python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then
      pass "${label}"
    else
      fail "${label} -- expected OK, got: ${actual}"
    fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

# The helper is a hyphenated script, not an importable module name, so the
# fixture loads it by file location -- the same way an operator's installed
# copy would be executed rather than imported.
PRELUDE="
import dataclasses, importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    'kyri_exec_transition', 'provisioning/execution/kyri-exec-transition.py')
helper = importlib.util.module_from_spec(spec)
# Registered before execution: dataclasses resolves string annotations through
# sys.modules, and a module loaded by location alone is not there yet.
sys.modules['kyri_exec_transition'] = helper
spec.loader.exec_module(helper)
WORK = os.environ['WORKDIR']
SOURCE = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()

def code_only():
    '''The helper source with docstrings removed.'''
    import ast
    tree = ast.parse(SOURCE)
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(tree)
    return ast.unparse(tree)

def authority(account='kyri-capability', uid=999, gid=987, **overrides):
    '''One execution identity authority body, as the ceremony renders it.'''
    import json
    body = dict(execution_account=account, execution_gid=gid,
                execution_uid=uid, schema_version=1)
    body.update(overrides)
    return json.dumps(body, sort_keys=True, separators=(',', ':')).encode()

class Status:
    '''What os.fstat reports for a correctly provisioned authority.'''
    st_mode = 0o100444
    st_uid = 0
    st_gid = 0

def identity(account='kyri-capability', uid=999, gid=987):
    '''An approved execution identity, built the only way there is.'''
    return helper.load_execution_identity(
        authority(account, uid, gid), Status(),
        resolve=lambda name: (uid, gid))

IDENTITY = identity()

def record(**overrides):
    body = dict(
        cinv='CINV-000042', cimp='CIMP-000001',
        profile_digest='a' * 64,
        handoff_root='/data/kyri/capability-handoff',
        profile_schema_version=1, commitment_digest='b' * 64,
        lifecycle_state='launch_authorized')
    body.update(overrides)
    return body
"

# --- CLI grammar --------------------------------------------------------------

run_case "exactly one argument beyond the program name is accepted" "${PRELUDE}
policy = helper.policy_for(['/usr/libexec/kyri-exec-transition', 'CINV-000042'],
                           identity=IDENTITY)
assert policy.cinv == 'CINV-000042'
print('OK')
"

run_case "a missing, extra, or empty argument list is refused" "${PRELUDE}
for argv in ([], ['prog'], ['prog', 'CINV-000042', 'CINV-000043'],
             ['prog', 'CINV-000042', '--force'], ['prog', '', 'x']):
    try:
        helper.policy_for(argv, identity=IDENTITY)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted argv {argv}')
print('OK')
"

run_case "the CLI carries no command, executable, identity, or environment slot" "${PRELUDE}
import inspect
signature = inspect.signature(helper.policy_for)
# One positional parameter -- the command line -- and one keyword-only
# parameter carrying the deployment's execution identity. The second is NOT a
# caller slot: it is keyword-only, has no default, and is type-checked against
# a class only \`load_execution_identity\` can produce, so the only value that
# satisfies it came from root-owned authority. G11-AS added it; before that the
# identity was two constants compiled into this file.
params = list(signature.parameters)
assert params == ['argv', 'identity'], params
assert signature.parameters['identity'].kind is inspect.Parameter.KEYWORD_ONLY
assert signature.parameters['identity'].default is inspect.Parameter.empty
for wrong in (None, 999, 'kyri-capability', {'uid': 999, 'gid': 987},
              type('Look', (), {'account': 'x', 'uid': 999, 'gid': 987})()):
    try:
        helper.policy_for(['prog', 'CINV-000042'], identity=wrong)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'a look-alike identity was accepted: {wrong!r}')
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
for banned in ('--exec', '--command', '--user', '--uid', '--gid', '--env',
               '--cwd', '--image', '--mount', '--worker', '--config',
               'argparse', 'optparse', 'getopt'):
    assert banned not in source, banned
print('OK')
"

# --- CINV validation -----------------------------------------------------------

run_case "the canonical CINV is accepted and returned unchanged" "${PRELUDE}
assert helper.validate_cinv('CINV-000042') == 'CINV-000042'
assert helper.validate_cinv('CINV-000000') == 'CINV-000000'
assert helper.validate_cinv('CINV-999999') == 'CINV-999999'
print('OK')
"

run_case "every malformed CINV shape is refused" "${PRELUDE}
bad = [
    'CINV-00004', 'CINV-0000042', 'cinv-000042', 'CINV_000042', 'CINV000042',
    '-CINV-000042', '--CINV-000042', 'CINV-000042 ', ' CINV-000042',
    'CINV-000042\\n', 'CINV-000042\\t', 'CINV-00004a', 'CINV-+00042',
    '../../etc/passwd', '/etc/passwd', '/data/kyri', 'CINV-000042/x',
    'x/CINV-000042', '--help', '-h', '', 'CINV-', 'CINV-000042;id',
    'CINV-000042\\x00', 'CIMP-000001', 'c' * 64, 'a' * 64,
    'kyri-capability', '999', '0', 'python3', '/usr/bin/podman',
    'PATH=/tmp', 'CINV-000042 extra',
]
for value in bad:
    try:
        helper.validate_cinv(value)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted CINV {value!r}')
for value in (None, 42, b'CINV-000042', ['CINV-000042']):
    try:
        helper.validate_cinv(value)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted non-string {value!r}')
print('OK')
"

# --- evidence path construction --------------------------------------------------

run_case "evidence paths are constructed internally, with no root parameter" "${PRELUDE}
import inspect
assert list(inspect.signature(helper.evidence_path).parameters) == ['cinv']
assert list(inspect.signature(helper.handoff_path).parameters) == ['cinv']
print('OK')
"

run_case "constructed paths stay beneath their fixed compiled-in roots" "${PRELUDE}
evidence = helper.evidence_path('CINV-000042')
handoff = helper.handoff_path('CINV-000042')
assert str(evidence).startswith(helper.EXECUTION_ROOT + '/'), evidence
assert str(handoff) == helper.HANDOFF_ROOT + '/CINV-000042', handoff
assert '..' not in str(evidence) and '..' not in str(handoff)
# Validation happens before construction: a malformed CINV never reaches a path.
for value in ('../../etc', 'CINV-000042/../..', '/etc/passwd'):
    try:
        helper.evidence_path(value)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'built a path from {value!r}')
print('OK')
"

run_case "the fixed roots are absolute and compiled in" "${PRELUDE}
for name in ('EXECUTION_ROOT', 'HANDOFF_ROOT', 'WORKER_INTERPRETER',
             'WORKER_SCRIPT', 'HELPER_PATH', 'WORKING_DIRECTORY'):
    value = getattr(helper, name)
    assert isinstance(value, str) and value.startswith('/'), (name, value)
print('OK')
"

# --- launch authorisation ---------------------------------------------------------

run_case "a launch_authorized record is accepted and returned as a closed type" "${PRELUDE}
authenticated = helper.check_launch_authorisation(record(), 'CINV-000042')
# vNext: the check returns the authenticated projection rather than None. The
# privileged action needs the CIMP and the profile digest, and a return value
# only this function can produce is what stops those values arriving from
# anywhere else.
assert isinstance(authenticated, helper.AuthenticatedLaunch), authenticated
assert authenticated.cinv == 'CINV-000042'
assert authenticated.cimp == 'CIMP-000001'
assert authenticated.profile_digest == 'a' * 64
assert authenticated.lifecycle_state == 'launch_authorized'
print('OK')
"

run_case "the authenticated record cannot be constructed, mutated, or copied" "${PRELUDE}
authenticated = helper.check_launch_authorisation(record(), 'CINV-000042')
try:
    helper.AuthenticatedLaunch(**record())
except Exception:
    pass
else:
    raise AssertionError('an authenticated record was constructed directly')
for field in helper.LAUNCH_RECORD_SCHEMA:
    try:
        setattr(authenticated, field, 'x')
    except Exception:
        continue
    raise AssertionError('the authenticated record was mutated at ' + field)
try:
    delattr(authenticated, 'cimp')
except Exception:
    pass
else:
    raise AssertionError('a field was deleted from the authenticated record')
# And it is rebound to the invocation being transitioned, so an authentic
# record for a different CINV is no more usable than a forged one.
assert helper.require_authenticated(authenticated, 'CINV-000042') is authenticated
for stand_in in (dict(record()), None, 'CINV-000042', 42):
    try:
        helper.require_authenticated(stand_in, 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError('an unauthenticated stand-in was accepted')
try:
    helper.require_authenticated(authenticated, 'CINV-000043')
except helper.TransitionRefused:
    print('OK')
else:
    raise AssertionError('a record for another invocation was accepted')
"

run_case "the launch record is parsed bounded, and refuses what is not one document" "${PRELUDE}
import json
body = json.dumps(record()).encode('utf-8')
assert helper.parse_launch_record(body) == record()
for bad in (b'not json', b'[]', b'{}{}', b'{\"cinv\": \"CINV-000042\",}',
            b'{\"cinv\":\"CINV-000042\",\"cinv\":\"CINV-000042\"}',
            b'{' + b'\"x\":1,' * 4096 + b'}', 'a string', None, 42):
    try:
        document = helper.parse_launch_record(bad)
    except helper.TransitionRefused:
        continue
    if isinstance(document, dict) and set(document) == set(record()):
        raise AssertionError('accepted ' + repr(bad)[:40])
print('OK')
"

run_case "every other lifecycle state is refused" "${PRELUDE}
states = ['reserved', 'created', 'container_verified', 'start_authorized',
          'started', 'running', 'terminal', 'classified', 'collected',
          'cleaned', 'released']
for state in states:
    try:
        helper.check_launch_authorisation(record(lifecycle_state=state),
                                          'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted lifecycle state {state!r}')
print('OK')
"

run_case "a missing, unknown, or wrongly typed lifecycle state is refused" "${PRELUDE}
for value in (None, '', 'LAUNCH_AUTHORIZED', 'launch authorised', 1, True):
    body = record(); body['lifecycle_state'] = value
    try:
        helper.check_launch_authorisation(body, 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted lifecycle {value!r}')
body = record(); body.pop('lifecycle_state')
try:
    helper.check_launch_authorisation(body, 'CINV-000042')
except helper.TransitionRefused:
    print('OK')
else:
    raise AssertionError('accepted a record with no lifecycle state')
"

run_case "the record schema is closed and minimal" "${PRELUDE}
# vNext, ruled in design §14.1: still exactly seven fields, with profile_digest
# in place of oci_image_id. Root commits to bytes and stays opaque to what they
# say, so an image identity has no business in the privileged parser.
assert helper.LAUNCH_RECORD_SCHEMA == (
    'cinv', 'cimp', 'profile_digest', 'handoff_root',
    'profile_schema_version', 'commitment_digest',
    'lifecycle_state'), helper.LAUNCH_RECORD_SCHEMA
assert len(helper.LAUNCH_RECORD_SCHEMA) == 7
assert 'oci_image_id' not in SOURCE, 'the helper still names an image identity'
try:
    helper.check_launch_authorisation(record(extra='x'), 'CINV-000042')
except helper.TransitionRefused:
    pass
else:
    raise AssertionError('an unknown record field was accepted')
for field in list(helper.LAUNCH_RECORD_SCHEMA):
    body = record(); body.pop(field)
    try:
        helper.check_launch_authorisation(body, 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'a record missing {field!r} was accepted')
print('OK')
"

run_case "the helper reads no A1-A5 semantics beyond the one record" "${PRELUDE}
code = code_only()
for banned in ('CSEL', 'CINST', 'CPKG', 'CCON', 'CAPDEF', 'CRES', 'CGEN',
               'CMUT', 'CADM', 'fabric', 'Fabric', 'trust_', 'TrustStore',
               'TrustGateway', 'health', 'Health', 'eligibility', 'selection',
               'admission', 'retirement', 'transitions', 'authority-set',
               'authority_set', 'generation'):
    assert banned not in code, banned
# One record, one schema, and nothing that walks a store.
assert code.count('LAUNCH_RECORD_SCHEMA') >= 1
for banned in ('scandir', 'listdir', 'walk', 'glob', 'iterdir'):
    assert banned not in code, banned
print('OK')
"

run_case "record identity must match the validated CINV" "${PRELUDE}
for other in ('CINV-000043', 'CINV-000000'):
    try:
        helper.check_launch_authorisation(record(cinv=other), 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted record naming {other}')
print('OK')
"

run_case "record identity and digest fields are grammar-checked" "${PRELUDE}
for field, value in (('cimp', 'CIMP-00001'), ('cimp', 'cimp-000001'),
                     ('cimp', 'CIMP-00000a'), ('cimp', 'CINV-000001'),
                     # Grammatical and meaningless: the unallocated CIMP names
                     # no implementation and is refused by name.
                     ('cimp', 'CIMP-000000'),
                     ('profile_digest', 'g' * 64),
                     ('profile_digest', 'sha256:' + 'a' * 64),
                     ('profile_digest', 'A' * 64),
                     ('profile_digest', 'a' * 63),
                     ('profile_digest', 'a' * 65),
                     ('profile_digest', ''),
                     ('profile_digest', 1),
                     ('profile_digest', None),
                     ('commitment_digest', 'z' * 64),
                     ('commitment_digest', 'b' * 63),
                     ('commitment_digest', 'B' * 64),
                     ('profile_schema_version', '1'),
                     ('profile_schema_version', 2),
                     ('profile_schema_version', True),
                     ('handoff_root', '/tmp/elsewhere'),
                     ('handoff_root', '../handoff')):
    try:
        helper.check_launch_authorisation(record(**{field: value}), 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted {field}={value!r}')
print('OK')
"

run_case "the published profile is located and checked like every other object" "${PRELUDE}
import stat as statmod
assert helper.PROFILE_NAME == 'profile', helper.PROFILE_NAME
assert helper.profile_path('CINV-000042') == \\
    helper.HANDOFF_ROOT + '/CINV-000042/profile', helper.profile_path('CINV-000042')
for value in ('../../etc', 'CINV-000042/../..', '/etc/passwd', ''):
    try:
        helper.profile_path(value)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'built a profile path from {value!r}')
path = os.path.join(WORK, 'published-profile')
with open(path, 'wb') as handle:
    handle.write(b'{}')
os.chmod(path, 0o444)
info = os.lstat(path)
assert helper.check_profile_object(info, expected_uid=info.st_uid) is None
for mode in (0o644, 0o664, 0o666, 0o755, 0o400):
    os.chmod(path, mode)
    try:
        helper.check_profile_object(os.lstat(path), expected_uid=info.st_uid)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted profile mode {oct(mode)}')
os.chmod(path, 0o444)
try:
    helper.check_profile_object(os.lstat(path), expected_uid=info.st_uid + 1)
except helper.TransitionRefused:
    pass
else:
    raise AssertionError('accepted a profile owned by the wrong identity')
directory = os.path.join(WORK, 'profile-directory')
os.mkdir(directory, 0o555)
try:
    helper.check_profile_object(os.lstat(directory), expected_uid=info.st_uid)
except helper.TransitionRefused:
    pass
else:
    raise AssertionError('accepted a directory as the published profile')
empty = os.path.join(WORK, 'empty-profile')
open(empty, 'wb').close()
os.chmod(empty, 0o444)
try:
    helper.check_profile_object(os.lstat(empty), expected_uid=info.st_uid)
except helper.TransitionRefused:
    print('OK')
else:
    raise AssertionError('accepted an empty published profile')
"

# --- ownership and mode expectations ------------------------------------------------

run_case "evidence ownership and mode expectations are enforced" "${PRELUDE}
import stat as statmod
path = os.path.join(WORK, 'evidence')
with open(path, 'wb') as handle:
    handle.write(b'{}')
os.chmod(path, 0o600)
info = os.lstat(path)
# The fixture runs as the coordinator, which is exactly who must own it.
assert helper.check_evidence_object(info, expected_uid=info.st_uid) is None
for mode in (0o644, 0o660, 0o666, 0o700, 0o777):
    os.chmod(path, mode)
    try:
        helper.check_evidence_object(os.lstat(path), expected_uid=info.st_uid)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted evidence mode {oct(mode)}')
os.chmod(path, 0o600)
try:
    helper.check_evidence_object(os.lstat(path), expected_uid=info.st_uid + 1)
except helper.TransitionRefused:
    print('OK')
else:
    raise AssertionError('accepted evidence owned by the wrong identity')
"

run_case "a symlink or non-regular evidence object is refused" "${PRELUDE}
target = os.path.join(WORK, 'real'); link = os.path.join(WORK, 'link')
with open(target, 'wb') as handle:
    handle.write(b'{}')
os.chmod(target, 0o600)
os.symlink(target, link)
try:
    helper.check_evidence_object(os.lstat(link), expected_uid=os.getuid())
except helper.TransitionRefused:
    pass
else:
    raise AssertionError('a symlink was accepted as evidence')
fifo = os.path.join(WORK, 'fifo'); os.mkfifo(fifo, 0o600)
try:
    helper.check_evidence_object(os.lstat(fifo), expected_uid=os.getuid())
except helper.TransitionRefused:
    print('OK')
else:
    raise AssertionError('a FIFO was accepted as evidence')
"

run_case "handoff directory expectations are enforced" "${PRELUDE}
path = os.path.join(WORK, 'handoff'); os.mkdir(path, 0o555)
info = os.lstat(path)
assert helper.check_handoff_object(info, expected_uid=info.st_uid) is None
for mode in (0o777, 0o755, 0o700):
    os.chmod(path, mode)
    try:
        helper.check_handoff_object(os.lstat(path), expected_uid=info.st_uid)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted handoff mode {oct(mode)}')
os.chmod(path, 0o555)
print('OK')
"

# --- fixed identity, executable, environment ------------------------------------------

run_case "the target identity is fixed and cannot be chosen" "${PRELUDE}
# The target identity is whatever the deployment's authority named, and
# nothing else -- not a constant here, and not anything the caller reached.
for account, uid, gid in (('kyri-capability', 999, 987),
                          ('fixture-b', 2203, 2207)):
    policy = helper.policy_for(['prog', 'CINV-000042'],
                               identity=identity(account, uid, gid))
    assert policy.worker_user == account, policy.worker_user
    assert (policy.worker_uid, policy.worker_gid) == (uid, gid)
    # And the rootless runtime directory follows the uid rather than a literal.
    assert dict(policy.environment)['XDG_RUNTIME_DIR'] == f'/run/user/{uid}'
# Nothing compiled in remains to fall back to.
for gone in ('WORKER_USER', 'WORKER_UID', 'WORKER_GID'):
    assert not hasattr(helper, gone), gone
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
for banned in ('pwd.getpwnam', 'grp.getgrnam', 'int(sys.argv', 'os.getuid()'):
    assert banned not in source, banned
print('OK')
"

run_case "the worker executable is fixed, absolute, and never searched for" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'], identity=IDENTITY)
assert policy.worker_interpreter == '/usr/bin/python3', policy.worker_interpreter
assert policy.worker_script == '/usr/libexec/kyri-exec-worker.py', policy.worker_script
# vNext: argv is five elements and is built from the AUTHENTICATED record, not
# from the command line -- the CIMP and the profile digest cannot be known
# before the record is read, and must never come from a caller.
#
# G6.1: the target is a required keyword taken from the policy that was
# authorised, not from this module's own constant. It has no default -- a
# default would silently restore the divergence -- and it is still not
# caller-reachable, because policy_for is the only producer of a policy and
# each governed policy module compiles in exactly one target.
authenticated = helper.check_launch_authorisation(record(), 'CINV-000042')
argv = helper.worker_argv(authenticated, worker_script=policy.worker_script)
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-worker.py',
                'CINV-000042', 'CIMP-000001', 'a' * 64), argv
assert len(argv) == 5, argv
try:
    helper.worker_argv(authenticated)
except TypeError:
    pass
else:
    raise AssertionError('the worker target carries a default')
for ungoverned in ('', '/tmp/worker.py', 'kyri-exec-worker.py', None, 42,
                   '../usr/libexec/kyri-exec-worker.py'):
    try:
        helper.worker_argv(authenticated, worker_script=ungoverned)
    except helper.TransitionRefused:
        continue
    raise AssertionError('argv was built for an ungoverned target')
for stand_in in (None, 'CINV-000042', dict(record()), 42, ('CINV-000042',)):
    try:
        helper.worker_argv(stand_in, worker_script=policy.worker_script)
    except helper.TransitionRefused:
        continue
    raise AssertionError('argv was built from an unauthenticated value')
assert not any(f.name == 'worker_argv' for f in dataclasses.fields(policy)), \\
    'the policy result still carries a caller-reachable argv'
assert helper.WORKER_INTERPRETER.startswith('/')
assert helper.WORKER_SCRIPT.startswith('/')
# The script is an argument, never the executable: no -m, no shebang reliance.
assert '-m' not in argv
code = code_only()
# No lookup of any kind: no PATH read, no search helper, no normalisation that
# could turn a relative name into a resolved one.
for banned in ('shutil', 'which', 'os.pathsep', 'os.defpath', 'os.environ',
               'expanduser', 'realpath', 'abspath', 'resolve()', 'getenv'):
    assert banned not in code, banned
print('OK')
"

run_case "the environment policy is closed and carries nothing inherited" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'], identity=IDENTITY)
assert isinstance(policy.environment, tuple)
names = {name for name, _ in policy.environment}
# Exactly the two rootless Podman requires, and nothing inherited.
assert names == {'HOME', 'XDG_RUNTIME_DIR'}, names
assert dict(policy.environment) == {
    'HOME': '/data/kyri/capability',
    'XDG_RUNTIME_DIR': '/run/user/999'}, policy.environment
for banned in ('PATH', 'PYTHONPATH', 'PYTHONHOME', 'LD_PRELOAD',
               'LD_LIBRARY_PATH', 'SHELL', 'USER', 'LOGNAME',
               'CONTAINER_HOST', 'DOCKER_HOST', 'XDG_DATA_HOME',
               'XDG_CONFIG_HOME', 'PYTHONSTARTUP', 'SUDO_USER', 'SUDO_UID'):
    assert banned not in names, banned
assert not any(n.startswith('CONTAINERS_') for n in names), names
print('OK')
"

run_case "the working directory is fixed and never the caller's" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'], identity=IDENTITY)
assert policy.working_directory == helper.WORKING_DIRECTORY
assert policy.working_directory.startswith('/')
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
assert 'getcwd' not in source and 'chdir' not in source
print('OK')
"

run_case "descriptor policy names the protocol descriptors and the sealed profile" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'], identity=IDENTITY)
# vNext: one governed exception to stdio-only inheritance, and it is an
# exception rather than a return to ambient inheritance -- the number is
# compiled in, root opens the object itself, and no caller may name a
# descriptor.
assert helper.PROFILE_FD == 3, helper.PROFILE_FD
assert policy.inherited_descriptors == (0, 1, 2, 3), policy.inherited_descriptors
assert policy.profile_fd == helper.PROFILE_FD, policy.profile_fd
assert isinstance(policy.inherited_descriptors, tuple)
# The seal set is a decision, so it is stated here rather than wherever the
# syscall happens to be made.
assert helper.REQUIRED_SEALS == 0xF, hex(helper.REQUIRED_SEALS)
assert (helper.F_SEAL_SEAL, helper.F_SEAL_SHRINK, helper.F_SEAL_GROW,
        helper.F_SEAL_WRITE) == (0x1, 0x2, 0x4, 0x8)
print('OK')
"

# --- policy result ---------------------------------------------------------------

run_case "the policy result is immutable and carries no generic execution field" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'], identity=IDENTITY)
try:
    policy.worker_executable = '/bin/sh'
except Exception:
    pass
else:
    raise AssertionError('the policy result was mutated')
names = {f.name for f in dataclasses.fields(policy)}
for banned in ('command', 'argv_extra', 'shell', 'env', 'cwd', 'image',
               'mounts', 'uid_arg', 'user_arg', 'config_path', 'extra'):
    assert banned not in names, banned
assert names == {'cinv', 'worker_user', 'worker_uid', 'worker_gid',
                 'worker_interpreter', 'worker_script',
                 'evidence_path', 'handoff_path', 'profile_path',
                 'environment', 'working_directory',
                 'inherited_descriptors', 'profile_fd'}, names
print('OK')
"

# --- classification distinction ----------------------------------------------------

run_case "policy refusal before any transition classifies as transition_failed_before_execution" "${PRELUDE}
from tools.capability.execution.types import Classification
try:
    helper.validate_cinv('--help')
except helper.TransitionRefused as error:
    assert error.classification is Classification.TRANSITION_FAILED_BEFORE_EXECUTION
    assert error.execution_excluded is True
    print('OK')
else:
    raise AssertionError('a malformed CINV was accepted')
"

run_case "the classification is withheld when execution cannot be excluded" "${PRELUDE}
from tools.capability.execution.types import Classification
error = helper.TransitionRefused('ambiguous', execution_excluded=False)
assert error.execution_excluded is False
assert error.classification is None, error.classification
print('OK')
"

# --- structural absences ------------------------------------------------------------

# Code, not prose: the environment constants carry a comment explaining why
# rootless Podman needs them, and a scan that cannot tell a comment from a call
# would forbid explaining the reason.
run_case "the helper invokes no Podman, Docker, socket, or container runtime" "${PRELUDE}
code = code_only().lower()
for banned in ('podman', 'docker', 'containerd', 'crun', 'runc', '.sock',
               'socket', 'oci runtime'):
    assert banned not in code, banned
print('OK')
"

run_case "the helper performs no privilege change and no host mutation" "${PRELUDE}
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
for banned in ('setuid', 'setgid', 'setgroups', 'initgroups', 'seteuid',
               'setegid', 'execv', 'execve', 'fork', 'no_new_privs',
               'prctl', 'capset', 'unshare', 'chroot'):
    assert banned not in source, banned
print('OK')
"

run_case "T10 exposes only policy functions" "${PRELUDE}
import types as pytypes
functions = sorted(n for n, v in vars(helper).items()
                   if isinstance(v, pytypes.FunctionType) and not n.startswith('_'))
assert functions == ['check_coordinator_authority_object',
                     'check_evidence_object',
                     'check_execution_authority_object',
                     'check_handoff_object',
                     'check_launch_authorisation', 'check_profile_object',
                     'evidence_path', 'execution_environment', 'handoff_path',
                     'load_coordinator_authority', 'load_execution_identity',
                     'parse_coordinator_authority', 'parse_execution_authority',
                     'parse_launch_record',
                     'policy_for', 'profile_path', 'reconciliation_policy_for',
                     'require_authenticated',
                     'sudoers_principal', 'validate_cinv',
                     'worker_argv'], functions
# Every addition is a decision, not an action: locating the profile, checking
# its object properties, parsing one bounded record, closing that record into a
# type, rebinding it, and stating the command line. None of them open, copy,
# seal, or place anything -- T11 still owns every syscall.
#
# G11-AH added four, and they keep that shape. Checking a stat result, parsing
# bounded bytes, closing them into a type only this module can build, and
# naming the principal derived from it are all decisions; the descriptor the
# stat came from and the read that produced the bytes belong to the action
# layer, exactly as they do for the launch record.
#
# G11-AS added five, and every one of them is the same shape applied to the
# second deployment identity, plus one derivation (the rootless environment
# from an approved identity) and one second policy builder. The account
# resolver is deliberately NOT here: consulting NSS is a syscall dependency,
# it is forbidden by the backstop above, and it lives in the action layer with
# every other one. This module receives it injected and cannot go looking.
source = SOURCE
for banned in ('memfd', 'F_ADD_SEALS', 'F_GET_SEALS', 'dup2', 'F_SETFD',
               'os.write', 'os.read', 'os.open'):
    assert banned not in source, banned
print('OK')
"

# --- the tests themselves are unprivileged ---------------------------------------------

run_case "the fixture runs as an ordinary user and mutates no production root" "${PRELUDE}
import json
assert os.getuid() != 0, 'these tests must not run as root'
with open('${PRODUCTION_BEFORE}', encoding='utf-8') as handle:
    before = json.load(handle)
assert before, 'the production baseline is empty'


def observe(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    return [info.st_mode, info.st_uid, info.st_gid, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns]


for path, recorded in sorted(before.items()):
    current = observe(path)
    # st_ctime_ns is in the tuple so a chmod or chown is caught as well as a
    # write; comparing existence alone would miss both.
    assert current == recorded, path + ' changed while this suite ran'
    if recorded is None:
        assert current is None, path + ' was created by this suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T10 helper-policy validation passed.\n'
else
  printf 'Capability execution T10 helper-policy validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
