#!/usr/bin/env bash
set -Eeuo pipefail

# Static repository assertions for the Schott Platform AI baseline.
#
# This test is extended task-by-task. It must be runnable from anywhere and
# must not require the schai VM, Docker daemon access, or any secret.
#
# Scope currently implemented: Task 1 (foundation), Task 2 (Ollama service).

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
# Result
# ---------------------------------------------------------------------------

if (( FAILURES > 0 )); then
  printf '\n%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nAll static assertions passed.\n'
