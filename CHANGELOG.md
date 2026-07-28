# Changelog

All notable changes to the Schott Platform are recorded here. This project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-28 — AI platform baseline

Initial reproducible baseline for the Schott AI platform on `schai`. Static and
`schai` runtime acceptance validation both passed; see
[docs/operations/acceptance-results.md](docs/operations/acceptance-results.md).

- Repository foundation: README, changelog, ignore rules, formatting defaults,
  and static repository test entry point.
- Ollama internal inference backend with NVIDIA GPU passthrough, pinned image,
  and rotating logs. Never published as an application endpoint.
- LiteLLM gateway as the only application-facing API (`http://schai:4000/v1`),
  failing closed on an empty master key, with the model aliases `local-fast`,
  `local-general`, and `local-embed`.
- Integrated stack (`ai/compose.yaml`) on a private `ai-backend` bridge network,
  publishing only port `4000`.
- Portable model storage: the Docker volume name is configurable via
  `OLLAMA_VOLUME_NAME`, with `OLLAMA_VOLUME_EXTERNAL` for adopting an existing
  volume, so clean installs and migrated hosts share one set of Compose files.
- Operations scripts: `validate-config.sh`, `deploy-schai.sh`, `update-schai.sh`,
  `health-check.sh` (with `--deep`), and `backup-config.sh`.
- Architecture, install, operations, recovery, network-policy, security, and
  hardening documentation.
- CI and security automation workflows with SHA-pinned actions, plus Dependabot
  configuration.

Accepted limitation: UFW does not reliably filter Docker-published port `4000`.
The host has no public address or NAT exposure, so port `4000` is reachable only
from the approved LAN. A persistent `DOCKER-USER` policy is deferred to a
separate network-hardening enhancement.
