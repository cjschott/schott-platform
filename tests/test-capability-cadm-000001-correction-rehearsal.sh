#!/usr/bin/env bash
set -Eeuo pipefail

# The CADM-000001 provenance-correction ceremony, rehearsed whole.
#
# HOST-ONLY. It builds a Generation-20 library with the real installer and
# drives the real operator ceremony against a byte copy of the production
# runtime. See tests/host-only.manifest.
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
GEN20_SUITE="${ROOT}/tests/test-capability-execution-generation20-installer.sh"
INSTALLER="${ROOT}/provisioning/execution/install-generation-20.sh"
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
# 1. Against the host as it stands, the ceremony refuses
# ===========================================================================
#
# Generation 20 is not installed yet. G11-BC-W's rule is that an operation runs
# against the runtime that can read what it writes, and this is that rule
# holding for the correction: the ceremony must refuse a Generation-19 host,
# and it must say which property failed.

printf -- '--- the ceremony refuses a host that is not at Generation 20 ---\n'

out="$( ( cd "${ROOT}" && bash "${CEREMONY}" ) 2>&1 )" && status=0 || status=$?
if (( status != 0 )); then
  pass "the ceremony refuses on this host"
else
  fail "the ceremony ran against a Generation-19 host"
fi
if [[ "${out}" == *"not the reviewed Generation-20"* ]] \
   || [[ "${out}" == *"still has no explicit store root"* ]]; then
  pass "it refuses at the installed-generation gate, naming what is wrong"
else
  fail "it refused for another reason: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ')"
fi
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the refusal wrote nothing: production is byte-identical"
else
  fail "THE REFUSING CEREMONY MUTATED PRODUCTION"
fi

# ===========================================================================
# 2. A Generation-20 library, built by the real installer
# ===========================================================================

printf -- '\n--- a Generation-20 library, and a runtime copy ---\n'

FIXTURE="${WORK}/host"
# Reuse the Generation-20 suite's fixture builder rather than a second copy of
# it: a fixture that drifted from the one the installer is tested against would
# be proving something about neither.
build_only() {
  local builder="${WORK}/builder.sh"
  sed -n '/^build_fixture() {/,/^}$/p' "${GEN20_SUITE}" > "${builder}"
  sed -n '/^declared_helper_paths() {/,/^}$/p' "${GEN20_SUITE}" >> "${builder}"
  printf 'set -Eeuo pipefail\nINSTALLED=%s\nbuild_fixture "%s"\n' \
    "${INSTALLED}" "${FIXTURE}" >> "${builder}"
  bash "${builder}"
}
if build_only; then
  pass "the Generation-19 fixture host was built from the installed runtime"
else
  fail "the fixture host could not be built"
  exit 1
fi

if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${INSTALLER}" --install \
     --fixture "${FIXTURE}" ) > "${WORK}/install.log" 2>&1; then
  pass "the real installer published Generation 20 into the fixture"
else
  fail "the fixture installation failed: $(tail -3 "${WORK}/install.log" | tr '\n' ' ')"
  exit 1
fi
FIXTURE_LIB="${FIXTURE}/usr/lib/kyri/python"
if [[ -f "${FIXTURE_LIB}/tools/capability/execution/provenance.py" ]]; then
  pass "the fixture library carries provenance.py"
else
  fail "the fixture library has no provenance.py"
  exit 1
fi

cp -a "${PRODUCTION}" "${WORK}/runtime"
cp -a "${WORK}/runtime" "${WORK}/runtime.orig"
pass "the production runtime was copied byte for byte into the fixture"

# ===========================================================================
# 3. The whole ceremony, aimed at the fixture
# ===========================================================================

printf -- '\n--- the whole ceremony, against the fixture ---\n'

rendered="${WORK}/ceremony.sh"
sed -e "s#^INSTALLED=/usr/lib/kyri/python\$#INSTALLED=${FIXTURE_LIB}#" \
    -e "s#^RUNTIME=/data/kyri/capability-runtime\$#RUNTIME=${WORK}/runtime#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${WORK}/runtime")#" \
    "${CEREMONY}" > "${rendered}"

if grep -qE "^(INSTALLED=${INSTALLED}|RUNTIME=${PRODUCTION})\$" "${rendered}"; then
  fail "a production root survived the substitution"
else
  pass "both roots were substituted"
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
if [[ ! -e "${PRODUCTION}/execution/admin-records/CADM-000002" ]]; then
  pass "no CADM-000002 exists in production"
else
  fail "A PRODUCTION CORRECTION RECORD WAS CREATED"
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
