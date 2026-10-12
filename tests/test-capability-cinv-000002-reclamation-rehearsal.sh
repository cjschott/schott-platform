#!/usr/bin/env bash
# shellcheck disable=SC2317  # everything past the disarm guard is deliberately
# unreachable: the file is kept as evidence of what it did, not to be run.
set -Eeuo pipefail

# The CINV-000002 reclamation ceremony, rehearsed whole against the INSTALLED
# Generation-19 runtime.
#
# HOST-ONLY. It runs the entire operator block with the real installed library
# and a byte copy of the production runtime. See tests/host-only.manifest.
#
# WHY THIS CEREMONY EXISTS, AND WHY THE FIRST ONE DID NOT WORK
# ============================================================
# G11-BC-V's ceremony called the coordinator CLI out of the checkout while the
# installed runtime was still Generation 18, which cannot parse an `abandoned`
# record -- and `all_states` resolves every chain in ONE comprehension, so that
# single record would have raised out of capacity, recovery and cleanup for the
# WHOLE store. G11-BC-W published Generation 19 first. This ceremony calls the
# INSTALLED library, by running from /usr/lib/kyri/python, and the suite asserts
# that it does.
#
# THE HARD GATE IS CONTAINER ABSENCE. ABANDONED removes the invocation from the
# recovery enumeration, so if a container still existed this would close the one
# surface that would have found it. BLOCK A observes as kyri-capability and
# BLOCK B refuses without a witness under 300 seconds old.
#
# BLOCK A IS NOT RUN HERE: it needs sudo, which a test may not assume. The suite
# writes the witness BLOCK A would write and separately proves BLOCK B refuses
# an absent, stale, future-dated or incomplete one.
#
# Substitutions, and nothing else:
#   /data/kyri/capability-runtime  -> a byte copy inside the fixture
#   the witness path               -> one inside the fixture
#   RUNTIME_BEFORE                 -> that copy's own aggregate
#
# The INSTALLED library is NOT substituted: it is the authority under test.
#
# Production is never written. Proved by aggregate after every run.

# =============================== DISARMED ===============================
# THIS SUITE CAUSED A PRODUCTION MUTATION ON 2026-09-20 AND MUST NOT RUN AGAIN
# IN THIS FORM.
#
# It rehearsed the whole operator block against a fixture by substituting the
# runtime path with sed. That substitution redirected every GATE, but it could
# not redirect the MUTATION: `tools.capability.cli.command_abandon` resolves its
# store from the module constant CAPABILITY_RUNTIME_ROOT ("/data/kyri/
# capability-runtime"). The CLI accepts no runtime-root argument. So the gates
# read a fixture, and the abandon wrote to production: CINV-000002 was
# administratively abandoned without operator authorisation and without the
# BLOCK A container observation.
#
# A whole-ceremony rehearsal is only sound if the mutation call itself can be
# aimed. Until that is settled by the reviewer, this file stands as evidence.
echo "DISARMED: this suite mutated production on 2026-09-20; see the G11-BC-X incident report" >&2
exit 1
# ========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python /etc/kyri/backing-store.json

CEREMONY="${ROOT}/provisioning/execution/g11-bc-x-cinv-000002-reclamation-ceremony.txt"
WITHDRAWN="${ROOT}/provisioning/execution/g11-bc-v-cinv-000002-abandonment-ceremony.txt"
INSTALLED=/usr/lib/kyri/python
PRODUCTION_RUNTIME=/data/kyri/capability-runtime
PRODUCTION_WITNESS=/data/kyri/work/g11bcx-cinv-000002-witness

TARGET=CINV-000002
REASON=terminal-result-lifecycle-stranded
SHA_CINV1=1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
SHA_CINV2=923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
SHA_CINV3=c0941b7d45dcccac4bb28d00f942ea63aa90cd46ed55767797363f1ed1accaf2
SHA_CRES1=18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d
RUNTIME_BASELINE=6202e1ecb7ce54cb6a90176ab1c5aff41438319f4c5a4f50e3f46dd705092e6f

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# The fixture lives on /data so it passes the same backing-store verification
# the production roots pass. /tmp is a different filesystem and would be refused.
WORK="$(mktemp -d -p /data/kyri g11bcx-suite.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }

PRODUCTION_BEFORE="$(aggregate "${PRODUCTION_RUNTIME}")"
if [[ "${PRODUCTION_BEFORE}" == "${RUNTIME_BASELINE}" ]]; then
  pass "production runtime is at the pinned post-Generation-19 baseline"
else
  fail "production runtime is ${PRODUCTION_BEFORE}, not ${RUNTIME_BASELINE}"
fi
if [[ -e "${PRODUCTION_WITNESS}" ]]; then
  fail "a production witness already exists; this suite will not rehearse over it"
  exit 1
fi

# ---- the withdrawn ceremony stays withdrawn -------------------------------

printf '\n--- the withdrawn ceremony ---\n'
if bash "${WITHDRAWN}" >/dev/null 2>&1; then
  fail "the withdrawn G11-BC-V ceremony still runs"
else
  pass "the withdrawn G11-BC-V ceremony refuses to run"
fi
if grep -q 'WITHDRAWN' "${WITHDRAWN}"; then
  pass "the withdrawn ceremony says so at the top of the file"
else
  fail "the withdrawn ceremony carries no withdrawal notice"
fi

# ---- the new ceremony uses the INSTALLED authority ------------------------

printf '\n--- the ceremony calls the installed runtime ---\n'
BLOCK="${WORK}/block.sh"
awk "/^bash <<'RECLAIM_CINV2'\$/{on=1;next} /^RECLAIM_CINV2\$/{on=0} on" "${CEREMONY}" > "${BLOCK}"
if [[ -s "${BLOCK}" ]]; then
  pass "the operator block was extracted whole ($(wc -l < "${BLOCK}") lines)"
else
  fail "the operator block could not be extracted"
  exit 1
fi
OBSERVE="${WORK}/observe.sh"
awk "/^bash <<'OBSERVE'\$/{on=1;next} /^OBSERVE\$/{on=0} on" "${CEREMONY}" > "${OBSERVE}"
if [[ -s "${OBSERVE}" ]]; then
  pass "BLOCK A was extracted whole"
else
  fail "BLOCK A could not be extracted"
fi

# shellcheck disable=SC2016  # the ceremony's own text is matched literally
if grep -q 'cd "${INSTALLED}" && python3 -m tools.capability.cli abandon' "${BLOCK}"; then
  pass "the abandon call runs from the installed library, not the checkout"
else
  fail "the abandon call does not run from the installed library"
fi
if grep -q 'INSTALLED=/usr/lib/kyri/python' "${BLOCK}"; then
  pass "the installed root is /usr/lib/kyri/python"
else
  fail "the block does not name the installed root"
fi
if grep -q 'sudo' "${BLOCK}"; then
  fail "BLOCK B contains sudo; the irreversible block must need no privilege"
else
  pass "BLOCK B needs no privilege"
fi
if grep -q '^cd /tmp$' "${OBSERVE}"; then
  pass "BLOCK A runs from /tmp, which kyri-capability can traverse"
else
  fail "BLOCK A does not cd to /tmp"
fi
if grep -q 'podman ps -a' "${OBSERVE}" && grep -q "podman ps --format" "${OBSERVE}"; then
  pass "BLOCK A observes both all containers and the running set"
else
  fail "BLOCK A does not observe both container sets"
fi
if grep -q 'WITNESS_MAXIMUM_AGE=300' "${BLOCK}"; then
  pass "the witness freshness bound is 300 seconds"
else
  fail "the witness freshness bound is not 300 seconds"
fi
# Exactly one production abandon, and it is not a rehearsal flag.
if [[ "$(grep -c 'tools.capability.cli abandon' "${BLOCK}")" == "1" ]]; then
  pass "the block runs exactly one abandon"
else
  fail "the block runs $(grep -c 'tools.capability.cli abandon' "${BLOCK}") abandons"
fi
if grep -q '^set +e$' "${BLOCK}" && grep -q '^RC=\$?$' "${BLOCK}"; then
  pass "the block captures the process status with errexit disabled"
else
  fail "the block does not capture the abandon status"
fi

# ---- the fixture ----------------------------------------------------------

build_fixture() {
  local fixture="$1"
  if [[ -e "${fixture}" ]]; then chmod -R u+w "${fixture}" 2>/dev/null || true; rm -rf "${fixture}"; fi
  mkdir -p "${fixture}"
  cp -a "${PRODUCTION_RUNTIME}" "${fixture}/runtime"
  mkdir -p "${fixture}/work"
  printf 'cinv-000002-container-observation\nno-container kyri-%s\nno-running kyri-%s\n' \
    "${TARGET}" "${TARGET}" > "${fixture}/work/witness"
  chmod 0600 "${fixture}/work/witness"
}

render_block() {
  local fixture="$1" out="$2" baseline
  baseline="$(aggregate "${fixture}/runtime")"
  sed \
    -e "s#${PRODUCTION_WITNESS}#${fixture}/work/witness#g" \
    -e "s#^RUNTIME=${PRODUCTION_RUNTIME}\$#RUNTIME=${fixture}/runtime#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=${baseline}#" \
    "${BLOCK}" > "${out}"
}

run_block() {
  local rendered="$1" out="$2" status=0
  ( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
  return "${status}"
}

# ---- the happy path -------------------------------------------------------

printf '\n--- the whole block, end to end ---\n'
FIX="${WORK}/fix"; build_fixture "${FIX}"
rendered="${WORK}/rendered.sh"; render_block "${FIX}" "${rendered}"
cp -a "${FIX}/runtime" "${FIX}/runtime.orig"

if grep -q -e "${PRODUCTION_RUNTIME}" -e "${PRODUCTION_WITNESS}" "${rendered}"; then
  fail "the rendered block still references a production runtime or witness path"
else
  pass "the rendered block references no production runtime or witness path"
fi
# The installed library is deliberately NOT substituted.
if grep -q "${INSTALLED}" "${rendered}"; then
  pass "the rendered block still calls the real installed library"
else
  fail "the installed library was substituted away; the rehearsal would prove nothing"
fi

out="${WORK}/run.out"; status=0
run_block "${rendered}" "${out}" || status=$?
if (( status == 0 )); then
  pass "the whole block runs to completion against the fixture"
else
  fail "the whole block failed (status ${status}): $(tail -4 "${out}" | tr '\n' ' ')"
fi

for expected in \
  'ok  observation' \
  'ok  installed: ABANDONED terminal, reachable only from reserved and launch_authorized' \
  'ok  installed: MAXIMUM_SLOTS 2, occupancy excludes only RELEASED and ABANDONED' \
  'ok  installed: recovery treats ABANDONED as closed' \
  'ok  installed: abandon present, no force or target-state flag, no destruction authority' \
  'ok  no administrative records yet' \
  'ok  2 of 2 held, by CINV-000001 and CINV-000002' \
  'ok  CINV-000002 is launch_authorized' \
  'ALL GATES PASSED. THE NEXT COMMAND IS IRREVERSIBLE.' \
  'ok  process rc 0' \
  'ok  lifecycle_state  abandoned' \
  "ok  reason           ${REASON}" \
  'ok  result_record_id CRES-000001 -- referenced, not rewritten' \
  'ok  slot_released    true      resumed false' \
  'ok  sequences unchanged, no CRES-000002' \
  'ok  launch-authorisation and published handoff both intact' \
  'ok  CINV-000002 is abandoned -- closed, not released' \
  'ok  CINV-000001 untouched and still holding its slot' \
  'ok  occupancy 2 -> 1 of 2; one slot reclaimed' \
  'CINV-000002 IS CLOSED. ONE SLOT RECLAIMED. STOP HERE.'
do
  if grep -qF "${expected}" "${out}"; then
    pass "the block reports: ${expected}"
  else
    fail "the block did not report: ${expected}"
  fi
done

# ---- the measured mutation ------------------------------------------------

printf '\n--- the mutation, measured ---\n'
for name in CINV-000001 CINV-000002 CINV-000003; do
  want="SHA_${name//CINV-0000/CINV}"; want="${!want:-}"
done
check_unchanged() {
  local path="$1" want="$2" got
  got="$(sha256sum "${path}" | cut -d' ' -f1)"
  if [[ "${got}" == "${want}" ]]; then
    pass "$(basename "${path}") is byte-identical after the closure"
  else
    fail "$(basename "${path}") is ${got}, expected ${want}"
  fi
}
check_unchanged "${FIX}/runtime/capability-invocations/CINV-000001.yaml" "${SHA_CINV1}"
check_unchanged "${FIX}/runtime/capability-invocations/CINV-000002.yaml" "${SHA_CINV2}"
check_unchanged "${FIX}/runtime/capability-invocations/CINV-000003.yaml" "${SHA_CINV3}"
check_unchanged "${FIX}/runtime/capability-results/CRES-000001.yaml"     "${SHA_CRES1}"

if [[ ! -e "${FIX}/runtime/capability-results/CRES-000002.yaml" ]]; then
  pass "no synthetic CRES was written"
else
  fail "A SYNTHETIC CRES WAS WRITTEN"
fi
if [[ "$(cat "${FIX}/runtime/sequences/capability-invocation.seq")" == "3" \
   && "$(cat "${FIX}/runtime/sequences/capability-result.seq")" == "1" ]]; then
  pass "both sequences are unchanged"
else
  fail "a sequence moved"
fi
if diff -r "${FIX}/runtime.orig/execution/${TARGET}" "${FIX}/runtime/execution/${TARGET}" >/dev/null; then
  pass "the launch-authorisation evidence is byte-identical"
else
  fail "the launch-authorisation evidence changed"
fi
if diff -r "${FIX}/runtime.orig/staging" "${FIX}/runtime/staging" >/dev/null; then
  pass "the staged package tree is byte-identical"
else
  fail "the staged package tree changed"
fi

# The whole mutation, proved by reconstruction rather than by enumeration.
CADM="$(find "${FIX}/runtime/execution/admin-records" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -1)"
if [[ -n "${CADM}" ]]; then
  pass "one administrative record was written (${CADM})"
else
  fail "no administrative record was written"
fi
recon="${WORK}/recon"
if [[ -e "${recon}" ]]; then chmod -R u+w "${recon}"; rm -rf "${recon}"; fi
cp -a "${FIX}/runtime" "${recon}"; chmod -R u+w "${recon}"
rm -rf "${recon}/execution/admin-records/${CADM}"
rm -f  "${recon}/execution/transitions/${TARGET}.000003"
# The CMUT the transition journalled, whichever ordinal it took.
newest_cmut="$(find "${recon}/execution/mutations" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tail -1)"
rm -rf "${recon}/execution/mutations/${newest_cmut}"
printf '000000\n' > "${recon}/execution/cadm-counter"
printf '%s\n' "$(cat "${FIX}/runtime.orig/execution/cmut-counter")" > "${recon}/execution/cmut-counter"
a="$(find "${recon}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${recon}#X#" | sha256sum | cut -d' ' -f1)"
b="$(find "${FIX}/runtime.orig" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${FIX}/runtime.orig#X#" | sha256sum | cut -d' ' -f1)"
if [[ "${a}" == "${b}" ]]; then
  pass "removing the CADM, the transition and the CMUT reproduces the pre-closure store exactly"
else
  fail "the mutation was not exactly one CADM, one transition and one CMUT"
fi

# The evidence says what ADR-0015 requires.
detail="${FIX}/runtime/execution/admin-records/${CADM}/abandonment"
if [[ -f "${detail}" ]]; then
  for pair in "\"cinv\":\"${TARGET}\"" '"previous_state":"launch_authorized"' \
              '"state":"abandoned"' "\"reason\":\"${REASON}\"" \
              '"result_record_id":"CRES-000001"' '"slot_released":true' \
              '"actor":"primary-platform-operator"'; do
    if grep -qF -- "${pair}" "${detail}"; then
      pass "the abandonment evidence records ${pair}"
    else
      fail "the abandonment evidence does not record ${pair}"
    fi
  done
else
  fail "no abandonment detail was written"
fi
for member in intent outcome; do
  if [[ -f "${FIX}/runtime/execution/admin-records/${CADM}/${member}" ]]; then
    pass "the CADM carries its ${member}"
  else
    fail "the CADM has no ${member}"
  fi
done

# ---- capacity, after the reclamation --------------------------------------

printf '\n--- capacity after the reclamation ---\n'
occupancy_of() {
  ( cd "${INSTALLED}" && python3 - "$1" <<'OCCPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import capacity as cap, state as sm
root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    st = sm.all_states(root)
    print(sum(1 for v in st.values() if v in cap.slot_holding_states()))
finally:
    root.close()
OCCPY
  )
}
if [[ "$(occupancy_of "${FIX}/runtime")" == "1" ]]; then
  pass "occupancy is exactly 1 of 2; one slot is available"
else
  fail "occupancy is $(occupancy_of "${FIX}/runtime") of 2, expected 1"
fi
if [[ ! -e "${FIX}/runtime/execution/CINV-000003" ]]; then
  pass "CINV-000003 still has no execution state; Stage 2 was not performed"
else
  fail "CINV-000003 GAINED EXECUTION STATE"
fi

# ---- fail closed, by gate --------------------------------------------------
#
# Each sabotage changes exactly one thing and must refuse FOR ITS OWN REASON.
# Every case also asserts that no abandonment happened: a sabotage that closed
# the invocation anyway is a gate that did not hold.

printf '\n--- fail closed, by gate ---\n'

# name | how the fixture or block is broken | expected refusal
SABOTAGE=(
"the installed runtime is not wholly Generation 19|sed -i 's#^check_installed tools/capability/execution/types.py .*#check_installed tools/capability/execution/types.py 0000000000000000000000000000000000000000000000000000000000000000#' \"\${rendered}\"|not the reviewed Generation-19"
"the abandon verb is unavailable|sed -i 's#tools.capability.cli abandon#tools.capability.cli no-such-verb#' \"\${rendered}\"|the process exited"
"CINV-000002 is missing|rm -f \"\${FIX}/runtime/capability-invocations/CINV-000002.yaml\"|CINV-000002.yaml is absent"
"the CINV-000002 SHA changed|printf 'x' >> \"\${FIX}/runtime/capability-invocations/CINV-000002.yaml\"|CINV-000002.yaml is"
"CRES-000001 is missing|rm -f \"\${FIX}/runtime/capability-results/CRES-000001.yaml\"|CRES-000001.yaml is absent"
"the CRES-000001 SHA changed|printf 'x' >> \"\${FIX}/runtime/capability-results/CRES-000001.yaml\"|CRES-000001.yaml is"
"CINV-000001 unexpectedly changed|printf 'x' >> \"\${FIX}/runtime/capability-invocations/CINV-000001.yaml\"|CINV-000001.yaml is"
"CINV-000003 unexpectedly changed|printf 'x' >> \"\${FIX}/runtime/capability-invocations/CINV-000003.yaml\"|CINV-000003.yaml is"
"the reason category is wrong|sed -i 's#^REASON=.*#REASON=historical-incomplete-execution#' \"\${rendered}\"|the process exited"
"the runtime baseline moved|sed -i 's#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#' \"\${rendered}\"|the capability-runtime store has moved"
"the invocation sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-invocation.seq\"|capability-invocation.seq is not 3"
"the result sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-result.seq\"|capability-result.seq is not 1"
"administrative evidence already exists|mkdir -p \"\${FIX}/runtime/execution/admin-records/CADM-000001\"|administrative records already exist"
"the witness is absent|rm -f \"\${FIX}/work/witness\"|run BLOCK A first"
"the witness records no container absence|printf 'cinv-000002-container-observation\\n' > \"\${FIX}/work/witness\"|does not record the absence"
"the witness records absence but not non-running|printf 'cinv-000002-container-observation\\nno-container kyri-CINV-000002\\n' > \"\${FIX}/work/witness\"|does not record that no kyri-CINV-000002 container is running"
"the witness is stale|touch -d '2 hours ago' \"\${FIX}/work/witness\"|re-run BLOCK A"
"the witness is dated in the future|touch -d '1 hour' \"\${FIX}/work/witness\"|dated in the future"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name breakage refusal <<<"${case}"
  build_fixture "${FIX}"
  render_block "${FIX}" "${rendered}"
  eval "${breakage}"

  out="${WORK}/sabotage.out"; status=0
  run_block "${rendered}" "${out}" || status=$?

  if (( status != 0 )); then
    pass "${name}: the block exits nonzero"
  else
    fail "${name}: the block exited 0"
  fi
  if grep -qF -- "${refusal}" "${out}"; then
    pass "${name}: refuses for its own reason (${refusal})"
  else
    fail "${name}: refused, but not for its own reason: $(grep -m1 -E 'REFUSE|STOP' "${out}" || echo 'no refusal line')"
  fi
  if grep -q 'Traceback (most recent call last)' "${out}"; then
    fail "${name}: something crashed instead of judging its input"
  else
    pass "${name}: no traceback"
  fi
  # THE ASSERTION THAT MATTERS: nothing was abandoned.
  if [[ ! -e "${FIX}/runtime/execution/transitions/${TARGET}.000003" ]]; then
    pass "${name}: no abandonment transition was written"
  else
    fail "${name}: THE INVOCATION WAS ABANDONED ANYWAY"
  fi
done

# A lifecycle that is not launch_authorized, and a conflicting replay, both need
# a fixture that has already been closed once.
printf '\n--- an already-closed invocation ---\n'
build_fixture "${FIX}"
render_block "${FIX}" "${rendered}"
run_block "${rendered}" "${WORK}/first.out" || true
render_block "${FIX}" "${rendered}"
status=0
run_block "${rendered}" "${WORK}/second.out" || status=$?
if (( status != 0 )); then
  pass "a second run against an already-closed invocation refuses"
else
  fail "a second run was accepted"
fi
if grep -qE 'administrative records already exist|not launch_authorized|an abandoned record already exists' "${WORK}/second.out"; then
  pass "the second run refuses on the already-closed state, before any mutation"
else
  fail "the second run refused for an unexpected reason: $(grep -m1 -E 'REFUSE|STOP' "${WORK}/second.out")"
fi

# A conflicting replay, judged at the operation rather than the ceremony: the
# ceremony's own gates stop a repeat before the call, so the conflict refusal is
# exercised directly against the installed library.
printf '\n--- a conflicting replay, judged by the installed operation ---\n'
if ( cd "${INSTALLED}" && python3 - "${FIX}/runtime" <<'REPLAYPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.store import CapabilityStore
from tools.capability.execution import abandonment

runtime = sys.argv[1]
store = CapabilityStore(runtime, expected_uid=1000, expected_gid=1000)
root = cli._anchored(os.path.join(runtime, "execution"))
try:
    try:
        abandonment.abandon(
            store=store, execution_root=root, cinv="CINV-000002",
            actor="somebody-else", request_id="a-different-request",
            recorded_at="2026-09-21T09:00:00-05:00",
            reason=abandonment.REASON_TERMINAL_RESULT_STRANDED)
    except abandonment.AbandonmentRefused as exc:
        print(f"refused: {exc}")
        raise SystemExit(0)
    raise SystemExit(1)
finally:
    root.close()
REPLAYPY
); then
  pass "a conflicting replay under different authority is refused by the installed operation"
else
  fail "a conflicting replay under different authority was accepted"
fi

# ---- production, after everything -----------------------------------------

printf '\n--- production untouched ---\n'
if [[ "$(aggregate "${PRODUCTION_RUNTIME}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical after the rehearsal"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
if [[ ! -e "${PRODUCTION_WITNESS}" ]]; then
  pass "no production witness was created"
else
  fail "A PRODUCTION WITNESS WAS CREATED"
fi
if [[ ! -e "${PRODUCTION_RUNTIME}/execution/transitions/${TARGET}.000003" ]]; then
  pass "${TARGET} was not abandoned in production"
else
  fail "${TARGET} WAS ABANDONED IN PRODUCTION"
fi
if [[ "$(find "${PRODUCTION_RUNTIME}/execution/admin-records" -mindepth 1 | wc -l)" == "0" ]]; then
  pass "no production administrative record was created"
else
  fail "A PRODUCTION ADMINISTRATIVE RECORD WAS CREATED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000002 reclamation rehearsal passed.\n'
else
  printf 'CINV-000002 reclamation rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
