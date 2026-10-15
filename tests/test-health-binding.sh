#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for ENG-0006-H2 — subject identity and reference
# validation.
#
# WHAT H2 IS, AND IS NOT.
#
# H2 enforces one rule from ADR-0013's referential-integrity section: a record's
# subject must equal the subject of every record it cites. Its input is **a
# record plus its cited records, supplied by the caller** -- the shape ENG-0006-D
# component A2 declares. There is no store, no network, no resolution from
# persistence, and no identity authority.
#
# THAT BOUNDARY IS THE POINT. H2 cannot know whether a cited record exists in
# the world; it knows only whether the caller supplied one. So a citation whose
# record is absent from the supplied set is REFUSED rather than skipped -- a
# validator that quietly passed an unresolvable citation would validate nothing
# -- and the refusal says `cited-record-not-supplied`, not "nonexistent", because
# claiming the record does not exist would be an assertion H2 has no basis for.
#
# H2 also does not conclude that a syntactically valid identifier names a real,
# authenticated, trusted, available, eligible or healthy entity. It compares
# subjects. Nothing else.
#
# THE ORACLE IS THE NORMATIVE TEXT, NOT THE MODULE.
#
# The six rules exercised below are quoted from ADR-0013 in the comments beside
# them, and the citation map is read out of the committed schemas. No expected
# value is imported from tools.health.
#
# Nothing here contacts a host, opens a socket, spawns a subprocess, writes
# outside memory, or touches any production store.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import copy
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

# --- the oracle ----------------------------------------------------------
SCHEMA = {}
for family in ("capability-health-envelope", "capability-health-observation",
               "capability-health-state", "capability-degradation-event",
               "capability-health-recommendation", "capability-heartbeat"):
    SCHEMA[family] = yaml.safe_load(
        (root / "platform-model/schemas" / f"{family}.schema.yaml").read_text())

# Every family that declares a subject binding must declare all four rules.
for family in ("capability-health-state", "capability-degradation-event",
               "capability-health-recommendation"):
    s = SCHEMA[family]
    check(s.get("subject_binding") == "must-match-every-cited-record",
          f"{family} schema requires a match against every cited record")
    check(s.get("identifier_format_sufficient") is False,
          f"{family} schema declares identifier format insufficient")
    check(s.get("cross_subject_citation") == "refuse",
          f"{family} schema refuses a cross-subject citation")
    check(s.get("nonexistent_reference") == "refuse",
          f"{family} schema refuses an unresolvable reference")

try:
    from tools.health import records as H
    from tools.health import errors as E
    IMPORTED = True
except Exception as error:  # noqa: BLE001
    IMPORTED = False
    print(f"FAIL: tools.health import failed: {type(error).__name__}", file=sys.stderr)
    failures += 1

if not IMPORTED:
    print(f"\nHealth binding validation FAILED with {failures} error(s).", file=sys.stderr)
    raise SystemExit(1)

check(hasattr(H, "validate_citations"),
      "the records module exposes validate_citations()")
check(hasattr(H, "citations_of"),
      "the records module exposes citations_of()")
if not (hasattr(H, "validate_citations") and hasattr(H, "citations_of")):
    print(f"\nHealth binding validation FAILED with {failures} error(s).", file=sys.stderr)
    raise SystemExit(1)

for code in ("CROSS_SUBJECT_CITATION", "CITED_RECORD_NOT_SUPPLIED",
             "CITED_RECORD_KIND_MISMATCH", "CITED_RECORD_IDENTITY_MISMATCH",
             "CITATION_SET_MALFORMED"):
    check(hasattr(E, code) and getattr(E, code) in E.CODES,
          f"the controlled refusal vocabulary declares {code}")

# --- hand-written fixtures, two distinct subjects -------------------------
PROV = {"class": "declared", "source": "docs/decisions/ADR-0013-capability-health-plane.md",
        "recorded_at": "2026-10-15"}
A = ("capability-instance", "CINST-000007")   # subject A
B = ("capability-instance", "CINST-000001")   # subject B, same type
C = ("capability-host", "CINST-000007")       # same id, DIFFERENT type


def obs(identifier, subject, dimension="latency"):
    t, i = subject
    return {"observation_id": identifier, "subject_type": t, "subject_id": i,
            "dimension": dimension, "measured_value": "1200",
            "unit": "milliseconds", "observed_at": "2026-10-15T09:00:00-05:00",
            "collector_id": "linux_resources",
            "source_fingerprint": "sha256:" + "a" * 64,
            "collection_status": "collected", "provenance": dict(PROV)}


def envelope(identifier, subject):
    t, i = subject
    return {"envelope_id": identifier, "envelope_version": 1,
            "subject_type": t, "subject_id": i,
            "dimensions": {"latency": {
                "dimension": "latency", "unit": "milliseconds",
                "aggregation": {"kind": "instant"},
                "entry_condition": {"operator": "gt", "value": "2000"},
                "exit_condition": {"operator": "le", "value": "1500"},
                "hysteresis": {"kind": "duration", "seconds": 120,
                               "max_gap_seconds": 30, "min_samples": 3},
                "freshness_policy_seconds": 60}},
            "evaluation": "worst-dimension-wins", "provenance": dict(PROV)}


def state(identifier, subject, observation_ids=("CHOBS-000001",),
          envelope_id="CHENV-0001"):
    t, i = subject
    return {"state_id": identifier, "subject_type": t, "subject_id": i,
            "state": "healthy", "envelope_id": envelope_id, "envelope_version": 1,
            "derived_from_observation_ids": list(observation_ids),
            "freshness": "current", "reason": "within the declared envelope",
            "evaluated_at": "2026-10-15T09:00:05-05:00", "provenance": dict(PROV)}


def event(identifier, subject, observation_ids=("CHOBS-000001", "CHOBS-000002"),
          first="CHOBS-000001", last="CHOBS-000002", envelope_id=None):
    t, i = subject
    body = {"event_id": identifier, "subject_type": t, "subject_id": i,
            "from_state": "healthy", "to_state": "degraded",
            "dimension": "latency",
            "entry_condition": {"operator": "gt", "value": "2000"},
            "observed_at": "2026-10-15T09:02:00-05:00",
            "derived_from_observation_ids": list(observation_ids),
            "provenance": dict(PROV),
            "hysteresis": {"kind": "duration", "seconds": 120,
                           "max_gap_seconds": 30, "min_samples": 3},
            "hysteresis_satisfied_over_seconds": 125,
            "hysteresis_first_observation_id": first,
            "hysteresis_last_observation_id": last,
            "hysteresis_sample_count": 5,
            "hysteresis_observed_max_gap_seconds": 25}
    if envelope_id is not None:
        body["envelope_id"] = envelope_id
    return body


def recommendation(identifier, subject, state_id="CHSTATE-000001", event_id=None):
    t, i = subject
    body = {"recommendation_id": identifier, "subject_type": t, "subject_id": i,
            "recommendation": "investigate", "reason": "latency outside its limit",
            "derived_from_state_id": state_id,
            "created_at": "2026-10-15T09:03:00-05:00",
            "review_required": True, "advisory_only": True,
            "provenance": dict(PROV)}
    if event_id is not None:
        body["derived_from_event_id"] = event_id
    return body


def parsed(kind, payload):
    return H.parse(kind, copy.deepcopy(payload))


def refuses(record, cited, label, expected_code=None, *, sentinel=None):
    """Assert a binding refusal, with a named class and no value leakage."""
    global failures
    try:
        H.validate_citations(record, cited)
    except E.HealthRecordError as error:
        if not getattr(error, "code", ""):
            print(f"FAIL: {label}: refused without a named class", file=sys.stderr)
            failures += 1
            return
        if expected_code is not None and error.code != expected_code:
            print(f"FAIL: {label}: refused as {error.code!r}, expected "
                  f"{expected_code!r}", file=sys.stderr)
            failures += 1
            return
        if sentinel is not None and sentinel in str(error):
            print(f"FAIL: {label}: the refusal echoed a supplied value",
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


def accepts(record, cited, label):
    global failures
    try:
        H.validate_citations(record, cited)
        print(f"PASS: {label}")
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: {label}: refused — {error}", file=sys.stderr)
        failures += 1


print("--- the citation map matches what the schemas declare ---")
# Read the citing fields out of the schemas rather than out of the module.
EXPECTED_CITATIONS = {
    "capability-health-state": {
        "derived_from_observation_ids": "capability-health-observation",
        "envelope_id": "capability-health-envelope"},
    "capability-degradation-event": {
        "derived_from_observation_ids": "capability-health-observation",
        "hysteresis_first_observation_id": "capability-health-observation",
        "hysteresis_last_observation_id": "capability-health-observation",
        "envelope_id": "capability-health-envelope"},
    "capability-health-recommendation": {
        "derived_from_state_id": "capability-health-state",
        "derived_from_event_id": "capability-degradation-event"},
    "capability-health-observation": {},
    "capability-heartbeat": {},
    "capability-health-envelope": {},
}
for kind, expected in EXPECTED_CITATIONS.items():
    declared = H.citations_of(kind)
    check(dict(declared) == expected,
          f"{kind} cites exactly the declared families "
          f"({sorted(declared)} vs {sorted(expected)})")
    for field in expected:
        allowed = (set(SCHEMA[kind].get("required_fields") or [])
                   | set(SCHEMA[kind].get("optional_fields") or [])
                   | set(SCHEMA[kind].get("conditionally_required_fields") or []))
        check(field in allowed,
              f"{kind} citing field {field} is a declared schema field")

print("--- a fully consistent working set is accepted ---")
# ADR-0013: "Every health state's subject equals the subject of every
# observation it cites" -- satisfied here.
S_A = parsed("capability-health-state", state("CHSTATE-000001", A))
CITED_A = {
    "CHOBS-000001": parsed("capability-health-observation", obs("CHOBS-000001", A)),
    "CHENV-0001": parsed("capability-health-envelope", envelope("CHENV-0001", A)),
}
accepts(S_A, CITED_A, "a state whose observation and envelope share its subject")

E_A = parsed("capability-degradation-event", event("CHDEG-000001", A))
CITED_E = {
    "CHOBS-000001": parsed("capability-health-observation", obs("CHOBS-000001", A)),
    "CHOBS-000002": parsed("capability-health-observation", obs("CHOBS-000002", A)),
}
accepts(E_A, CITED_E, "a transition whose every cited observation shares its subject")

R_A = parsed("capability-health-recommendation",
             recommendation("CHREC-000001", A, event_id="CHDEG-000001"))
CITED_R = {"CHSTATE-000001": S_A, "CHDEG-000001": E_A}
accepts(R_A, CITED_R, "a recommendation whose state and transition share its subject")

print("--- families that cite nothing are vacuously bound ---")
for kind, payload in (("capability-health-observation", obs("CHOBS-000009", A)),
                      ("capability-health-envelope", envelope("CHENV-0009", A)),
                      ("capability-heartbeat", {
                          "heartbeat_id": "CHBEAT-000001", "subject_type": A[0],
                          "subject_id": A[1],
                          "observed_at": "2026-10-15T09:00:00-05:00",
                          "received_at": "2026-10-15T09:00:01-05:00",
                          "epoch": 3, "sequence": 41, "provenance": dict(PROV)})):
    accepts(parsed(kind, payload), {}, f"{kind} cites nothing and binds vacuously")

print("--- unused supplied records are permitted context, not an error ---")
accepts(S_A, dict(CITED_A, **{"CHOBS-000099": parsed(
    "capability-health-observation", obs("CHOBS-000099", B))}),
    "a supplied record the subject does not cite is ignored, not refused")

print("--- CROSS-SUBJECT CITATION is refused, every family, every field ---")
# ADR-0013: "A state citing another subject's observations is well-formed,
# correctly typed, and false -- the cheapest route to a forged positive claim."
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", B)),
              "CHENV-0001": parsed("capability-health-envelope",
                                   envelope("CHENV-0001", A))},
        "a state citing another subject's observation is refused",
        E.CROSS_SUBJECT_CITATION, sentinel="CINST-000001")
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", A)),
              "CHENV-0001": parsed("capability-health-envelope",
                                   envelope("CHENV-0001", B))},
        "a state citing another subject's envelope is refused",
        E.CROSS_SUBJECT_CITATION)
# Same identifier, different subject TYPE. Type and id are separate assertions.
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", C)),
              "CHENV-0001": parsed("capability-health-envelope",
                                   envelope("CHENV-0001", A))},
        "a state citing the same identifier under a different subject TYPE is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(E_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", A)),
              "CHOBS-000002": parsed("capability-health-observation",
                                     obs("CHOBS-000002", B))},
        "a transition with one foreign observation among several is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(parsed("capability-degradation-event",
               event("CHDEG-000002", A, first="CHOBS-000003")),
        {"CHOBS-000001": parsed("capability-health-observation", obs("CHOBS-000001", A)),
         "CHOBS-000002": parsed("capability-health-observation", obs("CHOBS-000002", A)),
         "CHOBS-000003": parsed("capability-health-observation", obs("CHOBS-000003", B))},
        "a transition whose hysteresis FIRST observation is foreign is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(parsed("capability-degradation-event",
               event("CHDEG-000003", A, last="CHOBS-000004")),
        {"CHOBS-000001": parsed("capability-health-observation", obs("CHOBS-000001", A)),
         "CHOBS-000002": parsed("capability-health-observation", obs("CHOBS-000002", A)),
         "CHOBS-000004": parsed("capability-health-observation", obs("CHOBS-000004", B))},
        "a transition whose hysteresis LAST observation is foreign is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(parsed("capability-degradation-event",
               event("CHDEG-000004", A, envelope_id="CHENV-0002")),
        dict(CITED_E, **{"CHENV-0002": parsed("capability-health-envelope",
                                              envelope("CHENV-0002", B))}),
        "a transition citing another subject's envelope is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(R_A, {"CHSTATE-000001": parsed("capability-health-state",
                                       state("CHSTATE-000001", B)),
              "CHDEG-000001": E_A},
        "a recommendation citing another subject's state is refused",
        E.CROSS_SUBJECT_CITATION)
refuses(R_A, {"CHSTATE-000001": S_A,
              "CHDEG-000001": parsed("capability-degradation-event",
                                     event("CHDEG-000001", B))},
        "a recommendation citing another subject's transition is refused",
        E.CROSS_SUBJECT_CITATION)

print("--- an UNSUPPLIED citation is refused, not skipped ---")
# ADR-0013: "A reference to a record that does not exist is refused, not
# skipped." H2 can only know it was not supplied, and says exactly that.
refuses(S_A, {"CHENV-0001": parsed("capability-health-envelope",
                                   envelope("CHENV-0001", A))},
        "a state whose cited observation was not supplied is refused",
        E.CITED_RECORD_NOT_SUPPLIED, sentinel="CHOBS-000001")
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", A))},
        "a state whose cited envelope was not supplied is refused",
        E.CITED_RECORD_NOT_SUPPLIED)
refuses(S_A, {}, "a state supplied with nothing at all is refused",
        E.CITED_RECORD_NOT_SUPPLIED)
refuses(E_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", A))},
        "a transition missing one of its cited observations is refused",
        E.CITED_RECORD_NOT_SUPPLIED)
refuses(R_A, {"CHSTATE-000001": S_A},
        "a recommendation whose optional cited transition was not supplied is refused",
        E.CITED_RECORD_NOT_SUPPLIED)

print("--- an optional citation that is ABSENT from the record needs nothing ---")
accepts(parsed("capability-health-recommendation",
               recommendation("CHREC-000002", A)),
        {"CHSTATE-000001": S_A},
        "a recommendation that cites no transition requires none to be supplied")
accepts(parsed("capability-degradation-event", event("CHDEG-000005", A)),
        CITED_E,
        "a transition that cites no envelope requires none to be supplied")

print("--- a WRONG-FAMILY supplied record is refused ---")
# A wrong-family record can never carry an identifier of the cited family --
# the prefixes differ -- so the only way to present one is under the cited key
# with its own, foreign, identity. Family is therefore checked BEFORE identity,
# and this asserts that order: both faults are present and the refusal names
# the more fundamental one.
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000001", A)),
              "CHENV-0001": parsed("capability-health-observation",
                                   obs("CHOBS-000005", A))},
        "a state whose cited envelope slot holds an observation is refused",
        E.CITED_RECORD_KIND_MISMATCH)
refuses(R_A, {"CHSTATE-000001": parsed("capability-health-observation",
                                       obs("CHOBS-000006", A)),
              "CHDEG-000001": E_A},
        "a recommendation whose cited state slot holds an observation is refused",
        E.CITED_RECORD_KIND_MISMATCH)

print("--- a SUBSTITUTED record, keyed under another identifier, is refused ---")
# Never silently substitute another record: the supplied record's own identity
# must equal the key it was supplied under.
refuses(S_A, {"CHOBS-000001": parsed("capability-health-observation",
                                     obs("CHOBS-000777", A)),
              "CHENV-0001": parsed("capability-health-envelope",
                                   envelope("CHENV-0001", A))},
        "an observation supplied under a different identifier is refused",
        E.CITED_RECORD_IDENTITY_MISMATCH, sentinel="CHOBS-000777")

print("--- a malformed citation set is refused ---")
for bad in (None, [], "CHOBS-000001", 7,
            {"CHOBS-000001": {"observation_id": "CHOBS-000001"}},
            {7: None}):
    refuses(S_A, bad, f"a citation set of {type(bad).__name__} is refused",
            E.CITATION_SET_MALFORMED)

print("--- the record itself must be a parsed Health record ---")
for bad in (None, {}, "CHSTATE-000001", state("CHSTATE-000001", A)):
    try:
        H.validate_citations(bad, CITED_A)
        print(f"FAIL: an unparsed record ({type(bad).__name__}) was accepted",
              file=sys.stderr)
        failures += 1
    except E.HealthRecordError:
        print(f"PASS: an unparsed record ({type(bad).__name__}) is refused")

print("--- identifier syntax alone is proven insufficient ---")
# `identifier_format_sufficient: false`. Every identifier below is perfectly
# well formed; the relationship between the records is what is false.
well_formed = {"CHOBS-000001": parsed("capability-health-observation",
                                      obs("CHOBS-000001", B)),
               "CHENV-0001": parsed("capability-health-envelope",
                                    envelope("CHENV-0001", B))}
for identifier in well_formed:
    check(H.PATTERNS[{"CHOBS-000001": "capability-health-observation",
                      "CHENV-0001": "capability-health-envelope"}[identifier]]
          .match(identifier) is not None,
          f"{identifier} is a syntactically valid identifier")
refuses(S_A, well_formed,
        "syntactically valid identifiers do not make a citation valid",
        E.CROSS_SUBJECT_CITATION)

print("--- H2 asserts nothing about existence, authenticity or standing ---")
check(not any(hasattr(H, name) for name in
              ("resolve", "fetch", "load", "authenticate", "verify_identity",
               "exists", "lookup", "store", "trust")),
      "the module exposes no resolution, authentication or lookup entry point")
source = __import__("inspect").getsource(H)
for banned in ("import socket", "import subprocess", "urllib", "http.client",
               "tools.fabric", "tools.capability", "tools.trust",
               "ImmutableStore", "allocate_id", "open(", "Path("):
    check(banned not in source, f"the records module contains no {banned!r}")

print("--- a refusal never echoes a supplied value ---")
SENTINEL = "CINST-SENTINEL-MUST-NOT-APPEAR"
try:
    H.validate_citations(S_A, {
        "CHOBS-000001": parsed("capability-health-observation",
                               obs("CHOBS-000001",
                                   ("capability-instance", SENTINEL))),
        "CHENV-0001": parsed("capability-health-envelope", envelope("CHENV-0001", A))})
    print("FAIL: a foreign-subject citation was accepted", file=sys.stderr)
    failures += 1
except E.HealthRecordError as error:
    check(SENTINEL not in str(error),
          "a cross-subject refusal does not echo the foreign subject identifier")
    check(error.code == E.CROSS_SUBJECT_CITATION,
          "a cross-subject refusal names its class")

print("--- caller-owned input cannot be altered by validation ---")
supplied = dict(CITED_A)
before = {k: v.to_dict() for k, v in supplied.items()}
H.validate_citations(S_A, supplied)
check(set(supplied) == set(before) and
      all(supplied[k].to_dict() == before[k] for k in before),
      "validation mutates neither the citation set nor the records in it")

print()
if failures:
    print(f"Health binding validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All health binding assertions passed.")
PY
