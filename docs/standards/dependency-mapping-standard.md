# Dependency Mapping Standard

## Purpose

This standard defines how the Schott Platform records dependencies between hosts, services, applications, platform roles, networks, storage, monitoring, backups, automation, and operational documentation.

The goal is to make impact analysis, recovery planning, troubleshooting, maintenance, and Kyri reasoning depend on explicit relationships rather than assumptions or keyword searches.

## Scope

This standard applies to all long-lived platform entities, including:

- Hosts
- Virtual machines
- Containers
- Services
- Applications
- Platform roles
- Networks
- Storage
- Backup systems
- Monitoring systems
- Repositories
- Runbooks
- Standards
- Architecture Decision Records
- Automation

## Core Principle

Dependencies must be recorded as directed relationships.

A dependency record must identify:

- The source entity
- The relationship type
- The target entity
- Whether the dependency is required or optional
- Whether failure is blocking, degraded, or informational
- The validation method
- The recovery implication

A dependency must not be inferred only from a hostname, Compose file, firewall rule, or prose document when it can be represented explicitly.

## Canonical Storage

Machine-readable dependency data belongs under:

```text
platform-model/dependencies/
```

Recommended organization:

```text
platform-model/dependencies/
├── services.yaml
├── hosts.yaml
├── applications.yaml
├── infrastructure.yaml
└── operations.yaml
```

Smaller deployments may use a single `dependencies.yaml` file until the model becomes large enough to justify separation.

Human-readable diagrams and explanations belong under:

```text
docs/architecture/dependencies/
```

The machine-readable model is authoritative for relationship data. Diagrams are views generated from or reviewed against that model.

## Entity References

Dependencies must reference stable entity identifiers rather than display names alone.

Examples:

```text
HOST-001
SVC-AI-001
ROLE-AI-001
NET-001
STORE-001
RB-AI-001
```

Display names may change without invalidating relationships.

## Relationship Types

The initial approved relationship vocabulary is:

### Runtime relationships

- `RUNS_ON` — a service or application runs on a host, VM, or container platform.
- `HOSTED_BY` — inverse view of `RUNS_ON` where needed for readability.
- `DEPENDS_ON` — a source requires a target to provide normal functionality.
- `USES` — a source consumes a target but may not fail completely without it.
- `CONNECTS_TO` — a network or protocol relationship exists.
- `STORES_DATA_ON` — persistent state is stored on a target.
- `AUTHENTICATES_WITH` — identity or authentication depends on a target.

### Platform relationships

- `BELONGS_TO_ROLE` — a host or service belongs to a platform role.
- `USES_STANDARD` — an entity is governed by a platform standard.
- `IMPLEMENTED_BY` — a policy or service is implemented through automation or configuration.
- `MANAGED_BY` — an entity is managed by Ansible, a repository, or another control system.
- `EXPOSED_THROUGH` — client access flows through a gateway, proxy, or API layer.

### Operational relationships

- `MONITORED_BY` — metrics, logs, traces, or health are observed by a target.
- `ALERTED_BY` — alerting responsibility is provided by a target.
- `BACKED_UP_BY` — data or configuration is protected by a target.
- `RECOVERED_BY` — a runbook or recovery system restores the source.
- `DOCUMENTED_BY` — a runbook, standard, ADR, or service document explains the source.
- `DEPLOYED_BY` — automation deploys or updates the source.

### Ownership relationships

- `OWNED_BY` — a person, team, or platform function is accountable.
- `MAINTAINED_BY` — routine upkeep is assigned to a person, team, or automation process.

New relationship types require review and must not duplicate an existing meaning under a different name.

## Dependency Classes

Each dependency must declare one of these classes:

### Hard

The source cannot provide its primary function without the target.

Example:

```text
LiteLLM DEPENDS_ON Ollama
```

### Soft

The source continues operating with reduced capability when the target is unavailable.

Example:

```text
Kyri USES Grafana
```

### Operational

The dependency affects management, monitoring, backup, deployment, or recovery rather than direct runtime behavior.

Example:

```text
Ollama BACKED_UP_BY configuration backup process
```

### Informational

The relationship provides context but does not create an operational requirement.

Example:

```text
Docker Platform Standard DOCUMENTS service deployment conventions
```

## Failure Impact

Every dependency must include an impact value:

- `blocking` — the source cannot perform its primary function.
- `degraded` — the source remains partially usable.
- `operational-only` — runtime continues, but monitoring, backup, deployment, or recovery is affected.
- `none` — informational relationship only.

## Required Fields

Each dependency record must include:

```yaml
id: DEP-0001
source: SVC-AI-002
relationship: DEPENDS_ON
target: SVC-AI-003
class: hard
impact: blocking
reason: LiteLLM requires an inference backend
validation:
  method: authenticated model completion through LiteLLM
recovery:
  order: target-first
owner: platform-engineering
lifecycle: active
```

Required fields:

- `id`
- `source`
- `relationship`
- `target`
- `class`
- `impact`
- `reason`
- `validation.method`
- `recovery.order`
- `owner`
- `lifecycle`

## Lifecycle

Dependency records use these lifecycle states:

- `proposed`
- `active`
- `deprecated`
- `retired`

A retired dependency remains in history when needed for auditability but must not be treated as part of the active platform graph.

## Direction and Inverses

Relationships are stored in one canonical direction.

Example:

```text
Kyri DEPENDS_ON LiteLLM
```

The inverse question, "What depends on LiteLLM?", is answered by querying inbound relationships. Duplicate inverse records should not be created unless a specific consumer requires them.

## Runtime Dependency Rules

A service record must identify all hard runtime dependencies required for startup or healthy operation.

Examples include:

- Databases
- APIs
- Message queues
- Model-serving backends
- DNS
- Storage
- Identity providers
- Network paths

Health checks should distinguish between:

- The service process running
- The service being locally responsive
- Required dependencies being reachable
- End-to-end functionality succeeding

## Host Dependencies

Host dependency records should capture infrastructure requirements such as:

- Hypervisor
- Network gateway
- DNS
- Storage
- Backup target
- Management plane
- Power protection

Example:

```text
schai RUNS_ON schoxmox1
schai CONNECTS_TO pfSense gateway
schai AUTHENTICATES_WITH local SSH keys
schai BACKED_UP_BY Proxmox Backup Server
```

## Network Dependencies

Network dependencies must record:

- Source entity
- Target entity
- Protocol
- Port
- Approved source range or security zone
- Exposure classification
- Required DNS name, when applicable
- Encryption requirement

Example:

```yaml
id: DEP-NET-0001
source: SVC-AI-001
relationship: CONNECTS_TO
target: SVC-AI-002
class: hard
impact: blocking
network:
  protocol: tcp
  port: 4000
  source_zone: application-lan
  encryption: none-internal
validation:
  method: authenticated GET /v1/models
recovery:
  order: target-first
owner: platform-engineering
lifecycle: active
```

## Storage Dependencies

Storage relationships must distinguish between:

- Configuration
- Persistent application data
- Databases
- Model data
- Logs
- Backup data
- Temporary staging data

The record must state whether the data is authoritative, reproducible, cached, or disposable.

## Backup and Recovery Relationships

Every stateful service must have explicit `BACKED_UP_BY` and `RECOVERED_BY` relationships.

The dependency model must make recovery order visible.

Example:

```text
Kyri RECOVERED_BY RB-AI-001
Kyri BACKED_UP_BY BACKUP-001
BACKUP-001 DEPENDS_ON schpbs
```

Recovery order should use one of:

- `target-first`
- `source-first`
- `parallel`
- `not-applicable`

## Monitoring Relationships

Services and hosts must identify how they are observed.

Examples:

```text
schai MONITORED_BY Prometheus
schai MONITORED_BY Grafana Alloy
LiteLLM MONITORED_BY Loki
LiteLLM ALERTED_BY Alertmanager
```

The model should connect each monitored entity to its dashboards, alerts, and authoritative telemetry source when those entities exist.

## Documentation Relationships

Runbooks, standards, ADRs, and architecture documents must reference the entity IDs they govern.

Examples:

```text
RB-AI-001 DOCUMENTS SVC-AI-001
STD-DOCKER-001 USES_STANDARD relationship for Docker services
ADR-0001 DOCUMENTS HOST-001 reference-host decision
```

The relationship direction should remain semantically clear. A service is `DOCUMENTED_BY` a runbook; a runbook `DOCUMENTS` a service.

## Automation Relationships

Automation must identify what it manages or deploys.

Examples:

```text
ROLE-ANSIBLE-COMMON MANAGES HOST-001
PLAYBOOK-AI DEPLOYS SVC-AI-001
COMPOSE-AI IMPLEMENTS SVC-AI-002
```

This enables impact analysis before changing an Ansible role, playbook, or Compose definition.

## Example AI Platform Graph

```text
ROLE-AI-001 AI Platform
        |
        +-- BELONGS_TO_ROLE <-- HOST-001 schai
        |
        +-- contains SVC-AI-001 Kyri
        +-- contains SVC-AI-002 LiteLLM
        +-- contains SVC-AI-003 Ollama

SVC-AI-001 Kyri
        +-- DEPENDS_ON --> SVC-AI-002 LiteLLM
        +-- MONITORED_BY --> OBS-001 Grafana Alloy
        +-- DOCUMENTED_BY --> RB-AI-001

SVC-AI-002 LiteLLM
        +-- DEPENDS_ON --> SVC-AI-003 Ollama
        +-- RUNS_ON --> HOST-001 schai
        +-- EXPOSED_THROUGH --> NET-APP-001 port 4000

SVC-AI-003 Ollama
        +-- RUNS_ON --> HOST-001 schai
        +-- STORES_DATA_ON --> STORE-AI-001 model volume
        +-- CONNECTS_TO --> GPU-001 Tesla P4
```

## Impact Analysis

Before a disruptive change, operators should be able to answer:

- What directly depends on this entity?
- What indirectly depends on it?
- Which Tier 0 or Tier 1 systems are affected?
- Which runbooks apply?
- Which dashboards and alerts validate recovery?
- Which backups protect the affected state?
- What is the correct shutdown and startup order?

Kyri should eventually traverse both outbound and inbound relationships to produce this analysis.

## Validation

Dependency records must be validated for:

- Unique dependency IDs
- Valid source and target entity IDs
- Approved relationship vocabulary
- No self-dependencies unless explicitly justified
- No duplicate active relationships
- Required fields present
- Valid lifecycle values
- Valid dependency classes and impacts
- Valid recovery order
- No circular hard dependencies unless documented and tested

## Circular Dependencies

Hard circular dependencies are prohibited by default.

When one cannot be avoided, the record must document:

- Why the cycle exists
- Startup behavior
- Recovery order
- Failure behavior
- Manual break-glass procedure

## Security

Dependency records must not contain:

- Passwords
- API keys
- Private keys
- Secret values
- Unredacted credentials

They may reference an approved secret identifier or secrets-management path without including the secret itself.

## Change Management

A change to a host, service, network, storage target, backup policy, or automation component must include a dependency review.

The review should determine whether related records, runbooks, dashboards, firewall rules, backup policies, and recovery procedures must also change.

## Kyri Consumption

Kyri should use dependency data to answer questions such as:

- What breaks if `schai` is offline?
- Which services depend on Ollama?
- Can LiteLLM be restarted safely?
- What is the recovery order for the AI Platform?
- Which dashboards validate this service?
- Which automation manages this host?

Kyri must distinguish recorded facts from inferred relationships. Inferences should be labeled and should not silently become authoritative dependency records.

## Compliance

An entity complies with this standard when:

- Its hard and operational dependencies are explicitly recorded.
- Relationships use stable entity IDs.
- Required fields are complete.
- Runtime, storage, network, monitoring, backup, recovery, documentation, and automation dependencies are represented where applicable.
- Validation methods and recovery order are documented.
- No secrets are stored in dependency records.
- Changes trigger dependency review.

## Exceptions

Exceptions must identify:

- The affected entities
- The missing or nonstandard dependency relationship
- The reason
- The operational risk
- The compensating control
- The owner
- The review or expiration date
