#!/usr/bin/env bash
set -Eeuo pipefail

# update-schai.sh — pull newer images and recreate only changed services.
#
# Records the currently running image IDs before pulling, pulls images, then
# lets Docker Compose recreate only services whose image (or config) changed.
# Runs health checks afterward. If health fails, prints explicit manual
# rollback commands using the recorded image IDs — it never performs a
# destructive rollback automatically. Never prints the master key. Safe to
# rerun.

trap 'printf "ERROR: %s failed unexpectedly at line %d\n" "$(basename "$0")" "${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${ROOT}/ai/compose.yaml"
ENV_FILE="${ROOT}/ai/.env"
SERVICES=(ollama litellm)

compose() {
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

# --- Refuse without the local secret file -----------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'ERROR: missing local secret file: ai/.env\n' >&2
  exit 1
fi

running_image_id() {  # running_image_id <service> — resolved image ID (sha256:...)
  local svc="$1" cid
  cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
  [[ -n "${cid}" ]] || { printf ''; return 0; }
  docker inspect --format '{{.Image}}' "${cid}" 2>/dev/null || printf ''
}

configured_image_ref() {  # configured_image_ref <service> — the image reference
  local svc="$1" cid                     # the Compose service was created with.
  cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
  [[ -n "${cid}" ]] || { printf ''; return 0; }
  docker inspect --format '{{.Config.Image}}' "${cid}" 2>/dev/null || printf ''
}

# --- Record currently running image IDs and configured refs (before pulling) -
declare -A OLD_ID CFG_REF
for svc in "${SERVICES[@]}"; do
  OLD_ID["${svc}"]="$(running_image_id "${svc}")"
  CFG_REF["${svc}"]="$(configured_image_ref "${svc}")"
done

# --- Pull, then recreate only changed services ------------------------------
printf '==> Pulling images...\n'
compose pull

printf '==> Recreating services whose images changed...\n'
# `up -d` (no --force-recreate) recreates only services whose image or config
# changed; unchanged services are left running untouched.
compose up -d

# --- Determine what actually changed ----------------------------------------
declare -A NEW_ID
changed=()
for svc in "${SERVICES[@]}"; do
  NEW_ID["${svc}"]="$(running_image_id "${svc}")"
  if [[ "${OLD_ID[${svc}]}" != "${NEW_ID[${svc}]}" ]]; then
    changed+=("${svc}")
  fi
done

if (( ${#changed[@]} == 0 )); then
  printf '==> No image changes; all services already up to date.\n'
else
  printf '==> Recreated: %s\n' "${changed[*]}"
fi

# --- Verify functional health -----------------------------------------------
printf '==> Running health checks...\n'
if "${SCRIPT_DIR}/health-check.sh"; then
  printf '==> Update complete and healthy.\n'
  exit 0
fi

# --- Health failed: print manual rollback guidance (no auto rollback) -------
printf 'ERROR: health checks failed after update.\n' >&2
printf 'No automatic rollback was performed. To roll back manually, run the\n' >&2
printf 'commands below to re-pin each changed service to its previously running\n' >&2
printf 'image and recreate it:\n' >&2
if (( ${#changed[@]} == 0 )); then
  printf '  (No service image changed during this update; nothing to roll back.)\n' >&2
else
  for svc in "${changed[@]}"; do
    old="${OLD_ID[${svc}]:-}"
    ref="${CFG_REF[${svc}]:-}"
    if [[ -n "${old}" && -n "${ref}" ]]; then
      printf '  # %s — restore previously running image:\n' "${svc}" >&2
      printf '  docker tag %s %s\n' "${old}" "${ref}" >&2
      printf '  docker compose --env-file ai/.env -f ai/compose.yaml up -d --no-deps --force-recreate %s\n' "${svc}" >&2
    else
      printf '  # WARNING: cannot build a rollback command for %s — ' "${svc}" >&2
      printf 'previous image ID or configured image reference is unknown ' >&2
      printf '(service was not running before this update). Recreate it manually from a known-good image.\n' >&2
    fi
  done
fi
exit 1
