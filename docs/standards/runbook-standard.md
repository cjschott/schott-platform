# Platform Runbook Standard

## Purpose

This standard defines the required structure, content, ownership, validation, and lifecycle for Schott Platform runbooks.

A runbook is the approved operational procedure for performing a repeatable task safely. It must be usable by a human operator, consumable by Kyri, and precise enough to support automation later.

## Scope

This standard applies to runbooks for:

- Platform roles
- Hosts
- Services
- Applications
- Backups and restores
- Deployments and upgrades
- Security and network changes
- Incident response
- Recovery and decommissioning

## Core Principles

- One runbook must address one operational objective.
- Procedures must be explicit, ordered, and testable.
- Commands must be safe to copy and paste after required placeholders are replaced.
- Preconditions, validation, rollback, and failure handling are mandatory.
- Runbooks must reference stable platform identifiers where available.
- Secrets and live credentials must never appear in runbooks.
- Manual procedures should become automation only after they are proven on the reference implementation.

## Canonical Location

Human-readable runbooks must be stored under:

```text
docs/runbooks/
```

Recommended structure:

```text
docs/runbooks/
├── platform/
├── hosts/
├── services/
├── backup/
├── security/
├── incidents/
└── recovery/
```

Machine-readable runbook metadata should be stored under:

```text
platform-model/runbooks/
```

## Runbook Identifier

Every runbook must have a stable identifier.

Format:

```text
RB-<DOMAIN>-<NUMBER>
```

Examples:

```text
RB-AI-001
RB-NET-001
RB-BACKUP-001
RB-SEC-001
```

The identifier must remain stable even if the runbook title or filename changes.

## Required Front Matter

Each runbook must begin with metadata equivalent to:

```yaml
---
id: RB-AI-001
title: Restart the AI Platform
status: approved
owner: platform-engineering
version: 1.0.0
last_reviewed: 2026-08-01
review_interval_days: 180
applies_to:
  roles:
    - ROLE-AI-PLATFORM
  hosts:
    - HOST-SCHAI
  services:
    - SVC-LITELLM
    - SVC-OLLAMA
risk: medium
requires_approval: false
---
```

Required metadata fields:

- `id`
- `title`
- `status`
- `owner`
- `version`
- `last_reviewed`
- `review_interval_days`
- `applies_to`
- `risk`
- `requires_approval`

## Lifecycle States

Allowed runbook states:

- `draft`
- `review`
- `approved`
- `deprecated`
- `retired`

Only approved runbooks may be treated as authoritative operational procedures.

## Required Sections

Each approved runbook must contain the following sections.

### 1. Purpose

Explain the operational objective and when the runbook should be used.

### 2. Scope

Identify the applicable hosts, roles, services, environments, and exclusions.

### 3. Risk and Impact

Describe:

- Expected service impact
- Potential failure modes
- Security implications
- Data-loss risk
- Estimated interruption window

### 4. Prerequisites

List all required conditions before execution, including:

- Access level
- Backup state
- Maintenance window
- Console or recovery access
- Required tools
- Available disk capacity
- Existing service health
- Required approvals

### 5. Inputs and Placeholders

Define every variable or placeholder used by the procedure.

Example:

| Placeholder | Description | Example |
|---|---|---|
| `<host>` | Target host | `schai` |
| `<service>` | Compose service name | `litellm` |
| `<backup-path>` | Verified backup location | `/srv/schott-platform/backups/litellm` |

A command must not contain an unexplained placeholder.

### 6. Pre-change Validation

Record the commands and expected results used to establish a known-good starting state.

Examples:

- Service health
- Current configuration
- Listening ports
- Disk usage
- Backup verification
- Current image or package version

### 7. Procedure

Provide numbered, ordered steps.

Each step should include:

- The exact command or action
- Where it must be run
- Expected output or state
- A stop condition when the result is unexpected

Destructive commands must include a warning immediately before the command.

### 8. Validation

Define how success is proven.

Validation must cover:

- Service health
- Functional behavior
- Security behavior
- Network reachability where applicable
- Log review
- Dependency health
- Persistence after restart or reboot when relevant

### 9. Rollback

Provide an explicit rollback procedure, including:

- Trigger conditions
- Commands
- Configuration or artifact to restore
- Validation after rollback
- Conditions requiring escalation instead of continued attempts

A runbook without a viable rollback must clearly state why and identify the alternative recovery path.

### 10. Troubleshooting

Document common failures, diagnostic commands, authoritative log sources, and safe remediation actions.

Every runbook must answer:

> Where are the logs for this procedure or service?

### 11. Escalation

Identify when the operator must stop and escalate.

Examples:

- Backup cannot be verified
- Configuration validation fails
- Unexpected data loss is detected
- Required dependency is unavailable
- Rollback does not restore service
- Security controls cannot be maintained

### 12. References

Link to related:

- Service catalog records
- Standards
- ADRs
- Architecture documents
- Dashboards
- Repositories
- Vendor documentation
- Other runbooks

## Command Safety

Commands must follow these rules:

- Use fully qualified or unambiguous paths when location matters.
- Use `sudo` only where privilege is required.
- Avoid wildcard deletion.
- Never use `rm -rf` without an immediately preceding warning, exact target, and recovery context.
- Avoid commands that expose secrets through shell history, process arguments, or output.
- Validate configuration before reloading or restarting a service.
- Add replacement firewall or access rules before deleting existing access.
- Prefer read-only inspection before mutation.
- Require operator confirmation before irreversible actions.

## Expected Results

Runbooks must distinguish commands from expected output.

Example:

```bash
sudo sshd -t
```

Expected:

```text
No output and exit status 0.
```

Operators must not be expected to infer whether output is healthy.

## Observability Integration

Each runbook should identify relevant:

- Log source and retrieval command
- Metrics
- Dashboard
- Alerts that may fire
- Correlation or request identifiers

Runbooks should use the telemetry labels defined by the Platform Filesystem and Observability Standard.

## Service Catalog Integration

A service catalog record must reference its applicable runbooks by stable runbook ID.

A runbook must reference applicable services by stable service ID where those IDs exist.

Examples:

```yaml
runbooks:
  operations: RB-AI-001
  backup: RB-AI-002
  recovery: RB-AI-003
```

## Machine-Readable Metadata

The canonical machine-readable runbook record should include:

```yaml
schema_version: 1
runbook:
  id: RB-AI-001
  title: Restart the AI Platform
  status: approved
  version: 1.0.0
  owner: platform-engineering
  document: docs/runbooks/services/restart-ai-platform.md
  applies_to:
    roles:
      - ROLE-AI-PLATFORM
    hosts:
      - HOST-SCHAI
    services:
      - SVC-LITELLM
      - SVC-OLLAMA
  risk: medium
  requires_approval: false
  prerequisites:
    - docker
    - compose-v2
    - validated-ai-env
  related:
    standards:
      - STD-DOCKER-PLATFORM
    dashboards:
      - DASH-AI-OVERVIEW
    runbooks:
      - RB-AI-003
```

The Markdown runbook remains the human-readable procedure. The metadata record supplies stable relationships for validation, automation, and Kyri.

## Review and Testing

Runbooks must be reviewed:

- After a failed or confusing execution
- After a related architecture or configuration change
- After an incident involving the documented procedure
- At the defined review interval

High-risk recovery runbooks must be tested periodically in a safe environment or through a controlled tabletop exercise.

A test record should include:

- Date
- Operator
- Environment
- Outcome
- Deviations
- Follow-up actions

## Versioning

Runbooks use semantic-style document versions:

- Major: procedure or risk model changes materially
- Minor: new validated steps or expanded coverage
- Patch: corrections that do not change operational meaning

Repository history does not replace the version field because Kyri and the platform model need an explicit current version.

## Compliance

A runbook complies with this standard when:

- It has a stable ID and required metadata.
- It has one clearly defined operational objective.
- Required sections are present.
- Commands identify execution context and expected results.
- Preconditions and stop conditions are explicit.
- Validation and rollback are complete.
- Authoritative log sources are documented.
- Related services and platform objects use stable IDs.
- No secrets or live credentials are present.
- Links and referenced identifiers resolve.
- Review status and version are current.

## CI Validation

Repository validation should eventually verify:

- Required front matter fields
- Unique runbook IDs
- Allowed lifecycle states
- Required sections
- Valid relative links
- Resolvable service and host IDs
- No secret patterns
- No unexplained placeholders
- Catalog-to-runbook relationship integrity

## Exceptions

Exceptions must identify:

- Runbook ID
- Requirement being waived
- Reason
- Risk
- Compensating control
- Owner
- Review or expiration date
