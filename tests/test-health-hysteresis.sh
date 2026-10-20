#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0006-H5 hysteresis and continuity
# evaluator.
#
# H5 IS A PURE FUNCTION. It receives a declared hysteresis, a condition,
# observations and an EXPLICIT evaluation instant, and decides whether a
# transition is recordable -- producing the proof when it is. There is no
# store, no clock, no collector, no record writing and no state derivation
# here.
#
# THE TEST ORACLE IS THE COMMITTED SCHEMA AND ADR-0019, NOT THE MODULE.
#
# The hysteresis kinds, the four required declaration members, the continuity
# rules and the six CHDEG proof fields are read out of the committed schemas.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import copy
import inspect
import itertools
import sys
from datetime import datetime, timedelta, timezone
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
DEG_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-degradation-event.schema.yaml").read_text())
DIMENSION_UNITS = dict(ENV_SCHEMA["dimension_units"])
CONTINUITY = dict(ENV_SCHEMA["hysteresis_continuity"])

print("--- the oracle is the committed schema ---")
check(ENV_SCHEMA["hysteresis_kinds"] == ["duration"],
      "the schema declares exactly one hysteresis kind: duration")
check(sorted(ENV_SCHEMA["hysteresis_fields"]["required"])
      == ["kind", "max_gap_seconds", "min_samples", "seconds"],
      "the schema requires all four hysteresis members")
check(CONTINUITY["usable_observation"]
      == "collected-with-value-within-freshness-policy",
      "the schema defines a usable observation")
check(CONTINUITY["violation_required"] == "every-usable-observation-in-interval",
      "the schema requires violation throughout the interval")
check(CONTINUITY["gap_applies_to_interval_boundaries"] is True,
      "the schema applies the maximum gap to the interval boundaries")
check(CONTINUITY["reset_on_non_violating_usable_observation"] is True,
      "the schema resets on a non-violating usable observation")
check(CONTINUITY["reset_on_gap_exceeding_maximum"] is True,
      "the schema resets on a gap exceeding the maximum")
check(CONTINUITY["gap_cause_affects_reset"] is False,
      "the schema says the CAUSE of a gap does not affect the reset")
check(DEG_SCHEMA["unprovable_transition"] == "refuse",
      "the schema refuses an unprovable transition")
PROOF_FIELDS = [f for f in DEG_SCHEMA["required_fields"]
                if f.startswith("hysteresis")]
check(PROOF_FIELDS == ["hysteresis", "hysteresis_satisfied_over_seconds",
                       "hysteresis_first_observation_id",
                       "hysteresis_last_observation_id",
                       "hysteresis_sample_count",
                       "hysteresis_observed_max_gap_seconds"],
      "the schema declares exactly the six hysteresis proof fields")
check("derived_from_observation_ids" in DEG_SCHEMA["required_fields"],
      "and requires the ordered supporting evidence")

try:
    from tools.health import hysteresis as Y
    from tools.health import records as H
    from tools.health import conditions as C
    from tools.health import errors as E
    import tools.health as PKG
    print("PASS: tools.health.hysteresis and its siblings import")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: import failed: {type(error).__name__}: {error}", file=sys.stderr)
    raise SystemExit(1)

for name in ("evaluate_hysteresis", "HYSTERESIS_OUTCOMES", "UNSATISFIED_REASONS"):
    if hasattr(Y, name):
        print(f"PASS: the hysteresis module exposes {name}")
    else:
        print(f"FAIL: the hysteresis module does not expose {name}", file=sys.stderr)
        failures += 1
if not hasattr(Y, "evaluate_hysteresis"):
    print(f"\nHysteresis validation FAILED with {failures + 1} error(s).",
          file=sys.stderr)
    raise SystemExit(1)

evaluate = Y.evaluate_hysteresis
check(set(Y.HYSTERESIS_OUTCOMES) == {"satisfied", "unsatisfied", "unprovable"},
      "the outcome vocabulary is exactly satisfied / unsatisfied / unprovable")
# The three labels are INTERNAL result values and must not leak into any
# schema vocabulary.
for leaked in set(Y.HYSTERESIS_OUTCOMES):
    check(leaked not in (DEG_SCHEMA.get("enums", {}).get("from_state") or []),
          f"{leaked!r} is not a declared health-state value")

# --- fixtures ---------------------------------------------------------------
T0 = datetime(2026, 10, 20, 12, 0, 0, tzinfo=timezone.utc)


def stamp(offset):
    return (T0 + timedelta(seconds=offset)).isoformat()


EVAL_AT = stamp(0)
_n = [0]


def obs(*, age, value="3000", dimension="latency", status="collected",
        observation_id=None, subject_id="CINST-000007",
        subject_type="capability-instance"):
    """A parsed CHOBS. `age` is seconds BEFORE the evaluation instant."""
    _n[0] += 1
    return H.parse("capability-health-observation", {
        "observation_id": observation_id or f"CHOBS-{_n[0]:06d}",
        "subject_type": subject_type, "subject_id": subject_id,
        "dimension": dimension,
        "measured_value": value if status == "collected" else None,
        "unit": DIMENSION_UNITS[dimension], "observed_at": stamp(-age),
        "collector_id": "COLL-0001", "source_fingerprint": "sha256:abc",
        "collection_status": status, "provenance": {"tool": "test"}})


def hyst(seconds=120, max_gap=30, min_samples=3, kind="duration"):
    return {"kind": kind, "seconds": seconds, "max_gap_seconds": max_gap,
            "min_samples": min_samples}


_UNSET = object()


def run(*, dimension="latency", unit=_UNSET, condition=_UNSET,
        hysteresis=_UNSET, policy=600, observations=(), evaluated_at=_UNSET):
    return evaluate(
        dimension=dimension,
        unit=DIMENSION_UNITS.get(dimension) if unit is _UNSET else unit,
        condition={"operator": "gt", "value": "2000"} if condition is _UNSET
        else condition,
        hysteresis=hyst() if hysteresis is _UNSET else hysteresis,
        freshness_policy_seconds=policy,
        observations=observations,
        evaluated_at=EVAL_AT if evaluated_at is _UNSET else evaluated_at)


def refuses(label, **kwargs):
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


def violating_run(count, *, spacing=30, last_age=0, value="3000"):
    """`count` violating observations ending `last_age` before the instant."""
    return [obs(age=last_age + spacing * i, value=value)
            for i in range(count - 1, -1, -1)]


# --- duration ---------------------------------------------------------------
print("--- the declared duration, and its boundary ---")
# seconds=120, max_gap=30, min_samples=3. Five observations 30s apart ending at
# the instant spans 120s exactly.
result = run(observations=violating_run(5, spacing=30, last_age=0),
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "a 120s span against a 120s requirement is satisfied (inclusive)")
check(result.proof is not None, "and it carries a proof")
check(result.proof.hysteresis_satisfied_over_seconds == 120,
      "the achieved duration is reported as 120s")
result = run(observations=violating_run(4, spacing=30, last_age=0),
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "a 90s span against a 120s requirement is unsatisfied")
check(result.reason == "duration-not-met", "and names the duration as the cause")
check(result.proof is None, "an unsatisfied result carries no proof")
result = run(observations=violating_run(5, spacing=30, last_age=0),
             hysteresis=hyst(seconds=121, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "one second short of the requirement is unsatisfied")

# --- minimum samples --------------------------------------------------------
print("--- the minimum sample count, and its boundary ---")
for samples, expected in ((1, "satisfied"), (3, "satisfied"), (5, "satisfied"),
                          (6, "unsatisfied"), (10, "unsatisfied")):
    result = run(observations=violating_run(5, spacing=30, last_age=0),
                 hysteresis=hyst(seconds=120, max_gap=30, min_samples=samples))
    check(result.outcome == expected,
          f"five usable violating observations against min_samples={samples} "
          f"is {expected}")
result = run(observations=violating_run(5, spacing=30, last_age=0),
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=6))
check(result.reason == "coverage-below-minimum-samples",
      "falling short of min_samples names coverage as the cause")
# Two samples ninety seconds apart is "two measurements and an assumption".
result = run(observations=[obs(age=90), obs(age=0)],
             hysteresis=hyst(seconds=90, max_gap=120, min_samples=3))
check(result.outcome == "unsatisfied",
      "two samples ninety seconds apart do not satisfy min_samples=3")

# --- the maximum gap --------------------------------------------------------
print("--- the maximum gap, and the committed boundary rule ---")
# ADR-0019 resets on a gap EXCEEDING max_gap_seconds, so a gap exactly at the
# boundary does NOT reset.
result = run(observations=[obs(age=120), obs(age=90), obs(age=60),
                           obs(age=30), obs(age=0)],
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "gaps exactly at max_gap_seconds do not reset the interval")
check(result.proof.hysteresis_observed_max_gap_seconds == 30,
      "and the observed maximum gap is reported as 30s")
result = run(observations=[obs(age=124), obs(age=93), obs(age=62),
                           obs(age=31), obs(age=0)],
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "a gap one second over the maximum resets the interval")
check(result.reason in ("duration-not-met", "coverage-below-minimum-samples",
                        "gap-exceeds-maximum"),
      "and the cause is named from the closed vocabulary")

print("--- the gap applies to the interval boundaries ---")
# A run that ended long ago cannot establish continuity to the instant: the
# last-to-t1 gap exceeds the maximum. This is the monitoring-outage rule.
result = run(observations=violating_run(5, spacing=30, last_age=200),
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "a violating run that stopped 200s ago does not reach the instant")
check(result.reason == "gap-exceeds-maximum",
      "and the boundary gap is named as the cause")
result = run(observations=violating_run(5, spacing=30, last_age=30),
             hysteresis=hyst(seconds=150, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "a last-to-instant gap exactly at the maximum is permitted")
# When the boundary gap AND the duration both fail, the boundary gap is the
# cause reported: a reset means the interval never reached t1 at all, so there
# is no span to be short.
result = run(observations=[obs(age=200, value="3000")],
             hysteresis=hyst(seconds=500, max_gap=30, min_samples=1))
check(result.outcome == "unsatisfied",
      "a single stale-but-usable violating observation does not satisfy")
check(result.reason == "gap-exceeds-maximum",
      "and the unreached interval boundary is reported ahead of the duration")

print("--- a gap resets regardless of its cause ---")
# gap_cause_affects_reset: false. A collection failure produces a gap in USABLE
# observations, and the gap breaks continuity: a monitoring outage cannot
# manufacture a transition.
outage = [obs(age=240, value="3000"), obs(age=210, value="3000"),
          obs(age=180, status="failed"), obs(age=150, status="failed"),
          obs(age=120, status="unavailable"),
          obs(age=30, value="3000"), obs(age=0, value="3000")]
result = run(observations=outage,
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "a collection outage mid-interval breaks continuity")
check(result.reason == "duration-not-met",
      "and the cause is the SURVIVING run being too short, not the raw span: "
      "the interval resets at the outage rather than spanning it")
check(result.proof is None,
      "no proof is produced for an interrupted interval")
# The same shape with the outage replaced by usable violating observations
# DOES satisfy, which is what proves the outage was the deciding factor.
healthy_run = [obs(age=a, value="3000") for a in (240, 210, 180, 150, 120, 90, 60, 30, 0)]
check(run(observations=healthy_run,
          hysteresis=hyst(seconds=120, max_gap=30, min_samples=3)
          ).outcome == "satisfied",
      "the same interval WITHOUT the outage is satisfied")

print("--- a failed collection is never counted as a violation ---")
result = run(observations=[obs(age=90, status="failed"),
                           obs(age=60, status="failed"),
                           obs(age=30, status="failed"),
                           obs(age=0, status="failed")],
             hysteresis=hyst(seconds=60, max_gap=120, min_samples=3))
check(result.outcome == "unprovable",
      "four failed collections establish nothing")
check(result.proof is None, "and produce no proof")
for status in ("failed", "unavailable"):
    result = run(observations=[obs(age=a, status=status) for a in (90, 60, 30, 0)],
                 hysteresis=hyst(seconds=60, max_gap=120, min_samples=1))
    check(result.outcome == "unprovable",
          f"a wall of {status} collections is unprovable, not satisfied")

print("--- a non-violating usable observation resets the interval ---")
interrupted = [obs(age=150, value="3000"), obs(age=120, value="3000"),
               obs(age=90, value="100"),  # does not violate gt 2000
               obs(age=60, value="3000"), obs(age=30, value="3000"),
               obs(age=0, value="3000")]
result = run(observations=interrupted,
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "unsatisfied",
      "a non-violating observation mid-interval resets continuity")
check(result.reason == "duration-not-met",
      "and the surviving run is too short")
result = run(observations=interrupted,
             hysteresis=hyst(seconds=60, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "the run AFTER the reset satisfies a shorter requirement")
check(result.proof.hysteresis_sample_count == 3,
      "and the proof counts only the three observations after the reset")
check(result.proof.hysteresis_first_observation_id
      == interrupted[3].observation_id,
      "the interval starts at the first violating observation after the reset")

# ISOLATING THE VIOLATION RESET. With a maximum gap wide enough to span the
# non-violating observation, the gap rule cannot be what breaks continuity --
# only the non-violating observation itself can. Without this the reset could
# be deleted and the gap rule would silently cover for it.
spanning = [obs(age=90, value="3000"), obs(age=60, value="100"),
            obs(age=30, value="3000"), obs(age=0, value="3000")]
result = run(observations=spanning,
             hysteresis=hyst(seconds=90, max_gap=60, min_samples=2))
check(result.outcome == "unsatisfied",
      "a non-violating observation resets continuity even when the gap it "
      "leaves is within the maximum")
check(result.reason == "duration-not-met",
      "and only the 30s run after it survives, which is too short for 90s")
result = run(observations=spanning,
             hysteresis=hyst(seconds=30, max_gap=60, min_samples=2))
check(result.outcome == "satisfied" and result.proof.hysteresis_sample_count == 2,
      "the surviving two-observation run satisfies a 30s requirement")

# --- future-dated evidence --------------------------------------------------
print("--- future observations cannot establish current continuity ---")
future = obs(age=-60, value="3000")
result = run(observations=violating_run(5, spacing=30, last_age=0) + [future],
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "a future observation is ignored and the past run still stands")
check(future.observation_id not in result.proof.derived_from_observation_ids,
      "and that future observation is NOT cited in the proof")
result = run(observations=[obs(age=-30, value="3000"), obs(age=-60, value="3000"),
                           obs(age=-90, value="3000")],
             hysteresis=hyst(seconds=30, max_gap=120, min_samples=1))
check(result.outcome == "unprovable",
      "observations entirely in the future establish nothing")

# --- ordering and determinism ----------------------------------------------
print("--- ordering does not change the outcome ---")
sample = violating_run(5, spacing=30, last_age=0)
baseline = run(observations=sample,
               hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
seen = set()
for permutation in itertools.islice(itertools.permutations(sample), 24):
    r = run(observations=list(permutation),
            hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
    seen.add((r.outcome, r.proof.hysteresis_satisfied_over_seconds,
              r.proof.hysteresis_sample_count,
              r.proof.derived_from_observation_ids))
check(len(seen) == 1, "24 input orderings produce one identical result")
for _ in range(25):
    r = run(observations=sample,
            hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
    if (r.outcome, r.proof.to_dict()) != (baseline.outcome, baseline.proof.to_dict()):
        check(False, "a repeated evaluation differed")
        break
else:
    check(True, "twenty-five repeated evaluations are identical")

print("--- timestamp ties break deterministically ---")
tied = [obs(age=0, value="3000", observation_id="CHOBS-000902"),
        obs(age=0, value="3000", observation_id="CHOBS-000901"),
        obs(age=30, value="3000", observation_id="CHOBS-000900")]
first = run(observations=tied, hysteresis=hyst(seconds=30, max_gap=30, min_samples=3))
second = run(observations=list(reversed(tied)),
             hysteresis=hyst(seconds=30, max_gap=30, min_samples=3))
check(first.proof.derived_from_observation_ids
      == second.proof.derived_from_observation_ids,
      "a timestamp tie yields the same ordered evidence either way")
check(first.proof.derived_from_observation_ids
      == ("CHOBS-000900", "CHOBS-000901", "CHOBS-000902"),
      "ties order by observation identifier ascending")

# --- the transition proof ---------------------------------------------------
print("--- the proof carries exactly the committed CHDEG evidence ---")
result = run(observations=violating_run(5, spacing=30, last_age=0),
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
proof = result.proof
for field in PROOF_FIELDS:
    check(field in proof.to_dict(), f"the proof carries {field}")
check("derived_from_observation_ids" in proof.to_dict(),
      "the proof carries derived_from_observation_ids")
check(proof.to_dict()["hysteresis"] == hyst(seconds=120, max_gap=30, min_samples=3),
      "the proof quotes the resolved hysteresis declaration")
check(proof.hysteresis_sample_count == 5, "the sample count is five")
check(isinstance(proof.hysteresis_first_observation_id, str)
      and proof.hysteresis_first_observation_id.startswith("CHOBS-"),
      "the first observation identifier is a real observation identifier")
check(proof.hysteresis_first_observation_id
      != proof.hysteresis_last_observation_id,
      "and the interval spans two distinct observations")
check(proof.hysteresis_satisfied_over_seconds >= 120,
      "the achieved duration meets the requirement")
check(proof.hysteresis_observed_max_gap_seconds <= 30,
      "the observed maximum gap is within the declared maximum")
check(len(proof.derived_from_observation_ids) == proof.hysteresis_sample_count,
      "the cited evidence count equals the sample count")
# The observed maximum must include the last-to-t1 boundary gap, because
# clause 4 tests that gap against the same declared maximum. Here the boundary
# gap (25s) is the largest, so a build that only looked at inter-observation
# gaps would report 10s and understate the proof.
boundary_heavy = run(observations=violating_run(5, spacing=10, last_age=25),
                     hysteresis=hyst(seconds=60, max_gap=30, min_samples=3))
check(boundary_heavy.outcome == "satisfied",
      "a run with a 25s trailing gap under a 30s maximum is satisfied")
check(boundary_heavy.proof.hysteresis_observed_max_gap_seconds == 25,
      "and the observed maximum gap is the 25s BOUNDARY gap, not the 10s "
      "inter-observation gap")
check(proof.derived_from_observation_ids[0] == proof.hysteresis_first_observation_id
      and proof.derived_from_observation_ids[-1] == proof.hysteresis_last_observation_id,
      "the cited evidence runs from the first to the last observation")
try:
    proof.hysteresis_sample_count = 99
    check(False, "the proof refuses mutation")
except Exception:  # noqa: BLE001
    check(True, "the proof refuses mutation")
try:
    result.outcome = "satisfied"
    check(False, "the result refuses mutation")
except Exception:  # noqa: BLE001
    check(True, "the result refuses mutation")

# --- unprovable -------------------------------------------------------------
print("--- an unprovable transition is never dressed as a verdict ---")
for label, observations in (
        ("no observations at all", []),
        ("only another dimension's observations",
         [obs(age=a, dimension="queue-depth", value="9") for a in (60, 30, 0)]),
        ("only observations past the freshness policy",
         [obs(age=a, value="3000") for a in (900, 870, 840)]),
        ("only non-violating observations",
         [obs(age=a, value="100") for a in (90, 60, 30, 0)]),
):
    result = run(observations=observations,
                 hysteresis=hyst(seconds=60, max_gap=120, min_samples=1),
                 policy=600)
    check(result.outcome == "unprovable", f"{label} is unprovable")
    check(result.proof is None, f"{label} fabricates no proof")
    check(result.reason == "no-candidate-interval",
          f"{label} names the absence of an interval")
check(run(observations=[], hysteresis=hyst(), policy=600).outcome != "satisfied",
      "an empty observation set never satisfies a hysteresis")

# --- refusals ---------------------------------------------------------------
print("--- unsupported and malformed declarations are refused ---")
error = refuses("the occurrences hysteresis kind is refused",
                hysteresis=hyst(kind="occurrences"),
                observations=violating_run(5))
if error is not None:
    check(error.code == E.HYSTERESIS_KIND_NOT_PERMITTED,
          "occurrences is refused as a hysteresis kind, by name")
for bad_kind in ("occurrences", "count", "DURATION", "", None, 1, []):
    refuses(f"hysteresis kind {bad_kind!r} is refused",
            hysteresis=hyst(kind=bad_kind), observations=violating_run(5))
for missing in ({"kind": "duration", "seconds": 120, "max_gap_seconds": 30},
                {"kind": "duration", "seconds": 120, "min_samples": 3},
                {"kind": "duration", "max_gap_seconds": 30, "min_samples": 3},
                {"seconds": 120, "max_gap_seconds": 30, "min_samples": 3},
                {"kind": "duration"}, {}):
    refuses(f"a hysteresis missing {sorted({'kind','seconds','max_gap_seconds','min_samples'} - set(missing))} "
            f"is refused", hysteresis=missing, observations=violating_run(5))
refuses("a hysteresis carrying an unknown member is refused",
        hysteresis={**hyst(), "occurrences": 3}, observations=violating_run(5))
for bad in (0, -1, "120", 120.0, True, None):
    for member in ("seconds", "max_gap_seconds", "min_samples"):
        refuses(f"a hysteresis {member} of {bad!r} is refused",
                hysteresis={**hyst(), member: bad}, observations=violating_run(5))
for bad in ("instant", ["duration"], 1, None):
    refuses(f"a hysteresis of {bad!r} is refused", hysteresis=bad,
            observations=violating_run(5))
refuses("a malformed condition is refused", condition={"operator": "ne", "value": "1"},
        observations=violating_run(5))
refuses("a condition with a non-decimal value is refused",
        condition={"operator": "gt", "value": "banana"},
        observations=violating_run(5))
for bad in ("latency-ish", "", None, 1):
    refuses(f"a dimension of {bad!r} is refused", dimension=bad, observations=[])
refuses("an envelope unit that is not the dimension's is refused",
        dimension="latency", unit="seconds", observations=violating_run(5))
for bad in ("2026-10-20T12:00:00", "not-a-time", "", None, 0):
    refuses(f"an evaluation instant of {bad!r} is refused", evaluated_at=bad,
            observations=violating_run(5))
for bad in (0, -1, "600", 600.0, True):
    refuses(f"a freshness policy of {bad!r} is refused", policy=bad,
            observations=violating_run(5))
result = run(observations=violating_run(5), policy=None)
check(result.outcome == "unprovable",
      "a null freshness policy makes continuity unprovable, never satisfied")
check(result.reason == "null-freshness-policy",
      "and names the null policy as the cause")

print("--- subject and dimension isolation ---")
refuses("observations of two subjects are refused",
        observations=[obs(age=30, value="3000"),
                      obs(age=0, value="3000", subject_id="CINST-000008")])
refuses("observations of two subject types are refused",
        dimension="cpu-utilization",
        observations=[obs(age=30, value="30", dimension="cpu-utilization"),
                      obs(age=0, value="40", dimension="cpu-utilization",
                          subject_type="capability-host")])
mixed = (violating_run(5, spacing=30, last_age=0)
         + [obs(age=a, dimension="queue-depth", value="1") for a in (15, 45, 75)])
result = run(dimension="latency", observations=mixed,
             hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check(result.outcome == "satisfied",
      "another dimension's observations are filtered, not treated as gaps")
check(all(o not in [x.observation_id for x in mixed[5:]]
          for o in result.proof.derived_from_observation_ids),
      "and none of them is cited in the proof")
for bad in ("CHOBS-000001", {"a": 1}, 1, None):
    refuses(f"an observation given as {type(bad).__name__} is refused",
            observations=[bad])
state_record = H.parse("capability-health-state", {
    "state_id": "CHSTATE-000001", "subject_type": "capability-instance",
    "subject_id": "CINST-000007", "state": "healthy",
    "envelope_id": "CHENV-0001", "envelope_version": 1,
    "derived_from_observation_ids": ["CHOBS-000001"], "freshness": "current",
    "reason": "within envelope", "evaluated_at": EVAL_AT,
    "provenance": {"tool": "test"}})
refuses("a record of the wrong family is refused", observations=[state_record])

# --- purity and authority ---------------------------------------------------
print("--- the evaluator is pure and claims no authority ---")
signature = inspect.signature(evaluate)
check("evaluated_at" in signature.parameters
      and signature.parameters["evaluated_at"].default is inspect.Parameter.empty,
      "evaluated_at is required and has no default")
check(all(p.kind is inspect.Parameter.KEYWORD_ONLY
          for p in signature.parameters.values()),
      "every parameter is keyword-only")
source = inspect.getsource(Y)
for banned in ("datetime.now", "datetime.utcnow", "time.time", "time.monotonic",
               "date.today", "utcfromtimestamp"):
    check(banned not in source, f"the module never calls {banned}()")
for banned in ("socket", "subprocess", "requests", "urllib", "http", "asyncio",
               "threading", "multiprocessing", "sqlite3", "yaml", "open("):
    check(banned not in source, f"the module never uses {banned}")
import re as _re  # noqa: E402
for banned in ("eval", "exec", "compile", "__import__", "import_module"):
    check(_re.search(rf"(?<![\w.]){banned}\s*\(", source) is None,
          f"the module never calls {banned}()")
for banned_attr in ("derive_state", "derive_health_state", "evaluate_eligibility",
                    "select", "write_record", "store", "collect",
                    "receive_heartbeat", "recommend", "set_trust_state",
                    "write_degradation_event", "emit"):
    check(not hasattr(Y, banned_attr),
          f"the hysteresis module exposes no {banned_attr}()")
check("tools.fabric" not in source and "tools.capability" not in source,
      "the module reaches no other plane")
before = [o.to_dict() for o in sample]
run(observations=sample, hysteresis=hyst(seconds=120, max_gap=30, min_samples=3))
check([o.to_dict() for o in sample] == before,
      "evaluation leaves every supplied observation unchanged")
declared = hyst()
run(observations=sample, hysteresis=declared)
check(declared == hyst(), "evaluation does not mutate the supplied hysteresis")

print("--- the module boundary ---")
check(hasattr(PKG, "evaluate_hysteresis")
      and PKG.evaluate_hysteresis is Y.evaluate_hysteresis,
      "tools.health re-exports the SAME evaluate_hysteresis")
check(not hasattr(H, "evaluate_hysteresis")
      and not hasattr(C, "evaluate_hysteresis"),
      "neither the record model nor the condition evaluator carries it")
imports = [line for line in source.splitlines()
           if line.startswith(("import ", "from "))]
check(any(".conditions" in line for line in imports),
      "the hysteresis evaluator depends on the condition evaluator, as A5 declares")
check(not any("freshness" in line for line in imports),
      "and not on the freshness evaluator")

print()
if failures:
    print(f"Hysteresis validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All hysteresis assertions passed.")
PY
