#!/usr/bin/env bash
set -Eeuo pipefail

# Run ShellCheck at the version CI runs, without installing a host package.
#
# CI does not pin ShellCheck itself — it uses whatever ubuntu-24.04 ships, which
# was observed as 0.9.0. Local tooling pins that observed value so a developer
# and CI cannot disagree about findings without either noticing.
#
# Resolution order:
#   1. A pinned container image. Requires no host package and gives the exact
#      CI version on any machine that has Docker.
#   2. A host ShellCheck, but only when its version matches the manifest
#      exactly. A different version may report different findings, which is the
#      divergence this script exists to prevent.
#
# If neither is available this script fails and prints the exact remediation.
# It never installs anything, and it never skips: a skipped lint that reports
# success is worse than no lint at all.
#
# Usage:
#   tools/dev/run-shellcheck.sh            # lint the repository's shell scripts
#   tools/dev/run-shellcheck.sh --list     # print the resolved file list
#   tools/dev/run-shellcheck.sh --probe    # report the execution path, lint nothing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# versions.env holds only shell-safe assignments. Following it would require
# `shellcheck -x`, and CI invokes shellcheck without that flag; adding it here
# only would make local and CI lint differently, which is the divergence this
# script exists to prevent.
set -a
# shellcheck source=tools/dev/versions.env disable=SC1091
. "${SCRIPT_DIR}/versions.env"
set +a

MODE="run"
case "${1:-}" in
  --list) MODE="list" ;;
  --probe) MODE="probe" ;;
  "") ;;
  *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

# CI lints `scripts/*.sh tests/*.sh`. The dev scripts are linted too, because a
# tool that lints everything except itself is the one place a defect hides.
collect_targets() {
  local -a found=()
  local path
  for path in "${ROOT}"/scripts/*.sh "${ROOT}"/tests/*.sh "${ROOT}"/tools/dev/*.sh; do
    [[ -f "${path}" ]] && found+=("${path}")
  done
  printf '%s\n' "${found[@]}"
}

mapfile -t TARGETS < <(collect_targets)

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  printf 'ERROR no shell scripts found to lint; expected scripts/, tests/, tools/dev/\n' >&2
  exit 2
fi

if [[ "${MODE}" == "list" ]]; then
  printf '%s\n' "${TARGETS[@]#"${ROOT}"/}"
  exit 0
fi

host_shellcheck_version() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}'
}

remediation() {
  cat >&2 <<EOF

ShellCheck ${SHELLCHECK_VERSION} is required and was not found.

Either make the pinned container image available:

    docker pull ${SHELLCHECK_IMAGE}

or install ShellCheck ${SHELLCHECK_VERSION} on this host:

    sudo apt-get install --yes shellcheck

Installing a different version is not sufficient: a version mismatch between
this host and CI means findings can differ silently, which is exactly what the
pin exists to prevent. Nothing is installed automatically — see
tools/dev/bootstrap.sh.
EOF
}

# --- resolve an execution path --------------------------------------------
EXECUTION_PATH=""
HOST_VERSION="$(host_shellcheck_version || true)"

if [[ -n "${HOST_VERSION}" && "${HOST_VERSION}" == "${SHELLCHECK_VERSION}" ]]; then
  EXECUTION_PATH="host"
elif command -v docker >/dev/null 2>&1 && docker image inspect "${SHELLCHECK_IMAGE}" >/dev/null 2>&1; then
  # The image is already present. Nothing is pulled here: a lint run must not
  # reach the network as a side effect.
  EXECUTION_PATH="container"
fi

if [[ "${MODE}" == "probe" ]]; then
  if [[ -n "${EXECUTION_PATH}" ]]; then
    printf 'shellcheck execution path: %s (version %s)\n' "${EXECUTION_PATH}" "${SHELLCHECK_VERSION}"
    exit 0
  fi
  printf 'shellcheck execution path: unavailable (pinned version %s)\n' "${SHELLCHECK_VERSION}"
  if [[ -n "${HOST_VERSION}" ]]; then
    printf 'host shellcheck is %s, which does not match the pin\n' "${HOST_VERSION}"
  fi
  exit 1
fi

if [[ -z "${EXECUTION_PATH}" ]]; then
  if [[ -n "${HOST_VERSION}" ]]; then
    printf 'ERROR host shellcheck is %s but %s is pinned.\n' \
      "${HOST_VERSION}" "${SHELLCHECK_VERSION}" >&2
  else
    printf 'ERROR shellcheck is not available on this host.\n' >&2
  fi
  remediation
  exit 2
fi

printf '── ShellCheck %s (%s)\n' "${SHELLCHECK_VERSION}" "${EXECUTION_PATH}"

# CI runs shellcheck with no extra flags, so severity and format stay at their
# defaults here too. Matching CI matters more than a nicer local report.
if [[ "${EXECUTION_PATH}" == "host" ]]; then
  shellcheck "${TARGETS[@]}"
else
  # --network none because linting must never reach the network. Read-only
  # mount because a linter has no reason to write to the repository.
  docker run --rm --network none \
    --volume "${ROOT}:/mnt:ro" \
    --workdir /mnt \
    "${SHELLCHECK_IMAGE}" \
    "${TARGETS[@]#"${ROOT}"/}"
fi
