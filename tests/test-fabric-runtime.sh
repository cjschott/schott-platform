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

# ===========================================================================
# Increment 2 — Fabric record store (C1)
# ===========================================================================
# A separate block, so increment 1's contract assertions keep reporting their
# own result while these fail on the missing store module.
#
# Governed by the accepted plan's Increment 2 section: per-kind identifier
# widths, complete containment across all twelve inherited entry points,
# explicit ownership, preservation of pre-existing residue, and the
# deterministic commit race.

# --- AC 68: only store.py may reach the filesystem ---------------------------
# A preventive guard rather than a failing one: no writer exists yet, so it
# passes today and must keep passing once store.py arrives. Checked by AST so
# an alias import cannot slip past a text scan.
AC68_OUTPUT="$(python3 - "${ROOT}" <<'AC68PY' 2>&1 || true
import ast
import sys
from pathlib import Path

root = Path(sys.argv[1])
failures = 0

WRITE_ATTRS = {
    "open", "write", "mkdir", "makedirs", "chmod", "chown", "rename", "replace",
    "link", "symlink", "remove", "unlink", "rmdir", "truncate", "ftruncate",
    "fdopen", "write_text", "write_bytes", "touch", "symlink_to", "hardlink_to",
    "copy", "copy2", "copyfile", "copytree", "move", "rmtree",
    "NamedTemporaryFile", "mkstemp", "mkdtemp", "TemporaryFile",
    "write_atomic", "write_record",
}
WRITE_MODULES = {"os", "shutil", "tempfile", "pathlib"}

for path in sorted((root / "tools" / "fabric").glob("*.py")):
    if path.name == "store.py":
        continue
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

    # Names bound by `from os import replace as _r` and `import shutil as sh`.
    aliased = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module in WRITE_MODULES:
            for alias in node.names:
                aliased[alias.asname or alias.name] = f"{node.module}.{alias.name}"
        elif isinstance(node, ast.Import):
            for alias in node.names:
                base = alias.name.split(".")[0]
                if base in WRITE_MODULES and alias.asname:
                    aliased[alias.asname] = alias.name

    hits = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr in WRITE_ATTRS:
            hits.append(f"{path.name}:{node.lineno}:.{func.attr}")
        elif isinstance(func, ast.Name):
            if func.id in aliased:
                hits.append(f"{path.name}:{node.lineno}:{aliased[func.id]}")
            elif func.id == "open":
                hits.append(f"{path.name}:{node.lineno}:builtin open")
    if hits:
        failures += 1
        print(f"FAIL: only store.py may mutate the filesystem; {path.name} does ({hits[:3]})")
    else:
        print(f"PASS: {path.name} reaches the filesystem by no mechanism")

print(f"__AC68__={failures}")
AC68PY
)"
printf '%s\n' "${AC68_OUTPUT}" | grep -v '^__AC68__=' || true
AC68_FAILURES="$(printf '%s\n' "${AC68_OUTPUT}" | sed -n 's/^__AC68__=//p' | tail -1)"
if [[ -z "${AC68_FAILURES}" ]]; then
  fail "the AC 68 filesystem-mutation scan did not report a result"
else
  FAILURES=$((FAILURES + AC68_FAILURES))
fi

# --- Store behaviour ---------------------------------------------------------
STORE_OUTPUT="$(python3 - "${ROOT}" <<'STOREPY' 2>&1 || true
import os
import stat
import sys
import threading
from pathlib import Path
from tempfile import TemporaryDirectory

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
    try:
        callable_()
    except (FabricError, TypeError, ValueError, OSError):
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__})")
    else:
        bad(f"{message} (was accepted instead of refused)")


from tools.fabric.errors import FabricError  # noqa: E402
# The import that must fail before increment 2 exists.
from tools.fabric.store import FabricStore  # noqa: E402

UID = os.geteuid()
GID = os.getegid()

FOUR_DIGIT = ("capability-definition", "capability-contract", "capability-package",
              "capability-host", "capability-route")
SIX_DIGIT = ("capability-advertisement", "capability-instance", "capability-selection")


def opened(tmp, **overrides):
    fields = dict(expected_uid=UID, expected_gid=GID)
    fields.update(overrides)
    return FabricStore(Path(tmp) / "fabric", **fields)


# --- Ownership (AC 39, FC 19) -----------------------------------------------
# Defect caught: a store that infers its owner from the caller, or silently
# chowns a path whose owner does not match, instead of refusing.
with TemporaryDirectory() as tmp:
    try:
        opened(tmp)
        ok("a store opens when the supplied UID/GID match the process")
    except Exception as error:  # noqa: BLE001
        bad(f"a store opens when the supplied UID/GID match the process ({type(error).__name__})")

with TemporaryDirectory() as tmp:
    refuses(lambda: FabricStore(Path(tmp) / "fabric", expected_gid=GID),
            "a store refuses a missing expected_uid")
    refuses(lambda: FabricStore(Path(tmp) / "fabric", expected_uid=UID),
            "a store refuses a missing expected_gid")
    refuses(lambda: FabricStore(Path(tmp) / "fabric"),
            "a store refuses absent ownership inputs entirely")

with TemporaryDirectory() as tmp:
    # Process EUID/EGID must equal the supplied values before creation.
    refuses(lambda: opened(tmp, expected_uid=UID + 4242),
            "a store refuses to create a path when the process EUID differs")
    refuses(lambda: opened(tmp, expected_gid=GID + 4242),
            "a store refuses to create a path when the process EGID differs")

with TemporaryDirectory() as tmp:
    opened(tmp)  # create the tree once with matching ownership
    refuses(lambda: opened(tmp, expected_uid=UID + 4242),
            "an existing path whose UID does not match the supplied value refuses")
    refuses(lambda: opened(tmp, expected_gid=GID + 4242),
            "an existing path whose GID does not match the supplied value refuses")
    root_dir = Path(tmp) / "fabric"
    check(root_dir.stat().st_uid == UID and root_dir.stat().st_gid == GID,
          "a refused ownership check performs no chown")

# --- Absent store stays absent on the read path ------------------------------
with TemporaryDirectory() as tmp:
    absent = Path(tmp) / "not-a-store"
    try:
        FabricStore.open_for_read(absent, expected_uid=UID, expected_gid=GID)
        ok("open_for_read accepts ownership inputs and reports an absent store")
    except FabricError:
        ok("open_for_read accepts ownership inputs and reports an absent store")
    except Exception as error:  # noqa: BLE001
        bad(f"open_for_read propagates ownership ({type(error).__name__})")
    check(not absent.exists(), "open_for_read does not create an absent store root")

# --- Per-kind identifier widths ---------------------------------------------
# Defect caught: allocate_id hardcodes :06d, so a four-digit kind gets six.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    for kind in FOUR_DIGIT:
        identifier = store.allocate_id(kind)
        digits = identifier.split("-")[-1]
        check(len(digits) == 4, f"{kind} allocates a four-digit identifier (got {identifier})")
    for kind in SIX_DIGIT:
        identifier = store.allocate_id(kind)
        digits = identifier.split("-")[-1]
        check(len(digits) == 6, f"{kind} allocates a six-digit identifier (got {identifier})")

# The released Trust Plane keeps its six digits, byte for byte.
with TemporaryDirectory() as tmp:
    from tools.trust.store import TrustStore

    trust = TrustStore(Path(tmp) / "trust")
    trust_id = trust.allocate_id("authority")
    check(trust_id == "TAUTH-000001",
          f"released Trust Plane allocation is unchanged (got {trust_id})")

# --- Modes -------------------------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    for directory in sorted(Path(tmp).joinpath("fabric").iterdir()):
        mode = stat.S_IMODE(directory.stat().st_mode)
        check(mode == 0o700, f"{directory.name} is created 0700 (got {oct(mode)})")

# --- No update, no delete ----------------------------------------------------
for forbidden in ("update", "delete", "remove", "rmtree"):
    check(not hasattr(FabricStore, forbidden),
          f"the store exposes no '{forbidden}' method")

# --- No default root, repository root refused --------------------------------
refuses(lambda: FabricStore("", expected_uid=UID, expected_gid=GID),
        "a store refuses an empty root")
refuses(lambda: FabricStore(root / "tools", expected_uid=UID, expected_gid=GID),
        "a store refuses a root inside the repository")

# --- Containment: symlink and traversal, unresolved-first --------------------
# Defect caught: resolving before inspecting, so a broken symlink disappears
# and Path.exists() reports False for the case that must refuse.
with TemporaryDirectory() as tmp:
    outside = Path(tmp) / "outside"
    outside.mkdir()
    linked_root = Path(tmp) / "linked-root"
    linked_root.symlink_to(outside)
    refuses(lambda: FabricStore(linked_root, expected_uid=UID, expected_gid=GID),
            "__init__ refuses a symlinked store root")

    broken = Path(tmp) / "broken-root"
    broken.symlink_to(Path(tmp) / "does-not-exist")
    refuses(lambda: FabricStore(broken, expected_uid=UID, expected_gid=GID),
            "__init__ refuses a broken symlinked root")
    refuses(lambda: FabricStore.open_for_read(broken, expected_uid=UID, expected_gid=GID),
            "open_for_read refuses a broken symlinked root")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    fabric_root = Path(tmp) / "fabric"
    escape = Path(tmp) / "escape.yaml"
    escape.write_text("escaped: true\n", encoding="utf-8")

    definitions = fabric_root / "capability-definitions"
    if definitions.is_dir():
        linked_record = definitions / "CAPDEF-0001.yaml"
        linked_record.symlink_to(escape)
        refuses(lambda: store.read_record("capability-definition", "CAPDEF-0001"),
                "read_record refuses a symlinked record")
        refuses(lambda: store.list_records("capability-definition"),
                "list_records refuses a symlinked record")
        refuses(lambda: store.validate(),
                "validate refuses a symlinked record")
        refuses(lambda: store.counts(),
                "counts refuses a symlinked record")
    else:
        bad("the store creates a record directory per accepted kind")

    refuses(lambda: store.path_for("capability-definition", "../../escape"),
            "path_for refuses a traversing identifier")
    refuses(lambda: store._directory("capability-definition/../.."),
            "_directory refuses a traversing kind")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    sequences = Path(tmp) / "fabric" / "sequences"
    if sequences.is_dir():
        seq = sequences / "capability-definition.seq"
        if seq.exists():
            seq.unlink()
        seq.symlink_to(Path(tmp) / "elsewhere.seq")
        refuses(lambda: store.allocate_id("capability-definition"),
                "allocate_id refuses a symlinked sequence file")
    else:
        bad("the store creates a sequences directory")

# --- Residue: a pre-existing temporary is evidence, not debris to clear ------
# Defect caught: write_atomic opens the temp with O_TRUNC and unlinks it in
# `finally`, destroying an interrupted-write artifact.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    destination = store.path_for("capability-definition", "CAPDEF-0001")
    temporary = destination.with_name(f".{destination.stem}.tmp")
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.write_text("interrupted write evidence\n", encoding="utf-8")
    before_bytes = temporary.read_bytes()
    before_stat = temporary.stat()

    refuses(lambda: store.write_atomic(destination, {"capability_id": "CAPDEF-0001"}),
            "write_atomic refuses when a temporary sibling already exists")
    check(temporary.exists(), "the pre-existing temporary artifact is not removed")
    check(temporary.read_bytes() == before_bytes,
          "the pre-existing temporary artifact keeps its bytes")
    check(temporary.stat().st_mtime_ns == before_stat.st_mtime_ns,
          "the pre-existing temporary artifact keeps its metadata")
    findings = store.validate()
    check(any("tmp" in str(finding) for finding in findings),
          f"residue is reported as observable debris ({findings})")
    store.counts()
    check(temporary.exists(), "another operation does not clean the residue")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    destination = store.path_for("capability-contract", "CCON-0001")
    temporary = destination.with_name(f".{destination.stem}.tmp")
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.symlink_to(Path(tmp) / "no-such-target")
    refuses(lambda: store.write_atomic(destination, {"contract_id": "CCON-0001"}),
            "write_atomic refuses a broken-symlink temporary sibling")
    check(temporary.is_symlink(), "the broken-symlink residue is left in place")

# --- Deterministic commit race (AC 34, FC 13) --------------------------------
# Defect caught: without O_EXCL, writer B truncates writer A's synced temporary
# content, and either writer's `finally` can unlink the other's inode.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    destination = store.path_for("capability-host", "CHOST-0001")
    a_paused = threading.Event()
    a_release = threading.Event()
    outcomes = {}

    class PausingStore(type(store)):
        def _pre_link_sync_point(self, destination, temporary):  # noqa: A002
            a_paused.set()
            if not a_release.wait(timeout=10):
                raise AssertionError("commit-race coordinator timed out")

    paused_store = PausingStore(
        Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)

    def writer_a():
        try:
            paused_store.write_atomic(destination, {"capability_host_id": "CHOST-0001",
                                                    "writer": "A"})
            outcomes["a"] = "committed"
        except Exception as error:  # noqa: BLE001
            outcomes["a"] = f"{type(error).__name__}"

    def writer_b():
        if not a_paused.wait(timeout=10):
            outcomes["b"] = "timeout waiting for A"
            return
        try:
            store.write_atomic(destination, {"capability_host_id": "CHOST-0001",
                                             "writer": "B"})
            outcomes["b"] = "committed"
        except Exception as error:  # noqa: BLE001
            outcomes["b"] = f"{type(error).__name__}"
        finally:
            a_release.set()

    thread_a = threading.Thread(target=writer_a)
    thread_b = threading.Thread(target=writer_b)
    thread_a.start()
    thread_b.start()
    thread_a.join(timeout=20)
    thread_b.join(timeout=20)
    check(not thread_a.is_alive() and not thread_b.is_alive(),
          "the commit race completes within its bounded wait")

    check(outcomes.get("b") not in (None, "committed"),
          f"the losing writer receives a storage conflict (got {outcomes.get('b')})")
    check("replay" not in str(outcomes.get("b", "")).lower(),
          "the storage conflict is never classified as replay")
    check(outcomes.get("a") == "committed",
          f"the paused writer still commits after release (got {outcomes.get('a')})")
    if destination.exists():
        committed = destination.read_text(encoding="utf-8")
        check("A" in committed and "B" not in committed,
              "the committed record is writer A's payload, with no silent overwrite")
    else:
        bad("the paused writer's record is committed")

# --- Increment 2 synchronisation seams ---------------------------------------
# The accepted plan lists five seams under "Seams introduced here": four on
# ImmutableStore and one Fabric-only. Four are already exercised above through
# allocation, exclusive temporary creation, and the commit race. These two are
# not, so they are asserted directly rather than assumed.
#
#   FabricStore._test_sync_point(phase, request_id)  -- no-op; writes nothing
#   ImmutableStore.request_critical_section(id)      -- no-op; yields immediately
#
# Increment 12 gives the second one a real lock. Increment 2 must not.
import inspect  # noqa: E402


def tree_snapshot(base):
    """Everything under `base`, with the metadata a write would disturb."""
    entries = []
    for item in sorted(Path(base).rglob("*")):
        info = item.lstat()
        entries.append((str(item.relative_to(base)), info.st_mode, info.st_size,
                        info.st_mtime_ns))
    return entries


with TemporaryDirectory() as tmp:
    store = opened(tmp)
    fabric_root = Path(tmp) / "fabric"

    # --- _test_sync_point ---------------------------------------------------
    has_sync_point = hasattr(store, "_test_sync_point")
    check(has_sync_point, "the store exposes the _test_sync_point seam")
    check(not hasattr(store, "test_sync_point"),
          "the synchronisation seam stays private")

    if has_sync_point:
        params = list(inspect.signature(store._test_sync_point).parameters)
        check(params == ["phase", "request_id"],
              f"_test_sync_point takes (phase, request_id) (got {params})")

        before = tree_snapshot(fabric_root)
        returned = store._test_sync_point("after_replay_miss", "request-0001")
        after = tree_snapshot(fabric_root)
        check(returned is None, "_test_sync_point returns None")
        check(before == after, "_test_sync_point writes nothing")

        # Callable repeatedly and for any phase: it carries no state.
        store._test_sync_point("lock_contended", "request-0001")
        store._test_sync_point("after_replay_miss", "request-0002")
        check(tree_snapshot(fabric_root) == before,
              "repeated _test_sync_point calls write nothing")
    else:
        bad("_test_sync_point accepts (phase, request_id)")
        bad("_test_sync_point returns None")
        bad("_test_sync_point writes nothing")

    # --- request_critical_section -------------------------------------------
    has_section = hasattr(store, "request_critical_section")
    check(has_section, "the store exposes the request_critical_section seam")

    if has_section:
        section_params = list(inspect.signature(store.request_critical_section).parameters)
        check(section_params == ["request_id"],
              f"request_critical_section takes (request_id) (got {section_params})")

        before_section = tree_snapshot(fabric_root)
        with store.request_critical_section("request-0001") as yielded:
            check(yielded is None, "request_critical_section yields nothing")
            check(tree_snapshot(fabric_root) == before_section,
                  "entering the critical section creates nothing")
        check(tree_snapshot(fabric_root) == before_section,
              "leaving the critical section creates nothing")

        # Increment 12 introduces the lock artefact. Increment 2 must not.
        check(not (fabric_root / "sequences" / "request_identity.lock").exists(),
              "no request lock artefact exists at increment 2")

        # A no-op yields immediately; a real lock would deadlock on re-entry.
        # Bounded and daemonised so a regression fails rather than hangs.
        entered = threading.Event()

        def nested_entry():
            with store.request_critical_section("request-0001"):
                with store.request_critical_section("request-0001"):
                    entered.set()

        nested_thread = threading.Thread(target=nested_entry, daemon=True)
        nested_thread.start()
        check(entered.wait(timeout=5),
              "the critical section is a no-op and does not block on re-entry")

        # The seam composes with the ordinary store lifecycle.
        with store.request_critical_section("request-0002"):
            written = store.write_atomic(
                store.path_for("capability-route", "CROUTE-0001"),
                {"route_id": "CROUTE-0001"})
        check(written.exists(), "a record still commits inside the critical section")
    else:
        bad("request_critical_section takes (request_id)")
        bad("request_critical_section yields nothing")
        bad("the critical section is a no-op and does not block on re-entry")

    # Neither seam smuggles in later-increment behaviour.
    for later in ("acquire", "release", "lock", "replay_lookup", "admit",
                  "evaluate_eligibility", "select"):
        check(not hasattr(store, later),
              f"the store exposes no '{later}' behaviour at increment 2")


# --- The model-oriented write path (increment 2 correction) ------------------
# Defect caught: write() and the inherited write_record() both read `record.id`,
# copied from the Trust Plane, whose records carry one. No accepted fabric
# record does -- each kind names its own identity field -- so the public write
# path raises AttributeError for all eight kinds and can persist none of them.
import yaml  # noqa: E402
from datetime import datetime, timezone  # noqa: E402

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

WHEN = datetime(2026, 8, 5, 9, 0, 0, tzinfo=timezone.utc)
UNTIL = datetime(2026, 8, 6, 9, 0, 0, tzinfo=timezone.utc)
ORIGIN = {"class": "declared", "source": "operator"}


def fixture_evidence(kind):
    """The evidence every persisted record must carry, written literally.

    Increment 2 proved the physical writer before evidence existed. Increment 4
    requires C1 to refuse a record without it, so these fixtures now carry the
    evidence a real record would -- literal, so they stay independent of the
    assembler under test.
    """
    evidence = {
        "actor": "operator:cschott",
        "approving_authority": "operator:cschott",
        "causal_references": [],
        "trust_evidence_references": [],
        "reason_category": "declaration",
        "recorded_at": "2026-08-05T09:00:00+00:00",
        "request_id": "request-fixture-0001",
        "request_digest": "sha256:" + "0" * 64,
    }
    if kind == "capability-advertisement":
        # Published by the subject as itself; no human operator approves it.
        evidence["actor"] = "host:CHOST-0001"
        evidence["approving_authority"] = None
        evidence["reason_category"] = "advertisement-registration"
    elif kind == "capability-selection":
        evidence["actor"] = "fabric:selection"
        evidence["approving_authority"] = None
        evidence["reason_category"] = "selection"
    elif kind == "capability-host":
        evidence["reason_category"] = "subject-admission"
        evidence["trust_evidence_references"] = ["TAUTH-000001"]
    elif kind == "capability-instance":
        evidence["reason_category"] = "instance-admission"
        evidence["trust_evidence_references"] = ["TAUTH-000002", "TAUTH-000001"]
    elif kind == "capability-route":
        evidence["reason_category"] = "route-change"
    return evidence


def accepted_records():
    """One of every accepted kind. Identifiers and destinations are literal."""
    return (
        ("capability-definition", "capability-definitions", "CAPDEF-0001",
         "capability_id", CapabilityDefinition(
             capability_id="CAPDEF-0001", name="summarise text",
             description="Reduce a document to its essentials.",
             effect_class="read-only", contract_ids=("CCON-0001",),
             provenance=ORIGIN,
             evidence=fixture_evidence("capability-definition"))),
        ("capability-contract", "capability-contracts", "CCON-0001",
         "contract_id", CapabilityContract(
             contract_id="CCON-0001", capability_id="CAPDEF-0001",
             contract_version="1.0.0", effect_class="read-only",
             determinism_class="deterministic", request_shape={"text": "string"},
             response_shape={"summary": "string"}, failure_modes=("unavailable",),
             resource_requirements={"memory_mb": 512}, compatible_with=(),
             provenance=ORIGIN,
             evidence=fixture_evidence("capability-contract"))),
        ("capability-package", "capability-packages", "CPKG-0001",
         "capability_package_id", CapabilityPackage(
             capability_package_id="CPKG-0001", capability_id="CAPDEF-0001",
             contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
             package_version="1.0.0",
             artifact_reference="oci://registry.invalid/summarise",
             resource_requirements={"memory_mb": 512},
             trust_domain="schott-platform", provenance=ORIGIN,
             evidence=fixture_evidence("capability-package"))),
        ("capability-host", "capability-hosts", "CHOST-0001",
         "capability_host_id", CapabilityHost(
             capability_host_id="CHOST-0001", node_identity_reference="node/schai",
             fabric_node_trust_record_id="TAUTH-000001",
             verified_resource_profile={"memory_mb": 8192},
             location_class="on-premises", data_classification_ceiling="internal",
             availability_intent="available", provenance=ORIGIN,
             evidence=fixture_evidence("capability-host"))),
        ("capability-advertisement", "capability-advertisements", "CADV-000001",
         "advertisement_id", CapabilityAdvertisement(
             advertisement_id="CADV-000001", capability_host_id="CHOST-0001",
             capability_package_id="CPKG-0001", contract_id="CCON-0001",
             satisfied_contract_versions=("1.0.0",),
             advertised_resource_profile={"memory_mb": 512},
             observed_at=WHEN, valid_until=UNTIL, provenance=ORIGIN,
             evidence=fixture_evidence("capability-advertisement"))),
        ("capability-instance", "capability-instances", "CINST-000001",
         "instance_id", CapabilityInstance(
             instance_id="CINST-000001", capability_id="CAPDEF-0001",
             capability_package_id="CPKG-0001", capability_host_id="CHOST-0001",
             contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
             verified_resource_profile={"memory_mb": 512},
             admission_decision_id="TDEC-000001",
             package_trust_record_id="TAUTH-000002",
             host_trust_record_id="TAUTH-000001",
             effective_scope={"data_classification": "internal"},
             admitted_at=WHEN, admitted_until=UNTIL,
             advertisement_id="CADV-000001", provenance=ORIGIN,
             evidence=fixture_evidence("capability-instance"))),
        ("capability-route", "capability-routes", "CROUTE-0001",
         "route_id", CapabilityRoute(
             route_id="CROUTE-0001", route_version=1, capability_id="CAPDEF-0001",
             contract_id="CCON-0001", accepted_contract_versions=("1.0.0",),
             locality="local-only", candidate_instances=("CINST-000001",),
             data_classification="internal", provenance=ORIGIN,
             evidence=fixture_evidence("capability-route"))),
        ("capability-selection", "capability-selections", "CSEL-000001",
         "selection_id", CapabilitySelection(
             selection_id="CSEL-000001", route_id="CROUTE-0001", route_version=1,
             request_class={"data_classification": "internal"},
             considered_candidates=("CINST-000001",), excluded_candidates=(),
             selected_instance_id="CINST-000001",
             selection_reason="first eligible candidate in declared order",
             selected_at=WHEN, provenance=ORIGIN,
             evidence=fixture_evidence("capability-selection"))),
    )


def refuses_fabric(callable_, message):
    """Refused, and refused as a fabric refusal -- not as an attribute slip."""
    try:
        callable_()
    except FabricError:
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__} instead of FabricError)")
    else:
        bad(f"{message} (was accepted instead of refused)")


ACCEPTED = accepted_records()
check(len(ACCEPTED) == 8 and {entry[0] for entry in ACCEPTED} == set(RECORD_MODELS),
      "the write path is exercised for every accepted record kind and no other")

# No accepted record carries a universal identifier, so the store cannot read one.
for kind, _, _, _, record in ACCEPTED:
    check(not hasattr(record, "id"),
          f"a {kind} record carries no synthetic 'id' attribute")

# Both public model-oriented names must reach the same guarded destination.
for entry_point in ("write", "write_record"):
    for kind, directory, identifier, field, record in ACCEPTED:
        with TemporaryDirectory() as tmp:
            store = opened(tmp)
            expected = Path(tmp) / "fabric" / directory / f"{identifier}.yaml"
            try:
                written = getattr(store, entry_point)(kind, record)
            except Exception as error:  # noqa: BLE001
                bad(f"{entry_point}() persists a {kind} record "
                    f"(raised {type(error).__name__})")
                continue
            check(Path(written) == expected,
                  f"{entry_point}() writes a {kind} record to {directory}/{identifier}.yaml")
            check(expected.is_file(), f"{entry_point}() leaves a {kind} record on disk")
            stored = yaml.safe_load(expected.read_text(encoding="utf-8"))
            check(isinstance(stored, dict) and stored.get(field) == identifier,
                  f"the stored {kind} record carries {field} == {identifier}")
            check(isinstance(stored, dict) and stored.get("kind") == kind,
                  f"the stored {kind} record declares its kind")
            check(isinstance(stored, dict)
                  and stored.get("schema_version") == SUPPORTED_SCHEMA_VERSION,
                  f"the stored {kind} record declares the supported schema version")
            check(stat.S_IMODE(expected.lstat().st_mode) == 0o600,
                  f"a {kind} record written through {entry_point}() is mode 0600")
            residue = expected.with_name(f".{expected.stem}.tmp")
            check(not residue.exists(),
                  f"{entry_point}() leaves no temporary behind for a {kind} record")
            # Written once means written once, by either name.
            refuses_fabric(lambda: getattr(store, entry_point)(kind, record),
                           f"{entry_point}() refuses to overwrite an existing {kind} record")

# An object that is not the record it claims to be is refused, not guessed at.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    definition = ACCEPTED[0][4]
    for entry_point in ("write", "write_record"):
        refuses_fabric(lambda: getattr(store, entry_point)("capability-definition", object()),
                       f"{entry_point}() refuses an object that is not a record")
        refuses_fabric(lambda: getattr(store, entry_point)("capability-definition", None),
                       f"{entry_point}() refuses None")
        refuses_fabric(lambda: getattr(store, entry_point)(
                    "capability-definition", {"capability_id": "CAPDEF-0001"}),
                       f"{entry_point}() refuses a bare mapping")
        refuses_fabric(lambda: getattr(store, entry_point)("capability-contract", definition),
                       f"{entry_point}() refuses a record supplied under the wrong kind")
        refuses_fabric(lambda: getattr(store, entry_point)("ninth-record-kind", definition),
                       f"{entry_point}() refuses an unknown record kind")
    check(store.counts() == {kind: 0 for kind in store.record_dirs},
          "a refused write persists nothing")

# The correction does not bypass containment: write() still reaches path_for().
with TemporaryDirectory() as tmp:
    outside = Path(tmp) / "outside"
    outside.mkdir()
    fabric = Path(tmp) / "fabric"
    fabric.mkdir(mode=0o700)
    for name in (*FabricStore.record_dirs.values(), *FabricStore.extra_dirs):
        if name != "capability-definitions":
            (fabric / name).mkdir(mode=0o700)
    (fabric / "capability-definitions").symlink_to(outside)
    refuses_fabric(lambda: FabricStore(fabric, expected_uid=UID, expected_gid=GID),
                   "a symlinked record directory is still refused after the correction")

print(f"__FAILURES__={failures}")
STOREPY
)"
printf '%s\n' "${STORE_OUTPUT}" | grep -v '^__FAILURES__=' || true
STORE_FAILURES="$(printf '%s\n' "${STORE_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${STORE_FAILURES}" ]]; then
  fail "fabric store validation did not report a result"
else
  FAILURES=$((FAILURES + STORE_FAILURES))
fi

# --- Record validator, C2 (increment 3) --------------------------------------
VALIDATOR_OUTPUT="$(python3 - "${ROOT}" <<'VALIDATORPY' 2>&1 || true
import os
import stat
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml

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


def reports(store, message):
    """Validation must answer, never raise. Returns the report or None."""
    try:
        return validate_store(store)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__})")
        return None


from tools.fabric.store import FabricStore  # noqa: E402
# The import that must fail before increment 3 exists.
from tools.fabric.validator import validate_store  # noqa: E402
import tools.fabric.validator as validator_module  # noqa: E402

UID = os.geteuid()
GID = os.getegid()

VERSION = "schott-platform/v1"
STAMP = "2026-08-04T12:00:00+00:00"
LATER = "2026-08-05T12:00:00+00:00"
PROV = {"declared_by": "operator", "declared_at": STAMP}

DIRS = {
    "capability-definition": "capability-definitions",
    "capability-contract": "capability-contracts",
    "capability-package": "capability-packages",
    "capability-host": "capability-hosts",
    "capability-advertisement": "capability-advertisements",
    "capability-instance": "capability-instances",
    "capability-route": "capability-routes",
    "capability-selection": "capability-selections",
}

# One internally consistent record of every accepted kind. Written literally
# rather than produced by the models, so the expected state is independent of
# the code under test.
DEFINITION = {
    "capability_id": "CAPDEF-0001",
    "name": "summarise text",
    "description": "Reduce a document to its essentials.",
    "effect_class": "read-only",
    "contract_ids": ["CCON-0001"],
    "provenance": PROV,
}
CONTRACT = {
    "contract_id": "CCON-0001",
    "capability_id": "CAPDEF-0001",
    "contract_version": "1.0.0",
    "effect_class": "read-only",
    "determinism_class": "deterministic",
    "request_shape": {"text": "string"},
    "response_shape": {"summary": "string"},
    "failure_modes": ["unavailable"],
    "resource_requirements": {"memory_mb": 512},
    "compatible_with": [],
    "provenance": PROV,
}
PACKAGE = {
    "capability_package_id": "CPKG-0001",
    "capability_id": "CAPDEF-0001",
    "contract_id": "CCON-0001",
    "satisfied_contract_versions": ["1.0.0"],
    "package_version": "1.0.0",
    "artifact_reference": "oci://registry.invalid/summarise",
    "resource_requirements": {"memory_mb": 512},
    "trust_domain": "schott-platform",
    "provenance": PROV,
}
HOST = {
    "capability_host_id": "CHOST-0001",
    "node_identity_reference": "node/schai",
    "fabric_node_trust_record_id": "TAUTH-000001",
    "verified_resource_profile": {"memory_mb": 8192},
    "location_class": "on-premises",
    "data_classification_ceiling": "internal",
    "availability_intent": "available",
    "provenance": PROV,
}
ADVERTISEMENT = {
    "advertisement_id": "CADV-000001",
    "capability_host_id": "CHOST-0001",
    "capability_package_id": "CPKG-0001",
    "contract_id": "CCON-0001",
    "satisfied_contract_versions": ["1.0.0"],
    "advertised_resource_profile": {"memory_mb": 512},
    "observed_at": STAMP,
    "valid_until": LATER,
    "provenance": PROV,
}
INSTANCE = {
    "instance_id": "CINST-000001",
    "capability_id": "CAPDEF-0001",
    "capability_package_id": "CPKG-0001",
    "capability_host_id": "CHOST-0001",
    "contract_id": "CCON-0001",
    "satisfied_contract_versions": ["1.0.0"],
    "verified_resource_profile": {"memory_mb": 512},
    "admission_decision_id": "TDEC-000001",
    "package_trust_record_id": "TAUTH-000002",
    "host_trust_record_id": "TAUTH-000001",
    "effective_scope": {"data_classification": "internal"},
    "admitted_at": STAMP,
    "admitted_until": LATER,
    "advertisement_id": "CADV-000001",
    "provenance": PROV,
}
ROUTE = {
    "route_id": "CROUTE-0001",
    "route_version": 1,
    "capability_id": "CAPDEF-0001",
    "contract_id": "CCON-0001",
    "accepted_contract_versions": ["1.0.0"],
    "locality": "local-only",
    "candidate_instances": ["CINST-000001"],
    "data_classification": "internal",
    "provenance": PROV,
}
SELECTION = {
    "selection_id": "CSEL-000001",
    "route_id": "CROUTE-0001",
    "route_version": 1,
    "request_class": {"data_classification": "internal"},
    "considered_candidates": ["CINST-000001"],
    "excluded_candidates": [],
    "selected_instance_id": "CINST-000001",
    "selection_reason": "first eligible candidate in declared order",
    "selected_at": STAMP,
    "provenance": PROV,
}

CONSISTENT = (
    ("capability-definition", "CAPDEF-0001", DEFINITION),
    ("capability-contract", "CCON-0001", CONTRACT),
    ("capability-package", "CPKG-0001", PACKAGE),
    ("capability-host", "CHOST-0001", HOST),
    ("capability-advertisement", "CADV-000001", ADVERTISEMENT),
    ("capability-instance", "CINST-000001", INSTANCE),
    ("capability-route", "CROUTE-0001", ROUTE),
    ("capability-selection", "CSEL-000001", SELECTION),
)


def serialise(kind, fields):
    payload = {"schema_version": VERSION, "kind": kind}
    payload.update(fields)
    return yaml.safe_dump(payload, sort_keys=True, default_flow_style=False)


def built(tmp, entries=CONSISTENT, sequences=True):
    """A populated store. Fixtures are placed directly, never through a writer."""
    fabric = Path(tmp) / "fabric"
    store = FabricStore(fabric, expected_uid=UID, expected_gid=GID)
    highest = {}
    for kind, identifier, fields in entries:
        path = fabric / DIRS[kind] / f"{identifier}.yaml"
        path.write_text(serialise(kind, fields), encoding="utf-8")
        path.chmod(0o600)
        number = int(identifier.rsplit("-", 1)[1])
        highest[kind] = max(highest.get(kind, 0), number)
    if sequences:
        for kind, number in highest.items():
            sequence = fabric / "sequences" / f"{kind}.seq"
            sequence.write_text(f"{number}\n", encoding="utf-8")
            sequence.chmod(0o600)
    return store, fabric


def snapshot(base):
    """Every path, its mode, size, mtime and exact bytes. Repair shows up here."""
    entries = {}
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        content = path.read_bytes() if stat.S_ISREG(info.st_mode) else b""
        entries[str(path.relative_to(base))] = (
            stat.S_IMODE(info.st_mode), info.st_size, info.st_mtime_ns, content)
    return entries


def named(report, text):
    return any(text in str(finding) for finding in report.findings)


# --- The accepted boundary: a consistent store has nothing to report ---------
# Defect caught: a validator that delegates to the inherited structural
# validate(), which looks for an 'id' key no fabric record carries, and so
# reports every correct record as broken.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    before = snapshot(fabric)
    report = reports(store, "a consistent store validates without raising")
    if report is not None:
        ok("a consistent store validates without raising")
        check(tuple(report.findings) == (),
              "a consistent store produces no findings")
        check(dict(report.counts) == {kind: 1 for kind in DIRS},
              "validation reports a count for every accepted record kind")
        repeated = validate_store(store)
        check(tuple(repeated.findings) == tuple(report.findings),
              "repeated validation of a consistent store returns identical findings")
        check(dict(repeated.counts) == dict(report.counts),
              "repeated validation of a consistent store returns identical counts")
    check(snapshot(fabric) == before,
          "validating a consistent store writes nothing")

# --- AC 31, FC 3: malformed content becomes a finding, never an exception ----
# Defect caught: reading a record with yaml.safe_load and letting a parser
# error escape, which turns one unreadable file into a crashed validation.
MALFORMED = (
    ("CAPDEF-0002.yaml", "capability_id: [unclosed\n", "unparseable YAML"),
    ("CAPDEF-0003.yaml", "- one\n- two\n", "a YAML sequence rather than a mapping"),
    ("CAPDEF-0004.yaml", "just a bare scalar\n", "a bare scalar rather than a mapping"),
    ("CAPDEF-0005.yaml", "", "an empty file"),
)
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    for name, text, description in MALFORMED:
        (fabric / "capability-definitions" / name).write_text(text, encoding="utf-8")
        (fabric / "capability-definitions" / name).chmod(0o600)
    before = snapshot(fabric)
    report = reports(store, "malformed content becomes a finding rather than an exception")
    if report is not None:
        ok("malformed content becomes a finding rather than an exception")
        for name, _, description in MALFORMED:
            check(named(report, name), f"{description} is reported as a finding naming {name}")
        check(tuple(report.findings) == tuple(sorted(report.findings)),
              "findings over a malformed store are returned in sorted order")
        check(tuple(validate_store(store).findings) == tuple(report.findings),
              "findings over a malformed store are identical across repeated runs")
    check(snapshot(fabric) == before,
          "a malformed record is not repaired, removed, renamed, or rewritten")

# --- AC 32: an unsupported or absent stored version fails closed ------------
# Defect caught: a validator that guesses at, or silently migrates, a record
# written against a schema version this code does not know.
UNSUPPORTED = dict(DEFINITION, capability_id="CAPDEF-0006")
ABSENT_VERSION = dict(DEFINITION, capability_id="CAPDEF-0007")
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    unsupported = fabric / "capability-definitions" / "CAPDEF-0006.yaml"
    unsupported.write_text(
        yaml.safe_dump(dict(UNSUPPORTED, schema_version="schott-platform/v2",
                            kind="capability-definition"), sort_keys=True),
        encoding="utf-8")
    unsupported.chmod(0o600)
    versionless = fabric / "capability-definitions" / "CAPDEF-0007.yaml"
    versionless.write_text(
        yaml.safe_dump(dict(ABSENT_VERSION, kind="capability-definition"), sort_keys=True),
        encoding="utf-8")
    versionless.chmod(0o600)
    before = snapshot(fabric)
    report = reports(store, "an unsupported stored version becomes a finding")
    if report is not None:
        ok("an unsupported stored version becomes a finding")
        check(named(report, "CAPDEF-0006.yaml"),
              "an unsupported schema version is reported as a finding")
        check(named(report, "CAPDEF-0007.yaml"),
              "a record declaring no schema version is reported as a finding")
    check(snapshot(fabric) == before,
          "a record on an unknown schema version is never migrated in place")

# --- FC 5: a missing reference is reported for every referenced class -------
# Defect caught: reference checking that covers only the records the validator
# happens to iterate first, leaving whole classes of dangling reference silent.
DANGLING = (
    ("CAPDEF", "capability-contract", "CCON-0002",
     dict(CONTRACT, contract_id="CCON-0002", capability_id="CAPDEF-0009"), "CAPDEF-0009"),
    ("CCON", "capability-package", "CPKG-0002",
     dict(PACKAGE, capability_package_id="CPKG-0002", contract_id="CCON-0009"), "CCON-0009"),
    ("CPKG", "capability-advertisement", "CADV-000002",
     dict(ADVERTISEMENT, advertisement_id="CADV-000002",
          capability_package_id="CPKG-0009"), "CPKG-0009"),
    ("CHOST", "capability-advertisement", "CADV-000003",
     dict(ADVERTISEMENT, advertisement_id="CADV-000003",
          capability_host_id="CHOST-0009"), "CHOST-0009"),
    ("CADV", "capability-instance", "CINST-000002",
     dict(INSTANCE, instance_id="CINST-000002",
          advertisement_id="CADV-000009"), "CADV-000009"),
    ("CINST", "capability-route", "CROUTE-0002",
     dict(ROUTE, route_id="CROUTE-0002",
          candidate_instances=["CINST-000009"]), "CINST-000009"),
    ("CROUTE", "capability-selection", "CSEL-000002",
     dict(SELECTION, selection_id="CSEL-000002", route_id="CROUTE-0009"), "CROUTE-0009"),
)
for label, kind, identifier, fields, missing in DANGLING:
    with TemporaryDirectory() as tmp:
        store, fabric = built(tmp, CONSISTENT + ((kind, identifier, fields),))
        before = snapshot(fabric)
        report = reports(store, f"a missing {label} reference becomes a finding")
        if report is not None:
            check(named(report, missing),
                  f"a missing {label} reference is reported as a finding naming {missing}")
        check(snapshot(fabric) == before,
              f"a missing {label} reference creates nothing and repairs nothing")

# --- Identifier, filename, and record kind must agree -----------------------
# Defect caught: trusting the filename, or trusting the stored identifier,
# instead of requiring the reconstructed record to agree with where it is.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    misfiled = fabric / "capability-definitions" / "CAPDEF-0008.yaml"
    misfiled.write_text(serialise("capability-definition", DEFINITION), encoding="utf-8")
    misfiled.chmod(0o600)
    wrong_kind = fabric / "capability-contracts" / "CCON-0003.yaml"
    wrong_kind.write_text(
        serialise("capability-definition", dict(DEFINITION, capability_id="CAPDEF-0010")),
        encoding="utf-8")
    wrong_kind.chmod(0o600)
    before = snapshot(fabric)
    report = reports(store, "an identifier/filename disagreement becomes a finding")
    if report is not None:
        ok("an identifier/filename disagreement becomes a finding")
        check(named(report, "CAPDEF-0008.yaml"),
              "a record whose stored identifier disagrees with its filename is reported")
        check(named(report, "CCON-0003.yaml"),
              "a record whose kind disagrees with its directory is reported")
    check(snapshot(fabric) == before,
          "a misfiled record is not renamed, moved, or rewritten")

# --- Interrupted-write residue is reported, never cleared -------------------
# Defect caught: a validator that tidies debris away, destroying the only
# evidence that a write was interrupted.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    residue = fabric / "capability-definitions" / ".CAPDEF-0011.tmp"
    residue.write_text("capability_id: CAPDEF-0011\n", encoding="utf-8")
    residue.chmod(0o600)
    before = snapshot(fabric)
    report = reports(store, "temporary residue becomes a finding")
    if report is not None:
        ok("temporary residue becomes a finding")
        check(named(report, ".CAPDEF-0011.tmp"),
              "residue from an interrupted write is reported as a finding")
    check(residue.exists(), "residue is left in place, not cleared")
    check(snapshot(fabric) == before, "reporting residue changes nothing on disk")

# --- FC 16: derived state is reported, never trusted and never repaired -----
# Defect caught: a validator that quietly rewrites a sequence file to agree
# with the records, which repairs derived state and erases the discrepancy.
DERIVED = (
    ("stale", "0\n"),
    ("corrupt", "not-a-number\n"),
)
for label, content in DERIVED:
    with TemporaryDirectory() as tmp:
        store, fabric = built(tmp)
        sequence = fabric / "sequences" / "capability-definition.seq"
        sequence.write_text(content, encoding="utf-8")
        sequence.chmod(0o600)
        before = snapshot(fabric)
        report = reports(store, f"a {label} derived artefact becomes a finding")
        if report is not None:
            check(named(report, "capability-definition.seq"),
                  f"a {label} sequence file is reported as a finding")
        check(sequence.read_text(encoding="utf-8") == content,
              f"a {label} sequence file is not recomputed or repaired")
        check(snapshot(fabric) == before,
              f"reporting a {label} derived artefact changes nothing on disk")

with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    sequence = fabric / "sequences" / "capability-definition.seq"
    sequence.unlink()
    before = snapshot(fabric)
    report = reports(store, "a missing derived artefact becomes a finding")
    if report is not None:
        check(named(report, "capability-definition.seq"),
              "a missing sequence file is reported as a finding")
    check(not sequence.exists(),
          "a missing sequence file is not recreated by validation")
    check(snapshot(fabric) == before,
          "reporting a missing derived artefact changes nothing on disk")

# --- Fail-closed on type and datetime failures ------------------------------
# Defect caught: letting a TypeError or an unreadable timestamp escape as an
# exception instead of reporting the record that carries it.
ILL_TYPED = (
    ("capability-route", "CROUTE-0003", dict(ROUTE, route_id="CROUTE-0003",
                                             route_version="one"), "a non-integer route version"),
    ("capability-advertisement", "CADV-000004",
     dict(ADVERTISEMENT, advertisement_id="CADV-000004",
          observed_at="not a timestamp"), "an unreadable timestamp"),
    ("capability-advertisement", "CADV-000005",
     dict(ADVERTISEMENT, advertisement_id="CADV-000005",
          observed_at="2026-08-04T12:00:00"), "a timestamp carrying no offset"),
    ("capability-definition", "CAPDEF-0012",
     dict(DEFINITION, capability_id="CAPDEF-0012", trust_score=1), "an unknown field"),
    ("capability-definition", "CAPDEF-0013",
     dict(DEFINITION, capability_id="CAPDEF-0013", effect_class="unheard-of"),
     "an effect class outside the accepted vocabulary"),
)
for kind, identifier, fields, description in ILL_TYPED:
    with TemporaryDirectory() as tmp:
        store, fabric = built(tmp, CONSISTENT + ((kind, identifier, fields),))
        before = snapshot(fabric)
        report = reports(store, f"{description} becomes a finding")
        if report is not None:
            check(named(report, f"{identifier}.yaml"),
                  f"{description} is reported as a finding naming {identifier}.yaml")
        check(snapshot(fabric) == before,
              f"{description} is reported without being corrected")

# --- Read-only through a read-only handle -----------------------------------
# Defect caught: validation that initialises, backfills, or touches the store
# it was only asked to read.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    expected = tuple(validate_store(store).findings)
    reader = FabricStore.open_for_read(fabric, expected_uid=UID, expected_gid=GID)
    before = snapshot(fabric)
    report = reports(reader, "validation runs through a read-only handle")
    if report is not None:
        ok("validation runs through a read-only handle")
        check(tuple(report.findings) == expected,
              "a read-only handle returns the same findings as a writable one")
    check(snapshot(fabric) == before,
          "validating through a read-only handle writes nothing")

# --- Increment 3 stops at reporting -----------------------------------------
# Defect caught: a validator that grows repair, admission, eligibility, or the
# inspection surface that belongs to a later increment.
for later in ("repair", "fix", "clean", "normalise", "normalize", "rebuild",
              "recompute", "evaluate_eligibility", "compute_eligibility", "select",
              "admit", "inspect", "render", "verify_trust"):
    check(not hasattr(validator_module, later),
          f"the validator exposes no '{later}' behaviour at increment 3")

for absent in ("inspection.py", "cli.py", "eligibility.py", "selection.py",
               "admission.py", "trust.py"):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 3 creates no {absent}")


# --- Every exact file passes the store's guard (AC 39, FC 19) ----------------
# Defect caught: enumerating a directory the store guarded and then reading
# each entry directly. Ownership and containment are then enforced on the
# directory but not on the record or sequence file actually opened -- weaker
# than FabricStore.validate() and list_records(), which guard the exact path.
from tools.fabric.errors import FabricError  # noqa: E402


class RefusingStore(FabricStore):
    """The real store, with designated exact paths refused by its own guard.

    Ownership cannot be varied without privilege, so the refusal the accepted
    guard raises for a foreign-owned inode is raised here for a named path
    instead. Nothing else changes: every path not designated still goes
    through FabricStore._guard_path unmodified. If the validator never asks
    the guard about a file, the refusal never fires and the assertion fails --
    which is exactly what must be proven.
    """

    def refuse(self, *names):
        self._refused = frozenset(names)
        return self

    def _guard_path(self, path, description):
        if Path(path).name in getattr(self, "_refused", frozenset()):
            raise FabricError(f"{description} is not owned by the supplied uid/gid")
        return super()._guard_path(path, description)


def refusing(tmp, *names):
    """A consistent store whose accepted guard refuses the named exact paths."""
    fabric = Path(tmp) / "fabric"
    store = RefusingStore(fabric, expected_uid=UID, expected_gid=GID)
    for kind, identifier, fields in CONSISTENT:
        path = fabric / DIRS[kind] / f"{identifier}.yaml"
        path.write_text(serialise(kind, fields), encoding="utf-8")
        path.chmod(0o600)
        sequence = fabric / "sequences" / f"{kind}.seq"
        sequence.write_text("1\n", encoding="utf-8")
        sequence.chmod(0o600)
    store.refuse(*names)
    return store, fabric


def forensic(base):
    """Path inventory including inode identity and ownership, not just bytes."""
    entries = {}
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
            info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns, info.st_size,
            path.read_bytes() if stat.S_ISREG(info.st_mode) else b"")
    return entries


with TemporaryDirectory() as tmp:
    store, fabric = refusing(tmp, "CAPDEF-0001.yaml")
    before = forensic(fabric)
    report = reports(store, "a refused record file becomes a finding")
    if report is not None:
        ok("a refused record file becomes a finding")
        check(named(report, "CAPDEF-0001.yaml"),
              "a record refused by the exact-path guard is reported as a finding")
        # If the refused record had been read anyway it would still resolve the
        # references that point at it. It must not.
        check(any("CCON-0001.yaml" in str(finding) and "CAPDEF-0001" in str(finding)
                  for finding in report.findings),
              "a refused record is not parsed, so a reference to it stops resolving")
        check(tuple(report.findings) == tuple(sorted(report.findings)),
              "findings over a refused record are returned in sorted order")
        check(tuple(validate_store(store).findings) == tuple(report.findings),
              "findings over a refused record are identical across repeated runs")
    check(forensic(fabric) == before,
          "refusing a record file changes no byte, mode, owner, inode, or path")

with TemporaryDirectory() as tmp:
    store, fabric = refusing(tmp, "capability-definition.seq")
    before = forensic(fabric)
    report = reports(store, "a refused sequence file becomes a finding")
    if report is not None:
        ok("a refused sequence file becomes a finding")
        check(named(report, "capability-definition.seq"),
              "a sequence file refused by the exact-path guard is reported as a finding")
        check(tuple(validate_store(store).findings) == tuple(report.findings),
              "findings over a refused sequence file are identical across repeated runs")
    check(forensic(fabric) == before,
          "refusing a sequence file changes no byte, mode, owner, inode, or path")

# --- AC 39: a mode mismatch is reported and never corrected ------------------
# Defect caught: validation that reads a record whose mode was widened without
# saying so, or that quietly restores the mode it expected.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    widened = fabric / "capability-definitions" / "CAPDEF-0001.yaml"
    widened.chmod(0o644)
    loosened = fabric / "sequences" / "capability-contract.seq"
    loosened.chmod(0o640)
    before = forensic(fabric)
    report = reports(store, "a mode mismatch becomes a finding")
    if report is not None:
        ok("a mode mismatch becomes a finding")
        check(named(report, "CAPDEF-0001.yaml"),
              "a record file whose mode is not 0600 is reported as a finding")
        check(named(report, "capability-contract.seq"),
              "a sequence file whose mode is not 0600 is reported as a finding")
    check(stat.S_IMODE(widened.lstat().st_mode) == 0o644,
          "a wrong-mode record is left at the mode it was found with")
    check(stat.S_IMODE(loosened.lstat().st_mode) == 0o640,
          "a wrong-mode sequence file is left at the mode it was found with")
    check(forensic(fabric) == before,
          "reporting a mode mismatch changes no byte, mode, owner, inode, or path")

# --- Undecodable bytes are a finding, not a UnicodeDecodeError ---------------
# Defect caught: read_text() raising UnicodeDecodeError, which is a ValueError
# and not an OSError, so a record holding invalid UTF-8 escapes validation
# entirely instead of being reported.
INVALID_UTF8 = b"capability_id: \xff\xfe\x00 not utf-8\n"
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    undecodable = fabric / "capability-definitions" / "CAPDEF-0014.yaml"
    undecodable.write_bytes(INVALID_UTF8)
    undecodable.chmod(0o600)
    broken_sequence = fabric / "sequences" / "capability-host.seq"
    broken_sequence.write_bytes(INVALID_UTF8)
    broken_sequence.chmod(0o600)
    before = forensic(fabric)
    report = reports(store, "undecodable bytes become a finding rather than an exception")
    if report is not None:
        ok("undecodable bytes become a finding rather than an exception")
        check(named(report, "CAPDEF-0014.yaml"),
              "a record file that is not valid UTF-8 is reported as a finding")
        check(named(report, "capability-host.seq"),
              "a sequence file that is not valid UTF-8 is reported as a finding")
        check(not any("\\xff" in str(finding) or "0xff" in str(finding)
                      or "utf-8 not" in str(finding) or "byte 0x" in str(finding)
                      for finding in report.findings),
              "the finding names the file without quoting the bytes it could not decode")
        check(tuple(report.findings) == tuple(sorted(report.findings)),
              "findings over undecodable bytes are returned in sorted order")
        check(tuple(validate_store(store).findings) == tuple(report.findings),
              "findings over undecodable bytes are identical across repeated runs")
    check(undecodable.read_bytes() == INVALID_UTF8,
          "an undecodable record keeps the exact bytes it was found with")
    check(forensic(fabric) == before,
          "an undecodable file is not repaired, removed, rewritten, or quarantined")


# --- AC 39 / FC 19: a wrong mode refuses, it does not merely warn ------------
# Defect caught: reporting the mode and then reading the file anyway, so a
# record with the wrong permissions still reconstructs, still counts, and
# still satisfies every reference pointing at it -- reported, but not refused.
with TemporaryDirectory() as tmp:
    store, fabric = built(tmp)
    widened = fabric / "capability-definitions" / "CAPDEF-0001.yaml"
    widened.chmod(0o644)
    before = forensic(fabric)
    report = reports(store, "a wrong-mode record is refused")
    if report is not None:
        ok("a wrong-mode record is refused")
        check(named(report, "CAPDEF-0001.yaml"),
              "a wrong-mode record is reported as a finding")
        check(report.counts["capability-definition"] == 0,
              "a wrong-mode record is not counted as a validated record")
        # Four stored records point at CAPDEF-0001. If the refused file were
        # read anyway they would all still resolve, which is the whole defect.
        check(any("CCON-0001.yaml" in str(finding) and "CAPDEF-0001" in str(finding)
                  for finding in report.findings),
              "a wrong-mode record is not reconstructed, so a reference to it stops resolving")
        check(sum(1 for finding in report.findings
                  if "CAPDEF-0001.yaml" in str(finding)) == 1,
              "a refused record yields the mode finding and nothing derived from its contents")
        check(tuple(report.findings) == tuple(sorted(report.findings)),
              "findings over a wrong-mode record are returned in sorted order")
        check(tuple(validate_store(store).findings) == tuple(report.findings),
              "findings over a wrong-mode record are identical across repeated runs")
    check(stat.S_IMODE(widened.lstat().st_mode) == 0o644,
          "a refused wrong-mode record keeps the mode it was found with")
    check(forensic(fabric) == before,
          "refusing a wrong-mode record changes no byte, mode, owner, inode, or path")

# Content chosen so that parsing it would produce a distinguishable finding.
# If either appears, the refused file was interpreted after all.
REFUSED_SEQUENCES = (
    ("not-a-number\n", "does not hold a sequence number", "malformed numeric content"),
    ("0\n", "is behind the stored records", "a value behind the stored identifiers"),
)
for content, derived, description in REFUSED_SEQUENCES:
    with TemporaryDirectory() as tmp:
        store, fabric = built(tmp)
        sequence = fabric / "sequences" / "capability-definition.seq"
        sequence.write_text(content, encoding="utf-8")
        sequence.chmod(0o644)
        before = forensic(fabric)
        report = reports(store, f"a wrong-mode sequence file with {description} is refused")
        if report is not None:
            ok(f"a wrong-mode sequence file with {description} is refused")
            check(any("capability-definition.seq" in str(finding) and "mode" in str(finding)
                      for finding in report.findings),
                  f"a wrong-mode sequence file with {description} is reported")
            check(not any(derived in str(finding) for finding in report.findings),
                  f"a refused sequence file's {description} is never interpreted")
            check(sum(1 for finding in report.findings
                      if "capability-definition.seq" in str(finding)) == 1,
                  f"a refused sequence file with {description} yields exactly one finding")
            check(tuple(validate_store(store).findings) == tuple(report.findings),
                  f"findings over a wrong-mode sequence file with {description} repeat identically")
        check(sequence.read_text(encoding="utf-8") == content,
              f"a refused sequence file with {description} keeps its exact bytes")
        check(stat.S_IMODE(sequence.lstat().st_mode) == 0o644,
              f"a refused sequence file with {description} keeps the mode it was found with")
        check(forensic(fabric) == before,
              f"refusing a sequence file with {description} changes nothing on disk")

print(f"__FAILURES__={failures}")
VALIDATORPY
)"
printf '%s\n' "${VALIDATOR_OUTPUT}" | grep -v '^__FAILURES__=' || true
VALIDATOR_FAILURES="$(printf '%s\n' "${VALIDATOR_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${VALIDATOR_FAILURES}" ]]; then
  fail "fabric record validation did not report a result"
else
  FAILURES=$((FAILURES + VALIDATOR_FAILURES))
fi

# --- Request identity, digest, and evidence, C7 (increment 4) ----------------
IDENTITY_OUTPUT="$(python3 - "${ROOT}" <<'IDENTITYPY' 2>&1 || true
import hashlib
import inspect
import json
import os
import stat
import sys
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml

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


def refuses_fabric(callable_, message):
    try:
        callable_()
    except FabricError:
        ok(message)
    except Exception as error:  # noqa: BLE001
        bad(f"{message} (raised {type(error).__name__} instead of FabricError)")
    else:
        bad(f"{message} (was accepted instead of refused)")


from tools.fabric.errors import FabricError  # noqa: E402
from tools.fabric.store import FabricStore  # noqa: E402
from tools.fabric.models import RECORD_MODELS  # noqa: E402
# The import that must fail before increment 4 exists.
from tools.fabric.request_identity import (  # noqa: E402
    REPLAY_CONFLICT,
    REPLAY_EXACT,
    REPLAY_NEW,
    SUPPORTED_CANONICALISATION,
    SUPPORTED_DIGEST,
    compute_request_digest,
    replay_lookup,
    validate_request_id,
)
import tools.fabric.request_identity as identity_module  # noqa: E402
from tools.fabric.evidence import (  # noqa: E402
    REASON_CATEGORIES,
    assemble_evidence,
    validate_record_evidence,
)
import tools.fabric.evidence as evidence_module  # noqa: E402

UID = os.geteuid()
GID = os.getegid()

WHEN = datetime(2026, 8, 5, 9, 0, 0, tzinfo=timezone.utc)
UNTIL = WHEN + timedelta(days=1)
NAIVE = datetime(2026, 8, 5, 9, 0, 0)


class WitnessStore(FabricStore):
    """The real store, watching how the critical section and seam are used.

    Counts every entry into request_critical_section and records every
    _test_sync_point call, so the call *shape* the plan prescribes can be
    asserted rather than assumed. Nothing about store behaviour changes.
    """

    def __init__(self, *args, **kwargs):
        self.sync_points = []
        self.entries = 0
        self.depth = 0
        self.deepest = 0
        super().__init__(*args, **kwargs)

    def _test_sync_point(self, phase, request_id):
        self.sync_points.append((phase, request_id, self.depth))
        return super()._test_sync_point(phase, request_id)

    @contextmanager
    def request_critical_section(self, request_id):
        self.entries += 1
        self.depth += 1
        self.deepest = max(self.deepest, self.depth)
        try:
            with super().request_critical_section(request_id):
                yield
        finally:
            self.depth -= 1


def forensic(base):
    """Path inventory with inode identity and ownership, not just bytes."""
    entries = {}
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
            info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns, info.st_size,
            path.read_bytes() if stat.S_ISREG(info.st_mode) else b"")
    return entries


# --- Request identity is opaque, caller-supplied, and never derived (A8) -----
# Defect caught: a fabric that mints, parses, or infers structure from a value
# the caller owns, which would make replay depend on Fabric's opinion of it.
OPAQUE = ("x", "9f3", "not-a-uuid-at-all", "a-b-c", "R" * 200,
          "3f8b2c1d-0000-4000-8000-000000000000", "%^&*()+=", "0")
for candidate in OPAQUE:
    check(validate_request_id(candidate) == candidate,
          f"an opaque request_id of shape {candidate[:12]!r} is accepted unchanged")

UNSAFE = (
    (None, "None"),
    (b"bytes", "bytes rather than text"),
    (1234, "an integer"),
    ("", "an empty value"),
    ("R" * 201, "a value over the bounded length"),
    ("has space", "an embedded space"),
    ("line\nbreak", "an embedded newline"),
    ("tab\there", "an embedded tab"),
    ("null\x00byte", "an embedded null byte"),
    ("bell\x07", "an embedded control character"),
)
for value, description in UNSAFE:
    refuses_fabric(lambda v=value: validate_request_id(v),
                   f"a request_id carrying {description} fails closed")

for derived in ("generate_request_id", "new_request_id", "derive_request_id",
                "next_request_id", "allocate_request_id", "mint"):
    check(not hasattr(identity_module, derived),
          f"the fabric derives no request_id: no '{derived}'")

# Record identity is allocated by the store; request identity is not, and the
# two never meet.
for allocator in ("allocate_id", "path_for", "write", "write_atomic"):
    check(not hasattr(identity_module, allocator),
          f"request identity allocates no record identity: no '{allocator}'")

# --- The digest is the released sha256 canonical-JSON convention (A9) --------
# Defect caught: a second hashing convention, or a payload whose shape the
# caller cannot reproduce, which would make the digest unverifiable.
OPERATION = "declare-capability"
INPUTS = {"capability_id": "CAPDEF-0001", "effect_class": "read-only"}
digest = compute_request_digest(OPERATION, INPUTS)

expected_payload = {
    "canonicalisation": SUPPORTED_CANONICALISATION,
    "digest": SUPPORTED_DIGEST,
    "operation": OPERATION,
    "inputs": INPUTS,
}
expected_encoded = json.dumps(expected_payload, sort_keys=True,
                              separators=(",", ":"), default=str).encode("utf-8")
expected_digest = f"sha256:{hashlib.sha256(expected_encoded).hexdigest()}"

check(digest == expected_digest,
      "the digest is sha256 over canonical JSON with sorted keys and stable separators")
check(digest.startswith("sha256:") and len(digest) == 71,
      "the digest carries the released 'sha256:' prefix and 64 hex characters")
check(digest[7:] == digest[7:].lower() and all(c in "0123456789abcdef" for c in digest[7:]),
      "the digest hex is lowercase")
check(compute_request_digest(OPERATION, INPUTS) == digest,
      "the same supported canonical input digests identically every time")
check(compute_request_digest("declare-contract", INPUTS) != digest,
      "the operation type participates in the digest")
check(compute_request_digest(OPERATION, dict(INPUTS, effect_class="computational")) != digest,
      "semantically distinct authoritative input changes the digest")
check(compute_request_digest(OPERATION, dict(INPUTS, capability_id="CAPDEF-0002")) != digest,
      "a distinct authoritative identifier changes the digest")
check(compute_request_digest(OPERATION, {"value": 1})
      != compute_request_digest(OPERATION, {"value": "1"}),
      "no semantic equivalence is guessed between 1 and '1'")

# Unordered inputs are unordered because the accepted schema says so.
UNORDERED = ("contract_ids", "satisfied_contract_versions", "compatible_with",
             "failure_modes", "accepted_contract_versions")
for field in UNORDERED:
    forward = compute_request_digest(OPERATION, {field: ["b", "a", "c"]})
    reversed_ = compute_request_digest(OPERATION, {field: ["c", "b", "a"]})
    check(forward == reversed_,
          f"input order does not change the digest for the unordered '{field}'")

check(compute_request_digest(OPERATION, {"candidate_instances": ["CINST-000001", "CINST-000002"]})
      != compute_request_digest(OPERATION, {"candidate_instances": ["CINST-000002", "CINST-000001"]}),
      "input order does change the digest for the human-ordered 'candidate_instances'")

EXCLUDED = (
    ({"transport_metadata": {"peer": "10.0.0.1"}}, "transport metadata"),
    ({"arrival_time": "2026-08-05T09:00:00+00:00"}, "arrival time"),
    ({"received_at": "2026-08-05T09:00:00+00:00"}, "a receipt timestamp"),
    ({"correlation_id": "log-42"}, "a log correlation identifier"),
    ({"trace_id": "trace-42"}, "a trace identifier"),
    ({"record_id": "CAPDEF-0001"}, "store-allocated record identity"),
)
for extra, description in EXCLUDED:
    check(compute_request_digest(OPERATION, dict(INPUTS, **extra)) == digest,
          f"{description} does not change the digest")

refuses_fabric(lambda: compute_request_digest(OPERATION, INPUTS,
                                              canonicalisation="fabric-canonical/v99"),
               "an unknown canonicalisation version fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, INPUTS, digest="sha512"),
               "an unknown digest version fails closed")
refuses_fabric(lambda: compute_request_digest("", INPUTS),
               "an absent operation type fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, ["not", "a", "mapping"]),
               "authoritative inputs that are not a mapping fail closed")
for algorithm in ("md5", "sha1", "blake2b", "sha3_256"):
    check(algorithm not in str(getattr(identity_module, "SUPPORTED_DIGEST", "")),
          f"no {algorithm} algorithm is introduced")

# --- Evidence assembly (AC 35, AC 63, §11) ----------------------------------
# Defect caught: a record accepted without the evidence that justifies it, or
# evidence that restates trust content instead of referencing it.
REQUIRED_EVIDENCE = ("actor", "approving_authority", "causal_references",
                     "trust_evidence_references", "reason_category",
                     "recorded_at", "request_id", "request_digest")
REQUEST = "request-0001"

KIND_REASONS = {
    "capability-definition": "declaration",
    "capability-contract": "declaration",
    "capability-package": "declaration",
    "capability-host": "subject-admission",
    "capability-advertisement": "advertisement-registration",
    "capability-instance": "instance-admission",
    "capability-route": "route-change",
    "capability-selection": "selection",
}
for reason in KIND_REASONS.values():
    check(reason in REASON_CATEGORIES,
          f"'{reason}' is a named category in the controlled vocabulary")
check(len(set(REASON_CATEGORIES)) == len(REASON_CATEGORIES),
      "the reason vocabulary names each category once")


def evidence_for(kind, **overrides):
    fields = dict(
        actor="operator:cschott",
        reason_category=KIND_REASONS[kind],
        recorded_at=WHEN,
        request_id=REQUEST,
        request_digest=digest,
        causal_references=("CAPDEF-0001",),
        trust_evidence_references=(("TAUTH-000002", "TAUTH-000001")
                                   if kind == "capability-instance"
                                   else ("TAUTH-000001",)),
    )
    # An advertisement is published by the subject as itself; naming an
    # approving human operator would turn a self-report into an approval.
    if kind == "capability-advertisement":
        fields["actor"] = "host:CHOST-0001"
    elif kind == "capability-selection":
        # A selection is a deterministic read plus its own record. No human
        # operator approves it, so naming one would misdescribe the act.
        fields["actor"] = "fabric:selection"
    else:
        fields["approving_authority"] = "operator:cschott"
    fields.update(overrides)
    return assemble_evidence(kind, **fields)


for kind in RECORD_MODELS:
    built_evidence = evidence_for(kind)
    for field in REQUIRED_EVIDENCE:
        check(field in built_evidence,
              f"assembled {kind} evidence carries '{field}'")
    check(built_evidence["recorded_at"] == WHEN.isoformat(),
          f"assembled {kind} evidence carries the caller's exact timestamp")
    check(built_evidence["request_id"] == REQUEST and built_evidence["request_digest"] == digest,
          f"assembled {kind} evidence carries the request identity and digest")
    check(evidence_for(kind) == built_evidence,
          f"assembling {kind} evidence twice returns an identical result")
    # Trust evidence is a reference. Nothing about trust standing is restated.
    references = built_evidence["trust_evidence_references"]
    check(all(isinstance(entry, str) for entry in references),
          f"{kind} trust evidence is referenced by identifier only")
    check(not any(word in json.dumps(built_evidence, default=str).lower()
                  for word in ("trusted", "restricted", "revoked", "quarantined", "signature")),
          f"{kind} evidence restates no trust standing or trust content")

check(evidence_for("capability-definition")["approving_authority"] == "operator:cschott",
      "a human-authorised mutation records its approving authority")
check(evidence_for("capability-advertisement").get("approving_authority") is None,
      "an advertisement records no approving human operator")
refuses_fabric(lambda: assemble_evidence(
                   "capability-advertisement", actor="host:schai",
                   approving_authority="operator:cschott",
                   reason_category="advertisement-registration", recorded_at=WHEN,
                   request_id=REQUEST, request_digest=digest),
               "naming an approving operator on an advertisement fails closed")

# Nothing in this layer reads a clock.
for clock in ("now", "utcnow", "today", "time", "monotonic"):
    check(not hasattr(evidence_module, clock),
          f"evidence assembly reads no clock: no '{clock}'")
refuses_fabric(lambda: evidence_for("capability-definition", recorded_at=NAIVE),
               "a timestamp carrying no timezone offset fails closed")
refuses_fabric(lambda: evidence_for("capability-definition", recorded_at="2026-08-05T09:00:00+00:00"),
               "a timestamp supplied as text rather than an aware datetime fails closed")

INVALID_EVIDENCE = (
    (dict(actor=""), "an empty actor"),
    (dict(actor=None), "an absent actor"),
    (dict(reason_category="whatever-happened"), "a reason outside the controlled vocabulary"),
    (dict(reason_category=""), "an empty reason category"),
    (dict(approving_authority=""), "an empty approving authority"),
    (dict(request_id="has space"), "an unsafe request_id"),
    (dict(request_digest="deadbeef"), "a digest without the released prefix"),
    (dict(request_digest="sha256:NOTHEX"), "a digest that is not lowercase hex"),
    (dict(causal_references=("not-an-identifier",)), "a causal reference that is not a record identity"),
    (dict(causal_references="CAPDEF-0001"), "causal references supplied as a bare string"),
    (dict(trust_evidence_references=("",)), "an empty trust evidence reference"),
)
for overrides, description in INVALID_EVIDENCE:
    refuses_fabric(lambda o=overrides: evidence_for("capability-definition", **o),
                   f"evidence carrying {description} fails closed")

for kind in RECORD_MODELS:
    # An advertisement is self-published and a selection is fabric-derived;
    # neither is approved by a human operator.
    if kind in ("capability-advertisement", "capability-selection"):
        continue
    refuses_fabric(lambda k=kind: assemble_evidence(
                       k, actor="operator:cschott", reason_category=KIND_REASONS[k],
                       recorded_at=WHEN, request_id=REQUEST, request_digest=digest),
                   f"a {kind} without an approving authority fails closed")

# The assembler mutates nothing it was handed.
supplied = {"causal_references": ["CAPDEF-0001"], "trust_evidence_references": ["TAUTH-000001"]}
before_call = json.dumps(supplied, sort_keys=True)
evidence_for("capability-definition", **supplied)
check(json.dumps(supplied, sort_keys=True) == before_call,
      "evidence assembly leaves the caller's input exactly as supplied")

# --- Every accepted record carries its evidence (AC 35, AC 63, A14) ---------
STAMP = "2026-08-04T12:00:00+00:00"
LATER = "2026-08-05T12:00:00+00:00"
PROV = {"class": "declared", "source": "operator"}


def accepted(kind, evidence):
    """One valid record of a kind, carrying assembled evidence."""
    bodies = {
        "capability-definition": dict(
            capability_id="CAPDEF-0001", name="summarise text",
            description="Reduce a document to its essentials.",
            effect_class="read-only", contract_ids=("CCON-0001",), provenance=PROV),
        "capability-contract": dict(
            contract_id="CCON-0001", capability_id="CAPDEF-0001",
            contract_version="1.0.0", effect_class="read-only",
            determinism_class="deterministic", request_shape={"text": "string"},
            response_shape={"summary": "string"}, failure_modes=("unavailable",),
            resource_requirements={"memory_mb": 512}, compatible_with=(), provenance=PROV),
        "capability-package": dict(
            capability_package_id="CPKG-0001", capability_id="CAPDEF-0001",
            contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
            package_version="1.0.0", artifact_reference="oci://registry.invalid/summarise",
            resource_requirements={"memory_mb": 512}, trust_domain="schott-platform",
            provenance=PROV),
        "capability-host": dict(
            capability_host_id="CHOST-0001", node_identity_reference="node/schai",
            fabric_node_trust_record_id="TAUTH-000001",
            verified_resource_profile={"memory_mb": 8192}, location_class="on-premises",
            data_classification_ceiling="internal", availability_intent="available",
            provenance=PROV),
        "capability-advertisement": dict(
            advertisement_id="CADV-000001", capability_host_id="CHOST-0001",
            capability_package_id="CPKG-0001", contract_id="CCON-0001",
            satisfied_contract_versions=("1.0.0",),
            advertised_resource_profile={"memory_mb": 512},
            observed_at=WHEN, valid_until=UNTIL, provenance=PROV),
        "capability-instance": dict(
            instance_id="CINST-000001", capability_id="CAPDEF-0001",
            capability_package_id="CPKG-0001", capability_host_id="CHOST-0001",
            contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
            verified_resource_profile={"memory_mb": 512},
            admission_decision_id="TDEC-000001", package_trust_record_id="TAUTH-000002",
            host_trust_record_id="TAUTH-000001",
            effective_scope={"data_classification": "internal"},
            admitted_at=WHEN, admitted_until=UNTIL, advertisement_id="CADV-000001",
            provenance=PROV),
        "capability-route": dict(
            route_id="CROUTE-0001", route_version=1, capability_id="CAPDEF-0001",
            contract_id="CCON-0001", accepted_contract_versions=("1.0.0",),
            locality="local-only", candidate_instances=("CINST-000001",),
            data_classification="internal", provenance=PROV),
        "capability-selection": dict(
            selection_id="CSEL-000001", route_id="CROUTE-0001", route_version=1,
            request_class={"data_classification": "internal"},
            considered_candidates=("CINST-000001",), excluded_candidates=(),
            selected_instance_id="CINST-000001",
            selection_reason="first eligible candidate in declared order",
            selected_at=WHEN, provenance=PROV),
    }
    return RECORD_MODELS[kind](evidence=evidence, **bodies[kind])


IDENTIFIERS = {
    "capability-definition": "CAPDEF-0001", "capability-contract": "CCON-0001",
    "capability-package": "CPKG-0001", "capability-host": "CHOST-0001",
    "capability-advertisement": "CADV-000001", "capability-instance": "CINST-000001",
    "capability-route": "CROUTE-0001", "capability-selection": "CSEL-000001",
}
DIRECTORIES = {
    "capability-definition": "capability-definitions",
    "capability-contract": "capability-contracts",
    "capability-package": "capability-packages",
    "capability-host": "capability-hosts",
    "capability-advertisement": "capability-advertisements",
    "capability-instance": "capability-instances",
    "capability-route": "capability-routes",
    "capability-selection": "capability-selections",
}

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    for kind in RECORD_MODELS:
        written = store.write(kind, accepted(kind, evidence_for(kind)))
        expected_path = Path(tmp) / "fabric" / DIRECTORIES[kind] / f"{IDENTIFIERS[kind]}.yaml"
        check(Path(written) == expected_path,
              f"an accepted {kind} is written to {DIRECTORIES[kind]}/{IDENTIFIERS[kind]}.yaml")
        stored = yaml.safe_load(expected_path.read_text(encoding="utf-8"))
        carried = stored.get("evidence") or {}
        for field in REQUIRED_EVIDENCE:
            if field == "approving_authority" and kind == "capability-advertisement":
                continue
            check(field in carried,
                  f"the stored {kind} record carries evidence field '{field}'")
        check(stored.get("kind") == kind and stored.get("schema_version"),
              f"the stored {kind} record carries its schema identity and version")
        check(carried.get("request_id") == REQUEST
              and carried.get("request_digest") == digest,
              f"the stored {kind} record carries its request identity and digest")
    # Exactly the eight accepted types, and no ninth namespace.
    check(sorted(store.counts()) == sorted(RECORD_MODELS),
          "the records written so far enumerate exactly the eight accepted types")
    check(all(count == 1 for count in store.counts().values()),
          "one accepted record of every accepted type was written")
    present = sorted(entry.name for entry in (Path(tmp) / "fabric").iterdir())
    check(present == sorted([*DIRECTORIES.values(), "sequences"]),
          "no audit, ledger, index, or ninth record directory was created")

# --- A record whose evidence cannot be validated is not written -------------
# Defect caught: committing the governed action and its evidence separately,
# so a record can exist without the evidence that justifies it.
BROKEN_EVIDENCE = (
    ({}, "evidence that is empty"),
    ({"actor": "operator:cschott"}, "evidence missing everything but the actor"),
    (None, "absent evidence"),
    ("operator:cschott", "evidence that is not a mapping"),
)
for broken, description in BROKEN_EVIDENCE:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        before = forensic(Path(tmp) / "fabric")
        refuses_fabric(lambda b=broken: store.write(
                           "capability-definition",
                           accepted("capability-definition", b)),
                       f"a record carrying {description} is not written")
        check(forensic(Path(tmp) / "fabric") == before,
              f"refusing {description} leaves no record, temporary, or sequence state")
        check(store.counts()["capability-definition"] == 0,
              f"refusing {description} persists nothing")

for field in REQUIRED_EVIDENCE:
    if field == "approving_authority":
        continue
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        partial = dict(evidence_for("capability-definition"))
        partial.pop(field)
        before = forensic(Path(tmp) / "fabric")
        refuses_fabric(lambda p=partial: store.write(
                           "capability-definition",
                           accepted("capability-definition", p)),
                       f"a record whose evidence omits '{field}' is not written")
        check(forensic(Path(tmp) / "fabric") == before,
              f"omitting '{field}' leaves no persistent state behind")

# --- Replay primitives (AC 76, AC 77, FC 7, FC 8, FC 9) ---------------------
# Defect caught: treating content equality as replay, or an occupied record
# path as proof a request was submitted twice.
def populated(tmp, request_id=REQUEST, request_digest=None):
    store = WitnessStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    evidence = evidence_for("capability-definition",
                            request_id=request_id,
                            request_digest=request_digest or digest)
    store.write("capability-definition",
                         accepted("capability-definition", evidence))
    return store


# A previously unseen request identity is new, and says so inside the one
# outer context the accepted operation boundary holds.
with TemporaryDirectory() as tmp:
    store = WitnessStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    store.sync_points.clear()
    store.entries = 0
    with store.request_critical_section("request-0002"):
        outcome = replay_lookup(store, "request-0002", digest)
    check(outcome.status == REPLAY_NEW, "an unseen request_id is treated as new")
    check(outcome.record_id is None and outcome.record_kind is None,
          "a new request identity names no existing record")
    check(store.entries == 1,
          "the accepted operation boundary enters the critical section exactly once")
    check(store.deepest == 1,
          "the replay helper never nests a second acquisition")
    check(("after_replay_miss", "request-0002", 1) in store.sync_points,
          "_test_sync_point('after_replay_miss') fires inside that single outer context")
    check(len(store.sync_points) == 1,
          "the replay miss is signalled exactly once")

# Exact replay returns the original, allocates nothing, writes nothing.
with TemporaryDirectory() as tmp:
    store = populated(tmp)
    fabric = Path(tmp) / "fabric"
    before = forensic(fabric)
    store.sync_points.clear()
    store.entries = 0
    with store.request_critical_section(REQUEST):
        outcome = replay_lookup(store, REQUEST, digest)
    check(outcome.status == REPLAY_EXACT, "an exact replay is recognised")
    check(outcome.record_kind == "capability-definition"
          and outcome.record_id == "CAPDEF-0001",
          "an exact replay returns the original record identity and outcome")
    check(store.entries == 1, "exact replay holds exactly one outer critical section")
    check(not store.sync_points,
          "no replay-miss signal fires when the request identity is already accepted")
    check(forensic(fabric) == before,
          "exact replay writes no record, allocates no identity, and changes nothing")
    check(store.counts()["capability-definition"] == 1,
          "exact replay creates no additional record")
    check(tuple(replay_lookup(store, REQUEST, digest)) == tuple(outcome),
          "replay lookup returns an identical result across repeated runs")

# Conflicting reuse fails closed and leaves the original untouched.
with TemporaryDirectory() as tmp:
    store = populated(tmp)
    fabric = Path(tmp) / "fabric"
    original = (fabric / "capability-definitions" / "CAPDEF-0001.yaml").read_bytes()
    before = forensic(fabric)
    other = compute_request_digest("declare-capability", {"capability_id": "CAPDEF-0002"})
    with store.request_critical_section(REQUEST):
        outcome = replay_lookup(store, REQUEST, other)
    check(outcome.status == REPLAY_CONFLICT,
          "an accepted request_id reused with a different digest fails closed")
    check(outcome.status == "request_identity_conflict",
          "the refusal is named request_identity_conflict")
    check((fabric / "capability-definitions" / "CAPDEF-0001.yaml").read_bytes() == original,
          "conflicting reuse leaves the original record byte-identical")
    check(forensic(fabric) == before,
          "conflicting reuse creates no record and modifies nothing")
    check(store.counts()["capability-definition"] == 1,
          "conflicting reuse neither supersedes nor adds a record")

# Identical content under different request identities stays independent.
with TemporaryDirectory() as tmp:
    store = WitnessStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    first = evidence_for("capability-definition", request_id="request-A")
    store.write("capability-definition", accepted("capability-definition", first))
    with store.request_critical_section("request-B"):
        outcome = replay_lookup(store, "request-B", digest)
    check(outcome.status == REPLAY_NEW,
          "identical authoritative content under a different request_id is not replay")
    second = evidence_for("capability-definition", request_id="request-B")
    duplicate = RECORD_MODELS["capability-definition"](
        capability_id="CAPDEF-0002", name="summarise text",
        description="Reduce a document to its essentials.", effect_class="read-only",
        contract_ids=("CCON-0001",), provenance=PROV, evidence=second)
    store.write("capability-definition", duplicate)
    check(store.counts()["capability-definition"] == 2,
          "different request identities produce independently allocated records")

# An occupied record path is a storage conflict, never replay evidence.
with TemporaryDirectory() as tmp:
    store = populated(tmp)
    fabric = Path(tmp) / "fabric"
    before = forensic(fabric)
    refuses_fabric(lambda: store.write(
                       "capability-definition",
                       accepted("capability-definition", evidence_for(
                           "capability-definition", request_id="request-Z"))),
                   "an occupied record path is refused as a storage conflict")
    with store.request_critical_section("request-Z"):
        outcome = replay_lookup(store, "request-Z", digest)
    check(outcome.status == REPLAY_NEW,
          "an occupied record path is never interpreted as replay")
    check(forensic(fabric) == before,
          "a storage conflict leaves the occupying record untouched")

# --- No ledger, no ninth type, no later-increment behaviour (A14, A15) ------
for ledger in ("RequestLedger", "ReplayLedger", "AuditRecord", "AuditEvent",
               "request_ledger", "replay_ledger", "record_request", "append"):
    check(not hasattr(identity_module, ledger),
          f"request identity defines no '{ledger}'")
    check(not hasattr(evidence_module, ledger),
          f"evidence defines no '{ledger}'")
for later in ("admit", "evaluate_eligibility", "compute_eligibility", "select",
              "inspect", "render", "verify_trust", "repair", "remediate",
              "quarantine", "retry"):
    check(not hasattr(identity_module, later),
          f"request identity exposes no '{later}' behaviour at increment 4")
    check(not hasattr(evidence_module, later),
          f"evidence exposes no '{later}' behaviour at increment 4")
for absent in ("admission.py", "eligibility.py", "selection.py", "inspection.py",
               "cli.py", "trust.py", "health.py", "ledger.py"):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 4 creates no {absent}")
check(len(RECORD_MODELS) == 8,
      "increment 4 introduces no ninth persistent record type")


# --- 1. Exact replay returns the original accepted outcome (spec §6) --------
# Defect caught: a replay result carrying only a status and a record identity,
# so the caller must re-read the store to learn what was originally decided --
# which is not "returning the original outcome".
SELECTION_OUTCOMES = (
    ("selected", "CSEL-000001", "CINST-000001", None, ("CINST-000001",), (),
     "selection", "first eligible candidate in declared order"),
    ("refused", "CSEL-000002", None, "none-eligible", ("CINST-000001",),
     ({"instance_id": "CINST-000001", "reason": "admission expired"},),
     "selection-refusal", "every candidate was excluded"),
    ("no-candidate", "CSEL-000003", None, "no-candidate", (), (),
     "no-candidate", "the route named no candidate"),
)
for (outcome_name, selection_id, chosen, refusal, candidates, excluded,
     category, reason) in SELECTION_OUTCOMES:
    with TemporaryDirectory() as tmp:
        store = WitnessStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        request = f"request-{outcome_name}"
        selection = RECORD_MODELS["capability-selection"](
            selection_id=selection_id, route_id="CROUTE-0001", route_version=1,
            request_class={"data_classification": "internal"},
            considered_candidates=candidates, excluded_candidates=excluded,
            selected_instance_id=chosen, selection_reason=reason,
            refusal_reason=refusal, selected_at=WHEN, provenance=PROV,
            evidence=evidence_for("capability-selection", request_id=request,
                                  reason_category=category))
        store.write("capability-selection", selection)
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        with store.request_critical_section(request):
            replayed = replay_lookup(store, request, digest)
        check(replayed.status == REPLAY_EXACT,
              f"a {outcome_name} CSEL replays exactly")
        check(replayed.record_id == selection_id,
              f"a {outcome_name} CSEL replay returns the original identity {selection_id}")
        original = replayed.outcome
        check(original is not None and original.get("outcome") == outcome_name,
              f"a {outcome_name} CSEL replay returns the original '{outcome_name}' outcome")
        check(original is not None and original.get("selected_instance_id") == chosen,
              f"a {outcome_name} CSEL replay returns the original selected instance")
        check(original is not None and original.get("refusal_reason") == refusal,
              f"a {outcome_name} CSEL replay returns the original refusal reason")
        check(original is not None and original.get("route_id") == "CROUTE-0001"
              and original.get("route_version") == 1,
              f"a {outcome_name} CSEL replay returns the original route and version")
        refuses_immutably = True
        try:
            original["outcome"] = "tampered"
            refuses_immutably = False
        except TypeError:
            pass
        check(refuses_immutably,
              f"a {outcome_name} CSEL replay outcome cannot be mutated by its caller")
        check(forensic(fabric) == before,
              f"replaying a {outcome_name} CSEL allocates nothing and writes nothing")
        check(store.entries == 1 and store.deepest == 1,
              f"replaying a {outcome_name} CSEL enters no critical section of its own")

# A non-selection record replays with its identity and a recorded outcome.
with TemporaryDirectory() as tmp:
    store = populated(tmp)
    with store.request_critical_section(REQUEST):
        replayed = replay_lookup(store, REQUEST, digest)
    check(replayed.outcome is not None and replayed.outcome.get("outcome") == "recorded",
          "a non-selection record replays as a recorded outcome")
    check(replayed.outcome.get("record_id") == "CAPDEF-0001",
          "a non-selection replay outcome names the original record identity")

# Conflicting reuse fabricates no original outcome.
with TemporaryDirectory() as tmp:
    store = populated(tmp)
    other = compute_request_digest("declare-capability", {"capability_id": "CAPDEF-0002"})
    with store.request_critical_section(REQUEST):
        conflicted = replay_lookup(store, REQUEST, other)
    check(conflicted.status == REPLAY_CONFLICT,
          "conflicting reuse still fails closed as request_identity_conflict")
    check(conflicted.outcome is None,
          "conflicting reuse exposes no fabricated original outcome")

# --- 2. C1 enforces evidence on its own persistence boundary ----------------
# Defect caught: two public meanings of an accepted write, one of which
# persists a record with no evidence at all.
check(not hasattr(FabricStore, "write_accepted"),
      "no separate write_accepted() persistence path exists")
BYPASS = [name for name in dir(FabricStore)
          if name not in ("write", "write_record", "write_atomic")
          and "write" in name and not name.startswith("__")]
check(BYPASS == [], f"no alternate persistence entry point exists (found {BYPASS})")

evidenceless = accepted("capability-definition", None)
for entry_point in ("write", "write_record"):
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        refuses_fabric(lambda e=entry_point: getattr(store, e)(
                           "capability-definition", evidenceless),
                       f"{entry_point}() refuses a record carrying no evidence")
        check(forensic(fabric) == before,
              f"{entry_point}() creates no record, temporary, or sequence state on refusal")
        check(store.counts()["capability-definition"] == 0,
              f"{entry_point}() persists nothing when evidence is missing")
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        broken = dict(evidence_for("capability-definition"))
        broken["reason_category"] = "whatever-happened"
        before = forensic(Path(tmp) / "fabric")
        refuses_fabric(lambda e=entry_point, b=broken: getattr(store, e)(
                           "capability-definition",
                           accepted("capability-definition", b)),
                       f"{entry_point}() refuses a record carrying invalid evidence")
        check(forensic(Path(tmp) / "fabric") == before,
              f"{entry_point}() leaves nothing behind when evidence is invalid")

# --- 3. Applicability is assessed against the complete record ---------------
# Defect caught: validating an isolated evidence mapping, which cannot see the
# supersession or trust-reference fields the record itself already carries.
check(list(inspect.signature(validate_record_evidence).parameters) == ["kind", "record"],
      "record evidence is validated against the complete record")

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    selection = RECORD_MODELS["capability-selection"](
        selection_id="CSEL-000004", route_id="CROUTE-0001", route_version=1,
        request_class={}, considered_candidates=("CINST-000001",),
        excluded_candidates=(), selected_instance_id="CINST-000001",
        selection_reason="first eligible", selected_at=WHEN, provenance=PROV,
        evidence=assemble_evidence(
            "capability-selection", actor="fabric:selection",
            reason_category="selection", recorded_at=WHEN, request_id=REQUEST,
            request_digest=digest, causal_references=("CROUTE-0001",),
            trust_evidence_references=()))
    store.write("capability-selection", selection)
    check(store.counts()["capability-selection"] == 1,
          "a CSEL is accepted with a requesting actor and no human approving authority")
refuses_fabric(lambda: assemble_evidence(
                   "capability-selection", actor="", reason_category="selection",
                   recorded_at=WHEN, request_id=REQUEST, request_digest=digest),
               "a CSEL without a requesting actor fails closed")
refuses_fabric(lambda: assemble_evidence(
                   "capability-advertisement", actor="", reason_category="advertisement-registration",
                   recorded_at=WHEN, request_id=REQUEST, request_digest=digest),
               "a CADV without a publishing subject as actor fails closed")

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    fabric = Path(tmp) / "fabric"
    before = forensic(fabric)
    advertisement = accepted("capability-advertisement",
                             dict(evidence_for("capability-advertisement"),
                                  actor="host:CHOST-9999"))
    refuses_fabric(lambda: store.write("capability-advertisement", advertisement),
                   "a CADV whose actor is not its advertising subject fails closed")
    check(forensic(fabric) == before,
          "an inapplicable CADV actor is refused before any filesystem mutation")

SUPERSESSION = (
    ("capability-definition", "CAPDEF-0002", "CAPDEF-0001"),
    ("capability-package", "CPKG-0002", "CPKG-0001"),
)
for kind, identifier, prior in SUPERSESSION:
    field = {"capability-definition": "capability_id",
             "capability-package": "capability_package_id"}[kind]
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        base = accepted(kind, evidence_for(kind))
        naming = dict(evidence_for(kind), reason_category="supersession")
        without_prior = replace(base, evidence=naming, **{field: identifier})
        before = forensic(fabric)
        refuses_fabric(lambda r=without_prior, k=kind: store.write(k, r),
                       f"a superseding {kind} without its prior record reference fails closed")
        check(forensic(fabric) == before,
              f"a superseding {kind} missing its prior reference mutates nothing")
        inconsistent = replace(
            base, evidence=dict(naming, causal_references=["CAPDEF-0003"]),
            supersedes=prior, **{field: identifier})
        refuses_fabric(lambda r=inconsistent, k=kind: store.write(k, r),
                       f"a superseding {kind} whose evidence disagrees with its "
                       "supersedes field fails closed")
        consistent = replace(
            base, evidence=dict(naming, causal_references=[prior]),
            supersedes=prior, **{field: identifier})
        store.write(kind, consistent)
        check(store.counts()[kind] == 1,
              f"a superseding {kind} naming its prior record is accepted")

TRUST_REQUIRED = (
    ("capability-host", ("TAUTH-000001",), "its host trust record"),
    ("capability-instance", ("TAUTH-000002", "TAUTH-000001"),
     "its package and host trust records"),
)
for kind, references, description in TRUST_REQUIRED:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        stripped = accepted(kind, dict(evidence_for(kind),
                                       trust_evidence_references=[]))
        refuses_fabric(lambda r=stripped, k=kind: store.write(k, r),
                       f"a {kind} that does not reference {description} fails closed")
        check(forensic(fabric) == before,
              f"a {kind} missing {description} is refused before any mutation")
        for omitted in references:
            partial = [r for r in references if r != omitted]
            record = accepted(kind, dict(evidence_for(kind),
                                         trust_evidence_references=partial))
            refuses_fabric(lambda r=record, k=kind: store.write(k, r),
                           f"a {kind} omitting the trust reference {omitted} fails closed")
        store.write(kind, accepted(kind, dict(evidence_for(kind),
                                              trust_evidence_references=list(references))))
        check(store.counts()[kind] == 1,
              f"a {kind} referencing {description} is accepted")

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    declaration = accepted("capability-definition",
                           dict(evidence_for("capability-definition"),
                                trust_evidence_references=[]))
    store.write("capability-definition", declaration)
    check(store.counts()["capability-definition"] == 1,
          "a declaration requiring no trust evidence accepts an empty trust reference collection")
    stored = yaml.safe_load(
        (Path(tmp) / "fabric" / "capability-definitions" / "CAPDEF-0001.yaml")
        .read_text(encoding="utf-8"))
    body = json.dumps(stored, default=str).lower()
    check(not any(word in body for word in
                  ("trusted", "restricted", "revoked", "quarantined", "signature", "standing")),
          "trust content is referenced by identifier and never copied into the record")

# --- 4. Evidence on a frozen record is deeply immutable ---------------------
# Defect caught: a shallow MappingProxyType whose nested lists stay mutable, so
# a frozen record can be edited after construction through its own evidence.
with TemporaryDirectory() as tmp:
    supplied_causal = ["CAPDEF-0001"]
    supplied_trust = ["TAUTH-000001"]
    assembled = assemble_evidence(
        "capability-definition", actor="operator:cschott",
        approving_authority="operator:cschott", reason_category="declaration",
        recorded_at=WHEN, request_id=REQUEST, request_digest=digest,
        causal_references=supplied_causal, trust_evidence_references=supplied_trust)
    record = accepted("capability-definition", assembled)
    first = json.dumps(record.to_dict(), sort_keys=True, default=str)

    for field in ("causal_references", "trust_evidence_references"):
        held = record.evidence[field]
        mutated = True
        try:
            held.append("CAPDEF-9999")
            mutated = False
        except AttributeError:
            pass
        check(mutated, f"a frozen record's evidence '{field}' cannot be appended to")
    replaced = True
    try:
        record.evidence["actor"] = "operator:someone-else"
        replaced = False
    except TypeError:
        pass
    check(replaced, "a frozen record's evidence mapping cannot be reassigned")

    supplied_causal.append("CAPDEF-8888")
    supplied_trust.append("TAUTH-999999")
    assembled["reason_category"] = "withdrawal"
    check(json.dumps(record.to_dict(), sort_keys=True, default=str) == first,
          "mutating the caller's collections after construction cannot change the record")
    check(json.dumps(record.to_dict(), sort_keys=True, default=str) == first,
          "repeated to_dict() output stays byte-equivalent")
    check(isinstance(record.to_dict()["evidence"]["causal_references"], list),
          "serialisation still produces the accepted JSON/YAML-compatible shapes")

    unchanged = ["CAPDEF-0001"]
    snapshot_input = list(unchanged)
    refuses_fabric(lambda: assemble_evidence(
                       "capability-definition", actor="", approving_authority="operator:c",
                       reason_category="declaration", recorded_at=WHEN,
                       request_id=REQUEST, request_digest=digest,
                       causal_references=unchanged, trust_evidence_references=[]),
                   "a refused assembly still fails closed")
    check(unchanged == snapshot_input,
          "validation never mutates the caller's input")

# --- 5. Unsupported canonical input fails closed (AC 82) --------------------
# Defect caught: json.dumps(default=str), which turns an unsupported value into
# an implementation-defined string -- one that carries a memory address, so the
# same input digests differently in the same process and across processes.
class Unsupported:
    pass


held_a = Unsupported()
held_b = Unsupported()
UNCANONICAL = (
    (held_a, "an arbitrary object"),
    ({1, 2, 3}, "a set"),
    (frozenset({1}), "a frozenset"),
    (float("nan"), "a NaN"),
    (float("inf"), "an infinity"),
    (float("-inf"), "a negative infinity"),
    (WHEN, "a datetime"),
    (b"bytes", "raw bytes"),
    (object(), "a bare object"),
)
for value, description in UNCANONICAL:
    refuses_fabric(lambda v=value: compute_request_digest(OPERATION, {"value": v}),
                   f"authoritative input carrying {description} fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, {"nested": {"deep": {1, 2}}}),
               "an unsupported value nested inside a mapping fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, {"nested": [1, {2, 3}]}),
               "an unsupported value nested inside a sequence fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, {1: "int key"}),
               "a non-string mapping key fails closed")
refuses_fabric(lambda: compute_request_digest(OPERATION, {"nested": {2: "int key"}}),
               "a nested non-string mapping key fails closed")

# Supported JSON values keep the released convention exactly.
SUPPORTED = {"text": "value", "count": 7, "ratio": 1.5, "flag": True,
             "absent": None, "list": ["a", "b"], "nested": {"k": "v"}}
supported_digest = compute_request_digest(OPERATION, SUPPORTED)
supported_expected = json.dumps(
    {"canonicalisation": SUPPORTED_CANONICALISATION, "digest": SUPPORTED_DIGEST,
     "operation": OPERATION, "inputs": SUPPORTED},
    sort_keys=True, separators=(",", ":")).encode("utf-8")
check(supported_digest == f"sha256:{hashlib.sha256(supported_expected).hexdigest()}",
      "supported canonical values keep the released sorted-key, stable-separator convention")
check(compute_request_digest(OPERATION, SUPPORTED) == supported_digest,
      "supported canonical values digest identically on repetition")


# --- 2. A selection is not a human-authorised mutation ----------------------
# Defect caught: demanding, or merely tolerating, an approving human operator
# on a record no human approves. Recording one would describe a deterministic
# read as an approval.
selection_body = dict(
    selection_id="CSEL-000009", route_id="CROUTE-0001", route_version=1,
    request_class={"data_classification": "internal"},
    considered_candidates=("CINST-000001",), excluded_candidates=(),
    selected_instance_id="CINST-000001",
    selection_reason="first eligible candidate in declared order",
    selected_at=WHEN, provenance=PROV)

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    accepted_selection = RECORD_MODELS["capability-selection"](
        evidence=evidence_for("capability-selection"), **selection_body)
    check(accepted_selection.evidence["approving_authority"] is None,
          "an accepted CSEL carries no approving authority")
    check(accepted_selection.evidence["actor"] == "fabric:selection",
          "an accepted CSEL records its requesting actor")
    store.write("capability-selection", accepted_selection)
    check(store.counts()["capability-selection"] == 1,
          "a CSEL with a requesting actor and no approving authority is accepted")

refuses_fabric(lambda: assemble_evidence(
                   "capability-selection", actor="fabric:selection",
                   approving_authority="operator:cschott",
                   reason_category="selection", recorded_at=WHEN,
                   request_id=REQUEST, request_digest=digest,
                   causal_references=("CROUTE-0001",), trust_evidence_references=()),
               "naming an approving operator on a CSEL fails closed")
refuses_fabric(lambda: assemble_evidence(
                   "capability-selection", actor=None, reason_category="selection",
                   recorded_at=WHEN, request_id=REQUEST, request_digest=digest,
                   causal_references=("CROUTE-0001",), trust_evidence_references=()),
               "a CSEL without a requesting actor fails closed")

with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    fabric = Path(tmp) / "fabric"
    before = forensic(fabric)
    approved = dict(evidence_for("capability-selection"),
                    approving_authority="operator:cschott")
    refuses_fabric(lambda: store.write(
                       "capability-selection",
                       RECORD_MODELS["capability-selection"](evidence=approved,
                                                             **selection_body)),
                   "a CSEL carrying an approving authority is refused at the boundary")
    check(forensic(fabric) == before,
          "an approved CSEL is refused before any filesystem mutation")

# --- 3. Supersession is symmetric -------------------------------------------
# Defect caught: enforcing the prior-record reference only when the reason
# category announces it, so a record that supersedes another can hide the fact
# by declaring some other reason.
SUPERSEDING = (
    ("capability-definition", "capability_id", "CAPDEF-0002", "CAPDEF-0001"),
    ("capability-host", "capability_host_id", "CHOST-0002", "CHOST-0001"),
    ("capability-route", "route_id", "CROUTE-0002", "CROUTE-0001"),
)
for kind, field, identifier, prior in SUPERSEDING:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        base = accepted(kind, evidence_for(kind))

        # Declared supersession without the field it must agree with.
        declared_only = replace(
            base, evidence=dict(evidence_for(kind), reason_category="supersession",
                                causal_references=[prior]),
            **{field: identifier})
        before = forensic(fabric)
        refuses_fabric(lambda r=declared_only, k=kind: store.write(k, r),
                       f"a {kind} declaring supersession without a supersedes field fails closed")
        check(forensic(fabric) == before,
              f"a {kind} declaring supersession without the field mutates nothing")

        # The field populated while the reason category hides it.
        hidden = replace(base, evidence=evidence_for(kind), supersedes=prior,
                         **{field: identifier})
        refuses_fabric(lambda r=hidden, k=kind: store.write(k, r),
                       f"a {kind} that supersedes another without declaring it fails closed")
        check(forensic(fabric) == before,
              f"an undeclared superseding {kind} mutates nothing")

        # Declared and populated, but the evidence does not name it.
        unreferenced = replace(
            base, evidence=dict(evidence_for(kind), reason_category="supersession",
                                causal_references=["CAPDEF-0001"] if kind != "capability-definition"
                                else ["CCON-0001"]),
            supersedes=prior, **{field: identifier})
        refuses_fabric(lambda r=unreferenced, k=kind: store.write(k, r),
                       f"a superseding {kind} whose evidence omits the prior record fails closed")
        check(forensic(fabric) == before,
              f"a superseding {kind} with unreferenced prior record mutates nothing")

        # All three agreeing.
        consistent = replace(
            base, evidence=dict(evidence_for(kind), reason_category="supersession",
                                causal_references=[prior]),
            supersedes=prior, **{field: identifier})
        store.write(kind, consistent)
        check(store.counts()[kind] == 1,
              f"a {kind} whose supersedes field, reason category, and evidence agree is accepted")

# --- 4. A selection's recorded outcome must be internally consistent --------
# Defect caught: deriving the outcome from a field combination nothing checked,
# so replay would faithfully report a contradiction as though it were a
# decision. The three outcomes are the ones the reason vocabulary already names.
def selection(**overrides):
    body = dict(selection_body, selection_id="CSEL-000010")
    category = overrides.pop("reason_category", "selection")
    evidence = overrides.pop("evidence", None) or evidence_for(
        "capability-selection", reason_category=category)
    body.update(overrides)
    return RECORD_MODELS["capability-selection"](evidence=evidence, **body)


CONSISTENT_OUTCOMES = (
    ("selected", dict(selected_instance_id="CINST-000001", refusal_reason=None,
                      considered_candidates=("CINST-000001",), excluded_candidates=(),
                      reason_category="selection")),
    ("refused", dict(selected_instance_id=None, refusal_reason="none-eligible",
                     considered_candidates=("CINST-000001",),
                     excluded_candidates=({"instance_id": "CINST-000001",
                                           "reason": "admission expired"},),
                     reason_category="selection-refusal")),
    ("no-candidate", dict(selected_instance_id=None, refusal_reason="no-candidate",
                          considered_candidates=(), excluded_candidates=(),
                          reason_category="no-candidate")),
)
for name, fields in CONSISTENT_OUTCOMES:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        store.write("capability-selection", selection(**fields))
        check(store.counts()["capability-selection"] == 1,
              f"a consistent {name} selection is accepted")

CONTRADICTIONS = (
    (dict(selected_instance_id="CINST-000001", refusal_reason="none-eligible",
          considered_candidates=("CINST-000001",), reason_category="selection"),
     "a selected outcome carrying a refusal reason"),
    (dict(selected_instance_id=None, refusal_reason=None,
          considered_candidates=("CINST-000001",), reason_category="selection-refusal"),
     "a refused outcome carrying no refusal reason"),
    (dict(selected_instance_id=None, refusal_reason="none-eligible",
          considered_candidates=("CINST-000001",), excluded_candidates=(),
          reason_category="selection-refusal"),
     "a refused outcome that excludes none of the candidates it considered"),
    (dict(selected_instance_id="CINST-000009", refusal_reason=None,
          considered_candidates=("CINST-000001",), reason_category="selection"),
     "a selected instance that was never considered"),
    (dict(selected_instance_id="CINST-000001", refusal_reason=None,
          considered_candidates=("CINST-000001",), reason_category="selection-refusal"),
     "a selected outcome declared as a refusal"),
    (dict(selected_instance_id=None, refusal_reason="none-eligible",
          considered_candidates=("CINST-000001",),
          excluded_candidates=({"instance_id": "CINST-000001", "reason": "x"},),
          reason_category="selection"),
     "a refused outcome declared as a selection"),
    (dict(selected_instance_id=None, refusal_reason="no-candidate",
          considered_candidates=(), excluded_candidates=(),
          reason_category="selection-refusal"),
     "a no-candidate outcome declared as a refusal"),
    (dict(selected_instance_id=None, refusal_reason="no-candidate",
          considered_candidates=(),
          excluded_candidates=({"instance_id": "CINST-000001", "reason": "x"},),
          reason_category="no-candidate"),
     "a no-candidate outcome that excluded a candidate it never considered"),
    (dict(selected_instance_id="CINST-000001", refusal_reason=None,
          considered_candidates=("CINST-000001",), reason_category="no-candidate"),
     "a selected outcome declared as no-candidate"),
)
for fields, description in CONTRADICTIONS:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        refuses_fabric(lambda f=fields: store.write("capability-selection", selection(**f)),
                       f"{description} fails closed")
        check(forensic(fabric) == before,
              f"{description} is refused before any filesystem mutation")
        check(store.counts()["capability-selection"] == 0,
              f"{description} persists nothing")

# Replay reports the validated outcome, and only ever a validated one. The
# three outcomes are exactly the three the accepted reason vocabulary names.
OUTCOME_CATEGORIES = {"selected": "selection", "refused": "selection-refusal",
                      "no-candidate": "no-candidate"}
for name, fields in CONSISTENT_OUTCOMES:
    with TemporaryDirectory() as tmp:
        store = WitnessStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        request = f"request-outcome-{name}"
        evidence = evidence_for("capability-selection",
                                reason_category=fields["reason_category"],
                                request_id=request)
        store.write("capability-selection",
                    selection(**dict(fields, evidence=evidence)))
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        with store.request_critical_section(request):
            replayed = replay_lookup(store, request, digest)
        check(replayed.outcome["outcome"] == name,
              f"replay reports the validated {name} outcome")
        check(OUTCOME_CATEGORIES[replayed.outcome["outcome"]] == fields["reason_category"],
              f"the {name} outcome agrees with the reason category that was validated")
        check(forensic(fabric) == before,
              f"replaying a {name} selection writes nothing")

print(f"__FAILURES__={failures}")
IDENTITYPY
)"
printf '%s\n' "${IDENTITY_OUTPUT}" | grep -v '^__FAILURES__=' || true
IDENTITY_FAILURES="$(printf '%s\n' "${IDENTITY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${IDENTITY_FAILURES}" ]]; then
  fail "fabric request identity and evidence did not report a result"
else
  FAILURES=$((FAILURES + IDENTITY_FAILURES))
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
