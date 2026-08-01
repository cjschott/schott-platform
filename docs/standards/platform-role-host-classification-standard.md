# Platform Role and Host Classification Standard

## Purpose

This standard defines how Schott Platform hosts are classified by role, criticality, lifecycle responsibility, and operational expectations.

The goal is to prevent role drift, make automation targetable, and ensure every host has a clear reason to exist.

## Scope

This standard applies to:

- Physical hosts
- Virtual machines
- Containers that function as long-lived infrastructure hosts
- Future cloud-hosted platform nodes

## Core Principle

Every host must have one primary platform role.

A host may support secondary functions, but those functions must not undermine the primary role or create an undocumented dependency.

Automation, monitoring, backup, firewall policy, and documentation should target platform roles wherever practical rather than individual hostnames.

## Platform Roles

### AI Platform

**Purpose:** Host artificial intelligence and model-serving workloads.

**Typical responsibilities:**

- Kyri
- LiteLLM
- Ollama
- Embedding services
- Model storage
- GPU-backed inference
- AI routing and provider integration

**Must not host:**

- Unrelated public websites
- Media services
- Download automation
- General-purpose databases unrelated to AI workloads

### Web Platform

**Purpose:** Host public or internal web applications.

**Typical responsibilities:**

- Jenn Experience
- StudyForge
- Future customer-facing applications
- Reverse proxy and application runtime dependencies where approved

**Must not host:**

- Media processing
- Backup infrastructure
- Unrelated management-plane services
- Experimental workloads that threaten production stability

### Management Platform

**Purpose:** Provide administration, automation, and control-plane services.

**Typical responsibilities:**

- Ansible control
- Infrastructure automation
- DNS management
- Administrative dashboards
- Platform tooling
- Configuration validation

**Must not host:**

- Public applications
- Media workloads
- Resource-heavy experiments
- Services that expose the management plane to unnecessary risk

### Monitoring Platform

**Purpose:** Provide centralized observability and alerting.

**Typical responsibilities:**

- Grafana
- Prometheus
- Loki
- Tempo
- Alertmanager
- Grafana Alloy management or related collectors

**Must not host:**

- Unrelated business applications
- High-risk experimental workloads
- Services that compete heavily for storage or memory without approval

### Backup Platform

**Purpose:** Protect platform data and support recovery.

**Typical responsibilities:**

- Proxmox Backup Server
- Backup verification
- Restore testing
- Replication
- Off-site synchronization

**Must not host:**

- General application workloads
- Media services
- Development workloads
- Any service that increases compromise or resource-exhaustion risk without strong justification

### Media Platform

**Purpose:** Host personal media, download, and library-management workloads.

**Typical responsibilities:**

- Plex
- Jellyfin
- Sonarr
- Radarr
- SABnzbd
- qBittorrent
- Media automation

**Must not host:**

- Management-plane services
- Backup infrastructure
- Public business applications
- Security-sensitive platform services

### Development Platform

**Purpose:** Support testing, experimentation, CI, and pre-production validation.

**Typical responsibilities:**

- CI runners
- Sandboxes
- Prototype applications
- Integration testing
- Temporary test databases

**Must not host:**

- Production workloads unless explicitly approved
- Authoritative backup data
- Core DNS or management-plane dependencies

### Compute Platform

**Purpose:** Provide virtualization and container compute capacity.

**Typical responsibilities:**

- Proxmox VE
- Virtual machines
- Containers
- PCI passthrough
- Cluster or standalone compute services

**Must not host directly:**

- Application services that should run inside managed guests
- Ad hoc host-level workloads without documentation

### Storage Platform

**Purpose:** Provide shared or dedicated persistent storage.

**Typical responsibilities:**

- NAS services
- Shared datasets
- Media storage
- Application storage where approved

**Must not host:**

- Unrelated compute-heavy workloads
- Public applications
- Management-plane services without an approved exception

## Host Classification

Each host record must include:

- Hostname
- Primary platform role
- Secondary functions, if any
- Criticality tier
- Environment
- Owner
- Operating system or platform
- Backup classification
- Monitoring requirements
- Recovery priority
- Lifecycle state

## Criticality Tiers

### Tier 0 - Foundational Infrastructure

Loss of the host may affect the operation or recovery of most other systems.

Examples:

- Hypervisors
- Core DNS
- Backup infrastructure
- Core network services

Requirements:

- Highest monitoring priority
- Documented recovery order
- Frequent backup or configuration export
- Tested recovery procedure
- Maintenance planning before disruptive changes

### Tier 1 - Core Platform Services

Loss of the host significantly reduces platform management, observability, or AI capability.

Examples:

- Management platform
- Monitoring platform
- Primary AI platform

Requirements:

- Active monitoring
- Documented backup and recovery
- Defined maintenance process
- High-priority alerting

### Tier 2 - Production Applications

Loss of the host affects one or more applications but does not prevent core infrastructure recovery.

Examples:

- Web applications
- Internal production services

Requirements:

- Service health monitoring
- Application backup
- Recovery documentation
- Reasonable alerting based on business impact

### Tier 3 - Convenience and Noncritical Services

Loss of the host is inconvenient but does not threaten platform administration or recovery.

Examples:

- Media services
- Development sandboxes
- Experimental services

Requirements:

- Basic monitoring
- Best-effort recovery
- Backups where data loss would be costly to recreate

## Environment Classification

Each host must be assigned one environment value:

- `production`
- `management`
- `development`
- `test`
- `lab`

Environment must be represented consistently in inventory, monitoring labels, and documentation.

## Lifecycle States

Each host must be assigned one lifecycle state:

- `planned`
- `provisioning`
- `active`
- `maintenance`
- `degraded`
- `retiring`
- `decommissioned`

A host in `decommissioned` state must not remain in active automation inventory, monitoring, or backup jobs unless required for historical reference.

## Role Operational Profile

Each platform role must define the following:

### Provisioning

- Required operating system or platform
- Required base packages
- Required directory structure
- Required network access
- Required automation roles

### Validation

- Host health checks
- Service health checks
- Network reachability checks
- Security baseline checks

### Monitoring

- Required host metrics
- Required service metrics
- Required logs
- Required alerts

### Patching

- Maintenance expectations
- Reboot requirements
- Validation after patching
- Rollback or recovery path

### Backup

- Configuration backup requirements
- Data backup requirements
- Backup destination
- Restore validation frequency

### Recovery

- Recovery priority
- Dependencies
- Restoration order
- Acceptance criteria

### Decommissioning

- Data retention decision
- Backup removal timing
- Monitoring removal
- DNS removal
- Automation inventory removal
- Secret and credential cleanup

## Initial Host Assignments

The following assignments define the current target state and may be refined as the environment inventory is completed.

| Host | Primary Role | Criticality | Notes |
|---|---|---:|---|
| `schai` | AI Platform | Tier 1 | Reference implementation for AI services |
| `schmgmt` | Management Platform | Tier 1 | Ansible and platform administration |
| `schweb1` | Web Platform | Tier 2 | Application hosting |
| `schweb2` | Web Platform | Tier 2 | StudyForge and supporting web workloads |
| `schdownload` | Media Platform | Tier 3 | Download and media automation |
| `schplex` | Media Platform | Tier 3 | Plex or media-serving workload |
| `schpbs` | Backup Platform | Tier 0 | Proxmox Backup Server and off-site replication |
| `schoxmox1` | Compute Platform | Tier 0 | Primary virtualization host |
| `schoxmox2` | Compute Platform | Tier 0 | Secondary compute and backup host |
| `schcore` | Management Platform | Tier 0 | Core network or DNS support where applicable |

The table is a classification baseline, not a substitute for inventory. Actual services and dependencies must be validated before automation relies on it.

## Role Drift

Role drift occurs when a host begins running services unrelated to its primary platform role.

Before adding a new service to a host, confirm:

1. The service aligns with the host's primary role.
2. Resource demand will not threaten existing responsibilities.
3. Network exposure remains compliant.
4. Backup and monitoring requirements are defined.
5. The host remains understandable as a single-purpose platform component.

If these conditions are not met, deploy the service to a more appropriate host or create a new host role assignment.

## Automation Requirements

Ansible inventory should group hosts by platform role and environment.

Example:

```yaml
all:
  children:
    ai_platform:
      hosts:
        schai:
    management_platform:
      hosts:
        schmgmt:
    web_platform:
      hosts:
        schweb1:
        schweb2:
```

Roles and playbooks should target groups rather than hard-coded hostnames whenever possible.

Host-specific variables are permitted only for settings that are truly unique to a host.

## Observability Requirements

Every host must expose consistent identifying metadata where supported:

- `host`
- `role`
- `criticality`
- `environment`
- `lifecycle_state`

Dashboards and alerts should be organized by role and criticality, not only by hostname.

## Backup and Recovery Requirements

Criticality drives recovery priority.

- Tier 0 systems are restored first.
- Tier 1 systems are restored after foundational infrastructure is operational.
- Tier 2 applications are restored after their dependencies are available.
- Tier 3 services are restored last or rebuilt when practical.

Recovery documentation must identify upstream and downstream dependencies.

## Compliance

A host complies with this standard when:

- It has one documented primary platform role.
- Its criticality tier is documented.
- Its environment and lifecycle state are documented.
- Its workloads align with its role.
- Monitoring, backup, and recovery expectations are defined.
- Automation targets the host through role-based inventory where practical.
- Role drift is absent or documented as an exception.

## Exceptions

Exceptions must identify:

- The host
- The conflicting workload or classification
- The reason
- The risk
- The compensating control
- The owner
- The review or expiration date
