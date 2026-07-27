# Local Validation

Every check that CI runs is reproducible on a workstation. **Passing local
validation should produce the same result as CI** — the workflows in
`.github/workflows/` invoke the same commands and tools documented here and
invent no CI-only behavior.

All commands run from the repository root. None of these validations require
`schai`, a running deployment, or a real secret — Compose is only *rendered*,
using the sanitized `ai/.env.example` template.

## Required checks (no extra tooling)

These need only Bash and Docker Compose v2, and mirror `ci.yml`:

```bash
# 1. Shell syntax of every script and the test file.
bash -n scripts/*.sh
bash -n tests/test-static.sh

# 2. Static repository assertions (contracts for Tasks 1–7).
bash tests/test-static.sh

# 3. Render every Compose file from the sanitized template (no secrets).
docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
docker compose --env-file ai/ollama/.env.example -f ai/ollama/compose.yaml config >/dev/null
docker compose --env-file ai/litellm/.env.example -f ai/litellm/compose.yaml config >/dev/null
```

`tests/test-static.sh` skips the Docker-dependent assertions gracefully when the
`docker` CLI is not installed, so it still runs anywhere; install Docker Compose
v2 to exercise the Compose checks exactly as CI does.

## Optional security tooling

These mirror the dedicated security workflows. They are **optional locally**
(install only what you need) but **required in CI**. Install via your package
manager or each tool's official instructions; this repository does not bundle
them.

### ShellCheck — `shellcheck.yml`

```bash
shellcheck scripts/*.sh tests/*.sh
```

Warnings are not suppressed globally. If a specific finding is a false positive,
add a scoped `# shellcheck disable=SCxxxx` with a justification in the script.

### Gitleaks — `gitleaks.yml`

```bash
gitleaks detect --source . --redact --verbose
```

Repository mode; nothing is allowlisted by default. A verified leak fails.

### Trivy — `trivy.yml`

```bash
trivy fs --severity HIGH,CRITICAL --exit-code 1 --skip-dirs backups,logs,models,data .
```

Filesystem scan of the repository for HIGH/CRITICAL findings. No image scanning
in this baseline.

### Semgrep — `semgrep.yml`

```bash
semgrep scan --config auto --error
```

Default security rules; findings fail the run.

### CodeQL — `codeql.yml`

CodeQL has **no analyzer for Bash/shell**, so it cannot be run against this
repository's current code and there is no local equivalent. `codeql.yml` is
scaffolded but disabled until a CodeQL-supported language is added; shell static
analysis is covered by ShellCheck and Semgrep above.

## Required vs optional summary

| Check | Tooling | Local | CI workflow |
|---|---|---|---|
| Shell syntax | Bash | Required | `ci.yml` |
| Static assertions | Bash (+ Docker for Compose parts) | Required | `ci.yml` |
| Compose render | Docker Compose v2 | Required | `ci.yml` |
| ShellCheck | `shellcheck` | Optional | `shellcheck.yml` |
| Gitleaks | `gitleaks` | Optional | `gitleaks.yml` |
| Trivy (fs) | `trivy` | Optional | `trivy.yml` |
| Semgrep | `semgrep` | Optional | `semgrep.yml` |
| CodeQL | — (n/a for shell) | n/a | `codeql.yml` (disabled) |

Run the required checks before every push; run the optional tools when changing
scripts, configuration, or dependencies. If they pass locally, they pass in CI.
