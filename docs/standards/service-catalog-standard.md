# Service Catalog Standard

## Purpose

This standard defines the authoritative record required for every long-lived service in the Schott Platform.

The service catalog gives humans, automation, monitoring, backup systems, and Kyri a shared source of truth for what a service is, where it runs, what it depends on, how it is operated, and what happens when it fails.

## Scope

This standard applies to:

- Platform services
- Application services
- Databases
- Reverse proxies
- Monitoring components
- Backup components
- AI services
- Long-lived Docker Compose projects
- Long-lived system services

Temporary development tools and one-time maintenance jobs are excluded unless they become operational dependencies.

## Core Principle

Every long-lived service must have one canonical catalog record.

The catalog record is the authoritative operational identity of the service. Supporting documentation may add detail, but it must not contradict the catalog.

## Canonical Location

Machine-readable service records must be stored under:

```text
platform-model/services/
```

One file must represent one service.

Example:

```text
platform-model/services/kyri.yaml
platform-model/services/litellm.yaml
platform-model/services/ollama.yaml
```

Human-readable service documentation should be stored under:

```text
docs/services/
```

## Naming

Service record filenames must:

- Use lowercase letters
- Use hyphens between words
- Match the canonical service slug
- End in `.yaml`

Example:

```text
litellm.yaml
proxmox-backup-server.yaml
jenn-booking-api.yaml
```

## Required Service Identity

Each service record must include:

- Stable service ID
- Canonical name
- Slug
- Description
- Service type
- Lifecycle state
- Version or release channel where applicable

Stable IDs must not change when a service is renamed or moved.

Recommended ID format:

```text
SVC-0001
```

## Required Classification

Each service record must include:

- Primary platform role
- Criticality tier
- Environment
- Data classification
- Exposure classification
- Backup classification
- Monitoring classification

These values must align with existing platform standards.

## Required Ownership

Each service record must include:

- Owner
- Technical maintainer
- Repository
- Documentation path
- Runbook path

The owner is accountable for the service outcome. The technical maintainer is responsible for implementation and operation. These may be the same person.

## Required Deployment Information

Each service record must include:

- Deployment method
- Host or host group
- Service directory
- Configuration location
- Persistent data location
- Compose project or systemd unit where applicable
- Image or package source
- Current deployment state

A service must not rely on an undocumented deployment location.

## Required Network Information

Each service record must include:

- Exposure classification
- Listening ports
- Published ports
- Required networks
- Approved callers
- Reverse proxy relationship where applicable
- TLS responsibility

Backend-only services must not be described as LAN-facing or public.

## Required Dependency Information

Dependencies must be explicit.

Each service record must identify:

- Services it requires
- Infrastructure it requires
- Services that require it, when known
- Optional dependencies
- Startup ordering constraints
- Failure behavior when a dependency is unavailable

Dependencies must reference stable entity IDs where available.

## Required Observability Information

Each service record must include:

- Authoritative log source
- Log retrieval command
- Metrics endpoint or exporter
- Health check
- Dashboard references
- Alert references
- Trace support where applicable

Every record must answer:

> Where are the logs?

and:

> How do I know the service is healthy?

## Required Operational Information

Each service record must include:

- Start command
- Stop command
- Restart command
- Validation command
- Update procedure reference
- Rollback procedure reference
- Backup procedure reference
- Restore procedure reference
- Recovery priority
- Maintenance constraints

Commands may reference the runbook instead of duplicating long procedures, but a direct path to the approved procedure is required.

## Required Data Protection Information

For services with persistent state, the catalog must define:

- What data is authoritative
- What data is reconstructable
- Backup scope
- Backup frequency classification
- Restore dependency order
- Recovery point objective where known
- Recovery time objective where known
- Last restore test date when available

A service must not be marked as backed up solely because its host is backed up. The record must identify whether application-consistent recovery is supported.

## Required Security Information

Each service record must include:

- Authentication method
- Authorization model
- Secret source
- Privileged access requirements
- Data sensitivity
- Security exceptions
- Public exposure approval where applicable

Secrets must never be stored directly in the service catalog.

## Lifecycle States

Approved lifecycle values are:

- proposed
- development
- test
- production
- maintenance
- deprecated
- retired

A deprecated service must identify its replacement or retirement plan.

A retired service record should be preserved for historical context but clearly marked as inactive.

## Canonical Schema Example

```yaml
api_version: schott-platform/v1
kind: Service

metadata:
  id: SVC-0001
  name: Kyri
  slug: kyri
  lifecycle: development
  version: 0.1.0

classification:
  platform_role: ROLE-0001
  criticality: tier-1
  environment: production
  data_classification: internal
  exposure: internal
  backup: required
  monitoring: required

ownership:
  owner: Christopher Schott
  maintainer: Christopher Schott
  repository: cjschott/schott-platform
  documentation: docs/services/kyri.md
  runbook: docs/runbooks/kyri.md

deployment:
  method: docker-compose
  host_group: ai-platform
  service_directory: /opt/schott-platform/services/kyri
  compose_project: kyri
  configuration: /etc/schott-platform/kyri
  persistent_data: /srv/schott-platform/data/kyri

network:
  exposure: internal
  networks:
    - backend
    - monitoring
  listening_ports:
    - 8000
  published_ports: []
  tls_termination: reverse-proxy

dependencies:
  requires:
    - SVC-0002
    - SVC-0003
  optional: []
  failure_mode: degraded

observability:
  authoritative_logs: docker
  log_command: docker compose logs --tail=200 kyri
  health_check: http://kyri:8000/health
  metrics_endpoint: http://kyri:8000/metrics
  dashboards:
    - DASH-0001
  alerts:
    - ALERT-0001

operations:
  start: docker compose up -d
  stop: docker compose down
  restart: docker compose restart
  validate: curl --fail http://localhost:8000/health
  backup_runbook: RB-0001
  restore_runbook: RB-0002
  update_runbook: RB-0003
  rollback_runbook: RB-0004
  recovery_priority: 2

security:
  authentication: required
  authorization: role-based
  secret_source: ansible-vault
  privileged: false
  exceptions: []
```

## Validation Requirements

Catalog records must be validated for:

- Valid YAML
- Required fields
- Unique stable IDs
- Unique service slugs
- Valid lifecycle values
- Valid criticality values
- Valid platform role references
- Existing documentation references
- Existing runbook references where required
- Valid dependency references
- No embedded secrets

Validation should run locally and in CI.

## Change Control

Service catalog changes must be reviewed when they alter:

- Criticality
- Exposure
- Dependencies
- Backup classification
- Data classification
- Ownership
- Deployment host
- Retirement state

Moving a service between hosts does not create a new service ID.

Replacing a service with a functionally different system should create a new service ID and link the old service as deprecated or retired.

## Relationship to Automation

The service catalog should progressively drive:

- Ansible inventory and variables
- Docker deployment configuration
- Monitoring target generation
- Dashboard links
- Backup policy assignment
- Firewall validation
- Kyri operational reasoning

Automation may consume the catalog, but automation must not silently rewrite authoritative catalog records.

## Relationship to Documentation

The service catalog stores concise operational facts.

Detailed explanations belong in:

- Service documentation
- Runbooks
- Architecture decision records
- Standards

The catalog must link to those documents instead of duplicating them.

## Initial Adoption

Initial records should be created for:

- Kyri
- LiteLLM
- Ollama
- Grafana
- Prometheus
- Loki
- Tempo
- Grafana Alloy
- Proxmox Backup Server
- Caddy
- StudyForge
- Jenn Experience
- Plex
- Jellyfin

Records may begin incomplete during discovery, but missing values must be explicit and tracked. Placeholder text must not be treated as an approved operational fact.

## Compliance

A production service is non-compliant when:

- It has no catalog record
- Its deployment location is undocumented
- Its owner is unknown
- Its logs cannot be located
- Its health cannot be validated
- Its dependencies are undocumented
- Its backup or restore requirements are unknown
- Its exposure differs from the catalog

Compliance findings should be remediated through documentation, configuration correction, or an approved exception.
