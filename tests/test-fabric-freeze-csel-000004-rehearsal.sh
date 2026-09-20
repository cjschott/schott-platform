#!/usr/bin/env bash
set -Eeuo pipefail

# The CSEL-000004 freeze block, rehearsed whole.
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
# it, in production, and both of its gates were broken. G11-BC-P is the report.
# The rule that came out of it is why this file exists before the ceremony
# rather than after it: gates are executed, not read.
#
# WHY A SELECTION NEEDS MORE THAN THE OTHERS
# ==========================================
# A selection is the only record in this chain whose correctness is not settled
# by its own identity. It can accept, match its reviewed request digest, and
# still have chosen the wrong instance -- or have been resolved through a route
# that is no longer in force. Route resolution is by CHAIN HEAD and is not
# time-bound, so a route written after the artifact was reviewed moves the head
# silently while the reviewed bytes still match their own digest.
#
# So the two dimensions are rehearsed separately, because they fail separately:
# the HISTORICAL governed resolution of the reviewed bytes, and the CURRENT
# operational authority at the operator's clock.
#
# The block is run. Not a paraphrase of it, not its Python fragments in
# isolation: the text between `bash <<'FREEZE_CSEL'` and `FREEZE_CSEL`,
# extracted from the committed artifact, with three substitutions and nothing
# else:
#
#   /var/lib/kyri/fabric -> a byte copy of it inside the fixture
#   /etc/kyri/fabric     -> a copy of the frozen inputs inside the fixture
#   FABRIC_BEFORE        -> that copy's own aggregate
#
# The third is forced by the second: the aggregate is a digest of `sha256sum`
# output, which names absolute paths, so it is root-dependent by construction.
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

ARTIFACT="${ROOT}/provisioning/fabric/g11-bc-n-csel-000004-freeze.txt"
INERT_BODY="${ROOT}/provisioning/fabric/g11-bc-n-csel-000004-input.json"
OTHER_BODY="${ROOT}/provisioning/fabric/g11-bc-n-croute-0006-input.json"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_FROZEN=/etc/kyri/fabric
REVIEWED_SHA256=d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29
REVIEWED_BYTES=605
REVIEWED_DIGEST=sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437
PRODUCTION_BASELINE=f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb

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
  pass "production Fabric is at the pinned post-CROUTE baseline before the rehearsal"
else
  fail "production Fabric is ${PRODUCTION_BEFORE}, not the pinned ${PRODUCTION_BASELINE}"
fi
if [[ -e "${PRODUCTION_FROZEN}/csel-000004.json" ]]; then
  fail "the frozen input already exists in production; this suite will not rehearse over it"
  exit 1
fi

# The route this selection resolves through must already be written, or the
# rehearsal is measuring a world the operator will not be in.
if [[ -e "${PRODUCTION_FABRIC}/capability-routes/CROUTE-0006.yaml" ]]; then
  pass "CROUTE-0006 is written in production, as this ceremony requires"
else
  fail "CROUTE-0006 is absent from production; CSEL-000004 cannot be rehearsed yet"
  exit 1
fi

# ---- the body the block will render ---------------------------------------

if [[ "$(sha256sum "${INERT_BODY}" | cut -d' ' -f1)" == "${REVIEWED_SHA256}" ]]; then
  pass "the committed inert body is the reviewed CSEL-000004 body"
else
  fail "the committed inert body is not the reviewed CSEL-000004 body"
fi
if [[ "$(wc -c < "${INERT_BODY}")" == "${REVIEWED_BYTES}" ]]; then
  pass "the committed inert body is ${REVIEWED_BYTES} bytes"
else
  fail "the committed inert body is $(wc -c < "${INERT_BODY}") bytes"
fi

# ---- the block, extracted -------------------------------------------------

BLOCK="${WORK}/block.sh"
awk "/^bash <<'FREEZE_CSEL'\$/{on=1;next} /^FREEZE_CSEL\$/{on=0} on" "${ARTIFACT}" > "${BLOCK}"
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
  'ok  admitted_at <= evaluated_at < admitted_until' \
  'ok  CROUTE-0006 routes to exactly CINST-000006' \
  'ok  the body asks the request class CROUTE-0006 declares' \
  'ok  eligible true, no unmet conditions' \
  'ok  CINST-000006 eligible at the current clock' \
  'ok  resolved route      CROUTE-0006 (route_version 6)' \
  'ok  selected instance   CINST-000006' \
  'ok  considered          CINST-000006, excluded none' \
  'ok  predicted_record_id   CSEL-000004' \
  'ok  selected_instance_id  CINST-000006' \
  "ok  request_digest        ${REVIEWED_DIGEST}"
do
  if grep -qF "${expected}" "${out}"; then
    pass "the block reports: ${expected}"
  else
    fail "the block did not report: ${expected}"
  fi
done

if grep -qF 'eligible True | 12 of 12 met | unmet [] | reasons []' "${out}"; then
  pass "the block reports CINST-000006 eligible 12 of 12, no unmet conditions"
else
  fail "the block did not report 12 of 12 current eligibility: $(grep -F 'eligible' "${out}" | head -1)"
fi

frozen="${FIX}/etc/csel-000004.json"
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
  if cmp -s "${frozen}" "${INERT_BODY}"; then
    pass "the installed frozen input is the committed inert input, copied not restated"
  else
    fail "the installed frozen input differs from the committed inert input"
  fi
else
  fail "the frozen input was not installed"
fi

if grep -q '"mutated": false' "${out}" && grep -q '"would_accept": true' "${out}"; then
  pass "the select against production stayed a preflight: would_accept true, mutated false"
else
  fail "the select did not report a clean preflight"
fi
if grep -q '"destination_exists": false' "${out}"; then
  pass "the preflight reports destination_exists false"
else
  fail "the preflight did not report destination_exists false"
fi

# Gate 3 writes into its OWN temporary copy; the fixture store must not move.
if [[ ! -e "${FIX}/fabric/capability-selections/CSEL-000004.yaml" ]]; then
  pass "no selection record was written into the fixture store"
else
  fail "the block wrote CSEL-000004 into the fixture store"
fi
if [[ "$(cat "${FIX}/fabric/sequences/capability-selection.seq")" == "3" ]]; then
  pass "the fixture selection sequence is still 3"
else
  fail "the fixture selection sequence moved"
fi

# ---- the scratch production write ------------------------------------------
#
# What the freeze may never do, done deliberately in a scratch store, so the
# identity and sequence the operator's write will produce are known before it
# is authorised.

printf '\n--- the scratch selection write ---\n'

RESOLVE="${WORK}/resolve"
build_fixture "${RESOLVE}"
mkdir -p "${RESOLVE}/approved"
cp "${INERT_BODY}" "${RESOLVE}/approved/csel-000004.json"
chmod 0640 "${RESOLVE}/approved"/*.json

if write_out="$(cd "${ROOT}" && python3 -m tools.fabric.cli select \
    --store-root "${RESOLVE}/fabric" --expected-uid 1000 --expected-gid 1000 \
    --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
    --trust-store-root /var/lib/kyri/trust \
    --input-file csel-000004.json --approved-directory "${RESOLVE}/approved" 2>&1)"; then
  pass "the reviewed body writes a selection into a scratch store"
else
  fail "the reviewed body did not write into a scratch store: ${write_out}"
fi
if printf '%s' "${write_out}" | grep -q '"record_id": "CSEL-000004"'; then
  pass "the scratch write allocated CSEL-000004"
else
  fail "the scratch write did not allocate CSEL-000004"
fi
if printf '%s' "${write_out}" | grep -qF "${REVIEWED_DIGEST}"; then
  pass "the scratch write carries the reviewed request digest"
else
  fail "the scratch write digest is not the reviewed one"
fi
if printf '%s' "${write_out}" | grep -q '"selected_instance_id": "CINST-000006"'; then
  pass "the scratch write selected CINST-000006"
else
  fail "the scratch write did not select CINST-000006"
fi
if [[ "$(cat "${RESOLVE}/fabric/sequences/capability-selection.seq")" == "4" ]]; then
  pass "the scratch selection sequence advanced 3 -> 4"
else
  fail "the scratch selection sequence is $(cat "${RESOLVE}/fabric/sequences/capability-selection.seq"), expected 4"
fi

persisted="${RESOLVE}/fabric/capability-selections/CSEL-000004.yaml"
if [[ -f "${persisted}" ]]; then
  pass "the scratch selection record was persisted"
  for needle in 'selection_id: CSEL-000004' \
                'selected_instance_id: CINST-000006' \
                'route_id: CROUTE-0006' \
                'route_version: 6' \
                'excluded_candidates: []'; do
    if grep -qF -- "${needle}" "${persisted}"; then
      pass "the persisted selection records ${needle}"
    else
      fail "the persisted selection does not record ${needle}"
    fi
  done
  # considered is a one-item list on its own line under its key.
  if awk '/^considered_candidates:/{f=1;next} f&&/^- /{print;next} f{exit}' "${persisted}" \
       | grep -qx -- '- CINST-000006'; then
    pass "the persisted selection considered exactly CINST-000006"
  else
    fail "the persisted selection considered an unexpected candidate set"
  fi
else
  fail "the scratch selection record was not persisted"
fi

# ---- fail closed, by stage ------------------------------------------------
#
# Each sabotage changes exactly one thing and asserts where control stopped,
# AND that the refusal is that stage's own judgement. G11-BC-O's suite asserted
# that a gate refused and could not tell a refusal from a crash, so a gate that
# died on its own input scored as a gate that judged it and said no.
#
# The inspect calls are sabotaged by overwriting the file each one writes,
# inserted immediately before the gate program runs. A blanket substitution on
# the inspect command line would hit all three at once and the gate would then
# refuse for the wrong reason. Each sed program stays on ONE line: the table is
# pipe-delimited and read by `read`, which stops at the first newline.

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

# A route that no longer points at the reviewed instance.
cat > "${WORK}/wrong-route.json" <<'WRONG_ROUTE'
{"findings": [], "reason": null,
 "records": [{"route_id": "CROUTE-0006", "route_version": 6,
              "capability_id": "CAPDEF-0001", "contract_id": "CCON-0001",
              "data_classification": "internal", "locality": "local-only",
              "accepted_contract_versions": ["1.0.0"],
              "candidate_instances": ["CINST-000005"]}]}
WRONG_ROUTE

cat > "${WORK}/ineligible.json" <<'INELIGIBLE'
{"eligible": false,
 "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["host-trust"], "reasons": ["host trust record withdrawn"]}
INELIGIBLE

# shellcheck disable=SC2016  # literal text to match in the block, not an expression
GATE_LINE='if ! python3 - "${TMP}" "${GATE_ADVERT}" "${GATE_INSTANCE}" "${GATE_ROUTE}" <<.GATE_PY.$'
# shellcheck disable=SC2016  # literal text to match in the block, not an expression
ELIG_LINE='if ! python3 - "${ELIG_FILE}" <<.ELIG_PY.$'

# name | sed program | gate 2 runs? | gate 3 runs? | install? | expected refusal
SABOTAGE=(
"gate 1: the governing advertisement has expired|/${GATE_LINE}/i cp ${WORK}/expired-advert.json \"\${GATE_ADVERT}\"|no|no|no|CADV-000007 is EXPIRED at the current clock"
"gate 1: the admission of CINST-000006 has expired|/${GATE_LINE}/i cp ${WORK}/expired-instance.json \"\${GATE_INSTANCE}\"|no|no|no|REFUSE: the admission of CINST-000006 closed at the current clock"
"gate 1: the route no longer points at CINST-000006|/${GATE_LINE}/i cp ${WORK}/wrong-route.json \"\${GATE_ROUTE}\"|no|no|no|REFUSE: CROUTE-0006 routes to"
"gate 1: inspect itself fails|s#--kind capability-advertisement --identifier CADV-000007#--kind capability-advertisement --identifier CADV-999999#|no|no|no|REFUSE: could not inspect CADV-000007 in the live store"
"gate 2: CINST-000006 is not currently eligible|/${ELIG_LINE}/i cp ${WORK}/ineligible.json \"\${ELIG_FILE}\"|yes|no|no|REFUSE: CINST-000006 is not eligible at the current clock"
"gate 2: compute-eligibility itself fails|s#^python3 -m tools.fabric.cli compute-eligibility .*#false \\\\#|yes|no|no|REFUSE: compute-eligibility failed against production"
"gate 3: the selector itself fails|s#^python3 -m tools.fabric.cli select .*#false \\\\#|yes|yes|no|REFUSE: the reviewed selection does not resolve against a copy of current production"
"the body is not the reviewed body|s#^SOURCE=.*#SOURCE=${OTHER_BODY}#|no|no|no|REFUSE: rendered"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name program gate2_expected gate3_expected install_expected refusal <<<"${case}"

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
               "gate 3:--- governed resolution gate ---:${gate3_expected}"; do
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

  if [[ -e "${FIX}/etc/csel-000004.json" ]]; then
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
  if [[ ! -e "${FIX}/fabric/capability-selections/CSEL-000004.yaml" ]]; then
    pass "${name}: no selection record was created"
  else
    fail "${name}: A SELECTION RECORD WAS CREATED"
  fi
done

# ---- the historical resolution gate, judged on its own -----------------------
#
# Gate 3's check is run directly against crafted engine output, because the
# failures it exists for cannot be produced by sabotaging the live store: a
# route head that has moved, or a selector that chose another eligible
# instance, are states this host is not in and must not be put into.

printf '\n--- gate 3 judged directly ---\n'

GATE3="${WORK}/gate3.py"
sed -n "/<<'RESOLVE_PY'\$/,/^RESOLVE_PY\$/p" "${ARTIFACT}" | sed '1d;$d' > "${GATE3}"
if [[ -s "${GATE3}" ]]; then
  pass "gate 3's check was extracted"
else
  fail "gate 3's check could not be extracted"
fi

cat > "${WORK}/good-result.json" <<GOOD_RESULT
{"outcome": "accepted", "reason": null, "record_id": "CSEL-000004",
 "record_kind": "capability-selection", "request_digest": "${REVIEWED_DIGEST}",
 "selected_instance_id": "CINST-000006"}
GOOD_RESULT

GOOD_RECORD="${persisted}"
if python3 "${GATE3}" "${WORK}/good-result.json" "${GOOD_RECORD}" >/dev/null 2>&1; then
  pass "gate 3 accepts the resolution this ceremony was reviewed for"
else
  fail "gate 3 refuses the reviewed resolution; it is a brick"
fi

# name | how the record or result is corrupted | expected refusal
GATE3_CASES=(
"the route head has moved to CROUTE-0007|record|s/^route_id: CROUTE-0006$/route_id: CROUTE-0007/|the route head has moved"
"the route version is not 6|record|s/^route_version: 6$/route_version: 5/|not 6"
"the persisted selection chose another instance|record|s/^selected_instance_id: CINST-000006$/selected_instance_id: CINST-000005/|not CINST-000006"
"the persisted selection is not CSEL-000004|record|s/^selection_id: CSEL-000004$/selection_id: CSEL-000005/|the persisted selection is not CSEL-000004"
)

for case in "${GATE3_CASES[@]}"; do
  IFS='|' read -r name _kind program refusal <<<"${case}"
  bad="${WORK}/bad-record.yaml"
  sed "${program}" "${GOOD_RECORD}" > "${bad}"
  got="$(python3 "${GATE3}" "${WORK}/good-result.json" "${bad}" 2>&1 || true)"
  if python3 "${GATE3}" "${WORK}/good-result.json" "${bad}" >/dev/null 2>&1; then
    fail "gate 3 ACCEPTED: ${name}"
  elif printf '%s' "${got}" | grep -qF -- "${refusal}"; then
    pass "gate 3 refuses ${name} for its own reason"
  else
    fail "gate 3 refused ${name} but not for its own reason: ${got}"
  fi
  if printf '%s' "${got}" | grep -q 'Traceback'; then
    fail "gate 3 crashed on ${name}"
  else
    pass "gate 3 judged ${name} without crashing"
  fi
done

# The selector reporting a different instance than it persisted, and a
# non-empty exclusion set, are judged from the result side and the record side.
python3 - "${WORK}/good-result.json" "${WORK}/other-instance.json" <<'OTHER_PY'
import json
import sys
result = json.load(open(sys.argv[1]))
result["selected_instance_id"] = "CINST-000005"
json.dump(result, open(sys.argv[2], "w"))
OTHER_PY
got="$(python3 "${GATE3}" "${WORK}/other-instance.json" "${GOOD_RECORD}" 2>&1 || true)"
if printf '%s' "${got}" | grep -qF -- "the selector chose CINST-000005, not CINST-000006"; then
  pass "gate 3 refuses a selector result that chose another eligible instance"
else
  fail "gate 3 did not refuse a selector result naming another instance: ${got}"
fi

python3 - "${GOOD_RECORD}" "${WORK}/excluded.yaml" <<'EXCL_PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
text = text.replace("excluded_candidates: []",
                    "excluded_candidates:\n- CINST-000005")
open(sys.argv[2], "w", encoding="utf-8").write(text)
EXCL_PY
got="$(python3 "${GATE3}" "${WORK}/good-result.json" "${WORK}/excluded.yaml" 2>&1 || true)"
if printf '%s' "${got}" | grep -qF -- "the selection excluded"; then
  pass "gate 3 refuses an unexpected exclusion set"
else
  fail "gate 3 did not refuse an unexpected exclusion set: ${got}"
fi

got="$(python3 "${GATE3}" "${WORK}/good-result.json" "${WORK}/does-not-exist.yaml" 2>&1 || true)"
if printf '%s' "${got}" | grep -qF -- "could not read the persisted selection"; then
  pass "gate 3 refuses an unreadable persisted selection"
else
  fail "gate 3 did not refuse an unreadable persisted selection: ${got}"
fi

# ---- a changed Fabric baseline is refused ----------------------------------

printf '\n--- a changed Fabric baseline is refused ---\n'

build_fixture "${FIX}"
render_block "${FIX}" "${rendered}"
sed -i "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=0000000000000000000000000000000000000000000000000000000000000000#" "${rendered}"
status=0
run_block "${rendered}" "${WORK}/baseline.out" || status=$?
if (( status != 0 )) && grep -q 'changed during the freeze' "${WORK}/baseline.out"; then
  pass "a baseline that does not match the store is refused"
else
  fail "a changed baseline was not refused"
fi
if [[ ! -e "${FIX}/fabric/capability-selections/CSEL-000004.yaml" ]]; then
  pass "the baseline refusal created no selection record"
else
  fail "A SELECTION RECORD WAS CREATED"
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
     || [[ -e "${FIX}/etc/csel-000004.json" ]]; then
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
if [[ ! -e "${PRODUCTION_FROZEN}/csel-000004.json" ]]; then
  pass "no frozen input was created in production"
else
  fail "A FROZEN INPUT WAS CREATED IN PRODUCTION"
fi
if [[ ! -e "${PRODUCTION_FABRIC}/capability-selections/CSEL-000004.yaml" ]]; then
  pass "CSEL-000004 is still absent from production"
else
  fail "CSEL-000004 WAS WRITTEN TO PRODUCTION"
fi
if [[ "$(cat "${PRODUCTION_FABRIC}/sequences/capability-selection.seq")" == "3" ]]; then
  pass "the production selection sequence is still 3"
else
  fail "THE PRODUCTION SELECTION SEQUENCE MOVED"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CSEL-000004 freeze rehearsal passed.\n'
else
  printf 'CSEL-000004 freeze rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
