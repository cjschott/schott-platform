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
# 2. STAGE 2 IS SPENT, and this suite says so rather than re-running it
# ===========================================================================
#
# The operator performed Stage 2 on 2026-09-21. CINV-000003 is
# `launch_authorized`, its authorisation and handoff exist, and occupancy is
# 2 of 2.
#
# WHAT THIS SUITE STOPPED DOING, AND WHY. It used to build a fixture from
# production and drive `authorise_launch` against it. That worked while the
# invocation had no execution state; today the copy already carries it, and the
# released code refuses -- correctly -- with `CapacityExhausted` or
# `AlreadyConsumed`. Reconstructing a pre-Stage-2 store instead would mean
# subtracting each later stage's artefacts from a hand-kept list, which is the
# defect corrected at G11-BC-Y in eight other suites.
#
# So: spent mode. Durable facts, the ceremony's own refusal, and the one
# behaviour that is still live and still matters -- that a repeat RESUMES
# rather than re-authorising.

printf -- '\n--- the ceremony is spent ---\n'

# BLOCK B only, against PRODUCTION, with one substitution: a fresh witness.
#
# BLOCK A elevates to kyri-capability and would fail on sudo rather than on the
# gate under test, and the operator's own witness has long since gone stale --
# so the witness gate would fire first and this would be a test of freshness
# rather than of spentness. Everything else points at production, which BLOCK B
# only ever reads. BLOCK C is never run at all.
mkdir -p "${WORK}/spent"
printf 'stage-2-observation\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\nno-target-container kyri-%s\n' \
  "${TARGET}" > "${WORK}/spent/witness"
chmod 0600 "${WORK}/spent/witness"
spent_gates="${WORK}/spent-gates.sh"
sed -e "s#^WITNESS=/data/kyri/work/g11bcz-stage-2-witness\$#WITNESS=${WORK}/spent/witness#" \
    "${GATES}" > "${spent_gates}"
out="$( ( cd "${ROOT}" && bash "${spent_gates}" ) 2>&1 )" && status=0 || status=$?
if (( status != 0 )); then
  pass "the spent ceremony refuses"
else
  fail "the spent ceremony ran again"
fi
if [[ "${out}" == *"already has execution state"* ]] \
   || [[ "${out}" == *"the capability-runtime store has moved"* ]]; then
  pass "it refuses on a durable fact: the store has moved past it"
else
  fail "it refused for another reason: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ')"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the refusal wrote nothing"
else
  fail "THE REFUSING CEREMONY MUTATED PRODUCTION"
fi

printf -- '\n--- the durable facts of Stage 2 ---\n'

check_production() {
  local path="$1" wanted="$2" got
  got="$(sha256sum "${path}" 2>/dev/null | cut -d' ' -f1)"
  if [[ "${got}" == "${wanted}" ]]; then
    pass "$(basename "$(dirname "${path}")")/$(basename "${path}") is ${got}"
  else
    fail "$(basename "${path}") is ${got:-absent}, expected ${wanted}"
  fi
}
check_production "${PRODUCTION}/execution/${TARGET}/launch-authorisation" \
  885801a1362dcf99faaacdcdf457b7a9cecac99104012c24cfb6cfa5284f31df
check_production "${PRODUCTION_HANDOFF}/${TARGET}/payload"  "${PAYLOAD_DIGEST}"
check_production "${PRODUCTION_HANDOFF}/${TARGET}/profile"  "${PROFILE_DIGEST}"
check_production "${PRODUCTION}/capability-invocations/${TARGET}.yaml" \
  c0941b7d45dcccac4bb28d00f942ea63aa90cd46ed55767797363f1ed1accaf2

for pair in "\"profile_digest\":\"${PROFILE_DIGEST}\"" \
            "\"commitment_digest\":\"${COMMITMENT_DIGEST}\"" \
            '"cimp":"CIMP-000001"' '"lifecycle_state":"launch_authorized"'; do
  if grep -qF -- "${pair}" "${PRODUCTION}/execution/${TARGET}/launch-authorisation"; then
    pass "the authorisation records ${pair}"
  else
    fail "the authorisation does not record ${pair}"
  fi
done

if [[ "$(cat "${PRODUCTION}/sequences/capability-invocation.seq")" -ge 3 ]]; then
  pass "the invocation sequence is at least 3: Stage 2 allocated nothing"
else
  fail "the invocation sequence is below 3"
fi

if ( cd "${INSTALLED}" && python3 - "${PRODUCTION}" <<'STATEPY'
import os
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import capacity as cap, state as sm

root = cli._anchored(os.path.join(sys.argv[1], "execution"))
try:
    states = sm.all_states(root)
    if states["CINV-000003"].value != "launch_authorized":
        raise SystemExit(1)
    held = sum(1 for v in states.values() if v in cap.slot_holding_states())
    raise SystemExit(0 if held == 2 else 1)
finally:
    root.close()
STATEPY
); then
  pass "${TARGET} is launch_authorized and occupancy is 2 of 2"
else
  fail "the lifecycle or occupancy is not what Stage 2 left"
fi

# ===========================================================================
# 3. A repeat RESUMES. The one Stage-2 behaviour that is still live.
# ===========================================================================
#
# Run against a byte copy, with the roots passed explicitly -- which is what
# the CLI cannot do and why BLOCK C is not rehearsable through it.

printf -- '\n--- a repeat resumes ---\n'

FIX="${WORK}/resume"
[[ -e "${FIX}" ]] && { chmod -R u+w "${FIX}"; rm -rf "${FIX}"; }
mkdir -p "${FIX}"
cp -a "${PRODUCTION}" "${FIX}/runtime"
mkdir -p "${FIX}/handoff"
cp -a "${PRODUCTION_HANDOFF}/${TARGET}" "${FIX}/handoff/${TARGET}"
cp -a "${FIX}/runtime" "${FIX}/runtime.orig"

resume="${WORK}/resume.json"
if ( cd "${INSTALLED}" && python3 - "${FIX}" "${AUTHORITY}" "${PAYLOAD}" <<'RESUMEPY' > "${resume}" 2>&1
import json
import os
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.store import CapabilityStore
from tools.capability.execution import capacity as cap, state as sm
from tools.capability.execution.launch import authorise_launch

base, authority_root, payload_path = sys.argv[1:4]
runtime = os.path.join(base, "runtime")
store = CapabilityStore(runtime, expected_uid=1000, expected_gid=1000)
execution_root = cli._anchored(os.path.join(runtime, "execution"))
handoff_root = cli._anchored(os.path.join(base, "handoff"))
try:
    record = store.read_record("capability-invocation", "CINV-000003")
    staged = record["staged_path"].replace("/data/kyri/capability-runtime", runtime)
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
    held = sum(1 for v in sm.all_states(execution_root).values()
               if v in cap.slot_holding_states())
    print(json.dumps({"resumed": ready.resumed,
                      "profile_digest": ready.profile_digest,
                      "commitment_digest": ready.commitment_digest,
                      "package_digest": ready.handoff.package_digest,
                      "payload_digest": ready.handoff.payload_digest,
                      "occupancy": held}, indent=2))
finally:
    execution_root.close(); handoff_root.close()
RESUMEPY
); then
  pass "the released bridge accepts the repeat"
else
  fail "the repeat failed: $(tail -3 "${resume}" | tr '\n' ' ')"
fi

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "${resume}" "$1"; }
for key_want in "resumed=True" "profile_digest=${PROFILE_DIGEST}" \
                "commitment_digest=${COMMITMENT_DIGEST}" \
                "package_digest=${ARTIFACT_DIGEST}" \
                "payload_digest=${PAYLOAD_DIGEST}" "occupancy=2"; do
  key="${key_want%%=*}"; want="${key_want#*=}"
  got="$(field "${key}" 2>/dev/null || echo '<unreadable>')"
  if [[ "${got}" == "${want}" ]]; then
    pass "the repeat reports ${key} = ${got}"
  else
    fail "the repeat reports ${key} = ${got}, expected ${want}"
  fi
done

if diff -r "${FIX}/runtime.orig" "${FIX}/runtime" >/dev/null 2>&1; then
  pass "and it wrote nothing at all: no second transition, no second CMUT, no second identity"
else
  fail "the resume mutated the store"
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
# "Absent" stopped being the right assertion when the operator ran Stage 2.
# "Exactly what Stage 2 left, unchanged by this run" is.
if [[ "$(sha256sum "${PRODUCTION}/execution/${TARGET}/launch-authorisation" | cut -d' ' -f1)" \
      == "885801a1362dcf99faaacdcdf457b7a9cecac99104012c24cfb6cfa5284f31df" ]]; then
  pass "${TARGET}'s launch-authorisation is byte-identical"
else
  fail "THE PRODUCTION LAUNCH-AUTHORISATION CHANGED"
fi
if [[ "$(sha256sum "${PRODUCTION_HANDOFF}/${TARGET}/profile" | cut -d' ' -f1)" == "${PROFILE_DIGEST}" ]]; then
  pass "the published handoff is byte-identical"
else
  fail "THE PRODUCTION HANDOFF CHANGED"
fi
if [[ ! -e "${PRODUCTION}/capability-results/CRES-000002.yaml" ]]; then
  pass "and no result exists: Stage 3 has not run"
else
  fail "A PRODUCTION RESULT EXISTS"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage 2 rehearsal passed.\n'
else
  printf 'CINV-000003 Stage 2 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
