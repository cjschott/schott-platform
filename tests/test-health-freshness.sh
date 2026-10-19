#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0006-H4 freshness evaluator.
#
# H4 IS A PURE FUNCTION. It receives observations, a per-dimension freshness
# policy and an EXPLICIT evaluation instant, and returns an advisory freshness
# label per dimension. There is no store, no clock, no collector, no network,
# no record writing and no health state here.
#
# THE TEST ORACLE IS THE COMMITTED SCHEMA AND THE CONFIDENCE AND FRESHNESS
# STANDARD, NOT THE MODULE.
#
# The four freshness states are read out of the committed schemas. Nothing here
# imports a vocabulary from the module under test and then asserts the module
# equals it, which would pass against any implementation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import copy
import inspect
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

OBS_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-health-observation.schema.yaml").read_text())
STATE_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-health-state.schema.yaml").read_text())
ENV_SCHEMA = yaml.safe_load(
    (root / "platform-model/schemas/capability-health-envelope.schema.yaml").read_text())
STANDARD = (root / "docs/standards/confidence-freshness-standard.md").read_text()

STATES = list(OBS_SCHEMA["enums"]["freshness"])
COLLECTION_STATUSES = list(OBS_SCHEMA["enums"]["collection_status"])
DIMENSION_UNITS = dict(ENV_SCHEMA["dimension_units"])

print("--- the suite's oracle is the committed schema and the standard ---")
check(STATES == ["current", "aging", "stale", "unknown"],
      "the schema declares exactly the four freshness states")
check(list(STATE_SCHEMA["enums"]["freshness"]) == STATES,
      "the state and observation schemas declare the same four")
check(STATE_SCHEMA["stored_freshness"] == "freshness-at-evaluated-at",
      "stored freshness is declared historical")
check(STATE_SCHEMA["stored_freshness_authoritative_for_eligibility"] is False,
      "a stored freshness label is declared non-authoritative for eligibility")
check(STATE_SCHEMA["freshness_recomputed_at_use"] is True,
      "freshness is declared recomputed at use")
check("freshness_policy_seconds" in ENV_SCHEMA["dimension_fields"]["required"],
      "each envelope dimension declares its own freshness policy")
check("review_required" in STATE_SCHEMA["conditionally_required_fields"],
      "review_required is a declared conditionally-required field")
check("never a default maximum age" in STANDARD,
      "the standard forbids a default maximum age (Null Policy Rule)")
check("the freshness of nothing is `unknown`, never `stale`" in STANDARD,
      "the standard says absent evidence is unknown, never stale")

try:
    from tools.health import freshness as F
    from tools.health import records as H
    from tools.health import errors as E
    import tools.health as PKG
    print("PASS: tools.health.freshness, .records and .errors import")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: import failed: {type(error).__name__}: {error}", file=sys.stderr)
    raise SystemExit(1)

for name in ("evaluate_freshness", "evaluate_envelope_freshness",
             "FRESHNESS_STATES"):
    if hasattr(F, name):
        print(f"PASS: the freshness module exposes {name}")
    else:
        print(f"FAIL: the freshness module does not expose {name}", file=sys.stderr)
        failures += 1
if not hasattr(F, "evaluate_freshness"):
    print(f"\nFreshness validation FAILED with {failures + 1} error(s).",
          file=sys.stderr)
    raise SystemExit(1)

evaluate = F.evaluate_freshness
per_envelope = F.evaluate_envelope_freshness
check(tuple(F.FRESHNESS_STATES) == tuple(STATES),
      "the module's state vocabulary is exactly the schema's four")

# --- fixtures ---------------------------------------------------------------
T0 = datetime(2026, 10, 19, 12, 0, 0, tzinfo=timezone.utc)


def stamp(offset):
    return (T0 + timedelta(seconds=offset)).isoformat()


EVAL_AT = stamp(0)
_n = [0]


def obs(*, dimension="latency", age=10, status="collected", value="1500",
        observation_id=None, stored_freshness=None, subject_id="CINST-000007"):
    """A parsed CHOBS. `age` is seconds BEFORE the evaluation instant."""
    _n[0] += 1
    payload = {
        "observation_id": observation_id or f"CHOBS-{_n[0]:06d}",
        "subject_type": "capability-instance", "subject_id": subject_id,
        "dimension": dimension,
        "measured_value": value if status == "collected" else None,
        "unit": DIMENSION_UNITS[dimension], "observed_at": stamp(-age),
        "collector_id": "COLL-0001", "source_fingerprint": "sha256:abc",
        "collection_status": status, "provenance": {"tool": "test"},
    }
    if stored_freshness is not None:
        payload["freshness"] = stored_freshness
    return H.parse("capability-health-observation", payload)


_UNSET = object()


def run(*, dimension="latency", policy=60, observations=(), evaluated_at=_UNSET,
        aging=_UNSET):
    kwargs = dict(dimension=dimension, freshness_policy_seconds=policy,
                  observations=observations,
                  evaluated_at=EVAL_AT if evaluated_at is _UNSET else evaluated_at)
    if aging is not _UNSET:
        kwargs["aging_threshold_seconds"] = aging
    return evaluate(**kwargs)


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


# --- the boundary ------------------------------------------------------------
print("--- freshness at the declared limit, and one second past it ---")
for age, expected in ((0, "current"), (1, "current"), (59, "current"),
                      (60, "current"), (61, "stale"), (120, "stale"),
                      (86400, "stale")):
    result = run(policy=60, observations=[obs(age=age)])
    check(result.state == expected,
          f"age {age}s against a 60s policy is {expected}")
    check(result.age_seconds == age,
          f"age {age}s is reported as {age}s")
check(run(policy=60, observations=[obs(age=60)]).state == "current",
      "an observation EXACTLY at the limit is still current, not stale")
check(run(policy=60, observations=[obs(age=61)]).state == "stale",
      "one second past the limit is stale")
check(run(policy=1, observations=[obs(age=1)]).state == "current",
      "the boundary holds at a one-second policy too")
check(run(policy=1, observations=[obs(age=2)]).state == "stale",
      "and one second past it")

print("--- a declared aging threshold, and none ---")
# No warning threshold is declared anywhere for Health, so the evaluator must
# not invent one: with no threshold supplied, `aging` is never reported.
plain = run(policy=60, observations=[obs(age=59)])
check(plain.state == "current",
      "with no aging threshold declared, 59s of a 60s policy is current")
check(plain.aging_threshold_seconds is None,
      "and the result records that no aging threshold was applied")
states_without_threshold = {run(policy=60, observations=[obs(age=a)]).state
                            for a in range(0, 121, 5)}
check("aging" not in states_without_threshold,
      "`aging` is NEVER reported without a declared threshold")
check(states_without_threshold <= {"current", "stale"},
      "and the only labels produced are current and stale")
# Supplied explicitly, the aging band appears between the two.
for age, expected in ((0, "current"), (29, "current"), (30, "current"),
                      (31, "aging"), (59, "aging"), (60, "aging"),
                      (61, "stale")):
    result = run(policy=60, aging=30, observations=[obs(age=age)])
    check(result.state == expected,
          f"age {age}s with a 30s aging threshold and 60s policy is {expected}")
check(run(policy=60, aging=30, observations=[obs(age=45)]
          ).aging_threshold_seconds == 30,
      "the result records the aging threshold it applied")
refuses("an aging threshold equal to the policy is refused",
        policy=60, aging=60, observations=[obs(age=10)])
refuses("an aging threshold greater than the policy is refused",
        policy=60, aging=61, observations=[obs(age=10)])
for bad in (0, -1, "30", 30.0, True):
    refuses(f"an aging threshold of {bad!r} is refused",
            policy=60, aging=bad, observations=[obs(age=10)])

# --- the Null Policy Rule ----------------------------------------------------
print("--- a null policy is unknown WITH review_required ---")
result = run(policy=None, observations=[obs(age=10)])
check(result.state == "unknown", "a null freshness policy is unknown")
check(result.review_required is True,
      "a null freshness policy sets review_required")
check(result.reason == "null-freshness-policy",
      "and names which gap caused it")
check(result.policy_seconds is None, "the result reports no policy")
check(result.age_seconds == 10,
      "the age is still reported, because the evidence exists")
check(run(policy=None, observations=[obs(age=10)]).state != "stale",
      "a null policy is never reported as stale")
check(run(policy=None, observations=[obs(age=100000)]).state == "unknown",
      "however old the evidence is")
for bad in (0, -1, "60", 60.0, True, [], {}):
    refuses(f"a freshness policy of {bad!r} is refused", policy=bad,
            observations=[obs(age=10)])

print("--- absent evidence is unknown, never stale ---")
for label, observations in (
        ("an empty observation set", []),
        ("only another dimension's observations",
         [obs(dimension="queue-depth", value="5")]),
        ("only a failed collection", [obs(status="failed")]),
        ("only an unavailable collection", [obs(status="unavailable")]),
):
    result = run(policy=60, observations=observations)
    check(result.state == "unknown", f"{label} is unknown")
    check(result.state != "stale", f"{label} is NOT stale")
    check(result.age_seconds is None, f"{label} reports no age")
    check(result.reason == "no-usable-observation",
          f"{label} names the absence as the cause")
# Per ADR-0013 and unknown-and-freshness.md, the review flag is enumerated for a
# null policy, insufficient-policy and contradicting sources -- NOT for absent
# evidence, which is the default inert state.
check(run(policy=60, observations=[]).review_required is False,
      "absent evidence alone does not set review_required")

print("--- the NEWEST collected observation sets the age ---")
# The standard measures knowledge age "against the newest supporting record,
# because the oldest record in a set says nothing useful about how current the
# overall picture is". With two collected observations straddling the policy,
# picking the older one would invert the verdict.
result = run(policy=60, observations=[obs(age=600), obs(age=5)])
check(result.state == "current",
      "two collected observations, newest 5s old: current, not stale")
check(result.age_seconds == 5,
      "the age is measured from the NEWEST collected observation")
newest = obs(age=5, observation_id="CHOBS-000777")
result = run(policy=60, observations=[obs(age=600), newest, obs(age=900)])
check(result.observation_id == "CHOBS-000777",
      "and the result cites the observation the age came from")
# And the converse, so the assertion cannot pass by always choosing one end.
result = run(policy=60, observations=[obs(age=300), obs(age=600)])
check(result.state == "stale" and result.age_seconds == 300,
      "when every observation is past policy, the newest still sets the age")
result = run(policy=60, aging=30, observations=[obs(age=600), obs(age=45)])
check(result.state == "aging" and result.age_seconds == 45,
      "the newest observation also decides the aging band")

print("--- a failed collection never establishes freshness ---")
# A dead collector must not freeze a favourable assessment, so a newer FAILED
# collection cannot make an old measurement look current.
result = run(policy=60, observations=[obs(age=5, status="failed"),
                                      obs(age=600, status="collected")])
check(result.state == "stale",
      "a newer failed collection does not refresh an old measurement")
check(result.age_seconds == 600,
      "the age is measured from the newest COLLECTED observation")
result = run(policy=60, observations=[obs(age=5, status="unavailable"),
                                      obs(age=30, status="collected")])
check(result.state == "current" and result.age_seconds == 30,
      "an unavailable collection is skipped and the collected one is used")
for status in COLLECTION_STATUSES:
    if status == "collected":
        continue
    check(run(policy=60, observations=[obs(age=1, status=status)]
              ).state == "unknown",
          f"a lone {status} collection yields unknown")

print("--- future observations do not establish freshness ---")
for age in (-1, -60, -86400):
    result = run(policy=60, observations=[obs(age=age)])
    check(result.state == "unknown",
          f"an observation {-age}s in the FUTURE does not make a dimension current")
    check(result.age_seconds is None,
          f"and no negative age is reported for a {-age}s future observation")
result = run(policy=60, observations=[obs(age=-10), obs(age=30)])
check(result.state == "current" and result.age_seconds == 30,
      "a future observation is skipped and the newest past one is used")

# --- per dimension, never collapsed -----------------------------------------
print("--- freshness is per dimension and never collapsed ---")
mixed = [obs(dimension="latency", age=5),
         obs(dimension="availability", value="1", age=5000),
         obs(dimension="queue-depth", value="3", age=30)]
check(run(dimension="latency", policy=60, observations=mixed).state == "current",
      "latency is current")
check(run(dimension="availability", policy=60, observations=mixed).state == "stale",
      "availability is stale at the same instant")
check(run(dimension="queue-depth", policy=60, observations=mixed).state == "current",
      "queue-depth is current at the same instant")
# Each dimension carries its OWN policy, so the same age can be current for one
# and stale for another.
check(run(dimension="availability", policy=3600, observations=mixed).state == "stale",
      "availability evidence 5000s old is still stale against a 3600s policy")
check(run(dimension="availability", policy=6000, observations=mixed).state == "current",
      "and current against a 6000s policy: the SAME evidence, a different policy")

print("--- the envelope-level entry point returns one result per dimension ---")
DIMS = {"latency": 60, "availability": 60, "queue-depth": 3600}
per = per_envelope(dimensions=DIMS, observations=mixed, evaluated_at=EVAL_AT)
check(set(per) == set(DIMS),
      "every declared dimension gets its own result")
check(len(per) == len(DIMS), "and exactly one result each")
check({d: r.state for d, r in per.items()}
      == {"latency": "current", "availability": "stale", "queue-depth": "current"},
      "the per-dimension states are independent")
check(not isinstance(per, (str, int, float)),
      "the envelope result is not a collapsed scalar")
for banned in ("score", "overall", "aggregate", "subject_freshness",
               "collapsed", "worst"):
    check(not hasattr(per, banned) and banned not in per,
          f"the envelope result exposes no {banned!r}")
# A declared dimension with no observations still gets a result, so a dimension
# that stopped reporting cannot vanish from the picture.
per = per_envelope(dimensions={"latency": 60, "cpu-utilization": 60},
                   observations=[obs(dimension="latency", age=5)],
                   evaluated_at=EVAL_AT)
check(per["cpu-utilization"].state == "unknown",
      "a declared dimension with no evidence is reported as unknown, not omitted")
check(len(per) == 2, "and the dimension is present in the result")
# With NO observations at all, every declared dimension must still appear: a
# dimension that stopped reporting is the one worth knowing about, so it cannot
# be dropped from the picture.
empty = per_envelope(dimensions=DIMS, observations=[], evaluated_at=EVAL_AT)
check(set(empty) == set(DIMS),
      "with no observations at all, every declared dimension still appears")
check(len(empty) == len(DIMS),
      "and the result holds one entry per declared dimension")
check(all(r.state == "unknown" for r in empty.values()),
      "each is unknown rather than missing")
check(all(r.reason == "no-usable-observation" for r in empty.values()),
      "and each names the absence as the cause")
try:
    per["latency"] = None
    check(False, "the envelope result refuses mutation")
except Exception:  # noqa: BLE001
    check(True, "the envelope result refuses mutation")
# A null policy is PERMITTED per CHENV ("Null is permitted and produces
# freshness: unknown"), so it must flow through to unknown rather than refuse.
null_policy = per_envelope(dimensions={"latency": None}, observations=mixed,
                           evaluated_at=EVAL_AT)
check(null_policy["latency"].state == "unknown"
      and null_policy["latency"].review_required is True,
      "a null policy in the envelope mapping yields unknown with review_required")
for bad in ({}, {"nope": 60}, {"latency": 0},
            {"latency": "60"}, [], "latency", None):
    try:
        per_envelope(dimensions=bad, observations=mixed, evaluated_at=EVAL_AT)
        print(f"FAIL: envelope dimensions {bad!r} was accepted", file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: envelope dimensions {bad!r} is refused")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: envelope dimensions {bad!r} raised {type(error).__name__}",
              file=sys.stderr)
        failures += 1

# --- the stored label is never read -----------------------------------------
print("--- a STORED freshness label is never read for a decision ---")
# The trust boundary: a stored `current` must never be usable as proof of
# present freshness, or a dead collector would freeze a favourable assessment.
for stored in STATES:
    result = run(policy=60, observations=[obs(age=600, stored_freshness=stored)])
    check(result.state == "stale",
          f"an old observation stored as {stored!r} is still computed as stale")
for stored in STATES:
    result = run(policy=60, observations=[obs(age=5, stored_freshness=stored)])
    check(result.state == "current",
          f"a fresh observation stored as {stored!r} is still computed as current")
source = inspect.getsource(F)
check('"freshness"' not in source and "'freshness'" not in source
      or "stored" in source,
      "the module does not read the observation's stored freshness field")
check(".freshness" not in source.replace("_freshness", ""),
      "the module never reads the stored `freshness` attribute")

# --- malformed input --------------------------------------------------------
print("--- malformed timestamps, dimensions and observations are refused ---")
for bad in ("2026-10-19T12:00:00", "not-a-time", "", None, 0, 1760616000, []):
    refuses(f"an evaluation instant of {bad!r} is refused", evaluated_at=bad,
            observations=[obs(age=10)])
for bad in ("latency-ish", "", None, 1, [], "LATENCY"):
    refuses(f"a dimension of {bad!r} is refused", dimension=bad,
            observations=[])
for bad in ("CHOBS-000001", {"observation_id": "x"}, 1, None):
    refuses(f"an observation given as {type(bad).__name__} is refused",
            observations=[bad])
for bad in (42, None, 3.5, {"a": 1}, "CHOBS-000001"):
    try:
        evaluate(dimension="latency", freshness_policy_seconds=60,
                 observations=bad, evaluated_at=EVAL_AT)
        print(f"FAIL: a non-sequence observation set {bad!r} was accepted",
              file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: a non-sequence observation set {bad!r} is refused")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: a non-sequence observation set {bad!r} raised "
              f"{type(error).__name__}", file=sys.stderr)
        failures += 1
state_record = H.parse("capability-health-state", {
    "state_id": "CHSTATE-000001", "subject_type": "capability-instance",
    "subject_id": "CINST-000007", "state": "healthy",
    "envelope_id": "CHENV-0001", "envelope_version": 1,
    "derived_from_observation_ids": ["CHOBS-000001"], "freshness": "current",
    "reason": "within envelope", "evaluated_at": EVAL_AT,
    "provenance": {"tool": "test"}})
refuses("a record of the wrong family is refused", observations=[state_record])
refuses("observations of two different subjects are refused",
        observations=[obs(age=5), obs(age=6, subject_id="CINST-000008")])
for leaky in ("CHOBS-SUPER-SECRET", "not-a-dimension-SECRET"):
    refuses(f"a refused dimension {leaky!r} is not echoed", dimension=leaky,
            observations=[], forbidden_value=leaky)

# --- determinism, purity, and no authority ----------------------------------
print("--- the evaluator is deterministic and reads no clock ---")
signature = inspect.signature(evaluate)
check("evaluated_at" in signature.parameters,
      "evaluate_freshness takes an explicit evaluated_at")
check(signature.parameters["evaluated_at"].default is inspect.Parameter.empty,
      "evaluated_at has NO default, so an implicit 'now' is impossible")
check(all(p.kind is inspect.Parameter.KEYWORD_ONLY
          for p in signature.parameters.values()),
      "every parameter is keyword-only")
env_signature = inspect.signature(per_envelope)
check(env_signature.parameters["evaluated_at"].default is inspect.Parameter.empty,
      "the envelope entry point also requires an explicit instant")
for banned in ("datetime.now", "datetime.utcnow", "time.time", "time.monotonic",
               "date.today", "utcfromtimestamp"):
    check(banned not in source, f"the module never calls {banned}()")
for banned in ("socket", "subprocess", "requests", "urllib", "http", "asyncio",
               "threading", "multiprocessing", "sqlite3", "yaml"):
    check(f"import {banned}" not in source and f"from {banned}" not in source,
          f"the module never imports {banned}")
import re as _re  # noqa: E402
for banned in ("eval", "exec", "compile", "__import__"):
    check(_re.search(rf"(?<![\w.]){banned}\s*\(", source) is None,
          f"the module never calls {banned}()")

sample = [obs(age=5), obs(age=50), obs(age=1, status="failed"),
          obs(dimension="availability", value="1", age=7)]
baseline = run(policy=60, observations=sample)
for attempt in range(25):
    again = run(policy=60, observations=sample)
    if (again.state, again.age_seconds, again.observation_id) != \
       (baseline.state, baseline.age_seconds, baseline.observation_id):
        check(False, f"evaluation {attempt} differed from the first")
        break
else:
    check(True, "twenty-five repeated evaluations returned an identical result")
import itertools  # noqa: E402
results = {(run(policy=60, observations=list(p)).state,
            run(policy=60, observations=list(p)).age_seconds,
            run(policy=60, observations=list(p)).observation_id)
           for p in itertools.permutations(sample)}
check(len(results) == 1,
      "all 24 input orderings produce one identical result")

print("--- nothing is mutated, and no authority is claimed ---")
before = [o.to_dict() for o in sample]
run(policy=60, observations=sample)
check([o.to_dict() for o in sample] == before,
      "evaluation leaves every supplied observation unchanged")
dims = {"latency": 60}
per_envelope(dimensions=dims, observations=sample, evaluated_at=EVAL_AT)
check(dims == {"latency": 60}, "the supplied dimension mapping is unchanged")
result = run(policy=60, observations=[obs(age=5)])
for attr in ("state", "age_seconds", "review_required"):
    try:
        setattr(result, attr, "x")
        check(False, f"a result refuses assignment to {attr}")
    except Exception:  # noqa: BLE001
        check(True, f"a result refuses assignment to {attr}")

# A freshness label is NOT a health state and NOT an eligibility decision.
health_states = set(H.HEALTH_STATES)
produced = {run(policy=p, observations=o).state
            for p in (60, None)
            for o in ([], [obs(age=5)], [obs(age=600)], [obs(status="failed")])}
check(produced <= set(STATES),
      "every produced label is one of the four declared freshness states")
check(produced & health_states <= {"unknown"},
      "the only label shared with the health-state vocabulary is `unknown`")
for banned_attr in ("derive_state", "derive_health_state", "evaluate_eligibility",
                    "select", "write_record", "store", "collect",
                    "receive_heartbeat", "recommend", "set_trust_state",
                    "evaluate_condition"):
    check(not hasattr(F, banned_attr),
          f"the freshness module exposes no {banned_attr}()")
check("tools.fabric" not in source and "tools.capability" not in source
      and "..fabric" not in source,
      "the module reaches no other plane")

print("--- the module boundary ---")
check(hasattr(PKG, "evaluate_freshness")
      and PKG.evaluate_freshness is F.evaluate_freshness,
      "tools.health re-exports the SAME evaluate_freshness")
check(hasattr(PKG, "FRESHNESS_STATES")
      and PKG.FRESHNESS_STATES is F.FRESHNESS_STATES,
      "tools.health re-exports the SAME FRESHNESS_STATES")
check(not hasattr(H, "evaluate_freshness"),
      "the record model does not carry the freshness evaluator")
from tools.health import conditions as C  # noqa: E402
check(not hasattr(C, "evaluate_freshness"),
      "the condition evaluator does not carry the freshness evaluator")
# Matched on import statements, because "freshness" appears legitimately in
# both modules as a field and parameter name.
for module, label in ((H, "record model"), (C, "condition evaluator")):
    imports = [line for line in inspect.getsource(module).splitlines()
               if line.startswith(("import ", "from "))]
    check(not any("freshness" in line for line in imports),
          f"the {label} does not import the freshness module")
check(any("records" in line for line in
          [l for l in source.splitlines() if l.startswith(("import ", "from "))]),
      "the freshness module imports the record model, not the reverse")

print()
if failures:
    print(f"Freshness validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All freshness assertions passed.")
PY
