#!/usr/bin/env bash
set -Eeuo pipefail

# Verify the local toolchain against tools/dev/versions.env.
#
# Read-only. It inspects what is installed and reports; it installs nothing,
# changes nothing, and touches no service. Every failure names a remedy,
# because an error that only says "missing" leaves the reader to guess.
#
# Two severities:
#
#   error    validation cannot be trusted without this. Exits non-zero.
#   warning  validation will run, but local and CI differ in a way worth
#            knowing about. Escalated to an error under --strict.
#
# The PyYAML version is the warning that matters. A distro may ship a
# different 6.0.x build than the hash-pinned one CI installs. The suites pass
# either way, so failing a developer's run would be obstructive — but
# run-local-ci.sh uses --strict, because claiming CI parity while running a
# different library build would be a false claim.
#
# Usage:
#   tools/dev/check-toolchain.sh            # report; warnings do not fail
#   tools/dev/check-toolchain.sh --strict   # warnings become errors

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

set -a
# shellcheck source=tools/dev/versions.env disable=SC1091
. "${SCRIPT_DIR}/versions.env"
set +a

STRICT=0
case "${1:-}" in
  --strict) STRICT=1 ;;
  "") ;;
  *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

ERRORS=0
WARNINGS=0

ok()   { printf '  ok       %s\n' "$1"; }
warn() { printf '  warning  %s\n' "$1" >&2; WARNINGS=$((WARNINGS + 1)); }
err()  { printf '  ERROR    %s\n' "$1" >&2; ERRORS=$((ERRORS + 1)); }

# version_at_least <have> <want> — true when have >= want, compared numerically
# field by field. sort -V is avoided so the comparison does not depend on the
# host's sort implementation.
version_at_least() {
  local have="$1" want="$2" i
  local -a h w
  IFS='.' read -r -a h <<<"${have}"
  IFS='.' read -r -a w <<<"${want}"
  for i in 0 1 2; do
    local hv="${h[i]:-0}" wv="${w[i]:-0}"
    hv="${hv//[^0-9]/}"; wv="${wv//[^0-9]/}"
    hv="${hv:-0}"; wv="${wv:-0}"
    if (( hv > wv )); then return 0; fi
    if (( hv < wv )); then return 1; fi
  done
  return 0
}

printf '── Toolchain (manifest: tools/dev/versions.env)\n'

# --- python3 ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  python_version="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo "0")"
  if version_at_least "${python_version}" "${PYTHON_MIN_VERSION}"; then
    ok "python3 ${python_version} (minimum ${PYTHON_MIN_VERSION})"
  else
    err "python3 ${python_version} is older than the ${PYTHON_MIN_VERSION} minimum. Install a newer python3: sudo apt-get install --yes python3"
  fi
else
  err "python3 is not installed. Install it: sudo apt-get install --yes python3 (or run tools/dev/bootstrap.sh)"
fi

# --- PyYAML ----------------------------------------------------------------
# Presence is a hard error: every behavioural suite depends on it, and the
# whole point of this increment is that a missing PyYAML must never produce a
# green run.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  pyyaml_version="$(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null || echo "unknown")"
  # PYYAML_VERSION comes from the sourced manifest, which shellcheck cannot
  # follow without -x; the similar local name is what triggers the warning.
  # shellcheck disable=SC2153
  if [[ "${pyyaml_version}" == "${PYYAML_VERSION}" ]]; then
    ok "PyYAML ${pyyaml_version} (matches the pinned CI version)"
  else
    warn "PyYAML ${pyyaml_version} differs from the pinned CI version ${PYYAML_VERSION}. CI installs the hash-pinned build with: ${PINNED_PIP_INSTALL}"
  fi
else
  err "PyYAML is not importable. Every behavioural suite needs it. Install it: ${PINNED_PIP_INSTALL}"
fi

# --- Docker Compose --------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  compose_version="$(docker compose version --short 2>/dev/null || echo "0")"
  compose_version="${compose_version#v}"
  if version_at_least "${compose_version}" "${DOCKER_COMPOSE_MIN_VERSION}"; then
    ok "Docker Compose ${compose_version} (minimum ${DOCKER_COMPOSE_MIN_VERSION})"
  else
    err "Docker Compose ${compose_version} is older than the ${DOCKER_COMPOSE_MIN_VERSION} minimum. The platform requires Compose v2."
  fi
else
  err "Docker Compose v2 is not available. Configuration rendering needs it. Install it: sudo apt-get install --yes docker-compose-plugin"
fi

# --- git -------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  git_version="$(git --version 2>/dev/null | awk '{print $3}')"
  if version_at_least "${git_version}" "${GIT_MIN_VERSION}"; then
    ok "git ${git_version} (minimum ${GIT_MIN_VERSION})"
  else
    warn "git ${git_version} is older than the ${GIT_MIN_VERSION} this repository has been validated against"
  fi
else
  err "git is not installed. Install it: sudo apt-get install --yes git"
fi

# --- ShellCheck execution path ---------------------------------------------
# Delegated so there is one definition of "can we lint", rather than two that
# can disagree.
if probe_output="$("${SCRIPT_DIR}/run-shellcheck.sh" --probe 2>&1)"; then
  ok "ShellCheck ${SHELLCHECK_VERSION} via ${probe_output#*path: }"
else
  err "No ShellCheck ${SHELLCHECK_VERSION} execution path. Make the pinned image available: docker pull ${SHELLCHECK_IMAGE} (or run tools/dev/bootstrap.sh)"
fi

# --- repository sanity -----------------------------------------------------
if [[ -f "${ROOT}/requirements-ci.txt" ]]; then
  ok "requirements-ci.txt present"
else
  err "requirements-ci.txt is missing; the pinned dependency set cannot be installed"
fi

printf '\n'
if (( ERRORS > 0 )); then
  printf 'Toolchain check failed: %d error(s), %d warning(s).\n' "${ERRORS}" "${WARNINGS}" >&2
  printf 'Run tools/dev/bootstrap.sh to see the exact commands that would fix this.\n' >&2
  exit 1
fi

if (( WARNINGS > 0 )); then
  if (( STRICT == 1 )); then
    printf 'Toolchain check failed under --strict: %d warning(s).\n' "${WARNINGS}" >&2
    exit 1
  fi
  printf 'Toolchain check passed with %d warning(s).\n' "${WARNINGS}"
  exit 0
fi

printf 'Toolchain check passed.\n'
