#!/usr/bin/env bash
set -Eeuo pipefail

# Run locally what .github/workflows/ci.yml runs remotely, and say plainly
# where the two cannot match.
#
# This is a thin wrapper over run-validation.sh rather than a second copy of
# the validation order. Two lists of steps drift; one list cannot.
#
# It runs the toolchain check in --strict mode. A warning that local and CI
# use different tool versions is tolerable in an edit loop, but this script's
# whole claim is "what CI will do", and making that claim while running a
# different PyYAML build would be a false one.
#
# It calls no GitHub API, pushes nothing, creates no branch, starts no platform
# container, and modifies neither the host nor platform-model.
#
# Usage:
#   tools/dev/run-local-ci.sh          # strict, full validation
#   tools/dev/run-local-ci.sh --report # print the parity summary only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

WORKFLOW=".github/workflows/ci.yml"
REPORT_ONLY=0
case "${1:-}" in
  --report) REPORT_ONLY=1 ;;
  "") ;;
  *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

parity_summary() {
  cat <<'EOF'
── CI / local parity

Covered locally, identical command:

  shell syntax                 bash -n over scripts, tests, tools/dev
  static repository assertions tests/test-static.sh
  static documentation         tests/test-docs-static.sh
  platform model               tests/test-platform-model.sh
  evidence validator           tests/test-evidence-validator.sh
  collector framework          tests/test-collector-framework.sh
  initial collectors           tests/test-initial-collectors.sh
  knowledge orchestrator       tests/test-knowledge-orchestrator.sh
  evidence definitions         tools/platform_model/validate_evidence.py
  collector manifests          tools/collectors/validate_plugins.py
  compose renders              docker compose config, all three files
  runtime evidence backstop    committed EVID/VER/MEM/OBS records
  shellcheck                   pinned 0.9.0, same file list as CI

Known gaps — these cannot be reproduced locally and are reported, not hidden:

  Gitleaks     runs as a separate workflow against full history; secret
               scanning of the commit graph is not reproduced here.
  Semgrep      separate workflow with its own hosted ruleset.
  Trivy        separate workflow; filesystem vulnerability scan.
  CodeQL       separate workflow; requires GitHub's analysis service.
  dependency   CI installs the hash-pinned PyYAML wheel before running any
  install      suite. This script verifies the installed version matches but
               does not install it, because installing is a host change and
               needs explicit approval (tools/dev/bootstrap.sh).

A green run here means the CI validation job should pass. It does not mean the
four security workflows will pass; those run only on GitHub.
EOF
}

parity_summary

if (( REPORT_ONLY == 1 )); then
  exit 0
fi

if [[ ! -f "${WORKFLOW}" ]]; then
  printf '\nERROR %s is missing; cannot claim parity with a workflow that does not exist.\n' \
    "${WORKFLOW}" >&2
  exit 2
fi

printf '\n── Running local validation in strict mode\n'
printf '   (mirrors the "%s" validation job)\n' "${WORKFLOW}"

# Delegated, not duplicated. If a suite is added to run-validation.sh it is
# picked up here automatically.
"${SCRIPT_DIR}/run-validation.sh" --strict
status=$?

printf '\nLocal CI wrapper finished (exit %d).\n' "${status}"
printf 'Security workflows (Gitleaks, Semgrep, Trivy, CodeQL) still run only on GitHub.\n'
exit "${status}"
