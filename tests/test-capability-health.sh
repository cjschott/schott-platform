#!/usr/bin/env bash
set -Eeuo pipefail

# Static and documentation validation for the Capability Health Plane.
#
# THIS SPRINT DEFINES ARCHITECTURE ONLY. There is no runtime implementation,
# and this suite asserts that: no health engine, no collectors, no probes, no
# heartbeat receiver, no evaluation loop, no remediation, no rerouting, no
# drain, no quarantine, no trust mutation, and no prediction of any kind.
#
# The Health Plane is the most dangerous layer in the platform to build
# carelessly, because availability data is the easiest signal to manipulate
# from outside and the most tempting to act on automatically. Most of the
# assertions here are about what must remain impossible.
#
# Nothing here contacts a host, reads a credential, or executes a transport.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADR="docs/decisions/ADR-0013-capability-health-plane.md"
HEALTH_DOC="docs/health/capability-health.md"
STATES_DOC="docs/health/health-states.md"
OBSERVATION_DOC="docs/health/observation-model.md"
ENVELOPE_DOC="docs/health/operational-envelope.md"
DEGRADATION_DOC="docs/health/degradation-semantics.md"
GOVERNANCE_DOC="docs/health/governance-boundaries.md"
ROADMAP="docs/platform-roadmap.md"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

assert_absent_in() {
  local target="$1" pattern="$2" description="$3" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required artefacts ------------------------------------------------------
assert_file "${ADR}"
for doc in "${HEALTH_DOC}" "${STATES_DOC}" "${OBSERVATION_DOC}" "${ENVELOPE_DOC}" \
           "${DEGRADATION_DOC}" "${GOVERNANCE_DOC}"; do
  assert_file "${doc}"
done

HEALTH_SCHEMAS=(capability-health-envelope capability-heartbeat
                capability-health-observation capability-health-state
                capability-degradation-event capability-health-recommendation)
for schema in "${HEALTH_SCHEMAS[@]}"; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- ADR structure -----------------------------------------------------------
assert_contains "${ADR}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0013 is accepted"
for section in '^## Context' '^## Decision' '^## Rejected Alternatives' '^## Consequences'; do
  assert_contains "${ADR}" "${section}" "ADR-0013 contains ${section#^## }"
done
assert_contains "${ADR}" '[Aa]rchitecture only' "ADR-0013 declares itself architecture only"
assert_contains "${ADR}" '[Nn]o runtime implementation' "ADR-0013 declares no runtime implementation"

# --- The governing principle -------------------------------------------------
assert_contains "${ADR}" '[Hh]ealth never grants trust' "ADR-0013 states health never grants trust"
assert_contains "${ADR}" '[Tt]rust never implies health' "ADR-0013 states trust never implies health"
assert_contains "${ADR}" '[Dd]eclared operational envelope' \
  "ADR-0013 defines health against a declared operational envelope"
assert_contains "${ADR}" '[Hh]ealth must never override trust|[Hh]ealth never overrides trust' \
  "ADR-0013 states health never overrides trust"
assert_contains "${ADR}" '[Ww]here the two disagree, trust decides' \
  "ADR-0013 states trust decides on disagreement"

# --- The three layers --------------------------------------------------------
assert_contains "${ADR}" '^### Trust, Fabric, and Health' "ADR-0013 defines the three-layer separation"
for question in '[Mm]ay this subject participate' \
                '[Ww]here may .*execute|[Ww]here can this workload execute' \
                '[Ii]s the trusted capability currently available'; do
  assert_contains "${ADR}" "${question}" "ADR-0013 states the layer question: ${question}"
done

# --- What health may never do ------------------------------------------------
# Each is a different way an observability layer becomes a controller. Named
# individually because a single "no remediation" line would not cover them.
for forbidden in '[Hh]ealth cannot grant trust' \
                 '[Hh]ealth cannot (change|mutate) [Tt]rust' \
                 '[Hh]ealth cannot override quarantine' \
                 '[Hh]ealth cannot broaden scope' \
                 '[Hh]ealth cannot admit' \
                 '[Nn]o automatic rerouting' \
                 '[Nn]o automatic drain' \
                 '[Nn]o automatic quarantine' \
                 '[Nn]o autonomous remediation' \
                 '[Nn]o automatic node admission' \
                 '[Nn]o prediction' \
                 '[Nn]o forecasting' \
                 '[Nn]o .*anomaly'; do
  assert_contains "${ADR}" "${forbidden}" "ADR-0013 forbids: ${forbidden}"
done

# The one thing health may produce, and it is a record rather than an act.
assert_contains "${ADR}" '[Rr]ecommend' "ADR-0013 permits recommendation"
assert_contains "${ADR}" '[Cc]annot execute remediation' "ADR-0013 forbids executing remediation"

# --- Health states -----------------------------------------------------------
for state in 'unknown' 'unmonitored' 'healthy' 'degraded' 'unavailable' 'withheld'; do
  assert_contains "${STATES_DOC}" "\`${state}\`" "states document defines ${state}"
done

# The distinction that keeps a monitoring outage from becoming a platform
# outage, and an unmonitored node from becoming the preferred one.
assert_contains "${STATES_DOC}" '[Nn]ever healthy' "unknown is never healthy"
assert_contains "${STATES_DOC}" '[Ii]nert' "unknown is inert with respect to eligibility"
assert_contains "${ADR}" '^### Why unknown does not remove a candidate' \
  "ADR-0013 explains why unknown neither qualifies nor disqualifies"

# Health states must not be confused with trust states.
assert_contains "${STATES_DOC}" '[Tt]rust state' "states document distinguishes health from trust states"
for trust_state in 'Trusted' 'Restricted' 'Quarantined' 'Revoked'; do
  matches="$(grep -nE "^\| \`?${trust_state}" "${ROOT}/${STATES_DOC}" || true)"
  if [[ -z "${matches}" ]]; then
    pass "health states do not redefine the trust state ${trust_state}"
  else
    fail "health states must not redefine the trust state ${trust_state}"
  fi
done

# --- Freshness reuses the existing standard ----------------------------------
# Four freshness states already exist. Inventing a fifth here would give the
# platform two vocabularies for the same idea.
for freshness in 'current' 'aging' 'stale' 'unknown'; do
  assert_contains "${OBSERVATION_DOC}" "${freshness}" \
    "observation model reuses the freshness state ${freshness}"
done
assert_contains "${OBSERVATION_DOC}" '[Nn]ull [Pp]olicy [Rr]ule|no freshness policy' \
  "observation model inherits the null policy rule"
assert_contains "${OBSERVATION_DOC}" 'confidence-freshness-standard' \
  "observation model cites the confidence and freshness standard"

# --- A collection failure is not a subject failure ---------------------------
# The collector standard already establishes this one layer down. A health
# monitor that concluded "unreachable therefore unhealthy" would manufacture
# findings out of its own outages.
assert_contains "${ADR}" '[Cc]ollection failure is not a' \
  "ADR-0013 states a collection failure is not a subject failure"
assert_contains "${OBSERVATION_DOC}" '[Cc]ollection failure' \
  "observation model separates collection failure from subject failure"

# --- Observed dimensions -----------------------------------------------------
for dimension in '[Aa]vailability' '[Ll]atency' 'queue depth' '[Rr]esource pressure' \
                 '[Hh]eartbeat' '[Ss]uccess' '[Ff]ailure' '[Tt]ransport' \
                 '[Cc]ollector freshness'; do
  assert_contains "${OBSERVATION_DOC}" "${dimension}" \
    "observation model covers ${dimension}"
done
for resource in 'GPU' 'VRAM' 'CPU' '[Mm]emory'; do
  assert_contains "${OBSERVATION_DOC}" "${resource}" \
    "observation model covers ${resource} utilization"
done

# --- Envelope ----------------------------------------------------------------
assert_contains "${ENVELOPE_DOC}" '[Dd]eclared' "envelope is declared, not learned"
assert_contains "${ENVELOPE_DOC}" '[Hh]uman' "envelope is authored by a human"
assert_contains "${ENVELOPE_DOC}" 'unmonitored' \
  "a subject with no envelope is unmonitored rather than healthy"
assert_contains "${ENVELOPE_DOC}" '[Nn]ever (learned|derived|inferred)|not learned' \
  "envelope thresholds are never learned from observed behaviour"

# --- Degradation semantics ---------------------------------------------------
assert_contains "${DEGRADATION_DOC}" '[Hh]ysteresis' "degradation defines hysteresis"
assert_contains "${DEGRADATION_DOC}" '[Ff]lap' "degradation addresses flapping"
assert_contains "${DEGRADATION_DOC}" '[Ee]ntry' "degradation defines entry conditions"
assert_contains "${DEGRADATION_DOC}" '[Ee]xit' "degradation defines exit conditions"
assert_contains "${DEGRADATION_DOC}" '[Dd]eterministic' "degradation evaluation is deterministic"
assert_contains "${DEGRADATION_DOC}" '[Nn]ever.*future|[Nn]o .*prediction|never predicts' \
  "degradation describes observed history, never the future"

# --- Governance boundaries ---------------------------------------------------
assert_contains "${GOVERNANCE_DOC}" '[Cc]onsumes [Tt]rust' "health consumes trust state"
assert_contains "${GOVERNANCE_DOC}" '[Cc]annot change|cannot mutate' "health cannot change trust state"
assert_contains "${GOVERNANCE_DOC}" '[Rr]ecommend' "health may recommend"
assert_contains "${GOVERNANCE_DOC}" '[Aa]udit' "governance defines audit requirements"
assert_contains "${ADR}" '^### Audit requirements' "ADR-0013 defines audit requirements"

# The Trust Plane must not read health back as evidence, or the loop closes.
assert_contains "${ADR}" '[Tt]rust Plane .*(does not|never) (use|consume)' \
  "ADR-0013 forbids the Trust Plane consuming health as evidence"

# --- Reconciliation with the v0.9.6 reservation ------------------------------
# The reservation named lease-health and placement-health. v0.9.5 deliberately
# defined no lease and no placement entity, so those two have nothing to
# observe. Saying so is better than shipping entities with no referent.
assert_contains "${ADR}" 'lease' "ADR-0013 reconciles the reserved lease-health entity"
assert_contains "${ADR}" 'placement' "ADR-0013 reconciles the reserved placement-health entity"

# --- No health runtime -------------------------------------------------------
# ADR-0013 remains architecture. `tools/fabric` is released by ENG-0004, which
# implements the Fabric and evaluates no health; every health-runtime name here
# stays forbidden.
for forbidden_dir in tools/health tools/monitor tools/heartbeat tools/probe \
                     tools/telemetry tools/metrics; do
  if [[ -d "${ROOT}/${forbidden_dir}" ]]; then
    fail "architecture only; ${forbidden_dir} must not exist"
  else
    pass "no implementation directory: ${forbidden_dir}"
  fi
done

# No health runtime records may be committed.
HEALTH_RUNTIME_RECORDS="$(git -C "${ROOT}" ls-files \
  '*CHOBS-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CHSTATE-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CHBEAT-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CHDEG-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CHREC-[0-9][0-9][0-9][0-9][0-9][0-9]*' 2>/dev/null)" || HEALTH_RUNTIME_RECORDS=""
if [[ -z "${HEALTH_RUNTIME_RECORDS}" ]]; then
  pass "no health runtime records are committed"
else
  fail "health runtime records must not be committed: ${HEALTH_RUNTIME_RECORDS}"
fi

# The health documentation must not acquire an execution vocabulary.
for doc in "${HEALTH_DOC}" "${OBSERVATION_DOC}" "${GOVERNANCE_DOC}" "${DEGRADATION_DOC}"; do
  assert_absent_in "${doc}" \
    '(docker (run|exec)|ssh +[a-z]|systemctl (start|restart)|curl +http|apt-get install|pip install)' \
    "$(basename "${doc}") contains no execution command"
done

# No probing vocabulary asserted as a thing that happens. Health in this
# release describes what a future runtime would record, not something running.
for probe_word in 'we poll' 'polls every' 'scrape interval' 'probe interval' \
                  'is running' 'currently monitors'; do
  matches="$(grep -rIniE -e "${probe_word}" "${ROOT}/docs/health/" 2>/dev/null || true)"
  if [[ -z "${matches}" ]]; then
    pass "no runtime behaviour asserted: ${probe_word}"
  else
    fail "health documentation asserts runtime behaviour: ${probe_word}"
  fi
done

# --- Schema invariants -------------------------------------------------------
set +e
python3 - "${ROOT}" <<'PY'
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


try:
    from tools.common.yaml_strict import load_strict
except Exception as exc:  # noqa: BLE001
    print(f"FAIL: strict YAML loader is importable ({exc})", file=sys.stderr)
    print("__FAILURES__=1")
    sys.exit(1)


def load(relative):
    path = root / relative
    if not path.is_file():
        return None
    return load_strict(path)


EXPECTED_IDS = {
    "capability-health-envelope": ("CHENV", 4),
    "capability-heartbeat": ("CHBEAT", 6),
    "capability-health-observation": ("CHOBS", 6),
    "capability-health-state": ("CHSTATE", 6),
    "capability-degradation-event": ("CHDEG", 6),
    "capability-health-recommendation": ("CHREC", 6),
}

schemas = {}
for name, (prefix, digits) in EXPECTED_IDS.items():
    schema = load(f"platform-model/schemas/{name}.schema.yaml")
    check(schema is not None, f"{name} schema loads")
    if schema is None:
        continue
    schemas[name] = schema
    check(schema.get("schema_for") == name, f"{name} declares schema_for")
    check(schema.get("id_pattern") == f"^{prefix}-[0-9]{{{digits}}}$",
          f"{name} uses the {prefix} identifier pattern")
    provenance = schema.get("provenance") or {}
    check(provenance.get("source") == "docs/decisions/ADR-0013-capability-health-plane.md",
          f"{name} cites ADR-0013 as its source")

# Everything the health plane records is immutable. A health history that can
# be edited cannot answer what was known at the moment a decision was made.
for name in EXPECTED_IDS:
    schema = schemas.get(name, {})
    check(schema.get("mutability") == "immutable", f"{name} is immutable")
    check(schema.get("update_methods") == "none", f"{name} has no update method")
    check(schema.get("delete_methods") == "none", f"{name} has no delete method")

# --- The invariant the whole layer exists to preserve -----------------------
for name in EXPECTED_IDS:
    schema = schemas.get(name, {})
    check(schema.get("may_modify_trust_state") is False,
          f"{name} may never modify trust state")
    check(schema.get("may_execute") is False,
          f"{name} may never execute anything")

# --- Envelope: declared, never learned --------------------------------------
env = schemas.get("capability-health-envelope", {})
for field in ("envelope_id", "subject_type", "subject_id", "dimensions",
              "evaluation", "provenance"):
    check(field in (env.get("required_fields") or []), f"envelope requires {field}")
check(env.get("authored_by") == "human",
      "an envelope is authored by a human")
check(env.get("threshold_source") == "declared-only",
      "envelope thresholds are declared, never learned from behaviour")
check(env.get("absent_envelope_means") == "unmonitored",
      "a subject with no envelope is unmonitored, never healthy")
for forbidden in ("learned_threshold", "auto_threshold", "baseline_threshold",
                  "anomaly_model", "forecast", "predicted_limit", "trust_state"):
    check(forbidden in (env.get("forbidden_fields") or []),
          f"envelope forbids {forbidden}")

# Experience may be cited as supporting evidence for a human's judgement. It
# may never author or mutate the policy, or the threshold becomes one the
# subject taught the platform.
check(env.get("experience_may_reference") is True,
      "Experience output may be referenced as supporting evidence")
check(env.get("experience_may_author") is False,
      "Experience cannot author an envelope")
check(env.get("experience_may_mutate") is False,
      "Experience cannot mutate an envelope")
check(env.get("baseline_promotion") == "forbidden",
      "no baseline automatically becomes a threshold")
check(env.get("violation_widens_threshold") is False,
      "frequent violations cannot widen a threshold")
check(env.get("change_requires") == "immutable-approval",
      "envelope changes require immutable approval")

# The Null Policy Rule, applied per metric rather than per envelope. An
# envelope covering four dimensions and declaring three of them must not report
# the fourth as satisfied.
check(env.get("null_policy_scope") == "per-metric",
      "the null policy rule applies independently per metric")
check(env.get("absent_threshold_means") == "insufficient-policy",
      "a metric with no threshold produces insufficient-policy")
check(env.get("absent_threshold_never_means") == "healthy",
      "a missing threshold never produces healthy")

# Supersession keeps the chain readable, and never reaches back.
check("envelope_version" in (env.get("required_fields") or []),
      "envelope records its version")
check(env.get("supersession") == "new-record-only",
      "an envelope is superseded, never edited")
check(env.get("supersession_rewrites_prior_evaluations") is False,
      "superseding an envelope never rewrites evaluations made against the old one")

# --- Observation: evidence, never a conclusion ------------------------------
obs = schemas.get("capability-health-observation", {})
for field in ("observation_id", "subject_type", "subject_id", "dimension",
              "measured_value", "unit", "observed_at", "source",
              "collection_status", "provenance"):
    check(field in (obs.get("required_fields") or []), f"observation requires {field}")
check(obs.get("record_class") == "evidence",
      "an observation is evidence")
# The distinction that stops a monitoring outage manufacturing findings.
check(obs.get("collection_failure_implies_subject_failure") is False,
      "a collection failure implies nothing about the subject")
statuses = (obs.get("enums") or {}).get("collection_status") or []
for value in ("collected", "failed", "unavailable"):
    check(value in statuses, f"collection status includes {value}")
dimensions = (obs.get("enums") or {}).get("dimension") or []
for value in ("availability", "heartbeat-freshness", "latency", "queue-depth",
              "success-count", "failure-count", "cpu-utilization",
              "memory-utilization", "gpu-utilization", "vram-utilization",
              "transport-health", "collector-freshness"):
    check(value in dimensions, f"observation dimension includes {value}")
for forbidden in ("health_state", "verdict", "conclusion", "trust_state",
                  "predicted_value", "forecast", "anomaly_score", "command"):
    check(forbidden in (obs.get("forbidden_fields") or []),
          f"observation forbids {forbidden}")

# --- State: derived, deterministic, cited -----------------------------------
state = schemas.get("capability-health-state", {})
for field in ("state_id", "subject_type", "subject_id", "state", "envelope_id",
              "derived_from_observation_ids", "freshness", "reason",
              "evaluated_at", "provenance"):
    check(field in (state.get("required_fields") or []), f"health state requires {field}")
check(state.get("supersession") == "new-record-only",
      "a health state is superseded, never edited")
check(state.get("evaluation") == "deterministic",
      "health evaluation is deterministic for identical inputs")
check(state.get("default_state") == "unknown",
      "the default health state is unknown")
health_states = (state.get("enums") or {}).get("state") or []
for value in ("unknown", "unmonitored", "insufficient-policy", "healthy",
              "degraded", "unavailable", "withheld"):
    check(value in health_states, f"health state enum includes {value}")
check(len(health_states) == 7, "exactly seven health states are defined")

# Only these may support a positive claim. Everything else is an absence of
# one, and an absence must never be rendered as reassurance.
check(state.get("states_supporting_positive_claim") == ["healthy"],
      "only healthy supports a positive claim")
check(set(state.get("inert_states") or [])
      == {"unknown", "unmonitored", "insufficient-policy", "withheld"},
      "unknown, unmonitored, insufficient-policy, and withheld are inert on eligibility")
# Fresh positive evidence of an ineligible condition is the only thing that
# subtracts. An absence never clears a finding either.
check(state.get("removal_requires") == "fresh-positive-evidence",
      "removal from eligibility requires fresh positive evidence")
check(state.get("unknown_may_clear_prior_finding") is False,
      "unknown cannot clear a prior degraded or unavailable finding")
check(state.get("stale_may_support_healthy") is False,
      "stale evidence cannot support a healthy claim")

# Rendering rules. The four phrasings that convert an absence of evidence into
# a positive claim are forbidden on the record, not merely discouraged in prose.
forbidden_renderings = state.get("forbidden_renderings") or []
for phrasing in ("assumed-healthy", "probably-available", "no-known-issues",
                 "healthy-by-default"):
    check(phrasing in forbidden_renderings,
          f"health state forbids rendering unknown as {phrasing}")

# Freshness and reason are required on every state, including unknown. A state
# with neither cannot be argued with.
check(state.get("freshness_required_for_all_states") is True,
      "every health state carries freshness, including unknown")
check(state.get("reason_required_for_all_states") is True,
      "every health state carries a reason, including unknown")

# The envelope version the evaluation used, so a later supersession cannot
# change what a past assessment meant.
check("envelope_version" in (state.get("required_fields") or []),
      "health state records the envelope version it was evaluated against")
check(state.get("supersession_rewrites_prior_evaluations") is False,
      "envelope supersession never rewrites prior evaluations")

# A fresh healthy reading overrides nothing. Health subtracts; it never adds.
cannot_override = set(state.get("cannot_override") or [])
for governed in ("manual-drain", "restricted-scope", "quarantine", "revocation",
                 "availability-intent"):
    check(governed in cannot_override,
          f"a healthy state cannot override {governed}")

# withheld, corrected. It was a second name for the Fabric's availability
# intent, which left the health layer with no way to say "we are deliberately
# not asserting a conclusion".
withheld = state.get("withheld_semantics") or {}
check(withheld.get("means") == "health-conclusion-not-asserted-or-published",
      "withheld means a health conclusion is intentionally not asserted or published")
check(withheld.get("implies_healthy") is False, "withheld does not mean healthy")
check(withheld.get("implies_degraded") is False, "withheld does not mean degraded")
check(withheld.get("implies_unavailable") is False, "withheld does not mean unavailable")
check(withheld.get("removes_eligibility") is False,
      "withheld does not itself remove Fabric eligibility")
check(withheld.get("equivalent_to_do_not_select") is False,
      "withheld is not a synonym for do-not-select")
check(withheld.get("may_set_availability_intent") is False,
      "health may never set the Fabric availability intent")
check(withheld.get("availability_intent_may_influence_publication") is True,
      "Fabric availability intent may influence whether health publishes")
freshness = (state.get("enums") or {}).get("freshness") or []
check(freshness == ["current", "aging", "stale", "unknown"],
      "health state reuses the four existing freshness states")

# Eligibility effects. This is the load-bearing pair: health may subtract on
# positive evidence and may never add, and unknown does neither.
check(state.get("may_remove_from_eligibility") is True,
      "an observed unavailable state may remove a candidate")
check(state.get("may_add_to_eligibility") is False,
      "health may never add a candidate")
check(state.get("may_reorder_candidates") is False,
      "health may never reorder candidates")
check(state.get("unknown_effect_on_eligibility") == "inert",
      "unknown health neither qualifies nor disqualifies a candidate")

# --- Heartbeat: a claim, like an advertisement ------------------------------
beat = schemas.get("capability-heartbeat", {})
for field in ("heartbeat_id", "subject_type", "subject_id", "observed_at",
              "provenance"):
    check(field in (beat.get("required_fields") or []), f"heartbeat requires {field}")
check(beat.get("record_class") == "claim", "a heartbeat is a claim")
check(beat.get("confers_trust") is False, "a heartbeat confers no trust")
check(beat.get("confers_eligibility") is False, "a heartbeat confers no eligibility")
check(beat.get("absent_heartbeat_means") == "unknown-never-healthy",
      "an absent heartbeat is unknown, never healthy")

# --- Degradation: a recorded transition -------------------------------------
deg = schemas.get("capability-degradation-event", {})
for field in ("event_id", "subject_type", "subject_id", "from_state", "to_state",
              "dimension", "entry_condition", "observed_at",
              "derived_from_observation_ids", "provenance"):
    check(field in (deg.get("required_fields") or []), f"degradation event requires {field}")
check(deg.get("describes") == "observed-history-only",
      "a degradation event describes observed history, never the future")
check(deg.get("hysteresis") == "declared-required",
      "degradation transitions require declared hysteresis")

# --- Recommendation: the only output, and it is never an action -------------
rec = schemas.get("capability-health-recommendation", {})
for field in ("recommendation_id", "subject_type", "subject_id",
              "recommendation", "reason", "derived_from_state_id",
              "created_at", "provenance"):
    check(field in (rec.get("required_fields") or []), f"recommendation requires {field}")
# A closed vocabulary of exactly four. Closed rather than merely enumerated:
# an open list is one pull request away from containing "restart".
kinds = (rec.get("enums") or {}).get("recommendation") or []
check(kinds == ["investigate", "review-envelope", "verify-observation-source",
                "consider-manual-drain"],
      "recommendation vocabulary is exactly the four approved kinds")
check(rec.get("vocabulary") == "closed", "the recommendation vocabulary is closed")
for value in ("quarantine", "revoke", "trust", "approve", "broaden-scope",
              "reroute", "restart", "stop", "kill", "repair", "remediate",
              "execute", "apply"):
    check(value not in kinds, f"recommendation may never propose {value}")

check(rec.get("is_action") is False, "a recommendation is not an action")
check(rec.get("advisory_only") is True, "a recommendation is advisory only")
check(rec.get("requires_human_action") is True,
      "a recommendation requires a human to act on it")
check(rec.get("auto_execution") == "forbidden",
      "a recommendation is never executed automatically")
for field in ("review_required", "advisory_only", "created_at"):
    check(field in (rec.get("required_fields") or []),
          f"recommendation requires {field}")

# Named as forbidden fields so a future runtime cannot quietly add an execution
# surface and still pass. Each is a different way the advisory boundary breaks.
for field in ("execution_target", "command", "script", "shell", "action_payload",
              "route_id", "trust_decision_id", "auto_apply", "auto_execute",
              "auto_drain", "auto_quarantine", "mutates_route",
              "mutates_trust_state"):
    check(field in (rec.get("forbidden_fields") or []),
          f"recommendation forbids the field {field}")

# --- Ontology ---------------------------------------------------------------
types = (load("platform-model/ontology/entity-types.yaml") or {}).get("entity_types") or {}
for name, (prefix, _digits) in EXPECTED_IDS.items():
    check(name in types, f"ontology defines the {name} entity type")
    check((types.get(name) or {}).get("id_prefix") == prefix,
          f"{name} uses the {prefix} prefix")

catalog = (load("platform-model/ontology/relationship-types.yaml") or {}).get("relationship_types") or {}
for name in ("OBSERVES_HEALTH_OF", "HEALTH_STATE_OF", "EVALUATED_AGAINST",
             "RECOMMENDS_ACTION"):
    check(name in catalog, f"ontology defines the {name} relationship")

# No lease or placement entity arrives to satisfy the old reservation. There is
# nothing to observe, because v0.9.5 defined neither.
for absent in ("lease-health", "placement-health", "workload-lease", "placement"):
    check(absent not in types, f"no entity with no referent is added ({absent})")

# Health must never be a source of trust. This is the same guard the Fabric
# carries, one layer up, and it is the reason this layer is safe to build.
HEALTH_TYPES = set(EXPECTED_IDS)
for name in ("TRUSTS", "VERIFIED_BY", "APPROVED_BY"):
    sources = set((catalog.get(name) or {}).get("allowed_sources") or [])
    check(not (sources & HEALTH_TYPES),
          f"{name} does not take a health record as its source")

# A trust record must never derive from a health record. The relationship
# catalog cannot express a per-pair rule in its lists, so the constraint is
# declared explicitly and asserted here.
derived = catalog.get("DERIVED_FROM") or {}
forbidden_pairs = derived.get("forbidden_source_target_pairs") or []
joined = " ".join(str(pair) for pair in forbidden_pairs)
check("trust-record" in joined and "capability-health" in joined,
      "DERIVED_FROM forbids a trust record deriving from a health record")

# Health observes the Fabric entities that exist.
observes = catalog.get("OBSERVES_HEALTH_OF") or {}
observed_targets = set(observes.get("allowed_targets") or [])
for target in ("capability-instance", "capability-host"):
    check(target in observed_targets, f"health may observe a {target}")
check("capability-route" not in observed_targets,
      "health does not observe a route, which is policy rather than a running thing")

# --- Trust domains are still fifteen ----------------------------------------
# Health introduces no trust subject. A health record is never trusted; it is
# evidence about something that already was.
for schema_name in ("trust-record", "trust-policy"):
    schema = load(f"platform-model/schemas/{schema_name}.schema.yaml") or {}
    domains = (schema.get("enums") or {}).get("domain") or []
    if domains:
        check(len(domains) == 15, f"{schema_name} still declares fifteen trust domains")

print(f"__FAILURES__={failures}")
sys.exit(1 if failures else 0)
PY
PY_STATUS=$?
set -e
if (( PY_STATUS != 0 )); then
  FAILURES=$((FAILURES + 1))
fi

# --- Reviewer clarifications: unknown health --------------------------------
# unknown is inert on eligibility but must never be invisible. An unknown that
# nobody sees is indistinguishable from a healthy one at the moment it matters.
UNKNOWN_DOC="docs/health/unknown-and-freshness.md"
assert_file "${UNKNOWN_DOC}"
for rule in '[Ii]nert on eligibility' \
            '[Nn]ever invisible|not invisible|always visible' \
            '[Cc]annot support a (positive|healthy) claim' \
            '[Cc]annot clear' \
            '[Mm]ust carry freshness' \
            '[Mm]ust carry a reason'; do
  assert_contains "${UNKNOWN_DOC}" "${rule}" "unknown document states: ${rule}"
done

# The four phrasings an unknown must never be rendered as. Each converts an
# absence of evidence into a positive claim, which is the one thing this layer
# exists to prevent.
for phrasing in 'assumed healthy' 'probably available' 'no known issues' \
                'healthy by default'; do
  assert_contains "${UNKNOWN_DOC}" "${phrasing}" \
    "unknown document forbids the phrasing: ${phrasing}"
done

# And the worked example a future runtime must be able to produce.
for field in 'eligible_by_fabric' 'health_state' 'health_effect' 'health_warning'; do
  assert_contains "${UNKNOWN_DOC}" "${field}" \
    "unknown document shows the ${field} example field"
done

# --- Freshness ---------------------------------------------------------------
for rule in '[Ss]tale evidence cannot support' \
            '[Ss]tale.*degraded|degraded.*stale' \
            '[Cc]ollection failure is not' \
            '[Mm]issing evidence is not' \
            '[Ii]ndependently per'; do
  assert_contains "${UNKNOWN_DOC}" "${rule}" "freshness rule stated: ${rule}"
done

# A fresh healthy reading overrides nothing. Health subtracts; it never adds.
for override in '[Mm]anual drain' '[Rr]estricted' '[Qq]uarantine' '[Rr]evocation' \
                'availability intent|availability_intent'; do
  assert_contains "${UNKNOWN_DOC}" "${override}" \
    "fresh healthy cannot override ${override}"
done

# --- Envelopes and the Experience separation ---------------------------------
for rule in '[Ee]xperience' '[Cc]annot (write|author)' '[Nn]o baseline' \
            '[Ff]requent violation' '[Ii]mmutable approval'; do
  assert_contains "${ENVELOPE_DOC}" "${rule}" "envelope document states: ${rule}"
done
assert_contains "${ENVELOPE_DOC}" 'insufficient-policy' \
  "a metric with no threshold produces insufficient-policy"
assert_contains "${ENVELOPE_DOC}" '[Pp]er metric|independently per' \
  "the null policy rule applies per metric"
assert_contains "${ENVELOPE_DOC}" '[Ss]upersed' "envelope supersession is defined"
assert_contains "${ENVELOPE_DOC}" '[Bb]oth remain auditable|remain auditable' \
  "two envelope versions may yield different results, both auditable"

# --- Manual drain ------------------------------------------------------------
for rule in '[Pp]revents new selections' \
            '[Dd]oes not alter trust' \
            '[Dd]oes not quarantine' \
            '[Dd]oes not revoke' \
            '[Rr]eversible only by an explicit [Ff]abric decision' \
            '[Cc]annot be executed by [Hh]ealth'; do
  assert_contains "${GOVERNANCE_DOC}" "${rule}" "manual drain: ${rule}"
done
assert_contains "${GOVERNANCE_DOC}" 'consider-manual-drain' \
  "health may recommend considering a manual drain"

# --- withheld versus availability intent -------------------------------------
# These were the same thing. If withheld means "the operator withdrew the
# node", it is a second name for availability_intent and the health layer has
# no state of its own for "we are deliberately not asserting a conclusion".
for rule in '[Nn]ot asserted|not published' \
            '[Dd]oes not mean healthy' \
            '[Dd]oes not mean degraded' \
            '[Dd]oes not mean unavailable' \
            '[Dd]oes not itself remove' \
            '[Nn]ot a synonym for do-not-select'; do
  assert_contains "${STATES_DOC}" "${rule}" "withheld: ${rule}"
done
assert_contains "${STATES_DOC}" '[Hh]ealth cannot set' \
  "health cannot set the Fabric availability intent"

# --- Selection visibility ----------------------------------------------------
SELECTION_DOC="docs/health/selection-visibility.md"
assert_file "${SELECTION_DOC}"
for exposure in '[Hh]ealth state' '[Ff]reshness' '[Ww]hether [Hh]ealth changed eligibility' \
                '[Ee]xplanation' '[Ee]nvelope version' '[Ww]arning'; do
  assert_contains "${SELECTION_DOC}" "${exposure}" \
    "future selection must expose ${exposure}"
done
assert_contains "${SELECTION_DOC}" '[Nn]ever silently disappear|must never silently' \
  "health may never silently disappear from a selection explanation"

# --- No aggregate score ------------------------------------------------------
# Named individually because each is a different spelling of the same mistake:
# a threshold nobody chose becoming the operational boundary.
for score in 'health_score' 'aggregate_score' 'composite_score' \
             'weighted_health' 'overall_numeric_health'; do
  assert_contains "${ADR}" "${score}" "ADR-0013 forbids the field ${score}"
done
assert_contains "${ADR}" '[Nn]o aggregate' "ADR-0013 forbids an aggregate health score"

# --- The fifteen stated principles -------------------------------------------
assert_contains "${ADR}" '^### Principles' "ADR-0013 states its principles under a heading"
for principle in '[Uu]nknown is inert on eligibility but always visible' \
                 '[Uu]nknown cannot support a positive claim' \
                 '[Hh]ealth state is inseparable from freshness' \
                 'only on fresh positive evidence' \
                 '[Hh]ealth cannot grant eligibility' \
                 '[Cc]ollection failure is not capability failure' \
                 '[Tt]hresholds are human-declared' \
                 '[Ee]xperience may inform an operator but cannot author policy' \
                 '[Hh]ealth has no aggregate score' \
                 '[Hh]ealth observations are not [Tt]rust evidence by default' \
                 '[Hh]ealth history is append-only' \
                 '[Ee]nvelope supersession never rewrites prior evaluations' \
                 '[Ww]ithheld is distinct from [Ff]abric availability intent' \
                 '[Mm]anual drain is [Ff]abric-local and operator-controlled'; do
  assert_contains "${ADR}" "${principle}" "ADR-0013 principle: ${principle}"
done

# --- Accepted consequences ---------------------------------------------------
for consequence in 'unmonitored capability may remain eligible' \
                   '[Mm]issing monitoring must remain conspicuous' \
                   '[Dd]eclared thresholds may initially be imperfect' \
                   '[Hh]uman approval remains a bottleneck' \
                   'without controlling admission'; do
  assert_contains "${ADR}" "${consequence}" "ADR-0013 accepts: ${consequence}"
done

# --- Roadmap -----------------------------------------------------------------
assert_contains "${ROADMAP}" 'v0\.9\.6 — Capability Health Monitor' "roadmap keeps the v0.9.6 heading"
assert_contains "${ROADMAP}" 'ADR-0013' "roadmap cites ADR-0013"
assert_contains "${ROADMAP}" '[Hh]ealth never grants trust' "roadmap keeps the governing principle"

# --- Summary -----------------------------------------------------------------
if (( FAILURES == 0 )); then
  printf '\nAll capability health assertions passed.\n'
else
  printf '\n%d capability health assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
