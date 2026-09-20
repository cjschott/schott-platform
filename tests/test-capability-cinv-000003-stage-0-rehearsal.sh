#!/usr/bin/env bash
set -Eeuo pipefail

# The CINV-000003 Stage 0 ceremony, rehearsed whole.
#
# HOST-ONLY. It runs the ENTIRE operator block -- every command the operator
# will paste, in order, with the real released CLI -- and that needs the
# governed stores. See tests/host-only.manifest.
#
# WHY THIS EXISTS
# ===============
# G11-BC-O's CINST artifact was asserted, extracted, digested and reasoned
# about, and never once run end to end. The operator was the first to execute
# it, in production, and both of its gates were broken. G11-BC-P is the report.
# Gates are executed, not read.
#
# WHAT STAGE 0 IS
# ===============
# Stage 0 creates ONLY the reviewed operator work area. It allocates no
# invocation identifier, writes no governed record and moves no sequence. Stage
# 1 -- `capability invoke` -- is the first irreversible step, and this suite
# proves Stage 0 does not reach it: after the happy path the fixture runtime
# store is byte-identical, capability-invocation.seq is still 2, and no
# CINV-000003 exists anywhere.
#
# Three substitutions and nothing else:
#
#   /var/lib/kyri/fabric            -> a byte copy inside the fixture
#   /data/kyri/capability-runtime   -> a byte copy inside the fixture
#   /data/kyri/work/g11bcn          -> a work root inside the fixture
#
# and the two baselines those force, because the aggregate is a digest of
# `sha256sum` output which names absolute paths and is root-dependent by
# construction. Trust, Evidence and the artifact store stay pointed at the real
# stores: the block only ever reads them.
#
# Production is never written. The suite proves that by aggregate, not by
# intention, after every run including the sabotaged ones.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires \
  /var/lib/kyri/fabric /var/lib/kyri/trust /var/lib/kyri/evidence \
  /data/kyri/capability-runtime

ARTIFACT="${ROOT}/provisioning/execution/g11-bc-n-cinv-000003-stage-0-ceremony.txt"
PAYLOAD="${ROOT}/provisioning/execution/g11-bc-n-cinv-000003-payload.json"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_RUNTIME=/data/kyri/capability-runtime
PRODUCTION_WORK=/data/kyri/work/g11bcn

REVIEWED_RAW=d01faccc67b83c60051348422861c121211a4079f7748572bad0a4882575a569
REVIEWED_RAW_BYTES=300
REVIEWED_CANONICAL=591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
REVIEWED_CANONICAL_BYTES=271
FABRIC_BASELINE=a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5
CINV_SEQ_BEFORE=2
CRES_SEQ_BEFORE=1

# THE CEREMONY IS SPENT ONCE THE WORK AREA EXISTS.
#
# This suite rehearses a ceremony whose first refusal is "the work area must
# not already exist". Once the operator has performed Stage 0 and the reviewer
# has accepted it, that precondition can never hold again.
#
# Deleting the suite would delete the evidence; leaving it asserting a vanished
# world would make it fail forever for the one reason that is not a defect. So
# it branches on the fact, as the Fabric freeze rehearsals do.
#
# DURABLE FACTS ONLY. Stage 0's output is a work area, and what stays true
# about it is its security properties and the bytes it holds -- not any
# whole-store aggregate. The runtime aggregate is deliberately NOT pinned here:
# Stage 1 legitimately moves it, and pinning it is the defect that broke the
# CINST-000006 spent mode when CROUTE-0006 landed. What IS asserted is the
# thing Stage 0 is responsible for: that it allocated nothing, which is proved
# by the invocation sequence never having gone below the 2 it left behind.
STAGE0_CINV_SEQ=2
STAGE0_CRES_SEQ=1

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
  pass "production Fabric is at the pinned post-CSEL baseline before the rehearsal"
else
  fail "production Fabric is ${PRODUCTION_FABRIC_BEFORE}, not the pinned ${FABRIC_BASELINE}"
fi
# ---- has the ceremony been performed? -------------------------------------

if [[ -e "${PRODUCTION_WORK}" ]]; then
  printf '\n--- the Stage 0 ceremony is spent ---\n'
  pass "the work area exists; Stage 0 cannot be rehearsed again"

  if [[ "$(stat -c '%u' "${PRODUCTION_WORK}")" == "1000" ]]; then
    pass "the work root is owned by uid 1000"
  else
    fail "the work root is owned by uid $(stat -c '%u' "${PRODUCTION_WORK}")"
  fi
  if [[ "$(stat -c '%a' "${PRODUCTION_WORK}")" == "700" ]]; then
    pass "the work root is mode 0700"
  else
    fail "the work root is mode $(stat -c '%a' "${PRODUCTION_WORK}")"
  fi

  spent_payload="${PRODUCTION_WORK}/third-invoke.json"
  if [[ -f "${spent_payload}" ]]; then
    pass "the reviewed payload is in the work area"
  else
    fail "the reviewed payload is absent from the work area"
    exit 1
  fi
  for check in "uid:%u:1000" "mode:%a:600" "links:%h:1" "bytes:%s:${REVIEWED_RAW_BYTES}"; do
    label="${check%%:*}"; rest="${check#*:}"
    fmt="${rest%%:*}"; want="${rest##*:}"
    got="$(stat -c "${fmt}" "${spent_payload}")"
    if [[ "${got}" == "${want}" ]]; then
      pass "the payload ${label} is ${want}"
    else
      fail "the payload ${label} is ${got}, expected ${want}"
    fi
  done
  if [[ "$(sha256sum "${spent_payload}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]]; then
    pass "the payload raw sha256 is ${REVIEWED_RAW}"
  else
    fail "the payload raw sha256 has drifted"
  fi
  if cmp -s "${spent_payload}" "${PAYLOAD}"; then
    pass "the payload is byte-identical to the committed payload"
  else
    fail "the payload differs from the committed payload"
  fi

  # The canonical digest, through the released canonicalizer -- the value Stage
  # 1 will record as payload_digest.
  if spent_canon="$(cd "${ROOT}" && python3 - "${spent_payload}" <<'SPENT_CANON_PY'
import hashlib
import json
import pathlib
import sys

from tools.capability.invocation_identity import canonical_bytes

blob = canonical_bytes(json.loads(pathlib.Path(sys.argv[1]).read_bytes()))
print(hashlib.sha256(blob).hexdigest())
print(len(blob))
SPENT_CANON_PY
  )"; then
    if [[ "$(printf '%s' "${spent_canon}" | sed -n 1p)" == "${REVIEWED_CANONICAL}" ]] \
       && [[ "$(printf '%s' "${spent_canon}" | sed -n 2p)" == "${REVIEWED_CANONICAL_BYTES}" ]]; then
      pass "the canonical digest is still ${REVIEWED_CANONICAL} (${REVIEWED_CANONICAL_BYTES} bytes)"
    else
      fail "the canonical digest has drifted: ${spent_canon}"
    fi
  else
    fail "the released canonicalizer could not be run over the spent payload"
  fi

  # STAGE 0 ALLOCATED NOTHING, and that stays provable after Stage 1 lands:
  # sequences are monotonic, so one that never fell below what Stage 0 left is
  # one Stage 0 never advanced. The whole-store aggregate is deliberately not
  # pinned -- Stage 1 moves it by design.
  seq_now="$(cat "${PRODUCTION_RUNTIME}/sequences/capability-invocation.seq")"
  if [[ "${seq_now}" =~ ^[0-9]+$ ]] && (( seq_now >= STAGE0_CINV_SEQ )); then
    pass "capability-invocation.seq is ${seq_now}, at or past the ${STAGE0_CINV_SEQ} Stage 0 left"
  else
    fail "capability-invocation.seq is ${seq_now}, below the ${STAGE0_CINV_SEQ} Stage 0 left"
  fi
  res_now="$(cat "${PRODUCTION_RUNTIME}/sequences/capability-result.seq")"
  if [[ "${res_now}" =~ ^[0-9]+$ ]] && (( res_now >= STAGE0_CRES_SEQ )); then
    pass "capability-result.seq is ${res_now}, at or past the ${STAGE0_CRES_SEQ} Stage 0 left"
  else
    fail "capability-result.seq is ${res_now}, below the ${STAGE0_CRES_SEQ} Stage 0 left"
  fi

  # The committed ceremony still describes what was done.
  if grep -qF -- "${REVIEWED_RAW}" "${ARTIFACT}" \
     && grep -qF -- "${REVIEWED_CANONICAL}" "${ARTIFACT}"; then
    pass "the committed Stage 0 ceremony still pins both reviewed digests"
  else
    fail "the committed Stage 0 ceremony no longer pins the reviewed digests"
  fi

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'CINV-000003 Stage 0 rehearsal: ceremony spent, accepted work area verified.\n'
    exit 0
  fi
  printf 'CINV-000003 Stage 0 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi

# The chain this ceremony rests on must be written, or the rehearsal is
# measuring a world the operator will not be in.
for required in "${PRODUCTION_FABRIC}/capability-selections/CSEL-000004.yaml" \
                "${PRODUCTION_FABRIC}/capability-routes/CROUTE-0006.yaml" \
                "${PRODUCTION_FABRIC}/capability-instances/CINST-000006.yaml"; do
  if [[ -e "${required}" ]]; then
    pass "$(basename "${required}" .yaml) is written in production, as this ceremony requires"
  else
    fail "$(basename "${required}" .yaml) is absent from production"
    exit 1
  fi
done
if [[ ! -e "${PRODUCTION_RUNTIME}/capability-invocations/CINV-000003.yaml" ]]; then
  pass "CINV-000003 is absent from production, as Stage 0 requires"
else
  fail "CINV-000003 already exists; Stage 1 has already run"
  exit 1
fi

# ---- the payload the block will copy ---------------------------------------

if [[ "$(sha256sum "${PAYLOAD}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]]; then
  pass "the committed payload is the reviewed payload (${REVIEWED_RAW})"
else
  fail "the committed payload is not the reviewed payload"
fi
if [[ "$(wc -c < "${PAYLOAD}")" == "${REVIEWED_RAW_BYTES}" ]]; then
  pass "the committed payload is ${REVIEWED_RAW_BYTES} raw bytes"
else
  fail "the committed payload is $(wc -c < "${PAYLOAD}") bytes"
fi
if canon="$(cd "${ROOT}" && python3 - "${PAYLOAD}" <<'CANON_PY'
import hashlib
import json
import pathlib
import sys

from tools.capability.invocation_identity import canonical_bytes

document = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
blob = canonical_bytes(document)
print(hashlib.sha256(blob).hexdigest())
print(len(blob))
CANON_PY
)"; then
  if [[ "$(printf '%s' "${canon}" | sed -n 1p)" == "${REVIEWED_CANONICAL}" ]]; then
    pass "the released canonicalizer reproduces the reviewed payload digest"
  else
    fail "canonical digest is $(printf '%s' "${canon}" | sed -n 1p), reviewed ${REVIEWED_CANONICAL}"
  fi
  if [[ "$(printf '%s' "${canon}" | sed -n 2p)" == "${REVIEWED_CANONICAL_BYTES}" ]]; then
    pass "the canonical form is ${REVIEWED_CANONICAL_BYTES} bytes"
  else
    fail "canonical bytes $(printf '%s' "${canon}" | sed -n 2p), reviewed ${REVIEWED_CANONICAL_BYTES}"
  fi
else
  fail "the released canonicalizer could not be run over the payload"
fi

# ---- the block, extracted -------------------------------------------------

BLOCK="${WORK}/block.sh"
awk "/^bash <<'STAGE0'\$/{on=1;next} /^STAGE0\$/{on=0} on" "${ARTIFACT}" > "${BLOCK}"
if [[ -s "${BLOCK}" ]]; then
  pass "the operator block was extracted whole ($(wc -l < "${BLOCK}") lines)"
else
  fail "the operator block could not be extracted"
  exit 1
fi

# The read-only observation commands are deliberately OUTSIDE the block, so the
# extracted block must contain no sudo at all.
if grep -q 'sudo' "${BLOCK}"; then
  fail "the extracted block contains sudo; Stage 0 needs no privilege"
else
  pass "the extracted block needs no privilege"
fi

# ---- the fixture ----------------------------------------------------------

build_fixture() {
  local fixture="$1"
  # The staged package tree is copied with its real modes, and those are
  # deliberately read-only -- a staged tree is not meant to be writable. `rm -rf`
  # cannot remove a file from a directory it may not write, so the tree is made
  # writable before the fixture is torn down. This touches only the fixture.
  if [[ -e "${fixture}" ]]; then
    chmod -R u+w "${fixture}" 2>/dev/null || true
    rm -rf "${fixture}"
  fi
  mkdir -p "${fixture}"
  cp -a "${PRODUCTION_FABRIC}" "${fixture}/fabric"
  cp -a "${PRODUCTION_RUNTIME}" "${fixture}/runtime"
  mkdir -p "${fixture}/workparent"
}

render_block() {
  local fixture="$1" out="$2"
  local fabric_baseline runtime_baseline
  fabric_baseline="$(aggregate "${fixture}/fabric")"
  runtime_baseline="$(aggregate "${fixture}/runtime")"
  sed \
    -e "s#${PRODUCTION_WORK}#${fixture}/workparent/g11bcn#g" \
    -e "s#${PRODUCTION_FABRIC}#${fixture}/fabric#g" \
    -e "s#${PRODUCTION_RUNTIME}#${fixture}/runtime#g" \
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

if grep -q -e "${PRODUCTION_FABRIC}" -e "${PRODUCTION_RUNTIME}" -e "${PRODUCTION_WORK}" "${rendered}"; then
  fail "the rendered block still references a production path"
else
  pass "the rendered block references no production Fabric, runtime or work path"
fi

# The fixture's OWN before-state. The aggregate digests `sha256sum` output,
# which names absolute paths, so a fixture store can never equal production's
# and comparing them would fail for the wrong reason.
HAPPY_FABRIC_BEFORE="$(aggregate "${FIX}/fabric")"
HAPPY_RUNTIME_BEFORE="$(aggregate "${FIX}/runtime")"

out="${WORK}/run.out"
status=0
run_block "${rendered}" "${out}" || status=$?

if (( status == 0 )); then
  pass "the whole block runs to completion against the fixture"
else
  fail "the whole block failed (status ${status}): $(tail -3 "${out}" | tr '\n' ' ')"
fi

for expected in \
  'ok  observed_at <= now < valid_until' \
  'ok  now < admitted_until <= valid_until' \
  'ok  CROUTE-0006 routes to exactly CINST-000006' \
  'ok  CSEL-000004 selects CINST-000006 through CROUTE-0006' \
  'ok  eligible true, no unmet conditions' \
  'ok  CINST-000006 eligible at the current clock' \
  'ok  CINV-000003 absent' \
  'ok  trust valid, no problems' \
  'ok  operation verify-execution-boundary, count 1, reviewed label' \
  'ok  the note binds CADV-000007 / CINST-000006 / CROUTE-0006 / CSEL-000004' \
  'ok  uid 1000, root 0700, file 0600, one link' \
  'ok  no invocation identifier was allocated'
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
  fail "the block did not report 12 of 12: $(grep -F 'eligible' "${out}" | head -1)"
fi
if grep -qF "raw        ${REVIEWED_RAW}" "${out}"; then
  pass "the block reports the reviewed raw digest"
else
  fail "the block did not report the reviewed raw digest"
fi
if grep -qF "canonical  ${REVIEWED_CANONICAL}" "${out}"; then
  pass "the block reports the reviewed canonical digest"
else
  fail "the block did not report the reviewed canonical digest"
fi

# ---- what Stage 0 created, and only that -----------------------------------

created="${FIX}/workparent/g11bcn"
placed="${created}/third-invoke.json"
if [[ -d "${created}" ]]; then
  pass "the work area was created"
  if [[ "$(stat -c '%a' "${created}")" == "700" ]]; then
    pass "the work area is mode 0700"
  else
    fail "the work area is mode $(stat -c '%a' "${created}")"
  fi
else
  fail "the work area was not created"
fi
if [[ -f "${placed}" ]]; then
  pass "the payload was placed in the work area"
  if [[ "$(sha256sum "${placed}" | cut -d' ' -f1)" == "${REVIEWED_RAW}" ]]; then
    pass "the placed payload is the reviewed payload, byte for byte"
  else
    fail "the placed payload is not the reviewed payload"
  fi
  if cmp -s "${placed}" "${PAYLOAD}"; then
    pass "the placed payload is the committed file, copied not retyped"
  else
    fail "the placed payload differs from the committed file"
  fi
  if [[ "$(stat -c '%a' "${placed}")" == "600" ]]; then
    pass "the placed payload is mode 0600"
  else
    fail "the placed payload is mode $(stat -c '%a' "${placed}")"
  fi
  if [[ "$(stat -c '%h' "${placed}")" == "1" ]]; then
    pass "the placed payload has exactly one hard link"
  else
    fail "the placed payload has $(stat -c '%h' "${placed}") links"
  fi
  if [[ "$(stat -c '%u' "${placed}")" == "1000" ]]; then
    pass "the placed payload is owned by uid 1000"
  else
    fail "the placed payload is owned by uid $(stat -c '%u' "${placed}")"
  fi
else
  fail "the payload was not placed"
fi

# STAGE 0 REACHES NO STAGE-1 EFFECT. This is the assertion that matters most.
if [[ "$(aggregate "${FIX}/runtime")" == "${HAPPY_RUNTIME_BEFORE}" ]]; then
  pass "the fixture runtime store is byte-identical to before the run; nothing was allocated"
else
  fail "THE FIXTURE RUNTIME STORE CHANGED during Stage 0"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "capability-invocation.seq is still ${CINV_SEQ_BEFORE}"
else
  fail "capability-invocation.seq moved to $(cat "${FIX}/runtime/sequences/capability-invocation.seq")"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-result.seq")" == "${CRES_SEQ_BEFORE}" ]]; then
  pass "capability-result.seq is still ${CRES_SEQ_BEFORE}"
else
  fail "capability-result.seq moved"
fi
if [[ ! -e "${FIX}/runtime/capability-invocations/CINV-000003.yaml" ]]; then
  pass "no CINV-000003 record was created, even in the fixture"
else
  fail "STAGE 0 CREATED AN INVOCATION RECORD"
fi
if [[ ! -e "${FIX}/runtime/capability-results/CRES-000002.yaml" ]]; then
  pass "no result record was created"
else
  fail "STAGE 0 CREATED A RESULT RECORD"
fi
if [[ "$(aggregate "${FIX}/fabric")" == "${HAPPY_FABRIC_BEFORE}" ]]; then
  pass "the fixture Fabric store is byte-identical; Stage 0 mutated no governed record"
else
  fail "THE FIXTURE FABRIC STORE CHANGED during Stage 0"
fi

# ---- the released Stage-1 preflight, against the prepared work area --------
#
# Stage 0 does not run it, but the work area it produces is exactly what Stage 1
# will be handed, so the prediction is made here where it is still free.

printf '\n--- the released preflight over the prepared work area ---\n'

if preflight="$(cd "${ROOT}" && python3 -m tools.capability.cli invoke \
    --store-root "${FIX}/runtime" \
    --expected-uid 1000 --expected-gid 1000 \
    --fabric-root "${PRODUCTION_FABRIC}" \
    --fabric-expected-uid 1000 --fabric-expected-gid 1000 \
    --approved-artifact-root /var/lib/kyri/artifacts \
    --trusted-source-uid 0 \
    --staging-root "${FIX}/runtime/staging" \
    --coordinator-uid 1000 \
    --approved-payload-root "${created}" \
    --payload-source-uid 1000 \
    --payload-file third-invoke.json \
    --invocation-id g11bcn-third-controlled-invoke \
    --selection-id CSEL-000004 \
    --instance-id CINST-000006 \
    --package-id CPKG-0001 \
    --operation execute \
    --trust-store-root /var/lib/kyri/trust \
    --actor primary-platform-operator \
    --request-id g11bcn-third-production-invoke \
    --requested-at "$(date -Is)" --preflight 2>&1)"; then
  pass "the released preflight accepts the work area Stage 0 prepared"
else
  fail "the released preflight refused the prepared work area: $(printf '%s' "${preflight}" | tail -2)"
fi

for pinned in '"predicted_invocation_record_id": "CINV-000003"' \
              "\"payload_digest\": \"sha256:${REVIEWED_CANONICAL}\"" \
              '"selection_id": "CSEL-000004"' \
              '"instance_id": "CINST-000006"' \
              '"current_eligibility": true' \
              '"scope_permits_operation": true' \
              '"would_accept": true' \
              '"outcome": "preflight"'; do
  if printf '%s' "${preflight}" | grep -qF -- "${pinned}"; then
    pass "the preflight reports ${pinned}"
  else
    fail "the preflight does not report ${pinned}"
  fi
done

# The preflight itself must have allocated nothing.
if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "the preflight allocated nothing; capability-invocation.seq is still ${CINV_SEQ_BEFORE}"
else
  fail "THE PREFLIGHT ALLOCATED AN IDENTIFIER"
fi

# ---- fail closed, by stage ------------------------------------------------
#
# Each sabotage changes exactly one thing and asserts where control stopped, AND
# that the refusal is that stage's own judgement. G11-BC-O's suite asserted that
# a gate refused and could not tell a refusal from a crash, so a gate that died
# on its own input scored as a gate that judged it and said no.
#
# The inspect calls are sabotaged by overwriting the file each one writes,
# inserted immediately before the gate program runs: a blanket substitution on
# the inspect command line would hit all four at once and the gate would then
# refuse for the wrong reason. Each sed program stays on ONE line, because the
# table is pipe-delimited and read by `read`, which stops at the first newline.

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

cat > "${WORK}/other-instance-selection.json" <<'OTHER_SELECTION'
{"findings": [], "reason": null,
 "records": [{"selection_id": "CSEL-000004", "route_id": "CROUTE-0006",
              "route_version": 6, "selected_instance_id": "CINST-000005",
              "considered_candidates": ["CINST-000005"],
              "excluded_candidates": [], "local_node_identity": "HOST-0001"}]}
OTHER_SELECTION

cat > "${WORK}/ineligible.json" <<'INELIGIBLE'
{"eligible": false,
 "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["host-trust"], "reasons": ["host trust record withdrawn"]}
INELIGIBLE

cat > "${WORK}/invalid-trust.json" <<'INVALID_TRUST'
{"valid": false, "problems": ["a lineage record is unreadable"],
 "store_root": "/var/lib/kyri/trust", "counts": {}}
INVALID_TRUST

# A payload whose raw bytes differ but whose canonical form does not: the same
# document, reformatted. It must be refused by the RAW check, which is the one
# the operator can see.
python3 - "${PAYLOAD}" "${WORK}/reformatted.json" <<'REFORMAT_PY'
import json
import sys
document = json.loads(open(sys.argv[1], encoding="utf-8").read())
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(document, indent=4) + "\n")
REFORMAT_PY

# A payload whose canonical form differs: a changed label. Both digests move.
python3 - "${PAYLOAD}" "${WORK}/relabelled.json" <<'RELABEL_PY'
import json
import sys
document = json.loads(open(sys.argv[1], encoding="utf-8").read())
document["arguments"]["label"] = "g11bcn-third-controlled-production-invoke-x"
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps(document, indent=2) + "\n")
RELABEL_PY

# shellcheck disable=SC2016  # literal text to match in the block, not an expression
GATE_LINE='if ! python3 - "${GATE_ADVERT}" "${GATE_INSTANCE}" "${GATE_ROUTE}" "${GATE_SELECTION}" <<.GATE_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
ELIG_LINE='if ! python3 - "${ELIG_FILE}" <<.ELIG_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
TRUST_LINE='if ! python3 - "${GATE_DIR}'

# name | sed program | gate 2 runs? | gate 3 runs? | gate 4 runs? | work area created? | expected refusal
SABOTAGE=(
"gate 1: the advertisement has expired|/${GATE_LINE}/i cp ${WORK}/expired-advert.json \"\${GATE_ADVERT}\"|no|no|no|no|CADV-000007 is EXPIRED at the current clock"
"gate 1: the admission has expired|/${GATE_LINE}/i cp ${WORK}/expired-instance.json \"\${GATE_INSTANCE}\"|no|no|no|no|REFUSE: the admission of CINST-000006 closed at the current clock"
"gate 1: the route head has moved|/${GATE_LINE}/i cp ${WORK}/moved-route.json \"\${GATE_ROUTE}\"|no|no|no|no|REFUSE: CROUTE-0006 no longer routes to exactly CINST-000006"
"gate 1: the selection now names another route|/${GATE_LINE}/i cp ${WORK}/changed-selection.json \"\${GATE_SELECTION}\"|no|no|no|no|REFUSE: CSEL-000004 does not resolve through CROUTE-0006"
"gate 1: the selection now names another instance|/${GATE_LINE}/i cp ${WORK}/other-instance-selection.json \"\${GATE_SELECTION}\"|no|no|no|no|REFUSE: CSEL-000004 does not select CINST-000006"
"gate 1: the advertisement is not in the store|s#^inspect_into capability-advertisement CADV-000007 #inspect_into capability-advertisement CADV-999999 #|no|no|no|no|REFUSE: could not inspect CADV-999999 in the live store"
"gate 1: inspect itself fails|s#^  python3 -m tools.fabric.cli inspect .*#  false \\\\#|no|no|no|no|REFUSE: could not inspect CADV-000007 in the live store"
"gate 2: CINST-000006 is not currently eligible|/${ELIG_LINE}/i cp ${WORK}/ineligible.json \"\${ELIG_FILE}\"|yes|no|no|no|REFUSE: CINST-000006 is not eligible at the current clock"
"gate 2: compute-eligibility itself fails|s#^python3 -m tools.fabric.cli compute-eligibility .*#false \\\\#|yes|no|no|no|REFUSE: compute-eligibility failed against production"
"gate 3: the Fabric baseline has moved|s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#|yes|yes|no|no|REFUSE: the Fabric store has moved"
"gate 3: the runtime store has moved|s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#|yes|yes|no|no|REFUSE: the capability-runtime store has moved"
"gate 3: the invocation sequence has moved|s#^CINV_SEQ_BEFORE=.*#CINV_SEQ_BEFORE=9#|yes|yes|no|no|REFUSE: capability-invocation.seq is 2, expected 9"
"gate 3: the result sequence has moved|s#^CRES_SEQ_BEFORE=.*#CRES_SEQ_BEFORE=9#|yes|yes|no|no|REFUSE: capability-result.seq is 1, expected 9"
"gate 3: Trust does not validate|/${TRUST_LINE}/i cp ${WORK}/invalid-trust.json \"\${GATE_DIR}/trust.json\"|yes|yes|no|no|REFUSE: the Trust store does not validate"
"gate 3: trust validate-store itself fails|s#^python3 -m tools.trust.cli validate-store .*#false \\\\#|yes|yes|no|no|REFUSE: the Trust store could not be validated"
"gate 4: the payload raw bytes changed|s#^SOURCE=.*#SOURCE=${WORK}/reformatted.json#|yes|yes|yes|no|REFUSE: raw digest"
"gate 4: a relabelled payload (both digests move)|s#^SOURCE=.*#SOURCE=${WORK}/relabelled.json#|yes|yes|yes|no|REFUSE: raw digest"
"gate 4: the payload is missing|s#^SOURCE=.*#SOURCE=${WORK}/does-not-exist.json#|yes|yes|yes|no|the reviewed CINV-000003 payload is not recoverable"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name program gate2_expected gate3_expected gate4_expected created_expected refusal <<<"${case}"

  build_fixture "${FIX}"
  fixture_fabric="$(aggregate "${FIX}/fabric")"
  fixture_runtime="$(aggregate "${FIX}/runtime")"
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

  for stage in "gate 2:--- current eligibility gate ---:${gate2_expected}" \
               "gate 3:--- governed chain baseline gate ---:${gate3_expected}" \
               "gate 4:--- payload gate ---:${gate4_expected}"; do
    label="${stage%%:*}"; rest="${stage#*:}"
    banner="${rest%:*}"; want="${rest##*:}"
    if grep -qF -- "${banner}" "${out}"; then
      if [[ "${want}" == "yes" ]]; then
        pass "${name}: ${label} ran, as this stage requires"
      else
        fail "${name}: ${label} RAN after an earlier stage failed"
      fi
    else
      if [[ "${want}" == "no" ]]; then
        pass "${name}: ${label} never ran"
      else
        fail "${name}: ${label} did not run when it should have"
      fi
    fi
  done

  if [[ -e "${FIX}/workparent/g11bcn" ]]; then
    if [[ "${created_expected}" == "yes" ]]; then
      pass "${name}: the work area was created"
    else
      fail "${name}: THE WORK AREA WAS CREATED after a gate refused"
    fi
  else
    pass "${name}: no work area was created"
  fi

  if [[ "$(aggregate "${FIX}/fabric")" == "${fixture_fabric}" ]]; then
    pass "${name}: the fixture Fabric store is byte-identical"
  else
    fail "${name}: the fixture Fabric store changed"
  fi
  if [[ "$(aggregate "${FIX}/runtime")" == "${fixture_runtime}" ]]; then
    pass "${name}: the fixture runtime store is byte-identical"
  else
    fail "${name}: the fixture runtime store changed"
  fi
  if [[ ! -e "${FIX}/runtime/capability-invocations/CINV-000003.yaml" ]]; then
    pass "${name}: no invocation record was created"
  else
    fail "${name}: AN INVOCATION RECORD WAS CREATED"
  fi
done

# ---- gate 4's canonical check, judged directly -------------------------------
#
# The raw check fires first and catches every payload substitution, so no
# sabotage of SOURCE can reach the canonical program -- a sabotage that never
# touches what it is aimed at proves nothing about it. G11-BC-R found exactly
# this shape in its own first draft. So the canonical check is extracted and
# run against crafted documents, where its own judgements are reachable.

printf '\n--- gate 4 canonical check, judged directly ---\n'

CANON_CHECK="${WORK}/canon.py"
sed -n "/<<'CANON_PY'\$/,/^CANON_PY\$/p" "${ARTIFACT}" | sed '1d;$d' > "${CANON_CHECK}"
if [[ -s "${CANON_CHECK}" ]]; then
  pass "gate 4's canonical check was extracted"
else
  fail "gate 4's canonical check could not be extracted"
fi

# Run the way the block runs it: the PROGRAM on stdin, the data as argv, from
# the repository root. Executing the extracted file by path would put /tmp on
# sys.path instead of the repository and the released canonicalizer would not
# import -- a failure of the harness that would read as a failure of the gate.
run_canon() {
  ( cd "${ROOT}" && python3 - "$1" "${REVIEWED_CANONICAL}" "${REVIEWED_CANONICAL_BYTES}" \
      < "${CANON_CHECK}" 2>&1 )
}
canon_accepts() {
  ( cd "${ROOT}" && python3 - "$1" "${REVIEWED_CANONICAL}" "${REVIEWED_CANONICAL_BYTES}" \
      < "${CANON_CHECK}" >/dev/null 2>&1 )
}

if canon_accepts "${PAYLOAD}"; then
  pass "gate 4 accepts the reviewed payload"
else
  fail "gate 4 refuses the reviewed payload; it is a brick"
fi

# Each crafted document changes exactly one thing the check is responsible for.
python3 - "${PAYLOAD}" "${WORK}" <<'CRAFT_PY'
import json
import pathlib
import sys

source, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
base = json.loads(source.read_text(encoding="utf-8"))


def write(name, mutate):
    document = json.loads(json.dumps(base))
    mutate(document)
    (out / name).write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


write("c-label.json", lambda d: d["arguments"].__setitem__(
    "label", "g11bcn-third-controlled-production-invoke-x"))
write("c-operation.json", lambda d: d.__setitem__("operation", "execute"))
write("c-count.json", lambda d: d["arguments"].__setitem__("count", 2))
write("c-note.json", lambda d: d.__setitem__(
    "note", "ENG-0005 G11-BC-N: a note that binds CADV-000007 / CINST-000006 / CROUTE-0006 only."))
write("c-noargs.json", lambda d: d.__delitem__("arguments"))
write("c-nonote.json", lambda d: d.__delitem__("note"))
(out / "c-notjson.json").write_text("this is not json\n", encoding="utf-8")
CRAFT_PY

# name | crafted file | expected refusal
CANON_CASES=(
"a changed label|c-label.json|arguments.label is"
"a changed operation|c-operation.json|the payload operation is execute"
"a changed argument count|c-count.json|arguments.count is 2"
"a note that does not bind CSEL-000004|c-note.json|the payload note does not bind CSEL-000004"
"no arguments object|c-noargs.json|the payload carries no arguments object"
"no note|c-nonote.json|the payload carries no note"
"a document that is not JSON|c-notjson.json|the payload is not readable JSON"
)

# Each crafted document is judged against ITS OWN canonical digest and byte
# count. Judged against the reviewed ones, every case would refuse on the digest
# and the semantic checks below it would never run -- refusals that prove only
# that sha256 works. The semantic checks exist as a cross-check on the PIN
# rather than on the document: they are what would catch a reviewed digest
# constant that is itself wrong, and that is reachable only when the digest
# agrees. So the digest is made to agree, and the semantics are made to fail.
own_canon() {
  ( cd "${ROOT}" && python3 - "$1" <<'OWN_PY'
import hashlib
import json
import pathlib
import sys

from tools.capability.invocation_identity import canonical_bytes

try:
    document = json.loads(pathlib.Path(sys.argv[1]).read_bytes())
    blob = canonical_bytes(document)
except Exception:  # noqa: BLE001
    print("unreadable")
    print("0")
    raise SystemExit(0)
print(hashlib.sha256(blob).hexdigest())
print(len(blob))
OWN_PY
  )
}

for case in "${CANON_CASES[@]}"; do
  IFS='|' read -r name file refusal <<<"${case}"
  own="$(own_canon "${WORK}/${file}")"
  own_digest="$(printf '%s' "${own}" | sed -n 1p)"
  own_bytes="$(printf '%s' "${own}" | sed -n 2p)"
  got="$( ( cd "${ROOT}" && python3 - "${WORK}/${file}" "${own_digest}" "${own_bytes}" \
            < "${CANON_CHECK}" 2>&1 ) || true )"
  if ( cd "${ROOT}" && python3 - "${WORK}/${file}" "${own_digest}" "${own_bytes}" \
         < "${CANON_CHECK}" >/dev/null 2>&1 ); then
    fail "gate 4 ACCEPTED: ${name}"
  elif printf '%s' "${got}" | grep -qF -- "${refusal}"; then
    pass "gate 4 refuses ${name} for its own reason"
  else
    fail "gate 4 refused ${name} but not for its own reason: ${got}"
  fi
  if printf '%s' "${got}" | grep -q 'Traceback'; then
    fail "gate 4 crashed on ${name}"
  else
    pass "gate 4 judged ${name} without crashing"
  fi
done

# And with the REVIEWED pins, every one of them refuses on the digest -- which
# is the check that actually stands between the operator and a changed payload.
for case in "${CANON_CASES[@]}"; do
  IFS='|' read -r name file _refusal <<<"${case}"
  [[ "${file}" == "c-notjson.json" ]] && continue
  got="$(run_canon "${WORK}/${file}" || true)"
  if printf '%s' "${got}" | grep -qF -- "canonical digest"; then
    pass "gate 4 refuses ${name} on the canonical digest against the reviewed pin"
  else
    fail "gate 4 did not refuse ${name} on the canonical digest: ${got}"
  fi
done

# A changed label must move the CANONICAL digest, not merely the raw one. This
# is the property the raw check cannot speak to.
got="$(run_canon "${WORK}/c-label.json" || true)"
if printf '%s' "${got}" | grep -qF -- "canonical digest"; then
  pass "gate 4 refuses a relabelled payload on its CANONICAL digest"
else
  fail "gate 4 did not judge the canonical digest of a relabelled payload: ${got}"
fi

# A reformatted payload is the SAME document: the canonical check must accept it,
# which is what makes the raw check load-bearing rather than redundant.
if canon_accepts "${WORK}/reformatted.json"; then
  pass "gate 4 accepts a reformatted payload; the raw check is what catches layout"
else
  fail "gate 4 refused a reformatted payload; the two digests are being conflated"
fi

# ---- the work area is not written over --------------------------------------

printf '\n--- an existing work area is refused ---\n'
build_fixture "${FIX}"
# workparent already exists from build_fixture, so -p would only muddy what
# -m applies to.
mkdir -m 0700 "${FIX}/workparent/g11bcn"
render_block "${FIX}" "${rendered}"
status=0
run_block "${rendered}" "${WORK}/exists.out" || status=$?
if (( status != 0 )) && grep -qF 'Stage 0 does not write over a prepared work area' "${WORK}/exists.out"; then
  pass "an existing work area is refused before any gate runs"
else
  fail "an existing work area was not refused"
fi

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
     || grep -q -- '--- current eligibility gate ---' "${WORK}/repeat-${attempt}.out" \
     || [[ -e "${FIX}/workparent/g11bcn" ]]; then
    deterministic=0
  fi
done
if (( deterministic == 1 )); then
  pass "an expired advertisement stops the block before gate 2 and before creation, 3 of 3 runs"
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
if [[ ! -e "${PRODUCTION_WORK}" ]]; then
  pass "no production work area was created"
else
  fail "A PRODUCTION WORK AREA WAS CREATED"
fi
if [[ ! -e "${PRODUCTION_RUNTIME}/capability-invocations/CINV-000003.yaml" ]]; then
  pass "CINV-000003 is still absent from production"
else
  fail "CINV-000003 WAS ALLOCATED IN PRODUCTION"
fi
if [[ "$(cat "${PRODUCTION_RUNTIME}/sequences/capability-invocation.seq")" == "${CINV_SEQ_BEFORE}" ]]; then
  pass "the production capability-invocation.seq is still ${CINV_SEQ_BEFORE}"
else
  fail "THE PRODUCTION INVOCATION SEQUENCE MOVED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage 0 rehearsal passed.\n'
else
  printf 'CINV-000003 Stage 0 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
