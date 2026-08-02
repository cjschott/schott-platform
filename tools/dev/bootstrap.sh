#!/usr/bin/env bash
set -Eeuo pipefail

# Report what the local toolchain is missing, and print the exact commands that
# would fix it.
#
# Dry-run is the default and installs nothing. `--apply` is the only way to
# change the host, and even then it installs only the specific packages this
# repository needs to validate itself.
#
# It never touches Docker services, volumes, containers, firewall rules, SSH
# configuration, or ai/.env. A developer bootstrap that reconfigures a host is
# how a "quick setup" becomes an outage.
#
# Idempotent: running it twice with nothing installed in between produces
# identical output, and running it when everything is present reports that and
# does nothing.
#
# Usage:
#   tools/dev/bootstrap.sh           # dry run: report and print commands
#   tools/dev/bootstrap.sh --apply   # install the listed packages
#   tools/dev/bootstrap.sh --help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

set -a
# shellcheck source=tools/dev/versions.env disable=SC1091
. "${SCRIPT_DIR}/versions.env"
set +a

DRY_RUN=1

usage() {
  cat <<EOF
Usage: tools/dev/bootstrap.sh [--apply|--help]

  (no flag)  Dry run. Reports missing tools and prints exact commands.
             Changes nothing.
  --apply    Install the reported packages. Requires sudo. Installs only the
             packages listed below and nothing else.
  --help     This message.
EOF
}

case "${1:-}" in
  --apply) DRY_RUN=0 ;;
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) printf 'ERROR unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac

# Commands are collected rather than run, so dry-run and apply operate on
# exactly the same list. A dry run that computes a different list from the
# apply path is not a preview of anything.
declare -a APT_PACKAGES=()
declare -a MANUAL_STEPS=()
declare -a SATISFIED=()

need_apt() { APT_PACKAGES+=("$1"); }
need_manual() { MANUAL_STEPS+=("$1"); }
satisfied() { SATISFIED+=("$1"); }

# --- inspect ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  satisfied "python3 $(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
else
  need_apt "python3"
fi

if python3 -c 'import yaml' >/dev/null 2>&1; then
  installed_pyyaml="$(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null || echo unknown)"
  if [[ "${installed_pyyaml}" == "${PYYAML_VERSION}" ]]; then
    satisfied "PyYAML ${installed_pyyaml}"
  else
    # Not an apt package: CI installs the hash-pinned wheel, and matching that
    # exactly is the only way local parsing matches CI parsing.
    need_manual "${PINNED_PIP_INSTALL}    # PyYAML ${installed_pyyaml} -> ${PYYAML_VERSION} (matches CI)"
  fi
else
  need_manual "${PINNED_PIP_INSTALL}    # PyYAML is required by every behavioural suite"
fi

if command -v git >/dev/null 2>&1; then
  satisfied "git $(git --version | awk '{print $3}')"
else
  need_apt "git"
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  satisfied "Docker Compose $(docker compose version --short 2>/dev/null || echo present)"
else
  need_apt "docker-compose-plugin"
fi

if "${SCRIPT_DIR}/run-shellcheck.sh" --probe >/dev/null 2>&1; then
  satisfied "ShellCheck ${SHELLCHECK_VERSION}"
else
  # The image is preferred because it pins the version without touching the
  # host. Pulling is a network operation and is never done implicitly.
  need_manual "docker pull ${SHELLCHECK_IMAGE}    # pinned ShellCheck ${SHELLCHECK_VERSION}, no host package needed"
fi

# --- report ----------------------------------------------------------------
if (( DRY_RUN == 1 )); then
  printf '── Bootstrap (dry run — nothing will be installed)\n\n'
else
  printf '── Bootstrap (--apply — packages will be installed)\n\n'
fi

if (( ${#SATISFIED[@]} > 0 )); then
  printf 'Already present:\n'
  printf '  ok  %s\n' "${SATISFIED[@]}"
  printf '\n'
fi

if (( ${#APT_PACKAGES[@]} == 0 && ${#MANUAL_STEPS[@]} == 0 )); then
  printf 'Nothing to do. The toolchain is complete.\n'
  printf 'Verify with: tools/dev/check-toolchain.sh\n'
  exit 0
fi

if (( ${#APT_PACKAGES[@]} > 0 )); then
  printf 'Missing host packages:\n'
  printf '  - %s\n' "${APT_PACKAGES[@]}"
  printf '\nExact command:\n\n'
  printf '    sudo apt-get update && sudo apt-get install --yes %s\n\n' "${APT_PACKAGES[*]}"
fi

if (( ${#MANUAL_STEPS[@]} > 0 )); then
  printf 'Steps that are not host packages:\n\n'
  printf '    %s\n' "${MANUAL_STEPS[@]}"
  printf '\n'
fi

if (( DRY_RUN == 1 )); then
  cat <<EOF
This was a dry run. Nothing was installed and the host was not modified.

To install the host packages listed above:

    tools/dev/bootstrap.sh --apply

Steps that are not host packages are never run by --apply; copy and run them
yourself so the change stays deliberate.
EOF
  exit 0
fi

# --- apply -----------------------------------------------------------------
if (( ${#APT_PACKAGES[@]} == 0 )); then
  printf 'No host packages to install. The remaining steps above are manual by design.\n'
  exit 0
fi

printf 'Installing %d package(s) with apt-get...\n\n' "${#APT_PACKAGES[@]}"
sudo apt-get update
sudo apt-get install --yes "${APT_PACKAGES[@]}"

printf '\nDone. Verify with: tools/dev/check-toolchain.sh\n'
printf 'Repository root: %s\n' "${ROOT}"
