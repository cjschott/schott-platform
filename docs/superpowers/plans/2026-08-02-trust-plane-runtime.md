# Trust Plane Runtime Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn ADR-0011 from a specification into runtime enforcement.

**Architecture:** v0.9.2 defined the Trust Plane and deliberately built nothing. That was correct — a partially built trust engine reads as a control while behaving as a suggestion — but it left the platform with guarantees that were intentions. This release makes them refusals.

**Tech Stack:** Python 3 standard library, `tools/common/immutable_store.py`, pinned PyYAML. No new dependencies, no network, no subprocess.

## The One Rule This Release Adds

v0.9.2 said what the platform must never silently trust. v0.9.3 makes it **unable** to.

Every function here fails closed. Where a state is unknown, malformed, or unreadable, the answer is denial with a written reason — never a default, never a guess, and never a score.

## Resolved Ambiguity

ADR-0011 stated that an expired subject "requires a new decision, not an automatic extension" but never said whether that decision continues the lineage or starts a new one. Revoked is explicitly new-lineage; Expired was undefined.

**Resolved by the operator: `Expired` continues the same lineage.** A renewal decision advances the existing lineage (`Expired → Trusted`/`Restricted` by explicit decision). Expiry means the grant aged out, not that anything went wrong, and forcing a new lineage would fragment a periodically-renewed subject's history into one chain per year. `Revoked` and `Rejected` remain terminal within their lineage.

ADR-0011 is amended additively to record this.

## Global Constraints

- No SSH, no network, no subprocess, no Docker, no `ai/.env`.
- No enrollment, no certificate handling, no known_hosts modification.
- No migration of the plugin registry, operation catalog, or target allowlists.
- No Fabric, no placement, no leases.
- No automatic trust, no trust on first use, no trust scores, no LLM.
- No automatic transition may produce a usable state. Only `Expired` is time-derived.
- Trust stores live outside the repository. No runtime record is ever committed.

## Out of Scope

Root authority supersession, non-root delegated authorities, certificate and SSH enrollment, model approval workflows, collector approval migration, Fabric integration, multi-host sequence allocation.

---

### Task 1: Test-First Contract

**Files:** Create `tests/test-trust-runtime.sh`; extend `test-static.sh`, `test-docs-static.sh`, `test-platform-model.sh`, `test-developer-experience.sh`, `ci.yml`, `run-validation.sh`

- [ ] **Step 1: Write failing tests** for all fourteen runtime modules, four documents, the CLI, and CI wiring → verify: red captured across every area listed in Phase 3.
- [ ] **Step 2: Write behavioural fixtures** driving synthetic stores in temp directories → verify: no store is created inside the repository.
- [ ] **Step 3: Write security assertions** — canary absence, no network, no SSH, no subprocess, no LLM, no scores → verify: each fails closed.
- [ ] **Step 4: Commit** as `test: define trust runtime contracts`.

### Task 2: Implementation Plan

**Files:** this document

- [ ] **Step 1: Record the resolved expiry ambiguity** and the amendment to ADR-0011.
- [ ] **Step 2: Commit** as `docs: add trust runtime implementation plan`.

### Task 3: Runtime Models

**Files:** `tools/trust/__init__.py`, `models.py`, `errors.py`, `identifiers.py`

- [ ] **Step 1: Write failing tests** for immutability, deterministic serialisation, unknown-field rejection, missing-field rejection, naive-timestamp rejection, and absence of score fields.
- [ ] **Step 2: Implement** frozen dataclasses for `OperatorRootAuthority`, `TrustRecord`, `TrustDecision`, `TrustScope`, `TrustEvidenceReference`, `TrustVerificationDetails`, `TrustLineage`, `TrustEvaluation`, `TrustAuditEvent`; `TrustState`, `AuthorityType`, `VerificationMethod` enums; six-digit identifier patterns → verify: every model round-trips deterministically.
- [ ] **Step 3: Commit** as `feat: add immutable trust runtime models`.

### Task 4: External Root Authority

**Files:** `tools/trust/root_authority.py`

- [ ] **Step 1: Write failing tests** for second-root refusal, self-approval refusal, missing evidence, missing verification details, inline secrets, and identity guessing.
- [ ] **Step 2: Implement** declaration from an explicit input file → verify: Kyri records that an external root exists and never establishes the identity.
- [ ] **Step 3: Commit** as `feat: add external root authority declaration`.

### Task 5: Immutable Trust Store

**Files:** `tools/trust/store.py`

- [ ] **Step 1: Write failing tests** for repository-root refusal, overwrite refusal, absent update and delete methods, mode `0700`/`0600`, temp residue, symlink escape, and every validation failure listed in Phase 6.
- [ ] **Step 2: Implement** `TrustStore` as a subclass of the shared `ImmutableStore` → verify: no fifth write path is created and the common abstraction needs no change.
- [ ] **Step 3: Commit** as `feat: add immutable trust store`.

### Task 6: Lineage

**Files:** `tools/trust/lineage.py`

- [ ] **Step 1: Write failing tests** for cross-lineage decisions, subject change, circular and self-supersession, orphan decisions, and rootless lineage.
- [ ] **Step 2: Implement** append-only lineage versions; the head is the highest version, never an in-place edit → verify: prior lineage records stay byte-identical.
- [ ] **Step 3: Commit** as `feat: enforce trust lineage`.

### Task 7: State Transitions

**Files:** `tools/trust/transitions.py`

- [ ] **Step 1: Write failing tests** for every transition in Phase 19, including each refusal.
- [ ] **Step 2: Implement** a code-owned transition table returning previous state, requested state, allowed/denied, governing rule, decision-required, new-lineage-required, and usability → verify: no automatic transition can produce a usable state.
- [ ] **Step 3: Commit** as `feat: enforce trust state transitions`.

### Task 8: Scope and Activity

**Files:** `tools/trust/scope.py`

- [ ] **Step 1: Write failing tests** for deny-by-default across all four dimensions, empty restricted scope, wildcard refusal, and state overrides.
- [ ] **Step 2: Implement** `evaluate_scope` and `evaluate_activity` → verify: quarantine, revocation, expiry, rejection, unknown, and pending all override a matching scope.
- [ ] **Step 3: Commit** as `feat: add trust scope and activity evaluation`.

### Task 9: Expiry

**Files:** `tools/trust/expiry.py`

- [ ] **Step 1: Write failing tests** for before, at, and after expiration, and for read-only evaluation writing nothing.
- [ ] **Step 2: Implement** stored-versus-effective state with no wall-clock read inside core functions → verify: deterministic for an explicit timestamp.
- [ ] **Step 3: Commit** as `feat: add deterministic expiry evaluation`.

### Task 10: Decisions and Audit

**Files:** `tools/trust/evaluator.py`, `audit.py`

- [ ] **Step 1: Write failing tests** for every rule in Phase 12 and every audit event kind in Phase 14.
- [ ] **Step 2: Implement** decision creation persisting decision, record, audit event, and a new lineage version → verify: read-only evaluation emits no audit event.
- [ ] **Step 3: Commit** as `feat: add immutable trust decisions and audit events`.

### Task 11: Query Service

**Files:** `tools/trust/query.py`

- [ ] **Step 1: Write failing tests** proving no identifier is consumed, nothing is written, ordering is deterministic, and every denial is explained.
- [ ] **Step 2: Implement** the seven read-only functions → verify: malformed and missing state fail closed.
- [ ] **Step 3: Commit** as `feat: add read-only trust queries`.

### Task 12: CLI

**Files:** `tools/trust/cli.py`

- [ ] **Step 1: Write failing tests** for the seven commands, three exit codes, containment after `resolve()`, and absence of delete, update, restore, and score commands.
- [ ] **Step 2: Implement** → verify: no inline JSON, no identity arguments, no interactive prompt, no default store.
- [ ] **Step 3: Commit** as `feat: add trust runtime CLI`.

### Task 13: Schema Compatibility

**Files:** tests only, unless a released schema proves insufficient

- [ ] **Step 1: Write failing compatibility tests** asserting every runtime record validates against the v0.9.2 schemas using their exact field names.
- [ ] **Step 2: Extend additively** only if a field is genuinely missing, preserving all previously valid records → verify: no safety field is weakened.
- [ ] **Step 3: Commit** as `feat: align runtime records with trust schemas`.

### Task 14: Capability and Documentation

**Files:** four `docs/trust/*.md`, capability entry, roadmap

- [ ] **Step 1: Write failing docs-static tests.**
- [ ] **Step 2: Write** runtime overview, root authority operations, state-transition runtime, and query reference; add the Trust Governance capability at maturity `partial`; add the v0.9.3 roadmap milestone → verify: synthetic identities only.
- [ ] **Step 3: Commit** as `docs: document trust runtime operations`.

### Task 15: CI

**Files:** `.github/workflows/ci.yml`, `tools/dev/run-validation.sh`

- [ ] **Step 1: Wire** the suite in dependency order — trust architecture, trust runtime, developer experience — preserving self-checking counters and extending the generated-record backstop for `TAUTH`, `TREC`, `TDEC`, `TSCOPE`, `TEVID`, and `TAUDIT`.
- [ ] **Step 2: Run full validation** → verify: every suite green, no committed runtime records.
- [ ] **Step 3: Commit and push** as `ci: validate trust runtime`.

---

## Verification Strategy

Every behavioural test builds a synthetic trust store in a temporary directory and destroys it. No test writes inside the repository, and a backstop step fails the build if a `TAUTH`, `TREC`, `TDEC`, `TSCOPE`, `TEVID`, or `TAUDIT` record is ever committed.

Time is injected. Core functions never read the wall clock, and the CLI requires `--evaluated-at`, so an expiry test asserts an exact answer rather than a race.

## Risks

- **This is the first release where trust refuses things at runtime.** A false denial blocks legitimate work; a false grant defeats the layer. Deny-by-default means the first failure mode is the recoverable one.
- **Sequence allocation is single-host.** `fcntl.flock` does not coordinate across machines, and a shared store on a network filesystem could allocate duplicate identifiers. Documented, not solved.
- **Records are immutable and the store is append-only.** A malformed record cannot be repaired, only superseded. Validation is therefore a first-class command rather than an afterthought.
- **Existing trust mechanisms remain unmigrated.** `known_hosts`, the plugin registry, the operation catalog, and target allowlists still govern real behaviour. Until migration, the platform has two trust systems, and only one of them is enforced.
