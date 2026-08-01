#!/usr/bin/env bash
set -Eeuo pipefail

# Static and behavioural validation for the collector framework.
#
# The framework must be safe by construction, not by convention, so most of
# these assertions check for the ABSENCE of capability: no network, no
# subprocess, no filesystem writes, no evidence persistence, no id assignment,
# no remediation. A collector is where the outside world first touches the
# model, and a plugin that cannot write, cannot name, and cannot act has a
# worst failure mode of a wrong observation.
#
# This script performs no network access, no SSH, and no runtime collection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COLLECTORS="tools/collectors"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_dir() {
  if [[ -d "${ROOT}/$1" ]]; then pass "directory exists: $1"; else fail "required directory missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

# Assert a pattern is absent from a path (file or directory tree).
# assert_absent_in <target> <pattern> <description> [exclude-glob]
assert_absent_in() {
  local target="$1" pattern="$2" description="$3" exclude="${4:-}" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  if [[ -n "${exclude}" ]]; then
    matches="$(grep -rIniE --exclude="${exclude}" -e "${pattern}" "${ROOT}/${target}" || true)"
  else
    matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  fi
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -3 | tr '\n' ' ')"
  fi
}

# Count files in a directory whose names start with a prefix.
#
# A glob rather than `ls | grep`: parsing ls output misbehaves on filenames
# containing newlines or unusual characters. An unmatched glob expands to the
# literal pattern, which the -e test rejects, so an absent prefix returns 0
# without needing nullglob.
count_matching_files() {
  local directory="$1"
  local prefix="$2"
  local path
  local count=0

  for path in "${directory}/${prefix}"*; do
    [[ -e "${path}" ]] || continue
    count=$((count + 1))
  done

  printf '%d\n' "${count}"
}

# --- Architecture decisions ------------------------------------------------
ADR2="docs/decisions/ADR-0002-evidence-first-architecture.md"
ADR3="docs/decisions/ADR-0003-provider-agnostic-ai-architecture.md"
assert_file "${ADR2}"
assert_file "${ADR3}"
assert_contains "${ADR2}" '^# ADR-0002:' "ADR-0002 has the expected title"
assert_contains "${ADR2}" '\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0002 is Accepted"
assert_contains "${ADR3}" '^# ADR-0003:' "ADR-0003 has the expected title"
assert_contains "${ADR3}" '\*\*Status:\*\*[[:space:]]+Accepted' "ADR-0003 is Accepted"

# ADR numbering must not collide with the existing reference-host decision.
if [[ "$(count_matching_files "${ROOT}/docs/decisions" "ADR-0002")" -eq 1 ]]; then
  pass "exactly one ADR-0002 exists"
else
  fail "ADR-0002 numbering is duplicated or missing"
fi
if [[ "$(count_matching_files "${ROOT}/docs/decisions" "ADR-0003")" -eq 1 ]]; then
  pass "exactly one ADR-0003 exists"
else
  fail "ADR-0003 numbering is duplicated or missing"
fi
assert_contains "docs/decisions/ADR-0001-schai-reference-host.md" '^# ADR-0001:' \
  "ADR-0001 remains intact and unrenumbered"

# ADR-0002 pipeline and principles.
for stage in Collector 'Normalized observation' 'Evidence record' Verification \
  'Drift assessment' Recommendation 'Human approval' 'Optional automation'; do
  assert_contains "${ADR2}" "${stage}" "ADR-0002 names the ${stage} stage"
done
assert_contains "${ADR2}" 'never modify canonical' "ADR-0002 forbids collectors modifying canonical entities"
assert_contains "${ADR2}" 'Missing evidence is not drift' "ADR-0002 separates missing evidence from drift"
assert_contains "${ADR2}" 'Collection failure is not service failure' "ADR-0002 separates collection failure from service failure"
assert_contains "${ADR2}" 'Declared intent remains authoritative' "ADR-0002 keeps declared intent authoritative"
assert_contains "${ADR2}" '[Rr]ejected' "ADR-0002 records rejected alternatives"

# ADR-0003 provider-agnostic guarantees.
assert_contains "${ADR3}" 'LiteLLM' "ADR-0003 names the current gateway"
assert_contains "${ADR3}" 'adapter' "ADR-0003 models providers as adapters"
assert_contains "${ADR3}" '[Pp]rovider-specific model names must not become application contracts' \
  "ADR-0003 forbids provider model names as contracts"
assert_contains "${ADR3}" 'local' "ADR-0003 prefers local processing for sensitive workloads"
assert_contains "${ADR3}" 'policy' "ADR-0003 requires policy authorization for external processing"
assert_contains "${ADR3}" 'No commercial or cloud fallback is silently enabled' \
  "ADR-0003 forbids silent cloud fallback"
assert_contains "${ADR3}" 'OmniRoute' "ADR-0003 addresses OmniRoute-inspired concepts"
assert_contains "${ADR3}" 'explainable|observable' "ADR-0003 requires routing decisions be explainable"

# --- Standards -------------------------------------------------------------
CAP_STANDARD="docs/standards/capability-model-standard.md"
PLUGIN_STANDARD="docs/standards/collector-plugin-standard.md"
assert_file "${CAP_STANDARD}"
assert_file "${PLUGIN_STANDARD}"
for maturity in planned foundation partial operational optimized retired; do
  assert_contains "${CAP_STANDARD}" "\`${maturity}\`" "capability standard defines ${maturity} maturity"
done
for stage in discover validate_configuration collect normalize return_result; do
  assert_contains "${PLUGIN_STANDARD}" "\`${stage}\`" "plugin standard defines the ${stage} stage"
done
for permission in read-declared-model read-repository-files synthetic-fixture-only; do
  assert_contains "${PLUGIN_STANDARD}" "\`${permission}\`" "plugin standard approves ${permission}"
done
for forbidden in write-platform-model write-evidence-store modify-runtime \
  execute-remediation manage-secrets network-admin host-admin; do
  assert_contains "${PLUGIN_STANDARD}" "\`${forbidden}\`" "plugin standard forbids ${forbidden}"
done
# Lifecycle stages that must NOT exist.
for banned in persist remediate mutate approve deploy; do
  assert_contains "${PLUGIN_STANDARD}" "${banned}" "plugin standard explicitly excludes the ${banned} stage"
done

# --- Framework modules -----------------------------------------------------
for module in __init__ base models registry normalizer exceptions validate_plugins; do
  assert_file "${COLLECTORS}/${module}.py"
done
assert_file "${COLLECTORS}/plugins/__init__.py"
assert_file "${COLLECTORS}/plugins/example/__init__.py"
assert_file "${COLLECTORS}/plugins/example/collector.py"
assert_file "${COLLECTORS}/plugins/example/manifest.yaml"
assert_file "${COLLECTORS}/README.md"

# --- Structural prohibitions ----------------------------------------------
# Safety by construction: the capability must be absent, not merely unused.
assert_absent_in "${COLLECTORS}" \
  '\b(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|telnetlib)|from[[:space:]]+(socket|requests|urllib|paramiko)[[:space:]]+import)' \
  "collector framework imports no network module"
# v0.6.0 narrows rather than relaxes the v0.5.0 prohibition: subprocess is
# permitted only inside command_runner.py, a single audited chokepoint enforcing
# shell=False, an executable allowlist, a mandatory timeout, bounded output, and
# a sanitized environment. Plugin code still never calls it directly.
assert_absent_in "${COLLECTORS}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\(|os\.exec)' \
  "collector framework invokes no subprocess outside command_runner.py" "command_runner.py"
# Writes are the capability that turns a wrong observation into a wrong record.
assert_absent_in "${COLLECTORS}" \
  "(open\\([^)]*['\"](w|a|x)|\\.write_text\\(|\\.write_bytes\\(|shutil\\.(copy|move|rmtree)|os\\.(remove|unlink|rename|mkdir|makedirs))" \
  "collector framework performs no filesystem write"
assert_absent_in "${COLLECTORS}" \
  'EVID-[0-9]' \
  "collector framework assigns no evidence identifier"
assert_absent_in "${COLLECTORS}" \
  '(def[[:space:]]+remediate|\.remediate\(|[^a-z]remediate\(|remediation_command|auto_remediate|apply_fix|execute_fix)' \
  "collector framework contains no remediation path" "validate_plugins.py"
assert_absent_in "${COLLECTORS}" \
  '\b(importlib|__import__|eval\(|exec\()' \
  "collector framework performs no dynamic import or eval" "validate_plugins.py"

# --- Example plugin manifest ----------------------------------------------
MANIFEST="${COLLECTORS}/plugins/example/manifest.yaml"
assert_contains "${MANIFEST}" 'id:[[:space:]]*example-synthetic' "example plugin uses the expected id"
assert_contains "${MANIFEST}" 'source_type:[[:space:]]*manual-attestation' "example plugin declares an approved source type"
assert_contains "${MANIFEST}" 'network_access:[[:space:]]*false' "example plugin declares no network access"
assert_contains "${MANIFEST}" 'subprocess_access:[[:space:]]*false' "example plugin declares no subprocess access"
assert_contains "${MANIFEST}" 'filesystem_access:[[:space:]]*false' "example plugin declares no filesystem access"
assert_contains "${MANIFEST}" 'synthetic-fixture-only' "example plugin is restricted to synthetic fixtures"
assert_contains "${MANIFEST}" 'test-only|non-production' "example plugin is labelled non-production"

# Forbidden permissions must appear nowhere in any manifest.
assert_absent_in "${COLLECTORS}/plugins" \
  '(write-platform-model|write-evidence-store|modify-runtime|execute-remediation|manage-secrets|network-admin|host-admin)' \
  "no plugin manifest declares a forbidden permission"
assert_absent_in "${COLLECTORS}/plugins" \
  '(password|passwd|api_key|apikey|secret_key|master_key|private_key|access_token|bearer_token)[[:space:]]*:[[:space:]]*[^[:space:]#]' \
  "no plugin manifest contains a secret value"

# --- Capability model ------------------------------------------------------
assert_dir "platform-model/capabilities"
assert_file "platform-model/capabilities/README.md"
assert_file "platform-model/schemas/capability.schema.yaml"
for capability in platform-modeling evidence-collection verification drift-detection \
  knowledge-reasoning llm-routing automation-planning human-approval-workflow; do
  assert_file "platform-model/capabilities/${capability}.yaml"
done

# --- Behavioural validation via Python ------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
failures = 0


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


# Capability entities.
cap_dir = root / "platform-model/capabilities"
capabilities = {}
if cap_dir.is_dir():
    for path in sorted(cap_dir.glob("*.yaml")):
        record = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(record, dict):
            bad(f"capability file is not a mapping: {path}")
            continue
        identifier = record.get("id")
        if identifier in capabilities:
            bad(f"duplicate capability id {identifier} in {path}")
        capabilities[identifier] = record

        if re.fullmatch(r"CAP-\d{4}", str(identifier)):
            ok(f"capability id uses four digits: {identifier}")
        else:
            bad(f"capability id is not four digits: {identifier}")

        if record.get("maturity") in {"planned", "foundation", "partial", "operational", "optimized", "retired"}:
            ok(f"{identifier} declares an approved maturity: {record.get('maturity')}")
        else:
            bad(f"{identifier} maturity is not approved: {record.get('maturity')}")

        if record.get("risk") in {"low", "medium", "high", "critical"}:
            ok(f"{identifier} declares an approved risk: {record.get('risk')}")
        else:
            bad(f"{identifier} risk is not approved: {record.get('risk')}")

required_caps = [f"CAP-{n:04d}" for n in range(1, 9)]
for required in required_caps:
    if required in capabilities:
        ok(f"required capability present: {required}")
    else:
        bad(f"required capability missing: {required}")

# Plugin manifests.
plugin_root = root / "tools/collectors/plugins"
approved_sources = {
    "manual-attestation", "command-output", "ssh-command", "api-response",
    "file-inspection", "configuration-render", "health-check", "backup-report",
    "monitoring-query", "git-repository",
}
seen_plugins = {}
for manifest_path in sorted(plugin_root.rglob("manifest.yaml")) if plugin_root.is_dir() else []:
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        bad(f"manifest is not a mapping: {manifest_path}")
        continue
    ok(f"manifest parses: {manifest_path}")

    identifier = manifest.get("id", "")
    if identifier in seen_plugins:
        bad(f"duplicate plugin id '{identifier}' in {manifest_path}")
    seen_plugins[identifier] = manifest_path

    if re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", str(identifier)):
        ok(f"plugin id is lowercase kebab-case: {identifier}")
    else:
        bad(f"plugin id is not lowercase kebab-case: {identifier}")

    if manifest.get("source_type") in approved_sources:
        ok(f"{identifier} declares an approved source type")
    else:
        bad(f"{identifier} source type is not approved: {manifest.get('source_type')}")

    # Network access is refused unconditionally: a collector that can reach the
    # network is no longer a local read-only observer. Subprocess and read-only
    # filesystem access are declarable from v0.6.0; write access never is.
    if manifest.get("network_access") is False:
        ok(f"{identifier} declares network_access: false")
    else:
        bad(f"{identifier} must declare network_access: false")
    if manifest.get("subprocess_access") in (True, False):
        ok(f"{identifier} declares a boolean subprocess_access")
    else:
        bad(f"{identifier} subprocess_access must be a boolean")
    if manifest.get("filesystem_access") in (False, "read-only"):
        ok(f"{identifier} declares non-write filesystem_access")
    else:
        bad(f"{identifier} filesystem_access must be false or read-only")

# Framework behaviour.
sys.path.insert(0, str(root.resolve()))
try:
    from tools.collectors.base import CollectorPlugin
    from tools.collectors.models import CollectorResult, CollectionContext
    from tools.collectors.registry import CollectorRegistry
    from tools.collectors.exceptions import CollectorRegistrationError
    from tools.collectors.plugins.example.collector import ExampleSyntheticCollector
    ok("collector framework modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"collector framework import failed: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

# Registry rejects duplicates.
registry = CollectorRegistry()
registry.register(ExampleSyntheticCollector)
try:
    registry.register(ExampleSyntheticCollector)
    bad("registry accepted a duplicate collector id")
except CollectorRegistrationError:
    ok("registry rejects duplicate collector ids")

# Registry does not execute plugins at registration time.
if registry.get("example-synthetic") is ExampleSyntheticCollector:
    ok("registry retrieves a plugin class without instantiating it")
else:
    bad("registry did not return the registered plugin class")

# Non-synthetic execution must fail closed.
plugin = ExampleSyntheticCollector()
context = CollectionContext(
    target="HOST-0001",
    declared={},
    requested_facts=["hostname"],
    collected_at="2026-08-01T09:00:00-05:00",
    synthetic=False,
)
result = plugin.execute(context)
if isinstance(result, CollectorResult) and result.status in {"failed", "unavailable"}:
    ok("example plugin refuses non-synthetic execution and fails closed")
else:
    bad(f"example plugin did not fail closed on non-synthetic execution: {getattr(result, 'status', result)}")

# Synthetic execution is deterministic and assigns no evidence id.
context = CollectionContext(
    target="HOST-0001",
    declared={},
    requested_facts=["hostname"],
    collected_at="2026-08-01T09:00:00-05:00",
    synthetic=True,
)
first = plugin.execute(context)
second = plugin.execute(context)
if first.status == "success":
    ok("example plugin succeeds under synthetic execution")
else:
    bad(f"example plugin failed under synthetic execution: {first.status}")
if first.content_fingerprint == second.content_fingerprint:
    ok("example plugin output is deterministic")
else:
    bad("example plugin output is not deterministic")
if not hasattr(first, "evidence_id") and "EVID" not in str(first.__dict__):
    ok("collector result carries no evidence identifier")
else:
    bad("collector result exposes an evidence identifier")

# Naive timestamps must be rejected.
naive = CollectionContext(
    target="HOST-0001",
    declared={},
    requested_facts=["hostname"],
    collected_at="2026-08-01T09:00:00",
    synthetic=True,
)
naive_result = plugin.execute(naive)
if naive_result.status in {"failed", "unavailable"}:
    ok("naive timestamp is rejected by the base lifecycle")
else:
    bad("naive timestamp was accepted")

# Secret-bearing facts must be rejected without echoing the value.
from tools.collectors.normalizer import normalize_observations, NormalizationError

try:
    normalize_observations({"api_key": "CANARY-NOT-A-REAL-VALUE"}, source="test", collected_at="2026-08-01T09:00:00-05:00")
    bad("normalizer accepted a secret-bearing fact name")
except NormalizationError as error:
    if "CANARY-NOT-A-REAL-VALUE" in str(error):
        bad("normalizer echoed the secret value in its error")
    else:
        ok("normalizer rejects secret-bearing fact names without echoing the value")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "collector framework behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'SKIP: PyYAML is not installed; behavioural validation was skipped.\n'
fi

# --- v0.7.0 boundary: collectors still never persist or number -------------
# The orchestrator exists now, so the temptation to let a collector write its
# own evidence is real. These assertions keep the boundary where ADR-0004 put
# it: collectors observe, the orchestrator remembers.
assert_absent_in "tools/collectors" 'EVID-[0-9]' \
  "collectors still assign no evidence identifier"
assert_absent_in "tools/collectors" \
  '(from[[:space:]]+tools\.observation|import[[:space:]]+tools\.observation|from[[:space:]]+\.\.observation)' \
  "collectors do not import the observation package"
assert_absent_in "tools/collectors" \
  '(EvidenceStore|write_evidence|persist_evidence|allocate_id)' \
  "collectors cannot reach the evidence store" "validate_plugins.py"

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nCollector framework validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nCollector framework validation passed.\n'
