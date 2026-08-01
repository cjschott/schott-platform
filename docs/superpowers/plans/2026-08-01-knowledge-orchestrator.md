# Knowledge Orchestrator and Immutable Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform `CollectorResult` objects into immutable, persisted evidence and derived knowledge events through an explicit orchestration layer.

**Architecture:** v0.6.0 delivered collectors that observe and return. Nothing persisted, nothing was numbered, and nothing accumulated over time. This increment adds the layer that assigns identity, writes evidence once and never again, and derives — never stores — the current knowledge state.

**Tech Stack:** Python 3 standard library plus pinned PyYAML. No database, no network service, no HTTP API.

## The Boundary This Increment Establishes

The single most important property is that **collectors observe and the orchestrator remembers**. These are separate responsibilities with separate trust levels:

| Collector (v0.6.0) | Orchestrator (v0.7.0) |
|---|---|
| Returns `CollectorResult` | Consumes `CollectorResult`, never runs one |
| Has no identifier field | Allocates `EVID`, `VER`, `MEM` identifiers |
| Writes nothing | Writes immutable records to an explicit store root |
| Knows one source | Compares sources, derives confidence |

A collector that numbered its own records would control the audit trail. An orchestrator that ran collectors would inherit their blast radius. Keeping them apart is what makes the evidence trail trustworthy.

## The ID Width Change

Evidence and verification identifiers widen from four digits to six:

| Before | After | Rationale |
|---|---|---|
| `EVID-0001` | `EVID-000001` | Evidence accumulates per collection, not per design decision. Four digits exhausts in under a year of routine collection. |
| `VER-0001` | `VER-000001` | Verifications are produced per evidence evaluation. |
| — | `MEM-000001` | New. Knowledge events are the highest-volume record of the three. |

`CAP-0001`, `DRIFT-0001`, and every declared-entity prefix (`HOST`, `SVC`, `REPO`, …) **remain four digits**. Those are authored by humans and grow slowly; widening them would churn every existing record for no benefit. No `EVID` or `VER` record exists in the repository yet, so widening those two costs nothing.

## Global Constraints

- Repository-only and local-only. No remote host, SSH, container inspection, Docker runtime API, or external service.
- `ai/.env` is never opened.
- No database, no Neo4j, no network service, no HTTP API, no LLM reasoning.
- Canonical platform entities are never modified by any code in this increment.
- Collectors never persist evidence; only the orchestrator writes.
- No remediation, and no executable action in any model or record.
- Evidence is append-only: no update method and no delete method exists in v0.7.0.

## Out of Scope

Remote collectors, databases, graph storage, HTTP APIs, LLM reasoning, automation, remediation, scheduling, and multi-host sequence coordination.

---

### Task 1: Contracts

**Files:** Create `tests/test-knowledge-orchestrator.sh`; extend `test-static.sh`, `test-docs-static.sh`, `test-platform-model.sh`, `test-evidence-validator.sh`, `test-collector-framework.sh`

- [ ] **Step 1: Write failing tests** for all twelve `tools/observation/` modules, three schemas, three documents, and two model READMEs → verify: red output captured before any implementation exists.
- [ ] **Step 2: Write behavioural fixtures** covering evidence persistence, deduplication, verification, drift, confidence, timeline, knowledge state, and CLI → verify: every scenario in Phase 19 has a named assertion.
- [ ] **Step 3: Write static safety assertions** for network imports, SSH, Docker runtime, subprocess, `ai/.env`, platform-model writes, deletion and update APIs, and remediation methods → verify: assertions fail closed on absence.
- [ ] **Step 4: Commit** the red contract.

### Task 2: ADR-0004 Immutable Knowledge Timeline

**Files:** `docs/decisions/ADR-0004-immutable-knowledge-timeline.md`

- [ ] **Step 1: Record the pipeline** `CollectorResult → Observation → Evidence → Verification → Drift → Knowledge Event → Knowledge State` → verify: docs-static test passes.
- [ ] **Step 2: Record sixteen principles** and seven rejected alternatives → verify: each is individually asserted.
- [ ] **Step 3: Commit.**

### Task 3: Knowledge Event and Confidence Standards

**Files:** `docs/standards/knowledge-event-standard.md`, `docs/standards/confidence-freshness-standard.md`

- [ ] **Step 1: Define ten approved event types** and the append-only rule → verify: test asserts each type.
- [ ] **Step 2: Define five confidence factors,** their weights, and the statement that confidence is an engineering heuristic rather than a probability → verify: weights sum to 1.0 in both document and code.
- [ ] **Step 3: Define four freshness states** and the null-policy rule producing `unknown` with `review_required: true` → verify: asserted behaviourally.
- [ ] **Step 4: Commit.**

### Task 4: Observation Data Models

**Files:** `tools/observation/__init__.py`, `tools/observation/models.py`

- [ ] **Step 1: Write failing tests** for the nine dataclasses and their required fields.
- [ ] **Step 2: Implement** `Observation`, `EvidenceRecord`, `VerificationRecord`, `DriftAssessment`, `KnowledgeEvent`, `KnowledgeState`, `ConfidenceExplanation`, `FreshnessAssessment`, `OrchestrationResult` → verify: focused tests pass.
- [ ] **Step 3: Assert no model carries an executable command or remediation instruction** → verify: static test.
- [ ] **Step 4: Commit.**

### Task 5: Immutable Evidence Store

**Files:** `tools/observation/evidence_store.py`

- [ ] **Step 1: Write failing tests** for atomic write, overwrite refusal, filename-matches-ID, restrictive permissions, and root rejection.
- [ ] **Step 2: Implement** explicit-root store with `evidence/`, `verifications/`, `events/`, `indexes/`, `state/`, `sequences/` → verify: focused tests pass.
- [ ] **Step 3: Implement six-digit sequence allocation** with atomic creation and collision handling → verify: two rapid allocations return distinct IDs.
- [ ] **Step 4: Commit.**

### Task 6: Evidence Builder and Deduplication

**Files:** `tools/observation/evidence_builder.py`, `tools/observation/deduplicator.py`

- [ ] **Step 1: Write failing tests** for `CollectorResult` immutability, defensive redaction, fingerprint determinism, and duplicate scoping.
- [ ] **Step 2: Implement builder** converting `CollectorResult` to `Observation` to `EvidenceRecord`, allocating an ID only after validation → verify: input object unchanged.
- [ ] **Step 3: Implement deduplicator** scoped by target, collector, and fact namespace → verify: duplicate produces a refresh event, not new evidence.
- [ ] **Step 4: Commit.**

### Task 7: Confidence and Freshness Engine

**Files:** `tools/observation/confidence.py`

- [ ] **Step 1: Write failing tests** for factor bounds, weight total, determinism, and the null-policy path.
- [ ] **Step 2: Implement** the weighted arithmetic mean with documented weights → verify: explanation lists every factor and weight.
- [ ] **Step 3: Commit.**

### Task 8: Verification and Drift Engines

**Files:** `tools/observation/verifier.py`, `tools/observation/drift_engine.py`

- [ ] **Step 1: Write failing tests** for the six drift result types and the four "not drift" rules.
- [ ] **Step 2: Implement verifier** producing `VerificationRecord` referencing supporting evidence IDs → verify: stale evidence cannot produce `verified`.
- [ ] **Step 3: Implement drift engine** producing `DriftAssessment` → verify: missing evidence is `missing_observation`, never `mismatch`.
- [ ] **Step 4: Commit.**

### Task 9: Knowledge Timeline

**Files:** `tools/observation/timeline.py`

- [ ] **Step 1: Write failing tests** for append-only behaviour, deterministic ordering, and query by target.
- [ ] **Step 2: Implement** append and query sorted by `occurred_at` then ID → verify: history preserved across appends.
- [ ] **Step 3: Commit.**

### Task 10: Derived Knowledge State

**Files:** `tools/observation/knowledge.py`

- [ ] **Step 1: Write failing tests** for deterministic rebuild and the declared/observed/inferred distinction.
- [ ] **Step 2: Implement** derivation from evidence, verifications, drift, and events → verify: rebuild from the same inputs is byte-identical.
- [ ] **Step 3: Commit.**

### Task 11: Orchestrator

**Files:** `tools/observation/orchestrator.py`

- [ ] **Step 1: Write failing tests** for the thirteen-step lifecycle and the fail-closed paths.
- [ ] **Step 2: Implement** `process_collector_result(...)` → verify: evidence survives a later verification failure and emits a failure event instead of being deleted.
- [ ] **Step 3: Commit.**

### Task 12: Observation CLI

**Files:** `tools/observation/cli.py`

- [ ] **Step 1: Write failing tests** for `ingest`, `timeline`, `knowledge`, `verify`, `validate-store`, and the three exit codes.
- [ ] **Step 2: Implement** with explicit store root, approved input directory, and symlink-escape rejection → verify: no default production path exists.
- [ ] **Step 3: Commit.**

### Task 13: Schemas and Ontology

**Files:** three `platform-model/schemas/*.yaml`, two model READMEs, four ontology files

- [ ] **Step 1: Write failing tests** for the schemas, entity types, and relationships.
- [ ] **Step 2: Add** `observation` and `knowledge-event` entity types with `OBS` and `MEM` prefixes → verify: platform-model test passes.
- [ ] **Step 3: Widen** `EVID` and `VER` id patterns to six digits, leaving `CAP` and `DRIFT` at four → verify: evidence validator passes.
- [ ] **Step 4: Commit.**

### Task 14: Documentation

**Files:** five `docs/observation/*.md`, `platform-model/README.md`, `docs/platform-roadmap.md`, `docs/standards/definition-of-done-standard.md`

- [ ] **Step 1: Write failing docs-static tests.**
- [ ] **Step 2: Write** overview, evidence store, timeline, confidence and freshness, and knowledge state documents → verify: docs-static passes.
- [ ] **Step 3: Mark** v0.7.0 delivered and reserve v0.7.5, v0.8.0, v0.9.0, keeping Sprint 98 and 99 intact → verify: roadmap assertions pass.
- [ ] **Step 4: Commit.**

### Task 15: CI

**Files:** `.github/workflows/ci.yml`

- [ ] **Step 1: Add** `bash tests/test-knowledge-orchestrator.sh` preserving all prior checks → verify: static assertion prevents silent removal.
- [ ] **Step 2: Run full validation** → verify: every suite green, no committed evidence, no tracked bytecode.
- [ ] **Step 3: Commit and push.**

---

## Verification Strategy

Behavioural tests are primary; static assertions are a backstop that raises the cost of introducing an unsafe call without claiming to prove its absence.

Every behavioural test uses a temporary directory. No test writes into the repository, and a static assertion fails if generated evidence appears under `platform-model/evidence/` or `platform-model/verifications/`.

## Risks

- **Sequence allocation under concurrency.** Scoped to one local host. `O_CREAT|O_EXCL` gives atomic reservation; a multi-host deployment would need a different mechanism and is out of scope.
- **Confidence is a heuristic.** The weighted mean is defensible and explainable, not statistically derived. The standard says so explicitly so no consumer reads it as a probability.
- **Derived state could be mistaken for truth.** Knowledge state is never persisted as authoritative and may be cached only under an ignored directory.
