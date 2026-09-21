#!/usr/bin/env bash
set -Eeuo pipefail

# Provenance correction of an administrative record (ADR-0016).
#
# WHY THIS EXISTS
# ===============
# On 2026-09-20 a rehearsal harness drove `capability abandon` against
# production. The lifecycle effect it produced is materially the one ADR-0015
# specifies -- CINV-000002 closed, one slot reclaimed, nothing deleted -- but
# CADM-000001 records `actor: primary-platform-operator` for an action no
# operator took or approved. The store holds a true effect under an untrue
# attribution.
#
# CORRECTING PROVENANCE IS NOT REVERSING AN ACTION. The whole value of this
# verb is that it keeps those two claims apart, so most of this suite is spent
# proving it CANNOT reach the second one: no transition, no slot movement, no
# result, no lifecycle field, and no write to the record it is about.
#
# Everything runs against fixtures. The CLI surface and the production-vs-
# fixture target question are proven by
# tests/test-capability-mutation-target-explicit.sh, which needs the host.
#
# Governed by docs/decisions/ADR-0016-provenance-correction-of-administrative-records.md

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
    [[ -n "${output}" ]] && printf '%s\n' "${output}" | sed 's/^/      /'
  else
    fail "${name}"
    printf '%s\n' "${output}" | sed 's/^/      /' >&2
  fi
  return 0
}

# ===========================================================================
# 0. The purity backstop
# ===========================================================================
#
# This verb records a finding about a record. It must not be able to do
# anything else. Two entries matter more than the rest:
#
#   `capacity`          absent, because a module that could count or take a
#                       slot is a module that could move one.
#   `transition_locked` absent, because the one thing separating a correction
#                       from a reversal is that it cannot write lifecycle.
#
# `datetime` IS imported: the module parses a caller-supplied `recorded_at`
# and refuses one without an offset. It never asks what time it is, which is
# why `now`, `today` and `monotonic` are forbidden and `fromisoformat` is not.

printf -- '--- purity backstop ---\n'

backstop="$(cd "${ROOT}" && python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

target = pathlib.Path(sys.argv[1]) / "tools/capability/execution/provenance.py"
tree = ast.parse(target.read_text())

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes", "socket",
    "http", "urllib", "requests", "asyncio", "docker", "podman", "pty",
    "shlex", "random", "secrets", "tempfile", "shutil", "glob", "logging",
    "time",
    # The two that make this verb a correction rather than a reversal.
    "capacity",
}
FORBIDDEN_NAMES = {
    "now", "today", "monotonic", "utcnow",
    "transition", "transition_locked", "reserve", "release",
    "unlink", "rmdir", "remove", "rmtree", "truncate", "system", "popen",
}

problems = []
imported = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            imported.add(alias.name.split(".")[0])
    elif isinstance(node, ast.ImportFrom):
        if node.module:
            imported.add(node.module.split(".")[-1])
        for alias in node.names:
            imported.add(alias.name)
    elif isinstance(node, ast.Call):
        name = None
        if isinstance(node.func, ast.Attribute):
            name = node.func.attr
        elif isinstance(node.func, ast.Name):
            name = node.func.id
        if name in FORBIDDEN_NAMES:
            problems.append(f"calls {name} at line {node.lineno}")

for bad in sorted(imported & FORBIDDEN_IMPORTS):
    problems.append(f"imports {bad}")
for bad in sorted(imported & FORBIDDEN_NAMES):
    problems.append(f"imports the name {bad}")

# O_WRONLY/O_RDWR on the subject would be an edit history. The module opens
# members read-only and writes only through the admin helper.
source = target.read_text()
if "O_RDWR" in source:
    problems.append("opens something read-write")

print("\n".join(problems) if problems else "clean")
SCANPY
)"
if [[ "${backstop}" == "clean" ]]; then
  pass "provenance.py imports no capacity, no lifecycle transition and no clock"
else
  fail "provenance.py purity backstop: ${backstop}"
fi

# ===========================================================================
# 1. The verb
# ===========================================================================

printf -- '\n--- the verb ---\n'

run_case "correct-provenance is a closed-set verb with no destruction authority" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution.admin import Verb, _DESTROYS_UNDER, is_mutating
assert Verb.CORRECT_PROVENANCE.value == 'correct-provenance'
assert Verb.CORRECT_PROVENANCE not in _DESTROYS_UNDER
assert is_mutating(Verb.CORRECT_PROVENANCE) is True
print(f'{len(list(Verb))} verbs, correct-provenance carries no destruction authority')
"

run_case "only provenance claims are correctable, and no lifecycle claim is" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution.provenance import CORRECTABLE_FIELDS
assert CORRECTABLE_FIELDS == frozenset({'actor'}), CORRECTABLE_FIELDS
for lifecycle in ('state', 'previous_state', 'reason', 'slot_released',
                  'result_record_id', 'cinv', 'cadm'):
    assert lifecycle not in CORRECTABLE_FIELDS, lifecycle
print('correctable:', sorted(CORRECTABLE_FIELDS))
"

PRELUDE="
import hashlib, json, os, shutil, sys
sys.path.insert(0, '.')
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem, target_fingerprint)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.state import (
    current_state, transition, TRANSITIONS_DIRECTORY, LOCKS_DIRECTORY)
from tools.capability.execution import capacity as capacity_module
from tools.capability.execution import state as sm
from tools.capability.execution.capacity import reserve
from tools.capability.execution.abandonment import (
    abandon, REASON_TERMINAL_RESULT_STRANDED)
from tools.capability.execution.provenance import (
    correct_provenance, existing_correction, ProvenanceRefused,
    FINDING_NOT_AUTHORISED, INITIATOR_UNAUTHORISED_REHEARSAL,
    INITIATOR_UNKNOWN, EFFECT_RETAINED, PROVENANCE_CORRECTION)
WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'

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
    def __init__(self, invocations, results):
        self._i = dict(invocations); self._r = dict(results)
    def read_record(self, kind, identity):
        from tools.capability.errors import CapabilityError
        table = self._i if kind == 'capability-invocation' else self._r
        if identity not in table:
            raise CapabilityError(f'{identity} is not a known {kind}')
        return dict(table[identity])
    def list_records(self, kind):
        table = self._i if kind == 'capability-invocation' else self._r
        return [dict(v) for v in table.values()]

def store_with():
    inv = {'CINV-000001': {'invocation_record_id': 'CINV-000001',
                           'invocation_id': 'first', 'adapter_identity': None},
           'CINV-000002': {'invocation_record_id': 'CINV-000002',
                           'invocation_id': 'second', 'adapter_identity': None}}
    res = {'CRES-000001': {'capability_result_id': 'CRES-000001',
                           'invocation_record_id': 'CINV-000002'}}
    return FakeStore(inv, res)

def occupancy(root):
    holding = capacity_module.slot_holding_states()
    return sum(1 for v in sm.all_states(root).values() if v in holding)

def counters(base):
    out = {}
    for name in ('cadm-counter', CMUT_COUNTER):
        with open(os.path.join(base, 'root', name)) as handle:
            out[name] = handle.read()
    return out

def transitions(base):
    return sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))

def member_bytes(base, cadm, member):
    with open(os.path.join(base, 'root', 'admin-records', cadm, member), 'rb') as h:
        return h.read()

def incident(name):
    '''The production condition: CINV-000002 abandoned, attributed to an
    operator who did nothing.'''
    base = make(name)
    root = anchor(base)
    for cinv in ('CINV-000001', 'CINV-000002'):
        reserve(root, cinv)
        transition(root, cinv, LifecycleState.RESERVED,
                   LifecycleState.LAUNCH_AUTHORIZED)
    abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
            actor='primary-platform-operator',
            request_id='g11bcx-reclaim-cinv-000002',
            recorded_at='2026-09-20T18:54:33-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
    return base, root

CORRECTION = dict(subject_cadm='CADM-000001', cinv='CINV-000002',
                  disputed_field='actor',
                  disputed_value='primary-platform-operator',
                  finding=FINDING_NOT_AUTHORISED,
                  actual_initiator=INITIATOR_UNAUTHORISED_REHEARSAL,
                  actor='primary-platform-operator',
                  request_id='g11bcy-correct-cadm-000001',
                  recorded_at='2026-09-20T20:00:00-05:00',
                  evidence_references=['docs/report.md@e5471e8'])
"

# ===========================================================================
# 2. The correction, and everything it leaves alone
# ===========================================================================

printf -- '\n--- the correction ---\n'

run_case "a correction records the finding and changes nothing else" "${PRELUDE}
base, root = incident('c1')
before_occupancy = occupancy(root)
before_transitions = transitions(base)
before_counters = counters(base)
before_subject = member_bytes(base, 'CADM-000001', 'abandonment')
before_state = current_state(root, 'CINV-000002')

outcome = correct_provenance(execution_root=root, **CORRECTION)

assert outcome.cadm == 'CADM-000002', outcome.cadm
assert outcome.subject_cadm == 'CADM-000001'
assert outcome.subject_member == 'abandonment'
assert outcome.subject_digest == hashlib.sha256(before_subject).hexdigest()
assert outcome.effect == EFFECT_RETAINED
assert outcome.lifecycle_state == 'abandoned', outcome.lifecycle_state
assert outcome.resumed is False

# the subject, byte for byte
assert member_bytes(base, 'CADM-000001', 'abandonment') == before_subject
# the lifecycle
assert current_state(root, 'CINV-000002') is before_state
assert transitions(base) == before_transitions, transitions(base)
# capacity
assert occupancy(root) == before_occupancy == 1, occupancy(root)
# the mutation journal: a correction writes no lifecycle, so no CMUT
after = counters(base)
assert after[CMUT_COUNTER] == before_counters[CMUT_COUNTER], after
assert after['cadm-counter'] != before_counters['cadm-counter']
print('CADM-000002 written; subject, lifecycle, occupancy and CMUT all unchanged')
"

run_case "the finding says the effect is retained and the action is not reversed" "${PRELUDE}
base, root = incident('c2')
correct_provenance(execution_root=root, **CORRECTION)
body = json.loads(member_bytes(base, 'CADM-000002', PROVENANCE_CORRECTION))
assert body['action_reversed'] is False
assert body['lifecycle_unchanged'] is True
assert body['slot_changed'] is False
assert body['effect'] == 'retained'
assert body['finding'] == 'attribution-not-authorised'
assert body['actual_initiator'] == 'unauthorised-rehearsal-harness'
assert body['disputed_field'] == 'actor'
assert body['disputed_value'] == 'primary-platform-operator'
assert body['subject_cadm'] == 'CADM-000001'
assert body['cinv'] == 'CINV-000002'
assert body['causal_references'] == ['CADM-000001', 'CINV-000002']
assert body['evidence_references'] == ['docs/report.md@e5471e8']
# It does not name a replacement actor. The recorded actor is whoever filed
# the correction, which is a different claim.
assert 'corrected_value' not in body and 'ratified' not in body
print(json.dumps({k: body[k] for k in sorted(body)}, indent=None)[:160])
"

run_case "the CADM carries intent and outcome in the usual order" "${PRELUDE}
base, root = incident('c3')
correct_provenance(execution_root=root, **CORRECTION)
record = os.path.join(base, 'root', 'admin-records', 'CADM-000002')
assert sorted(os.listdir(record)) == ['intent', 'outcome', PROVENANCE_CORRECTION]
intent = json.loads(member_bytes(base, 'CADM-000002', 'intent'))
outcome = json.loads(member_bytes(base, 'CADM-000002', 'outcome'))
assert intent['verb'] == 'correct-provenance', intent
assert intent['cinv'] == 'CINV-000002'
assert intent['target'] is None
assert outcome['result'] == 'done', outcome
print('intent ->', intent['verb'], '-> outcome', outcome['result'])
"

run_case "the target is the root the writer actually held" "${PRELUDE}
base, root = incident('c4')
outcome = correct_provenance(execution_root=root, **CORRECTION)
status = os.stat(os.path.join(base, 'root'))
assert outcome.target == {'st_dev': status.st_dev, 'st_ino': status.st_ino}, outcome.target
other = anchor(make('c4-other'))
assert target_fingerprint(other) != outcome.target
print('target', outcome.target, 'is the fixture root, and not another root')
"

run_case "an identical repeat resumes and writes nothing" "${PRELUDE}
base, root = incident('c5')
first = correct_provenance(execution_root=root, **CORRECTION)
before = sorted(os.listdir(os.path.join(base, 'root', 'admin-records')))
second = correct_provenance(execution_root=root, **CORRECTION)
assert second.resumed is True
assert second.cadm == first.cadm
assert sorted(os.listdir(os.path.join(base, 'root', 'admin-records'))) == before
print('resumed', second.cadm, 'with no second record')
"

run_case "a correction of the same claim under different authority refuses" "${PRELUDE}
base, root = incident('c6')
correct_provenance(execution_root=root, **CORRECTION)
for key, value in (('actor', 'somebody-else'),
                   ('request_id', 'another-request'),
                   ('recorded_at', '2026-09-21T09:00:00-05:00'),
                   ('actual_initiator', INITIATOR_UNKNOWN)):
    changed = dict(CORRECTION); changed[key] = value
    try:
        correct_provenance(execution_root=root, **changed)
    except ProvenanceRefused as error:
        assert 'different' in str(error), str(error)
    else:
        raise AssertionError(f'a differing {key} was accepted')
print('four differing authorities all refused')
"

# ===========================================================================
# 3. It cannot become a reversal, or an edit history
# ===========================================================================

printf -- '\n--- what it refuses ---\n'

run_case "no lifecycle claim can be corrected" "${PRELUDE}
base, root = incident('r1')
for field in ('state', 'previous_state', 'reason', 'slot_released',
              'result_record_id', 'cinv', 'slot_released'):
    changed = dict(CORRECTION); changed['disputed_field'] = field
    changed['disputed_value'] = 'anything'
    try:
        correct_provenance(execution_root=root, **changed)
    except ProvenanceRefused as error:
        assert 'not a correctable provenance claim' in str(error), str(error)
    else:
        raise AssertionError(f'{field} was correctable')
print('every lifecycle claim refused')
"

run_case "a claim the record does not make cannot be corrected" "${PRELUDE}
base, root = incident('r2')
changed = dict(CORRECTION); changed['disputed_value'] = 'somebody-else'
try:
    correct_provenance(execution_root=root, **changed)
except ProvenanceRefused as error:
    assert 'not' in str(error) and 'primary-platform-operator' in str(error), str(error)
else:
    raise AssertionError('a claim that is not there was corrected')
print('refused: the record does not say that')
"

run_case "an unknown subject refuses" "${PRELUDE}
base, root = incident('r3')
changed = dict(CORRECTION); changed['subject_cadm'] = 'CADM-000009'
try:
    correct_provenance(execution_root=root, **changed)
except ProvenanceRefused as error:
    assert 'CADM-000009 is not a recorded CADM' in str(error), str(error)
else:
    raise AssertionError('an unknown subject was accepted')
changed = dict(CORRECTION); changed['subject_cadm'] = 'not-a-cadm'
try:
    correct_provenance(execution_root=root, **changed)
except ProvenanceRefused as error:
    assert 'CADM identity' in str(error), str(error)
else:
    raise AssertionError('a malformed subject was accepted')
print('unknown and malformed subjects both refused')
"

run_case "an uncontrolled finding or initiator refuses" "${PRELUDE}
base, root = incident('r4')
for key, value in (('finding', 'looked-wrong'),
                   ('actual_initiator', 'a-person-i-suspect'),
                   ('finding', ''), ('actual_initiator', None)):
    changed = dict(CORRECTION); changed[key] = value
    try:
        correct_provenance(execution_root=root, **changed)
    except ProvenanceRefused:
        pass
    else:
        raise AssertionError(f'{key}={value!r} was accepted')
print('free-form findings and initiators refused')
"

run_case "a correction of a subject about another invocation refuses" "${PRELUDE}
base, root = incident('r5')
changed = dict(CORRECTION); changed['cinv'] = 'CINV-000001'
try:
    correct_provenance(execution_root=root, **changed)
except ProvenanceRefused as error:
    assert 'CINV-000002' in str(error), str(error)
else:
    raise AssertionError('a subject about another invocation was accepted')
print('refused: the subject is about CINV-000002')
"

run_case "a correction whose subject effect has since changed refuses" "${PRELUDE}
import tools.capability.execution.admin as admin_module
base, root = incident('r6')
# A hand-made subject claiming a state CINV-000001 is not in.
cadm = admin_module.allocate_cadm(root)
admin_module.record_intent(root, cadm, admin_module.Verb.ABANDON,
                           'CINV-000001', None)
handle = admin_module._record_directory(root, cadm)
admin_module._write_durable('abandonment', serialise({
    'actor': 'primary-platform-operator', 'cadm': cadm, 'cinv': 'CINV-000001',
    'state': 'released', 'previous_state': 'launch_authorized'}), handle)
os.close(handle)
changed = dict(CORRECTION)
changed['subject_cadm'] = cadm
changed['cinv'] = 'CINV-000001'
try:
    correct_provenance(execution_root=root, **changed)
except ProvenanceRefused as error:
    assert 'has changed' in str(error), str(error)
else:
    raise AssertionError('a correction of a changed effect was accepted')
print('refused: the effect this would correct has changed')
"

run_case "an ambiguous claim refuses rather than choosing" "${PRELUDE}
import tools.capability.execution.admin as admin_module
base, root = incident('r7')
handle = admin_module._record_directory(root, 'CADM-000001')
admin_module._write_durable('second-detail', serialise({
    'actor': 'primary-platform-operator', 'cinv': 'CINV-000002'}), handle)
os.close(handle)
try:
    correct_provenance(execution_root=root, **CORRECTION)
except ProvenanceRefused as error:
    assert 'more than one member' in str(error), str(error)
else:
    raise AssertionError('an ambiguous claim was corrected')
print('refused: the claim appears in more than one member')
"

run_case "a malformed instant refuses rather than being guessed at" "${PRELUDE}
base, root = incident('r8')
for value in ('2026-09-20T20:00:00', 'yesterday', '', None, 20260920):
    changed = dict(CORRECTION); changed['recorded_at'] = value
    try:
        correct_provenance(execution_root=root, **changed)
    except ProvenanceRefused:
        pass
    else:
        raise AssertionError(f'recorded_at={value!r} was accepted')
print('naive, malformed, empty and non-string instants all refused')
"

run_case "evidence references are bounded and checked" "${PRELUDE}
base, root = incident('r9')
for value in ('a-string-not-a-list', ['ok', 'ok'], [''], [None],
              ['x' * 600], ['r%d' % n for n in range(20)]):
    changed = dict(CORRECTION); changed['evidence_references'] = value
    try:
        correct_provenance(execution_root=root, **changed)
    except ProvenanceRefused:
        pass
    else:
        raise AssertionError(f'evidence_references={value!r} was accepted')
outcome = correct_provenance(execution_root=root,
                             **dict(CORRECTION, evidence_references=None))
assert outcome.cadm == 'CADM-000002'
print('bad reference lists refused; none is accepted')
"

run_case "an unverified root refuses before anything is read" "${PRELUDE}
base, root = incident('r10')
for bad in (None, base, os.path.join(base, 'root'), 3):
    try:
        correct_provenance(execution_root=bad, **CORRECTION)
    except ProvenanceRefused as error:
        assert 'RootDescriptor' in str(error), str(error)
    else:
        raise AssertionError(f'{bad!r} was accepted as a root')
print('only a verified RootDescriptor is accepted')
"

# ===========================================================================
# 4. What the store looks like afterwards
# ===========================================================================

printf -- '\n--- the store afterwards ---\n'

run_case "the disputed claim stays readable beside the finding about it" "${PRELUDE}
base, root = incident('s1')
correct_provenance(execution_root=root, **CORRECTION)
subject = json.loads(member_bytes(base, 'CADM-000001', 'abandonment'))
finding = json.loads(member_bytes(base, 'CADM-000002', PROVENANCE_CORRECTION))
assert subject['actor'] == 'primary-platform-operator'
assert finding['disputed_value'] == subject['actor']
assert finding['subject_digest'] == hashlib.sha256(
    member_bytes(base, 'CADM-000001', 'abandonment')).hexdigest()
print('the untrue attribution is still there, and now carries a finding')
"

run_case "the finding is discoverable from the subject alone" "${PRELUDE}
base, root = incident('s2')
assert existing_correction(root, 'CADM-000001', 'actor') is None
correct_provenance(execution_root=root, **CORRECTION)
found = existing_correction(root, 'CADM-000001', 'actor')
assert found is not None and found['cadm'] == 'CADM-000002'
assert existing_correction(root, 'CADM-000001', 'nothing') is None
assert existing_correction(root, 'CADM-000009', 'actor') is None
print('existing_correction finds it by subject and field, and nothing else')
"

run_case "a later change to the subject is detectable from the finding" "${PRELUDE}
base, root = incident('s3')
outcome = correct_provenance(execution_root=root, **CORRECTION)
path = os.path.join(base, 'root', 'admin-records', 'CADM-000001', 'abandonment')
os.chmod(path, 0o600)
with open(path, 'ab') as handle:
    handle.write(b' ')
assert hashlib.sha256(open(path, 'rb').read()).hexdigest() != outcome.subject_digest
print('the recorded digest no longer matches: tampering with the subject shows')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Provenance correction suite passed.\n'
else
  printf 'Provenance correction suite FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
