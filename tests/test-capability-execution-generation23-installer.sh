#!/usr/bin/env bash
set -Eeuo pipefail

# THE GENERATION-23 INSTALLER PROVES GENERATION 23, AND KEEPS PROVING IT.
#
# WHY THIS EXISTS. At G11-BC-AF the Generation-21 installer was found still
# verifying Generation 20's purpose: derived from its predecessor, the semantic
# verifier came along unchanged, so it would have published one architecture
# while proving another. This suite is what keeps that repair from decaying for
# Generation 23: it takes the verifier out of the installer, runs it against the
# reviewed bytes, and then SABOTAGES those bytes one property at a time.
#
# WHAT GENERATION 23 IS FOR. An ADR-0016-era correction record carries no
# `actual_occurrence_at`, and Generation 22's resume comparison treated that
# absence as evidence of a different authority. It is not: the authority is
# identical and the record SHAPE differs. The properties below are mostly about
# keeping those two reasons apart, because conflating them is the defect.
#
# STATIC BY CONSTRUCTION. Nothing here runs `--install`, nothing dispatches a
# governed mutator, and nothing names a capability runtime. The one thing
# executed is the installer's own Python verifier, against copies of source files
# in a temporary directory. tests/test-no-production-escape.sh exists because a
# suite that drove an installer's fixtures reached production; this suite has no
# fixtures to drive.
#
# WHAT IT DOES NOT COVER, stated rather than implied. It does not exercise the
# transaction journal, preparation, commit, rollback or recovery. Those are host
# behaviours of an installer that has not been installed, and the operator
# ceremony is where they are exercised. The claim here is narrower and checkable:
# the installer cannot publish Generation 23 while proving something else.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-23.sh"
CEREMONY="${ROOT}/provisioning/execution/gen23-operator-ceremony.txt"

# The reviewed authority the installer pins itself to. Read from the installer
# rather than written down again, so the two cannot disagree.
COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}" | head -1)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

[[ -f "${INSTALLER}" ]] || { fail "there is no Generation-23 installer"; exit 1; }
[[ -n "${COMMIT}" ]] || { fail "the installer pins no reviewed commit"; exit 1; }

printf -- '--- the installer is well formed ---\n'
if bash -n "${INSTALLER}" 2>/dev/null; then
  pass "the installer parses"
else
  fail "the installer does not parse"
fi
if bash -n "${CEREMONY}" 2>/dev/null; then
  pass "the operator ceremony parses"
else
  fail "the operator ceremony does not parse"
fi

# --- the matrix, read from the installer ------------------------------------
printf -- '\n--- the matrix says what this generation moves ---\n'
matrix_rows() {
  sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"' | tr -d '"'
}
rows="$(matrix_rows)"
row_count="$(printf '%s\n' "${rows}" | grep -c . || true)"
if [[ "${row_count}" == "1" ]]; then
  pass "the matrix holds exactly 1 row"
else
  fail "the matrix holds ${row_count} rows, expected 1"
fi

replaces="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "REPLACE"' | wc -l)"
creates="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "CREATE"' | wc -l)"
if [[ "${replaces}" == "1" && "${creates}" == "0" ]]; then
  pass "1 REPLACE and 0 CREATE: this generation creates nothing"
else
  fail "the matrix is ${replaces} REPLACE and ${creates} CREATE, expected 1 and 0"
fi

# THE SURFACE DOES NOT MOVE, and that is the derived claim the header rests on.
if printf '%s\n' "${rows}" | awk -F'|' '{print $1}' | grep -qx "tools/capability/cli.py"; then
  fail "the matrix moves cli.py: the header's claim that no operator surface moves is false"
else
  pass "no operator surface moves: cli.py is not a row"
fi
if printf '%s\n' "${rows}" | awk -F'|' '{print $1}' | grep -qx "tools/capability/execution/provenance.py"; then
  pass "the one row is provenance.py, the module that owns the comparison rule"
else
  fail "the one row is not provenance.py"
fi

# THE LETTER. P means post-execution lifecycle conclusion and still does, so
# reusing it here would have made `conclusion.py` -- a P member this generation
# does not move -- an undeclared member left behind.
groups="$(printf '%s\n' "${rows}" | awk -F'|' '{print $7}' | sort -u | tr '\n' ' ')"
if [[ "${groups}" == "L " ]]; then
  pass "the row is in coherence group L, a new letter rather than a reused one"
else
  fail "the matrix groups are '${groups}', expected L alone"
fi
if grep -q "L) printf 'ADR-0016 correction shape compatibility'" "${INSTALLER}"; then
  pass "group L is named: ADR-0016 correction shape compatibility"
else
  fail "coherence group L has no name; a split would report 'unknown group L'"
fi
# THE EARLIER LETTERS STILL MEAN WHAT THEY MEANT. Reusing C would have made
# cli.py -- a C member this generation does not move -- an undeclared member left
# behind, which is exactly why P was not reused at G11-BC-AI either.
if grep -q "C) printf 'multi-field provenance correction'" "${INSTALLER}"; then
  pass "group C still means multi-field provenance correction"
else
  fail "group C's name was overwritten; an earlier generation's report would now lie"
fi
if grep -q "P) printf 'post-execution lifecycle conclusion'" "${INSTALLER}"; then
  pass "group P still means what Generation 21 made it mean"
else
  fail "group P's name was overwritten; an earlier generation's report would now lie"
fi

# Both ends of the publication order carry a property, so both are named.
if grep -q 'FAIL_CLOSED_FIRST="tools/capability/execution/provenance.py"' "${INSTALLER}" \
   && grep -q 'OPERATOR_SURFACE_LAST=""' "${INSTALLER}"; then
  pass "the module that owns the comparison rule is the first and only object, and no operator surface is declared"
else
  fail "the publication ends are not the derived ones for a single-row generation"
fi
# ONE ROW MEANS NO INTERMEDIATE STATE AT ALL, and the installer should say so
# rather than inheriting an argument about which half-published combination an
# operator would meet.
if grep -q "NO INTERMEDIATE PUBLICATION STATE" "${INSTALLER}"; then
  pass "the installer states that a single row cannot be half-published"
else
  fail "the installer does not say what an interrupted publication leaves behind"
fi
first_row="$(printf '%s\n' "${rows}" | head -1 | cut -d'|' -f1)"
if [[ "${first_row}" == "tools/capability/execution/provenance.py" ]]; then
  pass "matrix order agrees with the declared order: provenance.py, and nothing after it"
else
  fail "matrix row one is ${first_row}"
fi

# --- the digests are the reviewed bytes, both ends --------------------------
printf -- '\n--- both ends of every row are real bytes ---\n'
digest_drift=0
while IFS='|' read -r source baseline wanted; do
  [[ -n "${source}" ]] || continue
  observed="$(cd "${ROOT}" && git show "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "${observed}" != "${wanted}" ]]; then
    fail "${source} is ${observed} at ${COMMIT:0:7}, and the matrix says ${wanted}"
    digest_drift=$((digest_drift + 1))
  fi
  # The baseline must be a real predecessor, not a guess: it is what the
  # Generation-22 authority carries.
  gen22="$(sed -n 's/^GEN22_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}" | head -1)"
  previous="$(cd "${ROOT}" && git show "${gen22}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "${previous}" != "${baseline}" ]]; then
    fail "${source} is ${previous} at the Generation-22 authority, and the matrix baseline says ${baseline}"
    digest_drift=$((digest_drift + 1))
  fi
  if [[ "${wanted}" == "${baseline}" ]]; then
    fail "${source} declares the same digest both ends: the row moves nothing"
    digest_drift=$((digest_drift + 1))
  fi
done < <(printf '%s\n' "${rows}" | awk -F'|' '{print $1"|"$5"|"$6}')
(( digest_drift == 0 )) \
  && pass "both digests of both rows are the real reviewed and predecessor bytes"

# --- the installer names its own generation --------------------------------
printf -- '\n--- the installer is named for the generation it publishes ---\n'
if grep -q 'TRANSACTION_ID="gen23-' "${INSTALLER}"; then
  pass "the transaction journal identifies itself as Generation 23's"
else
  fail "the transaction prefix is not gen23-: evidence that misnames its own generation has to be corrected by hand"
fi
if grep -q 'TRANSACTION_ROOT="/root/kyri-gen23-transaction"' "${INSTALLER}"; then
  pass "the transaction namespace is this generation's own"
else
  fail "the transaction namespace is not /root/kyri-gen23-transaction"
fi
if grep -q 'BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen22-library-digests.txt"' "${INSTALLER}" \
   && grep -q 'GEN23_LIBRARY_EVIDENCE="/root/kyri-gen23-library-digests.txt"' "${INSTALLER}"; then
  pass "the predecessor evidence is read as Generation 22's, and this generation writes its own"
else
  fail "the evidence paths do not separate Generation 22's from Generation 23's"
fi
if grep -q "KYRI_GEN22_FAIL_AT" "${INSTALLER}"; then
  fail "the fault-injection variable still carries a predecessor's name"
else
  pass "the fault-injection variable is named for this generation"
fi

# NO CREATE, so the declared object count must not move. Two numbers that
# disagree would change the installed count at publication.
baseline_count="$(sed -n 's/^EXPECTED_LIBRARY_FILES_BASELINE=\([0-9]*\)$/\1/p' "${INSTALLER}")"
target_count="$(sed -n 's/^EXPECTED_LIBRARY_FILES_TARGET=\([0-9]*\)$/\1/p' "${INSTALLER}")"
if [[ -n "${baseline_count}" && "${baseline_count}" == "${target_count}" ]]; then
  pass "the declared object count does not move (${baseline_count} -> ${target_count}), which is what 0 CREATE means"
else
  fail "the declared count moves ${baseline_count} -> ${target_count} while the matrix creates nothing"
fi

# --- it cannot reach a governed store -------------------------------------
printf -- '\n--- nothing here can reach a governed store ---\n'
# Every matrix TARGET must be under the library root. A row that named a
# capability runtime, the handoff, Fabric or Trust would publish into evidence.
stray=0
while IFS='|' read -r source target; do
  [[ -n "${target}" ]] || continue
  [[ "${target}" == "\${LIBRARY_ROOT}/"* ]] \
    || { fail "row ${source} targets ${target}, outside the library root"; stray=$((stray + 1)); }
done < <(printf '%s\n' "${rows}" | awk -F'|' '{print $1"|"$2}')
(( stray == 0 )) && pass "every target is under the library root"

for forbidden in /data/kyri/capability-runtime /data/kyri/capability-handoff; do
  if grep -q -- "${forbidden}" "${INSTALLER}"; then
    # Named in prose is fine; named as something the installer WRITES is not.
    if grep -E "^[^#]*(rm|mv|cp|install|chmod|chown|mkdir|>)[^#]*${forbidden}" "${INSTALLER}" >/dev/null; then
      fail "the installer has a write path that names ${forbidden}"
    else
      pass "${forbidden} appears only in prose, never in a write path"
    fi
  else
    pass "${forbidden} is not named at all"
  fi
done

# The escape class, applied to this suite and to the installer. Neither may
# dispatch a governed mutator.
if grep -E "capability(\.cli)?[^#]*\b(abandon|conclude|correct-provenance|execute|authorise-launch|recover|invoke)\b" \
     "${INSTALLER}" | grep -v '^\s*#' | grep -q 'python3 -m'; then
  fail "the installer dispatches a governed mutator"
else
  pass "the installer dispatches no governed mutator"
fi

# --- THE VERIFIER, AND WHAT IT REFUSES ------------------------------------
#
# The installer's own Python, lifted out and run against copies. This is the
# check the G21 drift would have failed.
printf -- '\n--- ADR-0018 is proved from the reviewed bytes ---\n'
python3 - "${INSTALLER}" > "${WORK}/verifier.py" <<'EXTRACT'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
marker = "<<'GEN23_PY'\n"
if marker not in source:
    sys.exit("the installer carries no GEN23_PY verifier")
body = source.split(marker, 1)[1].split("\nGEN23_PY", 1)[0]
sys.stdout.write(body + "\n")
EXTRACT
if [[ -s "${WORK}/verifier.py" ]]; then
  pass "the installer carries a Generation-23 property verifier"
else
  fail "the installer carries no Generation-23 property verifier"
  exit 1
fi

# The verifier must be the ONE the installed check uses too, so a source pass
# and an installed pass cannot be two different claims.
if grep -q "prove_adr0018 \"\${LIBRARY_ROOT}\"" "${INSTALLER}"; then
  pass "--verify-installed proves the INSTALLED bytes with the same verifier, not only their digests"
else
  fail "--verify-installed does not run the property verifier against the installed library"
fi

# The three sources the verifier reads, staged from the reviewed commit.
SOURCES=(tools/capability/execution/provenance.py
         tools/capability/execution/abandonment.py
         tools/capability/cli.py)
stage_reviewed() {
  local into="$1" relative
  rm -rf "${into}"; mkdir -p "${into}"
  for relative in "${SOURCES[@]}"; do
    mkdir -p "${into}/$(dirname "${relative}")"
    (cd "${ROOT}" && git show "${COMMIT}:${relative}") > "${into}/${relative}"
  done
}

stage_reviewed "${WORK}/honest"
honest_out="${WORK}/honest.txt"
if python3 "${WORK}/verifier.py" "${WORK}/honest" > "${honest_out}" 2>&1; then
  properties="$(grep -c '^ok ' "${honest_out}")"
  pass "the reviewed bytes carry every correction property (${properties} of them)"
else
  fail "the reviewed bytes do not pass the installer's own verifier"
  sed -n 's/^FAIL /  refused: /p' "${honest_out}" >&2
fi

# The properties the reviewer required by name. Absent from the verifier's
# output, they are not being proved at all, whatever else passes.
printf -- '\n--- the verifier proves the properties by name ---\n'
required=(
"the correctable set is exactly actor, request_id and recorded_at"
"'reason' is NOT correctable"
"never takes a capacity lock"
"never opens a mutation"
"exactly one member is declared as a later-schema addition"
"a member the prior record does not carry is SKIPPED, not compared"
"an absence no ADR explains refuses on the record SHAPE"
"the phrase 'different authority' appears exactly once"
"the resume reads the occurrence from the stored record"
"Correction.actual_occurrence_at is str | None"
"correction_schema_version stays 1"
"nothing assigns into it"
)
missing=0
for phrase in "${required[@]}"; do
  grep -qF "${phrase}" "${honest_out}" \
    || { fail "the verifier never proves: ${phrase}"; missing=$((missing + 1)); }
done
(( missing == 0 )) && pass "all ${#required[@]} named properties appear in the verifier's own output"

# --- SABOTAGE. Each one must be caught, and caught by a named property. ----
printf -- '\n--- every sabotage is caught ---\n'
sabotage() {
  local title="$1" relative="$2" old="$3" new="$4"
  local tree="${WORK}/sab" out="${WORK}/sab.txt"
  stage_reviewed "${tree}"
  local path="${tree}/${relative}"
  if ! grep -qF -- "${old}" "${path}"; then
    fail "BROKEN SABOTAGE (${title}): the anchor is not in the reviewed ${relative}"
    return
  fi
  python3 - "${path}" "${old}" "${new}" <<'PATCH'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PATCH
  # The sabotage must still be Python. A source that stopped parsing would make
  # the verifier exit non-zero for the wrong reason, and a pass here would be
  # measuring nothing.
  if ! python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "${path}" 2>/dev/null; then
    fail "BROKEN SABOTAGE (${title}): the sabotaged ${relative} no longer parses"
    return
  fi
  if python3 "${WORK}/verifier.py" "${tree}" > "${out}" 2>&1; then
    fail "NOT CAUGHT: ${title}"
    return
  fi
  if grep -q '^FAIL ' "${out}"; then
    pass "caught: ${title} -- $(sed -n 's/^FAIL //p' "${out}" | head -1 | cut -c1-64)"
  else
    fail "BROKEN SABOTAGE (${title}): the verifier failed without naming a property"
  fi
}

P=tools/capability/execution/provenance.py
A=tools/capability/execution/abandonment.py
C=tools/capability/cli.py

# THE GENERATION-23 PROPERTY: the two refusal reasons stay apart.
sabotage "the later-schema set is emptied" "${P}" \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "ADR-0018"}' \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {}'
sabotage "the set admits a member no ADR ever added" "${P}" \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "ADR-0018"}' \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "ADR-0018", "actor": "ADR-0018"}'
sabotage "the set stops naming the ADR that added the member" "${P}" \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "ADR-0018"}' \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "later"}'
sabotage "the set is derived instead of declared" "${P}" \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = {MEMBER_ACTUAL_OCCURRENCE_AT: "ADR-0018"}' \
  'LATER_SCHEMA_MEMBERS: dict[str, str] = dict.fromkeys([MEMBER_ACTUAL_OCCURRENCE_AT], "ADR-0018")'
sabotage "an absent member is compared again" "${P}" \
  '        if key in absent:
            continue' \
  '        if False:
            continue'
sabotage "an unexplained absence stops refusing on its shape" "${P}" \
  'and absent from no schema change ' \
  'and absent for some reason '
sabotage "the resume echoes the request instead of the record" "${P}" \
  'actual_occurrence_at=prior.get(MEMBER_ACTUAL_OCCURRENCE_AT),' \
  'actual_occurrence_at=occurrence_text,'
sabotage "the return can no longer represent absence" "${P}" \
  '    actual_occurrence_at: str | None' \
  '    actual_occurrence_at: str'
sabotage "the comparison stops being its own function" "${P}" \
  'def _compare_for_resume(' \
  'def _compare_for_resume_unused('
sabotage "the comparison restates the closed set" "${P}" \
  'if key not in LATER_SCHEMA_MEMBERS' \
  'if key not in ("actual_occurrence_at",)'
sabotage "the schema version is bumped after all" "${P}" \
  'CORRECTION_SCHEMA_VERSION = 1' \
  'CORRECTION_SCHEMA_VERSION = 2'

# AND THE ADR-0018 ARCHITECTURE UNDERNEATH IT, still refused if it regresses.
sabotage "reason becomes correctable" "${P}" \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT})' \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT, "reason"})'
sabotage "the verb gains a capacity lock" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    acquire_capacity(execution_root)'
sabotage "the verb gains a mutation" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    Mutation(execution_root)'
sabotage "the surface restates the correctable set" "${C}" \
  'choices=sorted(_CORRECTABLE_FIELDS)' \
  'choices=["actor", "request_id", "recorded_at", "reason"]'
sabotage "the surface loses its explicit target" "${C}" \
  'correct.add_argument("--store-root", required=True' \
  'correct.add_argument("--store-root", required=False'
sabotage "the abandonment stops validating its reason category" "${A}" \
  '_REASON_REQUIRES_RESULT' \
  '_REASON_MAP'

# --- one row, so there is no intermediate to measure ------------------------
#
# Generation 22 had to measure both half-published combinations because two
# coupled objects moved. This generation moves one, so the property to check is
# that the installer SAYS so instead of inheriting an argument it no longer has --
# and that it has not quietly kept a second row.
printf -- '\n--- a single row has no intermediate state ---\n'

if [[ "$(printf '%s\n' "${rows}" | grep -c .)" == "1" ]]; then
  pass "there is one row, so the transaction holds either the new bytes or the old"
else
  fail "more than one row: an intermediate state exists and must be measured"
fi
if grep -q "BOTH INTERMEDIATES" "${INSTALLER}"; then
  fail "the installer still argues about two intermediates it does not have"
else
  pass "the installer does not inherit Generation 22's intermediate argument"
fi

# AND THE RULE IS REACHABLE FROM THE RELEASED MODULE, in process, with no store
# and no dispatch. The comparison is pure: it takes a prior record and the values
# a request carries, and decides. That is the whole reason it is a function.
if (cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - <<'RULEPY'
import sys
sys.path.insert(0, ".")
from tools.capability.execution import provenance as P

prior_legacy = {"cadm": "CADM-000002", "actor": "an-operator"}
compared = (("actor", "an-operator"),
            (P.MEMBER_ACTUAL_OCCURRENCE_AT, "2026-09-20T18:54:33-05:00"))

absent = P._compare_for_resume(prior_legacy, "CADM-000001", "actor", compared)
assert absent == (P.MEMBER_ACTUAL_OCCURRENCE_AT,), absent
print("ok  a legacy shape is reported as absent, not refused")

prior_modern = dict(prior_legacy,
                    **{P.MEMBER_ACTUAL_OCCURRENCE_AT: "2026-09-20T18:54:33-05:00"})
assert P._compare_for_resume(prior_modern, "CADM-000001", "actor", compared) == ()
print("ok  a modern shape has nothing absent")

try:
    P._compare_for_resume({"cadm": "X", "actor": "somebody-else"},
                          "CADM-000001", "actor", compared)
except P.ProvenanceRefused as error:
    assert "different authority" in str(error), str(error)
    print("ok  a member the record carries still refuses as a real difference")
else:
    sys.exit("a conflicting actor was accepted")

try:
    P._compare_for_resume({"cadm": "X"}, "CADM-000001", "actor", compared)
except P.ProvenanceRefused as error:
    message = str(error)
    assert "different authority" not in message, message
    assert "schema" in message or "shape" in message, message
    print("ok  an absence no ADR explains refuses on the shape, not the authority")
else:
    sys.exit("an uncomparable shape was accepted")
RULEPY
); then
  pass "the comparison rule decides all four cases, in process, with no store"
else
  fail "the comparison rule does not decide the four cases"
fi

# --- the ceremony tells the operator the truth -----------------------------
printf -- '\n--- the operator ceremony matches the installer ---\n'
if grep -q '7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99' "${CEREMONY}"; then
  pass "the ceremony pins the runtime aggregate and asks for it twice"
else
  fail "the ceremony does not pin the runtime store aggregate"
fi
if grep -q 'install-generation-23.sh --verify-installed' "${CEREMONY}"; then
  pass "the ceremony ends in --verify-installed"
else
  fail "the ceremony does not verify what it installed"
fi
# Generation 22 deferred a correction ceremony, so its suite checked for one.
# Generation 23 defers nothing of the kind -- it publishes a comparison rule and
# performs no administrative act at all -- so what must be stated is that, plus
# the one widening the reviewer ratifies by running it.
if grep -qi 'IT CORRECTS NOTHING AND RESUMES NOTHING' "${CEREMONY}"; then
  pass "the ceremony states that it corrects nothing and resumes nothing"
else
  fail "the ceremony does not say that it performs no administrative act"
fi
if grep -q 'str | None' "${CEREMONY}" \
   && grep -qi 'DO NOT RUN THIS' "${CEREMONY}"; then
  pass "the ceremony names the return-shape widening it ratifies, and says not to run without acceptance"
else
  fail "the ceremony does not name what running it ratifies"
fi
if grep -q 'kyri-gen22-library-digests.txt' "${CEREMONY}"; then
  pass "the ceremony requires Generation 22's evidence before it starts"
else
  fail "the ceremony does not require Generation 22's evidence"
fi

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'Generation-23 installer validation passed.\n'
else
  printf 'Generation-23 installer validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
