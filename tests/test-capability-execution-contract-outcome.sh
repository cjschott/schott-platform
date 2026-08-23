#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the contract-outcome translation, and the closure
# invariant it exists to make checkable.
#
# THE INVARIANT: every terminal failure reachable by
# `kyri-execution-boundary-verification` maps to one of the failure modes
# CCON-0001 declares. Before this module there was nothing to check it over --
# `lifecycle` concludes an outcome class in `records.OUTCOME_CLASSES` and a
# contract declares modes in the governed contract vocabulary, and those two
# sets are neither equal nor nested.
#
# THE ONE CORRECTION: `provider-error` -> `adapter-error`. Generic lifecycle
# semantics are UNCHANGED and are asserted unchanged below: a workload that ran
# and exited nonzero is still the provider's failure on the runtime plane. The
# translation happens once, here, at the contract boundary.
#
# NOTHING GENERIC IS MODIFIED. This suite proves `lifecycle._OUTCOME`,
# `records.OUTCOME_CLASSES`, `collector`, and `adapter` still say exactly what
# they said, because a translation that quietly edited its inputs would be the
# second opinion the runtime cannot have.
#
# Governed by:
#   platform-model/schemas/capability-contract.schema.yaml  (enums.failure_mode)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/contract_outcome.py"

# ===========================================================================
# The authority backstop
# ===========================================================================
# This module reads fields off an outcome another authority already formed. It
# opens nothing, runs nothing, and re-derives none of the judgements it reads.

assert_pure_translation() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/contract_outcome.py"

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

# A pure translation needs no import beyond typing. In particular it imports no
# lifecycle, no collector and no adapter: re-reading what they concluded is
# exactly the second opinion this module must not become.
PERMITTED_IMPORTS = {"__future__", "typing"}
FORBIDDEN_CALLS = {
    "open", "fdopen", "read", "write", "system", "popen", "exec", "eval",
    "compile", "__import__", "getenv", "now", "today", "monotonic", "classify",
    "read_result", "collect", "observe",
    # Fail-closed, structurally. Every one of these supplies a value nobody
    # decided: `get`/`setdefault`/`pop` hand back a default for a key that was
    # never mapped, and `defaultdict` invents one on demand. A translator that
    # can produce an answer for an outcome class no ruling covers is not a
    # translator, it is a guess -- so the surface is absent rather than unused.
    "get", "setdefault", "pop", "defaultdict",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "exit_code", "disposition")

findings = []
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
            if alias.name.split(".")[0] not in PERMITTED_IMPORTS:
                findings.append(f"{rel}: unpermitted import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] not in PERMITTED_IMPORTS:
            findings.append(f"{rel}: unpermitted import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"{rel}: forbidden call: {attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "the translation reads a formed outcome and re-derives nothing"
  else
    fail "contract-outcome backstop found: ${report}"
  fi
}

assert_pure_translation

# ===========================================================================
# Behaviour and the closure invariant
# ===========================================================================

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
import types
from tools.capability import records
from tools.capability.execution import lifecycle as L
from tools.capability.execution import collector as C
from tools.capability.execution import adapter as A
from tools.capability.execution.contract_outcome import (
    contract_failure_mode, ContractOutcomeError, CONTRACT_FAILURE_MODE,
    UNREACHABLE_OUTCOME_CLASSES, COMPLETED)
from tools.fabric.models import FAILURE_MODES

# The modes CCON-0001 proposes to declare.
DECLARED = ('refused', 'adapter-error', 'timeout', 'interrupted',
            'serialisation-failure', 'result-missing')
assert set(DECLARED) == set(FAILURE_MODES), 'the proposal left the vocabulary'

CID = 'c' * 64

def observed(exit_code, state='exited', started_proven=True, trustworthy=True,
             started='2026-08-22T00:00:00Z', finished='2026-08-22T00:00:01Z'):
    return L.LifecycleObservation(
        container_id=CID, state=state, started_at=started, finished_at=finished,
        exit_code=exit_code, started_proven=started_proven,
        exit_code_trustworthy=trustworthy)

def tree(result_present):
    manifest = C.OutputManifest(files=(), file_count=0, total_bytes=0,
                                entry_count=0, result_present=result_present)
    return C.OutputTree(manifest=manifest,
                        result_bytes=b'{}' if result_present else None)

def outcome(outcome_class, succeeded=False, output=None):
    '''An AdapterOutcome exactly as the adapter builds one.'''
    return A.AdapterOutcome(
        cinv='CINV-000042', container_id=CID, outcome_class=outcome_class,
        classification=None, terminal=None, result=object() if succeeded else None,
        output=output, started_proven=True, succeeded=succeeded)
"

# --- the generic plane is read, never edited -------------------------------
run_case "generic lifecycle semantics are unchanged" "${PRELUDE}
assert L._OUTCOME[L.TerminalDisposition.COMPLETED_NONZERO] == 'provider-error', \
    'generic provider-error semantics were changed'
assert L._OUTCOME[L.TerminalDisposition.COMPLETED_ZERO] == 'completed'
assert L._OUTCOME[L.TerminalDisposition.NEVER_STARTED] == 'adapter-error'
assert L._OUTCOME[L.TerminalDisposition.RUNNING] == 'interrupted'
assert L._OUTCOME[L.TerminalDisposition.UNTRUSTWORTHY_EXIT] == 'adapter-error'
assert L._OUTCOME[L.TerminalDisposition.TIMED_OUT] == 'timeout'
assert L._OUTCOME[L.TerminalDisposition.INTEGRITY_FAILURE] == 'adapter-error'
assert len(L._OUTCOME) == len(L.TerminalDisposition) == 7
print('OK')
"

run_case "the released record vocabulary is unchanged" "${PRELUDE}
assert records.OUTCOME_CLASSES == (
    'completed', 'refused', 'adapter-error', 'provider-error', 'timeout',
    'cancelled', 'interrupted', 'serialisation-failure')
print('OK')
"

# --- THE INVARIANT ---------------------------------------------------------
#
# Every disposition the real classifier can reach, translated, lands inside the
# modes CCON-0001 declares -- or is success. Driven through `lifecycle.classify`
# rather than over the table, so the ordering rules participate.
run_case "every reachable terminal disposition closes over the declared modes" "${PRELUDE}
reached = {}
cases = (
    (observed(0), False, 'clean exit'),
    (observed(1), False, 'unhandled exception'),
    (observed(137), False, 'OOM kill under --memory 256m'),
    (observed(0, state='running'), False, 'still running'),
    (observed(0, started_proven=False), False, 'never started'),
    (observed(0, trustworthy=False), False, 'untrustworthy exit'),
    (observed(0, state='unknown'), False, 'self-contradicting report'),
    (observed(0), True, 'timed out'),
)
for observation, timed_out, why in cases:
    terminal = L.classify(observation, timed_out=timed_out)
    # A completed-zero run still has to be told whether a result was admitted.
    if terminal.outcome_class == COMPLETED:
        candidates = ((True, None), (False, tree(False)), (False, tree(True)),
                      (False, None))
    else:
        candidates = ((False, None),)
    for succeeded, output in candidates:
        mode = contract_failure_mode(outcome(terminal.outcome_class,
                                             succeeded=succeeded, output=output))
        assert mode is None or mode in DECLARED, (
            why, terminal.disposition.name, terminal.outcome_class, mode)
        reached.setdefault(terminal.disposition.name, set()).add(mode)

# Every disposition was exercised, so the closure claim covers all seven.
assert set(reached) == {d.name for d in L.TerminalDisposition}, sorted(reached)
print('OK')
"

# --- the correction, stated exactly ----------------------------------------
run_case "a nonzero exit presents as adapter-error through the contract" "${PRELUDE}
terminal = L.classify(observed(1))
assert terminal.disposition is L.TerminalDisposition.COMPLETED_NONZERO
assert terminal.outcome_class == 'provider-error'
assert terminal.may_collect_result is False
assert contract_failure_mode(outcome('provider-error')) == 'adapter-error'
print('OK')
"

run_case "provider-error is not itself a declared contract mode" "${PRELUDE}
assert 'provider-error' not in DECLARED
assert 'provider-error' not in FAILURE_MODES
assert 'completed' not in FAILURE_MODES
print('OK')
"

# --- a completed run that admitted no result is still a failure ------------
run_case "a completed run with no result never reports success" "${PRELUDE}
assert contract_failure_mode(outcome(COMPLETED, succeeded=True)) is None
assert contract_failure_mode(
    outcome(COMPLETED, output=tree(False))) == 'result-missing'
assert contract_failure_mode(
    outcome(COMPLETED, output=tree(True))) == 'serialisation-failure'
assert contract_failure_mode(outcome(COMPLETED, output=None)) == 'adapter-error'
print('OK')
"

# --- identities carry through unchanged ------------------------------------
run_case "an outcome class that is already a governed mode is carried, not renamed" "${PRELUDE}
for governed in ('refused', 'adapter-error', 'timeout', 'interrupted',
                 'serialisation-failure'):
    assert contract_failure_mode(outcome(governed)) == governed, governed
print('OK')
"

# --- every mode CCON-0001 declares is actually producible -------------------
#
# The other half of closure: a contract must not declare a mode its interface
# can never report, or the declaration is decoration.
run_case "every declared mode is producible by the translation" "${PRELUDE}
produced = set()
produced.add(contract_failure_mode(outcome('refused')))
produced.add(contract_failure_mode(outcome('provider-error')))
produced.add(contract_failure_mode(outcome('timeout')))
produced.add(contract_failure_mode(outcome('interrupted')))
produced.add(contract_failure_mode(outcome(COMPLETED, output=tree(True))))
produced.add(contract_failure_mode(outcome(COMPLETED, output=tree(False))))
assert produced == set(DECLARED), sorted(produced)
print('OK')
"

# --- an outcome nobody emits is refused, not guessed ------------------------
run_case "cancelled is refused rather than mapped" "${PRELUDE}
assert UNREACHABLE_OUTCOME_CLASSES == ('cancelled',)
assert 'cancelled' not in CONTRACT_FAILURE_MODE
try:
    contract_failure_mode(outcome('cancelled'))
except ContractOutcomeError:
    pass
else:
    raise AssertionError('cancelled was mapped')
print('OK')
"

run_case "no committed module emits cancelled" "
import pathlib
hits = [str(p) for p in pathlib.Path('tools').rglob('*.py')
        if 'cancelled' in p.read_text(encoding='utf-8')
        and p.name != 'records.py' and p.name != 'contract_outcome.py']
assert hits == [], hits
print('OK')
"

# --- the table is closed in both directions --------------------------------
run_case "the table maps only released outcome classes, and only to governed modes" "${PRELUDE}
assert set(CONTRACT_FAILURE_MODE) <= set(records.OUTCOME_CLASSES), \
    'the table invents an outcome class'
assert set(CONTRACT_FAILURE_MODE.values()) <= set(FAILURE_MODES), \
    'the table invents a failure mode'
covered = set(CONTRACT_FAILURE_MODE) | {COMPLETED} | set(UNREACHABLE_OUTCOME_CLASSES)
assert covered == set(records.OUTCOME_CLASSES), sorted(
    set(records.OUTCOME_CLASSES) - covered)
print('OK')
"

run_case "an unreleased outcome class is refused rather than mapped" "${PRELUDE}
for bogus in ('provider_error', 'PROVIDER-ERROR', 'exploded', ''):
    try:
        contract_failure_mode(outcome(bogus))
    except ContractOutcomeError:
        continue
    raise AssertionError(bogus + ' was mapped')
try:
    contract_failure_mode(None)
except ContractOutcomeError:
    pass
else:
    raise AssertionError('a non-outcome was mapped')
print('OK')
"

run_case "success is impossible outside a completed lifecycle" "${PRELUDE}
try:
    contract_failure_mode(outcome('provider-error', succeeded=True))
except ContractOutcomeError:
    pass
else:
    raise AssertionError('a non-completed outcome claimed a trusted result')
print('OK')
"

# ===========================================================================
# Fail-closed
# ===========================================================================
#
# The translator may never produce a governed failure mode for something no
# ruling covers. Everything below is about the absence of a default: an outcome
# this module does not recognise, or does not fully state, must refuse rather
# than acquire a plausible answer.

# --- 1. every supported mapping is explicit --------------------------------
run_case "every supported mapping is written out, and there are exactly six" "${PRELUDE}
assert CONTRACT_FAILURE_MODE == {
    'refused': 'refused',
    'adapter-error': 'adapter-error',
    'timeout': 'timeout',
    'interrupted': 'interrupted',
    'serialisation-failure': 'serialisation-failure',
    'provider-error': 'adapter-error',
}, CONTRACT_FAILURE_MODE
print('OK')
"

# --- 2/3. no default mapping to anything -----------------------------------
#
# The corpus deliberately includes every governed CONTRACT failure mode that is
# not a released OUTCOME class. `result-missing` is the sharp case: it is a
# legitimate answer this module can return, and it is not a thing the runtime
# ever says -- so feeding it in must refuse rather than round-trip.
run_case "nothing outside the explicit table maps to any governed mode" "${PRELUDE}
corpus = [
    'result-missing',            # a contract mode, never a runtime outcome
    'provider_error', 'PROVIDER-ERROR', 'Provider-Error',
    ' provider-error', 'provider-error ', 'provider-error\n',
    'adapter_error', 'ADAPTER-ERROR', ' adapter-error',
    'timed-out', 'timedout', 'time-out', 'deadline-exceeded',
    'refuse', 'REFUSED', 'denied', 'rejected',
    'error', 'failed', 'failure', 'unknown', 'unavailable',
    'completed_zero', 'completed-nonzero', 'nonzero', 'exit-1',
    'serialisation_failure', 'serialization-failure',
    'interrupt', 'killed', 'oom', '', ' ', '-',
]
for value in corpus:
    try:
        mode = contract_failure_mode(outcome(value))
    except ContractOutcomeError:
        continue
    raise AssertionError(repr(value) + ' produced ' + repr(mode))
print('OK')
"

run_case "a non-string or absent outcome class refuses" "${PRELUDE}
for bogus in (None, 7, True, [], {}, object()):
    try:
        contract_failure_mode(outcome(bogus))
    except ContractOutcomeError:
        continue
    raise AssertionError(repr(bogus) + ' was translated')
for missing in (types.SimpleNamespace(), object(), None, 'completed', 7):
    try:
        contract_failure_mode(missing)
    except ContractOutcomeError:
        continue
    raise AssertionError('an object stating no outcome class was translated')
print('OK')
"

# An outcome that does not STATE a field is not an outcome with a convenient
# default for it. Before this rule a partial object silently became
# 'adapter-error' or carried its outcome class straight through.
run_case "an outcome that under-states itself refuses rather than defaulting" "${PRELUDE}
partial = types.SimpleNamespace(outcome_class=COMPLETED)
try:
    contract_failure_mode(partial)
except ContractOutcomeError:
    pass
else:
    raise AssertionError('a completed outcome stating no success defaulted')

partial = types.SimpleNamespace(outcome_class='timeout')
try:
    contract_failure_mode(partial)
except ContractOutcomeError:
    pass
else:
    raise AssertionError('an outcome stating no success defaulted')

partial = types.SimpleNamespace(outcome_class=COMPLETED, succeeded=False)
try:
    contract_failure_mode(partial)
except ContractOutcomeError:
    pass
else:
    raise AssertionError('a completed outcome stating no output defaulted')

for bad in (None, 'yes', 1, 0):
    try:
        contract_failure_mode(types.SimpleNamespace(
            outcome_class='timeout', succeeded=bad, output=None))
    except ContractOutcomeError:
        continue
    raise AssertionError('success stated as ' + repr(bad) + ' was accepted')
print('OK')
"

run_case "a malformed output tree refuses rather than becoming a mode" "${PRELUDE}
for bad in (object(), 7, 'tree', types.SimpleNamespace(),
            types.SimpleNamespace(manifest=object()),
            types.SimpleNamespace(manifest=types.SimpleNamespace(result_present='yes'))):
    try:
        contract_failure_mode(outcome(COMPLETED, output=bad))
    except ContractOutcomeError:
        continue
    raise AssertionError('a malformed tree was translated')
print('OK')
"

# --- 4. cancellation stays unruled -----------------------------------------
run_case "cancelled refuses while cancellation is unimplemented and unruled" "${PRELUDE}
assert 'cancelled' in records.OUTCOME_CLASSES, 'the released vocabulary changed'
assert 'cancelled' not in CONTRACT_FAILURE_MODE
assert 'cancelled' not in FAILURE_MODES
for shape in (outcome('cancelled'), outcome('cancelled', output=tree(True)),
              outcome('cancelled', output=tree(False))):
    try:
        contract_failure_mode(shape)
    except ContractOutcomeError:
        continue
    raise AssertionError('cancelled was translated')
print('OK')
"

# --- 5. the ruled mapping is explicit, not incidental ----------------------
run_case "provider-error to adapter-error is an explicit ruled entry" "${PRELUDE}
assert CONTRACT_FAILURE_MODE['provider-error'] == 'adapter-error'
assert contract_failure_mode(outcome('provider-error')) == 'adapter-error'
print('OK')
"

# --- 6. the two result failures stay distinguishable -----------------------
run_case "result-missing and serialisation-failure are distinct answers" "${PRELUDE}
missing = contract_failure_mode(outcome(COMPLETED, output=tree(False)))
invalid = contract_failure_mode(outcome(COMPLETED, output=tree(True)))
assert missing == 'result-missing', missing
assert invalid == 'serialisation-failure', invalid
assert missing != invalid, 'the two result failures collapsed into one'
print('OK')
"

# --- 7. success is never a failure -----------------------------------------
run_case "a completed run with a trusted result is never a failure mode" "${PRELUDE}
assert contract_failure_mode(outcome(COMPLETED, succeeded=True)) is None
assert contract_failure_mode(outcome(COMPLETED, succeeded=True,
                                     output=tree(True))) is None
assert COMPLETED not in CONTRACT_FAILURE_MODE, 'completed acquired a failure mode'
assert COMPLETED not in FAILURE_MODES
print('OK')
"

# --- the standing rule ------------------------------------------------------
#
# A future member of `records.OUTCOME_CLASSES` must be given a contract meaning
# by decision. It cannot flow through: the totality assertion above fails the
# moment the released vocabulary grows, and until somebody decides, the
# translator refuses the new class outright.
run_case "a future outcome class demands a decision instead of flowing through" "${PRELUDE}
for hypothetical in ('degraded', 'evicted', 'preempted', 'quota-exceeded',
                     'partially-completed'):
    assert hypothetical not in records.OUTCOME_CLASSES, hypothetical
    try:
        contract_failure_mode(outcome(hypothetical))
    except ContractOutcomeError:
        continue
    raise AssertionError(hypothetical + ' flowed through undecided')
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution contract-outcome validation passed.\n'
else
  printf 'Capability execution contract-outcome validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
