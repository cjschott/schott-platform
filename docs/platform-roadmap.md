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

The roadmap runs in two phases. **Phase I** built the platform's ability to
observe itself and remember what it observed. **Phase II** builds the reasoning
layer on top of that foundation.

The order is deliberate: nothing in Phase II is worth building on a platform
that cannot describe its own state honestly.

## Phase I — Platform Foundation

Versions v0.1.0 through v0.7.5. Architecture, governance, the evidence
pipeline, immutable knowledge, and the developer workflow that validates all of
it.

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

### v0.6.0 — Initial Read-Only Collectors

**Delivered.** The first three real collectors, chosen because none needs host
access: repository state, rendered Compose configuration, and operator
attestation are all gathered locally.

- `git-repository` — read-only git inspection; remote URLs sanitized, never contacted
- `configuration-render` — `docker compose config` only; environment names, never values
- `manual-attestation` — structured human input; no file, network, or subprocess access
- `command_runner.py` — the single audited subprocess chokepoint
- `redaction.py` — applied before output *and* before fingerprinting
- A collector CLI emitting deterministic JSON and persisting nothing

Explicitly not delivered:

- **No evidence persistence.** Collectors return results; no `EVID` record is
  written, because the orchestrator that would assign identity does not exist.
- **No remote observation.** Collection is local only; the model still describes
  ten hosts nothing has contacted.
- **No runtime state.** Configuration render reports what Compose *would* do,
  not what is running.

Platform awareness is not complete. Evidence Collection advances from
`foundation` to `partial`, not `operational`.

### v0.7.0 — Knowledge Orchestrator and Immutable Timeline

**Delivered.** The layer that turns observations into memory. v0.6.0 collectors
observed and returned; nothing persisted, nothing was numbered, nothing
accumulated. This release adds identity, immutable storage, and derived
knowledge.

- `evidence_store.py` — atomic, overwrite-refusing, append-only storage at an explicit root
- `orchestrator.py` — the thirteen-step lifecycle; consumes results, never runs a collector
- `verifier.py` and `drift_engine.py` — deterministic, read-only comparison against declared intent
- `confidence.py` — five explainable factors, weights totalling 1.0
- `timeline.py` and `knowledge.py` — append-only events and derived state
- ADR-0004, plus the knowledge event and confidence standards
- `EVID` and `VER` widen to six digits; `MEM` joins them. `CAP` and `DRIFT` stay at four.

Explicitly not delivered:

- **No remote observation.** Still local only; nothing has contacted a host.
- **No database.** Files on disk, inspectable with `cat`. The storage decision stays open.
- **No remediation.** Recommendations are prose for a human to read.
- **No promotion of observation to intent.** Declared entities are never rewritten.

Evidence Collection remains `partial`: real evidence now persists, but nothing
observes a remote host.

### v0.7.5 — Developer Experience Hardening

**Delivered.** No feature work. This release changed how the repository is
validated, not what it does, after three local/CI divergences were found by
inspection.

- `tools/dev/versions.env` — every tool version pinned in one file, each with
  its kind (exact, minimum, CI-aligned, host-observed) and its evidence
- `tools/dev/run-shellcheck.sh` — ShellCheck `0.9.0` via a pinned container,
  no host package required; CI now lints `tools/dev/` too
- `tools/dev/check-toolchain.sh` and `bootstrap.sh` — dry-run by default;
  nothing installs without `--apply`
- `tools/dev/run-validation.sh` — one command, twenty ordered steps, plus a
  `--quick` mode that documents exactly what it omits
- `tools/dev/run-local-ci.sh` — strict-mode wrapper that names the four
  security workflows it cannot reproduce
- Optional `.pre-commit-config.yaml` using repository-local hooks only

The change that mattered most: **five suites printed `SKIP` and exited `0`
when PyYAML was missing.** A green run that verified almost nothing is worse
than no run, because it tells you your change is safe. All five now fail
closed and name the pinned install command.

Two defects were caught by the new tooling during its own construction — six
ShellCheck findings that would have failed CI, and a bug in the validation
runner that printed `FAILED` and then exited `0`.

## Phase II — Cognitive Infrastructure

Phase II turns a platform that records what it sees into one that can reason
about what it sees. Each release adds one faculty, and each is separately
useful.

### Architectural rule

**No model is Kyri. No machine is Kyri. Kyri is the governed core, its
evidence, and the contracts connecting replaceable capabilities.**

This is load-bearing, not a slogan. Kyri is the reasoning layer, its memory,
and its policies. Models are replaceable reasoning providers used by Kyri Core:
a language model is an adapter behind a stable interface, in exactly the way
ADR-0003 treats providers. A platform that lets a specific model
become its identity cannot replace that model without replacing itself — and
model choice is the fastest-moving decision in the stack.

The second sentence becomes load-bearing at v0.9.5, when work can be placed on
other nodes. A fabric that lets one machine become the platform has recreated
exactly the coupling the first sentence exists to prevent, one layer down: the
host would then be as unreplaceable as a hardcoded model. Nodes are capacity
behind a contract, and Kyri is what governs them.

### v0.8.0 — Operational Integrity and Digital Twin Foundation

**Delivered.** Immutable snapshots of known-good state, disposable digital twins
reconstructed from knowledge, integrity comparison, and advisory recovery
planning. Answers "is this still the system we think it is?" without ever
acting on the answer.

- `snapshot_manager.py` — immutable, versioned, fingerprinted, deterministic
  snapshots; temp-file plus `os.link`, so committing a write and refusing an
  overwrite are one atomic step
- `twin_builder.py` — disposable twins rebuilt entirely from knowledge, frozen
  with write-protected facts so a hand-edit fails rather than silently succeeds
- `integrity_analyzer.py` — five states: `MATCH`, `PARTIAL`, `DRIFT`,
  `UNKNOWN`, `INSUFFICIENT_EVIDENCE`
- `confidence.py` — five factors with weights totalling 1.0, each carrying a
  written reason
- `recovery_planner.py` — prose only; no command field, no script, no execute
  method
- ADR-0007, four schemas (`SNAP`, `TWIN`, `INTEG`, `RECOV`), four entity types,
  four relationships

`UNKNOWN` and `INSUFFICIENT_EVIDENCE` are deliberately separate from `DRIFT`:
reporting "we could not tell" as a change produces a false alarm on every gap
in coverage, and an operator paged three times for a coverage gap stops reading
drift reports at all.

Explicitly not delivered: no remediation, no automatic recovery, no runtime
Docker inspection, no remote access. Detected drift is frequently *intended*
change, and an engine that reverts a deployment it did not recognise has caused
the incident it was meant to prevent.

### v0.8.5 — Experience Engine and Operational Memory

**Delivered.** Statistical summaries of observed history: experience profiles,
rolling windows, and operational baselines. Answers "what is normal?", which is
a different question from "what is true?".

- `statistics.py` — deterministic descriptive statistics, standard library only
- `windows.py` — rolling `24h`, `7d`, `30d`, and `custom` windows resolved from
  an explicit `now` rather than the clock
- `profile_builder.py` and `baseline.py` — `EXP`, `WINDOW`, and `BASE` records,
  all immutable
- `confidence.py` — four factors totalling 1.0, each with a written reason
- `integration.py` — the `EXPECTED`/`UNEXPECTED` axis, independent of
  `MATCH`/`DRIFT`
- ADR-0008, three schemas, three entity types, three relationships

**No machine learning, by decision rather than omission.** No forecasting, no
online learning, no anomaly model, no randomness. Every number is recomputable
by hand from evidence: a wrong statistic is visibly wrong, while a wrong model
is confidently wrong, and confident wrongness is what an operational platform
can least afford.

Three rules keep it honest: missing observations are `UNKNOWN` and a thin
history is `INSUFFICIENT_EVIDENCE` — never `UNEXPECTED`; and `EXPECTED` is not
equivalent to `MATCH`, because one compares against operational history and the
other against a snapshot.

Known limitation carried forward: `sample_count` reflects *distinct retained
evidence values*, not collection frequency, because the observation layer
collapses identical repeated readings into one record plus a refresh event.
Frequency-aware weighting is reserved for v0.8.6.

### v0.8.6 — Occurrence Timeline and Temporal Knowledge

**Delivered.** A unified chronology of what happened across evidence,
integrity, and experience, so an operator can read a sequence of events rather
than reconcile several stores by hand.

- `recorder.py` — immutable `OCC` records carrying both `occurred_at` and
  `recorded_at`, each citing the evidence it came from
- `series.py` — `SERIES` records with first seen, last seen, intervals,
  frequency, and recurrence
- `patterns.py` — `PAT` records: recurring, burst, isolated, accelerating,
  decelerating
- `timeline.py` — `TL` records ordered by time then identifier
- `confidence.py` — four factors totalling 1.0, each with a written reason
- `integration.py` — temporal context alongside integrity and behaviour
- ADR-0009, four schemas, four entity types, five relationships
- `tools/common/immutable_store.py` — the shared write path, so this is not a
  fourth hand-copied store

Answers the question an operator asks first during an incident: **has this
happened before?** `DRIFT + UNEXPECTED` occurring for the first time is a
different situation from the same pair recurring every Tuesday for a month, and
only temporal history distinguishes them.

**No prediction, by decision rather than omission.** Once a system records
eleven events at two-hour intervals, predicting the twelfth is one function
away — and a predictive system that is wrong is confidently wrong at exactly
the moment an operator has stopped checking. `recurring` means it has recurred,
not that it will, and the models carry no field in which a forward claim could
be recorded.

Frequency weighting for the Experience Engine is exposed and explicitly
**not applied**: applying it would change how every existing baseline reads.
Experience continues to use distinct evidence in this release.

### v0.9.0 — Remote Read-Only Collectors

**Delivered.** First collectors requiring host access. Read-only, key-based,
scoped to explicitly approved operations. This is the release where the model
stops describing hosts nothing has contacted.

Deliberately after the reasoning layers: the pipeline is exercised against
local input, and memory is built, before anything is given reach.

Governed by [ADR-0010](decisions/ADR-0010-remote-read-only-collection.md).
One rule holds the release together: **remote collectors observe, they never
administer.**

- **The network contract is narrowed, not relaxed.** v0.5.0 refused
  `network_access` unconditionally. It is now permitted only alongside a
  `read-remote-host` permission — the same shape as the v0.6.0 subprocess
  narrowing, and refused in both directions so a manifest cannot claim one
  without the other.
- **A code-owned catalog of nine operations.** Configuration may choose an
  operation identifier and may never supply command text. Adding a fact is a
  code change and a review, on purpose: configuration is reviewed as data,
  and command text is code.
- **Targets are declared, never discovered.** No scan, no address range, no
  default. Target files are refused if they resolve outside their approved
  directory.
- **Host-key verification is mandatory** and cannot be disabled. Unknown and
  changed keys fail closed. Enrollment is deliberately absent — a collector
  that can enroll a key can enroll an attacker's.
- **Authentication is referenced, never stored.** Credential material in a
  target file is refused outright, and the refusal never echoes the value.
- **Three collectors:** `linux-host`, `linux-resources`, `linux-services`.
  No users, environments, processes, command history, network connections,
  package inventories, journals, or logs.
- **A collection failure is not a target failure.** Seven categories, all
  describing the attempt. None can say the host is down.

Largest blast-radius expansion so far: every earlier release could at worst
produce a wrong record. Accepted limits are recorded rather than resolved —
the OpenSSH client is external code, and fake-transport coverage is not
real-world coverage, so first real use needs supervised validation.

### v0.9.5 — Distributed Capability Fabric

Reserved. Lets the platform use capacity that is not on this host, without any
node becoming the platform.

Registries — what exists:

- **Node registry** — the machines the platform may use
- **Capability registry** — what each node can actually do
- **Model endpoint registry** — where inference is reachable, behind the
  ADR-0003 gateway contract rather than as a direct provider dependency
- **Resource metadata** — CPU, memory, GPU, and storage each node reports
- **Health and availability states** — whether a node is usable right now
- **Trust and privacy classifications** — what a node is permitted to see

Placement — what runs where:

- **Deterministic, policy-aware placement** — the same inputs choose the same
  node, and the choice is explainable. A scheduler nobody can predict is a
  scheduler nobody can debug during an incident.
- **Preferred and fallback placement** — an explicit second choice, never a
  silent redirection
- **Local-only enforcement** — a workload marked local must never leave this
  host, and the fabric must be able to refuse rather than degrade
- **Workload leases and expiry** — placement is time-bounded, so a node that
  disappears does not hold work indefinitely
- **Maintenance and drain modes** — a node can be removed from service
  deliberately rather than by failing

Verification — what came back:

- **Result validation** — output from another node is checked before it is
  trusted, because remote capacity does not confer remote authority
- **Placement audit events** — every decision is recorded on the timeline, so
  "why did this run there?" has an answer

Explicitly deferred to that release, and not implemented before it: no fabric,
no registry, no placement, and no remote execution of any kind exists in v0.8.6
or earlier.

### v1.0.0 — Kyri Core Foundation

Reserved. The reasoning layer itself — routing, policy, and memory — built on
the evidence, integrity, and experience foundations beneath it, and bound by
the architectural rule above.

Each release must extend the evidence pipeline without weakening the ADR-0002,
ADR-0004, or ADR-0007 guarantees.

## Reserved Release Gates

Three sprints are reserved outside the normal feature sequence. They are
numbered 97, 98, and 99 so they always sort last regardless of how many feature
sprints are added. All three are **required before v1.0.0** and none may be
skipped by declaring the feature work complete.

They exist because cognitive integrity, documentation, and engineering quality
are the three things a platform silently accrues debt in while every feature
still appears to work.

### Sprint 97 — Cognitive Integrity and Recovery

Make the reasoning layer as recoverable as the infrastructure beneath it.

A platform can restore a container from a snapshot and still be broken, because
what actually changed was a prompt, an embedding model, or a routing rule.
Cognitive state drifts in ways filesystem state does not, and it fails quietly:
answers get subtly worse while every health check stays green.

Versioning and provenance:

- Model and adapter manifests
- Prompt and policy versioning
- Routing configuration snapshots
- Embedding and index compatibility
- Memory schema versioning

Detection:

- Known-good cognitive baselines
- Golden evaluation suite
- Regression detection

Recovery:

- Suspect-state quarantine
- Human-approved layer-specific recovery
- Post-restore validation
- Audit trail and timeline events

Recovery is **layer-specific** on purpose: restoring an entire cognitive stack
because one embedding index went stale discards good state along with bad.
Every recovery step requires human approval, in line with ADR-0007 — an engine
that repairs its own reasoning without review has no independent check left.

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
