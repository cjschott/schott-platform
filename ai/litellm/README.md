# LiteLLM Gateway

LiteLLM is the **only supported application-facing endpoint**. It exposes an
OpenAI-compatible API on port `4000`, authenticates every request against a
master key (fail closed), and routes stable aliases to the internal Ollama
backend.

Applications connect to:

```text
http://schai:4000/v1
```

## Model aliases

Use these aliases, never provider-specific model names:

| Alias | Backend model |
|---|---|
| `local-fast` | `ollama/qwen3:8b` |
| `local-general` | `ollama/qwen3:30b` |
| `local-embed` | `ollama/nomic-embed-text` |

## Files

- `compose.yaml` — isolated LiteLLM service (publishes port `4000`).
- `config.yaml` — model aliases, backend URLs (via `${OLLAMA_BASE_URL}`), master
  key from the environment, and logging policy. Mounted read-only.
- `.env.example` — non-secret settings and the required master-key placeholder.
  Copy to a local `.env`; never commit real values.

## Authentication

Every request must present the master key as a bearer token. Requests without a
valid key are rejected — the gateway fails closed. Load the key from a local
`.env`; never hard-code it.

```bash
export LITELLM_KEY="your-local-master-key"   # matches LITELLM_MASTER_KEY
```

## Client examples

List available models:

```bash
curl http://schai:4000/v1/models \
  -H "Authorization: Bearer ${LITELLM_KEY}"
```

Chat completion via the fast alias:

```bash
curl http://schai:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local-fast",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

Embeddings via the embed alias:

```bash
curl http://schai:4000/v1/embeddings \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local-embed",
    "input": "The quick brown fox."
  }'
```

An unauthenticated request (no `Authorization` header, or a wrong key) must be
rejected with an authentication error — confirm this as part of health checks.

## Logging

Full prompts and responses are **not** logged (`turn_off_message_logging:
true`). Structured request metadata (model alias, latency, token counts,
success/failure) is still emitted. Container logs rotate (`max-size`,
`max-file`).
