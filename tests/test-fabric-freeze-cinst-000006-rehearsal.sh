#!/usr/bin/env bash
set -Eeuo pipefail

# The CINST-000006 freeze block, rehearsed whole.
#
# HOST-ONLY. tests/test-fabric-freeze-gate-execution.sh executes the two gates
# against fixtures and runs anywhere. This runs the ENTIRE operator block --
# every command the operator will paste, in order, with the real released CLI --
# and that needs the governed stores. See tests/host-only.manifest.
#
# WHY THIS EXISTS
# ===============
# G11-BC-O's artifact was asserted, extracted, digested and reasoned about, and
# never once run end to end. The operator was the first to execute it, in
# production, and both of its gates were broken. Every assertion that suite
# made was true; none of them was the thing that mattered.
#
# So the block is run. Not a paraphrase of it, not its Python fragments in
# isolation: the text between `bash <<'FREEZE_CINST'` and `FREEZE_CINST`,
# extracted from the committed artifact, with three substitutions and nothing
# else:
#
#   /var/lib/kyri/fabric -> a byte copy of it inside the fixture
#   /etc/kyri/fabric     -> a copy of the frozen inputs inside the fixture
#   FABRIC_BEFORE        -> that copy's own aggregate
#
# The third is forced by the second: the aggregate is a digest of `sha256sum`
# output, which names absolute paths, so it is root-dependent by construction.
# That is correct for its real job -- it pins THAT store -- and it means a
# rehearsal under a different root must pin its own.
#
# `sudo` is shimmed to run its arguments directly, and to drop `-o root` from
# the install, since the rehearsal is unprivileged and installs into its own
# fixture. Trust and Evidence stay pointed at the real stores: the block only
# ever reads them, and reading them is what makes the rehearsal faithful.
#
# Production is never written. The suite proves that by aggregate, not by
# intention, after every run including the sabotaged ones.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires \
  /var/lib/kyri/fabric /etc/kyri/fabric /var/lib/kyri/trust /var/lib/kyri/evidence

ARTIFACT="${ROOT}/provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_FROZEN=/etc/kyri/fabric
REVIEWED_SHA256=6746234a2b1293052c223ff4a3e253286129ddf58b9d8397d1ecf4d04175e162
REVIEWED_BYTES=1269
REVIEWED_DIGEST=sha256:c9444952f62e9a9a40132f3d4569043a2b853d9446dd00be64c43031f6f02372
PRODUCTION_BASELINE=3bcb57790fc7c502e4b5493ba5a6a956dab78703b7c86b5756293b78f3007f28

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

aggregate() {
  find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

PRODUCTION_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"
FROZEN_BEFORE="$(aggregate "${PRODUCTION_FROZEN}")"

if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_BASELINE}" ]]; then
  pass "production Fabric is at the pinned baseline before the rehearsal"
else
  fail "production Fabric is ${PRODUCTION_BEFORE}, not the pinned ${PRODUCTION_BASELINE}"
fi
if [[ -e "${PRODUCTION_FROZEN}/cinst-000006.json" ]]; then
  fail "the frozen input already exists in production; this suite will not rehearse over it"
  exit 1
fi

# ---- the block, extracted -------------------------------------------------

BLOCK="${WORK}/block.sh"
awk "/^bash <<'FREEZE_CINST'\$/{on=1;next} /^FREEZE_CINST\$/{on=0} on" "${ARTIFACT}" > "${BLOCK}"
if [[ -s "${BLOCK}" ]]; then
  pass "the operator block was extracted whole ($(wc -l < "${BLOCK}") lines)"
else
  fail "the operator block could not be extracted"
  exit 1
fi

# ---- the fixture ----------------------------------------------------------

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/sudo" <<'SUDO_SHIM'
#!/usr/bin/env bash
# Runs the command directly. The install drops -o/-g: the rehearsal is
# unprivileged and installs into its own fixture, and the mode is what the
# block is actually asserting about the frozen input.
if [[ "${1:-}" == "install" ]]; then
  shift
  args=()
  while (( $# )); do
    case "$1" in
      -o|-g) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  exec install "${args[@]}"
fi
exec "$@"
SUDO_SHIM
chmod +x "${WORK}/bin/sudo"

build_fixture() {
  local fixture="$1"
  rm -rf "${fixture}"
  mkdir -p "${fixture}"
  cp -a "${PRODUCTION_FABRIC}" "${fixture}/fabric"
  mkdir -p "${fixture}/etc"
  cp "${PRODUCTION_FROZEN}"/*.json "${fixture}/etc/"
  chmod 0640 "${fixture}/etc"/*.json
}

# Rewrites the block for the fixture. Three substitutions, listed above.
render_block() {
  local fixture="$1" out="$2"
  local fixture_baseline
  fixture_baseline="$(aggregate "${fixture}/fabric")"
  sed \
    -e "s#${PRODUCTION_FABRIC}#${fixture}/fabric#g" \
    -e "s#${PRODUCTION_FROZEN}#${fixture}/etc#g" \
    -e "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=${fixture_baseline}#" \
    "${BLOCK}" > "${out}"
}

run_block() {
  local rendered="$1" out="$2"
  local status=0
  ( cd "${ROOT}" && PATH="${WORK}/bin:${PATH}" bash "${rendered}" ) > "${out}" 2>&1 || status=$?
  return "${status}"
}

# ---- the happy path -------------------------------------------------------

printf '\n--- the whole block, end to end ---\n'

FIX="${WORK}/fix"
build_fixture "${FIX}"
rendered="${WORK}/rendered.sh"
render_block "${FIX}" "${rendered}"

if grep -q -e "${PRODUCTION_FABRIC}" -e "${PRODUCTION_FROZEN}" "${rendered}"; then
  fail "the rendered block still references a production path"
else
  pass "the rendered block references no production Fabric or frozen-input path"
fi

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
  'ok  eligible true, no unmet conditions' \
  'ok  CINST-000006 eligible at the current clock' \
  'ok  predicted_record_id CINST-000006' \
  "ok  request_digest      ${REVIEWED_DIGEST}"
do
  if grep -qF "${expected}" "${out}"; then
    pass "the block reports: ${expected}"
  else
    fail "the block did not report: ${expected}"
  fi
done

frozen="${FIX}/etc/cinst-000006.json"
if [[ -f "${frozen}" ]]; then
  pass "the frozen input was installed into the fixture"
  if [[ "$(sha256sum "${frozen}" | cut -d' ' -f1)" == "${REVIEWED_SHA256}" ]]; then
    pass "the installed frozen input is the reviewed body, byte for byte"
  else
    fail "the installed frozen input is not the reviewed body"
  fi
  if [[ "$(wc -c < "${frozen}")" == "${REVIEWED_BYTES}" ]]; then
    pass "the installed frozen input is ${REVIEWED_BYTES} bytes"
  else
    fail "the installed frozen input is $(wc -c < "${frozen}") bytes, reviewed ${REVIEWED_BYTES}"
  fi
  if [[ "$(stat -c '%a' "${frozen}")" == "640" ]]; then
    pass "the installed frozen input is mode 0640"
  else
    fail "the installed frozen input is mode $(stat -c '%a' "${frozen}")"
  fi
else
  fail "the frozen input was not installed"
fi

# The production-capable operation must have stayed a preflight.
if grep -q '"mutated": false' "${out}" && grep -q '"would_accept": true' "${out}"; then
  pass "the admit-instance stayed a preflight: would_accept true, mutated false"
else
  fail "the admit-instance did not report a clean preflight"
fi
if [[ ! -e "${FIX}/fabric/capability-instances/CINST-000006.yaml" ]]; then
  pass "no instance record was written, even in the fixture"
else
  fail "the block wrote CINST-000006 into the fixture store"
fi
if [[ "$(cat "${FIX}/fabric/sequences/capability-instance.seq")" == "5" ]]; then
  pass "the fixture instance sequence is still 5"
else
  fail "the fixture instance sequence moved"
fi

# ---- fail closed, by stage ------------------------------------------------
#
# Each sabotage replaces exactly one released command's output with a refusal
# the gate must catch, and asserts where control stopped. The sentinel for
# "gate 2 ran" is gate 2's own banner; for "the install ran", the frozen input.

printf '\n--- fail closed, by stage ---\n'

cat > "${WORK}/expired-advert.json" <<'EXPIRED'
{"findings": [], "reason": null,
 "records": [{"advertisement_id": "CADV-000007",
              "observed_at": "2026-09-15T06:00:00-05:00",
              "valid_until": "2026-09-19T06:00:00-05:00"}]}
EXPIRED

cat > "${WORK}/ineligible.json" <<'INELIGIBLE'
{"eligible": false,
 "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["host-trust"], "reasons": ["host trust record withdrawn"]}
INELIGIBLE

# name | sed program applied to the rendered block | gate 2 must run? | install must happen?
SABOTAGE=(
"gate 1: the governing advertisement has expired|s#^python3 -m tools.fabric.cli inspect .*#cat ${WORK}/expired-advert.json \\\\#|no|no"
"gate 1: inspect itself fails|s#^python3 -m tools.fabric.cli inspect .*#false \\\\#|no|no"
"gate 2: the candidate is not eligible|s#^python3 -m tools.fabric.cli compute-eligibility .*#cat ${WORK}/ineligible.json \\\\#|yes|no"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name program gate2_expected install_expected <<<"${case}"

  build_fixture "${FIX}"
  fixture_before="$(aggregate "${FIX}/fabric")"
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
  if grep -q 'REFUSE' "${out}"; then
    pass "${name}: the block states a refusal"
  else
    fail "${name}: the block failed silently"
  fi

  if grep -q -- '--- current eligibility gate ---' "${out}"; then
    if [[ "${gate2_expected}" == "yes" ]]; then
      pass "${name}: gate 2 ran, as this stage requires"
    else
      fail "${name}: gate 2 RAN after gate 1 failed"
    fi
  else
    if [[ "${gate2_expected}" == "no" ]]; then
      pass "${name}: gate 2 never ran"
    else
      fail "${name}: gate 2 did not run when it should have"
    fi
  fi

  if [[ -e "${FIX}/etc/cinst-000006.json" ]]; then
    if [[ "${install_expected}" == "yes" ]]; then
      pass "${name}: the frozen input was installed"
    else
      fail "${name}: THE FROZEN INPUT WAS INSTALLED after a gate refused"
    fi
  else
    pass "${name}: no frozen input was installed"
  fi

  if [[ "$(aggregate "${FIX}/fabric")" == "${fixture_before}" ]]; then
    pass "${name}: the fixture store is byte-identical to before the run"
  else
    fail "${name}: the fixture store changed"
  fi
done

# Determinism. Three runs of the gate-1 sabotage, all of which must stop dead.
printf '\n--- deterministic refusal ---\n'
deterministic=1
for attempt in 1 2 3; do
  build_fixture "${FIX}"
  render_block "${FIX}" "${rendered}"
  sed -i "s#^python3 -m tools.fabric.cli inspect .*#cat ${WORK}/expired-advert.json \\\\#" "${rendered}"
  status=0
  run_block "${rendered}" "${WORK}/repeat-${attempt}.out" || status=$?
  if (( status == 0 )) \
     || grep -q -- '--- current eligibility gate ---' "${WORK}/repeat-${attempt}.out" \
     || [[ -e "${FIX}/etc/cinst-000006.json" ]]; then
    deterministic=0
  fi
done
if (( deterministic == 1 )); then
  pass "an expired advertisement stops the block before gate 2 and before the install, 3 of 3 runs"
else
  fail "the gate-1 refusal was not deterministic"
fi

# ---- production, after everything -----------------------------------------

printf '\n--- production untouched ---\n'

PRODUCTION_AFTER="$(aggregate "${PRODUCTION_FABRIC}")"
FROZEN_AFTER="$(aggregate "${PRODUCTION_FROZEN}")"

if [[ "${PRODUCTION_AFTER}" == "${PRODUCTION_BEFORE}" ]]; then
  pass "production Fabric is byte-identical after the rehearsal (${PRODUCTION_AFTER})"
else
  fail "PRODUCTION FABRIC CHANGED: ${PRODUCTION_BEFORE} -> ${PRODUCTION_AFTER}"
fi
if [[ "${FROZEN_AFTER}" == "${FROZEN_BEFORE}" ]]; then
  pass "the production frozen inputs are byte-identical after the rehearsal"
else
  fail "THE PRODUCTION FROZEN INPUTS CHANGED: ${FROZEN_BEFORE} -> ${FROZEN_AFTER}"
fi
if [[ ! -e "${PRODUCTION_FROZEN}/cinst-000006.json" ]]; then
  pass "no frozen input was created in production"
else
  fail "A FROZEN INPUT WAS CREATED IN PRODUCTION"
fi
if [[ ! -e "${PRODUCTION_FABRIC}/capability-instances/CINST-000006.yaml" ]]; then
  pass "CINST-000006 is still absent from production"
else
  fail "CINST-000006 WAS WRITTEN TO PRODUCTION"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINST-000006 freeze rehearsal passed.\n'
else
  printf 'CINST-000006 freeze rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
