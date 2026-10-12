#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T13.
#
# T13 interprets what happened. It creates nothing, starts nothing, kills
# nothing real: termination is decided here and performed through an injected
# backend. No Podman, no subprocess, no container. Gate G6 stays closed.
#
# LIFECYCLE ESTABLISHES TRUTH BEFORE EXITCODE IS READ. That ordering is the
# whole increment. A container that never ran reports exit 0, which Track B
# observed directly, so an exit code read on its own would call a failed launch
# a success. Every branch below decides whether the workload started before it
# looks at what it returned.
#
# TIMEOUT IS PERMANENT. Once the threshold fires the invocation is a timeout,
# including when the workload exits during the grace period. A late exit is not
# a late success -- it is the same timeout with better manners.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §17
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T13

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# ===========================================================================
# The T13 backstop
# ===========================================================================
# T13 extends lifecycle.py, whose T12 guard already forbids Podman surfaces,
# subprocess, and filesystem mutation. This adds the clock rule: time may be
# measured only through the injected seam, never read directly.

assert_no_ambient_clock() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/lifecycle.py"

FORBIDDEN_IMPORTS = {"time", "datetime", "subprocess", "socket", "os",
                     "random", "shutil", "signal", "threading"}
FORBIDDEN_CALLS = {"monotonic", "now", "today", "sleep", "perf_counter",
                   "process_time", "gmtime", "localtime", "system", "popen"}

findings = []
tree = ast.parse(target.read_text(encoding="utf-8"))
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"forbidden import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T13 reads no ambient clock: time arrives only through the seam"
  else
    fail "T13 backstop found: ${report}"
  fi
}

assert_no_ambient_clock

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
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
from tools.capability.execution import lifecycle as L
from tools.capability.execution.types import Classification
CID = 'c' * 64

def observation(state='exited', exit_code=0, started_at='2026-08-12T00:00:00Z',
                finished_at='2026-08-12T00:00:05Z', started_proven=True,
                trustworthy=None, container_id=CID):
    return L.LifecycleObservation(
        container_id=container_id, state=state, started_at=started_at,
        finished_at=finished_at, exit_code=exit_code,
        started_proven=started_proven,
        exit_code_trustworthy=started_proven if trustworthy is None
        else trustworthy)

class FakeTermination:
    '''Records termination decisions and performs none of them.'''

    def __init__(self, exits_after=None):
        self.calls = []
        self._exits_after = exits_after
        self._terminated = False

    def terminate(self, container_id):
        self.calls.append(('terminate', container_id))
        self._terminated = True

    def kill(self, container_id):
        self.calls.append(('kill', container_id))

    def still_active(self, container_id):
        self.calls.append(('still_active', container_id))
        if self._exits_after is None:
            return True
        return not self._terminated or self._exits_after > 0

class FakeClock:
    '''Monotonic time the test controls entirely.'''

    def __init__(self, *ticks):
        self._ticks = list(ticks) or [0.0]
        self.reads = 0

    def __call__(self):
        self.reads += 1
        if len(self._ticks) > 1:
            return self._ticks.pop(0)
        return self._ticks[0]

def names(backend):
    return [c[0] for c in backend.calls]
"

# --- lifecycle before exit code ---------------------------------------------------

run_case "Created with exit 0 is a launch failure, never success" "${PRELUDE}
result = L.classify(observation(state='created', exit_code=0,
                                started_at=None, finished_at=None,
                                started_proven=False))
assert result.started_proven is False
assert result.outcome_class == 'adapter-error', result.outcome_class
assert result.may_collect_result is False
assert result.succeeded is False
print('OK')
"

run_case "Created with a nonzero exit is the same launch failure" "${PRELUDE}
result = L.classify(observation(state='created', exit_code=127,
                                started_at=None, finished_at=None,
                                started_proven=False))
assert result.outcome_class == 'adapter-error', result.outcome_class
assert result.may_collect_result is False
assert result.exit_code_considered is False
print('OK')
"

run_case "a never-started observation ignores its exit code entirely" "${PRELUDE}
for code in (0, 1, 127, -1, None):
    result = L.classify(observation(state='created', exit_code=code,
                                    started_at=None, finished_at=None,
                                    started_proven=False))
    assert result.exit_code_considered is False, code
    assert result.succeeded is False, code
print('OK')
"

run_case "an untrustworthy exit code is not read even when the state looks terminal" "${PRELUDE}
result = L.classify(observation(state='exited', exit_code=0,
                                started_proven=True, trustworthy=False))
assert result.exit_code_considered is False
assert result.succeeded is False
assert result.outcome_class == 'adapter-error', result.outcome_class
print('OK')
"

run_case "a proven start with a valid terminal exit 0 permits result collection" "${PRELUDE}
result = L.classify(observation(state='exited', exit_code=0))
assert result.started_proven is True
assert result.exit_code_considered is True
assert result.outcome_class == 'completed', result.outcome_class
assert result.may_collect_result is True
# T13 stops short of declaring the invocation successful: result validation
# has not happened yet.
assert result.succeeded is False, 'T13 declared success before result validation'
print('OK')
"

run_case "a proven start with a nonzero exit is an execution failure" "${PRELUDE}
for code in (1, 2, 42, 137, 255):
    result = L.classify(observation(state='exited', exit_code=code))
    assert result.exit_code_considered is True, code
    assert result.outcome_class == 'provider-error', (code, result.outcome_class)
    assert result.may_collect_result is False, code
    assert result.succeeded is False, code
print('OK')
"

run_case "a running container is neither success nor failure yet" "${PRELUDE}
result = L.classify(observation(state='running', exit_code=None,
                                finished_at=None))
assert result.disposition is L.TerminalDisposition.RUNNING
assert result.may_collect_result is False
assert result.exit_code_considered is False
print('OK')
"

# --- contradictions ----------------------------------------------------------------

run_case "contradictory lifecycle evidence fails closed" "${PRELUDE}
contradictions = [
    # Terminal state with no start ever proven.
    observation(state='exited', started_proven=True, started_at=None),
    # Start proven but no terminal evidence at all while claiming exited.
    observation(state='exited', finished_at=None, exit_code=None),
    # Finished before it started.
    observation(state='exited', started_at='2026-08-12T00:00:05Z',
                finished_at='2026-08-12T00:00:00Z'),
    # A state the runtime vocabulary does not contain.
    observation(state='teleported'),
    observation(state=None),
]
for observed in contradictions:
    result = L.classify(observed)
    assert result.disposition is L.TerminalDisposition.INTEGRITY_FAILURE, observed
    assert result.classification is Classification.EXECUTION_LIFECYCLE_INTEGRITY_FAILURE
    assert result.exit_code_considered is False
    assert result.may_collect_result is False
print('OK')
"

run_case "a timestamp alone never proves a start" "${PRELUDE}
# started_proven is the authority; a timestamp is metadata that accompanies it.
result = L.classify(observation(state='created', exit_code=0,
                                started_at='2026-08-12T00:00:00Z',
                                finished_at=None, started_proven=False))
assert result.started_proven is False
assert result.succeeded is False
assert result.exit_code_considered is False
print('OK')
"

run_case "timestamps are never normalised or compared to a wall clock" "${PRELUDE}
# Nonsense timestamps are carried, not corrected; only internal contradiction
# matters, and only where both endpoints are present and ordered.
result = L.classify(observation(state='exited', exit_code=0,
                                started_at='1970-01-01T00:00:00Z',
                                finished_at='2999-01-01T00:00:00Z'))
assert result.outcome_class == 'completed', result.outcome_class
assert result.started_at == '1970-01-01T00:00:00Z'
print('OK')
"

# --- timeout -------------------------------------------------------------------------

run_case "the accepted timeout and grace are 30 and 2 seconds" "${PRELUDE}
assert L.TIMEOUT_SECONDS == 30
assert L.GRACE_SECONDS == 2
print('OK')
"

run_case "the timeout fires at the threshold, not before" "${PRELUDE}
assert L.timed_out(elapsed=29.999) is False
assert L.timed_out(elapsed=30.0) is True
assert L.timed_out(elapsed=30.001) is True
print('OK')
"

run_case "a timeout classification is permanent and cannot revert" "${PRELUDE}
result = L.classify(observation(state='exited', exit_code=0), timed_out=True)
assert result.disposition is L.TerminalDisposition.TIMED_OUT
assert result.outcome_class == 'timeout', result.outcome_class
assert result.may_collect_result is False
assert result.succeeded is False
# Even a clean terminal exit 0 during the grace stays a timeout.
late = L.classify(observation(state='exited', exit_code=0), timed_out=True)
assert late.outcome_class == 'timeout', late.outcome_class
print('OK')
"

run_case "timeout outranks a nonzero exit and a contradiction alike" "${PRELUDE}
for observed in (observation(state='exited', exit_code=137),
                 observation(state='created', started_proven=False)):
    result = L.classify(observed, timed_out=True)
    assert result.outcome_class == 'timeout', result.outcome_class
print('OK')
"

# --- termination orchestration ---------------------------------------------------------

run_case "termination requests normal stop once, then kills only if still active" "${PRELUDE}
backend = FakeTermination()
clock = FakeClock(100.0, 100.5, 101.0, 102.5)
outcome = L.terminate_after_timeout(backend, CID, clock=clock)
assert names(backend).count('terminate') == 1, names(backend)
assert names(backend).count('kill') == 1, names(backend)
assert backend.calls[0] == ('terminate', CID)
assert ('kill', CID) in backend.calls
assert outcome.killed is True
print('OK')
"

run_case "no kill is issued when the container stops within the grace" "${PRELUDE}
backend = FakeTermination(exits_after=0)
clock = FakeClock(100.0, 100.1, 100.2)
outcome = L.terminate_after_timeout(backend, CID, clock=clock)
assert names(backend).count('terminate') == 1, names(backend)
assert 'kill' not in names(backend), names(backend)
assert outcome.killed is False
print('OK')
"

run_case "the grace is bounded to two seconds" "${PRELUDE}
backend = FakeTermination()
clock = FakeClock(100.0, 100.5, 101.0, 101.5, 102.0, 102.5)
L.terminate_after_timeout(backend, CID, clock=clock)
observed = [c for c in backend.calls if c[0] == 'still_active']
assert len(observed) <= 6, len(observed)
# The kill happens once the grace has elapsed, not before.
kill_index = names(backend).index('kill')
assert kill_index > 0
print('OK')
"

run_case "every termination action targets the exact immutable container ID" "${PRELUDE}
backend = FakeTermination()
L.terminate_after_timeout(backend, CID, clock=FakeClock(0.0, 3.0))
for call in backend.calls:
    assert call[1] == CID, call
# A short or non-hex identity is refused before any action.
for bad in ('c' * 12, 'kyri-CINV-000042', '', None):
    b = FakeTermination()
    try:
        L.terminate_after_timeout(b, bad, clock=FakeClock(0.0, 3.0))
    except L.LifecycleRefused:
        assert b.calls == [], b.calls
        continue
    raise AssertionError(f'accepted target {bad!r}')
print('OK')
"

run_case "termination never restarts, recreates, or reissues start" "${PRELUDE}
import inspect, ast
tree = ast.parse(inspect.getsource(L))
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if isinstance(body, list) and body and isinstance(
            node, (ast.Module, ast.ClassDef, ast.FunctionDef)):
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
ast.fix_missing_locations(tree)
code = ast.unparse(tree).lower()
for banned in ('restart', 'recreate', 're_run', 'reissue', 'retry',
               'extend_timeout', 'killpg', 'pkill', '--all'):
    assert banned not in code, banned
print('OK')
"

# --- boundaries -------------------------------------------------------------------------

run_case "T13 interprets no result.json and reads no output" "${PRELUDE}
import inspect
code = inspect.getsource(L).lower()
for banned in ('result.json', 'json.load', 'output_tree', 'collect_output',
               'read_result'):
    assert banned not in code, banned
print('OK')
"

run_case "classification is deterministic and immutable" "${PRELUDE}
import dataclasses
a = L.classify(observation(state='exited', exit_code=0))
b = L.classify(observation(state='exited', exit_code=0))
assert a == b
try:
    a.outcome_class = 'completed'
except Exception:
    pass
else:
    raise AssertionError('the classification was mutated')
assert {f.name for f in dataclasses.fields(a)} >= {
    'disposition', 'outcome_class', 'classification', 'started_proven',
    'exit_code_considered', 'may_collect_result', 'succeeded'}
print('OK')
"

run_case "only released outcome classes and specified classifications are used" "${PRELUDE}
from tools.capability.records import OUTCOME_CLASSES
seen = set()
cases = [
    observation(state='exited', exit_code=0),
    observation(state='exited', exit_code=1),
    observation(state='created', started_proven=False, started_at=None,
                finished_at=None),
    observation(state='running', exit_code=None, finished_at=None),
    observation(state='teleported'),
]
for observed in cases:
    seen.add(L.classify(observed).outcome_class)
    seen.add(L.classify(observed, timed_out=True).outcome_class)
assert seen <= set(OUTCOME_CLASSES), sorted(seen - set(OUTCOME_CLASSES))
for observed in cases:
    result = L.classify(observed)
    assert result.classification is None or isinstance(
        result.classification, Classification), result.classification
print('OK')
"

run_case "no real Podman or container was involved" "${PRELUDE}
import os, subprocess
assert os.getuid() != 0
import inspect
assert 'subprocess' not in inspect.getsource(L)
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T13 terminal classification validation passed.\n'
else
  printf 'Capability execution T13 terminal classification validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
