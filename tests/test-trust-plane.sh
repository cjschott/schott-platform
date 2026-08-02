#!/usr/bin/env bash
set -Eeuo pipefail

# Static and documentation validation for the Trust Plane architecture.
#
# THIS SPRINT DEFINES ARCHITECTURE ONLY. There is no runtime implementation,
# and this suite asserts that: no trust engine, no enrollment path, no
# certificate handling, no approval workflow, no fabric. A future engineer must
# be able to implement the Trust Plane from ADR-0011 and the schemas without
# inventing behaviour — so the assertions here are about completeness of the
# specification as much as about safety.
#
# Nothing here contacts a host, reads a credential, or executes a transport.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADR="docs/decisions/ADR-0011-trust-plane.md"
TRUST_DOC="docs/trust/trust-plane.md"
DOMAIN_DOC="docs/trust/trust-domains.md"
STATE_DOC="docs/trust/trust-states.md"
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
assert_file "${TRUST_DOC}"
assert_file "${DOMAIN_DOC}"
assert_file "${STATE_DOC}"
for schema in trust-record trust-decision trust-authority trust-policy; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- No implementation exists ------------------------------------------------
# This is the sprint's defining constraint. Trust is specified here and built
# later; a half-built trust engine is worse than none, because it looks like a
# control while behaving like a suggestion.
for forbidden_dir in tools/trust tools/fabric tools/capability tools/enrollment; do
  if [[ -e "${ROOT}/${forbidden_dir}" ]]; then
    fail "no implementation belongs in this sprint: ${forbidden_dir} exists"
  else
    pass "no implementation directory: ${forbidden_dir}"
  fi
done

if compgen -G "${ROOT}/platform-model/trust/TRUST-*" >/dev/null 2>&1; then
  fail "no trust runtime records belong in the repository"
else
  pass "no trust runtime records exist"
fi

# The schemas are declarations, not code. No executable trust logic anywhere.
assert_absent_in "platform-model/schemas" \
  '(def [a-z_]+\(|import |lambda |subprocess|ssh-keyscan)' \
  "trust schemas contain no executable logic"

# --- ADR-0011 structure ------------------------------------------------------
assert_contains "${ADR}" '^# ADR-0011:' "ADR-0011 has the expected title"
assert_contains "${ADR}" '\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0011 is Accepted"
for section in Context Decision "Rejected Alternatives" Consequences Related; do
  assert_contains "${ADR}" "^## ${section}" "ADR-0011 contains ${section}"
done

# The governing directionality. Reasoning may consume trust; trust must never
# consume reasoning, or a model could talk the platform into trusting something.
assert_contains "${ADR}" '[Tt]rust never consumes reasoning' \
  "ADR-0011 states that trust never consumes reasoning"
assert_contains "${ADR}" '[Rr]easoning may consume trust' \
  "ADR-0011 states that reasoning may consume trust"
assert_contains "${ADR}" '[Kk]yri shall never silently trust anything|never silently trust' \
  "ADR-0011 states that nothing is silently trusted"

# --- The ten design principles ----------------------------------------------
for principle in "[Tt]rust is explicit" "[Tt]rust is immutable" \
                 "[Tt]rust is reviewable" "[Tt]rust is explainable" \
                 "[Tt]rust is revocable" "[Tt]rust is versioned" \
                 "[Tt]rust never auto-enrolls" "[Tt]rust never auto-recovers" \
                 "[Tt]rust never assumes" "[Tt]rust always has provenance"; do
  assert_contains "${ADR}" "${principle}" "ADR-0011 records the principle: ${principle}"
done

# --- The fifteen defined concepts -------------------------------------------
for concept in "Trust Authority" "Trust Decision" "Trust Record" "Trust State" \
               "Trust Source" "Trust Verification" "Trust Revocation" \
               "Trust Scope" "Trust Domain" "Trust Boundary" "Trust Evidence" \
               "Trust Approval" "Trust Expiration" "Trust Review" "Trust History"; do
  assert_contains "${ADR}" "${concept}" "ADR-0011 defines ${concept}"
done

# --- The eight trust states --------------------------------------------------
for state in Unknown Pending Trusted Restricted Quarantined Revoked Expired Rejected; do
  assert_contains "${ADR}" "${state}" "ADR-0011 defines the ${state} state"
  assert_contains "${STATE_DOC}" "${state}" "the state document defines ${state}"
done

# Unknown must be the default. A default of anything else is trust on first use
# wearing a different name.
assert_contains "${ADR}" '[Uu]nknown is the default|default(s)? to [Uu]nknown|[Dd]efault state.*[Uu]nknown' \
  "ADR-0011 makes Unknown the default state"

# --- The fifteen trust domains ----------------------------------------------
for domain in "Host Trust" "SSH Host Keys" "Certificates" "Users" \
              "Collector Plugins" "Capability Packages" "Models" \
              "Model Adapters" "Prompt Bundles" "Embedding Models" "Indexes" \
              "Policies" "Configuration Snapshots" "Remote Transports" \
              "Fabric Nodes"; do
  assert_contains "${DOMAIN_DOC}" "${domain}" "the domain document covers ${domain}"
done

# --- The eleven recorded elements of every decision -------------------------
for element in Identifier Actor Timestamp Reason Evidence "Verification Method" \
               "Approval Source" Scope Expiration "Current State" History; do
  assert_contains "${ADR}" "${element}" "ADR-0011 requires every decision to record ${element}"
done

# --- Explicitly forbidden behaviours ----------------------------------------
# Each of these is individually convenient, which is exactly why each is named.
for forbidden in "[Aa]utomatic trust" "[Tt]rust on first use" \
                 "[Aa]utomatic ssh-keyscan" "[Aa]utomatic known_hosts" \
                 "[Aa]utomatic certificate acceptance" \
                 "[Aa]utomatic model approval" \
                 "[Aa]utomatic capability approval" \
                 "[Aa]utomatic policy changes" "[Aa]utomatic recovery"; do
  assert_contains "${ADR}" "${forbidden}" "ADR-0011 forbids ${forbidden}"
done
assert_contains "${TRUST_DOC}" '[Tt]rust on first use' \
  "the trust plane document names trust on first use as forbidden"

# --- Roadmap -----------------------------------------------------------------
ROADMAP="docs/platform-roadmap.md"
assert_contains "${ROADMAP}" '^### v0\.9\.2 — Trust Plane' "roadmap records v0.9.2 Trust Plane"
assert_contains "${ROADMAP}" 'v0\.9\.5 — Distributed Capability Fabric' \
  "roadmap preserves the v0.9.5 Fabric reservation"
assert_contains "${ROADMAP}" 'v1\.0\.0 — Kyri Core Foundation' "roadmap preserves v1.0.0"

# The Fabric cannot begin until the Trust Plane exists. Asserted as a stated
# gate, not merely implied by ordering.
assert_contains "${ROADMAP}" '[Cc]annot begin until.*[Tt]rust [Pp]lane|[Bb]locked until.*[Tt]rust [Pp]lane' \
  "roadmap gates the Distributed Capability Fabric on the Trust Plane"

# Ordering: v0.9.0 < v0.9.2 < v0.9.5 < v1.0.0, by line number. Four entries can
# all exist and still be in the wrong sequence.
roadmap_order="$(grep -nE '^### (v0\.9\.0|v0\.9\.2|v0\.9\.5|v1\.0\.0) — ' "${ROOT}/${ROADMAP}" \
  | cut -d: -f1 | tr '\n' ' ')"
read -r line_090 line_092 line_095 line_100 <<<"${roadmap_order}"
if [[ -n "${line_090}" && -n "${line_092}" && -n "${line_095}" && -n "${line_100}" ]] \
   && (( line_090 < line_092 && line_092 < line_095 && line_095 < line_100 )); then
  pass "roadmap orders v0.9.0 before v0.9.2 before v0.9.5 before v1.0.0"
else
  fail "roadmap must order v0.9.0, v0.9.2, v0.9.5, v1.0.0 (found lines: ${roadmap_order})"
fi

# v0.9.2 is a reservation in this release: architecture only.
if [[ -d "${ROOT}/tools/trust" ]]; then
  fail "v0.9.2 is an architecture reservation; no trust implementation belongs here"
else
  pass "v0.9.2 remains an architecture reservation with no implementation"
fi

# --- CI and local validation wiring -----------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-trust-plane\.sh' \
  "ci runs the trust plane suite"
assert_contains "tools/dev/run-validation.sh" 'tests/test-trust-plane\.sh' \
  "local validation runs the trust plane suite"

# --- Schema and ontology validation -----------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  TRUST_OUTPUT="$(python3 - "${ROOT}" <<'TRUSTPY' 2>&1 || true
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
failures = 0


def check(condition, message):
    global failures
    if condition:
        print(f"PASS: {message}")
    else:
        failures += 1
        print(f"FAIL: {message}")


def load(rel):
    return yaml.safe_load((root / rel).read_text(encoding="utf-8"))


# --- Ontology -------------------------------------------------------------
entities = load("platform-model/ontology/entity-types.yaml")
types = entities.get("entity_types") or {}
EXPECTED_PREFIX = {
    "trust-record": "TRUST",
    "trust-decision": "TDEC",
    "trust-authority": "TAUTH",
    "trust-policy": "TPOL",
}
for name, prefix in EXPECTED_PREFIX.items():
    check(name in types, f"ontology defines the {name} entity type")
    check((types.get(name) or {}).get("id_prefix") == prefix,
          f"{name} uses the {prefix} prefix")

rels = load("platform-model/ontology/relationship-types.yaml")
catalog = rels.get("relationship_types") or {}
for name in ("TRUSTS", "VERIFIED_BY", "APPROVED_BY", "REVOKES", "SUPERSEDES",
             "DERIVED_FROM", "PROTECTED_BY"):
    check(name in catalog, f"ontology defines the {name} relationship")

# Trust must never point at reasoning. A relationship allowing a trust record
# to take a knowledge or experience record as its source would let inference
# manufacture its own authority.
REASONING_TYPES = {"knowledge-event", "knowledge-state", "experience-profile",
                   "operational-baseline", "pattern", "occurrence-series"}
for name in ("TRUSTS", "VERIFIED_BY", "APPROVED_BY"):
    sources = set((catalog.get(name) or {}).get("allowed_sources") or [])
    check(not (sources & REASONING_TYPES),
          f"{name} does not take a reasoning record as its source")

# No fabric vocabulary arrives early: that is v0.9.5, gated on this release.
for premature in ("PLACES_WORKLOAD", "LEASES", "SCHEDULES_ON"):
    check(premature not in catalog,
          f"no capability-fabric relationship is added early ({premature})")

# --- Schemas --------------------------------------------------------------
SCHEMAS = {
    "trust-record": ("TRUST", 6),
    "trust-decision": ("TDEC", 6),
    "trust-authority": ("TAUTH", 4),
    "trust-policy": ("TPOL", 4),
}
for name, (prefix, width) in SCHEMAS.items():
    schema = load(f"platform-model/schemas/{name}.schema.yaml")
    check(schema.get("schema_for") == name, f"{name} schema declares its subject")
    check(schema.get("id_pattern") == f"^{prefix}-[0-9]{{{width}}}$",
          f"{name} schema uses a {width}-digit {prefix} identifier")

    # Immutability is the property the whole plane rests on. An editable trust
    # record is an audit trail that can be rewritten after the fact.
    check(schema.get("mutability") == "immutable", f"{name} schema is immutable")
    check(schema.get("update_methods") == "none", f"{name} schema defines no update method")
    check(schema.get("delete_methods") == "none", f"{name} schema defines no delete method")
    check(schema.get("supersession") == "new-record-only",
          f"{name} schema supersedes by new record only")
    check(schema.get("review_required") is True, f"{name} schema requires review")

    # No trust record may carry credential material or an automation switch.
    forbidden = schema.get("forbidden_fields") or []
    for field in ("private_key", "password", "passphrase", "token", "secret",
                  "auto_enroll", "trust_on_first_use", "auto_approve"):
        check(field in forbidden, f"{name} schema forbids a {field} field")

record = load("platform-model/schemas/trust-record.schema.yaml")
for field in ("record_id", "domain", "subject_identifier", "subject_fingerprint",
              "state", "scope", "trust_authority_id", "decision_id",
              "created_at", "provenance"):
    check(field in (record.get("required_fields") or []),
          f"trust-record schema requires {field}")

# Every trust decision records all eleven elements.
decision = load("platform-model/schemas/trust-decision.schema.yaml")
required = decision.get("required_fields") or []
for field in ("decision_id", "record_id", "actor", "decided_at", "reason",
              "evidence", "verification_method", "approval_source", "scope",
              "expiration", "resulting_state", "previous_state",
              "history_reference"):
    check(field in required, f"trust-decision schema requires {field}")

# The eight states, defined once and referenced everywhere.
STATES = ["unknown", "pending", "trusted", "restricted", "quarantined",
          "revoked", "expired", "rejected"]
state_enum = ((record.get("enums") or {}).get("state")) or []
for state in STATES:
    check(state in state_enum, f"trust-record schema enumerates the {state} state")
check(record.get("default_state") == "unknown",
      "trust-record schema defaults to unknown")

policy = load("platform-model/schemas/trust-policy.schema.yaml")
for field in ("policy_id", "domain", "default_state", "permitted_transitions",
              "expiration_required", "verification_methods", "review_interval_days"):
    check(field in (policy.get("required_fields") or []),
          f"trust-policy schema requires {field}")
check(policy.get("automatic_transitions") == "not-permitted",
      "trust-policy schema forbids automatic transitions")

authority = load("platform-model/schemas/trust-authority.schema.yaml")
for field in ("authority_id", "name", "domains", "permitted_states",
              "approval_requirements", "review_interval_days"):
    check(field in (authority.get("required_fields") or []),
          f"trust-authority schema requires {field}")
check(authority.get("self_approval") == "not-permitted",
      "trust-authority schema forbids self-approval")

# The fifteen domains are enumerated in one place so a new domain cannot be
# introduced by a document alone.
DOMAINS = ["host", "ssh-host-key", "certificate", "user", "collector-plugin",
           "capability-package", "model", "model-adapter", "prompt-bundle",
           "embedding-model", "index", "policy", "configuration-snapshot",
           "remote-transport", "fabric-node"]
domain_enum = ((record.get("enums") or {}).get("domain")) or []
for domain in DOMAINS:
    check(domain in domain_enum, f"trust-record schema enumerates the {domain} domain")

print(f"__FAILURES__={failures}")
TRUSTPY
)"
  printf '%s\n' "${TRUST_OUTPUT}" | grep -v '^__FAILURES__=' || true
  TRUST_FAILURES="$(printf '%s\n' "${TRUST_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${TRUST_FAILURES}" ]]; then
    fail "trust plane schema validation did not report a result"
  else
    FAILURES=$((FAILURES + TRUST_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the trust plane tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nTrust plane validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nTrust plane validation passed.\n'
