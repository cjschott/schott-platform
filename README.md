# Schott Platform

Reproducible, secured infrastructure for the Schott AI platform.

The current release is the **AI Platform Baseline** for the `schai` VM
(Ubuntu 24.04, Docker Compose v2, NVIDIA Tesla P4): a captured Ollama
inference backend fronted by a LiteLLM gateway, plus operational scripts,
recovery documentation, and repository security automation.

## Supported application endpoint

Applications connect **only** to the LiteLLM gateway:

```text
http://schai:4000/v1
```

The endpoint is OpenAI-compatible and requires authentication. Ollama is an
internal inference backend and is **not** a supported application endpoint.

## Model aliases

Applications reference stable aliases, never provider-specific model names, so
backends stay independently replaceable:

| Alias | Backend model |
|---|---|
| `local-fast` | `ollama/qwen3:8b` |
| `local-general` | `ollama/qwen3:30b` |
| `local-embed` | `ollama/nomic-embed-text` |

## Three storage domains

The platform deliberately separates what lives where. Never mix these:

1. **Git configuration** — Compose files, LiteLLM config, scripts, docs, and
   sanitized `.env.example` templates. Tracked in this repository.
2. **Local secrets** — real `.env` files (including `LITELLM_MASTER_KEY`) held
   in protected storage under `/opt/schott-platform`, outside Git.
3. **Model data** — downloaded Ollama model blobs, persisted in a Docker volume
   or host-mounted path, outside Git and excluded from backups in this baseline.

## Repository layout

- `ai/` — Docker Compose stacks and configuration for the AI services.
- `docs/` — architecture, operations, security, and design/plan documents.
- `scripts/` — deploy, update, health-check, and backup operations.
- `security/` — security policy and hardening checklist.
- `tests/` — repository-level static validation (`tests/test-static.sh`).

## Documentation

Operators should follow the scripts and these guides rather than running long
procedures by hand:

- Architecture: [docs/architecture/ai-platform.md](docs/architecture/ai-platform.md)
- Installation: [docs/operations/install.md](docs/operations/install.md)
- Operations: [docs/operations/operations.md](docs/operations/operations.md)
- Recovery: [docs/operations/recovery.md](docs/operations/recovery.md)
- Network policy: [docs/security/network-policy.md](docs/security/network-policy.md)
- Security policy: [security/SECURITY.md](security/SECURITY.md)
- Hardening checklist: [security/hardening-checklist.md](security/hardening-checklist.md)

Deploy, update, health-check, and backup are driven by the scripts in
`scripts/`; see the installation and operations guides for exact usage.

## Design and plan

The approved design and task-by-task implementation plan are authoritative:

- Design: [docs/superpowers/specs/2026-07-27-ai-platform-baseline-design.md](docs/superpowers/specs/2026-07-27-ai-platform-baseline-design.md)
- Plan: [docs/superpowers/plans/2026-07-27-ai-platform-baseline.md](docs/superpowers/plans/2026-07-27-ai-platform-baseline.md)

## Validation

One command runs everything CI runs (no VM, running deployment, or secrets
required):

```bash
tools/dev/run-validation.sh
```

Add `--quick` for a faster edit-loop subset; it prints exactly what it omitted
and is never sufficient before pushing.

## Development

New machine? Check the toolchain and see what is missing — nothing is installed
without your explicit approval:

```bash
tools/dev/check-toolchain.sh
tools/dev/bootstrap.sh            # dry run; changes nothing
```

Continuous integration in `.github/workflows/` automates the same validation
you can run locally — nothing CI-only. Tool versions are pinned in
`tools/dev/versions.env`, and `tools/dev/run-local-ci.sh` names the four
security workflows that can only run on GitHub.

- [docs/development/getting-started.md](docs/development/getting-started.md)
- [docs/development/toolchain.md](docs/development/toolchain.md)
- [docs/development/local-validation.md](docs/development/local-validation.md)

Passing local validation should produce the same result as CI.
