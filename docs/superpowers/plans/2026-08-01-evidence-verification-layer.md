# Evidence and Verification Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the schema and validation foundation that future read-only evidence collection will write into — without collecting anything.

**Architecture:** The platform model currently records declared intent only. Nothing in it has been checked against reality, and there is no vocabulary for saying "this was true at this moment, here is what supported it." This increment supplies that vocabulary: an entity lifecycle separate from provenance, an immutable evidence record, a read-only verification result, and declarative drift rules. It adds a validator that enforces the contract before any collector exists.

**Tech Stack:** YAML, Bash static validation, Python 3 standard library plus the already-pinned PyYAML.

## Global Constraints

- Repository-only. No host is contacted, no SSH, no Proxmox/pfSense/Docker/GitHub API is queried, no package is installed.
- No runtime collection. This increment defines schemas; it does not execute them.
- No remediation. `remediation_mode` may be `advisory` or `manual-approval-required`, never `automatic`.
- Nothing modifies runtime services, `ai/.env`, firewall, SSH, Docker volumes, or containers.
- Four-digit identifiers: `EVID-0001`, `VER-0001`, `DRIFT-0001`.
- Evidence never contains a secret value. Secret *metadata* such as `secret_present: true` is permitted.
- Verification is read-only and never rewrites a canonical entity file.
- Where an operational frequency is not already committed, use `evidence_max_age: null` with `review_required: true`. Do not invent cadences.

## The Distinction This Increment Exists To Enforce

Four concepts are routinely conflated, and conflating them is how a model starts lying:

| Concept | Question it answers | Example values |
|---|---|---|
| `lifecycle` | How mature is this record? | `declared`, `verified`, `managed` |
| `provenance` | Where did this fact come from? | `declared`, `observed`, `inferred` |
| `verification_state` | Did evidence support the declaration? | `pending`, `verified`, `drift` |
| `operational_health` | Is it working right now? | **Not modeled. Requires live telemetry.** |

A `verified` lifecycle does **not** mean the service is up. It means evidence supported the declared identity and required facts at a point in time. Nothing in this increment can answer "is it healthy now", and the schemas are shaped so that no consumer can accidentally imply that it can.

## Out of Scope

Runtime collectors, SSH, APIs, subprocess execution, network access, databases, Neo4j, remediation, Grafana, Kyri execution, and drift resolution.

---

## File Structure

- `docs/standards/entity-lifecycle-standard.md`: maturity vocabulary and transitions.
- `docs/standards/evidence-standard.md`: immutable evidence contract and source types.
- `docs/standards/verification-drift-standard.md`: verification states, drift results, severities.
- `platform-model/schemas/{evidence,verification,drift-rule}.schema.yaml`: declarative, repository-owned schemas.
- `platform-model/drift-rules/core-platform.yaml`: `DRIFT-0001`–`DRIFT-0006`.
- `platform-model/{evidence,verifications,drift-rules}/README.md`: contributor guidance.
- `tools/platform_model/validate_evidence.py`: the enforcing validator.
- `tests/test-evidence-validator.sh`: fixture-driven validator tests.

---

### Task 1: Test-First Contracts

**Files:** Modify `tests/test-platform-model.sh`, `tests/test-docs-static.sh`; create `tests/test-evidence-validator.sh`

The repository has no established Python test framework, so the validator is tested through Bash using fixture directories and exit codes: a valid fixture must exit 0, and each invalid fixture must exit non-zero for its own specific reason.

- [ ] **Step 1: Assert new directories, schema files, standards, and READMEs.**
- [ ] **Step 2: Assert the validator exists and is exercised.**
- [ ] **Step 3: Write fixture cases** covering duplicate ids, bad id format, unresolvable targets, unapproved enums, missing timestamps, naive timestamps, secret-bearing keys, `remediation_mode: automatic`, and stale-evidence-implies-verified.
- [ ] **Step 4: Run and capture the red phase.**
- [ ] **Step 5: Commit** — `test: define evidence and verification contracts`

### Task 2: Entity Lifecycle Standard

- [ ] **Step 1:** Define `draft`, `declared`, `verification-pending`, `verified`, `managed`, `deprecated`, `archived`, the forward transitions, and the `verified -> verification-pending` regression.
- [ ] **Step 2:** Record that transitions carry reason, actor, and timestamp; archived ids are never reused; lifecycle never implies runtime health.
- [ ] **Step 3: Commit** — `docs: add entity lifecycle standard`

### Task 3: Evidence and Verification Standards

- [ ] **Step 1:** Evidence standard — ten approved source types, required fields, status and sensitivity enums, immutability, redaction.
- [ ] **Step 2:** Verification and drift standard — seven states, five severities, six result types, read-only rules.
- [ ] **Step 3: Commit** — `docs: add evidence and verification standards`

### Task 4: Ontology Additions

- [ ] **Step 1:** Add `evidence`, `verification`, `drift-rule` entity types with `EVID`, `VER`, `DRIFT` prefixes.
- [ ] **Step 2:** Add `SUPPORTED_BY`, `VERIFIED_BY`, `EVALUATES`, `DETECTS_DRIFT_IN`, `SUPERSEDES` with valid source/target combinations and no remediation semantics.
- [ ] **Step 3:** Add validation and inference rules for the new concepts.
- [ ] **Step 4: Commit** — `feat: extend ontology for evidence and drift`

### Task 5: Schemas

- [ ] **Step 1:** Evidence schema — required fields, enums, timestamp rules, id pattern, forbidden secret-bearing keys, permitted fact value types.
- [ ] **Step 2:** Verification schema — states, results, severities, evidence-reference and approval rules, stale-evidence restriction.
- [ ] **Step 3:** Drift-rule schema — comparators and the `remediation_mode` restriction.
- [ ] **Step 4: Commit** — `feat: add evidence and verification schemas`

### Task 6: Initial Drift Rules

- [ ] **Step 1:** Define `DRIFT-0001`–`DRIFT-0006` as definitions only, with `evidence_max_age: null` and `review_required: true` wherever no cadence is committed.
- [ ] **Step 2: Commit** — `feat: add initial drift rules`

### Task 7: Validator

- [ ] **Step 1:** Implement `validate_evidence.py` using the standard library plus PyYAML, accepting `--root`, exiting 0 on success and non-zero on failure, printing file-specific errors and never printing a secret value.
- [ ] **Step 2:** Verify every fixture case behaves as asserted.
- [ ] **Step 3: Commit** — `feat: add evidence validator`

### Task 8: Documentation

- [ ] **Step 1:** Three directory READMEs plus updates to `platform-model/README.md` and the roadmap Sprint 4 entry.
- [ ] **Step 2: Commit** — `docs: document evidence model`

### Task 9: CI

- [ ] **Step 1:** Run the validator after the existing hashed requirements install, preserving `ubuntu-24.04`, action pins, least-privilege permissions, and sanitized inputs.
- [ ] **Step 2: Commit** — `ci: validate evidence and drift definitions`

---

## Verification

Complete when `bash -n tests/*.sh` is clean, all four suites pass, the validator exits 0 against the repository model and non-zero against every invalid fixture, all Compose configurations render, every `platform-model` YAML file parses, and `git diff --check` is clean.

## Known Limitations

- No evidence record exists yet. The `evidence/` and `verifications/` directories ship with a README and no records, because fabricating an evidence record would defeat the purpose of an evidence layer.
- `evidence_max_age` is `null` on every rule that lacks a committed cadence.
- The layer cannot report operational health and is deliberately shaped so it cannot appear to.
