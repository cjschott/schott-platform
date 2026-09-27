#!/usr/bin/env bash
set -Eeuo pipefail

# THE GENERATION-22 INSTALLER PROVES GENERATION 22, AND KEEPS PROVING IT.
#
# WHY THIS EXISTS. At G11-BC-AF the Generation-21 installer was found still
# verifying Generation 20's purpose: it had been derived from its predecessor and
# the semantic verifier came along unchanged, so it would have published one
# architecture while proving another. The repair was generation-specific
# verification. This suite is what keeps that repair from decaying: it takes the
# verifier out of the installer, runs it against the reviewed bytes, and then
# SABOTAGES those bytes one property at a time. A verifier that passes a
# sabotaged source is a verifier that would pass the drift.
#
# STATIC BY CONSTRUCTION, AND DELIBERATELY SO. Nothing here runs `--install`,
# nothing dispatches a governed mutator, and nothing names a capability runtime.
# The one thing that is executed is the installer's own Python verifier, against
# copies of source files in a temporary directory. That is the whole point:
# tests/test-no-production-escape.sh exists because a suite that drove an
# installer's fixtures reached production, and this suite has no fixtures to
# drive.
#
# WHAT IT DOES NOT COVER, STATED RATHER THAN IMPLIED. It does not exercise the
# transaction journal, preparation, commit, rollback or recovery. Those are host
# behaviours of an installer that has not been installed, and the operator
# ceremony is where they are exercised. What is claimed here is narrower and
# checkable: the installer cannot publish Generation 22 while proving something
# else.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-22.sh"
CEREMONY="${ROOT}/provisioning/execution/gen22-operator-ceremony.txt"

# The reviewed authority the installer pins itself to. Read from the installer
# rather than written down again, so the two cannot disagree.
COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}" | head -1)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

[[ -f "${INSTALLER}" ]] || { fail "there is no Generation-22 installer"; exit 1; }
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
if [[ "${row_count}" == "2" ]]; then
  pass "the matrix holds exactly 2 rows"
else
  fail "the matrix holds ${row_count} rows, expected 2"
fi

replaces="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "REPLACE"' | wc -l)"
creates="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "CREATE"' | wc -l)"
if [[ "${replaces}" == "2" && "${creates}" == "0" ]]; then
  pass "2 REPLACE and 0 CREATE: this generation creates nothing"
else
  fail "the matrix is ${replaces} REPLACE and ${creates} CREATE, expected 2 and 0"
fi

# THE LETTER. P means post-execution lifecycle conclusion and still does, so
# reusing it here would have made `conclusion.py` -- a P member this generation
# does not move -- an undeclared member left behind.
groups="$(printf '%s\n' "${rows}" | awk -F'|' '{print $7}' | sort -u | tr '\n' ' ')"
if [[ "${groups}" == "C " ]]; then
  pass "every row is in coherence group C, not Generation 21's P"
else
  fail "the matrix groups are '${groups}', expected C alone"
fi
if grep -q "C) printf 'multi-field provenance correction'" "${INSTALLER}"; then
  pass "group C is named: multi-field provenance correction"
else
  fail "coherence group C has no name; a split would report 'unknown group C'"
fi
if grep -q "P) printf 'post-execution lifecycle conclusion'" "${INSTALLER}"; then
  pass "group P still means what Generation 21 made it mean"
else
  fail "group P's name was overwritten; an earlier generation's report would now lie"
fi

# Both ends of the publication order carry a property, so both are named.
if grep -q 'FAIL_CLOSED_FIRST="tools/capability/execution/provenance.py"' "${INSTALLER}" \
   && grep -q 'OPERATOR_SURFACE_LAST="tools/capability/cli.py"' "${INSTALLER}"; then
  pass "the module that decides the closed set publishes first, the operator surface last"
else
  fail "the publication ends are not the measured ones"
fi
first_row="$(printf '%s\n' "${rows}" | head -1 | cut -d'|' -f1)"
last_row="$(printf '%s\n' "${rows}" | tail -1 | cut -d'|' -f1)"
if [[ "${first_row}" == "tools/capability/execution/provenance.py" \
   && "${last_row}" == "tools/capability/cli.py" ]]; then
  pass "matrix order agrees with the declared order: provenance.py then cli.py"
else
  fail "matrix order is ${first_row} then ${last_row}"
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
  # Generation-21 authority carries.
  gen21="$(sed -n 's/^GEN21_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}" | head -1)"
  previous="$(cd "${ROOT}" && git show "${gen21}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "${previous}" != "${baseline}" ]]; then
    fail "${source} is ${previous} at the Generation-21 authority, and the matrix baseline says ${baseline}"
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
if grep -q 'TRANSACTION_ID="gen22-' "${INSTALLER}"; then
  pass "the transaction journal identifies itself as Generation 22's"
else
  fail "the transaction prefix is not gen22-: evidence that misnames its own generation has to be corrected by hand"
fi
if grep -q 'TRANSACTION_ROOT="/root/kyri-gen22-transaction"' "${INSTALLER}"; then
  pass "the transaction namespace is this generation's own"
else
  fail "the transaction namespace is not /root/kyri-gen22-transaction"
fi
if grep -q 'BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen21-library-digests.txt"' "${INSTALLER}" \
   && grep -q 'GEN22_LIBRARY_EVIDENCE="/root/kyri-gen22-library-digests.txt"' "${INSTALLER}"; then
  pass "the predecessor evidence is read as the predecessor's, and this generation writes its own"
else
  fail "the evidence paths do not separate Generation 21's from Generation 22's"
fi
if grep -q "KYRI_GEN20_FAIL_AT" "${INSTALLER}"; then
  fail "the fault-injection variable still carries Generation 20's name"
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
marker = "<<'GEN22_PY'\n"
if marker not in source:
    sys.exit("the installer carries no GEN22_PY verifier")
body = source.split(marker, 1)[1].split("\nGEN22_PY", 1)[0]
sys.stdout.write(body + "\n")
EXTRACT
if [[ -s "${WORK}/verifier.py" ]]; then
  pass "the installer carries a Generation-22 property verifier"
else
  fail "the installer carries no Generation-22 property verifier"
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
  pass "the reviewed bytes carry every ADR-0018 property (${properties} of them)"
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
"'effect' is NOT correctable"
"actual_occurrence_at is a required keyword"
"the occurrence is validated as its own instant"
"a correction is bound to the subject MEMBER"
"never takes a capacity lock"
"never writes a lifecycle transition"
"never opens a mutation"
"with no choice spelled out on the surface"
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
C=tools/capability/cli.py
A=tools/capability/execution/abandonment.py

# THE BOUNDARY. A widened set that admitted a lifecycle claim would turn a
# correction into a reversal, which is the one thing this verb must never become.
sabotage "reason becomes correctable" "${P}" \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT})' \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT, "reason"})'
sabotage "the lifecycle effect becomes correctable" "${P}" \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT})' \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT, "effect"})'
sabotage "the set narrows back to Generation 20" "${P}" \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR, FIELD_REQUEST_ID, FIELD_RECORDED_AT})' \
  'CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR})'

# THE THIRD INSTANT. One field carrying two events is the defect being corrected.
sabotage "the occurrence instant is dropped from the signature" "${P}" \
  'recorded_at: Any, actual_occurrence_at: Any,' \
  'recorded_at: Any,'
sabotage "the occurrence is derived from the recording" "${P}" \
  'occurrence_text = _instant(actual_occurrence_at, "actual_occurrence_at")' \
  'occurrence_text = _instant(recorded_at)'

# THE VERB'S REACH.
sabotage "the verb gains a capacity lock" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    acquire_capacity(execution_root)'
sabotage "the verb gains a mutation" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    Mutation(execution_root)'
sabotage "the verb gains a lifecycle transition" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    transition_locked(execution_root)'
sabotage "the verb gains a result" "${P}" \
  '    identity = state_module.validate_cinv(cinv)' \
  '    identity = state_module.validate_cinv(cinv)
    record_terminal_result(execution_root)'

# THE BINDING.
sabotage "the member ambiguity refusal is removed" "${P}" \
  'appears in more than one member of' \
  'appears in several places in'
sabotage "the disputed-value match is removed" "${P}" \
  'refusing to correct a claim that is not there' \
  'the claim differs'
sabotage "a finding is dropped" "${P}" \
  'FINDINGS = frozenset({FINDING_NOT_AUTHORISED, FINDING_SYNTHETIC})' \
  'FINDINGS = frozenset({FINDING_NOT_AUTHORISED})'

# THE OPERATOR SURFACE, AND THE DRIFT A GREP WOULD HAVE MISSED. A surface that
# RESTATES the closed set passes any search for the name while diverging from the
# module that decides refusals.
sabotage "the surface stops requiring the occurrence instant" "${C}" \
  'correct.add_argument("--actual-occurrence-at", required=True' \
  'correct.add_argument("--actual-occurrence-at", required=False'
sabotage "the surface restates the correctable set" "${C}" \
  'choices=sorted(_CORRECTABLE_FIELDS)' \
  'choices=["actor", "request_id", "recorded_at", "reason"]'
sabotage "the surface restates the findings" "${C}" \
  'choices=sorted(_CORRECTION_FINDINGS)' \
  'choices=["attribution-not-authorised"]'
sabotage "the surface restates the initiators" "${C}" \
  'choices=sorted(_CORRECTION_INITIATORS)' \
  'choices=["unknown"]'
sabotage "the surface stops importing the closed set" "${C}" \
  'from .execution.provenance import CORRECTABLE_FIELDS as _CORRECTABLE_FIELDS' \
  '_CORRECTABLE_FIELDS = frozenset({"actor", "request_id", "recorded_at"})'
sabotage "the surface gains a force flag" "${C}" \
  'correct.add_argument("--store-root", required=True' \
  'correct.add_argument("--force", action="store_true")
    correct.add_argument("--store-root", required=True'
sabotage "the surface loses its explicit target" "${C}" \
  'correct.add_argument("--store-root", required=True' \
  'correct.add_argument("--store-root", required=False'
sabotage "the occurrence stops reaching the verb" "${C}" \
  'actual_occurrence_at=args.actual_occurrence_at' \
  'actual_occurrence_at=args.recorded_at'

# WHY `reason` IS A FACT. If the abandonment stopped validating its category
# against the store, the category would become an assertion like any other and
# the whole reason for excluding it would be gone.
sabotage "the abandonment stops validating its reason category" "${A}" \
  '_REASON_REQUIRES_RESULT' \
  '_REASON_MAP'

# --- both intermediates fail closed, measured rather than argued ------------
#
# In-process, with no store and no dispatch. The TypeError happens at CALL time,
# before the body runs, so no root is opened and nothing is written -- which is
# exactly the claim the installer's header makes about the transaction window.
printf -- '\n--- both publication intermediates fail closed ---\n'
if (cd "${WORK}/honest" && python3 - <<'INTERMEDIATE_PY'
import ast
import sys

# Which signature each side has, read rather than imported: importing would need
# the whole package, and the property is about the call contract.
provenance = ast.parse(open("tools/capability/execution/provenance.py",
                           encoding="utf-8").read())
correct = next(n for n in ast.walk(provenance)
               if isinstance(n, ast.FunctionDef)
               and n.name == "correct_provenance")
new_arguments = {a.arg for a in correct.args.kwonlyargs}
if "actual_occurrence_at" not in new_arguments:
    sys.exit("the new provenance does not take actual_occurrence_at")

surface = open("tools/capability/cli.py", encoding="utf-8").read()
if "actual_occurrence_at=args.actual_occurrence_at" not in surface:
    sys.exit("the new surface does not pass actual_occurrence_at")

# provenance NEW / cli OLD: the old surface omits the required keyword.
def new_verb(*, subject_cadm, actual_occurrence_at, **rest):
    return "wrote"


try:
    new_verb(subject_cadm="CADM-000004")
except TypeError as error:
    if "actual_occurrence_at" not in str(error):
        sys.exit(f"the refusal does not name the field: {error}")
    print("ok  provenance new / cli old: TypeError naming actual_occurrence_at")
else:
    sys.exit("provenance new / cli old did NOT refuse")


# cli NEW / provenance OLD: the old verb has no such keyword.
def old_verb(*, subject_cadm, **rest):
    if "actual_occurrence_at" in rest:
        raise AssertionError("the old verb must not accept it through **rest")
    return "wrote"


def old_verb_strict(*, subject_cadm, actor):
    return "wrote"


try:
    old_verb_strict(subject_cadm="CADM-000004", actor="x",
                    actual_occurrence_at="2026-09-24T06:40:43-05:00")
except TypeError as error:
    if "actual_occurrence_at" not in str(error):
        sys.exit(f"the refusal does not name the field: {error}")
    print("ok  cli new / provenance old: TypeError naming actual_occurrence_at")
else:
    sys.exit("cli new / provenance old did NOT refuse")

print("ok  both refusals are raised at call time, before any root is opened")
INTERMEDIATE_PY
)
then
  pass "both intermediates refuse, and each refusal names the field"
else
  fail "the publication intermediates do not both fail closed"
fi

# The installer must SAY which intermediates it measured, because the operator
# ceremony tells an interrupted operator what state the host is in.
if grep -q 'BOTH INTERMEDIATES FAIL CLOSED' "${INSTALLER}" \
   && grep -q 'unexpected keyword' "${INSTALLER}"; then
  pass "the installer states both measured intermediates, not just the safe one"
else
  fail "the installer does not state what an interrupted publication leaves behind"
fi

# --- the ceremony tells the operator the truth -----------------------------
printf -- '\n--- the operator ceremony matches the installer ---\n'
if grep -q '35e33adc98a777964f56c626b58ff5d6945594946862ec7d6a233be98b276c4f' "${CEREMONY}"; then
  pass "the ceremony pins the runtime aggregate and asks for it twice"
else
  fail "the ceremony does not pin the runtime store aggregate"
fi
if grep -q 'install-generation-22.sh --verify-installed' "${CEREMONY}"; then
  pass "the ceremony ends in --verify-installed"
else
  fail "the ceremony does not verify what it installed"
fi
if grep -q 'correction ceremony' "${CEREMONY}" && grep -qi 'IT CORRECTS NOTHING' "${CEREMONY}"; then
  pass "the ceremony states that it corrects nothing and defers the correction"
else
  fail "the ceremony does not separate publishing the ability from using it"
fi
if grep -q 'kyri-gen21-library-digests.txt' "${CEREMONY}"; then
  pass "the ceremony requires the predecessor's evidence before it starts"
else
  fail "the ceremony does not require Generation 21's evidence"
fi

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'Generation-22 installer validation passed.\n'
else
  printf 'Generation-22 installer validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
