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

assert_contains() {
  local target="$1" pattern="$2" description="$3"
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  if grep -qE -e "${pattern}" "${ROOT}/${target}"; then
    pass "${description}"
  else
    fail "${description}"
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


# A shape names the authority that enforces it. The fixtures name the real
# ones, so a shape that stopped being a reference to enforcing code would be
# visible here rather than merely valid.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}


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
        request_shape=REQUEST_SHAPE,
        response_shape=RESPONSE_SHAPE,
        # A generation interface can decline a call outright, and the adapter
        # in front of it can fail to serve one. Two governed modes, kept
        # distinct because they mean different things to a caller.
        failure_modes=("refused", "adapter-error"),
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
        # Required since the optionality between schema, model and admission
        # was reconciled: a host claiming a verified profile must name what
        # verified it.
        verification_reference="/approved/evidence/host-observed.txt",
        location_class="on-premises",
        data_classification="internal",
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
        lifecycle_state="admitted",
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


# --- Route provenance is all-or-none ----------------------------------------
# A request class with no resolvable route is still a recorded outcome, so the
# record has to exist without naming a route it never had. The pair is written
# together or not at all: a version without a route names no policy, and a
# route without the version that applied cannot be looked up as it stood.
NO_ROUTE = dict(
    selection_id="CSEL-000100",
    request_class={"data_classification": "internal"},
    considered_candidates=(), excluded_candidates=(),
    selected_instance_id=None,
    selection_reason="no route resolved for the request class",
    selected_at=STAMP, provenance={"class": "declared", "source": "core"})

no_route = CapabilitySelection(**NO_ROUTE)
ok("a selection with no route provenance is constructible")
check(no_route.route_id is None and no_route.route_version is None,
      "a no-route selection names neither a route nor a version")
stored_no_route = no_route.to_dict()
for absent in ("route_id", "route_version"):
    check(absent not in stored_no_route,
          f"a no-route selection serialises no {absent} at all")
check(CapabilitySelection.from_dict(stored_no_route).to_dict() == stored_no_route,
      "a no-route selection round-trips through the stored form")

routed_selection = CapabilitySelection(**dict(
    NO_ROUTE, selection_id="CSEL-000101", route_id="CROUTE-0001",
    route_version=1, considered_candidates=("CINST-000001",),
    selected_instance_id="CINST-000001"))
check(routed_selection.route_id == "CROUTE-0001"
      and routed_selection.route_version == 1,
      "a selection a route governed carries both halves of its provenance")

for half, description in (({"route_id": "CROUTE-0001"}, "a route with no version"),
                          ({"route_version": 1}, "a version with no route")):
    refuses(lambda half=half: CapabilitySelection(**dict(
        NO_ROUTE, selection_id="CSEL-000102", **half)),
        f"{description} is refused")

# A placeholder is not an absence. Anything occupying the route identity must
# be one, so a sentinel cannot stand where nothing belongs.
for sentinel in ("", "CROUTE-0000-placeholder", "none", "CROUTE-000"):
    refuses(lambda sentinel=sentinel: CapabilitySelection(**dict(
        NO_ROUTE, selection_id="CSEL-000103", route_id=sentinel, route_version=1)),
        "a sentinel route identity is refused")

# The node that governed a local-only decision is recorded, so the decision can
# be read back rather than re-derived from whichever node asks later.
contextual = CapabilitySelection(**dict(
    NO_ROUTE, selection_id="CSEL-000104", local_node_identity="node/schai"))
check(contextual.local_node_identity == "node/schai",
      "a selection may record the node identity that governed its locality")
check(contextual.to_dict()["local_node_identity"] == "node/schai",
      "the governing node identity survives serialisation")
check("local_node_identity" not in stored_no_route,
      "a selection that recorded no node identity serialises none")
for unusable in ("", "   ", 7):
    refuses(lambda unusable=unusable: CapabilitySelection(**dict(
        NO_ROUTE, selection_id="CSEL-000105", local_node_identity=unusable)),
        "an unusable local node identity is refused")

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

def aliases_in(tree):
    """Names bound by `from os import replace as _r` and `import shutil as sh`."""
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
    return aliased


SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


def formal_parameters(scope):
    """Every name this scope binds as a parameter of its own."""
    spec = scope.args
    names = [argument.arg for argument in
             (*spec.posonlyargs, *spec.args, *spec.kwonlyargs)]
    if spec.vararg:
        names.append(spec.vararg.arg)
    if spec.kwarg:
        names.append(spec.kwarg.arg)
    return names


def own_scope(scope):
    """The nodes belonging to this scope's own body, nested scopes excluded.

    A call made inside a nested function or lambda is that scope's call, not
    this one's, so it can never be this function's authorised delegation.
    """
    pending = list(scope.body)
    while pending:
        node = pending.pop()
        yield node
        for child in ast.iter_child_nodes(node):
            if not isinstance(child, SCOPES):
                pending.append(child)


def rebinds(scope, target):
    """Whether `target` is bound anywhere inside the body, by any mechanism.

    A parameter that is reassigned, shadowed, imported over, re-declared
    global, or reused as a nested scope's own parameter is no longer proof of
    the receiver: the call site would still read `store` either way.
    """
    for statement in scope.body:
        for node in ast.walk(statement):
            if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
                if node.id == target:
                    return True
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                if target in node.names:
                    return True
            elif isinstance(node, SCOPES):
                if target in formal_parameters(node):
                    return True
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                if any((alias.asname or alias.name.split(".")[0]) == target
                       for alias in node.names):
                    return True
    return False


def is_c1_delegation(call):
    """Exactly `store.write(kind, record)`, positionally and by name.

    The shape is asserted as well as the receiver: a call with other arguments,
    with keywords, or with a starred argument is a different call, and the
    guard must not permit one because it happens to be spelled `.write`.
    """
    func = call.func
    return (isinstance(func, ast.Attribute) and func.attr == "write"
            and isinstance(func.value, ast.Name) and func.value.id == "store"
            and not call.keywords
            and [argument.id for argument in call.args
                 if isinstance(argument, ast.Name)] == ["kind", "record"]
            and len(call.args) == 2)


def eligible_commits(tree):
    """The module's own `_commit` definitions that could carry the delegation.

    Module-level only. A `_commit` nested in a class or another function is not
    the reviewed commit path, and treating it as one would authorise a writer
    that no reader of this module's top level would ever see.
    """
    return [node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_commit"
            and "store" in formal_parameters(node) and not rebinds(node, "store")]


def delegation_calls(scope):
    """The `store.write(kind, record)` calls made in this scope's own body."""
    return [node for node in own_scope(scope)
            if isinstance(node, ast.Call) and is_c1_delegation(node)]


def permitted_delegations(tree):
    """The C1 commit calls, bound to the formal receiver that makes them one.

    C4 commits through C1; *that* call is delegation to the only writer, not a
    filesystem call of its own. The permission is bound to the delegation, not
    to a name: the call must sit in the intended `_commit()`, be made through
    `_commit()`'s own `store` parameter, and be exactly `.write(kind, record)`.
    Another receiver, another write name, a getattr indirection, an alias, a
    shadowed or rebound `store`, and a nested scope's own `store` all stay
    forbidden.

    **The authorisation is singular.** Exactly one eligible `_commit`, making
    exactly one delegation. Two definitions or two calls are an ambiguity, and
    an ambiguous authorisation authorises whichever site nobody reviewed, so
    any count other than one permits nothing at all.
    """
    commits = eligible_commits(tree)
    if len(commits) != 1:
        return set()
    calls = delegation_calls(commits[0])
    if len(calls) != 1:
        return set()
    return {id(calls[0])}


def scan(tree, aliased, name):
    """Every mechanism by which this module could mutate the filesystem."""
    hits = []
    permitted = permitted_delegations(tree)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr in WRITE_ATTRS:
            if id(node) in permitted:
                continue
            hits.append(f"{name}:{node.lineno}:.{func.attr}")
        elif isinstance(func, ast.Name):
            if func.id in aliased:
                hits.append(f"{name}:{node.lineno}:{aliased[func.id]}")
            elif func.id == "open":
                hits.append(f"{name}:{node.lineno}:builtin open")
            elif func.id == "getattr":
                # getattr(store, "write") would reach a writer without naming
                # it, which is exactly what the narrowing must not permit.
                for argument in node.args[1:2]:
                    if (isinstance(argument, ast.Constant)
                            and argument.value in WRITE_ATTRS):
                        hits.append(f"{name}:{node.lineno}:getattr bypass")
    return hits


# The narrowing is itself asserted, so it cannot quietly widen.
#
# The permitted call is the *formal* delegation, not a name. Recognising a
# receiver merely spelled `store` would let a module-level rebinding, a global,
# a shadowed parameter, or an alias reach a writer without ever proving it is
# the enclosing function's own parameter, so every one of those stays refused.
COMMIT = "def _commit(store, kind, evidence, build):\n"
GUARD_ALLOWED = (
    (COMMIT + "    store.write(kind, record)\n", "the C1 commit call"),
    ("store.allocate_id(kind)", "a non-writing store call"),
    ('getattr(record, "supersedes", None)', "a getattr that reads a field"),
)
GUARD_REFUSED = (
    ('path.write_text("x")', "a direct path write"),
    ('open("f", "w")', "a builtin open"),
    ("os.replace(a, b)", "a direct filesystem replace"),
    ("elsewhere.write(kind, record)", "a write on another receiver"),
    ("store.write_record(kind, record)", "write_record on the store"),
    ("store.write_atomic(destination, payload)", "write_atomic on the store"),
    ('getattr(store, "write")(kind, record)', "a getattr write bypass"),
    ("shutil.copy(a, b)", "a shutil copy"),
    ("path.mkdir()", "a directory creation"),
    ("store = foreign_writer\nstore.write(kind, record)\n",
     "a module-level name that is merely called store"),
    ("def wrong():\n    store.write(kind, record)\n",
     "a commit through a name that is no formal parameter"),
    ("def wrong(other):\n    store = other\n    store.write(kind, record)\n",
     "a shadowed store receiver"),
    ("def wrong(store):\n    store.write(kind, record)\n",
     "a commit outside the intended _commit function"),
    (COMMIT + "    store = elsewhere\n    store.write(kind, record)\n",
     "a store parameter rebound inside _commit"),
    (COMMIT + "    store.write_record(kind, record)\n",
     "write_record through the formal store parameter"),
    (COMMIT + "    store.write_atomic(destination, payload)\n",
     "write_atomic through the formal store parameter"),
    (COMMIT + '    getattr(store, "write")(kind, record)\n',
     "a getattr write through the formal store parameter"),
    (COMMIT + "    alias = store\n    alias.write(kind, record)\n",
     "an aliased store receiver inside _commit"),
    (COMMIT + "    store.write(kind, record, extra)\n",
     "a commit call of another shape"),
    (COMMIT + "    store.write(kind=kind, record=record)\n",
     "a commit call made by keyword"),
    (COMMIT + "    def inner(store):\n        store.write(kind, record)\n",
     "a commit from a nested scope's own store"),
    # The authorisation is for one delegation at one call site. Two of anything
    # is an ambiguity, and an ambiguous authorisation authorises whichever site
    # nobody looked at.
    (COMMIT + "    store.write(kind, record)\n    store.write(kind, record)\n",
     "two commit calls inside one _commit"),
    (COMMIT + "    store.write(kind, record)\n\n"
     + COMMIT + "    store.write(kind, record)\n",
     "two _commit definitions each carrying a commit"),
    (COMMIT + "    other.write(kind, record)\n",
     "a commit through a receiver that is not the store parameter"),
    (COMMIT + "    store.write_atomic(kind, record)\n",
     "write_atomic passed the commit arguments"),
    ("def wrong(store, kind, record):\n    store.write(kind, record)\n",
     "a commit function that is not named _commit"),
    ("class Holder:\n" + "    " + COMMIT + "        store.write(kind, record)\n",
     "a _commit that is not the module's own definition"),
)
for snippet, description in GUARD_ALLOWED:
    parsed = ast.parse(snippet)
    if scan(parsed, aliases_in(parsed), "<self-test>"):
        failures += 1
        print(f"FAIL: the writer guard permits {description}")
    else:
        print(f"PASS: the writer guard permits {description}")
for snippet, description in GUARD_REFUSED:
    parsed = ast.parse(snippet)
    if scan(parsed, aliases_in(parsed), "<self-test>"):
        print(f"PASS: the writer guard still refuses {description}")
    else:
        failures += 1
        print(f"FAIL: the writer guard no longer refuses {description}")


# The authorised delegation is singular, and the real module is asserted to be
# what the narrowing assumes. A guard that permits "at least one" would let a
# second commit site appear beside the reviewed one and still report success,
# so zero and two are both failures here.
ADMISSION_SOURCE = (root / "tools" / "fabric" / "admission.py").read_text(encoding="utf-8")
ADMISSION_TREE = ast.parse(ADMISSION_SOURCE, filename="admission.py")
DEFINED_COMMITS = [node for node in ast.walk(ADMISSION_TREE)
                   if isinstance(node, ast.FunctionDef) and node.name == "_commit"]
ELIGIBLE_COMMITS = eligible_commits(ADMISSION_TREE)
AUTHORISED = permitted_delegations(ADMISSION_TREE)
WRITE_CALLS = [node for node in ast.walk(ADMISSION_TREE)
               if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
               and node.func.attr == "write"]
for condition, description in (
        (len(DEFINED_COMMITS) == 1,
         f"admission.py defines exactly one _commit ({len(DEFINED_COMMITS)})"),
        (len(ELIGIBLE_COMMITS) == 1,
         f"exactly one _commit is eligible to delegate ({len(ELIGIBLE_COMMITS)})"),
        (len(ELIGIBLE_COMMITS) == 1 and len(delegation_calls(ELIGIBLE_COMMITS[0])) == 1,
         "the eligible _commit makes exactly one C1 delegation"),
        (len(AUTHORISED) == 1,
         f"exactly one C1 delegation is authorised in admission.py ({len(AUTHORISED)})"),
        (len(WRITE_CALLS) == 1,
         f"admission.py contains exactly one .write call at all ({len(WRITE_CALLS)})"),
        (len(permitted_delegations(ast.parse(ADMISSION_SOURCE))) == 1,
         "the authorisation is stable across a second parse")):
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}")


for path in sorted((root / "tools" / "fabric").glob("*.py")):
    if path.name == "store.py":
        continue
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

    aliased = aliases_in(tree)
    hits = scan(tree, aliased, path.name)
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
from tools.common.immutable_store import ImmutableStore  # noqa: E402

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
# Increment 12 gave C1's Fabric store a real lock in its override. The common
# store keeps the no-op, so the no-op is asserted where it still lives; what
# the Fabric override does instead is asserted with the Increment 12 sections.
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

        # The common store, which no override has touched: still a no-op, and
        # asserted on its own root so the Fabric store's lock cannot mask it.
        with TemporaryDirectory() as plain_tmp:
            plain = ImmutableStore(Path(plain_tmp) / "plain")
            plain_root = Path(plain_tmp) / "plain"
            before_section = tree_snapshot(plain_root)
            with plain.request_critical_section("request-0001") as yielded:
                check(yielded is None, "request_critical_section yields nothing")
                check(tree_snapshot(plain_root) == before_section,
                      "entering the critical section creates nothing")
            check(tree_snapshot(plain_root) == before_section,
                  "leaving the critical section creates nothing")

            # The common store acquires nothing, so it holds no artefact.
            check(not (plain_root / "sequences" / "request_identity.lock").exists(),
                  "the common store's critical section creates no lock artefact")

            # A no-op yields immediately. Bounded and daemonised so a
            # regression fails rather than hangs.
            entered = threading.Event()

            def nested_entry():
                with plain.request_critical_section("request-0001"):
                    with plain.request_critical_section("request-0001"):
                        entered.set()

            nested_thread = threading.Thread(target=nested_entry, daemon=True)
            nested_thread.start()
            check(entered.wait(timeout=5),
                  "the common store's critical section does not block on re-entry")

        # The seam composes with the ordinary store lifecycle.
        with store.request_critical_section("request-0002"):
            written = store.write_atomic(
                store.path_for("capability-route", "CROUTE-0001"),
                {"route_id": "CROUTE-0001"})
        check(written.exists(), "a record still commits inside the critical section")
    else:
        bad("request_critical_section takes (request_id)")
        bad("request_critical_section yields nothing")
        bad("the common store's critical section does not block on re-entry")

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

# A shape references the authority that enforces it; it never restates one.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}


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
        evidence["actor"] = "CHOST-0001"
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
             determinism_class="deterministic", request_shape=REQUEST_SHAPE,
             response_shape=RESPONSE_SHAPE, failure_modes=("adapter-error",),
             resource_requirements={"host_memory_mb": 512}, compatible_with=(),
             provenance=ORIGIN,
             evidence=fixture_evidence("capability-contract"))),
        ("capability-package", "capability-packages", "CPKG-0001",
         "capability_package_id", CapabilityPackage(
             capability_package_id="CPKG-0001", capability_id="CAPDEF-0001",
             contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
             package_version="1.0.0",
             artifact_reference="oci://registry.invalid/summarise",
             resource_requirements={"host_memory_mb": 512},
             trust_domain="schott-platform", provenance=ORIGIN,
             evidence=fixture_evidence("capability-package"))),
        ("capability-host", "capability-hosts", "CHOST-0001",
         "capability_host_id", CapabilityHost(
             capability_host_id="CHOST-0001", node_identity_reference="node/schai",
             fabric_node_trust_record_id="TAUTH-000001",
             verified_resource_profile={"host_memory_mb": 8192},
             # Required since the optionality between schema, model and
             # admission was reconciled: a host claiming a verified profile
             # must name what verified it.
             verification_reference="EVID-000001",
             location_class="on-premises", data_classification="internal",
             availability_intent="available", provenance=ORIGIN,
             evidence=fixture_evidence("capability-host"))),
        ("capability-advertisement", "capability-advertisements", "CADV-000001",
         "advertisement_id", CapabilityAdvertisement(
             advertisement_id="CADV-000001", capability_host_id="CHOST-0001",
             capability_package_id="CPKG-0001", contract_id="CCON-0001",
             satisfied_contract_versions=("1.0.0",),
             advertised_resource_profile={"host_memory_mb": 512},
             observed_at=WHEN, valid_until=UNTIL, provenance=ORIGIN,
             evidence=fixture_evidence("capability-advertisement"))),
        ("capability-instance", "capability-instances", "CINST-000001",
         "instance_id", CapabilityInstance(
             instance_id="CINST-000001", capability_id="CAPDEF-0001",
             capability_package_id="CPKG-0001", capability_host_id="CHOST-0001",
             contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
             verified_resource_profile={"host_memory_mb": 512},
             admission_decision_id="TDEC-000001",
             package_trust_record_id="TAUTH-000002",
             host_trust_record_id="TAUTH-000001",
             effective_scope={"data_classification": "internal"},
             admitted_at=WHEN, admitted_until=UNTIL,
             advertisement_id="CADV-000001", provenance=ORIGIN,
             lifecycle_state="admitted",
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


# =======================================================================
# Deferred C — the shared approved-directory containment primitive
# =======================================================================
# Four callers carried the same six lines: resolve both sides, then refuse
# anything that is not strictly beneath the approved directory. A fourth copy
# is how one of them ends up subtly weaker, so the containment question moves
# to one primitive. What does NOT move is policy: each caller keeps its own
# error type, its own message, and its own decision about whether the approved
# directory itself is expanded.
#
# The primitive answers one question -- is this name contained? -- and answers
# it the way every caller already answered it. These assertions are the proof
# that nothing widened.

import inspect  # noqa: E402
from tools.common.containment import contained_path  # noqa: E402


def probe(approved, name):
    """The primitive's answer, as a short label."""
    result = contained_path(approved, name)
    return "refused" if result is None else result


with TemporaryDirectory() as tmp:
    root = Path(tmp) / "approved"
    root.mkdir()
    (root / "ok.yaml").write_text("a: 1", encoding="utf-8")
    (root / "nested").mkdir()
    (root / "nested" / "deep.yaml").write_text("a: 1", encoding="utf-8")
    outside = Path(tmp) / "outside"
    outside.mkdir()
    (outside / "secret.yaml").write_text("a: 1", encoding="utf-8")
    # A sibling whose name has the approved directory as a string prefix. A
    # containment test written with startswith() accepts this one.
    sibling = Path(tmp) / "approvedbar"
    sibling.mkdir()
    (sibling / "x.yaml").write_text("a: 1", encoding="utf-8")
    (root / "link-inside").symlink_to(root / "ok.yaml")
    (root / "link-outside").symlink_to(outside / "secret.yaml")
    (root / "linkdir-outside").symlink_to(outside)

    # --- what stays contained -------------------------------------------
    for name, description in (
            ("ok.yaml", "a normal child"),
            ("nested/deep.yaml", "a nested child"),
            ("./ok.yaml", "a dot segment"),
            ("nested//deep.yaml", "a doubled separator"),
            ("ok.yaml/", "a trailing separator"),
            ("missing.yaml", "a leaf that does not exist"),
            ("nodir/missing.yaml", "a parent that does not exist"),
            ("link-inside", "a symlink that stays inside"),
            ("éà.yaml", "a non-ASCII name"),
            (str(root / "ok.yaml"), "an absolute path inside the root")):
        check(probe(root, name) != "refused", f"{description} stays contained")

    # --- what is refused -------------------------------------------------
    for name, description in (
            ("../outside/secret.yaml", "a traversing name"),
            ("nested/../../outside/secret.yaml", "a traversal through a child"),
            (str(outside / "secret.yaml"), "an absolute path outside the root"),
            ("link-outside", "a symlink pointing out of the root"),
            ("linkdir-outside/secret.yaml", "a symlinked parent directory"),
            ("../approvedbar/x.yaml", "a sibling sharing the root's name prefix"),
            (str(sibling / "x.yaml"), "an absolute sibling sharing the prefix"),
            (".", "the approved directory itself"),
            ("", "an empty name")):
        check(probe(root, name) == "refused", f"{description} is refused")

    # The resolved path is the real one, so a caller reads what was checked.
    check(contained_path(root, "link-inside") == (root / "ok.yaml").resolve(),
          "a contained symlink resolves to the file that was checked")

    # --- the primitive decides nothing else -------------------------------
    # Existence is the caller's policy: the primitive answers containment for a
    # path that is not there, and the caller decides what that means.
    check(contained_path(root, "missing.yaml") == (root / "missing.yaml"),
          "containment is answered for a path that does not exist")

    # --- the primitive mutates nothing ------------------------------------
    def inventory(base):
        entries = {}
        for path in sorted(Path(base).rglob("*")):
            info = path.lstat()
            entries[str(path.relative_to(base))] = (
                stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
                info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns,
                info.st_size)
        return entries

    before = inventory(tmp)
    for name in ("ok.yaml", "../outside/secret.yaml", "missing.yaml",
                 "nodir/deeper/missing.yaml", "link-outside", "", "."):
        contained_path(root, name)
    check(inventory(tmp) == before,
          "answering containment creates, removes, and changes nothing")

    # A root that does not exist is still answered, and still not created.
    absent = Path(tmp) / "never"
    check(contained_path(absent, "x.yaml") == (absent / "x.yaml"),
          "an absent approved directory is answered rather than built")
    check(not absent.exists(), "an absent approved directory stays absent")

# --- the approved directory is the caller's to normalise ------------------
# Trust expands `~` before checking; Fabric does not. That difference is
# observable, it predates this consolidation, and the primitive does not decide
# it -- so neither caller's reach changes.
check("expanduser" not in inspect.getsource(contained_path),
      "the primitive expands nothing on the caller's behalf")

with TemporaryDirectory() as tmp:
    root = Path(tmp) / "approved"
    root.mkdir()
    (root / "ok.yaml").write_text("a: 1", encoding="utf-8")
    # Given an already-expanded root, the primitive is indifferent to how it
    # got that way.
    check(contained_path(Path(root).expanduser(), "ok.yaml")
          == contained_path(root, "ok.yaml"),
          "an already-expanded root is treated identically")
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

# A shape references the authority that enforces it; it never restates one.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}

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
    "request_shape": REQUEST_SHAPE,
    "response_shape": RESPONSE_SHAPE,
    "failure_modes": ["adapter-error"],
    "resource_requirements": {"host_memory_mb": 512},
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
    "resource_requirements": {"host_memory_mb": 512},
    "trust_domain": "schott-platform",
    "provenance": PROV,
}
HOST = {
    "capability_host_id": "CHOST-0001",
    "node_identity_reference": "node/schai",
    "fabric_node_trust_record_id": "TAUTH-000001",
    "verified_resource_profile": {"host_memory_mb": 8192},
    # Required since the optionality between schema, model and admission was
    # reconciled: a host claiming a verified profile must name what verified it.
    "verification_reference": "/approved/evidence/host-observed.txt",
    "location_class": "on-premises",
    "data_classification": "internal",
    "availability_intent": "available",
    "provenance": PROV,
}
ADVERTISEMENT = {
    "advertisement_id": "CADV-000001",
    "capability_host_id": "CHOST-0001",
    "capability_package_id": "CPKG-0001",
    "contract_id": "CCON-0001",
    "satisfied_contract_versions": ["1.0.0"],
    "advertised_resource_profile": {"host_memory_mb": 512},
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
    "verified_resource_profile": {"host_memory_mb": 512},
    "admission_decision_id": "TDEC-000001",
    "package_trust_record_id": "TAUTH-000002",
    "host_trust_record_id": "TAUTH-000001",
    "effective_scope": {"data_classification": "internal"},
    "admitted_at": STAMP,
    "admitted_until": LATER,
    "advertisement_id": "CADV-000001",
    "provenance": PROV,
    "lifecycle_state": "admitted",
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

for absent in ("trust.py",):
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
        fields["actor"] = "CHOST-0001"
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

# A shape references the authority that enforces it; it never restates one.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}


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
            determinism_class="deterministic", request_shape=REQUEST_SHAPE,
            response_shape=RESPONSE_SHAPE, failure_modes=("adapter-error",),
            resource_requirements={"host_memory_mb": 512}, compatible_with=(), provenance=PROV),
        "capability-package": dict(
            capability_package_id="CPKG-0001", capability_id="CAPDEF-0001",
            contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
            package_version="1.0.0", artifact_reference="oci://registry.invalid/summarise",
            resource_requirements={"host_memory_mb": 512}, trust_domain="schott-platform",
            provenance=PROV),
        "capability-host": dict(
            capability_host_id="CHOST-0001", node_identity_reference="node/schai",
            fabric_node_trust_record_id="TAUTH-000001",
            verified_resource_profile={"host_memory_mb": 8192},
            # Required since the optionality between schema, model and
            # admission was reconciled.
            verification_reference="/approved/evidence/host-observed.txt",
            location_class="on-premises",
            data_classification="internal", availability_intent="available",
            provenance=PROV),
        "capability-advertisement": dict(
            advertisement_id="CADV-000001", capability_host_id="CHOST-0001",
            capability_package_id="CPKG-0001", contract_id="CCON-0001",
            satisfied_contract_versions=("1.0.0",),
            advertised_resource_profile={"host_memory_mb": 512},
            observed_at=WHEN, valid_until=UNTIL, provenance=PROV),
        "capability-instance": dict(
            instance_id="CINST-000001", capability_id="CAPDEF-0001",
            capability_package_id="CPKG-0001", capability_host_id="CHOST-0001",
            contract_id="CCON-0001", satisfied_contract_versions=("1.0.0",),
            verified_resource_profile={"host_memory_mb": 512},
            admission_decision_id="TDEC-000001", package_trust_record_id="TAUTH-000002",
            host_trust_record_id="TAUTH-000001",
            effective_scope={"data_classification": "internal"},
            admitted_at=WHEN, admitted_until=UNTIL, advertisement_id="CADV-000001",
            provenance=PROV, lifecycle_state="admitted"),
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
for absent in ("trust.py", "health.py", "ledger.py"):
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


# --- The advertisement actor is the admitted host identity, exactly ---------
# Defect caught: a substring test against an invented namespaced actor form.
# It accepted anything containing the host identity, so a forged actor that
# merely mentioned the subject passed as the subject.
ADVERTISEMENT_BODY = dict(
    advertisement_id="CADV-000009", capability_host_id="CHOST-0001",
    capability_package_id="CPKG-0001", contract_id="CCON-0001",
    satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"host_memory_mb": 512},
    observed_at=WHEN, valid_until=UNTIL, provenance=PROV)


def advertisement(actor):
    return RECORD_MODELS["capability-advertisement"](
        evidence=dict(evidence_for("capability-advertisement"), actor=actor),
        **ADVERTISEMENT_BODY)


with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    fabric = Path(tmp) / "fabric"
    written = store.write("capability-advertisement", advertisement("CHOST-0001"))
    check(Path(written).name == "CADV-000009.yaml",
          "an advertisement whose actor is exactly its capability_host_id is accepted")
    stored = yaml.safe_load(Path(written).read_text(encoding="utf-8"))
    check(stored["evidence"]["actor"] == "CHOST-0001",
          "the accepted actor is persisted unchanged as CHOST-0001")
    check(stored["capability_host_id"] == stored["evidence"]["actor"],
          "the persisted actor is identical to the advertised host identity")

# Every one of these mentions, contains, or resembles the subject. None is it.
FORGED_ACTORS = (
    ("host:CHOST-0001", "a namespaced form"),
    ("prefix-CHOST-0001", "a prefixed form"),
    ("CHOST-0001-suffix", "a suffixed form"),
    ("attacker:CHOST-0001:forged", "an embedded form"),
    (" CHOST-0001", "a leading space"),
    ("CHOST-0001 ", "a trailing space"),
    ("chost-0001", "a lowercase lookalike"),
    ("CHOST-0002", "a different admitted subject"),
    ("CHOST-00010", "a longer identifier sharing the prefix"),
    ("", "an empty actor"),
)
for actor, description in FORGED_ACTORS:
    with TemporaryDirectory() as tmp:
        store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        fabric = Path(tmp) / "fabric"
        before = forensic(fabric)
        refuses_fabric(lambda a=actor: store.write("capability-advertisement",
                                                   advertisement(a)),
                       f"an advertisement actor carrying {description} fails closed")
        after = forensic(fabric)
        check(after == before,
              f"{description} is refused before any filesystem mutation")
        check(store.counts()["capability-advertisement"] == 0,
              f"{description} allocates no record identity")
        check(not (fabric / "capability-advertisements" / "CADV-000009.yaml").exists(),
              f"{description} creates no final record")
        residue = list((fabric / "capability-advertisements").glob("*.tmp"))
        check(residue == [], f"{description} leaves no temporary artefact")
        sequence = fabric / "sequences" / "capability-advertisement.seq"
        check(not sequence.exists(),
              f"{description} advances no sequence state")

# The comparison is equality, not containment: neither direction matches.
with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    refuses_fabric(lambda: store.write("capability-advertisement",
                                       advertisement("CHOST-000")),
                   "an actor that is a substring of the host identity fails closed")
    refuses_fabric(lambda: store.write("capability-advertisement",
                                       advertisement("CHOST-0001CHOST-0001")),
                   "an actor that repeats the host identity fails closed")

# node_identity_reference is the underlying node identity, not the actor.
with TemporaryDirectory() as tmp:
    store = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    refuses_fabric(lambda: store.write("capability-advertisement",
                                       advertisement("node/schai")),
                   "a node identity reference is not the fabric evidence actor")


# --- Which outcomes may omit route provenance -------------------------------
# The model cannot know the outcome from the pair alone; these rules can,
# because they already derive it. Every decision a route governed names it, and
# the one decision no route governed must not invent an identity to fill the
# space.
PROVENANCE_BASE = dict(
    selection_id="CSEL-000100",
    request_class={"data_classification": "internal"},
    considered_candidates=(), excluded_candidates=(),
    selected_instance_id=None,
    selection_reason="no route resolved for the request class",
    selected_at=WHEN, provenance={"class": "declared", "source": "core"})
PROVENANCE_EVIDENCE = dict(
    actor="core", approving_authority=None, recorded_at=WHEN,
    request_id="req-route-provenance", request_digest="sha256:" + "0" * 64,
    causal_references=(), trust_evidence_references=())
SELECTION_MODEL = RECORD_MODELS["capability-selection"]


def provenance_case(category, **overrides):
    return SELECTION_MODEL(**dict(
        PROVENANCE_BASE, evidence=assemble_evidence(
            "capability-selection",
            **dict(PROVENANCE_EVIDENCE, reason_category=category)),
        **overrides))


validate_record_evidence("capability-selection", provenance_case("no-candidate"))
ok("a no-candidate outcome may omit route provenance")

validate_record_evidence("capability-selection", provenance_case(
    "selection", selection_id="CSEL-000106", route_id="CROUTE-0001",
    route_version=1, considered_candidates=("CINST-000001",),
    selected_instance_id="CINST-000001"))
ok("a selected outcome carrying route provenance is accepted")

refuses_fabric(lambda: validate_record_evidence(
    "capability-selection", provenance_case(
        "selection", selection_id="CSEL-000107",
        considered_candidates=("CINST-000001",),
        selected_instance_id="CINST-000001")),
    "a selected outcome may not omit the route that governed it")

EXCLUDED = ({"instance_id": "CINST-000001",
             "reason": "admission-window-expired"},)

refuses_fabric(lambda: validate_record_evidence(
    "capability-selection", provenance_case(
        "selection-refusal", selection_id="CSEL-000108",
        considered_candidates=("CINST-000001",), excluded_candidates=EXCLUDED,
        refusal_reason="no eligible candidate")),
    "a refusal over a resolved route's candidates may not omit route provenance")

validate_record_evidence("capability-selection", provenance_case(
    "selection-refusal", selection_id="CSEL-000109", route_id="CROUTE-0001",
    route_version=1, considered_candidates=("CINST-000001",),
    excluded_candidates=EXCLUDED, refusal_reason="no eligible candidate"))
ok("a resolved-route refusal carrying route provenance is accepted")

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

# --- Trust verification adapter, C3 (increment 5) ----------------------------
# A read-only bridge to the released Trust Plane. It resolves standing through
# the released query interfaces and nothing else: no direct trust-store path,
# no cache, no retry, no verdict of its own.
TRUSTPY_OUTPUT="$(python3 - "${ROOT}" <<'TRUSTPY' 2>&1 || true
import hashlib
import os
import stat
import sys
from datetime import datetime, timedelta, timezone
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


from tools.trust.store import TrustStore  # noqa: E402
from tools.trust.models import (  # noqa: E402
    TrustEvidenceReference, TrustScope, TrustState, TrustVerificationDetails,
    VerificationMethod,
)
from tools.trust.root_authority import (  # noqa: E402
    declare_root_authority, load_root_declaration,
)
from tools.trust.evaluator import create_decision  # noqa: E402
from tools.trust import query as Q  # noqa: E402
from tools.trust.identifiers import (  # noqa: E402
    DECISION_ID, EVIDENCE_ID, LINEAGE_ID, RECORD_ID,
)
from tools.fabric.errors import FabricError  # noqa: E402
from tools.fabric.store import FabricStore  # noqa: E402
from tools.fabric.models import RECORD_MODELS  # noqa: E402
from tools.fabric.evidence import assemble_evidence  # noqa: E402
from tools.fabric.request_identity import compute_request_digest  # noqa: E402
# The import that must fail before increment 5 exists.
from tools.fabric.trust_adapter import (  # noqa: E402
    REASON_EXPIRED,
    REASON_NOT_USABLE,
    REASON_NO_STANDING,
    REASON_REVOKED,
    REASON_SUBJECT_TYPE_MISMATCH,
    REASON_UNAVAILABLE,
    REASON_UNREADABLE,
    UNVERIFIED,
    UNVERIFIED_REASONS,
    VERIFIED,
    TrustVerification,
    verify_subject,
    verify_trust_record,
)
import tools.fabric.trust_adapter as adapter_module  # noqa: E402

import yaml as _yaml  # noqa: E402

UID = os.geteuid()
GID = os.getegid()

STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
SHORT = STAMP + timedelta(days=2)
AFTER = STAMP + timedelta(days=3)
YEAR = STAMP + timedelta(days=365)
NAIVE = datetime(2026, 8, 2, 9, 0, 0)
WHEN = datetime(2026, 8, 5, 9, 0, 0, tzinfo=timezone.utc)
PROV = {"class": "declared", "source": "operator"}
DIGEST = compute_request_digest("select", {"route_id": "CROUTE-0001"})


def selection_evidence(request_id):
    """Valid CSEL evidence: a requesting actor and no human approver."""
    return assemble_evidence(
        "capability-selection", actor="fabric:selection",
        reason_category="selection", recorded_at=WHEN, request_id=request_id,
        request_digest=DIGEST, causal_references=("CROUTE-0001",),
        trust_evidence_references=())


def forensic(base):
    """Every path, type, mode, owner, inode, mtime, size, and byte."""
    entries = {}
    if not base.exists():
        return entries
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        digest = (hashlib.sha256(path.read_bytes()).hexdigest()
                  if stat.S_ISREG(info.st_mode) else "")
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode),
            info.st_uid, info.st_gid, info.st_ino, info.st_mtime_ns,
            info.st_size, digest)
    return entries


def evidence(store):
    return (TrustEvidenceReference(
        evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
        reference="/approved/evidence/fingerprint.txt", recorded_at=STAMP),)


def details():
    return TrustVerificationDetails(
        subject_property="ssh-host-key-fingerprint",
        observed_value_reference="/approved/evidence/observed.txt",
        comparison_source="printed-console-readout",
        performed_by="operator-role-reference", performed_at=STAMP)


def scope():
    return TrustScope(
        scope_id="TSCOPE-000001", subject_type="host",
        permitted_capabilities=("coding-workload",),
        permitted_operations=("linux.hostname",),
        permitted_data_classifications=("internal",),
        permitted_targets=("schmgmt.home.arpa",),
        validity_start=STAMP, validity_end=YEAR)


def root_input():
    return {
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat(),
        },
        "evidence_references": [{
            "evidence_id": "TEVID-000001", "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": STAMP.isoformat(),
        }],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }


def seeded(tmp):
    """A real trust store: an operator root, plus trusted, expiring, revoked."""
    store = TrustStore(Path(tmp) / "trust")
    approved = Path(tmp) / "approved"
    approved.mkdir()
    (approved / "root.yaml").write_text(_yaml.safe_dump(root_input()),
                                        encoding="utf-8")
    authority = declare_root_authority(
        store, load_root_declaration("root.yaml", approved_directory=str(approved)))

    def decide(subject, state, decided_at, expiration, reason, lineage_id=None,
               revokes_record_id=None):
        return create_decision(
            store, subject_id=subject, subject_type="host", requested_state=state,
            actor_authority_id=authority.authority_id, decided_at=decided_at,
            reason=reason, evidence_references=evidence(store),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=details(), scope=scope(), expiration=expiration,
            lineage_id=lineage_id, revokes_record_id=revokes_record_id)

    granted = decide("HOST-GOOD", TrustState.TRUSTED.value, STAMP, YEAR,
                     "granted for the fabric trust adapter regression")
    lapsing = decide("HOST-LAPSED", TrustState.TRUSTED.value, STAMP, SHORT,
                     "granted with a short expiration for the adapter regression")
    revoking = decide("HOST-REVOKED", TrustState.TRUSTED.value, STAMP, YEAR,
                      "granted before revocation for the adapter regression")
    decide("HOST-REVOKED", TrustState.REVOKED.value, AFTER, None,
           "revoked by explicit operator decision",
           lineage_id=revoking.lineage.lineage_id,
           revokes_record_id=revoking.record.record_id)
    return store, granted, lapsing


class CountingStore:
    """The real store, counting every read the adapter performs."""

    def __init__(self, store):
        self._store = store
        self.calls = 0

    def __getattr__(self, name):
        attribute = getattr(self._store, name)
        if not callable(attribute):
            return attribute

        def counted(*args, **kwargs):
            self.calls += 1
            return attribute(*args, **kwargs)

        return counted


class UnavailableStore:
    """A Trust Plane that cannot be read at all."""

    def __init__(self):
        self.calls = 0

    def __getattr__(self, name):
        def unavailable(*args, **kwargs):
            self.calls += 1
            raise OSError("the trust store is unavailable")

        return unavailable


class MalformedStore:
    """A Trust Plane whose records are unreadable nonsense."""

    def read(self, *args, **kwargs):
        return {"state": object(), "expiration": "not-a-timestamp"}

    def all_records(self, *args, **kwargs):
        return [{"lineage_id": None, "current_decision_id": None}]

    def __getattr__(self, name):
        def anything(*args, **kwargs):
            return []

        return anything


# --- 1. Valid current trust --------------------------------------------------
with TemporaryDirectory() as tmp:
    store, granted, _ = seeded(tmp)
    released = Q.get_current_trust(store, "HOST-GOOD", evaluated_at=STAMP)
    verification = verify_subject(store, "HOST-GOOD", evaluated_at=STAMP)

    check(isinstance(verification, TrustVerification),
          "the adapter returns its immutable verification result")
    check(verification.status == VERIFIED,
          "a usable trust record verifies")
    check(verification.subject_id == released["subject_id"] == "HOST-GOOD",
          "the verified subject is the subject that was asked about")
    check(verification.standing == released["effective_state"],
          "the effective standing is the one the trust plane reports")
    check(verification.stored_standing == released["stored_state"],
          "the stored standing is preserved alongside the effective one")
    check(verification.evaluated_at == STAMP.isoformat(),
          "the result carries the caller's evaluation instant, unchanged")
    check(verification.record_id == released["record_id"],
          "the trust record identity agrees with the trust plane")
    check(verification.decision_id == released["decision_id"],
          "the trust decision identity agrees with the trust plane")
    check(verification.lineage_id == released["lineage_id"],
          "the lineage identity agrees with the trust plane")
    check(list(verification.evidence_reference_ids)
          == list(released["evidence_reference_ids"]),
          "the evidence references agree with the trust plane")
    check(verify_subject(store, "HOST-GOOD", evaluated_at=STAMP) == verification,
          "identical authoritative inputs return an identical result")
    check(verify_subject(store, "HOST-GOOD", evaluated_at=STAMP).to_dict()
          == verification.to_dict(),
          "repeated results serialise identically")

    # The record-identity entry point resolves to the same standing.
    by_record = verify_trust_record(store, granted.record.record_id,
                                    evaluated_at=STAMP)
    check(by_record.status == VERIFIED and by_record.subject_id == "HOST-GOOD",
          "a trust record identity resolves to the same verified subject")

    # Nothing about the result is mutable.
    frozen = True
    try:
        verification.evidence_reference_ids.append("TEVID-999999")
        frozen = False
    except AttributeError:
        pass
    check(frozen, "the verification's evidence references cannot be appended to")
    try:
        object.__setattr__  # noqa: B018 - presence only
        verification.status = "tampered"
        frozen = False
    except Exception:  # noqa: BLE001
        pass
    check(frozen, "the verification result cannot be reassigned")

    # An evaluation instant is required, and must be an instant.
    for bad_instant, description in ((NAIVE, "a naive datetime"),
                                     ("2026-08-02T09:00:00-05:00", "text"),
                                     (None, "nothing at all")):
        try:
            verify_subject(store, "HOST-GOOD", evaluated_at=bad_instant)
            bad(f"an evaluation instant supplied as {description} fails closed "
                "(was accepted)")
        except FabricError:
            ok(f"an evaluation instant supplied as {description} fails closed")
        except Exception as error:  # noqa: BLE001
            bad(f"an evaluation instant supplied as {description} fails closed "
                f"(raised {type(error).__name__})")

# --- 2. Absent trust ---------------------------------------------------------
with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    absent = verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP)
    check(absent.status == UNVERIFIED, "a subject with no trust lineage is unverified")
    check(absent.standing == TrustState.UNKNOWN.value,
          "absent trust reports the unknown standing the trust plane returned")
    check(absent.reasons, "an unverified result explains itself")
    check(all(isinstance(reason, str) and reason for reason in absent.reasons),
          "every refusal reason is written text")
    for forbidden in ("trusted", "admitted", "eligible", "provisional"):
        check(not any(forbidden in reason.lower() for reason in absent.reasons)
              or absent.status == UNVERIFIED,
              f"absent trust is never reported as {forbidden}")
    check(absent.record_id is None and absent.decision_id is None,
          "absent trust cites no trust record or decision")
    check(verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP) == absent,
          "an absent subject verifies identically on repetition")

# --- 3. Expired trust --------------------------------------------------------
with TemporaryDirectory() as tmp:
    store, _, lapsing = seeded(tmp)
    stored_before = Q.get_trust_record(store, lapsing.record.record_id)
    lapsed = verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER)
    check(lapsed.status == UNVERIFIED,
          "trust that has expired at the evaluation instant is unverified")
    check(lapsed.stored_standing == TrustState.TRUSTED.value,
          "the stored standing is still what the record says")
    check(lapsed.standing == TrustState.EXPIRED.value,
          "the effective standing at that instant is expired")
    check(lapsed.status == UNVERIFIED,
          "stored historical trust does not override the effective expired standing")
    live = verify_subject(store, "HOST-LAPSED", evaluated_at=STAMP)
    check(live.status == VERIFIED,
          "the same subject verifies before its expiration elapsed")
    check(Q.get_trust_record(store, lapsing.record.record_id) == stored_before,
          "verifying an expired subject leaves the historical record untouched")

# --- 4. Revoked trust --------------------------------------------------------
with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    revoked = verify_subject(store, "HOST-REVOKED", evaluated_at=AFTER)
    check(revoked.status == UNVERIFIED, "a revoked subject is unverified")
    check(revoked.standing == TrustState.REVOKED.value,
          "the revoked standing is reported as the trust plane reports it")
    # Revocation moves the lineage head. The evaluation instant governs expiry,
    # not which decision is current, so a revoked subject is revoked at every
    # instant -- the earlier grant is history, and history is not standing.
    earlier = verify_subject(store, "HOST-REVOKED", evaluated_at=STAMP)
    check(earlier.status == UNVERIFIED,
          "a revoked subject is unverified even at an instant before the revocation")
    check(earlier.standing == TrustState.REVOKED.value,
          "earlier trusted history is not reused after revocation")
    check(earlier.reasons == revoked.reasons,
          "the refusal reason does not vary with the instant once trust is revoked")

# --- 5. Malformed or unverifiable trust -------------------------------------
malformed = verify_subject(MalformedStore(), "HOST-BROKEN", evaluated_at=STAMP)
check(malformed.status == UNVERIFIED, "malformed trust data is unverified")
check(malformed.standing == TrustState.UNKNOWN.value,
      "malformed trust reports the unknown standing, never a guess")
check(malformed.reasons, "malformed trust explains itself")
serialised = " ".join(malformed.reasons) + " " + str(malformed.to_dict())
for leak, description in ((" 0x", "an object address"),
                          ("/tmp/", "a filesystem path"),
                          ("Traceback", "a traceback"),
                          ("object at", "an object repr")):
    check(leak not in serialised,
          f"an unverified result never carries {description}")
check(verify_subject(MalformedStore(), "HOST-BROKEN", evaluated_at=STAMP)
      == malformed,
      "malformed trust returns an identical result on repetition")

# --- 6. Trust Plane unavailable ---------------------------------------------
unavailable_store = UnavailableStore()
unavailable = verify_subject(unavailable_store, "HOST-GOOD", evaluated_at=STAMP)
check(unavailable.status == UNVERIFIED,
      "an unavailable trust plane yields an unverified result")
check(unavailable.standing == TrustState.UNKNOWN.value,
      "an unavailable trust plane assumes no standing")
check(unavailable_store.calls == 1,
      f"an unavailable trust plane is queried once and not retried "
      f"({unavailable_store.calls} calls)")
second = UnavailableStore()
verify_subject(second, "HOST-GOOD", evaluated_at=STAMP)
check(second.calls == 1, "a second unavailable verification also queries once")

with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    counting = CountingStore(store)
    first_calls = None
    verify_subject(counting, "HOST-GOOD", evaluated_at=STAMP)
    first_calls = counting.calls
    counting.calls = 0
    verify_subject(counting, "HOST-GOOD", evaluated_at=STAMP)
    check(counting.calls == first_calls,
          "a repeated verification performs the same reads, so nothing was cached")
    check(first_calls > 0, "verification actually consults the trust plane")

# --- 7. No stateful influence ------------------------------------------------
with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    baseline = verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER)
    for _ in range(5):
        verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER)
    check(verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER) == baseline,
          "repeated verification populates no cache and drifts nowhere")

    # A history of successful fabric selections is not trust evidence.
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    for number in range(1, 4):
        selection = RECORD_MODELS["capability-selection"](
            selection_id=f"CSEL-00000{number}", route_id="CROUTE-0001",
            route_version=1, request_class={"data_classification": "internal"},
            considered_candidates=("CINST-000001",), excluded_candidates=(),
            selected_instance_id="CINST-000001",
            selection_reason="first eligible candidate in declared order",
            selected_at=WHEN, provenance=PROV,
            evidence=selection_evidence(f"request-selection-{number}"))
        fabric.write("capability-selection", selection)
    check(fabric.counts()["capability-selection"] == 3,
          "a history of successful selections exists")
    check(verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER) == baseline,
          "a history of successful selections alters no trust standing")
    check(verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP).status
          == UNVERIFIED,
          "selection history is never accepted as trust evidence for an unknown subject")

# --- 8. Read-only against both stores ---------------------------------------
SUBJECTS = ("HOST-GOOD", "HOST-LAPSED", "HOST-REVOKED", "HOST-NEVER-SEEN")
for subject in SUBJECTS:
    for instant, moment in ((STAMP, "at the grant instant"), (AFTER, "after it")):
        with TemporaryDirectory() as tmp:
            store, _, _ = seeded(tmp)
            fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID,
                                 expected_gid=GID)
            trust_root = Path(tmp) / "trust"
            fabric_root = Path(tmp) / "fabric"
            trust_before = forensic(trust_root)
            fabric_before = forensic(fabric_root)
            verify_subject(store, subject, evaluated_at=instant)
            check(forensic(trust_root) == trust_before,
                  f"verifying {subject} {moment} changes nothing in the trust store")
            check(forensic(fabric_root) == fabric_before,
                  f"verifying {subject} {moment} changes nothing in the fabric store")

with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    trust_root = Path(tmp) / "trust"
    before = forensic(trust_root)
    verify_subject(MalformedStore(), "HOST-BROKEN", evaluated_at=STAMP)
    verify_subject(UnavailableStore(), "HOST-GOOD", evaluated_at=STAMP)
    check(forensic(trust_root) == before,
          "a refused verification creates no trust file, sequence, or temporary")
    residue = sorted(p.name for p in trust_root.rglob("*.tmp"))
    check(residue == [], "a refused verification leaves no temporary artefact")

# --- 9. The adapter claims nothing beyond verification ----------------------
for later in ("admit", "reject", "evaluate_eligibility", "compute_eligibility",
              "select", "transition", "advertise", "route", "load", "invoke",
              "health", "remediate", "repair", "retry", "cache", "refresh"):
    check(not hasattr(adapter_module, later),
          f"the trust adapter exposes no '{later}' behaviour at increment 5")
for writer in ("write", "write_record", "create_decision", "declare_root_authority",
               "record_decision", "revoke", "grant"):
    check(not hasattr(adapter_module, writer),
          f"the trust adapter writes no trust or fabric state: no '{writer}'")
for absent in ("health.py",):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 5 creates no {absent}")


# --- Structural coherence of the released response (increment 5 correction) --
# Defect caught: trusting `usable` and the standing alone. A response that
# looks trusted but carries no lineage, no record, no decision, or somebody
# else's subject would verify -- so a malformed answer could grant standing
# that nothing in the Trust Plane actually says.
RELEASED_QUERY = adapter_module.get_current_trust
RELEASED_RECORD = adapter_module.get_trust_record


class ForgedQuery:
    """Substitutes the released query so a malformed response can be observed.

    There is no way to make the real Trust Plane return an incoherent answer,
    and that is the point: the adapter must not assume its dependency is
    well-behaved. The substitution is test-only and is undone below; the
    adapter gains no hook.
    """

    def __init__(self, payload):
        self.payload = payload
        self.calls = 0

    def __call__(self, store, subject_id, *, evaluated_at):
        self.calls += 1
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


def under_forged_query(payload, subject="HOST-A", instant=None):
    """Verify `subject` against a forged released response."""
    query = ForgedQuery(payload)
    adapter_module.get_current_trust = query
    try:
        return verify_subject(object(), subject,
                              evaluated_at=instant or STAMP), query
    finally:
        adapter_module.get_current_trust = RELEASED_QUERY


def released_shape(**overrides):
    """A response with the shape the released query produces."""
    payload = {
        "subject_id": "HOST-A",
        "stored_state": TrustState.TRUSTED.value,
        "effective_state": TrustState.TRUSTED.value,
        "lineage_id": "TLIN-000001",
        "evaluated_at": STAMP.isoformat(),
        "scope": None,
        "record_id": "TREC-000001",
        "decision_id": "TDEC-000001",
        "evidence_reference_ids": ["TEVID-000001"],
        "reasons": [],
        "usable": True,
    }
    payload.update(overrides)
    return payload


# The coherent shape must still verify, or the guard is simply refusing.
coherent, _ = under_forged_query(released_shape())
check(coherent.status == VERIFIED,
      "a coherent released response still verifies")
check(coherent.record_id == "TREC-000001" and coherent.decision_id == "TDEC-000001"
      and coherent.lineage_id == "TLIN-000001",
      "a coherent released response preserves its authoritative identities")

INCOHERENT = (
    (released_shape(lineage_id=None), "no lineage identity"),
    (released_shape(record_id=None), "no trust record identity"),
    (released_shape(decision_id=None), "no decision identity"),
    (released_shape(lineage_id=""), "an empty lineage identity"),
    (released_shape(record_id=12345), "a non-textual record identity"),
    (released_shape(decision_id=["TDEC-000001"]), "a decision identity in a list"),
    (released_shape(subject_id="SOMEONE-ELSE"), "a different subject than requested"),
    (released_shape(subject_id=None), "no subject identity"),
    (released_shape(subject_id="host-a"), "a subject differing only in case"),
    (released_shape(usable="yes"), "a usable flag that is text"),
    (released_shape(usable=1), "a usable flag that is a number"),
    (released_shape(usable=None), "no usable flag"),
    (released_shape(effective_state="banana"), "an unrecognised effective standing"),
    (released_shape(stored_state="banana"), "an unrecognised stored standing"),
    (released_shape(effective_state=None), "no effective standing"),
    (released_shape(evaluated_at="1999-01-01T00:00:00+00:00"),
     "an evaluation instant that is not the one supplied"),
    (released_shape(evidence_reference_ids="TEVID-000001"),
     "evidence references supplied as a bare string"),
    (released_shape(evidence_reference_ids=[123]),
     "a non-textual evidence reference"),
    (released_shape(evidence_reference_ids=["", "TEVID-000001"]),
     "an empty evidence reference"),
    (released_shape(evidence_reference_ids=None), "no evidence reference collection"),
    (released_shape(reasons="something went wrong"), "reasons supplied as a bare string"),
    ("not a mapping at all", "a response that is not a mapping"),
    (None, "a response that is nothing"),
)
for payload, description in INCOHERENT:
    result, query = under_forged_query(payload)
    check(result.status == UNVERIFIED,
          f"a released response carrying {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"a released response carrying {description} is reported as unreadable")
    check(query.calls == 1,
          f"a released response carrying {description} is not asked for twice")
    repeated, _ = under_forged_query(payload)
    check(repeated == result,
          f"a released response carrying {description} refuses identically on repetition")
    leaked = " ".join(result.reasons) + " " + str(result.to_dict())
    for token, leak in ((" 0x", "an object address"), ("/tmp/", "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr")):
        check(token not in leaked,
              f"a response carrying {description} leaks no {leak}")

# An unresolved reference is not the same fact as absent trust.
UNRESOLVED = released_shape(
    stored_state=TrustState.UNKNOWN.value, effective_state=TrustState.UNKNOWN.value,
    usable=False, record_id=None, decision_id=None, evidence_reference_ids=[],
    reasons=["the lineage head cites a decision with no trust record"])
unresolved, _ = under_forged_query(UNRESOLVED)
check(unresolved.status == UNVERIFIED, "an unresolved lineage reference does not verify")
check(unresolved.reasons == (REASON_UNREADABLE,),
      "an unresolved lineage reference is unreadable, not merely absent")

ABSENT = released_shape(
    stored_state=TrustState.UNKNOWN.value, effective_state=TrustState.UNKNOWN.value,
    usable=False, lineage_id=None, record_id=None, decision_id=None,
    evidence_reference_ids=[], reasons=["no trust lineage exists for this subject"])
absent_shape, _ = under_forged_query(ABSENT)
check(absent_shape.reasons == (REASON_NO_STANDING,),
      "trust that is genuinely absent is still reported as absent, not unreadable")
check(unresolved.reasons != absent_shape.reasons,
      "an unresolved reference is distinguishable from truly absent trust")

# A standing that is recognised but unusable keeps its own reason.
for standing, reason, description in (
        (TrustState.EXPIRED.value, REASON_EXPIRED, "expired"),
        (TrustState.REVOKED.value, REASON_REVOKED, "revoked"),
        (TrustState.QUARANTINED.value, REASON_NOT_USABLE, "quarantined")):
    result, _ = under_forged_query(released_shape(
        stored_state=(TrustState.TRUSTED.value
                      if standing == TrustState.EXPIRED.value else standing),
        effective_state=standing, usable=False))
    check(result.reasons == (reason,),
          f"a {description} standing keeps its own reason rather than becoming unreadable")

# --- A trust record must be the record that was asked for -------------------
class ForgedRecord:
    def __init__(self, record):
        self.record = record
        self.calls = 0

    def __call__(self, store, record_id):
        self.calls += 1
        if isinstance(self.record, Exception):
            raise self.record
        return self.record


def under_forged_record(record, requested="TREC-000001"):
    lookup = ForgedRecord(record)
    adapter_module.get_trust_record = lookup
    try:
        return verify_trust_record(object(), requested, evaluated_at=STAMP), lookup
    finally:
        adapter_module.get_trust_record = RELEASED_RECORD


MISMATCHED_RECORDS = (
    ({"subject_id": "HOST-A"}, "no record identity"),
    ({"subject_id": "HOST-A", "record_id": "TREC-999999"},
     "a record identity that is not the one requested"),
    ({"subject_id": "HOST-A", "record_id": ""}, "an empty record identity"),
    ({"subject_id": "HOST-A", "record_id": 1}, "a non-textual record identity"),
    ({"record_id": "TREC-000001"}, "no subject identity"),
    ({"record_id": "TREC-000001", "subject_id": ""}, "an empty subject identity"),
    ("not a mapping", "a record that is not a mapping"),
)
for record, description in MISMATCHED_RECORDS:
    result, lookup = under_forged_record(record)
    check(result.status == UNVERIFIED,
          f"a retrieved record carrying {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"a retrieved record carrying {description} is reported as unreadable")
    check(lookup.calls == 1,
          f"a retrieved record carrying {description} is not fetched twice")

check(adapter_module.get_current_trust is RELEASED_QUERY
      and adapter_module.get_trust_record is RELEASED_RECORD,
      "the released query interfaces are restored after the substitution")

# --- The corrected guard changes nothing on disk ----------------------------
with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    trust_root = Path(tmp) / "trust"
    fabric_root = Path(tmp) / "fabric"
    trust_before = forensic(trust_root)
    fabric_before = forensic(fabric_root)
    for payload, _ in INCOHERENT:
        under_forged_query(payload)
    for record, _ in MISMATCHED_RECORDS:
        under_forged_record(record)
    verify_subject(store, "HOST-GOOD", evaluated_at=STAMP)
    verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP)
    check(forensic(trust_root) == trust_before,
          "refusing every malformed response changes nothing in the trust store")
    check(forensic(fabric_root) == fabric_before,
          "refusing every malformed response changes nothing in the fabric store")


# --- The evaluation instant must be stated, not merely not-contradicted ------
# Defect caught: tolerating an absent evaluated_at. A response that never says
# which moment it describes cannot be checked against the moment that was
# asked about, so an answer about any instant would pass as an answer about
# this one.
NO_INSTANT = released_shape()
del NO_INSTANT["evaluated_at"]
MISSING_INSTANT = (
    (NO_INSTANT, "no evaluation instant at all"),
    (released_shape(evaluated_at=None), "an evaluation instant of nothing"),
    (released_shape(evaluated_at=12345), "a numeric evaluation instant"),
    (released_shape(evaluated_at=STAMP), "an evaluation instant that is not text"),
    (released_shape(evaluated_at=""), "an empty evaluation instant"),
    (released_shape(evaluated_at=[STAMP.isoformat()]),
     "an evaluation instant inside a list"),
)
for payload, description in MISSING_INSTANT:
    result, query = under_forged_query(payload)
    check(result.status == UNVERIFIED,
          f"a released response carrying {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"a released response carrying {description} is reported as unreadable")
    check(query.calls == 1,
          f"a released response carrying {description} is asked for once")
    repeated, _ = under_forged_query(payload)
    check(repeated == result,
          f"a released response carrying {description} refuses identically on repetition")

# --- Absent trust cites nothing. Anything cited is a reference, not absence --
# Defect caught: reading an unknown standing as "no trust exists" even when the
# response names a lineage, a record, and a decision. A response citing
# authoritative identities is describing something that exists and could not be
# read -- reporting that as absence loses the difference.
IDENTITY_FIELDS = ("lineage_id", "record_id", "decision_id")
IDENTITY_VALUES = {"lineage_id": "TLIN-000001",
                   "record_id": "TREC-000001",
                   "decision_id": "TDEC-000001"}


def unknown_citing(*fields):
    """An unknown standing that cites exactly the named identities."""
    return released_shape(
        stored_state=TrustState.UNKNOWN.value,
        effective_state=TrustState.UNKNOWN.value, usable=False,
        **{name: (IDENTITY_VALUES[name] if name in fields else None)
           for name in IDENTITY_FIELDS})


CITED_COMBINATIONS = (
    (("lineage_id", "record_id", "decision_id"), "a lineage, a record, and a decision"),
    (("lineage_id",), "only a lineage"),
    (("record_id",), "only a record"),
    (("decision_id",), "only a decision"),
    (("lineage_id", "record_id"), "a lineage and a record"),
    (("lineage_id", "decision_id"), "a lineage and a decision"),
    (("record_id", "decision_id"), "a record and a decision"),
)
for fields, description in CITED_COMBINATIONS:
    result, query = under_forged_query(unknown_citing(*fields))
    check(result.status == UNVERIFIED,
          f"an unknown standing citing {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"an unknown standing citing {description} is unreadable, not absent")
    check(query.calls == 1,
          f"an unknown standing citing {description} is asked for once")

# An unknown effective standing over a stored standing that is not unknown is
# describing a record it could not interpret, not a subject it never found.
result, _ = under_forged_query(released_shape(
    stored_state=TrustState.TRUSTED.value,
    effective_state=TrustState.UNKNOWN.value, usable=False))
check(result.reasons == (REASON_UNREADABLE,),
      "an unknown effective standing over a stored grant is unreadable, not absent")

# Exactly one shape is genuine absence: unknown, unusable, citing nothing.
genuinely_absent, _ = under_forged_query(unknown_citing())
check(genuinely_absent.status == UNVERIFIED,
      "genuinely absent trust does not verify")
check(genuinely_absent.reasons == (REASON_NO_STANDING,),
      "only the exact absent shape is reported as no trust standing")
check(genuinely_absent.lineage_id is None and genuinely_absent.record_id is None
      and genuinely_absent.decision_id is None,
      "genuinely absent trust cites no lineage, record, or decision")

# --- Coherent responses keep the behaviour established at 9659acd -----------
for standing, description in ((TrustState.TRUSTED.value, "trusted"),
                              (TrustState.RESTRICTED.value, "restricted")):
    result, _ = under_forged_query(released_shape(
        effective_state=standing, stored_state=standing, usable=True))
    check(result.status == VERIFIED,
          f"a coherent {description} response still verifies")
    check(result.reasons == (),
          f"a coherent {description} response carries no refusal reason")
    check(result.evaluated_at == STAMP.isoformat(),
          f"a coherent {description} response reports the instant it was asked about")

for standing, reason, description in (
        (TrustState.EXPIRED.value, REASON_EXPIRED, "expired"),
        (TrustState.REVOKED.value, REASON_REVOKED, "revoked"),
        (TrustState.QUARANTINED.value, REASON_NOT_USABLE, "quarantined"),
        (TrustState.PENDING.value, REASON_NOT_USABLE, "pending"),
        (TrustState.REJECTED.value, REASON_NOT_USABLE, "rejected")):
    result, _ = under_forged_query(released_shape(
        stored_state=(TrustState.TRUSTED.value
                      if standing == TrustState.EXPIRED.value else standing),
        effective_state=standing, usable=False))
    check(result.status == UNVERIFIED,
          f"a coherent {description} response does not verify")
    check(result.reasons == (reason,),
          f"a coherent {description} response keeps its own refusal reason")
    check(result.standing == standing,
          f"a coherent {description} response preserves the reported standing")

# --- The new refusals leak nothing and change nothing ------------------------
NEW_REFUSALS = [payload for payload, _ in MISSING_INSTANT]
NEW_REFUSALS += [unknown_citing(*fields) for fields, _ in CITED_COMBINATIONS]
for payload in NEW_REFUSALS:
    result, _ = under_forged_query(payload)
    leaked = " ".join(result.reasons) + " " + str(result.to_dict())
    for token, leak in ((" 0x", "an object address"), ("/tmp/", "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr")):
        check(token not in leaked, f"a newly refused response leaks no {leak}")

with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    trust_root = Path(tmp) / "trust"
    fabric_root = Path(tmp) / "fabric"
    trust_before = forensic(trust_root)
    fabric_before = forensic(fabric_root)
    for payload in NEW_REFUSALS:
        under_forged_query(payload)
    check(forensic(trust_root) == trust_before,
          "refusing an incoherent evaluation changes nothing in the trust store")
    check(forensic(fabric_root) == fabric_before,
          "refusing an incoherent evaluation changes nothing in the fabric store")

# The real store still answers as it did: this narrows nothing that was right.
with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    check(verify_subject(store, "HOST-GOOD", evaluated_at=STAMP).status == VERIFIED,
          "a real trusted subject still verifies after the coherence guard")
    check(verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP).reasons
          == (REASON_NO_STANDING,),
          "a real absent subject still reports no trust standing")
    check(verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER).reasons
          == (REASON_EXPIRED,),
          "a real expired subject still reports expired trust")
    check(verify_subject(store, "HOST-REVOKED", evaluated_at=AFTER).reasons
          == (REASON_REVOKED,),
          "a real revoked subject still reports revoked trust")


# --- Stored and effective standing must be a pair expiry can produce --------
# Defect caught: accepting any two recognised standings side by side. The
# released expiry contract only ever leaves a standing unchanged or ages a
# usable one out, so 'stored revoked, effectively trusted' is not a weaker
# answer -- it is a combination nothing can produce, and it verified.
ALL_STANDINGS = tuple(state.value for state in TrustState)
EXPIRABLE_STANDINGS = (TrustState.TRUSTED.value, TrustState.RESTRICTED.value)
USABLE_SET = (TrustState.TRUSTED.value, TrustState.RESTRICTED.value)
check(len(ALL_STANDINGS) >= 6,
      "the released standing vocabulary is enumerated for the pair matrix")

for stored in ALL_STANDINGS:
    for effective in ALL_STANDINGS:
        producible = (effective == stored
                      or (stored in EXPIRABLE_STANDINGS
                          and effective == TrustState.EXPIRED.value))
        cites = effective != TrustState.UNKNOWN.value
        payload = released_shape(
            stored_state=stored, effective_state=effective,
            usable=effective in USABLE_SET,
            lineage_id="TLIN-000001" if cites else None,
            record_id="TREC-000001" if cites else None,
            decision_id="TDEC-000001" if cites else None)
        result, query = under_forged_query(payload)
        pair = f"stored '{stored}' reported effectively '{effective}'"
        if producible:
            check(result.reasons != (REASON_UNREADABLE,),
                  f"{pair} is a pair the expiry contract produces")
        else:
            check(result.status == UNVERIFIED and result.reasons == (REASON_UNREADABLE,),
                  f"{pair} is impossible and fails closed")
        check(query.calls == 1, f"{pair} is asked for once")

# The two expiry pairs specifically, and a usable standing never invented.
for stored in EXPIRABLE_STANDINGS:
    result, _ = under_forged_query(released_shape(
        stored_state=stored, effective_state=TrustState.EXPIRED.value, usable=False))
    check(result.reasons == (REASON_EXPIRED,),
          f"a stored '{stored}' grant reported expired keeps its expiry reason")

for stored in ALL_STANDINGS:
    for usable_standing in USABLE_SET:
        if stored == usable_standing:
            continue
        result, _ = under_forged_query(released_shape(
            stored_state=stored, effective_state=usable_standing, usable=True))
        check(result.status == UNVERIFIED,
              f"a usable '{usable_standing}' standing is never derived from stored '{stored}'")

# Matching standings keep exactly the behaviour established earlier.
for standing, expected in ((TrustState.TRUSTED.value, VERIFIED),
                           (TrustState.RESTRICTED.value, VERIFIED),
                           (TrustState.EXPIRED.value, UNVERIFIED),
                           (TrustState.REVOKED.value, UNVERIFIED),
                           (TrustState.QUARANTINED.value, UNVERIFIED)):
    result, _ = under_forged_query(released_shape(
        stored_state=standing, effective_state=standing,
        usable=standing in USABLE_SET))
    check(result.status == expected,
          f"a response whose stored and effective standing are both "
          f"'{standing}' is {expected}")

# --- Authoritative identities must be released identifiers ------------------
# Defect caught: treating any non-empty string as a resolved identity. A
# response citing 'arbitrary text' as its lineage cites nothing verifiable,
# and it verified.
MALFORMED_IDENTITIES = (
    ("lineage_id", "TLIN-000001-v0001", "a lineage record identity, not a lineage"),
    ("lineage_id", "tlin-000001", "a lowercase lineage identifier"),
    ("lineage_id", "TLIN-0001", "a lineage of the wrong width"),
    ("lineage_id", "TLIN-0000001", "a lineage identifier too wide"),
    ("lineage_id", " TLIN-000001", "a lineage with leading whitespace"),
    ("lineage_id", "TLIN-000001 ", "a lineage with trailing whitespace"),
    ("lineage_id", "trust:TLIN-000001", "a namespaced lineage identifier"),
    ("lineage_id", "arbitrary text", "a lineage that is arbitrary text"),
    ("lineage_id", "TREC-000001", "a record identifier in the lineage field"),
    ("record_id", "TDEC-000001", "a decision identifier in the record field"),
    ("record_id", "TREC-00001", "a record identifier of the wrong width"),
    ("record_id", "TREC-0000001", "a record identifier too wide"),
    ("record_id", "trec-000001", "a lowercase record identifier"),
    ("record_id", "TREC-00000A", "a record identifier carrying a letter"),
    ("record_id", "trust://TREC-000001", "a record identifier behind a scheme"),
    ("decision_id", "TREC-000001", "a record identifier in the decision field"),
    ("decision_id", "TDEC-00001", "a decision identifier of the wrong width"),
    ("decision_id", "TDEC-000001\n", "a decision identifier with a trailing newline"),
)
for field, value, description in MALFORMED_IDENTITIES:
    result, query = under_forged_query(released_shape(**{field: value}))
    check(result.status == UNVERIFIED,
          f"a response citing {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"a response citing {description} is reported as unreadable")
    check(query.calls == 1, f"a response citing {description} is asked for once")
    repeated, _ = under_forged_query(released_shape(**{field: value}))
    check(repeated == result,
          f"a response citing {description} refuses identically on repetition")

MALFORMED_EVIDENCE = (
    (["TAUTH-000001"], "an authority identifier as evidence"),
    (["TEVID-00001"], "an evidence identifier of the wrong width"),
    (["tevid-000001"], "a lowercase evidence identifier"),
    ([" TEVID-000001"], "an evidence identifier with leading whitespace"),
    (["TEVID-000001 "], "an evidence identifier with trailing whitespace"),
    (["TEVID-000001", "not-an-identifier"], "one valid and one arbitrary evidence entry"),
    (["TEVID-000001", 12345], "a non-textual evidence entry"),
)
for references, description in MALFORMED_EVIDENCE:
    result, _ = under_forged_query(released_shape(evidence_reference_ids=references))
    check(result.status == UNVERIFIED,
          f"a response citing {description} does not verify")
    check(result.reasons == (REASON_UNREADABLE,),
          f"a response citing {description} is reported as unreadable")

# The exact released forms are still accepted, unchanged.
exact, _ = under_forged_query(released_shape(
    lineage_id="TLIN-000001", record_id="TREC-000001",
    decision_id="TDEC-000001",
    evidence_reference_ids=["TEVID-000001", "TEVID-000002"]))
check(exact.status == VERIFIED,
      "a response citing exact released identifier forms still verifies")
check(exact.lineage_id == "TLIN-000001" and exact.record_id == "TREC-000001"
      and exact.decision_id == "TDEC-000001",
      "accepted identities are preserved exactly, never normalised")
check(tuple(exact.evidence_reference_ids) == ("TEVID-000001", "TEVID-000002"),
      "accepted evidence references are preserved in order and unchanged")

# --- A trust record identity is a released record identifier ----------------
BAD_RETURNED = (
    ({"subject_id": "HOST-A", "record_id": "TREC-00001"},
     "a returned record identifier of the wrong width"),
    ({"subject_id": "HOST-A", "record_id": "trec-000001"},
     "a lowercase returned record identifier"),
    ({"subject_id": "HOST-A", "record_id": "TDEC-000001"},
     "a decision identifier returned as a record"),
    ({"subject_id": "HOST-A", "record_id": " TREC-000001"},
     "a returned record identifier with leading whitespace"),
)
for record, description in BAD_RETURNED:
    result, lookup = under_forged_record(record)
    check(result.status == UNVERIFIED and result.reasons == (REASON_UNREADABLE,),
          f"{description} is reported as unreadable")
    check(lookup.calls == 1, f"{description} is fetched once")

for requested, description in (("not-a-record", "arbitrary text"),
                               ("TREC-00001", "the wrong width"),
                               ("trec-000001", "lowercase"),
                               ("TDEC-000001", "a decision identifier"),
                               (" TREC-000001", "leading whitespace")):
    try:
        verify_trust_record(object(), requested, evaluated_at=STAMP)
        bad(f"a trust record requested as {description} fails closed (was accepted)")
    except FabricError:
        ok(f"a trust record requested as {description} fails closed")
    except Exception as error:  # noqa: BLE001
        bad(f"a trust record requested as {description} fails closed "
            f"(raised {type(error).__name__})")

# --- The new refusals leak nothing and change nothing -----------------------
COHERENCE_REFUSALS = [released_shape(**{field: value})
                      for field, value, _ in MALFORMED_IDENTITIES]
COHERENCE_REFUSALS += [released_shape(evidence_reference_ids=references)
                       for references, _ in MALFORMED_EVIDENCE]
COHERENCE_REFUSALS.append(released_shape(
    stored_state=TrustState.REVOKED.value,
    effective_state=TrustState.TRUSTED.value, usable=True))
for payload in COHERENCE_REFUSALS:
    result, _ = under_forged_query(payload)
    leaked = " ".join(result.reasons) + " " + str(result.to_dict())
    for token, leak in ((" 0x", "an object address"), ("/tmp/", "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr")):
        check(token not in leaked, f"a coherence refusal leaks no {leak}")

with TemporaryDirectory() as tmp:
    store, _, _ = seeded(tmp)
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    trust_root = Path(tmp) / "trust"
    fabric_root = Path(tmp) / "fabric"
    trust_before = forensic(trust_root)
    fabric_before = forensic(fabric_root)
    for payload in COHERENCE_REFUSALS:
        under_forged_query(payload)
    for record, _ in BAD_RETURNED:
        under_forged_record(record)
    check(forensic(trust_root) == trust_before,
          "refusing an incoherent standing or identity changes nothing in the trust store")
    check(forensic(fabric_root) == fabric_before,
          "refusing an incoherent standing or identity changes nothing in the fabric store")

# The real store, which produces real identifiers, is unaffected.
with TemporaryDirectory() as tmp:
    store, granted, _ = seeded(tmp)
    live = verify_subject(store, "HOST-GOOD", evaluated_at=STAMP)
    check(live.status == VERIFIED,
          "a real trusted subject still verifies against the released identifier syntax")
    check(RECORD_ID.match(live.record_id or "") is not None,
          "a real verification cites a released record identifier")
    check(DECISION_ID.match(live.decision_id or "") is not None,
          "a real verification cites a released decision identifier")
    check(LINEAGE_ID.match(live.lineage_id or "") is not None,
          "a real verification cites a released lineage identifier")
    by_record = verify_trust_record(store, granted.record.record_id, evaluated_at=STAMP)
    check(by_record.status == VERIFIED,
          "a real trust record identity still resolves to its verified subject")
    check(verify_subject(store, "HOST-LAPSED", evaluated_at=AFTER).reasons
          == (REASON_EXPIRED,),
          "a real expired subject still reports expired trust")
    check(verify_subject(store, "HOST-REVOKED", evaluated_at=AFTER).reasons
          == (REASON_REVOKED,),
          "a real revoked subject still reports revoked trust")
    check(verify_subject(store, "HOST-NEVER-SEEN", evaluated_at=STAMP).reasons
          == (REASON_NO_STANDING,),
          "a real absent subject still reports no trust standing")


# --- The authoritative subject type rides the record, not the evaluation ----
# Defect caught: C4 will need to prove a referenced trust record belongs to the
# fabric-node domain and is still the subject's current record. The released
# evaluation carries neither fact, so without this an admission would have to
# read trust records directly -- exactly what C3 exists to prevent.
check(REASON_SUBJECT_TYPE_MISMATCH in UNVERIFIED_REASONS,
      "the subject-type mismatch is a named refusal in the controlled vocabulary")
check(REASON_SUBJECT_TYPE_MISMATCH == "trust-subject-type-mismatch",
      "the subject-type refusal is named trust-subject-type-mismatch")
check("subject_type" in TrustVerification.__dataclass_fields__,
      "a verification result carries a subject type")

FABRIC_NODE = "fabric-node"


def trust_record(**overrides):
    """A retrieved trust record with the shape the released store returns."""
    record = {"record_id": "TREC-000001", "subject_id": "HOST-A",
              "subject_type": FABRIC_NODE, "state": TrustState.TRUSTED.value}
    record.update(overrides)
    return record


def under_forged_pair(record, payload, requested="TREC-000001", **keywords):
    """Forge both released interfaces: the record lookup and the evaluation."""
    lookup = ForgedRecord(record)
    query = ForgedQuery(payload)
    adapter_module.get_trust_record = lookup
    adapter_module.get_current_trust = query
    try:
        return verify_trust_record(object(), requested, evaluated_at=STAMP,
                                   **keywords), lookup, query
    finally:
        adapter_module.get_trust_record = RELEASED_RECORD
        adapter_module.get_current_trust = RELEASED_QUERY


# A direct subject verification never learns a domain, and must not guess one.
direct, _ = under_forged_query(released_shape())
check(direct.subject_type is None,
      "a direct subject verification reports no subject type")
check("subject_type" in direct.to_dict(),
      "the subject type appears in the serialised result")
check(direct.to_dict()["subject_type"] is None,
      "the serialised subject type of a direct verification is nothing")
scoped, _ = under_forged_query(released_shape(
    scope={"scope_id": "TSCOPE-000001", "subject_type": FABRIC_NODE}))
check(scoped.subject_type is None,
      "a subject type present in the evaluation scope is never adopted as the domain")

# Through the record, the authoritative subject type is carried exactly.
result, lookup, query = under_forged_pair(trust_record(), released_shape())
check(result.status == VERIFIED,
      "a current fabric-node record verifies its subject")
check(result.subject_type == FABRIC_NODE,
      "the verification carries the record's authoritative subject type")
check(result.to_dict()["subject_type"] == FABRIC_NODE,
      "the authoritative subject type is serialised deterministically")
check(lookup.calls == 1 and query.calls == 1,
      "a record verification fetches the record once and evaluates once")
repeated, _, _ = under_forged_pair(trust_record(), released_shape())
check(repeated == result, "a record verification repeats identically")

for domain, description in ((None, "no subject type"),
                            ("", "an empty subject type"),
                            ("   ", "a blank subject type"),
                            (" fabric-node", "a subject type with leading whitespace"),
                            ("fabric-node ", "a subject type with trailing whitespace"),
                            ("fabric-node\n", "a subject type with a trailing newline"),
                            (12345, "a numeric subject type"),
                            (["fabric-node"], "a subject type inside a list")):
    record = trust_record(subject_type=domain)
    if domain is None:
        del record["subject_type"]
        description = "no subject type at all"
    outcome, forged_lookup, _ = under_forged_pair(record, released_shape())
    check(outcome.status == UNVERIFIED,
          f"a record carrying {description} does not verify")
    check(outcome.reasons == (REASON_UNREADABLE,),
          f"a record carrying {description} is reported as unreadable")
    check(forged_lookup.calls == 1,
          f"a record carrying {description} is fetched once")

# --- The optional exact domain requirement ----------------------------------
required, _, _ = under_forged_pair(trust_record(), released_shape(),
                                   expected_subject_type=FABRIC_NODE)
check(required.status == VERIFIED,
      "an exact fabric-node record verifies when fabric-node is required")
check(required.subject_type == FABRIC_NODE,
      "a domain-checked verification still carries the authoritative subject type")

OTHER_DOMAINS = ("fabric-package", "host", "plugin", "Fabric-Node", "FABRIC-NODE",
                 "fabric_node", "fabric-nodes", "fabric-nod")
for domain in OTHER_DOMAINS:
    outcome, _, _ = under_forged_pair(trust_record(subject_type=domain),
                                      released_shape(),
                                      expected_subject_type=FABRIC_NODE)
    check(outcome.status == UNVERIFIED,
          f"a '{domain}' record does not verify when fabric-node is required")
    check(outcome.reasons == (REASON_SUBJECT_TYPE_MISMATCH,),
          f"a '{domain}' record is refused as a subject-type mismatch")
    check(outcome.subject_type == domain,
          f"a refused '{domain}' record still reports the domain it actually carried")

# The comparison transforms nothing on either side.
for supplied in (" fabric-node", "fabric-node ", "", "   ", "\n", 12345,
                 ["fabric-node"], FABRIC_NODE.upper() + " "):
    try:
        under_forged_pair(trust_record(), released_shape(),
                          expected_subject_type=supplied)
        bad(f"a required subject type supplied as {supplied!r} fails closed "
            "(was accepted)")
    except FabricError:
        ok(f"a required subject type supplied as {supplied!r} fails closed")
    except Exception as error:  # noqa: BLE001
        bad(f"a required subject type supplied as {supplied!r} fails closed "
            f"(raised {type(error).__name__})")

# Omitting the requirement remains valid: the parameter is optional.
without, _, _ = under_forged_pair(trust_record(subject_type="fabric-package"),
                                  released_shape())
check(without.status == VERIFIED,
      "a record of any domain still verifies when no domain is required")
check(without.subject_type == "fabric-package",
      "the authoritative subject type is reported when no domain is required")

# --- The referenced record must still be the subject's current record -------
# Defect caught: a subject that has since been re-decided verifies through its
# new current record, which would let an obsolete reference be admitted.
superseded, _, _ = under_forged_pair(
    trust_record(), released_shape(record_id="TREC-000002"))
check(superseded.status == UNVERIFIED,
      "a referenced record that is no longer current does not verify")
check(superseded.reasons == (REASON_UNREADABLE,),
      "an obsolete referenced record is reported as unreadable")

current, _, _ = under_forged_pair(trust_record(), released_shape(
    record_id="TREC-000001"))
check(current.status == VERIFIED,
      "a referenced record that is still current verifies")

# A matching current record preserves every established standing outcome.
STANDING_OUTCOMES = (
    (TrustState.TRUSTED.value, TrustState.TRUSTED.value, True, VERIFIED, None),
    (TrustState.RESTRICTED.value, TrustState.RESTRICTED.value, True, VERIFIED, None),
    (TrustState.TRUSTED.value, TrustState.EXPIRED.value, False, UNVERIFIED,
     REASON_EXPIRED),
    (TrustState.REVOKED.value, TrustState.REVOKED.value, False, UNVERIFIED,
     REASON_REVOKED),
    (TrustState.QUARANTINED.value, TrustState.QUARANTINED.value, False, UNVERIFIED,
     REASON_NOT_USABLE),
    (TrustState.REJECTED.value, TrustState.REJECTED.value, False, UNVERIFIED,
     REASON_NOT_USABLE),
    (TrustState.PENDING.value, TrustState.PENDING.value, False, UNVERIFIED,
     REASON_NOT_USABLE),
)
for stored, effective, usable, status, reason in STANDING_OUTCOMES:
    outcome, _, _ = under_forged_pair(trust_record(), released_shape(
        stored_state=stored, effective_state=effective, usable=usable))
    check(outcome.status == status,
          f"a current record whose subject is effectively '{effective}' is {status}")
    if reason is not None:
        check(outcome.reasons == (reason,),
              f"a current record whose subject is effectively '{effective}' "
              f"keeps the reason {reason}")
    check(outcome.subject_type == FABRIC_NODE,
          f"a current record whose subject is effectively '{effective}' still "
          "carries its authoritative subject type")

# An unknown standing cites no record, and that is absence, not obsolescence.
unknown_outcome, _, _ = under_forged_pair(trust_record(), released_shape(
    stored_state=TrustState.UNKNOWN.value,
    effective_state=TrustState.UNKNOWN.value, usable=False,
    lineage_id=None, record_id=None, decision_id=None))
check(unknown_outcome.reasons == (REASON_NO_STANDING,),
      "a subject with no standing keeps its absent reason, not an obsolescence one")

# --- Unavailable and unreadable outcomes are not reclassified ---------------
# Defect caught: an unavailable trust plane cites no current record, and
# treating that as an obsolete reference would hide why the answer was missing.
unavailable_outcome, _, _ = under_forged_pair(
    trust_record(), OSError("the trust plane is unavailable"))
check(unavailable_outcome.reasons == (REASON_UNAVAILABLE,),
      "an unavailable evaluation keeps its unavailable reason through the record path")
unreadable_outcome, _, _ = under_forged_pair(
    trust_record(), released_shape(subject_id="SOMEONE-ELSE"))
check(unreadable_outcome.reasons == (REASON_UNREADABLE,),
      "an unreadable evaluation keeps its unreadable reason through the record path")

# --- The new refusals leak nothing and change nothing -----------------------
SUBJECT_TYPE_REFUSALS = (
    (trust_record(subject_type="fabric-package"), released_shape(),
     {"expected_subject_type": FABRIC_NODE}),
    (trust_record(subject_type=""), released_shape(), {}),
    (trust_record(), released_shape(record_id="TREC-000002"), {}),
    (trust_record(), OSError("unavailable"), {}),
)
for record, payload, keywords in SUBJECT_TYPE_REFUSALS:
    outcome, _, _ = under_forged_pair(record, payload, **keywords)
    leaked = " ".join(outcome.reasons) + " " + str(outcome.to_dict())
    for token, leak in ((" 0x", "an object address"), ("/tmp/", "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr")):
        check(token not in leaked, f"a subject-type refusal leaks no {leak}")

with TemporaryDirectory() as tmp:
    store, granted, _ = seeded(tmp)
    fabric = FabricStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    trust_root = Path(tmp) / "trust"
    fabric_root = Path(tmp) / "fabric"
    trust_before = forensic(trust_root)
    fabric_before = forensic(fabric_root)
    for record, payload, keywords in SUBJECT_TYPE_REFUSALS:
        under_forged_pair(record, payload, **keywords)
    check(forensic(trust_root) == trust_before,
          "refusing a subject type changes nothing in the trust store")
    check(forensic(fabric_root) == fabric_before,
          "refusing a subject type changes nothing in the fabric store")

    # The real store, end to end, through the accepted adapter only.
    real = verify_trust_record(store, granted.record.record_id, evaluated_at=STAMP)
    check(real.status == VERIFIED,
          "a real current trust record still verifies through the adapter")
    check(real.subject_type == "host",
          "a real verification carries the subject type its record declares")
    check(verify_trust_record(store, granted.record.record_id, evaluated_at=STAMP,
                              expected_subject_type="host").status == VERIFIED,
          "a real record verifies when its own domain is required")
    mismatched = verify_trust_record(store, granted.record.record_id,
                                     evaluated_at=STAMP,
                                     expected_subject_type=FABRIC_NODE)
    check(mismatched.reasons == (REASON_SUBJECT_TYPE_MISMATCH,),
          "a real record of another domain is refused when fabric-node is required")
    check(verify_subject(store, "HOST-GOOD", evaluated_at=STAMP).subject_type is None,
          "a real direct subject verification still reports no subject type")

print(f"__FAILURES__={failures}")
TRUSTPY
)"
printf '%s\n' "${TRUSTPY_OUTPUT}" | grep -v '^__FAILURES__=' || true
TRUSTPY_FAILURES="$(printf '%s\n' "${TRUSTPY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${TRUSTPY_FAILURES}" ]]; then
  fail "fabric trust verification did not report a result"
else
  FAILURES=$((FAILURES + TRUSTPY_FAILURES))
fi

# --- C3 containment: released interfaces only, no writer, no network --------
assert_absent_in "${FABRIC}/trust_adapter.py" \
  '(open\(|write_text|write_bytes|mkdir|makedirs|chmod|chown|unlink|rename|replace\(|os\.remove|shutil\.)' \
  "the trust adapter contains no filesystem-writing operation"
assert_absent_in "${FABRIC}/trust_adapter.py" \
  '(socket|requests|urllib|http\.client|paramiko|subprocess|os\.environ|getenv|Thread|Process|asyncio)' \
  "the trust adapter opens no network, environment, or background worker path"
assert_absent_in "${FABRIC}/trust_adapter.py" \
  '(create_decision|declare_root_authority|TrustStore\(|lru_cache|_cache|retry|sleep)' \
  "the trust adapter calls no trust mutation interface and caches or retries nothing"
assert_absent_in "${FABRIC}/trust_adapter.py" \
  '(/var/lib/kyri|platform-model/trust-store|trust-store)' \
  "the trust adapter opens no production trust plane path"
assert_contains "${FABRIC}/trust_adapter.py" 'get_current_trust' \
  "the trust adapter resolves standing through the released query interface"
assert_absent_in "${FABRIC}" \
  '(subject_is_trusted|is_trusted|trust_state|trusted=|untrusted)' \
  "no fabric record asserts that a subject is trusted or untrusted"

# --- Governed declaration, subject admission, advertisement, C4 part 1 -------
ADMIT_OUTPUT="$(python3 - "${ROOT}" <<'ADMITPY' 2>&1 || true
import dataclasses
import hashlib
import inspect
import os
import stat
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone, tzinfo
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml as _yaml

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


from tools.fabric.errors import FabricError  # noqa: E402
from tools.fabric.store import FabricStore  # noqa: E402
from tools.trust.store import TrustStore  # noqa: E402
from tools.trust.models import (  # noqa: E402
    TrustEvidenceReference, TrustScope, TrustState, TrustVerificationDetails,
    VerificationMethod,
)
from tools.trust.root_authority import (  # noqa: E402
    declare_root_authority, load_root_declaration,
)
from tools.trust.evaluator import create_decision  # noqa: E402
import tools.fabric.trust_adapter as trust_adapter  # noqa: E402
# The import that must fail before increment 6 exists.
from tools.fabric.admission import (  # noqa: E402
    ACCEPTED, CONFLICT, EXACT_REPLAY, INVALID, NOT_FOUND, REFUSED, UNAVAILABLE,
    OperationResult,
    admit_subject,
    declare_capability,
    declare_contract,
    declare_package,
    register_advertisement,
)
import tools.fabric.admission as admission_module  # noqa: E402

UID = os.geteuid()
GID = os.getegid()
STAMP = datetime(2026, 8, 2, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
LATER = STAMP + timedelta(days=1)
YEAR = STAMP + timedelta(days=365)
OPERATOR = "operator:cschott"
PROV = {"class": "declared", "source": "operator"}

# A shape references the authority that enforces it; it never restates one.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}


def forensic(base):
    entries = {}
    if not base.exists():
        return entries
    for path in sorted(base.rglob("*")):
        info = path.lstat()
        digest = (hashlib.sha256(path.read_bytes()).hexdigest()
                  if stat.S_ISREG(info.st_mode) else "")
        entries[str(path.relative_to(base))] = (
            stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode), info.st_uid,
            info.st_gid, info.st_ino, info.st_mtime_ns, info.st_size, digest)
    return entries


class WatchedStore(FabricStore):
    """The real store, counting critical-section entries and allocations."""

    def __init__(self, *args, **kwargs):
        self.entries = 0
        self.depth = 0
        self.deepest = 0
        self.allocations = []
        super().__init__(*args, **kwargs)

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

    def allocate_id(self, kind):
        identifier = super().allocate_id(kind)
        self.allocations.append(identifier)
        return identifier


def opened(tmp):
    return WatchedStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)


def seeded_trust(tmp, subject="node/schai", state=TrustState.TRUSTED.value,
                 expiration=None, subject_type="fabric-node"):
    """A real trust store with one decided subject."""
    store = TrustStore(Path(tmp) / "trust")
    approved = Path(tmp) / "approved"
    approved.mkdir()
    approved.joinpath("root.yaml").write_text(_yaml.safe_dump({
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat()},
        "evidence_references": [{
            "evidence_id": "TEVID-000001", "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": STAMP.isoformat()}],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))
    granted = create_decision(
        store, subject_id=subject, subject_type=subject_type,
        requested_state=state, actor_authority_id=authority.authority_id,
        decided_at=STAMP, reason="granted for the fabric admission regression",
        evidence_references=(TrustEvidenceReference(
            evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
            reference="/approved/evidence/fingerprint.txt", recorded_at=STAMP),),
        verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        verification_details=TrustVerificationDetails(
            subject_property="ssh-host-key-fingerprint",
            observed_value_reference="/approved/evidence/observed.txt",
            comparison_source="printed-console-readout",
            performed_by="operator-role-reference", performed_at=STAMP),
        scope=TrustScope(
            scope_id="TSCOPE-000001", subject_type=subject_type,
            permitted_capabilities=("coding-workload",),
            permitted_operations=("linux.hostname",),
            permitted_data_classifications=("internal",),
            permitted_targets=("schmgmt.home.arpa",),
            validity_start=STAMP, validity_end=YEAR),
        expiration=expiration)
    return store, granted


PROFILE = {"host_memory_mb": 8192, "host_cpu_cores": 8, "architecture": "x86-64"}


def capability(store, request_id="req-cap-1", **overrides):
    fields = dict(request_id=request_id, actor=OPERATOR,
                  approving_authority=OPERATOR, recorded_at=STAMP,
                  name="summarise text",
                  description="Reduce a document to its essentials.",
                  effect_class="read-only", contract_ids=(), provenance=PROV)
    fields.update(overrides)
    return declare_capability(store, **fields)


def contract(store, capability_id, request_id="req-con-1", **overrides):
    fields = dict(request_id=request_id, actor=OPERATOR,
                  approving_authority=OPERATOR, recorded_at=STAMP,
                  capability_id=capability_id, contract_version="1.0.0",
                  effect_class="read-only", determinism_class="deterministic",
                  request_shape=REQUEST_SHAPE,
                  response_shape=RESPONSE_SHAPE,
                  failure_modes=("adapter-error",),
                  resource_requirements={"host_memory_mb": 512},
                  compatible_with=(), provenance=PROV)
    fields.update(overrides)
    return declare_contract(store, **fields)


def package(store, capability_id, contract_id, request_id="req-pkg-1", **overrides):
    fields = dict(request_id=request_id, actor=OPERATOR,
                  approving_authority=OPERATOR, recorded_at=STAMP,
                  capability_id=capability_id, contract_id=contract_id,
                  satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
                  artifact_reference="oci://registry.invalid/summarise",
                  resource_requirements={"host_memory_mb": 512},
                  trust_domain="capability-package", provenance=PROV)
    fields.update(overrides)
    return declare_package(store, **fields)


def subject(store, trust_store, request_id="req-host-1", **overrides):
    fields = dict(request_id=request_id, actor=OPERATOR,
                  approving_authority=OPERATOR, recorded_at=STAMP,
                  evaluated_at=STAMP, node_identity_reference="node/schai",
                  fabric_node_trust_record_id=None,
                  verified_resource_profile=dict(PROFILE),
                  verification_reference="/approved/evidence/host-observed.txt",
                  location_class="on-premises",
                  data_classification="internal",
                  availability_intent="in-service", provenance=PROV)
    fields.update(overrides)
    return admit_subject(store, trust_store, **fields)


def advertisement(store, host_id, package_id, contract_id,
                  request_id="req-adv-1", **overrides):
    fields = dict(request_id=request_id, actor=host_id, recorded_at=STAMP,
                  capability_host_id=host_id, capability_package_id=package_id,
                  contract_id=contract_id, satisfied_contract_versions=("1.0.0",),
                  advertised_resource_profile={"host_memory_mb": 8192},
                  observed_at=STAMP, valid_until=LATER, provenance=PROV)
    fields.update(overrides)
    return register_advertisement(store, **fields)


def advertise(store, host_id, package_id, contract_id, **overrides):
    """The same call, with every field overridable by name."""
    return advertisement(store, host_id, package_id, contract_id, **overrides)


def declared(store, trust_store=None, record_id=None):
    """Capability, contract, package, and optionally an admitted subject."""
    cap = capability(store)
    con = contract(store, cap.record_id)
    pkg = package(store, cap.record_id, con.record_id)
    if trust_store is None:
        return cap, con, pkg, None
    host = subject(store, trust_store,
                   fabric_node_trust_record_id=record_id)
    return cap, con, pkg, host


# --- 1-2. Each class writes exactly its own record, allocated by C1 ---------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    trust_store, granted = seeded_trust(tmp)
    cap, con, pkg, host = declared(store, trust_store, granted.record.record_id)
    adv = advertisement(store, host.record_id, pkg.record_id, con.record_id)
    EXPECTED = ((cap, "capability-definition", "CAPDEF-0001"),
                (con, "capability-contract", "CCON-0001"),
                (pkg, "capability-package", "CPKG-0001"),
                (host, "capability-host", "CHOST-0001"),
                (adv, "capability-advertisement", "CADV-000001"))
    for result, kind, identifier in EXPECTED:
        check(result.outcome == ACCEPTED, f"a governed {kind} is accepted")
        check(result.record_kind == kind and result.record_id == identifier,
              f"a governed {kind} is allocated as {identifier} by the store")
        check(identifier in store.allocations,
              f"{identifier} was allocated through C1, not chosen by the caller")
    counts = store.counts()
    check(counts["capability-definition"] == 1 and counts["capability-contract"] == 1
          and counts["capability-package"] == 1 and counts["capability-host"] == 1
          and counts["capability-advertisement"] == 1,
          "each accepted operation wrote exactly one record of its own class")
    check(counts["capability-instance"] == 0 and counts["capability-route"] == 0
          and counts["capability-selection"] == 0,
          "part-1 operations create no instance, route, or selection")
    check(store.entries == 5 and store.deepest == 1,
          f"each operation entered the critical section exactly once "
          f"({store.entries} entries, depth {store.deepest})")
    # 18. Every accepted record carries complete applicable evidence.
    for kind, identifier in (("capability-definition", "CAPDEF-0001"),
                             ("capability-contract", "CCON-0001"),
                             ("capability-package", "CPKG-0001"),
                             ("capability-host", "CHOST-0001"),
                             ("capability-advertisement", "CADV-000001")):
        stored = store.read_record(kind, identifier)
        carried = stored.get("evidence") or {}
        for field in ("actor", "causal_references", "trust_evidence_references",
                      "reason_category", "recorded_at", "request_id",
                      "request_digest"):
            check(field in carried, f"the accepted {kind} evidence carries '{field}'")
        if kind == "capability-advertisement":
            check(carried.get("approving_authority") is None,
                  "an accepted advertisement records no approving authority")
            check(carried.get("actor") == "CHOST-0001",
                  "an accepted advertisement records its subject as the actor")
        else:
            check(carried.get("approving_authority") == OPERATOR,
                  f"the accepted {kind} records its approving authority")
    check(store.read_record("capability-host", "CHOST-0001")[
              "fabric_node_trust_record_id"] == granted.record.record_id,
          "the admitted host references the verified trust record")
    check(granted.record.record_id in (store.read_record(
              "capability-host", "CHOST-0001")["evidence"]
              ["trust_evidence_references"]),
          "the admitted host's evidence references the verified trust record")

# --- 3. Identical content under different request identities stays distinct --
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    first = capability(store, request_id="req-A")
    second = capability(store, request_id="req-B")
    check(first.outcome == ACCEPTED and second.outcome == ACCEPTED,
          "byte-identical declarations under different request identities are both accepted")
    check(first.record_id != second.record_id,
          "byte-identical declarations under different request identities allocate distinct records")
    check(second.outcome != EXACT_REPLAY,
          "a second identity is never treated as replay of the first")
    check(store.counts()["capability-definition"] == 2,
          "neither declaration overwrote the other")

# --- 4-6. Replay and conflicting reuse, per operation class -----------------
def rerun(store, trust_store, kind, record_id=None):
    """The same operation twice: once replayed, once with different content."""
    if kind == "capability-definition":
        return (lambda **k: capability(store, **k),
                {"request_id": "req-replay"}, {"name": "a different capability"})
    if kind == "capability-contract":
        cap = capability(store, request_id="req-seed-cap")
        return (lambda **k: contract(store, cap.record_id, **k),
                {"request_id": "req-replay"}, {"contract_version": "2.0.0"})
    if kind == "capability-package":
        cap = capability(store, request_id="req-seed-cap")
        con = contract(store, cap.record_id, request_id="req-seed-con")
        return (lambda **k: package(store, cap.record_id, con.record_id, **k),
                {"request_id": "req-replay"}, {"package_version": "2.0.0"})
    if kind == "capability-host":
        return (lambda **k: subject(store, trust_store,
                                    fabric_node_trust_record_id=record_id, **k),
                {"request_id": "req-replay"}, {"location_class": "third-party-hosted"})
    cap = capability(store, request_id="req-seed-cap")
    con = contract(store, cap.record_id, request_id="req-seed-con")
    pkg = package(store, cap.record_id, con.record_id, request_id="req-seed-pkg")
    host = subject(store, trust_store, request_id="req-seed-host",
                   fabric_node_trust_record_id=record_id)
    return (lambda **k: advertisement(store, host.record_id, pkg.record_id,
                                      con.record_id, **k),
            {"request_id": "req-replay"},
            {"advertised_resource_profile": {"host_cpu_cores": 8}})


for kind in ("capability-definition", "capability-contract", "capability-package",
             "capability-host", "capability-advertisement"):
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        trust_store, granted = seeded_trust(tmp)
        operation, replayed, differing = rerun(store, trust_store, kind,
                                               granted.record.record_id)
        original = operation(**replayed)
        check(original.outcome == ACCEPTED, f"the first {kind} operation is accepted")
        before_allocations = len(store.allocations)
        fabric_root = Path(tmp) / "fabric"
        before = forensic(fabric_root)

        again = operation(**replayed)
        check(again.outcome == EXACT_REPLAY, f"an exact {kind} replay is recognised")
        check(again.record_id == original.record_id and
              again.record_kind == original.record_kind,
              f"an exact {kind} replay returns the original identity")
        check(len(store.allocations) == before_allocations,
              f"an exact {kind} replay allocates nothing")
        check(forensic(fabric_root) == before,
              f"an exact {kind} replay writes nothing")

        conflicting = operation(**dict(replayed, **differing))
        check(conflicting.outcome == CONFLICT,
              f"conflicting {kind} reuse is refused as a conflict")
        check(conflicting.reason == "request_identity_conflict",
              f"conflicting {kind} reuse is named request_identity_conflict")
        check(conflicting.record_id is None,
              f"conflicting {kind} reuse allocates no record")
        check(forensic(fabric_root) == before,
              f"conflicting {kind} reuse leaves the original byte-identical")

# --- 7-8. Authority ----------------------------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    trust_store, granted = seeded_trust(tmp)
    cap = capability(store, request_id="req-seed-cap")
    con = contract(store, cap.record_id, request_id="req-seed-con")
    fabric_root = Path(tmp) / "fabric"
    HUMAN = (
        ("capability declaration", lambda **k: capability(store, request_id="req-x", **k)),
        ("contract declaration",
         lambda **k: contract(store, cap.record_id, request_id="req-x", **k)),
        ("package declaration",
         lambda **k: package(store, cap.record_id, con.record_id,
                             request_id="req-x", **k)),
        ("subject admission",
         lambda **k: subject(store, trust_store, request_id="req-x",
                             fabric_node_trust_record_id=granted.record.record_id, **k)),
    )
    for label, operation in HUMAN:
        for missing, description in ((dict(approving_authority=None), "no approving authority"),
                                     (dict(approving_authority=""), "an empty approving authority"),
                                     (dict(actor=None), "no actor"),
                                     (dict(actor=""), "an empty actor")):
            before = forensic(fabric_root)
            result = operation(**missing)
            check(result.outcome in (REFUSED, INVALID),
                  f"a {label} with {description} is refused")
            check(result.record_id is None,
                  f"a {label} with {description} allocates nothing")
            check(forensic(fabric_root) == before,
                  f"a {label} with {description} writes nothing")

# --- 9-10. References and the declaration boundary ---------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    fabric_root = Path(tmp) / "fabric"
    cap = capability(store, request_id="req-seed-cap")
    con = contract(store, cap.record_id, request_id="req-seed-con")
    MISSING = (
        ("a capability declaring an absent contract",
         lambda: capability(store, request_id="req-m1", contract_ids=("CCON-9999",))),
        ("a contract naming an absent capability",
         lambda: contract(store, "CAPDEF-9999", request_id="req-m2")),
        ("a package naming an absent capability",
         lambda: package(store, "CAPDEF-9999", con.record_id, request_id="req-m3")),
        ("a package naming an absent contract",
         lambda: package(store, cap.record_id, "CCON-9999", request_id="req-m4")),
    )
    for description, operation in MISSING:
        before = forensic(fabric_root)
        result = operation()
        check(result.outcome == NOT_FOUND,
              f"{description} is refused as not-found")
        check(result.record_id is None, f"{description} allocates nothing")
        check(forensic(fabric_root) == before, f"{description} writes nothing")

    for effect, description in ((None, "an absent effect class"),
                                ("", "an empty effect class"),
                                ("Read-Only", "a differently cased effect class"),
                                (" read-only", "a padded effect class"),
                                ("unheard-of", "an unrecognised effect class")):
        before = forensic(fabric_root)
        result = contract(store, cap.record_id, request_id="req-e", effect_class=effect)
        check(result.outcome in (REFUSED, INVALID),
              f"a contract declaring {description} is refused")
        check(result.record_id is None,
              f"a contract declaring {description} creates zero records")
        check(forensic(fabric_root) == before,
              f"a contract declaring {description} writes nothing")
        result = capability(store, request_id="req-e2", effect_class=effect)
        check(result.record_id is None,
              f"a capability declaring {description} creates zero records")

    # The contract must belong to the referenced capability.
    other = capability(store, request_id="req-other")
    before = forensic(fabric_root)
    mismatched = package(store, other.record_id, con.record_id, request_id="req-mm")
    check(mismatched.outcome in (REFUSED, NOT_FOUND),
          "a package whose contract belongs to another capability is refused")
    check(forensic(fabric_root) == before,
          "a mismatched package writes nothing")
    for domain, description in (("fabric-node", "another trust domain"),
                                ("", "an empty trust domain"),
                                ("Capability-Package", "a differently cased trust domain")):
        result = package(store, cap.record_id, con.record_id, request_id="req-td",
                         trust_domain=domain)
        check(result.record_id is None,
              f"a package declaring {description} creates zero records")

# --- 11-14. Subject admission and C3 integration ----------------------------
TRUST_OUTCOMES = (
    ("no-trust-standing", "absent trust"),
    ("trust-expired", "expired trust"),
    ("trust-revoked", "revoked trust"),
    ("trust-not-usable", "quarantined trust"),
    ("trust-unreadable", "malformed trust"),
    ("trust-unavailable", "an unavailable trust plane"),
    ("trust-subject-type-mismatch", "a wrong trust subject type"),
)
RELEASED_VERIFY = trust_adapter.verify_trust_record


class CountingVerify:
    def __init__(self, verification):
        self.verification = verification
        self.calls = 0

    def __call__(self, store, record_id, *, evaluated_at, expected_subject_type=None):
        self.calls += 1
        return self.verification


for reason, description in TRUST_OUTCOMES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        trust_store, granted = seeded_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        refusal = trust_adapter.TrustVerification(
            subject_id="node/schai", status=trust_adapter.UNVERIFIED,
            standing=TrustState.UNKNOWN.value,
            stored_standing=TrustState.UNKNOWN.value,
            evaluated_at=STAMP.isoformat(), reasons=(reason,))
        counting = CountingVerify(refusal)
        admission_module.verify_trust_record = counting
        try:
            before = forensic(fabric_root)
            result = subject(store, trust_store, request_id="req-t",
                             fabric_node_trust_record_id=granted.record.record_id)
        finally:
            admission_module.verify_trust_record = RELEASED_VERIFY
        check(result.outcome in (REFUSED, UNAVAILABLE),
              f"subject admission with {description} is refused")
        check(result.reason == reason,
              f"subject admission with {description} preserves the C3 reason {reason}")
        check(result.record_id is None,
              f"subject admission with {description} creates no record")
        check(store.counts()["capability-host"] == 0,
              f"subject admission with {description} leaves zero host records")
        check(forensic(fabric_root) == before,
              f"subject admission with {description} changes nothing on disk")
        check(counting.calls == 1,
              f"subject admission with {description} consults C3 exactly once")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    trust_store, granted = seeded_trust(tmp)
    fabric_root = Path(tmp) / "fabric"
    # A subject mismatch: the trust record names a different node.
    before = forensic(fabric_root)
    mismatched = subject(store, trust_store, request_id="req-sm",
                         fabric_node_trust_record_id=granted.record.record_id,
                         node_identity_reference="node/somewhere-else")
    check(mismatched.outcome in (REFUSED, NOT_FOUND),
          "an admission whose trust record names another subject is refused")
    check(forensic(fabric_root) == before,
          "a subject mismatch writes nothing")
    # Self-admission: the subject cannot be its own approving authority.
    self_admitted = subject(store, trust_store, request_id="req-self",
                            fabric_node_trust_record_id=granted.record.record_id,
                            actor="node/schai", approving_authority="node/schai")
    check(self_admitted.record_id is None, "self-admission is refused")
    # Out-of-band verification must be provable.
    for reference, description in ((None, "no verification reference"),
                                   ("", "an empty verification reference")):
        result = subject(store, trust_store, request_id="req-oob",
                         fabric_node_trust_record_id=granted.record.record_id,
                         verification_reference=reference)
        check(result.record_id is None,
              f"an admission with {description} is refused")
    # Trust alone creates no instance.
    admitted = subject(store, trust_store, request_id="req-ok",
                       fabric_node_trust_record_id=granted.record.record_id)
    check(admitted.outcome == ACCEPTED, "a verified subject is admitted")
    check(store.counts()["capability-instance"] == 0,
          "trust alone creates no instance record")
    check(store.counts()["capability-advertisement"] == 0,
          "admission creates no advertisement")

# --- 15-17. Advertisement registration ---------------------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    trust_store, granted = seeded_trust(tmp)
    fabric_root = Path(tmp) / "fabric"
    cap, con, pkg, host = declared(store, trust_store, granted.record.record_id)

    unadmitted = advertisement(store, "CHOST-9999", pkg.record_id, con.record_id,
                               request_id="req-una")
    check(unadmitted.outcome == NOT_FOUND,
          "an advertisement from an unadmitted subject is refused")
    check(unadmitted.record_id is None,
          "an unadmitted advertisement is not queued, staged, or persisted")
    check(store.counts()["capability-advertisement"] == 0,
          "an unadmitted advertisement leaves no authoritative state")

    impersonating = advertisement(store, host.record_id, pkg.record_id,
                                  con.record_id, request_id="req-imp",
                                  actor="CHOST-9999")
    check(impersonating.record_id is None,
          "a subject advertising as another subject is refused")
    approved = advertisement(store, host.record_id, pkg.record_id, con.record_id,
                             request_id="req-app", approving_authority=OPERATOR)
    check(approved.record_id is None,
          "an advertisement supplying an approving authority is refused")

    ADVERTISEMENT_REFUSALS = (
        ({"capability_package_id": "CPKG-9999"}, "an absent package"),
        ({"contract_id": "CCON-9999"}, "an absent contract"),
        ({"satisfied_contract_versions": ("2.0.0",)}, "versions outside the declaration"),
        ({"satisfied_contract_versions": ()}, "no satisfied versions"),
        ({"advertised_resource_profile": {"host_memory_mb": 65536}},
         "a resource claim not contained by the verified profile"),
        ({"advertised_resource_profile": {"accelerator_memory_mb": 4096}},
         "a resource dimension the operator never verified"),
        ({"valid_until": STAMP}, "a window that ends when it starts"),
        ({"valid_until": STAMP - timedelta(hours=1)}, "a reversed validity window"),
        ({"observed_at": STAMP.replace(tzinfo=None)}, "a naive observation instant"),
        ({"valid_until": LATER.replace(tzinfo=None)}, "a naive validity boundary"),
        # The window must cover the moment the claim is being registered.
        # `recorded_at` is the governed request's own instant, so the verdict
        # is a property of the request rather than of when it was replayed.
        ({"observed_at": STAMP - timedelta(hours=2),
          "valid_until": STAMP - timedelta(hours=1)},
         "a window that closed before the request was recorded"),
        ({"observed_at": STAMP - timedelta(hours=1), "valid_until": STAMP},
         "a window that ends exactly when the request is recorded"),
        ({"observed_at": STAMP + timedelta(hours=1),
          "valid_until": STAMP + timedelta(hours=2)},
         "an observation instant after the request was recorded"),
    )
    # One request identity per case. Sharing a single one is safe only while
    # every case refuses: the moment one is accepted, the rest collide with it
    # and report a request-identity conflict instead of the defect under test.
    for index, (overrides, description) in enumerate(ADVERTISEMENT_REFUSALS):
        before = forensic(fabric_root)
        result = advertisement(store, host.record_id, pkg.record_id,
                               overrides.pop("contract_id", con.record_id),
                               request_id=f"req-adv-bad-{index}", **overrides)
        check(result.record_id is None,
              f"an advertisement carrying {description} is refused")
        check(forensic(fabric_root) == before,
              f"an advertisement carrying {description} writes nothing")

    # A contract that is not the package's contract.
    other_con = contract(store, cap.record_id, request_id="req-oc",
                         contract_version="9.9.9")
    inconsistent = advertisement(store, host.record_id, pkg.record_id,
                                 other_con.record_id, request_id="req-inc")
    check(inconsistent.record_id is None,
          "an advertisement whose contract is not the package's contract is refused")

    # A window that covers the recording instant is accepted, at both the
    # inclusive start and a strictly-interior position.
    ADVERTISEMENT_FRESH = (
        ("start", {"observed_at": STAMP, "valid_until": LATER},
         "an observation instant equal to the recording instant"),
        ("inside", {"observed_at": STAMP - timedelta(hours=1),
                    "valid_until": LATER},
         "a window recorded strictly inside it"),
    )
    for slug, overrides, description in ADVERTISEMENT_FRESH:
        fresh = advertisement(store, host.record_id, pkg.record_id,
                              con.record_id, request_id=f"req-adv-fresh-{slug}",
                              **overrides)
        check(fresh.outcome == ACCEPTED,
              f"an advertisement with {description} is accepted")

    # The verdict comes from the three governed instants and nothing else, so
    # the same request replayed under a different request identity — and at a
    # different wall-clock moment — decides the same way. A check reading the
    # system clock could not promise this.
    stale_body = {"observed_at": STAMP - timedelta(hours=2),
                  "valid_until": STAMP - timedelta(hours=1)}
    first = advertisement(store, host.record_id, pkg.record_id, con.record_id,
                          request_id="req-adv-det-1", **stale_body)
    second = advertisement(store, host.record_id, pkg.record_id, con.record_id,
                           request_id="req-adv-det-2", **stale_body)
    check(first.record_id is None and second.record_id is None
          and first.reason == second.reason,
          "the freshness verdict depends only on the governed instants")

    accepted_adv = advertisement(store, host.record_id, pkg.record_id,
                                 con.record_id, request_id="req-adv-ok")
    check(accepted_adv.outcome == ACCEPTED,
          "an admitted subject may publish its own advertisement without new approval")
    stored_host = store.read_record("capability-host", host.record_id)
    check(stored_host["verified_resource_profile"] == PROFILE,
          "a fresh advertisement does not modify the host record")
    check(store.counts()["capability-instance"] == 0,
          "a fresh advertisement creates no instance")

# --- 20. A rejected operation is freshly evaluated when prerequisites change --
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    first = contract(store, "CAPDEF-0001", request_id="req-fresh")
    check(first.outcome == NOT_FOUND,
          "a contract naming an absent capability is refused")
    cap = capability(store, request_id="req-late-cap")
    check(cap.record_id == "CAPDEF-0001",
          "the capability the refused contract named is declared afterwards")
    second = contract(store, "CAPDEF-0001", request_id="req-fresh")
    check(second.outcome == ACCEPTED,
          "repeating the rejected request after the prerequisite exists is evaluated afresh")
    check(second.record_id == "CCON-0001",
          "the freshly evaluated request allocates its own record")

# --- 22-23. Boundaries and determinism ---------------------------------------
# `admit_instance` and `create_route` were part of this boundary at increment 6
# and are the two operations increment 7 exists to add, so they moved to the
# increment 7 surface assertions below. Every other name stays absent.
for later in ("supersede_route", "evaluate_eligibility",
              "select", "write_atomic", "load_capability", "invoke", "health",
              "remediate", "retry", "refresh"):
    check(not hasattr(admission_module, later),
          f"admission exposes no '{later}' behaviour at increment 6")
for absent in ("health.py",):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 6 creates no {absent}")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    refused = capability(store, request_id="req-det", effect_class="unheard-of")
    again = capability(store, request_id="req-det2", effect_class="unheard-of")
    check(refused.outcome == again.outcome and refused.reason == again.reason,
          "a refusal is deterministic across repetition")
    rendered = str(refused.to_dict())
    for token, leak in ((" 0x", "an object address"), ("/tmp/", "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr"),
                        ("unheard-of", "the rejected value")):
        check(token not in rendered, f"a refusal leaks no {leak}")

# ===========================================================================
# Increment 6 correction — complete request identity, complete validation
# before allocation, and refusals that change nothing
# ===========================================================================
# Three defects, corrected as causes rather than as examples:
#
#   * a request digest derived from a subset of the caller's authoritative
#     inputs, so a reused request identity carrying a changed authority,
#     timestamp, provenance, profile, shape, or optional value was misread as
#     an exact replay of an operation nobody submitted;
#   * allocation before the record content was known to be constructible, so
#     malformed caller content advanced a persistent sequence and let a raw
#     exception out of the boundary;
#   * a writer guard that recognised a receiver merely *named* `store`.
#
# Every assertion below is over synthetic records in a temporary directory.

RELEASED_TRUST_VERIFY = trust_adapter.verify_trust_record
CONFLICT_REASON = "request_identity_conflict"
MALFORMED_CONTENT = "malformed-operation-content"
NAIVE_INSTANT = "timestamp-carries-no-offset"
MISSING_ACTOR = "missing-actor"
MISSING_AUTHORITY = "missing-approving-authority"
UNEXPECTED_AUTHORITY = "unexpected-approving-authority"
INVALID_WINDOW = "invalid-validity-window"


class CountingTrust:
    """The released C3 adapter, counting every query it is asked to make.

    Delegates rather than answers: a stub would prove nothing about how often
    the real adapter is reached, which is exactly what is being counted.
    """

    def __init__(self):
        self.calls = 0

    def __call__(self, store, record_id, *, evaluated_at, expected_subject_type=None):
        self.calls += 1
        return RELEASED_TRUST_VERIFY(store, record_id, evaluated_at=evaluated_at,
                                     expected_subject_type=expected_subject_type)


class AuditStore(WatchedStore):
    """The real store, additionally counting writes and reference resolutions."""

    def __init__(self, *args, **kwargs):
        self.writes = []
        self.reads = 0
        super().__init__(*args, **kwargs)

    def write(self, kind, record):
        path = super().write(kind, record)
        self.writes.append(kind)
        return path

    def read_record(self, kind, identifier):
        self.reads += 1
        return super().read_record(kind, identifier)


def audited(tmp):
    return AuditStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)


def attempted(operation):
    """Run a governed operation, reporting anything that escapes it.

    A governed boundary that raises has already leaked: the exception carries
    the rejected value, its type, and a traceback naming real paths. Catching
    it here turns that leak into a reportable failure instead of a dead suite.
    """
    try:
        return operation(), None
    except BaseException as error:  # noqa: BLE001
        return None, error


def temporaries(base):
    return sorted(str(path) for path in base.rglob(".*.tmp"))


def sequences_of(base):
    directory = base / "sequences"
    if not directory.is_dir():
        return {}
    return {path.name: path.read_bytes() for path in sorted(directory.glob("*.seq"))}


BASE_CAPABILITY = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    name="summarise text", description="Reduce a document to its essentials.",
    effect_class="read-only", contract_ids=(), provenance=dict(PROV), notes=None)

BASE_CONTRACT = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    contract_version="1.0.0", effect_class="read-only",
    determinism_class="deterministic", request_shape=REQUEST_SHAPE,
    response_shape=RESPONSE_SHAPE, failure_modes=("adapter-error",),
    resource_requirements={"host_memory_mb": 512}, compatible_with=(),
    provenance=dict(PROV), description=None)

BASE_PACKAGE = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    satisfied_contract_versions=("1.0.0",), package_version="1.0.0",
    artifact_reference="oci://registry.invalid/summarise",
    resource_requirements={"host_memory_mb": 512},
    trust_domain="capability-package", provenance=dict(PROV), description=None)

BASE_SUBJECT = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    evaluated_at=STAMP, node_identity_reference="node/schai",
    verified_resource_profile=dict(PROFILE),
    verification_reference="/approved/evidence/host-observed.txt",
    location_class="on-premises", data_classification="internal",
    availability_intent="in-service", provenance=dict(PROV),
    name=None, description=None)

BASE_ADVERT = dict(
    recorded_at=STAMP, satisfied_contract_versions=("1.0.0",),
    advertised_resource_profile={"host_memory_mb": 8192},
    observed_at=STAMP, valid_until=LATER, provenance=dict(PROV),
    approving_authority=None)

OTHER_PROV = {"class": "declared", "source": "another operator"}


def identity_matrix(label, run, base, mutations, fabric_root, trust_root, store,
                    trust):
    """One accepted request, one byte-identical repeat, one change at a time.

    A structurally valid change to any authoritative input must be a conflict
    *before* any prerequisite is resolved or any trust standing is queried, so
    the counters are compared rather than the outcome alone.
    """
    original = run(**base)
    check(original.outcome == ACCEPTED,
          f"the {label} establishing a request identity is accepted")
    if original.outcome != ACCEPTED:
        return
    before = forensic(fabric_root)
    trust_before = forensic(trust_root)
    allocated = list(store.allocations)
    written = list(store.writes)
    resolutions = store.reads
    queries = trust.calls
    entries = store.entries

    repeated = run(**base)
    check(repeated.outcome == EXACT_REPLAY,
          f"a byte-identical {label} is an exact replay")
    check(repeated.record_id == original.record_id
          and repeated.record_kind == original.record_kind,
          f"a byte-identical {label} replay returns the original identity")
    check(repeated.request_digest == original.request_digest,
          f"a byte-identical {label} replay derives the same complete digest")
    check(store.allocations == allocated and store.writes == written,
          f"an exact {label} replay allocates and writes nothing")
    check(store.reads == resolutions,
          f"an exact {label} replay resolves no reference")
    check(trust.calls == queries, f"an exact {label} replay queries no trust")
    check(store.entries == entries + 1,
          f"an exact {label} replay enters the critical section exactly once")
    check(store.deepest == 1, f"an exact {label} replay nests no critical section")
    check(forensic(fabric_root) == before,
          f"an exact {label} replay leaves the fabric byte-identical")
    check(forensic(trust_root) == trust_before,
          f"an exact {label} replay leaves the trust plane byte-identical")
    entries = store.entries

    for field, value in mutations:
        result, error = attempted(lambda: run(**dict(base, **{field: value})))
        check(error is None,
              f"a changed {field} on a {label} raises nothing out of the boundary")
        if error is not None:
            continue
        check(result.outcome == CONFLICT,
              f"a changed {field} on a {label} reusing its request identity conflicts")
        check(result.reason == CONFLICT_REASON,
              f"a changed {field} on a {label} is named request_identity_conflict")
        check(result.request_digest != original.request_digest,
              f"a changed {field} changes the {label} request digest")
        check(result.record_id is None and result.record_kind is None,
              f"a changed {field} on a {label} names no record")
        check(store.allocations == allocated,
              f"a changed {field} on a {label} allocates nothing")
        check(store.writes == written,
              f"a changed {field} on a {label} writes nothing")
        check(store.reads == resolutions,
              f"a changed {field} on a {label} resolves no reference")
        check(trust.calls == queries,
              f"a changed {field} on a {label} queries no trust")
        check(store.entries == entries + 1,
              f"a changed {field} on a {label} enters the critical section once")
        check(forensic(fabric_root) == before,
              f"a changed {field} on a {label} leaves the original byte-identical")
        check(forensic(trust_root) == trust_before,
              f"a changed {field} on a {label} leaves the trust plane byte-identical")
        entries = store.entries


COUNTING_TRUST = CountingTrust()
admission_module.verify_trust_record = COUNTING_TRUST
try:
    # --- Every authoritative input participates in request identity ---------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        identity_matrix(
            "capability declaration",
            lambda **fields: declare_capability(store, **fields),
            dict(BASE_CAPABILITY, request_id="req-identity"),
            (("actor", "operator:other"),
             ("approving_authority", "operator:other"),
             ("recorded_at", LATER),
             ("name", "summarise audio"),
             ("description", "Reduce a recording to its essentials."),
             ("effect_class", "computational"),
             ("contract_ids", ("CCON-9999",)),
             ("provenance", dict(OTHER_PROV)),
             ("notes", "an operator note")),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        identity_matrix(
            "contract declaration",
            lambda **fields: declare_contract(store, **fields),
            dict(BASE_CONTRACT, request_id="req-identity",
                 capability_id=cap.record_id),
            (("actor", "operator:other"),
             ("approving_authority", "operator:other"),
             ("recorded_at", LATER),
             ("capability_id", "CAPDEF-9999"),
             ("contract_version", "2.0.0"),
             ("effect_class", "computational"),
             ("determinism_class", "nondeterministic"),
             # A different version of the same authority is a different
             # interface, and a governed one, so the conflict is about the
             # change rather than about the value being unadmittable.
             ("request_shape", dict(REQUEST_SHAPE, schema_version=2)),
             ("response_shape", dict(
                 RESPONSE_SHAPE,
                 content=dict(RESPONSE_SHAPE["content"], schema_version=2))),
             ("failure_modes", ("adapter-error", "timeout")),
             ("resource_requirements", {"host_memory_mb": 1024}),
             ("compatible_with", ("0.9.0",)),
             ("provenance", dict(OTHER_PROV)),
             ("description", "The summarising interface.")),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        identity_matrix(
            "package declaration",
            lambda **fields: declare_package(store, **fields),
            dict(BASE_PACKAGE, request_id="req-identity",
                 capability_id=cap.record_id, contract_id=con.record_id),
            (("actor", "operator:other"),
             ("approving_authority", "operator:other"),
             ("recorded_at", LATER),
             ("capability_id", "CAPDEF-9999"),
             ("contract_id", "CCON-9999"),
             ("satisfied_contract_versions", ("1.0.0", "2.0.0")),
             ("package_version", "2.0.0"),
             ("artifact_reference", "oci://registry.invalid/summarise-audio"),
             ("resource_requirements", {"host_memory_mb": 1024}),
             ("trust_domain", "fabric-node"),
             ("provenance", dict(OTHER_PROV)),
             ("description", "The summarising package.")),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        identity_matrix(
            "subject admission",
            lambda **fields: admit_subject(store, trust_store, **fields),
            dict(BASE_SUBJECT, request_id="req-identity",
                 fabric_node_trust_record_id=granted.record.record_id),
            (("actor", "operator:other"),
             ("approving_authority", "operator:other"),
             ("recorded_at", LATER),
             ("evaluated_at", LATER),
             ("node_identity_reference", "node/elsewhere"),
             ("fabric_node_trust_record_id", "TREC-999999"),
             ("verified_resource_profile", {"host_memory_mb": 4096,
                                            "host_cpu_cores": 8,
                                            "architecture": "x86-64"}),
             ("verification_reference", "/approved/evidence/host-reobserved.txt"),
             ("location_class", "third-party-hosted"),
             ("data_classification", "confidential"),
             ("availability_intent", "drained"),
             ("provenance", dict(OTHER_PROV)),
             ("name", "schai"),
             ("description", "The on-premises inference host.")),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        pkg = declare_package(store, **dict(BASE_PACKAGE, request_id="req-seed-pkg",
                                            capability_id=cap.record_id,
                                            contract_id=con.record_id))
        adm = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="req-seed-host",
            fabric_node_trust_record_id=granted.record.record_id))
        identity_matrix(
            "advertisement registration",
            lambda **fields: register_advertisement(store, **fields),
            dict(BASE_ADVERT, request_id="req-identity", actor=adm.record_id,
                 capability_host_id=adm.record_id,
                 capability_package_id=pkg.record_id, contract_id=con.record_id),
            (("actor", "CHOST-9999"),
             # Inside the base window on purpose: a `recorded_at` at or past
             # `valid_until` is refused on structure before the request is
             # identified, which would prove a refusal rather than a conflict.
             ("recorded_at", STAMP + timedelta(hours=1)),
             ("capability_host_id", "CHOST-9999"),
             ("capability_package_id", "CPKG-9999"),
             ("contract_id", "CCON-9999"),
             ("satisfied_contract_versions", ("1.0.0", "2.0.0")),
             ("advertised_resource_profile", {"host_cpu_cores": 8}),
             ("observed_at", STAMP - timedelta(hours=1)),
             ("valid_until", LATER + timedelta(hours=1)),
             ("provenance", dict(OTHER_PROV))),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)
        # `approving_authority` stays in the digest, but no non-`None` value is
        # ever structurally reachable: naming an approver is refused before the
        # request is identified at all, so it is asserted below as a structural
        # prohibition rather than as one more digestible change.

    # --- An optional that was supplied is not the same request as one that
    #     was not, in either direction --------------------------------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        supplied = declare_capability(store, **dict(
            BASE_CAPABILITY, request_id="req-optional", notes="an operator note"))
        check(supplied.outcome == ACCEPTED,
              "a declaration supplying an optional value is accepted")
        before = forensic(fabric_root)
        withdrawn = declare_capability(store, **dict(
            BASE_CAPABILITY, request_id="req-optional", notes=None))
        check(withdrawn.outcome == CONFLICT,
              "withdrawing an optional value under the same request identity conflicts")
        check(withdrawn.reason == CONFLICT_REASON,
              "a withdrawn optional value is named request_identity_conflict")
        check(forensic(fabric_root) == before,
              "a withdrawn optional value leaves the original byte-identical")
        again = declare_capability(store, **dict(
            BASE_CAPABILITY, request_id="req-optional", notes="an operator note"))
        check(again.outcome == EXACT_REPLAY,
              "restoring the optional value replays the original exactly")
        check(again.record_id == supplied.record_id,
              "the restored replay returns the original identity")

    # --- Malformed authority never becomes an exact replay ------------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        established = declare_capability(store, **dict(BASE_CAPABILITY,
                                                       request_id="req-authority"))
        check(established.outcome == ACCEPTED,
              "the declaration establishing an authority regression is accepted")
        before = forensic(fabric_root)
        allocated = list(store.allocations)
        # Malformed authority is not a different request -- it is not a request.
        # It is refused on its structure, so it can be neither a replay of the
        # accepted operation nor a conflict with it.
        for field, value, reason, description in (
                ("actor", None, MISSING_ACTOR, "no actor"),
                ("actor", "", MISSING_ACTOR, "an empty actor"),
                ("actor", 7, MISSING_ACTOR, "a non-textual actor"),
                ("approving_authority", None, MISSING_AUTHORITY,
                 "no approving authority"),
                ("approving_authority", "", MISSING_AUTHORITY,
                 "an empty approving authority"),
                ("approving_authority", 7, MISSING_AUTHORITY,
                 "a non-textual approving authority")):
            entries = store.entries
            result, error = attempted(lambda: declare_capability(
                store, **dict(BASE_CAPABILITY, request_id="req-authority",
                              **{field: value})))
            check(error is None,
                  f"a reused request identity with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome != EXACT_REPLAY,
                  f"a reused request identity with {description} is never an exact replay")
            check(result.outcome != CONFLICT,
                  f"a reused request identity with {description} is never a conflict")
            check(result.outcome == INVALID and result.reason == reason,
                  f"a reused request identity with {description} is refused as {reason}")
            check(store.entries == entries,
                  f"a reused request identity with {description} enters no critical section")
            check(result.record_id is None,
                  f"a reused request identity with {description} names no record")
            check(store.allocations == allocated,
                  f"a reused request identity with {description} allocates nothing")
            check(forensic(fabric_root) == before,
                  f"a reused request identity with {description} changes nothing")
        # An authority the released canonicaliser cannot represent is refused
        # before the critical section is entered at all.
        entries = store.entries
        result, error = attempted(lambda: declare_capability(
            store, **dict(BASE_CAPABILITY, request_id="req-authority",
                          actor=object())))
        check(error is None, "an unrepresentable actor raises nothing")
        check(result is not None and result.outcome == INVALID,
              "an unrepresentable actor is refused as invalid")
        check(result is not None and result.reason == MISSING_ACTOR,
              "an unrepresentable actor is named missing-actor")
        check(result is not None and result.outcome != EXACT_REPLAY,
              "an unrepresentable actor is never an exact replay")
        check(store.entries == entries,
              "an unrepresentable payload enters no critical section")
        check(forensic(fabric_root) == before,
              "an unrepresentable actor changes nothing")

    # --- Nothing is allocated until the content is known constructible ------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        pkg = declare_package(store, **dict(BASE_PACKAGE, request_id="req-seed-pkg",
                                            capability_id=cap.record_id,
                                            contract_id=con.record_id))
        adm = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="req-seed-host",
            fabric_node_trust_record_id=granted.record.record_id))
        adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="req-seed-adv", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id))
        check(all(result.outcome == ACCEPTED
                  for result in (cap, con, pkg, adm, adv)),
              "every sequence exists before the malformed-content matrix runs")

        def bad_capability(index, **overrides):
            return lambda: declare_capability(store, **dict(
                BASE_CAPABILITY, request_id=f"req-malformed-{index}", **overrides))

        def bad_contract(index, **overrides):
            return lambda: declare_contract(store, **dict(
                BASE_CONTRACT, request_id=f"req-malformed-{index}",
                capability_id=cap.record_id, **overrides))

        def bad_package(index, **overrides):
            return lambda: declare_package(store, **dict(
                BASE_PACKAGE, request_id=f"req-malformed-{index}",
                capability_id=cap.record_id, contract_id=con.record_id,
                **overrides))

        def bad_subject(index, **overrides):
            return lambda: admit_subject(store, trust_store, **dict(
                BASE_SUBJECT, request_id=f"req-malformed-{index}",
                fabric_node_trust_record_id=granted.record.record_id, **overrides))

        def bad_advertisement(index, **overrides):
            return lambda: register_advertisement(store, **dict(
                BASE_ADVERT, request_id=f"req-malformed-{index}",
                actor=adm.record_id, capability_host_id=adm.record_id,
                capability_package_id=pkg.record_id, contract_id=con.record_id,
                **overrides))

        MALFORMED = (
            ("a capability whose provenance is not a mapping", MALFORMED_CONTENT,
             bad_capability(1, provenance=7)),
            ("a capability whose contract references are not a sequence",
             MALFORMED_CONTENT, bad_capability(2, contract_ids=7)),
            ("a capability whose notes cannot be represented", MALFORMED_CONTENT,
             bad_capability(3, notes=object())),
            ("a contract whose request shape is not a mapping", MALFORMED_CONTENT,
             bad_contract(4, request_shape=7)),
            ("a contract whose response shape is not a mapping", MALFORMED_CONTENT,
             bad_contract(5, response_shape=7)),
            ("a contract whose failure modes are not a sequence", MALFORMED_CONTENT,
             bad_contract(6, failure_modes=7)),
            ("a contract whose resource requirements are not a mapping",
             MALFORMED_CONTENT, bad_contract(7, resource_requirements=7)),
            ("a contract whose compatibility is a bare string", MALFORMED_CONTENT,
             bad_contract(8, compatible_with="1.0.0")),
            ("a contract whose provenance is not a mapping", MALFORMED_CONTENT,
             bad_contract(9, provenance=7)),
            ("a contract whose description cannot be represented",
             MALFORMED_CONTENT, bad_contract(10, description=object())),
            ("a contract whose recorded instant carries no offset", NAIVE_INSTANT,
             bad_contract(11, recorded_at=STAMP.replace(tzinfo=None))),
            ("a package whose resource requirements are not a mapping",
             MALFORMED_CONTENT, bad_package(12, resource_requirements=7)),
            ("a package whose provenance is not a mapping", MALFORMED_CONTENT,
             bad_package(13, provenance=7)),
            ("a package whose satisfied versions are not a sequence",
             MALFORMED_CONTENT, bad_package(14, satisfied_contract_versions=7)),
            ("a package whose description cannot be represented",
             MALFORMED_CONTENT, bad_package(15, description=object())),
            ("an admission whose verified profile is not a mapping",
             MALFORMED_CONTENT, bad_subject(16, verified_resource_profile=7)),
            ("an admission whose provenance is not a mapping", MALFORMED_CONTENT,
             bad_subject(17, provenance=7)),
            ("an admission whose name cannot be represented", MALFORMED_CONTENT,
             bad_subject(18, name=object())),
            ("an admission whose evaluation instant carries no offset",
             NAIVE_INSTANT, bad_subject(19, evaluated_at=STAMP.replace(tzinfo=None))),
            ("an advertisement whose advertised profile is not a mapping",
             MALFORMED_CONTENT, bad_advertisement(20, advertised_resource_profile=7)),
            ("an advertisement whose provenance is not a mapping",
             MALFORMED_CONTENT, bad_advertisement(21, provenance=7)),
            ("an advertisement whose satisfied versions are not a sequence",
             MALFORMED_CONTENT, bad_advertisement(22, satisfied_contract_versions=7)),
            ("an advertisement whose observation instant is text", NAIVE_INSTANT,
             bad_advertisement(23, observed_at=STAMP.isoformat())),
        )
        for description, reason, operation in MALFORMED:
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            allocated = list(store.allocations)
            written = list(store.writes)
            residue = temporaries(fabric_root)
            counters = sequences_of(fabric_root)
            result, error = attempted(operation)
            check(error is None,
                  f"{description} raises nothing out of the governed boundary")
            if error is not None:
                continue
            check(result.outcome in (INVALID, REFUSED),
                  f"{description} returns a controlled result")
            check(result.reason == reason,
                  f"{description} is refused as {reason}")
            check(result.record_id is None and result.record_kind is None,
                  f"{description} names no record")
            check(store.allocations == allocated,
                  f"{description} allocates no identity")
            check(store.writes == written, f"{description} writes no record")
            check(sequences_of(fabric_root) == counters,
                  f"{description} creates and advances no sequence")
            check(temporaries(fabric_root) == residue,
                  f"{description} leaves no temporary artefact")
            check(forensic(fabric_root) == before,
                  f"{description} leaves the fabric forensically identical")
            check(forensic(trust_root) == trust_before,
                  f"{description} leaves the trust plane forensically identical")
            rendered = str(result.to_dict())
            for token, leak in ((" 0x", "an object address"),
                                ("/tmp/", "a filesystem path"),
                                ("Traceback", "a traceback"),
                                ("object at", "an object repr")):
                check(token not in rendered, f"{description} leaks no {leak}")
            repeated, repeated_error = attempted(operation)
            check(repeated_error is None and repeated is not None
                  and repeated.outcome == result.outcome
                  and repeated.reason == result.reason,
                  f"{description} is refused identically on repetition")

        check(temporaries(fabric_root) == [],
              "the malformed-content matrix left no temporary artefact at all")

        # The construction failure the correction was raised against: it used
        # to be discovered only after C1 had already advanced the sequence.
        counters = sequences_of(fabric_root)
        allocated = list(store.allocations)
        check("capability-contract.seq" in counters,
              "the contract sequence exists before the model-construction case")
        result, error = attempted(lambda: declare_contract(store, **dict(
            BASE_CONTRACT, request_id="req-shape", capability_id=cap.record_id,
            request_shape=7)))
        check(error is None,
              "declare_contract with a malformed request shape raises nothing")
        check(result is not None and result.outcome == INVALID
              and result.reason == MALFORMED_CONTENT,
              "declare_contract with a malformed request shape is controlled content")
        check(store.allocations == allocated,
              "a model-construction failure allocates no identity at all")
        check(sequences_of(fabric_root) == counters,
              "a model-construction failure leaves every sequence exactly where it was")

    # --- Structure is judged before identity, not after ---------------------
    # A caller value whose form is wrong does not describe a different request;
    # it describes no request. Digesting it first lets it borrow an accepted
    # request's identity: an ISO string and the datetime it renders produce the
    # same canonical text, so a malformed timestamp could return the accepted
    # record as though the caller had submitted it.

    class ExplodingInstant(datetime):
        """An aware instant whose rendering fails. Structure alone cannot tell."""

        def isoformat(self, *args, **kwargs):
            raise RuntimeError("this instant refuses to be rendered")

    class ExplodingZone(tzinfo):
        """An offset that raises when it is asked what it is."""

        def utcoffset(self, instant):
            raise RuntimeError("this zone refuses to answer")

        def tzname(self, instant):
            return "exploding"

        def dst(self, instant):
            return None

    def exploding_at(instant):
        """The same instant, rendered by something that refuses to render."""
        return ExplodingInstant(instant.year, instant.month, instant.day,
                                instant.hour, instant.minute, instant.second,
                                tzinfo=instant.tzinfo)

    def zoned_at(instant):
        """The same wall time, offset by something that refuses to answer."""
        return datetime(instant.year, instant.month, instant.day, instant.hour,
                        instant.minute, instant.second, tzinfo=ExplodingZone())

    def structural_matrix(label, run, base, cases, fabric_root, trust_root, store,
                          trust):
        """One accepted request, then structurally malformed reuses of its identity.

        Each case must be refused on its structure alone: before the digest,
        before the critical section, before replay or conflict classification,
        and before anything is resolved, queried, allocated, or written.
        """
        original = run(**base)
        check(original.outcome == ACCEPTED,
              f"the {label} establishing a structural regression is accepted")
        if original.outcome != ACCEPTED:
            return
        before = forensic(fabric_root)
        trust_before = forensic(trust_root)
        counters = sequences_of(fabric_root)
        allocated = list(store.allocations)
        written = list(store.writes)
        recorded = store.read_record(original.record_kind, original.record_id)
        resolutions = store.reads
        queries = trust.calls

        for field, value, outcome, reason, description in cases:
            entries = store.entries
            result, error = attempted(lambda: run(**dict(base, **{field: value})))
            check(error is None,
                  f"a {label} reusing its identity with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome and result.reason == reason,
                  f"a {label} reusing its identity with {description} is refused as {reason}")
            check(result.outcome != EXACT_REPLAY,
                  f"a {label} reusing its identity with {description} is never an exact replay")
            check(result.outcome != CONFLICT,
                  f"a {label} reusing its identity with {description} is never a conflict")
            check(store.entries == entries,
                  f"a {label} reusing its identity with {description} enters no critical section")
            check(result.record_id is None and result.record_kind is None,
                  f"a {label} reusing its identity with {description} names no record")
            check(store.allocations == allocated,
                  f"a {label} reusing its identity with {description} allocates nothing")
            check(store.writes == written,
                  f"a {label} reusing its identity with {description} writes nothing")
            check(store.reads == resolutions,
                  f"a {label} reusing its identity with {description} resolves no reference")
            check(trust.calls == queries,
                  f"a {label} reusing its identity with {description} queries no trust")
            check(sequences_of(fabric_root) == counters,
                  f"a {label} reusing its identity with {description} advances no sequence")
            check(forensic(fabric_root) == before,
                  f"a {label} reusing its identity with {description} leaves the fabric identical")
            check(forensic(trust_root) == trust_before,
                  f"a {label} reusing its identity with {description} leaves trust identical")
            rendered = str(result.to_dict())
            for token, leak in ((" 0x", "an object address"),
                                ("/tmp/", "a filesystem path"),
                                ("Traceback", "a traceback"),
                                ("object at", "an object repr"),
                                ("RuntimeError", "an exception type")):
                check(token not in rendered,
                      f"a {label} reusing its identity with {description} leaks no {leak}")
            repeated, repeated_error = attempted(
                lambda: run(**dict(base, **{field: value})))
            check(repeated_error is None and repeated is not None
                  and repeated.outcome == result.outcome
                  and repeated.reason == result.reason,
                  f"a {label} reusing its identity with {description} refuses identically twice")

        # The accepted record is still exactly what it was, and still replays.
        check(store.read_record(original.record_kind, original.record_id) == recorded,
              f"the accepted {label} record is unchanged after every structural refusal")
        survivor = run(**base)
        check(survivor.outcome == EXACT_REPLAY and survivor.record_id == original.record_id,
              f"the accepted {label} still replays exactly after every structural refusal")

    # A timestamp's own ISO text is the case that motivated the correction: it
    # canonicalises identically to the datetime it renders. The hostile
    # instants keep the field's own value, so a window check cannot refuse them
    # before the rendering that is actually under test is reached.
    NAIVE_STAMP = STAMP.replace(tzinfo=None)

    def instant_cases(field, accepted_value):
        return ((field, accepted_value.isoformat(), INVALID, NAIVE_INSTANT,
                 f"{field} as its own ISO text"),
                (field, NAIVE_STAMP, INVALID, NAIVE_INSTANT,
                 f"a naive {field}"),
                (field, 7, INVALID, NAIVE_INSTANT, f"a numeric {field}"),
                (field, None, INVALID, NAIVE_INSTANT, f"an absent {field}"),
                (field, exploding_at(accepted_value), INVALID, MALFORMED_CONTENT,
                 f"a {field} that cannot be rendered"),
                (field, zoned_at(accepted_value), INVALID, MALFORMED_CONTENT,
                 f"a {field} whose offset raises"))

    AUTHORITY_CASES = (
        ("actor", "", INVALID, MISSING_ACTOR, "an empty actor"),
        ("actor", None, INVALID, MISSING_ACTOR, "no actor"),
        ("approving_authority", None, INVALID, MISSING_AUTHORITY,
         "no approving authority"),
        ("approving_authority", "", INVALID, MISSING_AUTHORITY,
         "an empty approving authority"),
    )

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        structural_matrix(
            "capability declaration",
            lambda **fields: declare_capability(store, **fields),
            dict(BASE_CAPABILITY, request_id="req-structural"),
            AUTHORITY_CASES + instant_cases("recorded_at", STAMP),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        structural_matrix(
            "contract declaration",
            lambda **fields: declare_contract(store, **fields),
            dict(BASE_CONTRACT, request_id="req-structural",
                 capability_id=cap.record_id),
            AUTHORITY_CASES + instant_cases("recorded_at", STAMP),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        structural_matrix(
            "package declaration",
            lambda **fields: declare_package(store, **fields),
            dict(BASE_PACKAGE, request_id="req-structural",
                 capability_id=cap.record_id, contract_id=con.record_id),
            AUTHORITY_CASES + instant_cases("recorded_at", STAMP),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        structural_matrix(
            "subject admission",
            lambda **fields: admit_subject(store, trust_store, **fields),
            dict(BASE_SUBJECT, request_id="req-structural",
                 fabric_node_trust_record_id=granted.record.record_id),
            AUTHORITY_CASES + instant_cases("recorded_at", STAMP)
            + instant_cases("evaluated_at", STAMP),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        pkg = declare_package(store, **dict(BASE_PACKAGE, request_id="req-seed-pkg",
                                            capability_id=cap.record_id,
                                            contract_id=con.record_id))
        adm = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="req-seed-host",
            fabric_node_trust_record_id=granted.record.record_id))
        structural_matrix(
            "advertisement registration",
            lambda **fields: register_advertisement(store, **fields),
            dict(BASE_ADVERT, request_id="req-structural", actor=adm.record_id,
                 capability_host_id=adm.record_id,
                 capability_package_id=pkg.record_id, contract_id=con.record_id),
            (("actor", "", INVALID, MISSING_ACTOR, "an empty actor"),
             ("actor", None, INVALID, MISSING_ACTOR, "no actor"),
             # An advertisement names no approver, and one is refused on
             # structure: recording it would turn a self-report into approval.
             ("approving_authority", OPERATOR, REFUSED, UNEXPECTED_AUTHORITY,
              "a supplied approving authority"),
             ("approving_authority", "operator:other", REFUSED,
              UNEXPECTED_AUTHORITY, "another supplied approving authority"),
             ("valid_until", STAMP, REFUSED, INVALID_WINDOW,
              "a window that ends when it starts"),
             ("valid_until", STAMP - timedelta(hours=1), REFUSED, INVALID_WINDOW,
              "a reversed validity window"))
            + instant_cases("recorded_at", STAMP)
            + instant_cases("observed_at", STAMP)
            + instant_cases("valid_until", LATER),
            Path(tmp) / "fabric", Path(tmp) / "trust", store, COUNTING_TRUST)

    # --- Structural refusal does not displace conflict ----------------------
    # The preflight must refuse malformed structure without swallowing the
    # conflict a structurally valid change still owes.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, granted = seeded_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="req-seed-cap"))
        con = declare_contract(store, **dict(BASE_CONTRACT,
                                             request_id="req-seed-con",
                                             capability_id=cap.record_id))
        pkg = declare_package(store, **dict(BASE_PACKAGE, request_id="req-seed-pkg",
                                            capability_id=cap.record_id,
                                            contract_id=con.record_id))
        adm = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="req-seed-host",
            fabric_node_trust_record_id=granted.record.record_id))
        VALID_CHANGES = (
            ("capability declaration",
             lambda **fields: declare_capability(store, **fields),
             dict(BASE_CAPABILITY, request_id="req-valid-cap"),
             (("actor", "operator:other"),
              ("approving_authority", "operator:other"),
              ("recorded_at", LATER))),
            ("contract declaration",
             lambda **fields: declare_contract(store, **fields),
             dict(BASE_CONTRACT, request_id="req-valid-con",
                  capability_id=cap.record_id),
             (("actor", "operator:other"),
              ("approving_authority", "operator:other"),
              ("recorded_at", LATER))),
            ("package declaration",
             lambda **fields: declare_package(store, **fields),
             dict(BASE_PACKAGE, request_id="req-valid-pkg",
                  capability_id=cap.record_id, contract_id=con.record_id),
             (("actor", "operator:other"),
              ("approving_authority", "operator:other"),
              ("recorded_at", LATER))),
            ("subject admission",
             lambda **fields: admit_subject(store, trust_store, **fields),
             dict(BASE_SUBJECT, request_id="req-valid-host",
                  node_identity_reference="node/schai",
                  fabric_node_trust_record_id=granted.record.record_id),
             (("actor", "operator:other"),
              ("approving_authority", "operator:other"),
              ("recorded_at", LATER),
              ("evaluated_at", LATER))),
            ("advertisement registration",
             lambda **fields: register_advertisement(store, **fields),
             dict(BASE_ADVERT, request_id="req-valid-adv", actor=adm.record_id,
                  capability_host_id=adm.record_id,
                  capability_package_id=pkg.record_id, contract_id=con.record_id),
             (("actor", "CHOST-9999"),
              # Still inside the base window: a structurally valid change has
              # to remain structurally valid, and `recorded_at` at or past
              # `valid_until` is refused rather than identified.
              ("recorded_at", STAMP + timedelta(hours=1)),
              ("observed_at", STAMP - timedelta(hours=1)),
              ("valid_until", LATER + timedelta(hours=1)))),
        )
        for label, run, base, changes in VALID_CHANGES:
            accepted = run(**base)
            check(accepted.outcome == ACCEPTED,
                  f"the {label} establishing a valid-change regression is accepted")
            before = forensic(fabric_root)
            for field, value in changes:
                entries = store.entries
                result, error = attempted(lambda: run(**dict(base, **{field: value})))
                check(error is None,
                      f"a structurally valid changed {field} on a {label} raises nothing")
                if error is not None:
                    continue
                check(result.outcome == CONFLICT and result.reason == CONFLICT_REASON,
                      f"a structurally valid changed {field} on a {label} still conflicts")
                check(store.entries == entries + 1,
                      f"a structurally valid changed {field} on a {label} enters the section once")
                check(forensic(fabric_root) == before,
                      f"a structurally valid changed {field} on a {label} changes nothing")
            replayed = run(**base)
            check(replayed.outcome == EXACT_REPLAY
                  and replayed.record_id == accepted.record_id,
                  f"the byte-identical {label} still replays exactly")

    # --- A refused request is not durably replayed --------------------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        seeded_trust(tmp)
        refused = declare_capability(store, **dict(BASE_CAPABILITY,
                                                   request_id="req-retry",
                                                   provenance=7))
        check(refused.record_id is None, "a malformed declaration records nothing")
        corrected = declare_capability(store, **dict(BASE_CAPABILITY,
                                                     request_id="req-retry"))
        check(corrected.outcome == ACCEPTED,
              "the same request identity is evaluated afresh once the content is well formed")
        check(corrected.record_id == "CAPDEF-0001",
              "the freshly evaluated request allocates the first identity")
finally:
    admission_module.verify_trust_record = RELEASED_TRUST_VERIFY

check(admission_module.verify_trust_record is RELEASED_TRUST_VERIFY,
      "the released C3 adapter is restored after the correction regression")

# --- The correction adds no module, and increment 7 has not begun -----------
RELEASED_MODULES = {"__init__.py", "admission.py", "errors.py", "evidence.py",
                    "identifiers.py", "models.py", "request_identity.py",
                    "store.py", "trust_adapter.py", "validator.py",
                    # One module per increment: C5's, C6's, C8's, then the
                    # interface the twelve operations are reached through.
                    "eligibility.py", "selection.py", "inspection.py", "cli.py",
                    # The one resource-semantics primitive both admission and
                    # eligibility consume, so the two planes cannot drift.
                    "resources.py",
                    # The read-only reader for the deployment Evidence
                    # authority. It lives here because Fabric admission is its
                    # only consumer and this package is repository-side: placing
                    # it in the Capability runtime to reuse code would move
                    # plane ownership and make it an installed object.
                    "evidence_authority.py"}
check({path.name for path in (root / "tools" / "fabric").glob("*.py")}
      == RELEASED_MODULES,
      "the fabric package holds the released modules and C5, and nothing else")

# =======================================================================
# Increment 7 — instance admission, lifecycle transitions, route governance
# =======================================================================
# C4 part 2. Three governed operations, each single-record, each delegating
# its one physical write to C1 through the same `_commit`.
#
# What is *not* here is as deliberate as what is: no eligibility verdict is
# computed or stored, no selection happens, no `CSEL` exists, and the
# derived statuses -- expiry, disappearance, return, staleness -- write
# nothing at all. They are observations, and an observation that writes a
# record has been promoted to a decision.

OPERATIONS = {}
for _name in ("admit_instance", "create_route", "withdraw_subject",
              "refresh_subject", "withdraw_instance", "retire_instance"):
    _operation = getattr(admission_module, _name, None)
    check(callable(_operation), f"increment 7 exposes the governed operation {_name}")
    OPERATIONS[_name] = _operation


# A result-shaped placeholder, so an operation that does not exist yet fails an
# assertion instead of ending the suite with an AttributeError.
MISSING = OperationResult("missing-operation", "", reason="not-implemented")


def record_of(store, kind, identifier):
    """The stored record, or an empty mapping when there is none to read."""
    try:
        return store.read_record(kind, identifier)
    except BaseException:  # noqa: BLE001
        return {}



class MissingOperation(Exception):
    """Reported instead of a crash when an operation does not exist yet."""


def call(name, *args, **kwargs):
    """Invoke an increment 7 operation, reporting anything that escapes it."""
    operation = OPERATIONS.get(name)
    if operation is None:
        return MISSING, MissingOperation(name)
    try:
        return operation(*args, **kwargs), None
    except BaseException as error:  # noqa: BLE001
        return MISSING, error


class DomainTrust:
    """The released C3 adapter, counting queries by the domain asked about.

    Delegates rather than answers: counting a stub would prove nothing
    about how often the real adapter is reached.
    """

    def __init__(self):
        self.calls = []

    def __call__(self, store, record_id, *, evaluated_at, expected_subject_type=None):
        self.calls.append(expected_subject_type)
        return RELEASED_TRUST_VERIFY(store, record_id, evaluated_at=evaluated_at,
                                     expected_subject_type=expected_subject_type)

    def counts(self):
        return (self.calls.count("capability-package"),
                self.calls.count("fabric-node"))


# Exact containment, never interpretation: the package may require only
# dimensions the operator verified, at the values the operator verified.
INSTANCE_PACKAGE = dict(BASE_PACKAGE,
                        resource_requirements={"host_memory_mb": 512,
                                               "architecture": "x86-64"})
# The operator's own bound, in the released Trust scope vocabulary. Every
# dimension is named: every released dimension must survive composition
# non-empty, and one the composition leaves empty bounds nothing.
#
# The capability dimension names the canonical `CAPDEF-0000` identity the
# Fabric allocated, per the accepted architecture. A descriptive workload token
# would name nothing the Fabric could match, and there is no alias mapping.
SCOPE = {"permitted_capabilities": ["CAPDEF-0001"],
         "permitted_operations": ["linux.hostname"],
         "permitted_data_classifications": ["internal"],
         "permitted_targets": ["schmgmt.home.arpa"]}
# What the intersection of both grants and that bound comes to.
EFFECTIVE = {"permitted_capabilities": ("CAPDEF-0001",),
             "permitted_operations": ("linux.hostname",),
             "permitted_data_classifications": ("internal",),
             "permitted_targets": ("schmgmt.home.arpa",)}
BASE_INSTANCE = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    evaluated_at=LATER, satisfied_contract_versions=("1.0.0",),
    verified_resource_profile=dict(PROFILE),
    admission_decision_id="TDEC-000001",
    admission_scope=dict(SCOPE), admitted_at=STAMP, admitted_until=YEAR,
    endpoint_reference=None, provenance=dict(PROV), supersedes=None, notes=None)
BASE_ROUTE = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    accepted_contract_versions=("1.0.0",), locality="operator-controlled-only",
    data_classification="internal", route_version=1, provenance=dict(PROV),
    description=None, overlap_starts_at=None, overlap_ends_at=None,
supersedes=None, notes=None)
BASE_WITHDRAWAL = dict(
    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
    availability_intent="withheld", provenance=dict(PROV), notes=None)


# Which trust record decided which package subject, so a matrix can name the
# grant belonging to the package it is actually admitting.
PACKAGE_TRUST = {}
# Which trust record decided which fabric node, so a selection test can admit a
# second machine under an identity of its own.
NODE_TRUST = {}


def seeded_fabric_trust(tmp, node="node/schai", artifact="CPKG-0001",
                        node_state=TrustState.TRUSTED.value,
                        package_state=TrustState.TRUSTED.value,
                        node_expiration=None, package_expiration=None,
                        node_type="fabric-node",
                        package_type="capability-package",
                        capabilities=("CAPDEF-0001",), nodes=()):
    """A trust store holding two separately decided subjects.

    Trusting a package trusts no machine and trusting a machine trusts no
    package, so the host and the package are decided independently, in
    their own domains, and the Fabric reads neither -- it asks C3 twice.
    """
    store = TrustStore(Path(tmp) / "trust")
    approved = Path(tmp) / "approved"
    approved.mkdir()
    approved.joinpath("root.yaml").write_text(_yaml.safe_dump({
        "display_name": "Operator Root Authority",
        "external_identity_reference": "secret-source://approved/operator-root",
        "verification_method": VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
        "verification_details": {
            "subject_property": "operator-root-identity",
            "observed_value_reference": "/approved/evidence/root-observed.txt",
            "comparison_source": "in-person-verification-record",
            "performed_by": "operator-role-reference",
            "performed_at": STAMP.isoformat()},
        "evidence_references": [{
            "evidence_id": "TEVID-000001", "kind": "attestation",
            "reference": "/approved/evidence/root-attestation.txt",
            "recorded_at": STAMP.isoformat()}],
        "created_at": STAMP.isoformat(),
        "provenance": {"class": "declared", "source": "operator-out-of-band"},
    }), encoding="utf-8")
    authority = declare_root_authority(store, load_root_declaration(
        "root.yaml", approved_directory=str(approved)))

    def decide(subject_id, subject_type, state, expiration):
        return create_decision(
            store, subject_id=subject_id, subject_type=subject_type,
            requested_state=state, actor_authority_id=authority.authority_id,
            decided_at=STAMP, reason="granted for the fabric admission regression",
            evidence_references=(TrustEvidenceReference(
                evidence_id=store.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt", recorded_at=STAMP),),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=TrustVerificationDetails(
                subject_property="ssh-host-key-fingerprint",
                observed_value_reference="/approved/evidence/observed.txt",
                comparison_source="printed-console-readout",
                performed_by="operator-role-reference", performed_at=STAMP),
            scope=TrustScope(
                scope_id="TSCOPE-000001", subject_type=subject_type,
                permitted_capabilities=tuple(capabilities),
                permitted_operations=("linux.hostname",),
                permitted_data_classifications=("internal",),
                permitted_targets=("schmgmt.home.arpa",),
                validity_start=STAMP, validity_end=YEAR),
            expiration=expiration)

    host_trust = decide(node, node_type, node_state, node_expiration)
    # Selection has to tell one machine from another, so a test may decide
    # further nodes. Each is its own subject, decided in its own domain.
    NODE_TRUST.clear()
    NODE_TRUST[node] = host_trust.record.record_id
    for extra in nodes:
        NODE_TRUST[extra] = decide(
            extra, node_type, node_state, node_expiration).record.record_id
    # A package is a subject under its own record identity, decided per
    # version and per contract. The matrices declare four, so four are decided.
    granted = {name: decide(name, package_type, package_state, package_expiration)
               for name in ("CPKG-0001", "CPKG-0002", "CPKG-0003", "CPKG-0004")}
    PACKAGE_TRUST.clear()
    PACKAGE_TRUST.update({name: outcome.record.record_id
                          for name, outcome in granted.items()})
    return store, host_trust, granted[artifact]


def fabric_ready(tmp, store, trust_store, host_trust, package_trust, **overrides):
    """Capability, contract, package, admitted host, and a fresh claim."""
    cap = declare_capability(store, **dict(BASE_CAPABILITY, request_id="i7-cap"))
    con = declare_contract(store, **dict(BASE_CONTRACT, request_id="i7-con",
                                         capability_id=cap.record_id))
    pkg = declare_package(store, **dict(INSTANCE_PACKAGE, request_id="i7-pkg",
                                        capability_id=cap.record_id,
                                        contract_id=con.record_id))
    adm = admit_subject(store, trust_store, **dict(
        BASE_SUBJECT, request_id="i7-host",
        fabric_node_trust_record_id=host_trust.record.record_id))
    adv = register_advertisement(store, **dict(
        BASE_ADVERT, request_id="i7-adv", actor=adm.record_id,
        capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, observed_at=STAMP,
        valid_until=YEAR))
    check(all(result.outcome == ACCEPTED for result in (cap, con, pkg, adm, adv)),
          "the increment 7 prerequisites are all accepted")
    base = dict(BASE_INSTANCE, capability_id=cap.record_id,
                capability_package_id=pkg.record_id,
                capability_host_id=adm.record_id, contract_id=con.record_id,
                advertisement_id=adv.record_id,
                package_trust_record_id=package_trust.record.record_id,
                host_trust_record_id=host_trust.record.record_id)
    base.update(overrides)
    return cap, con, pkg, adm, adv, base


RELEASED_TRUST_VERIFY_7 = trust_adapter.verify_trust_record
DOMAIN_TRUST = DomainTrust()
admission_module.verify_trust_record = DOMAIN_TRUST
try:
    # --- 1. A governed instance admission writes exactly one CINST ------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        before_trust = forensic(trust_root)
        entries = store.entries
        queries = list(DOMAIN_TRUST.calls)
        admitted, error = call("admit_instance", store, trust_store,
                               **dict(base, request_id="i7-inst"))
        check(error is None, "a governed instance admission raises nothing")
        check(admitted is not None and admitted.outcome == ACCEPTED,
              "a governed instance admission is accepted")
        check(admitted is not None and admitted.record_kind == "capability-instance"
              and admitted.record_id == "CINST-000001",
              "a governed instance admission allocates CINST-000001 through C1")
        check("CINST-000001" in store.allocations,
              "CINST-000001 was allocated by the store, not chosen by the caller")
        check(store.entries == entries + 1,
              "instance admission enters the critical section exactly once")
        check(store.deepest == 1, "instance admission nests no critical section")
        fresh = [domain for domain in DOMAIN_TRUST.calls[len(queries):]]
        check(fresh.count("capability-package") == 1,
              "a fresh instance admission queries package trust exactly once")
        check(fresh.count("fabric-node") == 1,
              "a fresh instance admission queries host trust exactly once")
        check(len(fresh) == 2,
              "a fresh instance admission makes no other trust query")
        check(forensic(trust_root) == before_trust,
              "instance admission writes nothing to the Trust Plane")
        counts = store.counts()
        check(counts["capability-instance"] == 1,
              "instance admission wrote exactly one instance record")
        check(counts["capability-route"] == 0 and counts["capability-selection"] == 0,
              "instance admission creates no route and no selection")

        stored = record_of(store, "capability-instance", "CINST-000001")
        check(stored.get("schema_version") == "schott-platform/v1"
              and stored.get("kind") == "capability-instance",
              "the accepted instance declares its schema identity and version")
        for field, value in (("capability_id", cap.record_id),
                             ("capability_package_id", pkg.record_id),
                             ("capability_host_id", adm.record_id),
                             ("contract_id", con.record_id),
                             ("advertisement_id", adv.record_id),
                             ("admission_decision_id", "TDEC-000001"),
                             ("package_trust_record_id",
                              package_trust.record.record_id),
                             ("host_trust_record_id", host_trust.record.record_id)):
            check(stored.get(field) == value,
                  f"the accepted instance records its {field}")
        check(stored.get("verified_resource_profile") == PROFILE,
              "the accepted instance carries the host's verified profile")
        check(stored.get("effective_scope") == SCOPE,
              "the accepted instance carries its effective scope")
        check(tuple(stored.get("satisfied_contract_versions") or ()) == ("1.0.0",),
              "the accepted instance carries its satisfied contract versions")
        check("superseded_by" not in stored,
              "a fresh instance names no superseded_by")
        evidence = stored.get("evidence") or {}
        for field in ("actor", "approving_authority", "causal_references",
                      "trust_evidence_references", "reason_category",
                      "recorded_at", "request_id", "request_digest"):
            check(field in evidence, f"the accepted instance evidence carries '{field}'")
        check(evidence.get("reason_category") == "instance-admission",
              "a fresh instance admission is recorded as instance-admission")
        check(evidence.get("approving_authority") == OPERATOR,
              "the accepted instance records its approving authority")
        causal = tuple(evidence.get("causal_references") or ())
        for reference in (cap.record_id, con.record_id, pkg.record_id,
                          adm.record_id, adv.record_id):
            check(reference in causal,
                  f"the accepted instance evidence references {reference}")
        trust_refs = tuple(evidence.get("trust_evidence_references") or ())
        check(package_trust.record.record_id in trust_refs
              and host_trust.record.record_id in trust_refs,
              "the accepted instance evidence references both trust records")
        rendered = _yaml.safe_dump(stored)
        for forbidden in ("trust_score", "health_score", "auto_admit",
                          "auto_renew", "auto_failover", "weight",
                          "load_factor", "eligible", "ineligible"):
            check(forbidden not in rendered,
                  f"the accepted instance carries no '{forbidden}'")

        # Exact replay: the original identity, no governed re-evaluation.
        before = forensic(fabric_root)
        allocated = list(store.allocations)
        written = list(store.writes)
        reads = store.reads
        queries = list(DOMAIN_TRUST.calls)
        replayed, error = call("admit_instance", store, trust_store,
                               **dict(base, request_id="i7-inst"))
        check(error is None, "an instance-admission replay raises nothing")
        check(replayed is not None and replayed.outcome == EXACT_REPLAY,
              "a byte-identical instance admission is an exact replay")
        check(replayed is not None and replayed.record_id == "CINST-000001",
              "an instance-admission replay returns the original identity")
        check(store.allocations == allocated and store.writes == written,
              "an instance-admission replay allocates and writes nothing")
        check(store.reads == reads,
              "an instance-admission replay resolves no reference")
        check(DOMAIN_TRUST.calls == queries,
              "an instance-admission replay queries no trust")
        check(forensic(fabric_root) == before,
              "an instance-admission replay leaves the fabric byte-identical")

        # A different request identity is a different decision.
        distinct, error = call("admit_instance", store, trust_store,
                               **dict(base, request_id="i7-inst-again"))
        check(error is None and distinct is not None
              and distinct.outcome == ACCEPTED
              and distinct.record_id == "CINST-000002",
              "identical content under a new request identity admits a second instance")
        check(record_of(store, "capability-instance", "CINST-000001") == stored,
              "the first instance is untouched by the second")

    # --- 2. Every authoritative instance input participates in identity --
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        original, error = call("admit_instance", store, trust_store,
                               **dict(base, request_id="i7-identity"))
        check(error is None and original is not None
              and original.outcome == ACCEPTED,
              "the instance admission establishing a request identity is accepted")
        before = forensic(fabric_root)
        trust_before = forensic(trust_root)
        allocated = list(store.allocations)
        written = list(store.writes)
        counters = sequences_of(fabric_root)
        reads = store.reads
        queries = list(DOMAIN_TRUST.calls)
        INSTANCE_CHANGES = (
            ("actor", "operator:other"),
            ("approving_authority", "operator:other"),
            ("recorded_at", LATER),
            ("evaluated_at", LATER + timedelta(hours=1)),
            ("capability_id", "CAPDEF-9999"),
            ("capability_package_id", "CPKG-9999"),
            ("capability_host_id", "CHOST-9999"),
            ("contract_id", "CCON-9999"),
            ("satisfied_contract_versions", ("1.0.0", "2.0.0")),
            ("verified_resource_profile", {"architecture": "x86-64"}),
            ("admission_decision_id", "TDEC-000002"),
            ("package_trust_record_id", "TREC-999999"),
            ("host_trust_record_id", "TREC-999998"),
            ("admission_scope", dict(SCOPE, permitted_capabilities=["observation"])),
            ("admitted_at", LATER),
            ("admitted_until", YEAR + timedelta(days=1)),
            ("advertisement_id", "CADV-999999"),
            ("endpoint_reference", "https://schai.invalid/summarise"),
            ("provenance", dict(OTHER_PROV)),
            ("supersedes", "CINST-999999"),
            ("notes", "an operator note"),
        )
        for field, value in INSTANCE_CHANGES:
            entries = store.entries
            result, error = call("admit_instance", store, trust_store,
                                 **dict(base, request_id="i7-identity",
                                        **{field: value}))
            check(error is None,
                  f"an instance admission with a changed {field} raises nothing")
            if error is not None:
                continue
            check(result.outcome == CONFLICT and result.reason == CONFLICT_REASON,
                  f"an instance admission reusing its identity with a changed "
                  f"{field} conflicts")
            check(result.request_digest != original.request_digest,
                  f"a changed {field} changes the instance-admission digest")
            check(result.record_id is None,
                  f"a changed {field} on an instance admission names no record")
            check(store.allocations == allocated and store.writes == written,
                  f"a changed {field} on an instance admission allocates and writes nothing")
            check(store.reads == reads,
                  f"a changed {field} on an instance admission resolves no reference")
            check(DOMAIN_TRUST.calls == queries,
                  f"a changed {field} on an instance admission queries no trust")
            check(store.entries == entries + 1,
                  f"a changed {field} on an instance admission enters the section once")
            check(sequences_of(fabric_root) == counters,
                  f"a changed {field} on an instance admission advances no sequence")
            check(forensic(fabric_root) == before,
                  f"a changed {field} on an instance admission changes nothing")
            check(forensic(trust_root) == trust_before,
                  f"a changed {field} on an instance admission leaves trust identical")

    # --- 3. Admission prerequisites, each failing in isolation -----------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        # Real records for every mismatch, so nothing is proved against a fiction.
        other_cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                                     request_id="i7-cap2",
                                                     name="observe a host"))
        other_con = declare_contract(store, **dict(BASE_CONTRACT,
                                                   request_id="i7-con2",
                                                   capability_id=other_cap.record_id))
        other_pkg = declare_package(store, **dict(
            INSTANCE_PACKAGE, request_id="i7-pkg2",
            capability_id=other_cap.record_id, contract_id=other_con.record_id))
        # A second package for the same capability and contract: advertising it
        # names the right contract and the wrong package.
        alt_pkg = declare_package(store, **dict(
            INSTANCE_PACKAGE, request_id="i7-pkg-alt", capability_id=cap.record_id,
            contract_id=con.record_id, package_version="2.0.0"))
        # A package the verified host genuinely cannot satisfy: it asks for more
        # memory than the machine was verified to have. This fixture used to ask
        # for LESS (512 against 8192) and was refused only because comparison
        # was exact equality -- which is the defect capacity semantics fixes, so
        # the case has to be restated to still mean what its name says.
        heavy_pkg = declare_package(store, **dict(
            INSTANCE_PACKAGE, request_id="i7-pkg-heavy", capability_id=cap.record_id,
            contract_id=con.record_id, package_version="3.0.0",
            resource_requirements={"host_memory_mb": 65536,
                                   "architecture": "x86-64"}))
        second_host = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="i7-host2",
            fabric_node_trust_record_id=host_trust.record.record_id))
        alt_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-alt", actor=adm.record_id,
            capability_host_id=adm.record_id,
            capability_package_id=alt_pkg.record_id, contract_id=con.record_id,
            observed_at=STAMP, valid_until=YEAR))
        heavy_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-heavy", actor=adm.record_id,
            capability_host_id=adm.record_id,
            capability_package_id=heavy_pkg.record_id, contract_id=con.record_id,
            observed_at=STAMP, valid_until=YEAR))
        other_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-other", actor=adm.record_id,
            capability_host_id=adm.record_id,
            capability_package_id=other_pkg.record_id,
            contract_id=other_con.record_id, observed_at=STAMP, valid_until=YEAR))
        foreign_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-foreign", actor=second_host.record_id,
            capability_host_id=second_host.record_id,
            capability_package_id=pkg.record_id, contract_id=con.record_id,
            observed_at=STAMP, valid_until=YEAR))
        # Both windows are registered from inside themselves -- a claim made
        # while it was live -- and only go stale, or become not-yet-valid,
        # relative to the instant the admission is evaluated at. Registration
        # refuses a window that never covered its own request, so a claim that
        # was dead on arrival cannot be the fixture for a claim that lapsed.
        stale_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-stale", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id, recorded_at=STAMP - timedelta(days=3),
            observed_at=STAMP - timedelta(days=3),
            valid_until=STAMP - timedelta(days=2)))
        future_adv = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-adv-future", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id, recorded_at=YEAR, observed_at=YEAR,
            valid_until=YEAR + timedelta(days=1)))
        check(all(result.outcome == ACCEPTED for result in (
                  other_cap, other_con, other_pkg, alt_pkg, heavy_pkg, second_host,
                  alt_adv, heavy_adv, other_adv, foreign_adv, stale_adv, future_adv)),
              "the prerequisite-matrix fixtures are all accepted")

        PREREQUISITES = (
            ("an absent capability", NOT_FOUND, "unresolved-reference",
             {"capability_id": "CAPDEF-9999"}),
            ("an absent contract", NOT_FOUND, "unresolved-reference",
             {"contract_id": "CCON-9999"}),
            ("an absent package", NOT_FOUND, "unresolved-reference",
             {"capability_package_id": "CPKG-9999"}),
            ("an absent host", NOT_FOUND, "unresolved-reference",
             {"capability_host_id": "CHOST-9999"}),
            ("an absent advertisement", NOT_FOUND, "unresolved-reference",
             {"advertisement_id": "CADV-999999"}),
            ("no advertisement at all", INVALID, "malformed-operation-content",
             {"advertisement_id": None}),
            ("a contract of another capability", REFUSED,
             "contract-not-of-capability", {"contract_id": other_con.record_id}),
            ("a capability the package does not implement", REFUSED,
             "package-not-of-capability", {"capability_id": other_cap.record_id}),
            ("an advertisement published by another subject", REFUSED,
             "advertisement-not-of-subject", {"advertisement_id": "FOREIGN"}),
            ("an advertisement for another contract", REFUSED,
             "advertisement-not-of-contract", {"advertisement_id": "OTHER"}),
            ("an advertisement for another package", REFUSED,
             "advertisement-not-of-package", {"advertisement_id": "ALT"}),
            ("a package the verified host cannot satisfy", REFUSED,
             "resource-claim-not-verified",
             {"capability_package_id": "HEAVY", "advertisement_id": "HEAVYADV",
              "package_trust_record_id": "HEAVYTRUST"}),
            ("an undeclared contract version", REFUSED, "versions-not-declared",
             {"satisfied_contract_versions": ("2.0.0",)}),
            ("no contract version at all", REFUSED, "versions-not-declared",
             {"satisfied_contract_versions": ()}),
            ("a stale advertisement", REFUSED, "advertisement-not-fresh",
             {"advertisement_id": stale_adv.record_id}),
            ("an advertisement not yet valid", REFUSED, "advertisement-not-fresh",
             {"advertisement_id": future_adv.record_id}),
            ("an admission window already elapsed", REFUSED,
             "admission-window-expired",
             {"admitted_at": STAMP,
              "admitted_until": STAMP + timedelta(hours=1)}),
            ("an admission window that closes before it opens", REFUSED,
             "invalid-validity-window",
             {"admitted_until": STAMP - timedelta(days=1)}),
            ("an admission window of zero length", REFUSED,
             "invalid-validity-window", {"admitted_until": STAMP}),
            ("an admission bound naming no dimension", INVALID,
             "malformed-admission-scope", {"admission_scope": {}}),
            ("an admission bound with an empty dimension", INVALID,
             "malformed-admission-scope",
             {"admission_scope": dict(SCOPE, permitted_operations=[])}),
            ("an admission bound outside both grants", REFUSED,
             "empty-effective-scope",
             {"admission_scope": dict(SCOPE,
                                      permitted_capabilities=["observation"])}),
            ("a resource profile the operator did not verify", REFUSED,
             "resource-claim-not-verified",
             {"verified_resource_profile": {"host_memory_mb": 4096}}),
            ("a data classification outside the declared vocabulary", INVALID,
             "unknown-data-classification",
             {"admission_scope": dict(SCOPE,
                                      permitted_data_classifications=["secret"])}),
            ("no approving authority", INVALID, "missing-approving-authority",
             {"approving_authority": None}),
            ("no actor", INVALID, "missing-actor", {"actor": None}),
            ("an unresolved superseded instance", NOT_FOUND,
             "unresolved-reference", {"supersedes": "CINST-999999"}),
            ("malformed operation content", INVALID,
             "malformed-operation-content", {"provenance": 7}),
            ("a scope that is not a mapping", INVALID,
             "malformed-admission-scope", {"admission_scope": 7}),
            ("a naive admission instant", INVALID, "timestamp-carries-no-offset",
             {"admitted_at": STAMP.replace(tzinfo=None)}),
        )
        FIXTURES = {"FOREIGN": foreign_adv.record_id, "OTHER": other_adv.record_id,
                    "ALT": alt_adv.record_id, "HEAVY": heavy_pkg.record_id,
                    "HEAVYADV": heavy_adv.record_id,
                    "HEAVYTRUST": PACKAGE_TRUST[heavy_pkg.record_id]}
        for index, (description, outcome, reason, overrides) in enumerate(PREREQUISITES):
            overrides = {key: FIXTURES.get(value, value) if isinstance(value, str)
                         else value for key, value in overrides.items()}
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            allocated = list(store.allocations)
            written = list(store.writes)
            counters = sequences_of(fabric_root)
            residue = temporaries(fabric_root)
            result, error = call("admit_instance", store, trust_store,
                                 **dict(base, request_id=f"i7-bad-{index}",
                                        **overrides))
            check(error is None,
                  f"an instance admission with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome,
                  f"an instance admission with {description} returns {outcome}")
            check(result.reason == reason,
                  f"an instance admission with {description} is refused as {reason}")
            check(result.record_id is None and result.record_kind is None,
                  f"an instance admission with {description} names no record")
            check(store.allocations == allocated,
                  f"an instance admission with {description} allocates nothing")
            check(store.writes == written,
                  f"an instance admission with {description} writes nothing")
            check(sequences_of(fabric_root) == counters,
                  f"an instance admission with {description} advances no sequence")
            check(temporaries(fabric_root) == residue,
                  f"an instance admission with {description} leaves no temporary artefact")
            check(forensic(fabric_root) == before,
                  f"an instance admission with {description} leaves the fabric identical")
            check(forensic(trust_root) == trust_before,
                  f"an instance admission with {description} leaves trust identical")
            rendered = str(result.to_dict())
            for token, leak in ((" 0x", "an object address"),
                                ("/tmp/", "a filesystem path"),
                                ("Traceback", "a traceback"),
                                ("object at", "an object repr")):
                check(token not in rendered,
                      f"an instance admission with {description} leaks no {leak}")
            repeated, repeat_error = call("admit_instance", store, trust_store,
                                          **dict(base, request_id=f"i7-bad-{index}",
                                                 **overrides))
            check(repeat_error is None and repeated is not None
                  and repeated.outcome == result.outcome
                  and repeated.reason == result.reason,
                  f"an instance admission with {description} refuses identically twice")

        # Self-admission: the machine cannot admit its own binding.
        for actor_value, approver_value, description in (
                ("node/schai", OPERATOR, "the node as actor"),
                (OPERATOR, "node/schai", "the node as approver"),
                (adm.record_id, OPERATOR, "the host record as actor")):
            before = forensic(fabric_root)
            result, error = call("admit_instance", store, trust_store,
                                 **dict(base, request_id="i7-self",
                                        actor=actor_value,
                                        approving_authority=approver_value))
            check(error is None and result is not None
                  and result.outcome == REFUSED
                  and result.reason == "self-admission",
                  f"an instance admission naming {description} is refused as self-admission")
            check(forensic(fabric_root) == before,
                  f"an instance admission naming {description} writes nothing")

        check(store.counts()["capability-instance"] == 0,
              "no refused instance admission left an instance record")

    # --- 4. Trust integration, package and host separately --------------
    TRUST_FAILURES = (
        ("no-trust-standing", "absent trust"),
        ("trust-expired", "expired trust"),
        ("trust-revoked", "revoked trust"),
        ("trust-not-usable", "quarantined trust"),
        ("trust-unreadable", "malformed trust"),
        ("trust-subject-type-mismatch", "a wrong trust subject type"),
    )


    class SelectiveTrust:
        """Real C3 for one domain, a controlled refusal for the other."""

        def __init__(self, failing_domain, verification):
            self.failing_domain = failing_domain
            self.verification = verification
            self.calls = []

        def __call__(self, store, record_id, *, evaluated_at,
                     expected_subject_type=None):
            self.calls.append(expected_subject_type)
            if expected_subject_type == self.failing_domain:
                return self.verification
            return RELEASED_TRUST_VERIFY_7(
                store, record_id, evaluated_at=evaluated_at,
                expected_subject_type=expected_subject_type)


    for domain, label in (("capability-package", "package"),
                          ("fabric-node", "host")):
        for reason, description in TRUST_FAILURES:
            with TemporaryDirectory() as tmp:
                store = audited(tmp)
                trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
                fabric_root = Path(tmp) / "fabric"
                trust_root = Path(tmp) / "trust"
                cap, con, pkg, adm, adv, base = fabric_ready(
                    tmp, store, trust_store, host_trust, package_trust)
                refusal = trust_adapter.TrustVerification(
                    subject_id="unused", status=trust_adapter.UNVERIFIED,
                    standing=TrustState.UNKNOWN.value,
                    stored_standing=TrustState.UNKNOWN.value,
                    evaluated_at=STAMP.isoformat(), reasons=(reason,))
                selective = SelectiveTrust(domain, refusal)
                admission_module.verify_trust_record = selective
                before = forensic(fabric_root)
                trust_before = forensic(trust_root)
                try:
                    result, error = call("admit_instance", store, trust_store,
                                         **dict(base, request_id="i7-trust"))
                finally:
                    admission_module.verify_trust_record = DOMAIN_TRUST
                check(error is None,
                      f"instance admission with {label} {description} raises nothing")
                if error is not None:
                    continue
                check(result.outcome == REFUSED,
                      f"instance admission with {label} {description} is refused")
                check(result.reason == reason,
                      f"instance admission with {label} {description} keeps the "
                      f"C3 reason {reason}")
                check(result.record_id is None,
                      f"instance admission with {label} {description} creates no instance")
                check(store.counts()["capability-instance"] == 0,
                      f"instance admission with {label} {description} leaves zero instances")
                check(forensic(fabric_root) == before,
                      f"instance admission with {label} {description} changes nothing")
                check(forensic(trust_root) == trust_before,
                      f"instance admission with {label} {description} writes no trust")
                check(selective.calls.count(domain) == 1,
                      f"instance admission consults {label} trust exactly once")
                check(len(selective.calls) <= 2,
                      f"instance admission with {label} {description} makes "
                      f"no other trust query")

    for domain, label in (("capability-package", "package"),
                          ("fabric-node", "host")):
        with TemporaryDirectory() as tmp:
            store = audited(tmp)
            trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
            fabric_root = Path(tmp) / "fabric"
            cap, con, pkg, adm, adv, base = fabric_ready(
                tmp, store, trust_store, host_trust, package_trust)
            unavailable = trust_adapter.TrustVerification(
                subject_id="unused", status=trust_adapter.UNVERIFIED,
                standing=TrustState.UNKNOWN.value,
                stored_standing=TrustState.UNKNOWN.value,
                evaluated_at=STAMP.isoformat(), reasons=("trust-unavailable",))
            selective = SelectiveTrust(domain, unavailable)
            admission_module.verify_trust_record = selective
            before = forensic(fabric_root)
            try:
                result, error = call("admit_instance", store, trust_store,
                                     **dict(base, request_id="i7-unavail"))
            finally:
                admission_module.verify_trust_record = DOMAIN_TRUST
            check(error is None and result is not None
                  and result.outcome == UNAVAILABLE
                  and result.reason == "trust-unavailable",
                  f"an unavailable Trust Plane for the {label} is UNAVAILABLE")
            check(result is not None and result.record_id is None,
                  f"an unavailable Trust Plane for the {label} creates no instance")
            check(forensic(fabric_root) == before,
                  f"an unavailable Trust Plane for the {label} writes nothing")

    # A verified trust record for the wrong Fabric subject.
    for override, description in (
            ({"package_trust_record_id": "HOSTTRUST"}, "package"),
            ({"host_trust_record_id": "PACKAGETRUST"}, "host")):
        with TemporaryDirectory() as tmp:
            store = audited(tmp)
            trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
            fabric_root = Path(tmp) / "fabric"
            cap, con, pkg, adm, adv, base = fabric_ready(
                tmp, store, trust_store, host_trust, package_trust)
            swapped = {"HOSTTRUST": host_trust.record.record_id,
                       "PACKAGETRUST": package_trust.record.record_id}
            overrides = {key: swapped[value] for key, value in override.items()}
            before = forensic(fabric_root)
            result, error = call("admit_instance", store, trust_store,
                                 **dict(base, request_id="i7-swap", **overrides))
            check(error is None and result is not None
                  and result.outcome == REFUSED,
                  f"a {description} trust record for the other subject is refused")
            check(result is not None and result.record_id is None,
                  f"a {description} trust subject mismatch creates no instance")
            check(forensic(fabric_root) == before,
                  f"a {description} trust subject mismatch writes nothing")

    # --- 5. Route creation and supersession ------------------------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        first, _ = call("admit_instance", store, trust_store,
                        **dict(base, request_id="i7-r-inst-1"))
        second, _ = call("admit_instance", store, trust_store,
                         **dict(base, request_id="i7-r-inst-2"))
        check(first is not None and second is not None
              and first.record_id == "CINST-000001"
              and second.record_id == "CINST-000002",
              "two instances exist for the route matrix")
        route_base = dict(BASE_ROUTE, capability_id=cap.record_id,
                          contract_id=con.record_id,
                          candidate_instances=("CINST-000002", "CINST-000001"))
        entries = store.entries
        queries = list(DOMAIN_TRUST.calls)
        route, error = call("create_route", store,
                            **dict(route_base, request_id="i7-route"))
        check(error is None, "route creation raises nothing")
        check(route is not None and route.outcome == ACCEPTED
              and route.record_kind == "capability-route"
              and route.record_id == "CROUTE-0001",
              "route creation allocates CROUTE-0001 through C1")
        check(store.entries == entries + 1,
              "route creation enters the critical section exactly once")
        check(DOMAIN_TRUST.calls == queries,
              "route creation queries no trust")
        stored_route = record_of(store, "capability-route", "CROUTE-0001")
        check(stored_route.get("candidate_instances") == ["CINST-000002",
                                                          "CINST-000001"],
              "the route preserves the human-written candidate order exactly")
        check(stored_route.get("route_version") == 1,
              "the route records its declared version")
        check(stored_route.get("locality") == "operator-controlled-only"
              and stored_route.get("data_classification") == "internal",
              "the route records its request class")
        route_evidence = stored_route.get("evidence") or {}
        check(route_evidence.get("reason_category") == "route-change",
              "a fresh route is recorded as a route-change")
        for reference in (cap.record_id, con.record_id, "CINST-000001",
                          "CINST-000002"):
            check(reference in tuple(route_evidence.get("causal_references") or ()),
                  f"the accepted route evidence references {reference}")
        check(store.counts()["capability-selection"] == 0,
              "route creation creates no selection record")

        # Order is authoritative: the reversed list is a different request.
        before = forensic(fabric_root)
        reordered, error = call("create_route", store,
                                **dict(route_base, request_id="i7-route",
                                       candidate_instances=("CINST-000001",
                                                            "CINST-000002")))
        check(error is None and reordered is not None
              and reordered.outcome == CONFLICT
              and reordered.reason == CONFLICT_REASON,
              "reordering the candidate list under one request identity conflicts")
        check(forensic(fabric_root) == before,
              "a reordered candidate list writes nothing")
        replayed, error = call("create_route", store,
                               **dict(route_base, request_id="i7-route"))
        check(error is None and replayed is not None
              and replayed.outcome == EXACT_REPLAY
              and replayed.record_id == "CROUTE-0001",
              "a byte-identical route request replays the original route")
        independent, error = call("create_route", store,
                                  **dict(route_base, request_id="i7-route-2"))
        check(error is None and independent is not None
              and independent.outcome == ACCEPTED
              and independent.record_id == "CROUTE-0002",
              "identical route content under a new request identity is a new route")

        ROUTE_REFUSALS = (
            ("an unresolved candidate", NOT_FOUND, "unresolved-reference",
             {"candidate_instances": ("CINST-999999",)}),
            ("a malformed candidate identity", INVALID, "malformed-operation-content",
             {"candidate_instances": ("",)}),
            ("a candidate that is not a released identity", INVALID,
             "malformed-operation-content", {"candidate_instances": ("CINST-1",)}),
            ("a duplicated candidate", REFUSED, "duplicate-candidate",
             {"candidate_instances": ("CINST-000001", "CINST-000001")}),
            ("no candidate at all", REFUSED, "no-declared-candidate",
             {"candidate_instances": ()}),
            ("an absent capability", NOT_FOUND, "unresolved-reference",
             {"capability_id": "CAPDEF-9999"}),
            ("an absent contract", NOT_FOUND, "unresolved-reference",
             {"contract_id": "CCON-9999"}),
            ("a route version below one", REFUSED, "invalid-route-version",
             {"route_version": 0}),
            ("a non-integer route version", INVALID, "invalid-route-version",
             {"route_version": "1"}),
            ("no accepted contract version", REFUSED, "versions-not-declared",
             {"accepted_contract_versions": ()}),
            ("a half-declared overlap window", INVALID, "malformed-overlap-window",
             {"overlap_starts_at": STAMP}),
            ("an overlap window with nothing to overlap", REFUSED,
             "overlap-window-without-supersession",
             {"overlap_starts_at": STAMP, "overlap_ends_at": LATER}),
            ("an unresolved prior route", NOT_FOUND, "unresolved-reference",
             {"supersedes": "CROUTE-9999"}),
        )
        for index, (description, outcome, reason, overrides) in enumerate(ROUTE_REFUSALS):
            before = forensic(fabric_root)
            allocated = list(store.allocations)
            counters = sequences_of(fabric_root)
            result, error = call("create_route", store,
                                 **dict(route_base, request_id=f"i7-route-bad-{index}",
                                        **overrides))
            check(error is None, f"a route with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome and result.reason == reason,
                  f"a route with {description} is refused as {reason}")
            check(result.record_id is None,
                  f"a route with {description} names no record")
            check(store.allocations == allocated,
                  f"a route with {description} allocates nothing")
            check(sequences_of(fabric_root) == counters,
                  f"a route with {description} advances no sequence")
            check(forensic(fabric_root) == before,
                  f"a route with {description} writes nothing")

        # A candidate that is not of this route's capability or contract.
        other_cap = declare_capability(store, **dict(BASE_CAPABILITY,
                                                     request_id="i7-r-cap2",
                                                     name="observe a host"))
        other_con = declare_contract(store, **dict(BASE_CONTRACT,
                                                   request_id="i7-r-con2",
                                                   capability_id=other_cap.record_id))
        before = forensic(fabric_root)
        wrong_owner, error = call("create_route", store,
                                  **dict(route_base, request_id="i7-route-owner",
                                         capability_id=other_cap.record_id,
                                         contract_id=other_con.record_id))
        check(error is None and wrong_owner is not None
              and wrong_owner.outcome == REFUSED
              and wrong_owner.reason == "candidate-not-of-route",
              "a candidate of another capability and contract is refused")
        check(forensic(fabric_root) == before,
              "a candidate of the wrong capability writes nothing")

        # Supersession: a new version, the prior left exactly as written. A
        # declared overlap asserts that old and new coexist, so the cutover
        # carries one prior candidate and introduces one that is new.
        third, _ = call("admit_instance", store, trust_store,
                        **dict(base, request_id="i7-r-inst-3"))
        check(third is not None and third.record_id == "CINST-000003",
              "a third binding exists for the declared overlap")
        prior = record_of(store, "capability-route", "CROUTE-0001")
        prior_forensic = forensic(fabric_root / "capability-routes")
        superseded, error = call("create_route", store, **dict(
            route_base, request_id="i7-route-v2", route_version=2,
            candidate_instances=("CINST-000001", "CINST-000003"),
            overlap_starts_at=STAMP, overlap_ends_at=LATER,
            supersedes="CROUTE-0001"))
        check(error is None and superseded is not None
              and superseded.outcome == ACCEPTED
              and superseded.record_id == "CROUTE-0003",
              "a superseding route creates a new route record")
        new_route = record_of(store, "capability-route", "CROUTE-0003")
        check(new_route.get("supersedes") == "CROUTE-0001",
              "the superseding route names the route it supersedes")
        check(new_route.get("route_version") == 2,
              "the superseding route carries its own version")
        check((new_route.get("evidence") or {}).get("reason_category")
              == "supersession",
              "a superseding route is recorded as a supersession")
        check("CROUTE-0001" in tuple((new_route.get("evidence") or {}).get(
                  "causal_references") or ()),
              "the superseding route's evidence references the prior route")
        check(record_of(store, "capability-route", "CROUTE-0001") == prior,
              "the superseded route is unchanged")
        check("superseded_by" not in record_of(store, "capability-route",
                                                        "CROUTE-0001"),
              "the superseded route was not edited to point at its successor")
        check(new_route.get("overlap_window") == {"starts_at": STAMP.isoformat(),
                                                  "ends_at": LATER.isoformat()},
              "the superseding route carries its declared overlap window")

        SUPERSESSION_REFUSALS = (
            ("a prior route of another capability", REFUSED,
             "supersedes-different-subject",
             {"capability_id": other_cap.record_id,
              "contract_id": other_con.record_id,
              "candidate_instances": (),
              "supersedes": "CROUTE-0001", "route_version": 2}),
            ("a version that does not increase", REFUSED, "invalid-route-version",
             {"supersedes": "CROUTE-0001", "route_version": 1}),
            ("a version that decreases", REFUSED, "invalid-route-version",
             {"supersedes": "CROUTE-0003", "route_version": 1}),
        )
        for index, (description, outcome, reason, overrides) in enumerate(
                SUPERSESSION_REFUSALS):
            before = forensic(fabric_root)
            result, error = call("create_route", store, **dict(
                route_base, request_id=f"i7-sup-bad-{index}", **overrides))
            check(error is None, f"a route superseding with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome,
                  f"a route superseding with {description} returns {outcome}")
            check(result.record_id is None,
                  f"a route superseding with {description} names no record")
            check(forensic(fabric_root) == before,
                  f"a route superseding with {description} writes nothing")
        check(forensic(fabric_root / "capability-routes") != prior_forensic,
              "the route directory grew by supersession rather than by edit")
        check(store.counts()["capability-selection"] == 0,
              "the whole route matrix created no selection record")

    # --- 6. CINST commits before CROUTE, under separate identities -------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        original_instance, _ = call("admit_instance", store, trust_store,
                                    **dict(base, request_id="i7-cut-inst-1"))
        route_base = dict(BASE_ROUTE, capability_id=cap.record_id,
                          contract_id=con.record_id,
                          candidate_instances=("CINST-000001",))
        original_route, _ = call("create_route", store,
                                 **dict(route_base, request_id="i7-cut-route-1"))
        check(original_instance is not None and original_route is not None
              and original_instance.outcome == ACCEPTED
              and original_route.outcome == ACCEPTED,
              "the cutover starting state is admitted and routed")

        # The declared supersession: a new instance, then a new route.
        written_before = list(store.writes)
        new_instance, _ = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-cut-inst-2", supersedes="CINST-000001"))
        check(new_instance is not None and new_instance.outcome == ACCEPTED
              and new_instance.record_id == "CINST-000002",
              "the superseding instance is admitted first")
        check(store.writes[len(written_before):] == ["capability-instance"],
              "the superseding instance is the only record written so far")
        check(record_of(store, "capability-instance", "CINST-000002").get(
                  "supersedes") == "CINST-000001",
              "the superseding instance names the instance it supersedes")
        check((record_of(store, "capability-instance", "CINST-000002").get(
                  "evidence") or {}).get("reason_category") == "supersession",
              "a superseding instance is recorded as a supersession")
        unreferenced = record_of(store, "capability-instance", "CINST-000002")
        routes_before = store.counts()["capability-route"]
        check(routes_before == 1,
              "the new instance exists while no new route names it")
        new_route, _ = call("create_route", store, **dict(
            route_base, request_id="i7-cut-route-2", route_version=2,
            candidate_instances=("CINST-000002",), supersedes="CROUTE-0001"))
        check(new_route is not None and new_route.outcome == ACCEPTED,
              "the cutover route version is created second")
        order = store.writes[len(written_before):]
        check(order == ["capability-instance", "capability-route"],
              f"the CINST commits before the CROUTE (observed {order})")
        check(record_of(store, "capability-instance", "CINST-000001") is not None
              and record_of(store, "capability-route", "CROUTE-0001") is not None,
              "both superseded records remain readable through the overlap window")
        check(record_of(store, "capability-instance", "CINST-000002")
              == unreferenced,
              "creating the route did not alter the instance it names")

        # One identity may not serve both operations.
        before = forensic(fabric_root)
        crossed, error = call("create_route", store, **dict(
            route_base, request_id="i7-cut-inst-2", route_version=3,
            candidate_instances=("CINST-000002",)))
        check(error is None and crossed is not None
              and crossed.outcome == CONFLICT
              and crossed.reason == CONFLICT_REASON,
              "reusing the instance request identity for a route is conflicting reuse")
        crossed_back, error = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-cut-route-2"))
        check(error is None and crossed_back is not None
              and crossed_back.outcome == CONFLICT
              and crossed_back.reason == CONFLICT_REASON,
              "reusing the route request identity for an instance is conflicting reuse")
        check(forensic(fabric_root) == before,
              "neither crossed request identity wrote anything")
        check(original_instance.request_digest != original_route.request_digest,
              "neither request digest is derived from the other")

        # A failed route operation leaves the accepted instance intact.
        instance_before = record_of(store, "capability-instance", "CINST-000002")
        failed, error = call("create_route", store, **dict(
            route_base, request_id="i7-cut-route-fail", route_version=3,
            candidate_instances=("CINST-999999",)))
        check(error is None and failed is not None and failed.outcome == NOT_FOUND,
              "a route naming a missing instance is refused")
        check(record_of(store, "capability-instance", "CINST-000002")
              == instance_before,
              "a failed route operation leaves the accepted instance byte-identical")
        check(store.counts()["capability-instance"] == 2,
              "a failed route operation rolls back no instance")

    # --- 7. Lifecycle: derived events write nothing ----------------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(
            tmp, node_expiration=LATER, package_expiration=LATER)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        admitted, _ = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-life", evaluated_at=STAMP + timedelta(hours=1),
            admitted_until=LATER))
        check(admitted is not None and admitted.outcome == ACCEPTED,
              "the lifecycle fixture admits an instance")
        settled = forensic(fabric_root)
        settled_trust = forensic(trust_root)
        allocated = list(store.allocations)
        instance_record = record_of(store, "capability-instance", "CINST-000001")

        # Every clock lapsing is an observation. None of them writes.
        AFTER = YEAR + timedelta(days=1)
        DERIVED = (
            ("advertisement validity lapsing",
             lambda: call("admit_instance", store, trust_store,
                          **dict(base, request_id="i7-expired-adv",
                                 evaluated_at=AFTER, admitted_until=AFTER
                                 + timedelta(days=1)))),
            ("admission expiry lapsing",
             lambda: call("admit_instance", store, trust_store,
                          **dict(base, request_id="i7-expired-adm",
                                 admitted_at=STAMP - timedelta(days=9),
                                 admitted_until=STAMP - timedelta(days=8)))),
            ("trust expiry lapsing",
             lambda: call("admit_instance", store, trust_store,
                          **dict(base, request_id="i7-expired-trust",
                                 evaluated_at=YEAR,
                                 admitted_until=YEAR + timedelta(days=2)))),
        )
        for description, operation in DERIVED:
            before_writes = list(store.writes)
            result, error = operation()
            check(error is None, f"{description} raises nothing")
            if error is not None:
                continue
            check(result.record_id is None,
                  f"{description} creates no authoritative record")
            check(store.writes == before_writes, f"{description} writes nothing")
            check(store.allocations == allocated,
                  f"{description} allocates nothing")
            check(forensic(fabric_root) == settled,
                  f"{description} leaves the fabric byte-identical")
            check(forensic(trust_root) == settled_trust,
                  f"{description} leaves the Trust Plane byte-identical")

        # A host disappearing, returning, and advertising afresh.
        check(forensic(fabric_root) == settled,
              "host disappearance changes no authoritative record")
        # The host returns and speaks at YEAR, so that is when it records the
        # claim as well: a return that published a window it could not yet
        # have observed would be describing a future it has not reached.
        revived = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-revive", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id, recorded_at=YEAR, observed_at=YEAR,
            valid_until=YEAR + timedelta(days=1)))
        check(revived.outcome == ACCEPTED,
              "a returning host may publish a fresh advertisement")
        check(store.counts()["capability-instance"] == 1,
              "a fresh advertisement creates no instance and revives none")
        check(record_of(store, "capability-instance", "CINST-000001")
              == instance_record,
              "a fresh advertisement leaves the lapsed instance byte-identical")
        check(forensic(trust_root) == settled_trust,
              "a fresh advertisement writes nothing to the Trust Plane")

        # Re-admission is a new decision under a new request identity.
        readmitted, error = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-readmit", evaluated_at=YEAR,
            advertisement_id=revived.record_id, admitted_at=YEAR,
            admitted_until=YEAR + timedelta(days=30)))
        check(error is None and readmitted is not None,
              "a re-admission attempt raises nothing")
        check(readmitted is not None and readmitted.outcome == REFUSED
              and readmitted.reason == "trust-expired",
              "re-admission is evaluated against then-current trust evidence")
        check(store.counts()["capability-instance"] == 1,
              "re-admission against expired trust creates no instance")

    # --- 8. Withdrawal is a decision, and it edits nothing ---------------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        admitted, _ = call("admit_instance", store, trust_store,
                           **dict(base, request_id="i7-w-inst"))
        check(admitted is not None and admitted.outcome == ACCEPTED,
              "the withdrawal fixture admits an instance")
        prior_host = record_of(store, "capability-host", adm.record_id)
        prior_instance = record_of(store, "capability-instance", "CINST-000001")
        trust_before = forensic(trust_root)
        queries = list(DOMAIN_TRUST.calls)
        entries = store.entries
        withdrawn, error = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-withdraw",
            capability_host_id=adm.record_id,
            notes="withdrawn from service by operator decision"))
        check(error is None, "a governed withdrawal raises nothing")
        check(withdrawn is not None and withdrawn.outcome == ACCEPTED
              and withdrawn.record_kind == "capability-host"
              and withdrawn.record_id == "CHOST-0002",
              "withdrawal creates a new host record through C1")
        check(store.entries == entries + 1,
              "withdrawal enters the critical section exactly once")
        check(DOMAIN_TRUST.calls == queries,
              "withdrawal is a decision and queries no trust")
        check(forensic(trust_root) == trust_before,
              "withdrawal writes nothing to the Trust Plane")
        successor_id = withdrawn.record_id
        successor = record_of(store, "capability-host", successor_id)
        check(successor.get("availability_intent") == "withheld",
              "the withdrawal record declares the operator's availability intent")
        check(successor.get("supersedes") == adm.record_id,
              "the withdrawal record names the host record it supersedes")
        check((successor.get("evidence") or {}).get("reason_category")
              == "supersession",
              "a withdrawal is recorded as a supersession of the prior record")
        check(successor.get("node_identity_reference")
              == prior_host.get("node_identity_reference"),
              "the withdrawal record describes the same machine")
        check(successor.get("fabric_node_trust_record_id")
              == prior_host.get("fabric_node_trust_record_id"),
              "the withdrawal record references the same trust record")
        check(successor.get("verified_resource_profile")
              == prior_host.get("verified_resource_profile"),
              "the withdrawal record carries the same verified profile")
        check(record_of(store, "capability-host", adm.record_id) == prior_host,
              "the withdrawn host record is byte-identical and still readable")
        check("superseded_by" not in record_of(store, "capability-host",
                                                        adm.record_id),
              "the withdrawn host record was not edited to point forward")
        check(record_of(store, "capability-instance", "CINST-000001")
              == prior_instance,
              "withdrawal edits no instance record")
        check(store.counts()["capability-instance"] == 1,
              "withdrawal deletes no instance")

        # Retired stays retired: return and advertisement change nothing.
        settled = forensic(fabric_root)
        # A claim cites the declaration current for the machine, which the
        # withdrawal moved. Retaining the claim is not authority to admit: the
        # subject may still say what it holds while it is out of service.
        stale_claim = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-w-stale", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id))
        check(stale_claim.outcome == REFUSED
              and stale_claim.reason == "host-record-superseded",
              "a claim citing a superseded declaration is refused")
        check(forensic(fabric_root) == settled,
              "a claim citing a superseded declaration writes nothing")
        returned = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-w-return", actor=successor_id,
            capability_host_id=successor_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id))
        check(returned.outcome == ACCEPTED,
              "a withdrawn host's return is still recorded as a claim")
        check(record_of(store, "capability-host", "CHOST-0002") == successor,
              "a returning host does not reactivate the withdrawal decision")
        check(record_of(store, "capability-instance", "CINST-000001")
              == prior_instance,
              "a returning host does not reactivate the retired instance")
        check(store.counts()["capability-host"] == 2,
              "a returning host writes no host record of its own")

        # Withdrawal replay and conflict, and no self-withdrawal.
        replayed, error = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-withdraw",
            capability_host_id=adm.record_id,
            notes="withdrawn from service by operator decision"))
        check(error is None and replayed is not None
              and replayed.outcome == EXACT_REPLAY
              and replayed.record_id == "CHOST-0002",
              "a byte-identical withdrawal replays exactly")
        conflicting, error = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-withdraw",
            capability_host_id=adm.record_id, availability_intent="draining",
            notes="withdrawn from service by operator decision"))
        check(error is None and conflicting is not None
              and conflicting.outcome == CONFLICT
              and conflicting.reason == CONFLICT_REASON,
              "a changed availability intent under one identity conflicts")
        WITHDRAWAL_REFUSALS = (
            ("an absent host", NOT_FOUND, "unresolved-reference",
             {"capability_host_id": "CHOST-9999"}),
            ("no approving authority", INVALID, "missing-approving-authority",
             {"approving_authority": None}),
            ("no actor", INVALID, "missing-actor", {"actor": None}),
            ("an availability intent outside the vocabulary", INVALID,
             "unknown-availability-intent", {"availability_intent": ""}),
            ("the intent already declared", REFUSED,
             "availability-intent-unchanged", {"availability_intent": "withheld"}),
            ("a return to service", REFUSED,
             "return-to-service-requires-refresh",
             {"availability_intent": "in-service"}),
            ("the host withdrawing itself", REFUSED, "actor-is-the-subject",
             {"actor": "node/schai"}),
        )
        before = forensic(fabric_root)
        for index, (description, outcome, reason, overrides) in enumerate(
                WITHDRAWAL_REFUSALS):
            allocated = list(store.allocations)
            # The head moved when the withdrawal committed; a decision about
            # a machine addresses the declaration that is current for it.
            fields = dict(BASE_WITHDRAWAL, request_id=f"i7-w-bad-{index}",
                          capability_host_id=withdrawn.record_id)
            fields.update(overrides)
            result, error = call("withdraw_subject", store, **fields)
            check(error is None, f"a withdrawal with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome and result.reason == reason,
                  f"a withdrawal with {description} is refused as {reason}")
            check(result.record_id is None,
                  f"a withdrawal with {description} names no record")
            check(store.allocations == allocated,
                  f"a withdrawal with {description} allocates nothing")
            check(forensic(fabric_root) == before,
                  f"a withdrawal with {description} writes nothing")

    # --- 9. Digest routes are declared per operation ------------------------
    # Increments 1 to 6 keep the accepted helper exactly; the operations added
    # here take the narrower prepare-once route, which accepts less. A route
    # is stated at every call site so a new operation cannot inherit one.
    import ast as _ast
    ADMISSION_TREE = _ast.parse(
        (root / "tools" / "fabric" / "admission.py").read_text(encoding="utf-8"))
    ROUTES = {}
    DELEGATES = {}
    for _node in _ast.walk(ADMISSION_TREE):
        if not isinstance(_node, _ast.FunctionDef):
            continue
        for _call in _ast.walk(_node):
            if not isinstance(_call, _ast.Call) or not isinstance(_call.func, _ast.Name):
                continue
            if _call.func.id == "_governed":
                for _kw in _call.keywords:
                    if _kw.arg == "digest_route":
                        ROUTES[_node.name] = _kw.value.id
            elif _call.func.id.startswith("_") and not _node.name.startswith("_"):
                DELEGATES[_node.name] = _call.func.id
    # An operation that reaches the boundary through a shared helper takes the
    # route that helper declares, and is asserted under its own name.
    for _name, _helper in DELEGATES.items():
        if _name not in ROUTES and _helper in ROUTES:
            ROUTES[_name] = ROUTES[_helper]
    ROUTES = {name: route for name, route in ROUTES.items()
              if not name.startswith("_")}
    EXPECTED_ROUTES = {
        "declare_capability": "LEGACY_DIGEST",
        "declare_contract": "LEGACY_DIGEST",
        "declare_package": "LEGACY_DIGEST",
        "admit_subject": "LEGACY_DIGEST",
        "register_advertisement": "LEGACY_DIGEST",
        "admit_instance": "PREPARED_DIGEST",
        "create_route": "PREPARED_DIGEST",
        "withdraw_subject": "PREPARED_DIGEST",
        "refresh_subject": "PREPARED_DIGEST",
        "withdraw_instance": "PREPARED_DIGEST",
        "retire_instance": "PREPARED_DIGEST",
    }
    check(len(ROUTES) == 11, f"eleven governed operations declare a digest route ({len(ROUTES)})")
    for name, route in sorted(EXPECTED_ROUTES.items()):
        check(ROUTES.get(name) == route,
              f"{name} declares {route}")
    check(sum(1 for r in ROUTES.values() if r == "LEGACY_DIGEST") == 5,
          "exactly five operations take the accepted legacy route")
    check(sum(1 for r in ROUTES.values() if r == "PREPARED_DIGEST") == 6,
          "exactly six operations take the prepared route")
    check(_ast.parse("digest_route").body and "digest_route" in
          [a.arg for a in next(n for n in _ast.walk(ADMISSION_TREE)
                               if isinstance(n, _ast.FunctionDef)
                               and n.name == "_governed").args.kwonlyargs],
          "_governed takes the digest route as a keyword with no default")
    check(next(n for n in _ast.walk(ADMISSION_TREE) if isinstance(n, _ast.FunctionDef)
               and n.name == "_governed").args.kw_defaults[-1] is None,
          "the digest route has no default a new operation could inherit")

    # --- 10. The accepted helper is unchanged, and both routes agree --------
    from tools.fabric.request_identity import (  # noqa: E402
        compute_request_digest as LEGACY_DIGEST_FN,
        prepare_and_compute_request_digest as PREPARED_DIGEST_FN,
    )
    import tools.fabric.request_identity as identity_module  # noqa: E402

    LEGACY_FIXTURES = (
        ("declare-contract", {"capability_id": "CAPDEF-0001", "effect_class": "read-only"}),
        ("declare-contract", {"value": 1}),
        ("declare-contract", {"value": "1"}),
        ("declare-contract", {"text": "value", "count": 7, "ratio": 1.5,
                              "flag": True, "absent": None,
                              "nested": {"inner": ["a", "b"]}}),
        ("create-route", {"candidate_instances": ["CINST-000001", "CINST-000002"]}),
        ("declare-capability", {"contract_ids": ["b", "a", "c"]}),
        ("declare-package", {"satisfied_contract_versions": ["2.0.0", "1.0.0"]}),
        ("declare-contract", {"failure_modes": [], "compatible_with": []}),
        ("admit-subject", {"transport_metadata": {"peer": "10.0.0.1"},
                           "node_identity_reference": "node/schai"}),
    )
    for operation, inputs in LEGACY_FIXTURES:
        legacy = LEGACY_DIGEST_FN(operation, inputs)
        check(PREPARED_DIGEST_FN(operation, inputs) == legacy,
              f"both routes agree on the digest for {operation} {sorted(inputs)}")
        check(legacy.startswith("sha256:") and len(legacy) == 71,
              f"the accepted digest convention holds for {operation} {sorted(inputs)}")
    check(LEGACY_DIGEST_FN("declare-capability", {"contract_ids": ["b", "a"]})
          == LEGACY_DIGEST_FN("declare-capability", {"contract_ids": ["a", "b"]}),
          "the accepted helper still ignores unordered input order")

    # The prepared route accepts less, and says so rather than hashing it.
    NARROWER = (
        ({"contract_ids": [7]}, "a numeric unordered member"),
        ({"contract_ids": [["a"]]}, "a container unordered member"),
        ({"satisfied_contract_versions": [None]}, "an absent unordered member"),
    )
    for inputs, description in NARROWER:
        accepted_legacy = True
        try:
            LEGACY_DIGEST_FN("declare-capability", inputs)
        except FabricError:
            accepted_legacy = False
        check(accepted_legacy,
              f"the accepted helper still accepts {description}")
        refuses_prepared = False
        try:
            PREPARED_DIGEST_FN("declare-capability", inputs)
        except FabricError:
            refuses_prepared = True
        check(refuses_prepared, f"the prepared route refuses {description}")

    # --- 11. Caller content is visited once, and the bytes hashed are the
    #         bytes validated -----------------------------------------------
    class Counting(dict):
        """A mapping that counts how often anything walks it."""

        visits = 0

        def items(self):
            type(self).visits += 1
            return super().items()

        def __iter__(self):
            type(self).visits += 1
            return super().__iter__()

    class OnceOnly(dict):
        """Answers once, then refuses. A second walk would be a defect."""

        visits = 0

        def items(self):
            type(self).visits += 1
            if type(self).visits > 1:
                raise RuntimeError("this container may be read exactly once")
            return super().items()

    class Shifting(dict):
        """Yields one set of members, then another."""

        visits = 0

        def items(self):
            type(self).visits += 1
            payload = {"value": "first"} if type(self).visits == 1 else {"value": "second"}
            return payload.items()

    Counting.visits = 0
    counted = PREPARED_DIGEST_FN("declare-contract", {"provenance": Counting(a="b")})
    check(Counting.visits == 1,
          f"the prepared route walks a caller's mapping exactly once ({Counting.visits})")
    check(counted == PREPARED_DIGEST_FN("declare-contract", {"provenance": {"a": "b"}}),
          "walking it once produces the digest of what it contained")

    OnceOnly.visits = 0
    once, once_error = attempted(
        lambda: PREPARED_DIGEST_FN("declare-contract", {"provenance": OnceOnly(a="b")}))
    check(once_error is None and once is not None,
          "a container that may be read once is enough for the prepared route")
    check(OnceOnly.visits == 1,
          f"a read-once container is read exactly once ({OnceOnly.visits})")

    Shifting.visits = 0
    shifting = PREPARED_DIGEST_FN("declare-contract", {"provenance": Shifting()})
    check(Shifting.visits == 1, "a shifting container is walked once")
    check(shifting == PREPARED_DIGEST_FN("declare-contract",
                                         {"provenance": {"value": "first"}}),
          "the bytes hashed are the bytes that were validated")

    class Exploding(dict):
        def items(self):
            raise RuntimeError("this container refuses to be read")

    hostile, hostile_error = attempted(
        lambda: PREPARED_DIGEST_FN("declare-contract", {"provenance": Exploding()}))
    check(hostile_error is not None and isinstance(hostile_error, FabricError),
          "a hostile container is named as uncanonicalisable, not propagated")
    check("RuntimeError" not in str(hostile_error)
          and "refuses to be read" not in str(hostile_error),
          "the refusal carries nothing the hostile container said")

    cyclic = {}
    cyclic["self"] = cyclic
    _, cyclic_error = attempted(
        lambda: PREPARED_DIGEST_FN("declare-contract", {"provenance": cyclic}))
    check(isinstance(cyclic_error, FabricError),
          "a cyclic mapping is refused rather than recursed forever")

    # --- 12. The prepared representation cannot be supplied or forged -------
    check(not hasattr(identity_module, "PreparedRequestDigestInput"),
          "no public prepared type crosses the module boundary")
    check(not hasattr(identity_module, "prepare_request_digest_input"),
          "no admission-facing preparation function returns a prepared object")
    check(not hasattr(identity_module, "compute_prepared_request_digest"),
          "no admission-facing function accepts a prepared object")
    check("prepare_and_compute_request_digest" in dir(identity_module),
          "the whole supported surface is one function taking authoritative inputs")
    PREPARED_TYPE = identity_module._PreparedRequestDigestInput
    check([f.name for f in dataclasses.fields(PREPARED_TYPE)]
          == ["_token", "_canonical_bytes"],
          "the prepared type carries bytes and a token, and no separate metadata")
    check("canonical_bytes" not in inspect.signature(
              identity_module.prepare_and_compute_request_digest).parameters,
          "no supported parameter accepts canonical bytes")

    forged, forged_error = attempted(
        lambda: PREPARED_TYPE(object(), b"forged"))
    check(isinstance(forged_error, FabricError),
          "a prepared object built without the preparation token is refused")
    MISUSE = (
        (None, "nothing at all"),
        ("not prepared", "a wrong object type"),
        (PREPARED_TYPE(identity_module._PREPARATION, b"{}"), "genuine bytes"),
    )

    class Subclassed(PREPARED_TYPE):
        pass

    HASH_CALLS = []
    RELEASED_HASH = identity_module._hash_prepared_request_digest

    def counting_hash(prepared):
        HASH_CALLS.append(1)
        return RELEASED_HASH(prepared)

    identity_module._hash_prepared_request_digest = counting_hash
    try:
        for candidate, description in MISUSE[:2]:
            before_calls = len(HASH_CALLS)
            _, misuse_error = attempted(lambda: RELEASED_HASH(candidate))
            check(isinstance(misuse_error, FabricError),
                  f"hashing {description} is refused as a fabric error")
            check(len(HASH_CALLS) == before_calls,
                  f"hashing {description} never reaches the released hash")
        _, subclass_error = attempted(
            lambda: RELEASED_HASH(Subclassed(identity_module._PREPARATION, b"{}")))
        check(isinstance(subclass_error, FabricError),
              "a subclass of the prepared type is refused by exact type")
        genuine = RELEASED_HASH(MISUSE[2][0])
        check(genuine == f"sha256:{hashlib.sha256(b'{}').hexdigest()}",
              "a genuine prepared object hashes exactly its stored bytes")

        # A malformed nested value enters no hashing function and no store.
        with TemporaryDirectory() as tmp:
            store = audited(tmp)
            trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
            fabric_root = Path(tmp) / "fabric"
            trust_root = Path(tmp) / "trust"
            cap, con, pkg, adm, adv, base = fabric_ready(
                tmp, store, trust_store, host_trust, package_trust)
            accepted, _ = call("admit_instance", store, trust_store,
                               **dict(base, request_id="i7-prepared"))
            check(accepted is not None and accepted.outcome == ACCEPTED,
                  "the prepared-path regression establishes an accepted request")
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            counters = sequences_of(fabric_root)
            allocated = list(store.allocations)
            written = list(store.writes)
            reads = store.reads
            queries = list(DOMAIN_TRUST.calls)
            entries = store.entries
            HASH_CALLS.clear()
            REPLAY_CALLS = []
            released_replay = admission_module.replay_lookup

            def counting_replay(*args, **kwargs):
                REPLAY_CALLS.append(1)
                return released_replay(*args, **kwargs)

            admission_module.replay_lookup = counting_replay
            try:
                malformed, malformed_error = call(
                    "admit_instance", store, trust_store,
                    **dict(base, request_id="i7-prepared",
                           provenance={"nested": {"deep": {1, 2}}}))
            finally:
                admission_module.replay_lookup = released_replay
            check(malformed_error is None,
                  "a malformed nested value raises nothing out of the boundary")
            check(malformed is not None and malformed.outcome == INVALID
                  and malformed.reason == MALFORMED_CONTENT,
                  "a malformed nested value is controlled malformed content")
            check(malformed is not None and malformed.outcome != EXACT_REPLAY,
                  "a malformed nested value is never an exact replay")
            check(malformed is not None and malformed.outcome != CONFLICT,
                  "a malformed nested value is never a conflict")
            check(len(HASH_CALLS) == 0,
                  f"malformed preparation enters the hashing function zero times "
                  f"({len(HASH_CALLS)})")
            check(len(REPLAY_CALLS) == 0,
                  f"malformed preparation performs zero replay lookups "
                  f"({len(REPLAY_CALLS)})")
            check(store.entries == entries,
                  "malformed preparation acquires no critical section")
            check(store.reads == reads,
                  "malformed preparation resolves no reference")
            check(DOMAIN_TRUST.calls == queries,
                  "malformed preparation queries no trust")
            check(store.allocations == allocated and store.writes == written,
                  "malformed preparation allocates and writes nothing")
            check(sequences_of(fabric_root) == counters,
                  "malformed preparation advances no sequence")
            check(forensic(fabric_root) == before,
                  "malformed preparation leaves the fabric byte-identical")
            check(forensic(trust_root) == trust_before,
                  "malformed preparation leaves the trust plane byte-identical")
    finally:
        identity_module._hash_prepared_request_digest = RELEASED_HASH
    check(identity_module._hash_prepared_request_digest is RELEASED_HASH,
          "the released hashing function is restored")

    # --- 13. The host transition matrix, and Trust renewal ------------------
    HOST_TRANSITIONS = (
        ("in-service", "draining", "withdraw_subject", ACCEPTED, None, 0),
        ("in-service", "withheld", "withdraw_subject", ACCEPTED, None, 0),
        ("draining", "withheld", "withdraw_subject", ACCEPTED, None, 0),
        ("in-service", "in-service", "withdraw_subject", REFUSED,
         "availability-intent-unchanged", 0),
        ("draining", "draining", "withdraw_subject", REFUSED,
         "availability-intent-unchanged", 0),
        ("withheld", "withheld", "withdraw_subject", REFUSED,
         "availability-intent-unchanged", 0),
        ("draining", "in-service", "withdraw_subject", REFUSED,
         "return-to-service-requires-refresh", 0),
        ("withheld", "in-service", "withdraw_subject", REFUSED,
         "return-to-service-requires-refresh", 0),
        ("withheld", "draining", "withdraw_subject", REFUSED,
         "return-to-service-requires-refresh", 0),
        ("draining", "in-service", "refresh_subject", ACCEPTED, None, 1),
        ("withheld", "in-service", "refresh_subject", ACCEPTED, None, 1),
        ("withheld", "draining", "refresh_subject", ACCEPTED, None, 1),
        ("in-service", "in-service", "refresh_subject", REFUSED,
         "refresh-changes-nothing", 0),
        ("draining", "draining", "refresh_subject", REFUSED,
         "refresh-changes-nothing", 0),
        ("withheld", "withheld", "refresh_subject", REFUSED,
         "refresh-changes-nothing", 0),
    )
    for index, (start, target, operation, outcome, reason, queries) in enumerate(
            HOST_TRANSITIONS):
        with TemporaryDirectory() as tmp:
            store = audited(tmp)
            trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
            fabric_root = Path(tmp) / "fabric"
            trust_root = Path(tmp) / "trust"
            head = admit_subject(store, trust_store, **dict(
                BASE_SUBJECT, request_id=f"i7-t-host-{index}",
                fabric_node_trust_record_id=host_trust.record.record_id))
            if start != "in-service":
                moved, _ = call("withdraw_subject", store, **dict(
                    BASE_WITHDRAWAL, request_id=f"i7-t-move-{index}",
                    capability_host_id=head.record_id, availability_intent=start))
                check(moved is not None and moved.outcome == ACCEPTED,
                      f"the host reaches {start} before the {start} to {target} row")
                head = moved
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            allocated = list(store.allocations)
            asked = list(DOMAIN_TRUST.calls)
            if operation == "withdraw_subject":
                result, error = call("withdraw_subject", store, **dict(
                    BASE_WITHDRAWAL, request_id=f"i7-t-{index}",
                    capability_host_id=head.record_id, availability_intent=target))
            else:
                fields = dict(
                    actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
                    evaluated_at=STAMP, request_id=f"i7-t-{index}",
                    capability_host_id=head.record_id,
                    fabric_node_trust_record_id=host_trust.record.record_id,
                    verified_resource_profile=dict(PROFILE),
                    verification_reference=BASE_SUBJECT["verification_reference"],
                    location_class="on-premises",
                    data_classification="internal",
                    availability_intent=target, provenance=dict(PROV), notes=None)
                result, error = call("refresh_subject", store, trust_store, **fields)
            label = f"{start} to {target} by {operation}"
            check(error is None, f"the {label} row raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome, f"the {label} row returns {outcome}")
            if reason is not None:
                check(result.reason == reason, f"the {label} row is refused as {reason}")
            expected_records = 1 if outcome == ACCEPTED else 0
            check(len(store.allocations) == len(allocated) + expected_records,
                  f"the {label} row writes {expected_records} host record")
            check(len(DOMAIN_TRUST.calls) == len(asked) + queries,
                  f"the {label} row makes {queries} trust query")
            check(forensic(trust_root) == trust_before,
                  f"the {label} row writes nothing to the Trust Plane")
            if outcome != ACCEPTED:
                check(forensic(fabric_root) == before,
                      f"the {label} row leaves the fabric byte-identical")

    # A refresh that renews only the trust record is authoritative, and the
    # superseded declaration keeps its own reference for ever.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        head = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="i7-renew-host",
            fabric_node_trust_record_id=host_trust.record.record_id))
        renewed = create_decision(
            trust_store, subject_id="node/schai", subject_type="fabric-node",
            requested_state=TrustState.RESTRICTED.value,
            actor_authority_id=[record for record in
                                trust_store.all_records("authority")][0]["authority_id"],
            decided_at=STAMP, reason="renewed for the fabric refresh regression",
            evidence_references=(TrustEvidenceReference(
                evidence_id=trust_store.peek_next_id("evidence"), kind="fingerprint",
                reference="/approved/evidence/fingerprint.txt", recorded_at=STAMP),),
            verification_method=VerificationMethod.OUT_OF_BAND_PHYSICAL.value,
            verification_details=TrustVerificationDetails(
                subject_property="ssh-host-key-fingerprint",
                observed_value_reference="/approved/evidence/observed.txt",
                comparison_source="printed-console-readout",
                performed_by="operator-role-reference", performed_at=STAMP),
            scope=TrustScope(
                scope_id="TSCOPE-000001", subject_type="fabric-node",
                permitted_capabilities=("CAPDEF-0001",),
                permitted_operations=("linux.hostname",),
                permitted_data_classifications=("internal",),
                permitted_targets=("schmgmt.home.arpa",),
                validity_start=STAMP, validity_end=YEAR),
            supersedes=host_trust.decision.decision_id,
            lineage_id=host_trust.lineage.lineage_id)
        prior_host = record_of(store, "capability-host", head.record_id)
        asked = list(DOMAIN_TRUST.calls)
        refreshed, error = call(
            "refresh_subject", store, trust_store, request_id="i7-renew",
            actor=OPERATOR, approving_authority=OPERATOR, recorded_at=STAMP,
            evaluated_at=STAMP, capability_host_id=head.record_id,
            fabric_node_trust_record_id=renewed.record.record_id,
            verified_resource_profile=dict(PROFILE),
            verification_reference=BASE_SUBJECT["verification_reference"],
            location_class="on-premises", data_classification="internal",
            availability_intent="in-service", provenance=dict(PROV))
        check(error is None and refreshed is not None
              and refreshed.outcome == ACCEPTED,
              "a refresh citing a renewed trust record is authoritative")
        check(len(DOMAIN_TRUST.calls) == len(asked) + 1,
              "a declaration refresh makes exactly one fresh trust query")
        successor = record_of(store, "capability-host", refreshed.record_id)
        check(successor.get("fabric_node_trust_record_id") == renewed.record.record_id,
              "the current declaration cites the trust record it relied upon")
        check(record_of(store, "capability-host", head.record_id) == prior_host,
              "the superseded declaration keeps its historical trust reference")
        check(successor.get("supersedes") == head.record_id,
              "the refreshed declaration names the one it supersedes")

    # A successor addresses the head, and a chain that forks or loops refuses.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        head = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id="i7-chain-host",
            fabric_node_trust_record_id=host_trust.record.record_id))
        moved, _ = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-chain-1",
            capability_host_id=head.record_id, availability_intent="draining"))
        check(moved is not None and moved.outcome == ACCEPTED,
              "the chain regression moves the host once")
        before = forensic(fabric_root)
        stale, error = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-chain-2",
            capability_host_id=head.record_id, availability_intent="withheld"))
        check(error is None and stale is not None and stale.outcome == REFUSED
              and stale.reason == "host-predecessor-not-current",
              "a successor of a superseded declaration is refused")
        check(forensic(fabric_root) == before,
              "a stale predecessor writes nothing")
        absent, _ = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-chain-3",
            capability_host_id="CHOST-9999", availability_intent="withheld"))
        check(absent is not None and absent.outcome == NOT_FOUND,
              "a successor of an absent declaration is not-found")

    # --- 14. The instance lifecycle matrix ----------------------------------
    LIFECYCLE_ROWS = (
        ("admitted", "withdraw_instance", ACCEPTED, None, "withdrawn"),
        ("admitted", "retire_instance", ACCEPTED, None, "retired"),
        ("withdrawn", "retire_instance", ACCEPTED, None, "retired"),
        ("withdrawn", "withdraw_instance", REFUSED,
         "instance-lifecycle-transition-illegal", None),
        ("retired", "withdraw_instance", REFUSED,
         "instance-lifecycle-transition-illegal", None),
        ("retired", "retire_instance", REFUSED,
         "instance-lifecycle-transition-illegal", None),
    )
    for index, (start, operation, outcome, reason, produced) in enumerate(
            LIFECYCLE_ROWS):
        with TemporaryDirectory() as tmp:
            store = audited(tmp)
            trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
            fabric_root = Path(tmp) / "fabric"
            trust_root = Path(tmp) / "trust"
            cap, con, pkg, adm, adv, base = fabric_ready(
                tmp, store, trust_store, host_trust, package_trust)
            binding, _ = call("admit_instance", store, trust_store,
                              **dict(base, request_id=f"i7-l-inst-{index}"))
            check(binding is not None and binding.outcome == ACCEPTED,
                  f"the {start} lifecycle row admits a binding")
            head = binding.record_id
            if start in ("withdrawn", "retired"):
                first = "withdraw_instance" if start == "withdrawn" else "retire_instance"
                moved, _ = call(first, store, request_id=f"i7-l-move-{index}",
                                actor=OPERATOR, approving_authority=OPERATOR,
                                recorded_at=STAMP, instance_id=head,
                                provenance=dict(PROV))
                check(moved is not None and moved.outcome == ACCEPTED,
                      f"the binding reaches {start} before the {start} row")
                head = moved.record_id
            asked = list(DOMAIN_TRUST.calls)
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            allocated = list(store.allocations)
            result, error = call(operation, store, request_id=f"i7-l-{index}",
                                 actor=OPERATOR, approving_authority=OPERATOR,
                                 recorded_at=STAMP, instance_id=head,
                                 provenance=dict(PROV),
                                 notes="ended by operator decision")
            label = f"{start} by {operation}"
            check(error is None, f"the {label} lifecycle row raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome, f"the {label} row returns {outcome}")
            if reason is not None:
                check(result.reason == reason, f"the {label} row is refused as {reason}")
            check(DOMAIN_TRUST.calls == asked,
                  f"the {label} row queries no trust")
            check(forensic(trust_root) == trust_before,
                  f"the {label} row writes nothing to the Trust Plane")
            if outcome == ACCEPTED:
                successor = record_of(store, "capability-instance", result.record_id)
                prior = record_of(store, "capability-instance", head)
                check(successor.get("lifecycle_state") == produced,
                      f"the {label} row records the state it produced")
                check(successor.get("supersedes") == head,
                      f"the {label} row names the record it continues")
                check((successor.get("evidence") or {}).get("reason_category")
                      == ("withdrawal" if produced == "withdrawn" else "retirement"),
                      f"the {label} row is recorded under its own category")
                for field in ("capability_id", "capability_package_id",
                              "capability_host_id", "contract_id",
                              "admission_decision_id", "package_trust_record_id",
                              "host_trust_record_id", "effective_scope",
                              "advertisement_id"):
                    check(successor.get(field) == prior.get(field),
                          f"the {label} row carries {field} across unchanged")
                check(record_of(store, "capability-instance", head) == prior,
                      f"the {label} row leaves its predecessor byte-identical")
            else:
                check(len(store.allocations) == len(allocated),
                      f"the {label} row allocates nothing")
                check(forensic(fabric_root) == before,
                      f"the {label} row leaves the fabric byte-identical")

    # Retired stays retired, and a route names only a binding root.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        binding, _ = call("admit_instance", store, trust_store,
                          **dict(base, request_id="i7-retire-inst"))
        retired, _ = call("retire_instance", store, request_id="i7-retire",
                          actor=OPERATOR, approving_authority=OPERATOR,
                          recorded_at=STAMP, instance_id=binding.record_id,
                          provenance=dict(PROV))
        check(retired is not None and retired.outcome == ACCEPTED,
              "a binding is retired by decision")
        settled = forensic(fabric_root)
        returned = register_advertisement(store, **dict(
            BASE_ADVERT, request_id="i7-retire-adv", actor=adm.record_id,
            capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id, observed_at=STAMP, valid_until=YEAR))
        check(returned.outcome == ACCEPTED,
              "a host whose binding is retired may still publish a claim")
        check(record_of(store, "capability-instance", retired.record_id).get(
                  "lifecycle_state") == "retired",
              "a fresh advertisement does not reactivate a retired binding")
        route_base = dict(BASE_ROUTE, capability_id=cap.record_id,
                          contract_id=con.record_id,
                          candidate_instances=(retired.record_id,))
        refused_route, _ = call("create_route", store,
                                **dict(route_base, request_id="i7-retire-route"))
        check(refused_route is not None and refused_route.outcome == REFUSED
              and refused_route.reason == "candidate-not-a-binding-root",
              "a route may not name a lifecycle successor")
        rooted, _ = call("create_route", store, **dict(
            route_base, request_id="i7-root-route",
            candidate_instances=(binding.record_id,)))
        check(rooted is not None and rooted.outcome == ACCEPTED,
              "a route may still name the root of a binding whose lifecycle ended")
        check(record_of(store, "capability-instance", binding.record_id).get(
                  "lifecycle_state") == "admitted",
              "the root record itself is unchanged by the retirement that followed it")
        check(record_of(store, "capability-instance", retired.record_id).get(
                  "lifecycle_state") == "retired",
              "the lifecycle head is what says the binding ended")
        # Re-admission is a new decision producing a new binding.
        readmitted, _ = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-readmit-new", advertisement_id=returned.record_id))
        check(readmitted is not None and readmitted.outcome == ACCEPTED
              and readmitted.record_id != binding.record_id,
              "re-admission is a new human decision creating a new binding")
        check(record_of(store, "capability-instance", readmitted.record_id).get(
                  "supersedes") is None,
              "a re-admitted binding supersedes nothing; it is not a revival")

    # --- 15. A claim cites the declaration current for its subject ----------
    # Accepted increment 7 correction. An advertisement is published by a
    # subject as it is now; citing a record the operator already replaced would
    # attach a live claim to a stale identity. Claim retention is not authority
    # to admit -- that is enforced separately at instance admission.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        claim = dict(BASE_ADVERT, actor=adm.record_id,
                     capability_host_id=adm.record_id,
                     capability_package_id=pkg.record_id,
                     contract_id=con.record_id, observed_at=STAMP,
                     valid_until=YEAR)

        # Ordering: structure, then identity, then reference, then currency.
        STRUCTURAL = (
            ("a malformed host identity", INVALID, "malformed-operation-content",
             {"capability_host_id": "CHOST-1", "actor": "CHOST-1"}),
            ("a host identity of the wrong record kind", INVALID,
             "malformed-operation-content",
             {"capability_host_id": "CINST-000001", "actor": "CINST-000001"}),
            ("no host identity at all", INVALID, "malformed-operation-content",
             {"capability_host_id": None, "actor": None}),
        )
        for index, (description, outcome, reason, overrides) in enumerate(STRUCTURAL):
            before = forensic(fabric_root)
            entries = store.entries
            reads = store.reads
            allocated = list(store.allocations)
            result, error = attempted(lambda: register_advertisement(
                store, **dict(claim, request_id=f"i7-adv-bad-{index}", **overrides)))
            check(error is None, f"an advertisement with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == outcome and result.reason == reason,
                  f"an advertisement with {description} is refused as {reason}")
            check(store.entries == entries,
                  f"an advertisement with {description} enters no critical section")
            check(store.reads == reads,
                  f"an advertisement with {description} resolves no reference")
            check(store.allocations == allocated,
                  f"an advertisement with {description} allocates nothing")
            check(forensic(fabric_root) == before,
                  f"an advertisement with {description} writes nothing")

        absent, error = attempted(lambda: register_advertisement(
            store, **dict(claim, request_id="i7-adv-absent",
                          capability_host_id="CHOST-9999", actor="CHOST-9999")))
        check(error is None and absent is not None and absent.outcome == NOT_FOUND
              and absent.reason == "unresolved-reference",
              "an advertisement citing a missing declaration is not-found")

        # Now supersede the declaration and prove the stale citation refuses.
        moved, _ = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-adv-move",
            capability_host_id=adm.record_id, availability_intent="draining"))
        check(moved is not None and moved.outcome == ACCEPTED,
              "the advertisement regression supersedes the declaration once")
        before = forensic(fabric_root)
        trust_before = forensic(trust_root)
        counters = sequences_of(fabric_root)
        allocated = list(store.allocations)
        written = list(store.writes)
        queries = list(DOMAIN_TRUST.calls)
        stale, error = attempted(lambda: register_advertisement(
            store, **dict(claim, request_id="i7-adv-stale")))
        check(error is None, "a stale citation raises nothing")
        check(stale is not None and stale.outcome == REFUSED
              and stale.reason == "host-record-superseded",
              "a claim citing a superseded declaration is refused as host-record-superseded")
        check(stale is not None and stale.record_id is None,
              "a stale citation names no record")
        check(store.allocations == allocated and store.writes == written,
              "a stale citation allocates and writes nothing")
        check(sequences_of(fabric_root) == counters,
              "a stale citation advances no sequence")
        check(DOMAIN_TRUST.calls == queries, "a stale citation queries no trust")
        check(forensic(fabric_root) == before,
              "a stale citation leaves the fabric byte-identical")
        check(forensic(trust_root) == trust_before,
              "a stale citation leaves the trust plane byte-identical")

        # The head accepts, and a draining machine may still speak.
        current = dict(claim, actor=moved.record_id,
                       capability_host_id=moved.record_id)
        accepted_claim = register_advertisement(
            store, **dict(current, request_id="i7-adv-head"))
        check(accepted_claim.outcome == ACCEPTED,
              "a claim citing the current declaration is accepted")
        check(record_of(store, "capability-host", moved.record_id).get(
                  "availability_intent") == "draining",
              "a draining machine may still publish what it holds")
        replayed = register_advertisement(
            store, **dict(current, request_id="i7-adv-head"))
        check(replayed.outcome == EXACT_REPLAY
              and replayed.record_id == accepted_claim.record_id,
              "a byte-identical claim on the current declaration replays exactly")
        # A different claim that is still structurally valid: moving the
        # observation *earlier* keeps it inside the recorded window, so what
        # this proves is the identity conflict rather than a refusal.
        conflicting = register_advertisement(store, **dict(
            current, request_id="i7-adv-head", observed_at=STAMP - timedelta(hours=1)))
        check(conflicting.outcome == CONFLICT
              and conflicting.reason == CONFLICT_REASON,
              "a changed claim under one request identity conflicts")
        # Replay and conflict are classified before currency is consulted.
        stale_replay = register_advertisement(
            store, **dict(claim, request_id="i7-adv-stale"))
        check(stale_replay.outcome == REFUSED
              and stale_replay.reason == "host-record-superseded",
              "a refused stale citation is evaluated afresh, never durably replayed")

        # Claim retention is not authority to admit.
        drained, _ = call("admit_instance", store, trust_store, **dict(
            base, request_id="i7-adv-admit",
            capability_host_id=moved.record_id,
            advertisement_id=accepted_claim.record_id))
        check(drained is not None and drained.outcome == REFUSED
              and drained.reason == "host-not-in-service",
              "a claim on a draining machine grants no authority to admit")

    # --- 16. The schema and the runtime agree on every vocabulary ----------
    import yaml as _schema_yaml
    from tools.fabric.models import (  # noqa: E402
        INSTANCE_LIFECYCLE_STATES, WORKLOAD_DATA_CLASSIFICATIONS,
    )
    SCHEMAS = {}
    for _name in ("capability-host", "capability-route", "capability-instance",
                  "capability-package"):
        SCHEMAS[_name] = _schema_yaml.safe_load(
            (root / "platform-model" / "schemas"
             / f"{_name}.schema.yaml").read_text(encoding="utf-8"))
    HOST_SCHEMA = SCHEMAS["capability-host"]
    ROUTE_SCHEMA = SCHEMAS["capability-route"]
    INSTANCE_SCHEMA = SCHEMAS["capability-instance"]
    check(tuple(HOST_SCHEMA["enums"]["data_classification"])
          == WORKLOAD_DATA_CLASSIFICATIONS,
          "the host schema and the runtime agree on the workload vocabulary")
    check(HOST_SCHEMA["enums"]["data_classification"]
          == ROUTE_SCHEMA["enums"]["data_classification"],
          "the host and route schemas declare the identical workload vocabulary")
    check(tuple(HOST_SCHEMA["enums"]["availability_intent"])
          == admission_module.AVAILABILITY_INTENTS,
          "the host schema and the runtime agree on the availability vocabulary")
    check(tuple(HOST_SCHEMA["enums"]["location_class"])
          == admission_module.LOCATION_CLASSES,
          "the host schema and the runtime agree on the location vocabulary")
    check(tuple(ROUTE_SCHEMA["enums"]["locality"]) == admission_module.LOCALITIES,
          "the route schema and the runtime agree on the locality vocabulary")
    check(tuple(INSTANCE_SCHEMA["enums"]["lifecycle_state"])
          == INSTANCE_LIFECYCLE_STATES,
          "the instance schema and the runtime agree on the lifecycle vocabulary")
    check(tuple(HOST_SCHEMA["authoritative_fields"])
          == admission_module.AUTHORITATIVE_HOST_FIELDS,
          "the host schema and the runtime agree on the authoritative fields")
    # The two axes stay disjoint, and the withdrawn name stays withdrawn.
    STORAGE_LABELS = ("authoritative", "reconstructable", "mixed")
    for label in STORAGE_LABELS:
        check(label not in HOST_SCHEMA["enums"]["data_classification"],
              f"the storage recoverability label '{label}' is not a workload classification")
    check("data_classification" in HOST_SCHEMA["required_fields"],
          "the host schema requires data_classification")
    check("data_classification_ceiling" not in HOST_SCHEMA["required_fields"],
          "the withdrawn ceiling field name is gone from the host schema")
    check("lifecycle_state" in INSTANCE_SCHEMA["required_fields"],
          "the instance schema requires lifecycle_state")
    check(INSTANCE_SCHEMA["lifecycle_terminal_states"] == ["retired"],
          "the instance schema declares retirement terminal")
    check(INSTANCE_SCHEMA["reactivation"] == "forbidden",
          "the instance schema forbids reactivation")
    check(SCHEMAS["capability-package"]["trust_subject_identity"]
          == "capability_package_id",
          "the package schema names the trust subject it is decided under")
    check(HOST_SCHEMA["advertisement_must_cite"] == "current-head",
          "the host schema requires a claim to cite the current declaration")

    # --- 17. The overlap interval is audit evidence and nothing else -------
    OVERLAP = ROUTE_SCHEMA["overlap_window_structure"]
    for key, value in (("effect_on_eligibility", "none"),
                       ("effect_on_selection", "none"),
                       ("consulted_by", "audit-only"),
                       ("activates_on_timestamp", "never"),
                       ("permitted_only_with", "supersedes")):
        check(OVERLAP[key] == value,
              f"the route schema declares overlap {key} is {value}")
    # Judged over identifiers rather than prose: a docstring may say that
    # nothing schedules, and saying so must not be mistaken for doing it.
    ADMISSION_NAMES = set()
    for _n in _ast.walk(_ast.parse((root / "tools" / "fabric"
                                    / "admission.py").read_text(encoding="utf-8"))):
        if isinstance(_n, _ast.Name):
            ADMISSION_NAMES.add(_n.id)
        elif isinstance(_n, _ast.Attribute):
            ADMISSION_NAMES.add(_n.attr)
        elif isinstance(_n, (_ast.FunctionDef, _ast.AsyncFunctionDef, _ast.ClassDef)):
            ADMISSION_NAMES.add(_n.name)
        elif isinstance(_n, _ast.arg):
            ADMISSION_NAMES.add(_n.arg)
        elif isinstance(_n, _ast.keyword) and _n.arg:
            ADMISSION_NAMES.add(_n.arg)
        elif isinstance(_n, (_ast.Import, _ast.ImportFrom)):
            for _alias in _n.names:
                ADMISSION_NAMES.add(_alias.asname or _alias.name)
    check(not any(isinstance(_n, _ast.AsyncFunctionDef)
                  for _n in _ast.walk(_ast.parse(
                      (root / "tools" / "fabric"
                       / "admission.py").read_text(encoding="utf-8")))),
          "the admission controller defines nothing asynchronous")
    for forbidden in ("sched", "scheduler", "Timer", "timer", "threading",
                      "at_time", "activate", "activation", "cutover_at",
                      "rollback", "background", "deadline", "asyncio", "sleep",
                      "cron", "defer", "delay", "trigger"):
        check(not any(forbidden in name for name in ADMISSION_NAMES),
              f"the admission controller names no '{forbidden}' behaviour")
    # The declared interval changes nothing about what is stored beyond itself.
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        first, _ = call("admit_instance", store, trust_store,
                        **dict(base, request_id="i7-o-1"))
        second, _ = call("admit_instance", store, trust_store,
                         **dict(base, request_id="i7-o-2"))
        route_base = dict(BASE_ROUTE, capability_id=cap.record_id,
                          contract_id=con.record_id,
                          candidate_instances=(first.record_id,))
        original, _ = call("create_route", store,
                           **dict(route_base, request_id="i7-o-route"))
        check(original is not None and original.outcome == ACCEPTED,
              "the overlap regression declares a route")
        OVERLAP_REFUSALS = (
            ("an identical candidate list", "overlap-window-without-cutover",
             {"candidate_instances": (first.record_id,)}),
            ("a list that drops every prior candidate",
             "overlap-window-without-coexistence",
             {"candidate_instances": (second.record_id,)}),
            ("no prior route to overlap with", "overlap-window-without-supersession",
             {"supersedes": None, "route_version": 1,
              "candidate_instances": (first.record_id, second.record_id)}),
            ("an interval that closes before it opens", "invalid-validity-window",
             {"overlap_ends_at": STAMP - timedelta(hours=1)}),
        )
        for index, (description, reason, overrides) in enumerate(OVERLAP_REFUSALS):
            before = forensic(fabric_root)
            fields = dict(route_base, request_id=f"i7-o-bad-{index}", route_version=2,
                          candidate_instances=(first.record_id, second.record_id),
                          overlap_starts_at=STAMP, overlap_ends_at=LATER,
                          supersedes=original.record_id)
            fields.update(overrides)
            result, error = call("create_route", store, **fields)
            check(error is None, f"an overlap declared with {description} raises nothing")
            if error is not None:
                continue
            check(result.outcome == REFUSED and result.reason == reason,
                  f"an overlap declared with {description} is refused as {reason}")
            check(forensic(fabric_root) == before,
                  f"an overlap declared with {description} writes nothing")
        naive, _ = call("create_route", store, **dict(
            route_base, request_id="i7-o-naive", route_version=2,
            candidate_instances=(first.record_id, second.record_id),
            overlap_starts_at=STAMP.replace(tzinfo=None), overlap_ends_at=LATER,
            supersedes=original.record_id))
        check(naive is not None and naive.outcome == INVALID
              and naive.reason == "timestamp-carries-no-offset",
              "an overlap interval without an offset is refused")

        accepted_overlap, _ = call("create_route", store, **dict(
            route_base, request_id="i7-o-ok", route_version=2,
            candidate_instances=(first.record_id, second.record_id),
            overlap_starts_at=STAMP, overlap_ends_at=LATER,
            supersedes=original.record_id))
        check(accepted_overlap is not None and accepted_overlap.outcome == ACCEPTED,
              "a declared overlap carrying one candidate and adding one is accepted")
        stored_overlap = record_of(store, "capability-route",
                                   accepted_overlap.record_id)
        check(stored_overlap.get("overlap_window")
              == {"starts_at": STAMP.isoformat(), "ends_at": LATER.isoformat()},
              "the declared interval is stored exactly as two offset-carrying instants")
        settled = forensic(fabric_root)
        counts_before = store.counts()
        # Both boundaries are in the past relative to nothing the fabric reads.
        # Passing either instant activates nothing, because no operation
        # observes them: the record is evidence, and evidence does not fire.
        replayed_overlap, _ = call("create_route", store, **dict(
            route_base, request_id="i7-o-ok", route_version=2,
            candidate_instances=(first.record_id, second.record_id),
            overlap_starts_at=STAMP, overlap_ends_at=LATER,
            supersedes=original.record_id))
        check(replayed_overlap is not None
              and replayed_overlap.outcome == EXACT_REPLAY,
              "a declared overlap replays exactly rather than reapplying")
        check(forensic(fabric_root) == settled,
              "nothing in the store changes when the declared interval is revisited")
        check(store.counts() == counts_before,
              "no record appears or disappears on account of a declared interval")
        check(record_of(store, "capability-route", original.record_id).get(
                  "candidate_instances") == [first.record_id],
              "the superseded route keeps its own candidate list")
        check("superseded_by" not in record_of(store, "capability-route",
                                               original.record_id),
              "the superseded route is not edited to point at its successor")

    # --- 18. A corrupt chain is refused, not walked past --------------------
    # The released write APIs cannot produce these states, and that is not the
    # point: a store can be damaged out of band, carry a legacy record, or be
    # tampered with, and C4 must refuse on what it reads rather than trust that
    # C2 was run first. A successor whose declared predecessor is absent is not
    # an authoritative head; a file that answers with another kind of record
    # has not resolved the reference it was asked for.
    def corrupt_store(tmp):
        """A store whose host chain has been damaged after it was written."""
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        successor, _ = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-corrupt-move",
            capability_host_id=adm.record_id, availability_intent="draining"))
        check(successor is not None and successor.outcome == ACCEPTED,
              "the corrupt-chain fixture supersedes the declaration once")
        return (store, trust_store, host_trust, cap, con, pkg, adm, adv,
                base, successor)

    with TemporaryDirectory() as tmp:
        (store, trust_store, host_trust, cap, con, pkg, adm, adv, base,
         successor) = corrupt_store(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        # Out-of-band damage: the predecessor the successor names is gone.
        (fabric_root / "capability-hosts" / f"{adm.record_id}.yaml").unlink()
        check(not (fabric_root / "capability-hosts" / f"{adm.record_id}.yaml").exists(),
              "the predecessor named by the stored successor is absent")

        DANGLING = (
            ("register_advertisement", lambda: register_advertisement(
                store, **dict(BASE_ADVERT, request_id="i7-dangle-adv",
                              actor=successor.record_id,
                              capability_host_id=successor.record_id,
                              capability_package_id=pkg.record_id,
                              contract_id=con.record_id, observed_at=STAMP,
                              valid_until=YEAR))),
            ("admit_instance", lambda: OPERATIONS["admit_instance"](
                store, trust_store, **dict(base, request_id="i7-dangle-inst",
                                           capability_host_id=successor.record_id))),
            ("withdraw_subject", lambda: OPERATIONS["withdraw_subject"](
                store, **dict(BASE_WITHDRAWAL, request_id="i7-dangle-wd",
                              capability_host_id=successor.record_id,
                              availability_intent="withheld"))),
            ("refresh_subject", lambda: OPERATIONS["refresh_subject"](
                store, trust_store, request_id="i7-dangle-rf", actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                evaluated_at=STAMP, capability_host_id=successor.record_id,
                fabric_node_trust_record_id=host_trust.record.record_id,
                verified_resource_profile=dict(PROFILE),
                verification_reference="/approved/evidence/host-reobserved.txt",
                location_class="on-premises", data_classification="internal",
                availability_intent="in-service", provenance=dict(PROV))),
        )
        for name, operation in DANGLING:
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            counters = sequences_of(fabric_root)
            allocated = list(store.allocations)
            written = list(store.writes)
            queries = list(DOMAIN_TRUST.calls)
            result, error = attempted(operation)
            check(error is None,
                  f"{name} over a dangling predecessor raises nothing")
            if error is not None:
                continue
            check(result.outcome == REFUSED
                  and result.reason == "host-chain-incoherent",
                  f"{name} over a dangling predecessor is refused as host-chain-incoherent")
            check(result.outcome != ACCEPTED and result.record_id is None,
                  f"{name} treats no successor of a broken chain as authoritative")
            check(result.outcome not in (EXACT_REPLAY, CONFLICT),
                  f"{name} over a dangling predecessor is neither replay nor conflict")
            check(store.allocations == allocated,
                  f"{name} over a dangling predecessor allocates nothing")
            check(store.writes == written,
                  f"{name} over a dangling predecessor writes nothing")
            check(sequences_of(fabric_root) == counters,
                  f"{name} over a dangling predecessor advances no sequence")
            check(DOMAIN_TRUST.calls == queries,
                  f"{name} over a dangling predecessor queries no trust")
            check(forensic(fabric_root) == before,
                  f"{name} over a dangling predecessor leaves the fabric byte-identical")
            check(forensic(trust_root) == trust_before,
                  f"{name} over a dangling predecessor leaves trust byte-identical")
            repeated, repeat_error = attempted(operation)
            check(repeat_error is None and repeated is not None
                  and repeated.outcome == result.outcome
                  and repeated.reason == result.reason,
                  f"{name} over a dangling predecessor refuses identically twice")

    # --- 19. A file that answers with another kind has not resolved ---------
    with TemporaryDirectory() as tmp:
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        fabric_root = Path(tmp) / "fabric"
        trust_root = Path(tmp) / "trust"
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        # The committed-test mechanism for on-disk corruption: a payload of one
        # kind written where another kind belongs.
        instance_payload = {
            "schema_version": "schott-platform/v1",
            "kind": "capability-instance",
            "instance_id": "CINST-000009",
            "capability_id": cap.record_id,
            "capability_package_id": pkg.record_id,
            "capability_host_id": adm.record_id,
            "contract_id": con.record_id,
            "satisfied_contract_versions": ["1.0.0"],
            "verified_resource_profile": dict(PROFILE),
            "admission_decision_id": "TDEC-000001",
            "package_trust_record_id": "TREC-000001",
            "host_trust_record_id": "TREC-000002",
            "effective_scope": dict(SCOPE),
            "admitted_at": STAMP.isoformat(),
            "admitted_until": YEAR.isoformat(),
            "lifecycle_state": "admitted",
            "provenance": dict(PROV),
        }
        misfiled = fabric_root / "capability-hosts" / "CHOST-0009.yaml"
        misfiled.write_text(_yaml.safe_dump(instance_payload), encoding="utf-8")
        misfiled.chmod(0o600)
        check(misfiled.exists(),
              "a payload of the wrong kind is filed where a host record belongs")

        WRONG_KIND = (
            ("register_advertisement", lambda: register_advertisement(
                store, **dict(BASE_ADVERT, request_id="i7-kind-adv",
                              actor="CHOST-0009", capability_host_id="CHOST-0009",
                              capability_package_id=pkg.record_id,
                              contract_id=con.record_id, observed_at=STAMP,
                              valid_until=YEAR))),
            ("admit_instance", lambda: OPERATIONS["admit_instance"](
                store, trust_store, **dict(base, request_id="i7-kind-inst",
                                           capability_host_id="CHOST-0009"))),
            ("withdraw_subject", lambda: OPERATIONS["withdraw_subject"](
                store, **dict(BASE_WITHDRAWAL, request_id="i7-kind-wd",
                              capability_host_id="CHOST-0009",
                              availability_intent="withheld"))),
            ("refresh_subject", lambda: OPERATIONS["refresh_subject"](
                store, trust_store, request_id="i7-kind-rf", actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                evaluated_at=STAMP, capability_host_id="CHOST-0009",
                fabric_node_trust_record_id=host_trust.record.record_id,
                verified_resource_profile=dict(PROFILE),
                verification_reference="/approved/evidence/host-reobserved.txt",
                location_class="on-premises", data_classification="internal",
                availability_intent="in-service", provenance=dict(PROV))),
        )
        for name, operation in WRONG_KIND:
            before = forensic(fabric_root)
            trust_before = forensic(trust_root)
            counters = sequences_of(fabric_root)
            allocated = list(store.allocations)
            written = list(store.writes)
            queries = list(DOMAIN_TRUST.calls)
            result, error = attempted(operation)
            check(error is None,
                  f"{name} over a wrong-kind stored record raises nothing")
            if error is not None:
                continue
            check(result.outcome == NOT_FOUND
                  and result.reason == "unresolved-reference",
                  f"{name} over a wrong-kind stored record is refused as unresolved-reference")
            check(result.record_id is None,
                  f"{name} over a wrong-kind stored record names no record")
            check(result.outcome not in (EXACT_REPLAY, CONFLICT),
                  f"{name} over a wrong-kind stored record is neither replay nor conflict")
            check(store.allocations == allocated and store.writes == written,
                  f"{name} over a wrong-kind stored record allocates and writes nothing")
            check(sequences_of(fabric_root) == counters,
                  f"{name} over a wrong-kind stored record advances no sequence")
            check(DOMAIN_TRUST.calls == queries,
                  f"{name} over a wrong-kind stored record queries no trust")
            check(forensic(fabric_root) == before,
                  f"{name} over a wrong-kind stored record leaves the fabric byte-identical")
            check(forensic(trust_root) == trust_before,
                  f"{name} over a wrong-kind stored record leaves trust byte-identical")

        # A stored identity that disagrees with its filename has not resolved
        # the reference either: the record answering is not the one asked for.
        mislabelled = fabric_root / "capability-hosts" / "CHOST-0008.yaml"
        host_payload = record_of(store, "capability-host", adm.record_id)
        mislabelled.write_text(_yaml.safe_dump(dict(host_payload)), encoding="utf-8")
        mislabelled.chmod(0o600)
        before = forensic(fabric_root)
        mismatched, error = attempted(lambda: register_advertisement(
            store, **dict(BASE_ADVERT, request_id="i7-kind-id", actor="CHOST-0008",
                          capability_host_id="CHOST-0008",
                          capability_package_id=pkg.record_id,
                          contract_id=con.record_id, observed_at=STAMP,
                          valid_until=YEAR)))
        check(error is None and mismatched is not None
              and mismatched.outcome == NOT_FOUND
              and mismatched.reason == "unresolved-reference",
              "a stored record whose identity disagrees with the name asked for has not resolved")
        check(forensic(fabric_root) == before,
              "a mismatched stored identity writes nothing")

    # --- 20. A corrupt record inside the chain is not walked across ---------
    # `_resolve` guards what a caller names. Chain traversal reaches records the
    # caller never named, through `list_records`, so a payload that is not the
    # kind it was filed as -- or that names an identity other than the one it
    # lives under -- must stop the read there too. A head found by stepping
    # across damage is not evidence that it is current.
    def chained_store(tmp):
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        successor, _ = call("withdraw_subject", store, **dict(
            BASE_WITHDRAWAL, request_id="i7-inner-move",
            capability_host_id=adm.record_id, availability_intent="draining"))
        check(successor is not None and successor.outcome == ACCEPTED,
              "the inner-corruption fixture supersedes the declaration once")
        return (store, trust_store, host_trust, cap, con, pkg, adm, adv, base,
                successor)

    def chain_operations(store, trust_store, host_trust, con, pkg, base,
                         successor, tag):
        return (
            ("register_advertisement", lambda: register_advertisement(
                store, **dict(BASE_ADVERT, request_id=f"i7-{tag}-adv",
                              actor=successor.record_id,
                              capability_host_id=successor.record_id,
                              capability_package_id=pkg.record_id,
                              contract_id=con.record_id, observed_at=STAMP,
                              valid_until=YEAR))),
            ("admit_instance", lambda: OPERATIONS["admit_instance"](
                store, trust_store, **dict(base, request_id=f"i7-{tag}-inst",
                                           capability_host_id=successor.record_id))),
            ("withdraw_subject", lambda: OPERATIONS["withdraw_subject"](
                store, **dict(BASE_WITHDRAWAL, request_id=f"i7-{tag}-wd",
                              capability_host_id=successor.record_id,
                              availability_intent="withheld"))),
            ("refresh_subject", lambda: OPERATIONS["refresh_subject"](
                store, trust_store, request_id=f"i7-{tag}-rf", actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                evaluated_at=STAMP, capability_host_id=successor.record_id,
                fabric_node_trust_record_id=host_trust.record.record_id,
                verified_resource_profile=dict(PROFILE),
                verification_reference="/approved/evidence/host-reobserved.txt",
                location_class="on-premises", data_classification="internal",
                availability_intent="in-service", provenance=dict(PROV))),
        )

    INNER_CORRUPTION = (
        ("a predecessor payload of another kind", "innerkind",
         lambda adm, cap, con, pkg: {
             "schema_version": "schott-platform/v1",
             "kind": "capability-instance",
             "instance_id": "CINST-000009",
             "capability_id": cap.record_id,
             "capability_package_id": pkg.record_id,
             # The field the traversal reads for a host identity, set to the
             # predecessor's own name so a naive presence check is satisfied.
             "capability_host_id": adm.record_id,
             "contract_id": con.record_id,
             "satisfied_contract_versions": ["1.0.0"],
             "verified_resource_profile": dict(PROFILE),
             "admission_decision_id": "TDEC-000001",
             "package_trust_record_id": "TREC-000001",
             "host_trust_record_id": "TREC-000002",
             "effective_scope": dict(SCOPE),
             "admitted_at": STAMP.isoformat(),
             "admitted_until": YEAR.isoformat(),
             "lifecycle_state": "admitted",
             "provenance": dict(PROV)}),
        ("a predecessor payload naming another identity", "inneridentity",
         lambda adm, cap, con, pkg: {
             "schema_version": "schott-platform/v1",
             "kind": "capability-host",
             "capability_host_id": "CHOST-0007",
             "node_identity_reference": "node/schai",
             "fabric_node_trust_record_id": "TREC-000001",
             "verified_resource_profile": dict(PROFILE),
             "location_class": "on-premises",
             "data_classification": "internal",
             "availability_intent": "in-service",
             "provenance": dict(PROV)}),
    )
    for description, tag, payload_for in INNER_CORRUPTION:
        with TemporaryDirectory() as tmp:
            (store, trust_store, host_trust, cap, con, pkg, adm, adv, base,
             successor) = chained_store(tmp)
            fabric_root = Path(tmp) / "fabric"
            trust_root = Path(tmp) / "trust"
            corrupted = fabric_root / "capability-hosts" / f"{adm.record_id}.yaml"
            corrupted.write_text(_yaml.safe_dump(payload_for(adm, cap, con, pkg)),
                                 encoding="utf-8")
            corrupted.chmod(0o600)
            check(corrupted.exists(),
                  f"the chain now carries {description}")
            for name, operation in chain_operations(
                    store, trust_store, host_trust, con, pkg, base, successor, tag):
                before = forensic(fabric_root)
                trust_before = forensic(trust_root)
                counters = sequences_of(fabric_root)
                allocated = list(store.allocations)
                written = list(store.writes)
                queries = list(DOMAIN_TRUST.calls)
                result, error = attempted(operation)
                label = f"{name} over {description}"
                check(error is None, f"{label} raises nothing")
                if error is not None:
                    continue
                check(result.outcome == REFUSED
                      and result.reason == "host-chain-incoherent",
                      f"{label} is refused as host-chain-incoherent")
                check(result.outcome != ACCEPTED and result.record_id is None,
                      f"{label} accepts no authoritative head")
                check(result.outcome not in (EXACT_REPLAY, CONFLICT),
                      f"{label} is neither replay nor conflict")
                check(store.allocations == allocated,
                      f"{label} allocates nothing")
                check(store.writes == written, f"{label} writes nothing")
                check(sequences_of(fabric_root) == counters,
                      f"{label} advances no sequence")
                check(DOMAIN_TRUST.calls == queries, f"{label} queries no trust")
                check(forensic(fabric_root) == before,
                      f"{label} leaves the fabric byte-identical")
                check(forensic(trust_root) == trust_before,
                      f"{label} leaves trust byte-identical")
                repeated, repeat_error = attempted(operation)
                check(repeat_error is None and repeated is not None
                      and repeated.outcome == result.outcome
                      and repeated.reason == result.reason,
                      f"{label} refuses identically twice")

    # --- 21. A corrupt binding chain is refused, not walked across ----------
    # The same rule as the host chain, for the record class that carries a
    # binding's history. `instance-chain-incoherent` is the authorised
    # counterpart to `host-chain-incoherent`: it names a chain C4 cannot read,
    # and it replaces none of the reasons that name a chain it can read and
    # objects to -- forked, cyclic, not-current-head, already-superseded, or
    # not-admitted.
    def bound_store(tmp):
        """A binding with one lifecycle version, ready to be damaged."""
        store = audited(tmp)
        trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
        cap, con, pkg, adm, adv, base = fabric_ready(
            tmp, store, trust_store, host_trust, package_trust)
        binding, _ = call("admit_instance", store, trust_store,
                          **dict(base, request_id="i7-bind-root"))
        check(binding is not None and binding.outcome == ACCEPTED,
              "the binding-chain fixture admits a binding")
        head, _ = call("withdraw_instance", store, request_id="i7-bind-wd",
                       actor=OPERATOR, approving_authority=OPERATOR,
                       recorded_at=STAMP, instance_id=binding.record_id,
                       provenance=dict(PROV))
        check(head is not None and head.outcome == ACCEPTED,
              "the binding-chain fixture writes one lifecycle version")
        return store, trust_store, base, binding, head

    def binding_operations(store, trust_store, base, head, tag):
        return (
            ("admit_instance", lambda: OPERATIONS["admit_instance"](
                store, trust_store, **dict(base, request_id=f"i7-{tag}-sup",
                                           supersedes=head.record_id))),
            ("withdraw_instance", lambda: OPERATIONS["withdraw_instance"](
                store, request_id=f"i7-{tag}-wd", actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                instance_id=head.record_id, provenance=dict(PROV))),
            ("retire_instance", lambda: OPERATIONS["retire_instance"](
                store, request_id=f"i7-{tag}-rt", actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                instance_id=head.record_id, provenance=dict(PROV))),
        )

    BINDING_CORRUPTION = (
        ("a missing binding predecessor", "bindgone", None),
        ("a binding predecessor of another kind", "bindkind",
         lambda binding: {
             "schema_version": "schott-platform/v1",
             "kind": "capability-host",
             "capability_host_id": "CHOST-0007",
             # The field the traversal reads for a binding identity, set to the
             # predecessor's own name so a naive presence check is satisfied.
             "instance_id": binding.record_id,
             "node_identity_reference": "node/schai",
             "fabric_node_trust_record_id": "TREC-000001",
             "verified_resource_profile": dict(PROFILE),
             "location_class": "on-premises",
             "data_classification": "internal",
             "availability_intent": "in-service",
             "provenance": dict(PROV)}),
        ("a binding predecessor naming another identity", "bindidentity",
         lambda binding: {
             "schema_version": "schott-platform/v1",
             "kind": "capability-instance",
             "instance_id": "CINST-000007",
             "capability_id": "CAPDEF-0001",
             "capability_package_id": "CPKG-0001",
             "capability_host_id": "CHOST-0001",
             "contract_id": "CCON-0001",
             "satisfied_contract_versions": ["1.0.0"],
             "verified_resource_profile": dict(PROFILE),
             "admission_decision_id": "TDEC-000001",
             "package_trust_record_id": "TREC-000001",
             "host_trust_record_id": "TREC-000002",
             "effective_scope": dict(SCOPE),
             "admitted_at": STAMP.isoformat(),
             "admitted_until": YEAR.isoformat(),
             "lifecycle_state": "admitted",
             "provenance": dict(PROV)}),
    )
    for description, tag, payload_for in BINDING_CORRUPTION:
        with TemporaryDirectory() as tmp:
            store, trust_store, base, binding, head = bound_store(tmp)
            fabric_root = Path(tmp) / "fabric"
            trust_root = Path(tmp) / "trust"
            damaged = (fabric_root / "capability-instances"
                       / f"{binding.record_id}.yaml")
            if payload_for is None:
                damaged.unlink()
                check(not damaged.exists(),
                      "the predecessor named by the stored lifecycle version is absent")
            else:
                damaged.write_text(_yaml.safe_dump(payload_for(binding)),
                                   encoding="utf-8")
                damaged.chmod(0o600)
                check(damaged.exists(), f"the binding chain now carries {description}")
            for name, operation in binding_operations(
                    store, trust_store, base, head, tag):
                before = forensic(fabric_root)
                trust_before = forensic(trust_root)
                counters = sequences_of(fabric_root)
                allocated = list(store.allocations)
                written = list(store.writes)
                queries = list(DOMAIN_TRUST.calls)
                result, error = attempted(operation)
                label = f"{name} over {description}"
                check(error is None, f"{label} raises nothing")
                if error is not None:
                    continue
                check(result.outcome == REFUSED
                      and result.reason == "instance-chain-incoherent",
                      f"{label} is refused as instance-chain-incoherent")
                check(result.outcome != ACCEPTED and result.record_id is None,
                      f"{label} accepts no chain head or predecessor")
                check(result.outcome not in (EXACT_REPLAY, CONFLICT),
                      f"{label} is neither replay nor conflict")
                check(store.allocations == allocated,
                      f"{label} allocates nothing")
                check(store.writes == written, f"{label} writes nothing")
                check(sequences_of(fabric_root) == counters,
                      f"{label} advances no sequence")
                check(DOMAIN_TRUST.calls == queries, f"{label} queries no trust")
                check(forensic(fabric_root) == before,
                      f"{label} leaves the fabric byte-identical")
                check(forensic(trust_root) == trust_before,
                      f"{label} leaves trust byte-identical")
                repeated, repeat_error = attempted(operation)
                check(repeat_error is None and repeated is not None
                      and repeated.outcome == result.outcome
                      and repeated.reason == result.reason,
                      f"{label} refuses identically twice")

    # The authorised reason is CINST-specific and replaces nothing.
    check(admission_module.REASON_INSTANCE_INCOHERENT == "instance-chain-incoherent",
          "the runtime vocabulary names instance-chain-incoherent")
    check(admission_module.REASON_INSTANCE_INCOHERENT
          != admission_module.REASON_CHAIN_INCOHERENT,
          "the binding chain and the host chain carry distinct reasons")
    for kept in ("REASON_INSTANCE_FORKED", "REASON_INSTANCE_CYCLIC",
                 "REASON_INSTANCE_NOT_HEAD", "REASON_SUPERSEDES_SUPERSEDED",
                 "REASON_SUPERSEDES_NOT_ADMITTED"):
        check(getattr(admission_module, kept)
              != admission_module.REASON_INSTANCE_INCOHERENT,
              f"instance-chain-incoherent does not replace {kept}")

    # --- 22. Increment 7 stops where increment 8 begins -------------------
    for later in ("evaluate_eligibility", "eligibility", "select", "selection",
                  "compute_eligibility", "inspect", "validate_store",
                  "admit_route", "health", "remediate"):
        check(not hasattr(admission_module, later),
              f"admission exposes no '{later}' behaviour at increment 7")
    for absent in ("health.py",):
        check(not (root / "tools" / "fabric" / absent).exists(),
              f"increment 7 creates no {absent}")
finally:
    admission_module.verify_trust_record = RELEASED_TRUST_VERIFY_7

check(admission_module.verify_trust_record is RELEASED_TRUST_VERIFY_7,
      "the released C3 adapter is restored after the increment 7 regression")

# =======================================================================
# Increment 8 — eligibility evaluator (C5)
# =======================================================================
# C5 explains, at one supplied instant, whether one already-governed binding
# is eligible. It is pure: it reads records and asks C3 once per domain, and
# it writes nothing, allocates nothing, and stores no verdict -- eligibility
# is derived, and a derived answer that gets written back becomes a decision
# nobody made.
#
# Every one of the twelve conditions the schema enumerates is checked
# individually, because prose that says "eight" is how an enumerated check
# quietly disappears. ELIG-13 and ELIG-14 are C6's, in increment 9, and are
# absent here on purpose: route membership and effect-class routability are
# selection constraints, and C5 selects nothing.

RELEASED_TRUST_VERIFY_8 = trust_adapter.verify_trust_record

# The import that must fail before increment 8 exists.
import tools.fabric.eligibility as eligibility_module  # noqa: E402
from tools.fabric.eligibility import (  # noqa: E402
    CONDITION_IDS, INDETERMINATE, MET, UNMET, evaluate_eligibility,
)
from tools.fabric.models import RECORD_MODELS  # noqa: E402

SOON = STAMP + timedelta(days=2)
STALE_AT = STAMP + timedelta(days=3)
BEFORE = STAMP - timedelta(hours=1)

# The one classification the fixtures use, and one the host never declares.
FOREIGN_CLASS = "operator-restricted"


def verdict_for(store, trust_store, instance_id, request, instant):
    """One evaluation, reporting anything that escapes it as a failure.

    C5 is specified total, so an exception is itself a defect: an evaluator
    that raises has answered neither "eligible" nor "ineligible", and a caller
    that must catch to learn the verdict has no verdict.
    """
    try:
        return evaluate_eligibility(store, trust_store, instance_id=instance_id,
                                    request=request, evaluated_at=instant), None
    except BaseException as error:  # noqa: BLE001
        return None, error


def unmet_of(verdict):
    return () if verdict is None else tuple(verdict.unmet)


def reason_for(verdict, condition_id):
    """The reason C5 gave for one condition, or None."""
    if verdict is None:
        return None
    for result in verdict.conditions:
        if result.condition_id == condition_id:
            return result.reason
    return None


def status_of(verdict, condition_id):
    if verdict is None:
        return None
    for result in verdict.conditions:
        if result.condition_id == condition_id:
            return result.status
    return None


class DomainVerify:
    """The released C3 adapter, with one domain's answer substituted.

    Delegates every other domain rather than answering it, so a test that
    fails one half of trust still proves the other half was really verified.
    """

    def __init__(self, domain=None, verification=None):
        self.domain = domain
        self.verification = verification
        self.calls = []

    def __call__(self, store, record_id, *, evaluated_at, expected_subject_type=None):
        self.calls.append(expected_subject_type)
        if self.domain is not None and expected_subject_type == self.domain:
            return self.verification
        return RELEASED_TRUST_VERIFY_8(store, record_id, evaluated_at=evaluated_at,
                                       expected_subject_type=expected_subject_type)


def standing_of(subject_id, standing, reason, subject_type):
    """A refused C3 answer naming one standing and one controlled reason."""
    return trust_adapter.TrustVerification(
        subject_id=subject_id, status=trust_adapter.UNVERIFIED, standing=standing,
        stored_standing=standing, evaluated_at=LATER.isoformat(),
        lineage_id="TLIN-000001", record_id="TREC-000001-v0001",
        decision_id="TDEC-000001", reasons=(reason,), subject_type=subject_type)


class UnreadableStore(FabricStore):
    """The real store, refusing every record read.

    A store that cannot be read is not a store that says "eligible": the
    accepted failure behaviour is ineligible with the reason named.
    """

    def read_record(self, kind, identifier):
        raise FabricError("the record could not be read")


def i8_world(tmp, *, contract=None, package=None, advert=None, instance=None):
    """Capability, contract, package, admitted host, claim, and one binding.

    Built through the released operations only. An instance assembled by
    writing records directly would prove eligibility against a store no
    governed path could produce.
    """
    store = opened(tmp)
    trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
    cap = declare_capability(store, **dict(BASE_CAPABILITY, request_id="i8-cap"))
    interface = dict(BASE_CONTRACT, request_id="i8-con",
                     capability_id=cap.record_id)
    interface.update(contract or {})
    con = declare_contract(store, **interface)
    artefact = dict(INSTANCE_PACKAGE, request_id="i8-pkg",
                    capability_id=cap.record_id, contract_id=con.record_id)
    artefact.update(package or {})
    pkg = declare_package(store, **artefact)
    adm = admit_subject(store, trust_store, **dict(
        BASE_SUBJECT, request_id="i8-host",
        fabric_node_trust_record_id=host_trust.record.record_id))
    claim = dict(BASE_ADVERT, request_id="i8-adv", actor=adm.record_id,
                 capability_host_id=adm.record_id,
                 capability_package_id=pkg.record_id,
                 contract_id=con.record_id, observed_at=STAMP, valid_until=YEAR)
    claim.update(advert or {})
    adv = register_advertisement(store, **claim)
    binding = dict(BASE_INSTANCE, request_id="i8-inst",
                   capability_id=cap.record_id,
                   capability_package_id=pkg.record_id,
                   capability_host_id=adm.record_id, contract_id=con.record_id,
                   advertisement_id=adv.record_id,
                   package_trust_record_id=package_trust.record.record_id,
                   host_trust_record_id=host_trust.record.record_id)
    binding.update(instance or {})
    inst = admission_module.admit_instance(store, trust_store, **binding)
    check(all(result.outcome == ACCEPTED
              for result in (cap, con, pkg, adm, adv, inst)),
          "the increment 8 world is admitted through the released operations")
    request = {"capability_id": cap.record_id, "contract_id": con.record_id,
               "accepted_contract_versions": ("1.0.0",),
               "data_classification": "internal"}
    return store, trust_store, request, cap, con, pkg, adm, adv, inst


def variant_instance(store, source_id, identifier, **changes):
    """A second stored binding differing from an accepted one in named fields.

    The released admission path refuses these states, which is the point: a
    store can still hold one after damage or a legacy write, and a derived
    verdict has to refuse on what it reads rather than assume validation ran.
    """
    payload = dict(store.read_record("capability-instance", source_id))
    payload["instance_id"] = identifier
    for name, value in changes.items():
        if value is None and name in payload:
            del payload[name]
        else:
            payload[name] = value
    store.write_atomic(store.path_for("capability-instance", identifier), payload)
    return identifier


# --- 1. The evaluator exists, and it is the only thing that arrived ---------
check(callable(getattr(eligibility_module, "evaluate_eligibility", None)),
      "increment 8 exposes the C5 evaluator")
check(tuple(CONDITION_IDS) == tuple(f"ELIG-{number}" for number in range(1, 13)),
      "C5 enumerates exactly ELIG-1 through ELIG-12, in schema order")
for later in ("ELIG-13", "ELIG-14"):
    check(later not in tuple(CONDITION_IDS),
          f"{later} stays out of C5 and belongs to C6 at increment 9")

for later in ("select", "select_candidate", "resolve_route", "rank", "order",
              "choose", "score", "weight", "health", "remediate", "invoke",
              "load_capability", "persist", "store_verdict", "allocate_id",
              "write", "write_record", "write_atomic", "commit"):
    check(not hasattr(eligibility_module, later),
          f"the eligibility evaluator exposes no '{later}' behaviour at increment 8")

for absent in ("health.py",
               "trust.py", "ledger.py"):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 8 creates no {absent}")
check(len(RECORD_MODELS) == 8,
      "increment 8 introduces no ninth persistent record type")

ELIGIBILITY_SOURCE = (root / "tools" / "fabric" / "eligibility.py").read_text(
    encoding="utf-8")
for token, description in (
        ("random", "randomness"),
        ("datetime.now", "a clock of its own"),
        ("utcnow", "a clock of its own"),
        ("time.time", "a clock of its own"),
        ("socket", "a network path"),
        ("urllib", "a network path"),
        ("requests", "a network path"),
        ("subprocess", "a subprocess"),
        ("os.environ", "an environment dependency"),
        ("getenv", "an environment dependency"),
        ("lru_cache", "a cached verdict"),
        ("ELIG-13", "an increment 9 condition"),
        ("ELIG-14", "an increment 9 condition"),
        ("side-effecting", "an effect-class routing rule"),
        ("route", "route membership"),
        ("CSEL", "a selection record")):
    check(token not in ELIGIBILITY_SOURCE,
          f"the eligibility evaluator contains no {description} ('{token}')")

# --- 2. A fully eligible binding ------------------------------------------
with TemporaryDirectory() as tmp:
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    counting = DomainVerify()
    eligibility_module.verify_trust_record = counting
    try:
        verdict, error = verdict_for(store, trust_store, inst.record_id,
                                     request, LATER)
    finally:
        eligibility_module.verify_trust_record = RELEASED_TRUST_VERIFY_8
    check(error is None, f"a fully eligible binding evaluates without raising ({error})")
    check(verdict is not None and verdict.eligible,
          "a binding meeting all twelve conditions is eligible")
    check(unmet_of(verdict) == (), "an eligible verdict names no unmet condition")
    check(verdict is not None and verdict.reasons == (),
          "an eligible verdict carries no reason")
    check(verdict is not None
          and tuple(result.status for result in verdict.conditions)
          == tuple(MET for _ in CONDITION_IDS),
          "every one of the twelve conditions is reported met individually")
    check(verdict is not None
          and tuple(result.condition_id for result in verdict.conditions)
          == tuple(CONDITION_IDS),
          "the per-condition results are reported in schema order")
    check(verdict is not None and verdict.instance_id == inst.record_id,
          "the verdict names the binding it was asked about")
    check(verdict is not None and verdict.evaluated_at == LATER.isoformat(),
          "the verdict carries the supplied instant and introduces no other time")
    check(sorted(counting.calls) == ["capability-package", "fabric-node"],
          "C5 reaches trust twice, once per domain, through C3 only")

# --- 3. Each of ELIG-1 … ELIG-12 failing in isolation ----------------------
# Trust standing, twice, in two domains. Quarantine is reported as quarantine
# and drain as drain: one is a judgement that something is suspect, the other
# an operator withdrawing a working node, and reporting either as the other
# destroys the distinction an operator needs during an incident.
for domain, subject, condition, standing, reason, description in (
        ("capability-package", "CPKG-0001", "ELIG-1", TrustState.REVOKED.value,
         "trust-revoked", "revoked package trust"),
        ("fabric-node", "node/schai", "ELIG-2", TrustState.REVOKED.value,
         "trust-revoked", "revoked host trust"),
        ("capability-package", "CPKG-0001", "ELIG-1", TrustState.EXPIRED.value,
         "trust-expired", "expired package trust"),
        ("fabric-node", "node/schai", "ELIG-2", TrustState.EXPIRED.value,
         "trust-expired", "expired host trust"),
        ("capability-package", "CPKG-0001", "ELIG-1", TrustState.UNKNOWN.value,
         "trust-unavailable", "an unavailable trust plane, for the package"),
        ("fabric-node", "node/schai", "ELIG-2", TrustState.UNKNOWN.value,
         "trust-unavailable", "an unavailable trust plane, for the host")):
    with TemporaryDirectory() as tmp:
        store, trust_store, request, *_, inst = i8_world(tmp)
        substitute = DomainVerify(
            domain, standing_of(subject, standing, reason, domain))
        eligibility_module.verify_trust_record = substitute
        try:
            verdict, error = verdict_for(store, trust_store, inst.record_id,
                                         request, LATER)
        finally:
            eligibility_module.verify_trust_record = RELEASED_TRUST_VERIFY_8
        check(error is None, f"{description} evaluates without raising ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} makes the binding ineligible")
        check(unmet_of(verdict) == (condition,),
              f"{description} names {condition} and nothing else")
        check(reason_for(verdict, condition) == reason,
              f"{description} is reported as '{reason}'")
        check(status_of(verdict, "ELIG-10") == MET
              and status_of(verdict, "ELIG-11") == MET,
              f"{description} is not reported as quarantine")
        check(status_of(verdict, "ELIG-12") == MET,
              f"{description} is not reported as a drain")

# Quarantine, both subjects. A quarantined subject is also not trusted or
# restricted, so ELIG-1 or ELIG-2 fails with it -- that is what the enumerated
# condition says -- but the quarantine is named in its own right.
for domain, subject, quarantine, trust_condition, description in (
        ("capability-package", "CPKG-0001", "ELIG-11", "ELIG-1",
         "a quarantined package"),
        ("fabric-node", "node/schai", "ELIG-10", "ELIG-2",
         "a quarantined host")):
    with TemporaryDirectory() as tmp:
        store, trust_store, request, *_, inst = i8_world(tmp)
        substitute = DomainVerify(domain, standing_of(
            subject, TrustState.QUARANTINED.value, "trust-not-usable", domain))
        eligibility_module.verify_trust_record = substitute
        try:
            verdict, error = verdict_for(store, trust_store, inst.record_id,
                                         request, LATER)
        finally:
            eligibility_module.verify_trust_record = RELEASED_TRUST_VERIFY_8
        check(error is None, f"{description} evaluates without raising ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} makes the binding ineligible")
        check(quarantine in unmet_of(verdict),
              f"{description} names {quarantine} in its own right")
        check(reason_for(verdict, quarantine)
              == ("package-quarantined" if quarantine == "ELIG-11"
                  else "host-quarantined"),
              f"{description} is reported as quarantine, not as a drain")
        check(status_of(verdict, trust_condition) == UNMET,
              f"{description} is also not trusted or restricted")
        check(status_of(verdict, "ELIG-12") == MET,
              f"{description} is not reported as a drain")

# ELIG-3: the contract offers versions the request does not accept, while the
# package satisfies one that it does. Declared compatibility only -- no
# arithmetic, no nearest match, and no meaning read from any version number.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(
        tmp,
        package={"satisfied_contract_versions": ("1.0.0", "2.0.0")},
        advert={"satisfied_contract_versions": ("1.0.0", "2.0.0")})
    asked = dict(request, accepted_contract_versions=("2.0.0",))
    verdict, error = verdict_for(store, trust_store, inst.record_id, asked, LATER)
    check(error is None, f"an unaccepted contract version evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-3",),
          "a contract compatible with no accepted version fails ELIG-3 alone")
    check(reason_for(verdict, "ELIG-3") == "contract-version-not-accepted",
          "the unmet contract condition names the version intersection")
    check(status_of(verdict, "ELIG-4") == MET,
          "the package half of the version decision is judged separately")

# ELIG-4: the contract declares compatibility with the accepted version and
# the package does not satisfy it. Empty intersection refuses; it never
# upgrades, downgrades, or substitutes a near neighbour.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(
        tmp, contract={"compatible_with": ("2.0.0",)})
    asked = dict(request, accepted_contract_versions=("2.0.0",))
    verdict, error = verdict_for(store, trust_store, inst.record_id, asked, LATER)
    check(error is None, f"an unsatisfied package version evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-4",),
          "a package satisfying no accepted version fails ELIG-4 alone")
    check(reason_for(verdict, "ELIG-4") == "package-version-not-accepted",
          "the unmet package condition names the version intersection")
    check(status_of(verdict, "ELIG-3") == MET,
          "declared contract compatibility is honoured when it is declared")

# ELIG-5: the machine is re-declared with a profile that no longer satisfies
# what the package requires. Containment, never an ordering of two numbers.
with TemporaryDirectory() as tmp:
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    refreshed = admission_module.refresh_subject(
        store, trust_store, request_id="i8-refresh", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP, evaluated_at=LATER,
        capability_host_id=adm.record_id,
        fabric_node_trust_record_id=store.read_record(
            "capability-host", adm.record_id)["fabric_node_trust_record_id"],
        verified_resource_profile={"host_memory_mb": 8192, "host_cpu_cores": 8},
        verification_reference="/approved/evidence/host-reobserved.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=dict(PROV), notes=None)
    check(refreshed.outcome == ACCEPTED,
          "the machine is re-declared with a narrower verified profile")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"an unsatisfied resource requirement evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-5",),
          "a verified profile that no longer satisfies the package fails ELIG-5 alone")
    check(reason_for(verdict, "ELIG-5")
          == "resource-profile-does-not-satisfy-requirements",
          "the unmet resource condition names the containment failure")
    check(status_of(verdict, "ELIG-12") == MET,
          "a re-declared machine that stays in service is not reported drained")

# ELIG-6: the claim lapses while the binding's own window is still open. An
# expiry that removes eligibility changes no authoritative record.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, request, *_, inst = i8_world(
        tmp, advert={"valid_until": SOON})
    before = forensic(fabric_root)
    verdict, error = verdict_for(store, trust_store, inst.record_id,
                                 request, STALE_AT)
    check(error is None, f"a lapsed advertisement evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-6",),
          "an advertisement outside its validity window fails ELIG-6 alone")
    check(reason_for(verdict, "ELIG-6") == "advertisement-not-fresh",
          "the unmet advertisement condition names staleness")
    check(status_of(verdict, "ELIG-7") == MET,
          "an advertisement lapse is not reported as an admission lapse")
    check(forensic(fabric_root) == before,
          "expiry removes eligibility and changes no authoritative record")

# ELIG-7, three ways: absent, expired, and not yet open. Trust alone never
# admits, and an expired admission asserts nothing about trust.
with TemporaryDirectory() as tmp:
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(
        tmp, instance={"admitted_until": SOON})
    verdict, error = verdict_for(store, trust_store, inst.record_id,
                                 request, STALE_AT)
    check(error is None, f"a lapsed admission evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-7",),
          "an admission past its expiry fails ELIG-7 alone")
    check(reason_for(verdict, "ELIG-7") == "admission-window-expired",
          "the unmet admission condition names the elapsed window")
    check(status_of(verdict, "ELIG-1") == MET and status_of(verdict, "ELIG-2") == MET,
          "an expired admission asserts nothing about package or host trust")
    # A fresh claim never revives a lapsed binding.
    later_advert = register_advertisement(store, **dict(
        BASE_ADVERT, request_id="i8-adv-fresh", actor=adm.record_id,
        capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, observed_at=STAMP, valid_until=YEAR))
    check(later_advert.outcome == ACCEPTED, "a fresh advertisement is registered")
    again, error = verdict_for(store, trust_store, inst.record_id,
                               request, STALE_AT)
    check(error is None, f"the fresh claim evaluates cleanly ({error})")
    check(unmet_of(again) == ("ELIG-7",),
          "a fresh advertisement never revives a lapsed admission")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, BEFORE)
    check(error is None, f"an instant before admission evaluates cleanly ({error})")
    check("ELIG-7" in unmet_of(verdict),
          "a binding is not eligible before its own admission began")
    check(reason_for(verdict, "ELIG-7") == "admission-window-not-open",
          "an unopened window is distinguished from an elapsed one")

    absent = variant_instance(store, inst.record_id, "CINST-000900",
                              admission_decision_id="")
    verdict, error = verdict_for(store, trust_store, absent, request, LATER)
    check(error is None, f"an absent admission decision evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-7",),
          "a binding naming no admission decision fails ELIG-7 alone")
    check(reason_for(verdict, "ELIG-7") == "admission-decision-absent",
          "the absent admission is named as the unmet condition")

    unapproved = variant_instance(store, inst.record_id, "CINST-000901",
                                  evidence=dict(store.read_record(
                                      "capability-instance", inst.record_id)
                                      ["evidence"], approving_authority=None))
    verdict, error = verdict_for(store, trust_store, unapproved, request, LATER)
    check(error is None, f"an unapproved admission evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-7",),
          "a binding carrying no approving authority fails ELIG-7 alone")
    check(reason_for(verdict, "ELIG-7") == "admission-not-human-approved",
          "trust alone never admits: the missing human approval is named")

# ELIG-6, absent rather than stale: a binding naming no advertisement at all.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    unclaimed = variant_instance(store, inst.record_id, "CINST-000902",
                                 advertisement_id=None)
    verdict, error = verdict_for(store, trust_store, unclaimed, request, LATER)
    check(error is None, f"a binding with no advertisement evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-6",),
          "a binding naming no advertisement fails ELIG-6 alone")
    check(reason_for(verdict, "ELIG-6") == "advertisement-absent",
          "the absent advertisement is named rather than called stale")

# ELIG-8 and ELIG-9, the scope conditions. An empty intersection is a valid
# outcome, and it means nothing is eligible -- reported as the empty
# intersection, not as a generic scope failure.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    stored_scope = dict(store.read_record("capability-instance",
                                          inst.record_id)["effective_scope"])

    emptied = variant_instance(store, inst.record_id, "CINST-000903",
                               effective_scope=dict(stored_scope,
                                                    permitted_targets=[]))
    verdict, error = verdict_for(store, trust_store, emptied, request, LATER)
    check(error is None, f"an empty scope dimension evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-8",),
          "an empty effective intersection fails ELIG-8 alone")
    check(reason_for(verdict, "ELIG-8") == "empty-effective-scope",
          "the empty intersection is named, not a generic scope refusal")

    refusing = variant_instance(
        store, inst.record_id, "CINST-000904",
        effective_scope=dict(stored_scope,
                             permitted_data_classifications=[FOREIGN_CLASS]))
    verdict, error = verdict_for(store, trust_store, refusing, request, LATER)
    check(error is None, f"a scope refusing the request evaluates cleanly ({error})")
    check("ELIG-8" in unmet_of(verdict),
          "a non-empty scope that does not permit the request fails ELIG-8")
    check(reason_for(verdict, "ELIG-8") == "effective-scope-does-not-permit-request",
          "a scope that refuses the request is distinguished from an empty one")

    mixed = variant_instance(
        store, inst.record_id, "CINST-000905",
        effective_scope=dict(stored_scope,
                             permitted_data_classifications=["internal",
                                                             FOREIGN_CLASS]))
    verdict, error = verdict_for(store, trust_store, mixed, request, LATER)
    check(error is None, f"a classification the host never declared evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-9",),
          "a permitted classification the host does not handle fails ELIG-9 alone")
    check(reason_for(verdict, "ELIG-9") == "data-classification-not-declared-by-host",
          "the unmet classification condition names the host declaration")
    check(status_of(verdict, "ELIG-8") == MET,
          "membership, not rank: the request's own classification is still permitted")

# ELIG-12: an operator withdraws a working machine. Authoritative admission is
# untouched; the binding is ineligible as a derived outcome only.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    withdrawn = admission_module.withdraw_subject(
        store, request_id="i8-drain", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        capability_host_id=adm.record_id, availability_intent="withheld",
        provenance=dict(PROV), notes=None)
    check(withdrawn.outcome == ACCEPTED, "the machine is withdrawn by decision")
    admitted_before = store.read_record("capability-instance", inst.record_id)
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a drained machine evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-12",),
          "a manually drained candidate fails ELIG-12 alone")
    check(reason_for(verdict, "ELIG-12") == "candidate-manually-drained",
          "a drain is reported as a drain, never as quarantine")
    check(status_of(verdict, "ELIG-10") == MET,
          "a withdrawn machine is not reported quarantined")
    check(store.read_record("capability-instance", inst.record_id)
          == admitted_before,
          "withdrawal ends eligibility and edits no admission record")

# --- 4. Several conditions failing at once ---------------------------------
# Every unmet condition is reported, in schema order, so an operator sees the
# whole picture rather than whichever check happened to run first.
with TemporaryDirectory() as tmp:
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(
        tmp, advert={"valid_until": SOON})
    withdrawn = admission_module.withdraw_subject(
        store, request_id="i8-multi-drain", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        capability_host_id=adm.record_id, availability_intent="withheld",
        provenance=dict(PROV), notes=None)
    check(withdrawn.outcome == ACCEPTED, "the machine is withdrawn for the matrix")
    substitute = DomainVerify("capability-package", standing_of(
        "CPKG-0001", TrustState.REVOKED.value, "trust-revoked",
        "capability-package"))
    eligibility_module.verify_trust_record = substitute
    try:
        verdict, error = verdict_for(store, trust_store, inst.record_id,
                                     request, STALE_AT)
        again, _ = verdict_for(store, trust_store, inst.record_id,
                               request, STALE_AT)
    finally:
        eligibility_module.verify_trust_record = RELEASED_TRUST_VERIFY_8
    check(error is None, f"three simultaneous failures evaluate cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-1", "ELIG-6", "ELIG-12"),
          "every unmet condition is reported, in schema order")
    check(verdict is not None
          and verdict.reasons == ("trust-revoked", "advertisement-not-fresh",
                                  "candidate-manually-drained"),
          "the reasons follow the same order as the conditions that produced them")
    check(again is not None and verdict is not None
          and again.to_dict() == verdict.to_dict(),
          "repeating the identical evaluation produces the identical verdict")

# --- 5. Lifecycle boundaries ----------------------------------------------
# Withdrawal and retirement are decisions recorded as new records. The binding
# a route still names resolves to its own head, so a verdict read from the
# record a route was written against is not a verdict about a stale one.
for operation, state, description in (
        ("withdraw_instance", "withdrawn", "a withdrawn binding"),
        ("retire_instance", "retired", "a retired binding")):
    with TemporaryDirectory() as tmp:
        store, trust_store, request, *_, inst = i8_world(tmp)
        ended = OPERATIONS[operation](
            store, request_id=f"i8-{state}", actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP,
            instance_id=inst.record_id, provenance=dict(PROV), notes=None)
        check(ended.outcome == ACCEPTED, f"{description} is ended by decision")
        verdict, error = verdict_for(store, trust_store, inst.record_id,
                                     request, LATER)
        check(error is None, f"{description} evaluates cleanly ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} is not eligible")
        check(verdict is not None and "instance-not-admitted" in verdict.reasons,
              f"{description} names the lifecycle decision that ended it")
        check(unmet_of(verdict) == (),
              f"{description} is refused by its lifecycle, not by a trust or scope check")

# --- 6. Host disappearance is derived, and changes nothing -----------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    store.path_for("capability-host", adm.record_id).unlink()
    before = forensic(fabric_root)
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a disappeared host evaluates cleanly ({error})")
    check(verdict is not None and not verdict.eligible,
          "a binding whose host has disappeared is ineligible")
    check(reason_for(verdict, "ELIG-5") == "host-not-resolvable",
          "the absent host is named rather than guessed at")
    check(status_of(verdict, "ELIG-12") == INDETERMINATE,
          "a condition that could not be read is indeterminate, never met")
    check(forensic(fabric_root) == before,
          "host disappearance changes no authoritative record")

# --- 7. Malformed input is refused, never interpreted ----------------------
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    for asked, reason, description in (
            (dict(request, unexpected="value"), "malformed-request-classification",
             "an unknown request field"),
            ({key: value for key, value in request.items() if key != "contract_id"},
             "malformed-request-classification", "a request missing a field"),
            (dict(request, accepted_contract_versions=()),
             "malformed-request-classification", "an empty accepted version set"),
            (dict(request, accepted_contract_versions="1.0.0"),
             "malformed-request-classification", "a version set that is text"),
            (dict(request, accepted_contract_versions=(1,)),
             "malformed-request-classification", "a version that is not text"),
            (dict(request, data_classification="unheard-of"),
             "malformed-request-classification", "an unknown data classification"),
            (dict(request, capability_id="CAPDEF-9"),
             "malformed-request-classification", "a malformed capability identity"),
            ("a request", "malformed-request-classification",
             "a request that is not a mapping")):
        verdict, error = verdict_for(store, trust_store, inst.record_id, asked, LATER)
        check(error is None, f"{description} evaluates without raising ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} is ineligible")
        check(verdict is not None and verdict.reasons == (reason,),
              f"{description} is reported as '{reason}'")
        check(verdict is not None
              and tuple(result.status for result in verdict.conditions)
              == tuple(INDETERMINATE for _ in CONDITION_IDS),
              f"{description} leaves every condition indeterminate, never met")

    for instant, description in (
            (LATER.replace(tzinfo=None), "an instant carrying no offset"),
            ("2026-08-03T09:00:00-05:00", "an instant supplied as text"),
            (None, "an absent instant")):
        verdict, error = verdict_for(store, trust_store, inst.record_id,
                                     request, instant)
        check(error is None, f"{description} evaluates without raising ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} is ineligible")
        check(verdict is not None
              and verdict.reasons == ("evaluation-instant-carries-no-offset",),
              f"{description} names the unusable instant")

    for identifier, reason, description in (
            ("CINST-999999", "instance-not-found", "an absent binding"),
            ("CINST-99", "malformed-instance-identity", "a malformed identity"),
            (None, "malformed-instance-identity", "an absent identity"),
            ("../escape", "malformed-instance-identity", "a traversing identity")):
        verdict, error = verdict_for(store, trust_store, identifier, request, LATER)
        check(error is None, f"{description} evaluates without raising ({error})")
        check(verdict is not None and not verdict.eligible,
              f"{description} is ineligible")
        check(verdict is not None and verdict.reasons == (reason,),
              f"{description} is reported as '{reason}'")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    unreadable = UnreadableStore(Path(tmp) / "fabric", expected_uid=UID,
                                 expected_gid=GID)
    verdict, error = verdict_for(unreadable, trust_store, inst.record_id,
                                 request, LATER)
    check(error is None, f"an unreadable store evaluates without raising ({error})")
    check(verdict is not None and not verdict.eligible,
          "an unreadable store yields ineligible, never a cached or assumed verdict")
    check(verdict is not None and "store-unreadable" in verdict.reasons,
          "an unreadable store is named as the reason")

# --- 8. Purity: nothing is written, allocated, or remembered ---------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, request, *_, inst = i8_world(tmp)
    counting = DomainVerify()
    eligibility_module.verify_trust_record = counting
    try:
        before_fabric = forensic(fabric_root)
        before_trust = forensic(trust_root)
        verdicts = [evaluate_eligibility(store, trust_store,
                                         instance_id=inst.record_id,
                                         request=request, evaluated_at=LATER)
                    for _ in range(4)]
        after_fabric = forensic(fabric_root)
        after_trust = forensic(trust_root)
    finally:
        eligibility_module.verify_trust_record = RELEASED_TRUST_VERIFY_8
    check(after_fabric == before_fabric,
          "evaluating eligibility writes no fabric record, sequence, or temporary")
    check(after_trust == before_trust,
          "evaluating eligibility writes nothing into the trust store")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "evaluating eligibility leaves no temporary artefact")
    check(len({str(verdict.to_dict()) for verdict in verdicts}) == 1,
          "four identical evaluations produce one identical answer")
    check(len(counting.calls) == 8,
          "trust is asked afresh every evaluation; no verdict is cached")
    check(all(verdict.evaluated_at == LATER.isoformat() for verdict in verdicts),
          "the verdict carries only the instant it was given")
    rendered = str(verdicts[0].to_dict())
    for token, leak in ((" 0x", "an object address"), (str(tmp), "a filesystem path"),
                        ("Traceback", "a traceback"), ("object at", "an object repr")):
        check(token not in rendered, f"a verdict leaks no {leak}")
    check(dataclasses.is_dataclass(verdicts[0]),
          "the verdict is a declared shape rather than an open mapping")
    editable = True
    try:
        verdicts[0].eligible = True
    except Exception:  # noqa: BLE001
        editable = False
    check(not editable, "a verdict cannot be edited after it is returned")


# --- 9. One binding is one chain, and a supersession is not part of it -----
# A lifecycle decision continues a binding; a declared supersession starts a
# new one. Reading across that boundary would answer about a different binding
# than the one that was asked about, and during a declared overlap the old
# binding is still serving -- so the answer would be wrong exactly when it
# matters.
I8_ID_FIELD = {"capability-instance": "instance_id",
               "capability-host": "capability_host_id"}


def copied(store, record_kind, source, identifier, **changes):
    """One record written straight to the store, from an accepted one.

    The released path refuses most of these states, which is the point: a
    damaged, tampered, or legacy store can still hold one, and a derived
    verdict has to refuse on what it reads rather than assume validation ran.

    The record class is a positional named `record_kind`, so a test may change
    the stored `kind` field itself without colliding with it.
    """
    payload = dict(store.read_record(record_kind, source))
    payload[I8_ID_FIELD[record_kind]] = identifier
    for name, value in changes.items():
        if value is None and name in payload:
            del payload[name]
        else:
            payload[name] = value
    store.write_atomic(store.path_for(record_kind, identifier), payload)
    return identifier


def migrated_world(tmp):
    """Binding A, then binding B declared as superseding it."""
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    claim = register_advertisement(store, **dict(
        BASE_ADVERT, request_id="i8-adv-migrate", actor=adm.record_id,
        capability_host_id=adm.record_id, capability_package_id=pkg.record_id,
        contract_id=con.record_id, observed_at=STAMP, valid_until=YEAR))
    binding = dict(BASE_INSTANCE, request_id="i8-migrate",
                   capability_id=cap.record_id,
                   capability_package_id=pkg.record_id,
                   capability_host_id=adm.record_id, contract_id=con.record_id,
                   advertisement_id=claim.record_id,
                   package_trust_record_id=PACKAGE_TRUST["CPKG-0001"],
                   host_trust_record_id=store.read_record(
                       "capability-host",
                       adm.record_id)["fabric_node_trust_record_id"],
                   supersedes=inst.record_id)
    migrated = admission_module.admit_instance(store, trust_store, **binding)
    check(claim.outcome == ACCEPTED and migrated.outcome == ACCEPTED,
          "a declared supersession is admitted through the released path")
    stored = store.read_record("capability-instance", migrated.record_id)
    check((stored.get("evidence") or {}).get("reason_category") == "supersession",
          "the superseding record is categorised as a supersession, not a lifecycle version")
    check(stored.get("supersedes") == inst.record_id,
          "the superseding record declares the binding it replaces")
    return store, trust_store, request, inst.record_id, migrated.record_id


for ending, description in (("withdraw_instance", "withdrawn"),
                            ("retire_instance", "retired")):
    with TemporaryDirectory() as tmp:
        store, trust_store, request, first, second = migrated_world(tmp)

        before_a, error = verdict_for(store, trust_store, first, request, LATER)
        before_b, other = verdict_for(store, trust_store, second, request, LATER)
        check(error is None and other is None,
              f"both bindings evaluate cleanly before {description} ({error} {other})")
        check(before_a is not None and before_a.eligible,
              "the superseded binding stays eligible during the declared overlap")
        check(before_b is not None and before_b.eligible,
              "the new binding is eligible during the declared overlap")
        check(before_a is not None and before_a.instance_id == first
              and before_b is not None and before_b.instance_id == second,
              "each verdict names the binding it was asked about")

        ended = OPERATIONS[ending](
            store, request_id=f"i8-end-{description}", actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP,
            instance_id=second, provenance=dict(PROV), notes=None)
        check(ended.outcome == ACCEPTED,
              f"the new binding is {description} by decision")

        after_a, error = verdict_for(store, trust_store, first, request, LATER)
        after_b, other = verdict_for(store, trust_store, second, request, LATER)
        check(error is None and other is None,
              f"both bindings evaluate cleanly after {description} ({error} {other})")
        check(after_b is not None and not after_b.eligible,
              f"the {description} binding is ineligible")
        check(after_b is not None and "instance-not-admitted" in after_b.reasons,
              f"the {description} binding names the lifecycle decision that ended it")
        check(after_a is not None and after_a.eligible,
              f"the superseded binding is unaffected by the new binding being {description}")
        check(after_a is not None and after_a.reasons == (),
              "a verdict about one binding is never derived from another's lifecycle")
        check(store.read_record("capability-instance", first)["lifecycle_state"]
              == "admitted",
              "the superseded binding's own authoritative state is untouched")

# A lifecycle version of the binding itself is still followed. The boundary
# excludes supersessions, not withdrawals -- otherwise ending a binding would
# stop being observable at all.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    ended = OPERATIONS["withdraw_instance"](
        store, request_id="i8-continue", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        instance_id=inst.record_id, provenance=dict(PROV), notes=None)
    check(ended.outcome == ACCEPTED, "the binding is withdrawn by decision")
    stored = store.read_record("capability-instance", ended.record_id)
    check((stored.get("evidence") or {}).get("reason_category") == "withdrawal",
          "a withdrawal is categorised as a lifecycle version of the same binding")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a continued binding evaluates cleanly ({error})")
    check(verdict is not None and not verdict.eligible
          and "instance-not-admitted" in verdict.reasons,
          "a lifecycle continuation is followed and ends eligibility")

# --- 10. Validated-read parity on both traversed chains --------------------
# The same standard C4 holds a governed decision to. A chain that cannot be
# read is not a chain that was read, and a derived verdict must refuse on it
# rather than assume validation ran. Nothing here is repaired, skipped, or
# guessed at.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    host_id = store.read_record("capability-instance",
                                inst.record_id)["capability_host_id"]
    evidence = store.read_record("capability-instance",
                                 inst.record_id)["evidence"]

    # A record filed as one kind and declaring another.
    copied(store, "capability-instance", inst.record_id, "CINST-000910",
           kind="capability-host")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a wrong-kind instance record evaluates cleanly ({error})")
    check(verdict is not None and not verdict.eligible,
          "a record declaring a different kind makes the binding chain unreadable")
    check(verdict is not None and verdict.reasons == ("instance-chain-unreadable",),
          "the unreadable binding chain is named, and the record is not skipped")
    check(verdict is not None
          and tuple(result.status for result in verdict.conditions)
          == tuple(INDETERMINATE for _ in CONDITION_IDS),
          "an unreadable binding chain leaves every condition indeterminate")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    host_id = store.read_record("capability-instance",
                                inst.record_id)["capability_host_id"]
    copied(store, "capability-host", host_id, "CHOST-0009",
           kind="capability-instance")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a wrong-kind host record evaluates cleanly ({error})")
    check(verdict is not None and not verdict.eligible,
          "a record declaring a different kind makes the machine chain unreadable")
    check(reason_for(verdict, "ELIG-5") == "host-chain-unreadable",
          "the unreadable machine chain is named")
    check(status_of(verdict, "ELIG-12") == INDETERMINATE,
          "a drain cannot be judged through an unreadable machine chain")

# A successor whose declared predecessor is absent. It does not become the
# head, and it does not vanish: a record at the end of a broken chain is
# evidence that something is missing, not evidence that it is current.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    evidence = store.read_record("capability-instance",
                                 inst.record_id)["evidence"]
    copied(store, "capability-instance", inst.record_id, "CINST-000911",
           supersedes="CINST-000899",
           evidence=dict(evidence, reason_category="withdrawal"))
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"an orphaned binding successor evaluates cleanly ({error})")
    check(verdict is not None and verdict.reasons == ("instance-chain-unreadable",),
          "a successor naming an absent predecessor makes the binding chain unreadable")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    host_id = store.read_record("capability-instance",
                                inst.record_id)["capability_host_id"]
    copied(store, "capability-host", host_id, "CHOST-0008",
           supersedes="CHOST-0007")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"an orphaned host successor evaluates cleanly ({error})")
    check(reason_for(verdict, "ELIG-5") == "host-chain-unreadable",
          "a host successor naming an absent predecessor makes that chain unreadable")

# Two records claiming one predecessor is a fork, reported rather than
# resolved: choosing a winner nobody chose would be a repair.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    evidence = store.read_record("capability-instance",
                                 inst.record_id)["evidence"]
    lifecycle = dict(evidence, reason_category="withdrawal")
    copied(store, "capability-instance", inst.record_id, "CINST-000912",
           supersedes=inst.record_id, evidence=lifecycle)
    copied(store, "capability-instance", inst.record_id, "CINST-000913",
           supersedes=inst.record_id, evidence=lifecycle)
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a forked binding chain evaluates cleanly ({error})")
    check(verdict is not None and verdict.reasons == ("instance-chain-unreadable",),
          "two binding successors claiming one predecessor is refused, not resolved")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    host_id = store.read_record("capability-instance",
                                inst.record_id)["capability_host_id"]
    copied(store, "capability-host", host_id, "CHOST-0006", supersedes=host_id)
    copied(store, "capability-host", host_id, "CHOST-0007", supersedes=host_id)
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a forked host chain evaluates cleanly ({error})")
    check(reason_for(verdict, "ELIG-5") == "host-chain-unreadable",
          "two host successors claiming one predecessor is refused, not resolved")

# A cycle is walked once and refused. Nothing here loops.
with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    evidence = store.read_record("capability-instance",
                                 inst.record_id)["evidence"]
    lifecycle = dict(evidence, reason_category="withdrawal")
    copied(store, "capability-instance", inst.record_id, "CINST-000914",
           supersedes="CINST-000915", evidence=lifecycle)
    copied(store, "capability-instance", inst.record_id, "CINST-000915",
           supersedes="CINST-000914", evidence=lifecycle)
    verdict, error = verdict_for(store, trust_store, "CINST-000914", request, LATER)
    check(error is None, f"a cyclic binding chain evaluates cleanly ({error})")
    check(verdict is not None and verdict.reasons == ("instance-chain-unreadable",),
          "a cyclic binding chain is refused rather than walked forever")

with TemporaryDirectory() as tmp:
    store, trust_store, request, *_, inst = i8_world(tmp)
    host_id = store.read_record("capability-instance",
                                inst.record_id)["capability_host_id"]
    copied(store, "capability-host", host_id, "CHOST-0006", supersedes="CHOST-0007")
    copied(store, "capability-host", host_id, "CHOST-0007", supersedes="CHOST-0006")
    cyclic = copied(store, "capability-instance", inst.record_id, "CINST-000916",
                    capability_host_id="CHOST-0006")
    verdict, error = verdict_for(store, trust_store, cyclic, request, LATER)
    check(error is None, f"a cyclic host chain evaluates cleanly ({error})")
    check(reason_for(verdict, "ELIG-5") == "host-chain-unreadable",
          "a cyclic host chain is refused rather than walked forever")

# --- 11. A drain is still observed through the machine's own chain ---------
# The binding boundary applies to bindings. A machine chain is one machine
# re-declared, so every host successor still continues it.
with TemporaryDirectory() as tmp:
    store, trust_store, request, cap, con, pkg, adm, adv, inst = i8_world(tmp)
    drained = admission_module.withdraw_subject(
        store, request_id="i8-drain-parity", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        capability_host_id=adm.record_id, availability_intent="draining",
        provenance=dict(PROV), notes=None)
    check(drained.outcome == ACCEPTED, "the machine is set draining by decision")
    check(store.read_record("capability-host",
                            drained.record_id)["availability_intent"] == "draining",
          "the superseding machine record carries the drained intent")
    verdict, error = verdict_for(store, trust_store, inst.record_id, request, LATER)
    check(error is None, f"a draining machine evaluates cleanly ({error})")
    check(unmet_of(verdict) == ("ELIG-12",),
          "a draining machine still fails ELIG-12 alone through its own chain")
    check(reason_for(verdict, "ELIG-12") == "candidate-manually-drained",
          "the drain is still reported as a drain")

# --- 12. The correction introduces no side effect -------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, request, first, second = migrated_world(tmp)
    before_fabric = forensic(fabric_root)
    before_trust = forensic(trust_root)
    answers = [evaluate_eligibility(store, trust_store, instance_id=identity,
                                    request=request, evaluated_at=LATER)
               for identity in (first, second, first, second)]
    check(forensic(fabric_root) == before_fabric,
          "resolving a binding chain writes no fabric record, sequence, or temporary")
    check(forensic(trust_root) == before_trust,
          "resolving a binding chain writes nothing into the trust store")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "resolving a binding chain leaves no temporary artefact")
    check(answers[0].to_dict() == answers[2].to_dict()
          and answers[1].to_dict() == answers[3].to_dict(),
          "chain resolution is deterministic across repetition")

check(eligibility_module.verify_trust_record is RELEASED_TRUST_VERIFY_8,
      "the released C3 adapter is restored after the increment 8 regression")


# =======================================================================
# C4 capability anchor — the composed scope must name what is being bound
# =======================================================================
# Composing three grants proves they overlap; it proves nothing about *what*
# they overlap on. Until the binding's own capability is checked against the
# composed capability dimension, a grant covering one workload admits a binding
# for another, and every component downstream believes the operator authorised
# it.
#
# The identity compared is the canonical `CAPDEF-0000` the Fabric allocated.
# There is no alias field, no name mapping, and no fallback: a grant naming a
# capability some other way authorises nothing, which is the refusal an
# operator can act on rather than a guess nobody reviewed.

CAPABILITY_SCOPE_REASON = "capability-not-permitted-by-scope"
check(getattr(admission_module, "REASON_CAPABILITY_SCOPE", None)
      == CAPABILITY_SCOPE_REASON,
      "the runtime vocabulary names capability-not-permitted-by-scope")
check(CAPABILITY_SCOPE_REASON != admission_module.REASON_EMPTY_SCOPE,
      "a capability outside the composed scope is not reported as an empty one")
check(CAPABILITY_SCOPE_REASON != admission_module.REASON_CLASSIFICATION,
      "the capability dimension carries its own reason, not the classification one")


def anchored(tmp, *, granted=("CAPDEF-0001",), bound=("CAPDEF-0001",),
             request_id="c4-anchor"):
    """One admission attempt with the capability dimension under test.

    Both grants and the operator's own bound are authored independently, so a
    test can compose a scope that is non-empty in every dimension and still
    does not name the binding being admitted.
    """
    store = opened(tmp)
    trust_store, host_trust, package_trust = seeded_fabric_trust(
        tmp, capabilities=granted)
    cap, con, pkg, adm, adv, base = fabric_ready(
        tmp, store, trust_store, host_trust, package_trust)
    attempt = dict(base, request_id=request_id,
                   admission_scope=dict(SCOPE, permitted_capabilities=list(bound)))
    return store, trust_store, cap, adm, attempt


# --- 1. The canonical identity, permitted, is admitted --------------------
with TemporaryDirectory() as tmp:
    store, trust_store, cap, adm, attempt = anchored(tmp)
    check(cap.record_id == "CAPDEF-0001",
          "the fabric allocated the capability identity the grants name")
    accepted, error = call("admit_instance", store, trust_store, **attempt)
    check(error is None, f"a permitted capability admits without raising ({error})")
    check(accepted.outcome == ACCEPTED,
          "a binding whose capability the composed scope names is admitted")
    stored = record_of(store, "capability-instance", accepted.record_id)
    check(stored.get("capability_id") == cap.record_id,
          "the admitted binding carries the capability that was authorised")
    check(tuple((stored.get("effective_scope") or {}).get(
              "permitted_capabilities") or ()) == ("CAPDEF-0001",),
          "the composed capability dimension is the canonical identity")

# --- 2. Composed, non-empty, and not this binding's capability -------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, cap, adm, attempt = anchored(
        tmp, granted=("CAPDEF-0001", "CAPDEF-0002"), bound=("CAPDEF-0002",))
    before = forensic(fabric_root)
    before_trust = forensic(trust_root)
    before_sequences = sequences_of(fabric_root)
    refused, error = call("admit_instance", store, trust_store, **attempt)
    check(error is None, f"an unauthorised capability refuses without raising ({error})")
    check(refused.outcome == REFUSED,
          "a binding the composed scope does not name is refused")
    check(refused.reason == CAPABILITY_SCOPE_REASON,
          "the refusal names the capability dimension that did not permit it")
    check(refused.record_id is None, "a refused binding allocates no identity")
    check(forensic(fabric_root) == before,
          "a refused binding writes no fabric record, sequence, or temporary")
    check(sequences_of(fabric_root) == before_sequences,
          "a refused binding advances no identifier sequence")
    check(forensic(trust_root) == before_trust,
          "a refused binding writes nothing into the trust store")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "a refused binding leaves no temporary artefact")
    check(store.list_records("capability-instance") == [],
          "no instance record exists after the refusal")
    check(store.list_records("capability-route") == [],
          "a refused binding mutates no route")
    # The same request, refused identically: a rejected admission records
    # nothing, so repeating it is evaluated afresh against current state.
    again, other = call("admit_instance", store, trust_store, **attempt)
    check(other is None, f"the repeated attempt does not raise ({other})")
    check(again.outcome == refused.outcome and again.reason == refused.reason,
          "the refusal is deterministic across repetition")
    check(forensic(fabric_root) == before,
          "repeating a refused admission still writes nothing")

# --- 3. A descriptive token is not the identity ---------------------------
# `coding-workload` reads like an authorisation and matches nothing. Mapping it
# onto a capability would be a heuristic nobody reviewed.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, cap, adm, attempt = anchored(
        tmp, granted=("coding-workload",), bound=("coding-workload",))
    before = forensic(fabric_root)
    refused, error = call("admit_instance", store, trust_store, **attempt)
    check(error is None, f"a descriptive token refuses without raising ({error})")
    check(refused.outcome == REFUSED,
          "a grant naming a workload token authorises no fabric binding")
    check(refused.reason == CAPABILITY_SCOPE_REASON,
          "a descriptive token is refused as an unnamed capability, not repaired")
    check(refused.record_id is None,
          "a descriptive token allocates nothing")
    check(forensic(fabric_root) == before,
          "a descriptive token writes nothing")
    rendered = str(refused.to_dict())
    check("coding-workload" not in rendered,
          "the refusal does not echo the rejected scope value")

# --- 4. Several permitted identities, exact membership --------------------
# The binding admitted is not the first entry in the composed dimension, so a
# check that compared only the first would pass here and be wrong.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    trust_store, host_trust, package_trust = seeded_fabric_trust(
        tmp, capabilities=("CAPDEF-0001", "CAPDEF-0002"))
    first = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c4-cap-a"))
    second = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c4-cap-b",
                                              name="transcribe speech"))
    check((first.record_id, second.record_id) == ("CAPDEF-0001", "CAPDEF-0002"),
          "two capabilities are declared, in allocation order")
    con = declare_contract(store, **dict(BASE_CONTRACT, request_id="c4-con",
                                         capability_id=second.record_id))
    pkg = declare_package(store, **dict(INSTANCE_PACKAGE, request_id="c4-pkg",
                                        capability_id=second.record_id,
                                        contract_id=con.record_id))
    subject_admitted = admit_subject(store, trust_store, **dict(
        BASE_SUBJECT, request_id="c4-host",
        fabric_node_trust_record_id=host_trust.record.record_id))
    advert = register_advertisement(store, **dict(
        BASE_ADVERT, request_id="c4-adv", actor=subject_admitted.record_id,
        capability_host_id=subject_admitted.record_id,
        capability_package_id=pkg.record_id, contract_id=con.record_id,
        observed_at=STAMP, valid_until=YEAR))
    accepted, error = call(
        "admit_instance", store, trust_store, **dict(
            BASE_INSTANCE, request_id="c4-second", capability_id=second.record_id,
            capability_package_id=pkg.record_id,
            capability_host_id=subject_admitted.record_id,
            contract_id=con.record_id, advertisement_id=advert.record_id,
            package_trust_record_id=package_trust.record.record_id,
            host_trust_record_id=host_trust.record.record_id,
            admission_scope=dict(SCOPE, permitted_capabilities=["CAPDEF-0001",
                                                                "CAPDEF-0002"])))
    check(error is None, f"the second permitted capability admits cleanly ({error})")
    check(accepted.outcome == ACCEPTED,
          "membership, not position: a capability named anywhere in the dimension is admitted")
    stored = record_of(store, "capability-instance", accepted.record_id)
    check(stored.get("capability_id") == "CAPDEF-0002",
          "the admitted binding is the capability that was asked for")
    check(tuple((stored.get("effective_scope") or {}).get(
              "permitted_capabilities") or ()) == ("CAPDEF-0001", "CAPDEF-0002"),
          "both permitted identities survive composition")

# --- 5. An empty dimension stays its own outcome --------------------------
# Two different failures an operator has to tell apart: nothing overlapped at
# all, versus an overlap that does not cover this binding.
with TemporaryDirectory() as tmp:
    store, trust_store, cap, adm, attempt = anchored(
        tmp, granted=("CAPDEF-0001",), bound=("observation",))
    refused, error = call("admit_instance", store, trust_store, **attempt)
    check(error is None, f"an empty capability intersection refuses cleanly ({error})")
    check(refused.outcome == REFUSED,
          "a capability dimension that composes to nothing is refused")
    check(refused.reason == admission_module.REASON_EMPTY_SCOPE,
          "an empty intersection keeps its own reason")
    check(refused.reason != CAPABILITY_SCOPE_REASON,
          "an empty intersection is distinguishable from an unnamed capability")

# --- 6. The anchor runs before anything is allocated ----------------------
# Ordering is the whole point: a refusal after allocation would leave the
# sequence advanced for a binding that does not exist.
ANCHOR_SOURCE = (root / "tools" / "fabric" / "admission.py").read_text(encoding="utf-8")
anchor_at = ANCHOR_SOURCE.find("REASON_CAPABILITY_SCOPE)")
composed_at = ANCHOR_SOURCE.find("effective = _effective_scope(")
commit_at = ANCHOR_SOURCE.find("kind, allocated = _commit(store, \"capability-instance\"")
check(-1 < composed_at < anchor_at < commit_at,
      "the capability anchor is checked after composition and before allocation")

# =======================================================================
# Increment 9 — deterministic selection (C6)
# =======================================================================
# C6 answers "which one, and why not the others" and writes that down. It
# chooses the first eligible candidate in the order a human declared, and it
# records every candidate it considered with the reason each was excluded --
# a record naming only the winner documents the outcome while hiding the
# decision.
#
# It selects; it never runs anything. Eligibility stays C5's, so no condition
# is re-derived here. What C6 owns is route membership, whether the contract's
# effect class may be routed at all, and the locality the route declares --
# and `local-only` is answered from an operator-supplied node identity, never
# from a location class, because several machines are legitimately on-premises.

import tools.fabric.selection as selection_module  # noqa: E402
from tools.fabric.selection import (  # noqa: E402
    CONDITION_EFFECT_CLASS, CONDITION_LOCALITY, CONDITION_ROUTE,
    REASON_HEALTH_REMOVED, REASON_LOCALITY, REASON_NO_ROUTE,
    REASON_NOT_FIRST, REASON_NOT_ROUTABLE, REASON_ROUTE_AMBIGUOUS,
    select_candidate,
)

SELECTION_SOURCE = (root / "tools" / "fabric" / "selection.py").read_text(
    encoding="utf-8")
SELECTION_MODEL = RECORD_MODELS["capability-selection"]

# The two conditions the accepted schema assigns to C6, named as the schema
# names them rather than by their position in a list.
check(CONDITION_ROUTE == "ELIG-13",
      "C6 owns ELIG-13, the route membership condition")
check(CONDITION_EFFECT_CLASS == "ELIG-14",
      "C6 owns ELIG-14, the effect-class condition")
check(CONDITION_LOCALITY not in ("ELIG-13", "ELIG-14"),
      "locality is the route's own policy, not one of the enumerated conditions")

REMOTE_NODE = "node/schoxmox1"
LOCAL_NODE = "node/schai"


def c6_world(tmp, *, locality="any-trusted", second_host=False,
             second_location="on-premises", effect_class="read-only",
             candidates=None, versions=("1.0.0",)):
    """A capability, a contract, a package, admitted hosts, and one route.

    Built entirely through the released governed operations: a selection made
    over a store no admission path could produce would prove nothing about the
    selection.
    """
    store = opened(tmp)
    trust_store, host_trust, package_trust = seeded_fabric_trust(
        tmp, nodes=(REMOTE_NODE,))
    cap = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c6-cap",
                                           effect_class=effect_class))
    con = declare_contract(store, **dict(BASE_CONTRACT, request_id="c6-con",
                                         capability_id=cap.record_id,
                                         effect_class=effect_class))
    pkg = declare_package(store, **dict(INSTANCE_PACKAGE, request_id="c6-pkg",
                                        capability_id=cap.record_id,
                                        contract_id=con.record_id))
    hosts = []
    for index, (node, location) in enumerate(
            ((LOCAL_NODE, "on-premises"),) +
            (((REMOTE_NODE, second_location),) if second_host else ())):
        admitted = admit_subject(store, trust_store, **dict(
            BASE_SUBJECT, request_id=f"c6-host-{index}",
            node_identity_reference=node, location_class=location,
            fabric_node_trust_record_id=NODE_TRUST[node]))
        check(admitted.outcome == ACCEPTED, f"the c6 host {index} is admitted")
        hosts.append(admitted.record_id)

    instances = []
    for index, host_id in enumerate(hosts):
        advert = register_advertisement(store, **dict(
            BASE_ADVERT, request_id=f"c6-adv-{index}", actor=host_id,
            capability_host_id=host_id, capability_package_id=pkg.record_id,
            contract_id=con.record_id, observed_at=STAMP, valid_until=YEAR))
        binding = admission_module.admit_instance(store, trust_store, **dict(
            BASE_INSTANCE, request_id=f"c6-inst-{index}",
            capability_id=cap.record_id, capability_package_id=pkg.record_id,
            capability_host_id=host_id, contract_id=con.record_id,
            advertisement_id=advert.record_id,
            package_trust_record_id=package_trust.record.record_id,
            host_trust_record_id=NODE_TRUST[
                LOCAL_NODE if index == 0 else REMOTE_NODE]))
        check(binding.outcome == ACCEPTED, f"the c6 binding {index} is admitted")
        instances.append(binding.record_id)

    declared = list(instances) if candidates is None else list(candidates)
    route = admission_module.create_route(store, **dict(
        BASE_ROUTE, request_id="c6-route", capability_id=cap.record_id,
        contract_id=con.record_id, candidate_instances=tuple(declared),
        locality=locality, accepted_contract_versions=versions))
    check(route.outcome == ACCEPTED, f"the c6 route is declared ({route.reason})")
    asked = dict(capability_id=cap.record_id, contract_id=con.record_id,
                 accepted_contract_versions=versions,
                 data_classification="internal", locality=locality)
    return store, trust_store, asked, instances, hosts, route


def chosen(store, trust_store, asked, *, request_id="c6-select",
           local_node_identity=LOCAL_NODE, health_removals=(), **overrides):
    """One governed selection, reporting anything that escapes it."""
    call_args = dict(
        actor="core", recorded_at=STAMP, evaluated_at=LATER,
        provenance=dict(PROV), local_node_identity=local_node_identity,
        health_removals=health_removals, **asked)
    call_args.update(overrides)
    try:
        return select_candidate(store, trust_store, request_id=request_id,
                                **call_args), None
    except BaseException as error:  # noqa: BLE001
        return None, error


def written(store, identifier):
    return record_of(store, "capability-selection", identifier)


def excluded_of(record):
    """(instance_id, reasons) per excluded candidate, in recorded order."""
    return tuple((entry.get("instance_id"), tuple(entry.get("reasons") or ()))
                 for entry in (record.get("excluded_candidates") or ()))


# --- A. A request class no route governs ------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp)
    unrouted = dict(asked, capability_id="CAPDEF-0009")
    before = forensic(fabric_root)
    result, error = chosen(store, trust_store, unrouted, request_id="c6-no-route")
    check(error is None, f"a request class with no route selects cleanly ({error})")
    check(result.outcome == ACCEPTED,
          "a request class with no route still produces a governed outcome")
    record = written(store, result.record_id)
    check(record.get("kind") == "capability-selection",
          "the no-route outcome is recorded as a selection record")
    check("route_id" not in record and "route_version" not in record,
          "a no-route decision names neither a route nor a version")
    check(tuple(record.get("considered_candidates") or ()) == (),
          "a no-route decision considered no candidate")
    check(tuple(record.get("excluded_candidates") or ()) == (),
          "a no-route decision excluded no candidate")
    check("selected_instance_id" not in record,
          "a no-route decision selected nothing")
    check(record.get("refusal_reason") == REASON_NO_ROUTE,
          "the no-route decision names why it refused")
    check((record.get("evidence") or {}).get("reason_category") == "no-candidate",
          "the no-route decision is recorded as a no-candidate outcome")
    check((record.get("evidence") or {}).get("request_id") == "c6-no-route",
          "the no-route decision carries the request identity that produced it")
    for fabricated in ("CROUTE-0000", "CROUTE-0001"):
        check(fabricated not in str(record),
              f"the no-route decision invents no route identity ({fabricated})")
    after = forensic(fabric_root)
    created = sorted(path for path in set(after) - set(before)
                     if not path.endswith(".seq"))
    check(created == ["capability-selections/" + result.record_id + ".yaml"],
          f"a no-route decision creates only its selection record ({created})")
    check(all(after[path] == before[path] for path in before
              if path.endswith(".yaml")),
          "a no-route decision changes no existing record")

# --- B/F. One winner, whatever order the store enumerates -------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    first, second = instances
    result, error = chosen(store, trust_store, asked, request_id="c6-winner")
    check(error is None, f"a route with several candidates selects cleanly ({error})")
    check(result.outcome == ACCEPTED, "a selection over eligible candidates is accepted")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == first,
          "the first candidate in declared order wins")
    check(tuple(record.get("considered_candidates") or ()) == tuple(instances),
          "every declared candidate is recorded, in declared order")
    check(record.get("route_id") == route.record_id and record.get("route_version") == 1,
          "a decision a route governed names the route and the version that applied")
    check((record.get("evidence") or {}).get("reason_category") == "selection",
          "a selected outcome is recorded as a selection")
    check(excluded_of(record) == ((second, (REASON_NOT_FIRST,)),),
          "a candidate that lost on order is recorded with why it lost")

# The same logical route, declared in the other order, chooses the other one:
# order is the decision, and nothing else reorders it.
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True, candidates=None)
    reversed_route = admission_module.create_route(store, **dict(
        BASE_ROUTE, request_id="c6-route-reversed",
        capability_id=asked["capability_id"], contract_id=asked["contract_id"],
        candidate_instances=tuple(reversed(instances)),
        locality=asked["locality"],
        accepted_contract_versions=asked["accepted_contract_versions"],
        route_version=2, supersedes=route.record_id))
    check(reversed_route.outcome == ACCEPTED,
          f"the route is superseded with the candidates reversed ({reversed_route.reason})")
    result, error = chosen(store, trust_store, asked, request_id="c6-reversed")
    check(error is None, f"the superseding route selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[1],
          "the first candidate of the current route version wins")
    check(record.get("route_version") == 2,
          "the current route version governs, and is the one recorded")

# --- C. Eligibility is C5's, and its verdict is what gets recorded ----------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    first, second = instances
    ended = admission_module.withdraw_instance(
        store, request_id="c6-withdraw", actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        instance_id=first, provenance=dict(PROV), notes=None)
    check(ended.outcome == ACCEPTED, "the first candidate is withdrawn by decision")
    result, error = chosen(store, trust_store, asked, request_id="c6-filtered")
    check(error is None, f"a mixed candidate set selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == second,
          "an ineligible candidate cannot win, and the next declared one does")
    check(excluded_of(record)[0] == (first, ("instance-not-admitted",)),
          "the exclusion carries C5's own reason, unchanged")
    check(tuple(record.get("considered_candidates") or ()) == tuple(instances),
          "the ineligible candidate is still recorded as considered")

# --- D. A route whose candidates all fail ----------------------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    for index, identifier in enumerate(instances):
        ended = admission_module.withdraw_instance(
            store, request_id=f"c6-withdraw-all-{index}", actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP,
            instance_id=identifier, provenance=dict(PROV), notes=None)
        check(ended.outcome == ACCEPTED, f"candidate {index} is withdrawn")
    result, error = chosen(store, trust_store, asked, request_id="c6-none-eligible")
    check(error is None, f"a route with no eligible candidate selects cleanly ({error})")
    record = written(store, result.record_id)
    check("selected_instance_id" not in record, "nothing is selected")
    check(record.get("route_id") == route.record_id and record.get("route_version") == 1,
          "a refusal over a resolved route still names the route that governed it")
    check(tuple(record.get("considered_candidates") or ()) == tuple(instances),
          "every candidate is named")
    check(tuple(entry[0] for entry in excluded_of(record)) == tuple(instances),
          "every candidate carries its exclusion, in declared order")
    check(all(entry[1] == ("instance-not-admitted",) for entry in excluded_of(record)),
          "each exclusion carries the reason C5 gave")
    check((record.get("evidence") or {}).get("reason_category") == "selection-refusal",
          "a resolved route with nothing eligible is a refusal, not a no-candidate")

# --- E. Candidates alike in every respect still order by declaration -------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True, second_location="on-premises")
    result, error = chosen(store, trust_store, asked, request_id="c6-tie")
    check(error is None, f"indistinguishable candidates select cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[0],
          "candidates alike on every criterion are separated by declared order alone")

# --- G. ELIG-13, the route decides who is a candidate -----------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True, candidates=None)
    only_first = admission_module.create_route(store, **dict(
        BASE_ROUTE, request_id="c6-route-one",
        capability_id=asked["capability_id"], contract_id=asked["contract_id"],
        candidate_instances=(instances[0],), locality=asked["locality"],
        accepted_contract_versions=asked["accepted_contract_versions"],
        route_version=2, supersedes=route.record_id))
    check(only_first.outcome == ACCEPTED,
          f"a route naming one of the two bindings is declared ({only_first.reason})")
    result, error = chosen(store, trust_store, asked, request_id="c6-elig13")
    check(error is None, f"a narrowed route selects cleanly ({error})")
    record = written(store, result.record_id)
    check(tuple(record.get("considered_candidates") or ()) == (instances[0],),
          "ELIG-13: only the candidates the route permits are considered")
    check(instances[1] not in str(record),
          "ELIG-13: an admitted binding the route omits is not selectable")
    check(record.get("selected_instance_id") == instances[0],
          "the permitted candidate is chosen")

# --- H. ELIG-14, a side-effecting contract is unroutable -------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, effect_class="side-effecting")
    result, error = chosen(store, trust_store, asked, request_id="c6-elig14")
    check(error is None, f"an unroutable contract selects cleanly ({error})")
    record = written(store, result.record_id)
    check("selected_instance_id" not in record,
          "ELIG-14: nothing is selected for a side-effecting contract")
    check(record.get("route_id") == route.record_id,
          "the unroutable refusal still names the route it refused over")
    check(all(REASON_NOT_ROUTABLE in entry[1] for entry in excluded_of(record)),
          "ELIG-14: every candidate is excluded as unroutable")
    check((record.get("evidence") or {}).get("reason_category") == "selection-refusal",
          "an unroutable contract refuses rather than reporting no candidate")

# A route cannot lift the prohibition, whatever locality it declares.
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, effect_class="side-effecting", locality="any-trusted")
    result, _ = chosen(store, trust_store, asked, request_id="c6-elig14-override")
    record = written(store, result.record_id)
    check("selected_instance_id" not in record,
          "ELIG-14: no route may override unroutability")

# --- I/J/K. local-only is answered from an identity, never a location ------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="local-only", second_host=True)
    result, error = chosen(store, trust_store, asked, request_id="c6-local-hit",
                           local_node_identity=LOCAL_NODE)
    check(error is None, f"a local-only route selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[0],
          "local-only: the candidate whose host identity matches exactly is chosen")
    check(record.get("local_node_identity") == LOCAL_NODE,
          "a local-only decision records the node identity that governed it")
    check(excluded_of(record)[0] == (instances[1], (REASON_LOCALITY,)),
          "local-only: a candidate on another node is excluded as non-local")

    # The other machine is on-premises too, and that is not what local means.
    remote_host = record_of(store, "capability-host", hosts[1])
    check(remote_host.get("location_class") == "on-premises",
          "the excluded candidate's host is on-premises")
    check(remote_host.get("node_identity_reference") == REMOTE_NODE,
          "the excluded candidate's host is a different node")

with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="local-only", second_host=True)
    result, error = chosen(store, trust_store, asked, request_id="c6-local-miss",
                           local_node_identity=REMOTE_NODE)
    check(error is None, f"a local-only route on another node selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[1],
          "local-only: the node performing the selection decides which candidate is local")

for absent, description in ((None, "no local node identity"),
                            ("", "an empty local node identity"),
                            ("   ", "a blank local node identity")):
    with TemporaryDirectory() as tmp:
        store, trust_store, asked, instances, hosts, route = c6_world(
            tmp, locality="local-only", second_host=True)
        result, error = chosen(store, trust_store, asked,
                               request_id="c6-local-absent",
                               local_node_identity=absent)
        check(error is None, f"{description} selects cleanly ({error})")
        record = written(store, result.record_id)
        check("selected_instance_id" not in record,
              f"local-only with {description} selects nothing")
        check(all(REASON_LOCALITY in entry[1] for entry in excluded_of(record)),
              f"local-only with {description} excludes every candidate")
        check("local_node_identity" not in record,
              f"{description} is recorded as no identity, not as a placeholder")

# --- L. operator-controlled-only excludes the third-party-hosted -----------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="operator-controlled-only", second_host=True,
        second_location="third-party-hosted")
    result, error = chosen(store, trust_store, asked, request_id="c6-operator")
    check(error is None, f"an operator-controlled route selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[0],
          "an operator-controlled host is not excluded by locality")
    check(excluded_of(record)[0] == (instances[1], (REASON_LOCALITY,)),
          "a third-party-hosted candidate is excluded by locality")
    check("local_node_identity" not in record,
          "a locality that consults no node identity records none")

# --- M. any-trusted adds nothing ------------------------------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="any-trusted", second_host=True,
        second_location="third-party-hosted")
    result, error = chosen(store, trust_store, asked, request_id="c6-any")
    check(error is None, f"an any-trusted route selects cleanly ({error})")
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[0],
          "any-trusted selects the first eligible candidate in declared order")
    check(excluded_of(record) == ((instances[1], (REASON_NOT_FIRST,)),),
          "any-trusted excludes no candidate on locality")

# --- N/O. Replay, and the context that governed it -------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="local-only", second_host=True)
    first, error = chosen(store, trust_store, asked, request_id="c6-replay",
                          local_node_identity=LOCAL_NODE)
    check(error is None and first.outcome == ACCEPTED,
          f"the first governed selection is accepted ({error})")
    before = forensic(fabric_root)
    again, error = chosen(store, trust_store, asked, request_id="c6-replay",
                          local_node_identity=LOCAL_NODE)
    check(error is None, f"the exact replay evaluates cleanly ({error})")
    check(again.outcome == EXACT_REPLAY,
          "the same governed selection replays rather than deciding again")
    check(again.record_id == first.record_id,
          "the replay returns the original selection identity")
    check(forensic(fabric_root) == before,
          "an exact replay writes nothing")

    conflicting, error = chosen(store, trust_store, asked, request_id="c6-replay",
                                local_node_identity=REMOTE_NODE)
    check(error is None, f"the conflicting context evaluates cleanly ({error})")
    check(conflicting.outcome == CONFLICT,
          "a different local node context is not the same governed selection")
    check(conflicting.reason == "request_identity_conflict",
          "the conflicting context is named as a request identity conflict")
    check(forensic(fabric_root) == before,
          "a conflicting context writes no second decision")

# --- P. Every decision reconstructs from what was written ------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="local-only", second_host=True)
    selected, _ = chosen(store, trust_store, asked, request_id="c6-recon-selected")
    reread = FabricStore.open_for_read(Path(tmp) / "fabric", expected_uid=UID,
                                       expected_gid=GID)
    stored = reread.read_record("capability-selection", selected.record_id)
    for field in ("route_id", "route_version", "request_class",
                  "considered_candidates", "excluded_candidates",
                  "selected_instance_id", "selection_reason", "selected_at",
                  "provenance", "local_node_identity", "evidence"):
        check(field in stored,
              f"a reconstructed local-only selection carries {field}")
    check(stored["request_class"]["locality"] == "local-only",
          "the request class it decided is readable from the record")
    check(SELECTION_MODEL.from_dict(stored).to_dict() == stored,
          "an accepted selection round-trips through the released model")

# --- Q/S. Only CSEL is written, and health is not consulted ---------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    before = forensic(fabric_root)
    before_trust = forensic(trust_root)
    result, _ = chosen(store, trust_store, asked, request_id="c6-sole-write")
    after = forensic(fabric_root)
    created = sorted(path for path in set(after) - set(before)
                     if not path.endswith(".seq"))
    check(created == ["capability-selections/" + result.record_id + ".yaml"],
          f"a selection creates only its selection record ({created})")
    for kind in ("capability-instance", "capability-route", "capability-host",
                 "capability-definition", "capability-package",
                 "capability-contract", "capability-advertisement"):
        check(all(after[path] == before[path] for path in before
                  if kind.split("-")[-1] + "s" in path),
              f"a selection changes no {kind} record")
    check(forensic(trust_root) == before_trust,
          "a selection writes nothing into the trust store")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "a selection leaves no temporary artefact")

# Health removes and does nothing else. Absent input removes nothing.
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    result, _ = chosen(store, trust_store, asked, request_id="c6-health-absent",
                       health_removals=())
    record = written(store, result.record_id)
    check(record.get("selected_instance_id") == instances[0],
          "absent health input removes nothing")
    removed, _ = chosen(store, trust_store, asked, request_id="c6-health-removed",
                        health_removals=(instances[0],))
    record = written(store, removed.record_id)
    check(record.get("selected_instance_id") == instances[1],
          "a removed candidate cannot win")
    check(excluded_of(record)[0] == (instances[0], (REASON_HEALTH_REMOVED,)),
          "the removal is recorded as the reason it was excluded")
    check(tuple(record.get("considered_candidates") or ()) == tuple(instances),
          "health removes candidates without reordering or adding any")

for forbidden in ("health_score", "healthy", "unhealthy", "heartbeat",
                  "tools.health", "capability-health"):
    check(forbidden not in SELECTION_SOURCE,
          f"the selection engine invents no health behaviour ('{forbidden}')")

# --- R. Unreadable governed input fails closed ----------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp)
    before = forensic(fabric_root)
    for malformed, description in (
            (dict(asked, capability_id="CAPDEF-9"), "a malformed capability identity"),
            (dict(asked, accepted_contract_versions=()), "an empty version set"),
            (dict(asked, data_classification="unheard-of"), "an unknown classification"),
            (dict(asked, locality="anywhere"), "an unknown locality")):
        result, error = chosen(store, trust_store, malformed,
                               request_id=f"c6-bad-{description[:8]}")
        check(error is None, f"{description} evaluates without raising ({error})")
        check(result.outcome in (INVALID, REFUSED),
              f"{description} is refused")
        check(result.record_id is None, f"{description} writes no record")
    check(forensic(fabric_root) == before,
          "a refused governed selection writes nothing at all")


# --- Two routes for one class is refused, never resolved -------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp)
    rival = admission_module.create_route(store, **dict(
        BASE_ROUTE, request_id="c6-route-rival",
        capability_id=asked["capability_id"], contract_id=asked["contract_id"],
        candidate_instances=(instances[0],), locality=asked["locality"],
        accepted_contract_versions=asked["accepted_contract_versions"]))
    check(rival.outcome == ACCEPTED,
          f"a second route for the same class is declarable ({rival.reason})")
    before = forensic(fabric_root)
    result, error = chosen(store, trust_store, asked, request_id="c6-ambiguous")
    check(error is None, f"two competing routes evaluate cleanly ({error})")
    check(result.outcome == REFUSED,
          "two unsuperseded routes for one request class are refused")
    check(result.reason == REASON_ROUTE_AMBIGUOUS,
          "the ambiguity is named rather than resolved by picking one")
    check(result.record_id is None,
          "an ambiguous route universe writes no decision")
    check(forensic(fabric_root) == before,
          "an ambiguous route universe writes nothing at all")

# --- The selection engine claims nothing beyond choosing -------------------
for later in ("invoke", "execute", "run", "load_capability", "dispatch",
              "schedule", "place", "balance", "weight", "score", "rank",
              "remediate", "repair", "retry", "admit", "withdraw"):
    check(not hasattr(selection_module, later),
          f"the selection engine exposes no '{later}' behaviour at increment 9")
for token, description in (("random", "chance"), ("shuffle", "reordering"),
                           ("datetime.now", "a clock of its own"),
                           ("utcnow", "a clock of its own"),
                           ("socket", "a network path"),
                           ("subprocess", "a child process"),
                           ("importlib", "dynamic loading"),
                           ("eval(", "evaluation"), ("exec(", "execution")):
    check(token not in SELECTION_SOURCE,
          f"the selection engine contains no {description} ('{token}')")
check(len(RECORD_MODELS) == 8,
      "increment 9 introduces no ninth persistent record type")
for absent in ("health.py",):
    check(not (root / "tools" / "fabric" / absent).exists(),
          f"increment 9 creates no {absent}")

# =======================================================================
# Increment 10 — inspection and validation surface (C8)
# =======================================================================
# C8 looks and reports. It opens a store for read, exposes what C2 found, and
# adds the deterministic handling C2 has no way to reach: a root that is not
# there, one that cannot be opened, a filter that names nothing.
#
# **Not one byte, under any input.** An absent store is reported as absent
# rather than built and then described; a malformed record is described rather
# than mended; temp residue is named as the evidence of an interrupted write
# and left exactly where it was found. Inspection that repairs what it
# discovers destroys the only account of what happened.
#
# It replaces nothing. C2 still owns the findings; C8 exposes them.

import tools.fabric.inspection as inspection_module  # noqa: E402
from tools.fabric.inspection import (  # noqa: E402
    KIND_ORDER, REASON_ABSENT, REASON_MALFORMED_IDENTITY, REASON_NOT_FOUND,
    REASON_UNKNOWN_KIND, REASON_UNREADABLE, STATUS_ABSENT, STATUS_INVALID,
    STATUS_NOT_FOUND, STATUS_REPORTED, STATUS_UNREADABLE,
    inspect_records, validate_store,
)

INSPECTION_SOURCE = (root / "tools" / "fabric" / "inspection.py").read_text(
    encoding="utf-8")
ID_FIELDS_FOR_C8 = {
    "capability-definition": "capability_id",
    "capability-contract": "contract_id",
    "capability-package": "capability_package_id",
    "capability-host": "capability_host_id",
    "capability-advertisement": "advertisement_id",
    "capability-instance": "instance_id",
    "capability-route": "route_id",
    "capability-selection": "selection_id",
}


def c8_world(tmp):
    """A store with one of everything, built through the released path."""
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, second_host=True)
    selected, _ = chosen(store, trust_store, asked, request_id="c8-selected")
    check(selected.outcome == ACCEPTED, "the c8 world records a selection")
    return store, trust_store, asked, instances, route, selected


def looked(root_path, **overrides):
    """One inspection, reporting anything that escapes it."""
    arguments = dict(expected_uid=UID, expected_gid=GID)
    arguments.update(overrides)
    try:
        return inspect_records(root_path, **arguments), None
    except BaseException as error:  # noqa: BLE001
        return None, error


def checked(root_path, **overrides):
    """One validation, reporting anything that escapes it."""
    arguments = dict(expected_uid=UID, expected_gid=GID)
    arguments.update(overrides)
    try:
        return validate_store(root_path, **arguments), None
    except BaseException as error:  # noqa: BLE001
        return None, error


check(tuple(KIND_ORDER) == tuple(RECORD_MODELS),
      "C8 walks the eight accepted kinds in the order the model declares them")

# --- A. Reading a valid store changes nothing (AC 28, 47) ------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    before = forensic(fabric_root)
    before_trust = forensic(trust_root)
    before_sequences = sequences_of(fabric_root)

    first_look, error = looked(fabric_root)
    second_look, other = looked(fabric_root)
    check(error is None and other is None,
          f"inspecting a valid store raises nothing ({error} {other})")
    check(first_look.status == STATUS_REPORTED,
          "a readable store is reported")
    check(first_look.to_dict() == second_look.to_dict(),
          "inspecting the same store twice returns the identical report")

    first_check, error = checked(fabric_root)
    second_check, other = checked(fabric_root)
    check(error is None and other is None,
          f"validating a valid store raises nothing ({error} {other})")
    check(first_check.status == STATUS_REPORTED, "a readable store validates")
    check(first_check.to_dict() == second_check.to_dict(),
          "validating the same store twice returns the identical report")

    check(forensic(fabric_root) == before,
          "inspection and validation leave every path, mode, size, time and digest identical")
    check(forensic(trust_root) == before_trust,
          "inspection and validation write nothing into the trust store")
    check(sequences_of(fabric_root) == before_sequences,
          "inspection and validation move no identifier")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "inspection and validation leave no temporary artefact")

    # Every accepted kind is counted, and the records are the ones stored.
    check(tuple(first_check.counts) == tuple(RECORD_MODELS),
          "validation counts every accepted kind, in the declared order")
    check(first_check.counts["capability-selection"] == 1,
          "the recorded selection is counted")
    check(first_check.findings == (),
          "a store built through the released path has nothing wrong with it")

# --- B. Records come back in a canonical order, whatever the store enumerates
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    report, error = looked(fabric_root)
    check(error is None, f"inspecting records raises nothing ({error})")
    kinds = tuple(record["kind"] for record in report.records)
    ordered = tuple(sorted(set(kinds), key=tuple(RECORD_MODELS).index))
    check(tuple(sorted(set(kinds), key=kinds.index)) == ordered,
          "records are grouped by kind in the declared order")
    for kind in ordered:
        identities = [record[ID_FIELDS_FOR_C8[kind]] for record in report.records
                      if record["kind"] == kind]
        check(identities == sorted(identities),
              f"{kind} records are returned in identifier order")

    # The same store read again, and a second reader, agree exactly.
    again, _ = looked(fabric_root)
    check([record for record in report.records]
          == [record for record in again.records],
          "repeated inspection returns the identical records in the identical order")

# --- C. One record, by kind and identity ----------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    report, error = looked(fabric_root, kind="capability-selection",
                           identifier=selected.record_id)
    check(error is None, f"inspecting one record raises nothing ({error})")
    check(report.status == STATUS_REPORTED, "a stored record is reported")
    check(len(report.records) == 1, "exactly the record asked for is returned")
    stored = record_of(store, "capability-selection", selected.record_id)
    check(dict(report.records[0]) == stored,
          "the record is reported exactly as it is stored")

    by_kind, _ = looked(fabric_root, kind="capability-instance")
    check({record["instance_id"] for record in by_kind.records} == set(instances),
          "filtering by kind returns that kind and nothing else")

# --- D. Nothing there, and nothing invented -------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    before = forensic(fabric_root)
    missing, error = looked(fabric_root, kind="capability-selection",
                            identifier="CSEL-999999")
    check(error is None, f"an absent record raises nothing ({error})")
    check(missing.status == STATUS_NOT_FOUND, "an absent record is reported not-found")
    check(missing.reason == REASON_NOT_FOUND, "the not-found reason is named")
    check(missing.records == (), "an absent record returns no record")
    check(forensic(fabric_root) == before, "a not-found inspection writes nothing")

    for bad_kind in ("capability-health", "", 7):
        refused, error = looked(fabric_root, kind=bad_kind)
        check(error is None, f"an unsupported kind raises nothing ({error})")
        check(refused.status == STATUS_INVALID,
              "an unsupported record kind is refused")
        check(refused.reason == REASON_UNKNOWN_KIND,
              "the unsupported kind is named as unknown")
        check(refused.records == (),
              "an unsupported kind returns no records rather than all of them")
    for bad_id in ("CSEL-99", "not-an-identity", 7):
        refused, error = looked(fabric_root, kind="capability-selection",
                                identifier=bad_id)
        check(error is None, f"a malformed identity raises nothing ({error})")
        check(refused.status == STATUS_INVALID, "a malformed identity is refused")
        check(refused.reason == REASON_MALFORMED_IDENTITY,
              "the malformed identity is named")
    check(forensic(fabric_root) == before,
          "every refused query leaves the store exactly as it was")

# --- E. An absent root is reported, never built (AC 29, FC 1) -------------
with TemporaryDirectory() as tmp:
    parent = Path(tmp)
    absent = parent / "not-a-store"
    before_parent = forensic(parent)
    for report, error, label in ((*looked(absent), "inspection"),
                                 (*checked(absent), "validation")):
        check(error is None, f"{label} of an absent root raises nothing ({error})")
        check(report.status == STATUS_ABSENT,
              f"{label} reports an absent root as absent")
        check(report.reason == REASON_ABSENT, f"{label} names the absent root")
    check(not absent.exists(), "an absent store root is not created by looking at it")
    check(forensic(parent) == before_parent,
          "the parent of an absent store root is byte-unchanged")

# --- F. Empty is not absent (AC 30, FC 2) ---------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store = opened(tmp)
    before = forensic(fabric_root)
    report, error = checked(fabric_root)
    check(error is None, f"validating an empty store raises nothing ({error})")
    check(report.status == STATUS_REPORTED,
          "an empty store is reported, not called absent")
    check(report.status != STATUS_ABSENT,
          "empty is distinguishable from absent")
    check(sum(report.counts.values()) == 0, "an empty store counts no records")
    check(report.findings == (), "an empty store is not a problem")
    looked_report, error = looked(fabric_root)
    check(error is None and looked_report.records == (),
          "an empty store yields no records")
    check(forensic(fabric_root) == before,
          "looking at an empty store creates no directory and changes nothing")

# --- G. A malformed record is described, never mended (FC 3, AC 44) -------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    broken = store.path_for("capability-selection", "CSEL-000900")
    store.write_atomic(broken, {"schema_version": "schott-platform/v1",
                                "kind": "capability-selection"})
    before = forensic(fabric_root)
    report, error = checked(fabric_root)
    check(error is None, f"a malformed record raises nothing ({error})")
    check(report.status == STATUS_REPORTED,
          "a store containing a malformed record is still reported")
    check(any("CSEL-000900" in finding for finding in report.findings),
          "the malformed record is named in the findings")
    check(forensic(fabric_root) == before,
          "the malformed record is described and left exactly as found")
    again, _ = checked(fabric_root)
    check(again.to_dict() == report.to_dict(),
          "the finding is identical when validation runs again")

# --- H. A reference nothing declares is a finding, not a repair -----------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    payload = dict(record_of(store, "capability-instance", instances[0]))
    payload["instance_id"] = "CINST-000900"
    payload["supersedes"] = "CINST-000899"
    store.write_atomic(store.path_for("capability-instance", "CINST-000900"), payload)
    before = forensic(fabric_root)
    report, error = checked(fabric_root)
    check(error is None, f"a dangling predecessor raises nothing ({error})")
    check(any("CINST-000899" in finding and "supersedes" in finding
              for finding in report.findings),
          "a predecessor no stored record declares is reported")
    check(forensic(fabric_root) == before,
          "the dangling reference is reported and nothing is backfilled")

# A record filed under a name that is not its own identity is reported too.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    payload = dict(record_of(store, "capability-instance", instances[0]))
    store.write_atomic(store.path_for("capability-instance", "CINST-000901"), payload)
    before = forensic(fabric_root)
    report, error = checked(fabric_root)
    check(error is None, f"a misfiled record raises nothing ({error})")
    check(any("CINST-000901" in finding and "filename" in finding
              for finding in report.findings),
          "a record whose filename is not its identity is reported")
    check(forensic(fabric_root) == before, "the misfiled record is left where it is")

# --- I. Temp residue is debris, and debris is evidence (AC 33, FC 12) -----
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    residue = store.path_for("capability-selection", "CSEL-000902").with_name(
        ".CSEL-000902.tmp")
    store.write_atomic(residue.with_name("CSEL-000902.yaml"), {"kind": "x"})
    debris = residue.parent / "CSEL-000903.tmp"
    debris.write_text("partial", encoding="utf-8")
    before = forensic(fabric_root)
    report, error = checked(fabric_root)
    check(error is None, f"temp residue raises nothing ({error})")
    check(any("CSEL-000903.tmp" in finding and "partial write" in finding
              for finding in report.findings),
          "temp residue is reported as an interrupted write")
    check(debris.exists(), "temp residue is not removed by reporting it")
    check(forensic(fabric_root) == before,
          "reporting debris changes nothing at all")

# --- J. A root that cannot be opened is refused, not created --------------
with TemporaryDirectory() as tmp:
    parent = Path(tmp)
    linked = parent / "linked-store"
    linked.symlink_to(parent / "elsewhere")
    before = forensic(parent)
    for report, error, label in ((*looked(linked), "inspection"),
                                 (*checked(linked), "validation")):
        check(error is None, f"{label} of a linked root raises nothing ({error})")
        check(report.status in (STATUS_UNREADABLE, STATUS_ABSENT),
              f"{label} refuses a store root it cannot open")
        check(report.reason in (REASON_UNREADABLE, REASON_ABSENT),
              f"{label} names why the root could not be read")
    check(forensic(parent) == before,
          "a refused root leaves its parent byte-unchanged")

for empty_root in (None, "", "   "):
    report, error = checked(empty_root)
    check(error is None, f"an unusable root raises nothing ({error})")
    check(report.status == STATUS_INVALID, "an unusable store root is refused")

# --- K. A durable decision reads back exactly as it was written -----------
# C8 reports persisted truth. It never re-decides and presents the answer as
# though it were the original.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, route, selected = c8_world(tmp)
    refused, _ = chosen(store, trust_store, dict(asked, capability_id="CAPDEF-0009"),
                        request_id="c8-no-route")
    check(refused.outcome == ACCEPTED, "the c8 world records a no-route decision")

    report, error = looked(fabric_root, kind="capability-selection")
    check(error is None, f"inspecting selections raises nothing ({error})")
    reported = {record["selection_id"]: record for record in report.records}
    check(set(reported) == {selected.record_id, refused.record_id},
          "every durable decision is reported")

    chose = reported[selected.record_id]
    stored = record_of(store, "capability-selection", selected.record_id)
    for field in ("selection_id", "route_id", "route_version", "request_class",
                  "considered_candidates", "excluded_candidates",
                  "selected_instance_id", "selection_reason", "selected_at",
                  "provenance", "evidence"):
        check(dict(chose).get(field) == stored.get(field),
              f"the reported selection carries the persisted {field}")

    none_found = reported[refused.record_id]
    check("route_id" not in none_found and "route_version" not in none_found,
          "a reported no-route decision names no route provenance")
    check("selected_instance_id" not in none_found,
          "a reported no-route decision selected nothing")
    check(none_found["evidence"]["reason_category"] == "no-candidate",
          "a reported no-route decision keeps its own outcome category")

# A refusal over a resolved route, and a local-only decision, read back whole.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(
        tmp, locality="local-only", second_host=True)
    decided, _ = chosen(store, trust_store, asked, request_id="c8-local")
    for index, identifier in enumerate(instances):
        admission_module.withdraw_instance(
            store, request_id=f"c8-end-{index}", actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP,
            instance_id=identifier, provenance=dict(PROV), notes=None)
    turned_down, _ = chosen(store, trust_store, asked, request_id="c8-refused")
    report, error = looked(fabric_root, kind="capability-selection")
    check(error is None, f"inspecting mixed decisions raises nothing ({error})")
    reported = {record["selection_id"]: record for record in report.records}

    local = reported[decided.record_id]
    check(local.get("local_node_identity") == LOCAL_NODE,
          "the node identity that governed a local-only decision is reported")
    refusal = reported[turned_down.record_id]
    check(refusal.get("route_id") == route.record_id
          and refusal.get("route_version") == 1,
          "a reported refusal carries the route provenance it was decided under")
    check(refusal["evidence"]["reason_category"] == "selection-refusal",
          "a reported refusal keeps its own outcome category")
    check(tuple(entry["instance_id"] for entry in refusal["excluded_candidates"])
          == tuple(instances),
          "every persisted exclusion is reported, in the order it was written")

# --- L. Inspection decides nothing and reaches nothing --------------------
for forbidden in ("evaluate_eligibility", "select_candidate", "admit_instance",
                  "create_route", "withdraw", "retire", "create_decision",
                  "tools.health", "tools.capability", "health_score",
                  "importlib", "subprocess", "eval(", "exec("):
    check(forbidden not in INSPECTION_SOURCE,
          f"the inspection surface reaches no {forbidden}")
for mutation in ("store.write", "allocate_id", "write_atomic", "write_record",
                 "mkdir", "makedirs", "unlink", "rmtree", "chmod", "chown",
                 "rename", "replace(", "touch("):
    check(mutation not in INSPECTION_SOURCE,
          f"the inspection surface contains no {mutation}")
for token in ("random", "uuid", "datetime.now", "utcnow", "time.time",
              "os.environ", "getenv"):
    check(token not in INSPECTION_SOURCE,
          f"the inspection surface contains no {token}")
for later in ("repair", "fix", "clean", "normalise", "normalize", "rebuild",
              "recompute", "backfill", "remediate", "invoke", "execute",
              "select", "admit", "allocate"):
    check(not hasattr(inspection_module, later),
          f"the inspection surface exposes no '{later}' behaviour at increment 10")
check((root / "tools" / "fabric" / "cli.py").exists(),
      "the interface arrives at increment 11, after C8")
check(len(RECORD_MODELS) == 8,
      "increment 10 introduces no ninth persistent record type")

# =======================================================================
# Increment 11 — interface integration
# =======================================================================
# The twelve §8 operations, reachable. The interface parses, resolves nothing,
# decides nothing, and hands the governed inputs to the component that owns
# them -- a second policy engine at the edge is how the boundary moves onto
# whoever typed the command.
#
# What it refuses is the point. There is no default store root, no environment
# identity, no implicit current user, and no way to pass an approving authority
# as an argument: write commands read their decision body from a file inside an
# approved directory, checked after full resolution. Time is explicit, so a
# result is reproducible rather than a race against the clock.
#
# Exit codes follow the released trust interface: 0 succeeded, 1 the governed
# layer said no, 2 the invocation was unusable.

import io  # noqa: E402
import json as _json  # noqa: E402
from contextlib import redirect_stderr, redirect_stdout  # noqa: E402

import tools.fabric.cli as cli_module  # noqa: E402
from tools.fabric.cli import EXIT_DENIED, EXIT_SUCCESS, EXIT_USAGE, main  # noqa: E402

CLI_SOURCE = (root / "tools" / "fabric" / "cli.py").read_text(encoding="utf-8")

# Every §8 operation, and the command that reaches it. Operation 8 is one
# operation with four released spellings; each delegates to its own function
# rather than branching on a flag.
SECTION_8 = {
    1: ("declare-capability",), 2: ("declare-contract",), 3: ("declare-package",),
    4: ("admit-subject",), 5: ("register-advertisement",), 6: ("admit-instance",),
    7: ("create-route",),
    8: ("withdraw-subject", "refresh-subject", "withdraw-instance",
        "retire-instance"),
    9: ("compute-eligibility",), 10: ("select",), 11: ("inspect",),
    12: ("validate",),
}
ALL_COMMANDS = tuple(name for names in SECTION_8.values() for name in names)


def run(argv):
    """One invocation, captured. Nothing here reaches a real shell."""
    out, err = io.StringIO(), io.StringIO()
    try:
        with redirect_stdout(out), redirect_stderr(err):
            code = main(list(argv))
    except SystemExit as exit_code:  # argparse refuses an unusable invocation
        code = exit_code.code
    except BaseException as error:  # noqa: BLE001
        return None, out.getvalue(), err.getvalue(), error
    return code, out.getvalue(), err.getvalue(), None


def payload_of(text):
    try:
        return _json.loads(text)
    except ValueError:
        return None


def approved(tmp, name, body):
    """One decision body, in the approved directory, as a file."""
    directory = Path(tmp) / "approved"
    directory.mkdir(exist_ok=True)
    directory.joinpath(name).write_text(_json.dumps(body, default=str),
                                        encoding="utf-8")
    return str(directory)


def store_flags(tmp):
    return ["--store-root", str(Path(tmp) / "fabric"),
            "--expected-uid", str(UID), "--expected-gid", str(GID)]


def trust_flags(tmp):
    return ["--trust-store-root", str(Path(tmp) / "trust")]


check(sorted(ALL_COMMANDS) == sorted(set(ALL_COMMANDS)),
      "every §8 operation names a distinct command")
check(len(SECTION_8) == 12, "the interface covers all twelve §8 operations")

# --- A. No default store root ---------------------------------------------
with TemporaryDirectory() as tmp:
    before = forensic(Path(tmp))
    for command in ALL_COMMANDS:
        code, out, err, error = run([command])
        check(error is None, f"{command} without a store root raises nothing ({error})")
        check(code == EXIT_USAGE,
              f"{command} without a store root is an unusable invocation")
    check(forensic(Path(tmp)) == before,
          "an invocation with no store root creates nothing")
    check("--store-root" in CLI_SOURCE and "default=" not in CLI_SOURCE.split(
        "--store-root")[1].split("\n")[0],
        "the store root flag carries no default")

# --- B/C/D. The twelve operations, end to end, with no Health Runtime ------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_store, host_trust, package_trust = seeded_fabric_trust(tmp)
    opened(tmp)  # the store exists before the interface is asked to use it
    reached = {}

    def invoke(command, body=None, *, extra=(), name="input.json"):
        argv = [command, *store_flags(tmp)]
        if body is not None:
            argv += ["--input-file", name,
                     "--approved-directory", approved(tmp, name, body)]
        argv += list(extra)
        code, out, err, error = run(argv)
        check(error is None, f"{command} raises nothing ({error})")
        reached[command] = True
        return code, payload_of(out), err

    def instants(body):
        return dict(body, recorded_at=STAMP.isoformat())

    code, result, _ = invoke("declare-capability", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-cap",
        name="summarise text", description="Reduce a document.",
        effect_class="read-only", contract_ids=[], provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 1 declares a capability through the interface")
    capability_id = result.get("record_id")
    check(capability_id == "CAPDEF-0001",
          "the interface reports the identity the fabric allocated")

    code, result, _ = invoke("declare-contract", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-con",
        capability_id=capability_id, contract_version="1.0.0",
        effect_class="read-only", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=["adapter-error"], resource_requirements={"host_memory_mb": 512},
        compatible_with=[], provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 2 declares a contract through the interface")
    contract_id = result.get("record_id")

    code, result, _ = invoke("declare-package", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-pkg",
        capability_id=capability_id, contract_id=contract_id,
        satisfied_contract_versions=["1.0.0"], package_version="1.0.0",
        artifact_reference="oci://registry.invalid/summarise",
        resource_requirements={"host_memory_mb": 512, "architecture": "x86-64"},
        trust_domain="capability-package", provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 3 declares a package through the interface")
    package_id = result.get("record_id")

    code, result, _ = invoke("admit-subject", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-host",
        evaluated_at=STAMP.isoformat(), node_identity_reference="node/schai",
        fabric_node_trust_record_id=NODE_TRUST["node/schai"],
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/evidence/host-observed.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=dict(PROV))),
        extra=trust_flags(tmp))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 4 admits a subject through the interface")
    host_id = result.get("record_id")

    code, result, _ = invoke("register-advertisement", instants(dict(
        actor=host_id, request_id="cli-adv", capability_host_id=host_id,
        capability_package_id=package_id, contract_id=contract_id,
        satisfied_contract_versions=["1.0.0"],
        advertised_resource_profile={"host_memory_mb": 8192},
        observed_at=STAMP.isoformat(), valid_until=YEAR.isoformat(),
        provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 5 registers an advertisement through the interface")
    advertisement_id = result.get("record_id")

    code, result, _ = invoke("admit-instance", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-inst",
        evaluated_at=LATER.isoformat(), capability_id=capability_id,
        capability_package_id=package_id, capability_host_id=host_id,
        contract_id=contract_id, satisfied_contract_versions=["1.0.0"],
        verified_resource_profile=dict(PROFILE),
        admission_decision_id="TDEC-000001",
        package_trust_record_id=PACKAGE_TRUST["CPKG-0001"],
        host_trust_record_id=NODE_TRUST["node/schai"],
        admission_scope=dict(SCOPE), admitted_at=STAMP.isoformat(),
        admitted_until=YEAR.isoformat(), advertisement_id=advertisement_id,
        provenance=dict(PROV))), extra=trust_flags(tmp))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 6 admits an instance through the interface")
    instance_id = result.get("record_id")

    code, result, _ = invoke("create-route", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-route",
        capability_id=capability_id, contract_id=contract_id,
        accepted_contract_versions=["1.0.0"], locality="any-trusted",
        candidate_instances=[instance_id], data_classification="internal",
        route_version=1, provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 7 declares a route through the interface")

    # Operation 9 is read-only and takes its request as flags: nothing here
    # carries an approving authority.
    code, out, err, error = run(["compute-eligibility", *store_flags(tmp),
                                 *trust_flags(tmp), "--instance-id", instance_id,
                                 "--capability-id", capability_id,
                                 "--contract-id", contract_id,
                                 "--accepted-version", "1.0.0",
                                 "--data-classification", "internal",
                                 "--evaluated-at", LATER.isoformat()])
    reached["compute-eligibility"] = True
    check(error is None, f"operation 9 raises nothing ({error})")
    verdict = payload_of(out)
    check(code == EXIT_SUCCESS and verdict.get("eligible") is True,
          "operation 9 computes eligibility through the interface")
    check(tuple(entry["condition_id"] for entry in verdict["conditions"])
          == tuple(f"ELIG-{n}" for n in range(1, 13)),
          "the eligibility verdict reports every condition, in schema order")

    code, result, _ = invoke("select", instants(dict(
        actor="core", request_id="cli-select", evaluated_at=LATER.isoformat(),
        capability_id=capability_id, contract_id=contract_id,
        accepted_contract_versions=["1.0.0"], data_classification="internal",
        locality="any-trusted", local_node_identity="node/schai",
        health_removals=[], provenance=dict(PROV))), extra=trust_flags(tmp))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 10 selects through the interface")
    selection_id = result.get("record_id")

    code, out, err, error = run(["inspect", *store_flags(tmp),
                                 "--kind", "capability-selection"])
    reached["inspect"] = True
    check(error is None, f"operation 11 raises nothing ({error})")
    report = payload_of(out)
    check(code == EXIT_SUCCESS and report.get("status") == "reported",
          "operation 11 inspects through the interface")
    check([record["selection_id"] for record in report["records"]] == [selection_id],
          "the interface reports the record C8 read, unaltered")

    code, out, err, error = run(["validate", *store_flags(tmp)])
    reached["validate"] = True
    check(error is None, f"operation 12 raises nothing ({error})")
    findings = payload_of(out)
    check(code == EXIT_SUCCESS and findings.get("findings") == [],
          "operation 12 validates through the interface")
    check(findings.get("counts", {}).get("capability-selection") == 1,
          "the interface reports C8's counts unaltered")

    # Operation 8, all four released spellings.
    code, result, _ = invoke("withdraw-instance", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-wdi",
        instance_id=instance_id, provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 8 withdraws an instance through the interface")
    withdrawn_instance = result.get("record_id")
    code, result, _ = invoke("retire-instance", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-rti",
        instance_id=withdrawn_instance, provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 8 retires an instance through the interface")
    code, result, _ = invoke("withdraw-subject", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-wds",
        capability_host_id=host_id, availability_intent="withheld",
        provenance=dict(PROV))))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 8 withdraws a subject through the interface")
    withdrawn_host = result.get("record_id")
    code, result, _ = invoke("refresh-subject", instants(dict(
        actor=OPERATOR, approving_authority=OPERATOR, request_id="cli-rfs",
        evaluated_at=LATER.isoformat(), capability_host_id=withdrawn_host,
        fabric_node_trust_record_id=NODE_TRUST["node/schai"],
        verified_resource_profile=dict(PROFILE),
        verification_reference="/approved/evidence/host-reobserved.txt",
        location_class="on-premises", data_classification="internal",
        availability_intent="in-service", provenance=dict(PROV))),
        extra=trust_flags(tmp))
    check(code == EXIT_SUCCESS and result.get("outcome") == ACCEPTED,
          "operation 8 returns a subject to service through the interface")

    check(sorted(reached) == sorted(ALL_COMMANDS),
          f"every §8 operation was reached through the interface ({sorted(set(ALL_COMMANDS) - set(reached))})")
    # AC 25: none of that required a Health Runtime.
    check(not (root / "tools" / "health").exists(),
          "every operation ran with no Health Runtime present")

# --- E/F. Replay, and a conflicting reuse ---------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    body = dict(actor=OPERATOR, approving_authority=OPERATOR,
                request_id="cli-replay", recorded_at=STAMP.isoformat(),
                name="summarise text", description="Reduce a document.",
                effect_class="read-only", contract_ids=[], provenance=dict(PROV))
    first = run(["declare-capability", *store_flags(tmp), "--input-file", "a.json",
                 "--approved-directory", approved(tmp, "a.json", body)])
    check(first[0] == EXIT_SUCCESS, "the first governed request through the interface is accepted")
    original = payload_of(first[1])

    before = forensic(fabric_root)
    again = run(["declare-capability", *store_flags(tmp), "--input-file", "a.json",
                 "--approved-directory", approved(tmp, "a.json", body)])
    replayed = payload_of(again[1])
    check(again[0] == EXIT_SUCCESS, "an exact replay through the interface succeeds")
    check(replayed.get("outcome") == EXACT_REPLAY,
          "an exact replay is reported as a replay, not a second decision")
    check(replayed.get("record_id") == original.get("record_id"),
          "the replay returns the original record identity")
    check(forensic(fabric_root) == before, "an exact replay writes nothing")

    clashing = dict(body, description="Something else entirely.")
    conflict = run(["declare-capability", *store_flags(tmp), "--input-file", "b.json",
                    "--approved-directory", approved(tmp, "b.json", clashing)])
    reported = payload_of(conflict[1])
    check(conflict[0] == EXIT_DENIED,
          "a conflicting reuse of a request identity is denied")
    check(reported.get("outcome") == CONFLICT
          and reported.get("reason") == "request_identity_conflict",
          "the conflict is reported as a request identity conflict")
    check(reported.get("record_id") is None, "a conflict allocates no identity")
    check(forensic(fabric_root) == before, "a conflict writes nothing")
    check("request_id" not in CLI_SOURCE.split("def _generate")[0].split("uuid")[0]
          or "uuid" not in CLI_SOURCE,
          "the interface never generates a request identity of its own")

# --- G. Governed refusal stays structured ---------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    before = forensic(fabric_root)
    refused = run(["declare-contract", *store_flags(tmp), "--input-file", "c.json",
                   "--approved-directory", approved(tmp, "c.json", dict(
                       actor=OPERATOR, approving_authority=OPERATOR,
                       request_id="cli-missing", recorded_at=STAMP.isoformat(),
                       capability_id="CAPDEF-0009", contract_version="1.0.0",
                       effect_class="read-only", determinism_class="deterministic",
                       request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
                       failure_modes=[],
                       resource_requirements={}, compatible_with=[],
                       provenance=dict(PROV)))])
    body = payload_of(refused[1])
    check(refused[0] == EXIT_DENIED, "a governed refusal exits as denied")
    check(body is not None and body.get("outcome") == NOT_FOUND,
          "a governed refusal is still structured output")
    check(body.get("reason") == "unresolved-reference",
          "the governed reason reaches the caller unchanged")
    check("Traceback" not in refused[1] + refused[2],
          "a governed refusal shows no traceback")
    check(forensic(fabric_root) == before, "a governed refusal writes nothing")

# --- H. Selection outcomes through the interface --------------------------
with TemporaryDirectory() as tmp:
    store, trust_store, asked, instances, hosts, route = c6_world(tmp, second_host=True)
    def selected_through(request_id, **overrides):
        body = dict(actor="core", request_id=request_id,
                    recorded_at=STAMP.isoformat(), evaluated_at=LATER.isoformat(),
                    accepted_contract_versions=list(asked["accepted_contract_versions"]),
                    capability_id=asked["capability_id"],
                    contract_id=asked["contract_id"],
                    data_classification=asked["data_classification"],
                    locality=asked["locality"], local_node_identity=LOCAL_NODE,
                    health_removals=[], provenance=dict(PROV))
        body.update(overrides)
        name = f"{request_id}.json"
        return run(["select", *store_flags(tmp), *trust_flags(tmp),
                    "--input-file", name,
                    "--approved-directory", approved(tmp, name, body)])

    code, out, _, _ = selected_through("cli-sel-ok")
    chose = payload_of(out)
    check(code == EXIT_SUCCESS and chose.get("outcome") == ACCEPTED,
          "a selection through the interface succeeds")
    stored = record_of(store, "capability-selection", chose["record_id"])
    check(stored.get("selected_instance_id") == instances[0],
          "the interface records the same choice the runtime would")

    code, out, _, _ = selected_through("cli-sel-none", capability_id="CAPDEF-0009")
    none_found = payload_of(out)
    check(code == EXIT_SUCCESS and none_found.get("outcome") == ACCEPTED,
          "a no-route decision is a governed outcome, recorded and reported")
    stored = record_of(store, "capability-selection", none_found["record_id"])
    check("route_id" not in stored,
          "the interface does not invent route provenance for a no-route decision")

    for index, identifier in enumerate(instances):
        admission_module.withdraw_instance(
            store, request_id=f"cli-end-{index}", actor=OPERATOR,
            approving_authority=OPERATOR, recorded_at=STAMP,
            instance_id=identifier, provenance=dict(PROV), notes=None)
    code, out, _, _ = selected_through("cli-sel-refused")
    refusal = payload_of(out)
    stored = record_of(store, "capability-selection", refusal["record_id"])
    check(stored.get("selected_instance_id") is None
          and stored.get("route_id") == route.record_id,
          "a selection refusal keeps its route provenance through the interface")

# --- I. Approved-directory containment ------------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    outside = Path(tmp) / "outside"
    outside.mkdir()
    outside.joinpath("escape.json").write_text("{}", encoding="utf-8")
    directory = approved(tmp, "kept.json", {"actor": OPERATOR})
    Path(directory).joinpath("link.json").symlink_to(outside / "escape.json")
    before = forensic(Path(tmp))
    for name, description in (("../outside/escape.json", "a traversing input path"),
                              ("link.json", "a symlinked input file"),
                              ("/etc/hostname", "an absolute input path"),
                              ("missing.json", "an input file that is not there")):
        code, out, err, error = run(["declare-capability", *store_flags(tmp),
                                     "--input-file", name,
                                     "--approved-directory", directory])
        check(error is None, f"{description} raises nothing ({error})")
        check(code == EXIT_USAGE, f"{description} is refused as unusable")
        check("Traceback" not in out + err, f"{description} shows no traceback")
    check(forensic(Path(tmp)) == before,
          "every containment refusal leaves the filesystem unchanged")

    # Deferred C: the interface asks the shared primitive rather than carrying
    # a fifth copy of the same six lines. Refusals above are unchanged -- this
    # only fixes where the containment answer comes from.
    check("contained_path" in CLI_SOURCE,
          "the interface asks the shared containment primitive")
    check("approved not in" not in CLI_SOURCE,
          "the interface carries no containment test of its own")

# --- J/K. Malformed input and unknown commands ----------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    directory = Path(tmp) / "approved"
    directory.mkdir(exist_ok=True)
    directory.joinpath("broken.json").write_text("{not json", encoding="utf-8")
    before = forensic(fabric_root)
    code, out, err, error = run(["declare-capability", *store_flags(tmp),
                                 "--input-file", "broken.json",
                                 "--approved-directory", str(directory)])
    check(error is None, f"malformed input raises nothing ({error})")
    check(code == EXIT_USAGE, "a decision body that is not readable is unusable")
    check(forensic(fabric_root) == before,
          "a malformed decision body invokes no governed operation")
    for argv, description in ((["not-a-command"], "an unknown command"),
                              ([], "no command at all"),
                              (["inspect", *store_flags(tmp), "--nonsense"],
                               "an unknown flag")):
        code, out, err, error = run(argv)
        check(error is None, f"{description} raises nothing ({error})")
        check(code == EXIT_USAGE, f"{description} is an unusable invocation")
    check(forensic(fabric_root) == before,
          "an unusable invocation touches nothing")

# --- L/M. Explicit time and explicit authority ----------------------------
for token, description in (("datetime.now", "a clock of its own"),
                           ("utcnow", "a clock of its own"),
                           ("time.time", "a clock of its own"),
                           ("uuid", "an identity of its own"),
                           ("random", "chance"),
                           ("os.environ", "an environment-derived value"),
                           ("getenv", "an environment-derived value"),
                           ("expanduser", "a home-directory default"),
                           ("subprocess", "a child process"),
                           ("os.system", "a shell"),
                           ("shell=True", "a shell"),
                           ("importlib", "a dynamic import"),
                           ("eval(", "evaluation"),
                           ("exec(", "execution"),
                           ("socket", "a network path"),
                           ("urllib", "a network path"),
                           ("requests", "a network path")):
    check(token not in CLI_SOURCE,
          f"the interface contains no {description} ('{token}')")
for verb in ("invoke", "execute", "run_capability", "dispatch", "load",
             "activate", "repair", "remediate", "retry", "recover"):
    check(not hasattr(cli_module, verb),
          f"the interface exposes no '{verb}' verb at increment 11")

# --- N. FC 25: recovery is a new decision, never an event -----------------
# Nothing here recovers. A refused request leaves no record, and the way
# forward is another governed decision that produces its own.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    body = dict(actor=OPERATOR, approving_authority=OPERATOR,
                request_id="cli-fc25", recorded_at=STAMP.isoformat(),
                capability_id="CAPDEF-0009", contract_version="1.0.0",
                effect_class="read-only", determinism_class="deterministic",
                request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
                failure_modes=[],
                resource_requirements={}, compatible_with=[], provenance=dict(PROV))
    failed = run(["declare-contract", *store_flags(tmp), "--input-file", "f.json",
                  "--approved-directory", approved(tmp, "f.json", body)])
    check(failed[0] == EXIT_DENIED, "the first attempt is refused")
    after_failure = forensic(fabric_root)
    check(payload_of(failed[1]).get("record_id") is None,
          "a refused operation leaves no partial record to recover")

    # The prerequisite is declared, and the operator decides again -- with its
    # own request identity, producing its own record.
    made = run(["declare-capability", *store_flags(tmp), "--input-file", "g.json",
                "--approved-directory", approved(tmp, "g.json", dict(
                    actor=OPERATOR, approving_authority=OPERATOR,
                    request_id="cli-fc25-cap", recorded_at=STAMP.isoformat(),
                    name="summarise text", description="Reduce a document.",
                    effect_class="read-only", contract_ids=[],
                    provenance=dict(PROV)))])
    check(made[0] == EXIT_SUCCESS, "the missing prerequisite is declared by decision")
    recovered = run(["declare-contract", *store_flags(tmp), "--input-file", "h.json",
                     "--approved-directory", approved(tmp, "h.json", dict(
                         body, request_id="cli-fc25-again",
                         capability_id=payload_of(made[1])["record_id"]))])
    check(recovered[0] == EXIT_SUCCESS,
          "recovery is a new governed decision, and it succeeds on its own terms")
    check(payload_of(recovered[1])["record_id"] == "CCON-0001",
          "the new decision produces a new record")
    check(set(forensic(fabric_root)) > set(after_failure),
          "recovery added records rather than repairing anything")
    check(all(forensic(fabric_root)[path] == after_failure[path]
              for path in after_failure if path.endswith(".yaml")),
          "no record written before the failure was altered by recovering")

# --- O/P. Deterministic output, and no interface persistence --------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    trust_root = Path(tmp) / "trust"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp)
    before = forensic(fabric_root)
    before_trust = forensic(trust_root)
    before_sequences = sequences_of(fabric_root)
    first = run(["validate", *store_flags(tmp)])
    second = run(["validate", *store_flags(tmp)])
    check(first[0] == second[0] and first[1] == second[1] and first[2] == second[2],
          "repeating a validation returns byte-identical output")
    looked_once = run(["inspect", *store_flags(tmp)])
    looked_twice = run(["inspect", *store_flags(tmp)])
    check(looked_once[1] == looked_twice[1],
          "repeating an inspection returns byte-identical output")
    check(looked_once[2] == "" and first[2] == "",
          "a successful read writes nothing to stderr")
    check(payload_of(looked_once[1]) is not None,
          "stdout carries machine-readable output alone")
    check(forensic(fabric_root) == before and forensic(trust_root) == before_trust,
          "reading through the interface changes neither store")
    check(sequences_of(fabric_root) == before_sequences,
          "reading through the interface moves no identifier")
    check(sorted(p.name for p in fabric_root.rglob("*.tmp")) == [],
          "the interface leaves no temporary artefact")

# =======================================================================
# Increment 12 — failure injection, concurrency, regression, closure
# =======================================================================
# Two callers, one request identity. Until C1's critical section actually
# serialises, both observe "not found" on replay lookup and both commit, so one
# request identity yields two accepted records -- or, worse, two records for
# contradictory digests. That is the whole of this increment's Red.
#
# Blocking is never inferred from elapsed time or from an event that failed to
# arrive. The store names a seam, `_test_sync_point`, and a coordinator waits
# for a positive event: either the second caller reaches the replay-miss hook
# (pre-fix) or it reports contention (post-fix). Any timeout is a failure of
# the test, never evidence of blocking and never a pass.

import threading as _threading  # noqa: E402

RACE_TIMEOUT = 20  # seconds; a wait that expires is a failure, never a pass


class RacingStore(WatchedStore):
    """The real store, announcing the phases a coordinating test waits on."""

    def __init__(self, *args, **kwargs):
        self.observed = []
        self.gates = {}
        self.seen = {}
        self._notice = _threading.Lock()
        super().__init__(*args, **kwargs)

    def _test_sync_point(self, phase, request_id):
        with self._notice:
            self.observed.append((phase, request_id))
            event = self.seen.setdefault(phase, _threading.Event())
            event.set()
        gate = self.gates.get(phase)
        if gate is not None:
            # A positive wait: the coordinator releases it, or the test fails.
            if not gate.wait(RACE_TIMEOUT):
                raise AssertionError(f"{phase} was never released")

    def reached(self, phase):
        with self._notice:
            return self.seen.setdefault(phase, _threading.Event())


def raced(tmp, *, second_body, request_id="c12-race"):
    """Two callers, one request identity, deterministically interleaved.

    A is held at the replay-miss hook. B starts and is waited on for whichever
    positive event the implementation actually produces. Then A is released.
    """
    store = RacingStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    hold = _threading.Event()
    store.gates["after_replay_miss"] = hold
    results = {}

    first_body = dict(BASE_CAPABILITY, request_id=request_id)

    def run(name, body, gated):
        target = store if gated else RacingStore(
            Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
        try:
            results[name] = declare_capability(target, **body)
        except BaseException as error:  # noqa: BLE001
            results[name] = error

    # A enters first and stops at the replay miss.
    first = _threading.Thread(target=run, args=("a", first_body, True))
    first.start()
    check(store.reached("after_replay_miss").wait(RACE_TIMEOUT),
          "the first caller reaches the replay-miss seam")

    # B enters on its own handle, so the lock -- not the object -- is what
    # serialises them.
    partner = RacingStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    partner.gates["after_replay_miss"] = _threading.Event()
    partner.gates["after_replay_miss"].set()

    def run_second():
        try:
            results["b"] = declare_capability(partner, **second_body)
        except BaseException as error:  # noqa: BLE001
            results["b"] = error

    second = _threading.Thread(target=run_second)
    second.start()
    # Whichever the implementation produces: a replay miss (pre-fix) or
    # contention (post-fix). Never a timeout.
    # Whichever fires first, bounded well inside the first caller's hold so a
    # slow event can never be mistaken for a released gate.
    deadline = RACE_TIMEOUT / 4
    waited = 0.0
    while waited < deadline:
        if (partner.reached("lock_contended").is_set()
                or partner.reached("after_replay_miss").is_set()):
            break
        _threading.Event().wait(0.02)
        waited += 0.02
    signalled = (partner.reached("lock_contended").is_set()
                 or partner.reached("after_replay_miss").is_set())
    check(signalled, "the second caller produces a positive event, not a timeout")
    contended = partner.reached("lock_contended").is_set()

    hold.set()
    first.join(RACE_TIMEOUT)
    second.join(RACE_TIMEOUT)
    check(not first.is_alive() and not second.is_alive(),
          "both callers finish; neither deadlocks")
    return store, results, contended


def only(results, outcome):
    """The single result carrying this outcome, or None. Never raises, so a
    wrong outcome is reported as a failed check rather than a traceback."""
    matching = [r for r in results.values()
                if getattr(r, "outcome", None) == outcome]
    return matching[0] if len(matching) == 1 else None


# --- A. Concurrent exact reuse of one request identity (FC 8) --------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    store, results, contended = raced(
        tmp, second_body=dict(BASE_CAPABILITY, request_id="c12-race"),
        request_id="c12-race")
    check(contended, "the second caller reports contention rather than a replay miss")
    outcomes = sorted(getattr(result, "outcome", repr(result))
                      for result in results.values())
    check(outcomes == [ACCEPTED, EXACT_REPLAY],
          f"one request identity yields one accepted record and one replay ({outcomes})")
    accepted = only(results, ACCEPTED)
    replayed = only(results, EXACT_REPLAY)
    check(accepted is not None and replayed is not None
          and replayed.record_id == accepted.record_id,
          "the replay returns the original record identity")
    stored = store.list_records("capability-definition")
    check(len(stored) == 1,
          f"exactly one capability record exists ({len(stored)})")

# --- B. Concurrent conflicting reuse (FC 9) -------------------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    opened(tmp)
    store, results, contended = raced(
        tmp, second_body=dict(BASE_CAPABILITY, request_id="c12-race",
                              description="A different ability entirely."),
        request_id="c12-race")
    check(contended, "the conflicting caller reports contention")
    outcomes = sorted(getattr(result, "outcome", repr(result))
                      for result in results.values())
    check(outcomes == [ACCEPTED, CONFLICT],
          f"conflicting reuse yields one accepted record and one conflict ({outcomes})")
    conflict = only(results, CONFLICT)
    check(conflict is not None and conflict.reason == "request_identity_conflict",
          "the losing caller is refused as a request identity conflict")
    check(conflict is not None and conflict.record_id is None,
          "the conflicting caller allocates nothing")
    check(len(store.list_records("capability-definition")) == 1,
          "no second record is written for a contradictory digest")

# --- C. Independent request identities stay independent -------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    first = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-one"))
    second = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-two"))
    check(first.outcome == ACCEPTED and second.outcome == ACCEPTED,
          "two independent request identities both succeed")
    check(first.record_id != second.record_id,
          "identical content under distinct request identities creates distinct records")
    check(len(store.list_records("capability-definition")) == 2,
          "both records exist")

# --- D. One ordinary caller completes without a second acquisition --------
with TemporaryDirectory() as tmp:
    store = RacingStore(Path(tmp) / "fabric", expected_uid=UID, expected_gid=GID)
    finished = _threading.Event()

    def single():
        declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-single"))
        finished.set()

    worker = _threading.Thread(target=single)
    worker.start()
    check(finished.wait(RACE_TIMEOUT),
          "an ordinary single caller completes without self-deadlock")
    worker.join(RACE_TIMEOUT)
    check([phase for phase, _ in store.observed] == ["after_replay_miss"],
          f"one caller acquires once and reports no contention ({store.observed})")

# --- E. An exception inside the section releases it ------------------------
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    refused = declare_capability(store, **dict(BASE_CAPABILITY,
                                               request_id="c12-refused",
                                               effect_class="unheard-of"))
    check(refused.outcome in (INVALID, REFUSED),
          "a refused operation leaves the critical section")
    after = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-after"))
    check(after.outcome == ACCEPTED,
          "a later operation acquires the section the refusal released")

# --- F. AC 34 / FC 13 regression: allocation stays unique and monotonic ---
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    allocated = [declare_capability(store, **dict(BASE_CAPABILITY,
                                                  request_id=f"c12-seq-{n}")).record_id
                 for n in range(4)]
    check(allocated == sorted(allocated) and len(set(allocated)) == 4,
          f"identifiers are unique and monotonic ({allocated})")

# --- G. AC 62 / AC 87: eight accepted types, and nothing else -------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp, second_host=True)
    chosen(store, trust_store, asked, request_id="c12-exercised")
    present = {path.parent.name for path in fabric_root.rglob("*.yaml")}
    expected = {store.record_dirs[kind] for kind in RECORD_MODELS}
    check(present <= expected,
          "every persistent record sits in one of the eight accepted kinds "
          f"({sorted(present - expected)})")
    for forbidden in ("audit", "audits", "ledger", "ledgers", "requests",
                      "replay", "index"):
        check(not (fabric_root / forbidden).exists(),
              f"no {forbidden} namespace exists in the store")
    kinds = {record_of(store, kind, path.stem).get("kind")
             for kind in RECORD_MODELS
             for path in (fabric_root / store.record_dirs[kind]).glob("*.yaml")}
    check(kinds <= set(RECORD_MODELS),
          "every stored record declares one of the eight accepted kinds "
          f"({sorted(kinds - set(RECORD_MODELS))})")

# --- H. The lock is C1's artifact, not a Fabric record --------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store = opened(tmp)
    declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-lock"))
    artifacts = sorted(path.name for path in (fabric_root / "sequences").iterdir())
    check(any(name.endswith(".lock") for name in artifacts),
          f"the serialisation artifact lives under sequences ({artifacts})")
    for kind in RECORD_MODELS:
        check(not any(path.suffix == ".lock"
                      for path in (fabric_root / store.record_dirs[kind]).iterdir()),
              f"no lock artifact is filed as a {kind} record")
    report = validate_store(fabric_root, expected_uid=UID, expected_gid=GID)
    check(report.findings == (),
          f"the lock artifact is not a validation finding ({report.findings})")
    check(sum(report.counts.values()) == 1,
          "the lock artifact is not counted as a record")

# --- I. AC 74: an interrupted supersession is bounded ---------------------
# The new binding exists, no route names it, the cutover is uncommitted, the
# old route still serves, and the accepted CINST replays under its own
# request identity. Completion is another operator decision.
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store, trust_store, asked, instances, hosts, route = c6_world(tmp, second_host=True)
    claim = register_advertisement(store, **dict(
        BASE_ADVERT, request_id="c12-adv", actor=hosts[0],
        capability_host_id=hosts[0],
        capability_package_id=record_of(store, "capability-instance",
                                        instances[0])["capability_package_id"],
        contract_id=asked["contract_id"], observed_at=STAMP, valid_until=YEAR))
    migrated = admission_module.admit_instance(store, trust_store, **dict(
        BASE_INSTANCE, request_id="c12-migrate",
        capability_id=asked["capability_id"],
        capability_package_id=record_of(store, "capability-instance",
                                        instances[0])["capability_package_id"],
        capability_host_id=hosts[0], contract_id=asked["contract_id"],
        advertisement_id=claim.record_id,
        package_trust_record_id=PACKAGE_TRUST["CPKG-0001"],
        host_trust_record_id=NODE_TRUST[LOCAL_NODE],
        supersedes=instances[0]))
    check(migrated.outcome == ACCEPTED, "the new binding is admitted")
    # The interruption: the CROUTE version that would cut over is never issued.
    check(record_of(store, "capability-instance", migrated.record_id) != {},
          "AC 74: the new instance exists")
    routes = store.list_records("capability-route")
    check(all(migrated.record_id not in tuple(entry.get("candidate_instances") or ())
              for entry in routes),
          "AC 74: no route names the new instance")
    check(len(routes) == 1 and routes[0]["route_id"] == route.record_id,
          "AC 74: the cutover is not committed and the old route still serves")
    selected, _ = chosen(store, trust_store, asked, request_id="c12-after-migrate")
    stored = record_of(store, "capability-selection", selected.record_id)
    check(stored.get("selected_instance_id") != migrated.record_id,
          "AC 74: nothing selects the uncommitted instance")
    replayed = admission_module.admit_instance(store, trust_store, **dict(
        BASE_INSTANCE, request_id="c12-migrate",
        capability_id=asked["capability_id"],
        capability_package_id=record_of(store, "capability-instance",
                                        instances[0])["capability_package_id"],
        capability_host_id=hosts[0], contract_id=asked["contract_id"],
        advertisement_id=claim.record_id,
        package_trust_record_id=PACKAGE_TRUST["CPKG-0001"],
        host_trust_record_id=NODE_TRUST[LOCAL_NODE],
        supersedes=instances[0]))
    check(replayed.outcome == EXACT_REPLAY
          and replayed.record_id == migrated.record_id,
          "AC 74: the accepted CINST remains exactly replayable under its own request identity")
    completion = admission_module.create_route(store, **dict(
        BASE_ROUTE, request_id="c12-cutover", capability_id=asked["capability_id"],
        contract_id=asked["contract_id"],
        candidate_instances=(migrated.record_id,), locality=asked["locality"],
        accepted_contract_versions=asked["accepted_contract_versions"],
        route_version=2, supersedes=route.record_id))
    check(completion.outcome == ACCEPTED,
          "AC 74: completion is an explicit operator decision producing a new route version")

# --- J. FC 12 regression: residue is debris, and stays ---------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store = opened(tmp)
    declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-residue"))
    debris = fabric_root / store.record_dirs["capability-definition"] / "CAPDEF-0009.tmp"
    debris.write_text("partial", encoding="utf-8")
    report = validate_store(fabric_root, expected_uid=UID, expected_gid=GID)
    check(any("CAPDEF-0009.tmp" in finding and "partial write" in finding
              for finding in report.findings),
          "FC 12: an interrupted write is reported as debris")
    check(debris.exists(), "FC 12: debris is not cleaned automatically")

# --- K. FC 25 regression: recovery is a new decision -----------------------
with TemporaryDirectory() as tmp:
    fabric_root = Path(tmp) / "fabric"
    store = opened(tmp)
    failed = declare_contract(store, **dict(BASE_CONTRACT, request_id="c12-fc25",
                                            capability_id="CAPDEF-0009"))
    check(failed.outcome == NOT_FOUND, "FC 25: the first attempt fails")
    check(failed.record_id is None, "FC 25: a failed attempt leaves no record")
    after_failure = forensic(fabric_root)
    made = declare_capability(store, **dict(BASE_CAPABILITY, request_id="c12-fc25-cap"))
    recovered = declare_contract(store, **dict(BASE_CONTRACT,
                                               request_id="c12-fc25-again",
                                               capability_id=made.record_id))
    check(recovered.outcome == ACCEPTED,
          "FC 25: recovery is an explicit new decision and it succeeds")
    check(all(forensic(fabric_root)[path] == after_failure[path]
              for path in after_failure if path.endswith(".yaml")),
          "FC 25: no record written before the failure was edited by recovering")
print(f"__FAILURES__={failures}")
ADMITPY
)"
printf '%s\n' "${ADMIT_OUTPUT}" | grep -v '^__FAILURES__=' || true
ADMIT_FAILURES="$(printf '%s\n' "${ADMIT_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${ADMIT_FAILURES}" ]]; then
  fail "fabric governed admission did not report a result"
else
  FAILURES=$((FAILURES + ADMIT_FAILURES))
fi

# --- Contract semantics the schema governs and admission must enforce -------
#
# Two defects found while deriving the first capability contract. Both let a
# permanent, immutable CCON record carry a value no authority governs:
#
#   * `determinism_class` had a schema enum and an admission `_text` check, so
#     any non-empty string was written and kept forever;
#   * nothing compared a contract's `effect_class` with the effect class of the
#     capability it declares, so two permanent records could disagree about one
#     capability -- and the runtime reads the contract.
#
# Both are refused before allocation, so a refusal spends no identifier.
SEMANTICS_OUTPUT="$(python3 - <<'SEMPY'
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, ".")

import yaml

from tools.fabric import admission
from tools.fabric.errors import FabricError
from tools.fabric.models import (DETERMINISM_CLASSES, EFFECT_CLASSES,
                                 FAILURE_MODES, RECORD_MODELS,
                                 RESPONSE_SHAPE_PARTS, SHAPE_REFERENCE_FIELDS)
from tools.fabric.store import FabricStore

failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)


STAMP = datetime(2026, 8, 21, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
WHO = "operator:cschott"
PROV = {"class": "declared", "source": "operator"}

# The real authorities, named as a contract must name them. The request payload
# is enforced by `payload.py`; a result has two layers and two authorities --
# `collector.py` decides the envelope is a believable document at all, and
# `result_content.py` decides what is inside it is a governed result.
REQUEST_SHAPE = {"authority": "tools/capability/execution/payload.py",
                 "schema": "kyri-execution-payload", "schema_version": 1}
RESPONSE_SHAPE = {
    "envelope": {"authority": "tools/capability/execution/collector.py",
                 "schema": "kyri-execution-result-envelope",
                 "schema_version": 1},
    "content": {"authority": "tools/capability/execution/result_content.py",
                "schema": "kyri-execution-verification-result",
                "schema_version": 1},
}

# --- the vocabularies are the schema's, not this module's -------------------
schema = yaml.safe_load(
    Path("platform-model/schemas/capability-contract.schema.yaml").read_text(
        encoding="utf-8"))
enums = schema.get("enums") or {}
check(tuple(enums.get("determinism_class") or ()) == DETERMINISM_CLASSES,
      "the determinism vocabulary in code is exactly the schema's, in order")
check(tuple(enums.get("effect_class") or ()) == EFFECT_CLASSES,
      "the effect-class vocabulary in code is exactly the schema's, in order")
check(len(set(DETERMINISM_CLASSES)) == 3,
      "exactly three determinism classes are governed")
check(tuple(enums.get("failure_mode") or ()) == FAILURE_MODES,
      "the failure-mode vocabulary in code is exactly the schema's, in order")
check(len(set(FAILURE_MODES)) == 6, "exactly six failure modes are governed")

# The vocabulary is the observable outcome of a call, not the platform's own
# reasoning about one. A mode naming a provider, an internal refusal category,
# or an eligibility judgement would bind a permanent contract to a build.
check("completed" not in FAILURE_MODES, "success is not a failure mode")
check("result-missing" in FAILURE_MODES and "serialisation-failure" in FAILURE_MODES,
      "a missing result and an unrepresentable one stay distinguishable")
for ungoverned in ("provider-error", "cancelled", "unavailable", "timed-out",
                   "internal-error"):
    check(ungoverned not in FAILURE_MODES,
          f"'{ungoverned}' is not a governed failure mode")

# The shape governance in code is the schema's too, so a contract cannot be
# admitted against one structure and read back against another.
check(tuple(schema.get("shape_reference_fields") or ()) == SHAPE_REFERENCE_FIELDS,
      "the shape-reference fields in code are exactly the schema's, in order")
check(tuple(schema.get("response_shape_parts") or ()) == RESPONSE_SHAPE_PARTS,
      "the response-shape parts in code are exactly the schema's, in order")
check(schema.get("shape_reference_form") == "closed",
      "the schema declares the reference structure closed")
check(schema.get("inline_shape_declaration") == "forbidden",
      "the schema forbids a contract restating a shape it references")


def opened(tmp):
    import os
    return FabricStore(Path(tmp) / "fabric", expected_uid=os.getuid(),
                       expected_gid=os.getgid())


def seeded(store, effect_class="computational", request_id="sem-cap"):
    result = admission.declare_capability(
        store, request_id=request_id, actor=WHO, approving_authority=WHO,
        recorded_at=STAMP, name="an ability", description="A described ability.",
        effect_class=effect_class, contract_ids=[], provenance=dict(PROV))
    assert result.outcome == admission.ACCEPTED, result
    return result.record_id


def body(capability_id, **overrides):
    fields = dict(
        request_id="sem-con", actor=WHO, approving_authority=WHO,
        recorded_at=STAMP, capability_id=capability_id, contract_version="1.0.0",
        effect_class="computational", determinism_class="deterministic",
        request_shape=REQUEST_SHAPE, response_shape=RESPONSE_SHAPE,
        failure_modes=(), resource_requirements={}, compatible_with=(),
        provenance=dict(PROV))
    fields.update(overrides)
    return fields


def sequence_of(store, kind):
    """The kind's sequence value, or None when nothing has been allocated."""
    path = store.root / "sequences" / f"{kind}.seq"
    return path.read_text(encoding="utf-8").strip() if path.exists() else None


# --- every governed determinism class is accepted, and only those -----------
for governed in DETERMINISM_CLASSES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        result = admission.declare_contract(
            store, **body(capability, determinism_class=governed))
        check(result.outcome == admission.ACCEPTED,
              f"a contract declaring determinism_class '{governed}' is accepted")

REFUSED_DETERMINISM = (
    ("definitely-not-governed", "a value outside the vocabulary"),
    ("DETERMINISTIC", "an uppercase spelling"),
    (" deterministic ", "a whitespace-padded spelling"),
    ("deterministic\n", "a trailing newline"),
    ("", "an empty string"),
    (None, "no value at all"),
    (7, "a number"),
    (True, "a boolean"),
)
for value, described in REFUSED_DETERMINISM:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        before = sequence_of(store, "capability-contract")
        result = admission.declare_contract(
            store, **body(capability, determinism_class=value))
        check(result.outcome == admission.REFUSED,
              f"a determinism_class carrying {described} is refused")
        check(result.reason == admission.REASON_DETERMINISM_CLASS,
              f"{described} is named unknown-determinism-class")
        check(result.record_id is None,
              f"{described} produces no record identity")
        check(sequence_of(store, "capability-contract") == before,
              f"{described} is refused before allocation and burns no identifier")
        check(not list((store.root / "capability-contracts").glob("*.yaml")),
              f"{described} writes no contract record")

def reconstructed(**overrides):
    """One stored contract as the model would rebuild it, with one field bent.

    The route a store damaged out of band would take: admission is not
    involved, so what the model itself refuses is what this measures.
    """
    fields = dict(
        contract_id="CCON-0001", capability_id="CAPDEF-0001",
        contract_version="1.0.0", effect_class="computational",
        determinism_class="deterministic", request_shape=dict(REQUEST_SHAPE),
        response_shape={part: dict(reference)
                        for part, reference in RESPONSE_SHAPE.items()},
        failure_modes=(), resource_requirements={}, compatible_with=(),
        provenance=dict(PROV))
    fields.update(overrides)
    return RECORD_MODELS["capability-contract"](**fields)


def refuses_reconstruction(described, **overrides):
    try:
        reconstructed(**overrides)
    except FabricError:
        check(True, f"the model refuses to reconstruct {described}")
    else:
        check(False, f"the model refuses to reconstruct {described}")


check(reconstructed().contract_id == "CCON-0001",
      "a governed contract still reconstructs from the model")

# The model refuses to reconstruct one too, so a store damaged out of band
# cannot present an ungoverned value as a valid record.
refuses_reconstruction("an ungoverned determinism_class",
                       determinism_class="definitely-not-governed")
refuses_reconstruction("an ungoverned failure mode",
                       failure_modes=("unavailable",))
refuses_reconstruction("a governed mode beside an ungoverned one",
                       failure_modes=("refused", "unavailable"))
refuses_reconstruction("a request shape that restates a schema",
                       request_shape={"text": "string"})
refuses_reconstruction("a request shape carrying a fourth key",
                       request_shape=dict(REQUEST_SHAPE, extra="ignored"))
refuses_reconstruction("a response shape missing its content authority",
                       response_shape={"envelope": dict(
                           RESPONSE_SHAPE["envelope"])})

# --- the shape a frozen record names cannot be changed afterwards -----------
#
# A response shape is a mapping of mappings, so freezing only the outer one
# would leave the record able to change which authority it names through a
# reference the caller still holds.
supplied = {part: dict(reference) for part, reference in RESPONSE_SHAPE.items()}
record = reconstructed(response_shape=supplied)
supplied["content"]["authority"] = "tools/capability/execution/payload.py"
check(record.response_shape["content"]["authority"]
      == "tools/capability/execution/result_content.py",
      "a frozen contract does not follow the caller's mapping")
try:
    record.response_shape["content"]["authority"] = "elsewhere"
    check(False, "a frozen contract's response shape is immutable all the way down")
except TypeError:
    check(True, "a frozen contract's response shape is immutable all the way down")

# --- failure modes are the schema's closed vocabulary ----------------------
#
# `failure_modes` is permanent and immutable. Before this, any non-empty string
# was written and kept forever, so a contract could promise a failure nobody
# could interpret and no implementation could be held to.
for governed in FAILURE_MODES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        result = admission.declare_contract(
            store, **body(capability, failure_modes=(governed,)))
        check(result.outcome == admission.ACCEPTED,
              f"a contract declaring failure mode '{governed}' is accepted")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    result = admission.declare_contract(
        store, **body(capability, failure_modes=FAILURE_MODES))
    check(result.outcome == admission.ACCEPTED,
          "a contract declaring every governed failure mode is accepted")

with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    result = admission.declare_contract(
        store, **body(capability, failure_modes=()))
    check(result.outcome == admission.ACCEPTED,
          "a contract declaring no failure mode at all is accepted")

REFUSED_MODES = (
    (("unavailable",), "a mode outside the vocabulary"),
    (("timed-out",), "a plausible spelling of a governed mode"),
    (("completed",), "an outcome that is not a failure"),
    (("provider-error",), "a mode naming a provider"),
    (("REFUSED",), "an uppercase spelling"),
    ((" refused",), "a whitespace-padded spelling"),
    (("refused", "unavailable"), "one governed mode beside one ungoverned"),
    ((7,), "a number"),
    ((True,), "a boolean"),
    ((None,), "nothing at all"),
    ((("refused",),), "a nested sequence"),
)
for value, described in REFUSED_MODES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        before = sequence_of(store, "capability-contract")
        result = admission.declare_contract(
            store, **body(capability, failure_modes=value))
        check(result.outcome == admission.REFUSED,
              f"failure modes carrying {described} are refused")
        check(result.reason == admission.REASON_FAILURE_MODE,
              f"{described} is named unknown-failure-mode")
        check(result.record_id is None,
              f"{described} produces no record identity")
        check(sequence_of(store, "capability-contract") == before,
              f"{described} is refused before allocation and burns no identifier")
        check(not list((store.root / "capability-contracts").glob("*.yaml")),
              f"{described} writes no contract record")

# A sequence that is not one is malformed content, exactly as it was before the
# vocabulary existed. The two mistakes keep their two different answers.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    result = admission.declare_contract(store, **body(capability, failure_modes=7))
    check(result.reason == admission.REASON_CONTENT,
          "failure modes that are not a sequence are still malformed content")
    result = admission.declare_contract(
        store, **body(capability, failure_modes="refused"))
    check(result.reason == admission.REASON_CONTENT,
          "a bare string of failure modes is malformed content, not a mode")

# --- a shape names its enforcing authority and restates nothing -------------
#
# A contract that spelled its fields out would be a second, permanent,
# unexecuted copy of a schema some module already enforces -- and the day the
# two disagree, the contract wins by being immutable while the code wins by
# being what runs.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    result = admission.declare_contract(store, **body(capability))
    check(result.outcome == admission.ACCEPTED,
          "a contract referencing its authorities is accepted")

REFUSED_REQUEST_SHAPES = (
    ({"text": "string"}, "a restated schema"),
    ({}, "nothing at all"),
    (dict(REQUEST_SHAPE, extra="ignored"), "a fourth key"),
    ({"authority": "tools/capability/execution/payload.py",
      "schema": "kyri-execution-payload"}, "no schema version"),
    (dict(REQUEST_SHAPE, schema_version=0), "a version of zero"),
    (dict(REQUEST_SHAPE, schema_version=-1), "a negative version"),
    (dict(REQUEST_SHAPE, schema_version="1"), "a version written as text"),
    (dict(REQUEST_SHAPE, schema_version=True), "a boolean version"),
    (dict(REQUEST_SHAPE, authority=""), "an empty authority"),
    (dict(REQUEST_SHAPE, authority="   "), "a whitespace authority"),
    (dict(REQUEST_SHAPE, authority=7), "an authority that is not text"),
    (dict(REQUEST_SHAPE, schema=""), "an empty schema name"),
)
for value, described in REFUSED_REQUEST_SHAPES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        before = sequence_of(store, "capability-contract")
        result = admission.declare_contract(
            store, **body(capability, request_shape=value))
        check(result.outcome == admission.REFUSED,
              f"a request shape carrying {described} is refused")
        check(result.reason == admission.REASON_SHAPE_REFERENCE,
              f"a request shape carrying {described} is named "
              "shape-not-an-authority-reference")
        check(sequence_of(store, "capability-contract") == before,
              f"a request shape carrying {described} burns no identifier")
        check(not list((store.root / "capability-contracts").glob("*.yaml")),
              f"a request shape carrying {described} writes no contract record")

REFUSED_RESPONSE_SHAPES = (
    ({"summary": "string"}, "a restated schema"),
    ({}, "nothing at all"),
    ({"envelope": dict(RESPONSE_SHAPE["envelope"])}, "no content authority"),
    ({"content": dict(RESPONSE_SHAPE["content"])}, "no envelope authority"),
    (dict(RESPONSE_SHAPE, extra=dict(REQUEST_SHAPE)), "a third part"),
    (dict(RESPONSE_SHAPE, content={"summary": "string"}),
     "a content part that restates a schema"),
    (dict(RESPONSE_SHAPE,
          envelope=dict(RESPONSE_SHAPE["envelope"], schema_version=0)),
     "an envelope version of zero"),
)
for value, described in REFUSED_RESPONSE_SHAPES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store)
        before = sequence_of(store, "capability-contract")
        result = admission.declare_contract(
            store, **body(capability, response_shape=value))
        check(result.outcome == admission.REFUSED,
              f"a response shape carrying {described} is refused")
        check(result.reason == admission.REASON_SHAPE_REFERENCE,
              f"a response shape carrying {described} is named "
              "shape-not-an-authority-reference")
        check(sequence_of(store, "capability-contract") == before,
              f"a response shape carrying {described} burns no identifier")

# A shape that is not a mapping at all is malformed content, unchanged.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    for field in ("request_shape", "response_shape"):
        result = admission.declare_contract(store, **body(capability, **{field: 7}))
        check(result.reason == admission.REASON_CONTENT,
              f"a {field} that is not a mapping is still malformed content")

# The authorities the fixtures name are real, and they say what they enforce.
# A reference is a review question, but a reference to nothing at all would
# make the whole structure decorative.
from tools.capability.execution import collector, payload, result_content  # noqa: E402

check(payload.PAYLOAD_SCHEMA_VERSION == REQUEST_SHAPE["schema_version"],
      "the payload authority implements the version the request shape names")
# The envelope authority is referenced, never modified: `collector.py` is
# installed runtime, and this hardening changes no production byte. What is
# checked is that it really does enforce an envelope -- the document's name,
# its bound, and the one function that can produce a trusted result.
check(all(hasattr(collector, name) for name in
          ("RESULT_NAME", "RESULT_MAXIMUM_BYTES", "read_result")),
      "the envelope authority is the module that enforces the result envelope")
check(result_content.RESULT_CONTENT_SCHEMA == RESPONSE_SHAPE["content"]["schema"]
      and result_content.RESULT_CONTENT_SCHEMA_VERSION
      == RESPONSE_SHAPE["content"]["schema_version"],
      "the content authority implements the schema the response shape names")
for reference in (REQUEST_SHAPE, RESPONSE_SHAPE["envelope"],
                  RESPONSE_SHAPE["content"]):
    check(Path(reference["authority"]).is_file(),
          f"the authority {reference['authority']} is a module that exists")

# --- a contract may not declare an effect class its capability does not -----
for shared in EFFECT_CLASSES:
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store, effect_class=shared)
        result = admission.declare_contract(
            store, **body(capability, effect_class=shared))
        check(result.outcome == admission.ACCEPTED,
              f"a contract agreeing with its capability on '{shared}' is accepted")

for declared in EFFECT_CLASSES:
    for contradicted in EFFECT_CLASSES:
        if declared == contradicted:
            continue
        with TemporaryDirectory() as tmp:
            store = opened(tmp)
            capability = seeded(store, effect_class=declared)
            before = sequence_of(store, "capability-contract")
            result = admission.declare_contract(
                store, **body(capability, effect_class=contradicted))
            check(result.outcome == admission.REFUSED,
                  f"a '{contradicted}' contract on a '{declared}' capability is refused")
            check(result.reason == admission.REASON_EFFECT_CLASS_MISMATCH,
                  f"'{contradicted}' against '{declared}' is named "
                  "effect-class-not-of-capability")
            check(sequence_of(store, "capability-contract") == before,
                  f"'{contradicted}' against '{declared}' burns no identifier")

# An unknown effect class is still its own refusal: the mismatch check must not
# swallow the vocabulary check, or a typo would be reported as a disagreement.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    result = admission.declare_contract(
        store, **body(capability, effect_class="not-a-class"))
    check(result.reason == admission.REASON_EFFECT_CLASS,
          "an unknown effect class is refused as unknown, not as a mismatch")

# The capability is read, never written: a refused contract leaves it exactly
# as it was.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store, effect_class="computational")
    path = store.path_for("capability-definition", capability)
    before = path.read_bytes()
    admission.declare_contract(store, **body(capability, effect_class="read-only"))
    admission.declare_contract(store, **body(capability,
                                             determinism_class="not-governed"))
    check(path.read_bytes() == before,
          "a refused contract leaves its capability definition byte-identical")

# --- preflight and the real write refuse identically ------------------------
for described, overrides in (
        ("an ungoverned determinism_class", {"determinism_class": "not-governed"}),
        ("a contradicted effect class", {"effect_class": "read-only"}),
        ("an ungoverned failure mode", {"failure_modes": ("unavailable",)}),
        ("a restated request shape", {"request_shape": {"text": "string"}}),
        ("a response shape missing its content authority",
         {"response_shape": {"envelope": dict(RESPONSE_SHAPE["envelope"])}})):
    with TemporaryDirectory() as tmp:
        store = opened(tmp)
        capability = seeded(store, effect_class="computational")
        written = admission.declare_contract(store, **body(capability, **overrides))
        with admission.rehearsing():
            rehearsed = admission.declare_contract(
                store, **body(capability, request_id="sem-pre", **overrides))
        check(rehearsed.outcome == written.outcome
              and rehearsed.reason == written.reason,
              f"preflight and the write refuse {described} identically")
        check(sequence_of(store, "capability-contract") is None,
              f"neither path allocated an identifier for {described}")

# A rehearsal of a *valid* contract still stops before allocation, and the real
# write that follows still allocates the first identity.
with TemporaryDirectory() as tmp:
    store = opened(tmp)
    capability = seeded(store)
    with admission.rehearsing():
        rehearsed = admission.declare_contract(store, **body(capability))
    check(rehearsed.outcome == admission.PREFLIGHT,
          "a valid contract rehearses to preflight after the hardening")
    check(sequence_of(store, "capability-contract") is None,
          "the rehearsal allocated nothing")
    accepted = admission.declare_contract(store, **body(capability))
    check(accepted.outcome == admission.ACCEPTED
          and accepted.record_id == "CCON-0001",
          "the real write still takes the first contract identity")
    replayed = admission.declare_contract(store, **body(capability))
    check(replayed.outcome == admission.EXACT_REPLAY
          and replayed.record_id == "CCON-0001",
          "exact replay of a contract still returns the original identity")
    check(sequence_of(store, "capability-contract") == "1",
          "the replay allocated no second identifier")

print(f"__FAILURES__={failures}")
SEMPY
)"
printf '%s\n' "${SEMANTICS_OUTPUT}" | grep -v '^__FAILURES__=' || true
SEMANTICS_FAILURES="$(printf '%s\n' "${SEMANTICS_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
if [[ -z "${SEMANTICS_FAILURES}" ]]; then
  fail "fabric contract semantics did not report a result"
else
  FAILURES=$((FAILURES + SEMANTICS_FAILURES))
fi

# --- C4 and C7 reach the filesystem through C1 only -------------------------
assert_absent_in "${FABRIC}/admission.py" \
  '(open\(|write_text|write_bytes|mkdir|makedirs|chmod|chown|unlink|os\.remove|shutil\.|tempfile)' \
  "the admission controller contains no filesystem-writing operation"
assert_absent_in "${FABRIC}/admission.py" \
  '(socket|requests|urllib|paramiko|subprocess|os\.environ|getenv|Thread|asyncio|lru_cache|sleep)' \
  "the admission controller opens no network, environment, worker, or caching path"
assert_absent_in "${FABRIC}/admission.py" \
  '(get_current_trust|TrustStore\(|create_decision|declare_root_authority)' \
  "the admission controller reaches trust only through the accepted adapter"

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
