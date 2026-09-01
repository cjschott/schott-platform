#!/usr/bin/env bash
set -Eeuo pipefail

# The coordinator's half of a governed execution: what it authorises, what it
# refuses, and what it does when the worker stops talking.
#
# UNPRIVILEGED AND ISOLATED. No sudo, no privileged helper, no Podman, no
# container, no production path. The children below are real forked processes
# exchanging real frames over real pipes -- so end of stream, process death and
# reaping are genuine -- but what they run is a scripted responder, not the
# worker, because the worker needs a privilege drop this suite must not perform.
#
# WHAT WAS MISSING BEFORE G11-AT
# ==============================
# Everything on this side. `protocol.encode` had no production caller at all:
# the worker consumed `start_now` and reported nothing, so the coordinator could
# authorise an execution and then learn nothing about it. `cli.py` called
# `prepare_invocation` with no adapter, because the only adapter implementation
# ran inside the worker, on the far side of the boundary. The seam existed and
# nothing could fill it.
#
# THE THREE PROPERTIES THIS SUITE EXISTS FOR
# ==========================================
#   * START IS AUTHORITY. `start_now` is reachable exactly once, only after a
#     verified profile that correlates to this invocation. Every earlier
#     ordering is refused by the protocol's own table rather than by a check
#     somebody remembered to write.
#
#   * DEATH IS NOT AN OUTCOME. End of stream says the worker stopped talking
#     and nothing about the container. It is never mapped to a terminal state;
#     it routes to reconciliation, and what reconciliation proves is reported.
#
#   * DISPOSAL IS PROVEN BEFORE A RESULT IS CONCLUDED. An execution whose
#     container cannot be proven absent yields no outcome at all, so no CRES is
#     written and the invocation stays where the readiness gate will find it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

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

PRELUDE="
import os, signal, sys, time
sys.path.insert(0, '.')

from tools.capability.execution import profile as P
from tools.capability.execution import protocol as PR
from tools.capability.execution import recovery as RC
from tools.capability.execution import supervision as SV
from tools.capability.execution.implementation_authority import Admission

CINV = 'CINV-000042'
CID = 'a' * 64
IMAGE = 'b' * 64

ADMISSION = Admission(
    cimp='CIMP-000001', oci_image_id=IMAGE, adapter_identity='python-podman-v1',
    payload_schema_version=1,
    execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
    argv_contract_identity='fixed-python-entrypoint-v1',
    provisioning_evidence_digest='b' * 64)
PROFILE = P.build_profile(P.ProfileBinding(
    cinv=CINV, admission=ADMISSION, payload_digest='c' * 64,
    package_digest='d' * 64, package_entrypoint='main.py'))
DIGEST = 'e' * 64
BINDING = SV.SupervisedBinding(cinv=CINV, profile=PROFILE, profile_digest=DIGEST)

def frame(kind, cinv=CINV, **fields):
    return PR.encode(PR.Message(kind=kind, cinv=cinv,
                                fields=tuple(fields.items())))

def created(cid=CID, cinv=CINV):
    return frame(PR.MessageKind.CREATED, cinv, container_id=cid)

def verified(cid=CID, cinv=CINV, **overrides):
    fields = dict(container_id=cid, profile_digest=DIGEST, oci_image_id=IMAGE,
                  cimp=PROFILE.cimp,
                  profile_schema_version=PROFILE.profile_schema_version,
                  execution_uid=PROFILE.execution_uid,
                  execution_gid=PROFILE.execution_gid)
    fields.update(overrides)
    return frame(PR.MessageKind.VERIFIED_PROFILE, cinv, **fields)

def started(cid=CID, cinv=CINV):
    return frame(PR.MessageKind.STARTED, cinv, container_id=cid)

def terminal(cid=CID, cinv=CINV, outcome_class='completed', exit_code=0,
             lifecycle_state='exited', started_proven=True):
    return frame(PR.MessageKind.TERMINAL, cinv, container_id=cid,
                 lifecycle_state=lifecycle_state, outcome_class=outcome_class,
                 exit_code=exit_code, started_proven=started_proven,
                 started_at='2026-09-01T06:00:00Z',
                 finished_at='2026-09-01T06:00:01Z')

def collected(digest='f' * 64, cinv=CINV):
    return frame(PR.MessageKind.COLLECTED, cinv, result_digest=digest,
                 output_manifest_digest=None, stdout_truncated=False,
                 stderr_truncated=False)

def error(detail='execution_protocol_violation', cinv=CINV):
    return frame(PR.MessageKind.ERROR, cinv, detail=detail)

HAPPY = [created(), verified(), started(), terminal(), collected()]

class Child:
    '''A real forked process exchanging real frames over real pipes.

    Scripted rather than the worker: the worker needs a privilege drop this
    suite must not perform. What is genuine is everything the supervisor
    actually depends on -- a descriptor that reaches end of stream when the peer
    dies, a process that must be waited for, and a kill that cannot be trapped.
    '''

    def __init__(self, before_start, after_start, *, die=None, linger=0.0):
        self.before_start, self.after_start = before_start, after_start
        self.die, self.linger = die, linger
        to_child_r, to_child_w = os.pipe()
        from_child_r, from_child_w = os.pipe()
        self.pid = os.fork()
        if self.pid == 0:
            try:
                os.close(to_child_w); os.close(from_child_r)
                self._be_the_worker(to_child_r, from_child_w)
            finally:
                os._exit(0)
        os.close(to_child_r); os.close(from_child_w)
        self._in, self._out = from_child_r, to_child_w
        self._buffer = bytearray()
        self.status = None

    def _be_the_worker(self, read_fd, write_fd):
        for item in self.before_start:
            os.write(write_fd, item)
        if self.die == 'before-start':
            os._exit(9)
        # A scripted child with nothing left to say ends the conversation
        # rather than waiting. A worker blocked on authority it will never be
        # granted, while the coordinator blocks on a message that will never
        # come, is a deadlock rather than a test.
        if not self.after_start and self.die != 'after-start':
            return
        # Block for the coordinator's authority, exactly as the worker does.
        pending = b''
        while b'\\n' not in pending:
            chunk = os.read(read_fd, 4096)
            if not chunk:
                os._exit(7)
            pending += chunk
        if self.die == 'after-start':
            os._exit(9)
        for item in self.after_start:
            os.write(write_fd, item)
        if self.linger:
            time.sleep(self.linger)

    def reader(self):
        while True:
            index = self._buffer.find(b'\\n')
            if index >= 0:
                item = bytes(self._buffer[:index + 1])
                del self._buffer[:index + 1]
                return item
            chunk = os.read(self._in, 4096)
            if not chunk:
                return None
            self._buffer.extend(chunk)

    def writer(self, item):
        os.write(self._out, item)

    def reap(self, timeout):
        for descriptor in (self._in, self._out):
            try:
                os.close(descriptor)
            except OSError:
                pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = status
                return status, True
            time.sleep(0.01)
        os.kill(self.pid, signal.SIGKILL)
        _, status = os.waitpid(self.pid, 0)
        return status, False


class Launcher:
    '''The one seam that starts a process, as the supervisor sees it.'''

    def __init__(self, before, after, **options):
        self.before, self.after, self.options = before, after, options
        self.launched = []

    def launch(self, cinv):
        self.launched.append(cinv)
        return Child(self.before, self.after, **self.options)


def reconciler(absent=True, outcome='removed-exited', raises=None):
    calls = []

    def call(cinv):
        calls.append(cinv)
        if raises is not None:
            raise raises
        return {'invocation_id': cinv, 'outcome': outcome,
                'prior_state': 'exited', 'container_identity_verified': True,
                'final_absent': absent, 'reason': None if absent else 'refused'}

    call.calls = calls
    return call


def supervise(before, after, *, absent=True, outcome='removed-exited',
              raises=None, binding=None, **options):
    launcher = Launcher(before, after, **options)
    clean = reconciler(absent=absent, outcome=outcome, raises=raises)
    supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=clean)
    try:
        return supervisor.execute(binding or BINDING), None, supervisor, clean
    except SV.SupervisionRefused as refusal:
        return None, refusal, supervisor, clean
"

# --- the accepted sequence ---------------------------------------------------------

run_case "a full supervised success concludes what the worker reported" "${PRELUDE}
outcome, refusal, supervisor, clean = supervise(HAPPY[:2], HAPPY[2:])
assert refusal is None, refusal
assert outcome.cinv == CINV and outcome.container_id == CID
assert outcome.outcome_class == 'completed', outcome.outcome_class
assert outcome.succeeded is True
assert outcome.result_digest == 'sha256:' + 'f' * 64, outcome.result_digest
assert outcome.started_proven is True
# The timings the record reads come from the runtime's own words.
assert outcome.terminal.started_at == '2026-09-01T06:00:00Z'
assert outcome.terminal.finished_at == '2026-09-01T06:00:01Z'
# The coordinator observed nothing: it holds no manifest and no output tree.
assert outcome.result is None and outcome.output is None
trace = supervisor.trace
assert trace.protocol_complete is True and trace.worker_reaped is True
assert trace.disposal_proven is True
assert trace.states == ('created', 'profile_verified', 'start_sent',
                        'started', 'terminal', 'collected'), trace.states
print('OK')
"

run_case "the outcome class is carried from T13, never recomputed" "${PRELUDE}
# A timeout is the case a recomputing supervisor could not see: the container
# exited with a code, and only the worker knows its own clock ran out.
for reported, exit_code in (('timeout', 137), ('provider-error', 3),
                            ('adapter-error', None), ('completed', 0)):
    outcome, refusal, _, _ = supervise(
        HAPPY[:2], [started(), terminal(outcome_class=reported,
                                        exit_code=exit_code), collected()])
    assert refusal is None, refusal
    assert outcome.outcome_class == reported, (reported, outcome.outcome_class)
print('OK')
"

run_case "exit zero with no admitted result is not success" "${PRELUDE}
outcome, refusal, _, _ = supervise(
    HAPPY[:2], [started(), terminal(), collected(digest=None)])
assert refusal is None, refusal
assert outcome.outcome_class == 'completed'
assert outcome.succeeded is False, 'a missing result read as success'
assert outcome.result_digest is None
print('OK')
"

# --- start authority ---------------------------------------------------------------

run_case "start is granted once, after the profile, and names the container" "${PRELUDE}
launcher = Launcher(HAPPY[:2], HAPPY[2:])
sent = []
clean = reconciler()
supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=clean)
original = SV.Channel.send
def recording(self, kind, **fields):
    sent.append((kind.value, fields))
    return original(self, kind, **fields)
SV.Channel.send = recording
try:
    supervisor.execute(BINDING)
finally:
    SV.Channel.send = original
# Exactly one message crosses to the worker in the whole exchange, and it is
# the authority-bearing one.
assert [kind for kind, _ in sent] == ['start_now'], sent
assert sent[0][1] == {'container_id': CID}, sent
print('OK')
"

run_case "the worker cannot start before it is authorised" "${PRELUDE}
# The channel's own table refuses it, so this is not a check the supervisor
# could forget: 'started' is simply not legal before 'start_now' was sent.
for premature in ([started()], [created(), started()],
                  [created(), verified(), started(), started()]):
    outcome, refusal, _, clean = supervise(premature, [])
    assert outcome is None and refusal is not None, premature
    assert clean.calls == [CINV], 'the container was not reconciled'
print('OK')
"

run_case "a profile verified for another invocation is refused" "${PRELUDE}
# Correlation, not shape. Every field below is well formed; each names
# something this invocation did not publish.
for label, message in (
        ('another profile digest', verified(profile_digest='9' * 64)),
        ('another image', verified(oci_image_id='9' * 64)),
        ('another implementation', verified(cimp='CIMP-000002')),
        ('another container identity', verified(cid='9' * 64)),
        ('another execution identity', verified(execution_uid=1234)),
        ('another execution group', verified(execution_gid=1234))):
    outcome, refusal, _, _ = supervise([created(), message], HAPPY[2:])
    assert outcome is None, label
    assert refusal is not None, label
print('OK')
"

run_case "a message naming another invocation is refused" "${PRELUDE}
outcome, refusal, _, _ = supervise([created(cinv='CINV-000099')], [])
assert outcome is None and refusal is not None
outcome, refusal, _, _ = supervise([created(), verified(cinv='CINV-000099')], [])
assert outcome is None and refusal is not None
print('OK')
"

# --- the protocol negative matrix ---------------------------------------------------

run_case "every malformed or out-of-order conversation is refused" "${PRELUDE}
cases = {
    'malformed JSON': [b'{not json}\\n'],
    'a frame with no newline': [b'{}'],
    'an oversized frame': [b'{' + b'x' * (64 * 1024) + b'}\\n'],
    'an unknown kind': [b'{\"cinv\":\"CINV-000042\",\"kind\":\"nope\",'
                        b'\"protocol_version\":1}\\n'],
    'an unknown field': [b'{\"cinv\":\"CINV-000042\",\"kind\":\"created\",'
                         b'\"protocol_version\":1,\"container_id\":\"'
                         + b'a' * 64 + b'\",\"extra\":1}\\n'],
    'a duplicate created': [created(), created()],
    'verified before created': [verified()],
    'a duplicate verified': [created(), verified(), verified()],
    'terminal before started': [created(), verified(), terminal()],
    'a duplicate terminal': [created(), verified()],
    'collected before terminal': [created(), verified()],
    'nothing at all': [],
}
after = {
    'a duplicate terminal': [started(), terminal(), terminal()],
    'collected before terminal': [started(), collected()],
}
for label, before in cases.items():
    outcome, refusal, supervisor, clean = supervise(
        before, after.get(label, []))
    assert outcome is None, (label, 'was accepted')
    assert refusal is not None, label
    # Every refusal reconciles, because none of them establishes the
    # container's fate -- which is the whole reason the conversation mattered.
    assert clean.calls == [CINV], (label, clean.calls)
    assert supervisor.trace.protocol_complete is False, label
    assert supervisor.trace.worker_reaped is True, (label, 'a zombie survived')
# A duplicate collected is refused by the table rather than by the
# supervisor, which stops reading once the conversation is complete. Asserted
# where the rule actually lives: a supervisor that read on would be looking for
# messages the protocol says cannot exist.
channel = PR.Channel(CINV, reader=iter(
    [created(), verified(), started(), terminal(), collected(),
     collected()]).__next__, writer=lambda frame: None)
for kind in (PR.MessageKind.CREATED, PR.MessageKind.VERIFIED_PROFILE):
    channel.receive()
channel.send(PR.MessageKind.START_NOW, container_id=CID)
for kind in (PR.MessageKind.STARTED, PR.MessageKind.TERMINAL,
             PR.MessageKind.COLLECTED):
    channel.receive()
try:
    channel.receive()
except PR.ProtocolViolation:
    pass
else:
    raise AssertionError('a duplicate collected was legal')
print('OK')
"

run_case "end of stream at every state is a death, not an outcome" "${PRELUDE}
prefixes = ([], [created()], [created(), verified()])
for before in prefixes:
    outcome, refusal, supervisor, clean = supervise(before, [])
    assert outcome is None and refusal is not None
    # Never mapped to a terminal state. The refusal carries no classification
    # claiming the workload did or did not run.
    assert refusal.classification is None, refusal.classification
    assert clean.calls == [CINV]
# And after the start was granted, which is the case that matters most.
outcome, refusal, supervisor, clean = supervise(HAPPY[:2], [started()])
assert outcome is None and refusal is not None
assert clean.calls == [CINV]
assert supervisor.trace.states[-1] == 'started', supervisor.trace.states
print('OK')
"

run_case "a worker that reports an error is believed, not reinterpreted" "${PRELUDE}
outcome, refusal, _, clean = supervise(
    [created(), verified()], [started(), error(detail='result_missing')])
assert outcome is None and refusal is not None
assert refusal.classification is not None
assert refusal.classification.value == 'result_missing', refusal.classification
assert clean.calls == [CINV]
print('OK')
"

# --- process ownership --------------------------------------------------------------

run_case "the worker process is always reaped, and never becomes a zombie" "${PRELUDE}
for before, after, options in (
        (HAPPY[:2], HAPPY[2:], {}),
        ([created()], [], {'die': 'before-start'}),
        (HAPPY[:2], [], {'die': 'after-start'})):
    outcome, refusal, supervisor, _ = supervise(before, after, **options)
    trace = supervisor.trace
    assert trace.worker_reaped is True, options
    assert trace.worker_exit is not None, options
    # And there is nothing left to wait for: a second wait finds no child,
    # which is what no-zombie means as a fact rather than as a claim.
    try:
        assert os.waitpid(-1, os.WNOHANG) == (0, 0)
    except ChildProcessError:
        pass
print('OK')
"

run_case "a worker that outlives the bound is killed and still reaped" "${PRELUDE}
saved = SV.REAP_TIMEOUT_SECONDS
SV.REAP_TIMEOUT_SECONDS = 0.2
try:
    outcome, refusal, supervisor, clean = supervise(
        HAPPY[:2], HAPPY[2:], linger=5.0)
finally:
    SV.REAP_TIMEOUT_SECONDS = saved
# The conversation completed, so the facts are there -- but the process did not
# end on its own, and an unreaped worker is not a concluded execution.
assert outcome is None, 'a stuck worker was concluded'
assert refusal is not None
assert supervisor.trace.worker_reaped is False
assert clean.calls == [CINV], 'a stuck worker was not reconciled'
print('OK')
"

run_case "the exit status is never mistaken for an outcome" "${PRELUDE}
# A worker that exits non-zero after a clean conversation still succeeded, and
# a worker that exits zero after saying nothing still did not.
outcome, refusal, supervisor, _ = supervise(HAPPY[:2], HAPPY[2:])
assert refusal is None and outcome.succeeded is True
assert supervisor.trace.worker_exit == 0
outcome, refusal, supervisor, _ = supervise([], [])
assert outcome is None and refusal is not None
assert supervisor.trace.worker_exit == 0, supervisor.trace.worker_exit
print('OK')
"

# --- disposal ------------------------------------------------------------------------

run_case "every execution proves its container gone before concluding" "${PRELUDE}
outcome, refusal, _, clean = supervise(HAPPY[:2], HAPPY[2:])
assert refusal is None
# Success included. A report that the container was cleaned is a claim; an
# operation that looked is evidence, and reconciliation is idempotent so this
# costs nothing where nothing is left.
assert clean.calls == [CINV], clean.calls
print('OK')
"

run_case "an unproven disposal yields no outcome at all" "${PRELUDE}
# The stop condition made structural: a result recorded beside a container that
# might still be running is the one thing this boundary exists to prevent, so
# there is no outcome to record.
outcome, refusal, supervisor, _ = supervise(
    HAPPY[:2], HAPPY[2:], absent=False, outcome='refused')
assert outcome is None, 'a result was concluded over an unproven container'
assert refusal is not None
assert supervisor.trace.disposal_proven is False
assert supervisor.trace.protocol_complete is True, \\
    'the conversation itself was fine; only the disposal was not'
# And a reconciler that could not run at all is the same answer.
outcome, refusal, supervisor, _ = supervise(
    HAPPY[:2], HAPPY[2:], raises=OSError('the helper is not installed'))
assert outcome is None and refusal is not None
assert supervisor.trace.disposal_proven is False
print('OK')
"

# --- what the supervisor is not -------------------------------------------------------

run_case "the supervisor starts no process and holds no runtime authority" "${PRELUDE}
import ast
from pathlib import Path
source = Path('tools/capability/execution/supervision.py')
tree = ast.parse(source.read_text(encoding='utf-8'))
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
BANNED = {'subprocess', 'os', 'sys', 'ctypes', 'socket', 'signal', 'fcntl',
          'multiprocessing', 'importlib', 'runpy', 'shutil', 'tempfile'}
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            assert alias.name.split('.')[0] not in BANNED, alias.name
    elif isinstance(node, ast.ImportFrom):
        assert (node.module or '').split('.')[0] not in BANNED, node.module
lowered = ast.unparse(tree).lower()
for token in ('podman', 'docker', 'popen', 'execve', 'fork', '/usr/libexec',
              'sudo', 'container_name', 'create_argv'):
    assert token not in lowered, token
# It never writes a record either: the coordinator keeps result authority.
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(tree) if isinstance(n, ast.Call)}
for banned in ('record_terminal_result', 'record_invocation', 'allocate_id',
               'write_atomic', 'CapabilityStore'):
    assert banned not in called, banned
print('OK')
"

run_case "the launcher's privileged interface carries one CINV and nothing else" "${PRELUDE}
import ast, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location(
    'kyri_exec_launcher', 'provisioning/execution/kyri-exec-launcher.py')
launcher = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_launcher'] = launcher
spec.loader.exec_module(launcher)

assert launcher.PERMITTED_HELPERS == {
    '/usr/libexec/kyri-exec-transition', '/usr/libexec/kyri-exec-reconcile'}
for helper in launcher.PERMITTED_HELPERS:
    argv = launcher._argv(helper, CINV)
    assert argv == ['/usr/bin/sudo', '-n', helper, CINV], argv
for ungoverned in ('/usr/libexec/kyri-exec-verify', '/bin/sh', 'podman', ''):
    try:
        launcher._argv(ungoverned, CINV)
    except launcher.LauncherRefused:
        continue
    raise AssertionError(f'accepted helper {ungoverned!r}')
for bad in ('cinv-000042', 'CINV-00042', 'kyri-CINV-000042', 'CINV-000042 ',
            '../CINV-000042', 'CINV-000042; rm -rf /', '', None, 42):
    try:
        launcher._require_cinv(bad)
    except launcher.LauncherRefused:
        continue
    raise AssertionError(f'accepted identity {bad!r}')
# No shell anywhere, and every process call states its controls.
tree = ast.parse(Path('provisioning/execution/kyri-exec-launcher.py')
                 .read_text(encoding='utf-8'))
starts = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
          and getattr(n.func, 'attr', None) in ('Popen', 'run')]
assert len(starts) == 2, len(starts)
for call in starts:
    keywords = {k.arg for k in call.keywords}
    assert 'shell' in keywords and 'env' in keywords, ast.unparse(call)[:80]
    assert 'False' in ast.unparse(call), 'shell is not disabled'
print('OK')
"

# --- recovery and readiness ------------------------------------------------------------

RECOVERY_PRELUDE="${PRELUDE}
class Store:
    '''The two record kinds and nothing else. Reads only.'''

    def __init__(self, invocations, results):
        self._records = {'capability-invocation': invocations,
                         'capability-result': results}
        self.reads = 0
        self.writes = 0

    def list_records(self, kind):
        self.reads += 1
        return list(self._records.get(kind, ()))

    def allocate_id(self, kind):
        self.writes += 1
        raise AssertionError('recovery allocated an identity')

    def write_atomic(self, *args, **kwargs):
        self.writes += 1
        raise AssertionError('recovery wrote a record')

def invocation(record_id, cinv, adapter='python-podman-v1'):
    return {'invocation_record_id': record_id, 'invocation_id': cinv,
            'adapter_identity': adapter}

def result(record_id):
    return {'invocation_record_id': record_id, 'attempt_number': 1}
"

run_case "an invocation with an adapter and no result is unresolved" "${RECOVERY_PRELUDE}
store = Store(
    [invocation('CINV-000001', 'inv-1'),
     invocation('CINV-000002', 'inv-2'),
     # Nothing was authorised to run, so there is no container it could leave.
     invocation('CINV-000003', 'inv-3', adapter=None)],
    [result('CINV-000002')])
found = RC.unresolved_invocations(store)
assert [u.invocation_record_id for u in found] == ['CINV-000001'], found
assert found[0].invocation_id == 'inv-1'
assert store.writes == 0
print('OK')
"

run_case "recovery reconciles each unresolved invocation by CINV alone" "${RECOVERY_PRELUDE}
store = Store([invocation('CINV-000001', 'inv-1'),
               invocation('CINV-000004', 'inv-4')], [])
clean = reconciler(outcome='absent')
findings = RC.reconcile_unresolved(store, reconciler=clean)
assert clean.calls == ['inv-1', 'inv-4'], clean.calls
assert all(f.final_absent for f in findings)
assert all(f.interrupted for f in findings), 'a lost execution was resolved'
assert {f.disposition for f in findings} == {'absent'}
# Absence it had to establish is reported differently from absence it found.
recovered = RC.reconcile_unresolved(store, reconciler=reconciler(
    outcome='stopped-and-removed'))
assert {f.disposition for f in recovered} == {'reconciled'}
assert store.writes == 0, 'recovery mutated the store'
print('OK')
"

run_case "recovery synthesises no result and advances nothing" "${RECOVERY_PRELUDE}
store = Store([invocation('CINV-000001', 'inv-1')], [])
before = list(store.list_records('capability-result'))
RC.reconcile_unresolved(store, reconciler=reconciler())
assert list(store.list_records('capability-result')) == before
assert store.writes == 0
print('OK')
"

run_case "a second recovery pass is harmless" "${RECOVERY_PRELUDE}
store = Store([invocation('CINV-000001', 'inv-1')], [])
clean = reconciler(outcome='stopped-and-removed')
first = RC.reconcile_unresolved(store, reconciler=clean)
# The second pass sees an already-absent container, which reconciliation
# reports as success without touching anything.
again = reconciler(outcome='absent')
second = RC.reconcile_unresolved(store, reconciler=again)
assert [f.final_absent for f in first] == [True]
assert [f.final_absent for f in second] == [True]
assert [f.disposition for f in second] == ['absent']
assert store.writes == 0
print('OK')
"

run_case "execution is unsafe while any container state is unknown" "${RECOVERY_PRELUDE}
store = Store([invocation('CINV-000001', 'inv-1')], [])
safe = RC.execution_safety(store, reconciler=reconciler())
assert safe.state == RC.READY and safe.ready is True
assert safe.unresolved == () and safe.checked == 1

blocked = RC.execution_safety(
    store, reconciler=reconciler(absent=False, outcome='refused'))
assert blocked.state == RC.NOT_READY, blocked.state
assert blocked.ready is False
assert len(blocked.unresolved) == 1
assert blocked.unresolved[0].interrupted is True

# A helper that cannot run at all is unknown, not absent.
missing = RC.execution_safety(
    store, reconciler=reconciler(raises=OSError('no such helper')))
assert missing.state == RC.NOT_READY
assert 'reconciliation did not complete' in missing.unresolved[0].reason

# And an empty platform is ready, because nothing is unproven.
assert RC.execution_safety(Store([], []),
                              reconciler=reconciler()).state == RC.READY
print('OK')
"

run_case "recovery enumerates records, never containers" "${RECOVERY_PRELUDE}
import ast
from pathlib import Path
tree = ast.parse(Path('tools/capability/execution/recovery.py')
                 .read_text(encoding='utf-8'))
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
for token in ('podman', 'container_name', 'list_containers', 'ps', 'subprocess',
              'record_terminal_result', 'write_atomic', 'allocate_id'):
    assert token not in lowered, token
# The only outside call it makes is the injected reconciler, over a CINV.
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(tree) if isinstance(n, ast.Call)}
assert 'reconciler' in called, called
print('OK')
"

# --- helper and runtime compatibility --------------------------------------------------

run_case "the runtime declares the helper bytes it supervises through" "${PRELUDE}
import hashlib
from pathlib import Path
from tools.capability.execution import helpers as H

# The declaration is held to the sources it names. A digest table that could
# drift from its own sources would be a compatibility check that reports
# agreement with itself.
declared = {helper.path: helper.digest for helper in H.REQUIRED_HELPERS}
assert set(declared) == set(H.HELPER_SOURCES), (declared, H.HELPER_SOURCES)
for path, source in H.HELPER_SOURCES.items():
    observed = hashlib.sha256(Path(source).read_bytes()).hexdigest()
    assert declared[path] == observed, (path, source, 'the declaration is stale')
# The whole supervised privileged surface, and nothing that is not on it.
assert set(declared) == {
    '/usr/libexec/kyri-exec-transition', '/usr/libexec/kyri-exec-worker.py',
    '/usr/libexec/kyri-exec-reconcile',
    '/usr/libexec/kyri-exec-reconcile-worker.py'}, declared
print('OK')
"

run_case "a stale or absent helper is never reported compatible" "${PRELUDE}
import os
from pathlib import Path
from tools.capability.execution import helpers as H

work = Path(os.environ['WORKDIR']) / 'helpers'
work.mkdir(parents=True, exist_ok=True)
current = work / 'current'
current.write_bytes(b'the reviewed bytes')
stale = work / 'stale'
stale.write_bytes(b'some other bytes')
import hashlib
digest = hashlib.sha256(b'the reviewed bytes').hexdigest()

def required(path):
    return (H.RequiredHelper(path=str(path), digest=digest, purpose='fixture'),)

assert H.compatibility(required(current)).verdict == H.COMPATIBLE
for path, expected in ((stale, H.STATE_STALE),
                       (work / 'never-installed', H.STATE_ABSENT)):
    verdict = H.compatibility(required(path))
    assert verdict.verdict == H.INCOMPATIBLE, path
    assert verdict.compatible is False
    assert [h.state for h in verdict.helpers] == [expected], path
    assert len(verdict.blocking) == 1
# One current object does not carry a stale one: a supervision path is only as
# current as the object in it that is furthest behind.
mixed = H.compatibility(required(current) + required(stale))
assert mixed.verdict == H.INCOMPATIBLE
assert [h.state for h in mixed.helpers] == [H.STATE_CURRENT, H.STATE_STALE]
print('OK')
"

run_case "this host is truthfully not ready to supervise" "${PRELUDE}
from tools.capability.cli import _supervision_outlook

# The accepted state of schai right now, reported rather than assumed: the
# identity authorities are not installed, the helpers are stale or absent, and
# the sudoers namespace is one this surface may not read.
report = _supervision_outlook()
assert report['supervision_ready'] is False
assert report['helper_compatibility'] == 'incompatible', report
assert report['helpers_blocking'], 'nothing was named as blocking'
for helper in report['helpers_blocking']:
    assert helper['state'] in ('stale', 'absent', 'unreadable'), helper
    assert helper['purpose'], 'a blocking helper was named without a reason'
# Unobservable is not false. The coordinator may not read the elevation
# namespace, and claiming a verdict about it would be claiming to have looked.
assert report['launch_grant'] == 'unobservable'
assert report['reconcile_grant'] == 'unobservable'
print('OK')
"

run_case "the preflight mutates nothing and starts nothing" "${PRELUDE}
import ast
from pathlib import Path
source = Path('tools/capability/cli.py').read_text(encoding='utf-8')
tree = ast.parse(source)
functions = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
outlook = functions['_supervision_outlook']
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(outlook) if isinstance(n, ast.Call)}
for banned in ('launch', 'reconcile', 'execute', 'record_invocation',
               'record_terminal_result', 'allocate_id', 'write_atomic',
               'materialise', 'Popen', 'run', 'mkdir', 'makedirs', 'open'):
    assert banned not in called, (banned, called)
# It reads two authorities, asks for helper compatibility, and stops.
assert 'read_execution_identity' in called, called
assert 'compatibility' in called, called
print('OK')
"

run_case "the released execute verb takes one CINV and chooses nothing" "${PRELUDE}
from tools.capability import cli
parser = cli.build_parser()
actions = [a for a in parser._subparsers._group_actions][0].choices
assert 'execute' in actions, sorted(actions)
options = set()
for action in actions['execute']._actions:
    options.update(action.option_strings)
assert '--cinv' in options, options
for banned in ('--adapter', '--backend', '--execution-binding', '--image',
               '--argv', '--container', '--profile', '--uid', '--gid'):
    assert banned not in options, banned
print('OK')
"

run_case "the coordinator keeps result authority on the supervised path" "${PRELUDE}
import ast
from pathlib import Path
tree = ast.parse(Path('tools/capability/coordinator.py').read_text(encoding='utf-8'))
functions = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
supervised = functions['execute_supervised']
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(supervised) if isinstance(n, ast.Call)}
# It writes the terminal result and nothing else: no second preparation, no
# invocation record, and no edit to the immutable pre-execution evidence.
assert 'record_terminal_result' in called, called
for banned in ('record_invocation', 'prepare_invocation', 'resolve_and_stage_package',
               'verify_selected_evidence', 'bind'):
    assert banned not in called, banned
# The CLI reaches the coordinator for this, never the record writer directly.
cli_tree = ast.parse(Path('tools/capability/cli.py').read_text(encoding='utf-8'))
cli_functions = {n.name: n for n in ast.walk(cli_tree)
                 if isinstance(n, ast.FunctionDef)}
execute = cli_functions['command_execute']
cli_called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
              for n in ast.walk(execute) if isinstance(n, ast.Call)}
assert 'execute_supervised' in cli_called, cli_called
assert 'record_terminal_result' not in cli_called, cli_called
print('OK')
"

run_case "the wire vocabulary is exactly what T13 can conclude" "${PRELUDE}
from tools.capability.execution import lifecycle as L
from tools.capability import records

# Narrower than the released set on purpose: three released classes are
# conclusions reached elsewhere and are not the worker's to claim, so there is
# no field value that could carry one.
reachable = set(L._OUTCOME.values())
assert PR._OUTCOME_CLASSES == reachable, (PR._OUTCOME_CLASSES, reachable)
assert PR._OUTCOME_CLASSES < set(records.OUTCOME_CLASSES)
for unreachable in ('refused', 'cancelled', 'serialisation-failure'):
    assert unreachable not in PR._OUTCOME_CLASSES, unreachable
    try:
        terminal(outcome_class=unreachable)
    except PR.ProtocolViolation:
        continue
    raise AssertionError(f'a worker could report {unreachable}')
# And the lifecycle words are the same closed set on both sides.
assert set(L._VALID_STATES) == {
    'created', 'running', 'exited', 'stopped', 'paused', 'unknown'}
for word in L._VALID_STATES:
    terminal(lifecycle_state=word)
try:
    terminal(lifecycle_state='configured')
except PR.ProtocolViolation:
    pass
else:
    raise AssertionError('an unrecognised lifecycle word was accepted')
print('OK')
"

run_case "a coordinator that dies before disposal leaves no result" "${PRELUDE}
import ast
from pathlib import Path
# The coordinator-death model, made structural. There is exactly one point at
# which a terminal result becomes durable, and it is after the supervisor has
# returned -- which it only does after disposal was proven. So a coordinator
# killed at any earlier instant leaves a CINV carrying an adapter identity and
# no CRES, which is precisely what the recovery enumeration looks for.
tree = ast.parse(Path('tools/capability/coordinator.py').read_text(encoding='utf-8'))
functions = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
supervised = functions['execute_supervised']
lines = {}
for node in ast.walk(supervised):
    if isinstance(node, ast.Call):
        name = getattr(node.func, 'attr', None) or getattr(node.func, 'id', None)
        if name in ('execute', 'record_terminal_result'):
            lines.setdefault(name, node.lineno)
assert lines['execute'] < lines['record_terminal_result'], lines

# And inside the supervisor, disposal precedes every return of an outcome.
tree = ast.parse(Path('tools/capability/execution/supervision.py').read_text(
    encoding='utf-8'))
functions = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
body = functions['execute']
dispose = [n.lineno for n in ast.walk(body) if isinstance(n, ast.Call)
           and (getattr(n.func, 'attr', None) == '_dispose')]
conclude = [n.lineno for n in ast.walk(body) if isinstance(n, ast.Call)
            and (getattr(n.func, 'attr', None) == '_conclude')]
assert dispose and conclude, (dispose, conclude)
assert max(dispose) < min(conclude), (dispose, conclude)
returns = [n.lineno for n in ast.walk(body) if isinstance(n, ast.Return)]
assert all(line > max(dispose) for line in returns), (returns, dispose)
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution supervision validation passed.\n'
else
  printf 'Capability execution supervision validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
