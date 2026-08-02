#!/usr/bin/env bash
set -Eeuo pipefail

# One command that runs everything CI runs, in a deterministic order.
#
# Stops at the first failure and preserves that command's exit code, so the
# status this script returns is the status of the thing that actually broke.
#
# It contacts no host, installs nothing, starts no platform container, writes
# nothing into the repository, persists no evidence, and never reads ai/.env.
# The only container it may start is the pinned ShellCheck image, which is
# ephemeral, network-isolated, and mounts the repository read-only.
#
# Usage:
#   tools/dev/run-validation.sh           # everything (20 steps)
#   tools/dev/run-validation.sh --quick   # skip the slowest suites
#   tools/dev/run-validation.sh --strict  # toolchain warnings become errors
#
# What --quick omits, and nothing else:
#
#   - tests/test-platform-model.sh      (848 assertions, the slowest suite)
#   - tests/test-initial-collectors.sh  (builds temporary git repositories)
#   - tests/test-knowledge-orchestrator.sh (builds temporary evidence stores)
#   - the three Docker Compose renders  (each spawns the compose binary)
#
# Quick mode still runs syntax checking, ShellCheck, both static suites, both
# Python validators, the CLI checks, the bytecode check, and the whitespace
# check. It is for a tight edit loop; it is never sufficient before pushing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

QUICK=0
STRICT=0
for argument in "$@"; do
  case "${argument}" in
    --quick) QUICK=1 ;;
    --strict) STRICT=1 ;;
    --help|-h)
      sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'ERROR unknown argument: %s\n' "${argument}" >&2; exit 2 ;;
  esac
done

STEP=0
STARTED_AT="$(date -Is)"

section() {
  STEP=$((STEP + 1))
  printf '\n[%02d/%s] %s\n' "${STEP}" "${TOTAL_STEPS}" "$1"
}

# run <description> <command...>
# Preserves the failing command's exit code rather than collapsing everything
# to 1, so a caller can tell a validation failure from an invocation error.
#
# The status is captured immediately after the command, not inside an
# `if ! "$@"` test: there $? is the status of the negation, which is 0 when the
# command failed. That mistake makes a validation script report a failure and
# then exit 0, which is the worst possible outcome for a tool whose entire job
# is to be believed.
run() {
  local description="$1"; shift
  local status=0
  section "${description}"
  set +e
  "$@"
  status=$?
  set -e
  if (( status != 0 )); then
    printf '\nFAILED: %s (exit %d)\n' "${description}" "${status}" >&2
    printf 'Validation stopped at step %d. Nothing after it ran.\n' "${STEP}" >&2
    exit "${status}"
  fi
}

skipped_note() {
  printf '\n[--] %s — omitted by --quick\n' "$1"
}

if (( QUICK == 1 )); then
  TOTAL_STEPS=16
  printf '── Validation (quick mode) — %s\n' "${STARTED_AT}"
else
  TOTAL_STEPS=20
  printf '── Validation (full) — %s\n' "${STARTED_AT}"
fi

# --- 1. toolchain ----------------------------------------------------------
if (( STRICT == 1 )); then
  run "Toolchain check (strict)" "${SCRIPT_DIR}/check-toolchain.sh" --strict
else
  run "Toolchain check" "${SCRIPT_DIR}/check-toolchain.sh"
fi

# --- 2. shell syntax -------------------------------------------------------
# Mirrors the CI "Shell syntax check" step.
syntax_check() {
  bash -n scripts/*.sh
  bash -n tests/*.sh
  bash -n tools/dev/*.sh
}
run "Shell syntax (bash -n)" syntax_check

# --- 3. shellcheck ---------------------------------------------------------
run "ShellCheck" "${SCRIPT_DIR}/run-shellcheck.sh"

# --- 4-5. static suites ----------------------------------------------------
run "Static repository assertions" bash tests/test-static.sh
run "Static documentation assertions" bash tests/test-docs-static.sh

# --- 6. platform model -----------------------------------------------------
if (( QUICK == 0 )); then
  run "Platform model validation" bash tests/test-platform-model.sh
else
  skipped_note "Platform model validation"
fi

# --- 7-9. remaining suites -------------------------------------------------
run "Evidence validator behaviour" bash tests/test-evidence-validator.sh
run "Collector framework" bash tests/test-collector-framework.sh

if (( QUICK == 0 )); then
  run "Initial read-only collectors" bash tests/test-initial-collectors.sh
  run "Knowledge orchestrator" bash tests/test-knowledge-orchestrator.sh
else
  skipped_note "Initial read-only collectors"
  skipped_note "Knowledge orchestrator"
fi

run "Developer experience" bash tests/test-developer-experience.sh

# --- 10-11. python validators ---------------------------------------------
run "Evidence and drift definitions" \
  python3 tools/platform_model/validate_evidence.py --root platform-model
run "Collector plugin manifests" \
  python3 tools/collectors/validate_plugins.py --root .

# --- 12-14. command line interfaces ---------------------------------------
cli_collectors_list() { python3 -m tools.collectors.cli list >/dev/null; }
cli_collectors_validate() { python3 -m tools.collectors.cli validate >/dev/null; }
cli_observation_help() { python3 -m tools.observation.cli --help >/dev/null; }
run "Collector CLI (list)" cli_collectors_list
run "Collector CLI (validate)" cli_collectors_validate
run "Observation CLI (help)" cli_observation_help

# --- 15. compose renders ---------------------------------------------------
# `config` only. This renders declared configuration and starts nothing.
compose_renders() {
  docker compose --env-file ai/.env.example -f ai/compose.yaml config >/dev/null
  docker compose --env-file ai/ollama/.env.example -f ai/ollama/compose.yaml config >/dev/null
  docker compose --env-file ai/litellm/.env.example -f ai/litellm/compose.yaml config >/dev/null
}
if (( QUICK == 0 )); then
  run "Docker Compose configuration renders" compose_renders
else
  skipped_note "Docker Compose configuration renders"
fi

# --- 16. whitespace --------------------------------------------------------
run "Whitespace (git diff --check)" git diff --check

# --- 17. tracked bytecode --------------------------------------------------
bytecode_check() {
  local tracked
  tracked="$(git ls-files '*__pycache__*' '*.pyc')"
  if [[ -n "${tracked}" ]]; then
    printf 'Tracked Python bytecode found:\n%s\n' "${tracked}" >&2
    return 1
  fi
  printf '  ok       no tracked Python bytecode\n'
}
run "Tracked bytecode" bytecode_check

# --- 18. runtime evidence backstop -----------------------------------------
# Generated records belong in an observation store outside the repository.
runtime_evidence_check() {
  local committed
  committed="$(git ls-files \
    'platform-model/evidence/EVID-*' \
    'platform-model/verifications/VER-*' \
    'platform-model/knowledge-events/MEM-*' \
    'platform-model/observations/OBS-*')"
  if [[ -n "${committed}" ]]; then
    printf 'Generated runtime records must not be committed:\n%s\n' "${committed}" >&2
    return 1
  fi
  local stray
  stray="$(find . -path ./.git -prune -o -name '*.tmp' -print 2>/dev/null)"
  if [[ -n "${stray}" ]]; then
    printf 'Partial store writes left behind:\n%s\n' "${stray}" >&2
    return 1
  fi
  printf '  ok       no committed runtime evidence, no partial writes\n'
}
run "Runtime evidence backstop" runtime_evidence_check

# --- 19. platform-model mutation backstop ----------------------------------
# The suites must be read-only with respect to the declared model. This runs
# last so it observes the state the suites left behind.
model_mutation_check() {
  local dirty
  dirty="$(git status --porcelain platform-model)"
  if [[ -n "${dirty}" ]]; then
    printf 'Validation modified platform-model; it must be read-only to tests:\n%s\n' "${dirty}" >&2
    return 1
  fi
  printf '  ok       platform-model unmodified\n'
}
run "Platform model mutation backstop" model_mutation_check

# --- 20. summary -----------------------------------------------------------
section "Summary"
if (( QUICK == 1 )); then
  cat <<EOF
  quick mode omitted:
    - tests/test-platform-model.sh
    - tests/test-initial-collectors.sh
    - tests/test-knowledge-orchestrator.sh
    - the three Docker Compose renders

  Run without --quick before pushing.
EOF
else
  printf '  all checks ran\n'
fi

printf '\nValidation passed (%s mode), started %s.\n' \
  "$( ((QUICK == 1)) && printf 'quick' || printf 'full')" "${STARTED_AT}"
