# Platform Model Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the first machine-readable increment of the Schott Platform knowledge model: a canonical ontology and the four AI Platform entities that prove it works.

**Architecture:** The [Platform Ontology Standard](../../standards/platform-ontology-standard.md) defines the vocabulary. This increment renders that vocabulary as YAML under `platform-model/`, adds validation and inference rules, and populates the AI Platform role, the `schai` host, and the LiteLLM and Ollama services. Relationships live in one canonical list rather than being duplicated across entity files. Every fact carries a provenance class per the [Operational Metadata Standard](../../standards/operational-metadata-standard.md).

**Tech Stack:** YAML, Bash static validation, Python 3 with PyYAML for parse verification.

## Global Constraints

- This increment is documentation and data only. No containers, firewall rules, SSH configuration, services, or Docker volumes are touched.
- Entity type values use kebab-case, matching the Platform Ontology Standard.
- YAML field names use snake_case.
- Stable IDs are `ROLE-0001`, `HOST-0001`, `SVC-0002`, `SVC-0003`.
- Owner is `platform-engineering`. Environment is `production`. Service lifecycle is
  `production`; host lifecycle is `active`, per the host vocabulary.
- LiteLLM is the only application-facing AI endpoint. Ollama stays private with no host-published port.
- No secrets, API keys, passwords, bearer tokens, or real environment values.
- No volatile runtime values recorded as declared facts.
- Observed facts require `observed_at`. Inferred facts are labeled `inferred` and use qualified language. Explicit relationships are labeled `declared`.
- Kyri is a future consumer, not a deployed entity in this increment.

## Out of Scope

Do not implement in this increment:

- Kyri as a deployed service entity
- Neo4j or any graph database
- Runtime discovery or reconciliation
- Ansible inventory generation
- Grafana dashboard provisioning
- API development
- Additional hosts or services beyond the four listed IDs

---

## File Structure

- `platform-model/ontology/entity-types.yaml`: controlled entity vocabulary.
- `platform-model/ontology/relationship-types.yaml`: controlled relationship vocabulary.
- `platform-model/ontology/validation-rules.yaml`: rule IDs, descriptions, and severities.
- `platform-model/ontology/inference-rules.yaml`: conservative derivation rules.
- `platform-model/roles/ai-platform.yaml`: AI Platform role definition.
- `platform-model/hosts/schai.yaml`: `schai` host entity.
- `platform-model/services/litellm.yaml`: LiteLLM service entity.
- `platform-model/services/ollama.yaml`: Ollama service entity.
- `platform-model/relationships/ai-platform.yaml`: canonical declared relationship list.
- `platform-model/README.md`: model layout, provenance rules, and contribution procedure.
- `tests/test-platform-model.sh`: static and YAML validation for the model.

---

### Task 1: Model Contract Tests

**Files:**
- Create: `tests/test-platform-model.sh`

**Interfaces:**
- Consumes: the ontology and operational metadata standards.
- Produces: the executable contract every later task must satisfy.

A dedicated test file is used rather than extending `tests/test-docs-static.sh` because this contract validates structured data and requires Python-based YAML parsing, which is a different concern from Markdown documentation assertions.

- [ ] **Step 1: Assert directory structure**

Require `platform-model/ontology`, `roles`, `hosts`, `services`, and `relationships`.

- [ ] **Step 2: Assert required files**

Require the four ontology files, the four entity files, the relationship file, and the README.

- [ ] **Step 3: Assert entity and relationship integrity**

Require unique IDs, four-digit id format, filename-to-slug agreement, resolvable source and target references, relationship types defined in `relationship-types.yaml`, and entity types defined in `entity-types.yaml`.

- [ ] **Step 4: Assert required fields**

Services require `id`, `type`, `name`, `lifecycle`, `owner`, `platform_role`, `deployment`, `observability`, `security`, `relationships`. Hosts require `id`, `type`, `hostname`, `lifecycle`, `platform_role`, `environment`, `criticality`, `observability`, `security`.

- [ ] **Step 5: Assert service-specific facts**

LiteLLM runs on `HOST-0001`, belongs to `ROLE-0001`, depends on `SVC-0003`, exposes TCP 4000, uses application exposure, and names Docker as its authoritative log source. Ollama runs on `HOST-0001`, belongs to `ROLE-0001`, is private, uses TCP 11434 internally, declares no host-published port, and names Docker as its authoritative log source. `schai` uses hostname `schai`, belongs to `ROLE-0001`, is Tier 1, is in the production environment with lifecycle `active`, and identifies the Tesla P4 GPU.

- [ ] **Step 6: Assert safety rules**

No secrets, API keys, passwords, bearer tokens, or real environment values. No runtime state presented as continuously current. Observed facts carry `observed_at` or are marked declared. Inferred relationships are labeled `inferred`; explicit relationships are labeled `declared`.

- [ ] **Step 7: Run the test and verify failure**

Run: `bash tests/test-platform-model.sh`

Expected: FAIL for every missing directory and file.

- [ ] **Step 8: Commit**

```bash
git add tests/test-platform-model.sh
git commit -m "test: define platform model contracts"
```

### Task 2: Ontology Definitions

**Files:**
- Create: `platform-model/ontology/entity-types.yaml`
- Create: `platform-model/ontology/relationship-types.yaml`
- Create: `platform-model/ontology/validation-rules.yaml`
- Create: `platform-model/ontology/inference-rules.yaml`

**Interfaces:**
- Consumes: the Platform Ontology Standard vocabulary.
- Produces: the semantic source of truth every entity file is validated against.

- [ ] **Step 1: Define entity types**

Each type carries `name`, `description`, `id_prefix`, `lifecycle_supported`. Cover platform, platform-role, host, virtual-machine, container, service, application, repository, playbook, runbook, dashboard, alert, backup-policy, network, storage, standard, architecture-decision, api, model, gpu, dataset.

- [ ] **Step 2: Define relationship types**

Each type carries `name`, `description`, `allowed_sources`, `allowed_targets`, `transitive`, `inverse`, `operational_impact`. Cover the twenty relationship types required by the increment plus the ontology standard's `OWNS`, `MANAGES`, and `REQUIRES`.

- [ ] **Step 3: Define validation rules**

Each rule carries an identifier and a severity of `error`, `warning`, or `information`. Cover unique IDs, filename-slug agreement, reference resolution, role membership, deployment targets, Tier 0/1 owner and recovery references, security classification for remotely exposed services, wildcard publishing prohibition for private services, `observed_at` requirements, and the prohibition on representing inferred facts as observed.

- [ ] **Step 4: Define inference rules**

Limit to three conservative rules: indirect host dependency, role association through host membership, and possible impact from an unavailable dependency. Each rule identifies its input relationships and its output, uses "may" for impact, and prohibits claiming live state without runtime evidence.

- [ ] **Step 5: Run tests**

Run: `bash tests/test-platform-model.sh`

Expected: ontology assertions PASS; entity assertions still FAIL.

- [ ] **Step 6: Commit**

```bash
git add platform-model/ontology
git commit -m "feat: add platform ontology definitions"
```

### Task 3: AI Platform Entities and Relationships

**Files:**
- Create: `platform-model/roles/ai-platform.yaml`
- Create: `platform-model/hosts/schai.yaml`
- Create: `platform-model/services/litellm.yaml`
- Create: `platform-model/services/ollama.yaml`
- Create: `platform-model/relationships/ai-platform.yaml`

**Interfaces:**
- Consumes: the ontology from Task 2.
- Produces: the first populated slice of the platform graph.

- [ ] **Step 1: Create ROLE-0001**

Define purpose, responsibilities, prohibited workloads, default tier, required monitoring, required backup expectations, and standards references.

- [ ] **Step 2: Create HOST-0001**

Define hostname `schai`, role `ROLE-0001`, Tier 1 criticality, Ubuntu platform, `America/Chicago` timezone, Tesla P4 GPU, management classification, authoritative host log sources, and references to standards and acceptance documentation. Record declared facts only; use retrieval commands instead of volatile values.

- [ ] **Step 3: Create SVC-0002 LiteLLM**

Define role, host, Compose project `ai`, TCP 4000, application exposure, source scope `192.168.86.0/24`, authenticated OpenAI-compatible API, Docker authoritative logs, health-check command reference, and dependency on `SVC-0003`. No secrets.

- [ ] **Step 4: Create SVC-0003 Ollama**

Define role, host, TCP 11434 internal, private exposure, no host-published port, Docker authoritative logs, model-serving purpose, and the persistent model volume by logical name only. No model blobs, digests, or inventory treated as live state.

- [ ] **Step 5: Create the canonical relationship list**

Declare `HOST-0001 BELONGS_TO ROLE-0001`, `SVC-0002 BELONGS_TO ROLE-0001`, `SVC-0003 BELONGS_TO ROLE-0001`, `SVC-0002 RUNS_ON HOST-0001`, `SVC-0003 RUNS_ON HOST-0001`, `SVC-0002 DEPENDS_ON SVC-0003`. Reference the network policy, Docker standard, Linux security standard, and acceptance results where appropriate. Keep one canonical list; do not duplicate edges across files.

- [ ] **Step 6: Run tests**

Run: `bash tests/test-platform-model.sh`

Expected: PASS except the README assertion.

- [ ] **Step 7: Commit**

```bash
git add platform-model/roles platform-model/hosts platform-model/services platform-model/relationships
git commit -m "feat: add initial AI platform entities"
```

### Task 4: Model Documentation

**Files:**
- Create: `platform-model/README.md`

**Interfaces:**
- Consumes: the completed model.
- Produces: the contribution and validation procedure for future increments.

- [ ] **Step 1: Write the README**

Explain purpose, directory structure, declared versus observed versus inferred facts, stable IDs, how to add an entity, how to add a relationship, how to validate, security rules, why runtime facts must not be silently represented as current, and that Kyri is a future consumer rather than a deployed entity.

- [ ] **Step 2: Run the full validation suite**

```bash
bash -n tests/*.sh
bash tests/test-docs-static.sh
bash tests/test-platform-model.sh
git diff --check
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add platform-model/README.md
git commit -m "docs: document platform model usage"
```

---

## Verification

The increment is complete when:

- All four ontology files parse and define the required vocabulary.
- All four entity files parse, carry required fields, and reference resolvable IDs.
- The canonical relationship list resolves every source and target.
- `tests/test-platform-model.sh` passes.
- `tests/test-docs-static.sh` passes.
- `git diff --check` is clean.
- Every YAML file under `platform-model/` parses with PyYAML.
- No secrets or volatile runtime values are present.

## Known Limitations

- `tests/test-static.sh` has three pre-existing failures against `docs/security/network-policy.md` that predate this increment and are not addressed here.
- The model records declared intent only. No runtime observation is collected in this increment, so no entity carries an `observed_at` fact yet.
- Backup, dashboard, alert, and runbook entities are referenced conceptually but not created, because those entities are out of scope for this increment.
