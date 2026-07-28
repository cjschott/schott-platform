# AI Platform Architecture

Service boundaries and design principles for the Schott AI Platform Baseline on
`schai` (Ubuntu 24.04, Docker Compose v2, NVIDIA Tesla P4).

## Data flow

```text
Applications
    │  (OpenAI-compatible HTTPS/HTTP + bearer token)
    ▼
LiteLLM gateway  ── http://schai:4000/v1   (only application-facing API)
    │  (private Docker bridge: ai-backend)
    ▼
Ollama backend   ── ollama:11434           (internal only, never published)
    │
    ▼
Tesla P4 GPU + system RAM
```

Applications send OpenAI-compatible requests to the LiteLLM gateway at
`http://schai:4000/v1` and authenticate with a bearer token. LiteLLM resolves a
stable model alias to an Ollama model and calls Ollama over the private
`ai-backend` network. Ollama runs inference on the Tesla P4.

## LiteLLM is the only supported application-facing API

LiteLLM is the **only supported application-facing** endpoint. It:

- Exposes the OpenAI-compatible API on port `4000`.
- Requires a master key; unauthenticated requests are rejected (fails closed).
- Maps stable aliases to Ollama models.
- Emits request metadata but does not log full prompts or responses.

Ollama listens on `11434` **inside** the stack only. In the integrated stack
(`ai/compose.yaml`) Ollama has no host port mapping at all — it is reachable
only by LiteLLM over the `ai-backend` bridge network.
**Ollama is not an application endpoint** and must never be addressed directly
by applications.

## Stable alias contract

Applications reference stable aliases, never provider-specific model names:

| Alias | Backend model |
|---|---|
| `local-fast` | `ollama/qwen3:8b` |
| `local-general` | `ollama/qwen3:30b` |
| `local-embed` | `ollama/nomic-embed-text` |

### Why the application layer must not depend on provider-specific names

Coupling applications to **provider-specific** model names (for example
`ollama/qwen3:8b`) makes every backend change a breaking change for consumers.
By depending only on aliases, applications are insulated from:

- Swapping Ollama for another inference backend behind LiteLLM.
- Replacing a Qwen model with a newer or larger one while preserving the alias.
- Adding a commercial provider later through LiteLLM (a deliberate future option,
  not part of this baseline).
- Changing GPU hardware.

This is the platform's core **replaceable-services** principle: every component
is independently replaceable behind a stable interface without requiring changes
to consuming applications.

## Trust boundaries and exposed ports

| Port | Service | Scope | Exposure |
|---|---|---|---|
| `4000/tcp` | LiteLLM | Application-facing | Published on the host; restrict to approved clients (see network policy) |
| `11434/tcp` | Ollama | Internal backend | **Not** published in the integrated stack; private to `ai-backend` |
| `22/tcp` | SSH | Management | Trusted management systems only |

The trust boundary is the LiteLLM gateway. Everything behind it (Ollama, the
GPU, model data) is private. Authentication is enforced at the gateway and fails
closed.

## State and persistence

- **Repository configuration** — Compose files, LiteLLM config, scripts, and
  docs are tracked in Git.
- **Local secrets** — real `.env` files (including `LITELLM_MASTER_KEY`) live in
  protected storage under `/opt/schott-platform`, **outside Git**. The gateway
  loads the key from the local environment file and never from a committed
  value.
- **Model data** — downloaded models persist in the named `ollama-models`
  Docker volume mounted at `/root/.ollama`, so they survive container
  recreation. Model blobs are outside Git and are intentionally excluded from
  configuration backups in this baseline. The underlying Docker volume name is
  `${OLLAMA_VOLUME_NAME:-schott-platform-ollama-models}`, so the same Compose
  files serve a clean install and a host adopting an existing Ollama volume —
  keeping storage a replaceable implementation detail behind a stable mount.
  `OLLAMA_VOLUME_EXTERNAL` (default `false`) controls whether Compose may create
  that volume; adopters set it to `true` so an existing store is never
  shadowed by an empty one. See
  [../operations/install.md](../operations/install.md) for migration.

## Logging and failure behavior

- Both services use the `json-file` Docker log driver with rotation limits.
- Full prompts and responses are **not logged by default**
  (`turn_off_message_logging: true`); only request metadata is emitted.
- Missing or invalid authentication fails closed at LiteLLM.
- There is **no commercial-provider fallback** and no silent external routing:
  if Ollama is unavailable, LiteLLM reports the upstream failure rather than
  reaching out to any external provider.
- Restarting LiteLLM does not affect model data; restarting Ollama may cause
  model cold-start latency but not configuration loss.

## Related documents

- Installation: [../operations/install.md](../operations/install.md)
- Operations: [../operations/operations.md](../operations/operations.md)
- Recovery: [../operations/recovery.md](../operations/recovery.md)
- Network policy: [../security/network-policy.md](../security/network-policy.md)
- Security policy: [../../security/SECURITY.md](../../security/SECURITY.md)
