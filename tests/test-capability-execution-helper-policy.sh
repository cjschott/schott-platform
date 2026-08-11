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

def record(**overrides):
    body = dict(
        cinv='CINV-000042', cimp='CIMP-000001',
        oci_digest='sha256:' + 'a' * 64,
        handoff_root='/data/kyri/capability-handoff',
        profile_schema_version=1, commitment_digest='b' * 64,
        lifecycle_state='launch_authorized')
    body.update(overrides)
    return body
"

# --- CLI grammar --------------------------------------------------------------

run_case "exactly one argument beyond the program name is accepted" "${PRELUDE}
policy = helper.policy_for(['/usr/libexec/kyri-exec-transition', 'CINV-000042'])
assert policy.cinv == 'CINV-000042'
print('OK')
"

run_case "a missing, extra, or empty argument list is refused" "${PRELUDE}
for argv in ([], ['prog'], ['prog', 'CINV-000042', 'CINV-000043'],
             ['prog', 'CINV-000042', '--force'], ['prog', '', 'x']):
    try:
        helper.policy_for(argv)
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted argv {argv}')
print('OK')
"

run_case "the CLI carries no command, executable, identity, or environment slot" "${PRELUDE}
import inspect
params = list(inspect.signature(helper.policy_for).parameters)
assert params == ['argv'], params
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
    'CINV-000042\\x00', 'CIMP-000001', 'c' * 64, 'sha256:' + 'a' * 64,
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
for name in ('EXECUTION_ROOT', 'HANDOFF_ROOT', 'WORKER_EXECUTABLE',
             'HELPER_PATH', 'WORKING_DIRECTORY'):
    value = getattr(helper, name)
    assert isinstance(value, str) and value.startswith('/'), (name, value)
print('OK')
"

# --- launch authorisation ---------------------------------------------------------

run_case "a launch_authorized record is accepted" "${PRELUDE}
assert helper.check_launch_authorisation(record(), 'CINV-000042') is None
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
assert set(helper.LAUNCH_RECORD_SCHEMA) == {
    'cinv', 'cimp', 'oci_digest', 'handoff_root', 'profile_schema_version',
    'commitment_digest', 'lifecycle_state'}, set(helper.LAUNCH_RECORD_SCHEMA)
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
                     ('oci_digest', 'sha256:' + 'g' * 64),
                     ('oci_digest', 'a' * 64),
                     ('commitment_digest', 'z' * 64),
                     ('commitment_digest', 'b' * 63),
                     ('profile_schema_version', '1'),
                     ('profile_schema_version', 2),
                     ('handoff_root', '/tmp/elsewhere'),
                     ('handoff_root', '../handoff')):
    try:
        helper.check_launch_authorisation(record(**{field: value}), 'CINV-000042')
    except helper.TransitionRefused:
        continue
    raise AssertionError(f'accepted {field}={value!r}')
print('OK')
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
policy = helper.policy_for(['prog', 'CINV-000042'])
assert policy.worker_user == 'kyri-capability'
assert policy.worker_uid == 999 and policy.worker_gid == 987
assert helper.WORKER_USER == 'kyri-capability'
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
for banned in ('pwd.getpwnam', 'grp.getgrnam', 'int(sys.argv', 'os.getuid()'):
    assert banned not in source, banned
print('OK')
"

run_case "the worker executable is fixed, absolute, and never searched for" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'])
assert policy.worker_executable == '/usr/libexec/kyri-exec-worker', policy.worker_executable
assert policy.worker_argv == ('/usr/libexec/kyri-exec-worker', 'CINV-000042')
assert helper.WORKER_EXECUTABLE.startswith('/')
code = code_only()
# No lookup of any kind: no PATH read, no search helper, no normalisation that
# could turn a relative name into a resolved one.
for banned in ('shutil', 'which', 'os.pathsep', 'os.defpath', 'os.environ',
               'expanduser', 'realpath', 'abspath', 'resolve()', 'getenv'):
    assert banned not in code, banned
print('OK')
"

run_case "the environment policy is closed and carries nothing inherited" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'])
assert isinstance(policy.environment, tuple)
names = {name for name, _ in policy.environment}
for banned in ('PATH', 'PYTHONPATH', 'PYTHONHOME', 'LD_PRELOAD',
               'LD_LIBRARY_PATH', 'HOME', 'SHELL', 'USER', 'LOGNAME',
               'CONTAINER_HOST', 'DOCKER_HOST', 'XDG_RUNTIME_DIR',
               'PYTHONSTARTUP', 'SUDO_USER', 'SUDO_UID'):
    assert banned not in names, banned
# Only variables the worker's own contract requires, all adapter-owned.
assert names <= {'HOME', 'XDG_RUNTIME_DIR'} or names == set(), names
print('OK')
"

run_case "the working directory is fixed and never the caller's" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'])
assert policy.working_directory == helper.WORKING_DIRECTORY
assert policy.working_directory.startswith('/')
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text()
assert 'getcwd' not in source and 'chdir' not in source
print('OK')
"

run_case "descriptor policy names only the protocol descriptors" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'])
assert policy.inherited_descriptors == (0, 1, 2), policy.inherited_descriptors
assert isinstance(policy.inherited_descriptors, tuple)
print('OK')
"

# --- policy result ---------------------------------------------------------------

run_case "the policy result is immutable and carries no generic execution field" "${PRELUDE}
policy = helper.policy_for(['prog', 'CINV-000042'])
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
                 'worker_executable', 'worker_argv', 'evidence_path',
                 'handoff_path', 'environment', 'working_directory',
                 'inherited_descriptors'}, names
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

run_case "the helper never mentions Podman, Docker, a socket, or a container runtime" "${PRELUDE}
source = pathlib.Path('provisioning/execution/kyri-exec-transition.py').read_text().lower()
for banned in ('podman', 'docker', 'containerd', 'crun', 'runc', '.sock',
               'socket', 'oci runtime'):
    assert banned not in source, banned
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
assert functions == ['check_evidence_object', 'check_handoff_object',
                     'check_launch_authorisation', 'evidence_path',
                     'handoff_path', 'policy_for', 'validate_cinv'], functions
print('OK')
"

# --- the tests themselves are unprivileged ---------------------------------------------

run_case "the fixture runs as an ordinary user and touches no production root" "${PRELUDE}
assert os.getuid() != 0, 'these tests must not run as root'
for production in ('/data/kyri/capability-handoff',
                   '/data/kyri/capability-runtime/execution',
                   '/usr/libexec/kyri-exec-transition',
                   '/usr/libexec/kyri-exec-worker'):
    assert not os.path.exists(production), f'{production} exists: T10 must not provision'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T10 helper-policy validation passed.\n'
else
  printf 'Capability execution T10 helper-policy validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
