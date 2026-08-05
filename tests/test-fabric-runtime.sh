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


def accepted_records():
    """One of every accepted kind. Identifiers and destinations are literal."""
    return (
        ("capability-definition", "capability-definitions", "CAPDEF-0001",
         "capability_id", CapabilityDefinition(
             capability_id="CAPDEF-0001", name="summarise text",
             description="Reduce a document to its essentials.",
             effect_class="read-only", contract_ids=("CCON-0001",),
             provenance=ORIGIN)),
        ("capability-contract", "capability-contracts", "CCON-0001",
         "contract_id", CapabilityContract(
             contract_id="CCON-0001", capability_id="CAPDEF-0001",
             contract_version="1.0.0", effect_class="read-only",
             determinism_class="deterministic", request_shape={"text": "string"},
             response_shape={"summary": "string"}, failure_modes=("unavailable",),
             resource_requirements={"memory_mb": 512}, compatible_with=(),
             provenance=ORIGIN)),
        ("capability-package", "capability-packages", "CPKG-0001",
         "capability_package_id", CapabilityPackage(
             capability_package_id="CPKG-0001", capability_id="CAPDEF-0001",
             contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
             package_version="1.0.0",
             artifact_reference="oci://registry.invalid/summarise",
             resource_requirements={"memory_mb": 512},
             trust_domain="schott-platform", provenance=ORIGIN)),
        ("capability-host", "capability-hosts", "CHOST-0001",
         "capability_host_id", CapabilityHost(
             capability_host_id="CHOST-0001", node_identity_reference="node/schai",
             fabric_node_trust_record_id="TAUTH-000001",
             verified_resource_profile={"memory_mb": 8192},
             location_class="on-premises", data_classification_ceiling="internal",
             availability_intent="available", provenance=ORIGIN)),
        ("capability-advertisement", "capability-advertisements", "CADV-000001",
         "advertisement_id", CapabilityAdvertisement(
             advertisement_id="CADV-000001", capability_host_id="CHOST-0001",
             capability_package_id="CPKG-0001", contract_id="CCON-0001",
             satisfied_contract_versions=("1.0.0",),
             advertised_resource_profile={"memory_mb": 512},
             observed_at=WHEN, valid_until=UNTIL, provenance=ORIGIN)),
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
             advertisement_id="CADV-000001", provenance=ORIGIN)),
        ("capability-route", "capability-routes", "CROUTE-0001",
         "route_id", CapabilityRoute(
             route_id="CROUTE-0001", route_version=1, capability_id="CAPDEF-0001",
             contract_id="CCON-0001", accepted_contract_versions=("1.0.0",),
             locality="local-only", candidate_instances=("CINST-000001",),
             data_classification="internal", provenance=ORIGIN)),
        ("capability-selection", "capability-selections", "CSEL-000001",
         "selection_id", CapabilitySelection(
             selection_id="CSEL-000001", route_id="CROUTE-0001", route_version=1,
             request_class={"data_classification": "internal"},
             considered_candidates=("CINST-000001",), excluded_candidates=(),
             selected_instance_id="CINST-000001",
             selection_reason="first eligible candidate in declared order",
             selected_at=WHEN, provenance=ORIGIN)),
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
