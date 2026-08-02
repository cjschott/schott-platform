# Developer Experience Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Local parity with CI, deterministic tool versions, and one-command validation.

**Architecture:** No feature work. This increment changes how the repository is validated, not what it does.

**Tech Stack:** Bash, Python 3 standard library, pinned PyYAML, ShellCheck via a pinned container image.

## The Problem This Solves

Three divergences between a developer's machine and CI exist today, and each was found by inspecting the repository rather than by guessing:

| Divergence | Evidence | Consequence |
|---|---|---|
| Five suites skip their behavioural block and still exit `0` when PyYAML is absent | `grep 'SKIP: PyYAML' tests/*.sh` matches five files | A developer can see a green run that validated almost nothing |
| ShellCheck is not installed on `schai` | `command -v shellcheck` → absent | Shell findings are discovered only after pushing |
| Host PyYAML is `6.0.1`; CI installs `6.0.3` | `python3 -c 'import yaml; yaml.__version__'` vs `requirements-ci.txt` | Local and CI parse with different library builds |

The third is the subtlest and the reason a version manifest exists at all: nothing today tells a developer that their PyYAML differs from the one CI verified by hash.

## Version Evidence

Every pin is traced to a source. Nothing is invented.

| Variable | Value | Kind | Evidence |
|---|---|---|---|
| `SHELLCHECK_VERSION` | `0.9.0` | CI-aligned | CI log, ShellCheck run `30723148728`: `version: 0.9.0` |
| `PYYAML_VERSION` | `6.0.3` | exact | `requirements-ci.txt`, hash-pinned |
| `PYTHON_MIN_VERSION` | `3.12` | minimum | `ubuntu-24.04` runner; host `3.12.3` |
| `DOCKER_COMPOSE_MIN_VERSION` | `2.0.0` | minimum | `CLAUDE.md` mandates Compose v2; host observed `5.3.1` |
| `GIT_MIN_VERSION` | `2.43.0` | host-observed | Host `2.43.0`; the only version this repository has been validated against |

## Global Constraints

- Local-only. No remote host, SSH, GitHub API, or external service during validation.
- No host package is installed without an explicit `--apply` flag.
- No firewall, SSH, Docker volume, container, or runtime service is touched.
- `ai/.env` is never read.
- No evidence is persisted; `platform-model/` is never modified.
- No orchestration behaviour changes.

## Out of Scope

Remote collectors, feature work, CI configuration generation, and any change to what the suites assert.

---

### Task 1: Contracts

**Files:** Create `tests/test-developer-experience.sh`; extend `test-static.sh`, `test-docs-static.sh`

- [ ] **Step 1: Write failing tests** for the six `tools/dev/` scripts, the manifest, and three documents → verify: red output captured.
- [ ] **Step 2: Write behavioural fixtures** simulating missing PyYAML via a `PYTHONPATH` shim → verify: the technique fails the import without touching the host.
- [ ] **Step 3: Write parity assertions** binding local validation to CI → verify: they fail before the wrapper exists.
- [ ] **Step 4: Commit** the red contract.

### Task 2: Toolchain Manifest

**Files:** `tools/dev/versions.env`

- [ ] **Step 1: Write failing tests** for each pinned variable and its documented kind.
- [ ] **Step 2: Record** the five pins with evidence and kind → verify: static assertions pass.
- [ ] **Step 3: Commit.**

### Task 3: ShellCheck Parity

**Files:** `tools/dev/run-shellcheck.sh`

- [ ] **Step 1: Write failing tests** for absence handling, version matching, and CI flag parity.
- [ ] **Step 2: Implement** a pinned container image first, falling back to a host ShellCheck only when its version matches the manifest exactly → verify: never silently skips.
- [ ] **Step 3: Verify** the file list matches CI (`scripts/*.sh tests/*.sh`) plus the new `tools/dev/*.sh`.
- [ ] **Step 4: Commit.**

### Task 4: Toolchain Check and Bootstrap

**Files:** `tools/dev/check-toolchain.sh`, `tools/dev/bootstrap.sh`

- [ ] **Step 1: Write failing tests** for dry-run default, idempotency, and refusal to install without `--apply`.
- [ ] **Step 2: Implement** `check-toolchain.sh` verifying python3, Python minimum, PyYAML import, PyYAML version, Compose, git, and a ShellCheck execution path → verify: missing tools produce actionable errors.
- [ ] **Step 3: Implement** `bootstrap.sh` defaulting to dry-run and printing exact Ubuntu commands → verify: dry-run mutates nothing.
- [ ] **Step 4: Commit.**

### Task 5: Fail-Closed PyYAML

**Files:** five test suites

- [ ] **Step 1: Write a regression test** that runs each suite under a `PYTHONPATH` shim making `import yaml` fail → verify: red, because suites currently exit `0`.
- [ ] **Step 2: Replace** each skip branch with a hard failure naming the pinned install command → verify: each suite exits non-zero under the shim.
- [ ] **Step 3: Confirm** CI is unaffected because PyYAML is installed there before any suite runs.
- [ ] **Step 4: Commit.**

### Task 6: Unified Validation

**Files:** `tools/dev/run-validation.sh`

- [ ] **Step 1: Write failing tests** for the twenty ordered steps and for `--quick`.
- [ ] **Step 2: Implement** stop-on-first-failure with section headers and preserved exit codes → verify: a forced failure stops the run.
- [ ] **Step 3: Implement** `--quick` and document exactly what it omits → verify: quick still runs syntax, ShellCheck, static tests, validators, bytecode, and diff checks.
- [ ] **Step 4: Commit.**

### Task 7: Local CI Wrapper

**Files:** `tools/dev/run-local-ci.sh`

- [ ] **Step 1: Write failing tests** asserting no GitHub API call, no push, no container start.
- [ ] **Step 2: Implement** as a strict-mode wrapper over `run-validation.sh`, printing a parity summary and naming any gap explicitly → verify: gaps are reported rather than hidden.
- [ ] **Step 3: Commit.**

### Task 8: Documentation

**Files:** three `docs/development/*.md`, `docs/platform-roadmap.md`, `docs/standards/definition-of-done-standard.md`, `README.md`

- [ ] **Step 1: Write failing docs-static tests.**
- [ ] **Step 2: Write** getting-started, toolchain, and local-validation documents → verify: docs-static passes.
- [ ] **Step 3: Mark** v0.7.5 delivered, preserving later entries and reserved sprints exactly → verify: roadmap assertions pass.
- [ ] **Step 4: Commit.**

### Task 9: CI Parity Assertions

**Files:** `tests/test-developer-experience.sh`

- [ ] **Step 1: Assert** every CI validation command appears in `run-validation.sh` or is documented as CI-only.
- [ ] **Step 2: Assert** ShellCheck and PyYAML versions match their sources, and that no suite retains a successful skip path → verify: full run green.
- [ ] **Step 3: Commit and push.**

---

## Pre-commit Decision

`.pre-commit-config.yaml` is added **only** if it can run repository-local hooks without introducing unpinned third-party hook repositories. The framework's usual `repos:` entries point at external Git repositories pinned by tag, which is a supply-chain surface this repository has so far avoided — every CI action is pinned by commit SHA. If a local-hooks-only configuration is not clean, the decision is recorded and no file is added.

## Verification Strategy

Behavioural tests are primary. Every fixture uses a temp directory or a `PYTHONPATH` shim; nothing installs a package, writes into the repository, or contacts a host.

The wrapper must not be able to mask a failure, so each legacy suite is also run individually during validation.

## Risks

- **ShellCheck via container** requires the image to be present. First use needs a pull, which is the one network operation in this increment and is never performed implicitly.
- **Version drift** between host and CI is surfaced, not fixed. Fixing it means installing packages, which requires explicit operator approval.
- **Quick mode** could become a habit that hides failures, so what it omits is documented and it still runs every cheap check.
