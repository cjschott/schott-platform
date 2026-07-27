# Hardening Checklist

Operational hardening checklist for the AI Platform Baseline on `schai`. Work
through it after installation and revisit it on the review cadence below. Items
are verification steps, not automated actions — repository scripts never change
host firewall or system settings.

## Host

- [ ] Ubuntu 24.04 is fully updated (`sudo apt update && sudo apt upgrade`).
- [ ] SSH is hardened (key-only auth, root login disabled, sensible timeouts).
- [ ] Administrative access is restricted to trusted management systems only.
- [ ] NVIDIA driver and Container Toolkit verified (`nvidia-smi`,
      `nvidia-ctk --version`).
- [ ] Docker daemon access is restricted (membership of the `docker` group is
      limited; it is equivalent to root).

## Secrets

- [ ] `ai/.env` exists only on the host with mode `600` and restricted
      ownership (`chmod 600 ai/.env`).
- [ ] `LITELLM_MASTER_KEY` is strong and unique (e.g. `openssl rand -hex 32`).
- [ ] A key-rotation schedule is defined and rotation has been rehearsed.
- [ ] No real `.env` file or key value exists anywhere in Git or its history.

## Network

- [ ] Port `4000/tcp` (LiteLLM) is restricted to approved application clients.
- [ ] Port `11434/tcp` (Ollama) is not externally exposed.
- [ ] UFW / host firewall rules verified at the host level (manual;
      see [../docs/security/network-policy.md](../docs/security/network-policy.md)).
- [ ] Docker published ports verified
      (`docker compose --env-file ai/.env -f ai/compose.yaml ps` shows only
      `4000` published, no `11434`).

## Services and logging

- [ ] Docker log rotation is active (`json-file` with `max-size`/`max-file`).
- [ ] Full prompt/response logging is disabled by default
      (`turn_off_message_logging: true`).
- [ ] No commercial/cloud provider fallback is configured.
- [ ] Container image versions are reviewed and pinned deliberately.

## Repository security automation

- [ ] Gitleaks secret scanning status reviewed (as applicable).
- [ ] Trivy config/image scanning status reviewed (as applicable).
- [ ] Semgrep static analysis status reviewed (as applicable).
- [ ] CodeQL status reviewed — enabled only where a supported language exists
      (as applicable).

## Backup and recovery

- [ ] A configuration backup has been created (`scripts/backup-config.sh`).
- [ ] The backup checksum validates
      (`sha256sum -c schott-platform-config-<timestamp>.tar.gz.sha256`).
- [ ] A recovery test has been performed from Git + protected secrets +
      model re-pull.
- [ ] Model data (blobs) is confirmed excluded from backups.

## Validation

- [ ] `bash tests/test-static.sh` passes (static).
- [ ] `bash scripts/validate-config.sh` passes.
- [ ] `./scripts/health-check.sh` passes (runtime).
- [ ] `./scripts/health-check.sh --deep` passes (runtime, extended).

## Review cadence

- [ ] This checklist and the image pins are reviewed on a periodic cadence
      (for example monthly) and after any incident or major change.
