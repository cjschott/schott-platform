# Recovery

Rebuild the AI Platform Baseline on `schai` from Git, protected secrets, and
model re-downloads. The configuration backup archive restores **sanitized
configuration only** — never secrets and never model blobs.

## Recovery order

Follow this order. Do not reconnect applications until validation succeeds.

1. **Restore or rebuild Ubuntu 24.04 host prerequisites** — Docker Engine,
   Docker Compose v2, the NVIDIA driver, and the NVIDIA Container Toolkit.
   Verify with `docker compose version` and `nvidia-smi`.
2. **Restore the repository to `/opt/schott-platform`** — clone
   `cjschott/schott-platform` (or extract a configuration backup archive, below).
3. **Restore or recreate `ai/.env` securely** — from protected storage, or
   generate a new key. Set `chmod 600 ai/.env`.
4. **Run static/config validation** — `bash scripts/validate-config.sh` and
   `bash tests/test-static.sh`.
5. **Start the stack** — `./scripts/deploy-schai.sh`.
6. **Re-pull the Ollama models** rather than restoring model blobs (commands
   below).
7. **Run normal health checks** — `./scripts/health-check.sh`.
8. **Run deep validation if appropriate** — `./scripts/health-check.sh --deep`.
9. **Reconnect applications only after validation succeeds** — confirm clients
   use `http://schai:4000/v1` and the current master key.

## Recovering from a configuration backup archive

A backup produced by `scripts/backup-config.sh` is a sanitized bundle plus a
SHA-256 checksum.

### Verify the checksum before extraction

```bash
cd backups
sha256sum -c schott-platform-config-<timestamp>.tar.gz.sha256
tar xzf schott-platform-config-<timestamp>.tar.gz
```

Only extract after the checksum verifies.

### What the archive contains — and does not

The archive contains **sanitized configuration, not secrets**: tracked Compose
files, LiteLLM config, scripts, docs, sanitized `.env.example` templates, the
recorded git HEAD, a redacted rendered Compose config, an Ollama model
inventory, and a manifest.

- `ai/.env` is **not** in the archive and **must be recreated separately** from
  protected storage or by generating a new key (step 3).
- **Model blobs** are intentionally excluded — the archive never contains
  downloaded model data. Re-pull models instead of restoring blobs.

## Re-pull the Ollama models

```bash
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:8b
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull qwen3:30b
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama pull nomic-embed-text
docker compose --env-file ai/.env -f ai/compose.yaml exec ollama ollama list
```

These restore `local-fast`, `local-general`, and `local-embed` respectively.

## Recovering from a failed image update

If `./scripts/update-schai.sh` reported failed health checks, it printed
ready-to-paste rollback commands for each changed service (it does **not** roll
back automatically). Re-pin each changed service to its previously running image
using the printed commands, for example:

```bash
docker tag <recorded-old-image-id> <configured-image-ref>
docker compose --env-file ai/.env -f ai/compose.yaml up -d --no-deps --force-recreate <service>
```

Then re-run `./scripts/health-check.sh`. If the recorded image ID or configured
reference was unavailable, recreate the service manually from a known-good image
tag defined in `ai/.env`.

## Secret rotation after suspected compromise

If the master key may have been exposed, rotate it as part of recovery:

1. Generate a new `LITELLM_MASTER_KEY` and write it to `ai/.env` (`chmod 600`),
   without printing it into shell history.
2. Recreate LiteLLM:
   `docker compose --env-file ai/.env -f ai/compose.yaml up -d --force-recreate litellm`.
3. Verify unauthenticated `/v1/models` is still rejected and authenticated
   requests use the new key: `./scripts/health-check.sh`.
4. Update every application/client to the new key.

See [../../security/SECURITY.md](../../security/SECURITY.md) for the full
incident procedure.

## What cannot be recovered from the configuration archive

The following **cannot be recovered** from a configuration backup and must be
handled separately:

- The `LITELLM_MASTER_KEY` and any real `ai/.env` — recreate from protected
  storage or rotate to a new key.
- Downloaded model blobs — re-pull from Ollama.
- Runtime container/log state and request history — not backed up by design.
