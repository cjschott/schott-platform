#!/usr/bin/env bash
set -Eeuo pipefail

# health-check.sh — verify the LiteLLM gateway and model readiness.
#
# Checks, in order:
#   1. LiteLLM liveness.
#   2. Unauthenticated /v1/models is rejected.
#  2b. An invalid API key is rejected (authentication fails closed).
#   3. Authenticated /v1/models succeeds.
#   4. local-fast returns a non-empty completion.
#   5. local-embed returns a non-empty numeric vector.
#   6. local-general appears in the model inventory.
#   7. (--deep) local-general returns a bounded completion.
#
# The master key is read from ai/.env and never printed. Only concise pass/fail
# metadata is emitted — never full generated responses. Returns non-zero on any
# failure. Safe to run repeatedly.

trap 'printf "ERROR: %s failed unexpectedly at line %d\n" "$(basename "$0")" "${LINENO}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT}/ai/.env"

DEEP=0
for arg in "$@"; do
  case "${arg}" in
    --deep) DEEP=1 ;;
    -h|--help)
      printf 'Usage: %s [--deep]\n' "$(basename "$0")"; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "${arg}" >&2; exit 2 ;;
  esac
done

# --- Load configuration (key never printed) ---------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  printf 'ERROR: missing local secret file: ai/.env\n' >&2
  exit 1
fi

read_env() {  # read_env <VAR> ; echoes the raw value from ai/.env
  local v="$1" val
  val="$(grep -E "^[[:space:]]*${v}=" "${ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

MASTER_KEY="$(read_env LITELLM_MASTER_KEY)"
if [[ -z "${MASTER_KEY//[[:space:]]/}" ]]; then
  printf 'ERROR: LITELLM_MASTER_KEY is empty in ai/.env\n' >&2
  exit 1
fi

PORT="$(read_env LITELLM_PORT)"; PORT="${PORT:-4000}"
# For on-host checks connect to loopback; a 0.0.0.0/empty bind is not routable.
HOST="$(read_env LITELLM_HEALTH_HOST)"; HOST="${HOST:-127.0.0.1}"
BASE_URL="${LITELLM_URL:-http://${HOST}:${PORT}}"

CONNECT_TIMEOUT=5
MAX_TIME=20
DEEP_MAX_TIME=180

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

BODY="$(mktemp)"; MODELS_BODY="$(mktemp)"
cleanup() { rm -f "${BODY}" "${MODELS_BODY}"; }
trap cleanup EXIT

# get_code writes the response body to $BODY and echoes the HTTP status code.
# <auth> is 0 (no header), 1 (the real master key), or a literal token to send.
get_code() {  # get_code <max-time> <auth:0|1|token> <method> <url> [json-data]
  local mt="$1" auth="$2" method="$3" url="$4" data="${5-}"
  local -a args=(-sS -o "${BODY}" -w '%{http_code}'
                 --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${mt}"
                 -X "${method}")
  case "${auth}" in
    0) ;;
    1) args+=(-H "Authorization: Bearer ${MASTER_KEY}") ;;
    *) args+=(-H "Authorization: Bearer ${auth}") ;;
  esac
  if [[ -n "${data}" ]]; then
    args+=(-H "Content-Type: application/json" --data "${data}")
  fi
  curl "${args[@]}" "${url}" 2>/dev/null || printf '000'
}

is_2xx() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }

# --- 1. LiteLLM liveness ----------------------------------------------------
code="$(get_code "${MAX_TIME}" 0 GET "${BASE_URL}/health/liveliness")"
if is_2xx "${code}"; then
  pass "LiteLLM liveness (${code})"
else
  fail "LiteLLM liveness failed (${code}) at ${BASE_URL}/health/liveliness"
fi

# --- 2. Unauthenticated /v1/models is rejected ------------------------------
# Only an explicit authentication rejection counts. A 000 (no connection), 404,
# 429, or 5xx is NOT proof that auth rejected the request.
code="$(get_code "${MAX_TIME}" 0 GET "${BASE_URL}/v1/models")"
if [[ "${code}" == "401" || "${code}" == "403" ]]; then
  pass "unauthenticated /v1/models rejected (${code})"
else
  fail "unauthenticated /v1/models not rejected by auth (got ${code}; expected 401 or 403)"
fi

# --- 2b. An invalid API key is rejected -------------------------------------
# A request carrying a well-formed but wrong bearer token must never succeed.
# The rejection code varies with deployment shape and both are fail-closed:
#   401 — the key is absent or malformed, or a key database rejected it.
#   400 — this baseline runs with no key database, so LiteLLM cannot look up a
#         non-master key and returns "No connected db." Access is still denied.
# The load-bearing assertion is that the response is NOT 2xx; the accepted codes
# below are a secondary check that auth (not a timeout or 5xx) did the rejecting.
INVALID_KEY="sk-invalid-health-probe-000"
code="$(get_code "${MAX_TIME}" "${INVALID_KEY}" GET "${BASE_URL}/v1/models")"
if is_2xx "${code}"; then
  fail "invalid API key was ACCEPTED (${code}) — authentication is NOT failing closed"
elif [[ "${code}" == "400" || "${code}" == "401" || "${code}" == "403" ]]; then
  pass "invalid API key rejected (${code})"
else
  fail "invalid API key not rejected by auth (got ${code}; expected 400, 401, or 403)"
fi

# --- 3. Authenticated /v1/models succeeds -----------------------------------
code="$(get_code "${MAX_TIME}" 1 GET "${BASE_URL}/v1/models")"
if is_2xx "${code}"; then
  cp "${BODY}" "${MODELS_BODY}"
  pass "authenticated /v1/models (${code})"
else
  fail "authenticated /v1/models failed (${code})"
fi

# --- 4. local-fast returns a non-empty completion ---------------------------
code="$(get_code "${MAX_TIME}" 1 POST "${BASE_URL}/v1/chat/completions" \
  '{"model":"local-fast","messages":[{"role":"user","content":"ping"}],"max_tokens":16}')"
if is_2xx "${code}" && grep -Eq '"content"[[:space:]]*:[[:space:]]*"[^"]+"' "${BODY}"; then
  pass "local-fast completion (${code}, non-empty)"
else
  fail "local-fast completion failed (${code}) or returned empty content"
fi

# --- 5. local-embed returns a non-empty numeric vector ----------------------
code="$(get_code "${MAX_TIME}" 1 POST "${BASE_URL}/v1/embeddings" \
  '{"model":"local-embed","input":"ping"}')"
if is_2xx "${code}" && grep -Eq '"embedding"[[:space:]]*:[[:space:]]*\[[[:space:]]*-?[0-9]' "${BODY}"; then
  pass "local-embed embedding (${code}, numeric vector)"
else
  fail "local-embed embedding failed (${code}) or returned no numeric vector"
fi

# --- 6. local-general appears in the model inventory ------------------------
if grep -q 'local-general' "${MODELS_BODY}" 2>/dev/null; then
  pass "local-general present in model inventory"
else
  fail "local-general missing from model inventory"
fi

# --- 7. (--deep) local-general bounded completion ---------------------------
if (( DEEP )); then
  code="$(get_code "${DEEP_MAX_TIME}" 1 POST "${BASE_URL}/v1/chat/completions" \
    '{"model":"local-general","messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":32}')"
  if is_2xx "${code}" && grep -Eq '"content"[[:space:]]*:[[:space:]]*"[^"]+"' "${BODY}"; then
    pass "local-general deep completion (${code}, non-empty)"
  else
    fail "local-general deep completion failed (${code}) or returned empty content"
  fi
fi

# --- Result -----------------------------------------------------------------
if (( failures > 0 )); then
  printf '\nhealth-check: %d check(s) failed at %s\n' "${failures}" "${BASE_URL}" >&2
  exit 1
fi
printf '\nhealth-check: all checks passed at %s\n' "${BASE_URL}"
