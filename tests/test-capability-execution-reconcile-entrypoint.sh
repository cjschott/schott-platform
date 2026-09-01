#!/usr/bin/env bash
set -Eeuo pipefail

# The privileged reconciliation entrypoint: what it becomes, in what order.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no setuid, no account is created, no
# helper is installed, no Podman runs, and nothing under /etc or /usr is
# written. Every credential primitive is an injected recorder, which is the same
# seam the launch transition has been tested through since T11 -- and the only
# seam available, because a real drop to the execution identity would drive
# rootless Podman into the production graphroot.
#
# WHY THAT SEAM PROVES SOMETHING
# ==============================
# The decision layer is where the security property lives. `perform_reconciliation`
# is production code, run here unmodified, and what the recorder captures is the
# exact sequence of syscalls it asked for and the exact arguments it asked for
# them with. What the recorder cannot prove is that Linux honours setuid, which
# is not a property of this repository.
#
# WHAT G11-AR COULD NOT BUILD
# ===========================
# This entrypoint. Its whole job is to become the execution principal, and until
# G11-AS the only way to learn which identity that was would have been to read
# two constants compiled into the helper -- reproducing, inside a new privileged
# binary, the defect G11-AH had already removed from the launch helper. So every
# case below drives TWO unrelated deployments through the same code, because
# that is the assertion the compiled-in version would have passed anyway.

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
import ast, importlib.util, json, os, sys
sys.path.insert(0, '.')
from pathlib import Path

ENTRYPOINT = Path('provisioning/execution/kyri-exec-reconcile-entrypoint.py')
RECONCILE_WORKER = Path('provisioning/execution/kyri-exec-reconcile-worker.py')
TRANSITION = Path('provisioning/execution/kyri-exec-transition.py')
ACTION = Path('provisioning/execution/kyri-exec-transition-action.py')

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy = load('kyri_exec_transition', TRANSITION)
action = load('kyri_exec_transition_action', ACTION)

class Status:
    def __init__(self, mode=0o100444, uid=0, gid=0):
        self.st_mode, self.st_uid, self.st_gid = mode, uid, gid

def body(account='fixture-a', uid=999, gid=987):
    return json.dumps({'execution_account': account, 'execution_gid': gid,
                       'execution_uid': uid, 'schema_version': 1},
                      sort_keys=True, separators=(',', ':')).encode()

def identity(account='fixture-a', uid=999, gid=987):
    return policy.load_execution_identity(body(account, uid, gid), Status(),
                                          resolve=lambda name: (uid, gid))

DEPLOYMENTS = (('fixture-a', 999, 987), ('fixture-b', 2203, 2207))

class Recorder:
    '''Every credential primitive, recorded rather than performed.

    It reports what the process WOULD become, so the ordering and the arguments
    are real production decisions while nothing about this process changes.
    '''

    def __init__(self, uid, gid, *, fail_at=None, nnp=1, creds=None):
        self.calls = []
        self._uid, self._gid = uid, gid
        self._fail_at, self._nnp = fail_at, nnp
        self._creds = creds
        self.dropped = False

    def _step(self, name, *detail):
        self.calls.append((name,) + detail)
        if self._fail_at == name:
            raise OSError(1, f'{name} refused')

    def open_directory(self, path):
        self.calls.append(('open_directory', path))
        raise OSError(2, 'no governed root in this fixture', path)

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
        if self._creds is not None:
            return self._creds
        return action.Credentials(self._uid, self._uid, self._uid,
                                  self._gid, self._gid, self._gid,
                                  (self._gid,))

    def set_no_new_privs(self):
        self._step('set_no_new_privs')

    def get_no_new_privs(self):
        self.calls.append(('get_no_new_privs',))
        if self._fail_at == 'get_no_new_privs':
            raise OSError(1, 'refused')
        return self._nnp

    def execve(self, path, argv, environment):
        self.calls.append(('execve', path, tuple(argv), tuple(environment)))
        raise action.WorkerExecuted(path)

def order(recorder):
    return [call[0] for call in recorder.calls]

def drive(account, uid, gid, **options):
    '''One full reconciliation decision, to the point of exec.'''
    who = identity(account, uid, gid)
    plan = policy.reconciliation_policy_for(['prog', 'CINV-000042'], identity=who)
    recorder = Recorder(uid, gid, **options)
    try:
        action.perform_reconciliation(plan, backend=recorder, assume_root=True)
    except action.WorkerExecuted:
        return recorder, None
    except policy.TransitionRefused as error:
        return recorder, error
    raise AssertionError('perform_reconciliation returned')
"

# --- the public interface ----------------------------------------------------------

run_case "the entrypoint accepts one CINV and has no option parser" "${PRELUDE}
source = ENTRYPOINT.read_text(encoding='utf-8')
for banned in ('argparse', 'optparse', 'getopt', '--force', '--uid', '--gid',
               '--user', '--container', '--name', '--image', '--all'):
    assert banned not in source, banned
for argv in ([], ['prog'], ['prog', 'CINV-000042', 'CINV-000043'],
             ['prog', 'CINV-000042', '--force'], ['prog', ''],
             ['prog', 'cinv-000042'], ['prog', 'kyri-CINV-000042'],
             ['prog', '../CINV-000042'], ['prog', 'CINV-000042 ']):
    try:
        policy.reconciliation_policy_for(argv, identity=identity())
    except policy.TransitionRefused:
        continue
    raise AssertionError(f'accepted argv {argv}')
plan = policy.reconciliation_policy_for(['prog', 'CINV-000042'],
                                        identity=identity())
assert plan.cinv == 'CINV-000042'
# No profile, no handoff, no evidence path, no quota: reconciliation authors
# nothing and reads no coordinator-published object.
fields = {f.name for f in __import__('dataclasses').fields(plan)}
assert not (fields & {'profile_fd', 'profile_path', 'handoff_path',
                      'evidence_path'}), fields
print('OK')
"

run_case "it is a second entrypoint, not a subcommand of the first" "${PRELUDE}
# Two paths, two digests, two grants. The authority to reconcile is not the
# authority to launch, and that is a property of which files exist.
entry = ENTRYPOINT.read_text(encoding='utf-8')
launch = Path('provisioning/execution/kyri-exec-transition-entrypoint.py').read_text()
assert '/usr/libexec/kyri-exec-reconcile' in entry
assert '/usr/libexec/kyri-exec-transition' not in entry
assert 'reconcile' not in launch.lower(), 'the launch entrypoint learned a verb'
# And the launch entrypoint still takes exactly two argv elements.
assert 'len(argv) != 2' in launch
assert 'len(argv) != 2' in entry
print('OK')
"

# --- the ordering, which is the security property ----------------------------------

run_case "the accepted order is authority, closure, drop, no_new_privs, exec" "${PRELUDE}
for account, uid, gid in DEPLOYMENTS:
    recorder, error = drive(account, uid, gid)
    assert error is None, error
    steps = order(recorder)
    for step in ('close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
                 'set_no_new_privs', 'get_no_new_privs', 'execve'):
        assert step in steps, (step, steps)
    # Each step spends privilege the next one needs, so the order is the rule.
    assert steps.index('close_extra_descriptors') < steps.index('setgroups')
    assert steps.index('setgroups') < steps.index('setgid')
    assert steps.index('setgid') < steps.index('setuid')
    # The drop is verified before no_new_privs is set, and no_new_privs is set
    # after the drop rather than before -- setting it while still root would set
    # it on the wrong process.
    assert steps.index('setuid') < steps.index('credentials')
    assert steps.index('credentials') < steps.index('set_no_new_privs')
    assert steps.index('set_no_new_privs') < steps.index('get_no_new_privs')
    # And nothing is executed until every one of them has happened.
    assert steps.index('get_no_new_privs') < steps.index('execve')
    assert steps[-1] == 'execve'
print('OK')
"

run_case "the identity it becomes is the deployment's, not a constant" "${PRELUDE}
for account, uid, gid in DEPLOYMENTS:
    recorder, error = drive(account, uid, gid)
    assert error is None, error
    calls = dict((call[0], call[1:]) for call in recorder.calls)
    assert calls['setuid'] == (uid,), calls['setuid']
    assert calls['setgid'] == (gid,), calls['setgid']
    assert calls['setgroups'] == ((gid,),), calls['setgroups']
    # The rootless environment handed to the worker follows the same identity.
    path, argv, environment = calls['execve']
    assert dict(environment)['XDG_RUNTIME_DIR'] == f'/run/user/{uid}'
    assert dict(environment)['HOME'] == policy.EXECUTION_HOME
    assert set(dict(environment)) == {'HOME', 'XDG_RUNTIME_DIR'}
    # And the terminal target is the reconcile worker, never the launch worker.
    assert path == policy.WORKER_INTERPRETER
    assert argv == (policy.WORKER_INTERPRETER,
                    '/usr/libexec/kyri-exec-reconcile-worker.py', 'CINV-000042')
    assert policy.WORKER_SCRIPT not in argv
print('OK')
"

run_case "an incomplete drop is refused in every component" "${PRELUDE}
C = action.Credentials
uid, gid = 2203, 2207
for creds, why in (
        (C(0, 0, 0, gid, gid, gid, (gid,)), 'a uid that did not drop'),
        (C(uid, uid, 0, gid, gid, gid, (gid,)), 'a saved uid still root'),
        (C(uid, 0, uid, gid, gid, gid, (gid,)), 'an effective uid still root'),
        (C(uid, uid, uid, 0, 0, 0, (0,)), 'a gid that did not drop'),
        (C(uid, uid, uid, gid, gid, 0, (gid,)), 'a saved gid still root'),
        (C(uid, uid, uid, gid, gid, gid, (gid, 0)), 'a surviving root group'),
        (C(uid, uid, uid, gid, gid, gid, ()), 'an emptied group set'),
        (C(999, 999, 999, gid, gid, gid, (gid,)), 'a drop to another identity')):
    recorder, error = drive('fixture-b', uid, gid, creds=creds)
    assert error is not None, (why, order(recorder))
    assert 'execve' not in order(recorder), (why, 'it executed anyway')
# no_new_privs that does not read back as set is equally terminal.
recorder, error = drive('fixture-b', uid, gid, nnp=0)
assert error is not None and 'execve' not in order(recorder)
# And a failure at any primitive stops before the exec.
for step in ('close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
             'set_no_new_privs', 'get_no_new_privs'):
    recorder, error = drive('fixture-b', uid, gid, fail_at=step)
    assert error is not None, step
    assert 'execve' not in order(recorder), step
print('OK')
"

run_case "reconciliation without root refuses before spending anything" "${PRELUDE}
who = identity()
plan = policy.reconciliation_policy_for(['prog', 'CINV-000042'], identity=who)
recorder = Recorder(999, 987)
try:
    action.perform_reconciliation(plan, backend=recorder, assume_root=False)
except policy.TransitionRefused:
    pass
else:
    raise AssertionError('it proceeded without root')
assert recorder.calls == [], recorder.calls
# And a policy object of the wrong type is refused rather than acted on: a
# launch policy carries a different terminal target and a wider descriptor list.
launch = policy.policy_for(['prog', 'CINV-000042'], identity=who)
try:
    action.perform_reconciliation(launch, backend=Recorder(999, 987),
                                  assume_root=True)
except policy.TransitionRefused:
    print('OK')
else:
    raise AssertionError('a launch policy was reconciled')
"

# --- the descriptor policy, derived rather than copied -----------------------------

run_case "reconciliation closes to three descriptors, and launch keeps four" "${PRELUDE}
# Descriptor 3 is on the launch list because the transition seals a profile
# object onto it. Reconciliation authors no profile and holds no protocol
# session, so there is nothing for a fourth descriptor to carry.
assert policy.RECONCILE_INHERITED_DESCRIPTORS == (0, 1, 2)
assert policy.INHERITED_DESCRIPTORS == (0, 1, 2, 3), 'launch policy narrowed'
assert policy.PROFILE_FD == 3
for account, uid, gid in DEPLOYMENTS:
    recorder, error = drive(account, uid, gid)
    closure = [c for c in recorder.calls if c[0] == 'close_extra_descriptors']
    assert len(closure) == 1, closure
    assert closure[0][1] == (0, 1, 2), closure
    assert policy.PROFILE_FD not in closure[0][1], 'the profile fd survived'
plan = policy.reconciliation_policy_for(['prog', 'CINV-000042'],
                                        identity=identity())
assert plan.inherited_descriptors == (0, 1, 2)
assert not hasattr(plan, 'profile_fd')
print('OK')
"

run_case "the closure really closes an extra inherited descriptor" "${PRELUDE}
# The recorder proves what was asked for; this proves the primitive the
# production backend supplies does it. A real descriptor beyond the allowlist
# is opened and the system backend's own closure is run against a copy of the
# accepted allowlist in a forked child, so this process keeps its own.
low = os.open('/dev/null', os.O_RDONLY)
extra = os.dup2(low, 17)   # deliberately beyond any governed allowlist
os.close(low)
read_end, write_end = os.pipe()
child = os.fork()
if child == 0:
    try:
        os.close(read_end)
        backend = action.SystemBackend()
        backend.close_extra_descriptors((0, 1, 2, write_end))
        try:
            os.fstat(extra)
            os.write(write_end, b'SURVIVED')
        except OSError:
            os.write(write_end, b'CLOSED')
    finally:
        os._exit(0)
os.close(write_end)
observed = os.read(read_end, 16)
os.close(read_end)
os.waitpid(child, 0)
os.close(extra)
assert observed == b'CLOSED', observed
print('OK')
"

# --- root Podman is unreachable ----------------------------------------------------

run_case "no privileged module can reach Podman or the reconciler" "${PRELUDE}
# Not a textual ban: the import graph of everything that runs while euid is 0.
RUNTIME_NAMES = {'kyri_exec_podman', 'kyri_exec_reconcile', 'subprocess',
                 'podman', 'docker'}
for path in (ENTRYPOINT, ACTION, TRANSITION):
    tree = ast.parse(path.read_text(encoding='utf-8'))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name.split('.')[0] not in RUNTIME_NAMES, \\
                    (str(path), alias.name)
        elif isinstance(node, ast.ImportFrom):
            assert (node.module or '').split('.')[0] not in RUNTIME_NAMES, \\
                (str(path), node.module)
# The entrypoint names exactly the two modules it loads, and neither starts a
# process. A module name taken from the caller would turn one authorised
# command into an arbitrary module loader, so they are literals.
tree = ast.parse(ENTRYPOINT.read_text(encoding='utf-8'))
named = {n.value for n in ast.walk(tree)
         if isinstance(n, ast.Constant) and isinstance(n.value, str)
         and n.value.startswith('kyri_exec_')}
assert named == {'kyri_exec_transition', 'kyri_exec_transition_action'}, named
print('OK')
"

run_case "the reconciler is reached only after the exec, in the worker" "${PRELUDE}
# The worker is the first thing that names the reconciler and the backend, and
# it exists only on the far side of execve -- which the ordering case above
# proves happens after the drop. So reconciliation as root is not a mistake
# this code can make; there is no route.
worker = RECONCILE_WORKER.read_text(encoding='utf-8')
tree = ast.parse(worker)
named = {n.value for n in ast.walk(tree)
         if isinstance(n, ast.Constant) and isinstance(n.value, str)
         and n.value.startswith('kyri_exec_')}
assert named == {'kyri_exec_transition', 'kyri_exec_transition_action',
                 'kyri_exec_reconcile', 'kyri_exec_podman'}, named
# The worker refuses root before it resolves anything at all.
functions = {f.name: f for f in ast.walk(tree) if isinstance(f, ast.FunctionDef)}
main = ast.unparse(functions['main'])
assert main.index('geteuid' if 'geteuid' in main else 'getuid') \\
    < main.index('backend_for'), 'the root check does not precede Podman'
assert 'must never run as root' in main
# It writes no Capability Runtime record and holds no store. Asserted from the
# import graph and the call graph rather than from a text scan: 'store' occurs
# inside 'storage' and inside this module's own explanation of what it does not
# do, and a substring search cannot tell those from a store handle.
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            assert not alias.name.startswith('tools.'), alias.name
    elif isinstance(node, ast.ImportFrom):
        assert not (node.module or '').startswith('tools.'), node.module
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(tree) if isinstance(n, ast.Call)}
for banned in ('CapabilityStore', 'record_terminal_result', 'record_invocation',
               'write_record', 'allocate'):
    assert banned not in called, banned
print('OK')
"

# --- the worker half ---------------------------------------------------------------

run_case "the reconcile worker reports absence and nothing else" "${PRELUDE}
tree = ast.parse(RECONCILE_WORKER.read_text(encoding='utf-8'))
functions = {f.name: f for f in ast.walk(tree) if isinstance(f, ast.FunctionDef)}
returns = [n for n in ast.walk(functions['main']) if isinstance(n, ast.Return)]
assert len(returns) == 1, ast.unparse(functions['main'])
# The exit status carries whether the container is gone, never merely whether
# the process finished.
assert 'final_absent' in ast.unparse(returns[0]), ast.unparse(returns[0])
# The identity is confirmed from the far side of the exec rather than trusted.
main = ast.unparse(functions['main'])
assert 'execution_identity' in main
assert 'identity.uid' in main and 'identity.gid' in main
print('OK')
"

# --- coherence with the reconciler this drives -------------------------------------

run_case "the entrypoint and the reconciler agree on the one input" "${PRELUDE}
reconciler = load('kyri_exec_reconcile',
                  Path('provisioning/execution/kyri-exec-reconcile.py'))
# Both grammars, over the same vectors. The entrypoint validates what it hands
# over and the worker revalidates what it acts on: two sides of a privilege
# boundary, each checking what it uses.
for bad in ('cinv-000042', 'CINV-00042', 'CINV-0000042', 'kyri-CINV-000042',
            'CINV-000042 ', '../CINV-000042', 'CINV-000042; rm -rf /', '',
            None, 42, ['CINV-000042']):
    refused = 0
    try:
        policy.reconciliation_policy_for(['prog', bad], identity=identity())
    except (policy.TransitionRefused, TypeError):
        refused += 1
    try:
        reconciler.validate_cinv(bad)
    except reconciler.ReconciliationRefused:
        refused += 1
    assert refused == 2, (bad, refused)
assert reconciler.container_name('CINV-000042') == 'kyri-CINV-000042'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution reconcile entrypoint validation passed.\n'
else
  printf 'Capability execution reconcile entrypoint validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
