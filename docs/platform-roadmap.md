# Schott Platform Roadmap

## Vision

Build a secure, reproducible, automation-first homelab platform that is operated with the same engineering discipline as an enterprise production environment.

Guiding principles:

- Manual once. Automated forever.
- Security by default.
- Infrastructure as Code.
- Design before implementation.
- Validate before rollout.
- Document every significant architectural decision.

## Release Roadmap

### v0.2.x — Foundation

Objective: Establish architecture, governance, and engineering standards.

Completed / Planned:

- Platform architecture
- Linux security baseline
- Service exposure standard
- Architecture Decision Records
- Platform roadmap
- Network policy alignment
- Static validation improvements
- Initial release documentation

### v0.3.x — Automation

Objective: Convert validated manual configuration into reusable automation.

Planned:

- Core Ansible roles
- Host bootstrap
- Firewall automation
- Docker deployment automation
- Compliance validation playbooks
- Standard inventory structure
- Automated configuration drift detection

### v0.4.x — Observability

Objective: Provide complete visibility into platform health.

Planned:

- Prometheus
- Grafana dashboards
- Loki log aggregation
- Alertmanager
- Node Exporter
- Container monitoring
- Backup monitoring

### v0.5.x — Platform Services

Objective: Standardize shared platform capabilities.

Planned:

- Identity integration
- Secrets management
- Reverse proxy improvements
- Internal APIs
- Service catalog
- Documentation portal

### v0.6.x — Kyri Platform

Objective: Make Kyri the operational intelligence layer.

Planned:

- Infrastructure knowledge indexing
- Documentation-aware assistance
- Natural language operations
- Change guidance
- Operational runbook assistance
- Platform health summaries

### v1.0

Objectives:

- Fully reproducible infrastructure
- One-command platform deployment
- Continuous compliance validation
- Fully documented architecture
- Stable automation pipeline
- Production-quality operational standards

## Engineering Workflow

Every significant change follows:

1. Brainstorm
2. Design
3. Review
4. Approval
5. Manual implementation on schai
6. Validation
7. Documentation
8. Automation
9. Broad deployment

## Success Criteria

The platform is considered mature when:

- Manual configuration is the exception rather than the norm.
- Infrastructure can be rebuilt from source-controlled automation.
- Security standards are continuously validated.
- Documentation accurately reflects deployed infrastructure.
- Operational knowledge is preserved through standards, ADRs, and automation.
