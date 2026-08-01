#!/usr/bin/env bash
set -Eeuo pipefail

# Static repository assertions for the Schott Platform AI baseline.
#
# This test is extended task-by-task. It must be runnable from anywhere and
# must not require the schai VM, Docker daemon access, or any secret.
#
# Scope currently implemented: Task 1 (foundation), Task 2 (Ollama service),
# Task 3 (LiteLLM gateway), Task 4 (integrated stack).

# Resolve repository root relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
}

# assert_file <relative-path>
assert_file() {
  local rel="$1"
  if [[ -f "${ROOT}/${rel}" ]]; then
    pass "file exists: ${rel}"
  else
    fail "required file missing: ${rel}"
  fi
}

# assert_dir <relative-path>
assert_dir() {
  local rel="$1"
  if [[ -d "${ROOT}/${rel}" ]]; then
    pass "directory exists: ${rel}"
  else
    fail "required directory missing: ${rel}"
  fi
}

# assert_ignored <relative-path>  — path must be excluded by .gitignore
assert_ignored() {
  local rel="$1"
  if git -C "${ROOT}" check-ignore -q "${rel}"; then
    pass "git-ignored: ${rel}"
  else
    fail "path should be git-ignored but is not: ${rel}"
  fi
}

# assert_not_ignored <relative-path>  — path must NOT be excluded by .gitignore
assert_not_ignored() {
  local rel="$1"
  if git -C "${ROOT}" check-ignore -q "${rel}"; then
    fail "path should NOT be git-ignored but is: ${rel}"
  else
    pass "not git-ignored: ${rel}"
  fi
}

# assert_contains <relative-path> <ERE> <description>  — file must match regex
assert_contains() {
  local rel="$1" re="$2" desc="$3"
  if [[ -f "${ROOT}/${rel}" ]] && grep -Eq "${re}" "${ROOT}/${rel}"; then
    pass "${desc}"
  else
    fail "${desc} (expected /${re}/ in ${rel})"
  fi
}

# refute_contains <relative-path> <ERE> <description>  — file must NOT match regex
refute_contains() {
  local rel="$1" re="$2" desc="$3"
  if [[ -f "${ROOT}/${rel}" ]] && grep -Eq "${re}" "${ROOT}/${rel}"; then
    fail "${desc} (unexpected /${re}/ in ${rel})"
  else
    pass "${desc}"
  fi
}

# assert_count <relative-path> <ERE> <expected-count> <description>
assert_count() {
  local rel="$1" re="$2" want="$3" desc="$4" got
  got=$(grep -Ec "${re}" "${ROOT}/${rel}" 2>/dev/null || true)
  got=${got:-0}
  if [[ "${got}" == "${want}" ]]; then
    pass "${desc}"
  else
    fail "${desc} (matched ${got}, want ${want} in ${rel})"
  fi
}

# assert_compose_parses <env-file> <compose-file> <description>
# Renders the Compose file to confirm it parses. Requires only the docker CLI
# (no daemon). Skips gracefully where docker is unavailable so the test stays
# runnable anywhere.
assert_compose_parses() {
  local envfile="$1" composefile="$2" desc="$3"
  if ! command -v docker >/dev/null 2>&1; then
    printf 'SKIP: %s (docker CLI not available)\n' "${desc}"
    return 0
  fi
  if docker compose --env-file "${ROOT}/${envfile}" -f "${ROOT}/${composefile}" config >/dev/null 2>&1; then
    pass "${desc}"
  else
    fail "${desc}"
  fi
}

# ---------------------------------------------------------------------------
# Task 1: Repository foundation
# ---------------------------------------------------------------------------

# Required top-level foundation files.
assert_file "README.md"
assert_file "CHANGELOG.md"
assert_file ".gitignore"
assert_file ".editorconfig"
assert_file "ai/README.md"
assert_file "tests/test-static.sh"

# Required foundation directories.
assert_dir "ai"
assert_dir "docs"
assert_dir "tests"

# Every shell script must declare the bash shebang and strict mode.
while IFS= read -r script; do
  first_line="$(head -n 1 "${script}")"
  if [[ "${first_line}" != "#!/usr/bin/env bash" ]]; then
    fail "shell script missing '#!/usr/bin/env bash' shebang: ${script#"${ROOT}/"}"
  elif ! grep -qE '^set -Eeuo pipefail$' "${script}"; then
    fail "shell script missing 'set -Eeuo pipefail': ${script#"${ROOT}/"}"
  else
    pass "shell script conforms to standards: ${script#"${ROOT}/"}"
  fi
done < <(find "${ROOT}" -type f -name '*.sh' -not -path '*/.git/*')

# Local environment files must be ignored.
assert_ignored ".env"
assert_ignored "ai/.env"
assert_ignored "ai/litellm/.env"
assert_ignored "ai/ollama/.env"

# Sanitized example env files must remain tracked.
assert_not_ignored "ai/.env.example"
assert_not_ignored "ai/litellm/.env.example"

# Secret, runtime, and model/data directories must be ignored.
assert_ignored "secrets/key"
assert_ignored "backups/backup.tar.gz"
assert_ignored "logs/litellm.log"
assert_ignored "models/blob"
assert_ignored "data/ollama/blob"
assert_ignored ".superpowers/state"

# ---------------------------------------------------------------------------
# Task 2: Captured Ollama service
# ---------------------------------------------------------------------------

OLLAMA_COMPOSE="ai/ollama/compose.yaml"

# Required Ollama files.
assert_file "ai/ollama/compose.yaml"
assert_file "ai/ollama/.env.example"
assert_file "ai/ollama/README.md"

# The sanitized example env must remain tracked.
assert_not_ignored "ai/ollama/.env.example"

# The Compose file must render/parse.
assert_compose_parses "ai/ollama/.env.example" "${OLLAMA_COMPOSE}" \
  "docker compose config parses: ${OLLAMA_COMPOSE}"

# The service is named 'ollama'.
assert_contains "${OLLAMA_COMPOSE}" '^[[:space:]]{2}ollama:[[:space:]]*$' \
  "ollama service is named 'ollama'"

# Image is version-pinned (explicit tag, not 'latest') via an env var with a
# documented default.
assert_contains "${OLLAMA_COMPOSE}" 'OLLAMA_IMAGE:-ollama/ollama:[0-9]' \
  "ollama image is version-pinned with a default"
refute_contains "${OLLAMA_COMPOSE}" 'ollama/ollama:latest' \
  "ollama image does not use the 'latest' tag"

# Restart policy.
assert_contains "${OLLAMA_COMPOSE}" 'restart:[[:space:]]*unless-stopped' \
  "ollama uses restart: unless-stopped"

# Persistent model storage mounted at /root/.ollama via a named volume.
assert_contains "${OLLAMA_COMPOSE}" 'ollama-models:/root/\.ollama' \
  "ollama model storage mounted at /root/.ollama"
assert_contains "${OLLAMA_COMPOSE}" '^volumes:[[:space:]]*$' \
  "ollama declares a named volume section"
assert_contains "${OLLAMA_COMPOSE}" '^[[:space:]]{2}ollama-models:' \
  "ollama-models named volume is declared"

# NVIDIA GPU access is declared.
assert_contains "${OLLAMA_COMPOSE}" 'driver:[[:space:]]*nvidia' \
  "ollama declares the nvidia GPU driver"
assert_contains "${OLLAMA_COMPOSE}" 'capabilities:[[:space:]]*\[[[:space:]]*gpu' \
  "ollama declares the gpu capability"

# Health check uses the bundled ollama binary (guaranteed present), not curl.
assert_contains "${OLLAMA_COMPOSE}" 'ollama list' \
  "ollama health check uses the bundled ollama binary"
refute_contains "${OLLAMA_COMPOSE}" 'test:.*curl' \
  "ollama health check command does not depend on curl"

# Port 11434 is bound to localhost only — never all interfaces. The mapping
# uses the ${OLLAMA_BIND_ADDRESS:-127.0.0.1} default, so the localhost IP sits
# just before the closing brace of the substitution.
assert_contains "${OLLAMA_COMPOSE}" ':-127\.0\.0\.1[}]:11434:11434' \
  "ollama port defaults to localhost binding"
refute_contains "${OLLAMA_COMPOSE}" '0\.0\.0\.0' \
  "ollama port is not published to all interfaces"

# JSON-file logging with rotation limits.
assert_contains "${OLLAMA_COMPOSE}" 'driver:[[:space:]]*json-file' \
  "ollama uses the json-file logging driver"
assert_contains "${OLLAMA_COMPOSE}" 'max-size:' \
  "ollama logging sets max-size"
assert_contains "${OLLAMA_COMPOSE}" 'max-file:' \
  "ollama logging sets max-file"

# The env example carries the required non-secret settings.
assert_contains "ai/ollama/.env.example" '^TZ=America/Chicago' \
  "ollama .env.example sets TZ=America/Chicago"
assert_contains "ai/ollama/.env.example" '^OLLAMA_IMAGE=' \
  "ollama .env.example sets OLLAMA_IMAGE"
assert_contains "ai/ollama/.env.example" 'OLLAMA_BIND_ADDRESS' \
  "ollama .env.example documents the optional bind address"

# The README documents the required model pulls and GPU verification.
assert_contains "ai/ollama/README.md" 'qwen3:8b' \
  "ollama README documents qwen3:8b pull"
assert_contains "ai/ollama/README.md" 'qwen3:30b' \
  "ollama README documents qwen3:30b pull"
assert_contains "ai/ollama/README.md" 'nomic-embed-text' \
  "ollama README documents nomic-embed-text pull"
assert_contains "ai/ollama/README.md" 'nvidia-smi' \
  "ollama README documents nvidia-smi GPU verification"

# ---------------------------------------------------------------------------
# Task 3: LiteLLM gateway
# ---------------------------------------------------------------------------

LITELLM_COMPOSE="ai/litellm/compose.yaml"
LITELLM_CONFIG="ai/litellm/config.yaml"

# Required LiteLLM files.
assert_file "ai/litellm/compose.yaml"
assert_file "ai/litellm/config.yaml"
assert_file "ai/litellm/.env.example"
assert_file "ai/litellm/README.md"

# The sanitized example env must remain tracked.
assert_not_ignored "ai/litellm/.env.example"

# The Compose file must render/parse using the example env.
assert_compose_parses "ai/litellm/.env.example" "${LITELLM_COMPOSE}" \
  "docker compose config parses: ${LITELLM_COMPOSE}"

# Each of the three aliases is defined exactly once.
assert_count "${LITELLM_CONFIG}" 'model_name:[[:space:]]*local-fast[[:space:]]*$' 1 \
  "alias local-fast defined exactly once"
assert_count "${LITELLM_CONFIG}" 'model_name:[[:space:]]*local-general[[:space:]]*$' 1 \
  "alias local-general defined exactly once"
assert_count "${LITELLM_CONFIG}" 'model_name:[[:space:]]*local-embed[[:space:]]*$' 1 \
  "alias local-embed defined exactly once"

# Aliases map to the exact backend model names.
assert_contains "${LITELLM_CONFIG}" 'model:[[:space:]]*ollama/qwen3:8b[[:space:]]*$' \
  "local-fast maps to ollama/qwen3:8b"
assert_contains "${LITELLM_CONFIG}" 'model:[[:space:]]*ollama/qwen3:30b[[:space:]]*$' \
  "local-general maps to ollama/qwen3:30b"
assert_contains "${LITELLM_CONFIG}" 'model:[[:space:]]*ollama/nomic-embed-text[[:space:]]*$' \
  "local-embed maps to ollama/nomic-embed-text"

# Ollama base URL is resolved by LiteLLM from its own environment (os.environ/),
# not the Compose ${VAR} form — Compose does not interpolate a mounted config.
assert_count "${LITELLM_CONFIG}" 'api_base:[[:space:]]*os\.environ/OLLAMA_BASE_URL' 3 \
  "all three api_base entries use os.environ/OLLAMA_BASE_URL"
refute_contains "${LITELLM_CONFIG}" '\$\{OLLAMA_BASE_URL\}' \
  "config.yaml does not rely on Compose \${OLLAMA_BASE_URL} substitution"
assert_contains "ai/litellm/.env.example" '^OLLAMA_BASE_URL=http://ollama:11434[[:space:]]*$' \
  "OLLAMA_BASE_URL points to the internal ollama:11434 backend"

# Master key is referenced from the environment and never hard-coded.
assert_contains "${LITELLM_CONFIG}" 'master_key:[[:space:]]*os\.environ/LITELLM_MASTER_KEY' \
  "master key is read from the environment"
refute_contains "${LITELLM_CONFIG}" 'sk-[A-Za-z0-9]{16,}' \
  "no hard-coded key-like secret in config"

# Authentication fails closed when the master key is unset.
assert_contains "${LITELLM_COMPOSE}" 'LITELLM_MASTER_KEY:\?' \
  "LiteLLM fails closed without a master key"

# Full prompt/response logging is disabled by default.
assert_contains "${LITELLM_CONFIG}" 'turn_off_message_logging:[[:space:]]*true' \
  "full prompt/response logging is disabled by default"

# Port 4000 is configurable and published.
assert_contains "${LITELLM_COMPOSE}" 'LITELLM_PORT:-4000' \
  "LiteLLM port is configurable (defaults to 4000)"
assert_contains "${LITELLM_COMPOSE}" ':4000"' \
  "LiteLLM publishes container port 4000"

# Config is mounted read-only and the image is version-pinned.
assert_contains "${LITELLM_COMPOSE}" 'config\.yaml:/etc/litellm/config\.yaml:ro' \
  "LiteLLM config is mounted read-only"
assert_contains "${LITELLM_COMPOSE}" 'LITELLM_IMAGE:-ghcr\.io/berriai/litellm:' \
  "LiteLLM image is version-pinned with a default"
refute_contains "${LITELLM_COMPOSE}" 'berriai/litellm:main-latest' \
  "LiteLLM image does not use the moving 'main-latest' tag"

# Logs rotate.
assert_contains "${LITELLM_COMPOSE}" 'driver:[[:space:]]*json-file' \
  "LiteLLM uses the json-file logging driver"
assert_contains "${LITELLM_COMPOSE}" 'max-size:' \
  "LiteLLM logging sets max-size"
assert_contains "${LITELLM_COMPOSE}" 'max-file:' \
  "LiteLLM logging sets max-file"

# The README documents authenticated client usage.
assert_contains "ai/litellm/README.md" '/v1/models' \
  "LiteLLM README documents /v1/models"
assert_contains "ai/litellm/README.md" '/v1/chat/completions' \
  "LiteLLM README documents /v1/chat/completions"
assert_contains "ai/litellm/README.md" '/v1/embeddings' \
  "LiteLLM README documents /v1/embeddings"
assert_contains "ai/litellm/README.md" 'Authorization: Bearer' \
  "LiteLLM README documents bearer-token authentication"

# ---------------------------------------------------------------------------
# Task 4: Integrated AI stack
# ---------------------------------------------------------------------------

AI_COMPOSE="ai/compose.yaml"

# Required integrated-stack files.
assert_file "ai/compose.yaml"
assert_file "ai/.env.example"

# The sanitized example env must remain tracked.
assert_not_ignored "ai/.env.example"

# The integrated Compose file must render/parse using the example env.
assert_compose_parses "ai/.env.example" "${AI_COMPOSE}" \
  "docker compose config parses: ${AI_COMPOSE}"

# Self-contained: no Compose `extends` across the isolated service files.
refute_contains "${AI_COMPOSE}" '^[[:space:]]*extends:' \
  "integrated stack does not use Compose extends"

# Services are named exactly ollama and litellm.
assert_contains "${AI_COMPOSE}" '^[[:space:]]{2}ollama:[[:space:]]*$' \
  "integrated stack defines service 'ollama'"
assert_contains "${AI_COMPOSE}" '^[[:space:]]{2}litellm:[[:space:]]*$' \
  "integrated stack defines service 'litellm'"

# Ollama is NOT published to the host (no 11434 host mapping anywhere).
refute_contains "${AI_COMPOSE}" '11434:11434' \
  "ollama does not publish port 11434 to the host"

# LiteLLM publishes the exact configurable 4000 mapping.
assert_contains "${AI_COMPOSE}" 'LITELLM_BIND_ADDRESS:-0\.0\.0\.0' \
  "LiteLLM host bind address is configurable (defaults to 0.0.0.0)"
assert_contains "${AI_COMPOSE}" 'LITELLM_PORT:-4000\}:4000' \
  "LiteLLM publishes port 4000 (configurable)"

# LiteLLM depends on Ollama becoming healthy.
assert_contains "${AI_COMPOSE}" 'condition:[[:space:]]*service_healthy' \
  "LiteLLM depends on Ollama service_healthy"

# Both services share one private bridge network named ai-backend.
assert_contains "${AI_COMPOSE}" '^networks:[[:space:]]*$' \
  "integrated stack declares a networks section"
assert_contains "${AI_COMPOSE}" '^[[:space:]]{2}ai-backend:[[:space:]]*$' \
  "the ai-backend network is declared"
assert_contains "${AI_COMPOSE}" 'driver:[[:space:]]*bridge' \
  "ai-backend is a bridge network"
assert_count "${AI_COMPOSE}" '^[[:space:]]*-[[:space:]]*ai-backend[[:space:]]*$' 2 \
  "both services attach to ai-backend"

# Persistent named volume ollama-models mounted at /root/.ollama.
assert_contains "${AI_COMPOSE}" 'ollama-models:/root/\.ollama' \
  "ollama model storage mounted at /root/.ollama"
assert_contains "${AI_COMPOSE}" '^volumes:[[:space:]]*$' \
  "integrated stack declares a named volume section"
assert_contains "${AI_COMPOSE}" '^[[:space:]]{2}ollama-models:' \
  "ollama-models named volume is declared"

# NVIDIA GPU access preserved for Ollama.
assert_contains "${AI_COMPOSE}" 'driver:[[:space:]]*nvidia' \
  "integrated stack declares the nvidia GPU driver"
assert_contains "${AI_COMPOSE}" 'capabilities:[[:space:]]*\[[[:space:]]*gpu' \
  "integrated stack declares the gpu capability"

# Rotating logs for BOTH services.
assert_count "${AI_COMPOSE}" 'driver:[[:space:]]*json-file' 2 \
  "both services use the json-file logging driver"
assert_count "${AI_COMPOSE}" 'max-size:' 2 \
  "both services set a log max-size"
assert_count "${AI_COMPOSE}" 'max-file:' 2 \
  "both services set a log max-file"

# Fail-closed master-key handling: the key passes through for static rendering
# (empty-renderable), and the container itself refuses to start when it is empty
# — the guard runs before LiteLLM launches. No fallback/predictable key.
assert_contains "${AI_COMPOSE}" 'LITELLM_MASTER_KEY:[[:space:]]*\$\{LITELLM_MASTER_KEY-\}' \
  "master key passes through from the environment (empty-renderable)"
# shellcheck disable=SC2016  # '$$' is Compose's literal escape, matched as text
assert_contains "${AI_COMPOSE}" '\-z "\$\$LITELLM_MASTER_KEY"' \
  "startup guard checks LITELLM_MASTER_KEY is non-empty inside the container"
assert_contains "${AI_COMPOSE}" 'exit 1' \
  "startup guard exits non-zero when the master key is empty"
assert_contains "${AI_COMPOSE}" 'exec litellm' \
  "startup execs LiteLLM after the guard"
refute_contains "${AI_COMPOSE}" 'LITELLM_MASTER_KEY-[^}]' \
  "no predictable fallback master key is substituted"

# The guard (and its non-zero exit) must precede the exec of LiteLLM.
# shellcheck disable=SC2016  # '$$' is Compose's literal escape, matched as text
guard_line=$(grep -n -- '-z "\$\$LITELLM_MASTER_KEY"' "${ROOT}/${AI_COMPOSE}" | head -1 | cut -d: -f1)
exit_line=$(grep -n 'exit 1' "${ROOT}/${AI_COMPOSE}" | head -1 | cut -d: -f1)
exec_line=$(grep -n 'exec litellm' "${ROOT}/${AI_COMPOSE}" | head -1 | cut -d: -f1)
if [[ -n "${guard_line}" && -n "${exit_line}" && -n "${exec_line}" \
      && "${guard_line}" -lt "${exec_line}" && "${exit_line}" -lt "${exec_line}" ]]; then
  pass "master-key guard and non-zero exit precede exec of LiteLLM"
else
  fail "master-key guard/exit must precede exec of LiteLLM (guard=${guard_line:-?} exit=${exit_line:-?} exec=${exec_line:-?})"
fi

assert_contains "${AI_COMPOSE}" 'litellm/config\.yaml:/etc/litellm/config\.yaml:ro' \
  "integrated LiteLLM mounts the shared config read-only"

# Ollama backend URL is provided as a Compose env var (config.yaml resolves it
# via os.environ) — never hard-coded away from the internal hostname.
assert_contains "${AI_COMPOSE}" 'OLLAMA_BASE_URL:[[:space:]]*\$\{OLLAMA_BASE_URL:-http://ollama:11434\}' \
  "integrated stack sets OLLAMA_BASE_URL to the internal ollama:11434"

# ai/.env.example: non-secret defaults with an EMPTY master-key placeholder.
assert_contains "ai/.env.example" '^LITELLM_MASTER_KEY=[[:space:]]*$' \
  "ai/.env.example ships an empty LITELLM_MASTER_KEY placeholder"
assert_contains "ai/.env.example" '^OLLAMA_BASE_URL=http://ollama:11434[[:space:]]*$' \
  "ai/.env.example sets OLLAMA_BASE_URL to ollama:11434"
assert_contains "ai/.env.example" '^TZ=America/Chicago' \
  "ai/.env.example sets TZ=America/Chicago"
refute_contains "ai/.env.example" 'sk-[A-Za-z0-9]{16,}' \
  "ai/.env.example contains no real key"

# ai/README.md identifies ai/compose.yaml as the canonical production stack.
assert_contains "ai/README.md" 'canonical' \
  "ai/README.md identifies the canonical production stack"

# ---------------------------------------------------------------------------
# Rendered integrated-stack checks (require docker CLI; skipped otherwise)
# ---------------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  RENDERED="$(docker compose --env-file "${ROOT}/ai/.env.example" -f "${ROOT}/${AI_COMPOSE}" config 2>/dev/null || true)"
  if grep -Eq 'published:[[:space:]]*"?4000"?' <<<"${RENDERED}"; then
    pass "rendered: LiteLLM publishes port 4000"
  else
    fail "rendered: LiteLLM does not publish port 4000"
  fi
  if grep -Eq 'published:[[:space:]]*"?11434"?' <<<"${RENDERED}"; then
    fail "rendered: Ollama must not publish a host port"
  else
    pass "rendered: Ollama has no published host port"
  fi
else
  printf 'SKIP: rendered integrated-stack checks (docker CLI not available)\n'
fi

# ---------------------------------------------------------------------------
# Task 5: Operations scripts (validate, deploy, update, health-check, backup)
# ---------------------------------------------------------------------------

# Literal secret used only inside behavior stubs. It must never appear in any
# script output. (It is not a real key.)
T5_SENTINEL_KEY="sk-behaviortest-DO-NOT-LOG-123"

TASK5_SCRIPTS=(
  "scripts/validate-config.sh"
  "scripts/deploy-schai.sh"
  "scripts/update-schai.sh"
  "scripts/health-check.sh"
  "scripts/backup-config.sh"
)

assert_dir "scripts"

# assert_executable <relative-path> — trusts the git index mode (100755) when
# tracked (portable across platforms where core.fileMode is false), and falls
# back to a filesystem test for not-yet-committed files.
assert_executable() {
  local rel="$1" mode
  mode="$(git -C "${ROOT}" ls-files -s -- "${rel}" 2>/dev/null | awk '{print $1}')"
  if [[ "${mode}" == "100755" ]]; then
    pass "executable (git mode 100755): ${rel}"
  elif [[ -x "${ROOT}/${rel}" ]]; then
    pass "executable (filesystem +x): ${rel}"
  else
    fail "script is not executable: ${rel} (git mode='${mode:-none}')"
  fi
}

# assert_in <haystack> <needle> <description>
assert_in() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2')"; fi
}

# refute_in <haystack> <needle> <description>
refute_in() {
  if [[ "$1" == *"$2"* ]]; then fail "$3 (found forbidden '$2')"; else pass "$3"; fi
}

# Per-script structural assertions.
for s in "${TASK5_SCRIPTS[@]}"; do
  assert_file "${s}"
  assert_executable "${s}"
  assert_contains "${s}" 'BASH_SOURCE\[0\]' \
    "resolves paths from its own location: ${s}"
  # A script may READ the master key but must never echo/printf its value.
  refute_contains "${s}" 'echo[^#]*\$\{?LITELLM_MASTER_KEY' \
    "does not echo LITELLM_MASTER_KEY value: ${s}"
  refute_contains "${s}" 'printf[^#]*\$\{?LITELLM_MASTER_KEY' \
    "does not printf LITELLM_MASTER_KEY value: ${s}"
done

# Uses the canonical stack and local secret file, never the example for deploy.
assert_contains "scripts/validate-config.sh" 'ai/compose\.yaml' \
  "validate-config targets ai/compose.yaml"
assert_contains "scripts/validate-config.sh" 'ai/\.env' \
  "validate-config references the local secret file ai/.env"
assert_contains "scripts/validate-config.sh" 'LITELLM_MASTER_KEY' \
  "validate-config checks the master key"
assert_contains "scripts/validate-config.sh" 'bash -n' \
  "validate-config validates shell syntax"

assert_contains "scripts/deploy-schai.sh" 'validate-config\.sh' \
  "deploy calls validate-config.sh"
assert_contains "scripts/deploy-schai.sh" 'pull' \
  "deploy pulls images"
assert_contains "scripts/deploy-schai.sh" 'up -d' \
  "deploy starts services detached"
assert_contains "scripts/deploy-schai.sh" 'health-check\.sh' \
  "deploy runs health-check.sh"

assert_contains "scripts/update-schai.sh" 'inspect' \
  "update inspects running image IDs"
assert_contains "scripts/update-schai.sh" 'pull' \
  "update pulls images"
assert_contains "scripts/update-schai.sh" 'health-check\.sh' \
  "update runs health checks"
assert_contains "scripts/update-schai.sh" 'ollback' \
  "update prints rollback guidance on health failure"
assert_contains "scripts/update-schai.sh" '\.Config\.Image' \
  "update records each service's configured image reference"
refute_contains "scripts/update-schai.sh" '<image-ref-for' \
  "update emits no unresolved image-ref placeholder"

assert_contains "scripts/health-check.sh" '/health/liveliness' \
  "health-check probes LiteLLM liveness"
assert_contains "scripts/health-check.sh" '/v1/models' \
  "health-check queries /v1/models"
assert_contains "scripts/health-check.sh" '/v1/chat/completions' \
  "health-check exercises a completion"
assert_contains "scripts/health-check.sh" '/v1/embeddings' \
  "health-check exercises an embedding"
assert_contains "scripts/health-check.sh" 'local-general' \
  "health-check verifies local-general inventory"
assert_contains "scripts/health-check.sh" '\-\-deep' \
  "health-check supports --deep"
assert_contains "scripts/health-check.sh" '\-\-max-time' \
  "health-check bounds curl with --max-time"
assert_contains "scripts/health-check.sh" '401.*403|403.*401' \
  "health-check treats 401/403 as the unauthenticated rejection"
# An invalid key must also be rejected. 400 is accepted because this baseline
# runs with no key database (LiteLLM answers "No connected db."), which is still
# fail-closed — but a 2xx must always fail the check.
assert_contains "scripts/health-check.sh" 'invalid API key' \
  "health-check probes an invalid API key"
# The probe token is deliberately fake. It must not LOOK like a credential, or
# secret scanners flag it — an `sk-` prefix with high entropy trips Gitleaks'
# generic-api-key rule. Keep it well-formed as a bearer value but obviously
# non-secret.
assert_contains "scripts/health-check.sh" 'INVALID_KEY="invalid-health-probe-token"' \
  "invalid-key probe uses an obviously non-secret value"
refute_contains "scripts/health-check.sh" 'INVALID_KEY="sk-' \
  "invalid-key probe does not use a credential-like sk- prefix"
assert_contains "scripts/health-check.sh" '"400".*"401".*"403"' \
  "health-check accepts 400/401/403 as an invalid-key rejection"
assert_contains "scripts/health-check.sh" 'is_2xx "\$\{code\}"; then' \
  "health-check fails when an invalid key is accepted (2xx)"

assert_contains "scripts/backup-config.sh" 'ls-files' \
  "backup builds its inventory from git ls-files"
refute_contains "scripts/backup-config.sh" 'cp -R' \
  "backup does not recursively copy working-tree directories"

assert_contains "scripts/backup-config.sh" 'tar' \
  "backup creates a tar archive"
assert_contains "scripts/backup-config.sh" 'sha256' \
  "backup writes a SHA-256 checksum"
assert_contains "scripts/backup-config.sh" 'rev-parse HEAD' \
  "backup records git HEAD"
assert_contains "scripts/backup-config.sh" 'REDACTED' \
  "backup sanitizes the rendered compose config"

# ---------------------------------------------------------------------------
# Task 5 behavior tests — stubbed commands + temp dirs; no daemon/secret needed.
# Guarded by a local errexit disable so a single failing probe cannot abort the
# whole suite.
# ---------------------------------------------------------------------------

TASK5_TMP=()
t5_new_repo() {
  local t; t="$(mktemp -d)"; TASK5_TMP+=("${t}")
  mkdir -p "${t}/scripts" "${t}/ai/litellm" "${t}/docs" "${t}/bin"
  cp "${ROOT}/scripts/"*.sh "${t}/scripts/" 2>/dev/null || true
  cp "${ROOT}/ai/compose.yaml" "${t}/ai/compose.yaml" 2>/dev/null || true
  cp "${ROOT}/ai/.env.example" "${t}/ai/.env.example" 2>/dev/null || true
  cp "${ROOT}/ai/litellm/config.yaml" "${t}/ai/litellm/config.yaml" 2>/dev/null || true
  printf '%s' "${t}"
}

t5_write_env() {  # <repo> [key]
  local t="$1" key="${2-${T5_SENTINEL_KEY}}"
  cat >"${t}/ai/.env" <<EOF
TZ=America/Chicago
OLLAMA_IMAGE=ollama/ollama:0.11.4
LITELLM_IMAGE=ghcr.io/berriai/litellm:main-v1.74.3-stable
OLLAMA_BASE_URL=http://ollama:11434
LITELLM_PORT=4000
LITELLM_BIND_ADDRESS=0.0.0.0
LOG_LEVEL=INFO
LITELLM_MASTER_KEY=${key}
EOF
}

# Stub `docker` that succeeds for every subcommand (validate/backup path).
t5_stub_docker_ok() {  # <repo>
  cat >"$1/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$1/bin/docker"
}

# Smart `curl` stub for health-check: logs URL + auth flag, returns canned JSON.
t5_stub_curl() {  # <repo>
  cat >"$1/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; wfmt=""; url=""; auth=0; data=""
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -o) i=$((i+1)); out="${args[$i]}";;
    -H) i=$((i+1))
        if [[ "${args[$i]}" == Authorization:* ]]; then
          # auth=1 the real master key, auth=2 the invalid-key probe.
          if [[ "${args[$i]}" == *invalid-health-probe-token* ]]; then auth=2; else auth=1; fi
        fi;;
    -d|--data|--data-raw|--data-binary) i=$((i+1)); data="${args[$i]}";;
    -w) i=$((i+1)); wfmt="${args[$i]}";;
    http://*|https://*) url="$a";;
  esac
  i=$((i+1))
done
printf '%s auth=%d\n' "$url" "$auth" >> "${CURL_LOG:-/dev/null}"
code=200
case "$url" in
  */health/liveliness) body='{"status":"connected"}';;
  */v1/models)
    if (( auth == 1 )); then body='{"data":[{"id":"local-fast"},{"id":"local-general"},{"id":"local-embed"}]}'
    elif (( auth == 2 )); then body='{"error":{"message":"No connected db.","code":"400"}}'; code=400
    else body='{"error":"authentication required"}'; code=401; fi;;
  */v1/chat/completions) body='{"choices":[{"message":{"content":"pong"}}]}';;
  */v1/embeddings) body='{"data":[{"embedding":[0.11,0.22,0.33]}]}';;
  *) body='{}'; code=404;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
[[ -n "$wfmt" ]] && printf '%s' "$code"
exit 0
EOF
  chmod +x "$1/bin/curl"
}

t5_run() {  # <repo> <script-rel> <env-assignments...> -- runs and stores rc/out
  local t="$1" rel="$2"; shift 2
  T5_OUT="$(PATH="${t}/bin:${PATH}" env "$@" bash "${t}/${rel}" 2>&1)"
  T5_RC=$?
}

# --- Behavior 1: validate-config refuses a missing ai/.env ------------------
t5_b_validate_missing_env() {
  if [[ ! -f "${ROOT}/scripts/validate-config.sh" ]]; then
    fail "behavior: validate-config.sh absent (missing-env test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_docker_ok "${t}"
  t5_run "${t}" "scripts/validate-config.sh"
  if (( T5_RC != 0 )); then
    pass "behavior: validate-config fails without ai/.env"
  else
    fail "behavior: validate-config must fail without ai/.env"
  fi
  assert_in "${T5_OUT}" "ai/.env" "behavior: validate-config error names ai/.env"
}

# --- Behavior 2: validate-config refuses an empty master key ----------------
t5_b_validate_empty_key() {
  if [[ ! -f "${ROOT}/scripts/validate-config.sh" ]]; then
    fail "behavior: validate-config.sh absent (empty-key test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_docker_ok "${t}"; t5_write_env "${t}" ""
  t5_run "${t}" "scripts/validate-config.sh"
  if (( T5_RC != 0 )); then
    pass "behavior: validate-config fails on empty LITELLM_MASTER_KEY"
  else
    fail "behavior: validate-config must fail on empty LITELLM_MASTER_KEY"
  fi
  assert_in "${T5_OUT}" "LITELLM_MASTER_KEY" \
    "behavior: empty-key error names LITELLM_MASTER_KEY"
}

# --- Behavior 3: supplied key never leaks into script output ----------------
t5_b_no_key_leak() {
  if [[ ! -f "${ROOT}/scripts/validate-config.sh" || ! -f "${ROOT}/scripts/health-check.sh" ]]; then
    fail "behavior: scripts absent (no-key-leak test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_docker_ok "${t}"; t5_stub_curl "${t}"
  t5_write_env "${t}" "${T5_SENTINEL_KEY}"
  t5_run "${t}" "scripts/validate-config.sh"
  refute_in "${T5_OUT}" "${T5_SENTINEL_KEY}" \
    "behavior: validate-config output hides the master key"
  t5_run "${t}" "scripts/health-check.sh" "CURL_LOG=${t}/curl.log"
  refute_in "${T5_OUT}" "${T5_SENTINEL_KEY}" \
    "behavior: health-check output hides the master key"
}

# --- Behavior 4: deploy health wait is bounded (does not hang) --------------
t5_b_deploy_bounded_wait() {
  if [[ ! -f "${ROOT}/scripts/deploy-schai.sh" ]]; then
    fail "behavior: deploy-schai.sh absent (bounded-wait test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_write_env "${t}"
  # docker stub: pull/up/config/version ok; ps returns a cid; inspect never healthy.
  cat >"${t}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "compose" ]]; then
  shift; sub=""
  while (( $# )); do
    case "$1" in version|pull|config|up|ps|exec) sub="$1"; break;; esac
    shift
  done
  case "$sub" in
    ps) echo "cid-not-healthy";;
    *) : ;;
  esac
  exit 0
elif [[ "$1" == "inspect" ]]; then
  echo "starting"; exit 0
fi
exit 0
EOF
  chmod +x "${t}/bin/docker"
  t5_run "${t}" "scripts/deploy-schai.sh" \
    "DEPLOY_TIMEOUT_SECONDS=2" "DEPLOY_POLL_SECONDS=1"
  if (( T5_RC != 0 )); then
    pass "behavior: deploy fails (bounded) when services never become healthy"
  else
    fail "behavior: deploy must fail when health wait times out"
  fi
  assert_in "${T5_OUT}" "timed out" \
    "behavior: deploy reports a bounded health-wait timeout"
}

# --- Behavior 5: health-check issues the expected ordered requests ----------
t5_b_health_ordering() {
  if [[ ! -f "${ROOT}/scripts/health-check.sh" ]]; then
    fail "behavior: health-check.sh absent (ordering test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_curl "${t}"; t5_write_env "${t}"
  local log="${t}/curl.log"; : > "${log}"
  t5_run "${t}" "scripts/health-check.sh" "CURL_LOG=${log}"
  if (( T5_RC == 0 )); then
    pass "behavior: health-check passes against stubbed LiteLLM"
  else
    fail "behavior: health-check should pass against a healthy stub (rc=${T5_RC})"
  fi
  mapfile -t L < "${log}" 2>/dev/null || L=()
  assert_in "${L[0]:-}" "/health/liveliness" "behavior: check 1 is liveness"
  assert_in "${L[1]:-}" "/v1/models auth=0"  "behavior: check 2 is unauth /v1/models"
  assert_in "${L[2]:-}" "/v1/models auth=2"  "behavior: check 2b probes an invalid key"
  assert_in "${L[3]:-}" "/v1/models auth=1"  "behavior: check 3 is auth /v1/models"
  assert_in "${L[4]:-}" "/v1/chat/completions" "behavior: check 4 is a completion"
  assert_in "${L[5]:-}" "/v1/embeddings"     "behavior: check 5 is an embedding"
}

# --- Behavior 5b: health-check rejects a gateway that ACCEPTS an invalid key -
# Guards the widened 400/401/403 acceptance from silently permitting a 2xx.
t5_b_health_invalid_key_accepted() {
  if [[ ! -f "${ROOT}/scripts/health-check.sh" ]]; then
    fail "behavior: health-check.sh absent (invalid-key test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_curl "${t}"; t5_write_env "${t}"
  # Re-stub curl so ANY bearer token — including the invalid probe — returns 200.
  cat >"${t}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; wfmt=""; url=""; auth=0; a=("$@"); i=0
while (( i < ${#a[@]} )); do
  case "${a[$i]}" in
    -o) i=$((i+1)); out="${a[$i]}";;
    -H) i=$((i+1)); [[ "${a[$i]}" == Authorization:* ]] && auth=1;;
    -w) i=$((i+1)); wfmt="${a[$i]}";;
    http://*|https://*) url="${a[$i]}";;
  esac
  i=$((i+1))
done
code=200
case "$url" in
  */health/liveliness) body='{"status":"connected"}';;
  */v1/models)
    if (( auth )); then body='{"data":[{"id":"local-fast"},{"id":"local-general"},{"id":"local-embed"}]}'
    else body='{"error":"authentication required"}'; code=401; fi;;
  */v1/chat/completions) body='{"choices":[{"message":{"content":"pong"}}]}';;
  */v1/embeddings) body='{"data":[{"embedding":[0.11,0.22]}]}';;
  *) body='{}'; code=404;;
esac
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
[[ -n "$wfmt" ]] && printf '%s' "$code"
exit 0
EOF
  chmod +x "${t}/bin/curl"
  t5_run "${t}" "scripts/health-check.sh"
  if (( T5_RC != 0 )); then
    pass "behavior: health-check fails when an invalid key is accepted (200)"
  else
    fail "behavior: health-check MUST fail when an invalid key returns 200"
  fi
  assert_in "${T5_OUT}" "invalid API key was ACCEPTED" \
    "behavior: health-check names the fail-closed violation"
}

# --- Behavior 6/7: backup archives only tracked config; excludes runtime -----
t5_b_backup_exclusions() {
  if [[ ! -f "${ROOT}/scripts/backup-config.sh" ]]; then
    fail "behavior: backup-config.sh absent (backup test skipped)"; return
  fi
  if ! command -v git >/dev/null 2>&1; then
    fail "behavior: git unavailable (backup test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_write_env "${t}" "${T5_SENTINEL_KEY}"
  # Tracked configuration/docs the archive MUST include.
  printf '# overview\n' > "${t}/docs/overview.md"
  printf 'readme\n'     > "${t}/README.md"
  printf 'changelog\n'  > "${t}/CHANGELOG.md"
  cat > "${t}/.gitignore" <<'G'
.env
.env.*
!.env.example
secrets/
models/
data/
*.log
G
  printf 'root = true\n' > "${t}/.editorconfig"
  printf '* text=auto\n' > "${t}/.gitattributes"
  # Ignored / untracked runtime content that MUST NEVER enter the archive.
  mkdir -p "${t}/ai/secrets" "${t}/ai/models" "${t}/ai/data"
  printf 'RUNTIME-SECRET-SENTINEL\n'  > "${t}/ai/secrets/sentinel.txt"
  printf 'RUNTIME-BLOB-SENTINEL\n'    > "${t}/ai/models/sentinel.bin"
  printf 'RUNTIME-DATA-SENTINEL\n'    > "${t}/ai/data/runtime-sentinel.txt"
  printf 'log line\n'                 > "${t}/ai/service.log"
  # Initialize a git repo and track ONLY the approved configuration paths.
  git -C "${t}" init -q
  git -C "${t}" add \
    ai/compose.yaml ai/.env.example ai/litellm/config.yaml \
    scripts docs/overview.md README.md CHANGELOG.md \
    .gitignore .editorconfig .gitattributes >/dev/null 2>&1
  # docker stub: `config` prints a rendered file containing the key; ollama down.
  cat >"${t}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "compose" ]]; then
  shift; sub=""
  while (( $# )); do
    case "$1" in version|pull|config|up|ps|exec) sub="$1"; break;; esac
    shift
  done
  case "$sub" in
    config)
      printf 'services:\n  litellm:\n    environment:\n      LITELLM_MASTER_KEY: sk-behaviortest-DO-NOT-LOG-123\n';;
    ps) : ;;          # empty -> ollama not running
    exec) exit 1;;    # inventory unavailable
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${t}/bin/docker"
  t5_run "${t}" "scripts/backup-config.sh"
  if (( T5_RC == 0 )); then
    pass "behavior: backup succeeds even when Ollama is unavailable"
  else
    fail "behavior: backup should succeed with Ollama unavailable (rc=${T5_RC})"
  fi
  # Glob directly instead of parsing `ls` (SC2012). nullglob leaves the array
  # empty when nothing matches; glob expansion is sorted, so [0] is the same
  # entry the previous `ls | head -n1` selected.
  local arch=""
  local -a archives=()
  shopt -s nullglob
  archives=("${t}/backups/"*.tar.gz)
  shopt -u nullglob
  (( ${#archives[@]} )) && arch="${archives[0]}"
  if [[ -n "${arch}" && -f "${arch}" ]]; then
    pass "behavior: backup produced an archive"
  else
    fail "behavior: backup produced no archive"; return
  fi
  if [[ -f "${arch}.sha256" ]]; then
    pass "behavior: backup wrote a SHA-256 checksum"
  else
    fail "behavior: backup did not write a SHA-256 checksum"
  fi
  local x="${t}/extract"; mkdir -p "${x}"
  tar xzf "${arch}" -C "${x}" 2>/dev/null || true

  # --- Exclusions: ignored/untracked runtime content never appears ----------
  if find "${x}" -name '.env' -type f | grep -q .; then
    fail "behavior: archive must not contain a real .env file"
  else
    pass "behavior: archive excludes real .env files"
  fi
  if find "${x}" -name '*.log' -type f | grep -q .; then
    fail "behavior: archive must not contain log files"
  else
    pass "behavior: archive excludes log files"
  fi
  if find "${x}" -path '*/ai/secrets/*' | grep -q .; then
    fail "behavior: archive must not contain ai/secrets content"
  else
    pass "behavior: archive excludes ai/secrets"
  fi
  if find "${x}" -path '*/ai/models/*' | grep -q .; then
    fail "behavior: archive must not contain ai/models blobs"
  else
    pass "behavior: archive excludes ai/models blobs"
  fi
  if find "${x}" -path '*/ai/data/*' | grep -q .; then
    fail "behavior: archive must not contain ai/data runtime content"
  else
    pass "behavior: archive excludes ai/data runtime content"
  fi
  local leaked=0 m
  for m in RUNTIME-SECRET-SENTINEL RUNTIME-BLOB-SENTINEL RUNTIME-DATA-SENTINEL; do
    grep -rqF "${m}" "${x}" 2>/dev/null && leaked=1
  done
  if (( leaked )); then
    fail "behavior: archive leaked ignored/untracked runtime content"
  else
    pass "behavior: archive contains no ignored/untracked runtime content"
  fi

  # --- Inclusions: tracked configuration IS present -------------------------
  if find "${x}" -path '*/ai/.env.example' -type f | grep -q .; then
    pass "behavior: archive includes tracked ai/.env.example"
  else
    fail "behavior: archive is missing tracked ai/.env.example"
  fi
  if find "${x}" -path '*/ai/compose.yaml' -type f | grep -q .; then
    pass "behavior: archive includes tracked ai/compose.yaml"
  else
    fail "behavior: archive is missing tracked ai/compose.yaml"
  fi
  if find "${x}" -iname 'manifest*' -type f | grep -q .; then
    pass "behavior: archive includes a manifest"
  else
    fail "behavior: archive is missing a manifest"
  fi
  if grep -rqF "${T5_SENTINEL_KEY}" "${x}" 2>/dev/null; then
    fail "behavior: archive leaks the master key"
  else
    pass "behavior: archive contains no master-key value"
  fi
}

# --- Behavior 9: update prints executable rollback on health failure --------
t5_b_update_rollback() {
  if [[ ! -f "${ROOT}/scripts/update-schai.sh" || ! -f "${ROOT}/scripts/health-check.sh" ]]; then
    fail "behavior: update/health scripts absent (rollback test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_write_env "${t}" "${T5_SENTINEL_KEY}"
  # docker stub: records image IDs; a `pull` flips running image IDs so ollama
  # is detected as changed. .Config.Image yields the configured reference.
  cat >"${t}/bin/docker" <<'EOF'
#!/usr/bin/env bash
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PULLED="${BIN_DIR}/.pulled"
if [[ "$1" == "compose" ]]; then
  shift; a=("$@"); sub=""
  for x in "${a[@]}"; do
    case "$x" in version|pull|config|up|ps|exec) sub="$x"; break;; esac
  done
  case "$sub" in
    pull) : > "${PULLED}"; exit 0;;
    ps)   echo "cid-${a[${#a[@]}-1]}"; exit 0;;   # cid-<service>
    *)    exit 0;;
  esac
elif [[ "$1" == "inspect" ]]; then
  a=("$@"); fmt=""; cid="${a[${#a[@]}-1]}"; svc="${cid#cid-}"
  for ((i=0;i<${#a[@]};i++)); do
    [[ "${a[$i]}" == "--format" ]] && fmt="${a[$((i+1))]}"
  done
  case "${fmt}" in
    *Config.Image*)
      case "${svc}" in
        ollama)  echo "ollama/ollama:0.11.4";;
        litellm) echo "ghcr.io/berriai/litellm:main-v1.74.3-stable";;
        *) echo "unknown:latest";;
      esac;;
    *)
      if [[ -f "${PULLED}" ]]; then echo "sha256:NEW-${svc}"; else echo "sha256:OLD-${svc}"; fi;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "${t}/bin/docker"
  # curl stub: always fails so the post-update health check fails deterministically.
  cat >"${t}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; wfmt=""; a=("$@"); i=0
while (( i < ${#a[@]} )); do
  case "${a[$i]}" in -o) i=$((i+1)); out="${a[$i]}";; -w) i=$((i+1)); wfmt="${a[$i]}";; esac
  i=$((i+1))
done
[[ -n "$out" ]] && : > "$out"
[[ -n "$wfmt" ]] && printf '000'
exit 0
EOF
  chmod +x "${t}/bin/curl"
  t5_run "${t}" "scripts/update-schai.sh"
  if (( T5_RC != 0 )); then
    pass "behavior: update exits nonzero on post-update health failure"
  else
    fail "behavior: update must exit nonzero when health fails after update"
  fi
  assert_in "${T5_OUT}" "roll back" "behavior: update prints rollback guidance"
  assert_in "${T5_OUT}" "sha256:OLD-ollama" \
    "behavior: rollback uses the image ID recorded before pull"
  assert_in "${T5_OUT}" "docker tag sha256:OLD-ollama ollama/ollama:0.11.4" \
    "behavior: rollback tags old ID to the exact configured image reference"
  refute_in "${T5_OUT}" "<image-ref-for" \
    "behavior: rollback output has no unresolved placeholder"
  refute_in "${T5_OUT}" "${T5_SENTINEL_KEY}" \
    "behavior: update output hides the master key"
}

# --- Behavior 8: deploy refuses a missing ai/.env ---------------------------
t5_b_deploy_missing_env() {
  if [[ ! -f "${ROOT}/scripts/deploy-schai.sh" ]]; then
    fail "behavior: deploy-schai.sh absent (missing-env test skipped)"; return
  fi
  local t; t="$(t5_new_repo)"; t5_stub_docker_ok "${t}"
  t5_run "${t}" "scripts/deploy-schai.sh"
  if (( T5_RC != 0 )); then
    pass "behavior: deploy refuses to run without ai/.env"
  else
    fail "behavior: deploy must refuse to run without ai/.env"
  fi
  assert_in "${T5_OUT}" "ai/.env" "behavior: deploy error names ai/.env"
}

# Run behavior tests with errexit locally disabled so a probe cannot abort.
run_task5_behavior_tests() {
  local had_e=0; case "$-" in *e*) had_e=1;; esac
  set +e
  t5_b_validate_missing_env
  t5_b_validate_empty_key
  t5_b_no_key_leak
  t5_b_deploy_bounded_wait
  t5_b_health_ordering
  t5_b_health_invalid_key_accepted
  t5_b_backup_exclusions
  t5_b_deploy_missing_env
  t5_b_update_rollback
  # Clean up temp dirs while errexit is still disabled so a stray Windows file
  # lock during rm cannot abort the suite.
  local d
  for d in "${TASK5_TMP[@]:-}"; do
    # Explicit if/then rather than A && B || C, which is not if-then-else:
    # the `|| true` would also run when the test succeeds but rm fails (SC2015).
    if [[ -n "${d}" && -d "${d}" ]]; then
      rm -rf "${d}" 2>/dev/null || true
    fi
  done
  (( had_e )) && set -e
  return 0
}

run_task5_behavior_tests

# ---------------------------------------------------------------------------
# Task 6: Architecture, operations, recovery, and security documentation
# ---------------------------------------------------------------------------

ARCH_DOC="docs/architecture/ai-platform.md"
INSTALL_DOC="docs/operations/install.md"
OPS_DOC="docs/operations/operations.md"
RECOVERY_DOC="docs/operations/recovery.md"
NETPOL_DOC="docs/security/network-policy.md"
SECURITY_DOC="security/SECURITY.md"
HARDENING_DOC="security/hardening-checklist.md"

for d in "${ARCH_DOC}" "${INSTALL_DOC}" "${OPS_DOC}" "${RECOVERY_DOC}" \
         "${NETPOL_DOC}" "${SECURITY_DOC}" "${HARDENING_DOC}"; do
  assert_file "${d}"
done

# --- Architecture -----------------------------------------------------------
assert_contains "${ARCH_DOC}" 'http://schai:4000/v1' \
  "architecture documents the supported endpoint"
assert_contains "${ARCH_DOC}" 'local-fast'   "architecture documents local-fast alias"
assert_contains "${ARCH_DOC}" 'local-general' "architecture documents local-general alias"
assert_contains "${ARCH_DOC}" 'local-embed'  "architecture documents local-embed alias"
assert_contains "${ARCH_DOC}" 'not an application endpoint' \
  "architecture states Ollama is not an application endpoint"
assert_contains "${ARCH_DOC}" 'ai-backend' \
  "architecture names the private ai-backend network"
assert_contains "${ARCH_DOC}" 'ollama-models' \
  "architecture documents the persistent ollama-models volume"
assert_contains "${ARCH_DOC}" 'only supported application-facing' \
  "architecture states LiteLLM is the only supported application-facing API"
assert_contains "${ARCH_DOC}" 'provider-specific' \
  "architecture explains avoiding provider-specific model names"
assert_contains "${ARCH_DOC}" 'not logged by default' \
  "architecture states prompts/responses are not logged by default"
assert_contains "${ARCH_DOC}" '[Nn]o (commercial|automatic).*fallback' \
  "architecture states there is no commercial-provider fallback"
assert_contains "${ARCH_DOC}" 'replace' \
  "architecture documents the replaceable-services principle"

# --- Install ----------------------------------------------------------------
assert_contains "${INSTALL_DOC}" '/opt/schott-platform' \
  "install uses the canonical deployment path"
assert_contains "${INSTALL_DOC}" 'America/Chicago' "install references America/Chicago"
assert_contains "${INSTALL_DOC}" 'nvidia-smi' "install verifies the GPU with nvidia-smi"
assert_contains "${INSTALL_DOC}" 'docker compose version' \
  "install checks for Docker Compose v2"
assert_contains "${INSTALL_DOC}" 'scripts/validate-config.sh' "install runs validate-config.sh"
assert_contains "${INSTALL_DOC}" 'scripts/deploy-schai.sh' "install runs deploy-schai.sh"
assert_contains "${INSTALL_DOC}" 'scripts/health-check.sh' "install runs health-check.sh"
assert_contains "${INSTALL_DOC}" 'chmod 600' "install sets ai/.env to mode 600"
assert_contains "${INSTALL_DOC}" 'ollama pull qwen3:8b' "install documents qwen3:8b pull"
assert_contains "${INSTALL_DOC}" 'ollama pull qwen3:30b' "install documents qwen3:30b pull"
assert_contains "${INSTALL_DOC}" 'ollama pull nomic-embed-text' \
  "install documents nomic-embed-text pull"
assert_contains "${INSTALL_DOC}" '\-\-deep' "install mentions optional --deep validation"
assert_contains "${INSTALL_DOC}" '[Rr]untime' \
  "install separates runtime steps (requiring schai) from static tests"

# --- Operations -------------------------------------------------------------
assert_contains "${OPS_DOC}" 'docker compose --env-file ai/\.env -f ai/compose\.yaml' \
  "operations uses ai/.env with ai/compose.yaml"
assert_contains "${OPS_DOC}" 'scripts/health-check.sh --deep' \
  "operations documents health-check --deep"
assert_contains "${OPS_DOC}" 'scripts/update-schai.sh' "operations documents update"
assert_contains "${OPS_DOC}" 'scripts/backup-config.sh' "operations documents backup"
assert_contains "${OPS_DOC}" 'sha256sum -c' "operations verifies the backup checksum"
assert_contains "${OPS_DOC}" 'UNAVAILABLE' \
  "operations explains an unavailable Ollama inventory"
assert_contains "${OPS_DOC}" 'America/Chicago' "operations uses America/Chicago"
assert_contains "${OPS_DOC}" 'ollama pull' "operations documents model pulls"
assert_contains "${OPS_DOC}" '401' "operations troubleshoots authentication failures"
assert_contains "${OPS_DOC}" 'nvidia-smi' "operations documents GPU checks"
assert_contains "${OPS_DOC}" '[Nn]ever delete' \
  "operations warns against deleting the model volume as a routine fix"

# --- Recovery ---------------------------------------------------------------
assert_contains "${RECOVERY_DOC}" 'Recovery order' "recovery documents the recovery order"
assert_contains "${RECOVERY_DOC}" '/opt/schott-platform' "recovery restores the canonical path"
assert_contains "${RECOVERY_DOC}" 'sha256sum -c' \
  "recovery verifies the checksum before extraction"
assert_contains "${RECOVERY_DOC}" 'ollama pull qwen3:8b' "recovery re-pulls qwen3:8b"
assert_contains "${RECOVERY_DOC}" 'ollama pull qwen3:30b' "recovery re-pulls qwen3:30b"
assert_contains "${RECOVERY_DOC}" 'ollama pull nomic-embed-text' \
  "recovery re-pulls nomic-embed-text"
assert_contains "${RECOVERY_DOC}" 'recreat' \
  "recovery requires recreating ai/.env separately"
assert_contains "${RECOVERY_DOC}" 'model blob' \
  "recovery states model blobs are intentionally excluded"
assert_contains "${RECOVERY_DOC}" 'update-schai.sh' \
  "recovery references the update rollback guidance"
assert_contains "${RECOVERY_DOC}" 'rotat' \
  "recovery covers secret rotation after compromise"
assert_contains "${RECOVERY_DOC}" 'cannot be recovered' \
  "recovery states what cannot be recovered from the archive"

# --- Network policy ---------------------------------------------------------
assert_contains "${NETPOL_DOC}" 'ufw allow' "network policy documents manual UFW commands"
assert_contains "${NETPOL_DOC}" '4000/tcp' "network policy restricts port 4000"
assert_contains "${NETPOL_DOC}" '11434' "network policy addresses Ollama port 11434"
assert_contains "${NETPOL_DOC}" 'not applied by (any )?repository script' \
  "network policy states firewall changes are not scripted"
assert_contains "${NETPOL_DOC}" '(SSH|22/tcp)' "network policy retains SSH access"
# The approved ranges are an explicit platform-owner decision (recorded during
# Task 8B), not an inference — so the doc carries concrete values rather than a
# placeholder, together with the caveat that they must be narrowed later.
assert_contains "${NETPOL_DOC}" '192\.168\.86\.0/24' \
  "network policy records the approved source range"
assert_contains "${NETPOL_DOC}" '[Aa]pproved application range' \
  "network policy names the approved application range"
# The management scope is an address pool, not a range expressible as one CIDR,
# and it is deliberately narrower than the application /24. Assert the
# distinction rather than the earlier wording, which incorrectly equated the
# management scope with the whole /24.
assert_contains "${NETPOL_DOC}" '[Mm]anagement address pool' \
  "network policy names the management address pool"
assert_contains "${NETPOL_DOC}" '192\.168\.86\.2-192\.168\.86\.99' \
  "network policy records the management address pool bounds"
assert_contains "${NETPOL_DOC}" 'explicitly approved management' \
  "network policy requires an explicitly approved management host"
assert_contains "${NETPOL_DOC}" 'membership in the broader' \
  "network policy denies SSH authorization by /24 membership alone"
assert_contains "${NETPOL_DOC}" "broader \`/24\` rule merely for convenience" \
  "network policy forbids widening SSH to the /24 for convenience"
assert_contains "${NETPOL_DOC}" 'replace literal address ranges with VLAN' \
  "network policy requires replacing literal ranges with VLAN policy"
assert_contains "${NETPOL_DOC}" 'management network should eventually have its own CIDR' \
  "network policy requires a dedicated management CIDR"
refute_contains "${NETPOL_DOC}" '<(approved|management)-subnet>' \
  "network policy no longer carries unresolved subnet placeholders"
# The Docker/UFW bypass is a recorded, accepted v0.1.0 limitation.
assert_contains "${NETPOL_DOC}" 'DOCKER-USER' \
  "network policy records the Docker chain that bypasses UFW"
assert_contains "${NETPOL_DOC}" 'does not reliably filter Docker-published' \
  "network policy states UFW may not filter Docker-published ports"
assert_contains "${NETPOL_DOC}" 'remains a separately designed network-hardening enhancement' \
  "network policy defers persistent DOCKER-USER policy to a later enhancement"
assert_contains "${NETPOL_DOC}" 'not published at all' \
  "network policy states Ollama's port is never published"
assert_contains "${NETPOL_DOC}" 'http://schai:4000/v1' \
  "network policy names the application endpoint"

# --- Security policy --------------------------------------------------------
assert_contains "${SECURITY_DOC}" 'ai/\.env' "security references ai/.env handling"
assert_contains "${SECURITY_DOC}" '[Nn]ever commit' "security says never commit ai/.env"
assert_contains "${SECURITY_DOC}" 'rotat' "security documents key rotation"
assert_contains "${SECURITY_DOC}" 'expos' "security documents exposed-key response"
assert_contains "${SECURITY_DOC}" 'not logged by default' \
  "security states no full prompt/response logging by default"
assert_contains "${SECURITY_DOC}" 'sha256' "security documents checksum verification"
assert_contains "${SECURITY_DOC}" '(401|unauthenticated)' \
  "security validates unauthenticated rejection after rotation"

# --- Hardening checklist ----------------------------------------------------
assert_contains "${HARDENING_DOC}" '^- \[ \]' "hardening checklist uses checkboxes"
assert_contains "${HARDENING_DOC}" '600' "hardening: ai/.env mode 600"
assert_contains "${HARDENING_DOC}" '4000' "hardening: port 4000 restricted"
assert_contains "${HARDENING_DOC}" '11434' "hardening: port 11434 not exposed"
assert_contains "${HARDENING_DOC}" 'rotat' "hardening: key rotation"
assert_contains "${HARDENING_DOC}" '[Mm]odel (data|blob)' \
  "hardening: model data excluded from backups"
assert_contains "${HARDENING_DOC}" '\-\-deep' "hardening: deep validation"

# --- README links to each required document ---------------------------------
assert_contains "README.md" 'docs/architecture/ai-platform\.md' "README links the architecture doc"
assert_contains "README.md" 'docs/operations/install\.md' "README links the install doc"
assert_contains "README.md" 'docs/operations/operations\.md' "README links the operations doc"
assert_contains "README.md" 'docs/operations/recovery\.md' "README links the recovery doc"
assert_contains "README.md" 'docs/security/network-policy\.md' "README links the network-policy doc"
assert_contains "README.md" 'security/SECURITY\.md' "README links the security policy"
assert_contains "README.md" 'security/hardening-checklist\.md' "README links the hardening checklist"

# ---------------------------------------------------------------------------
# Task 7: CI / security automation workflows and local-validation docs
# ---------------------------------------------------------------------------

WF_DIR=".github/workflows"
CI_WF="${WF_DIR}/ci.yml"
SHELLCHECK_WF="${WF_DIR}/shellcheck.yml"
GITLEAKS_WF="${WF_DIR}/gitleaks.yml"
TRIVY_WF="${WF_DIR}/trivy.yml"
SEMGREP_WF="${WF_DIR}/semgrep.yml"
CODEQL_WF="${WF_DIR}/codeql.yml"
LOCALVAL_DOC="docs/development/local-validation.md"

assert_dir "${WF_DIR}"

# assert_uses_sha_pinned <workflow> — every `uses:` action reference must pin a
# full 40-character commit SHA (immutable), not a movable tag.
assert_uses_sha_pinned() {
  # Split deliberately: bash expands every word of a `local` declaration before
  # assigning any of them, so a single combined declaration would resolve ${w}
  # from the CALLER's scope, not from $1 (SC2318).
  local w="$1"
  local f="${ROOT}/${w}"
  local total pinned
  if [[ ! -f "${f}" ]]; then
    fail "SHA-pin check: workflow missing: ${w}"; return
  fi
  total="$(grep -cE '^[[:space:]]*(- )?uses:' "${f}" 2>/dev/null || true)"; total=${total:-0}
  pinned="$(grep -E '^[[:space:]]*(- )?uses:' "${f}" 2>/dev/null \
            | grep -cE '@[0-9a-f]{40}([^0-9a-f]|$)' || true)"; pinned=${pinned:-0}
  if [[ "${total}" -gt 0 && "${total}" -eq "${pinned}" ]]; then
    pass "all ${total} action ref(s) pinned to a 40-char commit SHA: ${w}"
  else
    fail "not all action refs are SHA-pinned in ${w} (pinned ${pinned}/${total})"
  fi
}

# Contracts every workflow must satisfy: a name, explicit least-privilege
# permissions, declared triggers, the ubuntu-24.04 runner (never ubuntu-latest),
# fully SHA-pinned immutable action references (no @main/@master and no movable
# @vN tags), and no reference to a real secret file (only ai/.env.example).
WORKFLOWS=( "${CI_WF}" "${SHELLCHECK_WF}" "${GITLEAKS_WF}" "${TRIVY_WF}" \
            "${SEMGREP_WF}" "${CODEQL_WF}" )
for w in "${WORKFLOWS[@]}"; do
  assert_file "${w}"
  assert_contains "${w}" '^name:[[:space:]]*[A-Za-z]' "workflow declares a name: ${w}"
  assert_contains "${w}" '^permissions:' "workflow declares explicit permissions: ${w}"
  assert_contains "${w}" '^on:' "workflow declares triggers: ${w}"
  assert_contains "${w}" 'runs-on:[[:space:]]*ubuntu-24\.04' \
    "workflow pins the runner to ubuntu-24.04: ${w}"
  refute_contains "${w}" 'ubuntu-latest' "workflow does not use ubuntu-latest: ${w}"
  assert_uses_sha_pinned "${w}"
  refute_contains "${w}" '@(main|master)([^A-Za-z0-9]|$)' \
    "workflow uses no @main/@master ref: ${w}"
  refute_contains "${w}" 'uses:[^#]*@v[0-9]' \
    "workflow uses no movable @vN action tag: ${w}"
  refute_contains "${w}" '/\.env([^.]|$)' \
    "workflow references only sanitized .env.example (never a real .env): ${w}"
done

# Regression (SC2318): assert_uses_sha_pinned must resolve its path from its own
# argument, never from a caller variable that happens to be named `w`. Bash
# expands every word of a `local` declaration before assigning any of them, so
# `local w="$1" f="${ROOT}/${w}"` reads the OUTER w. The loop above masked that
# because its variable is also `w` holding the same value. Here a decoy `w` is
# in scope and the loop variable has a different name: if the helper is still
# dynamically scoped it resolves the decoy, fails to find the file, and reports
# "workflow missing".
sha_pin_scoping_regression() {
  local w="workflows/DECOY-MUST-NOT-BE-USED.yml"   # decoy; must be ignored
  local target
  for target in "${CI_WF}" "${CODEQL_WF}"; do
    assert_uses_sha_pinned "${target}"
  done
}
sha_pin_scoping_regression

# --- ci.yml automates the existing local validation -------------------------
assert_contains "${CI_WF}" 'push:' "ci triggers on push"
assert_contains "${CI_WF}" 'pull_request:' "ci triggers on pull_request"
assert_contains "${CI_WF}" '^concurrency:' "ci uses concurrency cancellation"
assert_contains "${CI_WF}" 'bash -n scripts/\*\.sh' "ci runs shell syntax check"
assert_contains "${CI_WF}" 'bash -n tests/\*\.sh' "ci syntax-checks every test file"
assert_contains "${CI_WF}" 'bash tests/test-static\.sh' "ci runs the static test suite"
assert_contains "${CI_WF}" 'bash tests/test-docs-static\.sh' "ci runs the documentation test suite"
assert_contains "${CI_WF}" 'bash tests/test-platform-model\.sh' "ci runs the platform model test suite"
assert_contains "${CI_WF}" 'validate_evidence\.py --root platform-model' \
  "ci runs the evidence and drift definition validator"
assert_contains "${CI_WF}" 'bash tests/test-evidence-validator\.sh' \
  "ci runs the evidence validator behaviour tests"
assert_contains "${CI_WF}" 'validate_plugins\.py --root \.' \
  "ci runs the collector plugin validator"
assert_contains "${CI_WF}" 'bash tests/test-collector-framework\.sh' \
  "ci runs the collector framework tests"
assert_contains "${CI_WF}" "import yaml" "ci verifies PyYAML before model validation"
# --- Pinned CI Python dependency --------------------------------------------
# The platform model validator needs PyYAML. Installing it unpinned would make
# CI depend on whatever PyPI serves that day, so the version and artifact hashes
# are pinned and pip is required to verify them.
CI_REQUIREMENTS="requirements-ci.txt"
assert_file "${CI_REQUIREMENTS}"
assert_contains "${CI_REQUIREMENTS}" '^pyyaml==6\.0\.3' \
  "ci requirements pin PyYAML to an exact version"
assert_contains "${CI_REQUIREMENTS}" '\-\-hash=sha256:[0-9a-f]{64}' \
  "ci requirements carry sha256 artifact hashes"
# --require-hashes fails unless every requirement is hash-pinned, so an
# unrelated dependency cannot be added without also pinning it. Keep the file
# to PyYAML alone. Enumerate the requirement names rather than using a negative
# regex, so a missing file fails rather than silently passing.
ci_requirement_names="$( { grep -oE '^[a-zA-Z][a-zA-Z0-9_.-]*==' "${ROOT}/${CI_REQUIREMENTS}" 2>/dev/null || true; } \
  | sed 's/==$//' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [[ "${ci_requirement_names}" == "pyyaml" ]]; then
  pass "ci requirements introduce no other Python dependency"
else
  fail "ci requirements list unexpected packages: '${ci_requirement_names}'"
fi
assert_contains "${CI_WF}" 'python3 -m pip install --require-hashes -r requirements-ci\.txt' \
  "ci installs the pinned requirements with hash verification"
assert_contains "${CI_WF}" 'requirements-ci\.txt' \
  "ci references the pinned requirements file"

assert_contains "${CI_WF}" 'docker compose' "ci validates Docker Compose"
assert_contains "${CI_WF}" 'ai/\.env\.example' "ci renders compose from ai/.env.example"
assert_contains "${CI_WF}" 'ai/compose\.yaml' "ci validates the integrated stack"
assert_contains "${CI_WF}" 'ai/ollama/compose\.yaml' "ci validates the ollama sub-stack"
assert_contains "${CI_WF}" 'ai/litellm/compose\.yaml' "ci validates the litellm sub-stack"

# --- Tool workflows run the same tools available locally --------------------
assert_contains "${SHELLCHECK_WF}" 'shellcheck' "shellcheck workflow runs ShellCheck"
assert_contains "${GITLEAKS_WF}" '[Gg]itleaks' "gitleaks workflow runs Gitleaks"
assert_contains "${TRIVY_WF}" 'trivy' "trivy workflow runs Trivy"
assert_contains "${TRIVY_WF}" '(fs|filesystem)' "trivy runs a filesystem scan"
assert_contains "${TRIVY_WF}" '(HIGH,CRITICAL|CRITICAL,HIGH)' "trivy scans HIGH + CRITICAL"
refute_contains "${TRIVY_WF}" '@0\.28\.0' \
  "trivy no longer references the compromised 0.28.0 release"

assert_contains "${SEMGREP_WF}" 'semgrep' "semgrep workflow runs Semgrep"
assert_contains "${SEMGREP_WF}" 'semgrep/semgrep:[0-9]' \
  "semgrep image is pinned to a numbered version"
assert_contains "${SEMGREP_WF}" '@sha256:[0-9a-f]{64}' \
  "semgrep image is pinned by an immutable digest"
refute_contains "${SEMGREP_WF}" 'image:[[:space:]]*semgrep/semgrep[[:space:]]*$' \
  "semgrep image is not the mutable unversioned tag"

# CodeQL is functional: it scans the GitHub Actions workflows (language:actions),
# is not gated off, and carries no placeholder Python matrix.
assert_contains "${CODEQL_WF}" '[Cc]ode[Qq][Ll]' "codeql workflow references CodeQL"
assert_contains "${CODEQL_WF}" 'languages:[[:space:]]*actions' \
  "codeql configures the actions language"
assert_contains "${CODEQL_WF}" 'codeql-action/init' "codeql runs init"
assert_contains "${CODEQL_WF}" 'codeql-action/analyze' "codeql runs analyze"
refute_contains "${CODEQL_WF}" 'if:[[:space:]]*\$\{\{[[:space:]]*false' \
  "codeql analyze job is enabled (not gated off)"
refute_contains "${CODEQL_WF}" 'python' \
  "codeql has no placeholder python matrix"

# --- README + local validation documentation --------------------------------
assert_contains "README.md" 'docs/development/local-validation\.md' \
  "README links the local validation docs"

assert_file "${LOCALVAL_DOC}"
assert_contains "${LOCALVAL_DOC}" 'bash -n scripts/\*\.sh' "local-validation documents shell syntax check"
assert_contains "${LOCALVAL_DOC}" 'bash -n tests/test-static\.sh' "local-validation documents test syntax check"
assert_contains "${LOCALVAL_DOC}" 'bash tests/test-static\.sh' "local-validation documents the static suite"
assert_contains "${LOCALVAL_DOC}" 'docker compose' "local-validation documents compose config"
assert_contains "${LOCALVAL_DOC}" 'ai/\.env\.example' "local-validation uses ai/.env.example"
assert_contains "${LOCALVAL_DOC}" 'shellcheck' "local-validation documents ShellCheck"
assert_contains "${LOCALVAL_DOC}" '[Gg]itleaks' "local-validation documents Gitleaks"
assert_contains "${LOCALVAL_DOC}" 'trivy' "local-validation documents Trivy"
assert_contains "${LOCALVAL_DOC}" 'semgrep' "local-validation documents Semgrep"
assert_contains "${LOCALVAL_DOC}" 'same result as CI' \
  "local-validation states local runs match CI"
assert_contains "${LOCALVAL_DOC}" 'GitHub Actions workflows' \
  "local-validation explains CodeQL scans the GitHub Actions workflows"
assert_contains "${LOCALVAL_DOC}" 'GitHub-hosted' \
  "local-validation notes CodeQL is GitHub-hosted with no simple local equivalent"
assert_contains "${LOCALVAL_DOC}" '1\.171\.0' \
  "local-validation identifies the pinned Semgrep version"
refute_contains "${LOCALVAL_DOC}" '/\.env([^.]|$)' \
  "local-validation references only sanitized .env.example"

# --- Dependabot version updates (.github/dependabot.yml) --------------------
# compose.yaml files are handled by the `docker-compose` ecosystem (not the
# Dockerfile-only `docker` ecosystem), and Dependabot scans only the named
# directory (no recursion) — so each compose directory is listed explicitly.
DEPENDABOT=".github/dependabot.yml"
assert_file "${DEPENDABOT}"
assert_contains "${DEPENDABOT}" '^version:[[:space:]]*2[[:space:]]*$' \
  "dependabot uses schema version 2"
assert_contains "${DEPENDABOT}" 'package-ecosystem:[[:space:]]*"?github-actions"?' \
  "dependabot configures the github-actions ecosystem"
assert_contains "${DEPENDABOT}" 'package-ecosystem:[[:space:]]*"?docker(-compose)?"?' \
  "dependabot configures the docker/compose ecosystem"
assert_count "${DEPENDABOT}" 'interval:[[:space:]]*"?monthly"?' 2 \
  "both ecosystems use a monthly schedule"
assert_contains "${DEPENDABOT}" 'open-pull-requests-limit:[[:space:]]*[1-9]' \
  "dependabot sets an open-pull-requests-limit"
assert_contains "${DEPENDABOT}" 'groups:' "dependabot groups related updates"
assert_contains "${DEPENDABOT}" '"/ai"' \
  "dependabot covers ai/ (ai/compose.yaml)"
assert_contains "${DEPENDABOT}" '"/ai/ollama"' \
  "dependabot covers ai/ollama (ai/ollama/compose.yaml)"
assert_contains "${DEPENDABOT}" '"/ai/litellm"' \
  "dependabot covers ai/litellm (ai/litellm/compose.yaml)"
refute_contains "${DEPENDABOT}" '[Aa]uto-?merge' \
  "dependabot config has no auto-merge"
refute_contains "${DEPENDABOT}" '(registries:|password|[Tt]oken|[Ss]ecret)' \
  "dependabot embeds no registry credentials or secrets"
refute_contains "${DEPENDABOT}" '(reviewers:|assignees:)' \
  "dependabot adds no reviewers or assignees"

# Cooldown: never propose a dependency the moment it is published. A newly
# published version may be malicious or withdrawn within days, so each ecosystem
# waits before opening an update PR.
assert_count "${DEPENDABOT}" '^[[:space:]]*cooldown:[[:space:]]*$' 2 \
  "both ecosystems declare a cooldown"
assert_count "${DEPENDABOT}" '^[[:space:]]*default-days:[[:space:]]*[0-9]+[[:space:]]*$' 2 \
  "both cooldowns set default-days"

# Every declared default-days must be at least 7.
dependabot_cooldown_days_ok() {
  local file="${ROOT}/${DEPENDABOT}" days found=0 bad=0
  while read -r days; do
    found=$((found + 1))
    (( days < 7 )) && bad=$((bad + 1))
  done < <(grep -Eo '^[[:space:]]*default-days:[[:space:]]*[0-9]+' "${file}" 2>/dev/null \
           | grep -Eo '[0-9]+$')
  if (( found == 2 && bad == 0 )); then
    pass "every dependabot cooldown default-days is >= 7 (found ${found})"
  else
    fail "dependabot cooldown default-days must all be >= 7 (found ${found}, below-minimum ${bad})"
  fi
}
dependabot_cooldown_days_ok

# ---------------------------------------------------------------------------
# Task 8: Configurable Ollama model volume (adopt an existing Docker volume)
# ---------------------------------------------------------------------------
#
# The stack must be portable across clean installs, pre-existing Ollama
# installations, and migrated hosts WITHOUT editing any Compose file. The
# Compose volume key stays `ollama-models`; only the underlying Docker volume
# name is configurable, via OLLAMA_VOLUME_NAME.

VOLUME_DEFAULT="schott-platform-ollama-models"
# An example legacy name from a pre-existing standalone Ollama deployment. It is
# host-specific and must never appear in Compose or env files — only in docs.
LEGACY_VOLUME="ollama_ollama-data"

for c in "${AI_COMPOSE}" "${OLLAMA_COMPOSE}"; do
  # The named volume carries an explicit, env-overridable Docker volume name
  # with a host-agnostic platform default.
  assert_contains "${c}" \
    'name:[[:space:]]*\$\{OLLAMA_VOLUME_NAME:-schott-platform-ollama-models\}' \
    "volume name is configurable via OLLAMA_VOLUME_NAME with a default: ${c}"
  # The service still mounts the same Compose volume key at /root/.ollama.
  assert_contains "${c}" 'ollama-models:/root/\.ollama' \
    "model storage still mounts at /root/.ollama: ${c}"
  # No host-specific volume name is baked into the repository.
  refute_contains "${c}" "${LEGACY_VOLUME}" \
    "no host-specific legacy volume name hardcoded: ${c}"
  # Adoption safety switch, defaulting to false so clean installs still create
  # the volume. An unconditional `external: true` would break fresh hosts.
  assert_contains "${c}" 'external:[[:space:]]*\$\{OLLAMA_VOLUME_EXTERNAL:-false\}' \
    "volume external flag is configurable and defaults to false: ${c}"
  refute_contains "${c}" '^[[:space:]]*external:[[:space:]]*true[[:space:]]*$' \
    "no unconditional 'external: true' (would break clean installs): ${c}"
done

# Env examples carry the default so a clean install needs no edits, and they
# never hardcode a host-specific name.
for e in "ai/.env.example" "ai/ollama/.env.example"; do
  assert_contains "${e}" "^OLLAMA_VOLUME_NAME=${VOLUME_DEFAULT}[[:space:]]*\$" \
    "env example sets the default volume name: ${e}"
  refute_contains "${e}" "${LEGACY_VOLUME}" \
    "env example hardcodes no host-specific volume name: ${e}"
  assert_contains "${e}" '^OLLAMA_VOLUME_EXTERNAL=false[[:space:]]*$' \
    "env example defaults the adoption switch to false: ${e}"
done

# --- Rendered behavior: default and override (requires docker CLI) ----------
if command -v docker >/dev/null 2>&1; then
  t8_rendered_volume() {  # <env-file-abs> <compose-rel> -> prints rendered name
    docker compose --env-file "$1" -f "${ROOT}/$2" config 2>/dev/null \
      | awk '/^volumes:/{v=1; next} v && /^[^ ]/{v=0} v && /name:/{gsub(/^[ ]*name:[ ]*/,""); gsub(/"/,""); print; exit}'
  }

  T8_TMP="$(mktemp -d)"
  for c in "${AI_COMPOSE}" "${OLLAMA_COMPOSE}"; do
    if [[ "${c}" == "${OLLAMA_COMPOSE}" ]]; then
      base_env="${ROOT}/ai/ollama/.env.example"
    else
      base_env="${ROOT}/ai/.env.example"
    fi

    # Clean install: the example env renders the platform default, with no
    # Compose project prefix.
    got="$(t8_rendered_volume "${base_env}" "${c}")"
    if [[ "${got}" == "${VOLUME_DEFAULT}" ]]; then
      pass "rendered: default volume name is ${VOLUME_DEFAULT} (${c})"
    else
      fail "rendered: default volume name should be ${VOLUME_DEFAULT}, got '${got}' (${c})"
    fi

    # Existing installation: OLLAMA_VOLUME_NAME adopts an already-present
    # Docker volume without editing the Compose file.
    override_env="${T8_TMP}/override.env"
    { cat "${base_env}"; printf '\nOLLAMA_VOLUME_NAME=%s\n' "${LEGACY_VOLUME}"; } > "${override_env}"
    got="$(t8_rendered_volume "${override_env}" "${c}")"
    if [[ "${got}" == "${LEGACY_VOLUME}" ]]; then
      pass "rendered: OLLAMA_VOLUME_NAME adopts an existing volume (${c})"
    else
      fail "rendered: OLLAMA_VOLUME_NAME override should yield ${LEGACY_VOLUME}, got '${got}' (${c})"
    fi

    # No env file at all (bare `docker compose config`): the built-in default
    # still applies, so a clean install truly requires no configuration.
    : > "${T8_TMP}/empty.env"
    got="$(t8_rendered_volume "${T8_TMP}/empty.env" "${c}")"
    if [[ "${got}" == "${VOLUME_DEFAULT}" ]]; then
      pass "rendered: built-in default applies with an empty env file (${c})"
    else
      fail "rendered: built-in default should apply with an empty env file, got '${got}' (${c})"
    fi

    # Clean install must NOT render `external: true` — Compose has to be free to
    # create the volume, otherwise `up` fails with "external volume not found".
    if docker compose --env-file "${base_env}" -f "${ROOT}/${c}" config 2>/dev/null \
         | awk '/^volumes:/{v=1;next} v&&/^[^ ]/{v=0} v' | grep -Eq 'external:[[:space:]]*true'; then
      fail "rendered: clean install must not mark the volume external (${c})"
    else
      pass "rendered: clean install leaves the volume Compose-managed (${c})"
    fi

    # Opting in flips the volume to external so an adopted volume is never
    # created-if-missing and cannot be removed by `down -v`.
    ext_env="${T8_TMP}/ext.env"
    { cat "${base_env}"; printf '\nOLLAMA_VOLUME_EXTERNAL=true\n'; } > "${ext_env}"
    if docker compose --env-file "${ext_env}" -f "${ROOT}/${c}" config 2>/dev/null \
         | awk '/^volumes:/{v=1;next} v&&/^[^ ]/{v=0} v' | grep -Eq 'external:[[:space:]]*true'; then
      pass "rendered: OLLAMA_VOLUME_EXTERNAL=true marks the volume external (${c})"
    else
      fail "rendered: OLLAMA_VOLUME_EXTERNAL=true should mark the volume external (${c})"
    fi
  done
  rm -rf "${T8_TMP}" 2>/dev/null || true
else
  printf 'SKIP: rendered volume-name checks (docker CLI not available)\n'
fi

# --- Documentation: migration from a legacy Ollama deployment ---------------
MIGRATION_DOC="docs/operations/install.md"

assert_contains "${MIGRATION_DOC}" 'OLLAMA_VOLUME_NAME' \
  "install documents the OLLAMA_VOLUME_NAME setting"
assert_contains "${MIGRATION_DOC}" "${LEGACY_VOLUME}" \
  "install shows a concrete legacy volume name example"
assert_contains "${MIGRATION_DOC}" 'docker volume ls' \
  "install shows how to discover the existing volume"
assert_contains "${MIGRATION_DOC}" 'docker volume inspect' \
  "install shows how to confirm the existing volume holds model data"
assert_contains "${MIGRATION_DOC}" '[Mm]igrat' \
  "install has a migration section for legacy Ollama deployments"
assert_contains "${MIGRATION_DOC}" 'down -v' \
  "install warns that down -v destroys an adopted volume"

assert_contains "${ARCH_DOC}" 'OLLAMA_VOLUME_NAME' \
  "architecture documents the configurable model volume name"
assert_contains "docs/operations/operations.md" 'OLLAMA_VOLUME_NAME' \
  "operations documents the configurable model volume name"
assert_contains "ai/ollama/README.md" 'OLLAMA_VOLUME_NAME' \
  "ollama README documents the configurable model volume name"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if (( FAILURES > 0 )); then
  printf '\n%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll static assertions passed.\n'
