#!/usr/bin/env bash
set -Eeuo pipefail

# validate-config.sh — static preflight for the canonical AI platform stack.
#
# Verifies required tooling, required files, a present and non-empty local
# master key, Docker Compose rendering, shell syntax, and (where tooling
# exists) YAML syntax. Reports one actionable error per failed condition and
# exits non-zero if any check fails. Safe to run repeatedly. Never prints the
# master key.

trap 'printf "ERROR: %s failed unexpectedly at line %d\n" "$(basename "$0")" "${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${ROOT}/ai/compose.yaml"
ENV_FILE="${ROOT}/ai/.env"

errors=0
err()  { printf 'ERROR: %s\n' "$1" >&2; errors=$((errors + 1)); }
note() { printf '%s\n'        "$1"; }

# --- Required commands ------------------------------------------------------
for cmd in docker bash tar; do
  command -v "${cmd}" >/dev/null 2>&1 \
    || err "required command not found on PATH: ${cmd}"
done
if command -v docker >/dev/null 2>&1; then
  docker compose version >/dev/null 2>&1 \
    || err "Docker Compose v2 plugin is unavailable ('docker compose' does not work)"
fi

# --- Required files ---------------------------------------------------------
for rel in "ai/compose.yaml" "ai/litellm/config.yaml" "ai/.env.example"; do
  [[ -f "${ROOT}/${rel}" ]] \
    || err "required file missing: ${rel}"
done

# --- Local secret file must exist -------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  err "missing local secret file: ai/.env (copy ai/.env.example to ai/.env and set a real LITELLM_MASTER_KEY)"
fi

# --- Master key must be present and non-empty (never printed) ---------------
if [[ -f "${ENV_FILE}" ]]; then
  key_value="$(grep -E '^[[:space:]]*LITELLM_MASTER_KEY=' "${ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
  key_value="${key_value%\"}"; key_value="${key_value#\"}"
  key_value="${key_value%\'}"; key_value="${key_value#\'}"
  if [[ -z "${key_value//[[:space:]]/}" ]]; then
    err "LITELLM_MASTER_KEY is empty in ai/.env — set a strong, unique, non-empty key"
  fi
  unset key_value
fi

# --- Shell syntax of every operations script --------------------------------
while IFS= read -r script; do
  bash -n "${script}" 2>/dev/null \
    || err "shell syntax error: ${script#"${ROOT}/"}"
done < <(find "${ROOT}/scripts" -type f -name '*.sh')

# --- YAML syntax where suitable tooling exists ------------------------------
yaml_files=("${ROOT}/ai/compose.yaml" "${ROOT}/ai/litellm/config.yaml")
if command -v yamllint >/dev/null 2>&1; then
  for y in "${yaml_files[@]}"; do
    [[ -f "${y}" ]] || continue
    yamllint -d relaxed "${y}" >/dev/null 2>&1 \
      || err "YAML lint failed: ${y#"${ROOT}/"}"
  done
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  for y in "${yaml_files[@]}"; do
    [[ -f "${y}" ]] || continue
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "${y}" >/dev/null 2>&1 \
      || err "YAML parse failed: ${y#"${ROOT}/"}"
  done
else
  note "SKIP: YAML syntax lint (no yamllint or python3+PyYAML available)"
fi

# --- Docker Compose rendering (output discarded so no secret is printed) -----
if command -v docker >/dev/null 2>&1 && [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]]; then
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" config >/dev/null 2>&1 \
    || err "docker compose failed to render ai/compose.yaml with ai/.env"
fi

# --- Result -----------------------------------------------------------------
if (( errors > 0 )); then
  printf '\nvalidate-config: %d error(s) found.\n' "${errors}" >&2
  exit 1
fi
note "validate-config: all checks passed."
