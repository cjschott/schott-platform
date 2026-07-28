# AI Platform Stacks

Docker Compose stacks and configuration for the Schott AI platform.

## Layout

- `compose.yaml` — **the canonical production stack.** The integrated
  Ollama + LiteLLM deployment for `schai`; deploy this file. It is
  self-contained (no Compose `extends`), keeps Ollama private, and publishes
  only LiteLLM on port `4000`.
- `ollama/` — isolated Ollama service definition, for capturing/troubleshooting
  Ollama on its own. Not the production stack.
- `litellm/` — isolated LiteLLM gateway service and routing config
  (`config.yaml` is reused by the canonical stack). Not the production stack.

## Canonical production stack

`ai/compose.yaml` is the single source of truth for production. Run it with the
local secrets file:

```bash
docker compose --env-file ai/.env -f ai/compose.yaml up -d
```

Copy `ai/.env.example` to `ai/.env` and set a real `LITELLM_MASTER_KEY` first.
The isolated `ollama/` and `litellm/` stacks are development/troubleshooting
aids only and must not be used to run production.

### Fail closed on an empty master key

The LiteLLM container **refuses to start when `LITELLM_MASTER_KEY` is empty**. A
startup guard inside the container checks the key before launching LiteLLM and
exits non-zero if it is blank, so running `docker compose -f ai/compose.yaml up`
directly with an unset/blank key fails fast rather than starting an
unauthenticated gateway. No fallback or default key is ever substituted. The
empty value in `ai/.env.example` is a template only.

## Model alias contract

LiteLLM exposes stable aliases; applications must use these names rather than
provider-specific model names:

| Alias | Backend model |
|---|---|
| `local-fast` | `ollama/qwen3:8b` |
| `local-general` | `ollama/qwen3:30b` |
| `local-embed` | `ollama/nomic-embed-text` |

## Supported endpoint

Applications connect only to LiteLLM at `http://schai:4000/v1`. Ollama
(`11434`) is an internal backend and is not a supported application endpoint.

## Secrets

Real `.env` files (including `LITELLM_MASTER_KEY`) are never committed. Copy the
sanitized `.env.example` templates to local `.env` files kept in protected
storage under `/opt/schott-platform`.
