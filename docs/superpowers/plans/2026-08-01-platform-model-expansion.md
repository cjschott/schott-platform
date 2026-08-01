# Platform Model Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the machine-readable knowledge model from the single AI Platform slice to the full set of platform roles, known hosts, declared networks, logical storage, and backup policies — plus the governance gates that define when work is finished.

**Architecture:** The [Platform Ontology Standard](../../standards/platform-ontology-standard.md) supplies the vocabulary and the [Operational Metadata Standard](../../standards/operational-metadata-standard.md) the provenance contract. This increment adds entities only; it discovers nothing at runtime and asserts no live state.

**Tech Stack:** YAML, Bash static validation, Python 3 with PyYAML.

## Global Constraints

- Documentation and data only. No services, firewall rules, SSH configuration, containers, Docker volumes, `ai/.env`, or host packages are touched.
- Every fact is `declared`. Nothing in this increment is `observed` or `inferred`.
- Four-digit identifiers throughout, including relationship ids.
- Entity filenames are the bare slug; the `slug` field is the join key.
- Relationships stay canonical under `platform-model/relationships/`. Entity records reference edge ids and name `canonical_source`; they never restate source, relationship, or target.
- Active hosts use `lifecycle: active`. `environment: production` where applicable.
- No volatile values: no uptime, kernel, disk usage, IP lease state, container ids, or image ids.
- No secrets, credentials, bucket names, or encryption keys.
- Where a fact is not established by committed documentation, set `review_required: true` rather than guessing.

## Source of Truth for Classifications

Host role and tier assignments are taken from the committed table in the [Platform Role and Host Classification Standard](../../standards/platform-role-host-classification-standard.md), not from memory or inference.

Verification performed before implementation:

| Host | Committed source | Resolution |
|---|---|---|
| `schai` | Standard: AI Platform, Tier 1 | Confirmed |
| `schmgmt` | Standard: Management Platform, Tier 1 | Confirmed |
| `schoxmox1` | Standard: Compute Platform, Tier 0 | Confirmed |
| `schoxmox2` | Standard: Compute Platform, **Tier 0** | Confirmed as Tier 0; the ambiguity raised during scoping is resolved by the committed table |
| `schpbs` | Standard: Backup Platform, Tier 0 | Confirmed |
| `schdownload` | Standard: Media Platform, Tier 3 | Confirmed |
| `schweb1` | Standard: Web Platform, Tier 2 | Confirmed |
| `schweb2` | Standard: Web Platform, Tier 2 | Confirmed |
| `schplex` | Standard: Media Platform, Tier 3 | Confirmed |
| `schraspi` | **Absent from all committed documentation** | `review_required: true` |
| `schotectli` | **Absent from all committed documentation** | `review_required: true` |

Two further findings are recorded rather than silently resolved:

- `schcore` appears in the committed standard as Management Platform, Tier 0, but is not in this increment's host list. It is not modeled here and remains a known inventory gap.
- The [Network Architecture](../../architecture/network-architecture.md) defines a Reserved zone `192.168.86.100-149` that this increment does not model, because the network entity list is fixed at four.

## Out of Scope

- Runtime discovery, reconciliation, or drift detection
- Kyri as a deployed entity
- Service entities beyond the existing LiteLLM and Ollama
- Neo4j, dashboards, alerts, runbook entities
- Ansible inventory generation
- `schcore` and the Reserved network zone

---

## File Structure

- `docs/standards/definition-of-done-standard.md`: completion gates for platform work.
- `docs/platform-roadmap.md`: adds reserved Sprint 98 and Sprint 99 release gates.
- `platform-model/roles/*.yaml`: eight new platform roles.
- `platform-model/hosts/*.yaml`: ten new host entities.
- `platform-model/networks/*.yaml`: four declared network entities.
- `platform-model/storage/*.yaml`: four logical storage entities.
- `platform-model/backup-policies/*.yaml`: five backup policy entities.
- `platform-model/relationships/*.yaml`: canonical declared edges.
- `tests/test-platform-model.sh`, `tests/test-docs-static.sh`: extended contracts.

---

### Task 1: Expansion Contract Tests

**Files:** Modify `tests/test-platform-model.sh`, `tests/test-docs-static.sh`

- [ ] **Step 1: Assert new directories and entity kinds**

Require `platform-model/networks`, `storage`, `backup-policies`, and required fields per kind.

- [ ] **Step 2: Assert classification integrity**

Every host belongs to exactly one primary role that resolves. Tier 0 and Tier 1 hosts carry a backup policy relationship or `review_required: true`.

- [ ] **Step 3: Assert network validity**

Network entities declare a syntactically valid CIDR or address range.

- [ ] **Step 4: Assert governance documents**

Definition of Done exists with all required gates; roadmap contains Sprint 98 and Sprint 99 with their required contents.

- [ ] **Step 5: Run and capture the red phase**

Run: `bash tests/test-platform-model.sh` and `bash tests/test-docs-static.sh`

Expected: FAIL for every missing directory, entity, and governance section.

- [ ] **Step 6: Commit** — `test: define platform model expansion contracts`

### Task 2: Governance

**Files:** Create `docs/standards/definition-of-done-standard.md`; modify `docs/platform-roadmap.md`

- [ ] **Step 1: Write the Definition of Done** covering architecture alignment, tests, documentation, service catalog, platform model, runbooks, observability, security review, performance, backup and recovery, release notes, and reviewer approval.
- [ ] **Step 2: Add Sprint 98 and Sprint 99** as reserved gates required before v1.0.0.
- [ ] **Step 3: Commit** — `docs: add definition of done and release gates`

### Task 3: Platform Roles

**Files:** Create eight role files; modify `platform-model/roles/ai-platform.yaml`

- [ ] **Step 1: Create ROLE-0002 through ROLE-0009** with the required field set.
- [ ] **Step 2: Normalize ROLE-0001** field names to `observability_requirements` and `backup_expectations` so all nine roles share one schema.
- [ ] **Step 3: Commit** — `feat: add platform role entities`

### Task 4: Hosts

**Files:** Create ten host files

- [ ] **Step 1: Create HOST-0002 through HOST-0011** using the verified classification table, with `review_required: true` where documentation does not establish the classification.
- [ ] **Step 2: Commit** — `feat: add host entities`

### Task 5: Networks

**Files:** Create four network files

- [ ] **Step 1: Create NET-0001 through NET-0004** as declared policy, referencing the Network Architecture and Network Policy documents.
- [ ] **Step 2: Commit** — `feat: add network entities`

### Task 6: Storage and Backup Policies

**Files:** Create four storage files and five backup policy files

- [ ] **Step 1: Create STOR-0001 through STOR-0004** with logical descriptions only.
- [ ] **Step 2: Create BKP-0001 through BKP-0005**, using `review_required: true` wherever cadence or retention is not committed.
- [ ] **Step 3: Commit** — `feat: add storage and backup policy entities`

### Task 7: Relationships

**Files:** Create or extend files under `platform-model/relationships/`

- [ ] **Step 1: Declare edges** for host role membership, service placement, network attachment, storage use, and backup coverage.
- [ ] **Step 2: Verify no undocumented circular hard dependency** exists.
- [ ] **Step 3: Commit** — `feat: expand platform relationships`

### Task 8: Guidance

**Files:** Modify `platform-model/README.md`

- [ ] **Step 1: Document the new entity kinds**, the `review_required` convention, and the expanded id allocations.
- [ ] **Step 2: Commit** — `docs: update platform model guidance`

---

## Verification

The increment is complete when:

- `bash -n tests/*.sh` is clean.
- `tests/test-static.sh`, `tests/test-docs-static.sh`, and `tests/test-platform-model.sh` pass.
- All three Compose configurations render from `.env.example`.
- Every `platform-model` YAML file parses with PyYAML.
- `git diff --check` is clean.
- No secrets and no volatile runtime values are present.

## Known Limitations

- The model records declared intent. No host in this increment has been contacted, so no entity carries an `observed_at` fact and drift is undetected by design.
- `schraspi` and `schotectli` are modeled with unverified classifications pending review.
- Backup cadence and retention are largely `review_required`; no schedule is invented.
- `schcore` and the Reserved network zone remain unmodeled inventory gaps.
