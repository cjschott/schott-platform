#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural tests for tools/platform_model/validate_evidence.py.
#
# The repository has no established Python test framework, so the validator is
# exercised through fixture directories and exit codes: a valid fixture must
# exit 0, and each invalid fixture must exit non-zero for its own reason.
#
# Fixtures are generated into a temporary directory at run time and are never
# committed, so no secret-shaped value ever enters the repository. The
# "secret-bearing" fixture uses an obvious placeholder, not a realistic key.
#
# This script performs no network access, no SSH, and no runtime collection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATOR="${ROOT}/tools/platform_model/validate_evidence.py"
FAILURES=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

if [[ ! -f "${VALIDATOR}" ]]; then
  fail "validator missing: tools/platform_model/validate_evidence.py"
  printf '\nEvidence validator tests failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi
pass "validator exists: tools/platform_model/validate_evidence.py"

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  printf 'SKIP: PyYAML is not installed; validator behaviour tests were skipped.\n'
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Build a fixture model root. $1 is the fixture name; remaining setup is done by
# the caller writing extra files into ${WORK}/$1.
new_fixture() {
  local name="$1"
  local dir="${WORK}/${name}"
  mkdir -p "${dir}"/{hosts,evidence,verifications,drift-rules,schemas}
  cp "${ROOT}"/platform-model/schemas/*.schema.yaml "${dir}/schemas/"

  cat >"${dir}/hosts/fixture-host.yaml" <<'YAML'
id: HOST-9001
type: host
name: fixture-host
hostname: fixture-host
slug: fixture-host
lifecycle: active
owner: platform-engineering
platform_role: ROLE-9001
environment: production
criticality: tier-2
provenance:
  class: declared
  source: fixture
  recorded_at: 2026-08-01
observability:
  authoritative_logs: host-local
security:
  hardening_standard: fixture
YAML

  printf '%s\n' "${dir}"
}

# run_case <description> <fixture-dir> <expect-zero|expect-nonzero> [error-substring]
run_case() {
  local desc="$1" dir="$2" expect="$3" needle="${4:-}"
  local output status
  set +e
  output="$(python3 "${VALIDATOR}" --root "${dir}" 2>&1)"
  status=$?
  set -e

  if [[ "${expect}" == "expect-zero" ]]; then
    if [[ "${status}" -eq 0 ]]; then
      pass "${desc}"
    else
      fail "${desc} (expected exit 0, got ${status}: ${output})"
    fi
    return
  fi

  if [[ "${status}" -eq 0 ]]; then
    fail "${desc} (expected non-zero exit, got 0)"
    return
  fi
  local scrubbed
  scrubbed="${output//${dir}/<FIXTURE>}"
  if [[ -n "${needle}" ]] && ! grep -qi -- "${needle}" <<<"${scrubbed}"; then
    fail "${desc} (exit ${status} but message lacked '${needle}': ${scrubbed})"
    return
  fi
  pass "${desc}"
}

# --- Valid baseline -------------------------------------------------------
VALID="$(new_fixture c18)"
cat >"${VALID}/evidence/evid-0001.yaml" <<'YAML'
id: EVID-000001
type: evidence
target: HOST-9001
source_type: manual-attestation
collector: fixture-suite
collected_at: 2026-08-01T09:00:00-05:00
status: success
provenance:
  class: observed
  observed_at: 2026-08-01T09:00:00-05:00
sensitivity: internal
retention: 90d
content_fingerprint: sha256:0000000000000000000000000000000000000000000000000000000000000000
redaction:
  performed: false
facts:
  hostname: fixture-host
references: []
YAML
cat >"${VALID}/verifications/ver-0001.yaml" <<'YAML'
id: VER-000001
type: verification
target: HOST-9001
rule: DRIFT-9001
evaluated_at: 2026-08-01T09:05:00-05:00
evidence:
  - EVID-000001
state: verified
result: match
severity: information
declared_value: fixture-host
observed_value: fixture-host
explanation: Declared hostname matched the attested hostname.
recommended_action: none
provenance:
  class: inferred
  derived_from:
    - EVID-000001
approval_required: false
YAML
cat >"${VALID}/drift-rules/core.yaml" <<'YAML'
drift_rules:
  - id: DRIFT-9001
    name: Hostname matches declaration
    description: The attested hostname matches the declared hostname.
    target_entity_types: [host]
    declared_path: hostname
    observed_fact: hostname
    comparator: equals
    evidence_max_age: null
    review_required: true
    severity: medium
    missing_evidence_result: missing_observation
    mismatch_result: mismatch
    enabled: true
    remediation_mode: advisory
YAML
run_case "valid fixture passes" "${VALID}" expect-zero

# --- Invalid cases --------------------------------------------------------
D="$(new_fixture c01)"
for n in a b; do
  sed "s/EVID-000001/EVID-000002/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/evid-${n}.yaml"
done
run_case "duplicate evidence ids are rejected" "${D}" expect-nonzero "duplicate"

D="$(new_fixture c02)"
sed "s/EVID-000001/EVID-00001/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "five-digit evidence id is rejected" "${D}" expect-nonzero "pattern"

D="$(new_fixture c03)"
sed "s/target: HOST-9001/target: HOST-9999/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "unresolvable evidence target is rejected" "${D}" expect-nonzero "resolve"

D="$(new_fixture c04)"
sed "s/source_type: manual-attestation/source_type: telepathy/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "unapproved evidence source type is rejected" "${D}" expect-nonzero "source_type"

D="$(new_fixture c05)"
grep -v '^collected_at:' "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "evidence without collected_at is rejected" "${D}" expect-nonzero "collected_at"

D="$(new_fixture c06)"
sed "s/collected_at: .*/collected_at: 2026-08-01T09:00:00/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "timestamp without timezone is rejected" "${D}" expect-nonzero "timezone"

D="$(new_fixture c07)"
grep -v '^  observed_at:' "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "observed provenance without observed_at is rejected" "${D}" expect-nonzero "observed_at"

D="$(new_fixture c08)"
sed "s/status: success/status: failed/" "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "failed evidence without an error summary is rejected" "${D}" expect-nonzero "error"

# Placeholder only. Deliberately not a realistic credential.
D="$(new_fixture c09)"
sed 's/^  hostname: fixture-host$/  hostname: fixture-host\n  api_key: PLACEHOLDER-NOT-A-REAL-VALUE/' \
  "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
run_case "secret-bearing evidence key is rejected" "${D}" expect-nonzero "secret"

D="$(new_fixture c10)"
sed "s/^state: verified/state: probably-fine/" "${VALID}/verifications/ver-0001.yaml" >"${D}/verifications/v.yaml"
cp "${VALID}/evidence/evid-0001.yaml" "${D}/evidence/"
cp "${VALID}/drift-rules/core.yaml" "${D}/drift-rules/"
run_case "unapproved verification state is rejected" "${D}" expect-nonzero "state"

D="$(new_fixture c11)"
sed "s/  - EVID-000001/  - EVID-999999/" "${VALID}/verifications/ver-0001.yaml" >"${D}/verifications/v.yaml"
cp "${VALID}/evidence/evid-0001.yaml" "${D}/evidence/"
cp "${VALID}/drift-rules/core.yaml" "${D}/drift-rules/"
run_case "verification referencing unknown evidence is rejected" "${D}" expect-nonzero "evidence"

D="$(new_fixture c12)"
python3 - "${VALID}/verifications/ver-0001.yaml" "${D}/verifications/v.yaml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read().replace("evidence:\n  - EVID-000001\n", "evidence: []\n")
open(dst, "w").write(text)
PY
cp "${VALID}/evidence/evid-0001.yaml" "${D}/evidence/"
cp "${VALID}/drift-rules/core.yaml" "${D}/drift-rules/"
run_case "verified state with no evidence is rejected" "${D}" expect-nonzero "evidence"

D="$(new_fixture c13)"
sed "s/remediation_mode: advisory/remediation_mode: automatic/" "${VALID}/drift-rules/core.yaml" >"${D}/drift-rules/core.yaml"
run_case "automatic remediation is rejected" "${D}" expect-nonzero "remediation"

D="$(new_fixture c14)"
sed "s/comparator: equals/comparator: vibes/" "${VALID}/drift-rules/core.yaml" >"${D}/drift-rules/core.yaml"
run_case "unapproved comparator is rejected" "${D}" expect-nonzero "comparator"

D="$(new_fixture c15)"
sed "s/severity: medium/severity: catastrophic/" "${VALID}/drift-rules/core.yaml" >"${D}/drift-rules/core.yaml"
run_case "unapproved drift severity is rejected" "${D}" expect-nonzero "severity"

D="$(new_fixture c16)"
{ cat "${VALID}/verifications/ver-0001.yaml"; printf 'remediation_command: restart-everything\n'; } >"${D}/verifications/v.yaml"
cp "${VALID}/evidence/evid-0001.yaml" "${D}/evidence/"
cp "${VALID}/drift-rules/core.yaml" "${D}/drift-rules/"
run_case "high-impact action field is rejected" "${D}" expect-nonzero "action"

# The validator must never echo a value it flagged as secret-bearing.
D="$(new_fixture c17)"
sed 's/^  hostname: fixture-host$/  hostname: fixture-host\n  password: PLACEHOLDER-NOT-A-REAL-VALUE/' \
  "${VALID}/evidence/evid-0001.yaml" >"${D}/evidence/e.yaml"
set +e
secret_output="$(python3 "${VALIDATOR}" --root "${D}" 2>&1)"
set -e
if grep -q 'PLACEHOLDER-NOT-A-REAL-VALUE' <<<"${secret_output}"; then
  fail "validator echoed the flagged value back in its error output"
else
  pass "validator reports a secret-bearing key without echoing its value"
fi

# --- v0.7.0 identifier widths ----------------------------------------------
# Evidence and verification widened to six digits; capability and drift-rule
# identifiers are human-authored and must stay at four.
if grep -q "EVID-\[0-9\]{6}" "${ROOT}/platform-model/schemas/evidence.schema.yaml"; then
  pass "evidence schema requires six-digit identifiers"
else
  fail "evidence schema must require six-digit identifiers"
fi
if grep -q "VER-\[0-9\]{6}" "${ROOT}/platform-model/schemas/verification.schema.yaml"; then
  pass "verification schema requires six-digit identifiers"
else
  fail "verification schema must require six-digit identifiers"
fi
if grep -q "DRIFT-\[0-9\]{4}" "${ROOT}/platform-model/schemas/drift-rule.schema.yaml"; then
  pass "drift-rule identifiers remain four digits"
else
  fail "drift-rule identifiers must remain four digits"
fi

# A six-digit identifier must be accepted by the validator, not merely allowed
# by the pattern.
D="$(new_fixture c19)"
cp "${VALID}/evidence/evid-0001.yaml" "${D}/evidence/"
cp "${VALID}/verifications/ver-0001.yaml" "${D}/verifications/"
cp "${VALID}/drift-rules/core.yaml" "${D}/drift-rules/"
run_case "six-digit evidence and verification ids are accepted" "${D}" expect-zero ""

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nEvidence validator tests failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nEvidence validator tests passed.\n'
