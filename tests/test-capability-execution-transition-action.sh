#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T11.
#
# T11 is the privileged action layer: the credential drop and the exec that a
# root helper will one day perform. THESE TESTS PERFORM NONE OF IT. Every
# privileged operation runs through an injected backend, so the exact sequence
# is proven without changing this process's credentials, without root, without
# sudo, without installing anything, and without touching sudoers. The first
# real transition stays behind gate G6.
#
# ORDER IS THE SECURITY PROPERTY. setgroups before setgid before setuid,
# because each step needs the privilege the next one gives up. Verification
# before no_new_privs, and no_new_privs before exec. A recording backend makes
# that order an assertion rather than a comment.
#
# FAILURE SHORT-CIRCUITS. Any step that fails must prevent every later step,
# and above all must prevent execve -- a partially dropped process that execs
# is the one outcome worse than not running at all.
#
# THE FFI EXCEPTION IS NARROW. ctypes exists here for exactly two prctl calls
# with fixed constants and fixed arguments. The static guard below enforces
# that shape; T10's policy module and the whole execution package remain
# forbidden from importing ctypes at all.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §6
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T11

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The fixture launch record must be owned by the coordinator identity the
# production code pins, so this suite runs only as that identity.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
# THIS SUITE WAS SILENTLY SKIPPING. It used to read a compiled-in
# `COORDINATOR_UID` out of the policy module, and f9d94ce removed that constant
# in favour of the deployment coordinator identity authority. The `sed` then
# matched nothing, `host_only_requires_identity ""` compared "" against the real
# uid, and every run since reported HOST_ONLY_SKIP -- on the production host
# too, where this is the suite that proves the privileged credential sequence.
# A skip that can be produced by a stale extraction is worse than a failure,
# because it reads as "not applicable here" rather than "nobody checked".
#
# So the uid comes from the authority production itself reads, and a host that
# cannot answer skips for a stated reason instead of an empty string.
host_only_requires /etc/kyri/coordinator-identity.json   # prod-path-reference
host_only_requires_identity "$(python3 -c '
import json, sys
with open("/etc/kyri/coordinator-identity.json", encoding="utf-8") as handle:  # prod-path-reference
    print(json.load(handle)["coordinator_uid"])
' 2>/dev/null)"
ACTION="provisioning/execution/kyri-exec-transition-action.py"
POLICY="provisioning/execution/kyri-exec-transition.py"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "${ACTION}"

# ===========================================================================
# The T11 privileged-action backstop
# ===========================================================================
# Narrow by enumeration. Privileged surfaces are permitted one by one; nothing
# is permitted because "this file is allowed to do privileged things".

assert_narrow_privilege() {
  local report
  report="$(python3 - "${ROOT}" "${ACTION}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / sys.argv[2]

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "socket", "http",
    "urllib", "requests", "asyncio", "docker", "podman", "pty", "shlex",
    "time", "datetime", "random", "secrets", "tempfile", "shutil", "glob",
    "logging", "signal", "threading", "concurrent", "ssl", "getpass",
    "pathlib",
}
# `pwd` and `grp` are the account database, and they are DELIBERATELY here in
# the action layer. The policy module is the pure decision layer and the T10
# backstop forbids them to it -- "The account database is a syscall dependency,
# so it lives with the other syscall dependencies in the action layer, and the
# binding still happens inside that parser". `resolve_account` is that
# dependency. This list forbade them until G11-BC-D, and nobody noticed because
# this suite was skipping (see the identity note at the top).
# Exactly the privileged operations the accepted transition needs, and no
# others. Anything absent from this set is forbidden.
#
# Pass 3B-ii added the sealed profile transport, so this set grew by
# enumeration rather than by relaxing the rule: reading the two governed
# objects descriptor-relatively (open/read/fstat with the no-follow flags),
# copying them into an anonymous sealable object (memfd_create/write/lseek),
# proving the copy (pread), and fixing its descriptor number (dup2,
# get_inheritable). Nothing here can create, remove, rename, or change the mode
# of anything -- those calls remain forbidden below.
#
# G11-BC-D WIDENS THIS LIST BY EXACTLY TWO SYMBOLS, AND A REVIEWER SHOULD READ
# WHY BEFORE ACCEPTING IT.
#
#   os.fchown  -- §13 requires `…/<CINV>/out/` to be
#                 `kyri-capability:kyri-capability 0700`, and NOTHING in the
#                 tree produced that state. Publication runs as the coordinator
#                 and cannot create a directory owned by another uid; §34 fixes
#                 the quota step on `out/` BEFORE the credential drop, so the
#                 worker cannot create it either. handoff.py already names the
#                 owner of this job -- "Transferring the writable leaf to the
#                 execution identity is the privileged transition's job" -- so
#                 this is the step that was declared and never written, and
#                 Stage 3 for CINV-000002 refused on exactly its absence.
#
#                 Path-based `chown` stays FORBIDDEN. Only the descriptor form
#                 is permitted, so the object being given away is the one this
#                 layer already opened no-follow and verified, and there is no
#                 pathname for a coordinator to swap underneath it.
#
#   os.chdir    -- the credential drop changes identity and left cwd alone, so
#                 the process ended up with a working directory its new identity
#                 cannot reach. Rootless Podman's re-exec then refused with
#                 "cannot chdir to /opt/schott-platform: Permission denied".
#                 Closing cwd belongs with the other things this boundary closes.
#
# Both remain forbidden to every OTHER module the backstop covers.
PERMITTED_OS = {
    "setgroups", "setgid", "setuid", "getgroups", "getresuid", "getresgid",
    "getuid", "geteuid", "getgid", "getegid", "execve", "closerange",
    "close", "set_inheritable", "get_inheritable", "fstat", "error",
    "open", "read", "write", "pread", "lseek", "dup2", "memfd_create",
    "fchown", "chdir",
    "O_RDONLY", "O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY", "O_NONBLOCK",
    "O_PATH",
    "MFD_CLOEXEC", "MFD_ALLOW_SEALING", "SEEK_SET",
}
FORBIDDEN_CALLS = {
    "system", "popen", "spawnv", "spawnl", "posix_spawn", "posix_spawnp",
    "fork", "forkpty", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "unsetenv", "chroot", "mount", "umount", "unshare",
    "setns", "capset", "chmod", "chown", "mkdir", "makedirs", "remove",
    "unlink", "rename", "rmdir", "symlink", "link", "mkfifo", "mknod",
    "kill", "killpg", "now", "today", "monotonic", "uuid1", "uuid4",
    "which", "seteuid", "setegid", "setreuid", "setregid", "setresuid",
    "setresgid",
}
FORBIDDEN_TEXT = ("podman", "docker", "containerd", "crun", "runc", ".sock",
                  "socket", "subprocess", "/bin/sh", "/bin/bash", "shell",
                  "setpriv", "capsh", "os.system")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

findings = []
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

for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
            and node.value.id == "os" and node.attr not in PERMITTED_OS:
        findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

# --- the ctypes exception, enforced shape by shape ----------------------
cdll = [n for n in ast.walk(tree)
        if isinstance(n, ast.Call) and "CDLL" in ast.unparse(n.func)]
if len(cdll) != 1:
    findings.append(f"{rel}: expected exactly one CDLL construction, found {len(cdll)}")
for call in cdll:
    rendered = ast.unparse(call)
    # Bind the current process, never a caller-selected library path.
    if "None" not in rendered:
        findings.append(f"{rel}: CDLL binds something other than the current process: {rendered}")

# Only prctl may be looked up on the library handle.
symbols = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
            and node.value.id in {"_LIBC", "libc", "_libc"}:
        symbols.add(node.attr)
if symbols - {"prctl"}:
    findings.append(f"{rel}: libc symbols beyond prctl: {sorted(symbols - {'prctl'})}")

# No dynamic symbol resolution and no reusable FFI wrapper.
for banned in ("getattr(", "CFUNCTYPE", "cast(", "memmove", "string_at",
               "create_string_buffer", "byref", "POINTER", "windll", "oledll",
               "PyDLL", "LibraryLoader", "find_library"):
    if banned in code:
        findings.append(f"{rel}: generic FFI surface: {banned}")

# Constants must be literal and exact.
for required in ("PR_SET_NO_NEW_PRIVS = 38", "PR_GET_NO_NEW_PRIVS = 39"):
    if required not in source:
        findings.append(f"{rel}: missing fixed constant: {required}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T11 privilege is narrow: enumerated syscalls, one CDLL, prctl only"
  else
    fail "T11 backstop found: ${report}"
  fi
}

assert_narrow_privilege

# The T10 guard must still hold, unweakened.
assert_policy_backstop_intact() {
  local report
  report="$(python3 - "${ROOT}" "${POLICY}" <<'SCANPY'
import pathlib
import sys
source = (pathlib.Path(sys.argv[1]) / sys.argv[2]).read_text(encoding="utf-8")
findings = []
for banned in ("ctypes", "setuid", "setgid", "setgroups", "execve", "prctl"):
    if banned in source:
        findings.append(f"policy module gained {banned}")
print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "the T10 policy module gained no privileged surface"
  else
    fail "T10 policy backstop weakened: ${report}"
  fi
}

assert_policy_backstop_intact

assert_no_ctypes_in_package() {
  local hits
  # grep exits 1 when it finds nothing, which is the passing case here.
  hits="$( { grep -rl 'ctypes' "${ROOT}/tools/capability/" 2>/dev/null || true; } | wc -l)"
  if [[ "${hits}" -eq 0 ]]; then
    pass "no ctypes anywhere in the execution package"
  else
    fail "ctypes appears in the execution package (${hits} files)"
  fi
}

assert_no_ctypes_in_package

# ===========================================================================
# Behaviour
# ===========================================================================

WORK="$(mktemp -d)"
# The fixtures reproduce the production 0555 invocation directory, which its
# owner cannot delete from until it restores write access.
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

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

# Installed helpers this suite must never touch. Compared before and after
# rather than asserted absent: absence only asked whether G4 had run, and
# stopped being true when it did.
PRODUCTION_PATHS=(
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
)
PRODUCTION_BEFORE="$(mktemp)"
trap 'rm -f "${PRODUCTION_BEFORE}"' EXIT
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

PRELUDE="
import dataclasses, hashlib, importlib.util, json, os, sys, tempfile

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy_mod = load('kyri_exec_transition',
                  'provisioning/execution/kyri-exec-transition.py')
action = load('kyri_exec_transition_action',
              'provisioning/execution/kyri-exec-transition-action.py')

# The execution identity is REQUIRED by policy_for and has no default, so that
# an unpoliced identity is not a path anyone could forget. It is built here the
# way production builds it -- through the policy module's own parser, with the
# account resolver injected -- rather than by constructing the token-guarded
# record directly, which the type deliberately forbids.
#
# The numbers are the deployment's, and the resolver is injected so this asserts
# against the fixture rather than against the host's account database.
# The policy module requires the identity record to be root-owned and
# unwritable by anyone else -- correctly, since it names the identity root
# becomes. A fixture cannot manufacture that without privilege, so the REAL
# provisioned authority is read: it is root-owned, world-readable, and is the
# object production itself reads. Only the account RESOLVER is injected, so the
# suite still does not depend on this host's account database agreeing.
# (No backticks in this block: the prelude is a double-quoted bash string.)
def _identity():
    path = '/etc/kyri/execution-identity.json'   # prod-path-reference
    with open(path, 'rb') as handle:
        document = handle.read()
    record = json.loads(document.decode('utf-8'))
    return policy_mod.load_execution_identity(
        document, os.lstat(path),
        resolve=lambda account: (record['execution_uid'],
                                 record['execution_gid']))

EXECUTION_IDENTITY = _identity()
POLICY = policy_mod.policy_for(['prog', 'CINV-000042'],
                               identity=EXECUTION_IDENTITY)

# The same governed policy with the deployment's identity replaced by this
# process's own. It is still a TransitionPolicy, which is why the policy guard
# accepts it, and it is the only way an unprivileged suite can drive the
# output-leaf transfer all the way through its post-transfer verification: the
# kernel permits giving an object you own to yourself and nothing else. Used
# ONLY where the transfer has to actually take effect; every ordering and
# argument assertion uses the real deployment identity.
SELF_POLICY = dataclasses.replace(POLICY, worker_uid=os.getuid(),
                                  worker_gid=os.getgid())
WORK = os.environ['WORKDIR']

def self_pair(**kwargs):
    '''A recorder whose reported credentials match SELF_POLICY.

    The drop is verified against the policy in every component, so a recorder
    reporting the deployment identity while the policy names this process would
    refuse for a reason that is about the fixture rather than the code.
    '''
    kwargs.setdefault('uid', os.getuid())
    kwargs.setdefault('gid', os.getgid())
    kwargs.setdefault('groups', (os.getgid(),))
    return Recorder(**kwargs)

# Deliberately not a real ExecutionProfile. Root is opaque to what these bytes
# say, so a fixture that handed it a parseable profile would be testing a
# property this layer does not have. Any bytes will do, and that is the point.
PROFILE_BYTES = b'{\"opaque\":\"the privileged layer never parses this\"}'
PROFILE_DIGEST = hashlib.sha256(PROFILE_BYTES).hexdigest()

def scene(cinv='CINV-000042'):
    '''A temporary execution root and handoff root, published for real.

    The transition reads both, so they have to exist. Everything below the two
    root descriptors -- the no-follow opens, the ownership and mode checks, the
    read, the hash, the copy, and the seals -- is production code running
    unprivileged against this tree.
    '''
    base = tempfile.mkdtemp(dir=WORK)
    execution = os.path.join(base, 'execution', cinv)
    invocation = os.path.join(base, 'handoff', cinv)
    os.makedirs(execution)
    os.makedirs(invocation)

    published = os.path.join(invocation, policy_mod.PROFILE_NAME)
    with open(published, 'wb') as handle:
        handle.write(PROFILE_BYTES)
    os.chmod(published, 0o444)

    # The writable output leaf, in the shape publication really leaves it:
    # 0700 and owned by whoever published, which on production is the
    # COORDINATOR. handoff.py declares the mode and explicitly declines to set
    # the owner -- 'Transferring the writable leaf to the execution identity is
    # the privileged transition's job' -- so this fixture is that state, and the
    # transition is what has to move it.
    output = os.path.join(invocation, 'out')
    os.makedirs(output)
    os.chmod(output, 0o700)

    document = {
        'cinv': cinv, 'cimp': 'CIMP-000001', 'profile_digest': PROFILE_DIGEST,
        'handoff_root': policy_mod.HANDOFF_ROOT, 'profile_schema_version': 1,
        'commitment_digest': 'b' * 64, 'lifecycle_state': 'launch_authorized',
    }
    record = os.path.join(execution, policy_mod.LAUNCH_RECORD_NAME)
    with open(record, 'wb') as handle:
        handle.write(json.dumps(document).encode('utf-8'))
    os.chmod(record, 0o600)
    os.chmod(invocation, 0o555)

    # The two deployment authority directories are NOT redirected. Both records
    # must be root-owned and unwritable by anyone else -- the policy module
    # refuses otherwise, correctly, since between them they name the publisher
    # root recognises and the identity root becomes. A fixture cannot
    # manufacture that without privilege, and redirecting them to a
    # fixture-owned copy would test a check that production does not make. They
    # are root-owned, readable, and traversable, so the real ones are used.
    return {policy_mod.EXECUTION_ROOT: os.path.join(base, 'execution'),
            policy_mod.HANDOFF_ROOT: os.path.join(base, 'handoff'),
            '/etc/kyri': '/etc/kyri'}   # prod-path-reference

class Recorder:
    '''A backend that records what it was asked to do and does none of it.

    One exception, and it is not privilege: open_directory hands back a real
    descriptor to a temporary tree. The governed roots are compiled in, so a
    test cannot ask the transition to look elsewhere without this seam, and
    stubbing the read instead would leave the part that matters unexercised.
    '''

    def __init__(self, fail_at=None, uid=999, gid=987, groups=(987,),
                 nnp=1, exec_error=None, roots=None):
        self.calls = []
        self.roots = scene() if roots is None else roots
        self._fail_at = fail_at
        self._uid, self._gid, self._groups = uid, gid, groups
        self._nnp = nnp
        self._exec_error = exec_error
        self.dropped = False

    def _step(self, name, *detail):
        self.calls.append((name,) + detail)
        if self._fail_at == name:
            raise OSError(1, f'{name} refused')

    def open_directory(self, path):
        # The SAME flags production uses. O_PATH is not a detail here: two of
        # the three governed roots are 0711 traverse-only by design, so O_RDONLY
        # asks for a permission the deployment withholds and refuses -- which is
        # the G11-BB defect SystemBackend.open_directory documents. A recorder
        # that opened them more permissively than production would be a fixture
        # that only works because it is weaker than the thing it stands for.
        self.calls.append(('open_directory', path))
        target = self.roots.get(path)
        if target is None:
            raise OSError(2, 'no such governed root', path)
        return os.open(target, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
                       | os.O_DIRECTORY)

    def close_extra_descriptors(self, allowlist):
        self._step('close_extra_descriptors', tuple(allowlist))

    def setgroups(self, groups):
        self._step('setgroups', tuple(groups))

    def setgid(self, gid):
        self._step('setgid', gid)

    def setuid(self, uid):
        self._step('setuid', uid)
        self.dropped = True

    def credentials(self):
        self.calls.append(('credentials',))
        if not self.dropped:
            return action.Credentials(0, 0, 0, 0, 0, 0, (0,))
        return action.Credentials(self._uid, self._uid, self._uid,
                                  self._gid, self._gid, self._gid,
                                  tuple(self._groups))

    def set_no_new_privs(self):
        self._step('set_no_new_privs')

    def get_no_new_privs(self):
        self.calls.append(('get_no_new_privs',))
        if self._fail_at == 'get_no_new_privs':
            raise OSError(1, 'refused')
        return self._nnp

    def fchown(self, handle, uid, gid):
        # Records, and then performs ONLY the one transfer an unprivileged
        # process is allowed to make: giving an object it already owns to
        # itself. Recording alone would leave the production post-transfer
        # verification unexercised, and that verification is the part that
        # turns 'the syscall was issued' into 'the leaf really moved'. A test
        # still cannot give anything to another identity -- the kernel refuses,
        # which is exactly the guarantee wanted here.
        self._step('fchown', uid, gid)
        if (uid, gid) == (os.getuid(), os.getgid()):
            os.fchown(handle, uid, gid)

    def chdir(self, path):
        self._step('chdir', path)

    def execve(self, path, argv, environment):
        self.calls.append(('execve', path, tuple(argv), tuple(environment)))
        if self._exec_error is not None:
            raise self._exec_error
        raise action.WorkerExecuted(path)

class Quota:
    '''The injected quota component. Establishes nothing real.'''

    DERIVE = object()

    def __init__(self, error=None, project=DERIVE):
        self.calls = []
        self._error = error
        self._project = project

    def project_id(self, cinv):
        return 1_000_000 + int(cinv[5:])

    def apply(self, cinv):
        self.calls.append(('apply', cinv))
        if self._error is not None:
            raise self._error
        return (self.project_id(cinv) if self._project is Quota.DERIVE
                else self._project)

def names(recorder):
    return [call[0] for call in recorder.calls]

def steps(recorder):
    '''The recorded privileged steps, without the directory seam.

    open_directory is how this fixture substitutes a temporary tree for a
    compiled-in root. It is not a step in the accepted sequence, so the
    ordering assertions read the sequence without it.
    '''
    return [name for name in names(recorder) if name != 'open_directory']

def authenticated(recorder, policy=POLICY):
    return action.authenticate_launch(policy, backend=recorder)

def run(recorder, policy=POLICY, root=True, quota=None, launch=None):
    try:
        authorisation = (launch if launch is not None
                         else action.authenticate_launch(policy, backend=recorder))
    except policy_mod.TransitionRefused as error:
        return error
    try:
        action.perform_transition(policy, launch_authorisation=authorisation,
                                  backend=recorder,
                                  quota=Quota() if quota is None else quota,
                                  assume_root=root)
    except action.WorkerExecuted:
        return 'executed'
    except policy_mod.TransitionRefused as error:
        return error
"

# --- policy is required --------------------------------------------------------

run_case "a validated TransitionPolicy is required" "${PRELUDE}
recorder = Recorder()
launch = authenticated(recorder)
for bad in ('CINV-000042', None, {'cinv': 'CINV-000042'}, ['CINV-000042'], 42):
    try:
        action.perform_transition(bad, launch_authorisation=launch,
                                  backend=Recorder(), quota=Quota(),
                                  assume_root=True)
    except policy_mod.TransitionRefused:
        continue
    raise AssertionError(f'accepted {bad!r} in place of a policy')
print('OK')
"

run_case "an authenticated launch record is required and cannot be fabricated" "${PRELUDE}
import types as pytypes
# The CIMP and the profile digest the worker is told to trust come from this
# object, so a value that merely looks checked must not be usable as one.
forged = pytypes.SimpleNamespace(
    cinv='CINV-000042', cimp='CIMP-000009', profile_digest='c' * 64,
    handoff_root=policy_mod.HANDOFF_ROOT, profile_schema_version=1,
    commitment_digest='b' * 64, lifecycle_state='launch_authorized')
for bad in (forged, dict(vars(forged)), None, 'CIMP-000009', 42):
    recorder = Recorder()
    try:
        action.perform_transition(POLICY, launch_authorisation=bad,
                                  backend=recorder, quota=Quota(),
                                  assume_root=True)
    except policy_mod.TransitionRefused:
        assert 'execve' not in names(recorder), names(recorder)
        continue
    except action.WorkerExecuted:
        raise AssertionError('a fabricated launch record reached execve')
    raise AssertionError(f'accepted {bad!r} as an authenticated record')
print('OK')
"

run_case "the action layer accepts no independent execution input" "${PRELUDE}
import inspect
params = list(inspect.signature(action.perform_transition).parameters)
# The quota seam joined this set when the output project became a
# mandatory transition step; the authenticated record joined it when the CIMP
# and profile digest had to reach the worker. Both are closed collaborators,
# not execution inputs: one is a component, the other a type only the policy
# layer can build.
assert params == ['policy', 'launch_authorisation', 'backend', 'quota',
                  'assume_root'], params
for banned in ('cinv', 'cimp', 'digest', 'uid', 'gid', 'user', 'command',
               'argv', 'executable', 'environment', 'cwd', 'image', 'path',
               'record', 'descriptor', 'fd'):
    assert banned not in params, banned
signature = inspect.signature(action.perform_transition)
assert signature.parameters['launch_authorisation'].default \\
    is inspect.Parameter.empty, 'the authenticated record can be omitted'
print('OK')
"

run_case "the transition refuses unless it holds root" "${PRELUDE}
recorder = Recorder()
outcome = run(recorder, root=False)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
# The launch record was read before the call, and nothing privileged followed.
assert steps(recorder) == [], steps(recorder)
print('OK')
"

# --- the exact sequence ---------------------------------------------------------

run_case "the accepted credential sequence runs in exactly the accepted order" "${PRELUDE}
recorder = self_pair()
assert run(recorder, policy=SELF_POLICY) == 'executed'
assert steps(recorder) == [
    'fchown', 'close_extra_descriptors', 'chdir',
    'setgroups', 'setgid', 'setuid', 'credentials',
    'set_no_new_privs', 'get_no_new_privs', 'credentials', 'execve'
], steps(recorder)
# G11-BC-D added the first and third entries, and where they sit is the point.
# The transfer gives the output leaf away and needs root, so it precedes every
# credential step. The chdir closes the inherited working directory and sits
# inside the drop, before the identity changes -- a process that becomes the
# execution identity must not be left standing somewhere only the coordinator
# could reach.
# The whole profile transport happens before the first privileged step: the
# governed roots are read while root is still held and while a refusal can
# still prove nothing ran.
assert names(recorder)[:2] == ['open_directory', 'open_directory'], names(recorder)
print('OK')
"

run_case "the fixed identity values are exactly 999, 987 and the group set" "${PRELUDE}
# The REAL deployment policy: these are the deployment's numbers, and
# asserting them against the self-owned fixture would assert nothing.
# The run refuses at the transfer post-check -- an unprivileged process cannot
# actually give the leaf to 999:987 -- but the recorded credential arguments
# are what this case is about and they are recorded before that.
# The numbers are the POLICY's, and the policy is where they are decided --
# asserting them against a self-owned fixture would assert the fixture.
assert (POLICY.worker_uid, POLICY.worker_gid) == (999, 987), POLICY
# And the drop really passes the policy's numbers through, whatever they are.
recorder = self_pair()
run(recorder, policy=SELF_POLICY)
calls = dict((c[0], c[1:]) for c in recorder.calls if len(c) > 1)
assert calls['setgroups'] == ((SELF_POLICY.worker_gid,),), calls['setgroups']
assert calls['setgid'] == (SELF_POLICY.worker_gid,), calls['setgid']
assert calls['setuid'] == (SELF_POLICY.worker_uid,), calls['setuid']
print('OK')
"

run_case "setgroups precedes setgid, which precedes setuid" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
assert order.index('setgroups') < order.index('setgid') < order.index('setuid')
print('OK')
"

run_case "no_new_privs is set after the permanent drop, not before" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
assert order.index('setuid') < order.index('set_no_new_privs'), order
assert order.index('set_no_new_privs') < order.index('get_no_new_privs')
assert order.index('get_no_new_privs') < order.index('execve')
# A credential verification sits between the drop and the FFI call.
assert order.index('credentials') < order.index('set_no_new_privs')
print('OK')
"

run_case "descriptors are closed before any credential change" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
# The transfer precedes it -- root is required to give the leaf away, and the
# descriptor cleanup is the last step that could disturb what follows.
assert order[0] == 'fchown', order
assert order[1] == 'close_extra_descriptors', order
assert order.index('close_extra_descriptors') < order.index('setgroups')
calls = dict((c[0], c[1:]) for c in recorder.calls if len(c) > 1)
# vNext: the sealed profile object crosses on descriptor 3, so the inherited
# set is one wider -- by a number the transition owns, not one a caller named.
assert calls['close_extra_descriptors'] == ((0, 1, 2, 3),), calls['close_extra_descriptors']
print('OK')
"

# --- failure short-circuits -------------------------------------------------------

run_case "a failure at any step prevents every later step and the exec" "${PRELUDE}
sequence = ['close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
            'set_no_new_privs', 'get_no_new_privs']
for step in sequence:
    recorder = Recorder(fail_at=step)
    outcome = run(recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), (step, outcome)
    order = steps(recorder)
    assert 'execve' not in order, (step, order)
    later = sequence[sequence.index(step) + 1:]
    for name in later:
        assert name not in order, (step, name, order)
print('OK')
"

run_case "a credential verification that still shows privilege prevents the exec" "${PRELUDE}
for kwargs in ({'uid': 0}, {'gid': 0}, {'groups': (0, 987)}, {'groups': ()},
               {'uid': 1000}, {'gid': 1000}):
    recorder = Recorder(**kwargs)
    outcome = run(recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), (kwargs, outcome)
    assert 'execve' not in names(recorder), (kwargs, names(recorder))
print('OK')
"

run_case "no_new_privs that does not read back as 1 prevents the exec" "${PRELUDE}
for value in (0, 2, -1, None):
    recorder = Recorder(nnp=value)
    outcome = run(recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), (value, outcome)
    assert 'execve' not in names(recorder), value
print('OK')
"

# --- exec ---------------------------------------------------------------------------

run_case "execve receives the fixed interpreter, script, argv and closed environment" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
call = [c for c in recorder.calls if c[0] == 'execve'][0]
_, path, argv, environment = call
assert path == '/usr/bin/python3', path
# vNext: five elements. The CIMP and the profile digest come from the record
# root authenticated, because the worker cannot check the profile against
# itself and must not read the coordinator-owned launch record.
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-worker.py',
                'CINV-000042', 'CIMP-000001', PROFILE_DIGEST), argv
assert len(argv) == 5, argv
# Exactly the two rootless Podman needs; nothing inherited.
assert dict(environment) == {'HOME': '/data/kyri/capability',
                             'XDG_RUNTIME_DIR': '/run/user/999'}, environment
print('OK')
"

run_case "there is no PATH search, shell, -m, or alternate interpreter" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
_, path, argv, environment = [c for c in recorder.calls if c[0] == 'execve'][0]
assert path.startswith('/')
assert '-m' not in argv and '-c' not in argv
assert not any('sh' == a.rsplit('/', 1)[-1] for a in argv)
assert not any(a.startswith('tools/') or 'schott-platform' in a for a in argv)
assert dict(environment).get('PATH') is None
print('OK')
"

run_case "execve happens exactly once and is never retried" "${PRELUDE}
recorder = self_pair(exec_error=OSError(2, 'No such file or directory'))
outcome = run(recorder, policy=SELF_POLICY)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert names(recorder).count('execve') == 1, names(recorder)
import ast, pathlib
tree = ast.parse(pathlib.Path(
    'provisioning/execution/kyri-exec-transition-action.py').read_text())
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if isinstance(body, list) and body and isinstance(
            node, (ast.Module, ast.ClassDef, ast.FunctionDef)):
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
ast.fix_missing_locations(tree)
code = ast.unparse(tree)
# No loop and no recursion around the exec, or around any credential change:
# one attempt, structurally. The blanket ban on loops was retired with Pass
# 3B-ii -- copying bytes needs a bounded write loop, and forbidding the keyword
# would have forbidden a correct short-write check rather than a retry. What
# actually mattered is asserted directly instead.
for node in ast.walk(tree):
    if isinstance(node, (ast.For, ast.While)):
        inner = ast.unparse(node)
        for banned in ('execve', 'setuid', 'setgid', 'setgroups',
                       'set_no_new_privs', 'F_ADD_SEALS', 'memfd_create',
                       'dup2'):
            assert banned not in inner, f'{banned} sits inside a loop'
# Exactly one exec call site in the transition path itself.
fn = [n for n in ast.walk(tree)
      if isinstance(n, ast.FunctionDef) and n.name == 'perform_transition'][0]
sites = [n for n in ast.walk(fn)
         if isinstance(n, ast.Call) and ast.unparse(n.func).endswith('.execve')]
assert len(sites) == 1, f'{len(sites)} exec call sites in the transition path'
print('OK')
"

run_case "a conclusively failed execve still excludes execution" "${PRELUDE}
recorder = self_pair(exec_error=OSError(2, 'No such file or directory'))
outcome = run(recorder, policy=SELF_POLICY)
assert outcome.execution_excluded is True
from tools.capability.execution.types import Classification
assert outcome.classification is Classification.TRANSITION_FAILED_BEFORE_EXECUTION
print('OK')
"

run_case "an ambiguous outcome does not receive the before-execution classification" "${PRELUDE}
error = action.ambiguous('the exec outcome cannot be excluded')
assert isinstance(error, policy_mod.TransitionRefused)
assert error.execution_excluded is False
assert error.classification is None
assert not hasattr(action, 'TransitionAmbiguous'), 'a second refusal type exists'
print('OK')
"

# --- structural absences -------------------------------------------------------------

run_case "the privileged layer never mentions Podman or a container runtime" "${PRELUDE}
import ast, pathlib
# CODE, not commentary. Read raw, this case failed on the module's own sentence
# 'Podman is not reachable from here' -- prose stating the property being
# tested. Docstrings are stripped the same way the T11 backstop strips them, so
# what is asserted is that the layer has no runtime COUPLING.
tree = ast.parse(pathlib.Path(
    'provisioning/execution/kyri-exec-transition-action.py').read_text())
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
code = ast.unparse(tree).lower()
for banned in ('podman', 'docker', 'containerd', 'crun', 'runc', '.sock',
               'socket', 'subprocess', 'setpriv'):
    assert banned not in code, banned
print('OK')
"

run_case "the ctypes surface is exactly two prctl calls with fixed arguments" "${PRELUDE}
import ast, pathlib
source = pathlib.Path('provisioning/execution/kyri-exec-transition-action.py').read_text()
tree = ast.parse(source)
prctl_calls = [n for n in ast.walk(tree)
               if isinstance(n, ast.Call) and 'prctl' in ast.unparse(n.func)]
rendered = sorted(ast.unparse(c) for c in prctl_calls)
assert len(prctl_calls) == 2, rendered
setter = [r for r in rendered if 'SET' in r or '38' in r]
getter = [r for r in rendered if 'GET' in r or '39' in r]
assert len(setter) == 1 and len(getter) == 1, rendered
assert setter[0].endswith('(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)'), setter
assert getter[0].endswith('(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0)'), getter
assert 'PR_SET_NO_NEW_PRIVS = 38' in source
assert 'PR_GET_NO_NEW_PRIVS = 39' in source
print('OK')
"

run_case "the production backend exists but is never exercised by these tests" "${PRELUDE}
assert hasattr(action, 'SystemBackend')
import inspect
assert inspect.isclass(action.SystemBackend)
# The default is explicit rather than implicit: a caller must pass a backend.
import inspect as i
assert i.signature(action.perform_transition).parameters['backend'].default is i.Parameter.empty
print('OK')
"

run_case "these tests run unprivileged and this process keeps its credentials" "${PRELUDE}
before = (os.getuid(), os.geteuid(), os.getgid(), os.getegid(), tuple(os.getgroups()))
assert os.getuid() != 0, 'must not run as root'
recorder = Recorder(); run(recorder)
after = (os.getuid(), os.geteuid(), os.getgid(), os.getegid(), tuple(os.getgroups()))
assert before == after, 'the test changed process credentials'
import json
with open('${PRODUCTION_BEFORE}', encoding='utf-8') as handle:
    baseline = json.load(handle)
assert baseline, 'the production baseline is empty'
for production, recorded in sorted(baseline.items()):
    try:
        info = os.lstat(production)
        current = [info.st_mode, info.st_uid, info.st_gid, info.st_size,
                   info.st_mtime_ns, info.st_ctime_ns]
    except FileNotFoundError:
        current = None
    assert current == recorded, production + ' changed while this suite ran'
print('OK')
"

# --- the output quota is established before any privilege is spent ----------

run_case "the quota is established before the credential drop" "${PRELUDE}
recorder = self_pair()
quota = Quota()
assert run(recorder, policy=SELF_POLICY, quota=quota) == 'executed'
assert quota.calls == [('apply', SELF_POLICY.cinv)], quota.calls
# Before the descriptor cleanup, and therefore before every credential step.
assert steps(recorder).index('close_extra_descriptors') < steps(
    recorder).index('setgroups'), steps(recorder)
print('OK')
"

run_case "no worker exec is reachable when the quota is not established" "${PRELUDE}
for error in (OSError(1, 'operation not permitted'),
              OSError(2, 'no such file or directory'),
              RuntimeError('the project read back as 0, expected 1000042'),
              ValueError('the directory already carries project 7')):
    recorder = Recorder()
    outcome = run(recorder, quota=Quota(error=error))
    assert isinstance(outcome, policy_mod.TransitionRefused), outcome
    assert 'execve' not in steps(recorder), steps(recorder)
    assert 'setuid' not in steps(recorder), steps(recorder)
    assert 'setgroups' not in steps(recorder), steps(recorder)
print('OK')
"

run_case "a quota failure excludes execution and classifies as such" "${PRELUDE}
outcome = run(Recorder(), quota=Quota(error=OSError(1, 'refused')))
assert outcome.execution_excluded is True, outcome.execution_excluded
assert outcome.classification is not None
assert outcome.classification.value == 'transition_failed_before_execution', \\
    outcome.classification
print('OK')
"

run_case "a project that disagrees with the CINV prevents the drop" "${PRELUDE}
recorder = Recorder()
# The component reported success but returned somebody else's project.
outcome = run(recorder, quota=Quota(project=1_000_999))
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'setuid' not in steps(recorder), steps(recorder)
assert outcome.execution_excluded is True
for bad in (None, 0, '1000042', -1):
    recorder = Recorder()
    outcome = run(recorder, quota=Quota(project=bad))
    assert isinstance(outcome, policy_mod.TransitionRefused), (bad, outcome)
    assert 'execve' not in names(recorder), bad
print('OK')
"

run_case "there is no unquotaed path through the transition at all" "${PRELUDE}
import inspect
params = list(inspect.signature(action.perform_transition).parameters)
assert 'quota' in params, params
signature = inspect.signature(action.perform_transition)
assert signature.parameters['quota'].default is inspect.Parameter.empty, \\
    'the quota step has a default and can be skipped'
# Omitting it is an error rather than a quiet no-quota execution.
recorder = Recorder()
try:
    action.perform_transition(POLICY, launch_authorisation=authenticated(recorder),
                              backend=recorder, assume_root=True)
except TypeError:
    pass
else:
    raise AssertionError('the transition ran without a quota component')
print('OK')
"

run_case "the quota component receives only the validated CINV" "${PRELUDE}
import inspect
recorder = Recorder()
quota = Quota()
run(recorder, quota=quota)
assert quota.calls == [('apply', 'CINV-000042')], quota.calls
# One call, one CINV, and nothing else crosses: no path, no ID, no limit.
source = inspect.getsource(action.perform_transition)
for token in ('bhard', 'ihard', 'projid', 'ioctl', 'FS_IOC', 'xfs_quota',
              '/data/'):
    assert token not in source, token
print('OK')
"

# --- G11-BC-D: the writable output leaf is handed to the execution identity ----
#
# THE DEFECT THIS PINS. Stage 3 for CINV-000002 refused with
#
#   WorkerRefused: the handoff 'out' is unusable: [Errno 13] Permission denied
#
# because `out` was 0700 and owned by the COORDINATOR, while the worker runs as
# the execution identity. Three modules independently state that it should be
# worker-owned -- handoff.py ('Transferring the writable leaf to the execution
# identity is the privileged transition's job'), worker.py ('the worker-owned
# 0700 output directory'), snapshot.py ('the writable output leaf is already
# worker-owned') -- and no code anywhere performed the transfer. The mode was
# never wrong; the owner was never set.

run_case "the output leaf is transferred to the execution identity" "${PRELUDE}
# Deployment policy: the leaf must be handed to 999:987, which is the whole
# point. An unprivileged fixture cannot make that transfer take effect, so the
# run then refuses -- and the refusal is itself the post-transfer verification
# doing its job. Both facts are asserted.
recorder = Recorder()
outcome = run(recorder)
calls = [c for c in recorder.calls if c[0] == 'fchown']
assert calls == [('fchown', 999, 987)], calls
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'did not take effect' in str(outcome), str(outcome)

# And with a policy naming an identity the fixture CAN transfer to, the same
# code path completes -- so the refusal above is the verification working, not
# the transfer being unimplemented.
ok = self_pair()
assert run(ok, policy=SELF_POLICY) == 'executed'
assert [c for c in ok.calls if c[0] == 'fchown'] == [
    ('fchown', os.getuid(), os.getgid())]
print('OK')
"

run_case "the transfer happens while privilege is still held" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
assert 'fchown' in order, order
# Root is needed to give a directory away, so it must precede every credential
# step. After setuid the process could not do it at all.
assert order.index('fchown') < order.index('setgroups'), order
assert order.index('fchown') < order.index('setgid'), order
assert order.index('fchown') < order.index('setuid'), order
print('OK')
"

run_case "a refused transfer prevents the drop and the exec" "${PRELUDE}
recorder = Recorder(fail_at='fchown')
outcome = run(recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
order = steps(recorder)
assert 'execve' not in order, order
for later in ('setgroups', 'setgid', 'setuid'):
    assert later not in order, (later, order)
print('OK')
"

run_case "the transfer names no path and takes no identity from a caller" "${PRELUDE}
import inspect
source = inspect.getsource(action)
# The uid/gid come from the authenticated policy, never from an argument.
assert 'def transfer_output_leaf' in source, 'the transfer is not implemented'
body = source.split('def transfer_output_leaf', 1)[1].split(chr(10) + 'def ', 1)[0]
for banned in ('/data/', 'argv', 'environ', 'input('):
    assert banned not in body, (banned, 'is reachable in the transfer')
assert 'policy.worker_uid' in body and 'policy.worker_gid' in body, body
print('OK')
"

# --- G11-BC-D: cwd is closed at the credential boundary -------------------------
#
# THE SECOND DEFECT. Reconciliation refused with
#
#   the runtime refused: cannot chdir to /opt/schott-platform: Permission denied
#
# The coordinator's cwd is inherited all the way across the privilege boundary.
# /opt/schott-platform is 0750 cschott, so once the process becomes the
# execution identity its own cwd is unreachable, and rootless Podman's re-exec
# cannot restore it. cwd was the one inherited property this boundary never
# closed: the launcher states env, descriptors, argv and shell, and the Podman
# backend documents that 'every property of it is stated here' -- and neither
# stated cwd.

run_case "the credential drop closes cwd as well as credentials" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
assert 'chdir' in order, order
calls = [c for c in recorder.calls if c[0] == 'chdir']
assert calls == [('chdir', SELF_POLICY.working_directory)], calls
assert calls == [('chdir', '/')], calls
print('OK')
"

run_case "cwd is closed before the identity changes, so no step runs unreachable" "${PRELUDE}
recorder = self_pair(); run(recorder, policy=SELF_POLICY)
order = steps(recorder)
assert order.index('chdir') < order.index('setuid'), order
print('OK')
"

run_case "a refused chdir prevents the drop and the exec" "${PRELUDE}
recorder = Recorder(fail_at='chdir')
outcome = run(recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
order = steps(recorder)
assert 'execve' not in order, order
assert 'setuid' not in order, order
print('OK')
"

run_case "the safe cwd is a compiled-in invariant, not a caller's value" "${PRELUDE}
import inspect
source = inspect.getsource(action)
# The DECISION lives in the policy module and the action layer performs it.
assert policy_mod.WORKING_DIRECTORY == '/', policy_mod.WORKING_DIRECTORY
assert POLICY.working_directory == '/', POLICY.working_directory
assert 'policy.working_directory' in source, 'the drop does not consume the policy value'
assert 'SAFE_WORKING_DIRECTORY' not in source, \
    'the action layer carries a second copy of the decision'
# Nothing may aim it: no argument, no environment variable, no policy field a
# coordinator could populate.
body = inspect.getsource(action.drop_privilege)
assert 'environ' not in body and 'argv' not in body, body
print('OK')
"

run_case "reconciliation drops through the same sequence, so it closes cwd too" "${PRELUDE}
import inspect
# drop_privilege is shared by both transitions on purpose, so the cwd closure
# is not something the reconciliation path can be missing.
assert 'drop_privilege(policy, backend=backend)' in inspect.getsource(
    action.perform_reconciliation)
print('OK')
"

# --- G11-BC-E: the two widened privileges are NARROW, proven by refusal --------
#
# G11-BC-D permitted os.fchown and os.chdir to this layer. A test that only shows
# they WORK would be worthless -- the question a reviewer needs answered is what
# they still cannot do. Each case below is a capability that must remain out of
# reach, not a feature that must function.

run_case "fchown: only the descriptor form exists, never a pathname" "${PRELUDE}
import ast, inspect, pathlib
source = pathlib.Path('provisioning/execution/kyri-exec-transition-action.py').read_text()
tree = ast.parse(source)
seen = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \\
            and node.value.id == 'os':
        seen.add(node.attr)
assert 'fchown' in seen, 'the descriptor form is absent'
for banned in ('chown', 'lchown', 'chmod', 'fchmod', 'fchownat', 'chmodat'):
    assert banned not in seen, ('os.' + banned + ' is reachable')
# And exactly one call site, so the capability cannot spread quietly.
calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
         and ast.unparse(n.func) == 'os.fchown']
assert len(calls) == 1, ('fchown call sites', len(calls))
print('OK')
"

run_case "fchown: the transfer refuses before it has verified the object" "${PRELUDE}
import inspect
body = inspect.getsource(action.transfer_output_leaf)
fchown_at = body.index('backend.fchown')
# Type and mode are established BEFORE the transfer, not after it. A transfer
# that ran first would already have given away whatever was there.
assert body.index('S_ISDIR') < fchown_at, 'type is checked after the transfer'
assert body.index('S_IMODE') < fchown_at, 'mode is checked after the transfer'
# And both are re-established after, so a transfer that changed either refuses.
assert body.index('did not take effect') > fchown_at
assert body.index('changed mode during transfer') > fchown_at
print('OK')
"

run_case "fchown: a symlinked or non-directory leaf is refused, not followed" "${PRELUDE}
import os, tempfile
# The leaf is opened with the no-follow directory flags, so a replaced component
# cannot be followed to somewhere else.
assert action._DIR_FLAGS & os.O_NOFOLLOW, 'the leaf open follows symlinks'
assert action._DIR_FLAGS & os.O_DIRECTORY, 'the leaf open accepts a non-directory'

# Driven, not just asserted: a scene whose out/ is a symlink to a directory the
# transfer must not touch.
base = tempfile.mkdtemp(dir=WORK)
for part in ('execution/CINV-000042', 'handoff/CINV-000042', 'elsewhere'):
    os.makedirs(os.path.join(base, part))
published = os.path.join(base, 'handoff/CINV-000042', policy_mod.PROFILE_NAME)
open(published, 'wb').write(PROFILE_BYTES); os.chmod(published, 0o444)
os.symlink(os.path.join(base, 'elsewhere'),
           os.path.join(base, 'handoff/CINV-000042', 'out'))
os.chmod(os.path.join(base, 'handoff/CINV-000042'), 0o555)
roots = {policy_mod.EXECUTION_ROOT: os.path.join(base, 'execution'),
         policy_mod.HANDOFF_ROOT: os.path.join(base, 'handoff'),
         '/etc/kyri': '/etc/kyri'}
recorder = self_pair(roots=roots)
try:
    action.transfer_output_leaf(SELF_POLICY, backend=recorder)
except policy_mod.TransitionRefused as error:
    assert 'unusable' in str(error), str(error)
else:
    raise AssertionError('a symlinked output leaf was transferred')
assert not [c for c in recorder.calls if c[0] == 'fchown'], recorder.calls
print('OK')
"

run_case "fchown: a leaf at the wrong mode is refused rather than corrected" "${PRELUDE}
import os, tempfile
base = tempfile.mkdtemp(dir=WORK)
for part in ('execution/CINV-000042', 'handoff/CINV-000042/out'):
    os.makedirs(os.path.join(base, part))
published = os.path.join(base, 'handoff/CINV-000042', policy_mod.PROFILE_NAME)
open(published, 'wb').write(PROFILE_BYTES); os.chmod(published, 0o444)
# 0755, not the governed 0700. The transfer must refuse -- it is not a repair.
os.chmod(os.path.join(base, 'handoff/CINV-000042/out'), 0o755)
os.chmod(os.path.join(base, 'handoff/CINV-000042'), 0o555)
roots = {policy_mod.EXECUTION_ROOT: os.path.join(base, 'execution'),
         policy_mod.HANDOFF_ROOT: os.path.join(base, 'handoff'),
         '/etc/kyri': '/etc/kyri'}
recorder = self_pair(roots=roots)
try:
    action.transfer_output_leaf(SELF_POLICY, backend=recorder)
except policy_mod.TransitionRefused as error:
    assert '13 fixes' in str(error) or '0o700' in str(error), str(error)
else:
    raise AssertionError('a wrongly-moded output leaf was transferred')
assert not [c for c in recorder.calls if c[0] == 'fchown'], recorder.calls
print('OK')
"

run_case "fchown: the identity comes from the policy, and nowhere else" "${PRELUDE}
import inspect
body = inspect.getsource(action.transfer_output_leaf)
assert 'policy.worker_uid' in body and 'policy.worker_gid' in body
# No other source of an identity may appear in the transfer.
for banned in ('getuid', 'geteuid', 'getgid', 'getenv', 'environ', 'argv',
               'pwd.', 'grp.', 'input('):
    assert banned not in body, (banned, 'is reachable in the transfer')
# The leaf name is compiled in; there is no parameter naming a target.
assert action.OUTPUT_DIRECTORY_NAME == 'out', action.OUTPUT_DIRECTORY_NAME
signature = inspect.signature(action.transfer_output_leaf)
assert list(signature.parameters) == ['policy', 'backend'], signature
print('OK')
"

run_case "chdir: exactly one call site, to the compiled-in safe directory" "${PRELUDE}
import ast, pathlib
tree = ast.parse(pathlib.Path(
    'provisioning/execution/kyri-exec-transition-action.py').read_text())
calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
         and ast.unparse(n.func) in ('os.chdir', 'backend.chdir')]
assert len(calls) == 2, ('chdir call sites', [ast.unparse(c) for c in calls])
# One in the SystemBackend primitive, one in drop_privilege. Both take the
# constant -- neither takes an expression a caller could influence.
for call in calls:
    argument = ast.unparse(call.args[0])
    assert argument in ('path', 'policy.working_directory'), argument
assert policy_mod.WORKING_DIRECTORY == '/', policy_mod.WORKING_DIRECTORY
print('OK')
"

run_case "chdir: no caller-, environment- or payload-derived directory exists" "${PRELUDE}
import ast, inspect, textwrap
# CODE, not commentary. The docstring records which deployment path the incident
# happened on, and a guard that read it would be testing prose -- the same
# mistake the Podman coupling check made before G11-BC-D. Strip it, then assert
# that nothing in the executable body DERIVES a directory.
tree = ast.parse(textwrap.dedent(inspect.getsource(action.drop_privilege)))
fn = tree.body[0]
if isinstance(fn.body[0], ast.Expr) and isinstance(fn.body[0].value, ast.Constant):
    fn.body.pop(0)
body = ast.unparse(tree)
for banned in ('environ', 'getenv', 'argv', 'getcwd', 'expanduser', 'REPOSITORY',
               'schott-platform', 'tmp'):
    assert banned not in body, (banned, 'reachable in the drop')
# The policy MAY carry it -- that is exactly where the decision belongs, and
# the drop consuming it is the fix. What must not exist is any OTHER source:
# an argument, the environment, the current directory, or a repository path.
assert POLICY.working_directory == '/', POLICY.working_directory
assert 'policy.working_directory' in body, 'the drop does not consume the policy value'
print('OK')
"

run_case "chdir: the safe directory is traversable by every identity" "${PRELUDE}
import os, stat
info = os.stat(POLICY.working_directory)
mode = stat.S_IMODE(info.st_mode)
# Others need execute to stand there. This is the whole requirement, and it is
# why '/' was chosen rather than a directory some identity happens to own.
assert mode & 0o001, oct(mode)
assert info.st_uid == 0, info.st_uid
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T11 transition-action validation passed.\n'
else
  printf 'Capability execution T11 transition-action validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
