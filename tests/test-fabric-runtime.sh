#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the Fabric Runtime (ENG-0004), increment 1.
#
# Increment 1 is the contract layer and nothing else: the eight accepted record
# models, their identifier widths, their serialisation rules, and the fields
# they refuse to carry. There is no store, no admission, no eligibility, no
# selection, and no interface in this increment, and this suite asserts none of
# them.
#
# NOTHING HERE CONTACTS ANYTHING. Every assertion is in-memory over synthetic
# records. No store is opened, no file is written outside a temporary
# directory, no network, no SSH, no subprocess from library code, no Docker,
# and no ai/.env.
#
# Governed by:
#   docs/superpowers/specs/2026-08-04-fabric-runtime-design.md
#   docs/superpowers/plans/2026-08-04-eng-0004-fabric-runtime-implementation-plan.md
#   docs/decisions/ADR-0012-distributed-capability-fabric.md
#   platform-model/schemas/capability-*.schema.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FABRIC="tools/fabric"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
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

# --- Required increment 1 modules ------------------------------------------
for module in __init__ models identifiers; do
  assert_file "${FABRIC}/${module}.py"
done

# --- The contract layer reaches nothing -------------------------------------
# A contract module that can open a socket or spawn a process is no longer a
# contract module.
assert_absent_in "${FABRIC}" \
  '\b(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|subprocess)|from[[:space:]]+(socket|requests|urllib|paramiko|subprocess)[[:space:]]+import)' \
  "the fabric runtime imports no network or subprocess module"
assert_absent_in "${FABRIC}" '(subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\(|\beval\(|\bexec\()' \
  "the fabric runtime executes nothing"

# --- AC 48: no capability execution, no health runtime, no remediation -------
# This assertion is introduced here and must keep passing through increment 12,
# so that later interface or documentation work cannot reintroduce what it
# forbids.
assert_absent_in "${FABRIC}" \
  '(importlib|__import__|load_package|activate_capability|invoke_capability|dispatch|worker|provider_connector|execution_adapter)' \
  "the fabric runtime loads, activates, invokes, or dispatches nothing"
assert_absent_in "${FABRIC}" \
  '(health_state|evaluate_health|compute_health|health_score|degradation)' \
  "the fabric runtime evaluates no health state"
assert_absent_in "${FABRIC}" \
  '(remediat|auto_restart|redeploy|requeue|auto_drain|auto_quarantine)' \
  "the fabric runtime remediates nothing"

# --- No request ledger, replay ledger, or ninth persistent record ------------
assert_absent_in "${FABRIC}" \
  '(request_ledger|replay_ledger|audit_record|audit_event|AuditRecord|AuditEvent)' \
  "the fabric runtime defines no ledger and no audit-record class"

# --- Behavioural contract ---------------------------------------------------
PY_OUTPUT="$(python3 - "${ROOT}" <<'FABRICPY' 2>&1 || true
import json
import sys
from dataclasses import FrozenInstanceError
from datetime import datetime, timedelta, timezone
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))

failures = 0


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    if condition:
        ok(message)
    else:
        bad(message)


def refuses(callable_, message):
    """A construction that must be refused, by any FabricError."""
    try:
        callable_()
    except FabricError:
        ok(message)
    except Exception as error:  # noqa: BLE001 - a wrong exception type is a failure
        bad(f"{message} (raised {type(error).__name__} instead of FabricError)")
    else:
        bad(f"{message} (constructed instead of refusing)")


# The import that must fail before the package exists. Increment 1's observable
# Red reason is exactly this line.
from tools.fabric.errors import FabricError  # noqa: E402
from tools.fabric.identifiers import PATTERNS, PREFIXES  # noqa: E402
from tools.fabric.models import (  # noqa: E402
    RECORD_MODELS,
    SUPPORTED_SCHEMA_VERSION,
    CapabilityAdvertisement,
    CapabilityContract,
    CapabilityDefinition,
    CapabilityHost,
    CapabilityInstance,
    CapabilityPackage,
    CapabilityRoute,
    CapabilitySelection,
)

STAMP = datetime(2026, 8, 5, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
LATER = STAMP + timedelta(hours=12)

# ---------------------------------------------------------------------------
# Exactly eight persistent record types, and no ninth
# ---------------------------------------------------------------------------
EXPECTED_KINDS = {
    "capability-definition",
    "capability-contract",
    "capability-package",
    "capability-host",
    "capability-advertisement",
    "capability-instance",
    "capability-route",
    "capability-selection",
}
check(set(RECORD_MODELS) == EXPECTED_KINDS,
      f"exactly the eight accepted record kinds are registered ({sorted(RECORD_MODELS)})")
check(len(RECORD_MODELS) == 8, "no ninth persistent record model exists")
check(len(set(RECORD_MODELS.values())) == 8,
      "each accepted kind maps to a distinct model class")

# ---------------------------------------------------------------------------
# Identifier widths: four digits for human-declared, six for runtime-allocated
# ---------------------------------------------------------------------------
EXPECTED_PATTERNS = {
    "capability-definition": r"^CAPDEF-[0-9]{4}$",
    "capability-contract": r"^CCON-[0-9]{4}$",
    "capability-package": r"^CPKG-[0-9]{4}$",
    "capability-host": r"^CHOST-[0-9]{4}$",
    "capability-route": r"^CROUTE-[0-9]{4}$",
    "capability-advertisement": r"^CADV-[0-9]{6}$",
    "capability-instance": r"^CINST-[0-9]{6}$",
    "capability-selection": r"^CSEL-[0-9]{6}$",
}
for kind, expected in EXPECTED_PATTERNS.items():
    actual = PATTERNS.get(kind)
    check(actual is not None and actual.pattern == expected,
          f"{kind} identifier pattern is {expected}")

EXPECTED_PREFIXES = {
    "capability-definition": "CAPDEF",
    "capability-contract": "CCON",
    "capability-package": "CPKG",
    "capability-host": "CHOST",
    "capability-advertisement": "CADV",
    "capability-instance": "CINST",
    "capability-route": "CROUTE",
    "capability-selection": "CSEL",
}
check(PREFIXES == EXPECTED_PREFIXES, "identifier prefixes match the accepted schemas")


def definition(**overrides):
    fields = dict(
        capability_id="CAPDEF-0001",
        name="generate-text",
        description="Produce text from a prompt.",
        effect_class="content-generating",
        contract_ids=("CCON-0001",),
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityDefinition(**fields)


def contract(**overrides):
    fields = dict(
        contract_id="CCON-0001",
        capability_id="CAPDEF-0001",
        contract_version="1.0.0",
        effect_class="content-generating",
        determinism_class="nondeterministic",
        request_shape={"prompt": "string"},
        response_shape={"text": "string"},
        failure_modes=("refused", "unavailable"),
        resource_requirements={"host_memory_mb": 2048},
        compatible_with=(),
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityContract(**fields)


def package(**overrides):
    fields = dict(
        capability_package_id="CPKG-0001",
        capability_id="CAPDEF-0001",
        contract_id="CCON-0001",
        satisfied_contract_versions=("1.0.0",),
        package_version="0.1.0",
        artifact_reference="artifact://approved/text-generator",
        resource_requirements={"host_memory_mb": 2048},
        trust_domain="capability-package",
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityPackage(**fields)


def host(**overrides):
    fields = dict(
        capability_host_id="CHOST-0001",
        node_identity_reference="secret-source://approved/node-identity",
        fabric_node_trust_record_id="TREC-000001",
        verified_resource_profile={"host_memory_mb": 65536, "accelerator_class": "discrete-gpu"},
        location_class="on-premises",
        data_classification_ceiling="internal",
        availability_intent="in-service",
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityHost(**fields)


def advertisement(**overrides):
    fields = dict(
        advertisement_id="CADV-000001",
        capability_host_id="CHOST-0001",
        capability_package_id="CPKG-0001",
        contract_id="CCON-0001",
        satisfied_contract_versions=("1.0.0",),
        advertised_resource_profile={"host_memory_mb": 65536},
        observed_at=STAMP,
        valid_until=LATER,
        provenance={"class": "declared", "source": "subject"},
    )
    fields.update(overrides)
    return CapabilityAdvertisement(**fields)


def instance(**overrides):
    fields = dict(
        instance_id="CINST-000001",
        capability_id="CAPDEF-0001",
        capability_package_id="CPKG-0001",
        capability_host_id="CHOST-0001",
        contract_id="CCON-0001",
        satisfied_contract_versions=("1.0.0",),
        verified_resource_profile={"host_memory_mb": 65536},
        admission_decision_id="TDEC-000001",
        package_trust_record_id="TREC-000001",
        host_trust_record_id="TREC-000002",
        effective_scope={"permitted_operations": ("generate",)},
        admitted_at=STAMP,
        admitted_until=LATER,
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityInstance(**fields)


def route(**overrides):
    fields = dict(
        route_id="CROUTE-0001",
        route_version=1,
        capability_id="CAPDEF-0001",
        contract_id="CCON-0001",
        accepted_contract_versions=("1.0.0",),
        locality="local-only",
        candidate_instances=("CINST-000001",),
        data_classification="internal",
        provenance={"class": "declared", "source": "operator"},
    )
    fields.update(overrides)
    return CapabilityRoute(**fields)


def selection(**overrides):
    fields = dict(
        selection_id="CSEL-000001",
        route_id="CROUTE-0001",
        route_version=1,
        request_class={"capability_id": "CAPDEF-0001", "locality": "local-only"},
        considered_candidates=("CINST-000001",),
        excluded_candidates=(),
        selected_instance_id="CINST-000001",
        selection_reason="first eligible candidate in declared order",
        selected_at=STAMP,
        provenance={"class": "declared", "source": "core"},
    )
    fields.update(overrides)
    return CapabilitySelection(**fields)


BUILDERS = {
    "capability-definition": definition,
    "capability-contract": contract,
    "capability-package": package,
    "capability-host": host,
    "capability-advertisement": advertisement,
    "capability-instance": instance,
    "capability-route": route,
    "capability-selection": selection,
}

# ---------------------------------------------------------------------------
# Each accepted type is constructible, frozen, and deterministic
# ---------------------------------------------------------------------------
for kind, build in BUILDERS.items():
    try:
        record = build()
    except Exception as error:  # noqa: BLE001
        bad(f"{kind} is constructible with valid data ({type(error).__name__}: {error})")
        continue
    ok(f"{kind} is constructible with valid data")

    check(isinstance(record, RECORD_MODELS[kind]),
          f"{kind} builds the registered model class")

    try:
        object.__setattr__  # noqa: B018 - referenced for clarity only
        setattr(record, "provenance", {})
    except FrozenInstanceError:
        ok(f"{kind} is frozen; assignment is refused")
    except Exception as error:  # noqa: BLE001
        bad(f"{kind} is frozen; assignment is refused (raised {type(error).__name__})")
    else:
        bad(f"{kind} is frozen; assignment is refused (assignment succeeded)")

    first = record.to_dict()
    second = build().to_dict()
    check(first == second, f"{kind} serialises deterministically for equal input")
    check(json.dumps(first, sort_keys=True, default=str)
          == json.dumps(second, sort_keys=True, default=str),
          f"{kind} serialises to a byte-identical canonical form")

    restored = RECORD_MODELS[kind].from_dict(first)
    check(restored.to_dict() == first, f"{kind} round-trips deterministically")

    check(first.get("schema_version") == SUPPORTED_SCHEMA_VERSION,
          f"{kind} records its schema version")
    check(first.get("kind") == kind, f"{kind} records its own kind discriminator")

# ---------------------------------------------------------------------------
# Unknown fields are refused, not tolerated
# ---------------------------------------------------------------------------
for kind, build in BUILDERS.items():
    payload = build().to_dict()
    payload["unexpected_field"] = "should be refused"
    refuses(lambda p=payload, k=kind: RECORD_MODELS[k].from_dict(p),
            f"{kind} refuses an unknown stored field")

# ---------------------------------------------------------------------------
# Unsupported schema versions fail closed
# ---------------------------------------------------------------------------
check(SUPPORTED_SCHEMA_VERSION == "schott-platform/v1",
      "the supported schema version is schott-platform/v1")
for kind, build in BUILDERS.items():
    payload = build().to_dict()
    payload["schema_version"] = "schott-platform/v99"
    refuses(lambda p=payload, k=kind: RECORD_MODELS[k].from_dict(p),
            f"{kind} refuses an unsupported schema version")

    missing = build().to_dict()
    del missing["schema_version"]
    refuses(lambda p=missing, k=kind: RECORD_MODELS[k].from_dict(p),
            f"{kind} refuses an absent schema version")

# ---------------------------------------------------------------------------
# Timestamps must carry an offset
# ---------------------------------------------------------------------------
NAIVE = datetime(2026, 8, 5, 9, 0, 0)
refuses(lambda: advertisement(observed_at=NAIVE),
        "an advertisement refuses a naive observed_at")
refuses(lambda: advertisement(valid_until=NAIVE),
        "an advertisement refuses a naive valid_until")
refuses(lambda: instance(admitted_at=NAIVE),
        "an instance refuses a naive admitted_at")
refuses(lambda: instance(admitted_until=NAIVE),
        "an instance refuses a naive admitted_until")
refuses(lambda: selection(selected_at=NAIVE),
        "a selection refuses a naive selected_at")

for label, build, field_name in (
    ("advertisement", advertisement, "observed_at"),
    ("instance", instance, "admitted_at"),
    ("selection", selection, "selected_at"),
):
    try:
        build(**{field_name: STAMP})
        ok(f"a {label} accepts a timezone-aware {field_name}")
    except Exception as error:  # noqa: BLE001
        bad(f"a {label} accepts a timezone-aware {field_name} ({type(error).__name__})")

# ---------------------------------------------------------------------------
# Effect class: required, and only the accepted vocabulary
# ---------------------------------------------------------------------------
ACCEPTED_EFFECT_CLASSES = ("read-only", "computational", "content-generating", "side-effecting")
for value in ACCEPTED_EFFECT_CLASSES:
    try:
        contract(effect_class=value)
        definition(effect_class=value)
        ok(f"effect class '{value}' is representable")
    except Exception as error:  # noqa: BLE001
        bad(f"effect class '{value}' is representable ({type(error).__name__})")

refuses(lambda: contract(effect_class="actuating"),
        "a contract refuses an unrecognised effect class")
refuses(lambda: definition(effect_class="actuating"),
        "a definition refuses an unrecognised effect class")
refuses(lambda: contract(effect_class=""),
        "a contract refuses an empty effect class")
refuses(lambda: contract(effect_class=None),
        "a contract refuses an absent effect class")
refuses(lambda: definition(effect_class=None),
        "a definition refuses an absent effect class")

# ---------------------------------------------------------------------------
# Identifier validation is enforced at construction
# ---------------------------------------------------------------------------
refuses(lambda: definition(capability_id="CAPDEF-000001"),
        "a definition refuses a six-digit identifier where four are required")
refuses(lambda: advertisement(advertisement_id="CADV-0001"),
        "an advertisement refuses a four-digit identifier where six are required")
refuses(lambda: route(route_id="CROUTE-00001"),
        "a route refuses a malformed identifier")
refuses(lambda: instance(instance_id="TLIN-000001"),
        "an instance refuses an identifier from another plane")

# ---------------------------------------------------------------------------
# No field may carry a credential, a secret, or an executable command
# ---------------------------------------------------------------------------
FORBIDDEN_FIELDS = (
    "token", "secret", "credential", "private_key", "password", "passphrase",
    "command", "argv", "trust_score", "health_score", "prompt_content",
    "request_payload", "response_payload",
)
for kind, build in BUILDERS.items():
    stored = build().to_dict()
    present = sorted(name for name in FORBIDDEN_FIELDS if name in stored)
    check(not present, f"{kind} carries no credential, score, or command field ({present})")

    for name in ("token", "secret", "credential", "command", "trust_score"):
        payload = dict(stored)
        payload[name] = "refused"
        refuses(lambda p=payload, k=kind: RECORD_MODELS[k].from_dict(p),
                f"{kind} refuses a stored '{name}' field")

# ---------------------------------------------------------------------------
# The contract layer holds no store, admission, selection, or lock behaviour
# ---------------------------------------------------------------------------
import tools.fabric.models as models_module  # noqa: E402

for forbidden in ("write", "write_atomic", "allocate_id", "admit", "select",
                  "acquire", "lock", "evaluate_eligibility"):
    check(not hasattr(models_module, forbidden),
          f"the contract layer exposes no '{forbidden}' behaviour")

print(f"__FAILURES__={failures}")
FABRICPY
)"
printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${PY_FAILURES}" ]]; then
  fail "fabric runtime behavioural validation did not report a result"
else
  FAILURES=$((FAILURES + PY_FAILURES))
fi

# Nothing was written inside the repository by any of the above.
if [[ -n "$(find "${ROOT}/tools" -name 'C*-[0-9]*' -print -quit 2>/dev/null)" ]]; then
  fail "a fabric record was written into the source tree"
else
  pass "no fabric record was written into the source tree"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nFabric runtime validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nFabric runtime validation passed.\n'
