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
    "logging", "signal", "threading", "concurrent", "ssl", "getpass", "pwd",
    "grp", "pathlib",
}
# Exactly the privileged operations the accepted transition needs, and no
# others. Anything absent from this set is forbidden.
PERMITTED_OS = {
    "setgroups", "setgid", "setuid", "getgroups", "getresuid", "getresgid",
    "getuid", "geteuid", "getgid", "getegid", "execve", "closerange",
    "close", "set_inheritable", "get_inheritable", "fstat", "error",
}
FORBIDDEN_CALLS = {
    "system", "popen", "spawnv", "spawnl", "posix_spawn", "posix_spawnp",
    "fork", "forkpty", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "unsetenv", "chroot", "chdir", "mount", "umount", "unshare",
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
import dataclasses, importlib.util, os, sys

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

POLICY = policy_mod.policy_for(['prog', 'CINV-000042'])

class Recorder:
    '''A backend that records what it was asked to do and does none of it.'''

    def __init__(self, fail_at=None, uid=999, gid=987, groups=(987,),
                 nnp=1, exec_error=None):
        self.calls = []
        self._fail_at = fail_at
        self._uid, self._gid, self._groups = uid, gid, groups
        self._nnp = nnp
        self._exec_error = exec_error
        self.dropped = False

    def _step(self, name, *detail):
        self.calls.append((name,) + detail)
        if self._fail_at == name:
            raise OSError(1, f'{name} refused')

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

    def execve(self, path, argv, environment):
        self.calls.append(('execve', path, tuple(argv), tuple(environment)))
        if self._exec_error is not None:
            raise self._exec_error
        raise action.WorkerExecuted(path)

def names(recorder):
    return [call[0] for call in recorder.calls]

def run(recorder, policy=POLICY, root=True):
    try:
        action.perform_transition(policy, backend=recorder, assume_root=root)
    except action.WorkerExecuted:
        return 'executed'
    except policy_mod.TransitionRefused as error:
        return error
"

# --- policy is required --------------------------------------------------------

run_case "a validated TransitionPolicy is required" "${PRELUDE}
for bad in ('CINV-000042', None, {'cinv': 'CINV-000042'}, ['CINV-000042'], 42):
    try:
        action.perform_transition(bad, backend=Recorder(), assume_root=True)
    except policy_mod.TransitionRefused:
        continue
    raise AssertionError(f'accepted {bad!r} in place of a policy')
print('OK')
"

run_case "the action layer accepts no independent execution input" "${PRELUDE}
import inspect
params = list(inspect.signature(action.perform_transition).parameters)
assert params == ['policy', 'backend', 'assume_root'], params
for banned in ('cinv', 'uid', 'gid', 'user', 'command', 'argv', 'executable',
               'environment', 'cwd', 'image', 'path'):
    assert banned not in params, banned
print('OK')
"

run_case "the transition refuses unless it holds root" "${PRELUDE}
recorder = Recorder()
outcome = run(recorder, root=False)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert names(recorder) == [], names(recorder)
print('OK')
"

# --- the exact sequence ---------------------------------------------------------

run_case "the accepted credential sequence runs in exactly the accepted order" "${PRELUDE}
recorder = Recorder()
assert run(recorder) == 'executed'
assert names(recorder) == [
    'close_extra_descriptors', 'setgroups', 'setgid', 'setuid', 'credentials',
    'set_no_new_privs', 'get_no_new_privs', 'credentials', 'execve'
], names(recorder)
print('OK')
"

run_case "the fixed identity values are exactly 999, 987 and the group set" "${PRELUDE}
recorder = Recorder()
run(recorder)
calls = dict((c[0], c[1:]) for c in recorder.calls if len(c) > 1)
assert calls['setgroups'] == ((987,),), calls['setgroups']
assert calls['setgid'] == (987,), calls['setgid']
assert calls['setuid'] == (999,), calls['setuid']
print('OK')
"

run_case "setgroups precedes setgid, which precedes setuid" "${PRELUDE}
recorder = Recorder(); run(recorder)
order = names(recorder)
assert order.index('setgroups') < order.index('setgid') < order.index('setuid')
print('OK')
"

run_case "no_new_privs is set after the permanent drop, not before" "${PRELUDE}
recorder = Recorder(); run(recorder)
order = names(recorder)
assert order.index('setuid') < order.index('set_no_new_privs'), order
assert order.index('set_no_new_privs') < order.index('get_no_new_privs')
assert order.index('get_no_new_privs') < order.index('execve')
# A credential verification sits between the drop and the FFI call.
assert order.index('credentials') < order.index('set_no_new_privs')
print('OK')
"

run_case "descriptors are closed before any credential change" "${PRELUDE}
recorder = Recorder(); run(recorder)
order = names(recorder)
assert order[0] == 'close_extra_descriptors', order
assert order.index('close_extra_descriptors') < order.index('setgroups')
calls = dict((c[0], c[1:]) for c in recorder.calls if len(c) > 1)
assert calls['close_extra_descriptors'] == ((0, 1, 2),), calls['close_extra_descriptors']
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
    order = names(recorder)
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
recorder = Recorder(); run(recorder)
call = [c for c in recorder.calls if c[0] == 'execve'][0]
_, path, argv, environment = call
assert path == '/usr/bin/python3', path
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-worker.py',
                'CINV-000042'), argv
assert environment == (), environment
print('OK')
"

run_case "there is no PATH search, shell, -m, or alternate interpreter" "${PRELUDE}
recorder = Recorder(); run(recorder)
_, path, argv, environment = [c for c in recorder.calls if c[0] == 'execve'][0]
assert path.startswith('/')
assert '-m' not in argv and '-c' not in argv
assert not any('sh' == a.rsplit('/', 1)[-1] for a in argv)
assert not any(a.startswith('tools/') or 'schott-platform' in a for a in argv)
assert dict(environment).get('PATH') is None
print('OK')
"

run_case "execve happens exactly once and is never retried" "${PRELUDE}
recorder = Recorder(exec_error=OSError(2, 'No such file or directory'))
outcome = run(recorder)
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
# No loop and no recursion around the exec: one attempt, structurally.
assert 'while ' not in code, 'the action layer contains a loop'
for node in ast.walk(tree):
    if isinstance(node, (ast.For, ast.While)):
        inner = ast.unparse(node)
        assert 'execve' not in inner, 'execve sits inside a loop'
# Exactly one exec call site in the transition path itself.
fn = [n for n in ast.walk(tree)
      if isinstance(n, ast.FunctionDef) and n.name == 'perform_transition'][0]
sites = [n for n in ast.walk(fn)
         if isinstance(n, ast.Call) and ast.unparse(n.func).endswith('.execve')]
assert len(sites) == 1, f'{len(sites)} exec call sites in the transition path'
print('OK')
"

run_case "a conclusively failed execve still excludes execution" "${PRELUDE}
recorder = Recorder(exec_error=OSError(2, 'No such file or directory'))
outcome = run(recorder)
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
import pathlib
code = pathlib.Path('provisioning/execution/kyri-exec-transition-action.py').read_text().lower()
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
for production in ('/usr/libexec/kyri-exec-transition',
                   '/usr/libexec/kyri-exec-worker.py'):
    assert not os.path.exists(production), production
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T11 transition-action validation passed.\n'
else
  printf 'Capability execution T11 transition-action validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
