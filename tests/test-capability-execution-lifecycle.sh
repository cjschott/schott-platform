#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T12.
#
# T12 is the permanently unprivileged worker: the side that talks to rootless
# Podman. NO PODMAN RUNS HERE. Every interaction goes through an injected fake
# backend, no subprocess exists in the production modules at all, and no
# container is created or started. Gate G6 stays closed.
#
# CREATE AND START ARE SEPARATE, and that is load-bearing rather than stylistic:
# the container's identity and profile must be recorded and verified before any
# capability code is authorised to run. `podman run` would collapse those two
# moments into one and remove the verification point entirely.
#
# THE WORKER OBSERVES; IT DOES NOT JUDGE. It reports what Podman said, missing
# fields included. It never fills a gap from what it expected, never repairs a
# mismatch, and never decides a difference is acceptable -- the coordinator owns
# that comparison.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §7, §12, §17
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T12

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/worker.py"
assert_file "tools/capability/execution/lifecycle.py"

# ===========================================================================
# The T12 worker backstop
# ===========================================================================
# The first execution module allowed to name Podman. Naming it is all that is
# permitted: no socket, no API, no remote URI, no subprocess, and no subcommand
# beyond the two the accepted lifecycle uses.

assert_worker_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
targets = [root / "tools/capability/execution/worker.py",
           root / "tools/capability/execution/lifecycle.py"]

# Subprocess binding is NOT assigned to T12, so it is forbidden outright.
FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes", "socket",
    "http", "urllib", "requests", "asyncio", "docker", "pty", "shlex",
    "random", "secrets", "tempfile", "shutil", "glob", "logging", "signal",
    "pwd", "grp", "resource", "time", "datetime",
}
FORBIDDEN_CALLS = {
    "system", "popen", "spawnv", "posix_spawn", "fork", "exec", "eval",
    "compile", "__import__", "getenv", "putenv", "setuid", "setgid",
    "setgroups", "chroot", "chdir", "mount", "unshare", "chmod", "chown",
    "rename", "rmdir", "makedirs", "mkdir", "unlink", "remove", "now",
    "today", "monotonic", "sleep", "which",
}
# Every Podman surface that would widen the worker beyond its contract.
FORBIDDEN_TEXT = (
    "podman run", "podman pull", "podman build", "podman exec", "podman rm",
    "podman system", "podman ps", "podman images", "podman login",
    "podman-remote", "podman.socket", "docker", "containers.sock",
    "container_host", "docker_host", "--remote", "--url", "--connection",
    "libpod", "/v1.40", "unix://", "tcp://", "ssh://", "shell=true",
    "sudo", "runuser", "/bin/sh", "/bin/bash",
)

if any(not t.is_file() for t in targets):
    print("module-absent")
    raise SystemExit(0)

findings = []
for target in targets:
    rel = target.relative_to(root)
    source = target.read_text(encoding="utf-8")
    tree = ast.parse(source)
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
    code = ast.unparse(tree)
    lowered = code.lower()

    for token in FORBIDDEN_TEXT:
        if token in lowered:
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

    permitted_os = {"open", "read", "close", "fstat", "stat", "scandir",
                    "getuid", "geteuid", "getgid", "getegid", "O_RDONLY",
                    "O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY", "error"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id == "os" and node.attr not in permitted_os:
            findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

    # Only the two accepted subcommands may appear as argv literals.
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if node.value in ("run", "pull", "build", "exec", "rm", "system",
                              "ps", "images", "load", "save", "push", "cp"):
                findings.append(f"{rel}: Podman subcommand literal: {node.value!r}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T12 worker authority is bounded: CLI only, no socket, API, or subprocess"
  else
    fail "T12 backstop found: ${report}"
  fi
}

assert_worker_authority

# ===========================================================================
# Behaviour
# ===========================================================================

WORK="$(mktemp -d)"
cleanup() { chmod -R u+rwX "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"; }
trap cleanup EXIT

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

PRELUDE="
import os, shutil
from tools.capability.execution import worker as W
from tools.capability.execution import lifecycle as L
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.profile import (
    build_profile, ProfileBinding, ObservedProfile)
from tools.capability.execution.protocol import (
    Message, MessageKind, Session, encode, ProtocolViolation)
from tools.capability.execution.types import Classification, Mount
WORK = os.environ['WORKDIR']
CINV = 'CINV-000042'
CID = 'c' * 64
IMAGE = 'sha256:' + 'a' * 64

def package(entrypoint='main.py', extra=()):
    from tools.capability.execution.package_contract import validate_package
    import uuid
    base = os.path.join(WORK, 'pkg-' + entrypoint.replace('/', '_'))
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(os.path.dirname(os.path.join(base, entrypoint)) or base,
                exist_ok=True)
    with open(os.path.join(base, entrypoint), 'wb') as h:
        h.write(b'def run():\n    return {}\n')
    for name in extra:
        with open(os.path.join(base, name), 'wb') as h:
            h.write(b'X = 1\n')
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return validate_package(fd, entrypoint=entrypoint)
    finally:
        os.close(fd)

def profile(cinv=CINV):
    return build_profile(ProfileBinding(cinv=cinv, admission=Admission(
        cimp='CIMP-000001', oci_digest=IMAGE,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=1,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)))

def make_handoff(name='h', cinv=CINV, mode_pkg=0o555, mode_payload=0o444,
                 mode_out=0o700, mode_inv=0o555):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        chmod_tree(base); shutil.rmtree(base)
    inv = os.path.join(base, cinv)
    os.makedirs(os.path.join(inv, 'package'))
    os.makedirs(os.path.join(inv, 'out'))
    with open(os.path.join(inv, 'package', 'main.py'), 'wb') as h:
        h.write(b'def run():\n    return {}\n')
    with open(os.path.join(inv, 'payload'), 'wb') as h:
        h.write(b'{\"operation\":\"sum\"}')
    os.chmod(os.path.join(inv, 'payload'), mode_payload)
    os.chmod(os.path.join(inv, 'package'), mode_pkg)
    os.chmod(os.path.join(inv, 'out'), mode_out)
    os.chmod(inv, mode_inv)
    return base

def chmod_tree(base):
    for r, dirs, files in os.walk(base):
        for d in dirs: os.chmod(os.path.join(r, d), 0o755)
        for f in files: os.chmod(os.path.join(r, f), 0o644)

def root_fd(base):
    return os.open(base, os.O_RDONLY | os.O_DIRECTORY)

def sources(name='h', **kw):
    base = make_handoff(name, **kw)
    fd = root_fd(base)
    try:
        return W.verify_handoff(CINV, root_fd=fd)
    finally:
        os.close(fd)

class FakeBackend:
    '''Records Podman operations and performs none of them.'''

    def __init__(self, container_id=CID, inspect=None, create_error=None,
                 start_error=None, lifecycle=None):
        self.calls = []
        self._id = container_id
        self._inspect = inspect
        self._create_error = create_error
        self._start_error = start_error
        self._lifecycle = lifecycle or {
            'state': 'exited', 'started_at': '2026-08-12T00:00:00Z',
            'finished_at': '2026-08-12T00:00:05Z', 'exit_code': 0,
            'container_id': CID}

    def create(self, argv, environment):
        self.calls.append(('create', tuple(argv), tuple(environment)))
        if self._create_error:
            raise self._create_error
        return self._id

    def inspect(self, container_id):
        self.calls.append(('inspect', container_id))
        return self._inspect or {}

    def start(self, container_id):
        self.calls.append(('start', container_id))
        if self._start_error:
            raise self._start_error

    def lifecycle(self, container_id):
        self.calls.append(('lifecycle', container_id))
        return dict(self._lifecycle)

def code_of(module):
    '''Module source with docstrings removed.

    Every scan below uses this: the modules explain why a thing is absent, and
    a scan that cannot tell a docstring from a call would forbid the
    explanation.
    '''
    import ast, inspect
    tree = ast.parse(inspect.getsource(module))
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef)):
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(tree)
    return ast.unparse(tree)

def names(backend):
    return [c[0] for c in backend.calls]

def argv_of(backend):
    return [c for c in backend.calls if c[0] == 'create'][0][1]
"

# --- identity and executable ----------------------------------------------------

run_case "the worker refuses to run as root" "${PRELUDE}
for uid in (0,):
    try:
        W.require_worker_identity(uid=uid, gid=987)
    except W.WorkerRefused:
        continue
    raise AssertionError('running as root was accepted')
# And refuses any identity other than the accepted one.
for uid, gid in ((1000, 987), (999, 0), (0, 0), (1000, 1000)):
    try:
        W.require_worker_identity(uid=uid, gid=gid)
    except W.WorkerRefused:
        continue
    raise AssertionError(f'accepted uid={uid} gid={gid}')
assert W.require_worker_identity(uid=999, gid=987) is None
print('OK')
"

run_case "the Podman executable is a fixed absolute constant" "${PRELUDE}
assert W.PODMAN == '/usr/bin/podman', W.PODMAN
argv = W.create_argv(profile(), sources('exe'), package())
assert argv[0] == '/usr/bin/podman', argv[0]
code = code_of(W)
for banned in ('which', 'os.pathsep', 'expanduser', 'realpath', 'os.environ'):
    assert banned not in code, banned
print('OK')
"

run_case "the rootless environment is exactly the two accepted variables" "${PRELUDE}
assert dict(W.ENVIRONMENT) == {'HOME': '/data/kyri/capability',
                               'XDG_RUNTIME_DIR': '/run/user/999'}, W.ENVIRONMENT
names_ = {n for n, _ in W.ENVIRONMENT}
for banned in ('CONTAINER_HOST', 'DOCKER_HOST', 'XDG_DATA_HOME',
               'XDG_CONFIG_HOME', 'PATH', 'LD_PRELOAD'):
    assert banned not in names_, banned
assert not any(n.startswith('CONTAINERS_') for n in names_), names_
print('OK')
"

# --- handoff verification --------------------------------------------------------

run_case "handoff verification is descriptor-relative and returns fixed sources" "${PRELUDE}
found = sources('ok')
assert found.package == '/data/kyri/capability-handoff/CINV-000042/package'
assert found.payload == '/data/kyri/capability-handoff/CINV-000042/payload'
assert found.output == '/data/kyri/capability-handoff/CINV-000042/out'
import inspect
assert list(inspect.signature(W.verify_handoff).parameters) == ['cinv', 'root_fd']
print('OK')
"

run_case "the bind sources come from the compiled-in root, never from input" "${PRELUDE}
assert W.HANDOFF_ROOT == '/data/kyri/capability-handoff'
found = sources('fixed')
for value in (found.package, found.payload, found.output):
    assert value.startswith(W.HANDOFF_ROOT + '/' + CINV + '/'), value
    assert '..' not in value
code = code_of(W)
assert '/proc/self/fd' not in code, 'descriptor path used as a bind source'
assert '/dev/fd' not in code
print('OK')
"

run_case "a malformed CINV never reaches a handoff path" "${PRELUDE}
base = make_handoff('grammar')
fd = root_fd(base)
try:
    for bad in ('../../etc', '/etc/passwd', 'CINV-00004', 'cinv-000042',
                'CINV-000042/x', ''):
        try:
            W.verify_handoff(bad, root_fd=fd)
        except W.WorkerRefused:
            continue
        raise AssertionError(f'accepted {bad!r}')
finally:
    os.close(fd)
print('OK')
"

run_case "handoff objects of the wrong type, mode, or shape are refused" "${PRELUDE}
for kwargs in ({'mode_pkg': 0o777}, {'mode_payload': 0o666},
               {'mode_out': 0o777}, {'mode_inv': 0o777}):
    try:
        sources('bad', **kwargs)
    except W.WorkerRefused:
        continue
    raise AssertionError(f'accepted handoff with {kwargs}')
# A symlinked component is refused rather than followed.
base = make_handoff('sym')
inv = os.path.join(base, CINV)
os.chmod(inv, 0o755); os.remove(os.path.join(inv, 'payload'))
elsewhere = os.path.join(WORK, 'elsewhere'); open(elsewhere, 'wb').write(b'{}')
os.symlink(elsewhere, os.path.join(inv, 'payload')); os.chmod(inv, 0o555)
fd = root_fd(base)
try:
    W.verify_handoff(CINV, root_fd=fd)
except W.WorkerRefused:
    print('OK')
else:
    raise AssertionError('a symlinked payload was accepted')
finally:
    os.close(fd)
"

run_case "a missing handoff component is refused" "${PRELUDE}
base = make_handoff('missing')
inv = os.path.join(base, CINV)
os.chmod(inv, 0o755); os.rmdir(os.path.join(inv, 'out')); os.chmod(inv, 0o555)
fd = root_fd(base)
try:
    W.verify_handoff(CINV, root_fd=fd)
except W.WorkerRefused:
    print('OK')
else:
    raise AssertionError('a handoff missing its output leaf was accepted')
finally:
    os.close(fd)
"

# --- create argv ------------------------------------------------------------------

run_case "create and start are separate, and podman run appears nowhere" "${PRELUDE}
argv = W.create_argv(profile(), sources('sep'), package())
assert argv[1] == 'create', argv[1]
assert 'run' not in argv, argv
for module in (W, L):
    code = code_of(module)
    assert 'podman run' not in code
print('OK')
"

run_case "the container name is derived solely from the CINV" "${PRELUDE}
argv = W.create_argv(profile(), sources('name'), package())
assert W.container_name(CINV) == 'kyri-CINV-000042'
index = argv.index('--name')
assert argv[index + 1] == 'kyri-CINV-000042', argv[index + 1]
assert W.container_name('CINV-000001') == 'kyri-CINV-000001'
# No attempt suffix, no counter, no reuse marker.
for suffix in ('-1', '.1', '-attempt', '-retry'):
    assert not W.container_name(CINV).endswith(suffix)
print('OK')
"

run_case "the image is the exact bound digest, never a tag" "${PRELUDE}
argv = W.create_argv(profile(), sources('img'), package())
assert IMAGE in argv, argv
assert not any(a.endswith(':latest') for a in argv), argv
assert not any(a == 'latest' for a in argv)
image_index = argv.index(IMAGE)
# The image is the last flag-position argument before the container command.
assert image_index > argv.index('--name')
print('OK')
"

run_case "every accepted security flag is explicit in the argv" "${PRELUDE}
argv = W.create_argv(profile(), sources('flags'), package())
text = ' '.join(argv)
required = [
    '--network none', '--read-only', '--cap-drop ALL',
    '--security-opt no-new-privileges', '--pids-limit 64',
    '--memory 256m', '--memory-swap 256m', '--cpus 0.5',
    '--hostname trackb', '--user 1000:1000',
]
for fragment in required:
    assert fragment in text, (fragment, text)
print('OK')
"

run_case "the tmpfs carries its exact accepted options" "${PRELUDE}
argv = W.create_argv(profile(), sources('tmpfs'), package())
index = argv.index('--tmpfs')
spec = argv[index + 1]
assert spec.startswith('/tmp:'), spec
for option in ('size=16m', 'mode=1777', 'noexec', 'nosuid', 'nodev'):
    assert option in spec, (option, spec)
print('OK')
"

run_case "the three mounts carry the exact sources, destinations and access" "${PRELUDE}
found = sources('mounts')
argv = W.create_argv(profile(), found, package())
mounts = [argv[i + 1] for i, a in enumerate(argv) if a == '--mount']
assert len(mounts) == 3, mounts
joined = ' '.join(mounts)
assert f'src={found.package},dst=/kyri/package' in joined, mounts
assert f'src={found.payload},dst=/run/kyri/input/payload' in joined, mounts
assert f'src={found.output},dst=/kyri/output' in joined, mounts
package = [m for m in mounts if '/kyri/package' in m][0]
payload = [m for m in mounts if 'input/payload' in m][0]
output = [m for m in mounts if '/kyri/output' in m][0]
assert 'ro=true' in package and 'ro=true' in payload, (package, payload)
assert 'ro=false' in output, output
print('OK')
"

run_case "no device, privileged, host-network or socket flag appears" "${PRELUDE}
argv = W.create_argv(profile(), sources('none'), package())
text = ' '.join(argv)
for banned in ('--device', '--privileged', '--network host', '--pid host',
               '--cap-add', '--gpus', '--security-opt seccomp=unconfined',
               '--userns=host', '/var/run/docker.sock', 'podman.sock'):
    assert banned not in text, banned
print('OK')
"

run_case "the container command is adapter-owned with no caller argv" "${PRELUDE}
argv = W.create_argv(profile(), sources('cmd'), package())
tail = list(argv[argv.index(IMAGE) + 1:])
assert tail == ['/usr/bin/python3', '/kyri/package/main.py'], tail
for banned in ('sh', '-c', 'bash', '--'):
    assert banned not in tail, banned
print('OK')
"

# The entrypoint is the governed one the package contract validated, not a
# constant. A nested entrypoint must survive intact into the container path.
run_case "the script argument comes from the bound package entrypoint" "${PRELUDE}
nested = package('pkg/main.py')
argv = W.create_argv(profile(), sources('nested'), nested)
tail = list(argv[argv.index(IMAGE) + 1:])
assert tail == ['/usr/bin/python3', '/kyri/package/pkg/main.py'], tail
flat = package('main.py')
argv = W.create_argv(profile(), sources('flat'), flat)
assert list(argv[argv.index(IMAGE) + 1:]) == [
    '/usr/bin/python3', '/kyri/package/main.py']
# Two different bindings produce their own script argument.
deep = package('a/b/entry.py')
argv = W.create_argv(profile(), sources('deep'), deep)
assert list(argv[argv.index(IMAGE) + 1:])[1] == '/kyri/package/a/b/entry.py'
print('OK')
"

run_case "no hard-coded entrypoint remains, and none is caller-supplied" "${PRELUDE}
import inspect
code = code_of(W)
assert '/kyri/package/main.py' not in code, 'a hard-coded entrypoint remains'
assert 'main.py' not in code, 'the worker names a specific script'
params = list(inspect.signature(W.create_argv).parameters)
assert params == ['profile', 'sources', 'package'], params
assert 'entrypoint' not in params, params
# The entrypoint cannot arrive as a raw string.
from tools.capability.execution.worker import WorkerRefused
for bad in ('main.py', None, 42, {'entrypoint': 'main.py'}):
    try:
        W.create_argv(profile(), sources('raw'), bad)
    except WorkerRefused:
        continue
    raise AssertionError(f'accepted {bad!r} as a package binding')
print('OK')
"

run_case "no pull, and the argv is closed against extra flags" "${PRELUDE}
assert 'pull' not in code_of(W).lower(), 'the worker can pull'
argv = W.create_argv(profile(), sources('closed'), package())
# Every element is a constant, a governed identity, or a derived source.
assert isinstance(argv, tuple), type(argv)
try:
    argv.append('--privileged')
except AttributeError:
    print('OK')
else:
    raise AssertionError('the argv is mutable')
"

# --- create -------------------------------------------------------------------------

run_case "create returns the full 64-hex container ID" "${PRELUDE}
backend = FakeBackend()
container_id = L.create(backend, W.create_argv(profile(), sources('create'), package()),
                        W.ENVIRONMENT)
assert container_id == CID
assert names(backend) == ['create']
print('OK')
"

run_case "a short or malformed container ID is refused as authority" "${PRELUDE}
for bad in ('c' * 12, 'c' * 63, 'c' * 65, 'C' * 64, '', 'deadbeef', None, 42):
    backend = FakeBackend(container_id=bad)
    try:
        L.create(backend, W.create_argv(profile(), sources('short'), package()), W.ENVIRONMENT)
    except L.LifecycleRefused:
        continue
    raise AssertionError(f'accepted container id {bad!r}')
print('OK')
"

run_case "create failure never retries, recreates, or falls back" "${PRELUDE}
backend = FakeBackend(create_error=OSError('create refused'))
try:
    L.create(backend, W.create_argv(profile(), sources('fail'), package()), W.ENVIRONMENT)
except L.LifecycleRefused:
    pass
else:
    raise AssertionError('a failed create was accepted')
assert names(backend).count('create') == 1, names(backend)
code = code_of(L)
for banned in ('while ', 'retry', 'again', 'recreate', 'fallback'):
    assert banned not in code, banned
print('OK')
"

# --- observed profile -----------------------------------------------------------------

run_case "the observed profile is mapped from Podman data, not from expectation" "${PRELUDE}
expected = profile()
inspect_data = {
    'Id': CID, 'ImageDigest': IMAGE, 'NetworkMode': 'none',
    'ReadOnlyRootfs': True, 'NoNewPrivileges': True,
    'CapDrop': ['ALL'], 'EffectiveCaps': [], 'Memory': 268435456,
    'MemorySwap': 268435456, 'CpuQuota': 50000, 'CpuPeriod': 100000,
    'PidsLimit': 64, 'User': '1000:1000', 'Hostname': 'trackb',
    'Devices': [], 'Sockets': [], 'TmpfsSize': 16777216,
    'TmpfsMode': 1023, 'TmpfsOptions': ['noexec', 'nosuid', 'nodev'],
    'ProfileSchemaVersion': 1,
    'Mounts': [
        {'Destination': '/kyri/package', 'RW': False, 'Type': 'bind'},
        {'Destination': '/run/kyri/input/payload', 'RW': False, 'Type': 'bind'},
        {'Destination': '/kyri/output', 'RW': True, 'Type': 'bind'}],
}
observed = L.observe(FakeBackend(inspect=inspect_data), CID)
assert isinstance(observed, ObservedProfile)
from tools.capability.execution.profile import verify_observed
assert verify_observed(expected, observed) is None
print('OK')
"

run_case "a missing observed field stays missing and is never filled" "${PRELUDE}
base = {
    'Id': CID, 'ImageDigest': IMAGE, 'NetworkMode': 'none',
    'ReadOnlyRootfs': True, 'NoNewPrivileges': True, 'CapDrop': ['ALL'],
    'EffectiveCaps': [], 'Memory': 268435456, 'MemorySwap': 268435456,
    'CpuQuota': 50000, 'CpuPeriod': 100000, 'PidsLimit': 64,
    'User': '1000:1000', 'Hostname': 'trackb', 'Devices': [], 'Sockets': [],
    'TmpfsSize': 16777216, 'TmpfsMode': 1023,
    'TmpfsOptions': ['noexec', 'nosuid', 'nodev'],
    'ProfileSchemaVersion': 1, 'Mounts': [],
}
from tools.capability.execution.profile import verify_observed, ProfileMismatch
for dropped in ('NetworkMode', 'ReadOnlyRootfs', 'PidsLimit', 'Memory',
                'NoNewPrivileges', 'Hostname'):
    data = dict(base); data.pop(dropped)
    observed = L.observe(FakeBackend(inspect=data), CID)
    try:
        verify_observed(profile(), observed)
    except ProfileMismatch:
        continue
    raise AssertionError(f'a missing {dropped} was filled in')
print('OK')
"

run_case "the worker never repairs a mismatch" "${PRELUDE}
for module in (W, L):
    code = code_of(module).lower()
    for banned in ('update', 'rename', 'remount', 'restart', 'recreate',
                   'repair', 'fixup', 'reconfigure'):
        assert banned not in code, (module.__name__, banned)
print('OK')
"

# --- start -----------------------------------------------------------------------------

run_case "start requires a valid start_now in the session state" "${PRELUDE}
backend = FakeBackend()
frames = [encode(Message(kind=MessageKind.START_NOW, cinv=CINV,
                         fields=(('container_id', CID),)))]
session = Session(frames)
# Out of session order: the session has not seen created/verified yet.
try:
    L.start_when_authorised(backend, CID, session=session)
except ProtocolViolation:
    pass
else:
    raise AssertionError('start proceeded without a valid session state')
assert 'start' not in names(backend), names(backend)
print('OK')
"

run_case "start proceeds only after the accepted sequence reaches start_now" "${PRELUDE}
backend = FakeBackend()
msgs = [
    Message(kind=MessageKind.CREATED, cinv=CINV, fields=(('container_id', CID),)),
    Message(kind=MessageKind.VERIFIED_PROFILE, cinv=CINV, fields=(
        ('container_id', CID), ('profile_digest', 'd' * 64),
        ('image_digest', IMAGE), ('cimp', 'CIMP-000001'),
        ('profile_schema_version', 1), ('execution_uid', 1000),
        ('execution_gid', 1000))),
    Message(kind=MessageKind.START_NOW, cinv=CINV, fields=(('container_id', CID),)),
]
session = Session([encode(m) for m in msgs])
session.expect(MessageKind.CREATED)
session.expect(MessageKind.VERIFIED_PROFILE)
L.start_when_authorised(backend, CID, session=session)
assert names(backend) == ['start'], names(backend)
assert backend.calls[0] == ('start', CID)
print('OK')
"

run_case "a start_now naming a different container is refused" "${PRELUDE}
backend = FakeBackend()
other = 'd' * 64
msgs = [
    Message(kind=MessageKind.CREATED, cinv=CINV, fields=(('container_id', CID),)),
    Message(kind=MessageKind.VERIFIED_PROFILE, cinv=CINV, fields=(
        ('container_id', CID), ('profile_digest', 'd' * 64),
        ('image_digest', IMAGE), ('cimp', 'CIMP-000001'),
        ('profile_schema_version', 1), ('execution_uid', 1000),
        ('execution_gid', 1000))),
    Message(kind=MessageKind.START_NOW, cinv=CINV, fields=(('container_id', other),)),
]
session = Session([encode(m) for m in msgs])
session.expect(MessageKind.CREATED); session.expect(MessageKind.VERIFIED_PROFILE)
try:
    L.start_when_authorised(backend, CID, session=session)
except (ProtocolViolation, L.LifecycleRefused):
    assert 'start' not in names(backend)
    print('OK')
else:
    raise AssertionError('start accepted a different container id')
"

run_case "a second start is structurally unavailable" "${PRELUDE}
msgs = [
    Message(kind=MessageKind.CREATED, cinv=CINV, fields=(('container_id', CID),)),
    Message(kind=MessageKind.VERIFIED_PROFILE, cinv=CINV, fields=(
        ('container_id', CID), ('profile_digest', 'd' * 64),
        ('image_digest', IMAGE), ('cimp', 'CIMP-000001'),
        ('profile_schema_version', 1), ('execution_uid', 1000),
        ('execution_gid', 1000))),
    Message(kind=MessageKind.START_NOW, cinv=CINV, fields=(('container_id', CID),)),
    Message(kind=MessageKind.START_NOW, cinv=CINV, fields=(('container_id', CID),)),
]
backend = FakeBackend()
session = Session([encode(m) for m in msgs])
session.expect(MessageKind.CREATED); session.expect(MessageKind.VERIFIED_PROFILE)
L.start_when_authorised(backend, CID, session=session)
try:
    L.start_when_authorised(backend, CID, session=session)
except ProtocolViolation:
    assert names(backend).count('start') == 1, names(backend)
    print('OK')
else:
    raise AssertionError('a second start was permitted')
"

run_case "start failure is reported without retry" "${PRELUDE}
backend = FakeBackend(start_error=OSError('start refused'))
msgs = [
    Message(kind=MessageKind.CREATED, cinv=CINV, fields=(('container_id', CID),)),
    Message(kind=MessageKind.VERIFIED_PROFILE, cinv=CINV, fields=(
        ('container_id', CID), ('profile_digest', 'd' * 64),
        ('image_digest', IMAGE), ('cimp', 'CIMP-000001'),
        ('profile_schema_version', 1), ('execution_uid', 1000),
        ('execution_gid', 1000))),
    Message(kind=MessageKind.START_NOW, cinv=CINV, fields=(('container_id', CID),)),
]
session = Session([encode(m) for m in msgs])
session.expect(MessageKind.CREATED); session.expect(MessageKind.VERIFIED_PROFILE)
try:
    L.start_when_authorised(backend, CID, session=session)
except L.LifecycleRefused:
    assert names(backend).count('start') == 1, names(backend)
    print('OK')
else:
    raise AssertionError('a failed start was accepted')
"

# --- lifecycle observation --------------------------------------------------------------

run_case "lifecycle observation is bound to the recorded immutable ID" "${PRELUDE}
backend = FakeBackend()
observation = L.observe_lifecycle(backend, CID)
assert backend.calls == [('lifecycle', CID)], backend.calls
assert observation.container_id == CID
assert observation.state == 'exited'
print('OK')
"

run_case "a lifecycle report for a different container is refused" "${PRELUDE}
backend = FakeBackend(lifecycle={'state': 'exited', 'exit_code': 0,
                                 'started_at': 'x', 'finished_at': 'y',
                                 'container_id': 'd' * 64})
try:
    L.observe_lifecycle(backend, CID)
except L.LifecycleRefused:
    print('OK')
else:
    raise AssertionError('a lifecycle report for another container was accepted')
"

run_case "ExitCode is not trusted before the lifecycle proves a start" "${PRELUDE}
backend = FakeBackend(lifecycle={'state': 'created', 'exit_code': 0,
                                 'started_at': None, 'finished_at': None,
                                 'container_id': CID})
observation = L.observe_lifecycle(backend, CID)
assert observation.started_proven is False, observation
assert observation.exit_code_trustworthy is False, observation
running = FakeBackend(lifecycle={'state': 'exited', 'exit_code': 42,
                                 'started_at': '2026-08-12T00:00:00Z',
                                 'finished_at': '2026-08-12T00:00:01Z',
                                 'container_id': CID})
proven = L.observe_lifecycle(running, CID)
assert proven.started_proven is True and proven.exit_code_trustworthy is True
print('OK')
"

run_case "there is no arbitrary inspection, listing, or enumeration" "${PRELUDE}
for module in (W, L):
    public = [n for n in dir(module) if not n.startswith('_')]
    for banned in ('list_containers', 'list_images', 'enumerate',
                   'find_by_name', 'inspect_any', 'all_containers'):
        assert not any(banned in n.lower() for n in public), (module.__name__, banned)
    code = code_of(module)
    for banned in ('--all', '--format json', 'listdir'):
        assert banned not in code, (module.__name__, banned)
print('OK')
"

# --- backend and purity ---------------------------------------------------------------

run_case "the backend exposes only the accepted operations, with no generic runner" "${PRELUDE}
required = {'create', 'inspect', 'start', 'lifecycle'}
assert required <= set(dir(W.PodmanBackend)), sorted(dir(W.PodmanBackend))
for banned in ('run', 'command', 'invoke', 'call', 'execute', 'shell', 'raw'):
    assert not hasattr(W.PodmanBackend, banned), banned
print('OK')
"

run_case "no real Podman, subprocess, or container touched these tests" "${PRELUDE}
for module in (W, L):
    code = code_of(module)
    assert 'subprocess' not in code, module.__name__
    assert 'Popen' not in code
assert not os.path.exists('/data/kyri/capability-handoff')
assert os.getuid() != 0
print('OK')
"

run_case "the worker writes to no authority root" "${PRELUDE}
for module in (W, L):
    code = code_of(module)
    for banned in ('capability-runtime', 'transitions', 'mutations', 'locks',
                   'quarantine', 'admin-records', 'O_CREAT', 'O_WRONLY',
                   'os.write', 'os.rename', 'os.mkdir'):
        assert banned not in code, (module.__name__, banned)
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T12 worker and lifecycle validation passed.\n'
else
  printf 'Capability execution T12 worker and lifecycle validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
