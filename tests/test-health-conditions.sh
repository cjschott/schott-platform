#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0006-H3 condition grammar evaluator.
#
# H3 IS A PURE FUNCTION. There is no store, no clock, no collector, no network
# and no record writing here. The evaluator receives a condition, an
# aggregation, a freshness policy, observations and an EXPLICIT evaluation
# instant, and returns a verdict. This suite asserts that, and asserts the
# evaluator refuses rather than guesses.
#
# THE TEST ORACLE IS THE COMMITTED SCHEMA AND ADR-0019, NOT THE MODULE.
#
# The operator set, the aggregation set, the dimension units and the forbidden
# percentile are read out of `capability-health-envelope.schema.yaml`. Nothing
# here imports a vocabulary from the module under test and then asserts the
# module equals it, which would pass against any implementation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import copy
import inspect
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


import yaml  # noqa: E402

ENV_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-health-envelope.schema.yaml").read_text())
OBS_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-health-observation.schema.yaml").read_text())

# --- the declared grammar, read from the schema -----------------------------
OPERATORS = list(ENV_SCHEMA["condition_operators"])
AGGREGATIONS = list(ENV_SCHEMA["aggregations"])
DIMENSION_UNITS = dict(ENV_SCHEMA["dimension_units"])
WINDOWED_REQUIRED = list(ENV_SCHEMA["windowed_count_fields"]["required"])
COLLECTION_STATUSES = list(OBS_SCHEMA["enums"]["collection_status"])

print("--- the suite's oracle is the committed schema ---")
check(OPERATORS == ["gt", "ge", "lt", "le", "eq"],
      "the schema declares exactly the five comparison operators")
check(AGGREGATIONS == ["instant", "windowed_count"],
      "the schema declares exactly two aggregations")
check(ENV_SCHEMA["percentile_aggregation"] == "forbidden",
      "the schema forbids percentile aggregation")
check(ENV_SCHEMA["unit_mismatch"] == "refuse"
      and ENV_SCHEMA["unit_conversion"] == "forbidden",
      "the schema refuses a unit mismatch and forbids conversion")
check(ENV_SCHEMA["condition_value_representation"] == "decimal-string",
      "the schema declares condition values as decimal strings")
check(ENV_SCHEMA["window_boundaries"] == "start-inclusive-end-exclusive",
      "the schema declares half-open windows")
check("min_samples" in WINDOWED_REQUIRED and "window_seconds" in WINDOWED_REQUIRED,
      "the schema requires min_samples and window_seconds on windowed_count")

try:
    from tools.health import records as H
    from tools.health import conditions as C
    from tools.health import errors as E
    import tools.health as PKG
    print("PASS: tools.health.records, .conditions and .errors import")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: import failed: {type(error).__name__}", file=sys.stderr)
    raise SystemExit(1)

for name in ("evaluate_condition", "CONDITION_OUTCOMES"):
    if hasattr(C, name):
        print(f"PASS: the evaluator module exposes {name}")
    else:
        print(f"FAIL: the evaluator module does not expose {name}", file=sys.stderr)
        failures += 1
if not hasattr(C, "evaluate_condition"):
    print(f"\nCondition grammar validation FAILED with {failures + 1} error(s).",
          file=sys.stderr)
    raise SystemExit(1)

# ENG-0006-H3A. The evaluator moved out of `records` into `conditions`. The
# package must still re-export it, and must re-export THE SAME OBJECT: an alias
# that wrapped or copied the evaluator would be a second implementation to keep
# in step with the first.
for name in ("evaluate_condition", "CONDITION_OUTCOMES", "UNKNOWN_REASONS",
             "ConditionResult"):
    check(hasattr(PKG, name) and getattr(PKG, name) is getattr(C, name),
          f"tools.health re-exports the SAME {name} as tools.health.conditions")
for name in ("parse", "HealthRecord", "KINDS", "citations_of",
             "validate_citations"):
    check(hasattr(PKG, name) and getattr(PKG, name) is getattr(H, name),
          f"tools.health re-exports the SAME {name} as tools.health.records")
# And no copy may survive in the record model.
for name in ("evaluate_condition", "ConditionResult", "CONDITION_OUTCOMES",
             "UNKNOWN_REASONS"):
    check(not hasattr(H, name), f"the record model no longer carries {name}")
# The dependency runs one way: an evaluator depends on the record model, never
# the reverse.
check("conditions" not in inspect.getsource(H),
      "the record model never references the evaluator module")

evaluate = C.evaluate_condition
OUTCOMES = tuple(C.CONDITION_OUTCOMES)
check(set(OUTCOMES) == {"satisfied", "not-satisfied", "unknown"},
      "the outcome vocabulary is exactly satisfied / not-satisfied / unknown")

# --- fixtures ---------------------------------------------------------------
T0 = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)


def stamp(offset_seconds):
    return (T0 + timedelta(seconds=offset_seconds)).isoformat()


EVAL_AT = stamp(0)
_counter = [0]


def obs(*, dimension="latency", value="1500", age=10, status="collected",
        unit=None, subject_id="CINST-000007", observation_id=None,
        subject_type="capability-instance"):
    """A parsed CHOBS record. `age` is seconds BEFORE the evaluation instant."""
    _counter[0] += 1
    payload = {
        "observation_id": observation_id or f"CHOBS-{_counter[0]:06d}",
        "subject_type": subject_type,
        "subject_id": subject_id,
        "dimension": dimension,
        "measured_value": value,
        "unit": unit if unit is not None else DIMENSION_UNITS[dimension],
        "observed_at": stamp(-age),
        "collector_id": "COLL-0001",
        "source_fingerprint": "sha256:abc",
        "collection_status": status,
        "provenance": {"tool": "test"},
    }
    if status != "collected":
        payload["measured_value"] = None
    return H.parse("capability-health-observation", payload)


_UNSET = object()  # so that None can be PASSED, not silently defaulted away


def run(*, dimension="latency", unit=_UNSET, operator="gt", value="2000",
        aggregation=_UNSET, policy=60, observations=(), evaluated_at=_UNSET):
    return evaluate(
        dimension=dimension,
        unit=DIMENSION_UNITS.get(dimension) if unit is _UNSET else unit,
        condition={"operator": operator, "value": value},
        aggregation={"kind": "instant"} if aggregation is _UNSET else aggregation,
        freshness_policy_seconds=policy,
        observations=observations,
        evaluated_at=EVAL_AT if evaluated_at is _UNSET else evaluated_at)


def refuses(label, **kwargs):
    """Assert a refusal that names a code and echoes no supplied value."""
    global failures
    forbidden = kwargs.pop("forbidden_value", None)
    try:
        run(**kwargs)
    except E.HealthRecordError as error:
        if not getattr(error, "code", ""):
            print(f"FAIL: {label}: refused without a named code", file=sys.stderr)
            failures += 1
            return None
        if forbidden is not None and str(forbidden) in str(error):
            print(f"FAIL: {label}: the refusal echoed the rejected value",
                  file=sys.stderr)
            failures += 1
            return None
        print(f"PASS: {label}")
        return error
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {label}: raised {type(error).__name__}, not a "
              f"HealthRecordError", file=sys.stderr)
        failures += 1
        return None
    print(f"FAIL: {label}: accepted", file=sys.stderr)
    failures += 1
    return None


# --- every supported comparison operator ------------------------------------
print("--- every declared operator, with its boundary ---")
# Expected answers are written out here from the operator's MEANING, not taken
# from the module. Threshold 2000; measured 1999, 2000 and 2001.
EXPECTED = {
    "gt": {"1999": "not-satisfied", "2000": "not-satisfied", "2001": "satisfied"},
    "ge": {"1999": "not-satisfied", "2000": "satisfied",     "2001": "satisfied"},
    "lt": {"1999": "satisfied",     "2000": "not-satisfied", "2001": "not-satisfied"},
    "le": {"1999": "satisfied",     "2000": "satisfied",     "2001": "not-satisfied"},
    "eq": {"1999": "not-satisfied", "2000": "satisfied",     "2001": "not-satisfied"},
}
check(sorted(EXPECTED) == sorted(OPERATORS),
      "the expectation table covers exactly the declared operators")
for operator in OPERATORS:
    for measured, expected in sorted(EXPECTED[operator].items()):
        result = run(operator=operator, value="2000",
                     observations=[obs(value=measured)])
        check(result.outcome == expected,
              f"{operator} 2000 against {measured} is {expected}")

# --- exact decimal semantics -------------------------------------------------
print("--- decimal comparison is exact, not binary float ---")
# 0.1 as an IEEE-754 double is exactly this value. Under binary floats the two
# compare EQUAL; under exact decimals they do not. If this assertion ever
# passes as "satisfied", the evaluator has started using floats.
DOUBLE_OF_TENTH = "0.1000000000000000055511151231257827021181583404541015625"
check(float("0.1") == float(DOUBLE_OF_TENTH),
      "the two literals are indistinguishable AS BINARY FLOATS (premise)")
check(Decimal("0.1") != Decimal(DOUBLE_OF_TENTH),
      "and distinguishable AS EXACT DECIMALS (premise)")
result = run(dimension="cpu-utilization", operator="eq", value="0.1",
             observations=[obs(dimension="cpu-utilization",
                               value=DOUBLE_OF_TENTH)])
check(result.outcome == "not-satisfied",
      "eq 0.1 against the double expansion of 0.1 is NOT satisfied")
result = run(dimension="cpu-utilization", operator="eq", value="0.1",
             observations=[obs(dimension="cpu-utilization", value="0.1")])
check(result.outcome == "satisfied", "eq 0.1 against 0.1 is satisfied")

# Trailing zeros are the same NUMBER, so eq is numeric and not string equality.
for threshold, measured in (("1", "1.0"), ("1.0", "1"), ("1.00", "1.000"),
                            ("2000", "2.0e3"), ("0", "-0")):
    result = run(operator="eq", value=threshold, observations=[obs(value=measured)])
    check(result.outcome == "satisfied",
          f"eq treats {threshold!r} and {measured!r} as the same exact decimal")

# Precision far beyond a double survives.
big_a = "1." + "0" * 30 + "1"
big_b = "1." + "0" * 30 + "2"
check(float(big_a) == float(big_b), "the two long decimals collide as floats (premise)")
result = run(operator="eq", value=big_a, observations=[obs(value=big_b)])
check(result.outcome == "not-satisfied",
      "a difference 31 decimal places down is still a difference")
result = run(operator="lt", value=big_b, observations=[obs(value=big_a)])
check(result.outcome == "satisfied", "and it still orders correctly")

# --- invalid numeric values and unsupported types ---------------------------
print("--- invalid values and unsupported types are refused ---")
# `forbidden_value` is only meaningful for a value distinctive enough that a
# substring match means a real echo: "" and "  " match every message.
for bad in ("banana", "", "  ", "1,500", "0x10", "1500ms", "--1", "1.2.3",
            "NaN", "nan", "sNaN", "Infinity", "-Infinity", "inf"):
    refuses(f"a threshold value {bad!r} is refused", value=bad,
            observations=[obs()],
            forbidden_value=bad if bad.strip() else None)
for bad in (1500, 1500.0, True, False, None, [], {}, Decimal("1500")):
    refuses(f"a threshold of type {type(bad).__name__} is refused", value=bad,
            observations=[obs()])
for bad in ("banana", "NaN", "Infinity", "1,500", ""):
    refuses(f"a measured value {bad!r} is refused",
            observations=[obs(value=bad)],
            forbidden_value=bad if bad.strip() else None)
for bad in (1500, 1500.0, True, [1], {"a": 1}):
    refuses(f"a measured value of type {type(bad).__name__} is refused",
            observations=[obs(value=bad)])

# --- unsupported operators ---------------------------------------------------
print("--- unsupported operators are refused ---")
for bad in ("ne", "neq", "!=", ">", ">=", "between", "in", "not", "and", "or",
            "GT", "Gt", "", None, 1, []):
    error = refuses(f"operator {bad!r} is refused", operator=bad,
                    observations=[obs()])
    if error is not None and isinstance(bad, str) and bad:
        check(error.code == E.OPERATOR_NOT_PERMITTED,
              f"operator {bad!r} is refused as an operator, by name")

# --- unit validation ---------------------------------------------------------
print("--- a unit mismatch refuses and never converts ---")
# An observation whose unit disagrees with its own dimension cannot be built at
# all: H1 refuses it at parse time. Asserted here so the reason this suite
# cannot construct that case is recorded rather than looking like a gap.
try:
    H.parse("capability-health-observation", {
        "observation_id": "CHOBS-000500", "subject_type": "capability-instance",
        "subject_id": "CINST-000007", "dimension": "latency",
        "measured_value": "1500", "unit": "seconds",
        "observed_at": stamp(-10), "collector_id": "COLL-0001",
        "source_fingerprint": "sha256:abc", "collection_status": "collected",
        "provenance": {"tool": "test"}})
    check(False, "H1 refuses an observation whose unit is not its dimension's")
except E.HealthRecordError as error:
    check(error.code == E.UNIT_MISMATCH,
          "H1 refuses an observation whose unit is not its dimension's")
# So the envelope side is where a mismatch can be declared, and it refuses.
refuses("an envelope unit that is not the dimension's declared unit is refused",
        dimension="latency", unit="seconds", observations=[obs()])
refuses("an envelope unit of the wrong kind entirely is refused",
        dimension="latency", unit="percent", observations=[obs()])
for dimension, unit in sorted(DIMENSION_UNITS.items()):
    wrong = "furlongs"
    refuses(f"{dimension} declared in {wrong} is refused",
            dimension=dimension, unit=wrong, value="1",
            observations=[])
refuses("an unknown dimension is refused", dimension="latency-ish",
        unit="milliseconds", observations=[])
# A conversion must never be attempted: 2 seconds is not 2000 milliseconds here.
refuses("no implicit conversion turns seconds into milliseconds",
        dimension="latency", unit="seconds", value="2",
        observations=[obs(dimension="latency", value="2000")])

# --- percentile and other unsupported aggregations --------------------------
print("--- percentiles and unsupported aggregations are refused ---")
for bad_kind in ("p95", "p99", "percentile", "p50", "mean", "average", "median",
                 "sum", "max", "min", "stddev", "rate", "INSTANT", "", None, 1):
    error = refuses(f"aggregation kind {bad_kind!r} is refused",
                    aggregation={"kind": bad_kind}, observations=[obs()])
    if error is not None and isinstance(bad_kind, str) and bad_kind:
        check(error.code == E.AGGREGATION_NOT_PERMITTED,
              f"aggregation {bad_kind!r} is refused as an aggregation, by name")
refuses("a percentile with a declared interpolation is still refused",
        aggregation={"kind": "percentile", "percentile": "95",
                     "interpolation": "nearest-rank"}, observations=[obs()])
refuses("an aggregation that is not a mapping is refused",
        aggregation="instant", observations=[obs()])
refuses("an aggregation with no kind is refused",
        aggregation={"window_seconds": 60}, observations=[obs()])
refuses("an aggregation carrying an unknown member is refused",
        aggregation={"kind": "instant", "percentile": "95"},
        observations=[obs()])

# --- instant aggregation -----------------------------------------------------
print("--- instant evaluates the newest usable observation ---")
result = run(operator="gt", value="2000",
             observations=[obs(value="3000", age=50), obs(value="100", age=5)])
check(result.outcome == "not-satisfied",
      "instant uses the NEWEST observation, not the worst")
check(result.observation_ids and len(result.observation_ids) == 1,
      "instant cites exactly the one observation it used")
result = run(operator="gt", value="2000",
             observations=[obs(value="100", age=50), obs(value="3000", age=5)])
check(result.outcome == "satisfied", "and the newest again when it violates")

# Ties in observed_at break by identifier ascending, so "newest" is total.
first = obs(value="100", age=5, observation_id="CHOBS-000900")
second = obs(value="3000", age=5, observation_id="CHOBS-000901")
check(run(operator="gt", value="2000",
          observations=[first, second]).observation_ids == ("CHOBS-000901",),
      "an observed_at tie breaks by observation identifier ascending")
check(run(operator="gt", value="2000",
          observations=[second, first]).observation_ids == ("CHOBS-000901",),
      "and the input order does not change which one that is")

print("--- no usable observation yields unknown, never a verdict ---")
for label, observations in (
        ("an empty observation set", []),
        ("only a failed collection", [obs(status="failed")]),
        ("only an unavailable collection", [obs(status="unavailable")]),
        ("only observations of another dimension",
         [obs(dimension="queue-depth", value="5")]),
        ("only an observation older than the freshness policy",
         [obs(value="3000", age=120)]),
):
    result = run(operator="gt", value="2000", observations=observations)
    check(result.outcome == "unknown", f"{label} yields unknown")
    check(result.outcome != "satisfied" and result.outcome != "not-satisfied",
          f"{label} is never reported as a verdict")

# An unusable observation must not mask a usable one.
result = run(operator="gt", value="2000",
             observations=[obs(status="failed", age=1), obs(value="3000", age=5)])
check(result.outcome == "satisfied",
      "a newer FAILED collection does not hide an older usable observation")

print("--- the freshness policy bounds usability, and a null policy is unknown ---")
check(run(operator="gt", value="2000", policy=60,
          observations=[obs(value="3000", age=60)]).outcome == "satisfied",
      "an observation exactly at the policy age is still usable")
check(run(operator="gt", value="2000", policy=60,
          observations=[obs(value="3000", age=61)]).outcome == "unknown",
      "an observation one second past the policy is not")
result = run(operator="gt", value="2000", policy=None,
             observations=[obs(value="3000", age=1)])
check(result.outcome == "unknown",
      "a NULL freshness policy yields unknown, never a favourable default")
for bad in (0, -1, "60", 60.0, True):
    refuses(f"a freshness policy of {bad!r} is refused", policy=bad,
            observations=[obs()])

# --- windowed_count ----------------------------------------------------------
print("--- windowed_count counts usable observations in a half-open window ---")


def windowed(window_seconds=300, min_samples=3):
    return {"kind": "windowed_count", "window_seconds": window_seconds,
            "min_samples": min_samples}


five = [obs(dimension="failure-count", value="1", age=a, )
        for a in (10, 20, 30, 40, 50)]
result = run(dimension="failure-count", operator="gt", value="3",
             aggregation=windowed(), policy=600, observations=five)
check(result.outcome == "satisfied", "five usable observations are more than three")
check(result.count == 5, "and the count is reported as five")
check(len(result.observation_ids) == 5, "and all five are cited")
result = run(dimension="failure-count", operator="gt", value="5",
             aggregation=windowed(), policy=600, observations=five)
check(result.outcome == "not-satisfied", "five is not more than five")
result = run(dimension="failure-count", operator="eq", value="5",
             aggregation=windowed(), policy=600, observations=five)
check(result.outcome == "satisfied", "and equals five")

print("--- the window is start-inclusive and end-exclusive ---")
# window_seconds=300 anchored at EVAL_AT: [EVAL_AT-300, EVAL_AT)
at_start = obs(dimension="failure-count", value="1", age=300)
inside = obs(dimension="failure-count", value="1", age=299)
before = obs(dimension="failure-count", value="1", age=301)
at_end = obs(dimension="failure-count", value="1", age=0)
check(run(dimension="failure-count", operator="eq", value="1",
          aggregation=windowed(min_samples=1), policy=600,
          observations=[at_start]).count == 1,
      "an observation exactly at the window start is INSIDE the window")
check(run(dimension="failure-count", operator="eq", value="1",
          aggregation=windowed(min_samples=1), policy=600,
          observations=[inside]).count == 1,
      "an observation inside the window counts")
check(run(dimension="failure-count", operator="eq", value="0",
          aggregation=windowed(min_samples=1), policy=600,
          observations=[before]).outcome == "unknown",
      "an observation one second before the window start is OUTSIDE it")
check(run(dimension="failure-count", operator="eq", value="0",
          aggregation=windowed(min_samples=1), policy=600,
          observations=[at_end]).outcome == "unknown",
      "an observation exactly at the evaluation instant is EXCLUDED")

print("--- min_samples is required, and a thin window is unknown ---")
for missing in ({"kind": "windowed_count", "window_seconds": 300},
                {"kind": "windowed_count", "min_samples": 3},
                {"kind": "windowed_count"}):
    refuses(f"windowed_count missing {sorted(set(WINDOWED_REQUIRED) - set(missing))} "
            f"is refused", dimension="failure-count",
            aggregation=missing, observations=five, policy=600)
for bad in (0, -1, "3", 3.0, True, None):
    refuses(f"a min_samples of {bad!r} is refused", dimension="failure-count",
            aggregation=windowed(min_samples=bad), observations=five, policy=600)
    refuses(f"a window_seconds of {bad!r} is refused", dimension="failure-count",
            aggregation=windowed(window_seconds=bad), observations=five, policy=600)
two = five[:2]
result = run(dimension="failure-count", operator="gt", value="1",
             aggregation=windowed(min_samples=3), policy=600, observations=two)
check(result.outcome == "unknown",
      "a window holding fewer usable observations than min_samples is unknown")
check(result.count is None or result.count == 2,
      "and the thin count is not presented as a verdict")
result = run(dimension="failure-count", operator="gt", value="1",
             aggregation=windowed(min_samples=2), policy=600, observations=two)
check(result.outcome == "satisfied",
      "exactly min_samples usable observations is enough")
# Unusable observations do not count towards coverage.
mixed = [obs(dimension="failure-count", value="1", age=10),
         obs(dimension="failure-count", status="failed", age=20),
         obs(dimension="failure-count", status="unavailable", age=30)]
check(run(dimension="failure-count", operator="gt", value="0",
          aggregation=windowed(min_samples=2), policy=600,
          observations=mixed).outcome == "unknown",
      "failed and unavailable collections do not count towards min_samples")
check(run(dimension="failure-count", operator="gt", value="0",
          aggregation=windowed(min_samples=1), policy=600,
          observations=mixed).count == 1,
      "and only the usable one is counted")
# An observation inside the window but outside the freshness policy is unusable.
check(run(dimension="failure-count", operator="gt", value="0",
          aggregation=windowed(window_seconds=300, min_samples=1), policy=60,
          observations=[obs(dimension="failure-count", value="1", age=200)]
          ).outcome == "unknown",
      "a freshness policy tighter than the window still bounds usability")

# --- the evaluation instant is always supplied by the caller ----------------
print("--- the evaluator never reads a clock ---")
signature = inspect.signature(evaluate)
check("evaluated_at" in signature.parameters,
      "evaluate_condition takes an explicit evaluated_at")
check(signature.parameters["evaluated_at"].default is inspect.Parameter.empty,
      "evaluated_at has NO default, so an implicit 'now' is impossible")
check(all(p.kind is inspect.Parameter.KEYWORD_ONLY
          for p in signature.parameters.values()),
      "every parameter is keyword-only, so no call can transpose them")
# ENG-0006-H3A: BOTH modules, so moving code between them cannot move it out
# of the scope of these checks.
source = inspect.getsource(C) + "\n" + inspect.getsource(H)
for banned in ("datetime.now", "datetime.utcnow", "time.time", "time.monotonic",
               "date.today", "utcfromtimestamp"):
    check(banned not in source,
          f"the module never calls {banned}()")
for bad in ("2026-10-16T12:00:00", "not-a-time", "", None, 0, 1760616000):
    refuses(f"an evaluation instant of {bad!r} is refused", evaluated_at=bad,
            observations=[obs()])
check(run(operator="gt", value="2000", observations=[obs(value="3000", age=5)],
          evaluated_at=(T0.astimezone(timezone(timedelta(hours=-5)))).isoformat()
          ).outcome == "satisfied",
      "the same instant in another offset gives the same verdict")

# --- determinism -------------------------------------------------------------
print("--- repeated evaluation is deterministic ---")
sample = [obs(value="3000", age=5), obs(value="100", age=50),
          obs(status="failed", age=1)]
baseline = run(operator="gt", value="2000", observations=sample)
for attempt in range(25):
    again = run(operator="gt", value="2000", observations=sample)
    if (again.outcome, again.observation_ids, again.count) != \
       (baseline.outcome, baseline.observation_ids, baseline.count):
        check(False, f"evaluation {attempt} differed from the first")
        break
else:
    check(True, "twenty-five repeated evaluations returned an identical result")
shuffled = [sample[2], sample[0], sample[1]]
again = run(operator="gt", value="2000", observations=shuffled)
check((again.outcome, again.observation_ids) == (baseline.outcome,
                                                 baseline.observation_ids),
      "input ORDER does not change the result")

print("--- the evaluator mutates nothing and reaches nothing ---")
before = [o.to_dict() for o in sample]
run(operator="gt", value="2000", observations=sample)
check([o.to_dict() for o in sample] == before,
      "evaluation leaves every supplied observation unchanged")
condition = {"operator": "gt", "value": "2000"}
aggregation = {"kind": "instant"}
observations = [obs(value="3000", age=5)]
evaluate(dimension="latency", unit="milliseconds", condition=condition,
         aggregation=aggregation, freshness_policy_seconds=60,
         observations=observations, evaluated_at=EVAL_AT)
check(condition == {"operator": "gt", "value": "2000"},
      "evaluation does not mutate the supplied condition")
check(aggregation == {"kind": "instant"},
      "evaluation does not mutate the supplied aggregation")
check(len(observations) == 1, "evaluation does not mutate the supplied sequence")

result = run(operator="gt", value="2000", observations=[obs(value="3000", age=5)])
try:
    result.outcome = "not-satisfied"
    check(False, "a result refuses mutation")
except Exception:  # noqa: BLE001
    check(True, "a result refuses mutation")

for banned in ("socket", "subprocess", "requests", "urllib", "http",
               "asyncio", "threading", "multiprocessing", "sqlite3"):
    check(f"import {banned}" not in source and f"from {banned}" not in source,
          f"the module never imports {banned}")
# Matched at a call boundary. A bare substring search is useless here:
# `re.compile(` contains `compile(`, and the module legitimately precompiles
# its patterns.
import re as _re  # noqa: E402

for banned_name in ("eval", "exec", "compile", "__import__"):
    called = _re.search(rf"(?<![\w.]){banned_name}\s*\(", source)
    check(called is None,
          f"the module never calls {banned_name}()")

print("--- the evaluator concludes nothing beyond the condition ---")
for banned_attr in ("derive_state", "derive_health_state", "evaluate_eligibility",
                    "select", "write_record", "store", "collect",
                    "receive_heartbeat", "recommend", "set_trust_state"):
    check(not hasattr(C, banned_attr) and not hasattr(H, banned_attr)
          and not hasattr(PKG, banned_attr),
          f"neither module nor the package exposes {banned_attr}()")
check(result.outcome in OUTCOMES,
      "a result's outcome is always one of the three declared outcomes")
check(not any(s in str(result.outcome) for s in ("healthy", "degraded",
                                                 "unavailable", "withheld")),
      "an outcome is never a health STATE: that is a later increment's authority")

# --- invalid or missing condition fields ------------------------------------
print("--- malformed conditions are refused ---")
for bad_condition in ({}, {"operator": "gt"}, {"value": "2000"},
                      {"operator": "gt", "value": "2000", "unit": "ms"},
                      {"operator": "gt", "value": "2000", "dimension": "latency"},
                      "gt 2000", "> 2000", ["gt", "2000"], None, 1,
                      {"Operator": "gt", "Value": "2000"}):
    global_label = f"a condition of {bad_condition!r} is refused"
    try:
        evaluate(dimension="latency", unit="milliseconds",
                 condition=bad_condition, aggregation={"kind": "instant"},
                 freshness_policy_seconds=60, observations=[obs()],
                 evaluated_at=EVAL_AT)
        print(f"FAIL: {global_label}: accepted", file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: {global_label}")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {global_label}: raised {type(error).__name__}",
              file=sys.stderr)
        failures += 1

print("--- an expression string is never a condition ---")
check(ENV_SCHEMA["condition_form"] == "structured"
      and ENV_SCHEMA["condition_expression_strings"] == "forbidden",
      "the schema forbids expression strings (premise)")
for expression in ("p95 > 2000ms", "> 32", "latency > 2000", "value >= 2000"):
    try:
        evaluate(dimension="latency", unit="milliseconds", condition=expression,
                 aggregation={"kind": "instant"}, freshness_policy_seconds=60,
                 observations=[obs()], evaluated_at=EVAL_AT)
        print(f"FAIL: the expression string {expression!r} was accepted",
              file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: the expression string {expression!r} is refused")

# --- observations must be records, and must agree on their subject ----------
print("--- the evaluator takes validated records of one subject ---")
for bad in ("CHOBS-000001", {"observation_id": "CHOBS-000001"}, 1, None):
    refuses(f"an observation given as {type(bad).__name__} is refused",
            observations=[bad])
for not_a_sequence in (42, None, 3.5, {"a": 1}, "CHOBS-000001"):
    try:
        evaluate(dimension="latency", unit="milliseconds",
                 condition={"operator": "gt", "value": "2000"},
                 aggregation={"kind": "instant"}, freshness_policy_seconds=60,
                 observations=not_a_sequence, evaluated_at=EVAL_AT)
        print(f"FAIL: a non-sequence observation set {not_a_sequence!r} was "
              f"accepted", file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: a non-sequence observation set {not_a_sequence!r} is refused")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: a non-sequence observation set {not_a_sequence!r} raised "
              f"{type(error).__name__}", file=sys.stderr)
        failures += 1
wrong_family = H.parse("capability-health-state", {
    "state_id": "CHSTATE-000001", "subject_type": "capability-instance",
    "subject_id": "CINST-000007", "state": "healthy",
    "envelope_id": "CHENV-0001", "envelope_version": 1,
    "derived_from_observation_ids": ["CHOBS-000001"], "freshness": "current",
    "reason": "within envelope", "evaluated_at": stamp(0),
    "provenance": {"tool": "test"}})
refuses("a record of the wrong family is refused", observations=[wrong_family])
refuses("observations of two different subjects are refused",
        observations=[obs(value="3000", age=5),
                      obs(value="100", age=10, subject_id="CINST-000008")])
refuses("observations of two different subject types are refused",
        observations=[obs(dimension="cpu-utilization", value="30", age=5),
                      obs(dimension="cpu-utilization", value="40", age=10,
                          subject_type="capability-host")])

print()
if failures:
    print(f"Condition grammar validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All condition grammar assertions passed.")
PY
