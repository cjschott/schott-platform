#!/usr/bin/env bash
set -Eeuo pipefail

# Static validation for the Schott Platform machine-readable knowledge model.
#
# The Bash layer validates structure, required files, and prohibited content
# using only POSIX utilities. The Python layer adds YAML parsing, reference
# resolution, and field-level assertions when PyYAML is available.
#
# This script requires no access to schai, Docker, the network, or secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODEL="platform-model"
FAILURES=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_file() {
  local rel="$1"
  if [[ -f "${ROOT}/${rel}" ]]; then
    pass "file exists: ${rel}"
  else
    fail "required file missing: ${rel}"
  fi
}

assert_dir() {
  local rel="$1"
  if [[ -d "${ROOT}/${rel}" ]]; then
    pass "directory exists: ${rel}"
  else
    fail "required directory missing: ${rel}"
  fi
}

# Assert that a pattern does NOT appear anywhere in the model.
assert_absent() {
  local pattern="$1"
  local description="$2"
  local matches

  if [[ ! -d "${ROOT}/${MODEL}" ]]; then
    fail "${description} (model directory missing)"
    return
  fi

  matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${MODEL}" || true)"

  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -3 | tr '\n' ' ')"
  fi
}

# Required directory structure.
assert_dir "${MODEL}/ontology"
assert_dir "${MODEL}/roles"
assert_dir "${MODEL}/hosts"
assert_dir "${MODEL}/services"
assert_dir "${MODEL}/relationships"

# Required ontology files.
assert_file "${MODEL}/ontology/entity-types.yaml"
assert_file "${MODEL}/ontology/relationship-types.yaml"
assert_file "${MODEL}/ontology/validation-rules.yaml"
assert_file "${MODEL}/ontology/inference-rules.yaml"

# Required entity files.
assert_file "${MODEL}/roles/ROLE-001-ai-platform.yaml"
assert_file "${MODEL}/hosts/HOST-001-schai.yaml"
assert_file "${MODEL}/services/SVC-002-litellm.yaml"
assert_file "${MODEL}/services/SVC-003-ollama.yaml"

# Required relationship file.
assert_file "${MODEL}/relationships/ai-platform.yaml"

# Required documentation.
assert_file "${MODEL}/README.md"

# Secret handling. The model may name a secret source but never a secret value.
assert_absent '(password|passwd|api_key|apikey|secret_key|master_key|private_key|access_token|bearer_token)[[:space:]]*:[[:space:]]*[^[:space:]#]' \
  "no secret values are assigned in the model"
assert_absent 'sk-[A-Za-z0-9_-]{8,}' \
  "no API key literals appear in the model"
assert_absent 'Bearer[[:space:]]+[A-Za-z0-9._-]{8,}' \
  "no bearer tokens appear in the model"
assert_absent '-----BEGIN[[:space:]]+[A-Z ]*PRIVATE KEY-----' \
  "no private key material appears in the model"

# Volatile runtime values must not be recorded as declared facts. A key may
# introduce a block that names a retrieval command, but must not carry a value.
assert_absent '(current_kernel|kernel_version|uptime|container_id|image_id|image_digest|disk_usage|free_space|ip_lease|process_id|model_inventory)[[:space:]]*:[[:space:]]*[^[:space:]#]' \
  "no volatile runtime values are recorded as declared facts"

# Runtime state must not be described as continuously current.
assert_absent ':[[:space:]]*(now|today|latest|current|currently|recently)[[:space:]]*$' \
  "no relative time expressions are recorded as values"

# Python-based structural validation.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
model = root / "platform-model"

PROVENANCE_CLASSES = {"declared", "observed", "inferred", "unknown"}

REQUIRED_SERVICE_FIELDS = [
    "id", "type", "name", "lifecycle", "owner", "platform_role",
    "deployment", "observability", "security", "relationships",
]
REQUIRED_HOST_FIELDS = [
    "id", "type", "hostname", "lifecycle", "platform_role",
    "environment", "criticality", "observability", "security",
]

failures = 0


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def rel(path):
    return path.relative_to(root)


if not model.is_dir():
    bad("platform-model directory missing; skipping structural validation")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

# Parse every YAML document in the model.
documents = {}
for path in sorted(model.rglob("*.yaml")):
    try:
        documents[path] = yaml.safe_load(path.read_text(encoding="utf-8"))
        ok(f"YAML parses: {rel(path)}")
    except Exception as error:  # noqa: BLE001 - report any parse failure
        bad(f"YAML parse error in {rel(path)}: {error}")


def load(relative_path):
    return documents.get(model / relative_path)


# Ontology vocabularies.
entity_types_doc = load("ontology/entity-types.yaml") or {}
relationship_types_doc = load("ontology/relationship-types.yaml") or {}
validation_rules_doc = load("ontology/validation-rules.yaml") or {}
inference_rules_doc = load("ontology/inference-rules.yaml") or {}

entity_types = entity_types_doc.get("entity_types") or {}
relationship_types = relationship_types_doc.get("relationship_types") or {}
validation_rules = validation_rules_doc.get("validation_rules") or []
inference_rules = inference_rules_doc.get("inference_rules") or []

REQUIRED_ENTITY_TYPES = [
    "platform", "platform-role", "host", "virtual-machine", "container",
    "service", "application", "repository", "playbook", "runbook",
    "dashboard", "alert", "backup-policy", "network", "storage",
    "standard", "architecture-decision", "api", "model", "gpu", "dataset",
]
REQUIRED_RELATIONSHIP_TYPES = [
    "BELONGS_TO", "RUNS_ON", "HOSTS", "DEPENDS_ON", "PROVIDES", "CONSUMES",
    "CONNECTS_TO", "STORES_DATA_ON", "MONITORED_BY", "LOGGED_TO", "TRACED_BY",
    "ALERTED_BY", "BACKED_UP_BY", "RECOVERED_BY", "DEPLOYED_BY", "GOVERNED_BY",
    "DOCUMENTED_BY", "AUTOMATED_BY", "VALIDATED_BY", "PROTECTED_BY",
]

for required in REQUIRED_ENTITY_TYPES:
    if required in entity_types:
        ok(f"entity type defined: {required}")
    else:
        bad(f"entity type missing from entity-types.yaml: {required}")

for required in REQUIRED_RELATIONSHIP_TYPES:
    if required in relationship_types:
        ok(f"relationship type defined: {required}")
    else:
        bad(f"relationship type missing from relationship-types.yaml: {required}")

for name, definition in entity_types.items():
    missing = [
        field for field in ("name", "description", "id_prefix", "lifecycle_supported")
        if field not in (definition or {})
    ]
    if missing:
        bad(f"entity type {name} missing fields: {', '.join(missing)}")
if entity_types and not any(
    field not in (definition or {})
    for definition in entity_types.values()
    for field in ("name", "description", "id_prefix", "lifecycle_supported")
):
    ok("every entity type defines name, description, id_prefix, lifecycle_supported")

for name, definition in relationship_types.items():
    missing = [
        field for field in (
            "name", "description", "allowed_sources", "allowed_targets",
            "transitive", "inverse", "operational_impact",
        )
        if field not in (definition or {})
    ]
    if missing:
        bad(f"relationship type {name} missing fields: {', '.join(missing)}")
if relationship_types and not any(
    field not in (definition or {})
    for definition in relationship_types.values()
    for field in (
        "name", "description", "allowed_sources", "allowed_targets",
        "transitive", "inverse", "operational_impact",
    )
):
    ok("every relationship type defines its required descriptive fields")

# Validation rules must carry identifiers and approved severities.
VALID_SEVERITIES = {"error", "warning", "information"}
if validation_rules:
    bad_rules = [
        rule for rule in validation_rules
        if not rule.get("id") or rule.get("severity") not in VALID_SEVERITIES
    ]
    if bad_rules:
        bad(f"{len(bad_rules)} validation rule(s) lack an id or approved severity")
    else:
        ok(f"all {len(validation_rules)} validation rules carry an id and severity")
else:
    bad("validation-rules.yaml defines no validation rules")

# Inference rules must declare inputs, outputs, and evidence constraints.
if inference_rules:
    for rule in inference_rules:
        rule_id = rule.get("id", "<unidentified>")
        for field in ("id", "inputs", "output", "evidence_requirement"):
            if not rule.get(field):
                bad(f"inference rule {rule_id} missing field: {field}")
    impact_rules = [
        rule for rule in inference_rules
        if "impact" in str(rule.get("output", "")).lower()
        or "impact" in str(rule.get("assessment", "")).lower()
    ]
    for rule in impact_rules:
        text = f"{rule.get('output', '')} {rule.get('assessment', '')}"
        if " may " in f" {text.lower()} ":
            ok(f"inference rule {rule.get('id')} qualifies impact with 'may'")
        else:
            bad(f"inference rule {rule.get('id')} states impact without qualification")
    ok(f"inference-rules.yaml defines {len(inference_rules)} conservative rules")
else:
    bad("inference-rules.yaml defines no inference rules")

# Entity records.
entities = {}
for directory in ("roles", "hosts", "services"):
    for path in sorted((model / directory).glob("*.yaml")) if (model / directory).is_dir() else []:
        record = documents.get(path)
        if not isinstance(record, dict):
            bad(f"entity file is not a mapping: {rel(path)}")
            continue

        entity_id = record.get("id")
        if not entity_id:
            bad(f"entity file has no id: {rel(path)}")
            continue

        if entity_id in entities:
            bad(f"duplicate entity id {entity_id} in {rel(path)}")
        else:
            entities[entity_id] = (path, record)

        if path.name.startswith(f"{entity_id}-"):
            ok(f"filename matches entity id: {rel(path)}")
        else:
            bad(f"filename does not match entity id {entity_id}: {rel(path)}")

        entity_type = record.get("type")
        if entity_type in entity_types:
            ok(f"{entity_id} uses a defined entity type: {entity_type}")
        else:
            bad(f"{entity_id} uses undefined entity type: {entity_type}")

        provenance = record.get("provenance") or {}
        provenance_class = provenance.get("class")
        if provenance_class in PROVENANCE_CLASSES:
            ok(f"{entity_id} declares provenance class: {provenance_class}")
        else:
            bad(f"{entity_id} has missing or invalid provenance class: {provenance_class}")

if len(entities) == len({eid for eid in entities}):
    ok(f"all {len(entities)} entity ids are unique")

# Required fields per entity kind.
for entity_id, (path, record) in entities.items():
    if record.get("type") == "service":
        missing = [f for f in REQUIRED_SERVICE_FIELDS if f not in record]
        if missing:
            bad(f"service {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"service {entity_id} carries all required fields")
    elif record.get("type") == "host":
        missing = [f for f in REQUIRED_HOST_FIELDS if f not in record]
        if missing:
            bad(f"host {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"host {entity_id} carries all required fields")

# Every observed fact must carry observed_at; inferred facts must be labeled.
def walk_provenance(node, path_label, entity_id):
    if isinstance(node, dict):
        provenance = node.get("provenance")
        if isinstance(provenance, dict):
            provenance_class = provenance.get("class")
            if provenance_class not in PROVENANCE_CLASSES:
                bad(f"{entity_id}: invalid provenance class at {path_label}: {provenance_class}")
            if provenance_class == "observed" and not provenance.get("observed_at"):
                bad(f"{entity_id}: observed fact at {path_label} lacks observed_at")
            if provenance_class == "inferred" and not provenance.get("derived_from"):
                bad(f"{entity_id}: inferred fact at {path_label} lacks derived_from")
        for key, value in node.items():
            if key != "provenance":
                walk_provenance(value, f"{path_label}.{key}", entity_id)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk_provenance(value, f"{path_label}[{index}]", entity_id)


for entity_id, (path, record) in entities.items():
    walk_provenance(record, "root", entity_id)
ok("observed facts carry observed_at and inferred facts carry derived_from")

# Canonical relationships.
relationship_records = []
relationships_dir = model / "relationships"
if relationships_dir.is_dir():
    for path in sorted(relationships_dir.glob("*.yaml")):
        document = documents.get(path) or {}
        for edge in document.get("relationships") or []:
            relationship_records.append((path, edge))

if relationship_records:
    ok(f"relationship files define {len(relationship_records)} declared edges")
else:
    bad("no relationships are defined under platform-model/relationships")

seen_relationship_ids = set()
for path, edge in relationship_records:
    edge_id = edge.get("id", "<unidentified>")
    source = edge.get("source")
    target = edge.get("target")
    relationship = edge.get("relationship")

    if edge_id in seen_relationship_ids:
        bad(f"duplicate relationship id {edge_id} in {rel(path)}")
    seen_relationship_ids.add(edge_id)

    if relationship in relationship_types:
        ok(f"{edge_id} uses a defined relationship type: {relationship}")
    else:
        bad(f"{edge_id} uses undefined relationship type: {relationship}")

    for role, value in (("source", source), ("target", target)):
        if value in entities:
            ok(f"{edge_id} {role} resolves: {value}")
        else:
            bad(f"{edge_id} {role} does not resolve to a known entity: {value}")

    provenance_class = (edge.get("provenance") or {}).get("class")
    if provenance_class == "declared":
        ok(f"{edge_id} is labeled declared")
    elif provenance_class == "inferred":
        if (edge.get("provenance") or {}).get("derived_from"):
            ok(f"{edge_id} is labeled inferred with derived_from")
        else:
            bad(f"{edge_id} is labeled inferred but lacks derived_from")
    else:
        bad(f"{edge_id} has missing or invalid provenance class: {provenance_class}")

edge_set = {
    (edge.get("source"), edge.get("relationship"), edge.get("target"))
    for _, edge in relationship_records
}

REQUIRED_EDGES = [
    ("HOST-001", "BELONGS_TO", "ROLE-001"),
    ("SVC-002", "BELONGS_TO", "ROLE-001"),
    ("SVC-003", "BELONGS_TO", "ROLE-001"),
    ("SVC-002", "RUNS_ON", "HOST-001"),
    ("SVC-003", "RUNS_ON", "HOST-001"),
    ("SVC-002", "DEPENDS_ON", "SVC-003"),
]
for edge in REQUIRED_EDGES:
    if edge in edge_set:
        ok("declared relationship present: {} {} {}".format(*edge))
    else:
        bad("declared relationship missing: {} {} {}".format(*edge))

# Entity-specific operational facts.
litellm = (entities.get("SVC-002") or (None, {}))[1]
ollama = (entities.get("SVC-003") or (None, {}))[1]
schai = (entities.get("HOST-001") or (None, {}))[1]
role = (entities.get("ROLE-001") or (None, {}))[1]


def check(condition, message):
    ok(message) if condition else bad(message)


if litellm:
    network = litellm.get("network") or {}
    check(litellm.get("platform_role") == "ROLE-001", "LiteLLM belongs to ROLE-001")
    check((litellm.get("deployment") or {}).get("host") == "HOST-001", "LiteLLM runs on HOST-001")
    check(network.get("listening_port") == 4000, "LiteLLM exposes port 4000")
    check(str(network.get("protocol", "")).lower() == "tcp", "LiteLLM uses TCP")
    check(network.get("exposure") == "application", "LiteLLM uses application exposure")
    check(
        (litellm.get("observability") or {}).get("authoritative_logs") == "docker",
        "LiteLLM identifies Docker as its authoritative log source",
    )
    check(
        ("SVC-002", "DEPENDS_ON", "SVC-003") in edge_set,
        "LiteLLM depends on SVC-003",
    )

if ollama:
    network = ollama.get("network") or {}
    check(ollama.get("platform_role") == "ROLE-001", "Ollama belongs to ROLE-001")
    check((ollama.get("deployment") or {}).get("host") == "HOST-001", "Ollama runs on HOST-001")
    check(network.get("listening_port") == 11434, "Ollama uses port 11434 internally")
    check(network.get("exposure") == "private", "Ollama remains private")
    check(
        not (network.get("published_ports") or []),
        "Ollama declares no host-published port",
    )
    check(
        (ollama.get("observability") or {}).get("authoritative_logs") == "docker",
        "Ollama identifies Docker as its authoritative log source",
    )

if schai:
    check(schai.get("hostname") == "schai", "schai uses hostname schai")
    check(schai.get("platform_role") == "ROLE-001", "schai belongs to ROLE-001")
    check(schai.get("criticality") == "tier-1", "schai uses Tier 1 criticality")
    check(schai.get("environment") == "production", "schai uses production environment")
    check(
        "Tesla P4" in yaml.safe_dump(schai.get("hardware") or {}),
        "schai identifies the Tesla P4 GPU",
    )

if role:
    for field in (
        "purpose", "responsibilities", "prohibited_workloads", "default_tier",
        "required_monitoring", "required_backup", "standards",
    ):
        check(field in role, f"ROLE-001 defines {field}")

print(f"__FAILURES__={failures}")
PY
)"

  # Surface Python results and fold their failure count into the Bash total.
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "Python model validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'SKIP: PyYAML is not installed; structural YAML validation was skipped.\n'
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nPlatform model validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nPlatform model validation passed.\n'
