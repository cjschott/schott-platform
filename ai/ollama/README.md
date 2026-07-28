# Ollama Service

Ollama is the platform's **internal inference backend**. It loads local models
and serves generation and embedding APIs to LiteLLM over a private network.

> Ollama is **not** a supported application endpoint. Applications must use the
> LiteLLM gateway at `http://schai:4000/v1`. This isolated stack exists only to
> capture and troubleshoot Ollama on its own, with the API port bound to
> localhost.

## Files

- `compose.yaml` — isolated Ollama service (localhost-only port `11434`).
- `.env.example` — non-secret settings (`TZ`, `OLLAMA_IMAGE`, optional bind
  address). Copy to a local `.env`; never commit real values.

## Start (isolated troubleshooting)

```bash
cd ai/ollama
cp .env.example .env   # then edit as needed
docker compose --env-file .env -f compose.yaml up -d
```

## Persistence

Downloaded models live in the named volume `ollama-models`, mounted at
`/root/.ollama`. Model data therefore **survives container recreation**. Model
blobs are stored outside Git and are not backed up in this baseline.

The Docker volume behind that mount is
`${OLLAMA_VOLUME_NAME:-schott-platform-ollama-models}`. Keep this value
identical to the integrated stack's `ai/.env` so isolated troubleshooting
inspects the same models. To adopt the volume of an existing/legacy Ollama
deployment instead of re-downloading, set `OLLAMA_VOLUME_NAME` in the local
`.env` — and set `OLLAMA_VOLUME_EXTERNAL=true` so Compose adopts the volume
rather than creating one, which makes a wrong name fail loudly instead of
starting against an empty volume. Leave it `false` on a clean install. See
[../../docs/operations/install.md](../../docs/operations/install.md).

## Required models

Pull the exact models the platform depends on (these names are load-bearing —
LiteLLM aliases resolve to them):

```bash
docker exec ollama ollama pull qwen3:8b
docker exec ollama ollama pull qwen3:30b
docker exec ollama ollama pull nomic-embed-text
```

| Ollama model | Used by LiteLLM alias |
|---|---|
| `qwen3:8b` | `local-fast` |
| `qwen3:30b` | `local-general` |
| `nomic-embed-text` | `local-embed` |

Verify the inventory:

```bash
docker exec ollama ollama list
```

## GPU verification

Confirm the NVIDIA Tesla P4 is visible inside the container:

```bash
docker exec ollama nvidia-smi
```

If `nvidia-smi` fails, verify the NVIDIA Container Toolkit is installed on the
host and that the GPU device reservation in `compose.yaml` is honored.

## Health

The container health check runs `ollama list` using the bundled `ollama`
binary (the stock image does not include `curl`). A healthy container means the
Ollama server is answering; individual models may still cold-start on first
request.
