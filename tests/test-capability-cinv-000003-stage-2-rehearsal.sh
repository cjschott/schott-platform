#!/usr/bin/env bash
set -Eeuo pipefail

# The CINV-000003 Stage 2 ceremony, rehearsed.
#
# HOST-ONLY. It reads the installed Generation-20 runtime and the governed
# stores. See tests/host-only.manifest.
#
# WHAT IS REHEARSED, AND WHAT DELIBERATELY IS NOT
# ===============================================
# BLOCK B -- the gates -- is run WHOLE against fixtures. Every root it reads is
# a variable this suite substitutes, and it writes nothing, so a substitution
# there is sound.
#
# BLOCK C IS NEVER RUN. `authorise-launch` COMPILES IN its runtime, execution
# and handoff roots and takes no `--store-root`: substituting paths in that
# block would redirect its post-checks and would NOT redirect its mutation.
# That is the 2026-09-20 incident exactly, and this suite does not repeat it.
# Instead:
#
#   * the EFFECT of BLOCK C is rehearsed at the API, by calling
#     `launch.authorise_launch` with roots passed explicitly, against a byte
#     copy of production;
#   * the CHECKS in BLOCK C are extracted and run as predicates over stores --
#     the real rehearsed one, and sabotaged ones -- after asserting that the
#     extracted text contains no mutation;
#   * the suite asserts the production aggregate is byte-identical at the end,
#     measured rather than intended.
#
# STAGE 2 AT ONE FREE SLOT IS THE POINT. `capacity.reserve` refuses only when
# the held count REACHES MAXIMUM_SLOTS. Held is 1 of 2, so Stage 2 is admitted
# without reclaiming CINV-000001, and the rehearsal proves that rather than
# asserting it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python \
                   /etc/kyri/backing-store.json /var/lib/kyri/fabric \
                   /var/lib/kyri/implementation-authority \
                   /data/kyri/work/g11bcn/third-invoke.json

CEREMONY="${ROOT}/provisioning/execution/g11-bc-z-cinv-000003-stage-2-ceremony.txt"
INSTALLED=/usr/lib/kyri/python                    # prod-path-reference
PRODUCTION=/data/kyri/capability-runtime          # prod-path-reference
PRODUCTION_FABRIC=/var/lib/kyri/fabric            # prod-path-reference
PRODUCTION_HANDOFF=/data/kyri/capability-handoff  # prod-path-reference
AUTHORITY=/var/lib/kyri/implementation-authority  # prod-path-reference
PAYLOAD=/data/kyri/work/g11bcn/third-invoke.json  # prod-path-reference

TARGET=CINV-000003
ARTIFACT_DIGEST=6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
PROFILE_DIGEST=f6696e0dac6d70fea602897e70adb746ab9f82ddaf94527f674d677d7ace05ee
COMMITMENT_DIGEST=6d5a8d9249c7c9407145a69b55748136020a1a696c2e167d879864dc2dc86289
PAYLOAD_DIGEST=591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# On /data so a fixture satisfies the same backing-store verification the
# production root satisfies. A fixture the released code would refuse to open
# proves nothing about the released code.
WORK="$(mktemp -d -p /data/kyri g11bcz-rehearsal.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
PRODUCTION_BEFORE="$(aggregate "${PRODUCTION}")"
FABRIC_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"

# ===========================================================================
# 1. The ceremony's shape is the safety property
# ===========================================================================

printf -- '--- the ceremony, as written ---\n'

GATES="${WORK}/gates.sh"
awk "/^bash <<'GATES'\$/{on=1;next} /^GATES\$/{on=0} on" "${CEREMONY}" > "${GATES}"
STAGE2="${WORK}/stage2.sh"
awk "/^bash <<'STAGE2'\$/{on=1;next} /^STAGE2\$/{on=0} on" "${CEREMONY}" > "${STAGE2}"
OBSERVE="${WORK}/observe.sh"
awk "/^bash <<'OBSERVE'\$/{on=1;next} /^OBSERVE\$/{on=0} on" "${CEREMONY}" > "${OBSERVE}"

for block in "${GATES}" "${STAGE2}" "${OBSERVE}"; do
  if [[ -s "${block}" ]]; then
    pass "$(basename "${block}" .sh) extracted whole ($(wc -l < "${block}") lines)"
  else
    fail "$(basename "${block}" .sh) could not be extracted"
    exit 1
  fi
done

# THE ASSERTION THIS SUITE EXISTS FOR. The mutation is in BLOCK C and nowhere
# else, so running BLOCK B against a fixture cannot reach it.
if grep -q 'authorise-launch' "${GATES}"; then
  fail "BLOCK B contains the mutation; a fixture rehearsal of it would hit production"
else
  pass "BLOCK B contains no authorise-launch: the gates cannot mutate anything"
fi
if [[ "$(grep -c 'tools.capability.cli authorise-launch' "${STAGE2}")" == "1" ]]; then
  pass "BLOCK C runs exactly one authorise-launch"
else
  fail "BLOCK C runs $(grep -c 'tools.capability.cli authorise-launch' "${STAGE2}") authorise-launch commands"
fi
if grep -qE '^(RUNTIME|HANDOFF)=/data/kyri/' "${STAGE2}"; then
  pass "BLOCK C names its production roots literally, as the compiled-in command requires"
else
  fail "BLOCK C does not name its roots"
fi
if grep -q 'execute' "${STAGE2}" && ! grep -q 'cli execute' "${STAGE2}"; then
  pass "BLOCK C mentions execute only to forbid it"
else
  fail "BLOCK C may reach capability execute"
fi
# The installed command really does compile its roots in -- the reason BLOCK C
# is unrehearsable is a property of the released code, not an opinion.
if ( cd "${INSTALLED}" && python3 -c '
import sys; sys.path.insert(0, ".")
from tools.capability import cli
verbs = next(a.choices for a in cli.build_parser()._actions if getattr(a, "choices", None))
flags = {o for a in verbs["authorise-launch"]._actions for o in a.option_strings}
raise SystemExit(0 if "--store-root" not in flags else 1)'); then
  pass "the installed authorise-launch takes no --store-root, so it cannot be aimed"
else
  fail "the installed authorise-launch now takes a root; the ceremony should be rehearsable whole"
fi

# ===========================================================================
# 2. The fixture, and BLOCK B against it
# ===========================================================================

printf -- '\n--- the gates, against a fixture ---\n'

build_fixture() {
  local base="$1"
  [[ -e "${base}" ]] && { chmod -R u+w "${base}"; rm -rf "${base}"; }
  mkdir -p "${base}/work"
  cp -a "${PRODUCTION}" "${base}/runtime"
  cp -a "${PRODUCTION_FABRIC}" "${base}/fabric"
  # The handoff copy is deliberately partial: CINV-000002/out is owned by the
  # execution identity and unreadable here. Stage 2 touches only CINV-000003's
  # handoff, so what matters is that the target is absent, which it is.
  mkdir -p "${base}/handoff"
  cp -a "${PRODUCTION}/staging" "${base}/staging" 2>/dev/null || true
  cp "${PAYLOAD}" "${base}/work/third-invoke.json"
  chmod 0600 "${base}/work/third-invoke.json"
  printf 'stage-2-observation\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\nno-target-container kyri-%s\n' \
    "${TARGET}" > "${base}/work/witness"
  chmod 0600 "${base}/work/witness"
}

render_gates() {
  local base="$1" out="$2"
  sed \
    -e "s#^RUNTIME=/data/kyri/capability-runtime\$#RUNTIME=${base}/runtime#" \
    -e "s#^FABRIC=/var/lib/kyri/fabric\$#FABRIC=${base}/fabric#" \
    -e "s#^WITNESS=/data/kyri/work/g11bcz-stage-2-witness\$#WITNESS=${base}/work/witness#" \
    -e "s#^PAYLOAD_ROOT=/data/kyri/work/g11bcn\$#PAYLOAD_ROOT=${base}/work#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${base}/runtime")#" \
    -e "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${base}/fabric")#" \
    "${GATES}" > "${out}"
}

FIX="${WORK}/fix"
build_fixture "${FIX}"
rendered="${WORK}/rendered-gates.sh"
render_gates "${FIX}" "${rendered}"

# The staged path is named inside the invocation record, so the fixture's own
# copy is what the gate must find. Point the rendered STAGED at it.
sed -i "s#^STAGED=.*#STAGED=\"${FIX}/runtime/staging/tree-sha256-${ARTIFACT_DIGEST}\"#" "${rendered}"
sed -i "s#grep -q \"^staged_path: \${STAGED}\\\\\$\"#grep -q \"^staged_path: /data/kyri/capability-runtime/staging/tree-sha256-${ARTIFACT_DIGEST}\\\\\$\"#" "${rendered}"

# The exact production values, not a prefix: the fixture itself lives under
# /data, so a prefix match would call every substitution a failure.
if grep -qE "^(RUNTIME=${PRODUCTION}|FABRIC=${PRODUCTION_FABRIC}|WITNESS=/data/kyri/work/|PAYLOAD_ROOT=/data/kyri/work/g11bcn)\$" "${rendered}"; then
  fail "a production root survived the substitution"
else
  pass "every root BLOCK B writes against or measures was substituted"
fi
# Trust and the installed library are deliberately NOT substituted: the block
# only reads them, and the installed library is the authority under test.
if grep -q '^TRUST=/var/lib/kyri/trust$' "${rendered}" \
   && grep -q '^INSTALLED=/usr/lib/kyri/python$' "${rendered}"; then
  pass "Trust and the installed library still point at the real ones, which the block only reads"
else
  fail "Trust or the installed library was substituted away; the rehearsal would prove less"
fi

out="${WORK}/gates.out"; status=0
( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
if (( status == 0 )); then
  pass "BLOCK B passes against an unmodified fixture"
else
  fail "BLOCK B refused a clean fixture: $(tail -3 "${out}" | tr '\n' ' ')"
fi

for expected in \
  'ok  observation' \
  'ok  current authority supported at' \
  'ok  CROUTE-0006 is the route head, CADV-000007 is unsuperseded, CSEL-000004 still selects CINST-000006' \
  'ok  sequences 3/1, cadm 000002, cmut 000000000007, 5 transitions, no CRES-000002' \
  'ok  payload, staged tree and the three prepared digests all as reviewed' \
  'ok  CINV-000001 launch_authorized (holds the one slot), CINV-000002 abandoned (holds none)' \
  'ok  occupancy 1 of 2; 1 free, and Stage 2 needs 1' \
  'ALL GATES PASSED.'
do
  if grep -qF "${expected}" "${out}"; then
    pass "BLOCK B reports: ${expected}"
  else
    fail "BLOCK B did not report: ${expected}"
  fi
done

# ===========================================================================
# 3. The effect of BLOCK C, rehearsed at the API
# ===========================================================================

printf -- '\n--- Stage 2, at the API, against a byte copy ---\n'

api_stage2() {
  local base="$1"
  ( cd "${INSTALLED}" && python3 - "${base}" "${AUTHORITY}" "${PAYLOAD}" <<'STAGE2PY'
import json
import os
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.store import CapabilityStore
from tools.capability.execution import capacity as cap
from tools.capability.execution import state as sm
from tools.capability.execution.launch import authorise_launch

base, authority_root, payload_path = sys.argv[1:4]
runtime = os.path.join(base, "runtime")
store = CapabilityStore(runtime, expected_uid=1000, expected_gid=1000)
execution_root = cli._anchored(os.path.join(runtime, "execution"))
handoff_root = cli._anchored(os.path.join(base, "handoff"))


def occupancy():
    states = sm.all_states(execution_root)
    return sum(1 for v in states.values() if v in cap.slot_holding_states())


try:
    record = store.read_record("capability-invocation", "CINV-000003")
    # The record names the PRODUCTION staged path. The API takes the tree as a
    # descriptor, so the fixture's own copy is opened and handed over -- which
    # is the whole reason this rehearsal is sound where a text substitution
    # would not be.
    staged = record["staged_path"].replace("/data/kyri/capability-runtime", runtime)
    before = occupancy()
    payload = os.open(payload_path, os.O_RDONLY)
    artefact = os.open(staged, os.O_RDONLY | os.O_DIRECTORY)
    authority = os.open(authority_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        ready = authorise_launch(
            store=store, execution_root=execution_root,
            handoff_root=handoff_root, authority_fd=authority,
            cinv="CINV-000003", cimp="CIMP-000001", payload_fd=payload,
            package_entrypoint="main.py", artefact_fd=artefact)
    finally:
        os.close(payload); os.close(artefact); os.close(authority)
    print(json.dumps({
        "cinv": ready.cinv, "cimp": ready.cimp,
        "lifecycle_state": "launch_authorized",
        "profile_digest": ready.profile_digest,
        "commitment_digest": ready.commitment_digest,
        "package_digest": ready.handoff.package_digest,
        "payload_digest": ready.handoff.payload_digest,
        "entrypoint": ready.handoff.entrypoint,
        "entry_count": ready.handoff.entry_count,
        "handoff_published": True,
        "resumed": ready.resumed,
        "occupancy_before": before,
        "occupancy_after": occupancy()}, indent=2))
finally:
    execution_root.close(); handoff_root.close()
STAGE2PY
  )
}

build_fixture "${FIX}"
cp -a "${FIX}/runtime" "${FIX}/runtime.orig"
result="${WORK}/stage2.json"; status=0
api_stage2 "${FIX}" > "${result}" 2>&1 || status=$?
if (( status == 0 )); then
  pass "Stage 2 runs to completion against the byte copy"
else
  fail "Stage 2 failed: $(tail -3 "${result}" | tr '\n' ' ')"
  cat "${result}" >&2
fi

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${result}" "$1"; }
for key_want in \
  "cinv=${TARGET}" "cimp=CIMP-000001" "lifecycle_state=launch_authorized" \
  "profile_digest=${PROFILE_DIGEST}" "commitment_digest=${COMMITMENT_DIGEST}" \
  "package_digest=${ARTIFACT_DIGEST}" "payload_digest=${PAYLOAD_DIGEST}" \
  "entrypoint=main.py" "entry_count=1" "resumed=False" \
  "occupancy_before=1" "occupancy_after=2"
do
  key="${key_want%%=*}"; want="${key_want#*=}"
  got="$(field "${key}" 2>/dev/null || echo '<unreadable>')"
  if [[ "${got}" == "${want}" ]]; then
    pass "verdict ${key} = ${got}"
  else
    fail "verdict ${key} is ${got}, expected ${want}"
  fi
done

# ===========================================================================
# 4. The mutation, measured by content
# ===========================================================================

printf -- '\n--- the mutation, measured ---\n'

R="${FIX}/runtime"
O="${FIX}/runtime.orig"

for path in "execution/${TARGET}/launch-authorisation" \
            "execution/transitions/${TARGET}.000001" \
            "execution/transitions/${TARGET}.000002" \
            "execution/mutations/CMUT-000000000008" \
            "execution/mutations/CMUT-000000000009" \
            "execution/mutations/CMUT-000000000010"; do
  if [[ -e "${R}/${path}" ]]; then
    pass "Stage 2 wrote ${path}"
  else
    fail "Stage 2 did not write ${path}"
  fi
done

if [[ "$(cat "${R}/execution/cmut-counter")" == "000000000010" ]]; then
  pass "cmut-counter 000000000007 -> 000000000010: exactly three journalled mutations"
else
  fail "cmut-counter is $(cat "${R}/execution/cmut-counter")"
fi
for sequence in capability-invocation capability-result; do
  if [[ "$(cat "${R}/sequences/${sequence}.seq")" == "$(cat "${O}/sequences/${sequence}.seq")" ]]; then
    pass "${sequence}.seq is unchanged: Stage 2 allocates no identity"
  else
    fail "${sequence}.seq moved"
  fi
done
if [[ "$(cat "${R}/execution/cadm-counter")" == "000002" ]]; then
  pass "cadm-counter is unchanged: Stage 2 is not an administrative action"
else
  fail "cadm-counter moved"
fi
if diff -r "${O}/capability-invocations" "${R}/capability-invocations" >/dev/null \
   && diff -r "${O}/capability-results" "${R}/capability-results" >/dev/null; then
  pass "every CINV and CRES is byte-identical"
else
  fail "an immutable record changed"
fi
if diff -r "${O}/execution/admin-records" "${R}/execution/admin-records" >/dev/null; then
  pass "CADM-000001 and CADM-000002 are byte-identical"
else
  fail "an administrative record changed"
fi
if [[ ! -e "${R}/capability-results/CRES-000002.yaml" ]]; then
  pass "no result was written: Stage 2 runs nothing"
else
  fail "A RESULT WAS WRITTEN"
fi
for cinv in CINV-000001 CINV-000002; do
  if diff -r "${O}/execution/transitions" "${R}/execution/transitions" 2>/dev/null \
     | grep -q "${cinv}"; then
    fail "${cinv}'s transitions changed"
  else
    pass "${cinv}'s lifecycle is untouched"
  fi
done

# The published handoff, by content and by mode.
printf -- '\n--- the published handoff ---\n'
H="${FIX}/handoff/${TARGET}"
if [[ "$(sha256sum "${H}/payload" | cut -d' ' -f1)" == "${PAYLOAD_DIGEST}" ]]; then
  pass "the handoff payload is the canonical payload the record committed to"
else
  fail "the handoff payload digest is wrong"
fi
if [[ "$(sha256sum "${H}/profile" | cut -d' ' -f1)" == "${PROFILE_DIGEST}" ]]; then
  pass "the handoff profile is the authorised profile"
else
  fail "the handoff profile digest is wrong"
fi
for entry in "${H}:555" "${H}/package:555" "${H}/out:700" "${H}/payload:444" "${H}/profile:444"; do
  path="${entry%:*}"; want="${entry##*:}"
  got="$(stat -c '%a' "${path}" 2>/dev/null || echo absent)"
  if [[ "${got}" == "${want}" ]]; then
    pass "$(basename "${path}") is mode ${got}"
  else
    fail "$(basename "${path}") is mode ${got}, expected ${want}"
  fi
done

# The whole mutation, by reconstruction rather than by enumeration.
recon="${WORK}/recon"
[[ -e "${recon}" ]] && { chmod -R u+w "${recon}"; rm -rf "${recon}"; }
cp -a "${R}" "${recon}"; chmod -R u+w "${recon}"
rm -rf "${recon}/execution/${TARGET}" "${recon}/execution/locks/${TARGET}"
rm -f "${recon}/execution/transitions/${TARGET}.000001" \
      "${recon}/execution/transitions/${TARGET}.000002"
rm -rf "${recon}/execution/mutations/CMUT-000000000008" \
       "${recon}/execution/mutations/CMUT-000000000009" \
       "${recon}/execution/mutations/CMUT-000000000010"
printf '000000000007\n' > "${recon}/execution/cmut-counter"
a="$(find "${recon}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${recon}#X#" | sha256sum)"
b="$(find "${O}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${O}#X#" | sha256sum)"
if [[ "${a}" == "${b}" ]]; then
  pass "removing the execution state, two transitions and three CMUTs reproduces the pre-Stage-2 store exactly"
else
  fail "the mutation was not exactly that set"
fi

# ===========================================================================
# 5. Idempotency, and the capacity ceiling
# ===========================================================================

printf -- '\n--- running it twice ---\n'
before_counter="$(cat "${R}/execution/cmut-counter")"
again="${WORK}/again.json"; status=0
api_stage2 "${FIX}" > "${again}" 2>&1 || status=$?
if (( status == 0 )) \
   && [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["resumed"])' "${again}")" == "True" ]]; then
  pass "a second run resumes rather than re-authorising"
else
  fail "a second run did not resume: $(tail -2 "${again}" | tr '\n' ' ')"
fi
if [[ "$(cat "${R}/execution/cmut-counter")" == "${before_counter}" ]]; then
  pass "the repeat journalled no further mutation"
else
  fail "the repeat spent a CMUT"
fi

printf -- '\n--- the ceiling still holds ---\n'
ceiling="$( cd "${INSTALLED}" && python3 - "${FIX}/runtime" <<'CEILPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import capacity as cap
from tools.capability.execution import state as sm
root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    held = sum(1 for v in sm.all_states(root).values() if v in cap.slot_holding_states())
    print(f"held {held}")
    try:
        cap.reserve(root, "CINV-000099")
    except cap.CapacityExhausted as error:
        print(f"refused {error}")
    else:
        print("accepted")
finally:
    root.close()
CEILPY
)"
if [[ "${ceiling}" == *"held 2"* && "${ceiling}" == *"refused all 2 execution slots are held"* ]]; then
  pass "after Stage 2 occupancy is 2 of 2 and a third reservation is refused"
else
  fail "the ceiling did not hold: ${ceiling}"
fi

# ===========================================================================
# 6. The failure matrix
# ===========================================================================
#
# Each case breaks exactly one thing and must refuse FOR ITS OWN REASON. Every
# case also asserts that no execution state was created -- a sabotage that let
# Stage 2 through is a gate that did not hold.

# Sabotages that need more than a one-liner live here, so the matrix stays a
# table of single facts rather than a thicket of nested quoting.
expire_advertisement() {
  chmod u+w "${FIX}/fabric/capability-advertisements/CADV-000007.yaml"
  python3 - "${FIX}/fabric/capability-advertisements/CADV-000007.yaml" <<'EXPIRE'
import sys
path = sys.argv[1]
body = open(path).read().replace("2026-09-23T06:00:00-05:00",
                                 "2026-09-19T06:00:00-05:00")
open(path, "w").write(body)
EXPIRE
}

supersede_route() {
  local routes="${FIX}/fabric/capability-routes"
  chmod u+w "${routes}"
  cp "${routes}/CROUTE-0006.yaml" "${routes}/CROUTE-0007.yaml"
  chmod u+w "${routes}/CROUTE-0007.yaml"
  python3 - "${routes}/CROUTE-0007.yaml" <<'ROUTE'
import sys
path = sys.argv[1]
body = open(path).read()
body = body.replace("route_id: CROUTE-0006", "route_id: CROUTE-0007")
body = body.replace("supersedes: CROUTE-0005", "supersedes: CROUTE-0006")
open(path, "w").write(body)
ROUTE
}

change_selection() {
  local selection="${FIX}/fabric/capability-selections/CSEL-000004.yaml"
  chmod u+w "${selection}"
  python3 - "${selection}" <<'SELECT'
import sys
path = sys.argv[1]
body = open(path).read().replace("selected_instance_id: CINST-000006",
                                 "selected_instance_id: CINST-000005")
open(path, "w").write(body)
SELECT
}

# Occupancy without touching the transition COUNT. Deleting the abandonment
# record would change the count and be caught by the gate in front, which would
# make this case a test of that gate instead. Rewriting CINV-000002's last
# transition to `created` -- a state the released vocabulary reaches from
# launch_authorized, and one that holds a slot -- moves occupancy to 2 of 2
# while the journal still holds five records.
hold_second_slot() {
  local transition="${FIX}/runtime/execution/transitions/CINV-000002.000003"
  chmod u+w "${transition}"
  python3 - "${transition}" <<'HOLD'
import sys
path = sys.argv[1]
body = open(path).read().replace('"state":"abandoned"', '"state":"created"')
open(path, "w").write(body)
HOLD
}

corrupt_invocation_record() {
  local record="${FIX}/runtime/capability-invocations/CINV-000003.yaml"
  chmod u+w "${record}"
  printf 'x' >> "${record}"
}

corrupt_staged_entrypoint() {
  local tree="${FIX}/runtime/staging/tree-sha256-${ARTIFACT_DIGEST}"
  chmod u+w "${tree}" "${tree}/main.py"
  printf 'x' >> "${tree}/main.py"
}

printf -- '\n--- fail closed, by gate ---\n'

# name | how the fixture or the rendered gates are broken | expected refusal
SABOTAGE=(
"the installed runtime is not Generation 20|sed -i 's#^check_installed tools/capability/cli.py .*#check_installed tools/capability/cli.py 0000000000000000000000000000000000000000000000000000000000000000#' \"\${rendered}\"|not the reviewed Generation-20"
"the advertisement authority has expired|expire_advertisement; REFABRIC=1|the Fabric authority is not currently valid"
"the route has moved|supersede_route; REFABRIC=1|has been superseded and is no longer the route head"
"the selection no longer selects the instance|change_selection; REFABRIC=1|the Fabric authority is not currently valid"
"the Fabric baseline moved|printf 'x' >> \"\${FIX}/fabric/capability-routes/CROUTE-0006.yaml\"|the Fabric has moved"
"the runtime baseline moved|printf 'x' >> \"\${FIX}/runtime/execution/cadm-counter\"|the capability-runtime store has moved"
"CINV-000003 changed|corrupt_invocation_record; RERENDER=1|CINV-000003.yaml is"
"the invocation sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-invocation.seq\"; RERENDER=1|capability-invocation.seq is not 3"
"the result sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-result.seq\"; RERENDER=1|capability-result.seq is not 1"
"a result appeared|cp \"\${FIX}/runtime/capability-results/CRES-000001.yaml\" \"\${FIX}/runtime/capability-results/CRES-000002.yaml\"; RERENDER=1|CRES-000002 exists"
"execution state already exists|mkdir -p \"\${FIX}/runtime/execution/CINV-000003\"; RERENDER=1|already has execution state"
"occupancy is not 1 of 2|hold_second_slot; RERENDER=1|the lifecycle is"
"the staged tree changed|corrupt_staged_entrypoint; RERENDER=1|main.py is"
"the payload changed|printf 'x' >> \"\${FIX}/work/third-invoke.json\"|third-invoke.json is"
"the execution image is absent|printf 'stage-2-observation\\nno-target-container kyri-CINV-000003\\n' > \"\${FIX}/work/witness\"|does not record the expected execution image"
"a target container exists|printf 'stage-2-observation\\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\\n' > \"\${FIX}/work/witness\"|does not record the absence of a kyri-CINV-000003 container"
"the witness is absent|rm -f \"\${FIX}/work/witness\"|run BLOCK A first"
"the witness is stale|touch -d '2 hours ago' \"\${FIX}/work/witness\"|re-run BLOCK A"
"the witness is dated in the future|touch -d '1 hour' \"\${FIX}/work/witness\"|dated in the future"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name breakage refusal <<<"${case}"
  build_fixture "${FIX}"
  render_gates "${FIX}" "${rendered}"
  sed -i "s#^STAGED=.*#STAGED=\"${FIX}/runtime/staging/tree-sha256-${ARTIFACT_DIGEST}\"#" "${rendered}"
  sed -i "s#grep -q \"^staged_path: \${STAGED}\\\\\$\"#grep -q \"^staged_path: /data/kyri/capability-runtime/staging/tree-sha256-${ARTIFACT_DIGEST}\\\\\$\"#" "${rendered}"

  RERENDER=0
  REFABRIC=0
  eval "${breakage}"
  # A sabotage that changes the store on purpose must not be caught by the
  # aggregate gate standing in front of the gate under test: the baseline is
  # re-pinned so the intended gate is the one that judges.
  if (( RERENDER == 1 )); then
    sed -i "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${FIX}/runtime")#" "${rendered}"
  fi
  # The same, for the Fabric: the aggregate gate stands in front of the current-
  # authority gate, so a case about authority re-pins the aggregate and a case
  # about the aggregate does not.
  if (( REFABRIC == 1 )); then
    sed -i "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${FIX}/fabric")#" "${rendered}"
  fi

  out="${WORK}/sabotage.out"; status=0
  ( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?

  if (( status != 0 )); then
    pass "${name}: BLOCK B exits nonzero"
  else
    fail "${name}: BLOCK B exited 0"
  fi
  if grep -qF -- "${refusal}" "${out}"; then
    pass "${name}: refuses for its own reason (${refusal})"
  else
    fail "${name}: refused, but not for its own reason: $(grep -m1 -E 'REFUSE' "${out}" || echo 'no refusal line')"
  fi
  if grep -q 'Traceback (most recent call last)' "${out}"; then
    fail "${name}: something crashed instead of judging its input"
  else
    pass "${name}: no traceback"
  fi
done

# ---- operation-level refusals, at the API --------------------------------
#
# These are not gates in the ceremony: they are the released bridge's own,
# and they are exercised where they live.

printf -- '\n--- fail closed, in the operation ---\n'

build_fixture "${FIX}"
wrong_payload="${WORK}/wrong-payload.json"
printf '{"operation":"verify-execution-boundary","arguments":{"count":2}}\n' > "${wrong_payload}"
if ( cd "${INSTALLED}" && PAYLOAD_OVERRIDE="${wrong_payload}" python3 - "${FIX}" "${AUTHORITY}" "${wrong_payload}" <<'WRONGPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.store import CapabilityStore
from tools.capability.execution.launch import authorise_launch, LaunchRefused

base, authority_root, payload_path = sys.argv[1:4]
runtime = os.path.join(base, "runtime")
store = CapabilityStore(runtime, expected_uid=1000, expected_gid=1000)
er = cli._anchored(os.path.join(runtime, "execution"))
hr = cli._anchored(os.path.join(base, "handoff"))
try:
    record = store.read_record("capability-invocation", "CINV-000003")
    staged = record["staged_path"].replace("/data/kyri/capability-runtime", runtime)
    payload = os.open(payload_path, os.O_RDONLY)
    artefact = os.open(staged, os.O_RDONLY | os.O_DIRECTORY)
    authority = os.open(authority_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        authorise_launch(store=store, execution_root=er, handoff_root=hr,
                         authority_fd=authority, cinv="CINV-000003",
                         cimp="CIMP-000001", payload_fd=payload,
                         package_entrypoint="main.py", artefact_fd=artefact)
    except LaunchRefused as error:
        print(f"refused: {error}")
        raise SystemExit(0)
    finally:
        os.close(payload); os.close(artefact); os.close(authority)
    raise SystemExit(1)
finally:
    er.close(); hr.close()
WRONGPY
); then
  pass "a payload that is not the prepared one is refused by the bridge"
else
  fail "a different payload was accepted"
fi
if [[ ! -e "${FIX}/runtime/execution/${TARGET}" ]]; then
  pass "and the refusal created no execution state"
else
  fail "the refused run still reserved a slot"
fi

# Capacity exhausted: both slots genuinely held.
build_fixture "${FIX}"
exhausted="$( cd "${INSTALLED}" && python3 - "${FIX}/runtime" <<'EXHAUSTPY'
import os, sys
sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import capacity as cap
from tools.capability.execution import state as sm
from tools.capability.execution.types import LifecycleState
root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    # A second holder, so the ceiling is genuinely reached rather than simulated.
    cap.reserve(root, "CINV-000098")
    held = sum(1 for v in sm.all_states(root).values() if v in cap.slot_holding_states())
    try:
        cap.reserve(root, "CINV-000003")
    except cap.CapacityExhausted as error:
        print(f"held {held} refused {error}")
    else:
        print(f"held {held} accepted")
finally:
    root.close()
EXHAUSTPY
)"
if [[ "${exhausted}" == *"held 2 refused all 2 execution slots are held"* ]]; then
  pass "with both slots held, Stage 2's reservation is refused as CapacityExhausted"
else
  fail "capacity exhaustion did not refuse: ${exhausted}"
fi

# ---- BLOCK C's own checks, as predicates ---------------------------------
#
# The command cannot be run here, but its post-checks can: they are reads over
# a store and a verdict file. Extracted only after asserting the extract holds
# no mutation.

printf -- '\n--- BLOCK C post-checks, as predicates ---\n'
POST="${WORK}/post.sh"
awk '/^# ---- THE VERDICT/{on=1} on' "${STAGE2}" > "${POST}"
if grep -q 'authorise-launch' "${POST}"; then
  fail "the extracted post-checks contain the mutation; they may not be run"
else
  pass "the extracted post-checks contain no mutation, so running them is a read"
fi

build_fixture "${FIX}"
api_stage2 "${FIX}" > "${result}" 2>&1
run_post() {
  local base="$1" verdict="$2"
  local rendered_post="${WORK}/rendered-post.sh"
  { printf 'set -Eeuo pipefail\nRUNTIME=%s/runtime\nHANDOFF=%s/handoff\nTARGET=%s\nOUT=%s\n' \
      "${base}" "${base}" "${TARGET}" "${verdict}"
    cat "${POST}"; } > "${rendered_post}"
  ( cd "${ROOT}" && bash "${rendered_post}" ) > "${WORK}/post.out" 2>&1
}
if run_post "${FIX}" "${result}"; then
  pass "BLOCK C's post-checks accept the store Stage 2 actually produced"
else
  fail "BLOCK C's post-checks rejected a correct Stage 2: $(tail -3 "${WORK}/post.out" | tr '\n' ' ')"
fi

# A wrong verdict must be caught.
python3 -c '
import json, sys
body = json.load(open(sys.argv[1]))
body["profile_digest"] = "0" * 64
json.dump(body, open(sys.argv[2], "w"))' "${result}" "${WORK}/wrong-verdict.json"
if run_post "${FIX}" "${WORK}/wrong-verdict.json"; then
  fail "a wrong profile digest was accepted"
else
  if grep -q 'STOP: profile_digest' "${WORK}/post.out"; then
    pass "a wrong verdict field is caught, naming the field"
  else
    fail "the wrong verdict refused for another reason"
  fi
fi

# A Stage-3 effect must be caught.
cp "${FIX}/runtime/capability-results/CRES-000001.yaml" \
   "${FIX}/runtime/capability-results/CRES-000002.yaml"
if run_post "${FIX}" "${result}"; then
  fail "a fabricated result was not caught"
else
  if grep -q 'A RESULT WAS WRITTEN' "${WORK}/post.out"; then
    pass "an unexpected Stage-3 effect is caught: a result may not exist after Stage 2"
  else
    fail "the fabricated result refused for another reason: $(grep -m1 STOP "${WORK}/post.out")"
  fi
fi

# ===========================================================================
# 7. Production, after everything
# ===========================================================================

printf -- '\n--- production untouched ---\n'
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical: ${PRODUCTION_BEFORE}"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
if [[ "$(aggregate "${PRODUCTION_FABRIC}")" == "${FABRIC_BEFORE}" ]]; then
  pass "the production Fabric is byte-identical"
else
  fail "THE PRODUCTION FABRIC CHANGED"
fi
if [[ ! -e "${PRODUCTION}/execution/${TARGET}" ]]; then
  pass "${TARGET} still has no execution state in production"
else
  fail "${TARGET} GAINED EXECUTION STATE IN PRODUCTION"
fi
if [[ ! -e "${PRODUCTION_HANDOFF}/${TARGET}" ]]; then
  pass "no handoff was published for ${TARGET} in production"
else
  fail "A PRODUCTION HANDOFF WAS PUBLISHED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage 2 rehearsal passed.\n'
else
  printf 'CINV-000003 Stage 2 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
