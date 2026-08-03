#!/usr/bin/env bash
set -Eeuo pipefail

# Static documentation assertions for the Schott Platform.
#
# This script requires only Bash and standard POSIX utilities. It can run in CI
# without access to schai, Docker, the network, or secrets.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

# Production-path state, sampled before any assertion runs and compared after
# the last one. This suite must leave the two approved production paths exactly
# as it found them — whether that is absent on a workstation or present on a
# host where an operator has already run the deployment procedure.
#
# It reports existence only. Reading the contents of a root-owned trust store
# is not this suite's business, and it does not have permission to try.
prod_path_state() {
  local path state=''
  for path in /var/lib/kyri /etc/kyri; do   # prod-path-reference
    if [[ -e "${path}" ]]; then state+="${path}:present "; else state+="${path}:absent "; fi
  done
  printf '%s' "${state}"
}
PROD_PATH_STATE_AT_START="$(prod_path_state)"

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
  "docs/decisions/ADR-0002-evidence-first-architecture.md"
  "docs/decisions/ADR-0003-provider-agnostic-ai-architecture.md"
  "docs/decisions/ADR-0004-immutable-knowledge-timeline.md"
  "docs/decisions/ADR-0007-operational-integrity-engine.md"
  "docs/decisions/ADR-0008-experience-engine.md"
  "docs/decisions/ADR-0009-occurrence-timeline.md"
  "docs/decisions/ADR-0010-remote-read-only-collection.md"
  "docs/decisions/ADR-0011-trust-plane.md"
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
  "docs/standards/capability-model-standard.md"
  "docs/standards/collector-plugin-standard.md"
  "docs/standards/knowledge-event-standard.md"
  "docs/standards/confidence-freshness-standard.md"
)

# Per-collector documentation introduced in v0.6.0.
COLLECTOR_DOCS=(
  "docs/collectors/git-repository.md"
  "docs/collectors/configuration-render.md"
  "docs/collectors/manual-attestation.md"
  # Remote collectors, added in v0.9.0. Held to the same contract as the local
  # ones: reaching another machine is a reason for more scrutiny, not less.
  "docs/collectors/linux-host.md"
  "docs/collectors/linux-resources.md"
  "docs/collectors/linux-services.md"
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
assert_not_contains "${LIFECYCLE_STANDARD}" "^\|[[:space:]]*\`observed\`[[:space:]]*\|" \
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

# Each collector document must state its safety boundaries explicitly, so a
# reader cannot infer capabilities the collector does not have.
for collector_doc in "${COLLECTOR_DOCS[@]}"; do
  name="$(basename "${collector_doc}" .md)"
  assert_file "${collector_doc}"
  assert_contains "${collector_doc}" '^# ' "${name} doc has a title"
  assert_contains "${collector_doc}" '[Nn]ot [Cc]ollected' "${name} doc states what is not collected"
  assert_contains "${collector_doc}" '[Ss]ecret' "${name} doc documents secret handling"
  assert_contains "${collector_doc}" '[Ff]ailure' "${name} doc documents failure modes"
  assert_contains "${collector_doc}" '[Nn]o persistence|not persist|never persists' "${name} doc states it does not persist"
  assert_contains "${collector_doc}" 'EVID' "${name} doc states it assigns no evidence id"
  assert_contains "${collector_doc}" 'remediat' "${name} doc states it performs no remediation"
done

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

# --- v0.7.0 observation documentation --------------------------------------
for document in overview evidence-store timeline confidence-and-freshness knowledge-state; do
  assert_file "docs/observation/${document}.md"
  assert_markdown_links "docs/observation/${document}.md"
done

ADR4="docs/decisions/ADR-0004-immutable-knowledge-timeline.md"
assert_contains "${ADR4}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0004 is accepted"
for stage in Observation Evidence Verification "Knowledge Event" "Knowledge State"; do
  assert_contains "${ADR4}" "${stage}" "ADR-0004 documents the ${stage} stage"
done
assert_contains "${ADR4}" 'Missing evidence is not drift' \
  "ADR-0004 states that missing evidence is not drift"
assert_contains "${ADR4}" 'Collection failure is not service failure' \
  "ADR-0004 states that collection failure is not service failure"
assert_contains "${ADR4}" 'Rejected [Aa]lternatives' "ADR-0004 records rejected alternatives"
assert_contains "${ADR4}" 'Mutable current-state files' \
  "ADR-0004 rejects mutable current-state files"

EVENT_STD="docs/standards/knowledge-event-standard.md"
for event in observation-received evidence-created evidence-refreshed \
             verification-created drift-detected drift-cleared evidence-stale \
             collection-failed review-required knowledge-state-generated; do
  assert_contains "${EVENT_STD}" "${event}" "knowledge event standard defines ${event}"
done
assert_contains "${EVENT_STD}" 'append-only' "knowledge event standard states events are append-only"

CONF_STD="docs/standards/confidence-freshness-standard.md"
for factor in source_reliability freshness verification source_agreement completeness; do
  assert_contains "${CONF_STD}" "${factor}" "confidence standard documents the ${factor} factor"
done
assert_contains "${CONF_STD}" '0\.25' "confidence standard documents factor weights"
assert_contains "${CONF_STD}" '[Nn]ot a probability' \
  "confidence standard states confidence is not a probability"
assert_contains "${CONF_STD}" 'heuristic' "confidence standard calls confidence a heuristic"
for state in current aging stale unknown; do
  assert_contains "${CONF_STD}" "^- \`${state}\`" "confidence standard defines the ${state} freshness state"
done

# The roadmap must record this release and reserve the next three.
assert_contains "docs/platform-roadmap.md" 'v0\.7\.0 — Knowledge Orchestrator and Immutable Timeline' \
  "roadmap records v0.7.0"
assert_contains "docs/platform-roadmap.md" 'v0\.7\.5 — Developer Experience Hardening' \
  "roadmap reserves v0.7.5"
# v0.8.0 and v0.9.0 are asserted against the approved Phase II sequence in the
# roadmap block further down; the earlier reservation names were superseded.
assert_contains "docs/platform-roadmap.md" 'Sprint 98' "roadmap keeps Sprint 98 intact"
assert_contains "docs/platform-roadmap.md" 'Sprint 99' "roadmap keeps Sprint 99 intact"

# --- v0.8.0 operational integrity ------------------------------------------
ADR7="docs/decisions/ADR-0007-operational-integrity-engine.md"
assert_contains "${ADR7}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0007 is accepted"
assert_contains "${ADR7}" '^## Context' "ADR-0007 contains Context"
assert_contains "${ADR7}" '^## Decision' "ADR-0007 contains Decision"
assert_contains "${ADR7}" '^## Consequences' "ADR-0007 contains Consequences"
for concept in Snapshot "Digital Twin" "Integrity Report" "Recovery Plan"; do
  assert_contains "${ADR7}" "${concept}" "ADR-0007 defines ${concept}"
done
assert_contains "${ADR7}" '[Aa]dvisory' "ADR-0007 states recovery is advisory"
assert_contains "${ADR7}" 'never (executes|recovers)|no execution' \
  "ADR-0007 states the engine never executes recovery"
assert_contains "${ADR7}" 'disposable' "ADR-0007 states twins are disposable"
assert_contains "${ADR7}" 'Rejected [Aa]lternatives' "ADR-0007 records rejected alternatives"

assert_file "docs/integrity/overview.md"
assert_markdown_links "docs/integrity/overview.md"
for state in MATCH PARTIAL DRIFT UNKNOWN INSUFFICIENT_EVIDENCE; do
  assert_contains "docs/integrity/overview.md" "${state}" \
    "integrity overview documents the ${state} status"
done

# --- v0.8.5 experience engine ----------------------------------------------
ADR8="docs/decisions/ADR-0008-experience-engine.md"
assert_contains "${ADR8}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0008 is accepted"
assert_contains "${ADR8}" '^## Context' "ADR-0008 contains Context"
assert_contains "${ADR8}" '^## Decision' "ADR-0008 contains Decision"
assert_contains "${ADR8}" '^## Consequences' "ADR-0008 contains Consequences"
assert_contains "${ADR8}" 'Experience Profile' "ADR-0008 defines the Experience Profile"
assert_contains "${ADR8}" 'Experience Window' "ADR-0008 defines the Experience Window"
assert_contains "${ADR8}" 'Operational Baseline' "ADR-0008 defines the Operational Baseline"
assert_contains "${ADR8}" '[Ss]tatistics are not knowledge' \
  "ADR-0008 states that statistics are not knowledge"
assert_contains "${ADR8}" 'machine learning|Machine [Ll]earning' \
  "ADR-0008 explains the machine-learning exclusion"
assert_contains "${ADR8}" 'Rejected [Aa]lternatives' "ADR-0008 records rejected alternatives"
for rejected in "Predictive" "Online learning" "Automatic baseline" "LLM-generated" "anomaly correction"; do
  assert_contains "${ADR8}" "${rejected}" "ADR-0008 rejects ${rejected}"
done

assert_file "docs/experience/overview.md"
assert_markdown_links "docs/experience/overview.md"
for state in EXPECTED UNEXPECTED UNKNOWN INSUFFICIENT_EVIDENCE; do
  assert_contains "docs/experience/overview.md" "${state}" \
    "experience overview documents the ${state} status"
done
for trend in stable increasing decreasing volatile unknown; do
  assert_contains "docs/experience/overview.md" "${trend}" \
    "experience overview documents the ${trend} trend"
done

# --- v0.7.5 developer documentation ----------------------------------------
for document in getting-started toolchain local-validation; do
  assert_file "docs/development/${document}.md"
  assert_markdown_links "docs/development/${document}.md"
done

assert_contains "docs/development/getting-started.md" '^# ' "getting-started has a title"
assert_contains "docs/development/toolchain.md" '^# ' "toolchain doc has a title"
assert_contains "docs/development/local-validation.md" '^# ' "local-validation has a title"
assert_contains "docs/development/getting-started.md" '(never installs|no packages are installed|without .*approval)' \
  "getting started states that nothing is installed without approval"
assert_contains "docs/development/local-validation.md" 'fail(s|ed)? closed|fail-closed' \
  "local validation documents fail-closed PyYAML behaviour"

assert_contains "docs/platform-roadmap.md" 'v0\.7\.5 — Developer Experience Hardening' \
  "roadmap records v0.7.5"
assert_contains "docs/platform-roadmap.md" 'Sprint 98' "roadmap keeps Sprint 98 intact"
assert_contains "docs/platform-roadmap.md" 'Sprint 99' "roadmap keeps Sprint 99 intact"

# --- Roadmap: Phase I and Phase II ------------------------------------------
ROADMAP="docs/platform-roadmap.md"
assert_contains "${ROADMAP}" '^## Phase I — Platform Foundation' \
  "roadmap defines Phase I — Platform Foundation"
assert_contains "${ROADMAP}" '^## Phase II — Cognitive Infrastructure' \
  "roadmap defines Phase II — Cognitive Infrastructure"

# The approved Phase II sequence, in order.
assert_contains "${ROADMAP}" 'v0\.8\.0 — Operational Integrity and Digital Twin Foundation' \
  "roadmap records v0.8.0 Operational Integrity and Digital Twin Foundation"
assert_contains "${ROADMAP}" 'v0\.8\.5 — Experience Engine and Operational Memory' \
  "roadmap records v0.8.5 Experience Engine and Operational Memory"
assert_contains "${ROADMAP}" 'v0\.8\.6 — Occurrence Timeline' \
  "roadmap records v0.8.6 Occurrence Timeline"
assert_contains "${ROADMAP}" 'v0\.9\.0 — Remote Read-Only Collectors' \
  "roadmap records v0.9.0 Remote Read-Only Collectors"
assert_contains "${ROADMAP}" 'v1\.0\.0 — Kyri Core Foundation' \
  "roadmap records v1.0.0 Kyri Core Foundation"

# The architectural rule that keeps Kyri separable from any model.
assert_contains "${ROADMAP}" 'No model is Kyri' \
  "roadmap states that no model is Kyri"
assert_contains "${ROADMAP}" 'replaceable reasoning providers' \
  "roadmap states models are replaceable reasoning providers"

# --- Reserved release gates --------------------------------------------------
assert_contains "${ROADMAP}" 'Sprint 97 — Cognitive Integrity and Recovery' \
  "roadmap reserves Sprint 97"
assert_contains "${ROADMAP}" 'Sprint 98' "roadmap keeps Sprint 98"
assert_contains "${ROADMAP}" 'Sprint 99' "roadmap keeps Sprint 99"

for requirement in "[Mm]odel and adapter manifests" "[Pp]rompt and policy versioning" \
                   "[Rr]outing configuration snapshots" "[Ee]mbedding and index compatibility" \
                   "[Mm]emory schema versioning" "[Kk]nown-good cognitive baselines" \
                   "[Gg]olden evaluation suite" "[Rr]egression detection" \
                   "[Ss]uspect-state quarantine" "layer-specific recovery" \
                   "[Pp]ost-restore validation" "[Aa]udit trail"; do
  assert_contains "${ROADMAP}" "${requirement}" \
    "Sprint 97 requires ${requirement}"
done

# Sprint 98 and Sprint 99 requirements must survive the restructure.
for preserved in "User documentation" "Administrator guide" "Command reference" \
                 "Capability and limitation documentation" "Architecture review" \
                 "Dead-code and dependency review" "Security review" \
                 "Final code-quality review"; do
  assert_contains "${ROADMAP}" "${preserved}" \
    "roadmap preserves the existing requirement: ${preserved}"
done

# --- v0.8.6 occurrence timeline ---------------------------------------------
ADR9="docs/decisions/ADR-0009-occurrence-timeline.md"
assert_contains "${ADR9}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0009 is accepted"
assert_contains "${ADR9}" '^## Context' "ADR-0009 contains Context"
assert_contains "${ADR9}" '^## Decision' "ADR-0009 contains Decision"
assert_contains "${ADR9}" '^## Consequences' "ADR-0009 contains Consequences"
for concept in Occurrence "Occurrence Series" Pattern Timeline; do
  assert_contains "${ADR9}" "${concept}" "ADR-0009 defines ${concept}"
done
assert_contains "${ADR9}" '[Nn]ever predicts|no prediction' \
  "ADR-0009 states the engine never predicts"
assert_contains "${ADR9}" 'Rejected [Aa]lternatives' "ADR-0009 records rejected alternatives"
assert_contains "${ADR9}" '[Ff]orecast' "ADR-0009 addresses forecasting"

assert_file "docs/occurrence/overview.md"
assert_markdown_links "docs/occurrence/overview.md"
for concept in "first seen" "last seen" interval frequency recurrence ordering; do
  assert_contains "docs/occurrence/overview.md" "${concept}" \
    "occurrence overview documents ${concept}"
done
for state in regular irregular single unknown; do
  assert_contains "docs/occurrence/overview.md" "${state}" \
    "occurrence overview documents the ${state} recurrence state"
done

assert_contains "docs/platform-roadmap.md" 'v0\.8\.6 — Occurrence Timeline' \
  "roadmap records v0.8.6"
assert_contains "docs/platform-roadmap.md" 'Sprint 97' "roadmap keeps Sprint 97"

# --- v0.9.5 reservation and the extended architectural rule ------------------
assert_contains "${ROADMAP}" 'v0\.9\.5 — Distributed Capability Fabric' \
  "roadmap reserves v0.9.5 Distributed Capability Fabric"

# The reservation must describe what it covers, or it reserves a name rather
# than a scope.
for requirement in "[Nn]ode registry" "[Cc]apability registry" "[Mm]odel endpoint registry" \
                   "[Rr]esource metadata" "[Hh]ealth and availability" \
                   "[Tt]rust and privacy classifications" \
                   "[Dd]eterministic[, ].*placement" "[Ww]orkload leases" \
                   "[Mm]aintenance and drain" "[Ll]ocal-only enforcement" \
                   "[Pp]referred and fallback placement" "[Rr]esult validation" \
                   "[Pp]lacement audit events"; do
  assert_contains "${ROADMAP}" "${requirement}" \
    "v0.9.5 reservation covers ${requirement}"
done

# Ordering: v0.9.5 must sit between v0.9.0 and v1.0.0.
roadmap_order="$(grep -nE '^### (v0\.9\.0|v0\.9\.5|v1\.0\.0) — ' "${ROOT}/${ROADMAP}" \
  | cut -d: -f1 | tr '\n' ' ')"
read -r line_090 line_095 line_100 <<<"${roadmap_order}"
if [[ -n "${line_090}" && -n "${line_095}" && -n "${line_100}" ]] \
   && (( line_090 < line_095 && line_095 < line_100 )); then
  pass "roadmap orders v0.9.0 before v0.9.5 before v1.0.0"
else
  fail "roadmap must order v0.9.0, v0.9.5, v1.0.0 (found lines: ${roadmap_order})"
fi

# Kyri is neither a model nor a machine. The second half matters once work is
# placed on other nodes: a fabric that lets one machine become the platform has
# recreated the coupling the first half exists to prevent.
assert_contains "${ROADMAP}" 'No model is Kyri' "roadmap states no model is Kyri"
assert_contains "${ROADMAP}" 'No machine is Kyri' "roadmap states no machine is Kyri"
assert_contains "${ROADMAP}" 'governed core' \
  "roadmap defines Kyri as the governed core and its contracts"

# v0.9.5 is a reservation only in this release.
refute_contains_docs() {
  if [[ -d "${ROOT}/tools/fabric" ]] || [[ -d "${ROOT}/tools/capability" ]]; then
    fail "v0.9.5 is a roadmap reservation; no fabric implementation belongs here"
  else
    pass "v0.9.5 remains a reservation with no implementation"
  fi
}
refute_contains_docs

# --- v0.9.0 remote read-only collection --------------------------------------
ADR10="docs/decisions/ADR-0010-remote-read-only-collection.md"
assert_contains "${ADR10}" '^-[[:space:]]+\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0010 is accepted"
assert_contains "${ADR10}" '^## Context' "ADR-0010 contains Context"
assert_contains "${ADR10}" '^## Decision' "ADR-0010 contains Decision"
assert_contains "${ADR10}" '^## Consequences' "ADR-0010 contains Consequences"
assert_contains "${ADR10}" 'observe.*never administer|never administer' \
  "ADR-0010 states collectors observe but never administer"
assert_contains "${ADR10}" '[Hh]ost-key verification is mandatory|Host-key verification is mandatory' \
  "ADR-0010 requires host-key verification"
assert_contains "${ADR10}" 'fail closed' "ADR-0010 states unknown keys fail closed"
assert_contains "${ADR10}" 'connection failure is not' \
  "ADR-0010 states connection failure is not host failure"
assert_contains "${ADR10}" 'Rejected [Aa]lternatives' "ADR-0010 records rejected alternatives"
for rejected in "arbitrary SSH command" "Shell text supplied in YAML" \
                "Disabling host-key checking" "Remote sudo" \
                "Package installation" "Ansible"; do
  assert_contains "${ADR10}" "${rejected}" "ADR-0010 rejects ${rejected}"
done

for doc in remote-collection linux-host linux-resources linux-services; do
  assert_file "docs/collectors/${doc}.md"
  assert_markdown_links "docs/collectors/${doc}.md"
done

REMOTE_DOC="docs/collectors/remote-collection.md"
for topic in "[Tt]hreat model" "host key" "[Aa]uthentication reference" \
             "operation catalog" "timeout" "[Ff]ailure semantics" "[Rr]edaction" \
             "sudo" "Distributed Capability Fabric"; do
  assert_contains "${REMOTE_DOC}" "${topic}" "remote collection doc covers ${topic}"
done
for category in authentication_failure host_key_failure timeout output_limit \
                transport_failure unsupported_target collection_failure; do
  assert_contains "${REMOTE_DOC}" "${category}" \
    "remote collection doc documents the ${category} category"
done

# A target is one machine, as a name or an explicit address literal. The
# documentation must say both what is permitted and what stays refused, so a
# reader cannot infer that explicit addressing implies discovery.
for form in "DNS name" "IPv4 literal" "IPv6 literal"; do
  assert_contains "${REMOTE_DOC}" "${form}" \
    "remote collection doc documents the permitted ${form} target form"
done
for refused in "CIDR" "[Aa]ddress range" "[Ww]ildcard" "URL" \
               "[Ee]mbedded username" "[Mm]alformed literal"; do
  assert_contains "${REMOTE_DOC}" "${refused}" \
    "remote collection doc documents that ${refused} stays refused"
done
assert_contains "${REMOTE_DOC}" 'not host discovery|not discovery' \
  "remote collection doc states explicit addressing is not discovery"
assert_contains "${REMOTE_DOC}" 'bootstrap' \
  "remote collection doc explains why address literals exist"
assert_contains "${REMOTE_DOC}" 'unbracketed' \
  "remote collection doc states IPv6 is stored unbracketed"
assert_contains "${REMOTE_DOC}" 'RemoteTarget\.port|port field' \
  "remote collection doc states the port stays a separate field"
assert_contains "${REMOTE_DOC}" 'known_hosts' \
  "remote collection doc explains known_hosts identity for address literals"
assert_contains "${REMOTE_DOC}" 'ipaddress' \
  "remote collection doc states literals are parsed, not pattern-matched"
assert_contains "${REMOTE_DOC}" 'refused rather than trimmed|rejected-not-trimmed' \
  "remote collection doc states whitespace is refused rather than trimmed"

# Enrollment must never be documented as automatic.
assert_not_contains "${REMOTE_DOC}" '(automatic|automated)[[:space:]]+host.key[[:space:]]+enrollment' \
  "remote collection doc documents no automatic host-key enrollment"

# Atomic collection, in the approved wording.
assert_contains "${REMOTE_DOC}" '[Aa]tomic at the collector level' \
  "remote collection doc states collection is atomic at the collector level"
assert_contains "${REMOTE_DOC}" '[Ss]uccessful intermediate operations are discarded' \
  "remote collection doc states intermediate successes are discarded"
assert_contains "${REMOTE_DOC}" '[Pp]artial collection is deferred' \
  "remote collection doc records that partial collection is deferred"

# subprocess_access: true must be explained, not left to be read literally.
assert_contains "${REMOTE_DOC}" 'subprocess_access' \
  "remote collection doc explains the subprocess_access declaration"
assert_contains "${REMOTE_DOC}" 'not general subprocess authority|rather than general subprocess authority' \
  "remote collection doc bounds what subprocess_access means"
assert_contains "${REMOTE_DOC}" 'SSHRemoteTransport' \
  "remote collection doc names the transport that owns execution"

for collector_doc in docs/collectors/linux-host.md docs/collectors/linux-resources.md \
                     docs/collectors/linux-services.md; do
  assert_contains "${collector_doc}" '[Aa]tomic at the collector level' \
    "$(basename "${collector_doc}" .md) doc states collection is atomic"
  assert_contains "${collector_doc}" 'subprocess_access' \
    "$(basename "${collector_doc}" .md) doc explains subprocess_access"
done

# Documentation must use synthetic hostnames only; a real one invites a copy
# and paste straight at production.
assert_not_contains "${REMOTE_DOC}" '[a-z0-9-]+\.(com|net|org|io)\b' \
  "remote collection doc uses synthetic hostnames only"

assert_contains "docs/platform-roadmap.md" 'v0\.9\.0 — Remote Read-Only Collectors' \
  "roadmap records v0.9.0"
assert_contains "docs/platform-roadmap.md" 'v0\.9\.5 — Distributed Capability Fabric' \
  "roadmap preserves v0.9.5"
assert_contains "docs/platform-roadmap.md" 'v1\.0\.0 — Kyri Core Foundation' \
  "roadmap preserves v1.0.0"

# --- v0.9.2 trust plane ------------------------------------------------------
ADR11="docs/decisions/ADR-0011-trust-plane.md"
assert_contains "${ADR11}" '^# ADR-0011:' "ADR-0011 has the expected title"
assert_contains "${ADR11}" '\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0011 is Accepted"
assert_markdown_links "${ADR11}"

for trust_doc in docs/trust/trust-plane.md docs/trust/trust-domains.md \
                 docs/trust/trust-states.md; do
  assert_file "${trust_doc}"
  assert_contains "${trust_doc}" '^# ' "$(basename "${trust_doc}" .md) has a title"
  assert_markdown_links "${trust_doc}"
done

# The Trust Plane is a governed layer beside the others, not beneath reasoning.
assert_contains "${ADR11}" 'Observation' "ADR-0011 places trust beside observation"
assert_contains "${ADR11}" 'Knowledge' "ADR-0011 places trust beside knowledge"
assert_contains "${ADR11}" 'Integrity' "ADR-0011 places trust beside integrity"
assert_contains "${ADR11}" 'Experience' "ADR-0011 places trust beside experience"
assert_contains "${ADR11}" 'Occurrence' "ADR-0011 places trust beside occurrence"

# Architecture only. The documents must say so, so a reader does not mistake a
# specification for a shipped control.
assert_contains "${ADR11}" '[Nn]o runtime implementation|architecture only|not implemented in this release' \
  "ADR-0011 states that no runtime implementation exists yet"
assert_contains "${TRUST_PLANE_DOC:-docs/trust/trust-plane.md}" '[Nn]ot yet implemented|architecture only|no runtime' \
  "the trust plane document states it is not yet implemented"

# Supervised v0.9.0 validation is the origin of this decision and must be cited.
assert_contains "${ADR11}" 'v0\.9\.0' "ADR-0011 cites the v0.9.0 validation that motivated it"

# Documentation must use synthetic identifiers only.
assert_not_contains "docs/trust/trust-plane.md" '[a-z0-9-]+\.(com|net|org|io)\b' \
  "trust plane doc uses synthetic hostnames only"

# --- v0.9.3 trust runtime documentation --------------------------------------
for runtime_doc in docs/trust/runtime-overview.md \
                   docs/trust/root-authority-operations.md \
                   docs/trust/state-transition-runtime.md \
                   docs/trust/trust-query-reference.md; do
  assert_file "${runtime_doc}"
  assert_contains "${runtime_doc}" '^# ' "$(basename "${runtime_doc}" .md) has a title"
  assert_markdown_links "${runtime_doc}"
done

RUNTIME_DOC="docs/trust/runtime-overview.md"
for topic in "[Ss]tore layout" "[Ss]tored versus effective|stored and effective" \
             "[Ff]ailure semantics" "[Nn]on-goal" "single-host"; do
  assert_contains "${RUNTIME_DOC}" "${topic}" "runtime overview covers ${topic}"
done
assert_contains "${RUNTIME_DOC}" '[Mm]igration' \
  "runtime overview records that migration is still deferred"
assert_contains "${RUNTIME_DOC}" '[Ff]abric' \
  "runtime overview records that the Fabric is still blocked"

# Synthetic identities only: a real one invites a copy and paste at production.
for runtime_doc in docs/trust/runtime-overview.md \
                   docs/trust/root-authority-operations.md; do
  assert_not_contains "${runtime_doc}" '[a-z0-9-]+\.(com|net|org|io)\b' \
    "$(basename "${runtime_doc}" .md) uses synthetic identities only"
done

assert_contains "docs/platform-roadmap.md" '^### v0\.9\.3 — Trust Plane Runtime Foundation' \
  "roadmap records v0.9.3"

# --- v0.9.4 trust migration documentation ------------------------------------
MIGRATION_DOC="docs/trust/trust-migration.md"
assert_file "${MIGRATION_DOC}"
assert_contains "${MIGRATION_DOC}" '^# ' "trust migration doc has a title"
assert_markdown_links "${MIGRATION_DOC}"
for topic in "[Ii]nventory" "[Ss]ingle decision point|one decision point" \
             "[Dd]omain" "[Rr]emaining" "[Bb]ehaviour|[Bb]ehavior"; do
  assert_contains "${MIGRATION_DOC}" "${topic}" "trust migration doc covers ${topic}"
done
assert_contains "docs/platform-roadmap.md" '^### v0\.9\.4 — Trust Mechanism Migration' \
  "roadmap records v0.9.4"

# --- v0.9.6 Capability Health Monitor reservation ----------------------------
HEALTH_ROADMAP="docs/platform-roadmap.md"
assert_contains "${HEALTH_ROADMAP}" '^### v0\.9\.6 — Capability Health Monitor' \
  "roadmap reserves v0.9.6 Capability Health Monitor"

# Ordering across five entries. Five milestones can all exist and still be in
# the wrong sequence, so this is checked by line number rather than presence.
health_order="$(grep -nE '^### (v0\.9\.4|v0\.9\.5|v0\.9\.6|v1\.0\.0) — ' "${ROOT}/${HEALTH_ROADMAP}" \
  | cut -d: -f1 | tr '\n' ' ')"
read -r line_094 line_095 line_096 line_100 <<<"${health_order}"
if [[ -n "${line_094}" && -n "${line_095}" && -n "${line_096}" && -n "${line_100}" ]] \
   && (( line_094 < line_095 && line_095 < line_096 && line_096 < line_100 )); then
  pass "roadmap orders v0.9.4 before v0.9.5 before v0.9.6 before v1.0.0"
else
  fail "roadmap must order v0.9.4, v0.9.5, v0.9.6, v1.0.0 (found lines: ${health_order})"
fi

# Nothing already released may be renumbered by adding a reservation.
for preserved in 'v0\.9\.0 — Remote Read-Only Collectors' 'v0\.9\.2 — Trust Plane' \
                 'v0\.9\.3 — Trust Plane Runtime Foundation' \
                 'v0\.9\.4 — Trust Mechanism Migration' \
                 'v0\.9\.5 — Distributed Capability Fabric' \
                 'v1\.0\.0 — Kyri Core Foundation'; do
  assert_contains "${HEALTH_ROADMAP}" "${preserved}" \
    "roadmap preserves ${preserved}"
done

# Declared scope. Each is a thing the monitor observes; none is a thing it does.
for scope_item in "node availability" "endpoint availability" \
                  "capability availability" "capability latency" "queue depth" \
                  "execution success" "lease health" "placement history" \
                  "resource pressure" "GPU utilization" "VRAM utilization" \
                  "CPU utilization" "memory utilization" "transport health" \
                  "Trust Plane state" "quarantine state" "maintenance" "drain" \
                  "stale heartbeat" "collector freshness" "capability degradation" \
                  "health history" "deterministic health evaluation" \
                  "immutable health observations" "explainable status"; do
  assert_contains "${HEALTH_ROADMAP}" "${scope_item}" \
    "v0.9.6 scope covers ${scope_item}"
done

# The prohibitions. Each is a thing a health monitor is most tempted to do.
for prohibition in "no autonomous remediation" "no automatic node admission" \
                   "no automatic trust changes" "no automatic workload rerouting" \
                   "no automatic drain" "no automatic quarantine" \
                   "no prediction" "no forecasting" "no ML anomaly"; do
  assert_contains "${HEALTH_ROADMAP}" "${prohibition}" \
    "v0.9.6 forbids: ${prohibition}"
done

# The architectural principle, in the approved wording.
assert_contains "${HEALTH_ROADMAP}" '[Hh]ealth never grants trust' \
  "roadmap states that health never grants trust"
assert_contains "${HEALTH_ROADMAP}" '[Tt]rust never implies health' \
  "roadmap states that trust never implies health"
assert_contains "${HEALTH_ROADMAP}" 'declared operational envelope' \
  "roadmap defines capability health against a declared operational envelope"

# The dependency rule.
for dependency in "depends on v0\.9\.5" "consumes Trust Plane state" \
                  "cannot change Trust Plane state" \
                  "recommend investigation" "cannot execute remediation"; do
  assert_contains "${HEALTH_ROADMAP}" "${dependency}" \
    "roadmap records the dependency rule: ${dependency}"
done

# The three questions, and the combinations that follow from them.
for axis in "May this subject participate" "Where can this workload execute" \
            "trusted and degraded" "trusted and unavailable" \
            "restricted and healthy" "[Hh]ealth must never override trust"; do
  assert_contains "${HEALTH_ROADMAP}" "${axis}" \
    "roadmap separates trust from health: ${axis}"
done

# Future entities are named, not built.
for entity in capability-health-observation capability-health-state \
              node-heartbeat endpoint-health lease-health placement-health \
              degradation-event; do
  assert_contains "${HEALTH_ROADMAP}" "${entity}" \
    "roadmap names the future entity ${entity}"
  if [[ -f "${ROOT}/platform-model/schemas/${entity}.schema.yaml" ]]; then
    fail "v0.9.6 is a reservation; no ${entity} schema belongs here"
  else
    pass "no premature schema for ${entity}"
  fi
done

# A reservation implements nothing.
for premature in tools/health tools/fabric tools/capability tools/monitor; do
  if [[ -e "${ROOT}/${premature}" ]]; then
    fail "v0.9.6 is a roadmap reservation; ${premature} must not exist"
  else
    pass "no premature implementation: ${premature}"
  fi
done

# --- Operator Root Authority deployment gate ---------------------------------
DEPLOY_PLAN="docs/superpowers/plans/2026-08-03-operator-root-authority-deployment.md"
DEPLOY_GUIDE="docs/trust/operator-root-authority-deployment.md"
DEPLOY_CHECK="docs/trust/operator-root-authority-validation-checklist.md"
for deploy_doc in "${DEPLOY_PLAN}" "${DEPLOY_GUIDE}" "${DEPLOY_CHECK}"; do
  assert_file "${deploy_doc}"
  assert_contains "${deploy_doc}" '^# ' "$(basename "${deploy_doc}" .md) has a title"
  assert_markdown_links "${deploy_doc}"
done

# The root stays external. Everything else in this gate follows from that.
for boundary in "external to Kyri" "declaration only|persists a declaration" \
                "cannot establish the external identity" \
                "cannot approve its own root|no self-approval" \
                "out-of-band"; do
  assert_contains "${DEPLOY_GUIDE}" "${boundary}" \
    "deployment guide records the boundary: ${boundary}"
done

# No identity may be inferred. Each source is named because each is the one
# somebody would reach for when the operator is unavailable.
for inference in "current user" "environment variable" "hostname" \
                 "SSH key owner" "Git author" "email" "shell account"; do
  assert_contains "${DEPLOY_GUIDE}" "${inference}" \
    "deployment guide forbids inferring identity from ${inference}"
done
assert_contains "${DEPLOY_GUIDE}" '[Nn]o identity is inferred|never inferred' \
  "deployment guide states no identity is inferred"

# References only, never material.
for prohibition in "no credentials" "[Ee]xternal reference" "immutable" \
                   "[Nn]o TOFU|trust on first use" "no automatic approval" \
                   "no interactive identity guessing"; do
  assert_contains "${DEPLOY_GUIDE}" "${prohibition}" \
    "deployment guide forbids: ${prohibition}"
done

# Proposed paths, and the rules that keep them out of the repository.
assert_contains "${DEPLOY_GUIDE}" '/var/lib/kyri/trust' "guide proposes a store root"
assert_contains "${DEPLOY_GUIDE}" '/etc/kyri/trust' "guide proposes an input directory"
for rule in "0700" "0600" "never inside the Git repository|outside the repository" \
            "world-readable" "group-readable" "symlink" \
            "network filesystem" "single-host"; do
  assert_contains "${DEPLOY_GUIDE}" "${rule}" \
    "guide documents the path rule: ${rule}"
done
assert_contains "${DEPLOY_GUIDE}" '[Nn]ot created|do not create|without operator approval' \
  "guide states the paths are proposed rather than created"

# The input template carries references, and the test proves no real one leaked.
for field in authority_type display_name external_identity_reference \
             verification_method subject_property observed_value_reference \
             comparison_source performed_by performed_at evidence_references \
             approval_source history_reference created_at provenance lineage_id; do
  assert_contains "${DEPLOY_GUIDE}" "${field}" "input template defines ${field}"
done
for leak in "cschott" "Chris Schott" "@gmail" "ssh-ed25519" "BEGIN OPENSSH"; do
  for deploy_doc in "${DEPLOY_PLAN}" "${DEPLOY_GUIDE}" "${DEPLOY_CHECK}"; do
    if grep -qF -- "${leak}" "${ROOT}/${deploy_doc}" 2>/dev/null; then
      fail "no real identity may appear: '${leak}' in $(basename "${deploy_doc}")"
    else
      pass "no '${leak}' in $(basename "${deploy_doc}" .md)"
    fi
  done
done

# Out-of-band verification, and the shortcuts that are not verification.
for accepted in "physical console" "management session" "printed" \
                "hardware-backed" "offline signed"; do
  assert_contains "${DEPLOY_GUIDE}" "${accepted}" \
    "guide accepts the verification source: ${accepted}"
done
assert_contains "${DEPLOY_GUIDE}" 'same channel being enrolled|same channel' \
  "guide rejects verifying identity through the channel being enrolled"
for rejected in "ssh-keyscan" "DNS alone" "hostname alone" "login identity alone" \
                "Git metadata alone" "[Ss]elf-signed"; do
  assert_contains "${DEPLOY_GUIDE}" "${rejected}" \
    "guide rejects the non-proof: ${rejected}"
done

# The dry run changes nothing, and the checklist says so.
assert_contains "${DEPLOY_CHECK}" '[Nn]on-mutating|changes nothing|writes nothing' \
  "checklist states the dry run is non-mutating"
for dry in "repository clean" "released main" "outside the repository" \
           "containment" "timezone-aware" "already exist" \
           "code-owned policy"; do
  assert_contains "${DEPLOY_CHECK}" "${dry}" "dry run checks ${dry}"
done

# init-root is documented, not executed. No test may run it.
assert_contains "${DEPLOY_GUIDE}" 'init-root' "guide documents the init-root command"
assert_contains "${DEPLOY_GUIDE}" '[Nn]ot executed|do not execute|Do not run' \
  "guide states init-root is not executed in this task"
# Scoped to the documentation suites. test-trust-runtime.sh legitimately runs
# init-root against a synthetic store in a temp directory -- that is released
# coverage, not a deployment.
# The `grep -v grep` filters exclude these assertions' own pattern lines, which
# necessarily contain the literals they search for.
if grep -n "init-root" "${ROOT}/tests/test-docs-static.sh" "${ROOT}/tests/test-static.sh" 2>/dev/null \
     | grep -v 'grep' | grep -qE 'cli\(|subprocess'; then
  fail "no documentation test may execute init-root"
else
  pass "no documentation test executes init-root"
fi
# And nothing anywhere may run it against a production path.
if grep -rn "init-root" "${ROOT}/tests/" | grep -v 'grep' | grep -qE '/var/lib|/etc/kyri'; then
  fail "no test may run init-root against a production path"
else
  pass "no test runs init-root against a production path"
fi

# The first subjects to be seeded, by domain.
for subject in "collector plugin" "source type" "remote target" \
               "remote operation" "host identity" "code-owned policy" \
               "TrustGateway configuration"; do
  assert_contains "${DEPLOY_GUIDE}" "${subject}" \
    "guide lists the initial seeded subject: ${subject}"
done

# Cutover acceptance, including the one that matters most.
assert_contains "${DEPLOY_CHECK}" 'code-owned-policy' "checklist names the current verdict source"
assert_contains "${DEPLOY_CHECK}" 'trust-plane-runtime' "checklist names the target verdict source"
for cutover in "no silent fallback" "unseeded store denies|configured but unseeded" \
               "unknown subjects deny" "quarantined" "revoked" "expired" \
               "names source|names its source" "duplicate authority"; do
  assert_contains "${DEPLOY_CHECK}" "${cutover}" \
    "checklist defines the cutover acceptance: ${cutover}"
done

# Rollback is configuration rollback, never history rollback.
for rollback in "configuration rollback" "never delete|not.*delete" \
                "preserve" "maintenance window" "operator decision"; do
  assert_contains "${DEPLOY_GUIDE}" "${rollback}" \
    "guide documents the rollback rule: ${rollback}"
done
assert_contains "${DEPLOY_GUIDE}" '[Nn]ot trust-history rollback|not a trust-history' \
  "guide distinguishes configuration rollback from trust-history rollback"

# The v0.9.5 gate now requires deployment acceptance, not just the runtime.
for gate in "Operator Root Authority instantiated" "production trust store validated" \
            "initial migrated subjects seeded" "trust-plane-runtime" \
            "code-owned fallback" "rollback procedure validated" \
            "deployment evidence retained"; do
  assert_contains "docs/platform-roadmap.md" "${gate}" \
    "roadmap v0.9.5 gate requires: ${gate}"
done

# --- A deployment plan creates no deployment --------------------------------
#
# The previous form of this check asserted that /var/lib/kyri and /etc/kyri did
# not exist on the filesystem. That was never a test of the repository; it was
# a test of the machine, and it failed the moment an operator legitimately
# followed the deployment guide on a production host. Existence proves nothing
# about who created the path.
#
# Documenting a path and creating one are different acts. Only the second is
# forbidden here, and only when the repository is what does it.
#
#   Allowed:   documentation naming these paths; the guide describing their
#              ownership and permissions; a supervised operator creating them
#              out of band; runtime using them through explicit configuration.
#
#   Forbidden: tests creating them; validation creating them; CI creating them;
#              repository code defaulting to them; store tests writing outside
#              a temporary synthetic root.
#
# Lines that legitimately name a production path carry the marker
# `prod-path-reference`, so every exception is visible and greppable rather
# than hidden inside a regex.

PROD_PATH_RE='/var/lib/kyri|/etc/kyri'          # prod-path-reference
PROD_CREATE_RE='(mkdir|install +-d|touch|tee|rm +-[rf]|cp |mv |chown|chmod|> *)'

# 1. No test may create, write to, or remove a production path.
prod_violations="$(grep -rnE "${PROD_CREATE_RE}[^|]*(${PROD_PATH_RE})" \
  "${ROOT}/tests/" 2>/dev/null | grep -v 'prod-path-reference' || true)"
if [[ -z "${prod_violations}" ]]; then
  pass "no test creates or mutates a production path"
else
  fail "a test creates a production path: $(head -1 <<<"${prod_violations}")"
fi

# 2. No repository code may treat a production path as an implicit default.
#    A default is how a path gets created by something nobody asked to run it.
prod_defaults="$(grep -rnE "(default|DEFAULT|fallback|=)[^|]*(${PROD_PATH_RE})" \
  "${ROOT}/tools/" "${ROOT}/scripts/" 2>/dev/null | grep -v 'prod-path-reference' || true)"
if [[ -z "${prod_defaults}" ]]; then
  pass "no repository code defaults to a production path"
else
  fail "repository code defaults to a production path: $(head -1 <<<"${prod_defaults}")"
fi

# 3. CI may never create a production path. A workflow runs unattended, which
#    is the definition of unsupervised.
prod_ci="$(grep -rnE "${PROD_CREATE_RE}[^|]*(${PROD_PATH_RE})" \
  "${ROOT}/.github/" 2>/dev/null | grep -v 'prod-path-reference' || true)"
if [[ -z "${prod_ci}" ]]; then
  pass "CI creates no production path"
else
  fail "CI creates a production path: $(head -1 <<<"${prod_ci}")"
fi

# 4. Every store-building suite must root its stores in a temporary directory.
#    A store test that forgot this is exactly how validation would acquire the
#    ability to write somewhere real. Either mechanism is accepted: these
#    suites drive Python, which roots its own temporary trees.
for store_suite in test-trust-runtime test-knowledge-orchestrator \
                   test-operational-integrity test-experience-engine \
                   test-occurrence-timeline; do
  if [[ -f "${ROOT}/tests/${store_suite}.sh" ]] \
     && grep -qE 'mktemp|tempfile\.TemporaryDirectory|mkdtemp' "${ROOT}/tests/${store_suite}.sh"; then
    pass "${store_suite} roots its stores in a temporary directory"
  else
    fail "${store_suite} must build stores under a temporary root, never a real path"
  fi
done

# 5. And this suite itself creates nothing. Recorded at the top of the run and
#    compared here, so the claim is about what executed rather than about what
#    the filesystem happened to contain beforehand.
if [[ "$(prod_path_state)" == "${PROD_PATH_STATE_AT_START}" ]]; then
  pass "documentation validation created no production path"
else
  fail "documentation validation changed a production path"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nStatic documentation validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nStatic documentation validation passed.\n'
