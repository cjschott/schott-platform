#!/usr/bin/env bash
set -Eeuo pipefail

# The CADM-000001 provenance-correction ceremony, rehearsed whole.
#
# HOST-ONLY. It drives the real operator ceremony against the real INSTALLED
# library -- whichever generation the host carries -- and asserts the durable
# facts of the correction the operator already performed.
# See tests/host-only.manifest.
#
# THE CEREMONY IS SPENT, AND THE REHEARSAL IS NOT RETIRED
# ======================================================
# The operator performed the correction on 2026-09-21, so the ceremony now
# refuses. It refuses on a durable fact -- the runtime baseline it pins is
# behind the store, and on a host past Generation 20 its installed-generation
# gate fires first -- and that refusal is asserted here, at the gate it belongs
# to, together with the two facts themselves, measured independently of the
# refusal text.
#
# What remains live is asserted rather than re-run: the accepted correction's
# own bytes, the subject it did NOT write to, and the two behaviours of the
# correction verb that still have an answer on a spent store -- a conflicting
# correction is refused, and an identical one resumes. Both are driven against a
# byte copy, so the accepted production record is never the thing under test.
#
# WHAT IS PINNED AND WHAT IS MEASURED (G11-BC-AJ). The SUBJECT is pinned:
# CADM-000001's three members and CADM-000002's finding keep their exact
# digests. Everything else is measured against what this run found, because
# accepted later ceremonies legitimately add records -- CADM-000003 from the
# ADR-0017 conclusion, CADM-000004 from the 2026-09-24 escape -- and asserting
# the absence of a named identity would make each of them look like damage.
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
#   INSTALLED=/usr/lib/kyri/python   -> the library the installer built
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

# G11-BC-AJ. THE ADMINISTRATIVE NAMESPACE AS THIS RUN FOUND IT.
#
# This suite used to assert `CADM-000003 does not exist` -- in production and in
# its own fixture copy -- as its proof that nothing was written. That was true
# when CADM-000002 was the last record, and it stopped being true when the
# ADR-0017 conclusion wrote CADM-000003 and the 2026-09-24 escape wrote
# CADM-000004, both of which this suite has nothing to do with. Asserting the
# absence of a specific identity makes every later accepted ceremony look like
# damage.
#
# THE ASSERTION THAT WAS ALWAYS MEANT is "this run wrote nothing", so that is
# what is measured: the record names and the counter as they are at the start,
# compared at the end. The records this suite is ABOUT -- CADM-000001 and its
# correction CADM-000002 -- keep their exact pinned digests below, because those
# are its subject and a pin is the right instrument for a subject.
admin_names() {
  find "$1/execution/admin-records" -mindepth 1 -maxdepth 1 -printf '%f\n' \
    2>/dev/null | sort | tr '\n' ' '
}
ADMIN_BEFORE="$(admin_names "${PRODUCTION}")"
CADM_COUNTER_BEFORE="$(cat "${PRODUCTION}/execution/cadm-counter")"

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
# THE CLOSED SET OF DURABLE REASONS, each matched exactly. Refusing for anything
# else -- a crash, a missing file, a permission error -- is not spentness.
#
# G11-BC-AJ ADDED THE SECOND. The ceremony pins the Generation-20 runtime it was
# reviewed against and this host is at Generation 21, so that gate fires first
# and the ceremony stops before it reaches the store. That pin is HISTORICAL
# EVIDENCE of what the operator actually ran against; it is not edited to match
# today's host. What changed is that the suite now names it as the durable
# reason it is, and then proves the store-level fact independently below.
ceremony_refusal=""
if [[ "${out}" == *"the capability-runtime store has moved"* ]]; then
  ceremony_refusal="the runtime baseline it pins is behind the store"
elif [[ "${out}" == *"not the reviewed Generation-20"* ]]; then
  ceremony_refusal="the installed runtime is no longer the Generation 20 it pins"
fi
if [[ -n "${ceremony_refusal}" ]]; then
  pass "it refuses on a durable fact, before touching the subject: ${ceremony_refusal}"
else
  fail "it refused for another reason: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ')"
fi
# Whichever gate fired, BOTH facts are true, and both are measured here rather
# than read out of the refusal text.
if [[ "$(sha256sum "${INSTALLED}/tools/capability/cli.py" | cut -d' ' -f1)" \
      != "90979a0247d9cc0c28d9bce10be96e0b5205acca1d887db96f5794d6602c9c23" ]]; then
  pass "the host really has moved past Generation 20: the installed cli.py is not 90979a02"
else
  fail "the host is at Generation 20, so the generation gate should not have fired"
fi
if [[ "${PRODUCTION_BEFORE}" != "9374b56870759ebccbbb74a38ada5905bcd5ce3bd1418428b72e148cdc662d68" ]]; then
  pass "and the store really has moved past the pre-correction baseline the ceremony pins"
else
  fail "the store is still at the pre-correction baseline: the ceremony is not spent"
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
# 2. The released operation still refuses a conflicting correction
# ===========================================================================
#
# WHAT THIS SUITE STOPPED DOING, AND WHY.
#
# It used to reconstruct the pre-correction store -- today's store less
# CADM-000002 and its counter -- and drive the whole ceremony against it. That
# was sound the day it was written and stopped being sound the moment Stage 2
# landed: the reconstruction reproduces the pre-correction AGGREGATE only while
# nothing else has happened since, and something always happens next. Keeping
# it would mean subtracting every later stage's artefacts from a hand-kept
# list, which is the exact defect corrected at G11-BC-Y in eight other suites.
#
# So this is spent mode, as the discipline requires: durable facts, and no
# historical whole-store aggregate. What remains testable without one is the
# released operation's own refusal -- a property of the code rather than of the
# store's history, and the one that protects the accepted record from being
# written over by a second authority.

printf -- '\n--- a conflicting correction is refused ---\n'

FIXTURE="${WORK}/conflict"
[[ -e "${FIXTURE}" ]] && { chmod -R u+w "${FIXTURE}"; rm -rf "${FIXTURE}"; }
cp -a "${PRODUCTION}" "${FIXTURE}"
pass "a byte copy of production was taken, correction and all"
FIXTURE_ADMIN_BEFORE="$(admin_names "${FIXTURE}")"
FIXTURE_COUNTER_BEFORE="$(cat "${FIXTURE}/execution/cadm-counter")"

if ( cd "${INSTALLED}" && python3 - "${FIXTURE}" <<'CONFLICTPY'
import os
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import provenance

# G11-BC-AJ. THE CALL IS BUILT FROM THE INSTALLED SIGNATURE, not from a
# generation this suite assumes. Generation 22 adds a REQUIRED
# `actual_occurrence_at`; a call that hard-codes Generation 21's argument list
# would start failing the moment the operator installs it, which is the staleness
# this checkpoint exists to end. The occurrence is the incident's own instant --
# the rehearsal harness ran at 18:54:33 on 2026-09-20 -- and it is passed only
# where the released verb accepts it.
def call_kwargs(provenance, **kwargs):
    import inspect
    accepted = inspect.signature(provenance.correct_provenance).parameters
    if "actual_occurrence_at" in accepted:
        kwargs["actual_occurrence_at"] = "2026-09-20T18:54:33-05:00"
    return kwargs

root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    try:
        provenance.correct_provenance(**call_kwargs(
            provenance,
            execution_root=root, subject_cadm="CADM-000001",
            cinv="CINV-000002", disputed_field="actor",
            disputed_value="primary-platform-operator",
            finding=provenance.FINDING_NOT_AUTHORISED,
            actual_initiator=provenance.INITIATOR_UNKNOWN,
            actor="somebody-else", request_id="a-different-request",
            recorded_at="2026-09-22T09:00:00-05:00"))
    except provenance.ProvenanceRefused as error:
        print(f"refused: {error}")
        raise SystemExit(0)
    raise SystemExit(1)
finally:
    root.close()
CONFLICTPY
); then
  pass "a correction of the same claim under different authority is refused"
else
  fail "a conflicting correction was accepted"
fi
# Measured, not named. The next free identity is whatever the counter says, and
# an accepted ceremony may have taken several since this suite was written.
if [[ "$(admin_names "${FIXTURE}")" == "${FIXTURE_ADMIN_BEFORE}" \
   && "$(cat "${FIXTURE}/execution/cadm-counter")" == "${FIXTURE_COUNTER_BEFORE}" ]]; then
  pass "and the refusal allocated nothing: the record set and the counter are where they were"
else
  fail "the refused correction allocated a record: ${FIXTURE_ADMIN_BEFORE}-> $(admin_names "${FIXTURE}"), counter ${FIXTURE_COUNTER_BEFORE} -> $(cat "${FIXTURE}/execution/cadm-counter")"
fi

# An identical repeat resumes rather than writing a second finding. Asked of
# the copy, so the accepted production record is never the thing under test.
if ( cd "${INSTALLED}" && python3 - "${FIXTURE}" <<'RESUMEPY'
import os
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import provenance

# G11-BC-AJ. THE CALL IS BUILT FROM THE INSTALLED SIGNATURE, not from a
# generation this suite assumes. Generation 22 adds a REQUIRED
# `actual_occurrence_at`; a call that hard-codes Generation 21's argument list
# would start failing the moment the operator installs it, which is the staleness
# this checkpoint exists to end. The occurrence is the incident's own instant --
# the rehearsal harness ran at 18:54:33 on 2026-09-20 -- and it is passed only
# where the released verb accepts it.
def call_kwargs(provenance, **kwargs):
    import inspect
    accepted = inspect.signature(provenance.correct_provenance).parameters
    if "actual_occurrence_at" in accepted:
        kwargs["actual_occurrence_at"] = "2026-09-20T18:54:33-05:00"
    return kwargs

root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    outcome = provenance.correct_provenance(**call_kwargs(
        provenance,
        execution_root=root, subject_cadm="CADM-000001", cinv="CINV-000002",
        disputed_field="actor", disputed_value="primary-platform-operator",
        finding=provenance.FINDING_NOT_AUTHORISED,
        actual_initiator=provenance.INITIATOR_UNAUTHORISED_REHEARSAL,
        actor="primary-platform-operator",
        request_id="g11bcy-correct-cadm-000001-attribution",
        recorded_at="2026-09-21T06:42:08-05:00"))
    raise SystemExit(0 if (outcome.resumed and outcome.cadm == "CADM-000002")
                     else 1)
finally:
    root.close()
RESUMEPY
); then
  pass "the identical correction resumes and reports the record already written"
else
  fail "the identical repeat did not resume"
fi
if [[ "$(cat "${FIXTURE}/execution/cadm-counter")" == "${FIXTURE_COUNTER_BEFORE}" \
   && "$(admin_names "${FIXTURE}")" == "${FIXTURE_ADMIN_BEFORE}" ]]; then
  pass "and it allocated no identity: the counter is still ${FIXTURE_COUNTER_BEFORE%$'\n'}"
else
  fail "the resume spent a CADM: counter ${FIXTURE_COUNTER_BEFORE} -> $(cat "${FIXTURE}/execution/cadm-counter")"
fi

# ===========================================================================
# 3. Production, after everything
# ===========================================================================

printf -- '\n--- production untouched ---\n'
if [[ "$(find "${INSTALLED}" -type f -name '*.py' -print0 | sort -z \
         | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" == "${LIBRARY_BEFORE}" ]]; then
  pass "the installed library is byte-identical: this suite published nothing"
else
  fail "THE INSTALLED LIBRARY CHANGED"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical: ${PRODUCTION_BEFORE}"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
if [[ "$(sha256sum "${PRODUCTION}/execution/admin-records/CADM-000002/provenance-correction" | cut -d' ' -f1)" \
      == "47b977d83b164ee9056527d99ec40d995b8e9b26e4b63b992df1ac8da8b0e58e" ]]; then
  pass "the accepted correction is byte-identical: this run did not touch it"
else
  fail "PRODUCTION'S CORRECTION RECORD CHANGED"
fi
# "No CADM-000003" was the right assertion until the operator concluded
# CINV-000003 and the 2026-09-24 escape wrote CADM-000004 -- neither of which
# this suite has anything to do with. What must still be true is that THIS RUN
# created nothing, so the record set and the counter are compared against what
# this run found, and the subject's own records stay pinned by content above.
if [[ "$(admin_names "${PRODUCTION}")" == "${ADMIN_BEFORE}" \
   && "$(cat "${PRODUCTION}/execution/cadm-counter")" == "${CADM_COUNTER_BEFORE}" ]]; then
  pass "and no further administrative record was created: production still holds ${ADMIN_BEFORE}"
else
  fail "A PRODUCTION ADMINISTRATIVE RECORD WAS CREATED: ${ADMIN_BEFORE}-> $(admin_names "${PRODUCTION}")"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CADM-000001 correction rehearsal passed.\n'
else
  printf 'CADM-000001 correction rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
