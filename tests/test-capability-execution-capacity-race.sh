#!/usr/bin/env bash
set -Eeuo pipefail

# Concurrency proofs for the ENG-0005 first adapter, increment T6.
#
# The global ceiling is only a ceiling if it holds under a real race, so these
# cases fork actual processes and release them simultaneously from a pipe
# barrier. Nothing here sleeps to "probably" interleave: every child blocks on
# a read that returns only when the parent writes, so the contended window is
# genuine rather than hoped for.
#
# Split from the main T6 suite because these are slow and process-spawning,
# and because a race proof that is skipped when it gets inconvenient is worth
# nothing.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §23
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T6

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
import os, shutil, sys
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.state import (
    current_state, transition, TRANSITIONS_DIRECTORY, ExecutionStateError)
from tools.capability.execution.capacity import (
    reserve, release, CapacityExhausted, LOCKS_DIRECTORY, MAXIMUM_SLOTS)
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

def race(base, count, work):
    '''Fork count children, release them together, collect one byte each.

    Each child blocks reading the barrier pipe until the parent writes, so
    every child is already inside the contended path when it is let go.
    '''
    start_r, start_w = os.pipe()
    result_r, result_w = os.pipe()
    children = []
    for index in range(count):
        pid = os.fork()
        if pid == 0:
            try:
                os.close(start_w); os.close(result_r)
                while len(os.read(start_r, 1)) == 0:
                    pass
                os.close(start_r)
                outcome = work(index)
                os.write(result_w, outcome.encode('ascii')[:1])
            except BaseException:
                try:
                    os.write(result_w, b'E')
                except BaseException:
                    pass
            finally:
                os._exit(0)
        children.append(pid)
    os.close(start_r); os.close(result_w)
    os.write(start_w, b'g' * count)
    os.close(start_w)
    collected = b''
    while len(collected) < count:
        chunk = os.read(result_r, count - len(collected))
        if not chunk:
            break
        collected += chunk
    os.close(result_r)
    for pid in children:
        os.waitpid(pid, 0)
    return collected.decode('ascii')
"

# --- the ceiling under contention -------------------------------------------

run_case "eight concurrent reservations never exceed the two-slot ceiling" "${PRELUDE}
base = make('ceiling')
def work(index):
    root = anchor(base)
    try:
        reserve(root, f'CINV-{index:06d}')
        return 'R'
    except CapacityExhausted:
        return 'X'
    except Exception:
        return 'E'
    finally:
        root.close()
outcomes = race(base, 8, work)
granted = outcomes.count('R')
errors = outcomes.count('E')
assert errors == 0, f'unexpected errors: {outcomes}'
assert granted == MAXIMUM_SLOTS, f'{granted} reservations granted: {outcomes}'
# And the durable record agrees with what the callers were told.
root = anchor(base)
try:
    committed = [n for n in os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY))]
finally:
    root.close()
assert len(committed) == MAXIMUM_SLOTS, committed
print('OK')
"

run_case "sixteen concurrent reservations still commit exactly two" "${PRELUDE}
base = make('ceiling16')
def work(index):
    root = anchor(base)
    try:
        reserve(root, f'CINV-{index:06d}')
        return 'R'
    except CapacityExhausted:
        return 'X'
    except Exception:
        return 'E'
    finally:
        root.close()
outcomes = race(base, 16, work)
assert outcomes.count('E') == 0, outcomes
assert outcomes.count('R') == 2, outcomes
assert outcomes.count('X') == 14, outcomes
print('OK')
"

# --- same-CINV serialisation --------------------------------------------------

run_case "concurrent reservations of the same CINV grant exactly one" "${PRELUDE}
base = make('samecinv')
def work(index):
    root = anchor(base)
    try:
        reserve(root, 'CINV-000001')
        return 'R'
    except CapacityExhausted:
        return 'X'
    except ExecutionStateError:
        return 'D'
    except Exception:
        return 'E'
    finally:
        root.close()
outcomes = race(base, 8, work)
assert outcomes.count('E') == 0, outcomes
assert outcomes.count('R') == 1, f'the same CINV reserved {outcomes.count(\"R\")} times: {outcomes}'
root = anchor(base)
try:
    names = sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))
finally:
    root.close()
assert names == ['CINV-000001.000001'], names
print('OK')
"

run_case "conflicting transitions from one predecessor cannot both commit" "${PRELUDE}
base = make('conflict')
root = anchor(base)
reserve(root, 'CINV-000001')
root.close()
def work(index):
    root = anchor(base)
    try:
        transition(root, 'CINV-000001', LifecycleState.RESERVED,
                   LifecycleState.LAUNCH_AUTHORIZED)
        return 'T'
    except ExecutionStateError:
        return 'D'
    except Exception:
        return 'E'
    finally:
        root.close()
outcomes = race(base, 8, work)
assert outcomes.count('E') == 0, outcomes
assert outcomes.count('T') == 1, f'{outcomes.count(\"T\")} transitions committed: {outcomes}'
root = anchor(base)
try:
    assert current_state(root, 'CINV-000001') is LifecycleState.LAUNCH_AUTHORIZED
    names = sorted(os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)))
finally:
    root.close()
assert names == ['CINV-000001.000001', 'CINV-000001.000002'], names
print('OK')
"

# --- release racing reserve ----------------------------------------------------

run_case "release racing a reservation never overcounts or double-counts a slot" "${PRELUDE}
base = make('relrace')
root = anchor(base)
first = reserve(root, 'CINV-000001')
reserve(root, 'CINV-000002')
order = list(LifecycleState)
start = order.index(LifecycleState.RESERVED)
stop = order.index(LifecycleState.CLEANED)
for index in range(start, stop):
    transition(root, 'CINV-000001', order[index], order[index + 1])
root.close()

def work(index):
    root = anchor(base)
    try:
        if index == 0:
            release(root, first)
            return 'F'
        reserve(root, f'CINV-{100 + index:06d}')
        return 'R'
    except CapacityExhausted:
        return 'X'
    except Exception:
        return 'E'
    finally:
        root.close()

outcomes = race(base, 6, work)
assert outcomes.count('E') == 0, outcomes
assert outcomes.count('F') == 1, outcomes
granted = outcomes.count('R')
# The freed slot may or may not be observed by a racer, so zero or one new
# reservation is correct -- two would mean the slot was counted twice.
assert granted in (0, 1), f'{granted} reservations after one release: {outcomes}'

root = anchor(base)
try:
    consuming = 0
    seen = set()
    for name in os.listdir(os.path.join(base, 'root', TRANSITIONS_DIRECTORY)):
        seen.add(name.split('.')[0])
    for cinv in seen:
        state = current_state(root, cinv)
        if state is not LifecycleState.RELEASED:
            consuming += 1
finally:
    root.close()
assert consuming <= MAXIMUM_SLOTS, f'{consuming} slots consumed after the race'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T6 concurrency validation passed.\n'
else
  printf 'Capability execution T6 concurrency validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
