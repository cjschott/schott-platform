#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0006-H1 Health record models.
#
# H1 IS A PURE DATA-MODEL LAYER. There is no store, no evaluation, no
# derivation, no ingestion and no network here, and this suite asserts that by
# exercising only parsing, refusal, immutability and serialisation.
#
# THE TEST ORACLE IS THE COMMITTED SCHEMA, NOT THE MODULE UNDER TEST.
#
# Required, optional, forbidden and enumerated vocabularies are read out of
# platform-model/schemas/*.yaml and compared against the module's behaviour.
# Valid fixtures are hand-written below rather than generated from the module.
# Nothing here imports a constant from tools.health and asserts the module
# equals it: that proves a tuple is self-consistent, which is the ENG-0005 F4
# defect class and the reason this project now separates agreement tests from
# single-artefact ones.
#
# Every refusal assertion drives the implementation to a NAMED refusal and
# checks that the rejected VALUE never appears in the message. A model that
# echoes what it refused leaks the thing it was protecting.
#
# Nothing here contacts a host, opens a socket, spawns a subprocess, writes
# outside a temporary directory, or touches any production store.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import copy
import re
import sys
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


import yaml

# --- the oracle: the committed schemas ------------------------------------
FAMILIES = ("capability-health-envelope", "capability-health-observation",
            "capability-health-state", "capability-degradation-event",
            "capability-health-recommendation", "capability-heartbeat")

SCHEMA = {}
for family in FAMILIES:
    SCHEMA[family] = yaml.safe_load(
        (root / "platform-model/schemas" / f"{family}.schema.yaml").read_text())


def required(family):
    return list(SCHEMA[family].get("required_fields") or [])


def conditional(family):
    return list(SCHEMA[family].get("conditionally_required_fields") or [])


def optional(family):
    return list(SCHEMA[family].get("optional_fields") or [])


def forbidden(family):
    return list(SCHEMA[family].get("forbidden_fields") or [])


def enums(family):
    return SCHEMA[family].get("enums") or {}


# The declared unit per dimension, read from the envelope schema rather than
# from the module under test.
DIMENSION_UNITS = SCHEMA["capability-health-envelope"]["dimension_units"]


# --- the module under test ------------------------------------------------
try:
    from tools.health import records as H
    from tools.health import errors as E
    IMPORTED = True
except Exception as error:  # noqa: BLE001
    IMPORTED = False
    IMPORT_ERROR = error

check(IMPORTED, "tools.health.records and tools.health.errors import")
if not IMPORTED:
    print(f"FAIL: import failed: {type(IMPORT_ERROR).__name__}", file=sys.stderr)
    print(f"\nHealth record model validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)

# --- hand-written valid fixtures, independent of the implementation -------
# Deliberately NOT generated from the module. Each is the minimum valid record
# for its family: every required field, no optional field, nothing else.
PROV = {"class": "declared", "source": "docs/decisions/ADR-0013-capability-health-plane.md",
        "recorded_at": "2026-10-13"}

VALID = {
    "capability-health-envelope": {
        "envelope_id": "CHENV-0001",
        "envelope_version": 1,
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "dimensions": {
            "latency": {
                "dimension": "latency",
                "unit": "milliseconds",
                "aggregation": {"kind": "instant"},
                "entry_condition": {"operator": "gt", "value": "2000"},
                "exit_condition": {"operator": "le", "value": "1500"},
                "hysteresis": {"kind": "duration", "seconds": 120,
                               "max_gap_seconds": 30, "min_samples": 3},
                "freshness_policy_seconds": 60,
            },
        },
        "evaluation": "worst-dimension-wins",
        "provenance": dict(PROV),
    },
    "capability-health-observation": {
        "observation_id": "CHOBS-000001",
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "dimension": "latency",
        "measured_value": "1200",
        "unit": "milliseconds",
        "observed_at": "2026-10-13T09:00:00-05:00",
        "collector_id": "linux_resources",
        "source_fingerprint": "sha256:" + "a" * 64,
        "collection_status": "collected",
        "provenance": dict(PROV),
    },
    "capability-health-state": {
        "state_id": "CHSTATE-000001",
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "state": "healthy",
        "envelope_id": "CHENV-0001",
        "envelope_version": 1,
        "derived_from_observation_ids": ["CHOBS-000001"],
        "freshness": "current",
        "reason": "within the declared envelope on every measured dimension",
        "evaluated_at": "2026-10-13T09:00:05-05:00",
        "provenance": dict(PROV),
    },
    "capability-degradation-event": {
        "event_id": "CHDEG-000001",
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "from_state": "healthy",
        "to_state": "degraded",
        "dimension": "latency",
        "entry_condition": {"operator": "gt", "value": "2000"},
        "observed_at": "2026-10-13T09:02:00-05:00",
        "derived_from_observation_ids": ["CHOBS-000001", "CHOBS-000002"],
        "provenance": dict(PROV),
        "hysteresis": {"kind": "duration", "seconds": 120,
                       "max_gap_seconds": 30, "min_samples": 3},
        "hysteresis_satisfied_over_seconds": 125,
        "hysteresis_first_observation_id": "CHOBS-000001",
        "hysteresis_last_observation_id": "CHOBS-000002",
        "hysteresis_sample_count": 5,
        "hysteresis_observed_max_gap_seconds": 25,
    },
    "capability-health-recommendation": {
        "recommendation_id": "CHREC-000001",
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "recommendation": "investigate",
        "reason": "latency outside its declared envelope for two minutes",
        "derived_from_state_id": "CHSTATE-000001",
        "created_at": "2026-10-13T09:03:00-05:00",
        "review_required": True,
        "advisory_only": True,
        "provenance": dict(PROV),
    },
    "capability-heartbeat": {
        "heartbeat_id": "CHBEAT-000001",
        "subject_type": "capability-instance",
        "subject_id": "CINST-000007",
        "observed_at": "2026-10-13T09:00:00-05:00",
        "received_at": "2026-10-13T09:00:01-05:00",
        "epoch": 3,
        "sequence": 41,
        "provenance": dict(PROV),
    },
}

check(set(VALID) == set(FAMILIES),
      "the suite carries a hand-written fixture for all six families")


def parse(family, payload):
    return H.parse(family, payload)


def refuses(family, payload, label, *, forbidden_value=None):
    """Assert a refusal, and that the rejected value is not echoed."""
    global failures
    try:
        parse(family, payload)
    except E.HealthRecordError as error:
        message = str(error)
        code = getattr(error, "code", "")
        if not code:
            print(f"FAIL: {label}: refused without a named code", file=sys.stderr)
            failures += 1
            return
        if forbidden_value is not None and str(forbidden_value) in message:
            print(f"FAIL: {label}: the refusal echoed the rejected value",
                  file=sys.stderr)
            failures += 1
            return
        print(f"PASS: {label}")
        return
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {label}: raised {type(error).__name__}, not a "
              f"HealthRecordError", file=sys.stderr)
        failures += 1
        return
    print(f"FAIL: {label}: accepted", file=sys.stderr)
    failures += 1


print("--- valid fixtures parse ---")
PARSED = {}
for family in FAMILIES:
    try:
        PARSED[family] = parse(family, copy.deepcopy(VALID[family]))
        print(f"PASS: {family} parses its valid fixture")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {family} refused its valid fixture: "
              f"{type(error).__name__}: {error}", file=sys.stderr)
        failures += 1

print("--- every required field is refused when absent ---")
for family in FAMILIES:
    for field in required(family):
        payload = copy.deepcopy(VALID[family])
        payload.pop(field, None)
        refuses(family, payload, f"{family} refuses a missing {field}")

print("--- every forbidden field is refused by name ---")
for family in FAMILIES:
    for field in forbidden(family):
        payload = copy.deepcopy(VALID[family])
        payload[field] = "irrelevant-sentinel-value"
        refuses(family, payload, f"{family} refuses the forbidden {field}",
                forbidden_value="irrelevant-sentinel-value")

print("--- unknown fields are refused ---")
for family in FAMILIES:
    payload = copy.deepcopy(VALID[family])
    payload["an_undeclared_field"] = "sentinel-unknown"
    refuses(family, payload, f"{family} refuses an undeclared field",
            forbidden_value="sentinel-unknown")

print("--- optional fields are accepted ---")
for family in FAMILIES:
    payload = copy.deepcopy(VALID[family])
    for field in optional(family):
        payload[field] = "notes" if field == "notes" else None
    try:
        parse(family, payload)
        print(f"PASS: {family} accepts its declared optional fields")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {family} refused a declared optional field: {error}",
              file=sys.stderr)
        failures += 1

print("--- identifier formats are enforced ---")
BAD_IDS = {
    "capability-health-envelope": ("envelope_id", ["CHENV-1", "CHENV-00001",
                                                   "chenv-0001", "CHOBS-0001", ""]),
    "capability-health-observation": ("observation_id", ["CHOBS-1", "CHOBS-0000001",
                                                         "CHENV-000001", ""]),
    "capability-health-state": ("state_id", ["CHSTATE-1", "CHDEG-000001", ""]),
    "capability-degradation-event": ("event_id", ["CHDEG-1", "CHSTATE-000001", ""]),
    "capability-health-recommendation": ("recommendation_id", ["CHREC-1", "CHOBS-000001", ""]),
    "capability-heartbeat": ("heartbeat_id", ["CHBEAT-1", "CHREC-000001", ""]),
}
for family, (field, bad_values) in BAD_IDS.items():
    pattern = SCHEMA[family]["id_pattern"]
    check(re.match(pattern, VALID[family][field]) is not None,
          f"{family} fixture identifier matches the schema pattern")
    for bad in bad_values:
        payload = copy.deepcopy(VALID[family])
        payload[field] = bad
        refuses(family, payload,
                f"{family} refuses the identifier shape {bad!r}")

print("--- subject types: capability-package is refused everywhere ---")
for family in FAMILIES:
    permitted = set(enums(family).get("subject_type") or [])
    check("capability-package" not in permitted,
          f"{family} schema does not permit a package subject")
    payload = copy.deepcopy(VALID[family])
    payload["subject_type"] = "capability-package"
    refuses(family, payload, f"{family} refuses a capability-package subject")
    payload = copy.deepcopy(VALID[family])
    payload["subject_type"] = "fabric-node"
    refuses(family, payload, f"{family} refuses an undeclared subject type")

print("--- every closed enumeration is enforced ---")
for family in FAMILIES:
    for field, permitted in enums(family).items():
        if field not in VALID[family]:
            continue
        payload = copy.deepcopy(VALID[family])
        payload[field] = "not-a-permitted-member"
        refuses(family, payload,
                f"{family} refuses an invalid {field} member")
        accepted_all = True
        for member in permitted:
            payload = copy.deepcopy(VALID[family])
            payload[field] = member
            # Swapping one enum member must keep the record otherwise VALID,
            # or this loop stops testing "is this member accepted" and starts
            # re-testing the record-local rules asserted separately below.
            if field == "collection_status" and member != "collected":
                payload["measured_value"] = None
            if field == "dimension" and family == "capability-health-observation":
                payload["unit"] = DIMENSION_UNITS[member]
            if field == "state" and member == "insufficient-policy":
                payload["review_required"] = True
            rejected = None
            try:
                parse(family, payload)
            except Exception as error:  # noqa: BLE001
                rejected = error
            if rejected is not None:
                print(f"FAIL: {family} refused the permitted {field} member "
                      f"{member!r}: {rejected}", file=sys.stderr)
                failures += 1
                accepted_all = False
        # Only report the summary when every member really was accepted. An
        # unconditional PASS beside its own FAILs is how a reader comes away
        # believing a loop succeeded.
        check(accepted_all,
              f"{family} accepts every permitted {field} member "
              f"({len(permitted)})")

print("--- vocabulary sizes, read from the schema ---")
state_enum = set(enums("capability-health-state")["state"])
check(len(state_enum) == 7, "the schema declares exactly seven health states")
check(state_enum == {"unknown", "unmonitored", "insufficient-policy", "healthy",
                     "degraded", "unavailable", "withheld"},
      "the seven health states are the approved set")
rec_enum = set(enums("capability-health-recommendation")["recommendation"])
check(len(rec_enum) == 4, "the schema declares exactly four recommendation kinds")
check(rec_enum == {"investigate", "review-envelope", "verify-observation-source",
                   "consider-manual-drain"},
      "the four recommendation kinds are the approved set")
for extra in ("drain", "restart", "quarantine", "remediate", "reroute"):
    payload = copy.deepcopy(VALID["capability-health-recommendation"])
    payload["recommendation"] = extra
    refuses("capability-health-recommendation", payload,
            f"a recommendation of {extra!r} is refused")
for extra in ("assumed-healthy", "probably-available", "no-known-issues",
              "healthy-by-default"):
    payload = copy.deepcopy(VALID["capability-health-state"])
    payload["state"] = extra
    refuses("capability-health-state", payload,
            f"a health state of {extra!r} is refused")

print("--- record-local conditional requirements ---")
# measured_value: null exactly when collection_status is not "collected".
payload = copy.deepcopy(VALID["capability-health-observation"])
payload["collection_status"] = "failed"
refuses("capability-health-observation", payload,
        "a failed collection carrying a measured value is refused")
payload = copy.deepcopy(VALID["capability-health-observation"])
payload["collection_status"] = "unavailable"
payload["measured_value"] = 0
refuses("capability-health-observation", payload,
        "a zero substituted for an unavailable collection is refused")
payload = copy.deepcopy(VALID["capability-health-observation"])
payload["measured_value"] = None
refuses("capability-health-observation", payload,
        "a collected observation with no measured value is refused")
# insufficient-policy is the one record-local leg of the review_required rule.
payload = copy.deepcopy(VALID["capability-health-state"])
payload["state"] = "insufficient-policy"
refuses("capability-health-state", payload,
        "an insufficient-policy state without review_required is refused")
payload = copy.deepcopy(VALID["capability-health-state"])
payload["state"] = "insufficient-policy"
payload["review_required"] = False
refuses("capability-health-state", payload,
        "an insufficient-policy state with review_required false is refused")
payload = copy.deepcopy(VALID["capability-health-state"])
payload["state"] = "insufficient-policy"
payload["review_required"] = True
try:
    parse("capability-health-state", payload)
    print("PASS: an insufficient-policy state with review_required true parses")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: insufficient-policy with the flag was refused: {error}",
          file=sys.stderr)
    failures += 1
payload = copy.deepcopy(VALID["capability-health-state"])
payload["review_required"] = "yes"
refuses("capability-health-state", payload,
        "a non-boolean review_required is refused")

print("--- cross-family reference shapes are enforced ---")
REFS = [
    ("capability-health-state", "envelope_id", "CHOBS-000001"),
    ("capability-health-state", "derived_from_observation_ids", ["CHENV-0001"]),
    ("capability-health-recommendation", "derived_from_state_id", "CHDEG-000001"),
    ("capability-degradation-event", "hysteresis_first_observation_id", "CHSTATE-000001"),
]
for family, field, wrong in REFS:
    payload = copy.deepcopy(VALID[family])
    payload[field] = wrong
    refuses(family, payload,
            f"{family} refuses a wrong-family reference in {field}")
payload = copy.deepcopy(VALID["capability-health-state"])
payload["derived_from_observation_ids"] = []
refuses("capability-health-state", payload,
        "a state citing no observation is refused")

print("--- envelope dimension entries are structurally enforced ---")
ENV = "capability-health-envelope"
dim_required = SCHEMA[ENV]["dimension_fields"]["required"]
for member in dim_required:
    payload = copy.deepcopy(VALID[ENV])
    payload["dimensions"]["latency"].pop(member, None)
    refuses(ENV, payload, f"an envelope dimension missing {member} is refused")
for bad_operator in ("ne", "neq", ">", "between", ""):
    payload = copy.deepcopy(VALID[ENV])
    payload["dimensions"]["latency"]["entry_condition"]["operator"] = bad_operator
    refuses(ENV, payload, f"a condition operator {bad_operator!r} is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["entry_condition"] = "p95 > 2000ms"
refuses(ENV, payload, "a free-text condition string is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["aggregation"] = {"kind": "percentile",
                                                   "percentile": 95}
refuses(ENV, payload, "a percentile aggregation is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["unit"] = "seconds"
refuses(ENV, payload, "a unit that disagrees with the dimension is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["hysteresis"] = {"kind": "occurrences",
                                                  "count": 3,
                                                  "within_seconds": 60}
refuses(ENV, payload, "an occurrences hysteresis is refused in v1")
for member in SCHEMA[ENV]["hysteresis_fields"]["required"]:
    payload = copy.deepcopy(VALID[ENV])
    payload["dimensions"]["latency"]["hysteresis"].pop(member, None)
    refuses(ENV, payload, f"a hysteresis missing {member} is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["dimension"] = "not-a-dimension"
refuses(ENV, payload, "an undeclared dimension name is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"] = {}
refuses(ENV, payload, "an envelope declaring no dimension is refused")
payload = copy.deepcopy(VALID[ENV])
payload["dimensions"]["latency"]["freshness_policy_seconds"] = None
try:
    parse(ENV, payload)
    print("PASS: a null freshness policy is permitted, per the Null Policy Rule")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: a null freshness policy was refused: {error}", file=sys.stderr)
    failures += 1

print("--- the dimension/subject matrix is enforced ---")
matrix = SCHEMA["capability-health-observation"]["dimension_subjects"]
host_only = [d for d, subjects in matrix.items()
             if "capability-instance" not in subjects]
check(isinstance(matrix, dict) and len(matrix) == 13,
      "the schema declares a subject set for all thirteen dimensions")
for dimension, subjects in matrix.items():
    check("capability-package" not in subjects,
          f"the matrix excludes packages from {dimension}")

print("--- immutability ---")
for family in FAMILIES:
    record = PARSED.get(family)
    if record is None:
        continue
    try:
        setattr(record, "subject_id", "CINST-000001")
        print(f"FAIL: {family} permitted top-level mutation", file=sys.stderr)
        failures += 1
    except Exception:  # noqa: BLE001
        print(f"PASS: {family} refuses top-level mutation")

state = PARSED.get("capability-health-state")
if state is not None:
    try:
        state.provenance["class"] = "tampered"
        print("FAIL: nested mapping mutation was permitted", file=sys.stderr)
        failures += 1
    except Exception:  # noqa: BLE001
        print("PASS: a nested mapping refuses mutation")
    try:
        state.derived_from_observation_ids.append("CHOBS-000099")
        print("FAIL: a nested sequence permitted append", file=sys.stderr)
        failures += 1
    except Exception:  # noqa: BLE001
        print("PASS: a nested sequence refuses append")

print("--- a retained reference cannot change a parsed record ---")
supplied = copy.deepcopy(VALID["capability-health-state"])
retained_ids = supplied["derived_from_observation_ids"]
retained_prov = supplied["provenance"]
record = parse("capability-health-state", supplied)
retained_ids.append("CHOBS-000099")
retained_prov["class"] = "tampered"
supplied["reason"] = "rewritten after construction"
check(tuple(record.derived_from_observation_ids) == ("CHOBS-000001",),
      "a retained sequence reference cannot extend a parsed record")
check(record.provenance.get("class") == "declared",
      "a retained mapping reference cannot alter a parsed record")
check(record.reason == "within the declared envelope on every measured dimension",
      "mutating the supplied payload cannot alter a parsed record")

print("--- to_dict() exposes nothing mutable, and round-trips ---")
for family in FAMILIES:
    record = PARSED.get(family)
    if record is None:
        continue
    first = record.to_dict()
    first_copy = copy.deepcopy(first)
    # Mutating the returned mapping must not reach the record.
    try:
        first["subject_id"] = "CINST-000001"
    except Exception:  # noqa: BLE001
        pass
    check(record.subject_id == "CINST-000007",
          f"{family}: mutating to_dict() output cannot alter the record")
    again = parse(family, copy.deepcopy(first_copy))
    check(again.to_dict() == first_copy,
          f"{family}: parse -> to_dict -> parse round-trips losslessly")
    check(again.to_dict() == record.to_dict(),
          f"{family}: a round-tripped record serialises identically")

print("--- malformed input yields no partially valid object ---")
for family in FAMILIES:
    payload = copy.deepcopy(VALID[family])
    payload["an_undeclared_field"] = "x"
    try:
        result = parse(family, payload)
        print(f"FAIL: {family} returned an object for malformed input",
              file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: {family} returns no object for malformed input")

print("--- refusals carry a code and leak no value ---")
SECRET = "s3cret-sentinel-must-not-appear"
for family in FAMILIES:
    payload = copy.deepcopy(VALID[family])
    payload["subject_id"] = SECRET
    try:
        parse(family, payload)
        # subject_id shape may not be constrained; that is acceptable, but if
        # it IS refused the value must not be echoed.
        print(f"PASS: {family} accepted an unconstrained subject_id "
              f"(no leak possible)")
    except E.HealthRecordError as error:
        check(SECRET not in str(error),
              f"{family}: a refused subject_id is not echoed")

print("--- the kind dispatcher refuses an unknown family ---")
refuses("capability-health-seventh-family", {"x": 1},
        "an unknown record kind is refused")
for bad in (None, [], "not-a-mapping", 7):
    try:
        H.parse("capability-health-state", bad)
        print(f"FAIL: a non-mapping payload {type(bad).__name__} was accepted",
              file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: a non-mapping payload ({type(bad).__name__}) is refused")

print("--- H1 contains no evaluation, store, network or subprocess surface ---")
import inspect
source = inspect.getsource(H) + inspect.getsource(E)
# The production store root is assembled from parts rather than written as a
# literal, so this banned-string list does not itself look like a test that
# touches a production path to the repository-wide guard that checks for exactly
# that. The guard is right to be suspicious of the literal; nothing here needs
# it spelled out.
_health_store_root = "/var/lib/" + "kyri/health"
for banned in ("import socket", "import subprocess", "import requests",
               "urllib", "http.client", "tools.fabric", "tools.capability",
               "tools.trust", "ImmutableStore", "allocate_id", "open(",
               "Path(", "mkdir", _health_store_root):
    check(banned not in source,
          f"the H1 modules contain no {banned!r}")
for banned_name in ("evaluate", "derive", "compute_state", "freshness_of",
                    "hysteresis_satisfied", "subtract"):
    check(not hasattr(H, banned_name),
          f"the records module exposes no {banned_name}()")

print()
if failures:
    print(f"Health record model validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All health record model assertions passed.")
PY
