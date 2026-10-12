#!/usr/bin/env bash
set -Eeuo pipefail

# The terminal result contract: what an execution durably says it did.
#
# UNPRIVILEGED AND HERMETIC. No Podman, no container, no production path. Every
# store is a temporary directory and every outcome is a constructed
# `AdapterOutcome` -- the point here is what the coordinator does with a
# concluded outcome, not whether a container can be run, which the invoke
# harness proves separately.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AM joined the invoke front half to a real container and found two things
# the join exposed.
#
# `AdapterOutcome` carries both `outcome_class` and `succeeded`, and
# `prepare_invocation` copied the first while dropping the second. So a
# capability that wrote a valid governed result and one that wrote nothing both
# came back `completed`, and the caller could not tell them apart even though
# the adapter could.
#
# And nothing durable recorded what any execution did. A result record was
# allocated only on refusal, so every executed outcome left the same store
# state -- CINV spent, no CRES, outcome still `execution-prepared` -- which is
# also indistinguishable from an invocation that never executed at all.
#
# Design §15 names the fields a result record carries and §17 says validation
# reports an invocation with no result as interrupted. Both are the accepted
# architecture; neither was implemented.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

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

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PRELUDE="
import dataclasses, os, sys
sys.path.insert(0, '.')
from datetime import datetime, timezone
from tools.capability import evidence as E
from tools.capability import records as R
from tools.capability.execution.adapter import AdapterOutcome
from tools.capability.store import CapabilityStore
from tools.capability.errors import CapabilityError

WORK = os.environ['WORKDIR']
AT = datetime(2026, 8, 31, 12, 0, tzinfo=timezone.utc)
LATER = datetime(2026, 8, 31, 12, 0, 5, tzinfo=timezone.utc)

def outcome(outcome_class='completed', succeeded=True, result=None,
            started_at=AT, finished_at=LATER, **kw):
    '''A concluded adapter outcome, as the adapter would return one.'''
    class Terminal:
        def __init__(self):
            self.outcome_class = outcome_class
            self.started_at = started_at
            self.finished_at = finished_at
            self.classification = None
    return AdapterOutcome(
        cinv='CINV-000042', container_id='c' * 64,
        outcome_class=outcome_class, classification=None,
        terminal=Terminal(), result=result, output=None,
        started_proven=True, succeeded=succeeded, **kw)
"

# --- the accepted schema, §15 ---------------------------------------------------

run_case "the result record carries every field design section 15 names" "${PRELUDE}
# result_record_id is spelled capability_result_id in the released store; the
# rest are named exactly as the design names them.
required = {'capability_result_id', 'invocation_record_id', 'attempt_number',
            'outcome_class', 'reason', 'result_digest',
            'result_artifact_reference', 'started_at', 'ended_at',
            'kind', 'schema_version', 'evidence'}
missing = required - set(R.RESULT_FIELDS)
assert not missing, f'the result record cannot record: {sorted(missing)}'
print('OK')
"

run_case "the result schema version is its own, not the invocation's" "${PRELUDE}
# Splitting them rather than bumping one shared constant: a result record that
# gained fields must not reinterpret what a historical invocation record meant.
assert hasattr(R, 'RESULT_SCHEMA_VERSION'), 'result schema version is not stated'
assert hasattr(R, 'INVOCATION_SCHEMA_VERSION'), \\
    'invocation schema version is not stated'
# G11-AO moved the invocation record to 2 when adapter_identity joined its
# closed field set. The result record did not change and stays at 2.
assert R.INVOCATION_SCHEMA_VERSION == 2, R.INVOCATION_SCHEMA_VERSION
assert R.RESULT_SCHEMA_VERSION == 2, R.RESULT_SCHEMA_VERSION
print('OK')
"

# --- defect 1: succeeded reaches the caller --------------------------------------

run_case "a completed process with a result differs from one without" "${PRELUDE}
# The G11-AM defect in one assertion. Both are outcome_class 'completed'; only
# 'succeeded' distinguishes them, and it must survive the coordinator.
fields = {f.name for f in dataclasses.fields(E.InvocationDecision)}
assert 'succeeded' in fields, \\
    'the decision cannot carry whether a result was admitted'
print('OK')
"

run_case "succeeded is absent where no execution happened" "${PRELUDE}
# None, not False. A preparation that never reached an adapter did not fail --
# it did not execute, and saying False would be a claim about a run that never
# occurred.
decision = E.InvocationDecision(E.STATUS_PREPARED, 'no_authorised_adapter')
assert decision.succeeded is None, decision.succeeded
print('OK')
"

run_case "an unusable succeeded fails closed" "${PRELUDE}
# Missing or non-boolean must not read as success. The ruling is explicit: do
# not default missing succeeded to False -- refuse it.
for bad in ('true', 1, 0, '', object()):
    try:
        E.require_execution_success(bad)
    except CapabilityError:
        continue
    raise AssertionError(f'accepted a non-boolean success: {bad!r}')
assert E.require_execution_success(True) is True
assert E.require_execution_success(False) is False
print('OK')
"

# --- defect 2: a terminal result is durable --------------------------------------

run_case "a successful execution writes a terminal result record" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'success'), expected_uid=os.getuid(),
                        expected_gid=os.getgid())
record = E.record_terminal_result(
    store, invocation_record_id='CINV-000001',
    outcome=outcome(succeeded=True), result_digest='sha256:' + 'a' * 64,
    result_artifact_reference=None, actor='primary-platform-operator',
    recorded_at=LATER)
body = store.read_record(R.RESULT_KIND, record.result_record_id)
assert body['outcome_class'] == 'completed', body
assert body['reason'] is None, body
assert body['result_digest'] == 'sha256:' + 'a' * 64, body
assert body['attempt_number'] == 1, body
assert body['schema_version'] == R.RESULT_SCHEMA_VERSION, body
assert body['started_at'] is not None and body['ended_at'] is not None, body
print('OK')
"

run_case "a completed process with no result is not a success" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'noresult'), expected_uid=os.getuid(),
                        expected_gid=os.getgid())
record = E.record_terminal_result(
    store, invocation_record_id='CINV-000001',
    outcome=outcome(succeeded=False), result_digest=None,
    result_artifact_reference=None, actor='primary-platform-operator',
    recorded_at=LATER)
body = store.read_record(R.RESULT_KIND, record.result_record_id)
# The process completed; the invocation did not succeed. Both facts are kept.
assert body['outcome_class'] == 'completed', body
assert body['reason'] == R.REASON_RESULT_MISSING, body
assert body['result_digest'] is None, body
assert body['result_artifact_reference'] is None, body
print('OK')
"

run_case "a failing execution records its class and carries no result" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'failing'), expected_uid=os.getuid(),
                        expected_gid=os.getgid())
# A distinct invocation per class: one invocation has at most one terminal
# result, and the writer refuses a second -- proven in its own case below.
for index, cls in enumerate(('provider-error', 'adapter-error', 'timeout'), 1):
    record = E.record_terminal_result(
        store, invocation_record_id=f'CINV-00000{index}',
        outcome=outcome(outcome_class=cls, succeeded=False),
        result_digest=None, result_artifact_reference=None,
        actor='primary-platform-operator', recorded_at=LATER)
    body = store.read_record(R.RESULT_KIND, record.result_record_id)
    assert body['outcome_class'] == cls, body
    assert body['result_digest'] is None, body
print('OK')
"

run_case "one invocation may not carry two terminal results" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'duplicate'),
                        expected_uid=os.getuid(), expected_gid=os.getgid())
E.record_terminal_result(
    store, invocation_record_id='CINV-000001',
    outcome=outcome(succeeded=False), result_digest=None,
    result_artifact_reference=None, actor='primary-platform-operator',
    recorded_at=LATER)
# This adapter performs one attempt. A second terminal publication for the same
# invocation refuses rather than writing a second attempt-1 record.
try:
    E.record_terminal_result(
        store, invocation_record_id='CINV-000001',
        outcome=outcome(succeeded=False), result_digest=None,
        result_artifact_reference=None, actor='primary-platform-operator',
        recorded_at=LATER)
except CapabilityError:
    print('OK')
else:
    raise AssertionError('a second terminal result was written')
"

run_case "a success shape without a digest is refused before it is written" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'inconsistent'),
                        expected_uid=os.getuid(), expected_gid=os.getgid())
# completed + succeeded + no digest is not a describable outcome: the writer
# records conclusions, and this pair is not one anybody reached.
try:
    E.record_terminal_result(
        store, invocation_record_id='CINV-000001',
        outcome=outcome(succeeded=True), result_digest=None,
        result_artifact_reference=None, actor='primary-platform-operator',
    recorded_at=LATER)
except CapabilityError:
    print('OK')
else:
    raise AssertionError('an admitted result with no digest was written')
"

run_case "a failure carrying a result digest is refused" "${PRELUDE}
store = CapabilityStore(os.path.join(WORK, 'badfail'), expected_uid=os.getuid(),
                        expected_gid=os.getgid())
try:
    E.record_terminal_result(
        store, invocation_record_id='CINV-000001',
        outcome=outcome(outcome_class='timeout', succeeded=False),
        result_digest='sha256:' + 'a' * 64, result_artifact_reference=None,
        actor='primary-platform-operator', recorded_at=LATER)
except CapabilityError:
    print('OK')
else:
    raise AssertionError('a timeout carrying a result digest was written')
"

run_case "the invocation record is never rewritten to carry the outcome" "${PRELUDE}
import inspect
src = inspect.getsource(E.record_terminal_result)
# CINV is the immutable pre-execution attempt record. Recording completion by
# editing it would destroy the evidence that it was written BEFORE the adapter.
for banned in ('INVOCATION_KIND', 'invocation_body', 'write_atomic(store.path_for(R.INVOCATION'):
    assert banned not in src, banned
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability result contract validation passed.\n'
else
  printf 'Capability result contract validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
