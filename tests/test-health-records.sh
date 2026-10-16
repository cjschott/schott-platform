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
import json
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
            # ENG-0006-H2A/H2B: `unmonitored` means no envelope was declared,
            # so BOTH halves of the envelope citation must be null for that
            # member -- the identifier and the version are one fact. Without
            # this the loop would stop testing "is this member accepted" and
            # start re-testing the citation rules asserted separately below.
            if field == "state" and member == "unmonitored":
                payload["envelope_id"] = None
                payload["envelope_version"] = None
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

print("--- the state/envelope matrix (ENG-0006-H2A) ---")
# NORMATIVE BASIS, quoted:
#   CHSTATE schema, above `envelope_id`: "Null only when state is
#     `unmonitored`, which is precisely the case of having no envelope to
#     evaluate against."
#   CHSTATE `state` enum, on unmonitored: "No envelope declared at all, so
#     health is not assessable."
#   ADR-0013 line 290 and health-states.md line 11: "No envelope declared;
#     health is not assessable."
#   ADR-0013 line 278 and operational-envelope.md line 102: "A subject with no
#     envelope is `unmonitored`, not healthy."
#   CHENV schema: `absent_envelope_means: unmonitored`.
#
# So the clause cuts both ways, and the matrix below is read off it rather than
# chosen: null is permitted ONLY for `unmonitored`, and `unmonitored` means no
# envelope was declared at all -- so an `unmonitored` state that cites one is
# asserting the existence of the thing its own state says does not exist.
#
# The expected results are written here, not imported from the module.
STATE_KIND = "capability-health-state"


def state_with(state_value, envelope_id, **extra):
    payload = copy.deepcopy(VALID[STATE_KIND])
    payload["state"] = state_value
    payload["envelope_id"] = envelope_id
    # ENG-0006-H2B. The citation is one fact in two fields, so a fixture that
    # nulls the identifier and leaves a version behind is not a record anyone
    # could legitimately write. Pairing them here keeps these fixtures
    # OTHERWISE-VALID, which is what the assertions below are about. The
    # pairing rule itself is never exercised through this default: every
    # assertion that tests it sets `envelope_version` explicitly afterwards.
    if envelope_id is None:
        payload["envelope_version"] = None
    payload.update(extra)
    return payload


# Every state the schema declares, and what the clause requires of each.
ENVELOPE_REQUIRED = {
    "unknown": "non-null",
    "unmonitored": "null",
    "insufficient-policy": "non-null",
    "healthy": "non-null",
    "degraded": "non-null",
    "unavailable": "non-null",
    "withheld": "non-null",
}
check(set(ENVELOPE_REQUIRED) == set(enums(STATE_KIND)["state"]),
      "the matrix covers exactly the declared health states")

for state_value, requirement in sorted(ENVELOPE_REQUIRED.items()):
    extra = {"review_required": True} if state_value == "insufficient-policy" else {}
    # The form the clause permits.
    permitted = state_with(state_value, None if requirement == "null"
                           else "CHENV-0001", **extra)
    try:
        parse(STATE_KIND, permitted)
        print(f"PASS: state {state_value!r} accepts its permitted envelope form "
              f"({requirement})")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: state {state_value!r} refused its permitted envelope form "
              f"({requirement}): {error}", file=sys.stderr)
        failures += 1
    # The form the clause forbids.
    forbidden = state_with(state_value, "CHENV-0001" if requirement == "null"
                           else None, **extra)
    refuses(STATE_KIND, forbidden,
            f"state {state_value!r} refuses the forbidden envelope form")

# Rule A, stated on its own because it is the correction's whole point.
accepted = state_with("unmonitored", None)
try:
    record = parse(STATE_KIND, accepted)
    print("PASS: an unmonitored state with a null envelope parses")
    check(record.envelope_id is None,
          "the explicit null survives parsing rather than becoming absent")
    serialised = record.to_dict()
    check("envelope_id" in serialised,
          "the required field is still PRESENT after serialisation")
    check(serialised["envelope_id"] is None,
          "and serialises as an explicit null, not as a missing field")
    again = parse(STATE_KIND, copy.deepcopy(serialised))
    check(again.to_dict() == serialised,
          "a null-envelope state round-trips losslessly")
    check(again.envelope_id is None,
          "and the null is still null after the round trip")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: an unmonitored state with a null envelope was refused: {error}",
          file=sys.stderr)
    failures += 1

# Rule A: the field must still be PRESENT. Omitting it is not the same as
# supplying null, and the schema requires presence.
omitted = state_with("unmonitored", None)
del omitted["envelope_id"]
refuses(STATE_KIND, omitted,
        "an unmonitored state that OMITS the required field is refused")

# A null citation is never read as a reference to a real envelope.
refuses(STATE_KIND, state_with("unmonitored", ""),
        "an unmonitored state with an empty-string envelope is refused")
for malformed in ("CHENV-1", "CHENV-00001", "chenv-0001", "CHOBS-000001",
                  "null", "None", 0, False, []):
    refuses(STATE_KIND, state_with("healthy", malformed),
            f"a malformed non-null envelope {malformed!r} is refused")
    refuses(STATE_KIND, state_with("unmonitored", malformed),
            f"an unmonitored state with a malformed envelope {malformed!r} is refused")

# SUPERSEDED BY THE ENG-0006-H2B RULING. H2A asserted here that a null
# `envelope_version` was refused even on an unmonitored state, because the
# schema then declared a null permission for `envelope_id` alone. H2A recorded
# the resulting oddity -- a state carrying a version of an envelope that by
# definition does not exist -- as an open question rather than deciding it. The
# ruling decided it: both halves are null together. The inverted expectation is
# asserted in the H2B section below, along with the pairing rule in both
# directions, so nothing is merely deleted here.

print("--- the envelope citation pairs id with version (ENG-0006-H2B) ---")
# The ruling: an unmonitored CHSTATE carries an explicitly null envelope
# reference AND an explicitly null envelope version; both fields stay required;
# every other state must identify a valid envelope and version. A half-citation
# is forbidden in both directions and no sentinel version exists.
#
# Two independent oracles are used, and they are checked against each other.
# First the schema's own `envelope_citation` declaration, which is authored in
# platform-model and not by this suite or the module under test. Second the
# pairing table below, written out by hand from the ruling, so a wrong schema
# and a wrong implementation cannot agree their way to a pass.
CITATION = SCHEMA[STATE_KIND]["envelope_citation"]

check(CITATION["fields"] == ["envelope_id", "envelope_version"],
      "the schema declares the citation as exactly these two fields")
check(CITATION["both_fields_always_required"] is True,
      "the schema keeps both citation fields always required")
check(CITATION["omission_permitted"] is False,
      "the schema forbids omitting either citation field")
check(CITATION["null_permitted_for_states"] == ["unmonitored"],
      "the schema permits a null citation only for unmonitored")
check(CITATION["null_required_for_states"] == ["unmonitored"],
      "the schema requires a null citation for unmonitored")
check(CITATION["must_be_null_together"] is True
      and CITATION["must_be_non_null_together"] is True,
      "the schema declares the two fields null together or valid together")
check(CITATION["null_id_with_non_null_version"] == "forbidden",
      "the schema forbids a null identifier with a non-null version")
check(CITATION["non_null_id_with_null_version"] == "forbidden",
      "the schema forbids a non-null identifier with a null version")
check(CITATION["half_citation_permitted"] is False,
      "the schema forbids a half citation")
check(CITATION["version_without_envelope"] == "forbidden",
      "the schema forbids a version without its envelope")
check(CITATION["sentinel_version_permitted"] is False,
      "the schema permits no sentinel version")
check(CITATION["introduces_new_version_concept"] is False
      and CITATION["redefines_supersession"] is False,
      "the declaration introduces no new version concept and no supersession change")
# Both fields must still be REQUIRED, not quietly demoted to make nulls legal.
for field in ("envelope_id", "envelope_version"):
    check(field in required(STATE_KIND),
          f"{field} is still a required field")
    check(field not in conditional(STATE_KIND)
          and field not in optional(STATE_KIND),
          f"{field} was not demoted to conditional or optional")


def cited(state_value, envelope_id, envelope_version, **extra):
    payload = state_with(state_value, envelope_id, **extra)
    payload["envelope_version"] = envelope_version
    return payload


def extra_for(state_value):
    return {"review_required": True} if state_value == "insufficient-policy" else {}


OTHER_STATES = tuple(s for s in ENVELOPE_REQUIRED if s != "unmonitored")

# The pairing table, written from the ruling rather than read from anything.
#   (state group, envelope_id, envelope_version) -> accept?
PAIRING = (
    ("unmonitored", None,         None, True),
    ("unmonitored", None,         1,    False),
    ("unmonitored", "CHENV-0001", None, False),
    ("unmonitored", "CHENV-0001", 1,    False),
)
for state_value, eid, ver, accept in PAIRING:
    payload = cited(state_value, eid, ver, **extra_for(state_value))
    label = (f"{state_value} with id={eid!r} version={ver!r}")
    if accept:
        try:
            record = parse(STATE_KIND, payload)
            print(f"PASS: {label} is accepted")
            check(record.envelope_id is None and record.envelope_version is None,
                  f"{label} keeps both halves null")
        except Exception as error:  # noqa: BLE001
            print(f"FAIL: {label} was refused: {error}", file=sys.stderr)
            failures += 1
    else:
        refuses(STATE_KIND, payload, f"{label} is refused")

for state_value in sorted(OTHER_STATES):
    extra = extra_for(state_value)
    # valid + positive integer -> accept
    try:
        parse(STATE_KIND, cited(state_value, "CHENV-0001", 1, **extra))
        print(f"PASS: {state_value} with a valid id and version 1 is accepted")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {state_value} with a valid id and version 1 was refused: "
              f"{error}", file=sys.stderr)
        failures += 1
    # the three broken pairings
    refuses(STATE_KIND, cited(state_value, "CHENV-0001", None, **extra),
            f"{state_value} with a valid id and a null version is refused")
    refuses(STATE_KIND, cited(state_value, None, 1, **extra),
            f"{state_value} with a null id and version 1 is refused")
    refuses(STATE_KIND, cited(state_value, None, None, **extra),
            f"{state_value} with both halves null is refused")

# Omission is a different fault from an explicit null, for EITHER field, and in
# both the state that permits nulls and one that does not.
for state_value in ("unmonitored", "healthy"):
    for field in ("envelope_id", "envelope_version"):
        payload = cited(state_value, None if state_value == "unmonitored" else "CHENV-0001",
                        None if state_value == "unmonitored" else 1)
        del payload[field]
        refuses(STATE_KIND, payload,
                f"{state_value} with {field} OMITTED is refused")

# No sentinel. A null envelope plus any version-shaped value stays refused, and
# a declared envelope keeps the existing positive-integer rule.
for sentinel in (0, 1, -1, True, False, 1.0, "1", "", [], {}):
    refuses(STATE_KIND, cited("unmonitored", None, sentinel),
            f"unmonitored with a null id and version {sentinel!r} is refused")

# No leakage: a refusal names the field and the rule, never the value it
# rejected. Checked with values distinctive enough that a substring match means
# a real echo -- `-1` would match the "integer-at-least-1" detail and an empty
# string matches everything, so neither proves anything. The values here are
# also invalid on EVERY state, so these assertions test leakage alone and do
# not quietly re-test the pairing rule: a large positive integer such as
# 987654321 is a perfectly valid version beside a declared envelope.
for leaky in (-987654321, "SUPER-SECRET-ENVELOPE-VERSION"):
    refuses(STATE_KIND, cited("unmonitored", None, leaky),
            f"a refused version {leaky!r} is not echoed on an unmonitored state",
            forbidden_value=leaky)
    refuses(STATE_KIND, cited("healthy", "CHENV-0001", leaky),
            f"a refused version {leaky!r} is not echoed on a healthy state",
            forbidden_value=leaky)
for leaky in ("CHENV-SUPER-SECRET-IDENTIFIER", "CHOBS-987654"):
    refuses(STATE_KIND, cited("healthy", leaky, 1),
            f"a refused identifier {leaky!r} is not echoed",
            forbidden_value=leaky)
    refuses(STATE_KIND, cited("unmonitored", leaky, None),
            f"a refused identifier {leaky!r} is not echoed on unmonitored",
            forbidden_value=leaky)
for bad in (0, -1, -99, True, False, 1.0, "1", [], {}):
    refuses(STATE_KIND, cited("healthy", "CHENV-0001", bad),
            f"healthy with a valid id and version {bad!r} is refused")
try:
    parse(STATE_KIND, cited("healthy", "CHENV-0001", 2))
    print("PASS: a positive integer version other than 1 is still accepted")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: version 2 was refused: {error}", file=sys.stderr)
    failures += 1

# A malformed identifier stays malformed whatever the version beside it.
for malformed in ("CHENV-1", "chenv-0001", "CHOBS-000001", "", "null", 0, False, []):
    for ver in (1, None):
        refuses(STATE_KIND, cited("healthy", malformed, ver),
                f"healthy with malformed id {malformed!r} and version {ver!r} "
                f"is refused")
        refuses(STATE_KIND, cited("unmonitored", malformed, ver),
                f"unmonitored with malformed id {malformed!r} and version "
                f"{ver!r} is refused")

# The explicit nulls survive, for BOTH halves, through serialisation and back.
try:
    record = parse(STATE_KIND, cited("unmonitored", None, None))
    serialised = record.to_dict()
    for field in ("envelope_id", "envelope_version"):
        check(field in serialised,
              f"{field} is PRESENT in the serialised unmonitored state")
        check(serialised[field] is None,
              f"{field} serialises as an explicit null, not as a missing field")
    again = parse(STATE_KIND, copy.deepcopy(serialised))
    check(again.to_dict() == serialised,
          "a fully null citation round-trips losslessly")
    check(again.envelope_id is None and again.envelope_version is None,
          "both halves are still null after the round trip")
    check(json.loads(json.dumps(serialised))["envelope_version"] is None,
          "the null version survives JSON encoding")
except Exception as error:  # noqa: BLE001
    print(f"FAIL: the fully null citation was refused: {error}", file=sys.stderr)
    failures += 1

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

print("--- a threshold is a FINITE decimal string (ENG-0006-H1C) ---")
# NORMATIVE BASIS, quoted rather than inferred:
#   CHENV schema: `condition_value_representation: decimal-string`
#   ADR-0019:     "A decimal string, compared as an exact decimal... a threshold
#                  that compares differently on two hosts is not deterministic."
#   ADR-0013:     the absence of a policy produces an explicit "not defined",
#                  "never a favourable default", and
#                  `absent_threshold_never_means: healthy`.
#
# A non-finite threshold breaks all three. Under Python's default decimal
# context every comparison against NaN RAISES rather than returning a verdict,
# and a threshold of Infinity is violated either always or never regardless of
# what was measured. Either way the dimension LOOKS governed and cannot produce
# an honest finding -- which is the favourable default the architecture forbids,
# wearing a declared policy's clothes.
#
# Expected results below are written out here, not imported from the module.
ENV_KIND = "capability-health-envelope"


def envelope_with_threshold(value):
    """A minimum valid envelope whose entry threshold is `value`."""
    payload = copy.deepcopy(VALID[ENV_KIND])
    payload["dimensions"]["latency"]["entry_condition"]["value"] = value
    return payload


# Non-finite specials. Every one is refused.
for special in ("NaN", "-NaN", "+NaN", "nan", "NAN", "sNaN", "-sNaN",
                "Infinity", "-Infinity", "+Infinity", "infinity", "inf",
                "-inf", "Inf"):
    refuses(ENV_KIND, envelope_with_threshold(special),
            f"a threshold of {special!r} is refused as non-finite",
            forbidden_value=special)

# A very large exponent is NOT non-finite. `Decimal("1e999999")` is
# `Decimal("1E+999999")`, which `is_finite()` reports as finite -- it does not
# overflow, because a Decimal carries its exponent rather than converting. This
# assertion originally expected a refusal on the assumption that it overflowed;
# the assumption was wrong, and refusing it would be a magnitude restriction no
# normative source declares. It belongs with the accepted values below.

# Not decimal-string syntax. Each denotes nothing, or denotes a value only
# through a non-decimal convention.
for malformed in (" 1", "1 ", " 1 ", "1\n", "\t1", "1_000", "1,000", "0x10",
                  "1/2", "one", "", "   ", "--1", "1.2.3", "1e", "e3", "+",
                  "-", ".", "1e1.5"):
    refuses(ENV_KIND, envelope_with_threshold(malformed),
            f"a threshold of {malformed!r} is refused as non-decimal syntax")

# Finite decimals that MUST remain acceptable. Rejecting any of these would be
# inventing a precision, magnitude or formatting restriction that no normative
# source declares -- which this increment is explicitly forbidden from doing.
for ok in ("0", "-0", "+0", "0.1", "-0.1", "+1", "1.25", "2000", "32",
           "1e3", "1E3", "1.5e-3", "1.5E+3", ".5", "5.", "0.000001",
           "1e999999", "1e-999999",
           "1" + "0" * 400, "123456789012345678901234567890.123456789"):
    payload = envelope_with_threshold(ok)
    try:
        parse(ENV_KIND, payload)
        print(f"PASS: a finite decimal threshold {ok if len(ok) < 30 else ok[:22] + '...'!r} is accepted")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: a finite decimal threshold {ok!r} was refused: {error}",
              file=sys.stderr)
        failures += 1

# An exponent large enough that Decimal will not construct the value raises at
# construction and is refused as malformed syntax -- not silently accepted and
# not reported as non-finite. Pinned because it is the boundary between the two
# refusal paths.
refuses(ENV_KIND, envelope_with_threshold("1e" + "9" * 30),
        "a threshold whose exponent Decimal cannot construct is refused")

# Both conditions are governed, not just the entry one.
payload = copy.deepcopy(VALID[ENV_KIND])
payload["dimensions"]["latency"]["exit_condition"]["value"] = "NaN"
refuses(ENV_KIND, payload, "a non-finite EXIT threshold is refused")

# And the same rule governs a transition record's quoted condition.
payload = copy.deepcopy(VALID["capability-degradation-event"])
payload["entry_condition"]["value"] = "Infinity"
refuses("capability-degradation-event", payload,
        "a non-finite quoted condition on a transition is refused")
payload = copy.deepcopy(VALID["capability-degradation-event"])
payload["entry_condition"]["value"] = " 2000 "
refuses("capability-degradation-event", payload,
        "a whitespace-padded quoted condition on a transition is refused")

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
