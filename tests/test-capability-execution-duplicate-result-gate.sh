#!/usr/bin/env bash
set -Eeuo pipefail

# The duplicate-result gate, and the boundary it must sit in front of.
#
# UNPRIVILEGED AND HOST-INDEPENDENT. Every store is a temporary directory. No
# production store, no Fabric, no Trust, no handoff, no helper, no container,
# no sudo. The launcher and reconciler are recording stubs that perform nothing.
#
# WHAT THIS GUARDS
# ================
# `ExecutionSupervisor.execute` launches the privileged helper on its FIRST
# line. Everything after -- the transition action, the container, the handoff
# ownership transfer, the provider itself -- is a side effect nothing can take
# back. `record_terminal_result` has always refused a second result, but it runs
# after all of that, so a re-execute of a resolved CINV would run the workload
# again and only then decline to write it down.
#
# G11-BC-I found that on CINV-000002. The cases below are the invariant:
#
#   once an invocation has a governed terminal result, another execute request
#   for that CINV refuses BEFORE any provider-visible side effect
#
# The recording launcher is how that is proven rather than asserted: if the gate
# is late, `launch` is called, and the call is on disk to show for it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

run_case() {                                  # <description> <python program>
  local description="$1" program="$2"
  if OUTPUT="$(cd "${ROOT}" && python3 -c "${program}" 2>&1)"; then
    pass "${description}"
  else
    fail "${description}: ${OUTPUT}"
  fi
}

PRELUDE="
import sys, os, json, pathlib
from datetime import datetime, timezone, timedelta
sys.path.insert(0, '${ROOT}')
from tools.capability.store import CapabilityStore
from tools.capability.coordinator import execute_supervised
from tools.capability import evidence as E
from tools.capability.errors import CapabilityError
from tools.capability.execution.supervision import (ExecutionSupervisor,
                                                    SupervisedBinding)

CENTRAL = timezone(timedelta(hours=-5))
WHEN = datetime(2026, 9, 14, 9, 0, 0, tzinfo=CENTRAL)

# The two production records, in the shape the live store holds them.
def invocation(cinv):
    return {
        'kind': 'capability-invocation', 'schema_version': 2,
        'invocation_record_id': cinv, 'invocation_id': 'fixture-' + cinv,
        'request_id': 'fixture-request', 'actor': 'primary-platform-operator',
        'operation': 'execute', 'effect_class': 'computational',
        'capability_id': 'CAPDEF-0001', 'contract_id': 'CCON-0001',
        'capability_package_id': 'CPKG-0001',
        'selection_id': 'CSEL-000003', 'instance_id': 'CINST-000004',
        'adapter_identity': None,
        'payload_digest': 'sha256:' + '0' * 64,
        'binding_digest': 'sha256:' + '1' * 64,
        'artifact_digest': 'sha256:' + '2' * 64,
        'staged_path': '/nowhere', 'requested_at': WHEN,
        'evidence': {'actor': 'primary-platform-operator',
                     'outcome': 'execution-prepared'},
    }

def result(cres, cinv, *, outcome='provider-error', attempt=1):
    return {
        'kind': 'capability-result', 'schema_version': 2,
        'capability_result_id': cres, 'invocation_record_id': cinv,
        'attempt_number': attempt, 'outcome_class': outcome,
        'reason': None if outcome == 'completed' else outcome,
        'result_digest': None, 'result_artifact_reference': None,
        'started_at': None, 'ended_at': None, 'recorded_at': WHEN,
        'evidence': {'actor': 'primary-platform-operator', 'outcome': outcome},
    }

def build(root, invocations=(), results=()):
    '''A runtime store holding exactly these records.'''
    store = CapabilityStore(root, expected_uid=os.getuid(), expected_gid=os.getgid())
    for record in invocations:
        store.write_atomic(
            store.path_for('capability-invocation', record['invocation_record_id']),
            record)
    for record in results:
        store.write_atomic(
            store.path_for('capability-result', record['capability_result_id']),
            record)
    return store

class Recorder:
    '''A launcher and reconciler that perform nothing and remember everything.

    Every method here stands for a boundary the gate must sit in FRONT of.
    Calling any of them is the failure the RED case exists to show, so none of
    them does real work -- launch raises the moment it is reached, which is
    already too late.
    '''
    def __init__(self):
        self.calls = []
    def launch(self, cinv):
        self.calls.append('launch:' + str(cinv))
        raise AssertionError('the privileged helper was launched')
    def reconcile(self, cinv):
        self.calls.append('reconcile:' + str(cinv))
        return {'cinv': cinv}

def attempt(store, cinv):
    '''One execute request. Returns (refusal-or-None, recorded calls).'''
    recorder = Recorder()
    supervisor = ExecutionSupervisor(launcher=recorder, reconciler=recorder.reconcile)
    binding = SupervisedBinding(cinv=cinv, profile=None, profile_digest='f' * 64)
    try:
        execute_supervised(
            store, invocation_record_id=cinv, invocation_id=cinv,
            supervisor=supervisor, binding=binding,
            actor='primary-platform-operator', recorded_at=WHEN)
    except BaseException as error:
        return error, recorder.calls
    return None, recorder.calls
"

# ===========================================================================
# A. the invariant -- refusal happens before every side-effect boundary
# ===========================================================================

run_case "a resolved CINV refuses, and the privileged helper is never launched" "${PRELUDE}
store = build('${WORK}/a', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002')])
error, calls = attempt(store, 'CINV-000002')
assert error is not None, 'the second execute was permitted'
assert isinstance(error, E.TerminalResultExists), type(error).__name__
assert 'CRES-000001' in str(error), str(error)
# THE assertion. Not 'it refused' -- 'it refused before anything ran'.
assert calls == [], 'boundaries reached before the refusal: ' + repr(calls)
"

run_case "the refusal allocates no second result and leaves the store untouched" "${PRELUDE}
import hashlib
store = build('${WORK}/a2', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002')])
def snapshot():
    return sorted((p.name, hashlib.sha256(p.read_bytes()).hexdigest())
                  for p in pathlib.Path('${WORK}/a2').rglob('*.yaml'))
before = snapshot()
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, E.TerminalResultExists)
assert snapshot() == before, 'the refusal changed a record'
results = list(pathlib.Path('${WORK}/a2/capability-results').glob('*.yaml'))
assert len(results) == 1, [p.name for p in results]
"

run_case "the refusal does not invoke reconciliation" "${PRELUDE}
store = build('${WORK}/a3', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002')])
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, E.TerminalResultExists)
assert not any(c.startswith('reconcile') for c in calls), calls
"

# ===========================================================================
# B. the matrix
# ===========================================================================

# A. launch_authorized, no CRES -> execution may proceed. Proven by the gate
# letting the call through to the launcher, which is exactly the boundary the
# other cases require it never to reach.
run_case "matrix A: an unresolved CINV is not blocked -- the gate passes it to the launcher" "${PRELUDE}
store = build('${WORK}/b-a', [invocation('CINV-000003')], [])
error, calls = attempt(store, 'CINV-000003')
assert calls == ['launch:CINV-000003'], calls
assert not isinstance(error, E.TerminalResultExists), 'the gate blocked a first execution'
"

run_case "matrix B: a final SUCCESSFUL result refuses before the provider" "${PRELUDE}
store = build('${WORK}/b-b', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002', outcome='completed')])
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, E.TerminalResultExists), type(error).__name__
assert calls == [], calls
"

run_case "matrix C: a final provider-error result refuses before the provider" "${PRELUDE}
store = build('${WORK}/b-c', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002', outcome='provider-error')])
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, E.TerminalResultExists), type(error).__name__
assert calls == [], calls
"

# D. Malformed linkage. list_records SKIPS a file that is not a mapping, which
# is right for listing and fail-open here -- a corrupted CRES would vanish and
# the gate would answer 'no result' for an invocation that has one.
run_case "matrix D: an unreadable result record fails closed, not open" "${PRELUDE}
store = build('${WORK}/b-d', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002')])
pathlib.Path('${WORK}/b-d/capability-results/CRES-000002.yaml').write_text(
    '- this file is a list, not a record\n')
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, CapabilityError), type(error).__name__
assert 'unreadable' in str(error), str(error)
assert calls == [], calls
"

run_case "matrix E: a result naming ANOTHER invocation does not block this one" "${PRELUDE}
store = build('${WORK}/b-e', [invocation('CINV-000003')],
              [result('CRES-000001', 'CINV-000002')])
error, calls = attempt(store, 'CINV-000003')
assert calls == ['launch:CINV-000003'], calls
assert not isinstance(error, E.TerminalResultExists), 'a foreign result blocked CINV-000003'
"

run_case "matrix F: two terminal results for one invocation fail closed as corruption" "${PRELUDE}
store = build('${WORK}/b-f', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002'),
               result('CRES-000002', 'CINV-000002')])
error, calls = attempt(store, 'CINV-000002')
assert isinstance(error, CapabilityError), type(error).__name__
assert 'corrupt' in str(error), str(error)
assert calls == [], calls
"

# G. The result namespace claims more than it can produce. Same fail-closed
# path as D, reached by a file that cannot be parsed at all rather than one
# that parses to the wrong shape.
run_case "matrix G: a result file that will not parse fails closed" "${PRELUDE}
store = build('${WORK}/b-g', [invocation('CINV-000002')], [])
pathlib.Path('${WORK}/b-g/capability-results/CRES-000001.yaml').write_text(
    'this: [is: not: valid: yaml\n')
error, calls = attempt(store, 'CINV-000002')
assert error is not None, 'a damaged result namespace was treated as empty'
assert calls == [], calls
"

run_case "matrix H: an unrelated later result is not a false positive" "${PRELUDE}
store = build('${WORK}/b-h',
              [invocation('CINV-000003'), invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002'),
               result('CRES-000002', 'CINV-000001')])
error, calls = attempt(store, 'CINV-000003')
assert calls == ['launch:CINV-000003'], calls
assert not isinstance(error, E.TerminalResultExists), str(error)
"

# The fail-open hole the old recording guard carried: it required
# attempt_number == 1, so a result with an unusable one blocked nothing.
run_case "a result with an unusable attempt_number still blocks" "${PRELUDE}
for bad in (None, 0, 2, 'one', True):
    store = build('${WORK}/b-att-' + str(bad), [invocation('CINV-000002')],
                  [result('CRES-000001', 'CINV-000002', attempt=bad)])
    error, calls = attempt(store, 'CINV-000002')
    assert isinstance(error, E.TerminalResultExists), (bad, type(error).__name__)
    assert calls == [], (bad, calls)
"

# ===========================================================================
# C. the recording guard is still there
# ===========================================================================
#
# The pre-execution gate stops a second RUN. The guard inside the critical
# section stops a second RECORD, which is a different race: two callers past
# the gate concurrently would both reach the write, and only one may land.
# Moving the check must not have removed it.

run_case "record_terminal_result still refuses a second result inside the critical section" "${PRELUDE}
store = build('${WORK}/c', [invocation('CINV-000002')],
              [result('CRES-000001', 'CINV-000002')])
class Outcome:
    succeeded = False
    outcome_class = 'provider-error'
    terminal = None
try:
    E.record_terminal_result(store, invocation_record_id='CINV-000002',
                             outcome=Outcome(), actor='fixture',
                             invocation_id='CINV-000002', recorded_at=WHEN)
except CapabilityError as error:
    assert 'already exists' in str(error), str(error)
else:
    raise AssertionError('a second terminal result was recorded')
"

run_case "the gate and the recording guard answer through the same reader" "${PRELUDE}
import inspect
gate = inspect.getsource(E.require_no_terminal_result)
record = inspect.getsource(E.record_terminal_result)
# Not a style check: two spellings of 'does a result exist' would eventually
# disagree, and the disagreement would be a second execution.
assert 'existing_terminal_result' in gate
assert 'require_no_terminal_result' in record
"

# ===========================================================================
# D. §10 -- terminal provider-failure semantics are unchanged
# ===========================================================================
#
# The correction is the ORDERING of the duplicate-result guard. What a provider
# failure means must be exactly what G11-BC-I accepted.

run_case "a first provider failure still records succeeded=false / provider-error / null digest" "${PRELUDE}
store = build('${WORK}/d', [invocation('CINV-000003')], [])
class Terminal:
    started_at = '2026-09-14T09:00:00.000000000-05:00'
    finished_at = '2026-09-14T09:00:00.200000000-05:00'
class Outcome:
    succeeded = False
    outcome_class = 'provider-error'
    terminal = Terminal()
decision = E.record_terminal_result(
    store, invocation_record_id='CINV-000003', outcome=Outcome(),
    actor='primary-platform-operator', invocation_id='CINV-000003',
    recorded_at=WHEN)
assert decision.succeeded is False, decision.succeeded
assert decision.result_digest is None
assert decision.result_artifact_reference is None
written = store.read_record('capability-result', decision.result_record_id)
assert written['outcome_class'] == 'provider-error', written['outcome_class']
assert written['reason'] == 'provider-error', written['reason']
assert written['result_digest'] is None
assert written['result_artifact_reference'] is None
assert written['attempt_number'] == 1
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Duplicate-result gate validation passed.\n'
else
  printf 'Duplicate-result gate validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
