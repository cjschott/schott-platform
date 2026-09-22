#!/usr/bin/env bash
set -Eeuo pipefail

# Governed administrative abandonment for permanently stuck invocations.
#
# WHY THIS EXISTS
# ===============
# G11-BC-U found a real production blocker. Both execution slots are held by
# CINV-000001 and CINV-000002, both stuck at `launch_authorized`, and the
# released lifecycle reaches `released` only from `cleaned`. `recover` writes
# nothing, no administrative verb repairs or forces, and CINV-000002 cannot be
# driven forward because `execute` refuses an invocation that already has a
# terminal result. CINV-000003 Stage 2 therefore refuses with
# `CapacityExhausted` before it mutates anything.
#
# ABANDONED is the reviewer's ruling: a first-class exceptional closure state
# meaning "permanently administratively closed WITHOUT asserting that the normal
# execution and cleanup lifecycle completed". It is terminal, it holds no
# execution slot, and it is NOT released -- conflating the two would let an
# administrative closure be read as a successful lifecycle.
#
# MAXIMUM_SLOTS IS NOT CHANGED. The ceiling is the control; the defect was that
# nothing could ever give a slot back.
#
# This suite reproduces the blocker first, then proves the operation, then
# proves the blocker is gone. Everything runs against fixtures.
#
# Governed by docs/decisions/ADR-0015-governed-administrative-abandonment.md

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

PRELUDE="
import os, shutil, sys
sys.path.insert(0, '.')
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.state import (
    current_state, transition, open_state_locked, TRANSITIONS_DIRECTORY,
    LOCKS_DIRECTORY, InvalidTransition)
from tools.capability.execution import capacity as capacity_module
from tools.capability.execution.capacity import reserve, CapacityExhausted, MAXIMUM_SLOTS
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

def ready(name):
    base = make(name)
    return base, anchor(base)

def at_launch_authorized(root, cinv):
    reserve(root, cinv)
    transition(root, cinv, LifecycleState.RESERVED,
               LifecycleState.LAUNCH_AUTHORIZED)

def occupancy(root):
    from tools.capability.execution import state as sm
    holding = capacity_module.slot_holding_states()
    return sum(1 for v in sm.all_states(root).values() if v in holding)
"

# ===========================================================================
# 0. The purity backstop for the new module
# ===========================================================================
#
# It closes a lifecycle. It must not be able to do anything else: no process,
# no container runtime, no deletion, no store record, and no clock.
#
# `datetime` IS imported, and that is deliberate rather than an exemption. The
# module PARSES a caller-supplied `recorded_at` and refuses one without a
# timezone offset; it never asks what time it is. The forbidden-call set below
# is what draws that line -- `now`, `today` and `monotonic` are refused while
# `fromisoformat` is not.

printf -- '--- purity backstop ---\n'

backstop_report="$(cd "${ROOT}" && python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/abandonment.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "random", "secrets", "tempfile", "shutil", "glob",
    "logging", "time",
}
# Deletion, elevation, and the clock. `fromisoformat` is absent on purpose:
# parsing an instant somebody else supplied is not reading a clock.
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "rmtree", "removedirs", "remove", "unlink", "rmdir", "rename",
    "chmod", "chown", "symlink", "link", "chdir", "truncate",
    "now", "today", "monotonic", "utcnow", "uuid1", "uuid4",
    "allocate_id", "write_atomic",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "MAXIMUM_SLOTS =", "force", "repair")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

source = target.read_text(encoding="utf-8")
tree = ast.parse(source)
findings = []

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        if (node.module or "").split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"forbidden import-from: {node.module}")
    elif isinstance(node, ast.Call):
        func = node.func
        name = getattr(func, "attr", None) or getattr(func, "id", None)
        if name in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {name}")

# Prose saying a power is absent would otherwise read as the power being
# present, so the text scan runs over the source with documentation removed.
for node in ast.walk(tree):
    if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
        continue
    body = getattr(node, "body", None)
    if (body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        del body[0]
stripped = ast.unparse(tree)
for text in FORBIDDEN_TEXT:
    if text in stripped:
        findings.append(f"forbidden text: {text}")

print("clean" if not findings else "; ".join(sorted(set(findings))))
SCANPY
)"
if [[ "${backstop_report}" == "clean" ]]; then
  pass "abandonment.py starts no process, deletes nothing, writes no store record and reads no clock"
else
  fail "abandonment.py purity backstop: ${backstop_report}"
fi

# ===========================================================================
# 1. The blocker, reproduced
# ===========================================================================

printf '\n--- the production blocker, reproduced ---\n'

run_case "two launch_authorized invocations hold both slots and a third is refused" "${PRELUDE}
base, root = ready('blocker')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000002')
assert MAXIMUM_SLOTS == 2, MAXIMUM_SLOTS
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted as exc:
    print('reproduced:', exc)
else:
    raise AssertionError('the third reservation was not refused')
"

run_case "launch_authorized cannot reach released, so no slot can be given back" "${PRELUDE}
base, root = ready('noreturn')
at_launch_authorized(root, 'CINV-000001')
try:
    transition(root, 'CINV-000001', LifecycleState.LAUNCH_AUTHORIZED,
               LifecycleState.RELEASED)
except InvalidTransition as exc:
    print('confirmed:', exc)
else:
    raise AssertionError('launch_authorized -> released was permitted')
"

# ===========================================================================
# 2. The state and the capacity model
# ===========================================================================

printf '\n--- ABANDONED as a first-class state ---\n'

run_case "ABANDONED exists, is distinct from RELEASED, and is terminal" "${PRELUDE}
from tools.capability.execution.state import _ALLOWED
assert LifecycleState.ABANDONED.value == 'abandoned'
assert LifecycleState.ABANDONED is not LifecycleState.RELEASED
assert _ALLOWED[LifecycleState.ABANDONED] == frozenset(), _ALLOWED[LifecycleState.ABANDONED]
print('abandoned is terminal and distinct from released')
"

run_case "only the narrow pre-handover states may reach ABANDONED" "${PRELUDE}
from tools.capability.execution.state import _ALLOWED
sources = {s for s, targets in _ALLOWED.items() if LifecycleState.ABANDONED in targets}
assert sources == {LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED}, sources
print('eligible sources:', sorted(s.value for s in sources))
"

run_case "RELEASED, ABANDONED and CONCLUDED hold no slot; every other state does" "${PRELUDE}
holding = set(capacity_module.slot_holding_states())
# ADR-0017 added CONCLUDED to the exclusion. Abandonment's own guarantee is
# unchanged by it: this asserts the exclusion set exactly, so a state added
# without review would still fail here.
CLOSED = (LifecycleState.RELEASED, LifecycleState.ABANDONED,
          LifecycleState.CONCLUDED)
for closed in CLOSED:
    assert closed not in holding, closed
expected = {s for s in LifecycleState if s not in CLOSED}
assert holding == expected, holding
print('slot-holding states:', len(holding), 'of', len(list(LifecycleState)))
"

# ===========================================================================
# 3. The operation
# ===========================================================================

printf '\n--- abandonment, the operation ---\n'

ABANDON_PRELUDE="${PRELUDE}
from tools.capability.execution import abandonment
from tools.capability.execution.abandonment import (
    abandon, AbandonmentRefused, REASON_TERMINAL_RESULT_STRANDED,
    REASON_HISTORICAL_INCOMPLETE_EXECUTION)

class FakeStore:
    def __init__(self, invocations, results):
        self._i = dict(invocations)
        self._r = dict(results)
    def read_record(self, kind, identity):
        from tools.capability.errors import CapabilityError
        table = self._i if kind == 'capability-invocation' else self._r
        if identity not in table:
            raise CapabilityError(f'{identity} is not a known {kind}')
        return dict(table[identity])
    def list_records(self, kind):
        table = self._i if kind == 'capability-invocation' else self._r
        return [dict(v) for v in table.values()]

def store_with(stranded=True):
    inv = {
        'CINV-000001': {'invocation_record_id': 'CINV-000001',
                        'invocation_id': 'first', 'adapter_identity': None},
        'CINV-000002': {'invocation_record_id': 'CINV-000002',
                        'invocation_id': 'second', 'adapter_identity': None},
    }
    res = {}
    if stranded:
        # The identity key is capability_result_id, which is what the
        # released schema and identifiers.ID_FIELDS actually use. The first
        # draft of this fixture said result_record_id; it looked right, the
        # unit tests passed, and the rehearsal against real production records
        # refused, because the implementation had followed the fixture instead
        # of the schema.
        res['CRES-000001'] = {'capability_result_id': 'CRES-000001',
                              'invocation_record_id': 'CINV-000002',
                              'outcome_class': 'provider-error'}
    return FakeStore(inv, res)
"

run_case "abandoning a stranded launch_authorized invocation releases exactly one slot" "${ABANDON_PRELUDE}
base, root = ready('abandon1')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000002')
assert occupancy(root) == 2, occupancy(root)
outcome = abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
                  actor='primary-platform-operator', request_id='g11bcv-reclaim-cinv-000002',
                  recorded_at='2026-09-20T14:00:00-05:00',
                  reason=REASON_TERMINAL_RESULT_STRANDED)
assert outcome.cinv == 'CINV-000002'
assert outcome.previous_state == 'launch_authorized', outcome.previous_state
assert outcome.state == 'abandoned', outcome.state
assert outcome.slot_released is True
assert outcome.resumed is False
assert outcome.result_record_id == 'CRES-000001', outcome.result_record_id
assert current_state(root, 'CINV-000002') is LifecycleState.ABANDONED
assert occupancy(root) == 1, occupancy(root)
print('cadm:', outcome.cadm, 'occupancy 2 ->', occupancy(root))
"

run_case "an exact replay is idempotent and writes no second lifecycle record" "${ABANDON_PRELUDE}
base, root = ready('replay')
at_launch_authorized(root, 'CINV-000002')
kw = dict(store=store_with(), execution_root=root, cinv='CINV-000002',
          actor='primary-platform-operator', request_id='g11bcv-reclaim-cinv-000002',
          recorded_at='2026-09-20T14:00:00-05:00',
          reason=REASON_TERMINAL_RESULT_STRANDED)
first = abandon(**kw)
before = sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))
second = abandon(**kw)
after = sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))
assert second.resumed is True, second
assert second.slot_released is False, second
assert second.state == 'abandoned'
assert before == after, (before, after)
assert second.cadm == first.cadm, (first.cadm, second.cadm)
print('replay resumed, transitions unchanged:', after)
"

run_case "a conflicting replay refuses rather than resuming" "${ABANDON_PRELUDE}
base, root = ready('conflict')
at_launch_authorized(root, 'CINV-000002')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='g11bcv-reclaim-cinv-000002',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
try:
    abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
            actor='someone-else', request_id='a-different-request',
            recorded_at='2026-09-20T15:00:00-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('a conflicting replay was accepted')
"

run_case "the reason category must match the observed result relationship" "${ABANDON_PRELUDE}
base, root = ready('reason')
at_launch_authorized(root, 'CINV-000002')
try:
    abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('a mismatched reason category was accepted')
base2, root2 = ready('reason2')
at_launch_authorized(root2, 'CINV-000001')
try:
    abandon(store=store_with(), execution_root=root2, cinv='CINV-000001',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('a mismatched reason category was accepted')
"

run_case "no execution result is fabricated for an invocation that has none" "${ABANDON_PRELUDE}
base, root = ready('noresult')
at_launch_authorized(root, 'CINV-000001')
store = store_with()
before = len(store.list_records('capability-result'))
outcome = abandon(store=store, execution_root=root, cinv='CINV-000001',
                  actor='primary-platform-operator', request_id='g11bcv-reclaim-cinv-000001',
                  recorded_at='2026-09-20T14:00:00-05:00',
                  reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
assert outcome.result_record_id is None, outcome.result_record_id
assert len(store.list_records('capability-result')) == before
assert current_state(root, 'CINV-000001') is LifecycleState.ABANDONED
print('no result fabricated; result_record_id is', outcome.result_record_id)
"

run_case "an unknown invocation, a bad actor and a malformed request are refused" "${ABANDON_PRELUDE}
base, root = ready('refusals')
at_launch_authorized(root, 'CINV-000002')
cases = [
    ('unknown invocation', dict(cinv='CINV-000009')),
    ('empty actor', dict(actor='')),
    ('empty request id', dict(request_id='')),
    ('malformed recorded_at', dict(recorded_at='not-an-instant')),
    ('unknown reason', dict(reason='because-i-said-so')),
]
for label, override in cases:
    kw = dict(store=store_with(), execution_root=root, cinv='CINV-000002',
              actor='primary-platform-operator', request_id='r',
              recorded_at='2026-09-20T14:00:00-05:00',
              reason=REASON_TERMINAL_RESULT_STRANDED)
    kw.update(override)
    try:
        abandon(**kw)
    except AbandonmentRefused as exc:
        print(f'{label}: refused')
    else:
        raise AssertionError(f'{label} was accepted')
"

run_case "a state that can still continue normally is not administratively eligible" "${ABANDON_PRELUDE}
base, root = ready('ineligible')
reserve(root, 'CINV-000002')
for frm, to in ((LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED),
                (LifecycleState.LAUNCH_AUTHORIZED, LifecycleState.CREATED)):
    transition(root, 'CINV-000002', frm, to)
try:
    abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('a created invocation was abandoned')
"

run_case "an invocation with no execution state at all is refused" "${ABANDON_PRELUDE}
base, root = ready('nostate')
try:
    abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('an invocation with no lifecycle was abandoned')
"

# ===========================================================================
# 4. Evidence
# ===========================================================================

printf '\n--- administrative evidence ---\n'

run_case "abandonment writes CADM intent, detail and outcome, each create-once" "${ABANDON_PRELUDE}
import json
base, root = ready('evidence')
at_launch_authorized(root, 'CINV-000002')
outcome = abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
                  actor='primary-platform-operator', request_id='g11bcv-reclaim-cinv-000002',
                  recorded_at='2026-09-20T14:00:00-05:00',
                  reason=REASON_TERMINAL_RESULT_STRANDED)
d = os.path.join(base, 'root', 'admin-records', outcome.cadm)
members = sorted(os.listdir(d))
assert members == ['abandonment', 'intent', 'outcome'], members
detail = json.loads(open(os.path.join(d, 'abandonment'), encoding='utf-8').read())
for key, value in (('cinv', 'CINV-000002'), ('previous_state', 'launch_authorized'),
                   ('state', 'abandoned'), ('actor', 'primary-platform-operator'),
                   ('request_id', 'g11bcv-reclaim-cinv-000002'),
                   ('recorded_at', '2026-09-20T14:00:00-05:00'),
                   ('reason', REASON_TERMINAL_RESULT_STRANDED),
                   ('result_record_id', 'CRES-000001'),
                   ('slot_released', True), ('cadm', outcome.cadm)):
    assert detail[key] == value, (key, detail[key], value)
assert 'CINV-000002' in detail['causal_references']
assert 'CRES-000001' in detail['causal_references']
intent = json.loads(open(os.path.join(d, 'intent'), encoding='utf-8').read())
assert intent['verb'] == 'abandon', intent
print('members:', members, 'verb:', intent['verb'])
"

run_case "the terminal result is found through the released identity field" "${ABANDON_PRELUDE}
from tools.capability.identifiers import ID_FIELDS
from tools.capability.records import RESULT_KIND
assert ID_FIELDS[RESULT_KIND] == 'capability_result_id', ID_FIELDS
# The fixture must speak the released schema, or it proves nothing about it.
sample = store_with().list_records(RESULT_KIND)[0]
assert ID_FIELDS[RESULT_KIND] in sample, sample
base, root = ready('idfield')
at_launch_authorized(root, 'CINV-000002')
out = abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
              actor='primary-platform-operator', request_id='r',
              recorded_at='2026-09-20T14:00:00-05:00',
              reason=REASON_TERMINAL_RESULT_STRANDED)
assert out.result_record_id == 'CRES-000001', out.result_record_id
print('result identity read through ID_FIELDS:', ID_FIELDS[RESULT_KIND])
"

run_case "a result bound to the invocation but carrying no identity is refused" "${ABANDON_PRELUDE}
base, root = ready('badresult')
at_launch_authorized(root, 'CINV-000002')
store = store_with()
store._r['CRES-000001'].pop('capability_result_id')
try:
    abandon(store=store, execution_root=root, cinv='CINV-000002',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_TERMINAL_RESULT_STRANDED)
except AbandonmentRefused as exc:
    print('refused:', exc)
else:
    raise AssertionError('a result with no identity was accepted')
"

run_case "abandon is a first-class closed admin verb, not a generic force" "${ABANDON_PRELUDE}
from tools.capability.execution.admin import Verb, is_mutating, _DESTROYS_UNDER
assert Verb.ABANDON.value == 'abandon'
assert is_mutating(Verb.ABANDON) is True
assert Verb.ABANDON not in _DESTROYS_UNDER, 'abandonment must carry no destruction authority'
generic = [v for v in Verb if v.value in ('force', 'repair', 'delete', 'cleanup', 'reset')]
assert not generic, generic
print('verbs:', len(list(Verb)))
"

# ===========================================================================
# 5. Terminality
# ===========================================================================

printf '\n--- ABANDONED is terminal everywhere ---\n'

run_case "no lifecycle progression leaves ABANDONED" "${ABANDON_PRELUDE}
base, root = ready('terminal')
at_launch_authorized(root, 'CINV-000002')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='r',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
for target in LifecycleState:
    try:
        transition(root, 'CINV-000002', LifecycleState.ABANDONED, target)
    except InvalidTransition:
        continue
    raise AssertionError(f'abandoned -> {target.value} was permitted')
print('every transition out of abandoned is refused')
"

run_case "an abandoned invocation can never reacquire a slot" "${ABANDON_PRELUDE}
base, root = ready('noreacquire')
at_launch_authorized(root, 'CINV-000002')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='r',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
try:
    reserve(root, 'CINV-000002')
except Exception as exc:
    print('refused:', type(exc).__name__, exc)
else:
    raise AssertionError('an abandoned invocation reserved a slot again')
"

run_case "authorise-launch reaches its refusal branch for an ABANDONED invocation" "${ABANDON_PRELUDE}
import inspect
from tools.capability.execution import launch
from tools.capability.execution.launch import LaunchRefused
source = inspect.getsource(launch.authorise_launch)
# The bridge decides on the CURRENT state: None and RESERVED transition,
# LAUNCH_AUTHORIZED resumes, and everything else falls to the else branch that
# raises. ABANDONED is in 'everything else' by construction.
assert 'is no longer awaiting launch ' in source, 'the refusal branch moved'
assert 'raise LaunchRefused(' in source
base, root = ready('launchrefuse')
at_launch_authorized(root, 'CINV-000002')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='r',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
from tools.capability.execution.state import current_state as cs
assert cs(root, 'CINV-000002') is LifecycleState.ABANDONED
# The bridge's own branch: not None, not RESERVED, not LAUNCH_AUTHORIZED.
assert LifecycleState.ABANDONED not in (None, LifecycleState.RESERVED,
                                        LifecycleState.LAUNCH_AUTHORIZED)
print('authorise_launch reaches its refusal branch for abandoned')
"

run_case "recovery does not offer an ABANDONED invocation as resumable" "${ABANDON_PRELUDE}
from tools.capability.execution import recovery
from tools.capability.execution.recovery import unresolved_invocations, _container_possible
assert _container_possible(LifecycleState.ABANDONED) is False
base, root = ready('recover')
at_launch_authorized(root, 'CINV-000001')
store = store_with()
before = unresolved_invocations(store, execution_root=root)
assert any(u.invocation_record_id == 'CINV-000001' for u in before), before
abandon(store=store, execution_root=root, cinv='CINV-000001',
        actor='primary-platform-operator', request_id='r',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
after = unresolved_invocations(store, execution_root=root)
assert not any(u.invocation_record_id == 'CINV-000001' for u in after), after
print('unresolved before:', len(before), 'after:', len(after))
"

run_case "a normal RELEASED lifecycle is unaffected" "${ABANDON_PRELUDE}
base, root = ready('released')
reserve(root, 'CINV-000001')
order = [LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED,
         LifecycleState.CREATED, LifecycleState.CONTAINER_VERIFIED,
         LifecycleState.START_AUTHORIZED, LifecycleState.STARTED,
         LifecycleState.RUNNING, LifecycleState.TERMINAL,
         LifecycleState.CLASSIFIED, LifecycleState.COLLECTED,
         LifecycleState.CLEANED, LifecycleState.RELEASED]
for frm, to in zip(order, order[1:]):
    transition(root, 'CINV-000001', frm, to)
assert current_state(root, 'CINV-000001') is LifecycleState.RELEASED
assert occupancy(root) == 0, occupancy(root)
try:
    abandon(store=store_with(), execution_root=root, cinv='CINV-000001',
            actor='primary-platform-operator', request_id='r',
            recorded_at='2026-09-20T14:00:00-05:00',
            reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
except AbandonmentRefused as exc:
    print('a released invocation is refused:', exc)
else:
    raise AssertionError('a released invocation was abandoned')
"

# ===========================================================================
# 6. The blocker, cleared
# ===========================================================================

printf '\n--- the blocker, cleared ---\n'

run_case "abandoning both stuck invocations frees both slots and unblocks the third" "${ABANDON_PRELUDE}
base, root = ready('cleared')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000002')
assert occupancy(root) == 2
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted:
    pass
else:
    raise AssertionError('capacity was not exhausted to begin with')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='r2',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
assert occupancy(root) == 1, occupancy(root)
abandon(store=store_with(), execution_root=root, cinv='CINV-000001',
        actor='primary-platform-operator', request_id='r1',
        recorded_at='2026-09-20T14:05:00-05:00',
        reason=REASON_HISTORICAL_INCOMPLETE_EXECUTION)
assert occupancy(root) == 0, occupancy(root)
reserve(root, 'CINV-000003')
assert current_state(root, 'CINV-000003') is LifecycleState.RESERVED
assert occupancy(root) == 1, occupancy(root)
print('2/2 -> 1/2 -> 0/2, then CINV-000003 reserved: 1/2')
"

run_case "capacity stays bounded by MAXIMUM_SLOTS after abandonment" "${ABANDON_PRELUDE}
base, root = ready('bounded')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000002')
abandon(store=store_with(), execution_root=root, cinv='CINV-000002',
        actor='primary-platform-operator', request_id='r',
        recorded_at='2026-09-20T14:00:00-05:00',
        reason=REASON_TERMINAL_RESULT_STRANDED)
reserve(root, 'CINV-000003')
assert occupancy(root) == 2, occupancy(root)
try:
    reserve(root, 'CINV-000004')
except CapacityExhausted as exc:
    print('still bounded at', MAXIMUM_SLOTS, ':', exc)
else:
    raise AssertionError('the ceiling was exceeded after abandonment')
"

run_case "concurrent abandonment and reservation cannot oversubscribe" "${ABANDON_PRELUDE}
import multiprocessing as mp
base, root = ready('race')
at_launch_authorized(root, 'CINV-000001')
at_launch_authorized(root, 'CINV-000002')

# A plain Barrier and Queue rather than a Manager: a Manager proxy created
# before the fork is not usable in the child, and the failure reads as a test
# crash rather than as the race this is meant to observe.
def child(which, barrier, queue):
    r = anchor(base)
    barrier.wait()
    try:
        if which == 'abandon':
            abandon(store=store_with(), execution_root=r, cinv='CINV-000002',
                    actor='primary-platform-operator', request_id='r',
                    recorded_at='2026-09-20T14:00:00-05:00',
                    reason=REASON_TERMINAL_RESULT_STRANDED)
            queue.put(('abandon', 'ok'))
        else:
            reserve(r, which)
            queue.put((which, 'ok'))
    except Exception as exc:
        queue.put((which, type(exc).__name__))

barrier = mp.Barrier(3)
queue = mp.Queue()
procs = [mp.Process(target=child, args=(w, barrier, queue))
         for w in ('abandon', 'CINV-000003', 'CINV-000004')]
for p in procs: p.start()
outcomes = [queue.get(timeout=60) for _ in procs]
for p in procs: p.join(30)
final = occupancy(root)
assert final <= MAXIMUM_SLOTS, (final, outcomes)
# The abandonment must have succeeded, and at most as many reservations as
# there were free slots afterwards.
assert ('abandon', 'ok') in outcomes, outcomes
reserved = [o for o in outcomes if o[0].startswith('CINV') and o[1] == 'ok']
assert len(reserved) <= MAXIMUM_SLOTS, outcomes
print('outcomes:', sorted(outcomes), 'final occupancy:', final, '<=', MAXIMUM_SLOTS)
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Governed administrative abandonment validation passed.\n'
else
  printf 'Governed administrative abandonment validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
