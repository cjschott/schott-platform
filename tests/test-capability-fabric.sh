#!/usr/bin/env bash
set -Eeuo pipefail

# Static and documentation validation for the Distributed Capability Fabric.
#
# THIS SPRINT DEFINES ARCHITECTURE ONLY. There is no runtime implementation,
# and this suite asserts that: no fabric engine, no registry service, no
# scheduler, no placement, no networking, no execution, no remediation. A
# future engineer must be able to implement the Fabric from ADR-0012 and the
# eight schemas without inventing behaviour, so the assertions here are about
# completeness of the specification as much as about safety.
#
# Nothing here contacts a host, reads a credential, or executes a transport.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ADR="docs/decisions/ADR-0012-distributed-capability-fabric.md"
FABRIC_DOC="docs/fabric/capability-fabric.md"
LIFECYCLE_DOC="docs/fabric/capability-lifecycle.md"
IDENTITY_DOC="docs/fabric/capability-identity.md"
ROUTING_DOC="docs/fabric/capability-routing.md"
NODE_DOC="docs/fabric/node-model.md"
FAILURE_DOC="docs/fabric/failure-behaviour.md"
GOVERNANCE_DOC="docs/fabric/governance-boundaries.md"
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
for doc in "${FABRIC_DOC}" "${LIFECYCLE_DOC}" "${IDENTITY_DOC}" "${ROUTING_DOC}" \
           "${NODE_DOC}" "${FAILURE_DOC}" "${GOVERNANCE_DOC}"; do
  assert_file "${doc}"
done

FABRIC_SCHEMAS=(capability-definition capability-contract capability-package
                capability-host capability-advertisement capability-instance
                capability-route capability-selection)
for schema in "${FABRIC_SCHEMAS[@]}"; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- ADR structure -----------------------------------------------------------
assert_contains "${ADR}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0012 is accepted"
for section in '^## Context' '^## Decision' '^## Rejected Alternatives' '^## Consequences'; do
  assert_contains "${ADR}" "${section}" "ADR-0012 contains ${section#^## }"
done

# The ADR must say, in its own text, that it ships no runtime. Every prior
# architecture-only release in this platform made that claim explicit rather
# than leaving it to be inferred from an empty directory.
assert_contains "${ADR}" '[Aa]rchitecture only' "ADR-0012 declares itself architecture only"
assert_contains "${ADR}" '[Nn]o runtime implementation' "ADR-0012 declares no runtime implementation"

# --- The nine required definitions -------------------------------------------
# Each is defined in the ADR as a bolded term, so a reader can find the
# definition rather than reconstructing it from usage.
for term in "Capability Package" "Capability Advertisement" "Capability Instance" \
            "Capability Host" "Capability Route" "Capability Health" \
            "Capability Selection" "Capability Contract"; do
  assert_contains "${ADR}" "\*\*${term}\.\*\*" "ADR-0012 defines ${term}"
done
assert_contains "${ADR}" '\*\*Capability\.\*\*' "ADR-0012 defines Capability"

# --- The twelve required questions -------------------------------------------
# Answered under headings, so a future engineer can find the answer to the
# question they actually have.
for question in "How nodes discover capabilities" \
                "How capabilities are trusted" \
                "How routing occurs" \
                "How capability loss is handled" \
                "How version negotiation works" \
                "How governance remains centralized" \
                "How trust decisions flow" \
                "How capabilities expire" \
                "How capability supersession works" \
                "How capability identity survives host migration" \
                "How one capability executes on multiple hosts" \
                "How heterogeneous hardware is represented"; do
  assert_contains "${ADR}" "^### ${question}" "ADR-0012 answers: ${question}"
done

# --- Core principles ---------------------------------------------------------
assert_contains "${ADR}" 'No machine is Kyri' "ADR-0012 preserves: no machine is Kyri"
assert_contains "${ADR}" 'No model is Kyri' "ADR-0012 preserves: no model is Kyri"
assert_contains "${ADR}" '[Tt]rust precedes capability' "ADR-0012 states trust precedes capability"
assert_contains "${ADR}" '[Hh]ealth never overrides trust' "ADR-0012 states health never overrides trust"
assert_contains "${ADR}" '[Gg]overnance remains centralized' "ADR-0012 states governance remains centralized"

# Directionality, extended one layer. ADR-0011 forbade reasoning from producing
# trust; the fabric adds two more sources that must not: a node's self-report
# and an execution result.
assert_contains "${ADR}" '[Aa] node.s self-report is not trust' \
  "ADR-0012 restates that a node's self-report is not trust"
assert_contains "${ADR}" '[Tt]rust never consumes' \
  "ADR-0012 preserves the ADR-0011 directionality rule"

# The Fabric must not have invented a sixteenth trust domain. Capability
# packages and fabric nodes were reserved by ADR-0011 for exactly this.
assert_contains "${ADR}" '[Nn]o new trust domain' \
  "ADR-0012 adds no new trust domain"
assert_contains "${ADR}" 'capability-package' "ADR-0012 uses the capability-package trust domain"
assert_contains "${ADR}" 'fabric-node' "ADR-0012 uses the fabric-node trust domain"

# --- The runtime gate terminates at Operator Root Authority -------------------
# Fabric implementation is gated by establishment of the Operator Root
# Authority and the released-defect sprint, not by TrustGateway cutover.
assert_contains "${ADR}" '[Dd]eployment gate' "ADR-0012 preserves the deployment gate"
assert_contains "${ADR}" 'Operator Root Authority' "ADR-0012 terminates at the Operator Root Authority"

# --- Explicitly forbidden ----------------------------------------------------
for forbidden in "[Nn]o automatic node registration" \
                 "[Nn]o trust on first advertisement" \
                 "[Nn]o self-admission" \
                 "[Nn]o peer discovery" \
                 "[Nn]o automatic remediation" \
                 "[Nn]o automatic failover outside the declared" \
                 "[Nn]o prediction" \
                 "[Nn]o load-based routing" \
                 "[Nn]o quorum" \
                 "[Nn]o leader election"; do
  assert_contains "${ADR}" "${forbidden}" "ADR-0012 forbids: ${forbidden}"
done

# TOFU by any name. The fabric's version of it is believing the first
# advertisement a host sends, which is the same mistake with a new spelling.
assert_contains "${ADR}" '[Tt]rust on first use' "ADR-0012 names trust on first use as forbidden"

# --- Effect classes: the door for robotics is open and closed ----------------
# A future actuating capability must not arrive under the governance written
# for text generation. The slot exists; nothing may route to it yet.
for effect in 'read-only' 'computational' 'content-generating' 'side-effecting'; do
  assert_contains "${ADR}" "${effect}" "ADR-0012 defines the ${effect} effect class"
done
assert_contains "${ADR}" '^### Effect classes' "ADR-0012 defines effect classes under a heading"
assert_contains "${ADR}" '[Uu]nroutable|may not be routed|no route may select' \
  "ADR-0012 states side-effecting is unroutable"

# Enabling actuation later must cost something. Naming the price here is what
# stops it being paid by accident in a pull request that looks like a model.
for requirement in '[Nn]ew ADR' '[Aa]pproval model' '[Ee]ffect authorization' \
                   '[Rr]emediation boundaries' '[Aa]udit requirements' \
                   '[Hh]uman approval semantics'; do
  assert_contains "${ADR}" "${requirement}" \
    "ADR-0012 requires ${requirement} before side-effecting is enabled"
done

# --- The named hosts are records, never code ---------------------------------
# The sprint must support MainPC, schai, and schoxmox1 without any of them
# existing in a schema, an ontology entry, or a rule.
assert_contains "${NODE_DOC}" 'MainPC' "node model works the MainPC example"
assert_contains "${NODE_DOC}" 'schai' "node model works the schai example"
assert_contains "${NODE_DOC}" 'schoxmox1' "node model works the schoxmox1 example"
assert_contains "${NODE_DOC}" '[Cc]loud' "node model covers future cloud nodes"

for schema in "${FABRIC_SCHEMAS[@]}"; do
  assert_absent_in "platform-model/schemas/${schema}.schema.yaml" \
    '(MainPC|schoxmox1|\bRTX\b|Tesla|5070|4060|\bP4\b)' \
    "${schema} schema hardcodes no host or hardware model"
done
for ontology in entity-types relationship-types; do
  assert_absent_in "platform-model/ontology/${ontology}.yaml" \
    '(MainPC|schoxmox1|\bRTX\b|Tesla|5070|4060)' \
    "${ontology} hardcodes no host or hardware model"
done

# --- Only the ENG-0004 fabric package, no networking, no execution -----------
# ADR-0012 remains architecture. ENG-0004 implements the fabric runtime, so
# `tools/fabric` is permitted; every other runtime package still is not.
for forbidden_dir in tools/capability tools/scheduler tools/placement \
                     tools/clustering tools/routing; do
  if [[ -d "${ROOT}/${forbidden_dir}" ]]; then
    fail "only the ENG-0004 fabric package may exist; ${forbidden_dir} must not"
  else
    pass "no implementation directory: ${forbidden_dir}"
  fi
done

# The schemas describe records. They must not smuggle in an execution surface.
for schema in "${FABRIC_SCHEMAS[@]}"; do
  assert_absent_in "platform-model/schemas/${schema}.schema.yaml" \
    '^[[:space:]]*(command|argv|entrypoint|ssh_command|docker_run|exec):' \
    "${schema} schema declares no execution surface"
done

# --- Schema invariants -------------------------------------------------------
set +e
python3 - "${ROOT}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


try:
    import yaml
except ImportError:  # pragma: no cover - CI installs PyYAML explicitly
    print("FAIL: PyYAML is required for capability fabric schema validation",
          file=sys.stderr)
    sys.exit(1)


def load(relative):
    path = root / relative
    if not path.is_file():
        return None
    return yaml.safe_load(path.read_text())


# --- Identifier scheme ------------------------------------------------------
# Human-declared records carry four digits; machine-generated records carry
# six, matching the convention ADR-0011 established for trust records.
EXPECTED_IDS = {
    "capability-definition": ("CAPDEF", 4),
    "capability-contract": ("CCON", 4),
    "capability-package": ("CPKG", 4),
    "capability-host": ("CHOST", 4),
    "capability-route": ("CROUTE", 4),
    "capability-advertisement": ("CADV", 6),
    "capability-instance": ("CINST", 6),
    "capability-selection": ("CSEL", 6),
}

schemas = {}
for name, (prefix, digits) in EXPECTED_IDS.items():
    schema = load(f"platform-model/schemas/{name}.schema.yaml")
    check(schema is not None, f"{name} schema loads")
    if schema is None:
        continue
    schemas[name] = schema
    check(schema.get("schema_for") == name, f"{name} schema declares schema_for")
    check(schema.get("id_pattern") == f"^{prefix}-[0-9]{{{digits}}}$",
          f"{name} uses the {prefix}-{'0' * digits} identifier pattern")
    provenance = schema.get("provenance") or {}
    check(provenance.get("source") == "docs/decisions/ADR-0012-distributed-capability-fabric.md",
          f"{name} schema cites ADR-0012 as its source")

# --- Immutability -----------------------------------------------------------
# Advertisements, instances, and selections are records of what was claimed,
# admitted, and chosen. Editing any of them rewrites the audit trail.
for name in ("capability-advertisement", "capability-instance", "capability-selection"):
    schema = schemas.get(name, {})
    check(schema.get("mutability") == "immutable", f"{name} is immutable")
    check(schema.get("update_methods") == "none", f"{name} has no update method")
    check(schema.get("delete_methods") == "none", f"{name} has no delete method")
    check(schema.get("supersession") == "new-record-only",
          f"{name} changes only by supersession")

# --- Advertisement: a claim, never a grant ----------------------------------
adv = schemas.get("capability-advertisement", {})
check(adv.get("confers_trust") is False,
      "an advertisement explicitly confers no trust")
check(adv.get("record_class") == "claim",
      "an advertisement is classified as a claim, not as evidence of trust")
for field in ("advertisement_id", "capability_host_id", "capability_package_id",
              "contract_id", "satisfied_contract_versions",
              "advertised_resource_profile", "observed_at", "valid_until",
              "provenance"):
    check(field in (adv.get("required_fields") or []),
          f"advertisement requires {field}")
# A host may describe itself. It may not describe its own standing.
for field in ("trust_state", "trusted", "trust_score", "auto_admit", "auto_enroll",
              "auto_approve", "scope_grant", "admitted", "admission_decision_id",
              "route_id", "priority", "token", "secret", "credential", "command"):
    check(field in (adv.get("forbidden_fields") or []),
          f"advertisement forbids {field}")

# --- Instance: the composed, admitted binding --------------------------------
inst = schemas.get("capability-instance", {})
for field in ("instance_id", "capability_id", "capability_package_id",
              "capability_host_id", "contract_id", "satisfied_contract_versions",
              "verified_resource_profile", "admission_decision_id",
              "package_trust_record_id", "host_trust_record_id",
              "effective_scope", "admitted_at", "admitted_until", "provenance"):
    check(field in (inst.get("required_fields") or []),
          f"instance requires {field}")

# Eligibility is a conjunction. Each condition is declared so an implementation
# cannot quietly drop one and still call the result eligible.
eligibility = inst.get("eligibility_conditions") or []
check(len(eligibility) >= 8,
      "instance declares every eligibility condition (at least eight)")
joined = " ".join(str(item) for item in eligibility).lower()
for requirement in ("package", "host", "contract", "resource", "advertisement",
                    "admission", "scope", "classification",
                    # Quarantine and drain are separate conditions: one is a
                    # trust judgement, the other an operator's deliberate
                    # withdrawal, and reporting either as the other destroys a
                    # distinction an operator needs during an incident.
                    "quarantin", "drain", "effect class", "version", "route"):
    check(requirement in joined,
          f"instance eligibility covers {requirement}")

check(inst.get("default_eligibility") == "ineligible",
      "an instance is ineligible by default and fails closed")
check(inst.get("scope_composition") == "intersection",
      "instance scope is the intersection of package, host, and admission scope")
check(inst.get("trust_inheritance") == "forbidden",
      "an instance inherits trust from neither its package nor its host")

# --- Host: identity, not hardware -------------------------------------------
host = schemas.get("capability-host", {})
for field in ("capability_host_id", "node_identity_reference",
              "fabric_node_trust_record_id", "verified_resource_profile",
              "location_class", "data_classification",
              "availability_intent", "provenance"):
    check(field in (host.get("required_fields") or []),
          f"capability host requires {field}")
for field in ("auto_register", "auto_enroll", "self_admit", "trust_on_first_use",
              "trust_score", "private_key", "password", "token", "credential"):
    check(field in (host.get("forbidden_fields") or []),
          f"capability host forbids {field}")

# Heterogeneous hardware is a controlled vocabulary, not free text, and it is
# expressed in terms no vendor owns.
profile = host.get("resource_profile_vocabulary") or {}
for attribute in ("accelerator_class", "accelerator_memory_mb", "host_memory_mb",
                  "host_cpu_cores", "architecture"):
    check(attribute in profile, f"resource profile vocabulary defines {attribute}")
accelerator_classes = (profile.get("accelerator_class") or {}).get("values") or []
for value in ("none", "integrated-gpu", "discrete-gpu", "dedicated-accelerator",
              "remote-service"):
    check(value in accelerator_classes,
          f"accelerator class vocabulary includes {value}")

location_classes = (host.get("enums") or {}).get("location_class") or []
for value in ("on-premises", "operator-controlled-remote", "third-party-hosted"):
    check(value in location_classes, f"location class includes {value}")

# --- Contract: the versioned interface --------------------------------------
contract = schemas.get("capability-contract", {})
for field in ("contract_id", "capability_id", "contract_version", "effect_class",
              "request_shape", "response_shape", "failure_modes",
              "determinism_class", "compatible_with", "provenance"):
    check(field in (contract.get("required_fields") or []),
          f"contract requires {field}")
effect_classes = (contract.get("enums") or {}).get("effect_class") or []
for value in ("read-only", "computational", "content-generating", "side-effecting"):
    check(value in effect_classes, f"effect class includes {value}")
check(len(effect_classes) == 4, "exactly four effect classes are defined")

# Compatibility is declared, never inferred. A platform that reads meaning into
# a version number has guessed, and it will guess wrong during an upgrade.
check(contract.get("version_compatibility") == "declared-only",
      "contract compatibility is declared, never inferred from version numbers")
check(contract.get("routable_effect_classes")
      == ["read-only", "computational", "content-generating"],
      "no route may select a side-effecting contract in this architecture")
check("side-effecting" not in (contract.get("routable_effect_classes") or []),
      "side-effecting is representable but unroutable")
check(contract.get("effect_class_override") == "forbidden",
      "no route or selection may override the side-effecting prohibition")

check(set(effect_classes) - set(contract.get("routable_effect_classes") or [])
      == {"side-effecting"},
      "side-effecting is the only effect class that is not routable")

# A contract describes an interface, not a machine. Binding one to a host would
# make the interface unrepeatable somewhere else.
check(contract.get("host_bound") is False, "a contract is not host-bound")
check("resource_requirements" in (contract.get("required_fields") or []),
      "contract declares the resource requirements of its interface")

# --- Package: the trust subject ---------------------------------------------
package = schemas.get("capability-package", {})
for field in ("capability_package_id", "capability_id", "contract_id",
              "satisfied_contract_versions", "package_version",
              "artifact_reference", "resource_requirements",
              "trust_domain", "provenance"):
    check(field in (package.get("required_fields") or []),
          f"package requires {field}")
check(package.get("trust_domain") == "capability-package",
      "a package is a subject in the capability-package trust domain")
check(package.get("approval") == "requires-new-decision-per-version",
      "each package version is a new trust subject requiring its own decision")
check(package.get("implements") == "one-definition-one-contract",
      "a package implements exactly one capability definition and contract")

# --- Host: reachability is not standing -------------------------------------
check(host.get("reachability_implies_trust") is False,
      "reachability implies no trust")
check(host.get("reachability_implies_admission") is False,
      "reachability implies no admission")

# --- Advertisement: registered by an admitted subject, then queryable -------
# The ordering matters. An advertisement from a subject that has not been
# admitted is not a pending application; it is not a record at all.
check(adv.get("requires_admitted_subject") is True,
      "only an admitted subject may register an advertisement")
check(adv.get("queryable_after") == "admission",
      "an advertisement becomes queryable only after admission")
check(adv.get("may_modify_trust_state") is False,
      "an advertisement may never modify trust state")
check(adv.get("unsolicited") == "rejected",
      "an unsolicited advertisement is rejected")

# --- Route: declared, deterministic, explainable -----------------------------
route = schemas.get("capability-route", {})
for field in ("route_id", "route_version", "capability_id", "contract_id",
              "accepted_contract_versions", "locality", "candidate_instances",
              "data_classification", "provenance"):
    check(field in (route.get("required_fields") or []),
          f"route requires {field}")
check(route.get("candidate_order") == "declared-explicit",
      "route candidate order is declared, never computed")
check(route.get("selection_determinism") == "deterministic",
      "routing is deterministic for identical inputs")
check(route.get("fallback") == "declared-candidates-only",
      "fallback never leaves the declared candidate list")
check(route.get("on_no_eligible_candidate") == "refuse",
      "a route with no eligible candidate refuses rather than degrades")
locality = (route.get("enums") or {}).get("locality") or []
for value in ("local-only", "operator-controlled-only", "any-trusted"):
    check(value in locality, f"route locality includes {value}")
for field in ("weight", "load_factor", "latency_score", "priority_score",
              "auto_failover", "auto_scale", "capacity_forecast"):
    check(field in (route.get("forbidden_fields") or []),
          f"route forbids {field}")

# --- Selection: why did this run there --------------------------------------
selection = schemas.get("capability-selection", {})
for field in ("selection_id", "request_class",
              "considered_candidates", "excluded_candidates",
              "selected_instance_id", "selection_reason", "selected_at",
              "provenance"):
    check(field in (selection.get("required_fields") or []),
          f"selection requires {field}")
# Route provenance is required of every decision a route governed and absent
# from the one decision no route governed. A request class with no resolvable
# route is still recorded; there is simply no route identity to name, and a
# placeholder would cite a policy that never existed.
for field in ("route_id", "route_version"):
    check(field in (selection.get("conditionally_required_fields") or []),
          f"selection records {field} conditionally")
    check(field not in (selection.get("required_fields") or []),
          f"selection does not require {field} unconditionally")
check(selection.get("route_provenance") == "all-or-none",
      "a selection records route identity and version together or not at all")
check(selection.get("route_provenance_absent_only_for") == "no-candidate",
      "only the no-candidate outcome may omit route provenance")
check(selection.get("route_identity_placeholder") == "forbidden",
      "a selection never invents a route identity")
check("local_node_identity" in (selection.get("optional_fields") or []),
      "a selection may record the node that governed a local-only decision")
check(selection.get("records_exclusion_reason") is True,
      "a selection records why each candidate was excluded")
# A selection points at the policy that governed it; it does not carry a copy.
# A copy would drift, and the audit record would then describe a policy that
# never applied.
check(selection.get("references_governing_route") is True,
      "a selection must reference the route that governed it")
check(selection.get("duplicates_route_policy") is False,
      "a selection does not duplicate route policy")
check(selection.get("record_class") == "audit",
      "a selection is an audit record")

# --- Route: policy, not an execution event ----------------------------------
check(route.get("record_class") == "policy-declaration",
      "a route is a policy declaration")
check(route.get("is_execution_event") is False,
      "a route is not an execution event")
check(route.get("dynamic_optimization") == "forbidden",
      "a route carries no dynamic optimization")
check(route.get("selection_rule") == "first-eligible-in-declared-order",
      "selection takes the first eligible candidate in declared order")

# The route carries its own copy of the routable list. Asserting each against a
# literal let the two drift: the route kept an effect class the contract had
# renamed, and every assertion still passed. They are compared against each
# other now, and against the enum, so a rename cannot leave one behind.
route_routable = route.get("routable_effect_classes") or []
contract_routable = contract.get("routable_effect_classes") or []
check(route_routable == contract_routable,
      "route and contract agree on which effect classes are routable")
check(set(route_routable) <= set(effect_classes),
      "every routable effect class is a defined effect class")
check("side-effecting" not in route_routable,
      "no route may select a side-effecting contract")
# Multiple candidates mean redundancy and declared alternatives, and imply no
# distribution policy whatever.
implies = route.get("multiple_candidates_imply") or []
check(implies == [] or implies == ["redundancy", "declared-alternatives"],
      "multiple candidates imply redundancy only, never a distribution policy")
for forbidden_behaviour in ("round-robin", "weighted", "load-balancing",
                            "least-loaded", "latency-optimization",
                            "automatic-failover", "parallel-execution",
                            "speculative-execution", "adaptive-placement",
                            "cost-optimization"):
    check(forbidden_behaviour in (route.get("forbidden_behaviours") or []),
          f"route forbids {forbidden_behaviour}")

# Health, before v0.9.6 exists to supply it.
check(route.get("health_may_reorder") is False,
      "health may not reorder route candidates")
check(route.get("absent_health_means") == "unknown-never-healthy",
      "absent health is never converted into a positive health claim")
check(route.get("automatic_rerouting") == "forbidden",
      "no automatic rerouting before v0.9.6")

# --- Definition: the identity anchor ----------------------------------------
definition = schemas.get("capability-definition", {})
for field in ("capability_id", "name", "description", "effect_class",
              "contract_ids", "provenance"):
    check(field in (definition.get("required_fields") or []),
          f"capability definition requires {field}")
check(definition.get("identity_survives") is not None,
      "capability definition declares what its identity survives")
# A definition names an ability. Routing to it directly would mean routing to
# a name, with no host, package, or contract version behind it.
check(definition.get("directly_routable") is False,
      "a capability definition is not directly routable")
survives = " ".join(str(item) for item in (definition.get("identity_survives") or [])).lower()
for event in ("host", "package", "contract"):
    check(event in survives, f"capability identity survives a {event} change")

# --- Ontology ---------------------------------------------------------------
types = (load("platform-model/ontology/entity-types.yaml") or {}).get("entity_types") or {}
for name, (prefix, _digits) in EXPECTED_IDS.items():
    check(name in types, f"ontology defines the {name} entity type")
    check((types.get(name) or {}).get("id_prefix") == prefix,
          f"{name} uses the {prefix} prefix")

# The existing capability record (CAP) describes what the platform can do. The
# fabric's capability describes something executable. Collapsing them would let
# a governance claim be routed to.
check((types.get("capability") or {}).get("id_prefix") == "CAP",
      "the pre-existing capability entity type is unchanged")

catalog = (load("platform-model/ontology/relationship-types.yaml") or {}).get("relationship_types") or {}
for name in ("CONTRACT_FOR", "IMPLEMENTS_CONTRACT", "ADVERTISES", "ADMITTED_AS",
             "ROUTES_TO", "SELECTS"):
    check(name in catalog, f"ontology defines the {name} relationship")

# Placement, leasing, and scheduling remain absent: this sprint defines no
# scheduler, so acquiring its vocabulary would claim more than was built.
for premature in ("PLACES_WORKLOAD", "LEASES", "SCHEDULES_ON", "PROVIDES_ENDPOINT"):
    check(premature not in catalog,
          f"no scheduler vocabulary is added ({premature})")
for premature in ("worker-node", "workload-lease", "model-endpoint", "placement"):
    check(premature not in types,
          f"no scheduler entity is added ({premature})")

# An advertisement must not be routable to. Only an admitted instance is.
routes_to = (catalog.get("ROUTES_TO") or {})
check(routes_to.get("allowed_targets") == ["capability-instance"],
      "a route may only target an admitted capability instance")
check("capability-advertisement" not in (routes_to.get("allowed_targets") or []),
      "a route may never target an advertisement")

# Trust must not be derivable from a fabric record. The fabric consumes trust;
# it never produces it.
FABRIC_TYPES = set(EXPECTED_IDS)
for name in ("TRUSTS", "VERIFIED_BY", "APPROVED_BY"):
    sources = set((catalog.get(name) or {}).get("allowed_sources") or [])
    check(not (sources & FABRIC_TYPES),
          f"{name} does not take a fabric record as its source")

# --- Trust domains are unchanged --------------------------------------------
# The Fabric fits the fifteen domains ADR-0011 declared. A sixteenth would mean
# the trust model was shaped by the feature that needed it.
for schema_name in ("trust-record", "trust-policy", "trust-authority"):
    schema = load(f"platform-model/schemas/{schema_name}.schema.yaml") or {}
    domains = (schema.get("enums") or {}).get("domain") or []
    if not domains:
        domains = (schema.get("enums") or {}).get("domains") or []
    if domains:
        check(len(domains) == 15, f"{schema_name} still declares fifteen trust domains")
        check("capability-package" in domains,
              f"{schema_name} keeps the capability-package domain")
        check("fabric-node" in domains,
              f"{schema_name} keeps the fabric-node domain")

sys.exit(1 if failures else 0)
PY
PY_STATUS=$?
set -e
if (( PY_STATUS != 0 )); then
  FAILURES=$((FAILURES + 1))
fi

# --- Documentation content ---------------------------------------------------
assert_contains "${FABRIC_DOC}" '[Nn]o machine is Kyri' "fabric overview restates that no machine is Kyri"
assert_contains "${LIFECYCLE_DOC}" '[Dd]eclared' "lifecycle documents the declared stage"
assert_contains "${LIFECYCLE_DOC}" '[Aa]dvertised' "lifecycle documents the advertised stage"
assert_contains "${LIFECYCLE_DOC}" '[Aa]dmitted' "lifecycle documents the admitted stage"
assert_contains "${LIFECYCLE_DOC}" '[Ss]uperseded' "lifecycle documents the superseded stage"
assert_contains "${LIFECYCLE_DOC}" '[Rr]etired' "lifecycle documents the retired stage"

assert_contains "${IDENTITY_DOC}" '[Hh]ost migration' "identity document covers host migration"
assert_contains "${ROUTING_DOC}" '[Dd]eterministic' "routing document states determinism"
assert_contains "${ROUTING_DOC}" 'local-only' "routing document covers local-only enforcement"
assert_contains "${FAILURE_DOC}" '[Rr]efuse' "failure document states the fabric refuses"
assert_contains "${FAILURE_DOC}" '[Nn]o automatic remediation' "failure document forbids remediation"
assert_contains "${GOVERNANCE_DOC}" '[Hh]osts execute' "governance document states hosts execute"
assert_contains "${GOVERNANCE_DOC}" 'never decide' "governance document states hosts never decide"

# The audit requirement is what makes a distributed system reviewable at all.
assert_contains "${GOVERNANCE_DOC}" '[Aa]udit' "governance document defines audit requirements"
assert_contains "${ADR}" '^### Audit requirements' "ADR-0012 defines audit requirements"

# --- The fabric carries no capability semantics ------------------------------
# Adding speech, vision, or robotics must be a record change, never a core
# change. The core therefore must not name a modality.
assert_contains "${ADR}" '[Ss]peech' "ADR-0012 shows speech arriving without a core change"
assert_contains "${ADR}" '[Vv]ision' "ADR-0012 shows vision arriving without a core change"
assert_contains "${ADR}" '[Rr]obotics' "ADR-0012 shows robotics arriving without a core change"
for schema in "${FABRIC_SCHEMAS[@]}"; do
  assert_absent_in "platform-model/schemas/${schema}.schema.yaml" \
    '(ollama|litellm|whisper|robotic)' \
    "${schema} schema names no specific capability implementation"
done

# --- Roadmap -----------------------------------------------------------------
assert_contains "${ROADMAP}" 'v0\.9\.5 — Distributed Capability Fabric' \
  "roadmap keeps the v0.9.5 heading"
assert_contains "${ROADMAP}" 'ADR-0012' "roadmap cites ADR-0012"
assert_contains "${ROADMAP}" 'TrustGateway production cutover gate' \
  "roadmap keeps the production cutover gate"
assert_contains "${ROADMAP}" 'Fabric Runtime entry gate' \
  "roadmap names the Fabric Runtime entry gate separately"

# --- Standards ---------------------------------------------------------------
# The name collision between the platform capability record and the fabric
# capability is the single most likely thing for a future reader to conflate.
assert_contains "docs/standards/capability-model-standard.md" 'CAPDEF' \
  "capability model standard distinguishes itself from the fabric capability"
assert_contains "docs/standards/platform-ontology-standard.md" 'capability-instance' \
  "ontology standard records the fabric entity types as a documented change"

# --- Two gates: Fabric Runtime entry, then production cutover -----------------
# The governance document must name both gates and keep them apart. Collapsing
# them in either direction is the failure this block exists to catch: fold them
# together and either the fabric never gets built, or it gets admitted into
# production through a chain that does not terminate at the root.
assert_contains "${ADR}" '[Ss]pecification may proceed' \
  "ADR-0012 states specification may proceed before deployment acceptance"
assert_contains "${GOVERNANCE_DOC}" '^### Gate 1 — Fabric Runtime entry gate' \
  "governance document defines the Fabric Runtime entry gate"
assert_contains "${GOVERNANCE_DOC}" '^### Gate 2 — TrustGateway production cutover gate' \
  "governance document defines the production cutover gate separately"
for requirement in 'Operator Root Authority ceremony complete' \
                   'ENG-0001' 'ENG-0002' \
                   'Fabric Runtime' 'Health Runtime' \
                   'subjects seeded' 'TrustGateway cutover'; do
  assert_contains "${GOVERNANCE_DOC}" "${requirement}" \
    "governance document records the corrected sequence item: ${requirement}"
done

# One exact sentence, not a loose pattern. '[Tt]rustGateway cutover.*not.*gate'
# was satisfiable by prose meaning the opposite, e.g. "cutover is not the only
# gate", which would pass while asserting exactly what must not be true.
assert_contains "${GOVERNANCE_DOC}" \
  'TrustGateway cutover is intentionally not the Fabric Runtime gate' \
  "governance document states cutover is intentionally not the Fabric Runtime gate"
assert_absent_in "${GOVERNANCE_DOC}" \
  '(blocked|forbidden|waits?) until .*TrustGateway cutover' \
  "governance document does not block Fabric Runtime on TrustGateway cutover"

# Gate 1 permits construction. Production operation still waits for Gate 2, and
# each prohibition is asserted in its production-scoped form rather than as a
# bare word that architecture prose would satisfy by accident.
for prohibited in 'Node admission in production' \
                  'Capability registration in production' \
                  'Routing in production' \
                  'Selection in production' \
                  'Execution in production'; do
  assert_contains "${GOVERNANCE_DOC}" "${prohibited}" \
    "governance document prohibits until cutover: ${prohibited}"
done
assert_contains "${GOVERNANCE_DOC}" 'Runtime implementation\*\* — the fabric engine may be built' \
  "governance document permits building the runtime after Gate 1"

# Every production cutover requirement survives verbatim.
for cutover_requirement in 'Operator Root Authority instantiated' \
                           'production trust store validated' \
                           'initial migrated subjects seeded' \
                           'trust-plane-runtime or approved code-owned fallback available' \
                           'rollback procedure validated' \
                           'deployment evidence retained'; do
  assert_contains "${GOVERNANCE_DOC}" "${cutover_requirement}" \
    "governance document preserves the cutover requirement: ${cutover_requirement}"
done

# --- Governed discovery ------------------------------------------------------
assert_contains "${ADR}" '^### Governed discovery' "ADR-0012 defines governed discovery"
assert_contains "${ADR}" '[Rr]eachability never implies admission' \
  "ADR-0012 states reachability never implies admission"
for forbidden in '[Nn]etwork scanning' '[Ss]ubnet scanning' '[Mm]ulticast' \
                 '[Bb]roadcast' '[Uu]nsolicited advertisement' \
                 '[Aa]utomatic registration' '[Aa]utomatic node admission' \
                 'DNS discovery' 'bypass'; do
  assert_contains "${ADR}" "${forbidden}" "ADR-0012 forbids ${forbidden} in discovery"
done

# The seven-step sequence, in order. An advertisement is queryable only after
# its subject was admitted, which is what makes "governed lookup" mean
# something other than "lookup".
assert_contains "${GOVERNANCE_DOC}" '[Qq]ueryable' \
  "governance document states when an advertisement becomes queryable"
assert_contains "${ADR}" '[Aa]dvertisement.*queryable|queryable.*admission' \
  "ADR-0012 ties advertisement queryability to admission"

# --- Route versus selection --------------------------------------------------
# Two records, two lifetimes. A route is durable policy; a selection is one
# recorded act. Collapsing them would mean either that policy is rewritten per
# request, or that the audit record carries policy it does not own.
assert_contains "${ROUTING_DOC}" '[Pp]olicy declaration' \
  "routing document calls a route a policy declaration"
assert_contains "${ROUTING_DOC}" 'not an execution event|never an execution event' \
  "routing document states a route is not an execution event"
assert_contains "${ROUTING_DOC}" '[Hh]uman-authored|human-written' \
  "routing document states candidate order is human-authored"
assert_contains "${ROUTING_DOC}" 'first eligible candidate' \
  "routing document states first-eligible-candidate selection"
assert_contains "${ROUTING_DOC}" 'does not duplicate|never duplicates' \
  "routing document states a selection does not duplicate route policy"

# --- Multi-instance restraint ------------------------------------------------
assert_contains "${IDENTITY_DOC}" '[Rr]edundancy' \
  "identity document frames multiple instances as redundancy"
for absent in '[Rr]ound-robin' '[Ww]eighted routing' '[Ll]oad balancing' \
              '[Ll]east-loaded' '[Ll]atency optimi' '[Aa]utomatic failover' \
              '[Pp]arallel execution' '[Ss]peculative execution' \
              '[Aa]daptive placement' '[Cc]ost optimi'; do
  assert_contains "${IDENTITY_DOC}" "${absent}" \
    "identity document states multiple instances do not imply ${absent}"
done

# Health, before there is a health monitor to provide it.
assert_contains "${ROUTING_DOC}" '[Dd]eclared or unknown' \
  "routing document allows health to be declared or unknown"
assert_contains "${ROUTING_DOC}" '[Mm]ust not reorder|never reorder' \
  "routing document forbids health reordering candidates"
assert_contains "${ROUTING_DOC}" '[Aa]bsence of health' \
  "routing document forbids converting absent health into a positive claim"

# --- Trust, Fabric, Health separation ----------------------------------------
assert_contains "${ADR}" '^### Trust, Fabric, and Health' \
  "ADR-0012 defines the three-layer separation"
for rule in '[Tt]rust precedes admission' \
            '[Hh]ealth cannot grant trust' \
            '[Hh]ealth cannot override quarantine' \
            '[Hh]ealth cannot broaden scope' \
            '[Hh]ealth cannot admit' \
            '[Ff]abric cannot create trust decisions' \
            '[Ff]abric cannot mutate trust state'; do
  assert_contains "${ADR}" "${rule}" "ADR-0012 states: ${rule}"
done
assert_contains "${ADR}" '[Rr]outing outcomes|routing outcome' \
  "ADR-0012 forbids the Trust Plane using routing outcomes as evidence"

# --- No runtime beyond the ENG-0004 fabric package ---------------------------
# Named individually because each is a different way the same line gets
# crossed, and a single directory check would miss most of them. `tools/fabric`
# is released by ENG-0004; the rest stay forbidden.
for forbidden_dir in tools/capability tools/scheduler tools/placement \
                     tools/clustering tools/routing tools/health tools/discovery \
                     tools/lease tools/admission; do
  if [[ -d "${ROOT}/${forbidden_dir}" ]]; then
    fail "only the ENG-0004 fabric package may exist; ${forbidden_dir} must not"
  else
    pass "no implementation directory: ${forbidden_dir}"
  fi
done

# No fabric runtime records may be committed. These are machine-generated and
# belong in a store outside the repository, exactly like trust runtime records.
FABRIC_RUNTIME_RECORDS="$(git -C "${ROOT}" ls-files \
  '*CADV-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CINST-[0-9][0-9][0-9][0-9][0-9][0-9]*' \
  '*CSEL-[0-9][0-9][0-9][0-9][0-9][0-9]*' 2>/dev/null)" || FABRIC_RUNTIME_RECORDS=""
if [[ -z "${FABRIC_RUNTIME_RECORDS}" ]]; then
  pass "no fabric runtime records are committed"
else
  fail "fabric runtime records must not be committed: ${FABRIC_RUNTIME_RECORDS}"
fi

# The fabric documentation must not acquire an execution vocabulary. Each of
# these would be a different claim that something runs.
for doc in "${FABRIC_DOC}" "${ROUTING_DOC}" "${GOVERNANCE_DOC}" "${NODE_DOC}"; do
  assert_absent_in "${doc}" \
    '(docker (run|exec|compose up)|ssh +[a-z]|systemctl (start|restart)|apt-get install|pip install)' \
    "$(basename "${doc}") contains no execution command"
done

# --- Scheduler vocabulary stays absent ---------------------------------------
# There is no scheduler, so the words that describe one must not appear as
# though something implements them.
#
# The ADR's Rejected Alternatives section is excluded from the scan. Naming a
# mechanism in order to refuse it is the opposite of claiming it, and a rule
# that forbade the naming would make the rejections unwritable.
SCHEDULER_SCAN="$(mktemp)"
trap 'rm -f "${SCHEDULER_SCAN}"' EXIT
sed '/^## Rejected Alternatives/,$d' "${ROOT}/${ADR}" > "${SCHEDULER_SCAN}"
# Fabric schemas only. The health schemas share the capability- prefix but
# legitimately measure queue depth and latency: observing a number is not the
# same as scheduling on it, and ADR-0013 governs what health may do with it.
for fabric_schema in "${FABRIC_SCHEMAS[@]}"; do
  cat "${ROOT}/platform-model/schemas/${fabric_schema}.schema.yaml" >> "${SCHEDULER_SCAN}"
done
cat "${ROOT}"/docs/fabric/*.md >> "${SCHEDULER_SCAN}"

for schedulerism in 'workload lease' 'placement engine' 'bin.pack' \
                    'autoscal' 'queue depth' 'work.steal'; do
  matches="$(grep -rIniE -e "${schedulerism}" "${SCHEDULER_SCAN}" 2>/dev/null \
    | grep -viE 'no |never |not |without |forbidden|absent|deferred|reserved' || true)"
  if [[ -z "${matches}" ]]; then
    pass "no scheduler vocabulary asserted: ${schedulerism}"
  else
    fail "scheduler vocabulary appears as a claim: ${schedulerism}"
  fi
done

# --- Summary -----------------------------------------------------------------
if (( FAILURES == 0 )); then
  printf '\nAll capability fabric assertions passed.\n'
else
  printf '\n%d capability fabric assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
