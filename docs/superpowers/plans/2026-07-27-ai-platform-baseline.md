# AI Platform Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible, secured Ollama + LiteLLM baseline for `schai` with stable model aliases, operational scripts, validation, recovery documentation, and repository security automation.

**Architecture:** LiteLLM is the only supported application-facing API and routes stable aliases to an internal Ollama backend. Docker Compose defines both isolated service stacks and a root integrated stack. Secrets stay outside Git, model data persists outside containers, and scripts provide repeatable deploy, update, health, and backup operations.

**Tech Stack:** Ubuntu 24.04, Docker Engine, Docker Compose v2, NVIDIA Container Toolkit, Ollama, LiteLLM Proxy, Bash, YAML, GitHub Actions, ShellCheck, Gitleaks, Trivy, Semgrep, Dependabot.

## Global Constraints

- Canonical repository: `cjschott/schott-platform`.
- Canonical deployment path: `/opt/schott-platform`.
- Timezone: `America/Chicago`.
- Application endpoint: `http://schai:4000/v1`.
- Ollama must not be the documented application endpoint.
- Model aliases are exactly `local-fast`, `local-general`, and `local-embed`.
- Alias mappings are exactly `ollama/qwen3:8b`, `ollama/qwen3:30b`, and `ollama/nomic-embed-text`.
- LiteLLM authentication fails closed and uses a master key loaded from a local `.env` file.
- No production secret, token, password, model blob, prompt log, or response log may be committed.
- Full prompts and responses are not logged by default.
- No automatic commercial-provider fallback is included.
- Ollama model data must survive container recreation.
- Docker logs must rotate.
- Shell scripts must use `set -Eeuo pipefail`, print actionable errors, and be safe to run repeatedly.
- Host firewall changes must be documented but not applied automatically by repository scripts.
- Existing working Ollama behavior must be preserved while it is captured in Git.
- Runtime verification requiring `schai` must be clearly separated from static repository validation.

---

## File Map

- `README.md`: platform overview, supported endpoint, quick-start flow.
- `CHANGELOG.md`: baseline release history.
- `.gitignore`: secrets, runtime data, backups, logs, local environment files.
- `.editorconfig`: repository formatting defaults.
- `ai/compose.yaml`: integrated Ollama + LiteLLM stack.
- `ai/README.md`: integrated stack usage and model alias contract.
- `ai/ollama/compose.yaml`: isolated Ollama service definition.
- `ai/ollama/.env.example`: non-secret Ollama settings.
- `ai/ollama/README.md`: Ollama operation, model inventory, GPU checks.
- `ai/litellm/compose.yaml`: isolated LiteLLM service definition.
- `ai/litellm/config.yaml`: aliases, backend URLs, logging defaults.
- `ai/litellm/.env.example`: LiteLLM environment placeholders.
- `ai/litellm/README.md`: authenticated client examples.
- `scripts/validate-config.sh`: static Compose/YAML/shell validation entry point.
- `scripts/deploy-schai.sh`: first deployment and idempotent startup.
- `scripts/update-schai.sh`: pull images and recreate services safely.
- `scripts/health-check.sh`: liveness, auth, completion, and embedding checks.
- `scripts/backup-config.sh`: sanitized config and model-inventory backup.
- `tests/test-static.sh`: repository-level static assertions.
- `security/SECURITY.md`: disclosure and secret-handling policy.
- `security/hardening-checklist.md`: host, network, container, and operational checklist.
- `docs/architecture/ai-platform.md`: service boundaries and replaceability principle.
- `docs/operations/install.md`: clean installation procedure.
- `docs/operations/operations.md`: normal operations and troubleshooting.
- `docs/operations/recovery.md`: rebuild and restore procedure.
- `docs/security/network-policy.md`: UFW transition from direct Ollama access to LiteLLM-only client access.
- `.github/dependabot.yml`: dependency update configuration.
- `.github/workflows/static-validation.yml`: YAML, Compose, ShellCheck, and repository tests.
- `.github/workflows/gitleaks.yml`: secret scanning.
- `.github/workflows/trivy.yml`: config and image scanning.
- `.github/workflows/semgrep.yml`: infrastructure/static rules.
- `.github/workflows/codeql.yml`: only enabled for supported repository languages if source code is later added; initial workflow documents that limitation.

---

### Task 1: Bootstrap the Repository Foundation

**Files:**
- Create: `README.md`
- Create: `CHANGELOG.md`
- Create: `.gitignore`
- Create: `.editorconfig`
- Create: `ai/README.md`
- Create: `tests/test-static.sh`

**Interfaces:**
- Consumes: approved design at `docs/superpowers/specs/2026-07-27-ai-platform-baseline-design.md`.
- Produces: repository conventions and a static test entry point used by later tasks and CI.

- [ ] **Step 1: Write the failing static repository test**

Create `tests/test-static.sh` with assertions that the required top-level files and service directories exist, executable shell scripts use `set -Eeuo pipefail`, `.env` files are ignored, and model/runtime directories are ignored.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
bash tests/test-static.sh
```

Expected: failure because the repository foundation files and directories do not yet exist.

- [ ] **Step 3: Create the repository foundation**

Create the listed files with:

- A README describing the platform, `http://schai:4000/v1`, the three aliases, and the separation between Git configuration, local secrets, and model data.
- A changelog beginning with `0.1.0 - AI platform baseline` under an Unreleased or dated heading.
- `.gitignore` rules for `.env`, `.env.*` except `!.env.example`, `secrets/`, `backups/`, `logs/`, model data, `.superpowers/`, and generated validation output.
- `.editorconfig` using UTF-8, LF, final newline, two-space YAML indentation, and four-space shell indentation.

- [ ] **Step 4: Run the test and verify it passes for Task 1 scope**

Run:

```bash
bash tests/test-static.sh
```

Expected: PASS for all foundation assertions implemented so far.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md .gitignore .editorconfig ai/README.md tests/test-static.sh
git commit -m "chore: bootstrap AI platform repository"
```

---

### Task 2: Capture the Working Ollama Service

**Files:**
- Create: `ai/ollama/compose.yaml`
- Create: `ai/ollama/.env.example`
- Create: `ai/ollama/README.md`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: Docker with NVIDIA Container Toolkit and an existing model volume/data path.
- Produces: service name `ollama`, internal port `11434`, persistent model storage, and Docker network compatibility for LiteLLM.

- [ ] **Step 1: Extend the static test with Ollama assertions**

Assert that:

- `ai/ollama/compose.yaml` parses with `docker compose config`.
- The service is named `ollama`.
- Port `11434` is not published to all interfaces in the integrated design.
- Persistent model storage is mounted at `/root/.ollama`.
- NVIDIA GPU access is declared.
- The image is version-pinned or constrained by an explicit environment variable with a documented default.
- Docker JSON-file logging has `max-size` and `max-file` options.

- [ ] **Step 2: Run the test and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because Ollama files do not exist.

- [ ] **Step 3: Implement the Ollama service**

Create the isolated Compose file with:

- `ollama` service.
- Image reference `${OLLAMA_IMAGE:-ollama/ollama:0.11.4}` or another tested explicit version.
- Restart policy `unless-stopped`.
- Persistent named volume `ollama-models` mounted at `/root/.ollama`.
- NVIDIA GPU reservation/configuration compatible with Compose v2.
- Health check against `http://127.0.0.1:11434/api/tags`.
- Rotating JSON-file logs.
- Port binding defaulting to `127.0.0.1:11434:11434` for isolated troubleshooting only.

Create `.env.example` with `TZ=America/Chicago`, `OLLAMA_IMAGE`, and a documented optional bind address. Document model pulls for `qwen3:8b`, `qwen3:30b`, and `nomic-embed-text`, plus GPU verification with `nvidia-smi` inside the container.

- [ ] **Step 4: Validate configuration**

```bash
docker compose --env-file ai/ollama/.env.example -f ai/ollama/compose.yaml config >/dev/null
bash tests/test-static.sh
```

Expected: both commands succeed.

- [ ] **Step 5: Commit**

```bash
git add ai/ollama tests/test-static.sh
git commit -m "feat: capture Ollama service configuration"
```

---

### Task 3: Add LiteLLM Routing and Authentication

**Files:**
- Create: `ai/litellm/compose.yaml`
- Create: `ai/litellm/config.yaml`
- Create: `ai/litellm/.env.example`
- Create: `ai/litellm/README.md`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: Ollama at `http://ollama:11434`.
- Produces: authenticated OpenAI-compatible API on port `4000` with aliases `local-fast`, `local-general`, and `local-embed`.

- [ ] **Step 1: Add failing LiteLLM static assertions**

Assert that:

- All three aliases exist exactly once.
- They map to the exact backend model names in Global Constraints.
- Ollama base URL is `http://ollama:11434` through environment substitution.
- The master key is referenced from an environment variable and not hard-coded.
- Prompt/response logging is disabled by default.
- Port `4000` is configurable and published.
- Logs rotate.

- [ ] **Step 2: Run the test and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because LiteLLM files do not exist.

- [ ] **Step 3: Implement LiteLLM configuration**

Create `config.yaml` with three model-list entries:

```yaml
model_list:
  - model_name: local-fast
    litellm_params:
      model: ollama/qwen3:8b
      api_base: ${OLLAMA_BASE_URL}
  - model_name: local-general
    litellm_params:
      model: ollama/qwen3:30b
      api_base: ${OLLAMA_BASE_URL}
  - model_name: local-embed
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: ${OLLAMA_BASE_URL}
```

Include general settings that require `LITELLM_MASTER_KEY`, avoid prompt/response persistence, and emit useful request metadata without full content.

Create Compose using an explicitly pinned LiteLLM image, a read-only config mount, health check, rotating logs, and `4000:4000` configurable binding. Create `.env.example` with placeholders only and README examples for `/v1/models`, `/v1/chat/completions`, and `/v1/embeddings` using an Authorization bearer token.

- [ ] **Step 4: Validate configuration**

```bash
docker compose --env-file ai/litellm/.env.example -f ai/litellm/compose.yaml config >/dev/null
bash tests/test-static.sh
```

Expected: both commands succeed without exposing a real key.

- [ ] **Step 5: Commit**

```bash
git add ai/litellm tests/test-static.sh
git commit -m "feat: add authenticated LiteLLM gateway"
```

---

### Task 4: Build the Integrated AI Stack

**Files:**
- Create: `ai/compose.yaml`
- Create: `ai/.env.example`
- Modify: `ai/README.md`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: Ollama and LiteLLM service definitions from Tasks 2 and 3.
- Produces: one internal network, private Ollama access, public LiteLLM port `4000`, persistent model data, and deterministic startup dependencies.

- [ ] **Step 1: Add failing integrated-stack assertions**

Assert that:

- `docker compose --env-file ai/.env.example -f ai/compose.yaml config` succeeds.
- Ollama has no host `ports` entry in the integrated stack.
- LiteLLM publishes port `4000`.
- LiteLLM depends on Ollama health.
- Both services share one private network.
- The Ollama model volume is persistent.

- [ ] **Step 2: Run tests and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because the integrated stack does not exist.

- [ ] **Step 3: Implement integrated Compose**

Create a self-contained root stack rather than Compose `extends` across files. Preserve the exact service settings from Tasks 2 and 3. Do not expose Ollama to the host. Publish LiteLLM using `${LITELLM_BIND_ADDRESS:-0.0.0.0}:${LITELLM_PORT:-4000}:4000`. Use a private bridge network named `ai-backend` and the named volume `ollama-models`.

Create `ai/.env.example` with all non-secret defaults and an empty `LITELLM_MASTER_KEY=` placeholder. Update `ai/README.md` to identify this file as the canonical production stack.

- [ ] **Step 4: Validate all Compose files**

```bash
docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
docker compose --env-file ai/ollama/.env.example -f ai/ollama/compose.yaml config >/dev/null
docker compose --env-file ai/litellm/.env.example -f ai/litellm/compose.yaml config >/dev/null
bash tests/test-static.sh
```

Expected: all commands succeed.

- [ ] **Step 5: Commit**

```bash
git add ai/compose.yaml ai/.env.example ai/README.md tests/test-static.sh
git commit -m "feat: add integrated AI platform stack"
```

---

### Task 5: Add Deployment, Update, Health, and Backup Scripts

**Files:**
- Create: `scripts/validate-config.sh`
- Create: `scripts/deploy-schai.sh`
- Create: `scripts/update-schai.sh`
- Create: `scripts/health-check.sh`
- Create: `scripts/backup-config.sh`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: `ai/compose.yaml`, local `ai/.env`, Docker Compose v2, curl, tar.
- Produces: idempotent operations and a sanitized backup archive.

- [ ] **Step 1: Add failing script assertions**

Assert every script:

- Is executable.
- Starts with `#!/usr/bin/env bash`.
- Uses `set -Eeuo pipefail`.
- Resolves repository paths relative to the script location.
- Never prints `LITELLM_MASTER_KEY`.

Add behavior tests using temporary directories and command stubs where practical.

- [ ] **Step 2: Run tests and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because scripts do not exist.

- [ ] **Step 3: Implement `validate-config.sh`**

Validate required commands, required files, non-empty local master key, Compose rendering, shell syntax, and YAML syntax where tooling exists. Return non-zero with one actionable error per failure.

- [ ] **Step 4: Implement `deploy-schai.sh` and `update-schai.sh`**

`deploy-schai.sh` must:

- Refuse to proceed without `ai/.env`.
- Run validation.
- Run `docker compose pull` and `docker compose up -d`.
- Wait for service health with a bounded timeout.
- Call `health-check.sh`.

`update-schai.sh` must:

- Record currently running image IDs.
- Pull images.
- Recreate only changed services.
- Run health checks.
- Print rollback commands using the recorded image IDs if health fails.

- [ ] **Step 5: Implement `health-check.sh`**

Check:

1. LiteLLM liveness.
2. Unauthenticated `/v1/models` is rejected.
3. Authenticated `/v1/models` succeeds.
4. `local-fast` returns a non-empty completion.
5. `local-embed` returns a non-empty numeric vector.
6. `local-general` appears in model inventory; full inference is optional unless `--deep` is supplied.

Support `--deep` to submit a short `local-general` completion with an extended timeout.

- [ ] **Step 6: Implement `backup-config.sh`**

Create a timestamped tar archive containing tracked configuration, docs, scripts, sanitized `.env.example` files, `git rev-parse HEAD`, `docker compose config`, and Ollama model inventory. Exclude `.env`, secrets, model blobs, logs, and existing backup archives. Write a manifest and SHA-256 checksum next to the archive.

- [ ] **Step 7: Run tests**

```bash
bash -n scripts/*.sh
bash tests/test-static.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts tests/test-static.sh
git commit -m "feat: add AI platform operations scripts"
```

---

### Task 6: Add Architecture, Operations, Recovery, and Security Documentation

**Files:**
- Create: `docs/architecture/ai-platform.md`
- Create: `docs/operations/install.md`
- Create: `docs/operations/operations.md`
- Create: `docs/operations/recovery.md`
- Create: `docs/security/network-policy.md`
- Create: `security/SECURITY.md`
- Create: `security/hardening-checklist.md`
- Modify: `README.md`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: completed Compose and script interfaces.
- Produces: operator procedures precise enough to deploy and recover `schai` without undocumented manual steps.

- [ ] **Step 1: Add failing documentation assertions**

Assert that docs contain:

- `/opt/schott-platform`.
- `America/Chicago`.
- `http://schai:4000/v1`.
- All three aliases.
- Explicit statement that Ollama is not the application endpoint.
- UFW transition commands documented but not scripted.
- Recovery order and model re-pull commands.
- Secret rotation and incident procedure.

- [ ] **Step 2: Run tests and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because documentation is incomplete.

- [ ] **Step 3: Write architecture and operational docs**

Document service boundaries, data flow, replaceability principle, health semantics, initial installation, normal start/stop/update, log inspection, model pulls, GPU checks, cold-start expectations, and common failure modes.

- [ ] **Step 4: Write recovery and security docs**

Document:

- Clean Ubuntu/Docker/NVIDIA prerequisites.
- Clone into `/opt/schott-platform`.
- Restore local `ai/.env` from protected storage.
- Deploy and pull all three models.
- Verify via `health-check.sh --deep`.
- UFW rules allowing `4000/tcp` from approved sources.
- Removal of the current LAN-wide `11434/tcp` rule after gateway validation.
- Secret exposure response and master-key rotation.

- [ ] **Step 5: Run tests**

```bash
bash tests/test-static.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add README.md docs security tests/test-static.sh
git commit -m "docs: add AI platform operations and security guides"
```

---

### Task 7: Add GitHub Security and Validation Automation

**Files:**
- Create: `.github/dependabot.yml`
- Create: `.github/workflows/static-validation.yml`
- Create: `.github/workflows/gitleaks.yml`
- Create: `.github/workflows/trivy.yml`
- Create: `.github/workflows/semgrep.yml`
- Create: `.github/workflows/codeql.yml`
- Modify: `tests/test-static.sh`

**Interfaces:**
- Consumes: repository tests and configuration files.
- Produces: pull-request and push validation with least-privilege permissions.

- [ ] **Step 1: Add failing workflow assertions**

Assert:

- Workflow YAML parses.
- Each workflow declares explicit permissions.
- Actions are pinned to major versions at minimum and preferably immutable SHAs.
- Static validation runs `bash tests/test-static.sh` and ShellCheck.
- Gitleaks scans the repository history appropriate to the event.
- Trivy scans configuration and the pinned service images.
- Semgrep uses infrastructure/security rules suitable for YAML, Docker, and shell.
- CodeQL does not pretend to scan unsupported languages; it is disabled or limited until supported source code is added and explains this in comments.

- [ ] **Step 2: Run tests and verify failure**

```bash
bash tests/test-static.sh
```

Expected: failure because workflows do not exist.

- [ ] **Step 3: Implement Dependabot and workflows**

Configure monthly updates for GitHub Actions and Docker references where supported. Use least-privilege workflow permissions and avoid uploading sensitive runtime files.

- [ ] **Step 4: Validate locally**

```bash
bash tests/test-static.sh
```

If `actionlint` is installed:

```bash
actionlint
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .github tests/test-static.sh
git commit -m "ci: add platform security and validation workflows"
```

---

### Task 8: Perform Full Static and `schai` Runtime Acceptance Validation

**Files:**
- Create: `docs/operations/acceptance-results.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: complete repository, `schai`, local protected `ai/.env`, existing Ollama model volume or migrated model data.
- Produces: recorded evidence that the baseline meets acceptance criteria.

- [ ] **Step 1: Run full static validation**

```bash
bash scripts/validate-config.sh
bash tests/test-static.sh
shellcheck scripts/*.sh tests/*.sh
docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
```

Expected: all commands pass.

- [ ] **Step 2: Prepare the local production environment on `schai`**

Copy `ai/.env.example` to `ai/.env`, generate a strong master key without placing it in shell history, set file mode `600`, and verify ownership is restricted to the deployment operator.

- [ ] **Step 3: Deploy the integrated stack**

```bash
cd /opt/schott-platform
./scripts/deploy-schai.sh
```

Expected: Ollama and LiteLLM become healthy without deleting the persistent model volume.

- [ ] **Step 4: Verify GPU and model inventory**

```bash
docker exec ollama nvidia-smi
docker exec ollama ollama list
```

Expected: Tesla P4 is visible and all three required models are present. Pull any missing model using the exact documented names.

- [ ] **Step 5: Run runtime health checks**

```bash
./scripts/health-check.sh --deep
```

Expected:

- Unauthenticated access is rejected.
- Authenticated model listing succeeds.
- `local-fast` completion succeeds.
- `local-general` deep completion succeeds.
- `local-embed` returns a numeric vector.

- [ ] **Step 6: Verify persistence and logging**

Recreate the Ollama container without deleting volumes, confirm all models remain listed, generate enough test logs to verify rotation configuration is active, and confirm no full prompt text is persisted by default.

- [ ] **Step 7: Verify sanitized backup**

```bash
./scripts/backup-config.sh
```

Inspect archive contents and assert that no `.env`, master key, model blob, or full prompt/response log is included.

- [ ] **Step 8: Apply the documented firewall transition manually**

After validating LiteLLM from an approved LAN client:

- Allow `4000/tcp` only from approved source ranges.
- Remove or narrow the LAN-wide `11434/tcp` rule.
- Preserve SSH access before reloading UFW.
- Confirm applications can use LiteLLM and cannot reach Ollama directly.

Record the exact applied rules in the acceptance results without recording secrets.

- [ ] **Step 9: Write acceptance evidence and release note**

Create `docs/operations/acceptance-results.md` with date, host, commit SHA, image versions, model inventory, commands run, pass/fail results, and any accepted limitations. Update `CHANGELOG.md` to mark `0.1.0` complete only if all load-bearing checks pass.

- [ ] **Step 10: Commit**

```bash
git add docs/operations/acceptance-results.md CHANGELOG.md
git commit -m "test: record AI platform baseline acceptance"
```

---

## Final Review Checklist

- [ ] Every approved design requirement maps to at least one task.
- [ ] No real secret exists in Git history.
- [ ] All Compose configurations render successfully.
- [ ] Ollama is private in the integrated stack.
- [ ] LiteLLM requires authentication and exposes all three aliases.
- [ ] Completion and embeddings work through LiteLLM.
- [ ] Model data survives container recreation.
- [ ] Backup output excludes secrets and model blobs.
- [ ] Security workflows use explicit permissions.
- [ ] Runtime acceptance evidence names the tested commit and image versions.
- [ ] Direct LAN access to Ollama is removed or explicitly documented as a temporary exception.
