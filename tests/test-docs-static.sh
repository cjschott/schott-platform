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

assert_not_contains() {
  local rel="$1"
  local pattern="$2"
  local description="$3"

  if [[ ! -f "${ROOT}/${rel}" ]]; then
    fail "${description} (missing file ${rel})"
  elif grep -Eq "${pattern}" "${ROOT}/${rel}"; then
    fail "${description} (unexpected /${pattern}/ in ${rel})"
  else
    pass "${description}"
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
)

# Standards introduced on the v0.2.0 foundation branch. Every one of these must
# exist and satisfy the shared structural contract checked below.
BRANCH_STANDARDS=(
  "docs/standards/platform-filesystem-observability-standard.md"
  "docs/standards/platform-role-host-classification-standard.md"
  "docs/standards/docker-platform-standard.md"
  "docs/standards/platform-automation-standard.md"
  "docs/standards/service-catalog-standard.md"
  "docs/standards/runbook-standard.md"
  "docs/standards/dependency-mapping-standard.md"
  "docs/standards/operational-metadata-standard.md"
  "docs/standards/platform-ontology-standard.md"
  "docs/standards/definition-of-done-standard.md"
  "docs/standards/entity-lifecycle-standard.md"
  "docs/standards/evidence-standard.md"
  "docs/standards/verification-drift-standard.md"
)

for document in "${REQUIRED_DOCS[@]}"; do
  assert_file "${document}"
done

# Shared structural contract for every branch standard: it must exist, carry a
# title, and define its purpose, scope, and compliance criteria. A standard
# without compliance criteria cannot be audited against.
for standard in "${BRANCH_STANDARDS[@]}"; do
  name="$(basename "${standard}" .md)"
  assert_file "${standard}"
  assert_contains "${standard}" '^# ' "${name} has a title"
  assert_contains "${standard}" '^## Purpose' "${name} defines a purpose"
  assert_contains "${standard}" '^## Scope' "${name} defines a scope"
  assert_contains "${standard}" '^## Compliance' "${name} defines compliance criteria"
  assert_markdown_links "${standard}"
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

# Minimum content contracts per branch standard. These assert the load-bearing
# concepts each standard exists to define, not merely that the file is present.

FS_STANDARD="docs/standards/platform-filesystem-observability-standard.md"
assert_contains "${FS_STANDARD}" 'Canonical Filesystem Layout' \
  "filesystem standard defines the canonical layout"
assert_contains "${FS_STANDARD}" 'Structured Logging' \
  "filesystem standard requires structured logging"
assert_contains "${FS_STANDARD}" 'Prometheus' \
  "filesystem standard names the metrics system"
assert_contains "${FS_STANDARD}" 'Loki' \
  "filesystem standard names the log aggregation system"
assert_contains "${FS_STANDARD}" '[Rr]etention' \
  "filesystem standard defines retention"

ROLE_STANDARD="docs/standards/platform-role-host-classification-standard.md"
assert_contains "${ROLE_STANDARD}" 'AI Platform' \
  "role standard defines the AI Platform role"
assert_contains "${ROLE_STANDARD}" 'Tier 0' \
  "role standard defines Tier 0 criticality"
assert_contains "${ROLE_STANDARD}" 'Tier 1' \
  "role standard defines Tier 1 criticality"
assert_contains "${ROLE_STANDARD}" 'schai' \
  "role standard assigns schai to a role"
assert_contains "${ROLE_STANDARD}" '[Rr]ole [Dd]rift' \
  "role standard defines role drift"

DOCKER_STANDARD="docs/standards/docker-platform-standard.md"
assert_contains "${DOCKER_STANDARD}" 'Compose' \
  "Docker standard covers Compose"
assert_contains "${DOCKER_STANDARD}" 'Image Versioning' \
  "Docker standard defines image versioning"
assert_contains "${DOCKER_STANDARD}" 'Port Exposure' \
  "Docker standard defines port exposure"
assert_contains "${DOCKER_STANDARD}" 'Health Check' \
  "Docker standard requires health checks"
assert_contains "${DOCKER_STANDARD}" 'max-size' \
  "Docker standard requires log rotation limits"

AUTOMATION_STANDARD="docs/standards/platform-automation-standard.md"
assert_contains "${AUTOMATION_STANDARD}" 'Ansible' \
  "automation standard names the automation tool"
assert_contains "${AUTOMATION_STANDARD}" 'Idempotency' \
  "automation standard requires idempotency"
assert_contains "${AUTOMATION_STANDARD}" 'Inventory Design' \
  "automation standard defines inventory design"
assert_contains "${AUTOMATION_STANDARD}" 'Secrets Management' \
  "automation standard defines secrets management"
assert_contains "${AUTOMATION_STANDARD}" 'Check Mode' \
  "automation standard requires check mode"

CATALOG_STANDARD="docs/standards/service-catalog-standard.md"
assert_contains "${CATALOG_STANDARD}" 'platform-model/services' \
  "service catalog standard names the canonical record location"
assert_contains "${CATALOG_STANDARD}" 'SVC-' \
  "service catalog standard defines the service id prefix"
assert_contains "${CATALOG_STANDARD}" 'Lifecycle States' \
  "service catalog standard defines lifecycle states"
assert_contains "${CATALOG_STANDARD}" '[Aa]uthoritative log' \
  "service catalog standard requires an authoritative log source"

RUNBOOK_STANDARD="docs/standards/runbook-standard.md"
assert_contains "${RUNBOOK_STANDARD}" 'RB-' \
  "runbook standard defines the runbook id prefix"
assert_contains "${RUNBOOK_STANDARD}" 'Front Matter' \
  "runbook standard requires front matter"
assert_contains "${RUNBOOK_STANDARD}" 'Required Sections' \
  "runbook standard defines required sections"
assert_contains "${RUNBOOK_STANDARD}" 'Lifecycle States' \
  "runbook standard defines lifecycle states"

DEPENDENCY_STANDARD="docs/standards/dependency-mapping-standard.md"
assert_contains "${DEPENDENCY_STANDARD}" 'Dependency Classes' \
  "dependency standard defines dependency classes"
assert_contains "${DEPENDENCY_STANDARD}" '^### Hard' \
  "dependency standard defines the hard dependency class"
assert_contains "${DEPENDENCY_STANDARD}" '^### Soft' \
  "dependency standard defines the soft dependency class"
assert_contains "${DEPENDENCY_STANDARD}" 'DEPENDS_ON' \
  "dependency standard uses the controlled relationship vocabulary"

ONTOLOGY_STANDARD="docs/standards/platform-ontology-standard.md"
assert_contains "${ONTOLOGY_STANDARD}" 'entity-types.yaml' \
  "ontology standard names the entity type catalog"
assert_contains "${ONTOLOGY_STANDARD}" 'relationship-types.yaml' \
  "ontology standard names the relationship type catalog"
assert_contains "${ONTOLOGY_STANDARD}" 'Stable Identifier' \
  "ontology standard defines stable identifiers"
assert_contains "${ONTOLOGY_STANDARD}" 'BELONGS_TO' \
  "ontology standard defines the BELONGS_TO relationship"
assert_contains "${ONTOLOGY_STANDARD}" 'RUNS_ON' \
  "ontology standard defines the RUNS_ON relationship"

# Definition of Done gates. Each named gate must appear, so the standard cannot
# silently drop a completion requirement.
DOD_STANDARD="docs/standards/definition-of-done-standard.md"
for gate in \
  'Architecture alignment' \
  'Tests' \
  'Documentation' \
  'Service catalog' \
  'Platform model' \
  'Runbook' \
  'Observability' \
  'Security review' \
  'Performance' \
  'Backup and recovery' \
  'Release notes' \
  'Reviewer approval'; do
  assert_contains "${DOD_STANDARD}" "^### ${gate}" \
    "definition of done defines the ${gate} gate"
done
assert_contains "${DOD_STANDARD}" '[Ww]hen applicable' \
  "definition of done scopes gates to applicability"

# Entity lifecycle standard. Lifecycle is entity maturity and must stay
# distinct from provenance and from runtime health.
LIFECYCLE_STANDARD="docs/standards/entity-lifecycle-standard.md"
for state in draft declared verification-pending verified managed deprecated archived; do
  assert_contains "${LIFECYCLE_STANDARD}" "\`${state}\`" \
    "lifecycle standard defines the ${state} state"
done
# "observed" is provenance, never a lifecycle state. Asserting its absence from
# the state list is the whole point of separating the two vocabularies.
assert_not_contains "${LIFECYCLE_STANDARD}" '^\|[[:space:]]*`observed`[[:space:]]*\|' \
  "lifecycle standard does not list observed as a lifecycle state"
assert_contains "${LIFECYCLE_STANDARD}" 'verified -> verification-pending' \
  "lifecycle standard permits regression when evidence goes stale"
assert_contains "${LIFECYCLE_STANDARD}" 'operational_health' \
  "lifecycle standard distinguishes operational health"
assert_contains "${LIFECYCLE_STANDARD}" 'verification_state' \
  "lifecycle standard distinguishes verification state"
assert_contains "${LIFECYCLE_STANDARD}" 'never be reused|never reused' \
  "lifecycle standard forbids reusing archived identifiers"
assert_contains "${LIFECYCLE_STANDARD}" 'does not imply|not imply runtime' \
  "lifecycle standard states lifecycle does not imply runtime health"

# Evidence standard.
EVIDENCE_STANDARD="docs/standards/evidence-standard.md"
for source in manual-attestation command-output ssh-command api-response \
  file-inspection configuration-render health-check backup-report \
  monitoring-query git-repository; do
  assert_contains "${EVIDENCE_STANDARD}" "\`${source}\`" \
    "evidence standard defines the ${source} source type"
done
for status in success partial failed unavailable; do
  assert_contains "${EVIDENCE_STANDARD}" "\`${status}\`" \
    "evidence standard defines the ${status} status"
done
for level in public internal restricted secret-metadata; do
  assert_contains "${EVIDENCE_STANDARD}" "\`${level}\`" \
    "evidence standard defines the ${level} sensitivity"
done
assert_contains "${EVIDENCE_STANDARD}" 'collected_at' \
  "evidence standard requires collected_at"
assert_contains "${EVIDENCE_STANDARD}" 'content_fingerprint' \
  "evidence standard requires a content fingerprint"
assert_contains "${EVIDENCE_STANDARD}" 'secret_present' \
  "evidence standard permits secret metadata without secret values"
assert_contains "${EVIDENCE_STANDARD}" '[Ii]mmutab' \
  "evidence standard defines immutability"
assert_contains "${EVIDENCE_STANDARD}" 'supersede' \
  "evidence standard defines supersession rather than overwrite"
assert_contains "${EVIDENCE_STANDARD}" 'redaction' \
  "evidence standard requires declaring redaction"

# Verification and drift standard.
VERIFY_STANDARD="docs/standards/verification-drift-standard.md"
for state in unknown pending verified warning drift failed unsupported; do
  assert_contains "${VERIFY_STANDARD}" "\`${state}\`" \
    "verification standard defines the ${state} state"
done
for severity in information low medium high critical; do
  assert_contains "${VERIFY_STANDARD}" "\`${severity}\`" \
    "verification standard defines the ${severity} severity"
done
for result in match mismatch missing_observation stale_evidence unsupported collection_failure; do
  assert_contains "${VERIFY_STANDARD}" "\`${result}\`" \
    "verification standard defines the ${result} result type"
done
assert_contains "${VERIFY_STANDARD}" 'read-only' \
  "verification standard states verification is read-only"
assert_contains "${VERIFY_STANDARD}" 'no remediation|No remediation' \
  "verification standard performs no remediation"
assert_contains "${VERIFY_STANDARD}" 'Missing evidence is not' \
  "verification standard separates missing evidence from drift"
assert_contains "${VERIFY_STANDARD}" 'Collection failure is not' \
  "verification standard separates collection failure from service failure"
assert_contains "${VERIFY_STANDARD}" 'Stale evidence cannot' \
  "verification standard forbids verified state from stale evidence"
assert_contains "${VERIFY_STANDARD}" 'advisory' \
  "verification standard marks recommended actions advisory"

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
assert_contains "${METADATA_STANDARD}" "\`declared\`" \
  "operational metadata standard defines the declared provenance class"
assert_contains "${METADATA_STANDARD}" "\`observed\`" \
  "operational metadata standard defines the observed provenance class"
assert_contains "${METADATA_STANDARD}" "\`inferred\`" \
  "operational metadata standard defines the inferred provenance class"
assert_contains "${METADATA_STANDARD}" 'observed_at' \
  "operational metadata standard requires observed_at on observed facts"
# The provenance vocabulary is exactly three classes. "asserted" was an alias
# for "declared" and has been removed so the model has one term per concept.
assert_not_contains "${METADATA_STANDARD}" 'asserted' \
  "operational metadata standard does not use the asserted alias"
assert_not_contains "${ONTOLOGY_STANDARD}" 'asserted' \
  "ontology standard does not use the asserted alias"
assert_contains "${METADATA_STANDARD}" 'exactly three' \
  "operational metadata standard states the vocabulary is exactly three classes"
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

# Reserved release gates required before v1.0.0.
assert_contains "${ROADMAP}" 'Sprint 98' \
  "roadmap reserves Sprint 98"
assert_contains "${ROADMAP}" 'Sprint 99' \
  "roadmap reserves Sprint 99"
assert_contains "${ROADMAP}" 'Documentation Lockdown' \
  "roadmap names the Sprint 98 documentation lockdown gate"
assert_contains "${ROADMAP}" 'Performance & Engineering Excellence' \
  "roadmap names the Sprint 99 engineering excellence gate"
for item in \
  'User documentation' \
  'Administrator guide' \
  'Developer guide' \
  'Command reference' \
  'Troubleshooting' \
  'Operations manual' \
  'Architecture diagrams' \
  'Capability and limitation'; do
  assert_contains "${ROADMAP}" "${item}" \
    "Sprint 98 covers ${item}"
done
for item in \
  'Architecture review' \
  'Dead-code and dependency review' \
  'CPU/RAM/GPU/disk/network profiling' \
  'API and inference latency benchmarking' \
  'Token/context/prompt efficiency review' \
  'Container and image review' \
  'Database/query review' \
  'Observability review' \
  'Security review' \
  'Final code-quality review'; do
  assert_contains "${ROADMAP}" "${item}" \
    "Sprint 99 covers ${item}"
done
assert_contains "${ROADMAP}" 'required before v1\.0\.0' \
  "roadmap states both gates are required before v1.0.0"


# Validate relative Markdown links in the new governance documents.
for document in "${REQUIRED_DOCS[@]}"; do
  assert_markdown_links "${document}"
done

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nStatic documentation validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nStatic documentation validation passed.\n'
