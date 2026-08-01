# Docker Platform Standard

## Purpose

This standard defines how Docker and Docker Compose workloads are structured, secured, operated, monitored, backed up, and updated across the Schott Platform.

The goal is to make every containerized service predictable to deploy, inspect, recover, and automate.

## Scope

This standard applies to:

- Long-running Docker services
- Docker Compose application stacks
- Supporting databases, workers, and scheduled containers
- Development or test stacks promoted into managed platform use

## Core Principles

1. One Compose project represents one independently operated service or application stack.
2. Configuration, persistent data, secrets, and logs must have clear ownership and locations.
3. Services must expose only the network paths they require.
4. Container deployments must be reproducible and recoverable.
5. Operational commands must be documented before a service is considered managed.
6. Automatic updates are disabled unless a controlled update policy explicitly permits them.

## Canonical Service Location

Each managed Compose project must live under:

```text
/opt/schott-platform/services/<service-name>/
```

The canonical layout is:

```text
<service-name>/
├── compose.yaml
├── README.md
├── config/
├── scripts/
└── env/
```

Persistent application data must live under:

```text
/srv/schott-platform/data/<service-name>/
```

Backup staging, when required, must live under:

```text
/srv/schott-platform/backups/<service-name>/
```

Runtime state that is not application data may live under:

```text
/var/lib/schott-platform/<service-name>/
```

## Naming Standard

Service, project, container, network, and volume names must:

- Use lowercase characters
- Use hyphens as separators
- Avoid spaces and underscores unless required by an upstream application
- Describe the workload rather than the host

The Compose project name should match the service directory name.

Hostnames must not be embedded in container names unless the workload is intentionally host-specific.

## Compose File Standard

The standard Compose filename is:

```text
compose.yaml
```

A managed stack must be operable with commands equivalent to:

```bash
docker compose up -d
docker compose down
docker compose ps
docker compose logs
```

Compose files must be valid under the Docker Compose specification supported by the managed Docker version.

Deprecated Compose syntax must not be introduced into new services.

## Image Versioning

The `latest` tag is prohibited for managed workloads.

Images must use one of the following:

- A specific release tag
- A version-constrained release tag approved for that service
- A digest pin for workloads requiring stronger reproducibility

Tier 0 and Tier 1 workloads should use digest pinning when practical after the update process has been validated.

A service README must record the update source and expected versioning strategy.

## Build Policy

Locally built images must:

- Use a documented Dockerfile
- Use a minimal and maintained base image
- Avoid embedding secrets
- Pin important runtime dependencies where practical
- Include build and rollback instructions
- Be tagged with an application version or commit identifier

Production images must not depend on uncommitted local files.

## Environment and Secrets

Live secrets must never be committed to Git.

Permitted secret sources include:

- Docker secrets where supported
- Root-owned environment files outside the repository
- A future approved secrets-management system

Example or template files may be committed as:

```text
.env.example
```

A committed template must contain placeholder values only.

Environment files containing secrets must:

- Be excluded by `.gitignore`
- Have restrictive filesystem permissions
- Be backed up securely if required for recovery
- Be documented in the service README

## Volume and Data Policy

Persistent data must use explicit bind mounts or named volumes with documented ownership.

Bind mounts are preferred when they improve backup visibility and operational clarity.

Every persistent mount must be classified as one of:

- Configuration
- Application data
- Database data
- Cache
- Temporary data
- Backup staging

Caches and temporary data should not be included in backups unless recovery requires them.

Database files must not be copied while active unless the database vendor explicitly supports that method. Application-aware backup methods are required where applicable.

## Network Classes

Managed Compose stacks use explicit networks. Reliance on an unnamed implicit default network is discouraged.

The standard network classes are:

### edge

Purpose:

- Connect an approved reverse proxy to frontend services
- Carry client-facing application traffic

Only services that must receive proxied requests may join this network.

### backend

Purpose:

- Carry private application-to-application traffic
- Connect frontends, APIs, databases, queues, and internal dependencies

Backend services must not publish ports to the host unless an approved operational requirement exists.

### monitoring

Purpose:

- Allow approved observability collectors to reach metrics or telemetry endpoints
- Connect scrape targets and collection agents

Joining the monitoring network does not authorize public or general LAN access.

### Network Requirements

- A service joins only the networks it requires.
- Database and queue services normally join only `backend`.
- Public applications should be reached through the approved reverse proxy.
- Private services should not publish host ports when container networking is sufficient.
- Host-network mode requires a documented exception.
- Privileged containers require a documented exception.

## Port Exposure

Published ports must be explicitly documented.

Each published port must identify:

- Protocol
- Purpose
- Intended source network
- Whether authentication is required
- Firewall dependency

Public exposure must follow the Service Exposure Standard.

Administrative interfaces must not be exposed publicly.

Binding to `127.0.0.1` or a management address is preferred when LAN-wide access is unnecessary.

## Restart Policies

Restart policy must match workload behavior.

### `unless-stopped`

Use for long-running platform and application services that should return after a host restart.

### `on-failure`

Use for workers or jobs that should retry after an error but should not restart after successful completion.

### `no`

Use for migrations, maintenance tasks, initialization jobs, and intentional one-time workloads.

`always` should be avoided unless its behavior is specifically required and documented.

## Health Checks

Every service that supports a meaningful health check must define one.

Health checks should test application readiness rather than only process existence.

Health-check configuration should include:

- Command or endpoint
- Interval
- Timeout
- Retry count
- Start period when required

Dependencies should use health conditions where supported rather than fixed sleep delays.

A missing health check must be explained in the service README.

## Resource Management

Resource limits or reservations should be defined when a workload could threaten host stability or compete with critical services.

Resource planning should consider:

- CPU
- Memory
- GPU access
- Disk capacity
- Disk I/O
- Network bandwidth
- Process count

Tier 0 and Tier 1 services must not depend on uncontrolled resource growth.

## Security Requirements

Managed containers must:

- Run as a non-root user when supported
- Avoid privileged mode
- Avoid mounting the Docker socket unless explicitly approved
- Use read-only filesystems when practical
- Drop unneeded Linux capabilities
- Add only required capabilities
- Avoid broad host filesystem mounts
- Use maintained images from trusted sources
- Separate public and private traffic

Access to `/var/run/docker.sock` is considered administrative access to the Docker host and must be treated as a high-risk exception.

## Logging

Each service must identify its authoritative log source.

Approved sources include:

- Docker standard output and standard error
- journald
- Application files under `/var/log/schott-platform/<service-name>/`
- A documented upstream logging destination

The default Docker JSON log driver must use bounded rotation unless another approved driver is configured.

A baseline example is:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```

Values may be adjusted based on service volume and retention requirements.

Logs must not contain passwords, tokens, session secrets, private keys, or unnecessary personal data.

## Observability Labels

Managed services should include standard metadata where supported:

- `service`
- `host`
- `environment`
- `role`
- `project`
- `version`

Metrics endpoints should be reachable only from approved collectors or management networks.

High-cardinality values must not be used as persistent log labels.

## Backups

Every stateful stack must document:

- What data is authoritative
- What data is included in backups
- What data may be recreated
- Backup method
- Backup destination
- Backup frequency
- Restore procedure
- Validation procedure

A VM or host backup alone does not replace application-aware backup requirements for databases or other consistency-sensitive systems.

Backups are not considered valid until a restore process has been documented and tested at an appropriate frequency.

## Updates

Automatic container updates are disabled by default.

A controlled update must include:

1. Review of release notes or upstream changes
2. Verification of available backups
3. Recording of the current image version or digest
4. Pulling the approved replacement image
5. Recreating the affected service
6. Health and functional validation
7. Log review
8. Rollback if validation fails

Updates should be performed with commands equivalent to:

```bash
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=200
```

## Rollback

Each service must have a defined rollback method.

At minimum, rollback must identify:

- Previous image tag or digest
- Configuration rollback source
- Database compatibility risk
- Data restore requirement
- Validation steps

A container image rollback must not be assumed safe after an irreversible database migration.

## Service Documentation

Every managed service must include a README that documents:

- Purpose
- Owner
- Platform role
- Criticality tier
- Start command
- Stop command
- Restart command
- Status command
- Authoritative log source
- Log retrieval command
- Health check
- Published ports
- Networks
- Configuration location
- Secret location
- Persistent data location
- Backup method
- Restore method
- Update method
- Rollback method
- Known dependencies

The README must allow an operator to answer:

- Where are the logs?
- How do I restart it?
- How do I verify health?
- What is exposed?
- Where is the data?
- How do I back it up?
- How do I restore it?
- How do I update it?
- How do I roll it back?

## Automation Requirements

Future Ansible automation should manage:

- Docker installation and configuration
- Compose plugin installation
- Service directories
- Permissions
- Network creation where required
- Environment-file placement
- Compose deployment
- Log rotation
- Health validation
- Backup integration

Automation must not conceal undocumented manual steps.

The reference service should be deployed manually once, documented, validated, and then converted into idempotent automation.

## Exceptions

Exceptions require documentation that includes:

- Requirement
- Risk
- Scope
- Compensating control
- Owner
- Review date

Undocumented exceptions are platform drift.

## Compliance Checklist

A managed Docker service is compliant when:

- It has one canonical service directory
- It uses `compose.yaml`
- It does not use `latest`
- Persistent data is explicit and documented
- Secrets are excluded from Git
- Networks are explicit and least-privileged
- Published ports are justified
- Health checks are defined where possible
- Logs are bounded and retrievable
- Backup and restore procedures exist
- Update and rollback procedures exist
- The service README satisfies the operational documentation requirements
