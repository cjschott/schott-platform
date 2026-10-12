#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 G4 provisioning artifacts.
#
# STATIC AND UNPRIVILEGED. Nothing here installs a file, writes under
# /usr/libexec, /etc, /run, or /data, creates sudoers policy, mounts anything,
# or invokes a transition. It reads repository sources and asserts what they
# say. G1, G5, G6, and G7 stay closed.
#
# THE WORKER SCRIPT DELEGATES. It is the execve target the transition names,
# and its whole job is to be that target: validate one CINV, confirm the
# execution identity, and hand off to the accepted worker library. Execution
# policy lives in the library and is not restated here, because two copies of a
# Podman contract is one more than can be kept correct.
#
# THE SHEBANG IS NOT IN THE TRUST CHAIN. The worker is installed 0444 and never
# directly executed: the interpreter is named explicitly and the script is
# passed to it. A script that cannot be executed cannot be executed by the
# wrong interpreter.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §13, §22, §34
#   docs/superpowers/specs/2026-08-11-execution-transition-boundary.md  §3.2, §3.3

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
import ast, importlib.util, os, stat
from pathlib import Path

WORKER = Path('provisioning/execution/kyri-exec-worker.py')
BACKING = Path('provisioning/execution/backing-store.json.example')
SUDOERS = Path('provisioning/execution/sudoers.d/kyri-exec.example')
RUNBOOK = Path('provisioning/execution/README.md')

for required in (WORKER, BACKING, SUDOERS, RUNBOOK):
    assert required.exists(), str(required) + ' is absent'


def load(path, name):
    import sys
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    # Dataclass field resolution goes through sys.modules, and a module loaded
    # by location alone is not there yet.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def stripped(path):
    tree = ast.parse(path.read_text(encoding='utf-8'))
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return ast.unparse(tree)


CANONICAL_ROOT = '/usr/lib/kyri/python'
ROOT_ASSIGNMENT = 'RUNTIME_LIBRARY_ROOT = ' + chr(34) + CANONICAL_ROOT + chr(34)
MARK = 'LIBRARY' + '_REDIRECTED'
DECOY_SOURCE = chr(10).join([
    'import sys',
    'sys.stderr.write(' + repr(MARK) + ')',
    'PROFILE_FD = 3',
    'class WorkerRefused(ValueError):',
    '    pass',
    'def require_worker_identity(**kwargs):',
    '    return None',
    'def container_name(cinv):',
    '    return None',
    'def require_launch_context(**kwargs):',
    '    return None',
    'def profile_from_descriptor(context, descriptor=3):',
    '    return None',
])

# The vNext invocation, used wherever a subprocess must reach the library: the
# argument shape is checked before anything is imported, so a legacy one-CINV
# command line now refuses before resolution happens and would prove nothing
# about which library won.
WORKER_ARGV = ['CINV-000001', 'CIMP-000001', 'a' * 64]


def mirror_canonical_root(destination):
    '''Build a library root from the install matrix, not from the checkout.

    The matrix decides what the installed root contains, so a test that
    recursively copied the checkout would give the mirror a shape the real root
    does not have -- and would prove a property production does not hold.
    '''
    import shutil
    sources = []
    top = Path('tools/__init__.py')
    if top.exists():
        sources.append(top)
    for base in (Path('tools/capability'), Path('tools/common')):
        sources.extend(sorted(path for path in base.rglob('*.py')
                              if '__pycache__' not in path.parts))
    for source in sources:
        target = Path(destination) / source
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    return destination


def worker_rooted_at(root, destination):
    '''The real worker source with only the compiled-in root literal changed.

    The root is deliberately not configurable in production, so a host
    independent test cannot ask the real file to look elsewhere. Rewriting the
    single assignment keeps every line of the resolution logic under test and
    changes only where it looks; the two assertions are what keep that honest.
    '''
    original = WORKER.read_text(encoding='utf-8')
    assert original.count(ROOT_ASSIGNMENT) == 1, 'the compiled-in root moved'
    patched = original.replace(
        ROOT_ASSIGNMENT, 'RUNTIME_LIBRARY_ROOT = ' + repr(str(root)))
    assert CANONICAL_ROOT not in patched, 'the production root survived'
    Path(destination).write_text(patched, encoding='utf-8')
    return destination


def build_decoy(directory):
    '''A regular package named tools, carrying a worker that proves execution.

    Regular rather than namespace on purpose: a namespace portion loses to
    anything, so a namespace decoy would pass against a broken root and prove
    nothing.
    '''
    package = Path(directory) / 'tools' / 'capability' / 'execution'
    package.mkdir(parents=True)
    for part in ('tools', 'tools/capability', 'tools/capability/execution'):
        (Path(directory) / part / '__init__.py').write_text('', encoding='utf-8')
    (package / 'worker.py').write_text(DECOY_SOURCE, encoding='utf-8')
    return directory
"

# --- the worker entrypoint ---------------------------------------------------

run_case "the worker source carries no shebang and no executable bit" "${PRELUDE}
text = WORKER.read_text(encoding='utf-8')
assert not text.startswith('#!'), 'the worker carries a shebang'
mode = stat.S_IMODE(WORKER.lstat().st_mode)
assert not mode & 0o111, oct(mode)
# The installed mode is stated where an operator will look for it.
assert '0444' in text, 'the installed mode is not documented in the source'
print('OK')
"

run_case "the worker delegates to the accepted library and restates no policy" "${PRELUDE}
import ast
code = stripped(WORKER)
assert 'from tools.capability.execution import worker' in code, \
    'the worker does not delegate to the accepted library'

# Execution policy belongs to the library. A second COPY here is the failure --
# not a call into the library, which is the delegation this file exists to do.
# G11-AL bound the backend here, so the entrypoint now legitimately calls
# create_argv and names the installed backend module; what it still may not do
# is state a container contract of its own.
tree = ast.parse(WORKER.read_text(encoding='utf-8'))

# No flag, image or environment literal may appear anywhere in the source.
literals = [n.value for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str)]
for token in ('--network', '--cap-drop', '--user', '--mount', '--pull',
              '--userns', '--read-only', 'PYTHONHASHSEED', 'oci_image_id',
              '/usr/bin/podman', 'keep-id'):
    for literal in literals:
        assert token not in literal, (token, literal)

# The argv builder is the library's. The entrypoint may call it and may not
# define one: a locally defined create_argv is exactly the second copy.
assert not [n for n in ast.walk(tree)
            if isinstance(n, ast.FunctionDef) and n.name == 'create_argv'], \
    'the worker defines its own argv builder'
calls = [n for n in ast.walk(tree)
         if isinstance(n, ast.Call) and getattr(n.func, 'attr', None) == 'create_argv']
for call in calls:
    assert isinstance(call.func, ast.Attribute), ast.dump(call)
    assert getattr(call.func.value, 'id', None) == 'worker', \
        'create_argv is called on something other than the accepted library'

# Naming its own installed path is fine; building a container name is not.
assert chr(39) + 'kyri-' + chr(39) not in code, 'the worker builds a container name'
print('OK')
"

run_case "the worker takes exactly the five governed elements and nothing else" "${PRELUDE}
W = load(WORKER, 'kyri_exec_worker')
import inspect
assert list(inspect.signature(W.main).parameters) == ['argv'], \\
    inspect.signature(W.main)
digest = 'a' * 64
# vNext: no optional three-element form. Accepting one would mean accepting a
# profile nobody had bound to an implementation.
for argv in ([], ['x'], ['x', 'CINV-000001'], ['x', 'CINV-000001', 'CIMP-000001'],
             ['x', 'CINV-000001', 'CIMP-000001', digest, 'extra'],
             ['x', ''], ['x', 'CINV-00001', 'CIMP-000001', digest],
             ['x', 'CINV-0000001', 'CIMP-000001', digest],
             ['x', 'cinv-000001', 'CIMP-000001', digest],
             ['x', '../etc', 'CIMP-000001', digest],
             ['x', '/data/kyri', 'CIMP-000001', digest],
             ['x', 'CINV-00000a', 'CIMP-000001', digest],
             ['x', 'CINV-000001', 'CIMP-00001', digest],
             ['x', 'CINV-000001', 'CIMP-000000', digest],
             ['x', 'CINV-000001', 'CIMP-000001', digest.upper()],
             ['x', 'CINV-000001', 'CIMP-000001', 'sha256:' + digest],
             ['x', 'CINV-000001', 'CIMP-000001', 'a' * 63]):
    try:
        W.main(argv)
    except SystemExit:
        continue
    raise AssertionError('accepted argv ' + repr(argv))
print('OK')
"

run_case "the worker fails closed when it is not the execution identity" "${PRELUDE}
W = load(WORKER, 'kyri_exec_worker')
assert os.getuid() != 999, 'this suite must not run as the execution identity'
try:
    W.main(['kyri-exec-worker.py', 'CINV-000001', 'CIMP-000001', 'a' * 64])
except SystemExit:
    pass
else:
    raise AssertionError('the worker proceeded as the wrong identity')
print('OK')
"

run_case "the worker performs no privilege, quota, or trust action" "${PRELUDE}
code = stripped(WORKER)
for token in ('setuid', 'setgid', 'setgroups', 'no_new_privs', 'prctl',
              'ioctl', 'FS_IOC', 'projid', 'quota', 'subprocess', 'ctypes',
              'socket', 'chmod', 'chown', 'sudo'):
    assert token not in code, token
tree = ast.parse(WORKER.read_text(encoding='utf-8'))
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and node.attr == 'environ':
        raise AssertionError('the worker reads the environment')
print('OK')
"

run_case "the worker adds no environment beyond the accepted container set" "${PRELUDE}
from tools.capability.execution.worker import CONTAINER_ENVIRONMENT
assert CONTAINER_ENVIRONMENT == (
    ('LC_ALL', 'C.UTF-8'), ('PYTHONDONTWRITEBYTECODE', '1'),
    ('PYTHONHASHSEED', '0'), ('PYTHONUTF8', '1')), CONTAINER_ENVIRONMENT
code = stripped(WORKER)
assert 'putenv' not in code and 'setdefault' not in code
print('OK')
"

# --- structural consistency with the transition ------------------------------

run_case "the transition exec target and the installed worker agree" "${PRELUDE}
policy = load(Path('provisioning/execution/kyri-exec-transition.py'),
              'kyri_exec_transition')
assert policy.WORKER_SCRIPT == '/usr/libexec/kyri-exec-worker.py', \\
    policy.WORKER_SCRIPT
# The repository source is the thing that becomes that installed path.
assert Path(policy.WORKER_SCRIPT).name == WORKER.name, \\
    (policy.WORKER_SCRIPT, WORKER.name)
assert policy.WORKER_INTERPRETER == '/usr/bin/python3', policy.WORKER_INTERPRETER
# And the argv is exactly interpreter, script, CINV.
built = policy.build_policy if hasattr(policy, 'build_policy') else None
# vNext: descriptor 3 carries the sealed profile object the transition authors.
assert policy.INHERITED_DESCRIPTORS == (0, 1, 2, 3), policy.INHERITED_DESCRIPTORS
assert policy.PROFILE_FD == 3, policy.PROFILE_FD
print('OK')
"

run_case "the worker is never selected through PATH or the checkout" "${PRELUDE}
policy = load(Path('provisioning/execution/kyri-exec-transition.py'),
              'kyri_exec_transition')
for value in (policy.WORKER_SCRIPT, policy.WORKER_INTERPRETER,
              policy.HELPER_PATH):
    assert value.startswith('/'), value
    assert 'schott-platform' not in value, value
    assert 'tools/' not in value, value
print('OK')
"

# --- the installed runtime library boundary ----------------------------------

run_case "the canonical installed library root is fixed and compiled in" "${PRELUDE}
W = load(WORKER, 'kyri_exec_worker')
assert W.RUNTIME_LIBRARY_ROOT == '/usr/lib/kyri/python', W.RUNTIME_LIBRARY_ROOT
import ast
code = stripped(WORKER)
assert 'RUNTIME_LIBRARY_ROOT' in code

# The root must not be derived from anything a caller can influence. Asserted
# as attribute accesses rather than as substrings: an environment= keyword
# argument contains those letters and would trip a text scan while having
# nothing to do with reading the process environment.
# Docstrings removed first: _library's prose explains that an inherited
# PYTHONPATH must not win, and scanning it would read the explanation as the
# thing it forbids.
tree = ast.parse(stripped(WORKER))
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and getattr(node.value, 'id', None) == 'os':
        assert node.attr not in ('environ', 'environb', 'getenv', 'putenv',
                                 'getcwd'), f'os.{node.attr}'
    if isinstance(node, ast.Call):
        name = getattr(node.func, 'attr', None) or getattr(node.func, 'id', None)
        assert name not in ('getenv', 'getcwd'), name
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        assert 'PYTHONPATH' not in node.value, node.value
print('OK')
"

run_case "the production worker cannot import policy from the checkout" "${PRELUDE}
code = stripped(WORKER)
for token in ('/opt/schott-platform', 'schott-platform', 'site-packages'):
    assert token not in code, token
assert 'origin' in code or '__file__' in code, \\
    'the worker does not verify where its library resolved from'
print('OK')
"

run_case "the canonical library root is a regular package, not a namespace" "${PRELUDE}
# A namespace portion does not terminate the import search, so a regular
# package of the same name found later on sys.path wins outright -- inserting
# the canonical root at position 0 does not help. The installed tree must
# therefore be a regular package, which means the matrix must carry this file.
top = Path('tools/__init__.py')
assert top.exists(), 'tools/__init__.py is absent: tools installs as a namespace package'
rows = [line for line in RUNBOOK.read_text(encoding='utf-8').splitlines()
        if 'tools/__init__.py' in line and '|' in line]
assert rows, 'the install matrix does not carry tools/__init__.py'
for row in rows:
    assert '/usr/lib/kyri/python/tools/__init__.py' in row, row
    assert '0444' in row, row
    assert 'root:root' in row, row
print('OK')
"

run_case "PYTHONPATH cannot redirect the production import" "${PRELUDE}
import subprocess, tempfile
assert os.getuid() != 0, 'this case reads the unprivileged refusal'
with tempfile.TemporaryDirectory() as work:
    canonical = mirror_canonical_root(str(Path(work) / 'canonical'))
    decoy = build_decoy(str(Path(work) / 'decoy'))
    script = worker_rooted_at(canonical, str(Path(work) / 'worker.py'))
    outcome = subprocess.run(
        ['/usr/bin/python3', script] + WORKER_ARGV,
        cwd='/', env={'PYTHONPATH': decoy, 'PATH': '/usr/bin:/bin',
                      'PYTHONDONTWRITEBYTECODE': '1'},
        capture_output=True, text=True)
combined = outcome.stdout + outcome.stderr
assert outcome.returncode != 0, combined
# The property is that the decoy never runs -- not that it runs and is then
# rejected. Module-level code has already had its effect by the time a
# post-import check can object.
assert MARK not in combined, 'the decoy library executed: ' + combined
# Positive half: the refusal can only come from the governed library, so its
# presence proves resolution reached the canonical root rather than nothing.
assert 'refused:' in combined, 'the governed library was not reached: ' + combined
print('OK')
"

run_case "the working directory cannot redirect the production import" "${PRELUDE}
import subprocess, tempfile
assert os.getuid() != 0, 'this case reads the unprivileged refusal'
with tempfile.TemporaryDirectory() as work:
    canonical = mirror_canonical_root(str(Path(work) / 'canonical'))
    decoy = build_decoy(str(Path(work) / 'decoy'))
    script = worker_rooted_at(canonical, str(Path(work) / 'worker.py'))
    outcome = subprocess.run(
        ['/usr/bin/python3', script] + WORKER_ARGV,
        cwd=decoy, env={'PATH': '/usr/bin:/bin',
                        'PYTHONDONTWRITEBYTECODE': '1'},
        capture_output=True, text=True)
combined = outcome.stdout + outcome.stderr
assert outcome.returncode != 0, combined
assert MARK not in combined, 'the working directory redirected the import: ' + combined
assert 'refused:' in combined, 'the governed library was not reached: ' + combined
print('OK')
"

run_case "an absent library refuses before importing anything" "${PRELUDE}
import subprocess, tempfile
# Host-independent by construction: the root under test is one this case
# creates and never creates anything at, so the answer does not depend on
# whether G4 has run. The old form asserted /usr/lib/kyri/python was absent,
# which only asked whether provisioning had happened -- not a property of this
# suite, and false from the moment it did.
#
# Whether the *installed* tree holds these properties is verified against the
# host after each re-provisioning, not here; a source suite that asserted it
# could never be green before the install it is meant to authorise.
with tempfile.TemporaryDirectory() as work:
    missing = str(Path(work) / 'nowhere')
    decoy = build_decoy(str(Path(work) / 'decoy'))
    script = worker_rooted_at(missing, str(Path(work) / 'worker.py'))
    outcome = subprocess.run(
        ['/usr/bin/python3', script] + WORKER_ARGV,
        cwd='/', env={'PYTHONPATH': decoy, 'PATH': '/usr/bin:/bin',
                      'PYTHONDONTWRITEBYTECODE': '1'},
        capture_output=True, text=True)
combined = outcome.stdout + outcome.stderr
assert outcome.returncode != 0, combined
assert 'not installed' in combined, combined
# The refusal must come before the import, so an available decoy is never
# reached even when the canonical root holds nothing.
assert MARK not in combined, 'the decoy executed while failing closed: ' + combined
print('OK')
"

# --- the transition public interface -----------------------------------------

run_case "exactly one privileged public transition entrypoint exists" "${PRELUDE}
ENTRY = Path('provisioning/execution/kyri-exec-transition-entrypoint.py')
assert ENTRY.exists(), str(ENTRY) + ' is absent'
E = load(ENTRY, 'kyri_exec_transition_entrypoint')
assert E.HELPER_PATH == '/usr/libexec/kyri-exec-transition', E.HELPER_PATH
assert E.RUNTIME_LIBRARY_ROOT == '/usr/lib/kyri/python', E.RUNTIME_LIBRARY_ROOT
import inspect
assert list(inspect.signature(E.main).parameters) == ['argv'], \\
    inspect.signature(E.main)
print('OK')
"

run_case "the transition action stays an internal library component" "${PRELUDE}
prose = RUNBOOK.read_text(encoding='utf-8')
# Checked as a mapping, not as wording: the runbook may say the action is
# not a command, and saying so must not read as doing so.
rows = [line for line in prose.splitlines()
        if 'kyri-exec-transition-action' in line and '|' in line]
assert rows, 'the action has no installed destination'
for row in rows:
    assert '/usr/libexec' not in row, row
    assert '/usr/lib/kyri/python' in row, row
action = Path('provisioning/execution/kyri-exec-transition-action.py')
assert '__main__' not in action.read_text(encoding='utf-8'), \\
    'the action carries its own command entry point'
print('OK')
"

run_case "the transition entrypoint takes nothing but one CINV" "${PRELUDE}
ENTRY = Path('provisioning/execution/kyri-exec-transition-entrypoint.py')
E = load(ENTRY, 'kyri_exec_transition_entrypoint')
for argv in ([], ['x'], ['x', 'CINV-000001', 'extra'],
             ['x', 'CINV-000001', '--library-root=/tmp']):
    try:
        E.main(argv)
    except SystemExit:
        continue
    raise AssertionError('accepted argv ' + repr(argv))
code = stripped(ENTRY)
for token in ('getenv', 'environ', 'getcwd', 'PYTHONPATH', 'schott-platform'):
    assert token not in code, token
print('OK')
"

# --- the backing-store example -----------------------------------------------

run_case "the backing-store example matches the accepted closed schema" "${PRELUDE}
from tools.capability.execution import canonical_json
from tools.capability.execution.backing_store import MAXIMUM_CONFIG_BYTES
body = BACKING.read_bytes()
assert len(body) <= MAXIMUM_CONFIG_BYTES, len(body)
document = canonical_json.parse(body, maximum_bytes=MAXIMUM_CONFIG_BYTES)
assert set(document) == {'filesystem_uuid', 'filesystem_type', 'mount_point'}, \\
    sorted(document)
for name, value in document.items():
    assert isinstance(value, str) and value, (name, value)
print('OK')
"

run_case "the backing-store example is accepted by the real verifier" "${PRELUDE}
from tools.capability.execution.backing_store import _parse_config
document = _parse_config(BACKING.read_bytes())
assert document['filesystem_type'] == 'xfs', document
assert document['mount_point'] == '/data', document
print('OK')
"

run_case "the example carries no live host identity" "${PRELUDE}
text = BACKING.read_text(encoding='utf-8')
# The production UUID is captured from the host at provisioning time. A real
# one committed here would be a default somebody could ship by accident.
assert 'c5ea4a36-fc61-4978-8d9e-3a83c29f9a00' not in text, \\
    'the live host UUID is committed in the repository'
assert '/dev/sdb1' not in text, 'a device name is committed as configuration'
document_uuid = __import__('json').loads(text)['filesystem_uuid']
assert set(document_uuid) - set('0123456789abcdef-') or 'x' in document_uuid, \\
    'the example UUID is indistinguishable from a real one'
print('OK')
"

# --- the sudoers example ------------------------------------------------------

run_case "the sudoers example grants exactly one path and one argument" "${PRELUDE}
text = SUDOERS.read_text(encoding='utf-8')
lines = [line.strip() for line in text.splitlines()
         if line.strip() and not line.strip().startswith('#')]
body = ' '.join(lines)
assert '/usr/libexec/kyri-exec-transition' in body, body
assert '^CINV-[0-9]{6}\$' in body, body
assert 'cschott' in body, body
assert 'NOPASSWD' in body, body
print('OK')
"

run_case "the sudoers example opens no broader authority" "${PRELUDE}
text = SUDOERS.read_text(encoding='utf-8')
lines = [line.strip() for line in text.splitlines()
         if line.strip() and not line.strip().startswith('#')]
body = ' '.join(lines)
for forbidden in ('podman', 'runuser', 'su ', '/bin/sh', '/bin/bash',
                  'systemd-run', 'xfs_quota', 'SETENV', 'env_keep',
                  '!authenticate', 'ALL=(ALL)', 'ALL=(ALL:ALL)', '*',
                  'kyri-exec-quota', 'kyri-exec-admin', '/usr/bin/python3'):
    assert forbidden not in body, forbidden
# One command specification, one runas, one caller.
assert body.count('NOPASSWD') == 1, body
print('OK')
"

run_case "the sudoers example is an example and is installed by nothing" "${PRELUDE}
assert SUDOERS.name.endswith('.example'), SUDOERS.name
try:
    assert not Path('/etc/sudoers.d/kyri-exec').exists(), 'sudoers policy exists'
except PermissionError:
    pass  # 0750 on some runners: unreadable is not absent, and a
          # distribution default is not a policy breach
installed = '/etc/sudoers.d/' + 'kyri-exec'
for suite in Path('tests').glob('*.sh'):
    text = suite.read_text(encoding='utf-8')
    # No suite may copy the example into place or validate it as policy.
    assert (installed + ' ') not in text, suite.name
    assert 'vi' + 'sudo' not in text, suite.name
# The digest is captured at G3 against the installed artifact, not committed.
text = SUDOERS.read_text(encoding='utf-8')
assert 'sha256:' in text, 'the digest control is not represented'
assert 'REPLACE' in text or 'PLACEHOLDER' in text, \\
    'a concrete digest is committed as if it were real'
print('OK')
"

# --- the argument constraint is a regex, and fails closed if it is not --------
#
# sudoers matches command arguments with shell globs by default. An argument is
# read as a regular expression only when it begins with '^' and ends with '\$',
# and only on sudo >= 1.9.10. Parsing successfully proves neither, so the form
# is pinned here: an edit that drops an anchor silently changes which
# invocations the grant admits, and would do it without any syntax error.

run_case "the sudoers argument is anchored, so sudoers reads it as a regex" "${PRELUDE}
text = SUDOERS.read_text(encoding='utf-8')
lines = [line.strip() for line in text.splitlines()
         if line.strip() and not line.strip().startswith('#')]
alias = [line for line in lines if 'Cmnd_Alias' in line]
assert len(alias) == 1, alias
argument = alias[0].split()[-1]
assert argument.startswith('^'), argument
assert argument.endswith('\$'), argument
assert argument == '^CINV-[0-9]{6}\$', argument
print('OK')
"

run_case "a sudo too old for regex arguments would deny every CINV, not admit one" "${PRELUDE}
import fnmatch
pattern = '^CINV-[0-9]{6}\$'
# Under glob semantics '^', '{6}' and '\$' are literal and '[0-9]' matches a
# single character, so the pattern describes strings no well-formed CINV can
# be. Misinterpretation therefore costs availability, never authority -- which
# is the direction a privilege grant is allowed to fail in.
for identity in ('CINV-000000', 'CINV-000123', 'CINV-999999'):
    assert not fnmatch.fnmatchcase(identity, pattern), identity
print('OK')
"

run_case "the sudoers regex admits exactly what the helper admits" "${PRELUDE}
import re
module = load(Path('provisioning/execution/kyri-exec-transition.py'),
              'kyri_exec_transition')
# The anchors are sudoers syntax; the expression between them is the pattern.
expression = re.compile('CINV-[0-9]{6}')

accepted = ('CINV-000000', 'CINV-000123', 'CINV-999999')
refused = ('CINV-00012', 'CINV-0001234', 'cinv-000123', 'CINV-00012a',
           ' CINV-000123', 'CINV-000123 ', 'CINV-000123\\\\n', '',
           'CINV-', 'CINV-000123; rm -rf /', 'CINV-0001 3', '../CINV-000123')
for identity in accepted + refused:
    by_regex = expression.fullmatch(identity) is not None
    try:
        module.validate_cinv(identity)
        by_helper = True
    except module.TransitionRefused:
        by_helper = False
    assert by_regex == by_helper, (identity, by_regex, by_helper)
    assert by_helper == (identity in accepted), identity
print('OK')
"

run_case "the grant does not carry noexec, which would break the helper" "${PRELUDE}
text = SUDOERS.read_text(encoding='utf-8')
lines = [line.strip() for line in text.splitlines()
         if line.strip() and not line.strip().startswith('#')]
body = ' '.join(lines).lower()
# The helper's entire purpose is to execve the worker after dropping privilege.
# NOEXEC would forbid exactly that, and the grant would look more restrictive
# while being non-functional.
assert 'noexec' not in body, body
print('OK')
"

# --- the runbook --------------------------------------------------------------

run_case "the runbook records the live quota blocker without remediating it" "${PRELUDE}
prose = RUNBOOK.read_text(encoding='utf-8')
assert 'noquota' in prose, 'the current mount state is not recorded'
for phrase in ('unmount', 'maintenance window'):
    assert phrase.lower() in prose.lower(), phrase
# A remount is explicitly not accepted as the remediation.
assert 'remount,prjquota' in prose, 'the rejected remediation is not named'
assert 'not sufficient' in prose.lower() or 'will not' in prose.lower(), \\
    'the rejected remediation is not marked as rejected'
print('OK')
"

run_case "the runbook orders the backing-store bootstrap before quota work" "${PRELUDE}
prose = RUNBOOK.read_text(encoding='utf-8')
bootstrap = prose.lower().index('backing-store identity')
limits = prose.lower().index('bhard=32m')
assert bootstrap < limits, (bootstrap, limits)
for phrase in ('read the installed configuration back', 'refuse',
               'independently observed'):
    assert phrase.lower() in prose.lower(), phrase
print('OK')
"

run_case "the runbook carries the enforcement fixture and its cleanup" "${PRELUDE}
prose = RUNBOOK.read_text(encoding='utf-8')
for phrase in ('disposable', 'over-limit', 'cleanup', 'rollback',
               'sha256sum', '0444', 'bhard=32m', 'ihard=512'):
    assert phrase.lower() in prose.lower(), phrase
for path in ('/usr/libexec/kyri-exec-transition',
             '/usr/libexec/kyri-exec-worker.py',
             '/usr/libexec/kyri-exec-quota'):
    assert path in prose, path
print('OK')
"

run_case "the runbook executes nothing and states the gates stay closed" "${PRELUDE}
prose = RUNBOOK.read_text(encoding='utf-8')
assert RUNBOOK.suffix == '.md', RUNBOOK.suffix
for phrase in ('sudoers', 'image admission', 'G6'):
    assert phrase.lower() in prose.lower(), phrase
# Nothing under provisioning/execution is executable.
for entry in Path('provisioning/execution').rglob('*'):
    if entry.is_file():
        assert not stat.S_IMODE(entry.lstat().st_mode) & 0o111, entry
print('OK')
"

run_case "the provisioning suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-provisioning.sh'
assert name in validation, 'local validation does not run the suite'
assert name in ci, 'ci does not run the suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution G4 provisioning artifact validation passed.\n'
else
  printf 'Capability execution G4 provisioning artifact validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
