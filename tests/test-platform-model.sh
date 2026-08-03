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
assert_dir "${MODEL}/networks"
assert_dir "${MODEL}/storage"
assert_dir "${MODEL}/backup-policies"
assert_dir "${MODEL}/evidence"
assert_dir "${MODEL}/verifications"
assert_dir "${MODEL}/drift-rules"
assert_dir "${MODEL}/schemas"
assert_dir "${MODEL}/capabilities"

# Required ontology files.
assert_file "${MODEL}/ontology/entity-types.yaml"
assert_file "${MODEL}/ontology/relationship-types.yaml"
assert_file "${MODEL}/ontology/validation-rules.yaml"
assert_file "${MODEL}/ontology/inference-rules.yaml"

# Required entity files.
assert_file "${MODEL}/roles/ai-platform.yaml"
assert_file "${MODEL}/hosts/schai.yaml"
assert_file "${MODEL}/services/litellm.yaml"
assert_file "${MODEL}/services/ollama.yaml"

# Required relationship file.
assert_file "${MODEL}/relationships/ai-platform.yaml"

# Required documentation.
assert_file "${MODEL}/README.md"

# Evidence and verification layer: schemas, rules, and contributor guidance.
assert_file "${MODEL}/schemas/evidence.schema.yaml"
assert_file "${MODEL}/schemas/verification.schema.yaml"
assert_file "${MODEL}/schemas/drift-rule.schema.yaml"
assert_file "${MODEL}/evidence/README.md"
assert_file "${MODEL}/verifications/README.md"
assert_file "${MODEL}/drift-rules/README.md"
assert_file "${MODEL}/drift-rules/core-platform.yaml"
assert_file "${MODEL}/schemas/capability.schema.yaml"
assert_file "${MODEL}/capabilities/README.md"

# Remediation must never be automatic anywhere in the model.
assert_absent 'remediation_mode:[[:space:]]*automatic' \
  "no drift rule permits automatic remediation"

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
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
model = root / "platform-model"

PROVENANCE_CLASSES = {"declared", "observed", "inferred"}

REQUIRED_SERVICE_FIELDS = [
    "id", "type", "name", "lifecycle", "owner", "platform_role",
    "deployment", "observability", "security", "relationships",
]
REQUIRED_HOST_FIELDS = [
    "id", "type", "hostname", "lifecycle", "platform_role",
    "environment", "criticality", "observability", "security",
]
REQUIRED_ROLE_FIELDS = [
    "id", "type", "name", "purpose", "lifecycle", "owner", "default_tier",
    "responsibilities", "prohibited_workloads", "observability_requirements",
    "backup_expectations", "standards", "provenance",
]
REQUIRED_NETWORK_FIELDS = ["id", "type", "name", "lifecycle", "scope", "provenance"]
REQUIRED_STORAGE_FIELDS = ["id", "type", "name", "lifecycle", "owner", "purpose", "provenance"]
REQUIRED_BACKUP_FIELDS = [
    "id", "type", "name", "lifecycle", "owner", "scope", "retention", "provenance",
]

# Criticality tiers whose hosts must carry backup coverage or an explicit
# review flag. A Tier 0 or Tier 1 host with neither is an unrecorded risk.
CRITICAL_TIERS = {"tier-0", "tier-1"}

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
for directory in ("roles", "hosts", "services", "networks", "storage", "backup-policies", "capabilities"):
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

        # Canonical entity files are named for the bare slug, not the id, so a
        # renumbering never forces a rename. The slug is the join key.
        slug = record.get("slug")
        if slug and path.stem == slug:
            ok(f"filename matches entity slug: {rel(path)}")
        else:
            bad(f"filename {path.name} does not match entity slug {slug!r}")

        # Identifiers are four digits so ordering stays stable past 999.
        if re.fullmatch(r"[A-Z]+-\d{4}", str(entity_id)):
            ok(f"entity id uses the four-digit format: {entity_id}")
        else:
            bad(f"entity id is not a four-digit identifier: {entity_id}")

        entity_type = record.get("type")
        if entity_type in entity_types:
            ok(f"{entity_id} uses a defined entity type: {entity_type}")
        else:
            bad(f"{entity_id} uses undefined entity type: {entity_type}")

        # Lifecycle must be drawn from the vocabulary its own entity type
        # declares. A value valid for one type is not automatically valid for
        # another: "production" is a service state, "active" is a host state.
        supported = (entity_types.get(entity_type) or {}).get("lifecycle_supported") or []
        lifecycle = record.get("lifecycle")
        if not supported:
            pass  # Unknown type is already reported above.
        elif lifecycle in supported:
            ok(f"{entity_id} lifecycle '{lifecycle}' is valid for type {entity_type}")
        else:
            bad(
                f"{entity_id} lifecycle '{lifecycle}' is not supported by type "
                f"{entity_type} (allowed: {', '.join(supported)})"
            )

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
    elif record.get("type") == "platform-role":
        missing = [f for f in REQUIRED_ROLE_FIELDS if f not in record]
        if missing:
            bad(f"role {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"role {entity_id} carries all required fields")
    elif record.get("type") == "network":
        missing = [f for f in REQUIRED_NETWORK_FIELDS if f not in record]
        if missing:
            bad(f"network {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"network {entity_id} carries all required fields")
    elif record.get("type") == "storage":
        missing = [f for f in REQUIRED_STORAGE_FIELDS if f not in record]
        if missing:
            bad(f"storage {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"storage {entity_id} carries all required fields")
    elif record.get("type") == "backup-policy":
        missing = [f for f in REQUIRED_BACKUP_FIELDS if f not in record]
        if missing:
            bad(f"backup policy {entity_id} missing required fields: {', '.join(missing)}")
        else:
            ok(f"backup policy {entity_id} carries all required fields")

# Relationships stay canonical. An entity record may reference edge ids and name
# the canonical source, but must never restate source, relationship, or target.
EDGE_DEFINITION_KEYS = {"source", "relationship", "target"}
for entity_id, (path, record) in entities.items():
    block = record.get("relationships")
    if block is None:
        continue

    if not isinstance(block, dict):
        bad(f"{entity_id}: relationships must be a mapping, not a list of edges")
        continue

    if not block.get("canonical_source"):
        bad(f"{entity_id}: relationships block does not name canonical_source")
    else:
        ok(f"{entity_id} references the canonical relationship source")

    duplicated = EDGE_DEFINITION_KEYS.intersection(block.keys())
    nested = [
        item for item in (block.get("declared") or [])
        if isinstance(item, dict) and EDGE_DEFINITION_KEYS.intersection(item.keys())
    ]
    if duplicated or nested:
        bad(f"{entity_id}: relationships block duplicates edge definitions")
    else:
        ok(f"{entity_id} does not duplicate edge definitions")

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

    # Relationship ids use the same four-digit format as entity ids.
    if re.fullmatch(r"REL-\d{4}", str(edge_id)):
        ok(f"relationship id uses the four-digit format: {edge_id}")
    else:
        bad(f"relationship id is not a four-digit identifier: {edge_id}")

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

# Edges must respect the allowed_sources and allowed_targets the ontology
# declares for their relationship type. Without this the vocabulary is
# decorative: any entity kind could be joined to any other.
for path, edge in relationship_records:
    edge_id = edge.get("id", "<unidentified>")
    definition = relationship_types.get(edge.get("relationship"))
    if not definition:
        continue
    source_entity = entities.get(edge.get("source"))
    target_entity = entities.get(edge.get("target"))
    if not source_entity or not target_entity:
        continue

    source_type = source_entity[1].get("type")
    target_type = target_entity[1].get("type")
    allowed_sources = definition.get("allowed_sources") or []
    allowed_targets = definition.get("allowed_targets") or []

    if source_type in allowed_sources:
        ok(f"{edge_id} source type {source_type} is allowed for {edge.get('relationship')}")
    else:
        bad(
            f"{edge_id}: {edge.get('relationship')} does not allow source type "
            f"{source_type} (allowed: {', '.join(allowed_sources)})"
        )

    if target_type in allowed_targets:
        ok(f"{edge_id} target type {target_type} is allowed for {edge.get('relationship')}")
    else:
        bad(
            f"{edge_id}: {edge.get('relationship')} does not allow target type "
            f"{target_type} (allowed: {', '.join(allowed_targets)})"
        )

edge_set = {
    (edge.get("source"), edge.get("relationship"), edge.get("target"))
    for _, edge in relationship_records
}

REQUIRED_EDGES = [
    ("HOST-0001", "BELONGS_TO", "ROLE-0001"),
    ("SVC-0002", "BELONGS_TO", "ROLE-0001"),
    ("SVC-0003", "BELONGS_TO", "ROLE-0001"),
    ("SVC-0002", "RUNS_ON", "HOST-0001"),
    ("SVC-0003", "RUNS_ON", "HOST-0001"),
    ("SVC-0002", "DEPENDS_ON", "SVC-0003"),
]
for edge in REQUIRED_EDGES:
    if edge in edge_set:
        ok("declared relationship present: {} {} {}".format(*edge))
    else:
        bad("declared relationship missing: {} {} {}".format(*edge))

# Edge-id references inside entity records must resolve to declared edges.
# Without this, a partial id migration would leave dangling references that
# every other check would happily ignore.
for entity_id, (path, record) in entities.items():
    block = record.get("relationships")
    if not isinstance(block, dict):
        continue
    for referenced in block.get("declared") or []:
        if referenced in seen_relationship_ids:
            ok(f"{entity_id} references an existing relationship: {referenced}")
        else:
            bad(f"{entity_id} references an unknown relationship id: {referenced}")

# Every host belongs to exactly one primary role, and that role must exist.
for entity_id, (path, record) in entities.items():
    if record.get("type") != "host":
        continue
    role = record.get("platform_role")
    if isinstance(role, list):
        bad(f"host {entity_id} declares multiple primary roles: {role}")
    elif not role:
        bad(f"host {entity_id} declares no primary platform role")
    elif role not in entities:
        bad(f"host {entity_id} references an unknown platform role: {role}")
    elif entities[role][1].get("type") != "platform-role":
        bad(f"host {entity_id} platform_role {role} is not a platform-role entity")
    else:
        ok(f"host {entity_id} belongs to exactly one existing role: {role}")

# Tier 0 and Tier 1 hosts need backup coverage or an explicit review flag.
backed_up = {
    edge.get("source") for _, edge in relationship_records
    if edge.get("relationship") == "BACKED_UP_BY"
}
for entity_id, (path, record) in entities.items():
    if record.get("type") != "host":
        continue
    if record.get("criticality") not in CRITICAL_TIERS:
        continue
    if entity_id in backed_up:
        ok(f"critical host {entity_id} declares backup coverage")
    elif record.get("review_required") is True:
        ok(f"critical host {entity_id} has no backup policy but is flagged review_required")
    else:
        bad(f"critical host {entity_id} has neither backup coverage nor review_required")

# Network entities must declare a syntactically valid CIDR or address range.
CIDR = re.compile(r"^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$")
RANGE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}-(\d{1,3}\.){3}\d{1,3}$")


def octets_valid(text):
    return all(0 <= int(part) <= 255 for part in re.findall(r"\d{1,3}", text.split("/")[0]))


for entity_id, (path, record) in entities.items():
    if record.get("type") != "network":
        continue
    value = record.get("subnet") or record.get("range")
    if not value:
        # A private container network has no routable range of its own.
        if record.get("scope") == "private":
            ok(f"network {entity_id} is private and declares no routable range")
        else:
            bad(f"network {entity_id} declares neither subnet nor range")
        continue
    value = str(value)
    if (CIDR.match(value) or RANGE.match(value)) and octets_valid(value):
        ok(f"network {entity_id} declares a valid range: {value}")
    else:
        bad(f"network {entity_id} declares an invalid range: {value}")

# Entity-specific operational facts.
litellm = (entities.get("SVC-0002") or (None, {}))[1]
ollama = (entities.get("SVC-0003") or (None, {}))[1]
schai = (entities.get("HOST-0001") or (None, {}))[1]
role = (entities.get("ROLE-0001") or (None, {}))[1]


def check(condition, message):
    ok(message) if condition else bad(message)


if litellm:
    network = litellm.get("network") or {}
    check(litellm.get("platform_role") == "ROLE-0001", "LiteLLM belongs to ROLE-0001")
    check((litellm.get("deployment") or {}).get("host") == "HOST-0001", "LiteLLM runs on HOST-0001")
    check(network.get("listening_port") == 4000, "LiteLLM exposes port 4000")
    check(str(network.get("protocol", "")).lower() == "tcp", "LiteLLM uses TCP")
    check(network.get("exposure") == "application", "LiteLLM uses application exposure")
    check(
        (litellm.get("observability") or {}).get("authoritative_logs") == "docker",
        "LiteLLM identifies Docker as its authoritative log source",
    )
    check(
        ("SVC-0002", "DEPENDS_ON", "SVC-0003") in edge_set,
        "LiteLLM depends on SVC-0003",
    )

if ollama:
    network = ollama.get("network") or {}
    check(ollama.get("platform_role") == "ROLE-0001", "Ollama belongs to ROLE-0001")
    check((ollama.get("deployment") or {}).get("host") == "HOST-0001", "Ollama runs on HOST-0001")
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
    check(schai.get("platform_role") == "ROLE-0001", "schai belongs to ROLE-0001")
    check(schai.get("criticality") == "tier-1", "schai uses Tier 1 criticality")
    check(schai.get("environment") == "production", "schai uses production environment")
    # Host lifecycle uses the host vocabulary from the Platform Role and Host
    # Classification Standard, where running hosts are "active". "production" is
    # an environment, not a host lifecycle state.
    check(schai.get("lifecycle") == "active", "schai uses the active host lifecycle state")
    check(
        "Tesla P4" in yaml.safe_dump(schai.get("hardware") or {}),
        "schai identifies the Tesla P4 GPU",
    )

if role:
    for field in (
        "purpose", "responsibilities", "prohibited_workloads", "default_tier",
        "observability_requirements", "backup_expectations", "standards",
    ):
        check(field in role, f"ROLE-0001 defines {field}")

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
  printf 'ERROR PyYAML is required for %s and is not importable.\n' "$(basename "${BASH_SOURCE[0]}")" >&2
  printf 'A skipped behavioural block must never report success, so this is a failure.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

# --- v0.7.0 observation schemas and ontology -------------------------------
for schema in observation knowledge-event knowledge-state; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done
assert_file "platform-model/observations/README.md"
assert_file "platform-model/knowledge-events/README.md"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  ONTOLOGY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
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


entities = yaml.safe_load((root / "platform-model/ontology/entity-types.yaml").read_text())
types = entities.get("entity_types") or {}
check("observation" in types, "ontology defines the observation entity type")
check("knowledge-event" in types, "ontology defines the knowledge-event entity type")
check((types.get("observation") or {}).get("id_prefix") == "OBS",
      "observation entities use the OBS prefix")
check((types.get("knowledge-event") or {}).get("id_prefix") == "MEM",
      "knowledge events use the MEM prefix")
check((types.get("evidence") or {}).get("id_prefix") == "EVID",
      "evidence keeps the EVID prefix")

rels = yaml.safe_load((root / "platform-model/ontology/relationship-types.yaml").read_text())
catalog = rels.get("relationship_types") or {}
for name in ("DERIVED_FROM", "REFRESHES", "SUPERSEDES", "SUPPORTS_KNOWLEDGE", "RECORDED_IN"):
    check(name in catalog, f"ontology defines the {name} relationship")

# No relationship may imply that observed data can rewrite declared intent.
forbidden = [n for n in catalog if any(
    token in n.upper() for token in ("REMEDIAT", "APPLIES_FIX", "ENFORCES", "MUTATES"))]
check(not forbidden, "no relationship implies remediation authority")

for schema_name, prefix in (("observation", "OBS"), ("knowledge-event", "MEM")):
    schema = yaml.safe_load(
        (root / f"platform-model/schemas/{schema_name}.schema.yaml").read_text())
    check(schema.get("id_pattern") == f"^{prefix}-[0-9]{{6}}$",
          f"{schema_name} schema requires six-digit {prefix} identifiers")
    check("remediation_command" in (schema.get("forbidden_fields") or []),
          f"{schema_name} schema forbids remediation fields")

state_schema = yaml.safe_load(
    (root / "platform-model/schemas/knowledge-state.schema.yaml").read_text())
for field in ("target", "generated_at", "knowledge_age_seconds", "freshness",
              "confidence", "supporting_evidence", "review_required"):
    check(field in (state_schema.get("required_fields") or []),
          f"knowledge-state schema requires {field}")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${ONTOLOGY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  ONTOLOGY_FAILURES="$(printf '%s\n' "${ONTOLOGY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${ONTOLOGY_FAILURES}" ]]; then
    fail "observation ontology validation did not report a result"
  else
    FAILURES=$((FAILURES + ONTOLOGY_FAILURES))
  fi
fi

# --- v0.9.0 remote schemas and ontology --------------------------------------
assert_file "platform-model/schemas/remote-target.schema.yaml"
assert_file "platform-model/schemas/remote-operation.schema.yaml"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  REMOTE_OUTPUT="$(python3 - "${ROOT}" <<'REMOTEPY' 2>&1 || true
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


entities = yaml.safe_load((root / "platform-model/ontology/entity-types.yaml").read_text())
types = entities.get("entity_types") or {}
check("remote-target" in types, "ontology defines the remote-target entity type")
check("remote-operation" in types, "ontology defines the remote-operation entity type")
check((types.get("remote-target") or {}).get("id_prefix") == "RTGT",
      "remote targets use the RTGT prefix")
check((types.get("remote-operation") or {}).get("id_prefix") == "ROP",
      "remote operations use the ROP prefix")

rels = yaml.safe_load(
    (root / "platform-model/ontology/relationship-types.yaml").read_text())
catalog = rels.get("relationship_types") or {}
for name in ("TARGETS", "PERMITS_OPERATION", "COLLECTS_FROM"):
    check(name in catalog, f"ontology defines the {name} relationship")

# The Distributed Capability Fabric belongs to v0.9.5. Observation must not
# quietly acquire the vocabulary of placement.
for premature in ("PLACES_WORKLOAD", "LEASES", "SCHEDULES_ON", "PROVIDES_ENDPOINT"):
    check(premature not in catalog,
          f"no capability-fabric relationship is added early ({premature})")
for premature in ("worker-node", "workload-lease", "model-endpoint", "placement"):
    check(premature not in types,
          f"no capability-fabric entity is added early ({premature})")

target_schema = yaml.safe_load(
    (root / "platform-model/schemas/remote-target.schema.yaml").read_text())
required = target_schema.get("required_fields") or []
for field in ("target_id", "hostname", "port", "username", "host_key_policy",
              "known_hosts_reference", "authentication_reference", "platform",
              "trust_classification", "allowed_operation_ids"):
    check(field in required, f"remote-target schema requires {field}")

forbidden = target_schema.get("forbidden_fields") or []
for name in ("password", "passphrase", "private_key", "private_key_content",
             "command", "sudo"):
    check(name in forbidden, f"remote-target schema forbids {name}")

check(target_schema.get("discovery") == "not-supported",
      "remote-target schema records that discovery is unsupported")

operation_schema = yaml.safe_load(
    (root / "platform-model/schemas/remote-operation.schema.yaml").read_text())
op_required = operation_schema.get("required_fields") or []
for field in ("operation_id", "description", "platform", "sensitivity",
              "read_only"):
    check(field in op_required, f"remote-operation schema requires {field}")

# Command text must never be a schema field: the argv lives in reviewed code.
for name in ("command", "command_text", "shell", "script", "args"):
    check(name not in op_required,
          f"remote-operation schema carries no {name} field")
check(operation_schema.get("command_source") == "code-owned-catalog",
      "remote-operation schema records that argv is code-owned")

print(f"__FAILURES__={failures}")
REMOTEPY
)"
  printf '%s\n' "${REMOTE_OUTPUT}" | grep -v '^__FAILURES__=' || true
  REMOTE_FAILURES="$(printf '%s\n' "${REMOTE_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${REMOTE_FAILURES}" ]]; then
    fail "remote schema validation did not report a result"
  else
    FAILURES=$((FAILURES + REMOTE_FAILURES))
  fi
fi

# No remote target may be declared with a routable address in the repository.
assert_absent 'RTGT-[0-9]{4}.*([0-9]{1,3}\.){3}[0-9]{1,3}' \
  "no remote target is declared with a literal IP address"

# --- Duplicate mapping keys ------------------------------------------------
#
# A standard YAML loader silently keeps only the last value for a repeated key.
# In an ontology that is not a style problem: an earlier relationship
# definition disappears during parsing, and every reader downstream believes a
# vocabulary the file does not actually declare. The ontology carried three
# SUPERSEDES definitions for exactly this reason, and nothing noticed.
#
# Ontology YAML is therefore loaded through a duplicate-rejecting loader that
# fails closed and names the file, the key, and the line.

assert_file "tools/common/yaml_strict.py"
assert_file "tools/platform_model/validate_ontology.py"

if python3 -c 'import yaml' >/dev/null 2>&1; then
  STRICT_OUTPUT="$(cd "${ROOT}" && python3 - <<'STRICTPY'
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, ".")
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


try:
    from tools.common.yaml_strict import DuplicateKeyError, load_strict, loads_strict
except Exception as exc:  # noqa: BLE001 - the import itself is under test
    print(f"FAIL: tools.common.yaml_strict is importable ({exc})", file=sys.stderr)
    print("__FAILURES__=1")
    sys.exit(0)

check(True, "tools.common.yaml_strict is importable")


def rejects(text, description):
    """The loader must refuse, and the refusal must be identifiable."""
    try:
        loads_strict(text, source="fixture.yaml")
    except DuplicateKeyError as exc:
        message = str(exc)
        named_key = "duplicate" in message.lower()
        located = any(ch.isdigit() for ch in message)
        check(named_key and located,
              f"{description} (error names the key and a location)")
        return
    except Exception as exc:  # noqa: BLE001
        check(False, f"{description} (wrong exception type: {type(exc).__name__})")
        return
    check(False, f"{description} (loader accepted it)")


# Duplicate top-level key.
rejects(
    "alpha: 1\n"
    "beta: 2\n"
    "alpha: 3\n",
    "strict loader rejects a duplicate top-level key")

# Duplicate relationship key, the shape the ontology actually had.
rejects(
    "relationship_types:\n"
    "  SUPERSEDES:\n"
    "    name: Supersedes\n"
    "  OTHER:\n"
    "    name: Other\n"
    "  SUPERSEDES:\n"
    "    name: Supersedes Again\n",
    "strict loader rejects a duplicate relationship key")

# Duplicate nested key, below the top two levels.
rejects(
    "entity_types:\n"
    "  host:\n"
    "    name: Host\n"
    "    id_prefix: HOST\n"
    "    name: Host Again\n",
    "strict loader rejects a duplicate nested key")

# Values differ: the dangerous case, because meaning is silently lost.
rejects(
    "policy:\n"
    "  mode: enforce\n"
    "  mode: advisory\n",
    "strict loader rejects a duplicate key whose values differ")

# Values identical: still rejected. A loader that permits harmless duplicates
# has to decide what harmless means, and it will decide wrongly eventually.
rejects(
    "policy:\n"
    "  mode: enforce\n"
    "  mode: enforce\n",
    "strict loader rejects a duplicate key whose values are identical")

# Valid YAML must still load, and load correctly.
try:
    parsed = loads_strict(
        "relationship_types:\n"
        "  SUPERSEDES:\n"
        "    name: Supersedes\n"
        "    allowed_sources: [evidence, verification]\n",
        source="valid.yaml")
    ok = (parsed["relationship_types"]["SUPERSEDES"]["name"] == "Supersedes"
          and parsed["relationship_types"]["SUPERSEDES"]["allowed_sources"]
          == ["evidence", "verification"])
    check(ok, "strict loader accepts valid YAML and parses it correctly")
except Exception as exc:  # noqa: BLE001
    check(False, f"strict loader accepts valid YAML ({exc})")

# Repeated keys in sibling mappings are not duplicates. A loader that confused
# these would reject every real ontology file.
try:
    parsed = loads_strict(
        "entity_types:\n"
        "  host:\n"
        "    name: Host\n"
        "  service:\n"
        "    name: Service\n",
        source="siblings.yaml")
    check(len(parsed["entity_types"]) == 2,
          "strict loader accepts the same key name in sibling mappings")
except Exception as exc:  # noqa: BLE001
    check(False, f"strict loader accepts sibling mappings ({exc})")

# The error must name the file it came from, or a failure in CI is a hunt.
with tempfile.TemporaryDirectory() as tmp:
    bad = Path(tmp) / "broken-ontology.yaml"
    bad.write_text("relationship_types:\n  A:\n    name: one\n  A:\n    name: two\n")
    try:
        load_strict(bad)
        check(False, "strict loader rejects a duplicate key read from a file")
    except DuplicateKeyError as exc:
        check("broken-ontology.yaml" in str(exc),
              "strict loader names the file containing the duplicate")

# Every ontology file must load under the strict loader.
for path in sorted(Path("platform-model/ontology").glob("*.yaml")):
    try:
        load_strict(path)
        check(True, f"ontology file loads with no duplicate keys: {path.name}")
    except DuplicateKeyError as exc:
        check(False, f"ontology file has a duplicate key: {exc}")

# Every tracked schema must load under it too. The ontology is where duplicates
# were found; there is no reason to believe it is the only place they occur.
for path in sorted(Path("platform-model/schemas").glob("*.yaml")):
    try:
        load_strict(path)
    except DuplicateKeyError as exc:
        check(False, f"schema file has a duplicate key: {exc}")
check(True, "every schema file loads with no duplicate keys")

print(f"__FAILURES__={failures}")
STRICTPY
)"
  printf '%s\n' "${STRICT_OUTPUT}" | grep -v '^__FAILURES__=' || true
  STRICT_FAILURES="$(printf '%s\n' "${STRICT_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${STRICT_FAILURES}" ]]; then
    fail "strict YAML validation did not report a result"
  else
    FAILURES=$((FAILURES + STRICT_FAILURES))
  fi
fi

# The ontology validator must be wired into both CI and local validation, or
# the rejection exists and nothing runs it.
for wiring in ".github/workflows/ci.yml" "tools/dev/run-validation.sh"; do
  if grep -qE 'validate_ontology\.py' "${ROOT}/${wiring}"; then
    pass "${wiring} runs the ontology duplicate-key validator"
  else
    fail "${wiring} must run the ontology duplicate-key validator"
  fi
done

# --- Exactly one SUPERSEDES -------------------------------------------------
# Three definitions existed; only the last survived parsing. Consolidated into
# one, and asserted at the text level so a fourth cannot be reintroduced
# without this failing.
SUPERSEDES_COUNT="$(grep -cE '^  SUPERSEDES:' "${ROOT}/${MODEL}/ontology/relationship-types.yaml" || true)"
if [[ "${SUPERSEDES_COUNT}" == "1" ]]; then
  pass "relationship catalog declares exactly one SUPERSEDES definition"
else
  fail "relationship catalog must declare exactly one SUPERSEDES (found ${SUPERSEDES_COUNT})"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nPlatform model validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nPlatform model validation passed.\n'
