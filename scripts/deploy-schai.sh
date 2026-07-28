#!/usr/bin/env bash
set -Eeuo pipefail

# deploy-schai.sh — first deployment / idempotent startup of the canonical AI
# platform stack (ai/compose.yaml) using the local secret file (ai/.env).
#
# Refuses to run without ai/.env, validates configuration, pulls images, starts
# services, waits (bounded) for Ollama and LiteLLM to become healthy, then runs
# health-check.sh. Exits non-zero if deployment or health verification fails.
# Safe to rerun. Never applies firewall changes. Never prints the master key.

trap 'printf "ERROR: %s failed unexpectedly at line %d\n" "$(basename "$0")" "${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${ROOT}/ai/compose.yaml"
ENV_FILE="${ROOT}/ai/.env"

# Bounded health wait (overridable for testing / slow cold starts).
TIMEOUT="${DEPLOY_TIMEOUT_SECONDS:-180}"
POLL="${DEPLOY_POLL_SECONDS:-5}"

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

# --- Refuse without the local secret file -----------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'ERROR: missing local secret file: ai/.env\n' >&2
  printf 'Copy ai/.env.example to ai/.env and set a real LITELLM_MASTER_KEY before deploying.\n' >&2
  exit 1
fi

# --- Validate before changing any services ----------------------------------
printf '==> Validating configuration...\n'
"${SCRIPT_DIR}/validate-config.sh"

# --- Pull and start ---------------------------------------------------------
printf '==> Pulling images...\n'
compose pull

printf '==> Starting services (detached)...\n'
compose up -d

# --- Bounded wait for container health --------------------------------------
service_healthy() {  # service_healthy <service>
  local svc="$1" cid status
  cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
  [[ -n "${cid}" ]] || return 1
  status="$(docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${cid}" 2>/dev/null || true)"
  [[ "${status}" == "healthy" ]]
}

printf '==> Waiting up to %ss for ollama and litellm to become healthy...\n' "${TIMEOUT}"
deadline=$(( SECONDS + TIMEOUT ))
while true; do
  if service_healthy ollama && service_healthy litellm; then
    printf '==> Services are healthy.\n'
    break
  fi
  if (( SECONDS >= deadline )); then
    printf 'ERROR: timed out after %ss waiting for services to become healthy.\n' "${TIMEOUT}" >&2
    printf 'Inspect status with: docker compose --env-file ai/.env -f ai/compose.yaml ps\n' >&2
    exit 1
  fi
  sleep "${POLL}"
done

# --- Verify functional health -----------------------------------------------
printf '==> Running health checks...\n'
if ! "${SCRIPT_DIR}/health-check.sh"; then
  printf 'ERROR: health checks failed after deployment.\n' >&2
  exit 1
fi

printf '==> Deployment complete and healthy.\n'
