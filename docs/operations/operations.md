# Operations

Day-to-day operation of the AI Platform Baseline on `schai`. All commands run
from `/opt/schott-platform` and use the canonical stack `ai/compose.yaml` with
the local secret file `ai/.env`. The host timezone is `America/Chicago`.

All Compose commands take the form:

```bash
docker compose --env-file ai/.env -f ai/compose.yaml <subcommand>
```

## Status checks

```bash
docker compose --env-file ai/.env -f ai/compose.yaml ps
```

Both `ollama` and `litellm` should report `running` and `healthy`.

## Health verification

```bash
./scripts/health-check.sh
```

Runs the standard checks (liveness, unauthenticated rejection, authenticated
model list, `local-fast` completion, `local-embed` vector, `local-general`
inventory). For an extended, bounded `local-general` completion:

```bash
./scripts/health-check.sh --deep
```

The script reads the master key from `ai/.env`, never prints it, and prints only
concise pass/fail metadata — never full generated responses.

## Log inspection

```bash
docker compose --env-file ai/.env -f ai/compose.yaml logs --tail=100 litellm
docker compose --env-file ai/.env -f ai/compose.yaml logs --tail=100 ollama
```

Logs use the `json-file` driver with rotation limits (`max-size`, `max-file`).
Full prompts and responses are **not logged by default**, so ordinary log
inspection does not expose prompt or response content. Never paste the master
key or an `Authorization: Bearer` header into logs, tickets, or chat.

## Updating images

```bash
./scripts/update-schai.sh
```

`update-schai.sh` records the running image IDs and each service's configured
image reference **before** pulling, pulls images, recreates only services whose
image changed, then runs health checks.

### Interpreting update rollback guidance

If health checks fail after an update, `update-schai.sh` exits non-zero and
prints ready-to-paste rollback commands for each changed service — it never
performs a rollback automatically. The guidance looks like:

```text
  # ollama — restore previously running image:
  docker tag <recorded-old-image-id> <configured-image-ref>
  docker compose --env-file ai/.env -f ai/compose.yaml up -d --no-deps --force-recreate ollama
```

Review the printed commands, then run them yourself to restore the previously
running image. If a service's old image ID or configured reference could not be
determined, the script prints a per-service warning instead of a misleading
command.

## Backups

```bash
./scripts/backup-config.sh
```

Creates a timestamped, sanitized archive under `backups/`
(`schott-platform-config-<timestamp>.tar.gz`) plus a `.sha256` checksum. The
archive contains tracked configuration, docs, scripts, sanitized `.env.example`
templates, the git HEAD, a **redacted** rendered Compose config, an Ollama model
inventory, and a manifest. It never contains `ai/.env`, real secrets, model
blobs, or logs.

### Verify the checksum

```bash
cd backups
sha256sum -c schott-platform-config-<timestamp>.tar.gz.sha256
```

### When the Ollama inventory is unavailable

If the Ollama container is not running when a backup is taken, the backup still
succeeds: the manifest and inventory file record an `UNAVAILABLE` status with
guidance to deploy and re-run the backup. No secrets or model blobs are
archived in that case.

## Model management

```bash
# List installed models
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama list

# Pull (or refresh) a required model
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:8b

# Remove a model you deliberately no longer need
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama rm <model>
```

The three required models are `qwen3:8b`, `qwen3:30b`, and `nomic-embed-text`.
Removing a required model will break the corresponding alias.

## Disk-space checks

Model blobs live in the `ollama-models` volume and can be large. Check space
before pulling models:

```bash
df -h /
docker system df
docker volume ls                 # model volume: ${OLLAMA_VOLUME_NAME:-schott-platform-ollama-models}
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama du -sh /root/.ollama
```

## GPU checks

```bash
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama nvidia-smi
```

The Tesla P4 should be listed with the Ollama process using it during inference.

## Safe restart procedures

```bash
# Restart a single service
docker compose --env-file ai/.env -f ai/compose.yaml restart litellm

# Restart the whole stack (preserves the model volume)
docker compose --env-file ai/.env -f ai/compose.yaml up -d
```

`restart` and `up -d` preserve the `ollama-models` volume. **Never delete** the
persistent model volume as a routine fix (see troubleshooting).

## Troubleshooting

### Unhealthy Ollama

```bash
docker compose --env-file ai/.env -f ai/compose.yaml ps
docker compose --env-file ai/.env -f ai/compose.yaml logs --tail=200 ollama
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama list
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama nvidia-smi
```

Common causes: GPU driver/toolkit problems (`nvidia-smi` fails inside the
container) or a cold start after restart. Restart the service; do not delete the
model volume.

### Unhealthy LiteLLM

```bash
docker compose --env-file ai/.env -f ai/compose.yaml logs --tail=200 litellm
```

LiteLLM depends on Ollama becoming healthy first. If LiteLLM refuses to start,
confirm `LITELLM_MASTER_KEY` is non-empty in `ai/.env`
(`bash scripts/validate-config.sh`) — it fails closed on an empty key.

### Authentication failures

A `401` (or `403`) from `/v1/models` or `/v1/chat/completions` means the request
lacked a valid `Authorization: Bearer <key>` header or the key does not match
`LITELLM_MASTER_KEY` in `ai/.env`. This is the intended fail-closed behavior.
Confirm the client is using the current key; rotate the key per
[../../security/SECURITY.md](../../security/SECURITY.md) if it may be exposed.

A **`400` with `"No connected db."`** is also a rejection, not a success. This
baseline runs LiteLLM without a key database, so the master key is the only key
it can verify; any other well-formed token cannot be looked up and is refused
with `400` instead of `401`. Access is still denied — no model data is returned.
Treat it exactly like a `401`: the client is using the wrong key.

Rejection codes by request shape:

| Request | Code | Meaning |
|---|---|---|
| No `Authorization` header | `401` | `Authentication Error, No api key passed in.` |
| Malformed header or empty bearer | `401` | `Malformed API Key passed in.` |
| Well-formed but wrong key | `400` | `No connected db.` — cannot verify, refused |
| Correct master key | `200` | Authorized |

`health-check.sh` asserts both paths: an unauthenticated request must return
`401`/`403`, and an invalid key must return `400`/`401`/`403`. Any `2xx` for an
invalid key is a hard failure — that would mean authentication is not failing
closed.

### Model-not-found failures

If a request for `local-fast`, `local-general`, or `local-embed` fails with a
model-not-found error, the backing model is not present in Ollama:

```bash
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama list
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:8b
```

### Do not delete the model volume as a routine fix

Deleting `ollama-models` forces a full re-download of every model and is never
an appropriate routine troubleshooting step. Reserve volume removal for
deliberate, documented recovery only.
