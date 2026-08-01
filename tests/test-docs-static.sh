#!/usr/bin/env bash
set -Eeuo pipefail

# Static documentation assertions for the Schott Platform.
#
# This script requires only Bash and standard POSIX utilities. It can run in CI
# without access to schai, Docker, the network, or secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

assert_file() {
  local rel="$1"
  if [[ -f "${ROOT}/${rel}" ]]; then
    pass "file exists: ${rel}"
  else
    fail "required file missing: ${rel}"
  fi
}

assert_dir() {
  local rel="$1"
  if [[ -d "${ROOT}/${rel}" ]]; then
    pass "directory exists: ${rel}"
  else
    fail "required directory missing: ${rel}"
  fi
}

assert_contains() {
  local rel="$1"
  local pattern="$2"
  local description="$3"

  if [[ -f "${ROOT}/${rel}" ]] && grep -Eq "${pattern}" "${ROOT}/${rel}"; then
    pass "${description}"
  else
    fail "${description} (expected /${pattern}/ in ${rel})"
  fi
}

assert_markdown_links() {
  local file="$1"
  local file_dir
  local target
  local normalized
  local failed=0

  file_dir="$(dirname "${ROOT}/${file}")"

  while IFS= read -r target; do
    [[ -z "${target}" ]] && continue

    # Ignore anchors, external URLs, mail links, and template values.
    case "${target}" in
      \#*|http://*|https://*|mailto:*|\<*\>)
        continue
        ;;
    esac

    target="${target%%#*}"
    [[ -z "${target}" ]] && continue

    if [[ "${target}" == /* ]]; then
      normalized="${ROOT}${target}"
    else
      normalized="${file_dir}/${target}"
    fi

    if [[ ! -e "${normalized}" ]]; then
      fail "broken Markdown link in ${file}: ${target}"
      failed=1
    fi
  done < <(grep -Eo '\[[^]]+\]\([^)]+\)' "${ROOT}/${file}" \
    | sed -E 's/^.*\]\(([^)]+)\)$/\1/' || true)

  if [[ "${failed}" -eq 0 ]]; then
    pass "Markdown links resolve: ${file}"
  fi
}

# Required governance structure.
assert_dir "docs/architecture"
assert_dir "docs/standards"
assert_dir "docs/decisions"
assert_dir "docs/security"

# Required foundation documents.
REQUIRED_DOCS=(
  "docs/architecture/network-architecture.md"
  "docs/standards/linux-server-security-standard.md"
  "docs/standards/service-exposure-standard.md"
  "docs/decisions/ADR-0001-schai-reference-host.md"
  "docs/security/network-policy.md"
  "docs/platform-roadmap.md"
  "docs/standards/operational-metadata-standard.md"
)

for document in "${REQUIRED_DOCS[@]}"; do
  assert_file "${document}"
done

# Architecture Decision Record requirements.
ADR="docs/decisions/ADR-0001-schai-reference-host.md"
assert_contains "${ADR}" '^# ADR-0001:' \
  "ADR-0001 has the expected title"
assert_contains "${ADR}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' \
  "ADR-0001 status is Accepted"
assert_contains "${ADR}" '^## Context' \
  "ADR-0001 contains Context"
assert_contains "${ADR}" '^## Decision' \
  "ADR-0001 contains Decision"
assert_contains "${ADR}" '^## Consequences' \
  "ADR-0001 contains Consequences"
assert_contains "${ADR}" 'schai' \
  "ADR-0001 identifies schai"
assert_contains "${ADR}" 'Ansible' \
  "ADR-0001 connects the reference host to automation"

# Standard document requirements.
LINUX_STANDARD="docs/standards/linux-server-security-standard.md"
assert_contains "${LINUX_STANDARD}" '^# ' \
  "Linux security standard has a title"
assert_contains "${LINUX_STANDARD}" 'SSH' \
  "Linux security standard covers SSH"
assert_contains "${LINUX_STANDARD}" 'firewall|Firewall' \
  "Linux security standard covers firewall policy"
assert_contains "${LINUX_STANDARD}" 'Docker' \
  "Linux security standard covers Docker"
assert_contains "${LINUX_STANDARD}" 'backup|Backup' \
  "Linux security standard covers backups"

EXPOSURE_STANDARD="docs/standards/service-exposure-standard.md"
assert_contains "${EXPOSURE_STANDARD}" 'Administrative' \
  "Service exposure standard defines Administrative exposure"
assert_contains "${EXPOSURE_STANDARD}" 'Application' \
  "Service exposure standard defines Application exposure"
assert_contains "${EXPOSURE_STANDARD}" 'Infrastructure' \
  "Service exposure standard defines Infrastructure exposure"
assert_contains "${EXPOSURE_STANDARD}" 'Private' \
  "Service exposure standard defines Private exposure"
assert_contains "${EXPOSURE_STANDARD}" 'Ollama' \
  "Service exposure standard classifies Ollama"
assert_contains "${EXPOSURE_STANDARD}" 'LiteLLM' \
  "Service exposure standard classifies LiteLLM"

# Operational metadata standard requirements.
#
# The Platform Ontology Standard requires every entity to carry "Operational
# metadata" but does not define it. This standard supplies that definition and
# governs how declared, observed, and inferred facts are distinguished in
# platform-model records.
METADATA_STANDARD="docs/standards/operational-metadata-standard.md"
assert_contains "${METADATA_STANDARD}" '^# Operational Metadata Standard' \
  "operational metadata standard has the expected title"
assert_contains "${METADATA_STANDARD}" '^## Purpose' \
  "operational metadata standard states a purpose"
assert_contains "${METADATA_STANDARD}" '^## Scope' \
  "operational metadata standard states a scope"
assert_contains "${METADATA_STANDARD}" '`declared`' \
  "operational metadata standard defines the declared provenance class"
assert_contains "${METADATA_STANDARD}" '`observed`' \
  "operational metadata standard defines the observed provenance class"
assert_contains "${METADATA_STANDARD}" '`inferred`' \
  "operational metadata standard defines the inferred provenance class"
assert_contains "${METADATA_STANDARD}" '`unknown`' \
  "operational metadata standard defines the unknown provenance class"
assert_contains "${METADATA_STANDARD}" 'observed_at' \
  "operational metadata standard requires observed_at on observed facts"
assert_contains "${METADATA_STANDARD}" 'asserted' \
  "operational metadata standard aligns declared with the ontology asserted class"
assert_contains "${METADATA_STANDARD}" 'stale|Stale|freshness|Freshness' \
  "operational metadata standard defines freshness or staleness handling"
assert_contains "${METADATA_STANDARD}" 'platform-model/' \
  "operational metadata standard applies to the platform model"
assert_contains "${METADATA_STANDARD}" 'secret|Secret' \
  "operational metadata standard prohibits secret values"
assert_contains "${METADATA_STANDARD}" 'Platform Ontology Standard' \
  "operational metadata standard references the ontology standard"
assert_contains "${METADATA_STANDARD}" '^## Compliance' \
  "operational metadata standard defines compliance criteria"

# Network policy alignment.
NETWORK_POLICY="docs/security/network-policy.md"
assert_contains "${NETWORK_POLICY}" '192\.168\.86\.0/24' \
  "Network policy contains the application LAN"
assert_contains "${NETWORK_POLICY}" '192\.168\.86\.2-192\.168\.86\.99' \
  "Network policy contains the management address pool"
assert_contains "${NETWORK_POLICY}" '4000/tcp' \
  "Network policy defines LiteLLM port 4000"
assert_contains "${NETWORK_POLICY}" '11434/tcp' \
  "Network policy defines Ollama port 11434"
assert_contains "${NETWORK_POLICY}" 'Ollama must never be exposed' \
  "Network policy prohibits direct Ollama exposure"
assert_contains "${NETWORK_POLICY}" 'DOCKER-USER' \
  "Network policy documents Docker firewall behavior"
assert_contains "${NETWORK_POLICY}" 'ADR-0001' \
  "Network policy references ADR-0001"
assert_contains "${NETWORK_POLICY}" 'Ansible' \
  "Network policy describes future automation"

# Roadmap requirements.
ROADMAP="docs/platform-roadmap.md"
assert_contains "${ROADMAP}" '^# Schott Platform Roadmap' \
  "roadmap has the expected title"
assert_contains "${ROADMAP}" 'v0\.2\.x' \
  "roadmap defines the foundation release"
assert_contains "${ROADMAP}" 'v0\.3\.x' \
  "roadmap defines the automation release"
assert_contains "${ROADMAP}" 'v0\.4\.x' \
  "roadmap defines the observability release"
assert_contains "${ROADMAP}" 'v0\.6\.x' \
  "roadmap defines the Kyri release"
assert_contains "${ROADMAP}" 'v1\.0' \
  "roadmap defines the v1.0 target"
assert_contains "${ROADMAP}" 'Manual once\. Automated forever\.' \
  "roadmap preserves the automation principle"

# Validate relative Markdown links in the new governance documents.
for document in "${REQUIRED_DOCS[@]}"; do
  assert_markdown_links "${document}"
done

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nStatic documentation validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nStatic documentation validation passed.\n'
