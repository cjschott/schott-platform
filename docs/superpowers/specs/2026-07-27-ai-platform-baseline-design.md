# AI Platform Baseline Design

**Date:** 2026-07-27

**Status:** Approved

## 1. Purpose

Build the first reproducible baseline for the Schott AI platform on `schai`. The baseline captures the working Ollama deployment in source control, adds LiteLLM as the supported application-facing gateway, establishes operational scripts and documentation, and enables security scanning from the beginning.

This phase intentionally excludes Kyri application services, PostgreSQL, pgvector, Redis, and memory ingestion.

## 2. Goals

- Make the AI platform reproducible from Git and protected secrets.
- Preserve the currently working Ollama deployment and downloaded model choices.
- Provide one OpenAI-compatible application endpoint through LiteLLM.
- Use stable model aliases so consuming applications do not depend on provider-specific names.
- Require authentication at the LiteLLM boundary.
- Establish health checks, operational scripts, recovery documentation, and security workflows.
- Keep every platform component independently replaceable behind stable interfaces.

## 3. Non-Goals

- Building the Kyri API or user interface.
- Adding persistent vector storage.
- Adding commercial model providers or automatic external fallback.
- Building centralized observability on `schmgmt`.
- Backing up downloaded model files.
- Implementing application-specific virtual keys beyond the initial gateway baseline.

## 4. Current State

The `schai` Ubuntu 24.04 VM currently has:

- Docker with NVIDIA container support.
- Tesla P4 passthrough working.
- A healthy Ollama container listening on port `11434`.
- `qwen3:8b` installed and successfully generating responses.
- `qwen3:30b` installed.
- `nomic-embed-text` installed and successfully returning embeddings.
- UFW enabled with SSH open and Ollama currently allowed from `192.168.86.0/24`.

The repository `cjschott/schott-platform` is empty before this design document is added.

## 5. Architecture

```text
Applications
    |
    v
LiteLLM :4000
    |
    v
Ollama :11434
    |
    v
Tesla P4 + system RAM
```

LiteLLM is the only supported application-facing AI endpoint. Ollama remains the local inference backend.

Applications must use LiteLLM model aliases rather than Ollama model names:

| Alias | Backend model |
|---|---|
| `local-fast` | `ollama/qwen3:8b` |
| `local-general` | `ollama/qwen3:30b` |
| `local-embed` | `ollama/nomic-embed-text` |

No automatic commercial-provider fallback is included in this phase.

## 6. Repository Structure

```text
schott-platform/
├── ai/
│   ├── compose.yaml
│   ├── README.md
│   ├── ollama/
│   │   ├── compose.yaml
│   │   ├── .env.example
│   │   └── README.md
│   └── litellm/
│       ├── compose.yaml
│       ├── config.yaml
│       ├── .env.example
│       └── README.md
├── docs/
│   ├── architecture/
│   ├── operations/
│   ├── security/
│   └── superpowers/
│       ├── plans/
│       └── specs/
├── scripts/
│   ├── deploy-schai.sh
│   ├── update-schai.sh
│   ├── health-check.sh
│   └── backup-config.sh
├── security/
│   ├── SECURITY.md
│   └── hardening-checklist.md
├── .github/
│   ├── dependabot.yml
│   └── workflows/
├── .editorconfig
├── .gitignore
├── CHANGELOG.md
└── README.md
```

The canonical deployment location on the VM is:

```text
/opt/schott-platform
```

Downloaded Ollama models are stored outside Git using a Docker volume or host-mounted data path.

Secrets and production `.env` files are never committed.

## 7. Service Boundaries

### 7.1 Ollama

Responsibilities:

- Load and run local models.
- Provide generation and embedding APIs to LiteLLM.
- Use NVIDIA acceleration where supported.
- Persist downloaded models across container replacement.

Ollama is not the supported long-term client endpoint.

### 7.2 LiteLLM

Responsibilities:

- Expose an OpenAI-compatible API on port `4000`.
- Require a master key for the initial baseline.
- Map stable aliases to Ollama models.
- Return clear upstream failures.
- Provide health endpoints and structured request metadata.
- Avoid full prompt and response logging by default.

### 7.3 Operational Scripts

Responsibilities:

- Validate prerequisites and configuration.
- Deploy or update the Compose stack.
- Check both gateway health and model readiness.
- Back up configuration and operational metadata without copying model files or secrets.

Each script must fail on errors, print actionable messages, and be safe to run repeatedly.

## 8. Configuration and Secrets

Each service directory includes an `.env.example` containing placeholders only.

Expected baseline variables include:

```text
TZ=America/Chicago
LITELLM_MASTER_KEY=
OLLAMA_BASE_URL=http://ollama:11434
LITELLM_PORT=4000
LOG_LEVEL=INFO
```

Production secrets are stored in protected local environment files under `/opt/schott-platform` or another root-readable location outside Git.

The LiteLLM master key is administrative and must not be embedded in Compose YAML, documentation, shell scripts, Notion, GitHub, or command history.

## 9. Networking and Firewall

Initial intended policy:

| Port | Service | Allowed source |
|---|---|---|
| `22/tcp` | SSH | Trusted management systems |
| `4000/tcp` | LiteLLM | Trusted LAN and approved application servers |
| `11434/tcp` | Ollama | Localhost and the internal Docker network |

During migration, the current LAN access rule for port `11434` may remain temporarily for troubleshooting. After LiteLLM is validated, the deployment documentation must instruct the operator to remove or narrow that rule.

The Compose design must avoid publishing Ollama publicly when LiteLLM and Ollama are running in the same stack.

## 10. Health and Failure Behavior

The platform must distinguish:

- Container process health.
- LiteLLM API availability.
- Ollama API availability.
- Model presence.
- Successful inference readiness.

Baseline health verification includes:

- LiteLLM liveness request.
- LiteLLM authenticated model-list request.
- Ollama tag/model inventory check from inside the trusted network.
- A short completion through LiteLLM using `local-fast`.
- An embedding request through LiteLLM using `local-embed` where supported by the selected LiteLLM configuration.

Failure behavior:

- Missing or invalid LiteLLM authentication fails closed.
- Ollama failures are reported clearly by LiteLLM.
- No silent fallback to external providers occurs.
- Restarting LiteLLM does not affect downloaded model data.
- Restarting Ollama may cause model cold-start latency but not configuration loss.

## 11. Logging and Observability

All containers log to stdout/stderr.

Docker logging uses rotation limits to prevent unbounded disk growth.

Request metadata should include, where available:

- Request identifier.
- Key or application identity.
- Model alias.
- Resolved backend model.
- Latency.
- Success or failure.
- Token counts.

Full prompts and responses are not logged by default.

Centralized Prometheus, Grafana, and log forwarding are deferred to a later phase.

## 12. Security Baseline

The repository includes:

- Gitleaks secret scanning.
- CodeQL where applicable.
- Semgrep static analysis.
- Trivy scanning for container/configuration vulnerabilities.
- Dependabot configuration.
- A security policy and hardening checklist.

Security workflows should be appropriate for an infrastructure repository and must not claim meaningful source-code analysis where no supported language exists.

The deployment must use pinned image versions or documented version constraints rather than relying permanently on unbounded `latest` tags.

## 13. Backup and Recovery

Back up:

- Compose files.
- LiteLLM configuration.
- Operational scripts.
- Documentation.
- Sanitized environment templates.
- A model inventory produced by Ollama.

Do not back up:

- Downloaded model blobs during this baseline.
- Production secrets inside the repository backup bundle.
- Full prompt or response logs.

Recovery process:

1. Install Ubuntu, Docker, and NVIDIA container support.
2. Clone `cjschott/schott-platform` into `/opt/schott-platform`.
3. Restore protected local secrets.
4. Start the Compose stack.
5. Pull the documented Ollama models.
6. Run the health-check script.
7. Apply the documented UFW rules.

## 14. Testing Strategy

### Static validation

- `docker compose config` succeeds for the root and service-specific Compose files.
- YAML files pass linting.
- Shell scripts pass ShellCheck.
- Secret scanning passes.
- Trivy configuration and image scans complete.

### Runtime validation on `schai`

- Containers become healthy.
- The Tesla P4 is visible in the Ollama container.
- LiteLLM rejects unauthenticated requests.
- LiteLLM accepts authenticated requests.
- `local-fast` completes a test prompt.
- `local-general` resolves to `qwen3:30b` and begins inference successfully.
- `local-embed` returns a numeric embedding vector.
- Model data survives container recreation.
- Docker logs rotate according to configuration.

### Recovery validation

- A clean deployment from the repository and local secrets reproduces the service.
- The backup script omits secrets and model blobs.

## 15. Implementation Sequence

1. Create the repository foundation and documentation.
2. Capture the working Ollama Compose configuration without changing current behavior.
3. Add LiteLLM configuration and model aliases.
4. Add root-stack orchestration and protected configuration handling.
5. Add deployment, update, health, and backup scripts.
6. Add security automation and repository policy files.
7. Validate locally and on `schai`.
8. Remove or narrow direct LAN access to Ollama after gateway validation.

## 16. Acceptance Criteria

The baseline is complete when:

- The repository contains the approved structure and documentation.
- Ollama and LiteLLM deploy with Docker Compose on `schai`.
- LiteLLM is reachable at `http://schai:4000/v1` from an approved client.
- Authentication is required.
- `local-fast`, `local-general`, and `local-embed` resolve correctly.
- Completion and embedding requests work through LiteLLM.
- Ollama is no longer the documented application endpoint.
- No production secret exists in Git.
- Health-check and backup scripts succeed.
- Security workflows are committed and syntactically valid.
- Recovery documentation is sufficient to rebuild the platform from Git, protected secrets, and model downloads.

## 17. Architectural Principle

Every service in the Schott Platform must be independently replaceable without requiring changes to consuming applications.

Examples:

- Ollama can be replaced by another inference backend behind LiteLLM.
- Qwen models can be replaced while preserving aliases.
- Commercial providers can be added later through LiteLLM without application rewrites.
- GPU hardware can change without changing application integrations.
- Future memory storage can change behind the Kyri Memory API without changing its consumers.
