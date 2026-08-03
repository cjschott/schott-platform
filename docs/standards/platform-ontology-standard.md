# Platform Ontology Standard

## Purpose

This standard defines the controlled vocabulary, entity types, relationship types, semantic rules, and inference boundaries used by the Schott Platform knowledge model.

The ontology gives humans, automation, observability systems, and Kyri the same meaning for hosts, services, roles, runbooks, dashboards, backups, networks, storage, repositories, and dependencies.

## Scope

This standard applies to all machine-readable records under `platform-model/` and to human-readable documentation that references those records.

It governs:

- Entity types
- Stable identifiers
- Relationship types
- Cardinality rules
- Validation rules
- Inference rules
- Lifecycle semantics
- Security and privacy constraints

## Core Principle

Every managed object is represented as an entity with:

- A stable identifier
- An approved entity type
- A human-readable name
- Operational metadata
- Lifecycle state
- Zero or more approved relationships

Names may change. Stable identifiers and relationship meaning must remain consistent.

## Canonical Ontology Layout

```text
platform-model/
└── ontology/
    ├── entity-types.yaml
    ├── relationship-types.yaml
    ├── validation-rules.yaml
    └── inference-rules.yaml
```

These files become the machine-readable semantic source of truth. Documentation may explain the ontology, but tools must consume the canonical model rather than inventing private terminology.

## Entity Types

The initial controlled vocabulary includes:

### Platform and governance

- `platform`
- `platform-role`
- `standard`
- `architecture-decision`
- `repository`

### Infrastructure

- `host`
- `virtual-machine`
- `container`
- `network`
- `storage`
- `gpu`

### Workloads and interfaces

- `service`
- `application`
- `api`
- `model`
- `dataset`

### Operations

- `runbook`
- `playbook`
- `dashboard`
- `alert`
- `backup-policy`

### Distributed Capability Fabric

Added by [ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md) as a documented ontology change:

- `capability-definition`
- `capability-contract`
- `capability-package`
- `capability-host`
- `capability-advertisement`
- `capability-instance`
- `capability-route`
- `capability-selection`

These describe **executable** things. The `capability` type above describes a stated ability of the platform and carries a maturity claim; nothing routes to it. They are separate types, with separate identifier spaces, precisely so the two meanings cannot be conflated — see the [Capability Model Standard](capability-model-standard.md).

Additional entity types require a documented ontology change. Do not represent the same concept with multiple competing type names.

## Stable Identifier Conventions

Entity identifiers must be unique and immutable.

Recommended prefixes:

| Entity type | Prefix | Example |
|---|---|---|
| Host | `HOST` | `HOST-0001` |
| Platform role | `ROLE` | `ROLE-0001` |
| Service | `SVC` | `SVC-001` |
| Application | `APP` | `APP-001` |
| Network | `NET` | `NET-001` |
| Storage | `STOR` | `STOR-001` |
| Runbook | `RB` | `RB-AI-001` |
| Playbook | `PB` | `PB-001` |
| Dashboard | `DASH` | `DASH-001` |
| Alert | `ALERT` | `ALERT-001` |
| Backup policy | `BKP` | `BKP-001` |
| Standard | `STD` | `STD-001` |
| Architecture decision | `ADR` | `ADR-0001` |
| Repository | `REPO` | `REPO-001` |
| Model | `MODEL` | `MODEL-001` |
| GPU | `GPU` | `GPU-001` |

An identifier must not be reused after an entity is retired.

## Relationship Model

Relationships are directed edges between two existing entities.

Each relationship must contain:

- Source entity ID
- Approved relationship type
- Target entity ID
- Dependency class when applicable
- Impact level when applicable
- Optional operational notes

Illustrative record:

```yaml
source: SVC-001
relationship: DEPENDS_ON
target: SVC-0002
dependency_class: hard
impact: service-unavailable
```

## Approved Relationship Types

### Placement and ownership

- `BELONGS_TO`
- `RUNS_ON`
- `HOSTS`
- `OWNS`
- `MANAGES`

### Service and data flow

- `DEPENDS_ON`
- `PROVIDES`
- `CONSUMES`
- `REQUIRES`
- `CONNECTS_TO`
- `STORES_DATA_ON`

### Governance and automation

- `GOVERNED_BY`
- `DOCUMENTED_BY`
- `AUTOMATED_BY`
- `DEPLOYED_BY`
- `VALIDATED_BY`

### Observability

- `MONITORED_BY`
- `LOGGED_TO`
- `TRACED_BY`
- `ALERTED_BY`

### Protection and recovery

- `BACKED_UP_BY`
- `RECOVERED_BY`
- `PROTECTED_BY`

New relationship types require an ontology change. Synonyms must not be added when an existing relationship already expresses the intended meaning.

## Direction and Inverse Relationships

Relationship direction must be consistent.

Examples:

```text
SVC-001 RUNS_ON HOST-0001
HOST-0001 HOSTS SVC-001
SVC-001 DOCUMENTED_BY RB-AI-001
DASH-001 MONITORS SVC-001
```

Where inverse relationships are useful, one side may be stored and the inverse may be derived. The canonical ontology must identify which relationship is authoritative to avoid duplicate or contradictory edges.

## Cardinality Rules

Initial validation rules include:

- Every active `host` must `BELONGS_TO` one primary `platform-role`.
- Every active `service` must `BELONGS_TO` at least one `platform-role`.
- Every deployed `service` must `RUNS_ON` at least one logical deployment target.
- Every production `service` must be `DOCUMENTED_BY` at least one runbook or approved operational document.
- Every Tier 0 or Tier 1 stateful service must be `BACKED_UP_BY` an approved backup policy or carry a documented exception.
- Every remotely exposed service must be `GOVERNED_BY` the Service Exposure Standard.
- Every relationship source and target must reference an existing entity.
- Retired entities may remain referenced for history but must not be treated as active dependencies.

High-availability services may run on multiple targets. Single-instance services must not claim multiple active deployment targets without documented intent.

## Semantic Constraints

Examples of valid relationships:

- A `service` may `RUNS_ON` a `host`, `virtual-machine`, or `container` deployment target.
- A `container` may `RUNS_ON` a `host` or `virtual-machine`.
- A `runbook` may document a `service`, `host`, `platform-role`, or recovery process.
- A `dashboard` may monitor one or more services or hosts.
- A `backup-policy` may protect services, hosts, storage entities, or datasets.
- A `standard` may govern any operational entity.

Examples of invalid relationships:

- A `network` must not `RUNS_ON` a runbook.
- A `dashboard` must not `BACKED_UP_BY` a host unless the intended protected data is explicitly modeled.
- A `service` must not `DEPENDS_ON` itself.

## Dependency Semantics

Dependencies use the classifications defined by the Dependency Mapping Standard:

- `hard`
- `soft`
- `operational`
- `informational`

Dependencies may also include an impact value such as:

- `service-unavailable`
- `degraded-performance`
- `management-only`
- `observability-loss`
- `recovery-risk`

A hard dependency contributes to startup, shutdown, recovery, and impact-analysis ordering.

## Inference Rules

Inference may derive new facts from approved relationships, but inferred facts must remain distinguishable from explicitly declared facts.

Initial safe inference examples:

1. If a service `RUNS_ON` a host and another service has a hard `DEPENDS_ON` relationship to that service, the dependent service indirectly depends on that host.
2. If a host `BELONGS_TO` a platform role, services running on that host may inherit the role as a candidate classification, but explicit service metadata takes precedence.
3. If a service is `DOCUMENTED_BY` a runbook and the runbook references a recovery procedure, Kyri may identify that runbook as relevant recovery guidance.
4. If a Tier 0 or Tier 1 stateful service lacks a `BACKED_UP_BY` relationship, validation may report a coverage gap.
5. If a service is `MONITORED_BY` a dashboard and `ALERTED_BY` an alert, Kyri may include both when presenting the service's operational view.

Inference must not silently create write actions, change firewall policy, expose secrets, or claim live state without runtime evidence.

## Explicit Facts vs. Inferred Facts

Tools consuming the ontology must label knowledge with exactly one provenance class:

- `declared`: explicitly stored in the platform model
- `observed`: collected from live systems
- `inferred`: derived from ontology rules

The vocabulary is exactly these three values. There is no alias for any of them; one concept has one name.

A fact that is not represented or not verifiable has no provenance class. Record the value itself as `unknown` rather than inventing a fourth class, and never promote an unclassified value to an operational decision.

When sources conflict, consumers must report the conflict rather than choosing a convenient value silently.

The full contract for these classes is defined in the [Operational Metadata Standard](operational-metadata-standard.md).

## Example AI Platform Graph

```text
ROLE-0001  AI Platform
   |
   +-- HOST-0001  schai
          |
          +-- SVC-0002  LiteLLM
          |      |
          |      +-- DEPENDS_ON --> SVC-0003  Ollama
          |
          +-- SVC-0003  Ollama
                 |
                 +-- REQUIRES --> GPU-001  Tesla P4
                 +-- STORES_DATA_ON --> STOR-001  Ollama model volume
```

Operational relationships may extend the graph:

```text
SVC-0002 DOCUMENTED_BY RB-AI-001
SVC-0002 MONITORED_BY DASH-001
SVC-0003 BACKED_UP_BY BKP-001
SVC-0002 GOVERNED_BY STD-EXPOSURE-001
```

## Knowledge Traversal

Kyri and other consumers may traverse the graph to answer operational questions.

For a request such as `Can I reboot schai?`, the traversal should consider:

1. The host entity
2. Hosted services
3. Consumers of those services
4. Hard dependencies
5. Criticality and lifecycle state
6. Backup coverage
7. Related runbooks
8. Observability state, when available
9. Recovery ordering
10. Known limitations and unknowns

The result must identify both direct and inferred impact.

## Digital Twin Boundary

The platform model is an operational knowledge twin, not a guaranteed real-time copy of the environment.

It combines:

- Desired state from Git
- Asserted relationships
- Runtime observations
- Validation results
- Documented exceptions

Runtime truth must be refreshed before high-impact decisions. Stale metadata must not be presented as current fact without qualification.

## Security and Privacy

The ontology must not store:

- Passwords
- Private keys
- API tokens
- Session secrets
- Unredacted sensitive prompts or payloads
- Credentials embedded in URLs

Sensitive entity existence may be modeled, but secret values must remain in approved secret stores.

Graph queries must respect authorization boundaries when the model later includes business, user, or confidential data.

## Validation Requirements

CI validation should eventually verify:

- YAML syntax
- Unique identifiers
- Approved entity types
- Approved relationship types
- Existing source and target entities
- Required metadata fields
- Cardinality rules
- No direct self-dependencies
- No invalid hard-dependency cycles
- No live secrets
- Valid document references

The validator must return actionable file paths and entity IDs for failures.

## Lifecycle Management

Entities use controlled lifecycle states such as:

- `proposed`
- `development`
- `active`
- `deprecated`
- `retired`

Relationships involving retired entities remain for historical analysis but must not drive current automation unless explicitly requested.

## Change Control

Ontology changes require:

- A clear reason
- Compatibility analysis
- Migration guidance for existing model files
- Validation updates
- Documentation updates

Breaking semantic changes should be reviewed as architecture decisions.

## Implementation Phases

### Phase 1: Canonical YAML

Create the four ontology files and initial entities for the AI Platform.

### Phase 2: Validation

Add schema and relationship validation in CI.

### Phase 3: Graph generation

Generate an in-memory or persisted graph from the canonical YAML model.

### Phase 4: Kyri traversal

Use the graph for inventory, dependency, runbook, and impact-analysis queries.

### Phase 5: Runtime reconciliation

Compare desired model state with live observations and report drift.

### Phase 6: Predictive reasoning

Use historical telemetry and dependency data to produce qualified recommendations without bypassing human approval.

## Compliance

The platform complies with this standard when:

- Managed objects use approved entity types and stable identifiers.
- Relationships use the controlled vocabulary.
- Source and target references resolve.
- Explicit and inferred facts remain distinguishable.
- Critical cardinality and dependency rules are validated.
- Sensitive values are excluded.
- Ontology changes follow review and migration procedures.
