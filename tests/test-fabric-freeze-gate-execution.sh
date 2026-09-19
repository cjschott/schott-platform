#!/usr/bin/env bash
set -Eeuo pipefail

# The freeze artifacts' GATES, executed rather than read.
#
# UNPRIVILEGED AND HOST-INDEPENDENT. Reads committed files and writes only
# inside a temporary directory. No production store, no Fabric, no Trust, no
# sudo, no network. The live-like whole-block rehearsal, which does need the
# production stores, is tests/test-fabric-freeze-cinst-000006-rehearsal.sh.
#
# WHY THIS EXISTS
# ===============
# G11-BC-O shipped a CINST-000006 freeze artifact whose two gates had never
# been executed in the shape the operator would execute them in. The operator
# ran it and both gates failed:
#
#   GATE 1  the program came in on stdin through a heredoc and the advertisement
#           was appended as a here-string on the following line. A here-string
#           on its own line is a complete word-less command with status 0, not a
#           second redirection of the python3 command -- so the advertisement
#           went nowhere, `json.load(sys.stdin)` read a spent stream and raised
#           JSONDecodeError, AND that status-0 null command became the exit
#           status of the enclosing $( ), masking the failure. Control fell
#           through into GATE 2.
#
#   GATE 2  the report line was an f-string containing \" inside its expression
#           parts, inside a bash single-quoted `python3 -c` program, where a
#           backslash is literal. Python refused to compile it.
#
# tests/test-fabric-freeze-artifacts.sh had 136 passing assertions over that
# artifact. It asserted the gate's TEXT and ran the gate's PROGRAM with argv it
# invents itself; it never ran the shell construct that feeds the program, and
# its regression loop stopped at the first gated row -- CADV-000007, whose gate
# is single-channel and was fine -- so the CINST-000006 gate was executed by
# nothing at all. A gate is a control path. Reading it is not testing it.
#
# So this suite executes them: the real extracted constructs, real python3, real
# shell status propagation, against fixtures. Every failure case must exit
# nonzero AND must not reach the sentinel that stands for the next stage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARTIFACT="${ROOT}/provisioning/fabric/g11-bc-n-cinst-000006-freeze.txt"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

REAL_PYTHON="$(command -v python3)"

# Region between two marker comments, markers excluded.
extract_between() {
  local begin="$1" end="$2" file="$3"
  awk -v b="${begin}" -v e="${end}" '
    index($0, b) { on = 1; next }
    index($0, e) { on = 0 }
    on { print }
  ' "${file}"
}

# ---- section 1: the G11-BC-O shapes, executed ------------------------------
#
# These two fixtures are the committed G11-BC-O constructs, verbatim. They are
# kept and executed so the live failure stays reproducible from the repository
# instead of only from a report, and so the assertions below say what was
# actually wrong rather than what someone remembered being wrong.

printf '\n--- the G11-BC-O defect shapes ---\n'

cat > "${WORK}/defect-body.json" <<'DEFECT_BODY'
{"advertisement_id": "CADV-000007",
 "admitted_at": "2026-09-19T06:15:00-05:00",
 "admitted_until": "2026-09-23T06:00:00-05:00"}
DEFECT_BODY

cat > "${WORK}/defect-advert.json" <<'DEFECT_ADVERT'
{"findings": [], "reason": null,
 "records": [{"advertisement_id": "CADV-000007",
              "observed_at": "2026-09-19T06:00:00-05:00",
              "valid_until": "2026-09-23T06:00:00-05:00"}]}
DEFECT_ADVERT

cat > "${WORK}/defect-gate1.sh" <<'DEFECT_GATE1'
set -Eeuo pipefail
TMP="$1"
ADVERT="$(cat "$2")"
GATE="$(python3 - "${TMP}" <<'GATE_PY'
import json, sys
from datetime import datetime
body = json.load(open(sys.argv[1]))
advert = json.load(sys.stdin)["records"][0]
print("the advertisement was read")
GATE_PY
<<<"${ADVERT}"
)" || { printf '%s\n' "${GATE}"; echo "REFUSE: current-time freshness gate failed"; exit 1; }
printf '%s\n' "${GATE}"
echo "SENTINEL_GATE2_REACHED"
DEFECT_GATE1

defect1_out="${WORK}/defect-gate1.out"
defect1_status=0
bash "${WORK}/defect-gate1.sh" "${WORK}/defect-body.json" "${WORK}/defect-advert.json" \
  > "${defect1_out}" 2>&1 || defect1_status=$?

if grep -q 'JSONDecodeError' "${defect1_out}"; then
  pass "G11-BC-O gate 1: the here-string never reaches python3, so the advertisement read raises JSONDecodeError"
else
  fail "G11-BC-O gate 1: expected a JSONDecodeError from the spent stdin"
fi
if grep -q 'the advertisement was read' "${defect1_out}"; then
  fail "G11-BC-O gate 1: the advertisement was somehow read"
else
  pass "G11-BC-O gate 1: the advertisement was never read"
fi
if (( defect1_status == 0 )) && grep -q 'SENTINEL_GATE2_REACHED' "${defect1_out}"; then
  pass "G11-BC-O gate 1: the failure is masked -- status 0 and control reaches the next stage"
else
  fail "G11-BC-O gate 1: expected the masked-failure fall-through (status ${defect1_status})"
fi
if grep -q 'REFUSE: current-time freshness gate failed' "${defect1_out}"; then
  fail "G11-BC-O gate 1: the refusal handler ran, so this is not the observed defect"
else
  pass "G11-BC-O gate 1: the refusal handler never ran, exactly as observed live"
fi

cat > "${WORK}/defect-gate2.sh" <<'DEFECT_GATE2'
set -uo pipefail
ELIG="$(cat "$1")"
printf '%s\n' "${ELIG}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
met = sum(1 for c in d["conditions"] if c["status"] == "met")
print(f"eligible {d[\"eligible\"]} | {met} of {len(d[\"conditions\"])} met | unmet {d[\"unmet\"]} | reasons {d[\"reasons\"]}")
sys.exit(0 if d["eligible"] is True and not d["unmet"] else 1)
' || { echo "REFUSE: CINST-000006 is not eligible at the current clock"; exit 1; }
echo "SENTINEL_INSTALL_REACHED"
DEFECT_GATE2

cat > "${WORK}/eligible.json" <<'ELIGIBLE'
{"eligible": true, "conditions": [{"status": "met"}, {"status": "met"}],
 "unmet": [], "reasons": []}
ELIGIBLE

defect2_out="${WORK}/defect-gate2.out"
defect2_status=0
bash "${WORK}/defect-gate2.sh" "${WORK}/eligible.json" > "${defect2_out}" 2>&1 || defect2_status=$?

if grep -q 'SyntaxError' "${defect2_out}"; then
  pass "G11-BC-O gate 2: the backslashed f-string does not compile"
else
  fail "G11-BC-O gate 2: expected a SyntaxError from the backslashed f-string"
fi
if (( defect2_status != 0 )) && ! grep -q 'SENTINEL_INSTALL_REACHED' "${defect2_out}"; then
  pass "G11-BC-O gate 2: an eligible result still refuses, and the install is not reached"
else
  fail "G11-BC-O gate 2: expected a refusal short of the install"
fi

# ---- section 2: the committed gate 1 program, executed ---------------------
#
# Extracted from the artifact and run exactly as the artifact runs it: the
# program on stdin, the body as argv[1], the inspect output as argv[2].

printf '\n--- committed gate 1, program semantics ---\n'

gate1_region="${WORK}/gate1-region.sh"
extract_between '# >>> GATE1_BEGIN' '# <<< GATE1_END' "${ARTIFACT}" > "${gate1_region}"
gate1_prog="${WORK}/gate1.py"
extract_between "<<'GATE_PY'" 'GATE_PY' "${gate1_region}" > "${gate1_prog}"

if [[ -s "${gate1_region}" && -s "${gate1_prog}" ]]; then
  pass "gate 1 was extracted from the committed artifact ($(wc -l < "${gate1_prog}") program lines)"
else
  fail "gate 1 could not be extracted from the committed artifact"
fi

# Fixtures are generated relative to now, so this suite does not expire.
python3 - "${WORK}" <<'FIXTURES'
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path

work = Path(sys.argv[1])
now = datetime.now().astimezone()


def stamp(delta):
    return (now + delta).isoformat()


def advert(observed, expires, identifier="CADV-000007", records=None):
    record = {
        "advertisement_id": identifier,
        "observed_at": observed,
        "valid_until": expires,
    }
    payload = {"findings": [], "reason": None,
               "records": [record] if records is None else records}
    return payload


def body(admitted, until, identifier="CADV-000007"):
    return {
        "advertisement_id": identifier,
        "admitted_at": admitted,
        "admitted_until": until,
    }


day = timedelta(days=1)
hour = timedelta(hours=1)

open_advert = advert(stamp(-day), stamp(day))
good_body = body(stamp(-hour), stamp(hour))

cases = {
    "advert-open": open_advert,
    "advert-expired": advert(stamp(-2 * day), stamp(-day)),
    "advert-not-open": advert(stamp(day), stamp(2 * day)),
    "advert-missing-valid-until": {
        "records": [{"advertisement_id": "CADV-000007", "observed_at": stamp(-day)}]},
    "advert-naive-instants": advert(
        (now - day).replace(tzinfo=None).isoformat(),
        (now + day).replace(tzinfo=None).isoformat()),
    "advert-wrong-identity": advert(stamp(-day), stamp(day), identifier="CADV-000006"),
    "advert-two-records": advert(stamp(-day), stamp(day), records=[
        {"advertisement_id": "CADV-000007", "observed_at": stamp(-day),
         "valid_until": stamp(day)},
        {"advertisement_id": "CADV-000007", "observed_at": stamp(-day),
         "valid_until": stamp(day)}]),
    "advert-no-records": advert(stamp(-day), stamp(day), records=[]),
    "advert-unparseable-instant": advert("not-an-instant", stamp(day)),
}
for name, payload in cases.items():
    (work / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")

bodies = {
    "body-good": good_body,
    "body-window-closed": body(stamp(-2 * hour), stamp(-hour)),
    "body-outlives-advert": body(stamp(-hour), stamp(2 * day)),
    "body-wrong-advert": body(stamp(-hour), stamp(hour), identifier="CADV-000006"),
    "body-missing-admitted-until": {"advertisement_id": "CADV-000007",
                                    "admitted_at": stamp(-hour)},
    "body-naive-admitted": {"advertisement_id": "CADV-000007",
                            "admitted_at": (now - hour).replace(tzinfo=None).isoformat(),
                            "admitted_until": (now + hour).replace(tzinfo=None).isoformat()},
}
for name, payload in bodies.items():
    (work / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")

(work / "advert-not-json.json").write_text("this is not JSON at all\n")
FIXTURES

# name | body fixture | advert fixture | expect (ok|refuse) | required text
GATE1_CASES=(
"an open window with a sound body|body-good|advert-open|ok|ok  observed_at <= now < valid_until"
"the governing advertisement has expired|body-good|advert-expired|refuse|EXPIRED at the current clock"
"the governing advertisement has not opened|body-good|advert-not-open|refuse|has not opened yet"
"the inspect output is not JSON|body-good|advert-not-json|refuse|could not read the inspect output"
"the advertisement has no valid_until|body-good|advert-missing-valid-until|refuse|has no valid_until"
"the advertisement instants carry no offset|body-good|advert-naive-instants|refuse|carries no timezone offset"
"the advertisement instant does not parse|body-good|advert-unparseable-instant|refuse|is not an ISO-8601 instant"
"the inspected record is a different advertisement|body-good|advert-wrong-identity|refuse|is not CADV-000007"
"inspect returned two records|body-good|advert-two-records|refuse|exactly one advertisement record"
"inspect returned no records|body-good|advert-no-records|refuse|exactly one advertisement record"
"the admission window has closed|body-window-closed|advert-open|refuse|admission window closed at the current clock"
"admitted_until outlives the advertisement|body-outlives-advert|advert-open|refuse|outlives the advertisement"
"the body binds a different advertisement|body-wrong-advert|advert-open|refuse|does not bind CADV-000007"
"the body has no admitted_until|body-missing-admitted-until|advert-open|refuse|has no admitted_until"
"the body instants carry no offset|body-naive-admitted|advert-open|refuse|carries no timezone offset"
)

for case in "${GATE1_CASES[@]}"; do
  IFS='|' read -r name body_fixture advert_fixture expect needle <<<"${case}"
  out="${WORK}/gate1-case.out"
  status=0
  python3 "${gate1_prog}" "${WORK}/${body_fixture}.json" "${WORK}/${advert_fixture}.json" \
    > "${out}" 2>&1 || status=$?
  if [[ "${expect}" == "ok" ]]; then
    if (( status == 0 )) && grep -qF "${needle}" "${out}"; then
      pass "gate 1 accepts: ${name}"
    else
      fail "gate 1 should accept: ${name} (status ${status})"
    fi
  else
    if (( status != 0 )) && grep -qF "${needle}" "${out}"; then
      pass "gate 1 refuses: ${name}"
    elif (( status != 0 )); then
      fail "gate 1 refused ${name} but not for the stated reason (${needle})"
    else
      fail "gate 1 ACCEPTED what it must refuse: ${name}"
    fi
  fi
done

# ---- section 3: the committed gate 1 shell construct, executed -------------
#
# Section 2 proves the program judges correctly. This proves the SHELL around
# it delivers both inputs and propagates the program's status -- the two things
# G11-BC-O got wrong and that no assertion about the program alone can see.
#
# `python3 -m tools.fabric.cli inspect` is stubbed, because the live store is
# not available here and the subject is the plumbing, not the CLI.

printf '\n--- committed gate 1, shell construct ---\n'

mkdir -p "${WORK}/stub"
cat > "${WORK}/stub/python3" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "-m" && "\${2:-}" == "tools.fabric.cli" ]]; then
  if [[ -n "\${STUB_INSPECT_FAIL:-}" ]]; then
    echo "stub: inspect refused" >&2
    exit 1
  fi
  cat "\${STUB_INSPECT_FILE}"
  exit 0
fi
exec "${REAL_PYTHON}" "\$@"
STUB
chmod +x "${WORK}/stub/python3"

run_gate1_construct() {
  local body_fixture="$1" advert_fixture="$2" out="$3"
  local runner="${WORK}/gate1-runner.sh"
  cp "${WORK}/${body_fixture}.json" "${WORK}/gate1-tmp.json"
  {
    printf 'set -Eeuo pipefail\n'
    printf 'TMP=%q\n' "${WORK}/gate1-tmp.json"
    cat "${gate1_region}"
    printf 'echo SENTINEL_GATE2_REACHED\n'
  } > "${runner}"
  local status=0
  PATH="${WORK}/stub:${PATH}" \
    STUB_INSPECT_FILE="${WORK}/${advert_fixture}.json" \
    STUB_INSPECT_FAIL="${STUB_INSPECT_FAIL:-}" \
    bash "${runner}" > "${out}" 2>&1 || status=$?
  return "${status}"
}

out="${WORK}/construct-ok.out"
status=0
run_gate1_construct body-good advert-open "${out}" || status=$?
if (( status == 0 )) && grep -q 'SENTINEL_GATE2_REACHED' "${out}" \
   && grep -q 'ok  now < admitted_until <= valid_until' "${out}"; then
  pass "gate 1 construct: both inputs arrive, the gate passes, control proceeds"
else
  fail "gate 1 construct: a sound case did not pass cleanly (status ${status})"
fi
if grep -q 'JSONDecodeError' "${out}"; then
  fail "gate 1 construct: the advertisement is still being read from a spent stdin"
else
  pass "gate 1 construct: the advertisement is read from its own channel, not stdin"
fi

# Every failing input must stop the construct dead, before the sentinel.
CONSTRUCT_FAILURES=(
"an expired advertisement|body-good|advert-expired|"
"an unparseable inspect output|body-good|advert-not-json|"
"an advertisement with no valid_until|body-good|advert-missing-valid-until|"
"naive instants|body-good|advert-naive-instants|"
"a closed admission window|body-window-closed|advert-open|"
"an admission outliving its advertisement|body-outlives-advert|advert-open|"
"inspect itself failing|body-good|advert-open|1"
)

for case in "${CONSTRUCT_FAILURES[@]}"; do
  IFS='|' read -r name body_fixture advert_fixture stub_fail <<<"${case}"
  out="${WORK}/construct-fail.out"
  status=0
  STUB_INSPECT_FAIL="${stub_fail}" run_gate1_construct "${body_fixture}" "${advert_fixture}" "${out}" || status=$?
  if (( status != 0 )) && ! grep -q 'SENTINEL_GATE2_REACHED' "${out}"; then
    pass "gate 1 construct refuses and stops: ${name}"
  elif (( status == 0 )); then
    fail "gate 1 construct returned success on: ${name}"
  else
    fail "gate 1 construct exited nonzero but control still reached gate 2: ${name}"
  fi
  if grep -q 'REFUSE' "${out}"; then
    pass "gate 1 construct states a refusal: ${name}"
  else
    fail "gate 1 construct failed silently: ${name}"
  fi
done

# Determinism. A fail-closed gate that only usually fails closed is not one.
deterministic=1
for _ in 1 2 3 4 5; do
  out="${WORK}/construct-repeat.out"
  status=0
  run_gate1_construct body-good advert-expired "${out}" || status=$?
  if (( status == 0 )) || grep -q 'SENTINEL_GATE2_REACHED' "${out}"; then
    deterministic=0
  fi
done
if (( deterministic == 1 )); then
  pass "gate 1 construct refuses an expired window on all 5 of 5 runs"
else
  fail "gate 1 construct did not refuse deterministically"
fi

# ---- section 4: the committed gate 2 check, executed -----------------------

printf '\n--- committed gate 2, eligibility check ---\n'

gate2_region="${WORK}/gate2-region.sh"
extract_between '# >>> GATE2_CHECK_BEGIN' '# <<< GATE2_CHECK_END' "${ARTIFACT}" > "${gate2_region}"
gate2_prog="${WORK}/gate2.py"
extract_between "<<'ELIG_PY'" 'ELIG_PY' "${gate2_region}" > "${gate2_prog}"

if [[ -s "${gate2_prog}" ]]; then
  pass "gate 2 was extracted from the committed artifact ($(wc -l < "${gate2_prog}") program lines)"
else
  fail "gate 2 could not be extracted from the committed artifact"
fi

if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "${gate2_prog}" 2>/dev/null; then
  pass "gate 2 is syntactically valid Python -- the G11-BC-O defect is gone"
else
  fail "gate 2 does not parse as Python"
fi

cat > "${WORK}/elig-eligible.json" <<'E1'
{"eligible": true, "conditions": [{"status": "met"}, {"status": "met"},
 {"status": "met"}], "unmet": [], "reasons": []}
E1
cat > "${WORK}/elig-not-eligible.json" <<'E2'
{"eligible": false, "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["trust"], "reasons": ["trust record withdrawn"]}
E2
cat > "${WORK}/elig-true-but-unmet.json" <<'E3'
{"eligible": true, "conditions": [{"status": "met"}, {"status": "unmet"}],
 "unmet": ["contract"], "reasons": []}
E3
cat > "${WORK}/elig-no-conditions.json" <<'E4'
{"eligible": true, "conditions": [], "unmet": [], "reasons": []}
E4
cat > "${WORK}/elig-missing-key.json" <<'E5'
{"eligible": true, "conditions": [{"status": "met"}], "reasons": []}
E5
printf 'not json\n' > "${WORK}/elig-not-json.json"

# name | fixture | expect | required text
GATE2_CASES=(
"an eligible result with no unmet conditions|elig-eligible|ok|3 of 3 met"
"an ineligible result|elig-not-eligible|refuse|did not return eligible true"
"eligible true alongside unmet conditions|elig-true-but-unmet|refuse|reported unmet conditions"
"a result with no conditions to judge|elig-no-conditions|refuse|no conditions to judge"
"a result missing a required key|elig-missing-key|refuse|has no unmet"
"a result that is not JSON|elig-not-json|refuse|could not read the compute-eligibility result"
)

for case in "${GATE2_CASES[@]}"; do
  IFS='|' read -r name fixture expect needle <<<"${case}"
  out="${WORK}/gate2-case.out"
  status=0
  python3 "${gate2_prog}" "${WORK}/${fixture}.json" > "${out}" 2>&1 || status=$?
  if [[ "${expect}" == "ok" ]]; then
    if (( status == 0 )) && grep -qF "${needle}" "${out}"; then
      pass "gate 2 accepts: ${name}"
    else
      fail "gate 2 should accept: ${name} (status ${status})"
    fi
  else
    if (( status != 0 )) && grep -qF "${needle}" "${out}"; then
      pass "gate 2 refuses: ${name}"
    elif (( status != 0 )); then
      fail "gate 2 refused ${name} but not for the stated reason (${needle})"
    else
      fail "gate 2 ACCEPTED what it must refuse: ${name}"
    fi
  fi
done

# The met count is reported, and it is the real one rather than a restatement.
out="${WORK}/gate2-count.out"
python3 "${gate2_prog}" "${WORK}/elig-eligible.json" > "${out}" 2>&1 || true
if grep -q 'eligible True | 3 of 3 met | unmet \[\] | reasons \[\]' "${out}"; then
  pass "gate 2 reports the met condition count it counted"
else
  fail "gate 2 did not report the condition count: $(head -1 "${out}")"
fi

# ---- section 5: the shapes must not come back ------------------------------
#
# Structural, and deliberately narrow: these two spellings cost a production
# ceremony, so they are refused by name in every committed freeze artifact.

printf '\n--- the defect shapes are absent from every freeze artifact ---\n'

# shellcheck disable=SC1003  # the trailing \\ is a BRE literal backslash, which
# is the whole point: it is what the G11-BC-O f-string expressions contain.
FSTRING_BACKSLASH='f"[^"]*{[^}]*\\'

# A detector nothing has ever tripped is decoration. Both are run first against
# the G11-BC-O shapes themselves, which are what they were written to catch.
if awk '
    /^[A-Z_]+$/ { prev_terminator = 1; next }
    /^[[:space:]]*<<</ { if (prev_terminator) { found = 1 } }
    { prev_terminator = 0 }
    END { exit(found ? 1 : 0) }
  ' "${WORK}/defect-gate1.sh"; then
  fail "detector self-check: the here-string detector does not flag the G11-BC-O gate 1 shape"
else
  pass "detector self-check: the here-string detector flags the G11-BC-O gate 1 shape"
fi

if grep -q "${FSTRING_BACKSLASH}" "${WORK}/defect-gate2.sh"; then
  pass "detector self-check: the f-string detector flags the G11-BC-O gate 2 shape"
else
  fail "detector self-check: the f-string detector does not flag the G11-BC-O gate 2 shape"
fi

for artifact in "${ROOT}"/provisioning/fabric/*.txt; do
  label="provisioning/fabric/$(basename "${artifact}")"

  # A here-string is not itself wrong, but a here-string on its own line
  # directly after a heredoc terminator is the G11-BC-O construct exactly.
  if awk '
      /^[A-Z_]+$/ { prev_terminator = 1; next }
      /^[[:space:]]*<<</ { if (prev_terminator) { found = 1 } }
      { prev_terminator = 0 }
      END { exit(found ? 1 : 0) }
    ' "${artifact}"; then
    pass "${label}: no here-string trailing a heredoc terminator"
  else
    fail "${label}: a here-string follows a heredoc terminator -- the G11-BC-O gate 1 shape"
  fi

  # A backslash inside an f-string expression is the G11-BC-O gate 2 shape.
  if grep -n "${FSTRING_BACKSLASH}" "${artifact}" > /dev/null 2>&1; then
    fail "${label}: a backslash appears inside an f-string expression -- the G11-BC-O gate 2 shape"
  else
    pass "${label}: no backslash inside an f-string expression"
  fi
done

# ---- section 6: one obvious control path -----------------------------------
#
# Stage order is asserted on the artifact itself, so a future edit cannot move
# the install above a gate without this failing.

printf '\n--- stage order ---\n'

line_of() { grep -n -m1 -F -e "$1" -- "${ARTIFACT}" | cut -d: -f1; }

# shellcheck disable=SC2016  # these are literal text to find in the artifact,
# not expressions for this shell to expand.
body_line="$(line_of 'test "${ACTUAL}" = "${REVIEWED}"')"
gate1_line="$(line_of '# >>> GATE1_BEGIN')"
gate2_line="$(line_of '# >>> GATE2_CHECK_BEGIN')"
install_line="$(line_of 'sudo install -o root -g cschott -m 0640')"
preflight_line="$(line_of '--preflight')"
# shellcheck disable=SC2016  # literal text in the artifact, as above.
unchanged_line="$(line_of 'test "${AFTER}" = "${FABRIC_BEFORE}"')"

order_ok=1
for pair in \
  "${body_line}:${gate1_line}" \
  "${gate1_line}:${gate2_line}" \
  "${gate2_line}:${install_line}" \
  "${install_line}:${preflight_line}" \
  "${preflight_line}:${unchanged_line}"
do
  before="${pair%%:*}"; after="${pair##*:}"
  if [[ -z "${before}" || -z "${after}" ]] || (( before >= after )); then
    order_ok=0
  fi
done
if (( order_ok == 1 )); then
  pass "stage order: body -> gate 1 -> gate 2 -> install -> preflight -> unchanged proof"
else
  fail "stage order is wrong or a stage is missing (body ${body_line}, gate1 ${gate1_line}, gate2 ${gate2_line}, install ${install_line}, preflight ${preflight_line}, unchanged ${unchanged_line})"
fi

# Both gates must run as their own command with their own status, never inside
# a command substitution whose status some later word can supply.
if extract_between '# >>> GATE1_BEGIN' '# <<< GATE1_END' "${ARTIFACT}" | grep -q '^if ! python3 - '; then
  pass "gate 1 runs as a plain command under 'if !', so its status is its own"
else
  fail "gate 1 no longer runs as a plain command under 'if !'"
fi
if extract_between '# >>> GATE2_CHECK_BEGIN' '# <<< GATE2_CHECK_END' "${ARTIFACT}" | grep -q '^if ! python3 - '; then
  pass "gate 2 runs as a plain command under 'if !', so its status is its own"
else
  fail "gate 2 no longer runs as a plain command under 'if !'"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Fabric freeze gate execution validation passed.\n'
else
  printf 'Fabric freeze gate execution validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
