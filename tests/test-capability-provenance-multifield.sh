#!/usr/bin/env bash
set -Eeuo pipefail

# ADR-0018 multi-field provenance correction.
#
# WHAT THIS SUITE IS FOR. CADM-000004 records a truthful EFFECT under three
# false ASSERTIONS -- actor 'x', request_id 'y', and a recorded_at backdated four
# days to a literal that lived in a test. ADR-0016 could record one of the three;
# the other two were refused, so two thirds of the falsehood was unrecordable.
#
# ADR-0018 widens the closed set to the three assertions that together make up a
# record's claimed AUTHORITY, and adds one finding for a value that no authority
# ever asserted. It does NOT make `reason` correctable: that is a claim about
# what happened, validated against the store before the abandonment was written.
#
# THE BOUNDARY THIS SUITE DEFENDS is that a correction touches the asserted
# authority, the disputed values and the observed occurrence -- and never the
# lifecycle truth. Everything below is a way of asking whether that still holds.
#
# Fixtures only. No production path is opened and no governed store is written.
#
# Governed by docs/decisions/ADR-0018-provenance-correction-of-synthetic-authority.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORKDIR="$(mktemp -d)"
trap 'chmod -R u+w "${WORKDIR}" 2>/dev/null || true; rm -rf "${WORKDIR}"' EXIT
export WORKDIR

run_case() {
  local name="$1" program="$2" output status=0
  output="$(cd "${ROOT}" && python3 -c "${program}" 2>&1)" || status=$?
  if (( status == 0 )); then
    pass "${name}"
  else
    fail "${name}"
    printf '%s\n' "${output}" | sed 's/^/      /' >&2
  fi
  return 0
}

printf -- '--- the closed sets ---\n'

run_case "exactly three assertions are correctable, and no lifecycle claim is" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution.provenance import CORRECTABLE_FIELDS
assert CORRECTABLE_FIELDS == frozenset({'actor', 'request_id', 'recorded_at'}), \
    sorted(CORRECTABLE_FIELDS)
# The effect, and every way of naming it, stays out.
for forbidden in ('reason', 'state', 'previous_state', 'slot_released',
                  'result_record_id', 'cinv', 'lifecycle_state', 'effect'):
    assert forbidden not in CORRECTABLE_FIELDS, forbidden
"

run_case "reason is NOT correctable, and the released rule says why" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution.provenance import CORRECTABLE_FIELDS
from tools.capability.execution.abandonment import (
    _REASON_REQUIRES_RESULT, REASON_HISTORICAL_INCOMPLETE_EXECUTION)
assert 'reason' not in CORRECTABLE_FIELDS
# It is excluded because it is checked against the store when it is written: the
# category asserts whether a terminal result exists, and the abandonment refuses
# a category that disagrees. A claim the store validated is a fact, not an
# attribution, so it is not this verb's to dispute.
assert _REASON_REQUIRES_RESULT[REASON_HISTORICAL_INCOMPLETE_EXECUTION] is False
"

run_case "two findings, saying different things" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution.provenance import (
    FINDINGS, FINDING_NOT_AUTHORISED, FINDING_SYNTHETIC)
assert FINDINGS == frozenset({FINDING_NOT_AUTHORISED, FINDING_SYNTHETIC}), sorted(FINDINGS)
assert FINDING_NOT_AUTHORISED == 'attribution-not-authorised'
assert FINDING_SYNTHETIC == 'assertion-synthetic'
"

run_case "the three instants have three names: none carries two meanings" "
import sys, inspect; sys.path.insert(0, '.')
from tools.capability.execution import provenance as P
parameters = inspect.signature(P.correct_provenance).parameters
for required in ('disputed_value', 'recorded_at', 'actual_occurrence_at'):
    assert required in parameters, required
# And the record keeps them apart rather than deriving one from another.
source = inspect.getsource(P.correct_provenance)
assert '\"actual_occurrence_at\": occurrence_text' in source
assert '\"recorded_at\": recorded_text' in source
assert '\"disputed_value\": claimed' in source
assert 'occurrence_text = _instant(actual_occurrence_at' in source
"

run_case "an occurrence without an offset is refused, and named" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution import provenance as P
for bad, expect in (('2026-09-24T06:40:43', 'timezone offset'),
                    ('not-a-time', 'ISO-8601'),
                    ('', 'non-empty')):
    try:
        P._instant(bad, 'actual_occurrence_at')
    except P.ProvenanceRefused as error:
        assert 'actual_occurrence_at' in str(error), str(error)
        assert expect in str(error), (bad, str(error))
    else:
        raise AssertionError('accepted ' + repr(bad))
"

PRELUDE="
import hashlib, json, os, shutil, sys
sys.path.insert(0, '.')
from tools.capability.errors import CapabilityError
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.state import (
    transition, TRANSITIONS_DIRECTORY, LOCKS_DIRECTORY)
from tools.capability.execution import capacity as capacity_module
from tools.capability.execution import state as sm
from tools.capability.execution.capacity import reserve
from tools.capability.execution.abandonment import (
    abandon, REASON_HISTORICAL_INCOMPLETE_EXECUTION)
from tools.capability.execution.provenance import (
    correct_provenance, ProvenanceRefused, existing_correction,
    FINDING_NOT_AUTHORISED, FINDING_SYNTHETIC, EFFECT_RETAINED,
    INITIATOR_UNAUTHORISED_TEST_HARNESS)
WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'

# The three disputed assertions, as production carries them.
DISPUTED = {'actor': 'x',
            'request_id': 'y',
            'recorded_at': '2026-09-20T20:00:00-05:00'}
OCCURRED = '2026-09-24T06:40:43-05:00'

def make(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for sub in ('root/mutations', 'root/state', 'root/' + TRANSITIONS_DIRECTORY,
                'root/' + LOCKS_DIRECTORY, 'root/admin-records'):
        os.makedirs(os.path.join(base, sub))
    with open(os.path.join(base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
        handle.write(b'000000000000\n')
    with open(os.path.join(base, 'root', 'cadm-counter'), 'wb') as handle:
        handle.write(b'000000\n')
    return base

def anchor(base):
    cfg = os.open(os.path.join(base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    try:
        return verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)

class FakeStore:
    def read_record(self, kind, identity):
        if identity != 'CINV-000001':
            raise CapabilityError(identity + ' unknown')
        return {'invocation_record_id': 'CINV-000001'}
    def list_records(self, kind):
        return []          # no terminal result, as CINV-000001 has none

def incident(name):
    '''The production condition: CINV-000001 abandoned by a test harness, with
    all three authority assertions synthetic.'''
    base = make(name)
    root = anchor(base)
    reserve(root, 'CINV-000001')
    transition(root, 'CINV-000001', LifecycleState.RESERVED,
               LifecycleState.LAUNCH_AUTHORIZED)
    abandon(store=FakeStore(), execution_root=root, cinv='CINV-000001',
            actor=DISPUTED['actor'], request_id=DISPUTED['request_id'],
            recorded_at=DISPUTED['recorded_at'],
            reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
    return base, root

def correction(field, **overrides):
    finding = (FINDING_NOT_AUTHORISED if field == 'actor'
               else FINDING_SYNTHETIC)
    kwargs = dict(subject_cadm='CADM-000001', cinv='CINV-000001',
                  disputed_field=field, disputed_value=DISPUTED[field],
                  finding=finding,
                  actual_initiator=INITIATOR_UNAUTHORISED_TEST_HARNESS,
                  actor='primary-platform-operator',
                  request_id='g11bcai-correct-' + field,
                  recorded_at='2026-09-27T09:00:00-05:00',
                  actual_occurrence_at=OCCURRED,
                  evidence_references=['docs/report.md@d8f95d4'])
    kwargs.update(overrides)
    return kwargs

def member_bytes(base, cadm, member):
    with open(os.path.join(base, 'root', 'admin-records', cadm, member), 'rb') as h:
        return h.read()

def snapshot(base):
    out = {}
    for here, _, names in os.walk(os.path.join(base, 'root')):
        for name in names:
            path = os.path.join(here, name)
            out[os.path.relpath(path, os.path.join(base, 'root'))] = open(path, 'rb').read()
    return out

def occupancy(root):
    holding = capacity_module.slot_holding_states()
    return sum(1 for v in sm.all_states(root).values() if v in holding)

def cmuts(base):
    directory = os.path.join(base, 'root', 'mutations')
    return sorted(os.listdir(directory)) if os.path.isdir(directory) else []
"

printf -- '\n--- one record per field, and they do not stand in for each other ---\n'

run_case "all three fields are correctable independently, each its own CADM" "${PRELUDE}
base, root = incident('e1')
seen = {}
for field in ('actor', 'request_id', 'recorded_at'):
    out = correct_provenance(execution_root=root, **correction(field))
    assert out.disputed_field == field, out
    assert out.disputed_value == DISPUTED[field], out
    assert out.actual_occurrence_at == OCCURRED, out
    assert out.effect == EFFECT_RETAINED, out
    assert out.lifecycle_state == 'abandoned', out
    assert out.subject_member == 'abandonment', out
    seen[field] = out.cadm
# Three distinct records, one per field.
assert len(set(seen.values())) == 3, seen
"

run_case "an actor correction cannot stand in for request_id" "${PRELUDE}
base, root = incident('e2')
correct_provenance(execution_root=root, **correction('actor'))
assert existing_correction(root, 'CADM-000001', 'actor') is not None
# The other two are still unrecorded: the create-once key is (subject, field).
assert existing_correction(root, 'CADM-000001', 'request_id') is None
assert existing_correction(root, 'CADM-000001', 'recorded_at') is None
"

run_case "a request_id correction cannot stand in for recorded_at" "${PRELUDE}
base, root = incident('e3')
correct_provenance(execution_root=root, **correction('actor'))
correct_provenance(execution_root=root, **correction('request_id'))
assert existing_correction(root, 'CADM-000001', 'request_id') is not None
assert existing_correction(root, 'CADM-000001', 'recorded_at') is None
"

run_case "an identical repeat resumes per field and writes nothing" "${PRELUDE}
base, root = incident('e4')
first = {f: correct_provenance(execution_root=root, **correction(f))
         for f in ('actor', 'request_id', 'recorded_at')}
before = snapshot(base)
for field in ('actor', 'request_id', 'recorded_at'):
    again = correct_provenance(execution_root=root, **correction(field))
    assert again.resumed is True, (field, again)
    assert again.cadm == first[field].cadm, (field, again.cadm)
assert snapshot(base) == before, 'a resume wrote something'
"

printf -- '\n--- the failure matrix ---\n'

run_case "wrong subject CADM is refused" "${PRELUDE}
base, root = incident('f1')
try:
    correct_provenance(execution_root=root, **correction('actor', subject_cadm='CADM-000009'))
except ProvenanceRefused as error:
    assert 'CADM-000009' in str(error), str(error)
else:
    raise AssertionError('a correction named a subject that does not exist')
"

run_case "a changed subject member is refused: the digest binds it" "${PRELUDE}
base, root = incident('f2')
path = os.path.join(base, 'root', 'admin-records', 'CADM-000001', 'abandonment')
document = json.loads(open(path, encoding='utf-8').read())
document['actor'] = 'someone-else'
os.chmod(path, 0o600); open(path, 'w', encoding='utf-8').write(json.dumps(document))
try:
    correct_provenance(execution_root=root, **correction('actor'))
except ProvenanceRefused as error:
    assert 'refusing to correct a claim that is not there' in str(error), str(error)
else:
    raise AssertionError('a correction was written against bytes it had not read')
"

run_case "wrong CINV is refused" "${PRELUDE}
base, root = incident('f3')
try:
    correct_provenance(execution_root=root, **correction('actor', cinv='CINV-000002'))
except (ProvenanceRefused, Exception) as error:
    assert 'CINV-000002' in str(error) or 'CINV-000001' in str(error), str(error)
else:
    raise AssertionError('a correction named the wrong invocation')
"

run_case "each disputed value must match what the record says" "${PRELUDE}
base, root = incident('f4')
for field, wrong in (('actor', 'an-operator'),
                     ('request_id', 'some-request'),
                     ('recorded_at', '2026-09-24T06:40:43-05:00')):
    try:
        correct_provenance(execution_root=root,
                           **correction(field, disputed_value=wrong))
    except ProvenanceRefused as error:
        assert 'refusing to correct a claim that is not there' in str(error), (field, str(error))
    else:
        raise AssertionError('a mismatched ' + field + ' value was accepted')
"

run_case "an unsupported field is refused, naming the closed set" "${PRELUDE}
base, root = incident('f5')
for field in ('reason', 'state', 'slot_released', 'result_record_id', 'previous_state'):
    try:
        correct_provenance(execution_root=root,
                           **correction('actor', disputed_field=field,
                                        disputed_value='whatever'))
    except ProvenanceRefused as error:
        assert 'no lifecycle claim' in str(error) or 'corrects' in str(error), (field, str(error))
    else:
        raise AssertionError(field + ' was accepted as correctable')
"

run_case "a conflicting repeat is refused, and names the field that differs" "${PRELUDE}
base, root = incident('f6')
correct_provenance(execution_root=root, **correction('actor'))
for override in ({'actor': 'someone-else'},
                 {'request_id': 'another-request'},
                 {'recorded_at': '2026-09-27T10:00:00-05:00'},
                 {'actual_occurrence_at': '2026-09-25T00:00:00-05:00'},
                 {'finding': FINDING_SYNTHETIC},
                 {'actual_initiator': 'unknown'}):
    try:
        correct_provenance(execution_root=root, **correction('actor', **override))
    except ProvenanceRefused as error:
        assert 'differs' in str(error) or 'already' in str(error), (override, str(error))
    else:
        raise AssertionError('a conflicting correction was accepted: ' + repr(override))
"

run_case "a correction alters no lifecycle, no occupancy, and spends no CMUT" "${PRELUDE}
base, root = incident('f7')
before_states = dict(sm.all_states(root))
before_occupancy = occupancy(root)
before_cmuts = cmuts(base)
before_cmut_counter = open(os.path.join(base, 'root', CMUT_COUNTER), 'rb').read()
before_transitions = sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))
for field in ('actor', 'request_id', 'recorded_at'):
    correct_provenance(execution_root=root, **correction(field))
assert dict(sm.all_states(root)) == before_states, 'the lifecycle moved'
assert occupancy(root) == before_occupancy, 'occupancy moved'
assert sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))) == before_transitions
# THE POINT: a provenance correction is not a lifecycle transition, so it opens
# no mutation. G11-BC-AG proved every transition spends a CMUT; this proves a
# correction is not one.
assert cmuts(base) == before_cmuts, cmuts(base)
assert open(os.path.join(base, 'root', CMUT_COUNTER), 'rb').read() == before_cmut_counter
"

run_case "a correction rewrites nothing it disputes" "${PRELUDE}
base, root = incident('f8')
before = {m: member_bytes(base, 'CADM-000001', m)
          for m in os.listdir(os.path.join(base, 'root', 'admin-records', 'CADM-000001'))}
for field in ('actor', 'request_id', 'recorded_at'):
    correct_provenance(execution_root=root, **correction(field))
after = {m: member_bytes(base, 'CADM-000001', m) for m in before}
assert after == before, 'the subject record changed'
"

run_case "a refusal writes nothing at all" "${PRELUDE}
base, root = incident('f9')
before = snapshot(base)
for override in ({'subject_cadm': 'CADM-000009'},
                 {'disputed_value': 'wrong'},
                 {'disputed_field': 'reason'},
                 {'actual_occurrence_at': 'not-a-time'},
                 {'finding': 'invented-finding'},
                 {'actual_initiator': 'somebody'}):
    try:
        correct_provenance(execution_root=root, **correction('actor', **override))
    except Exception:
        pass
    else:
        raise AssertionError('expected a refusal for ' + repr(override))
assert snapshot(base) == before, 'a refusal left something behind'
"

run_case "the correction cannot reach a capacity lock or a transition" "
import sys, inspect; sys.path.insert(0, '.')
from tools.capability.execution import provenance as P
source = inspect.getsource(P)
for forbidden in ('acquire_capacity', 'transition_locked', 'transition(',
                  'Mutation(', 'record_terminal_result'):
    assert forbidden not in source, forbidden
"

printf -- '\n--- the CADM-000004 correction chain, proved against a fixture ---\n'

run_case "all three CADM-000004 assertions are recordable, effect retained" "${PRELUDE}
base, root = incident('d1')
records = []
for field in ('actor', 'request_id', 'recorded_at'):
    out = correct_provenance(execution_root=root, **correction(field))
    records.append(out)
# What the chain asserts, and what it refuses to assert.
for out in records:
    assert out.effect == EFFECT_RETAINED
    assert out.lifecycle_state == 'abandoned'
    assert out.actual_initiator == INITIATOR_UNAUTHORISED_TEST_HARNESS
    assert out.actual_occurrence_at == OCCURRED
detail = existing_correction(root, 'CADM-000001', 'recorded_at')
assert detail['disputed_value'] == '2026-09-20T20:00:00-05:00'
assert detail['actual_occurrence_at'] == OCCURRED
assert detail['recorded_at'] == '2026-09-27T09:00:00-05:00'
# Three distinct instants, none standing in for another.
assert len({detail['disputed_value'], detail['actual_occurrence_at'],
            detail['recorded_at']}) == 3
assert detail['lifecycle_unchanged'] is True
assert detail['slot_changed'] is False
assert detail['action_reversed'] is False
# And no substitute authority was invented anywhere in the chain.
assert 'corrected_value' not in detail and 'true_actor' not in detail
"

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'ADR-0018 multi-field provenance correction validation passed.\n'
else
  printf 'ADR-0018 multi-field provenance correction validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
