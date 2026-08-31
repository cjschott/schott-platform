#!/usr/bin/env bash
set -Eeuo pipefail

# The governed Podman backend: the one module in Kyri that starts a process.
#
# NO PODMAN RUNS HERE, and no container is created. Every case is static or
# fixture-driven, so this suite proves the same things on a CI runner with no
# container runtime as it does on the production host. The behaviour that needs
# a real runtime is proven by provisioning/execution/g11-aj-e2e-probe.sh
# against the exported governed image.
#
# WHAT THIS IS GUARDING
# =====================
# Everything under tools/capability/ is asserted to reach no subprocess at all,
# and lifecycle.py -- the first module allowed even to name Podman -- is held
# to "naming it is all that is permitted". This module is where that stops
# being true, so it is where the boundary has to be stated: one executable by
# absolute path, a closed subcommand set, argv vectors, no shell, a closed
# environment, bounded output, and a timeout.
#
# The registry is the other half. An adapter identity resolves to an
# implementation by dictionary lookup, and there is deliberately no import by
# name, no entry point, no plugin directory and no configured executable --
# each of which would be a route by which something other than this module
# could become the backend.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND="provisioning/execution/kyri-exec-podman.py"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

if [[ ! -f "${ROOT}/${BACKEND}" ]]; then
  fail "required file missing: ${BACKEND}"
  exit 1
fi
pass "file exists: ${BACKEND}"

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
import importlib.util, sys
sys.path.insert(0, '.')
spec = importlib.util.spec_from_file_location(
    'kyri_exec_podman', 'provisioning/execution/kyri-exec-podman.py')
B = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_podman'] = B
spec.loader.exec_module(B)
IMAGE = '5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190'
"

# --- the closed registry --------------------------------------------------------

run_case "the registry binds exactly one adapter identity" "${PRELUDE}
backend = B.backend_for('python-podman-v1')
assert isinstance(backend, B.PodmanBackend), type(backend)
for unknown in ('python-docker-v1', 'python-podman-v2', 'PYTHON-PODMAN-V1',
                'python-podman', '', 'default'):
    try:
        B.backend_for(unknown)
    except B.PodmanBackendRefused:
        continue
    raise AssertionError(f'an unknown adapter resolved: {unknown!r}')
print('OK')
"

run_case "no dynamic import, plugin, or configured executable exists" "${PRELUDE}
import ast
from pathlib import Path
tree = ast.parse(Path('provisioning/execution/kyri-exec-podman.py').read_text())
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        name = getattr(node.func, 'attr', None) or getattr(node.func, 'id', None)
        # import_module / __import__ / eval / exec would each be a route by
        # which something other than this module became the backend.
        assert name not in ('import_module', '__import__', 'eval', 'exec',
                            'load_module', 'entry_points', 'getenv'), name
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(a.name.split('.')[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom):
        imports.add((node.module or '').split('.')[0])
assert imports <= {'__future__', 'json', 'subprocess', 'typing'}, imports
print('OK')
"

# --- the subprocess boundary ----------------------------------------------------

run_case "the runtime is one absolute path, never resolved through PATH" "${PRELUDE}
assert B.PODMAN == '/usr/bin/podman', B.PODMAN
assert B.PODMAN.startswith('/')
print('OK')
"

run_case "the subcommand set is closed and holds no mutating verb" "${PRELUDE}
assert B.PERMITTED_SUBCOMMANDS == {
    'create', 'inspect', 'start', 'stop', 'kill', 'rm', 'ps'}, \
    B.PERMITTED_SUBCOMMANDS
for banned in ('pull', 'build', 'run', 'load', 'save', 'push', 'tag', 'exec',
               'cp', 'import', 'commit', 'login'):
    assert banned not in B.PERMITTED_SUBCOMMANDS, banned
backend = B.backend_for('python-podman-v1')
for banned in ('pull', 'build', 'run', 'exec'):
    try:
        backend._run(banned, [])
    except B.PodmanBackendRefused:
        continue
    raise AssertionError(f'a forbidden subcommand was accepted: {banned}')
print('OK')
"

run_case "no shell is reachable and stdin is closed" "${PRELUDE}
import ast, inspect
from pathlib import Path
source = Path('provisioning/execution/kyri-exec-podman.py').read_text()
tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        for keyword in node.keywords:
            if keyword.arg == 'shell':
                assert isinstance(keyword.value, ast.Constant) and \
                    keyword.value.value is False, 'shell is not pinned False'
code = ast.unparse(tree)
for banned in ('/bin/sh', '/bin/bash', 'os.system', 'popen', 'shell=True'):
    assert banned not in code, banned
# Every process creation closes stdin and bounds what it will read back.
assert code.count('stdin=subprocess.DEVNULL') == 2, code.count('stdin=subprocess.DEVNULL')
assert 'timeout=self._timeout' in code
assert 'capture_output=True' in code
print('OK')
"

run_case "the backend environment is closed to three names" "${PRELUDE}
assert B.PERMITTED_ENVIRONMENT == {'HOME', 'PATH', 'XDG_RUNTIME_DIR'}, \
    B.PERMITTED_ENVIRONMENT
for bad in (('LD_PRELOAD', '/x.so'),), (('PYTHONPATH', '/x'),), (('SHELL', '/bin/sh'),):
    try:
        B.PodmanBackend(environment=bad)
    except B.PodmanBackendRefused:
        continue
    raise AssertionError(f'an ungoverned variable was accepted: {bad}')
# The two Podman resolves its storage from must be absolute.
try:
    B.PodmanBackend(environment=(('HOME', 'relative'),))
except B.PodmanBackendRefused:
    pass
else:
    raise AssertionError('a relative HOME was accepted')
print('OK')
"

run_case "the storage seam admits only --root and --runroot, absolute" "${PRELUDE}
B.PodmanBackend(storage=('--root', '/tmp/a', '--runroot', '/tmp/b'))
for bad in (('--storage-driver', 'vfs'), ('--remote', '/x'), ('--root',),
            ('--root', 'relative'), ('--url', 'tcp://x'), ('/tmp/a',)):
    try:
        B.PodmanBackend(storage=bad)
    except B.PodmanBackendRefused:
        continue
    raise AssertionError(f'the storage seam accepted {bad!r}')
print('OK')
"

# --- create takes the governed argv and composes none of it ---------------------

run_case "create refuses any command line it did not receive governed" "${PRELUDE}
backend = B.backend_for('python-podman-v1')
env = tuple(B.BACKEND_ENVIRONMENT)
for bad in ([], ['/usr/bin/docker', 'create'], ['/usr/bin/podman', 'run'],
            ['/usr/bin/podman', 'pull', IMAGE], ['podman', 'create']):
    try:
        backend.create(bad, env)
    except B.PodmanBackendRefused:
        continue
    raise AssertionError(f'create accepted {bad!r}')
print('OK')
"

run_case "create refuses a transition environment it was not built with" "${PRELUDE}
backend = B.backend_for('python-podman-v1')
try:
    backend.create(['/usr/bin/podman', 'create'], (('HOME', '/somewhere/else'),))
except B.PodmanBackendRefused:
    print('OK')
else:
    raise AssertionError('a divergent transition environment was accepted')
"

# --- observation is translation, never substitution -----------------------------

run_case "the image identity normalises one known spelling and nothing else" "${PRELUDE}
assert B._canonical_image_id(IMAGE) == IMAGE
assert B._canonical_image_id('sha256:' + IMAGE) == IMAGE
for bad in (IMAGE[:12], IMAGE.upper(), 'sha256:' + IMAGE.upper(),
            IMAGE + 'deadbeef', 'localhost/kyri:g5', 'sha512:' + IMAGE,
            '', None, 42, 'sha256:'):
    assert B._canonical_image_id(bad) is None, bad
print('OK')
"

run_case "the tmpfs mount is parsed from what Podman said" "${PRELUDE}
size, mode, options = B._tmpfs(
    {'/tmp': 'size=16m,mode=1777,noexec,nosuid,nodev,rw,rprivate,tmpcopyup'})
assert size == 16 * 1024 * 1024, size
assert mode == 0o1777, oct(mode)
assert options == ('noexec', 'nosuid', 'nodev'), options
# Nothing is assumed when the runtime says nothing.
assert B._tmpfs(None) == (None, None, None)
assert B._tmpfs({}) == (None, None, None)
assert B._tmpfs({'/other': 'size=16m'}) == (None, None, None)
print('OK')
"

run_case "dropping everything is claimed only when nothing remains" "${PRELUDE}
# Verified against the installed Podman: a container created WITHOUT
# --cap-drop ALL reports all eleven of this host's capabilities in
# BoundingCaps, and one created WITH it omits the key. So the expansion is
# normalised to ALL only when the bounding set agrees.
eleven = ['CAP_CHOWN', 'CAP_DAC_OVERRIDE', 'CAP_FOWNER', 'CAP_FSETID',
          'CAP_KILL', 'CAP_NET_BIND_SERVICE', 'CAP_SETFCAP', 'CAP_SETGID',
          'CAP_SETPCAP', 'CAP_SETUID', 'CAP_SYS_CHROOT']
dropped, effective = B._capabilities({'CapDrop': eleven}, {})
assert dropped == ('ALL',), dropped
assert effective == (), effective

# Capabilities remain: the raw expansion is reported and will not match.
dropped, effective = B._capabilities({'CapDrop': []}, {'BoundingCaps': eleven})
assert dropped == (), dropped
assert effective == tuple(eleven), effective

# A partial drop is not ALL, whatever it was asked for.
dropped, effective = B._capabilities(
    {'CapDrop': ['CAP_CHOWN']}, {'BoundingCaps': ['CAP_SETUID']})
assert dropped == ('CAP_CHOWN',), dropped
assert effective == ('CAP_SETUID',), effective

# Nothing reported stays nothing.
assert B._capabilities({}, {})[0] is None
print('OK')
"

run_case "the observation omits what a container cannot report" "${PRELUDE}
import ast, inspect, textwrap
# Code, not prose: the method's comment names the two fields precisely in order
# to say they are absent, and a raw text scan would read the explanation as the
# thing it forbids. ast.unparse drops comments and the docstring is popped.
tree = ast.parse(textwrap.dedent(inspect.getsource(B.PodmanBackend.inspect)))
function = tree.body[0]
if isinstance(function.body[0], ast.Expr) and \
        isinstance(function.body[0].value, ast.Constant):
    function.body.pop(0)
code = ast.unparse(function)
# Both were removed because they were being filled from the expected profile.
assert 'ProfileSchemaVersion' not in code, code
assert 'Sockets' not in code, 'the backend invents a socket report'
print('OK')
"

run_case "a container that never ran reports no start time" "${PRELUDE}
assert B.ZERO_TIME == '0001-01-01T00:00:00Z'
# Podman renders 'never' as the zero time, which is truthy and would otherwise
# read as evidence that the workload started.
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution Podman backend validation passed.\n'
else
  printf 'Capability execution Podman backend validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
