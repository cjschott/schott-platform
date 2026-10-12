#!/usr/bin/env bash
set -Eeuo pipefail

# The released worker entrypoint, and the backend it now binds.
#
# STATIC AND UNPRIVILEGED. No Podman runs, no container is created, no
# privileged path is written, and nothing is installed. The behaviour that
# needs a real runtime is proven by provisioning/execution/g11-ak-backend-e2e.sh
# against the exported governed image.
#
# WHAT THIS IS GUARDING
# =====================
# G11-AK built a governed backend and proved it at the adapter seam, but
# nothing reached it from the released entrypoint: the worker still stopped at
# "no governed runtime backend is bound". Binding it is the change that closes
# the invoke path, and it is also the change most able to go quietly wrong,
# because the entrypoint is the one place where privilege ordering, library
# resolution and Podman authority meet.
#
# So three properties are pinned, and they fail differently:
#
#   1. The backend is reached from the released entrypoint, and the Generation
#      closure can see it without anything being whitelisted.
#   2. Podman is never reached before the identity gate. The transition has
#      already dropped privilege permanently by the time this process exists,
#      and `main` checks the identity before it reaches any execution step --
#      asserted structurally, because an ordering that is only true by reading
#      is one refactor away from not being true.
#   3. The container's bind sources are the worker's snapshot, never the
#      coordinator-owned handoff.

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
import ast, sys
from pathlib import Path
sys.path.insert(0, '.')

WORKER = Path('provisioning/execution/kyri-exec-worker.py')
BACKEND = Path('provisioning/execution/kyri-exec-podman.py')

def tree(path):
    return ast.parse(path.read_text(encoding='utf-8'))

def stripped(path):
    '''The source as CODE, with every docstring removed.

    These files explain in prose exactly what they refuse to do -- the exec
    tuple, an inherited PYTHONPATH, which module may start a process -- so a
    scan over the raw text reads each explanation as the thing it forbids.
    '''
    parsed = tree(path)
    for node in ast.walk(parsed):
        body = getattr(node, 'body', None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return ast.unparse(parsed)

def body_of(path, name):
    '''One function's code, docstring removed.'''
    node = function(path, name)
    if (node.body and isinstance(node.body[0], ast.Expr)
            and isinstance(node.body[0].value, ast.Constant)):
        node = ast.Module(body=node.body[1:], type_ignores=[])
    return ast.unparse(node)

def function(path, name):
    for node in ast.walk(tree(path)):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f'{path}: no function {name}')

def calls_in(node):
    '''Every call name in source order -- the order is the property.'''
    found = []
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            name = getattr(child.func, 'attr', None) or getattr(child.func, 'id', None)
            if name:
                found.append((getattr(child, 'lineno', 0), name))
    return [name for _, name in sorted(found)]
"

# --- the binding exists ----------------------------------------------------------

run_case "the entrypoint no longer stops at an unbound backend" "${PRELUDE}
source = WORKER.read_text(encoding='utf-8')
# The governed refusal G11-AK left in place. Its removal is the whole change,
# so its absence is asserted rather than assumed.
assert 'no governed runtime backend is bound' not in source, \\
    'the entrypoint still refuses to execute'
assert 'gated at G6' not in source, 'the entrypoint still describes G6 as closed'
print('OK')
"

run_case "the backend is resolved from the installed root, like the library" "${PRELUDE}
resolver = function(WORKER, '_backend_module')
names = calls_in(resolver)
# Same shape as _library: check the canonical root holds it BEFORE importing,
# then confirm where it actually resolved from. A search path is a preference
# and this needs a fact.
assert 'isfile' in names, names
assert 'realpath' in names, names
source = body_of(WORKER, '_backend_module')
assert 'RUNTIME_LIBRARY_ROOT' in source
assert 'SystemExit' in source, 'resolution failure is not a refusal'
print('OK')
"

run_case "the backend module is imported, not constructed by name" "${PRELUDE}
code = stripped(WORKER)
# One import of one module. No importlib, no getattr-by-string, no path from
# the profile, the package or the protocol.
for banned in ('import_module', '__import__', 'eval', 'exec(', 'load_module',
               'spec_from_file_location'):
    assert banned not in code, banned
imports = set()
for node in ast.walk(tree(WORKER)):
    if isinstance(node, ast.Import):
        imports.update(a.name.split('.')[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom):
        imports.add((node.module or '').split('.')[0])
assert 'kyri_exec_podman' in imports, imports
print('OK')
"

run_case "the implementation is chosen by the authenticated profile" "${PRELUDE}
body = body_of(WORKER, 'run_execution')
# Through the closed registry, keyed on the profile the transition
# authenticated -- not on argv, the environment, or the package.
assert 'backend_for' in body, body
assert 'profile.adapter_identity' in body, \\
    'the backend is not selected by the authenticated adapter identity'
print('OK')
"

# --- privilege ordering ------------------------------------------------------------

run_case "the identity gate precedes every execution step" "${PRELUDE}
names = calls_in(function(WORKER, 'main'))
assert 'require_worker_identity' in names, names
gate = names.index('require_worker_identity')
# Nothing that could reach Podman, the handoff, the snapshot or the backend may
# appear before the gate.
for later in ('require_launch_context', 'profile_from_descriptor',
              'run_execution', '_backend_module'):
    assert later in names, (later, names)
    assert names.index(later) > gate, (later, names)
print('OK')
"

run_case "the entrypoint performs no privileged action of its own" "${PRELUDE}
# The transition has already dropped privilege permanently and set
# no_new_privs; there is nothing left here to do and nothing is done. Asserted
# over code with docstrings removed, since the prose explains these very names
# -- the module docstring even quotes the execve tuple.
code = stripped(WORKER)
for banned in ('setuid', 'setgid', 'setgroups', 'prctl', 'PR_SET',
               'FS_IOC', 'projid', 'ioctl', 'chown', 'chmod', 'fork',
               'execve', 'subprocess'):
    assert banned not in code, banned
print('OK')
"

run_case "only the backend module may start a process" "${PRELUDE}
# The whole platform's subprocess authority, in one place. The entrypoint
# imports it; every other execution module is asserted elsewhere to reach none.
backend = stripped(BACKEND)
assert 'subprocess' in backend, 'the backend starts no process'
worker_code = stripped(WORKER)
assert 'subprocess.run' not in worker_code, 'the entrypoint runs a process itself'
print('OK')
"

# --- the snapshot stands between the coordinator and the container -----------------

run_case "the container's bind sources are the snapshot, never the handoff" "${PRELUDE}
body = body_of(WORKER, 'run_execution')
# materialise() consumes the verified gate result and produces the binding;
# create_argv takes that binding and nothing else, so there is no seam through
# which a coordinator-owned source could reach Podman.
assert 'materialise' in body, body
assert 'create_argv' in body, body
order = body.index('materialise') < body.index('create_argv')
assert order, 'argv is built before the snapshot exists'
# The gate runs first, and the snapshot consumes its result rather than the
# profile -- which is what stops the snapshot being a way around the gate.
assert 'verify_execution' in body
assert body.index('verify_execution') < body.index('materialise')
print('OK')
"

run_case "the output descriptor is opened no-follow" "${PRELUDE}
body = body_of(WORKER, 'run_execution')
assert '_DIR_FLAGS' in body, body
flags = [n for n in ast.walk(tree(WORKER))
         if isinstance(n, ast.Assign)
         and any(getattr(t, 'id', None) == '_DIR_FLAGS' for t in n.targets)]
assert len(flags) == 1, flags
declared = ast.unparse(flags[0])
for required in ('O_NOFOLLOW', 'O_DIRECTORY', 'O_CLOEXEC'):
    assert required in declared, (required, declared)
print('OK')
"

# --- the exit contract --------------------------------------------------------------

run_case "the exit status reports admission, not completion" "${PRELUDE}
body = body_of(WORKER, 'main')
# A capability that failed, timed out, or produced nothing collectable must not
# look like success merely because this process reached the end.
assert 'outcome.succeeded' in body, body
returns = [n for n in ast.walk(function(WORKER, 'main'))
           if isinstance(n, ast.Return)]
assert len(returns) == 1, ast.unparse(function(WORKER, 'main'))
assert 'succeeded' in ast.unparse(returns[0]), ast.unparse(returns[0])
print('OK')
"

# --- the generation closure reaches it ------------------------------------------------

run_case "the released entrypoint is a closure entry root" "${PRELUDE}
import importlib.util
spec = importlib.util.spec_from_file_location('runtime_closure',
                                              'tools/dev/runtime_closure.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# The worker entrypoint and the backend are production execution objects, so
# the closure must be able to name them. Adding the backend directly would be
# whitelisting; adding the entrypoint is naming a real entry point, and the
# backend then arrives through its import.
assert 'kyri_exec_worker' in module.FLATTENED, module.FLATTENED
assert 'kyri_exec_podman' in module.FLATTENED, module.FLATTENED
assert module.FLATTENED['kyri_exec_worker'] == \\
    'provisioning/execution/kyri-exec-worker.py'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution worker binding validation passed.\n'
else
  printf 'Capability execution worker binding validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
