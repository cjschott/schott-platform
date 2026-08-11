#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T6.
#
# T6 is capacity and lifecycle state: the global two-slot ceiling, the closed
# transition relation, and the locks that serialise them. There is no handoff,
# no payload copy, no transition helper, no worker protocol, no Podman, no
# container, no image, no result collection, no quarantine, no CADM -- and NO
# EXECUTION.
#
# CAPACITY IS DURABLE STATE, never inferred. It is counted from committed
# lifecycle records, never from process counts, container counts, file ages,
# timestamps, or the existence of a lock file.
#
# ONCE reserved IS COMMITTED THE CINV IS SPENT. There is no rollback to unused,
# no age-based expiry, and no way to delete state back into eligibility.
#
# The concurrency proofs fork real processes and release them from a pipe
# barrier rather than sleeping, so the ceiling is tested under genuine races.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §16, §23
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T6

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/state.py"
assert_file "tools/capability/execution/capacity.py"

# ===========================================================================
# The T6 authority backstop
# ===========================================================================

assert_bounded_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
targets = [root / "tools/capability/execution/state.py",
           root / "tools/capability/execution/capacity.py"]

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "chmod", "chown", "rmtree", "removedirs", "symlink", "link",
    "readlink", "realpath", "abspath", "expanduser", "chdir", "now", "today",
    "monotonic", "uuid1", "uuid4", "normalize", "walk", "getmtime", "st_mtime",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "st_mtime", "st_ctime")

if any(not t.is_file() for t in targets):
    print("module-absent")
    raise SystemExit(0)

findings = []
for target in targets:
    rel = target.relative_to(root)
    tree = ast.parse(target.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(tree)

    stripped = ast.unparse(tree).lower()
    for token in FORBIDDEN_TEXT:
        if token in stripped:
            findings.append(f"{rel}: forbidden token in code: {token}")

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    findings.append(f"{rel}: forbidden import: {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            name = node.module or ""
            if name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{rel}: forbidden import-from: {name}")
        elif isinstance(node, ast.Call):
            func = node.func
            attr = getattr(func, "attr", None) or getattr(func, "id", None)
            if attr in FORBIDDEN_CALLS:
                findings.append(f"{rel}: forbidden call: {attr}")

    # T6 writes authority state only through the T5 substrate. Its own
    # filesystem writes are confined to advisory lock files.
    permitted_os = {
        "open", "read", "close", "fstat", "stat", "scandir", "mkdir", "dup",
        "O_RDONLY", "O_WRONLY", "O_RDWR", "O_CREAT", "O_NOFOLLOW",
        "O_CLOEXEC", "O_DIRECTORY",
    }
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id == "os" and node.attr not in permitted_os:
            findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T6 authority is bounded: state via the CMUT substrate, no clock or path authority"
  else
    fail "T6 authority backstop found: ${report}"
  fi
}

assert_bounded_authority

# ===========================================================================
# Behaviour
# ===========================================================================

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
import os, shutil
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import (
    Mutation, MutationJournalIntegrityFailure, CMUT_COUNTER)
from tools.capability.execution.types import LifecycleState, SlotReservation
from tools.capability.execution.state import (
    current_state, transition, ExecutionStateError, InvalidTransition,
    StateIntegrityFailure, TRANSITIONS_DIRECTORY)
from tools.capability.execution.capacity import (
    reserve, release, CapacityExhausted, MAXIMUM_SLOTS,
    CAPACITY_CONSUMING_STATES, LOCKS_DIRECTORY)
from tools.capability.execution.types import Classification
WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'

def make(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for sub in ('root/mutations', 'root/state', 'root/' + TRANSITIONS_DIRECTORY,
                'root/' + LOCKS_DIRECTORY):
        os.makedirs(os.path.join(base, sub))
    with open(os.path.join(base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
        handle.write(b'000000000000\n')
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

def walk_to(root, cinv, target):
    order = list(LifecycleState)
    start = order.index(LifecycleState.RESERVED)
    stop = order.index(target)
    for index in range(start, stop):
        transition(root, cinv, order[index], order[index + 1])
"

# --- interface shape --------------------------------------------------------

run_case "every authority operation takes a RootDescriptor first" "${PRELUDE}
import inspect
for fn in (current_state, transition, reserve, release):
    params = list(inspect.signature(fn).parameters)
    assert params[0] == 'root', (fn.__name__, params)
    for name, p in inspect.signature(fn).parameters.items():
        assert 'path' not in name.lower(), (fn.__name__, name)
        assert str(p.annotation) != 'Path', (fn.__name__, name)
print('OK')
"

run_case "a raw root pathname is not accepted" "${PRELUDE}
base, root = ready('rawpath')
try:
    reserve(os.path.join(base, 'root'), 'CINV-000001')
except (AttributeError, TypeError, ExecutionStateError):
    root.close()
    print('OK')
else:
    root.close()
    raise AssertionError('a pathname was accepted as the root')
"

# --- reservation and the ceiling --------------------------------------------

run_case "a valid reservation commits reserved and consumes one slot" "${PRELUDE}
base, root = ready('one')
reservation = reserve(root, 'CINV-000001')
assert isinstance(reservation, SlotReservation)
assert reservation.cinv == 'CINV-000001'
assert current_state(root, 'CINV-000001') is LifecycleState.RESERVED
root.close()
print('OK')
"

run_case "a second independent reservation takes the second slot" "${PRELUDE}
base, root = ready('two')
a = reserve(root, 'CINV-000001')
b = reserve(root, 'CINV-000002')
assert {a.slot_index, b.slot_index} == {0, 1}, (a.slot_index, b.slot_index)
root.close()
print('OK')
"

run_case "the third reservation is refused as execution_capacity_exhausted" "${PRELUDE}
base, root = ready('three')
reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted as error:
    assert error.classification is Classification.EXECUTION_CAPACITY_EXHAUSTED
    assert MAXIMUM_SLOTS == 2
    print('OK')
else:
    raise AssertionError('third reservation was granted')
finally:
    root.close()
"

run_case "a refused reservation leaves no queue and no state behind" "${PRELUDE}
base, root = ready('noqueue')
reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted:
    pass
assert current_state(root, 'CINV-000003') is None
names = os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))
assert not any(n.startswith('CINV-000003') for n in names), names
import tools.capability.execution.capacity as module
public = [n for n in dir(module) if not n.startswith('_')]
for banned in ('queue', 'wait', 'pending', 'enqueue', 'defer'):
    assert not any(banned in n.lower() for n in public), (banned, public)
root.close()
print('OK')
"

run_case "capacity survives a reopened root -- it is durable, not in-memory" "${PRELUDE}
base, root = ready('durable')
reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
root.close()
reopened = anchor(base)
try:
    reserve(reopened, 'CINV-000003')
except CapacityExhausted:
    print('OK')
else:
    raise AssertionError('capacity was forgotten across a reopen')
finally:
    reopened.close()
"

run_case "capacity is counted from durable state, not from lock files" "${PRELUDE}
base, root = ready('notlocks')
reserve(root, 'CINV-000001')
locks = os.path.join(base, 'root', LOCKS_DIRECTORY)
# Fabricated lock files for CINVs that never reserved anything.
for name in ('CINV-000900', 'CINV-000901', 'CINV-000902'):
    with open(os.path.join(locks, name), 'wb'):
        pass
reserve(root, 'CINV-000002')
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted:
    print('OK')
else:
    raise AssertionError('lock files changed the count')
finally:
    root.close()
"

run_case "a stale lock file is harmless and carries no state" "${PRELUDE}
base, root = ready('stale')
locks = os.path.join(base, 'root', LOCKS_DIRECTORY)
with open(os.path.join(locks, 'capacity'), 'wb') as handle:
    handle.write(b'this content means nothing')
with open(os.path.join(locks, 'CINV-000001'), 'wb') as handle:
    handle.write(b'reserved')
reservation = reserve(root, 'CINV-000001')
assert current_state(root, 'CINV-000001') is LifecycleState.RESERVED
assert reservation.cinv == 'CINV-000001'
root.close()
print('OK')
"

run_case "no age-based expiry: an old reservation still holds its slot" "${PRELUDE}
import dataclasses
base, root = ready('noage')
reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
# Backdate everything on disk by twenty years.
for base_dir, _, names in os.walk(os.path.join(base, 'root')):
    for name in names:
        p = os.path.join(base_dir, name)
        os.utime(p, (1, 1))
try:
    reserve(root, 'CINV-000003')
except CapacityExhausted:
    pass
else:
    raise AssertionError('an aged reservation was reclaimed')
assert {f.name for f in dataclasses.fields(SlotReservation)} == {'cinv', 'slot_index'}
root.close()
print('OK')
"

# --- CINV grammar -----------------------------------------------------------

run_case "only canonical CINV identity reaches authority state" "${PRELUDE}
base, root = ready('grammar')
for bad in ('CINV-00001', 'CINV-0000001', 'cinv-000001', '../../etc/passwd',
            '/etc/passwd', 'CINV-000001/x', '--help', '', 'CINV-00000a',
            'opaque-invocation-id'):
    try:
        reserve(root, bad)
    except ExecutionStateError:
        continue
    root.close()
    raise AssertionError(f'accepted CINV {bad!r}')
root.close()
print('OK')
"

# --- lifecycle transitions ---------------------------------------------------

run_case "the transition relation is closed and linear" "${PRELUDE}
base, root = ready('linear')
reserve(root, 'CINV-000001')
transition(root, 'CINV-000001', LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED)
assert current_state(root, 'CINV-000001') is LifecycleState.LAUNCH_AUTHORIZED
root.close()
print('OK')
"

run_case "skipping a state is refused" "${PRELUDE}
base, root = ready('skip')
reserve(root, 'CINV-000001')
try:
    transition(root, 'CINV-000001', LifecycleState.RESERVED, LifecycleState.STARTED)
except InvalidTransition:
    print('OK')
else:
    raise AssertionError('a skipped transition was accepted')
finally:
    root.close()
"

run_case "going backwards is refused" "${PRELUDE}
base, root = ready('back')
reserve(root, 'CINV-000001')
transition(root, 'CINV-000001', LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED)
try:
    transition(root, 'CINV-000001', LifecycleState.LAUNCH_AUTHORIZED, LifecycleState.RESERVED)
except InvalidTransition:
    print('OK')
else:
    raise AssertionError('a backwards transition was accepted')
finally:
    root.close()
"

run_case "a transition whose declared predecessor is wrong is refused" "${PRELUDE}
base, root = ready('wrongfrom')
reserve(root, 'CINV-000001')
try:
    transition(root, 'CINV-000001', LifecycleState.CREATED, LifecycleState.CONTAINER_VERIFIED)
except InvalidTransition:
    print('OK')
else:
    raise AssertionError('a mismatched predecessor was accepted')
finally:
    root.close()
"

run_case "there is no rollback from reserved to unused" "${PRELUDE}
base, root = ready('norollback')
reserve(root, 'CINV-000001')
try:
    reserve(root, 'CINV-000001')
except ExecutionStateError:
    pass
else:
    root.close()
    raise AssertionError('a consumed CINV reserved again')
assert current_state(root, 'CINV-000001') is LifecycleState.RESERVED
import tools.capability.execution.state as module
public = [n for n in dir(module) if not n.startswith('_')]
for banned in ('delete', 'reset', 'rollback', 'unreserve', 'clear', 'purge'):
    assert not any(banned in n.lower() for n in public), (banned, public)
root.close()
print('OK')
"

# --- release -----------------------------------------------------------------

run_case "release is refused before the lifecycle reaches cleaned" "${PRELUDE}
base, root = ready('earlyrelease')
reservation = reserve(root, 'CINV-000001')
try:
    release(root, reservation)
except InvalidTransition:
    print('OK')
else:
    raise AssertionError('capacity was released early')
finally:
    root.close()
"

run_case "release after cleaned frees the slot" "${PRELUDE}
base, root = ready('release')
a = reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
walk_to(root, 'CINV-000001', LifecycleState.CLEANED)
release(root, a)
assert current_state(root, 'CINV-000001') is LifecycleState.RELEASED
third = reserve(root, 'CINV-000003')
assert third.cinv == 'CINV-000003'
root.close()
print('OK')
"

run_case "released is not capacity-consuming, every other state is" "${PRELUDE}
expected = tuple(s for s in LifecycleState if s is not LifecycleState.RELEASED)
assert set(CAPACITY_CONSUMING_STATES) == set(expected), CAPACITY_CONSUMING_STATES
print('OK')
"

# --- CMUT integration --------------------------------------------------------

run_case "every authority transition goes through the CMUT substrate" "${PRELUDE}
base, root = ready('cmut')
reserve(root, 'CINV-000001')
transition(root, 'CINV-000001', LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED)
mutations = sorted(os.listdir(os.path.join(base, 'root', 'mutations')))
assert mutations == ['CMUT-000000000001', 'CMUT-000000000002'], mutations
for cmut in mutations:
    d = os.path.join(base, 'root', 'mutations', cmut)
    assert os.path.isfile(os.path.join(d, 'intent'))
    assert os.path.isfile(os.path.join(d, 'outcome'))
root.close()
print('OK')
"

run_case "a broken CMUT journal blocks state mutation with no fallback write" "${PRELUDE}
base, root = ready('cmutfail')
with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
    handle.write(b'garbage\n')
try:
    reserve(root, 'CINV-000001')
except MutationJournalIntegrityFailure:
    pass
else:
    root.close()
    raise AssertionError('state mutated with a broken journal')
assert current_state(root, 'CINV-000001') is None
assert os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)) == []
root.close()
print('OK')
"

run_case "state modules contain no second atomic-write protocol" "${PRELUDE}
import inspect
import tools.capability.execution.state as state_module
import tools.capability.execution.capacity as capacity_module
for module in (state_module, capacity_module):
    source = inspect.getsource(module)
    assert 'os.rename' not in source, f'{module.__name__} renames directly'
    assert 'os.write' not in source or module is capacity_module, module.__name__
    assert 'fsync' not in source, f'{module.__name__} fsyncs outside the substrate'
print('OK')
"

# --- corruption ---------------------------------------------------------------

run_case "a malformed transition record fails closed" "${PRELUDE}
base, root = ready('malformed')
reserve(root, 'CINV-000001')
d = os.path.join(base, 'root', TRANSITIONS_DIRECTORY)
name = os.listdir(d)[0]
with open(os.path.join(d, name), 'wb') as handle:
    handle.write(b'{broken')
try:
    current_state(root, 'CINV-000001')
except StateIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a malformed record was tolerated')
finally:
    root.close()
"

run_case "a gap in the transition chain fails closed" "${PRELUDE}
base, root = ready('gap')
reserve(root, 'CINV-000001')
transition(root, 'CINV-000001', LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED)
d = os.path.join(base, 'root', TRANSITIONS_DIRECTORY)
os.remove(os.path.join(d, 'CINV-000001.000001'))
try:
    current_state(root, 'CINV-000001')
except StateIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a broken chain was tolerated')
finally:
    root.close()
"

run_case "a contradictory chain fails closed rather than picking the newest" "${PRELUDE}
base, root = ready('contra')
reserve(root, 'CINV-000001')
d = os.path.join(base, 'root', TRANSITIONS_DIRECTORY)
# A second record claiming a predecessor that never happened.
with open(os.path.join(d, 'CINV-000001.000002'), 'wb') as handle:
    handle.write(serialise({'cinv': 'CINV-000001', 'schema_version': 1,
                            'sequence': 2, 'previous': 'started',
                            'state': 'running'}))
try:
    current_state(root, 'CINV-000001')
except StateIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a contradictory chain was tolerated')
finally:
    root.close()
"

run_case "an unexpected object in the transitions namespace fails closed" "${PRELUDE}
base, root = ready('unexpected')
reserve(root, 'CINV-000001')
with open(os.path.join(base, 'root', TRANSITIONS_DIRECTORY, 'stray.tmp'), 'wb'):
    pass
try:
    current_state(root, 'CINV-000001')
except StateIntegrityFailure:
    print('OK')
else:
    raise AssertionError('an unexpected object was tolerated')
finally:
    root.close()
"

# --- locking ------------------------------------------------------------------

run_case "lock order is global capacity then per-CINV, and inversion raises" "${PRELUDE}
import tools.capability.execution.capacity as module
base, root = ready('lockorder')
held = module._LockOrder()
held.acquire_capacity()
held.acquire_cinv('CINV-000001')
held.release_all()
held.acquire_cinv('CINV-000001')
try:
    held.acquire_capacity()
except module.LockOrderViolation:
    print('OK')
else:
    raise AssertionError('lock order inversion was permitted')
finally:
    held.release_all()
    root.close()
"

# The lock must cover the whole decision, not just the write: read, validate,
# decide, and commit all sit inside it, so two actors cannot read the same
# valid state and both act on it.
run_case "the CINV lock spans read, validate, decide and commit" "${PRELUDE}
import ast, inspect
import tools.capability.execution.capacity as capacity_module
import tools.capability.execution.state as state_module

def spans(module, function, *markers):
    '''Every marker must appear between acquiring and releasing the lock.'''
    tree = ast.parse(inspect.getsource(module))
    fn = [n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == function]
    assert fn, f'no {function}'
    body = ast.unparse(fn[0])
    positions = [body.index('acquire_cinv')]
    for marker in markers:
        positions.append(body.index(marker))
    positions.append(body.rindex('release_all'))
    assert positions == sorted(positions), (
        f'{function}: lock does not span {markers} in order')

spans(capacity_module, 'reserve', 'all_states', 'open_state_locked')
spans(capacity_module, 'release', 'current_state', 'transition_locked')
# state.transition delegates the read/validate/decide/commit body wholesale,
# so the single call is the entire protected region.
spans(state_module, 'transition', 'transition_locked')
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T6 capacity and state validation passed.\n'
else
  printf 'Capability execution T6 capacity and state validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
