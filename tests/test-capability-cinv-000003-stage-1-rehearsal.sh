#!/usr/bin/env bash
set -Eeuo pipefail

# The CINV-000003 Stage 1 ceremony, rehearsed whole.
#
# HOST-ONLY. It runs the ENTIRE operator block -- every command the operator
# will paste, in order, with the real released CLI -- and that needs the
# governed stores. See tests/host-only.manifest.
#
# STAGE 1 IS THE FIRST IRREVERSIBLE STEP
# ======================================
# `capability invoke` allocates CINV-000003, writes an immutable record and
# advances capability-invocation.seq. The identity is SPENT EVEN ON A REFUSAL:
# `record_invocation` allocates inside its critical section before it decides
# whether the evidence supports the invocation, and a refusal allocates a CRES
# too. There is no path that reaches the invoke and allocates nothing.
#
# So every gate is rehearsed against a fixture first, and the assertion that
# matters is where control stopped: a sabotage that lets the invoke run has
# spent an identity in the rehearsal, and the suite checks the fixture
# sequences to prove that did not happen.
#
# rc=1 IS THE SUCCESS CODE. `command_invoke` returns EXIT_DENIED
# unconditionally. The suite requires rc to be exactly 1 AND the JSON verdict
# to be exactly the released success -- neither alone.
#
# Three substitutions and nothing else:
#
#   /data/kyri/capability-runtime  -> a byte copy inside the fixture
#   /var/lib/kyri/fabric           -> a byte copy inside the fixture
#   /data/kyri/work/g11bcn         -> a work root inside the fixture
#
# plus the two baselines those force, the witness path, and the expected staged
# path, which is rooted in the runtime store. The aggregate digests `sha256sum`
# output, which names absolute paths, so it is root-dependent by construction.
#
# Trust, Evidence and the artifact store stay pointed at the real stores: the
# block only ever reads them.
#
# BLOCK A is NOT run. It needs the kyri-capability account through sudo, which
# a test may not assume. The suite writes the witness BLOCK A would write, and
# separately proves BLOCK B refuses an absent, stale, foreign or wrong witness
# -- which is the whole of what BLOCK B relies on it for.
#
# Production is never written. The suite proves that by aggregate, not by
# intention, after every run including the sabotaged ones.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires \
  /var/lib/kyri/fabric /var/lib/kyri/trust /var/lib/kyri/evidence \
  /var/lib/kyri/artifacts /data/kyri/capability-runtime /data/kyri/work/g11bcn

ARTIFACT="${ROOT}/provisioning/execution/g11-bc-n-cinv-000003-stage-1-ceremony.txt"
PAYLOAD="${ROOT}/provisioning/execution/g11-bc-n-cinv-000003-payload.json"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_RUNTIME=/data/kyri/capability-runtime
PRODUCTION_WORK=/data/kyri/work/g11bcn
PRODUCTION_WITNESS=/data/kyri/work/g11bcn-stage-1-witness

REVIEWED_RAW=d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569
EXPECTED_CINV=CINV-000003
EXPECTED_RC=1
EXPECTED_STATUS=prepared
EXPECTED_REASON=no_authorised_adapter
EXPECTED_PAYLOAD_DIGEST=sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
EXPECTED_BINDING_DIGEST=sha256:6d5a8d9249c7c9407145a69b55748136020a1a696c2e167d879864dc2dc86289
EXPECTED_ARTIFACT_DIGEST=sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
EXPECTED_IMAGE=5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
FABRIC_BASELINE=a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5
RUNTIME_BASELINE=159651ee6c98113f182b80cecdff5a83f5782df8ff8e16c6cf30ac91f0ea92fc
CINV_SEQ_BEFORE=2
CRES_SEQ_BEFORE=1
CINV_SEQ_AFTER=3

# THE CEREMONY IS SPENT ONCE CINV-000003 EXISTS.
#
# Stage 1 allocated the invocation identity. That is irreversible: identities
# are spent, not reserved, and the Capability Runtime is append-only. The
# block's own Gate 3 refuses when CINV-000003 is present, so the ceremony can
# never be rehearsed again -- and it must never be re-run, because a replayed
# invocation_id resolves to the existing record and returns `consumed`.
#
# Deleting the suite would delete the evidence; leaving it asserting a vanished
# world would make it fail forever for the one reason that is not a defect.
#
# DURABLE FACTS ONLY. The record is immutable, so its SHA is now an OBSERVED
# fact and may be pinned -- it could not be predicted before the write, because
# `requested_at` carries the operator's clock, but it cannot change afterwards.
# The runtime whole-store aggregate is deliberately NOT pinned: Stage 2
# legitimately writes lifecycle state, a projection and a handoff, and pinning a
# whole-store aggregate in spent-mode evidence is the defect that broke the
# CINST-000006 spent mode when CROUTE-0006 landed.
ACCEPTED_RECORD=/data/kyri/capability-runtime/capability-invocations/CINV-000003.yaml
ACCEPTED_RECORD_SHA256=c0941b7d45dcccac4bb28d00f942ea63aa90cd46ed55767797363f1ed1accaf2
ACCEPTED_RECORD_BYTES=988

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() {
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

PRODUCTION_FABRIC_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"
PRODUCTION_RUNTIME_BEFORE="$(aggregate "${PRODUCTION_RUNTIME}")"

if [[ "${PRODUCTION_FABRIC_BEFORE}" == "${FABRIC_BASELINE}" ]]; then
  pass "production Fabric is at the pinned baseline before the rehearsal"
else
  fail "production Fabric is ${PRODUCTION_FABRIC_BEFORE}, not the pinned ${FABRIC_BASELINE}"
fi
# ---- has the ceremony been performed? -------------------------------------

if [[ -e "${ACCEPTED_RECORD}" ]]; then
  printf '\n--- the Stage 1 ceremony is spent ---\n'
  pass "${EXPECTED_CINV} is written; the invocation identity is permanently spent"

  record_sha="$(sha256sum "${ACCEPTED_RECORD}" | cut -d' ' -f1)"
  if [[ "${record_sha}" == "${ACCEPTED_RECORD_SHA256}" ]]; then
    pass "the persisted record is the accepted one (${ACCEPTED_RECORD_SHA256})"
  else
    fail "the persisted record is ${record_sha}, accepted ${ACCEPTED_RECORD_SHA256}"
  fi
  if [[ "$(wc -c < "${ACCEPTED_RECORD}")" == "${ACCEPTED_RECORD_BYTES}" ]]; then
    pass "the persisted record is ${ACCEPTED_RECORD_BYTES} bytes"
  else
    fail "the persisted record is $(wc -c < "${ACCEPTED_RECORD}") bytes"
  fi
  if [[ "$(stat -c '%a' "${ACCEPTED_RECORD}")" == "600" ]]; then
    pass "the persisted record is mode 0600"
  else
    fail "the persisted record is mode $(stat -c '%a' "${ACCEPTED_RECORD}")"
  fi

  for field in "invocation_record_id: ${EXPECTED_CINV}" \
               'invocation_id: g11bcn-third-controlled-invoke' \
               'request_id: g11bcn-third-production-invoke' \
               'selection_id: CSEL-000004' \
               'instance_id: CINST-000006' \
               'capability_package_id: CPKG-0001' \
               'capability_id: CAPDEF-0001' \
               'contract_id: CCON-0001' \
               'operation: execute' \
               'kind: capability-invocation' \
               'schema_version: 2' \
               'effect_class: computational' \
               'adapter_identity: null' \
               'outcome: execution-prepared' \
               "payload_digest: ${EXPECTED_PAYLOAD_DIGEST}" \
               "binding_digest: ${EXPECTED_BINDING_DIGEST}" \
               "artifact_digest: ${EXPECTED_ARTIFACT_DIGEST}"; do
    if grep -qF -- "${field}" "${ACCEPTED_RECORD}"; then
      pass "the record carries ${field}"
    else
      fail "the record does not carry ${field}"
    fi
  done

  # Monotonic, so "at or past" rather than "equal to": a later invocation
  # legitimately raises it, and the whole-store aggregate is not pinned at all.
  seq_now="$(cat "${PRODUCTION_RUNTIME}/sequences/capability-invocation.seq")"
  if [[ "${seq_now}" =~ ^[0-9]+$ ]] && (( seq_now >= CINV_SEQ_AFTER )); then
    pass "capability-invocation.seq is ${seq_now}, at or past the ${CINV_SEQ_AFTER} this write allocated"
  else
    fail "capability-invocation.seq is ${seq_now}, below the ${CINV_SEQ_AFTER} this write allocated"
  fi

  # Stage 1 wrote no result and reached no execution surface. Both stay true
  # until a later stage legitimately changes them, so they are asserted as
  # Stage 1's own effect rather than as a permanent property of the store.
  if [[ ! -e "${PRODUCTION_RUNTIME}/capability-results/CRES-000002.yaml" ]]; then
    pass "Stage 1 wrote no result record"
  else
    fail "a result record exists for this invocation"
  fi

  # The Stage 0 payload the record binds must still be the reviewed bytes:
  # Stage 2 re-presents it and checks it against this record's payload_digest.
  spent_payload="${PRODUCTION_WORK}/third-invoke.json"
  if [[ "$(sha256sum "${spent_payload}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]] \
     && [[ "$(stat -c '%a' "${spent_payload}")" == "600" ]] \
     && [[ "$(stat -c '%h' "${spent_payload}")" == "1" ]]; then
    pass "the Stage 0 payload is still the reviewed payload, 0600, one link"
  else
    fail "the Stage 0 payload has drifted"
  fi

  # The committed ceremony still describes what was done.
  if grep -qF -- "${EXPECTED_PAYLOAD_DIGEST}" "${ARTIFACT}" \
     && grep -qF -- "${EXPECTED_BINDING_DIGEST}" "${ARTIFACT}"; then
    pass "the committed Stage 1 ceremony still pins the reviewed digests"
  else
    fail "the committed Stage 1 ceremony no longer pins the reviewed digests"
  fi

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'CINV-000003 Stage 1 rehearsal: ceremony spent, accepted write verified.\n'
    exit 0
  fi
  printf 'CINV-000003 Stage 1 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi

pass "${EXPECTED_CINV} is absent from production"

# Only meaningful while Stage 1 is unspent: Stage 1 moves this aggregate by
# design, which is why the spent branch above does not assert it at all.
if [[ "${PRODUCTION_RUNTIME_BEFORE}" == "${RUNTIME_BASELINE}" ]]; then
  pass "the production runtime store is at the pinned pre-Stage-1 baseline"
else
  fail "the production runtime store is ${PRODUCTION_RUNTIME_BEFORE}, not ${RUNTIME_BASELINE}"
fi

# ---- Stage 0's durable output, which Stage 1 depends on --------------------

printf '\n--- the Stage 0 work area ---\n'
if [[ "$(stat -c '%u' "${PRODUCTION_WORK}")" == "1000" \
   && "$(stat -c '%a' "${PRODUCTION_WORK}")" == "700" ]]; then
  pass "the work root is uid 1000, mode 0700"
else
  fail "the work root is uid $(stat -c '%u' "${PRODUCTION_WORK}") mode $(stat -c '%a' "${PRODUCTION_WORK}")"
fi
prod_payload="${PRODUCTION_WORK}/third-invoke.json"
if [[ -f "${prod_payload}" ]] \
   && [[ "$(stat -c '%u' "${prod_payload}")" == "1000" ]] \
   && [[ "$(stat -c '%a' "${prod_payload}")" == "600" ]] \
   && [[ "$(stat -c '%h' "${prod_payload}")" == "1" ]] \
   && [[ "$(sha256sum "${prod_payload}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]]; then
  pass "the Stage 0 payload is the reviewed payload, uid 1000, 0600, one link"
else
  fail "the Stage 0 payload does not meet the trusted-source requirements"
fi
if cmp -s "${prod_payload}" "${PAYLOAD}"; then
  pass "the Stage 0 payload is byte-identical to the committed payload"
else
  fail "the Stage 0 payload differs from the committed payload"
fi

# ---- the block, extracted -------------------------------------------------

BLOCK="${WORK}/block.sh"
awk "/^bash <<'STAGE1'\$/{on=1;next} /^STAGE1\$/{on=0} on" "${ARTIFACT}" > "${BLOCK}"
if [[ -s "${BLOCK}" ]]; then
  pass "BLOCK B was extracted whole ($(wc -l < "${BLOCK}") lines)"
else
  fail "BLOCK B could not be extracted"
  exit 1
fi

OBSERVE="${WORK}/observe.sh"
awk "/^bash <<'OBSERVE'\$/{on=1;next} /^OBSERVE\$/{on=0} on" "${ARTIFACT}" > "${OBSERVE}"
if [[ -s "${OBSERVE}" ]]; then
  pass "BLOCK A was extracted whole ($(wc -l < "${OBSERVE}") lines)"
else
  fail "BLOCK A could not be extracted"
fi

# The irreversible block must not need privilege: a sudo prompt inside it would
# land between the gates and the allocation.
if grep -q 'sudo' "${BLOCK}"; then
  fail "BLOCK B contains sudo; the irreversible block must need no privilege"
else
  pass "BLOCK B needs no privilege"
fi
# And the observation block must run from somewhere kyri-capability can reach.
if grep -q '^cd /tmp$' "${OBSERVE}"; then
  pass "BLOCK A runs from /tmp, which kyri-capability can traverse"
else
  fail "BLOCK A does not cd to /tmp; runuser inherits the caller's directory"
fi

# Exactly one production invoke that is not a preflight.
joined="${WORK}/joined"
sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "${BLOCK}" > "${joined}"
live=0; live_unguarded=0
while IFS= read -r call; do
  [[ "${call}" == *"--store-root /data/kyri/capability-runtime"* ]] || continue
  live=$((live + 1))
  [[ "${call}" == *"--preflight"* ]] || live_unguarded=$((live_unguarded + 1))
done < <(grep -- "tools.capability.cli invoke" "${joined}" || true)
if (( live == 2 && live_unguarded == 1 )); then
  pass "BLOCK B runs exactly one production invoke without --preflight, and one preflight"
else
  fail "BLOCK B runs ${live} production invokes, ${live_unguarded} without --preflight"
fi
# The invoke must not be under `set -e`.
if grep -q '^set +e$' "${BLOCK}" && grep -q '^INVOKE_RC=\$?$' "${BLOCK}"; then
  pass "BLOCK B disables errexit around the invoke and captures its status"
else
  fail "BLOCK B does not capture the invoke status with errexit disabled"
fi

# ---- the fixture ----------------------------------------------------------

build_fixture() {
  local fixture="$1"
  # The staged package tree is copied with its real, read-only modes; rm -rf
  # cannot remove a file from a directory it may not write.
  if [[ -e "${fixture}" ]]; then
    chmod -R u+w "${fixture}" 2>/dev/null || true
    rm -rf "${fixture}"
  fi
  mkdir -p "${fixture}"
  cp -a "${PRODUCTION_FABRIC}" "${fixture}/fabric"
  cp -a "${PRODUCTION_RUNTIME}" "${fixture}/runtime"
  mkdir -p "${fixture}/workparent"
  cp -a "${PRODUCTION_WORK}" "${fixture}/workparent/g11bcn"
  chmod 0700 "${fixture}/workparent/g11bcn"
  chmod 0600 "${fixture}/workparent/g11bcn/third-invoke.json"
  # The witness BLOCK A would have written.
  printf 'stage-1-observation\nimage %s\nno-target-container kyri-%s\n' \
    "${EXPECTED_IMAGE}" "${EXPECTED_CINV}" > "${fixture}/workparent/g11bcn-stage-1-witness"
  chmod 0600 "${fixture}/workparent/g11bcn-stage-1-witness"
}

render_block() {
  local fixture="$1" out="$2"
  local fabric_baseline runtime_baseline
  fabric_baseline="$(aggregate "${fixture}/fabric")"
  runtime_baseline="$(aggregate "${fixture}/runtime")"
  sed \
    -e "s#${PRODUCTION_WITNESS}#${fixture}/workparent/g11bcn-stage-1-witness#g" \
    -e "s#${PRODUCTION_WORK}#${fixture}/workparent/g11bcn#g" \
    -e "s#${PRODUCTION_RUNTIME}#${fixture}/runtime#g" \
    -e "s#${PRODUCTION_FABRIC}#${fixture}/fabric#g" \
    -e "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=${fabric_baseline}#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=${runtime_baseline}#" \
    "${BLOCK}" > "${out}"
}

run_block() {
  local rendered="$1" out="$2"
  local status=0
  ( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
  return "${status}"
}

# ---- the happy path -------------------------------------------------------

printf '\n--- the whole block, end to end ---\n'

FIX="${WORK}/fix"
build_fixture "${FIX}"
rendered="${WORK}/rendered.sh"
render_block "${FIX}" "${rendered}"

if grep -q -e "${PRODUCTION_RUNTIME}" -e "${PRODUCTION_FABRIC}" -e "${PRODUCTION_WORK}" "${rendered}"; then
  fail "the rendered block still references a production path"
else
  pass "the rendered block references no production runtime, Fabric or work path"
fi

FIX_RUNTIME_BEFORE="$(aggregate "${FIX}/runtime")"
FIX_FABRIC_BEFORE="$(aggregate "${FIX}/fabric")"

out="${WORK}/run.out"
status=0
run_block "${rendered}" "${out}" || status=$?

if (( status == 0 )); then
  pass "the whole block runs to completion against the fixture"
else
  fail "the whole block failed (status ${status}): $(tail -4 "${out}" | tr '\n' ' ')"
fi

for expected in \
  'ok  observation' \
  'ok  observed_at <= now < valid_until' \
  'ok  CROUTE-0006 routes to exactly CINST-000006' \
  'ok  CSEL-000004 selects CINST-000006 through CROUTE-0006' \
  'ok  eligible true, no unmet conditions' \
  'ok  CINST-000006 eligible at the current clock' \
  "ok  ${EXPECTED_CINV} absent" \
  'ok  trust valid, no problems' \
  'ok  work root 0700 uid 1000, payload 0600 uid 1000, one link' \
  'ok  operation verify-execution-boundary, count 1, reviewed label' \
  "ok  would_accept true, predicted ${EXPECTED_CINV}" \
  'ALL GATES PASSED. THE NEXT COMMAND IS IRREVERSIBLE.' \
  "ok  process rc ${EXPECTED_RC}, as the released contract returns" \
  "ok  status   ${EXPECTED_STATUS}" \
  "ok  reason   ${EXPECTED_REASON}" \
  "ok  invocation_record_id  ${EXPECTED_CINV}" \
  'ok  result_record_id      null -- prepared, not refused' \
  'ok  every reviewed field is present in the record' \
  'ok  record mode 0600' \
  "ok  capability-invocation.seq ${CINV_SEQ_BEFORE} -> ${CINV_SEQ_AFTER}" \
  "ok  capability-result.seq still ${CRES_SEQ_BEFORE}" \
  'ok  no result record was created' \
  'ok  one staged commitment, reused not rebuilt' \
  "ok  no execution state for ${EXPECTED_CINV}" \
  'ok  fabric unchanged' \
  'STAGE 1 COMPLETE. STOP HERE.'
do
  if grep -qF "${expected}" "${out}"; then
    pass "the block reports: ${expected}"
  else
    fail "the block did not report: ${expected}"
  fi
done

if grep -qF 'eligible True | 12 of 12 met | unmet [] | reasons []' "${out}"; then
  pass "the block reports CINST-000006 eligible 12 of 12"
else
  fail "the block did not report 12 of 12"
fi
if grep -qF 'process rc=1' "${out}"; then
  pass "the invoke returned rc=1, the released success code"
else
  fail "the invoke did not return rc=1"
fi

# ---- exactly what Stage 1 did to the fixture ------------------------------

printf '\n--- the Stage 1 mutation, measured ---\n'

record="${FIX}/runtime/capability-invocations/${EXPECTED_CINV}.yaml"
if [[ -f "${record}" ]]; then
  pass "the immutable invocation record was written"
  if [[ "$(stat -c '%a' "${record}")" == "600" ]]; then
    pass "the invocation record is mode 0600"
  else
    fail "the invocation record is mode $(stat -c '%a' "${record}")"
  fi
  for field in "invocation_record_id: ${EXPECTED_CINV}" \
               'invocation_id: g11bcn-third-controlled-invoke' \
               'request_id: g11bcn-third-production-invoke' \
               'selection_id: CSEL-000004' \
               'instance_id: CINST-000006' \
               'capability_package_id: CPKG-0001' \
               'capability_id: CAPDEF-0001' \
               'contract_id: CCON-0001' \
               'operation: execute' \
               'kind: capability-invocation' \
               'schema_version: 2' \
               'effect_class: computational' \
               'adapter_identity: null' \
               'outcome: execution-prepared' \
               "payload_digest: ${EXPECTED_PAYLOAD_DIGEST}" \
               "binding_digest: ${EXPECTED_BINDING_DIGEST}" \
               "artifact_digest: ${EXPECTED_ARTIFACT_DIGEST}"; do
    if grep -qF -- "${field}" "${record}"; then
      pass "the record carries ${field}"
    else
      fail "the record does not carry ${field}"
    fi
  done
  # adapter_identity null is what makes an unresolved invocation
  # distinguishable later: nothing was ever authorised to run.
  if grep -qF 'adapter_identity: null' "${record}"; then
    pass "adapter_identity is null; no mechanism was authorised"
  else
    fail "adapter_identity is not null"
  fi
else
  fail "the invocation record was not written"
fi

if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_AFTER}" ]]; then
  pass "the fixture capability-invocation.seq advanced ${CINV_SEQ_BEFORE} -> ${CINV_SEQ_AFTER}"
else
  fail "the fixture capability-invocation.seq is $(cat "${FIX}/runtime/sequences/capability-invocation.seq")"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-result.seq")" == "${CRES_SEQ_BEFORE}" ]]; then
  pass "the fixture capability-result.seq is still ${CRES_SEQ_BEFORE}"
else
  fail "the fixture capability-result.seq moved; a result was allocated"
fi
if [[ ! -e "${FIX}/runtime/capability-results/CRES-000002.yaml" ]]; then
  pass "no CRES was created"
else
  fail "A RESULT RECORD WAS CREATED"
fi
if [[ ! -e "${FIX}/runtime/execution/${EXPECTED_CINV}" ]]; then
  pass "no execution state exists for ${EXPECTED_CINV}; nothing ran"
else
  fail "EXECUTION STATE EXISTS for ${EXPECTED_CINV}"
fi
staged_count="$(find "${FIX}/runtime/staging" -mindepth 1 -maxdepth 1 | wc -l)"
if [[ "${staged_count}" == "1" ]]; then
  pass "the staging directory holds exactly one commitment, reused not rebuilt"
else
  fail "the staging directory holds ${staged_count} commitments"
fi
if [[ "$(aggregate "${FIX}/fabric")" == "${FIX_FABRIC_BEFORE}" ]]; then
  pass "the fixture Fabric store is byte-identical; Stage 1 does not touch Fabric"
else
  fail "THE FIXTURE FABRIC STORE CHANGED during Stage 1"
fi

# The complete runtime mutation, by content: exactly one new file and one
# changed sequence, proved by reconstruction rather than by enumeration.
recon="${WORK}/recon"
if [[ -e "${recon}" ]]; then chmod -R u+w "${recon}"; rm -rf "${recon}"; fi
cp -a "${FIX}/runtime" "${recon}"
rm -f "${recon}/capability-invocations/${EXPECTED_CINV}.yaml"
printf '%s\n' "${CINV_SEQ_BEFORE}" > "${recon}/sequences/capability-invocation.seq"
# The reconstruction is digested under the fixture's own path strings, because
# the aggregate names absolute paths and is root-dependent by construction.
recon_agg="$(find "${recon}" -type f -print0 | sort -z | xargs -0 sha256sum \
             | sed "s#${recon}#${FIX}/runtime#" | sha256sum | cut -d' ' -f1)"
if [[ "${recon_agg}" == "${FIX_RUNTIME_BEFORE}" ]]; then
  pass "removing the record and rewinding the sequence reproduces the pre-Stage-1 store exactly"
else
  fail "the Stage 1 mutation was not exactly one record and one sequence change"
fi

# ---- fail closed, by stage ------------------------------------------------
#
# Each sabotage changes exactly one thing and asserts where control stopped,
# AND that the refusal is that stage's own judgement. The assertion that
# matters most for a pre-invoke sabotage is that the fixture sequence did NOT
# move: an identity spent in a rehearsal is an identity the gate failed to
# protect.

printf '\n--- fail closed, by stage ---\n'

cat > "${WORK}/expired-advert.json" <<'EXPIRED_ADVERT'
{"findings": [], "reason": null,
 "records": [{"advertisement_id": "CADV-000007",
              "observed_at": "2026-09-15T06:00:00-05:00",
              "valid_until": "2026-09-19T06:00:00-05:00"}]}
EXPIRED_ADVERT

cat > "${WORK}/expired-instance.json" <<'EXPIRED_INSTANCE'
{"findings": [], "reason": null,
 "records": [{"instance_id": "CINST-000006",
              "advertisement_id": "CADV-000007",
              "lifecycle_state": "admitted",
              "admitted_at": "2026-09-15T06:15:00-05:00",
              "admitted_until": "2026-09-19T06:00:00-05:00"}]}
EXPIRED_INSTANCE

cat > "${WORK}/moved-route.json" <<'MOVED_ROUTE'
{"findings": [], "reason": null,
 "records": [{"route_id": "CROUTE-0006", "route_version": 6,
              "capability_id": "CAPDEF-0001", "contract_id": "CCON-0001",
              "data_classification": "internal", "locality": "local-only",
              "accepted_contract_versions": ["1.0.0"],
              "candidate_instances": ["CINST-000005"]}]}
MOVED_ROUTE

cat > "${WORK}/changed-selection.json" <<'CHANGED_SELECTION'
{"findings": [], "reason": null,
 "records": [{"selection_id": "CSEL-000004", "route_id": "CROUTE-0007",
              "route_version": 7, "selected_instance_id": "CINST-000006",
              "considered_candidates": ["CINST-000006"],
              "excluded_candidates": [], "local_node_identity": "HOST-0001"}]}
CHANGED_SELECTION

cat > "${WORK}/ineligible.json" <<'INELIGIBLE'
{"eligible": false,
 "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["host-trust"], "reasons": ["host trust record withdrawn"]}
INELIGIBLE

cat > "${WORK}/invalid-trust.json" <<'INVALID_TRUST'
{"valid": false, "problems": ["a lineage record is unreadable"],
 "store_root": "/var/lib/kyri/trust", "counts": {}}
INVALID_TRUST

cat > "${WORK}/refusing-preflight.json" <<'REFUSING_PREFLIGHT'
{"outcome": "preflight", "would_accept": false,
 "would_refuse_reason": "selection-not-supported",
 "predicted_invocation_record_id": "CINV-000003"}
REFUSING_PREFLIGHT

cat > "${WORK}/other-cinv-preflight.json" <<'OTHER_CINV'
{"outcome": "preflight", "would_accept": true, "would_refuse_reason": null,
 "predicted_invocation_record_id": "CINV-000004",
 "payload_digest": "sha256:591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3",
 "selection_id": "CSEL-000004", "instance_id": "CINST-000006",
 "capability_package_id": "CPKG-0001", "operation": "execute",
 "current_eligibility": true, "scope_permits_operation": true}
OTHER_CINV

python3 - "${PAYLOAD}" "${WORK}/relabelled.json" <<'RELABEL_PY'
import json
import sys
document = json.loads(open(sys.argv[1], encoding="utf-8").read())
document["arguments"]["label"] = "g11bcn-third-controlled-production-invoke-x"
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(document, indent=2) + "\n")
RELABEL_PY

python3 - "${PAYLOAD}" "${WORK}/reformatted.json" <<'REFORMAT_PY'
import json
import sys
document = json.loads(open(sys.argv[1], encoding="utf-8").read())
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(document, indent=4) + "\n")
REFORMAT_PY

# shellcheck disable=SC2016  # literal text to match in the block, not an expression
GATE_LINE='if ! python3 - "${GATE_ADVERT}" "${GATE_INSTANCE}" "${GATE_ROUTE}" "${GATE_SELECTION}" <<.GATE_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
ELIG_LINE='if ! python3 - "${ELIG_FILE}" <<.ELIG_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
TRUST_LINE='if ! python3 - "${GATE_DIR}'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
PRE_LINE='if ! python3 - "${PREFLIGHT_FILE}"'

# A sabotage runs BEFORE the invoke unless its name says otherwise, and for
# those the fixture sequence must not have moved.
#
# name | sed program | invoke must run? | expected refusal
SABOTAGE=(
"gate 0: the witness is absent|s#^WITNESS=.*#WITNESS=${WORK}/no-such-witness#|no|run BLOCK A first"
"gate 0: the witness names another image|s#^EXPECTED_IMAGE=.*#EXPECTED_IMAGE=0000000000000000000000000000000000000000000000000000000000000000#|no|does not record the expected execution image"
"gate 1: the advertisement has expired|/${GATE_LINE}/i cp ${WORK}/expired-advert.json \"\${GATE_ADVERT}\"|no|CADV-000007 is EXPIRED at the current clock"
"gate 1: the admission has expired|/${GATE_LINE}/i cp ${WORK}/expired-instance.json \"\${GATE_INSTANCE}\"|no|REFUSE: the admission of CINST-000006 closed at the current clock"
"gate 1: the route head has moved|/${GATE_LINE}/i cp ${WORK}/moved-route.json \"\${GATE_ROUTE}\"|no|REFUSE: CROUTE-0006 no longer routes to exactly CINST-000006"
"gate 1: the selection has changed|/${GATE_LINE}/i cp ${WORK}/changed-selection.json \"\${GATE_SELECTION}\"|no|REFUSE: CSEL-000004 does not resolve through CROUTE-0006"
"gate 1: inspect itself fails|s#^  python3 -m tools.fabric.cli inspect .*#  false \\\\#|no|REFUSE: could not inspect CADV-000007 in the live store"
"gate 2: current eligibility is false|/${ELIG_LINE}/i cp ${WORK}/ineligible.json \"\${ELIG_FILE}\"|no|REFUSE: CINST-000006 is not eligible at the current clock"
"gate 2: compute-eligibility itself fails|s#^python3 -m tools.fabric.cli compute-eligibility .*#false \\\\#|no|REFUSE: compute-eligibility failed against production"
"gate 3: the Fabric baseline has moved|s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#|no|REFUSE: the Fabric store has moved"
"gate 3: the runtime baseline has moved|s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#|no|REFUSE: the capability-runtime store has moved"
"gate 3: the invocation sequence has moved|s#^CINV_SEQ_BEFORE=.*#CINV_SEQ_BEFORE=9#|no|REFUSE: capability-invocation.seq is 2, expected 9"
"gate 3: the result sequence has moved|s#^CRES_SEQ_BEFORE=.*#CRES_SEQ_BEFORE=9#|no|REFUSE: capability-result.seq is 1, expected 9"
"gate 3: Trust does not validate|/${TRUST_LINE}/i cp ${WORK}/invalid-trust.json \"\${GATE_DIR}/trust.json\"|no|REFUSE: the Trust store does not validate"
"gate 3: trust validate-store itself fails|s#^python3 -m tools.trust.cli validate-store .*#false \\\\#|no|REFUSE: the Trust store could not be validated"
"gate 4: the work root mode changed|s#^  || { echo \"REFUSE: \${WORK_ROOT} is mode#  || { echo \"REFUSE: WORKROOTMODE \${WORK_ROOT} is mode#|no|ok  observation"
"gate 5: the preflight refuses|/${PRE_LINE}/i cp ${WORK}/refusing-preflight.json \"\${PREFLIGHT_FILE}\"|no|REFUSE: the preflight would not accept"
"gate 5: the preflight predicts another identity|/${PRE_LINE}/i cp ${WORK}/other-cinv-preflight.json \"\${PREFLIGHT_FILE}\"|no|REFUSE: the preflight predicts CINV-000004, not CINV-000003"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name program invoke_expected refusal <<<"${case}"
  # This row exists only to keep the table honest about a check that is a plain
  # `test`, not a gate program; it is exercised separately below.
  [[ "${name}" == "gate 4: the work root mode changed" ]] && continue

  build_fixture "${FIX}"
  fixture_fabric="$(aggregate "${FIX}/fabric")"
  render_block "${FIX}" "${rendered}"
  sed -i "${program}" "${rendered}"

  out="${WORK}/sabotage.out"
  status=0
  run_block "${rendered}" "${out}" || status=$?

  if (( status != 0 )); then
    pass "${name}: the block exits nonzero"
  else
    fail "${name}: the block exited 0"
  fi
  if grep -qF -- "${refusal}" "${out}"; then
    pass "${name}: refuses for its own reason (${refusal})"
  else
    fail "${name}: refused, but not for its own reason: $(grep -m1 'REFUSE' "${out}" || echo 'no REFUSE line')"
  fi
  if grep -q 'Traceback (most recent call last)' "${out}"; then
    fail "${name}: the gate crashed instead of judging its input"
  else
    pass "${name}: no traceback; the gate judged its input"
  fi

  if grep -qF 'ALL GATES PASSED' "${out}"; then
    if [[ "${invoke_expected}" == "yes" ]]; then
      pass "${name}: the gates passed, as this stage requires"
    else
      fail "${name}: THE GATES PASSED and the invoke was reached"
    fi
  else
    if [[ "${invoke_expected}" == "no" ]]; then
      pass "${name}: the invoke was never reached"
    else
      fail "${name}: the invoke was not reached when it should have been"
    fi
  fi

  # THE ASSERTION THAT MATTERS: no identity was spent.
  if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
    pass "${name}: capability-invocation.seq is still ${CINV_SEQ_BEFORE}; no identity was spent"
  else
    fail "${name}: AN INVOCATION IDENTITY WAS SPENT"
  fi
  if [[ ! -e "${FIX}/runtime/capability-invocations/${EXPECTED_CINV}.yaml" ]]; then
    pass "${name}: no invocation record was written"
  else
    fail "${name}: AN INVOCATION RECORD WAS WRITTEN"
  fi
  if [[ "$(cat "${FIX}/runtime/sequences/capability-result.seq")" == "${CRES_SEQ_BEFORE}" ]]; then
    pass "${name}: capability-result.seq is still ${CRES_SEQ_BEFORE}"
  else
    fail "${name}: A RESULT IDENTITY WAS SPENT"
  fi
  if [[ "$(aggregate "${FIX}/fabric")" == "${fixture_fabric}" ]]; then
    pass "${name}: the fixture Fabric store is byte-identical"
  else
    fail "${name}: the fixture Fabric store changed"
  fi
done

# ---- the work area and payload checks, exercised on their own --------------
#
# These are plain `test` guards rather than gate programs, so they are
# exercised by changing the fixture rather than the block.

printf '\n--- the Stage 0 work area guards ---\n'

# name | how the fixture work area is broken | expected refusal
# The canonical check cannot be reached by substituting the payload: the raw
# digest covers every byte, so it refuses first. That program is judged
# directly by tests/test-capability-cinv-000003-stage-0-rehearsal.sh, against
# the identical extracted check; what these cases prove is that the raw guard
# catches every substitution before the identity is spent.
WORKAREA_CASES=(
"the work root mode changed|chmod 0750 \"\${FIX}/workparent/g11bcn\"|required 700"
"the payload mode changed|chmod 0644 \"\${FIX}/workparent/g11bcn/third-invoke.json\"|required 600"
"the payload has a second hard link|ln \"\${FIX}/workparent/g11bcn/third-invoke.json\" \"\${FIX}/workparent/g11bcn/second-link.json\"|hard links, required 1"
"the payload raw digest changed|cp \"${WORK}/reformatted.json\" \"\${FIX}/workparent/g11bcn/third-invoke.json\"|the payload raw digest is"
"a relabelled payload, both digests moved|cp \"${WORK}/relabelled.json\" \"\${FIX}/workparent/g11bcn/third-invoke.json\"|the payload raw digest is"
"the payload is absent|rm -f \"\${FIX}/workparent/g11bcn/third-invoke.json\"|is absent or not a regular file"
"the work root is absent|rm -rf \"\${FIX}/workparent/g11bcn\"|Stage 0 has not been performed"
)

for case in "${WORKAREA_CASES[@]}"; do
  IFS='|' read -r name breakage refusal <<<"${case}"
  build_fixture "${FIX}"
  render_block "${FIX}" "${rendered}"
  eval "${breakage}"

  out="${WORK}/workarea.out"
  status=0
  run_block "${rendered}" "${out}" || status=$?

  if (( status != 0 )) && grep -qF -- "${refusal}" "${out}"; then
    pass "work area: ${name} is refused for its own reason"
  else
    fail "work area: ${name} was not refused: $(grep -m1 'REFUSE' "${out}" || echo 'no REFUSE line')"
  fi
  if grep -qF 'ALL GATES PASSED' "${out}"; then
    fail "work area: ${name} REACHED THE INVOKE"
  else
    pass "work area: ${name} never reached the invoke"
  fi
  if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
    pass "work area: ${name} spent no identity"
  else
    fail "work area: ${name} SPENT AN IDENTITY"
  fi
done

# ---- a stale observation ---------------------------------------------------
#
# The witness is made OLD rather than the bound made zero: an age of 0 is not
# greater than a bound of 0, so shrinking the bound proves nothing and the
# sabotage ran the whole ceremony.

printf '\n--- a stale observation is refused ---\n'
build_fixture "${FIX}"
render_block "${FIX}" "${rendered}"
touch -d '3 hours ago' "${FIX}/workparent/g11bcn-stage-1-witness"
status=0
run_block "${rendered}" "${WORK}/stale.out" || status=$?
if (( status != 0 )) && grep -qF 're-run BLOCK A' "${WORK}/stale.out"; then
  pass "an observation older than the bound is refused"
else
  fail "a stale observation was not refused: $(grep -m1 'REFUSE' "${WORK}/stale.out" || echo none)"
fi
if grep -qF 'ALL GATES PASSED' "${WORK}/stale.out"; then
  fail "a stale observation REACHED THE INVOKE"
else
  pass "a stale observation never reached the invoke"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "a stale observation spent no identity"
else
  fail "AN IDENTITY WAS SPENT"
fi

# A witness dated in the future is refused too, rather than treated as fresh.
build_fixture "${FIX}"
render_block "${FIX}" "${rendered}"
touch -d '1 hour' "${FIX}/workparent/g11bcn-stage-1-witness"
status=0
run_block "${rendered}" "${WORK}/future.out" || status=$?
if (( status != 0 )) && grep -qF 'dated in the future' "${WORK}/future.out"; then
  pass "an observation dated in the future is refused"
else
  fail "a future-dated observation was not refused"
fi

# ---- CINV-000003 already present -------------------------------------------
#
# The record is planted BEFORE the block is rendered, so the runtime baseline
# is derived from a store that already holds it. Otherwise the baseline gate
# refuses first -- correctly, but for a different reason -- and the absence
# check this case exists for is never reached.

printf '\n--- the identity has already been spent ---\n'
build_fixture "${FIX}"
cp "${FIX}/runtime/capability-invocations/CINV-000002.yaml" \
   "${FIX}/runtime/capability-invocations/${EXPECTED_CINV}.yaml"
render_block "${FIX}" "${rendered}"
status=0
run_block "${rendered}" "${WORK}/present.out" || status=$?
if (( status != 0 )) && grep -qF "${EXPECTED_CINV} already exists" "${WORK}/present.out"; then
  pass "an existing ${EXPECTED_CINV} is refused before the invoke"
else
  fail "an existing ${EXPECTED_CINV} was not refused"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "an existing ${EXPECTED_CINV} spent no further identity"
else
  fail "AN IDENTITY WAS SPENT"
fi

# ---- the verdict check, judged directly ------------------------------------
#
# The invoke's own verdict cannot be sabotaged by changing the block without
# also running the irreversible command, so the verdict program is extracted
# and run against crafted results. These are the cases where the released
# contract itself would have changed underneath the ceremony.

printf '\n--- the verdict check, judged directly ---\n'

VERDICT="${WORK}/verdict.py"
sed -n "/<<'VERDICT_PY'\$/,/^VERDICT_PY\$/p" "${ARTIFACT}" | sed '1d;$d' > "${VERDICT}"
if [[ -s "${VERDICT}" ]]; then
  pass "the verdict check was extracted"
else
  fail "the verdict check could not be extracted"
fi

EXPECTED_STAGED_PATH="${PRODUCTION_RUNTIME}/staging/tree-sha256-6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e"

run_verdict() {
  ( cd "${ROOT}" && python3 - "$1" "${EXPECTED_CINV}" "${EXPECTED_STATUS}" \
      "${EXPECTED_REASON}" "${EXPECTED_PAYLOAD_DIGEST}" "${EXPECTED_BINDING_DIGEST}" \
      "${EXPECTED_ARTIFACT_DIGEST}" "${EXPECTED_STAGED_PATH}" < "${VERDICT}" 2>&1 )
}
verdict_accepts() {
  ( cd "${ROOT}" && python3 - "$1" "${EXPECTED_CINV}" "${EXPECTED_STATUS}" \
      "${EXPECTED_REASON}" "${EXPECTED_PAYLOAD_DIGEST}" "${EXPECTED_BINDING_DIGEST}" \
      "${EXPECTED_ARTIFACT_DIGEST}" "${EXPECTED_STAGED_PATH}" < "${VERDICT}" >/dev/null 2>&1 )
}

python3 - "${WORK}" "${EXPECTED_CINV}" "${EXPECTED_STATUS}" "${EXPECTED_REASON}" \
          "${EXPECTED_PAYLOAD_DIGEST}" "${EXPECTED_BINDING_DIGEST}" \
          "${EXPECTED_ARTIFACT_DIGEST}" "${EXPECTED_STAGED_PATH}" <<'CRAFT_PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
(cinv, status, reason, payload, binding, artifact, staged) = sys.argv[2:9]

good = {"status": status, "reason": reason, "invocation_id": "g11bcn-third-controlled-invoke",
        "invocation_record_id": cinv, "result_record_id": None,
        "binding_digest": binding, "payload_digest": payload,
        "artifact_digest": artifact, "staged_path": staged}


def write(name, mutate):
    document = dict(good)
    mutate(document)
    (out / name).write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


(out / "v-good.json").write_text(json.dumps(good, indent=2) + "\n", encoding="utf-8")
write("v-status.json", lambda d: d.__setitem__("status", "refused"))
write("v-reason.json", lambda d: d.__setitem__("reason", "selection-not-supported"))
write("v-cinv.json", lambda d: d.__setitem__("invocation_record_id", "CINV-000004"))
write("v-invid.json", lambda d: d.__setitem__("invocation_id", "someone-elses-invoke"))
write("v-payload.json", lambda d: d.__setitem__("payload_digest", "sha256:" + "0" * 64))
write("v-binding.json", lambda d: d.__setitem__("binding_digest", "sha256:" + "1" * 64))
write("v-artifact.json", lambda d: d.__setitem__("artifact_digest", "sha256:" + "2" * 64))
write("v-staged.json", lambda d: d.__setitem__("staged_path", "/somewhere/else"))
write("v-cres.json", lambda d: d.__setitem__("result_record_id", "CRES-000002"))
write("v-consumed.json", lambda d: (d.__setitem__("status", "consumed"),
                                    d.__setitem__("reason", "consumed")))
(out / "v-notjson.json").write_text("not json\n", encoding="utf-8")
CRAFT_PY

if verdict_accepts "${WORK}/v-good.json"; then
  pass "the verdict check accepts the released Stage-1 success"
else
  fail "the verdict check refuses the released success; it is a brick"
fi

# name | crafted file | expected refusal
VERDICT_CASES=(
"a refused status|v-status.json|status is refused"
"a different reason|v-reason.json|reason is selection-not-supported"
"another allocated identity|v-cinv.json|the allocated invocation is CINV-000004"
"another invocation id|v-invid.json|the invocation id is someone-elses-invoke"
"a different payload digest|v-payload.json|the payload digest is"
"a different binding digest|v-binding.json|the binding digest is"
"a different artifact digest|v-artifact.json|the artifact digest is"
"a different staged path|v-staged.json|the staged path is"
"a result record was allocated|v-cres.json|a result record CRES-000002 was allocated"
"a consumed replay|v-consumed.json|status is consumed"
"a verdict that is not JSON|v-notjson.json|not readable JSON"
)

for case in "${VERDICT_CASES[@]}"; do
  IFS='|' read -r name file refusal <<<"${case}"
  got="$(run_verdict "${WORK}/${file}" || true)"
  if verdict_accepts "${WORK}/${file}"; then
    fail "the verdict check ACCEPTED: ${name}"
  elif printf '%s' "${got}" | grep -qF -- "${refusal}"; then
    pass "the verdict check refuses ${name} for its own reason"
  else
    fail "the verdict check refused ${name} but not for its own reason: ${got}"
  fi
  if printf '%s' "${got}" | grep -q 'Traceback'; then
    fail "the verdict check crashed on ${name}"
  else
    pass "the verdict check judged ${name} without crashing"
  fi
  # Every refusal after the invoke must say so.
  if printf '%s' "${got}" | grep -qF 'STOP AND REPORT'; then
    pass "the verdict check tells the operator to stop and report on ${name}"
  else
    fail "the verdict check does not say to stop and report on ${name}"
  fi
done

# ---- the exit-code check, judged on its own --------------------------------
#
# rc=0 and rc=2 must both be refused: the first would mean the released
# contract changed, the second is a usage error.

printf '\n--- the exit-code check ---\n'
for bad_rc in 0 2 137; do
  build_fixture "${FIX}"
  render_block "${FIX}" "${rendered}"
  # Replace the real invoke with something that emits the correct verdict but
  # the wrong status, so only the rc check can catch it.
  sed -i "s#^INVOKE_RC=\\\$?\$#INVOKE_RC=${bad_rc}#" "${rendered}"
  status=0
  run_block "${rendered}" "${WORK}/rc-${bad_rc}.out" || status=$?
  if (( status != 0 )) && grep -qF "the process exited ${bad_rc}" "${WORK}/rc-${bad_rc}.out"; then
    pass "a process exit of ${bad_rc} is refused"
  else
    fail "a process exit of ${bad_rc} was not refused"
  fi
  if grep -qF 'STOP AND REPORT, do not re-run' "${WORK}/rc-${bad_rc}.out"; then
    pass "the rc refusal for ${bad_rc} tells the operator not to re-run"
  else
    fail "the rc refusal for ${bad_rc} does not warn against re-running"
  fi
done

# ---- deterministic refusal -------------------------------------------------

printf '\n--- deterministic refusal ---\n'
deterministic=1
for attempt in 1 2 3; do
  build_fixture "${FIX}"
  render_block "${FIX}" "${rendered}"
  sed -i "/${GATE_LINE}/i cp ${WORK}/expired-advert.json \"\${GATE_ADVERT}\"" "${rendered}"
  status=0
  run_block "${rendered}" "${WORK}/repeat-${attempt}.out" || status=$?
  if (( status == 0 )) \
     || grep -qF 'ALL GATES PASSED' "${WORK}/repeat-${attempt}.out" \
     || [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" != "${CINV_SEQ_BEFORE}" ]]; then
    deterministic=0
  fi
done
if (( deterministic == 1 )); then
  pass "an expired advertisement stops the block before the invoke, 3 of 3 runs"
else
  fail "the gate-1 refusal was not deterministic"
fi

# ---- production, after everything -----------------------------------------

printf '\n--- production untouched ---\n'

if [[ "$(aggregate "${PRODUCTION_FABRIC}")" == "${PRODUCTION_FABRIC_BEFORE}" ]]; then
  pass "production Fabric is byte-identical after the rehearsal"
else
  fail "PRODUCTION FABRIC CHANGED"
fi
if [[ "$(aggregate "${PRODUCTION_RUNTIME}")" == "${PRODUCTION_RUNTIME_BEFORE}" ]]; then
  pass "the production capability-runtime store is byte-identical after the rehearsal"
else
  fail "THE PRODUCTION RUNTIME STORE CHANGED"
fi
if [[ ! -e "${PRODUCTION_RUNTIME}/capability-invocations/${EXPECTED_CINV}.yaml" ]]; then
  pass "${EXPECTED_CINV} is still absent from production"
else
  fail "${EXPECTED_CINV} WAS ALLOCATED IN PRODUCTION"
fi
if [[ "$(cat "${PRODUCTION_RUNTIME}/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "the production capability-invocation.seq is still ${CINV_SEQ_BEFORE}"
else
  fail "THE PRODUCTION INVOCATION SEQUENCE MOVED"
fi
if [[ "$(cat "${PRODUCTION_RUNTIME}/sequences/capability-result.seq")" == "${CRES_SEQ_BEFORE}" ]]; then
  pass "the production capability-result.seq is still ${CRES_SEQ_BEFORE}"
else
  fail "THE PRODUCTION RESULT SEQUENCE MOVED"
fi
if [[ ! -e "${PRODUCTION_WITNESS}" ]]; then
  pass "no production observation witness was created"
else
  fail "A PRODUCTION WITNESS WAS CREATED"
fi
# The Stage 0 work area must be exactly as the reviewer accepted it.
if [[ "$(sha256sum "${prod_payload}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]] \
   && [[ "$(stat -c '%a' "${prod_payload}")" == "600" ]] \
   && [[ "$(stat -c '%h' "${prod_payload}")" == "1" ]]; then
  pass "the Stage 0 payload is untouched by the rehearsal"
else
  fail "THE STAGE 0 PAYLOAD WAS MODIFIED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage 1 rehearsal passed.\n'
else
  printf 'CINV-000003 Stage 1 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
