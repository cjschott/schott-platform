# Platform Filesystem and Observability Standard

## Purpose

This standard defines where Schott Platform services, configuration, persistent data, backups, logs, and operational metadata must live. It also defines the common telemetry model used to support centralized logging, Prometheus, Loki, Tempo, and Grafana.

The primary operational objective is simple: an administrator must be able to determine where a service is installed, where its data is stored, and where its logs can be found without searching the entire host.

## Scope

This standard applies to supported Linux hosts and services managed as part of the Schott Platform, including:

- Infrastructure services
- Docker Compose projects
- Web applications
- AI services
- Management services
- Monitoring and observability components

## Design Principles

- Use predictable locations across all hosts.
- Separate application definitions from mutable data.
- Keep secrets outside version control.
- Make every service observable by default.
- Prefer structured telemetry over unstructured text.
- Collect telemetry centrally without making the central platform the only recovery path.
- Document every exception.

## Canonical Filesystem Layout

```text
/
├── opt/
│   └── schott-platform/
│       ├── infrastructure/
│       ├── services/
│       └── tools/
├── etc/
│   └── schott-platform/
├── srv/
│   └── schott-platform/
│       ├── backups/
│       ├── data/
│       └── staging/
├── var/
│   ├── lib/
│   │   └── schott-platform/
│   └── log/
│       └── schott-platform/
```

## Directory Responsibilities

### `/opt/schott-platform/infrastructure`

Contains infrastructure definitions and operator-managed assets, including:

- Ansible content
- Docker Compose projects for shared infrastructure
- Bootstrap scripts
- Templates
- Operational scripts

### `/opt/schott-platform/services`

Contains service definitions grouped by service name.

Examples:

```text
/opt/schott-platform/services/kyri
/opt/schott-platform/services/litellm
/opt/schott-platform/services/ollama
/opt/schott-platform/services/studyforge
```

Each service directory should use the following layout when applicable:

```text
service-name/
├── compose.yaml
├── README.md
├── config/
├── scripts/
└── env/
```

Live secrets must not be committed. A tracked `.env.example` may document required variables, while the live environment file must be stored with restrictive permissions or supplied through an approved secrets mechanism.

### `/opt/schott-platform/tools`

Contains platform utilities that are not standalone services, such as validation tools, migration helpers, and administrative command wrappers.

### `/etc/schott-platform`

Contains host-level platform configuration that is not owned directly by an operating-system package.

Examples include:

- Host identity metadata
- Collector configuration
- Platform defaults
- Service policy fragments

### `/srv/schott-platform/data`

Contains service-owned persistent data when that data should be directly visible on the host.

Recommended structure:

```text
/srv/schott-platform/data/<service-name>/
```

Database files, uploaded content, model data, and other mutable state must not be stored beside Compose definitions unless an approved exception is documented.

### `/srv/schott-platform/backups`

Contains local backup staging data and service-native backup exports.

Recommended structure:

```text
/srv/schott-platform/backups/<service-name>/
```

This location is not itself a complete backup strategy. Each service must document how data is transferred to the approved backup platform and how it is restored.

### `/srv/schott-platform/staging`

Contains temporary import, export, migration, and restore-validation data. Content in this directory must be treated as temporary and must not become an undocumented production dependency.

### `/var/lib/schott-platform`

Contains platform runtime state that is not user-managed service data.

Examples include:

- Collector checkpoints
- Generated inventories
- Local caches
- Runtime metadata

### `/var/log/schott-platform`

Contains file-based application logs written directly by Schott Platform services.

Recommended structure:

```text
/var/log/schott-platform/<service-name>/
```

A service is not required to duplicate logs here when it logs exclusively to `journald`, Docker, or another approved source. Its README must identify the authoritative log source and the command used to retrieve it.

## Naming Standard

- Directory and service names must use lowercase characters.
- Multiword names must use hyphens.
- Names must describe the service rather than the underlying product when practical.
- Spaces and inconsistent abbreviations must not be used.

Examples:

```text
ai-router
jenn-platform
studyforge
kyri
```

## Service Documentation Requirement

Every managed service must include a `README.md` that identifies:

- Service purpose
- Owning host or host role
- Start, stop, and restart commands
- Configuration location
- Persistent data location
- Backup location and restore procedure
- Authoritative log source
- Log retrieval command
- Health-check method
- Exposed ports and exposure classification

The README must answer the operational question: **Where are the logs?**

## Observability Architecture

The standard observability pipeline is:

```text
Applications and Hosts
        |
        +--> Logs ------> Grafana Alloy ------> Loki
        |
        +--> Metrics -------------------------> Prometheus
        |
        +--> Traces ----> OTLP ----------------> Tempo
                                             |
                                             v
                                           Grafana
```

Grafana is the visualization and investigation layer. Loki, Prometheus, and Tempo retain and query the corresponding telemetry types.

## Centralized Logging

Grafana Alloy is the preferred collection agent for Schott Platform hosts unless a later architecture decision selects another collector.

The collector should gather approved sources such as:

- `journald`
- Docker container logs
- `/var/log/schott-platform/*`
- Selected operating-system logs
- Reverse-proxy and access logs

Central collection must not prevent local troubleshooting. Recent logs should remain accessible through the original local source when practical.

## Structured Logging

Applications developed or controlled by the Schott Platform should emit structured JSON logs where practical.

Recommended fields include:

```json
{
  "timestamp": "2026-07-28T12:00:00-05:00",
  "level": "INFO",
  "service": "kyri",
  "component": "router",
  "event": "request_completed",
  "message": "Request completed successfully",
  "request_id": "example-request-id"
}
```

Logs must not contain passwords, API keys, access tokens, private keys, session secrets, or unnecessary sensitive user data.

## Standard Telemetry Labels

The following labels or resource attributes should be used consistently where supported:

- `service`
- `host`
- `environment`
- `role`
- `project`
- `version`

High-cardinality values such as request IDs, user IDs, filenames, and full URLs must not be used as Loki labels. They may remain fields within the log body.

## Metrics

Metrics should be exposed through documented scrape endpoints or approved exporters rather than written as files to a shared metrics directory.

Initial platform exporters may include:

- Node Exporter for host metrics
- cAdvisor or an approved equivalent for container metrics
- Application-native Prometheus endpoints

Every metrics endpoint must have a documented owner, network exposure classification, and scrape path.

## Traces

Applications that support distributed tracing should use OpenTelemetry and export through OTLP to the approved collector or Tempo endpoint.

Trace adoption may be incremental, but new platform applications should propagate correlation identifiers so logs and traces can be connected later.

## Correlation

Where practical, applications should include a common correlation or request identifier in logs and traces. Reverse proxies and downstream services should preserve it.

This enables an operator to move from a Grafana dashboard to the related logs and traces during troubleshooting.

## Retention

Retention must be based on available capacity, operational value, and data sensitivity.

Until service-specific retention policies are approved:

- Preserve enough local logs for immediate troubleshooting.
- Use bounded Docker and system log rotation.
- Configure centralized retention explicitly rather than relying on unlimited growth.
- Retain security-relevant events longer than routine debug logs when capacity permits.

Exact retention periods will be defined when the centralized observability stack is implemented and storage capacity is measured.

## Permissions

- Service configuration and data must be owned by the least-privileged account that requires access.
- Secret-bearing files must use restrictive permissions.
- Log directories must not be broadly writable.
- Collector access must be read-only wherever practical.
- Containers should not run as root unless required and documented.

## Backup and Recovery

Each stateful service must define:

- What data is backed up
- Where backups are staged
- How backups leave the host
- Retention ownership
- Restore commands
- Restore-validation procedure

Logs and metrics are operational data and should not be treated as the sole source of business or configuration state.

## Automation

Ansible should create and manage the required directory structure, ownership, permissions, collector configuration, and log-rotation policy.

Automation must be idempotent and must not remove unknown data without an explicit migration or cleanup action.

## Compliance

A service complies with this standard when:

- Its definitions, configuration, data, and logs use approved locations.
- Its README documents the authoritative log source and retrieval command.
- Persistent data is separated from application definitions.
- Secrets are not stored in Git.
- Logs are bounded by rotation or retention controls.
- Supported telemetry includes the standard identifying labels.
- Sensitive information is excluded from logs.
- Backup and restore locations are documented.
- Any deviation has a documented exception.

## Exceptions

Exceptions must identify:

- The affected host or service
- The requirement being waived
- The reason
- The operational or security risk
- The compensating control
- The owner
- The review or expiration date
