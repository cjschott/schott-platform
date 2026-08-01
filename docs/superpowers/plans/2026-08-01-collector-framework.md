# Collector Framework and Architecture Decisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the collector plugin architecture, the capability model, and the two architectural decisions that govern them — without implementing a single live collector.

**Architecture:** v0.4.0 defined what evidence *is*. This increment defines what may produce it, and under what constraints. Building the contract before the first collector means a collector cannot quietly widen its own permissions, invent its own vocabulary, or acquire write access by accident.

**Tech Stack:** Python 3 standard library (dataclasses, enums, abc) plus the already-pinned PyYAML; YAML; Bash validation.

## Global Constraints

- Repository-only. No live collection, no host contact, no SSH, no Proxmox/pfSense/Docker/GitHub/PBS/Pi-hole API, no runtime discovery.
- Collectors never modify canonical platform entities.
- Collectors never persist evidence and never assign `EVID` identifiers.
- No remediation, at any layer.
- No network, subprocess, or filesystem write in framework or plugin code this increment.
- Plugin code receives no raw secret values.
- Nothing touches runtime services, `ai/.env`, firewall, SSH, Docker volumes, containers, or host packages.
- Four-digit capability identifiers, `CAP-0001`; lowercase kebab-case collector identifiers.

## The Boundary This Increment Exists To Draw

A collector is the point where the outside world first touches the model. That makes it the most dangerous component in the system, and the one most likely to accumulate quiet privilege.

Three separations are therefore structural rather than conventional:

| Separation | Why it must hold |
|---|---|
| **Collection from persistence** | A collector that writes its own evidence can rewrite history. It returns data; the orchestrator decides what becomes a record. |
| **Collection from identity** | A collector that assigns `EVID` ids controls the audit trail's numbering. Ids are assigned outside the plugin. |
| **Collection from correction** | A collector that can act on what it finds will eventually act on something it misread. |

A plugin that cannot write, cannot name, and cannot act is a plugin whose worst failure mode is a wrong observation — which verification is designed to catch.

## Out of Scope

Live Git, Compose, manual-attestation, SSH, Docker, Proxmox, pfSense, PBS, Pi-hole, network, and API collectors. Runtime execution against `schai`. Entry-point plugin discovery. Secret brokering.

---

## File Structure

- `docs/decisions/ADR-0002-evidence-first-architecture.md`: the collection-to-approval pipeline.
- `docs/decisions/ADR-0003-provider-agnostic-ai-architecture.md`: gateway and routing policy.
- `docs/standards/capability-model-standard.md`: what the platform can intentionally provide.
- `docs/standards/collector-plugin-standard.md`: the plugin contract.
- `tools/collectors/`: models, base interface, registry, normalizer, exceptions, validator.
- `tools/collectors/plugins/example/`: a synthetic, test-only plugin.
- `platform-model/capabilities/`: `CAP-0001`–`CAP-0008`.
- `platform-model/schemas/capability.schema.yaml`.
- `tests/test-collector-framework.sh`.

---

### Task 1: Contracts

**Files:** Create `tests/test-collector-framework.sh`; modify the three existing suites.

- [ ] **Step 1:** Assert every required file, the capability and collector id formats, manifest parsing, unique plugin names, approved source types, and absent secrets.
- [ ] **Step 2:** Assert the prohibitions structurally — no write or remediation permission, no network/SSH/subprocess/filesystem-write in collector code, no `EVID` assignment, no direct evidence writes, no canonical-entity mutation.
- [ ] **Step 3:** Assert ADR numbering does not collide with `ADR-0001`, and the provider-agnostic routing guarantees.
- [ ] **Step 4:** Run and capture the red phase.
- [ ] **Step 5: Commit** — `test: define collector framework contracts`

### Task 2: ADR-0002 Evidence-First Architecture

- [ ] **Step 1:** Record the pipeline from runtime through collector, normalized observation, evidence, verification, drift, recommendation, human approval, to optional automation.
- [ ] **Step 2:** State the twelve principles and the five rejected alternatives.
- [ ] **Step 3: Commit** — `docs: add evidence-first architecture decision`

### Task 3: ADR-0003 Provider-Agnostic AI Architecture

- [ ] **Step 1:** Record the stable gateway interface, adapter model, routing dimensions, and the prohibition on silent cloud fallback.
- [ ] **Step 2:** Describe OmniRoute-inspired concepts without depending on it as a service or proxy.
- [ ] **Step 3: Commit** — `docs: add provider-agnostic AI architecture decision`

### Task 4: Standards

- [ ] **Step 1:** Capability model standard — id range, required fields, maturity and risk vocabularies.
- [ ] **Step 2:** Collector plugin standard — definition, five-stage lifecycle, manifest fields, approved and forbidden permissions.
- [ ] **Step 3: Commit** — `docs: add capability and collector plugin standards`

### Task 5: Data Models and Base Interface

- [ ] **Step 1:** `models.py` — `CollectorManifest`, `CollectionContext`, `Observation`, `CollectorResult`, `CollectorError`.
- [ ] **Step 2:** `base.py` — abstract `CollectorPlugin` enforcing the lifecycle and failing closed.
- [ ] **Step 3: Commit** — `feat: add collector data models and base interface`

### Task 6: Registry and Normalizer

- [ ] **Step 1:** `registry.py` — explicit registration, duplicate rejection, no dynamic import, no execution at registration.
- [ ] **Step 2:** `normalizer.py` — deterministic ordering, canonical timestamps, secret-key rejection, fingerprint over redacted content.
- [ ] **Step 3: Commit** — `feat: add collector registry and normalization`

### Task 7: Example Plugin

- [ ] **Step 1:** A synthetic plugin that refuses non-synthetic execution and touches nothing.
- [ ] **Step 2: Commit** — `feat: add synthetic example collector`

### Task 8: Plugin Validator

- [ ] **Step 1:** `validate_plugins.py --root .` with exit codes 0/1/2 and secret-safe errors.
- [ ] **Step 2: Commit** — `feat: add collector plugin validator`

### Task 9: Capabilities and Ontology

- [ ] **Step 1:** `capability.schema.yaml` plus `CAP-0001`–`CAP-0008` with honest maturity values.
- [ ] **Step 2:** Ontology additions for the `capability` type and needed relationships.
- [ ] **Step 3: Commit** — `feat: add capability model entities`

### Task 10: Documentation and Roadmap

- [ ] **Step 1:** Two READMEs, model README update, roadmap v0.5.0 entry and v0.6.0–v0.9.0 reservations.
- [ ] **Step 2: Commit** — `docs: document collector framework and roadmap`

### Task 11: CI

- [ ] **Step 1:** Run the plugin validator and framework tests after the hashed install; assert CI invokes both.
- [ ] **Step 2: Commit** — `ci: validate collector framework`

---

## Verification

Complete when `bash -n tests/*.sh` is clean, all five suites pass, both validators exit 0, all Compose configurations render, every YAML file parses, and `git diff --check` is clean.

## Known Limitations

- No collector collects anything. The only plugin is synthetic and refuses non-synthetic execution.
- The framework is unproven against a real source; its fitness is untested until v0.6.0.
- Capability maturity is a declared judgement, not an evidence-backed measurement, and is marked `review_required` where committed evidence does not support it.
