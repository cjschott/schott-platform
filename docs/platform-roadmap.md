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

### Sprint 4 — Evidence and Verification Layer

**Schema and validation foundation only.** This increment defines how observation
enters the model; it collects nothing.

Delivered:

- Entity lifecycle standard separating maturity from provenance and runtime health
- Evidence standard: immutable, timestamped support for observed facts
- Verification and drift standard: read-only comparison with no remediation
- Ontology additions for `evidence`, `verification`, and `drift-rule`
- Machine-readable schemas for all three record kinds
- Initial drift rule definitions
- A repository-only validator enforcing the contract

Explicitly not delivered, and not implied:

- No runtime collection. Nothing contacts a host, and no evidence record exists.
- No automatic remediation, at any severity, under any configuration.
- No operational health reporting. Nothing here can say whether the platform is
  working right now, and the schemas are shaped so nothing can appear to.

Evidence collection is future work. Building the contract first means a collector
cannot invent its own vocabulary later.

### v0.5.0 — Collector Framework and Architecture Decisions

**Schema, contract, and validation only.** Defines what may produce evidence and
under what constraints, without implementing a single live collector.

Delivered:

- ADR-0002 Evidence-First Architecture — the fixed pipeline from collection to
  optional automation, and the twelve principles governing it
- ADR-0003 Provider-Agnostic AI Architecture — stable gateway interface,
  providers as adapters, no silent cloud fallback
- Capability model standard and `CAP-0001`–`CAP-0008`
- Collector plugin standard: five-stage lifecycle, permissions, secret rules
- Collector framework: data models, base interface, registry, normalizer
- A synthetic example plugin that observes nothing
- A collector plugin validator wired into CI

Explicitly not delivered:

- No live collector. The only plugin refuses to run outside a test context.
- No evidence persistence. Collectors return data; the orchestrator decides
  what becomes a record.
- No automatic remediation, at any layer.

### v0.6.0 — Git Repository, Configuration Render, and Manual Attestation Collectors

Reserved. The first real collectors, chosen because none of them needs host
access: repository state, rendered Compose configuration, and operator
attestation can all be gathered from the working tree.

### v0.7.0 — Read-Only SSH Collector

Reserved. First collector requiring host access. Read-only, key-based, scoped
to explicitly approved commands.

### v0.8.0 — Docker and Compose Runtime Collector

Reserved. Container and Compose runtime state on the AI platform host.

### v0.9.0 — Proxmox Collector

Reserved. Virtualization inventory and guest state from the compute platform.

Each collector release must extend the evidence pipeline without weakening the
ADR-0002 guarantees. Collection order is deliberate: the lowest-risk sources
come first, so the framework is exercised against real input before it is given
host access.

## Reserved Release Gates

Two sprints are reserved outside the normal feature sequence. They are numbered
98 and 99 so they always sort last regardless of how many feature sprints are
added. Both are **required before v1.0.0** and neither may be skipped by
declaring the feature work complete.

They exist because documentation and engineering quality are the two things a
platform silently accrues debt in while every feature still appears to work.

### Sprint 98 — Documentation Lockdown

Freeze the feature surface and make the platform fully explicable to someone who
did not build it.

- User documentation
- Administrator guide
- Developer guide
- Command reference
- Troubleshooting
- Operations manual
- Architecture diagrams
- Capability and limitation documentation

The capability and limitation documentation is explicitly required: the platform
must state what it does *not* do, so operators do not infer guarantees that were
never implemented.

### Sprint 99 — Performance & Engineering Excellence

Review the accumulated implementation before declaring it production quality.

- Architecture review
- Dead-code and dependency review
- CPU/RAM/GPU/disk/network profiling
- API and inference latency benchmarking
- Token/context/prompt efficiency review
- Container and image review
- Database/query review
- Observability review
- Security review
- Final code-quality review

Findings from Sprint 99 either get fixed before v1.0.0 or are recorded as
accepted limitations with an owner. Neither sprint is a formality; a release
that skips them is not v1.0.0.

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
