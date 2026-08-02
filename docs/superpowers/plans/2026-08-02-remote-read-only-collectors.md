# Remote Read-Only Collectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A narrow, auditable framework for collecting explicitly approved facts from explicitly approved remote hosts.

**Architecture:** Every release through v0.8.6 was local by construction. This one crosses the remote-observation boundary, which is the largest single expansion of blast radius the platform has taken. The framework is deliberately narrow: a collector may run one of nine code-owned operations against a declared target, and nothing else.

**Tech Stack:** Python 3 standard library, the system OpenSSH client invoked through an argv-only runner, pinned PyYAML.

## The Contract Change This Increment Requires

v0.5.0 required `network_access: false` for every plugin, unconditionally. Three collectors here genuinely need the network, so that blanket rule must change — and changing it is the riskiest thing in this sprint.

It is **narrowed**, exactly as v0.6.0 narrowed the subprocess prohibition:

| Before | After |
|---|---|
| No plugin may declare network access | Network permitted **only** with the `read-remote-host` permission |
| Enforced by absence of the capability | Enforced by an audited transport, a code-owned catalog, and static tests |

A plugin still never opens a socket, never builds a command string, and never chooses what runs. It names an operation identifier; the catalog owns the argv.

## The Distinction That Governs Everything

**Remote collectors observe. They never administer.**

Every rejected design in ADR-0010 collapses that distinction somewhere: an arbitrary-command collector, shell text in YAML, `sudo`, disabled host-key checking. Each is individually convenient and each converts a read-only observer into a remote execution service.

## Global Constraints

- No remote writes, no service mutation, no package installation, no `sudo`.
- No arbitrary command text crosses any public API; configuration selects an identifier.
- Host-key verification is mandatory and cannot be disabled. Unknown and changed keys fail closed.
- Authentication material is referenced by path or secret-source identifier, never stored or passed as an argument.
- No target discovery, no CIDR scanning, no defaults.
- Collectors return `CollectorResult` only: no persistence, no evidence identifiers.
- **No real host is contacted during implementation or CI.** Every behavioural test drives a fake transport.
- The control plane keeps working when every remote target is unreachable.

## Out of Scope

Distributed Capability Fabric, job placement, inference scheduling, remote writes, host-key enrollment, credential management, Ansible execution, Docker runtime inspection, service enumeration.

---

### Task 1: Contracts

**Files:** Create `tests/test-remote-collectors.sh`; extend `test-static.sh`, `test-docs-static.sh`, `test-platform-model.sh`, `test-collector-framework.sh`, `test-developer-experience.sh`

- [ ] **Step 1: Write failing tests** for the eight `remote/` modules, three plugins, the CLI, two schemas, and four documents → verify: red captured.
- [ ] **Step 2: Write behavioural fixtures** driving `FakeRemoteTransport` across every failure category → verify: no real transport is constructed.
- [ ] **Step 3: Write static safety assertions** for shells, `sudo`, package managers, mutation verbs, forwarding, and disabled host-key checking → verify: each fails closed.
- [ ] **Step 4: Commit** the red contract.

### Task 2: ADR-0010

**Files:** `docs/decisions/ADR-0010-remote-read-only-collection.md`

- [ ] **Step 1: Record sixteen principles** and ten rejected alternatives → verify: docs-static asserts each.
- [ ] **Step 2: Commit.**

### Task 3: Remote Models

**Files:** `tools/collectors/remote/models.py`, `target.py`

- [ ] **Step 1: Write failing tests** for field validation and the absence of password, key-content, and passphrase fields.
- [ ] **Step 2: Implement** `RemoteTarget`, `AuthenticationReference`, `RemoteOperation`, `RemoteExecutionRequest`, `RemoteExecutionResult`, `RemoteFailureCategory` → verify: CIDR and range targets rejected.
- [ ] **Step 3: Commit.**

### Task 4: Transport Contract and SSH argv

**Files:** `tools/collectors/remote/transport.py`, `ssh_transport.py`

- [ ] **Step 1: Write failing tests** asserting the argv builder includes `BatchMode=yes`, `StrictHostKeyChecking=yes`, an explicit `UserKnownHostsFile` and `ConnectTimeout`, and excludes forwarding, `ProxyCommand`, and TTY allocation.
- [ ] **Step 2: Implement** the abstract interface, `FakeRemoteTransport`, and `SSHRemoteTransport` → verify: the builder is tested without executing.
- [ ] **Step 3: Commit.**

### Task 5: Command Catalog

**Files:** `tools/collectors/remote/command_catalog.py`

- [ ] **Step 1: Write failing tests** that every operation is argv-only and that no forbidden binary appears.
- [ ] **Step 2: Implement** the nine operations with parsers, ceilings, platform, and sensitivity → verify: unknown identifiers are rejected.
- [ ] **Step 3: Commit.**

### Tasks 6–8: Three Collectors

**Files:** `plugins/linux_host/`, `plugins/linux_resources/`, `plugins/linux_services/`

- [ ] **Step 1: Write failing tests** per collector, including the forbidden facts each must not gather.
- [ ] **Step 2: Implement** each against the transport interface → verify: unit names validated against a strict pattern and the target allowlist.
- [ ] **Step 3: Commit** each separately.

### Task 9: CLI

**Files:** `tools/collectors/remote_cli.py`

- [ ] **Step 1: Write failing tests** for `list-operations`, `validate-target`, `collect`, containment, and the three exit codes.
- [ ] **Step 2: Implement** → verify: no enrollment command exists.
- [ ] **Step 3: Commit.**

### Task 10: Schemas and Ontology

**Files:** two schemas, four ontology files

- [ ] **Step 1: Write failing tests.**
- [ ] **Step 2: Add** `remote-target` (`RTGT`) and `remote-operation` (`ROP`) with `TARGETS`, `PERMITS_OPERATION`, `COLLECTS_FROM` → verify: no fabric entity added.
- [ ] **Step 3: Commit.**

### Task 11: Documentation

**Files:** four `docs/collectors/*.md`, roadmap

- [ ] **Step 1: Write failing docs-static tests.**
- [ ] **Step 2: Write** the threat model, enrollment, catalog, limits, failure semantics, and forbidden behaviour → verify: synthetic hostnames only.
- [ ] **Step 3: Commit.**

### Task 12: CI

**Files:** `.github/workflows/ci.yml`, `tools/dev/run-validation.sh`

- [ ] **Step 1: Wire** the suite into CI and local validation, preserving self-checking counters.
- [ ] **Step 2: Run full validation** → verify: every suite green, no network, no tracked bytecode.
- [ ] **Step 3: Commit and push.**

---

## Verification Strategy

Behavioural tests drive `FakeRemoteTransport` exclusively. `SSHRemoteTransport` is tested by inspecting the argv it *would* build, never by running it — the one component that could reach a host is the one component never executed under test.

Static assertions are a backstop: they raise the cost of introducing an unsafe call without claiming to prove absence.

## Risks

- **Largest blast-radius expansion so far.** Mitigated by the catalog, the argv-only transport, and mandatory host-key verification — but a bug here reaches other machines, which no previous release could.
- **The OpenSSH client is an external dependency.** Its option parsing is not ours; the argv builder pins every relevant option explicitly rather than relying on defaults or ambient config.
- **Host-key enrollment is deliberately absent.** Operators must enroll keys outside collection, which is friction by design: a collector that can enroll a key can accept an attacker's.
- **Fake-transport coverage is not real-world coverage.** Nothing here proves the SSH client behaves as modelled against a live host; first real use needs supervised validation.
