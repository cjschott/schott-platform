# Security Policy

Security policy for the Schott Platform AI Baseline (`cjschott/schott-platform`),
a private personal repository.

## Supported baseline and reporting

The supported baseline is the AI Platform Baseline for `schai` documented in
`docs/`. Because this is a private personal repository, there is no public
disclosure program. Report suspected security issues privately to the repository
owner (see the account associated with `cjschott/schott-platform`) and avoid
including real secrets in the report.

## Secrets: never commit `ai/.env`

- **Never commit** `ai/.env` or any real `.env` file. Only sanitized
  `*.env.example` templates are tracked. `.gitignore` enforces this and
  `tests/test-static.sh` asserts it.
- Never place the `LITELLM_MASTER_KEY` in Compose YAML, documentation, scripts,
  tickets, chat, or command history.

### Generation, storage, rotation, revocation

- **Generate** a strong, unique key, e.g. `openssl rand -hex 32`.
- **Store** it only in `ai/.env` under `/opt/schott-platform` with `chmod 600`
  and restricted ownership, plus your protected secret store.
- **Rotate** the key on a schedule and whenever staff/access changes.
- **Revoke** an old key by replacing it in `ai/.env` and recreating LiteLLM so
  the old value no longer authenticates.

## Response to an exposed LiteLLM master key

If the master key may have been exposed (committed, logged, pasted, or shared):

1. **Treat it as compromised immediately.**
2. **Review Git history and logs** for the exposure and its blast radius:
   ```bash
   git log -p -- ai/.env            # ai/.env must never appear; investigate if it does
   git log -S '<suspected-string>'  # search history for the leaked value
   ```
   Also review container/host logs and any external system the key was pasted
   into.
3. **Rotate the key** — generate a new `LITELLM_MASTER_KEY`, write it to
   `ai/.env` (`chmod 600`) without echoing it into history.
4. **Restart/recreate LiteLLM** so the new key takes effect:
   ```bash
   docker compose --env-file ai/.env -f ai/compose.yaml up -d --force-recreate litellm
   ```
5. **Validate that unauthenticated requests are rejected** and only the new key
   works:
   ```bash
   ./scripts/health-check.sh
   ```
   The check confirms unauthenticated `/v1/models` returns `401`/`403`, that an
   invalid key is refused (`400`/`401`/`403` — never `2xx`), and that
   authenticated access with the new key succeeds. A `400 "No connected db."`
   for a wrong key is a rejection, not a success: with no key database
   configured, LiteLLM can only verify the master key. The check fails hard if
   any invalid key is ever answered with `2xx`.
6. **Update all clients** to the new key and remove the old value from any
   store.

If a secret ever entered Git history, rotating the key is mandatory; purging
history (e.g. with `git filter-repo`) is secondary and does not substitute for
rotation.

## Prompt and response handling

Full prompts and responses are **not logged by default**
(`turn_off_message_logging: true` in `ai/litellm/config.yaml`). Only request
metadata (model alias, latency, token counts, success/failure) is emitted. Do
not enable full message logging on shared or production hosts without a
data-handling review, and never paste captured prompts/responses into tickets or
chat.

## Backups and checksum verification

`scripts/backup-config.sh` produces sanitized configuration backups only. The
rendered Compose config is redacted and re-checked so the master key can never
be archived; `ai/.env`, real secrets, model blobs, and logs are excluded.
Always verify a backup's integrity before trusting or restoring it:

```bash
sha256sum -c schott-platform-config-<timestamp>.tar.gz.sha256
```

## Dependency and image vulnerability response

- Container images are version-pinned (see `ai/.env.example` /
  `ai/compose.yaml`); review and update pins deliberately rather than tracking
  moving tags.
- Repository security automation (Gitleaks secret scanning, Trivy config/image
  scanning, Semgrep, Dependabot, and CodeQL where a supported language exists)
  is added in a later task. When a scan flags a vulnerable image or dependency,
  update the pin, re-run `scripts/validate-config.sh`, redeploy with
  `scripts/update-schai.sh`, and re-run `scripts/health-check.sh`.

## Responsible disclosure

For this private repository, handle findings internally: report privately to the
owner, do not publish exploit details, rotate any affected secret first, and
record the remediation. Do not include live keys, tokens, or captured
prompt/response content in any report.
