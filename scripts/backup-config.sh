#!/usr/bin/env bash
set -Eeuo pipefail

# backup-config.sh — timestamped, sanitized configuration backup.
#
# Archives tracked configuration, documentation, scripts, sanitized
# *.env.example templates, the git HEAD, a sanitized rendered Compose config,
# an Ollama model inventory, and a manifest. Writes a SHA-256 checksum next to
# the archive.
#
# Explicitly excludes: ai/.env and all real .env files, secrets, model blobs,
# logs, and any existing backup archives. The rendered Compose output is
# sanitized before inclusion because it can contain the runtime master key; the
# script also verifies the sanitized output before archiving and aborts rather
# than ship a secret. If Ollama is unavailable, an actionable status is recorded
# in the manifest instead of failing. Safe to run repeatedly.

trap 'printf "ERROR: %s failed unexpectedly at line %d\n" "$(basename "$0")" "${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${ROOT}/ai/compose.yaml"
ENV_FILE="${ROOT}/ai/.env"
ENV_EXAMPLE="${ROOT}/ai/.env.example"
BACKUP_DIR="${ROOT}/backups"

TS="$(date +%Y%m%d-%H%M%S)"
NAME="schott-platform-config-${TS}"

compose() {
  docker compose --env-file "${1}" -f "${COMPOSE_FILE}" "${@:2}"
}

sha256_of() {  # sha256_of <file> ; echoes "<hash>  <basename>"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$(dirname "$1")" && sha256sum "$(basename "$1")" )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "$(dirname "$1")" && shasum -a 256 "$(basename "$1")" )
  else
    printf 'ERROR: no sha256 tool (sha256sum/shasum) available\n' >&2
    return 1
  fi
}

mkdir -p "${BACKUP_DIR}"

STAGE="$(mktemp -d)"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

CONTENT="${STAGE}/${NAME}"
META="${CONTENT}/BACKUP-META"
mkdir -p "${CONTENT}" "${META}"

# --- Copy tracked configuration / docs / scripts ----------------------------
# Only config-bearing top-level items are copied; model data, secrets, logs,
# and backups are never in this list, so they cannot enter the archive.
for item in ai docs scripts security README.md CHANGELOG.md .gitignore .editorconfig .gitattributes; do
  [[ -e "${ROOT}/${item}" ]] || continue
  cp -R "${ROOT}/${item}" "${CONTENT}/" 2>/dev/null || true
done

# --- Prune anything sensitive that a copied tree might contain ---------------
#   * real .env files (keep sanitized *.env.example)
#   * logs
#   * Ollama model caches
find "${CONTENT}" -type f -name '.env' -delete 2>/dev/null || true
find "${CONTENT}" -type f -name '.env.*' ! -name '*.example' -delete 2>/dev/null || true
find "${CONTENT}" -type f -name '*.log' -delete 2>/dev/null || true
find "${CONTENT}" -type d -name '.ollama' -prune -exec rm -rf {} + 2>/dev/null || true

# --- git HEAD ---------------------------------------------------------------
if HEAD="$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null)"; then
  printf '%s\n' "${HEAD}" > "${META}/git-HEAD.txt"
else
  HEAD="unknown (not a git working tree)"
  printf '%s\n' "${HEAD}" > "${META}/git-HEAD.txt"
fi

# --- Sanitized rendered Compose config --------------------------------------
# Render with the local env when present (production truth) but ALWAYS redact
# the master key, then verify the redaction succeeded before archiving.
RENDER_ENV="${ENV_FILE}"
[[ -f "${RENDER_ENV}" ]] || RENDER_ENV="${ENV_EXAMPLE}"
RENDERED="${META}/compose-config.sanitized.yaml"
compose_status="ok"
if command -v docker >/dev/null 2>&1 && [[ -f "${RENDER_ENV}" && -f "${COMPOSE_FILE}" ]]; then
  if compose "${RENDER_ENV}" config 2>/dev/null \
      | sed -E 's/^([[:space:]]*LITELLM_MASTER_KEY:[[:space:]]*).*/\1"<REDACTED>"/' \
      > "${RENDERED}"; then
    :
  else
    compose_status="render failed"
    printf '# compose config render failed\n' > "${RENDERED}"
  fi
else
  compose_status="skipped (docker unavailable)"
  printf '# compose config not rendered: %s\n' "${compose_status}" > "${RENDERED}"
fi

# Defense in depth: if the live key still appears anywhere in the sanitized
# output, refuse to continue rather than archive a secret. The key value is
# never printed.
if [[ -f "${ENV_FILE}" ]]; then
  live_key="$(grep -E '^[[:space:]]*LITELLM_MASTER_KEY=' "${ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
  live_key="${live_key%\"}"; live_key="${live_key#\"}"
  if [[ -n "${live_key//[[:space:]]/}" ]] && grep -qF -- "${live_key}" "${RENDERED}"; then
    unset live_key
    printf 'ERROR: sanitization failed — master key detected in rendered config; aborting backup.\n' >&2
    exit 1
  fi
  unset live_key
fi

# --- Ollama model inventory (actionable status if unavailable) --------------
INVENTORY="${META}/ollama-models.txt"
inventory_status="ok"
if command -v docker >/dev/null 2>&1 \
   && [[ -n "$(compose "${RENDER_ENV}" ps -q ollama 2>/dev/null || true)" ]] \
   && compose "${RENDER_ENV}" exec -T ollama ollama list > "${INVENTORY}" 2>/dev/null; then
  :
else
  inventory_status="UNAVAILABLE"
  {
    printf 'UNAVAILABLE: could not query the Ollama model inventory.\n'
    printf 'The Ollama container was not running or not reachable at backup time.\n'
    printf 'Deploy the stack (scripts/deploy-schai.sh) and re-run this backup to\n'
    printf 'capture the inventory. No secrets or model blobs were archived.\n'
  } > "${INVENTORY}"
fi

# --- Manifest ---------------------------------------------------------------
MANIFEST="${META}/MANIFEST.txt"
{
  printf 'Schott Platform configuration backup\n'
  printf 'name:            %s\n' "${NAME}"
  printf 'created:         %s\n' "${TS}"
  printf 'git HEAD:        %s\n' "${HEAD}"
  printf 'compose render:  %s (master key REDACTED)\n' "${compose_status}"
  printf 'ollama inventory:%s\n' " ${inventory_status}"
  printf '\nExcluded by design: ai/.env, all real .env files, secrets, model\n'
  printf 'blobs, logs, existing backup archives, and any LITELLM_MASTER_KEY value.\n'
  printf '\nContents:\n'
} > "${MANIFEST}"
( cd "${CONTENT}" && find . -type f | sort ) >> "${MANIFEST}"

# --- Create the archive + checksum ------------------------------------------
ARCHIVE="${BACKUP_DIR}/${NAME}.tar.gz"
tar -czf "${ARCHIVE}" -C "${STAGE}" "${NAME}"
sha256_of "${ARCHIVE}" > "${ARCHIVE}.sha256"

printf 'Backup written: %s\n' "${ARCHIVE#"${ROOT}/"}"
printf 'Checksum:       %s\n' "${ARCHIVE#"${ROOT}/"}.sha256"
printf 'Ollama inventory status: %s\n' "${inventory_status}"
