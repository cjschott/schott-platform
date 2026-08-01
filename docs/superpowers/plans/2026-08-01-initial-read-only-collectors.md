# Initial Read-Only Collectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the first three real collectors — git repository, Docker Compose configuration render, and manual attestation — all local and read-only, all returning `CollectorResult` objects only.

**Architecture:** v0.5.0 defined the contract with a synthetic plugin that observes nothing. This increment exercises that contract against real sources, chosen deliberately as the lowest-risk three: none contacts a host, opens a socket, or inspects a running container.

**Tech Stack:** Python 3 standard library plus pinned PyYAML; `git` and `docker compose config` as read-only local commands.

## The Contract Change This Increment Requires

v0.5.0 required every plugin to declare `subprocess_access: false`. Two of these collectors genuinely need a subprocess, so that blanket rule must change — and changing it is the single riskiest thing here.

It is narrowed rather than relaxed:

| v0.5.0 | v0.6.0 |
|---|---|
| No plugin may declare subprocess access | Subprocess permitted **only** through `command_runner.py` |
| Enforced by absence of the capability | Enforced by a single audited chokepoint with an executable allowlist |

Plugin code still never calls `subprocess` directly. Every command passes through one module that enforces `shell=False`, an explicit executable allowlist, a mandatory timeout, bounded output, a sanitized environment, and argument screening. Static tests assert `subprocess` appears nowhere in `tools/collectors/` except that module.

`network_access` remains `false` for every plugin, without exception.

## Global Constraints

- No remote host contact, SSH, container inspection, Docker runtime API, or external service.
- `ai/.env` is never opened. Only `*.env.example` files are approved inputs.
- No evidence persistence, no `EVID` assignment, no platform-model mutation, no remediation.
- Secrets are redacted before output **and before fingerprinting**.
- Collectors return `CollectorResult` objects only; the CLI prints JSON and writes nothing.

## Out of Scope

Evidence persistence, runtime Docker collection, remote git access, SSH, APIs, database storage, remediation, attachments and photo ingestion.

---

### Task 1: Contracts

**Files:** Create `tests/test-initial-collectors.sh`; extend `test-collector-framework.sh`, `test-static.sh`, `test-docs-static.sh`, `test-platform-model.sh`

- [ ] **Step 1: Write failing tests** for the three plugin packages, `command_runner.py`, `redaction.py`, `cli.py`, and three collector documents.
- [ ] **Step 2: Write behavioural fixtures** covering git states, Compose rendering, attestation rejection, and CLI modes.
- [ ] **Step 3: Run and capture the complete red phase.**
- [ ] **Step 4: Commit** — `test: define initial collector contracts`

### Task 2: Safe Command Runner

**Files:** Create `tools/collectors/command_runner.py`

- [ ] **Step 1: Write failing tests** for allowlist rejection, timeout, output bounds, argument screening, and environment sanitation.
- [ ] **Step 2: Implement** `CommandResult` and `run_read_only_command` with `shell=False`, disabled stdin, mandatory timeout, and a minimal environment.
- [ ] **Step 3: Run focused tests.**
- [ ] **Step 4: Commit** — `feat: add safe local command runner`

### Task 3: Redaction

**Files:** Create `tools/collectors/redaction.py`

- [ ] **Step 1: Write failing canary tests** proving a secret value never reaches stdout, stderr, errors, fingerprints, or serialized results.
- [ ] **Step 2: Implement** recursive key and value redaction with a deterministic `<REDACTED>` marker.
- [ ] **Step 3: Run focused tests.**
- [ ] **Step 4: Commit** — `feat: add collector redaction utilities`

### Task 4: Git Repository Collector

- [ ] **Step 1: Write failing tests** for clean, dirty, untracked, detached HEAD, tag-at-HEAD, credential-bearing remote, and invalid repository cases.
- [ ] **Step 2: Implement** using only the approved read-only git commands, with remote URL sanitization.
- [ ] **Step 3: Verify** the repository is byte-identical before and after collection.
- [ ] **Step 4: Commit** — `feat: add git repository collector`

### Task 5: Configuration Render Collector

- [ ] **Step 1: Write failing tests** for fixture rendering, `.env` rejection, path traversal, escaping symlinks, and invalid Compose files.
- [ ] **Step 2: Implement** `docker compose --env-file <approved>.example -f <compose> config`, emitting variable **names** only.
- [ ] **Step 3: Verify** no container is created, started, or inspected.
- [ ] **Step 4: Commit** — `feat: add configuration render collector`

### Task 6: Manual Attestation Collector

- [ ] **Step 1: Write failing tests** for missing actor, missing and naive and future timestamps, empty facts, secret-bearing fields, and blob rejection.
- [ ] **Step 2: Implement** structured-input-only attestation that never generates its own timestamp and never claims verification.
- [ ] **Step 3: Commit** — `feat: add manual attestation collector`

### Task 7: Collector CLI

- [ ] **Step 1: Write failing tests** for `list`, `validate`, `collect`, exit codes, and deterministic JSON.
- [ ] **Step 2: Implement** with attestation input accepted only as a file inside a caller-approved directory, never as an argument, because shell history retains arguments.
- [ ] **Step 3: Commit** — `feat: add collector command line interface`

### Task 8: Registration

- [ ] **Step 1: Register** all four collectors explicitly and update manifest validation for the narrowed subprocess model.
- [ ] **Step 2: Commit** — `feat: register initial collectors`

### Task 9: Documentation

- [ ] **Step 1: Write** three collector documents and update the framework README, capability record, model README, and roadmap.
- [ ] **Step 2: Commit** — `docs: document initial collectors`

### Task 10: CI

- [ ] **Step 1: Add** `bash tests/test-initial-collectors.sh` with static assertions preventing silent removal.
- [ ] **Step 2: Commit** — `ci: validate initial read-only collectors`

---

## Verification

Complete when all six suites pass, both validators exit 0, `cli list` and `cli validate` succeed, all three Compose configurations render, every YAML parses, `git diff --check` is clean, and no Python bytecode is tracked.

## Known Limitations

- Collection is local only. Nothing observes a remote host, and the model still describes ten hosts never contacted.
- Configuration render reports **declared** configuration, not running state. A rendered port mapping is what Compose would do, not what is listening.
- Manual attestation is human-supplied and carries no independent verification; `review_required` stays true.
- Evidence Collection advances from `foundation` to `partial`, not `operational`: real sources flow through, but nothing persists an evidence record yet.
