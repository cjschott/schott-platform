# AI Platform Stacks

Docker Compose stacks and configuration for the Schott AI platform.

## Layout

- `compose.yaml` — the integrated Ollama + LiteLLM production stack _(added in a
  later task)_.
- `ollama/` — isolated Ollama service definition _(added in a later task)_.
- `litellm/` — isolated LiteLLM gateway service and routing config _(added in a
  later task)_.

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
