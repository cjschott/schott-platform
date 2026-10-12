#!/usr/bin/env bash
set -Eeuo pipefail

# ADR-0017 post-execution lifecycle conclusion.
#
# WHAT THIS SUITE IS FOR. A supervised execution records its terminal result and
# stops: the journal is written by `authorise_launch` before the privilege
# boundary and the states past `launch_authorized` live on the wire and never in
# it. So every successful execution strands at `launch_authorized` holding a
# slot, and `released` is unreachable -- §13 gives the output leaf to the
# execution identity and nothing released can remove it, so `cleaned` cannot
# truthfully be recorded and `released` is only reachable from `cleaned`.
#
# `CONCLUDED` closes that. This proves it closes exactly what it claims, refuses
# everything else, and never invents evidence. Everything runs against fixtures;
# no production path is opened.
#
# Governed by docs/decisions/ADR-0017-post-execution-lifecycle-conclusion.md

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

# ===========================================================================
# 0. The purity backstop
# ===========================================================================
#
# It closes a lifecycle. It must not be able to do anything else: no process, no
# container runtime, no deletion, and no clock. `datetime` IS imported and that
# is deliberate -- the module PARSES a caller-supplied `recorded_at` and refuses
# one without an offset; it never asks what time it is.

printf -- '--- purity backstop ---\n'

backstop="$(cd "${ROOT}" && python3 - <<'SCANPY'
import ast
source = open('tools/capability/execution/conclusion.py', encoding='utf-8').read()
tree = ast.parse(source)
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef)) and body
            and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        del body[0]
ast.fix_missing_locations(tree)
code = ast.unparse(tree)

problems = []
for banned in ('subprocess', 'podman', 'Podman', 'os.system', 'shutil',
               'rmtree', 'unlink', 'rmdir', 'remove('):
    if banned in code:
        problems.append(f'reaches {banned}')
for banned in ('.now(', '.today(', 'monotonic', 'time.time'):
    if banned in code:
        problems.append(f'reads a clock via {banned}')
# It must not write a result, of any outcome.
for banned in ('record_terminal_result', 'RESULT_KIND_WRITE'):
    if banned in code:
        problems.append(f'writes a result via {banned}')
print('; '.join(problems) if problems else 'clean')
SCANPY
)"
if [[ "${backstop}" == "clean" ]]; then
  pass "conclusion.py starts no process, deletes nothing, fabricates no result and reads no clock"
else
  fail "conclusion.py purity backstop: ${backstop}"
fi

# The verb carries no destruction authority.
run_case "conclude is absent from the destruction-authority mapping" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution import admin
assert admin.Verb.CONCLUDE not in admin._DESTROYS_UNDER, 'conclude may destroy'
assert admin.is_mutating(admin.Verb.CONCLUDE), 'conclude must need a CADM'
"

printf -- '\n--- the state itself ---\n'

run_case "concluded is terminal, holds no slot, and is not released or abandoned" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution import capacity, state
from tools.capability.execution.types import LifecycleState as L
allowed = getattr(state, '_ALLOWED')
assert allowed[L.CONCLUDED] == frozenset(), allowed[L.CONCLUDED]
assert L.CONCLUDED in capacity.NON_SLOT_HOLDING_STATES
assert L.CONCLUDED not in capacity.SLOT_HOLDING_STATES
assert L.CONCLUDED is not L.RELEASED and L.CONCLUDED is not L.ABANDONED
assert capacity.MAXIMUM_SLOTS == 2, capacity.MAXIMUM_SLOTS
"

run_case "launch_authorized is the only state that reaches concluded" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution import state
from tools.capability.execution.types import LifecycleState as L
allowed = getattr(state, '_ALLOWED')
reaching = {s for s, targets in allowed.items() if L.CONCLUDED in targets}
assert reaching == {L.LAUNCH_AUTHORIZED}, sorted(x.value for x in reaching)
# and the edges that already existed are untouched
assert L.CREATED in allowed[L.LAUNCH_AUTHORIZED]
assert L.ABANDONED in allowed[L.LAUNCH_AUTHORIZED]
assert allowed[L.CLEANED] == frozenset({L.RELEASED})
assert allowed[L.RELEASED] == frozenset()
assert allowed[L.ABANDONED] == frozenset()
"

run_case "recovery never offers a concluded invocation as resumable" "
import sys; sys.path.insert(0, '.')
from tools.capability.execution import recovery
from tools.capability.execution.types import LifecycleState as L
assert L.CONCLUDED in getattr(recovery, '_ADMINISTRATIVELY_CLOSED')
assert recovery._container_possible(L.CONCLUDED) is False
assert recovery._container_possible(L.ABANDONED) is False
assert recovery._container_possible(L.LAUNCH_AUTHORIZED) is True
"

# ===========================================================================
# 1. Behaviour, against fixtures
# ===========================================================================

PRELUDE="
import json, os, shutil, sys
sys.path.insert(0, '.')
from datetime import datetime, timedelta, timezone
from tools.capability.errors import CapabilityError
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.state import (
    current_state, transition, TRANSITIONS_DIRECTORY, LOCKS_DIRECTORY)
from tools.capability.execution import capacity as capacity_module
from tools.capability.execution import state as sm
from tools.capability.execution.capacity import reserve, MAXIMUM_SLOTS
from tools.capability.execution.conclusion import (
    conclude, ConclusionRefused, existing_conclusion,
    DERIVATION_OBSERVED, DERIVATION_RECONSTRUCTED, CONCLUSION)
WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
WHEN = '2026-09-22T12:30:00-05:00'

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

def ready(name):
    base = make(name)
    return base, anchor(base)

def at_launch_authorized(root, cinv):
    reserve(root, cinv)
    transition(root, cinv, LifecycleState.RESERVED,
               LifecycleState.LAUNCH_AUTHORIZED)

def occupancy(root):
    holding = capacity_module.slot_holding_states()
    return sum(1 for v in sm.all_states(root).values() if v in holding)

def cmut_counter(base):
    with open(os.path.join(base, 'root', CMUT_COUNTER), 'rb') as handle:
        return handle.read().decode().strip()

def cmuts(base):
    directory = os.path.join(base, 'root', 'mutations')
    return sorted(os.listdir(directory)) if os.path.isdir(directory) else []

def transition_targets(base):
    '''Which transition each CMUT was opened for, read from its own intent.'''
    out = {}
    for name in cmuts(base):
        intent = os.path.join(base, 'root', 'mutations', name, 'intent')
        if not os.path.isfile(intent):
            continue
        document = json.loads(open(intent, encoding='utf-8').read())
        out[name] = (document.get('target_kind'), document.get('target_name'))
    return out

class FakeStore:
    def __init__(self, invocations, results):
        self._i = dict(invocations); self._r = dict(results)
    def read_record(self, kind, identity):
        table = self._i if kind == 'capability-invocation' else self._r
        if identity not in table:
            raise CapabilityError(f'{identity} is not a known {kind}')
        return dict(table[identity])
    def list_records(self, kind):
        table = self._i if kind == 'capability-invocation' else self._r
        return [dict(v) for v in table.values()]

def store_with(result=True, outcome='completed', bound='CINV-000003',
               extra=None, identity_field='capability_result_id'):
    inv = {'CINV-000001': {'invocation_record_id': 'CINV-000001',
                           'invocation_id': 'first', 'adapter_identity': None},
           'CINV-000003': {'invocation_record_id': 'CINV-000003',
                           'invocation_id': 'third', 'adapter_identity': None}}
    res = {}
    if result:
        res['CRES-000002'] = {identity_field: 'CRES-000002',
                              'invocation_record_id': bound,
                              'outcome_class': outcome,
                              'result_digest': 'sha256:' + 'f' * 64}
    if extra:
        res.update(extra)
    return FakeStore(inv, res)

def accepted(root, cinv='CINV-000003', **kw):
    kw.setdefault('store', store_with())
    kw.setdefault('actor', 'primary-platform-operator')
    kw.setdefault('request_id', 'g11bcad-conclude-' + cinv.lower())
    kw.setdefault('recorded_at', WHEN)
    kw.setdefault('derivation', DERIVATION_RECONSTRUCTED)
    return conclude(execution_root=root, cinv=cinv, **kw)
"

printf -- '\n--- the accepted closure ---\n'

run_case "concluding a stranded executed invocation releases exactly one slot" "${PRELUDE}
base, root = ready('c1')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000003')
assert occupancy(root) == 2, occupancy(root)
out = accepted(root)
assert out.state == 'concluded', out
assert out.previous_state == 'launch_authorized', out
assert out.result_record_id == 'CRES-000002', out
assert out.slot_released is True and out.resumed is False, out
assert out.handoff_retained is True, out
assert current_state(root, 'CINV-000003') is LifecycleState.CONCLUDED
assert occupancy(root) == 1, occupancy(root)
# the other invocation is untouched
assert current_state(root, 'CINV-000001') is LifecycleState.LAUNCH_AUTHORIZED
"

run_case "the conclusion writes intent, detail and outcome, in that order" "${PRELUDE}
base, root = ready('c2')
at_launch_authorized(root, 'CINV-000003')
out = accepted(root)
records = os.path.join(base, 'root', 'admin-records', out.cadm)
present = sorted(os.listdir(records))
assert present == ['conclusion', 'intent', 'outcome'], present
import json
detail = json.loads(open(os.path.join(records, CONCLUSION), encoding='utf-8').read())
assert detail['cinv'] == 'CINV-000003'
assert detail['state'] == 'concluded'
assert detail['previous_state'] == 'launch_authorized'
assert detail['result_record_id'] == 'CRES-000002'
assert detail['derivation'] == 'reconstructed'
assert detail['handoff_retained'] is True
assert detail['slot_released'] is True
intent = json.loads(open(os.path.join(records, 'intent'), encoding='utf-8').read())
assert intent['verb'] == 'conclude', intent
"

run_case "an identical repeat resumes, releases no second slot and writes nothing" "${PRELUDE}
base, root = ready('c3')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000003')
first = accepted(root)
before = sorted(os.listdir(os.path.join(base, 'root', 'admin-records')))
again = accepted(root)
after = sorted(os.listdir(os.path.join(base, 'root', 'admin-records')))
assert again.resumed is True and again.slot_released is False, again
assert before == after, (before, after)
assert occupancy(root) == 1, occupancy(root)
"

run_case "a repeat differing in any recorded field is refused, naming the field" "${PRELUDE}
base, root = ready('c4')
at_launch_authorized(root, 'CINV-000003')
accepted(root)
for field, kw in (('actor', {'actor': 'someone-else'}),
                  ('request_id', {'request_id': 'another-request'}),
                  ('recorded_at', {'recorded_at': '2026-09-22T13:00:00-05:00'}),
                  ('derivation', {'derivation': DERIVATION_OBSERVED})):
    try:
        accepted(root, **kw)
    except ConclusionRefused as error:
        assert 'differs in ' + field in str(error), (field, str(error))
    else:
        raise AssertionError('a differing ' + field + ' was accepted')
"

# ===========================================================================
# 2. The failure matrix
# ===========================================================================
#
# Each sabotage must reach ITS OWN gate. A refusal for the right reason is the
# assertion; a refusal for any other reason would mean the gate under test was
# never reached and something earlier answered for it.

# ===========================================================================
# 1b. The mutation substrate the transition rides on
# ===========================================================================
#
# G11-BC-AG. The closure ceremony asserted `cmut-counter MUST still be
# 000000000010` and production came back at 000000000011. The assertion was
# hard-coded from an assumption about the mutation shape; this suite had the
# substrate live in its fixture and never once read it.
#
# The truthful expectation is DERIVED, not written down: `state._commit` --
# which every lifecycle transition goes through -- opens a Mutation, so the
# CMUT count moves by exactly the number of transitions written. These cases
# assert that relationship, so a future change to the substrate fails here
# rather than in production.

printf -- '\n--- the mutation substrate ---\n'

run_case "a conclusion spends exactly one CMUT, and it names the transition it wrote" "${PRELUDE}
base, root = ready('m1')
at_launch_authorized(root, 'CINV-000003')
before = cmut_counter(base)
before_set = set(cmuts(base))
out = accepted(root)
after = cmut_counter(base)
# Derived from the substrate, not asserted as a literal: one transition was
# written, so exactly one CMUT was opened.
assert int(after) == int(before) + 1, (before, after)
new = set(cmuts(base)) - before_set
assert len(new) == 1, sorted(new)
name = new.pop()
kind, target = transition_targets(base)[name]
assert kind == 'execution-transition', kind
# ...and it names THIS invocation's newest transition, not some other object.
assert target.startswith('CINV-000003.'), target
assert target == 'CINV-000003.%06d' % len([
    t for t in os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))
    if t.startswith('CINV-000003.')]), target
"

run_case "the CMUT pins the bytes the transition actually committed" "${PRELUDE}
import hashlib
base, root = ready('m2')
at_launch_authorized(root, 'CINV-000003')
before_set = set(cmuts(base))
accepted(root)
name = (set(cmuts(base)) - before_set).pop()
intent = json.loads(open(os.path.join(base, 'root', 'mutations', name, 'intent'),
                         encoding='utf-8').read())
written = open(os.path.join(base, 'root', TRANSITIONS_DIRECTORY,
                            intent['target_name']), 'rb').read()
assert intent['expected_sha256'] == hashlib.sha256(written).hexdigest(), intent
outcome = json.loads(open(os.path.join(base, 'root', 'mutations', name, 'outcome'),
                          encoding='utf-8').read())
assert outcome['installed'] is True, outcome
"

run_case "the CMUT count tracks transitions one for one, across the whole history" "${PRELUDE}
base, root = ready('m3')
# reserve + authorise are two transitions, the conclusion is a third.
at_launch_authorized(root, 'CINV-000003')
accepted(root)
transitions = [t for t in os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))]
targets = [t for _, t in transition_targets(base).values()]
# Every transition on disk is named by exactly one CMUT, and nothing else is.
assert sorted(targets) == sorted(transitions), (sorted(targets), sorted(transitions))
assert int(cmut_counter(base)) == len(transitions), (cmut_counter(base), transitions)
"

run_case "the conclusion's whole durable footprint is the three things it writes" "${PRELUDE}
base, root = ready('m4')
at_launch_authorized(root, 'CINV-000003')
def snapshot():
    out = {}
    for here, _, names in os.walk(os.path.join(base, 'root')):
        for name in names:
            path = os.path.join(here, name)
            out[os.path.relpath(path, os.path.join(base, 'root'))] = open(path, 'rb').read()
    return out
before = snapshot()
accepted(root)
after = snapshot()
created = sorted(set(after) - set(before))
changed = sorted(k for k in set(after) & set(before) if after[k] != before[k])
# One transition, one CMUT (intent + outcome), one CADM (intent + detail +
# outcome) -- and the two counters they advanced. Nothing else, proved by
# content rather than by listing what was expected to move.
assert len(created) == 6, created
assert sum(1 for k in created if k.startswith(TRANSITIONS_DIRECTORY)) == 1, created
assert sum(1 for k in created if k.startswith('mutations/')) == 2, created
assert sum(1 for k in created if k.startswith('admin-records/')) == 3, created
assert changed == ['cadm-counter', CMUT_COUNTER], changed
"

printf -- '\n--- the failure matrix ---\n'

run_case "result missing: refused, and pointed at recovery rather than closed" "${PRELUDE}
base, root = ready('f1')
at_launch_authorized(root, 'CINV-000003')
try:
    accepted(root, store=store_with(result=False))
except ConclusionRefused as error:
    assert 'has no terminal result' in str(error), str(error)
    assert 'recovery' in str(error), str(error)
else:
    raise AssertionError('an unexecuted invocation was concluded')
assert current_state(root, 'CINV-000003') is LifecycleState.LAUNCH_AUTHORIZED
assert occupancy(root) == 1, occupancy(root)
assert os.listdir(os.path.join(base, 'root', 'admin-records')) == []
"

run_case "wrong result identity: a result bound to another invocation is not this one's" "${PRELUDE}
base, root = ready('f2')
at_launch_authorized(root, 'CINV-000003')
try:
    accepted(root, store=store_with(bound='CINV-000001'))
except ConclusionRefused as error:
    assert 'has no terminal result' in str(error), str(error)
else:
    raise AssertionError('a result bound elsewhere was accepted as this one')
assert current_state(root, 'CINV-000003') is LifecycleState.LAUNCH_AUTHORIZED
"

run_case "more than one result: refused rather than one of them chosen" "${PRELUDE}
base, root = ready('f3')
at_launch_authorized(root, 'CINV-000003')
extra = {'CRES-000009': {'capability_result_id': 'CRES-000009',
                         'invocation_record_id': 'CINV-000003',
                         'outcome_class': 'completed'}}
try:
    accepted(root, store=store_with(extra=extra))
except ConclusionRefused as error:
    assert 'more than one terminal result' in str(error), str(error)
else:
    raise AssertionError('an ambiguous result set was resolved silently')
"

run_case "a result carrying no identity is refused, not read as absent" "${PRELUDE}
base, root = ready('f4')
at_launch_authorized(root, 'CINV-000003')
try:
    accepted(root, store=store_with(identity_field='result_record_id'))
except ConclusionRefused as error:
    assert 'carries no capability_result_id' in str(error), str(error)
else:
    raise AssertionError('a result with no identity was accepted')
"

run_case "lifecycle not expected: every other state is refused by name" "${PRELUDE}
base, root = ready('f5')
# reserved -- before the coordinator handed anything over
reserve(root, 'CINV-000003')
try:
    accepted(root)
except ConclusionRefused as error:
    assert 'is reserved' in str(error), str(error)
    assert 'closes an invocation at launch_authorized' in str(error), str(error)
else:
    raise AssertionError('a reserved invocation was concluded')
assert current_state(root, 'CINV-000003') is LifecycleState.RESERVED
"

run_case "an abandoned invocation cannot be concluded" "${PRELUDE}
base, root = ready('f6')
at_launch_authorized(root, 'CINV-000003')
transition(root, 'CINV-000003', LifecycleState.LAUNCH_AUTHORIZED,
           LifecycleState.ABANDONED)
try:
    accepted(root)
except ConclusionRefused as error:
    assert 'is abandoned' in str(error), str(error)
else:
    raise AssertionError('an abandoned invocation was concluded')
assert current_state(root, 'CINV-000003') is LifecycleState.ABANDONED
"

run_case "an invocation with no execution state at all is refused" "${PRELUDE}
base, root = ready('f7')
try:
    accepted(root)
except ConclusionRefused as error:
    assert 'has no execution state' in str(error), str(error)
else:
    raise AssertionError('an invocation with no state was concluded')
"

run_case "CINV changed: an unreadable invocation is refused before anything else" "${PRELUDE}
base, root = ready('f8')
at_launch_authorized(root, 'CINV-000003')
store = FakeStore({}, {})
try:
    accepted(root, store=store)
except ConclusionRefused as error:
    assert 'is not a readable invocation' in str(error), str(error)
else:
    raise AssertionError('an absent invocation record was concluded')
assert current_state(root, 'CINV-000003') is LifecycleState.LAUNCH_AUTHORIZED
"

run_case "conflicting closure: a conclusion record while the journal disagrees" "${PRELUDE}
base, root = ready('f9')
at_launch_authorized(root, 'CINV-000003')
out = accepted(root)
# Rewind the journal under the evidence: the record now claims a closure the
# lifecycle does not carry.
import shutil as _sh
_sh.rmtree(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))
os.makedirs(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))
at_launch_authorized(root, 'CINV-000003')
try:
    accepted(root)
except ConclusionRefused as error:
    assert 'carries a conclusion record while it is launch_authorized' in str(error), str(error)
    assert 'disagree' in str(error), str(error)
else:
    raise AssertionError('a lifecycle/evidence disagreement was resolved silently')
"

run_case "concluded with no conclusion record is a disagreement, not a resume" "${PRELUDE}
base, root = ready('f10')
at_launch_authorized(root, 'CINV-000003')
transition(root, 'CINV-000003', LifecycleState.LAUNCH_AUTHORIZED,
           LifecycleState.CONCLUDED)
try:
    accepted(root)
except ConclusionRefused as error:
    assert 'concluded with no conclusion record' in str(error), str(error)
else:
    raise AssertionError('a concluded state with no evidence was accepted')
"

run_case "capacity mismatch cannot be manufactured: no second slot is ever released" "${PRELUDE}
base, root = ready('f11')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000003')
assert occupancy(root) == 2
accepted(root)
assert occupancy(root) == 1
for _ in range(3):
    again = accepted(root)
    assert again.slot_released is False and again.resumed is True
assert occupancy(root) == 1, occupancy(root)
"

run_case "an unverified root is refused before any read" "${PRELUDE}
base, root = ready('f12')
at_launch_authorized(root, 'CINV-000003')
for bogus in (None, object(), base):
    try:
        conclude(store=store_with(), execution_root=bogus, cinv='CINV-000003',
                 actor='a', request_id='r', recorded_at=WHEN)
    except ConclusionRefused as error:
        assert 'verified RootDescriptor' in str(error), str(error)
    else:
        raise AssertionError('an unverified root was accepted')
"

run_case "a naive or malformed recorded_at is refused" "${PRELUDE}
base, root = ready('f13')
at_launch_authorized(root, 'CINV-000003')
for bad, expect in (('2026-09-22T12:30:00', 'timezone offset'),
                    ('not-a-time', 'ISO-8601'),
                    ('', 'non-empty'),
                    (datetime(2026, 9, 22, 12, 30), 'timezone offset')):
    try:
        accepted(root, recorded_at=bad)
    except ConclusionRefused as error:
        assert expect in str(error), (bad, str(error))
    else:
        raise AssertionError('a bad recorded_at was accepted: ' + repr(bad))
"

run_case "an uncontrolled derivation is refused" "${PRELUDE}
base, root = ready('f14')
at_launch_authorized(root, 'CINV-000003')
for bad in ('guessed', 'assumed', '', 'OBSERVED'):
    try:
        accepted(root, derivation=bad)
    except ConclusionRefused as error:
        assert 'derivation' in str(error) or 'non-empty' in str(error), str(error)
    else:
        raise AssertionError('an uncontrolled derivation was accepted: ' + bad)
"

run_case "an empty actor or request id is refused" "${PRELUDE}
base, root = ready('f15')
at_launch_authorized(root, 'CINV-000003')
for kw in ({'actor': ''}, {'actor': '   '}, {'request_id': ''}, {'actor': None}):
    try:
        accepted(root, **kw)
    except ConclusionRefused as error:
        assert 'non-empty string' in str(error), str(error)
    else:
        raise AssertionError('an empty field was accepted: ' + repr(kw))
"

run_case "a refusal writes nothing at all: no CADM, no transition, no counter move" "${PRELUDE}
base, root = ready('f16')
at_launch_authorized(root, 'CINV-000003')
records = os.path.join(base, 'root', 'admin-records')
counter = os.path.join(base, 'root', 'cadm-counter')
before_counter = open(counter, 'rb').read()
# BOTH counters. G11-BC-AG: this case was titled 'no counter move' and read
# only the CADM one, so a refusal that had spent a CMUT would have passed it.
before_cmut = cmut_counter(base)
before_cmuts = cmuts(base)
before_states = dict(sm.all_states(root))
for kw in ({'store': store_with(result=False)}, {'actor': ''},
           {'recorded_at': 'not-a-time'}, {'derivation': 'guessed'}):
    try:
        accepted(root, **kw)
    except ConclusionRefused:
        pass
    else:
        raise AssertionError('expected a refusal for ' + repr(kw))
assert os.listdir(records) == [], os.listdir(records)
assert open(counter, 'rb').read() == before_counter
assert cmut_counter(base) == before_cmut, cmut_counter(base)
assert cmuts(base) == before_cmuts, cmuts(base)
assert dict(sm.all_states(root)) == before_states
assert occupancy(root) == 1, occupancy(root)
"

run_case "an error outcome is concluded too: the state is about the lifecycle" "${PRELUDE}
base, root = ready('f17')
at_launch_authorized(root, 'CINV-000003')
# 'concluded' says the execution ran and concluded and that cleanup did not. It
# says nothing about whether the capability succeeded -- the CRES does, and is
# referenced rather than reinterpreted.
out = accepted(root, store=store_with(outcome='provider-error'))
assert out.state == 'concluded', out
assert out.result_record_id == 'CRES-000002', out
assert current_state(root, 'CINV-000003') is LifecycleState.CONCLUDED
"

# ===========================================================================
# 3. The operator surface
# ===========================================================================

printf -- '\n--- the operator surface ---\n'

run_case "conclude names no target state: no --to, no --force, no --state" "
import sys; sys.path.insert(0, '.')
from tools.capability import cli
parser = cli.build_parser() if hasattr(cli, 'build_parser') else None
import argparse, io, contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    try:
        cli.main(['conclude', '--help'])
    except SystemExit:
        pass
text = buf.getvalue()
for forbidden in ('--to', '--force', '--state', '--reason'):
    assert forbidden not in text, forbidden
for required in ('--store-root', '--expected-uid', '--expected-gid', '--cinv',
                 '--actor', '--request-id', '--recorded-at'):
    assert required in text, required
"

run_case "conclude refuses without an explicit store root: there is no default" "
import sys, io, contextlib; sys.path.insert(0, '.')
from tools.capability import cli
buf = io.StringIO()
status = None
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    try:
        status = cli.main(
            ['conclude', '--expected-uid', '1000', '--expected-gid', '1000',
             '--cinv', 'CINV-000003', '--actor', 'a', '--request-id', 'r',
             '--recorded-at', '2026-09-22T12:30:00-05:00'])
    except SystemExit as exit_error:
        status = exit_error.code
# Nonzero however the surface chooses to report it -- argparse returns rather
# than raising here, and a test that only caught SystemExit would pass on a
# build where the flag stopped being required.
assert status not in (0, None), (status, buf.getvalue())
assert 'store-root' in buf.getvalue(), buf.getvalue()
"

run_case "the execute surface reports the closure beside the result" "
import sys, inspect; sys.path.insert(0, '.')
from tools.capability import cli
source = inspect.getsource(cli.command_execute)
# The result is written first and stands whatever the closure does: a recorded
# execution must never be lost because the closure that follows it failed.
assert source.index('execute_supervised') < source.index('conclusion.conclude')
for field in ('lifecycle_state', 'slot_released', 'conclusion_cadm',
              'conclusion_refused'):
    assert field in source, field
assert 'DERIVATION_OBSERVED' in source, 'the inline closure must record observation'
"

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'Capability execution conclusion validation passed.\n'
else
  printf 'Capability execution conclusion validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
