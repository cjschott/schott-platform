#!/usr/bin/env bash
set -Eeuo pipefail

# The CADM-000001 provenance-correction ceremony, rehearsed whole.
#
# HOST-ONLY. It drives the real operator ceremony, with the real INSTALLED
# Generation-20 library, against a reconstruction of the store the operator ran
# it against. See tests/host-only.manifest.
#
# THE CEREMONY IS SPENT, AND THE REHEARSAL IS NOT RETIRED
# ======================================================
# The operator performed the correction on 2026-09-21, so the ceremony now
# refuses: it pins the pre-correction runtime baseline and production is past
# it. That refusal is asserted here, at the gate it belongs to.
#
# The rehearsal itself still runs, because the correction's whole mutation was
# one CADM and one counter increment -- so removing them reproduces the store
# the operator ran against, exactly, which G11-BC-Z proved by aggregate. The
# ceremony is then driven against that reconstruction with the real installed
# library, which is a stronger claim than a list of assertions about what the
# record says: it shows the accepted production record is reproducible from the
# reviewed ceremony.
#
# THIS IS THE SUITE THE LAST ONE COULD NOT BE
# ===========================================
# tests/test-capability-cinv-000002-reclamation-rehearsal.sh tried to rehearse a
# whole ceremony by substituting the runtime path. Every GATE followed the
# substitution and the MUTATION did not: `command_abandon` resolved a module
# constant, and the rehearsal abandoned CINV-000002 in production.
#
# Generation 20 removed that constant from the administrative mutators. So a
# substitution now reaches the writer too, and the property is asserted rather
# than assumed: the ceremony's own emitted `target` -- the device and inode the
# kernel reports for the descriptor the mutation was written through -- must be
# the FIXTURE's, and production must be byte-identical afterwards.
#
# WHAT IS SUBSTITUTED, AND NOTHING ELSE
#   INSTALLED=/usr/lib/kyri/python   -> a Generation-20 library the installer built
#   RUNTIME=/data/kyri/capability-runtime -> a byte copy inside the fixture
#   RUNTIME_BEFORE                   -> that copy's own aggregate
#
# Every pinned digest, every gate and the mutation itself are the ceremony's own.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python \
                   /etc/kyri/backing-store.json

CEREMONY="${ROOT}/provisioning/execution/g11-bc-y-cadm-000001-provenance-correction-ceremony.txt"
PRODUCTION=/data/kyri/capability-runtime          # prod-path-reference
INSTALLED=/usr/lib/kyri/python                    # prod-path-reference

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d -p /data/kyri g11bcy-rehearsal.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
PRODUCTION_BEFORE="$(aggregate "${PRODUCTION}")"
LIBRARY_BEFORE="$(find "${INSTALLED}" -type f -name '*.py' -print0 | sort -z \
                  | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"

# ===========================================================================
# 1. The ceremony is SPENT, and says so where it should
# ===========================================================================
#
# The operator ran it on 2026-09-21 and CADM-000002 exists. A spent ceremony
# must refuse, and it must refuse on a DURABLE FACT rather than on a whole-store
# aggregate that will keep moving: the runtime baseline it pins is the
# pre-correction one, and production is past it.

printf -- '--- the ceremony is spent ---\n'

out="$( ( cd "${ROOT}" && bash "${CEREMONY}" ) 2>&1 )" && status=0 || status=$?
if (( status != 0 )); then
  pass "the spent ceremony refuses"
else
  fail "the spent ceremony ran again"
fi
if [[ "${out}" == *"the capability-runtime store has moved"* ]]; then
  pass "it refuses at the runtime-baseline gate, before touching the subject"
else
  fail "it refused for another reason: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ')"
fi
if [[ "${out}" == *"not the reviewed Generation-20"* ]]; then
  fail "it refused on the installed generation; Generation 20 is installed"
else
  pass "the installed-generation gate passes: the host is at Generation 20"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the refusal wrote nothing: production is byte-identical"
else
  fail "THE REFUSING CEREMONY MUTATED PRODUCTION"
fi

# ===========================================================================
# 1b. The durable facts of the accepted correction
# ===========================================================================
#
# Spent mode: facts that stay true, never an aggregate. Stage 2 will move
# counters and transitions; none of these depends on that.

printf -- '\n--- the accepted correction, as durable facts ---\n'

CADM2="${PRODUCTION}/execution/admin-records/CADM-000002"
if [[ -d "${CADM2}" ]]; then
  pass "CADM-000002 exists in production"
else
  fail "CADM-000002 is absent"
  exit 1
fi
if [[ "$(cd "${CADM2}" && find . -type f -printf '%P\n' | sort | tr '\n' ' ')" \
      == "intent outcome provenance-correction " ]] \
   || [[ "$(cd "${CADM2}" && find . -type f -printf '%P\n' | sort | tr '\n' ' ')" \
      == "intent outcome provenance-correction" ]]; then
  pass "it carries intent, outcome and the finding, and nothing else"
else
  fail "CADM-000002 holds $(cd "${CADM2}" && find . -type f -printf '%P\n' | sort | tr '\n' ' ')"
fi
for pair in \
  "abandonment:d1307f014d8eae2cccf83bfc8c3d673a93a00a86c797e07af44b9053b0dedced" \
  "intent:a7faa2c165f7c0fd4b3b91204ecd213b4ad4ffdb1029e0c438b3eb25d6e92944" \
  "outcome:07bb889d884bc76b0cae423a65f6e2fdff9a6d7d8de4584df029fc6a3bbeeeb3"
do
  member="${pair%%:*}"; want="${pair##*:}"
  got="$(sha256sum "${PRODUCTION}/execution/admin-records/CADM-000001/${member}" | cut -d' ' -f1)"
  if [[ "${got}" == "${want}" ]]; then
    pass "CADM-000001/${member} is byte-identical: the subject was never written to"
  else
    fail "CADM-000001/${member} is ${got}"
  fi
done
for claim in '"subject_cadm":"CADM-000001"' '"subject_member":"abandonment"' \
             '"subject_digest":"d1307f014d8eae2cccf83bfc8c3d673a93a00a86c797e07af44b9053b0dedced"' \
             '"disputed_field":"actor"' '"disputed_value":"primary-platform-operator"' \
             '"finding":"attribution-not-authorised"' \
             '"actual_initiator":"unauthorised-rehearsal-harness"' \
             '"effect":"retained"' '"action_reversed":false' \
             '"lifecycle_unchanged":true' '"slot_changed":false' \
             '"lifecycle_state":"abandoned"'
do
  if grep -qF -- "${claim}" "${CADM2}/provenance-correction"; then
    pass "the finding records ${claim}"
  else
    fail "the finding does not record ${claim}"
  fi
done
# The effect it describes is still standing. This is the fact the correction is
# ABOUT, so it is checked rather than assumed.
if ( cd "${INSTALLED}" && python3 - "${PRODUCTION}" <<'STANDINGPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import capacity as cap, state as sm
root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    states = sm.all_states(root)
    if states["CINV-000002"].value != "abandoned":
        raise SystemExit(1)
    if states["CINV-000002"] in cap.slot_holding_states():
        raise SystemExit(1)
finally:
    root.close()
STANDINGPY
); then
  pass "CINV-000002 is still abandoned and still holds no slot: the effect stands"
else
  fail "the effect the correction describes has changed"
fi

# ===========================================================================
# 2. The pre-correction store, reconstructed
# ===========================================================================
#
# The correction's whole mutation was one CADM and one counter increment, so
# removing them reproduces the store it ran against -- which G11-BC-Z proved by
# aggregate. That reconstruction is what the ceremony is rehearsed against, so
# the rehearsal still runs the REAL ceremony against the REAL starting state
# rather than being retired to a list of assertions.

printf -- '\n--- the pre-correction store, reconstructed ---\n'

cp -a "${PRODUCTION}" "${WORK}/runtime"
chmod -R u+w "${WORK}/runtime"
rm -rf "${WORK}/runtime/execution/admin-records/CADM-000002"
printf '000001\n' > "${WORK}/runtime/execution/cadm-counter"
reconstructed="$(find "${WORK}/runtime" -type f -print0 | sort -z | xargs -0 sha256sum \
  | sed "s#${WORK}/runtime#/data/kyri/capability-runtime#" | sha256sum | cut -d' ' -f1)"
if [[ "${reconstructed}" == "9374b56870759ebccbbb74a38ada5905bcd5ce3bd1418428b72e148cdc662d68" ]]; then
  pass "the reconstruction reproduces the accepted pre-correction aggregate"
else
  fail "the reconstruction is ${reconstructed}"
fi
cp -a "${WORK}/runtime" "${WORK}/runtime.orig"

# The library is the INSTALLED one: Generation 20 is what the operator ran, and
# it is the authority this rehearsal is about.
FIXTURE_LIB="${INSTALLED}"
pass "the rehearsal calls the installed Generation-20 library, as the operator did"

# ===========================================================================
# 3. The whole ceremony, aimed at the fixture
# ===========================================================================

printf -- '\n--- the whole ceremony, against the fixture ---\n'

rendered="${WORK}/ceremony.sh"
sed -e "s#^INSTALLED=/usr/lib/kyri/python\$#INSTALLED=${FIXTURE_LIB}#" \
    -e "s#^RUNTIME=/data/kyri/capability-runtime\$#RUNTIME=${WORK}/runtime#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${WORK}/runtime")#" \
    "${CEREMONY}" > "${rendered}"

# Only the RUNTIME is substituted. INSTALLED stays pointed at the real library
# on purpose: Generation 20 is installed, it is what the operator ran, and it
# is the authority this rehearsal exists to exercise.
if grep -q "^RUNTIME=${PRODUCTION}\$" "${rendered}"; then
  fail "the production runtime root survived the substitution"
else
  pass "the runtime root was substituted"
fi
if grep -q "^INSTALLED=${INSTALLED}\$" "${rendered}"; then
  pass "the installed Generation-20 library is still what the ceremony calls"
else
  fail "the installed library was substituted away; the rehearsal would prove less"
fi

out="$( ( cd "${ROOT}" && bash "${rendered}" ) 2>&1 )" && status=0 || status=$?
if (( status == 0 )); then
  pass "the ceremony runs to completion against the fixture"
else
  fail "the ceremony failed (${status}): $(printf '%s' "${out}" | tail -4 | tr '\n' ' ')"
fi

for expected in \
  'ok  installed: correct-provenance present, actor-only, no destruction authority' \
  'ok  installed: both administrative mutators require an explicit target' \
  'ok  CADM-000001 records actor primary-platform-operator for CINV-000002 -- the claim this corrects' \
  'ok  exactly one administrative record, and no correction yet' \
  'ok  CINV-000001 launch_authorized, CINV-000002 abandoned, 1 of 2 slots held' \
  'ALL GATES PASSED. THE NEXT COMMAND IS IRREVERSIBLE.' \
  'ok  process rc 0' \
  'ok  cadm               CADM-000002' \
  'ok  effect             retained' \
  'ok  lifecycle_state    abandoned' \
  'ok  resumed            False' \
  'ok  the writer held the production execution root, asked of the kernel' \
  'ok  no transition, no CMUT, no CRES, no sequence movement, CINV-000003 untouched' \
  'ok  lifecycle unchanged, 1 of 2 slots held' \
  'THE ATTRIBUTION IS CORRECTED. THE EFFECT STANDS. STOP HERE.'
do
  if printf '%s' "${out}" | grep -qF "${expected}"; then
    pass "the ceremony reports: ${expected}"
  else
    fail "the ceremony did not report: ${expected}"
  fi
done

# ===========================================================================
# 4. THE PROPERTY THE LAST REHEARSAL DID NOT HAVE
# ===========================================================================

printf -- '\n--- the writer followed the substitution ---\n'

fixture_inode="$(stat -c '%i' "${WORK}/runtime/execution")"
production_inode="$(stat -c '%i' "${PRODUCTION}/execution")"
reported="$(printf '%s' "${out}" | sed -n 's/^ok  production execution root is device [0-9]* inode \([0-9]*\)$/\1/p' | head -1)"
if [[ "${reported}" == "${fixture_inode}" ]]; then
  pass "the ceremony measured the fixture's execution root (inode ${reported})"
else
  fail "the ceremony measured inode ${reported}, the fixture is ${fixture_inode}"
fi
if [[ "${reported}" != "${production_inode}" ]]; then
  pass "and that is not production's (inode ${production_inode})"
else
  fail "the fixture and production are indistinguishable"
fi

if [[ -f "${WORK}/runtime/execution/admin-records/CADM-000002/provenance-correction" ]]; then
  pass "the correction landed in the fixture"
else
  fail "no correction was written to the fixture"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "PRODUCTION IS BYTE-IDENTICAL: ${PRODUCTION_BEFORE}"
else
  fail "THE REHEARSAL MUTATED PRODUCTION"
fi
# Production's CADM-000002 is the operator's accepted one, and this run did not
# touch it. "Absent" stopped being the right assertion the moment the operator
# performed the correction; "unchanged by me" is.
if [[ "$(sha256sum "${PRODUCTION}/execution/admin-records/CADM-000002/provenance-correction" | cut -d' ' -f1)" \
      == "47b977d83b164ee9056527d99ec40d995b8e9b26e4b63b992df1ac8da8b0e58e" ]]; then
  pass "production's accepted CADM-000002 is byte-identical: this run did not touch it"
else
  fail "PRODUCTION'S CADM-000002 CHANGED"
fi
if [[ ! -e "${PRODUCTION}/execution/admin-records/CADM-000003" ]]; then
  pass "and no further administrative record was created"
else
  fail "A PRODUCTION ADMINISTRATIVE RECORD WAS CREATED"
fi
after_lib="$(find "${INSTALLED}" -type f -name '*.py' -print0 | sort -z \
             | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
if [[ "${after_lib}" == "${LIBRARY_BEFORE}" ]]; then
  pass "the installed library is byte-identical: the rehearsal published nothing"
else
  fail "THE INSTALLED LIBRARY CHANGED"
fi

# ===========================================================================
# 5. The mutation, measured
# ===========================================================================

printf -- '\n--- the mutation, measured ---\n'

for member in intent outcome provenance-correction; do
  if [[ -f "${WORK}/runtime/execution/admin-records/CADM-000002/${member}" ]]; then
    pass "CADM-000002 carries its ${member}"
  else
    fail "CADM-000002 has no ${member}"
  fi
done
if diff -r "${WORK}/runtime.orig/execution/admin-records/CADM-000001" \
           "${WORK}/runtime/execution/admin-records/CADM-000001" >/dev/null; then
  pass "CADM-000001 is byte-identical: the subject was never opened for writing"
else
  fail "CADM-000001 CHANGED"
fi
if diff -r "${WORK}/runtime.orig/execution/transitions" \
           "${WORK}/runtime/execution/transitions" >/dev/null; then
  pass "the transition journal is byte-identical"
else
  fail "a transition was written"
fi
if diff -r "${WORK}/runtime.orig/execution/mutations" \
           "${WORK}/runtime/execution/mutations" >/dev/null; then
  pass "the mutation journal is byte-identical: a correction journals no lifecycle"
else
  fail "a CMUT was written"
fi
if diff -r "${WORK}/runtime.orig/capability-invocations" \
           "${WORK}/runtime/capability-invocations" >/dev/null \
   && diff -r "${WORK}/runtime.orig/capability-results" \
              "${WORK}/runtime/capability-results" >/dev/null; then
  pass "every CINV and CRES is byte-identical"
else
  fail "an immutable record changed"
fi

# The whole mutation, by reconstruction rather than by enumeration.
recon="${WORK}/recon"
cp -a "${WORK}/runtime" "${recon}"; chmod -R u+w "${recon}"
rm -rf "${recon}/execution/admin-records/CADM-000002"
printf '000001\n' > "${recon}/execution/cadm-counter"
a="$(find "${recon}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${recon}#X#" | sha256sum)"
b="$(find "${WORK}/runtime.orig" -type f -print0 | sort -z | xargs -0 sha256sum \
     | sed "s#${WORK}/runtime.orig#X#" | sha256sum)"
if [[ "${a}" == "${b}" ]]; then
  pass "removing CADM-000002 and the counter increment reproduces the pre-correction store exactly"
else
  fail "the mutation was not exactly one CADM and one counter increment"
fi

# ===========================================================================
# 6. A second run refuses
# ===========================================================================

printf -- '\n--- a second run ---\n'
sed -i "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${WORK}/runtime")#" "${rendered}"
out="$( ( cd "${ROOT}" && bash "${rendered}" ) 2>&1 )" && status=0 || status=$?
if (( status != 0 )); then
  pass "a second run refuses"
else
  fail "a second run was accepted"
fi
# It refuses at the counter, which is the earliest gate that can see the
# correction already happened -- before the subject is read and long before
# anything is written.
if printf '%s' "${out}" | grep -qE 'cadm-counter is not 000001|more than one administrative record'; then
  pass "it refuses on evidence that the correction already happened, before the mutation"
else
  fail "the second run refused for another reason: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ')"
fi
if [[ ! -e "${WORK}/runtime/execution/admin-records/CADM-000003" ]]; then
  pass "and no second correction was written"
else
  fail "a second correction was written"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CADM-000001 correction rehearsal passed.\n'
else
  printf 'CADM-000001 correction rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
