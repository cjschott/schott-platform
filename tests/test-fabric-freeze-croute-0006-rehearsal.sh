#!/usr/bin/env bash
set -Eeuo pipefail

# The CROUTE-0006 freeze block, rehearsed whole.
#
# HOST-ONLY. tests/test-fabric-freeze-gate-execution.sh executes gate
# constructs against fixtures and runs anywhere. This runs the ENTIRE operator
# block -- every command the operator will paste, in order, with the real
# released CLI -- and that needs the governed stores. See
# tests/host-only.manifest.
#
# WHY THIS EXISTS
# ===============
# G11-BC-O's CINST artifact was asserted, extracted, digested and reasoned
# about, and never once run end to end. The operator was the first to execute
# it, in production, and both of its gates were broken. Every assertion that
# suite made was true; none of them was the thing that mattered. G11-BC-P is
# the report. The rule that came out of it is the reason this file exists
# before the CROUTE ceremony rather than after it: gates are executed, not
# read.
#
# So the block is run. Not a paraphrase of it, not its Python fragments in
# isolation: the text between `bash <<'FREEZE_CROUTE'` and `FREEZE_CROUTE`,
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

ARTIFACT="${ROOT}/provisioning/fabric/g11-bc-n-croute-0006-freeze.txt"
INERT_BODY="${ROOT}/provisioning/fabric/g11-bc-n-croute-0006-input.json"
OTHER_BODY="${ROOT}/provisioning/fabric/g11-bc-n-csel-000004-input.json"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_FROZEN=/etc/kyri/fabric
REVIEWED_SHA256=cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c
REVIEWED_BYTES=678
REVIEWED_DIGEST=sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9
PRODUCTION_BASELINE=1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78

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
  pass "production Fabric is at the pinned post-CINST baseline before the rehearsal"
else
  fail "production Fabric is ${PRODUCTION_BEFORE}, not the pinned ${PRODUCTION_BASELINE}"
fi
if [[ -e "${PRODUCTION_FROZEN}/croute-0006.json" ]]; then
  fail "the frozen input already exists in production; this suite will not rehearse over it"
  exit 1
fi

# The predecessor this ceremony rests on must already be written, or the
# rehearsal is measuring a world the operator will not be in.
if [[ -e "${PRODUCTION_FABRIC}/capability-instances/CINST-000006.yaml" ]]; then
  pass "CINST-000006 is written in production, as this ceremony requires"
else
  fail "CINST-000006 is absent from production; CROUTE-0006 cannot be rehearsed yet"
  exit 1
fi

# ---- the body the block will render ---------------------------------------

if [[ "$(sha256sum "${INERT_BODY}" | cut -d' ' -f1)" == "${REVIEWED_SHA256}" ]]; then
  pass "the committed inert body is the reviewed CROUTE-0006 body"
else
  fail "the committed inert body is not the reviewed CROUTE-0006 body"
fi

# ---- the block, extracted -------------------------------------------------

BLOCK="${WORK}/block.sh"
awk "/^bash <<'FREEZE_CROUTE'\$/{on=1;next} /^FREEZE_CROUTE\$/{on=0} on" "${ARTIFACT}" > "${BLOCK}"
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
  'ok  admitted_at <= recorded_at < admitted_until' \
  'ok  eligible true, no unmet conditions' \
  'ok  CINST-000006 eligible at the current clock' \
  'ok  predicted_record_id CROUTE-0006' \
  "ok  request_digest      ${REVIEWED_DIGEST}"
do
  if grep -qF "${expected}" "${out}"; then
    pass "the block reports: ${expected}"
  else
    fail "the block did not report: ${expected}"
  fi
done

# Current eligibility is 12 of 12, and the block says so rather than implying it.
if grep -qF 'eligible True | 12 of 12 met | unmet [] | reasons []' "${out}"; then
  pass "the block reports CINST-000006 eligible 12 of 12, no unmet conditions"
else
  fail "the block did not report 12 of 12 current eligibility: $(grep -F 'eligible' "${out}" | head -1)"
fi

frozen="${FIX}/etc/croute-0006.json"
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
  pass "the create-route stayed a preflight: would_accept true, mutated false"
else
  fail "the create-route did not report a clean preflight"
fi
if grep -q '"destination_exists": false' "${out}"; then
  pass "the preflight reports destination_exists false"
else
  fail "the preflight did not report destination_exists false"
fi

# Record creation during a freeze is impossible because the only live
# create-route carries --preflight. Asserted on the run, not on the text.
if [[ ! -e "${FIX}/fabric/capability-routes/CROUTE-0006.yaml" ]]; then
  pass "no route record was written, even in the fixture"
else
  fail "the block wrote CROUTE-0006 into the fixture store"
fi
if [[ "$(cat "${FIX}/fabric/sequences/capability-route.seq")" == "5" ]]; then
  pass "the fixture route sequence is still 5"
else
  fail "the fixture route sequence moved"
fi

# ---- the route resolves through CINST-000006 -------------------------------
#
# The freeze does not select, so resolution is proved separately: the reviewed
# body is written into a scratch store and the released selector is asked which
# instance the resulting route resolves to. A route that accepts and resolves
# to the wrong instance is the one failure its own identity cannot catch.

printf '\n--- the route resolves through CINST-000006 ---\n'

RESOLVE="${WORK}/resolve"
build_fixture "${RESOLVE}"
mkdir -p "${RESOLVE}/approved"
cp "${INERT_BODY}" "${RESOLVE}/approved/croute-0006.json"
cp "${OTHER_BODY}" "${RESOLVE}/approved/csel-000004.json"
chmod 0640 "${RESOLVE}/approved"/*.json

if write_out="$(cd "${ROOT}" && python3 -m tools.fabric.cli create-route \
    --store-root "${RESOLVE}/fabric" --expected-uid 1000 --expected-gid 1000 \
    --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
    --input-file croute-0006.json --approved-directory "${RESOLVE}/approved" 2>&1)"; then
  pass "the reviewed body writes CROUTE-0006 into a scratch store"
else
  fail "the reviewed body did not write into a scratch store: ${write_out}"
fi
if printf '%s' "${write_out}" | grep -q '"record_id": "CROUTE-0006"'; then
  pass "the scratch write allocated CROUTE-0006"
else
  fail "the scratch write did not allocate CROUTE-0006"
fi
if printf '%s' "${write_out}" | grep -qF "${REVIEWED_DIGEST}"; then
  pass "the scratch write carries the reviewed request digest"
else
  fail "the scratch write digest is not the reviewed one"
fi
if [[ "$(cat "${RESOLVE}/fabric/sequences/capability-route.seq")" == "6" ]]; then
  pass "the scratch route sequence advanced 5 -> 6"
else
  fail "the scratch route sequence is $(cat "${RESOLVE}/fabric/sequences/capability-route.seq"), expected 6"
fi

if select_out="$(cd "${ROOT}" && python3 -m tools.fabric.cli select \
    --store-root "${RESOLVE}/fabric" --expected-uid 1000 --expected-gid 1000 \
    --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
    --trust-store-root /var/lib/kyri/trust \
    --input-file csel-000004.json --approved-directory "${RESOLVE}/approved" \
    --preflight 2>&1)"; then
  pass "the selector resolves against the scratch store with CROUTE-0006 written"
else
  fail "the selector failed against the scratch store: ${select_out}"
fi
if printf '%s' "${select_out}" | grep -q '"selected_instance_id": "CINST-000006"'; then
  pass "the route resolves to CINST-000006, as intended"
else
  fail "the route does not resolve to CINST-000006"
fi

# ---- fail closed, by stage ------------------------------------------------
#
# Each sabotage changes exactly one thing and asserts where control stopped.
# The sentinel for "gate 2 ran" is gate 2's own banner; for "the install ran",
# the frozen input.
#
# The two `inspect` calls are sabotaged by overwriting the file each one writes,
# inserted immediately before the gate program runs. Each sed program stays on
# ONE line: the table is pipe-delimited and read by `read`, which stops at the
# first newline, so a multi-line sed script would silently truncate the row and
# leave the expectations empty. A blanket substitution on
# the `inspect` command line would hit both calls at once and the gate would
# then refuse for the wrong reason -- an advertisement where an instance was
# expected -- which proves nothing about the window it is supposed to judge.

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

cat > "${WORK}/ineligible.json" <<'INELIGIBLE'
{"eligible": false,
 "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["host-trust"], "reasons": ["host trust record withdrawn"]}
INELIGIBLE

# These two are sed ADDRESSES matching literal lines in the rendered block, so
# the ${...} in them must reach sed unexpanded. They are text to find, not
# expressions to evaluate.
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
GATE_LINE='if ! python3 - "${TMP}" "${GATE_ADVERT}" "${GATE_INSTANCE}" <<.GATE_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
ELIG_LINE='if ! python3 - "${ELIG_FILE}" <<.ELIG_PY.$'

# name | sed program applied to the rendered block | gate 2 must run? |
#   install must happen? | the refusal this stage must state
#
# The fifth column is the one that makes this evidence. G11-BC-O's suite
# asserted that a gate refused and could not tell a refusal from a crash, so a
# gate that died on its own input scored as a gate that judged its input and
# said no. Each case below must refuse FOR ITS OWN REASON.
SABOTAGE=(
"gate 1: the governing advertisement has expired|/${GATE_LINE}/i cp ${WORK}/expired-advert.json \"\${GATE_ADVERT}\"|no|no|CADV-000007 is EXPIRED at the current clock"
"gate 1: the admission of CINST-000006 has expired|/${GATE_LINE}/i cp ${WORK}/expired-instance.json \"\${GATE_INSTANCE}\"|no|no|REFUSE: the admission of CINST-000006 closed at the current clock"
"gate 1: inspect itself fails|s#--kind capability-advertisement --identifier CADV-000007#--kind capability-advertisement --identifier CADV-999999#|no|no|REFUSE: could not inspect CADV-000007 in the live store"
"gate 2: CINST-000006 is not currently eligible|/${ELIG_LINE}/i cp ${WORK}/ineligible.json \"\${ELIG_FILE}\"|yes|no|REFUSE: CINST-000006 is not eligible at the current clock"
"gate 2: compute-eligibility itself fails|s#^python3 -m tools.fabric.cli compute-eligibility .*#false \\\\#|yes|no|REFUSE: compute-eligibility failed against production"
"the body is not the reviewed body|s#^SOURCE=.*#SOURCE=${OTHER_BODY}#|no|no|REFUSE: rendered"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name program gate2_expected install_expected refusal <<<"${case}"

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

  # The refusal must be THIS stage's judgement, not a traceback that happened
  # to exit nonzero.
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

  if grep -q -- '--- current eligibility gate ---' "${out}"; then
    if [[ "${gate2_expected}" == "yes" ]]; then
      pass "${name}: gate 2 ran, as this stage requires"
    else
      fail "${name}: gate 2 RAN after an earlier stage failed"
    fi
  else
    if [[ "${gate2_expected}" == "no" ]]; then
      pass "${name}: gate 2 never ran"
    else
      fail "${name}: gate 2 did not run when it should have"
    fi
  fi

  if [[ -e "${FIX}/etc/croute-0006.json" ]]; then
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

  if [[ ! -e "${FIX}/fabric/capability-routes/CROUTE-0006.yaml" ]]; then
    pass "${name}: no route record was created"
  else
    fail "${name}: A ROUTE RECORD WAS CREATED"
  fi
done

# ---- a changed Fabric baseline is refused ----------------------------------
#
# This one is last on purpose: the baseline check is the final statement in the
# block, after the install and the preflight, so it refuses rather than
# prevents. What it protects is the reviewer's claim that the store the
# ceremony was prepared against is the store it ran against.

printf '\n--- a changed Fabric baseline is refused ---\n'

build_fixture "${FIX}"
render_block "${FIX}" "${rendered}"
sed -i "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#" "${rendered}"
status=0
run_block "${rendered}" "${WORK}/baseline.out" || status=$?
if (( status != 0 )) && grep -q 'REFUSE: /var/lib/kyri/fabric changed during the freeze\|changed during the freeze' "${WORK}/baseline.out"; then
  pass "a baseline that does not match the store is refused"
else
  fail "a changed baseline was not refused"
fi
if [[ ! -e "${FIX}/fabric/capability-routes/CROUTE-0006.yaml" ]]; then
  pass "the baseline refusal created no route record"
else
  fail "A ROUTE RECORD WAS CREATED"
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
     || [[ -e "${FIX}/etc/croute-0006.json" ]]; then
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
if [[ ! -e "${PRODUCTION_FROZEN}/croute-0006.json" ]]; then
  pass "no frozen input was created in production"
else
  fail "A FROZEN INPUT WAS CREATED IN PRODUCTION"
fi
if [[ ! -e "${PRODUCTION_FABRIC}/capability-routes/CROUTE-0006.yaml" ]]; then
  pass "CROUTE-0006 is still absent from production"
else
  fail "CROUTE-0006 WAS WRITTEN TO PRODUCTION"
fi
if [[ "$(cat "${PRODUCTION_FABRIC}/sequences/capability-route.seq")" == "5" ]]; then
  pass "the production route sequence is still 5"
else
  fail "THE PRODUCTION ROUTE SEQUENCE MOVED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CROUTE-0006 freeze rehearsal passed.\n'
else
  printf 'CROUTE-0006 freeze rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
