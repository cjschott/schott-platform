#!/usr/bin/env bash
set -Eeuo pipefail

# ADR-0016 / ADR-0018 provenance-correction COMPATIBILITY.
#
# WHAT THIS SUITE IS FOR. CADM-000002 was written under ADR-0016 and carries no
# `actual_occurrence_at`. ADR-0018 added that member and the create-once resume
# check compares EVERY recorded field, so against a Generation-22 runtime there
# was no call that could resume it:
#
#   supply the field  ->  ProvenanceRefused: already corrected under DIFFERENT
#                         AUTHORITY (actual_occurrence_at None, not '...')
#   omit the field    ->  TypeError: missing 1 required keyword-only argument
#
# Both fail closed, so no record could be damaged. But the refusal named the
# WRONG CAUSE: the authority is identical, and only the record SHAPE differs.
# In the provenance subsystem specifically, a refusal that misdescribes itself is
# the defect this whole arc exists to remove, which is why it is worth a
# generation of its own.
#
# THE RULE THIS SUITE SPECIFIES, from the reviewer's G11-BC-AL ruling:
#
#   1. ADR-0016-era records stay immutable. Nothing is retrofitted into them.
#   2. A member the prior record does not carry, and which a later ADR added, is
#      a LEGACY RECORD SHAPE -- never evidence of different authority.
#   3. Every authority-bearing member the prior record DOES carry must match, or
#      it refuses, naming the member.
#   4. A member absent from the prior record that is NOT a known later-schema
#      addition is a shape this runtime cannot compare, and that fails closed
#      with a schema reason rather than a guess.
#   5. The resume reports what the legacy record HOLDS -- which for
#      `actual_occurrence_at` is nothing at all. It does not report back the
#      value the caller supplied, because the record does not carry it.
#
# NO VERSION BUMP. §B of the ruling asked whether the released records already
# carry enough structure to tell the two shapes apart. They do, and this suite
# proves it from the real records: `correction_schema_version` is 1 on BOTH
# shapes, so the version is no discriminator at all, while the presence of
# `actual_occurrence_at` is total -- the ADR-0018 source writes it
# unconditionally, and the ADR-0016 source had no such field.
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

# The legacy shape, synthesised from the ADR-0018 shape by removing exactly the
# member ADR-0018 added -- and then CHECKED against the real CADM-000002 key set,
# so the fixture is proved to be the historical shape rather than assumed to be.
LEGACY="${PRELUDE}
from tools.capability.execution.provenance import (
    INITIATOR_UNKNOWN, LATER_SCHEMA_MEMBERS, MEMBER_ACTUAL_OCCURRENCE_AT)
LEGACY_FIELD = MEMBER_ACTUAL_OCCURRENCE_AT

def make_legacy(name, **overrides):
    '''An accepted correction, then reshaped into the ADR-0016 record shape.

    The member is removed from the durable record only. Nothing retrofits
    anything INTO a record, which is the direction the ruling forbids.
    '''
    base, root = incident(name)
    out = correct_provenance(execution_root=root, **correction('actor', **overrides))
    path = os.path.join(base, 'root', 'admin-records', out.cadm,
                        'provenance-correction')
    document = json.loads(open(path, encoding='utf-8').read())
    assert LEGACY_FIELD in document, 'the ADR-0018 shape should carry it'
    del document[LEGACY_FIELD]
    os.chmod(path, 0o600)
    with open(path, 'wb') as handle:
        handle.write(serialise(document))
    os.chmod(path, 0o400)
    return base, root, out.cadm, document
"

printf -- '--- the two shapes, and what tells them apart ---\n'

run_case "the released source writes actual_occurrence_at unconditionally" "
import ast, sys
tree = ast.parse(open('tools/capability/execution/provenance.py',
                      encoding='utf-8').read())
fn = next(n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == 'correct_provenance')
# The detail dict is a flat literal, and nothing conditional encloses it -- so an
# ADR-0018-era record ALWAYS carries the member, which is what makes its absence
# a reliable marker of the older shape.
def enclosing(node, target, trail=()):
    for child in ast.iter_child_nodes(node):
        if child is target:
            return trail + (type(node).__name__,)
        found = enclosing(child, target, trail + (type(node).__name__,))
        if found:
            return found
    return None
detail = [n for n in ast.walk(fn)
          if isinstance(n, ast.Assign)
          and any(getattr(t, 'id', None) == 'detail' for t in n.targets)][-1]
trail = enclosing(fn, detail)
assert not any(k in ('If', 'IfExp') for k in trail), trail
keys = [k.value for k in detail.value.keys]
assert 'actual_occurrence_at' in keys, keys
print('unconditional, among', len(keys), 'members')
"

run_case "the schema version is no discriminator: it is 1 on both shapes" "${LEGACY}
base, root, cadm, legacy = make_legacy('s1')
assert legacy['correction_schema_version'] == 1, legacy
base2, root2 = incident('s2')
modern = existing_correction(root2, 'CADM-000001', 'actor') if False else None
out = correct_provenance(execution_root=root2, **correction('actor'))
modern = existing_correction(root2, 'CADM-000001', 'actor')
assert modern['correction_schema_version'] == 1, modern
assert 'actual_occurrence_at' in modern
assert 'actual_occurrence_at' not in legacy
# One member apart, and the version identical. Shape is the only discriminator.
assert set(modern) - set(legacy) == {'actual_occurrence_at'}, set(modern) ^ set(legacy)
"

printf -- '\n--- the legacy fixture is the historical shape, not a guess ---\n'

# Against the REAL CADM-000002 when this is run on the host that holds it. The
# suite stays portable: where production is not readable the check is skipped by
# declaration and says so, rather than silently proving less.
PRODUCTION_LEGACY=/data/kyri/capability-runtime/execution/admin-records/CADM-000002/provenance-correction
if [[ -r "${PRODUCTION_LEGACY}" ]]; then
  run_case "the synthesised legacy shape matches production's real CADM-000002" "${LEGACY}
base, root, cadm, legacy = make_legacy('r1')
real = json.loads(open('${PRODUCTION_LEGACY}', encoding='utf-8').read())
assert set(real) == set(legacy), sorted(set(real) ^ set(legacy))
assert 'actual_occurrence_at' not in real
assert real['correction_schema_version'] == 1
print('key sets identical:', len(real), 'members')
"
else
  printf 'note: production CADM-000002 is not readable here; the synthesised shape is checked against the source instead\n'
fi

printf -- '\n--- a legacy record resumes, and is not called different authority ---\n'

run_case "an identical request against a legacy record RESUMES" "${LEGACY}
base, root, cadm, legacy = make_legacy('g1')
before = snapshot(base)
out = correct_provenance(execution_root=root, **correction('actor'))
assert out.resumed is True, out.resumed
assert out.cadm == cadm, (out.cadm, cadm)
# And it wrote nothing: a resume is a report, not a mutation.
assert snapshot(base) == before, 'the resume mutated the store'
"

run_case "the resume reports what the legacy record HOLDS, and invents nothing" "${LEGACY}
base, root, cadm, legacy = make_legacy('g2')
out = correct_provenance(execution_root=root, **correction('actor'))
# The caller supplied an occurrence. The record does not carry one, so the result
# must not claim it does.
assert out.actual_occurrence_at is None, repr(out.actual_occurrence_at)
# And the durable record is untouched: still no such member.
again = existing_correction(root, 'CADM-000001', 'actor')
assert 'actual_occurrence_at' not in again, sorted(again)
"

run_case "the refusal never again calls an absent later member 'different authority'" "${LEGACY}
base, root, cadm, legacy = make_legacy('g3')
try:
    out = correct_provenance(execution_root=root, **correction('actor'))
except ProvenanceRefused as error:
    raise AssertionError('refused a legitimate legacy resume: ' + str(error))
# The phrase must not be reachable for this case at all.
assert out.resumed is True
"

printf -- '\n--- a real conflict still refuses, on the members the record carries ---\n'

run_case "a different actor still refuses, naming the member" "${LEGACY}
base, root, cadm, legacy = make_legacy('c1')
before = snapshot(base)
try:
    correct_provenance(execution_root=root,
                       **correction('actor', actor='somebody-else'))
except ProvenanceRefused as error:
    assert 'different authority' in str(error), str(error)
    assert 'actor' in str(error), str(error)
else:
    raise AssertionError('a conflicting actor was accepted')
assert snapshot(base) == before
"

run_case "a different initiator, request_id or recorded_at each still refuses" "${LEGACY}
for n, override in enumerate((dict(actual_initiator=INITIATOR_UNKNOWN),
                              dict(request_id='another-request'),
                              dict(recorded_at='2026-09-28T09:00:00-05:00'))):
    base, root, cadm, legacy = make_legacy('c2-%d' % n)
    before = snapshot(base)
    try:
        correct_provenance(execution_root=root, **correction('actor', **override))
    except ProvenanceRefused as error:
        assert 'different authority' in str(error), str(error)
        key = sorted(override)[0]
        assert key in str(error), (key, str(error))
    else:
        raise AssertionError('a conflicting %s was accepted' % sorted(override)[0])
    assert snapshot(base) == before
"

run_case "a different finding still refuses: the legacy rule widens nothing else" "${LEGACY}
base, root, cadm, legacy = make_legacy('c3')
try:
    correct_provenance(execution_root=root,
                       **correction('actor', finding=FINDING_SYNTHETIC))
except ProvenanceRefused as error:
    assert 'different authority' in str(error), str(error)
    assert 'finding' in str(error), str(error)
else:
    raise AssertionError('a conflicting finding was accepted')
"

printf -- '\n--- an unknown older shape fails closed, with a schema reason ---\n'

run_case "a record missing a member no ADR ever removed is refused as uncomparable" "${LEGACY}
base, root = incident('u1')
out = correct_provenance(execution_root=root, **correction('actor'))
path = os.path.join(base, 'root', 'admin-records', out.cadm,
                    'provenance-correction')
document = json.loads(open(path, encoding='utf-8').read())
# 'actor' is authority-bearing and no ADR has ever added or removed it, so a
# record without it is a shape this runtime has no rule for.
del document['actor']
os.chmod(path, 0o600)
open(path, 'wb').write(serialise(document))
os.chmod(path, 0o400)
before = snapshot(base)
try:
    correct_provenance(execution_root=root, **correction('actor'))
except ProvenanceRefused as error:
    message = str(error)
    assert 'different authority' not in message, message
    assert 'actor' in message, message
    assert ('schema' in message or 'shape' in message), message
else:
    raise AssertionError('an uncomparable record shape was accepted')
assert snapshot(base) == before, 'a refusal wrote something'
"

printf -- '\n--- the modern shape is unaffected ---\n'

run_case "an ADR-0018 record still resumes, reporting its own recorded instant" "${LEGACY}
base, root = incident('m1')
first = correct_provenance(execution_root=root, **correction('actor'))
before = snapshot(base)
again = correct_provenance(execution_root=root, **correction('actor'))
assert again.resumed is True
assert again.cadm == first.cadm
# Read back from the record, not echoed from the request.
assert again.actual_occurrence_at == OCCURRED, again.actual_occurrence_at
assert snapshot(base) == before
"

run_case "an ADR-0018 record with a different occurrence still refuses" "${LEGACY}
base, root = incident('m2')
correct_provenance(execution_root=root, **correction('actor'))
try:
    correct_provenance(execution_root=root,
                       **correction('actor',
                                    actual_occurrence_at='2026-09-25T06:40:43-05:00'))
except ProvenanceRefused as error:
    assert 'different authority' in str(error), str(error)
    assert 'actual_occurrence_at' in str(error), str(error)
else:
    raise AssertionError('a conflicting occurrence was accepted')
"

run_case "a legacy resume takes no slot, spends no mutation, moves no lifecycle" "${LEGACY}
base, root, cadm, legacy = make_legacy('i1')
before = dict(cmut=open(os.path.join(base, 'root', CMUT_COUNTER), 'rb').read(),
              cmuts=cmuts(base), occupancy=occupancy(root),
              states={k: v.value for k, v in sm.all_states(root).items()},
              transitions=sorted(os.listdir(os.path.join(base, 'root',
                                                         TRANSITIONS_DIRECTORY))),
              cadm_counter=open(os.path.join(base, 'root', 'cadm-counter'),
                                'rb').read())
correct_provenance(execution_root=root, **correction('actor'))
after = dict(cmut=open(os.path.join(base, 'root', CMUT_COUNTER), 'rb').read(),
             cmuts=cmuts(base), occupancy=occupancy(root),
             states={k: v.value for k, v in sm.all_states(root).items()},
             transitions=sorted(os.listdir(os.path.join(base, 'root',
                                                        TRANSITIONS_DIRECTORY))),
             cadm_counter=open(os.path.join(base, 'root', 'cadm-counter'),
                               'rb').read())
assert before == after, {k: (before[k], after[k])
                         for k in before if before[k] != after[k]}
"

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'ADR-0016/ADR-0018 correction compatibility validation passed.\n'
else
  printf 'ADR-0016/ADR-0018 correction compatibility validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
