#!/usr/bin/env bash
set -Eeuo pipefail

# THE GENERATION-24 INSTALLER PROVES GENERATION 24, AND KEEPS PROVING IT.
#
# WHY THIS EXISTS. At G11-BC-AF the Generation-21 installer was found still
# verifying Generation 20's purpose: derived from its predecessor, the semantic
# verifier came along unchanged, so it would have published one architecture
# while proving another. This suite is what keeps that repair from decaying for
# Generation 24: it takes the verifier out of the installer, runs it against the
# reviewed bytes, and then SABOTAGES those bytes one property at a time.
#
# WHAT GENERATION 24 IS FOR. The released validator rejected the whole of
# production, because it tested execution authority with `adapter_identity`, a
# field the released supervised writer never fills in, and ignored the lifecycle
# journal, which `launch.py` names as the authority.
#
# WHY SABOTAGE MATTERS MORE HERE THAN USUAL. Every sabotage below is a plausible
# WRONG FIX, and every one of them makes production validate clean: suppress the
# finding, accept the launch-authorisation projection, read the current lifecycle
# state, make the default permissive, make the unreadable-journal path fail open.
# A digest check cannot tell any of them from the right fix, and neither can a
# test that only looks at production. The properties are what distinguish them.
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
# the installer cannot publish Generation 24 while proving something else.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-24.sh"
CEREMONY="${ROOT}/provisioning/execution/gen24-operator-ceremony.txt"

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
if [[ "${row_count}" == "3" ]]; then
  pass "the matrix holds exactly 1 row"
else
  fail "the matrix holds ${row_count} rows, expected 3"
fi

replaces="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "REPLACE"' | wc -l)"
creates="$(printf '%s\n' "${rows}" | awk -F'|' '$4 == "CREATE"' | wc -l)"
if [[ "${replaces}" == "3" && "${creates}" == "0" ]]; then
  pass "1 REPLACE and 0 CREATE: this generation creates nothing"
else
  fail "the matrix is ${replaces} REPLACE and ${creates} CREATE, expected 3 and 0"
fi

# THE SURFACE DOES NOT MOVE, and that is the derived claim the header rests on.
# THE OPERATOR SURFACE DOES MOVE, unlike Generation 23, and that is declared
# rather than discovered: `cli.py` is what reads the journal for the validator.
if printf '%s\n' "${rows}" | awk -F'|' '{print $1}' | grep -qx "tools/capability/cli.py"; then
  pass "the operator surface moves, and the installer declares that it does"
else
  fail "cli.py is not a row, but it is what reads the journal for the validator"
fi
for required in tools/capability/execution/state.py tools/capability/inspection.py; do
  if printf '%s\n' "${rows}" | awk -F'|' '{print $1}' | grep -qx "${required}"; then
    pass "${required##*/} is a row"
  else
    fail "${required} is not a row, so the authority change is incomplete"
  fi
done

# THE LETTER. E is new. Reusing T -- the terminal-result authority -- would have
# been tempting, since this generation is about when a terminal result is
# authorised; but T's members are not these, and reusing it would have made every
# unmoved T member an undeclared member left behind.
groups="$(printf '%s\n' "${rows}" | awk -F'|' '{print $7}' | sort -u | tr '\n' ' ')"
if [[ "${groups}" == "E " ]]; then
  pass "all three rows are in coherence group E, a new letter rather than a reused one"
else
  fail "the matrix groups are '${groups}', expected E alone"
fi
if grep -q "E) printf 'execution-authority evidence'" "${INSTALLER}"; then
  pass "group E is named: execution-authority evidence"
else
  fail "coherence group E has no name; a split would report 'unknown group E'"
fi
if grep -q "L) printf 'ADR-0016 correction shape compatibility'" "${INSTALLER}"; then
  pass "group L still means what Generation 23 made it mean"
else
  fail "group L's name was overwritten; an earlier generation's report would now lie"
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
if grep -q 'FAIL_CLOSED_FIRST="tools/capability/execution/state.py"' "${INSTALLER}" \
   && grep -q 'OPERATOR_SURFACE_LAST="tools/capability/cli.py"' "${INSTALLER}"; then
  pass "the accessor's provider is published first and the operator surface last"
else
  fail "the publication ends are not the dependency-derived ones"
fi
# THREE ROWS MEANS THE INTERMEDIATES EXIST, so the installer must reason about
# them rather than declare them impossible -- and must not inherit Generation
# 23's claim that it cannot be half-published.
if grep -q "NO INTERMEDIATE PUBLICATION STATE" "${INSTALLER}"; then
  fail "the installer inherits Generation 23's claim that it cannot be half-published"
else
  pass "the installer does not claim a three-row matrix has no intermediate state"
fi
if grep -q "INTERMEDIATE PUBLICATION STATES EXIST" "${INSTALLER}"; then
  pass "and it states that intermediate publication states exist"
else
  fail "the installer does not reason about its intermediate publication states"
fi

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
  # predecessor authority carries.
  gen22="$(sed -n 's/^PREDECESSOR_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}" | head -1)"
  previous="$(cd "${ROOT}" && git show "${gen22}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "${previous}" != "${baseline}" ]]; then
    fail "${source} is ${previous} at the predecessor authority, and the matrix baseline says ${baseline}"
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
# THIS BLOCK IS WHY G11-BC-AW HAPPENED. It read, verbatim:
#
#   if grep -q 'TRANSACTION_ID="gen23-' "${INSTALLER}"; then
#     pass "the transaction journal identifies itself as Generation 23's"
#
# It ASSERTED THE DEFECT. Inherited from Generation 23's suite, where `gen23-`
# was the correct answer, and never inverted -- so the installer created
# Generation-23 transaction IDs and this suite reported that as a pass. Fifty-one
# assertions agreed with it.
#
# The lesson is not "check for gen24- instead". A literal expectation is what
# rots. These checks now read the installer's DECLARED constants and require
# every identifier to be derived from them, so there is no literal to inherit.
declared_generation="$(sed -n 's/^GENERATION=\([0-9]\+\)$/\1/p' "${INSTALLER}" | head -1)"
declared_predecessor="$(sed -n 's/^PREDECESSOR_GENERATION=\([0-9]\+\)$/\1/p' "${INSTALLER}" | head -1)"
if [[ "${declared_generation}" == "24" && "${declared_predecessor}" == "23" ]]; then
  pass "the installer declares its roles: publishing ${declared_generation} over ${declared_predecessor}"
else
  fail "the installer declares generation '${declared_generation}' over '${declared_predecessor}'"
fi
# Derived, not literal. A literal prefix anywhere in the assignment is the
# committed defect, so a literal prefix is what this refuses.
if grep -qE 'TRANSACTION_ID="gen[0-9]' "${INSTALLER}"; then
  fail "the transaction identifier carries a LITERAL generation prefix: the G11-BC-AW defect"
else
  pass "the transaction identifier carries no literal generation prefix"
fi
for derived in TRANSACTION_ROOT TARGET_LIBRARY_EVIDENCE TARGET_HELPER_EVIDENCE \
               BASELINE_LIBRARY_EVIDENCE BASELINE_HELPER_EVIDENCE \
               PREPARED_SUFFIX BACKUP_SUFFIX; do
  if grep -qE "^${derived}=\"[^\"]*gen[0-9]" "${INSTALLER}"; then
    fail "${derived} hard-codes a generation number instead of deriving it"
  else
    pass "${derived} derives its generation from the declared constants"
  fi
done
# AND THE INSTALLER GATES ALL OF IT ITSELF, in every mode.
if grep -q 'require_generation_identity' "${INSTALLER}"; then
  pass "the installer gates its own generation identity"
else
  fail "the installer does not gate its own generation identity"
fi
if grep -qE "KYRI_GEN[0-9]+_FAIL_AT" "${INSTALLER}"; then
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
printf -- '\n--- the authority invariant is proved from the reviewed bytes ---\n'
python3 - "${INSTALLER}" > "${WORK}/verifier.py" <<'EXTRACT'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
marker = "<<'GEN24_PY'\n"
if marker not in source:
    sys.exit("the installer carries no GEN24_PY verifier")
body = source.split(marker, 1)[1].split("\nGEN24_PY", 1)[0]
sys.stdout.write(body + "\n")
EXTRACT
if [[ -s "${WORK}/verifier.py" ]]; then
  pass "the installer carries a Generation-24 property verifier"
else
  fail "the installer carries no Generation-24 property verifier"
  exit 1
fi

# The verifier must be the ONE the installed check uses too, so a source pass
# and an installed pass cannot be two different claims.
if grep -q "prove_result_authority \"\${LIBRARY_ROOT}\"" "${INSTALLER}"; then
  pass "--verify-installed proves the INSTALLED bytes with the same verifier, not only their digests"
else
  fail "--verify-installed does not run the property verifier against the installed library"
fi

# The three sources the verifier reads, staged from the reviewed commit.
SOURCES=(tools/capability/execution/state.py
         tools/capability/inspection.py
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
  pass "the reviewed bytes carry every authority property (${properties} of them)"
else
  fail "the reviewed bytes do not pass the installer's own verifier"
  sed -n 's/^FAIL /  refused: /p' "${honest_out}" >&2
fi

# The properties the reviewer required by name. Absent from the verifier's
# output, they are not being proved at all, whatever else passes.
printf -- '\n--- the verifier proves the properties by name ---\n'
required=(
"state.py defines launch_authorised"
"launch_authorised reads the journal through _scan"
"and validates the chain with _resolve before believing a member"
"and does NOT reduce to the current state, which cannot prove history"
"and writes nothing, repairs nothing and reads no clock"
"and the state it looks for is LAUNCH_AUTHORIZED"
"cannot treat one as proof of authority"
"inspection.py defines the authority predicate _execution_authorised"
"validate_store takes launch_authorised keyword-only"
"and its default is None, which means nothing is proven"
"the result-without-execution-authority finding still exists"
"and validate_store still reaches it, so this is not a suppression"
"the predicate accepts adapter-bound authority"
"the predicate accepts journalled supervised authority"
"one per accepted authority shape"
"PROJECTION, which launch.py says is not the authority"
"cannot accept a terminal one as proof"
"cli.py defines _supervised_launch_authority"
"and every failure path returns None, which is 'not proven'"
"and command_validate supplies the journal evidence"
"and still exits EXIT_DENIED when findings are non-empty"
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

S=tools/capability/execution/state.py
I=tools/capability/inspection.py
C=tools/capability/cli.py

# THE GENERATION-24 PROPERTY: authority comes from the journal's HISTORY, the
# predicate keeps exactly three accept paths, and the finding still fires.
#
# Each sabotage below is a plausible WRONG FIX for F7, not a random mutation.
# Every one of them makes production validate clean, which is precisely why a
# digest check and a production-only test cannot tell them from the right fix.

# 1. Reduce the accessor to the current state. Accepts an invocation abandoned
#    straight from `reserved`, because `abandoned` is a legal closure from it.
sabotage "the accessor reduces to the current state" "${S}" \
  "    for cinv, records in _scan(root).items():" \
  "    for cinv, records in all_states(root).items():"

# 2. Treat a terminal closure as proof. `CONCLUDED` happens to be sound;
#    `ABANDONED` is not, and a single membership test cannot distinguish them.
sabotage "a terminal closure is treated as proof of authority" "${S}" \
  "                    == LifecycleState.LAUNCH_AUTHORIZED.value):" \
  "                    in (LifecycleState.LAUNCH_AUTHORIZED.value,
                        LifecycleState.CONCLUDED.value)):"

# 3. Stop validating the chain, so a journal with a gap or a broken `previous`
#    link still yields an answer.
sabotage "the chain is no longer validated before it is believed" "${S}" \
  "        _resolve(records, cinv)" \
  "        pass"

# 4. The predicate gains a fourth accept path that swallows everything.
sabotage "the predicate gains an unconditional accept" "${I}" \
  "    if adapter_identity is not None:" \
  "    if True:"

# 5. The supervised check is removed, which is the pre-fix behaviour and
#    rejects production again -- the regression this generation exists to stop.
sabotage "the supervised accept path is removed" "${I}" \
  "    if identity in authorised:" \
  "    if False:"

# 6. The finding is deleted. The laziest wrong fix, and the one a
#    production-only test would never notice.
sabotage "the finding is suppressed instead of answered" "${I}" \
  "                    f\"{identity}: {FINDING_RESULT_WITHOUT_AUTHORITY}\")" \
  "                    f\"{identity}: {FINDING_OUTCOME_MISMATCH}\")"

# 7. The default becomes permissive, so a caller that passes nothing gets
#    everything authorised rather than nothing proven.
sabotage "the default stops meaning 'nothing is proven'" "${I}" \
  "                   launch_authorised: Collection[str] | None = None) -> Report:" \
  "                   launch_authorised: Collection[str] | None = ()) -> Report:"

# 8. The keyword is dropped, which is the pre-fix signature.
sabotage "validate_store loses the authority argument" "${I}" \
  "                   launch_authorised: Collection[str] | None = None) -> Report:" \
  "                   _unrelated: Collection[str] | None = None) -> Report:"

# 9. The operator surface stops reading the journal.
sabotage "command_validate stops supplying the journal evidence" "${C}" \
  "        launch_authorised=_supervised_launch_authority(args.store_root))" \
  "        launch_authorised=None)"

# 10. The fail-closed path becomes fail-open: an unreadable journal would
#     authorise every result instead of none.
sabotage "the journal read is replaced by a hard-coded permissive answer" "${C}" \
  "        return state_module.launch_authorised(execution_root)" \
  "        return frozenset({\"CINV-000002\", \"CINV-000003\"})"

# 11. The verb stops failing the exit code, so findings become advisory.
sabotage "findings stop denying the exit code" "${C}" \
  "    return EXIT_SUCCESS if sound else EXIT_DENIED" \
  "    return EXIT_SUCCESS"

# --- three rows, so the intermediates exist and the order must cover them ---
#
# Generation 23 moved one object and could argue that no intermediate state
# existed. This one moves three, so the property is the opposite: the
# intermediates DO exist, every one of them must be a working library, and the
# declared order is what makes that true.
printf -- '\n--- three rows, and the order makes every intermediate work ---\n'

if [[ "$(printf '%s\n' "${rows}" | grep -c .)" == "3" ]]; then
  pass "there are three rows, so intermediate publication states exist"
else
  fail "expected three rows; an intermediate state would be unaccounted for"
fi

# THE PROVIDER FIRST. `cli.py` published before `state.py` would call an
# accessor that does not exist, so the order is not a preference.
if grep -q 'FAIL_CLOSED_FIRST="tools/capability/execution/state.py"' "${INSTALLER}"; then
  pass "the provider of the new accessor is published first"
else
  fail "the installer does not publish the accessor's provider first"
fi
if grep -q 'OPERATOR_SURFACE_LAST="tools/capability/cli.py"' "${INSTALLER}"; then
  pass "the operator surface is published last, after what it calls exists"
else
  fail "the installer does not publish the operator surface last"
fi
if grep -q "the matrix is 3 REPLACE and 0 CREATE" "${INSTALLER}"; then
  pass "the row count is pinned, so a fourth row is a reviewable edit"
else
  fail "the installer does not pin its row count"
fi
if grep -q "A SINGLE ROW ALSO MEANS" "${INSTALLER}"; then
  fail "the installer still inherits Generation 23's single-row argument"
else
  pass "the installer does not inherit Generation 23's single-row argument"
fi

# AND THE RULE IS REACHABLE FROM THE RELEASED MODULE, in process, with no store
# and no dispatch. The predicate is pure: it takes an identity, an adapter
# binding, a legacy flag and the journalled set, and decides. That is the whole
# reason it is a function rather than four lines inside a loop.
if (cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - <<'RULEPY'
import sys
sys.path.insert(0, ".")
from tools.capability import inspection as I

authorised = frozenset({"CINV-000003"})

# SUPERVISED: the journal proves it, and nothing else is needed.
assert I._execution_authorised("CINV-000003", None, False, authorised) is True
print("ok  a journalled launch authorises a terminal result")

# And authority does not transfer between identities.
assert I._execution_authorised("CINV-000002", None, False, authorised) is False
print("ok  authority for one invocation does not authorise another")

# ADAPTER-BOUND: permitted, with no journal at all.
assert I._execution_authorised("CINV-000006", "python-podman-v1", False,
                               frozenset()) is True
print("ok  an adapter-bound invocation is authorised with no journal")

# LEGACY: kept exactly as accepted.
assert I._execution_authorised("CINV-000005", None, True, frozenset()) is True
print("ok  the legacy flag is honoured where it is set")

# AND THE ONE THAT MATTERS: nothing proven means nothing authorised.
assert I._execution_authorised("CINV-000099", None, False, frozenset()) is False
print("ok  an invocation with no evidence of any shape is NOT authorised")

# An empty set is not the same as None at the call site, and neither authorises.
assert I._execution_authorised("CINV-000099", None, False, frozenset()) is False
print("ok  and an empty journal authorises nothing, which is fail-closed")
RULEPY
); then
  pass "the authority predicate decides all six cases, in process, with no store"
else
  fail "the authority predicate does not decide the six cases"
fi

# --- the ceremony tells the operator the truth -----------------------------
# --- GENERATION IDENTITY. Each role sabotaged independently. ---------------
#
# WHY THIS SECTION EXISTS. G11-BC-AW found this installer committed creating
# `gen23-` transaction IDs, announcing "Generation 23 is already installed", and
# carrying its predecessor's commit under a `GEN22_COMMIT` name whose message
# claimed it checked Generation 23. `--verify-source` passed. The 51 assertions
# above passed. Every one of those defects is a STRING, and nothing tied the
# strings to the generation being installed.
#
# So the installer now derives all four roles from two constants and gates them,
# and this section sabotages each role on a COPY and requires the gate to refuse.
# The copy keeps the real filename inside a temporary directory, because the gate
# checks the filename against the declared generation -- a copy named anything
# else would be "caught" for the wrong reason, and every sabotage below would
# pass while proving nothing.
printf -- '\n--- generation identity: every role refuses independently ---\n'

# HOW THIS IS EXERCISED, and why not through `--verify-source`.
#
# The first version of this section ran the sabotaged installer with
# `--verify-source` and required a refusal. Every sabotage was "caught" -- by
# `STOP: the working tree is not clean`, which fires long before the identity
# gate and fires whenever this suite runs with uncommitted changes. Nine
# sabotages passed while proving nothing, which is the same vacuous-pass shape as
# the gen23- check above. The output said so plainly, in nine identical lines.
#
# So the gate is extracted and run in isolation: its own source, its own stubs,
# a sabotaged copy as its SELF. Tree-independent, and the refusal that comes back
# is the gate's own.
extract_identity_gate() {
  local from="$1" into="$2"
  # The stubs come from a quoted heredoc, not printf: escaping them through
  # printf produced a malformed `halt` whose refusals carried no message, and
  # every case then reported "refused without naming a reason".
  cat > "${into}" <<'STUBS'
set -Eeuo pipefail
halt() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok %s\n' "$1"; }
TRANSACTION_ID=""
STUBS
  {
    # The declarations the gate reads, taken from the copy under test.
    sed -n -E '/^(GENERATION|PREDECESSOR_GENERATION)=[0-9]+$/p' "${from}"
    sed -n -E '/^(TRANSACTION_ROOT|BASELINE_LIBRARY_EVIDENCE|BASELINE_HELPER_EVIDENCE|TARGET_LIBRARY_EVIDENCE|TARGET_HELPER_EVIDENCE)=/p' "${from}"
    # SELF is supplied by the caller, so the gate reads the copy under test.
    printf 'SELF="%s"\n' "${from}"
    # The gate itself.
    awk '/^require_generation_identity\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${from}"
    printf 'require_generation_identity\n'
  } >> "${into}"
}

# The extraction must actually contain the gate, or every case below measures an
# empty script.
probe="${WORK}/identity-probe.sh"
extract_identity_gate "${INSTALLER}" "${probe}"
if grep -q 'require_generation_identity() {' "${probe}" \
   && grep -qE '^GENERATION=[0-9]+$' "${probe}" \
   && grep -qE '^PREDECESSOR_GENERATION=[0-9]+$' "${probe}"; then
  pass "the generation-identity gate and its declarations extract cleanly"
else
  fail "the identity gate did not extract; the cases below would measure nothing"
fi

# And the UNSABOTAGED gate must pass, or a refusal proves nothing.
if (cd "${ROOT}" && bash "${probe}" > "${WORK}/identity-clean.txt" 2>&1); then
  pass "the unsabotaged identity gate passes: $(sed -n 's/^ok //p' "${WORK}/identity-clean.txt" | cut -c1-58)"
else
  fail "the unsabotaged identity gate refuses: $(sed -n 's/^STOP: //p' "${WORK}/identity-clean.txt" | head -1)"
fi

identity_sabotage() {
  local title="$1" old="$2" new="$3"
  local dir="${WORK}/identity-case" copy script out
  rm -rf "${dir}"; mkdir -p "${dir}"
  # THE COPY KEEPS THE REAL FILENAME. The gate checks the filename against the
  # declared generation, so a copy named anything else would refuse for that
  # reason and every case would be "caught" without testing its own property.
  copy="${dir}/install-generation-24.sh"
  cp "${INSTALLER}" "${copy}"
  if ! grep -qF -- "${old}" "${copy}"; then
    fail "BROKEN SABOTAGE (${title}): the anchor is not in the installer"
    return
  fi
  python3 - "${copy}" "${old}" "${new}" <<'IDPATCH'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
IDPATCH
  if ! bash -n "${copy}" 2>/dev/null; then
    fail "BROKEN SABOTAGE (${title}): the sabotaged installer no longer parses"
    return
  fi
  script="${dir}/probe.sh"
  extract_identity_gate "${copy}" "${script}"
  out="${dir}/out.txt"
  if (cd "${ROOT}" && bash "${script}" > "${out}" 2>&1); then
    fail "NOT CAUGHT: ${title}"
    return
  fi
  if grep -q '^STOP: ' "${out}"; then
    pass "caught: ${title} -- $(sed -n 's/^STOP: //p' "${out}" | head -1 | cut -c1-62)"
  else
    fail "BROKEN SABOTAGE (${title}): the gate refused without naming a reason"
  fi
}

# ROLE 1 -- THE TRANSACTION PREFIX. The committed defect, exactly.
# The opening brace, assembled once. A single-quoted anchor containing ${...} is
# the shape this repository's ShellCheck refuses, and an anchor that quotes an
# expression should not read as one.
B="$(printf '\x24\x7b')"
GEN="gen${B}GENERATION}"
PRED="gen${B}PREDECESSOR_GENERATION}"

identity_sabotage "the transaction prefix reverts to the predecessor's" \
  "TRANSACTION_ID=\"${GEN}-" \
  "TRANSACTION_ID=\"gen23-"
identity_sabotage "the transaction prefix is hard-coded to this generation" \
  "TRANSACTION_ID=\"${GEN}-" \
  "TRANSACTION_ID=\"gen24-"

# ROLE 2 -- THE PREDECESSOR IS THE EVIDENCE BASELINE.
identity_sabotage "the baseline evidence names the wrong generation" \
  "BASELINE_LIBRARY_EVIDENCE=\"/root/kyri-${PRED}-library-digests.txt\"" \
  'BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen22-library-digests.txt"'

# ROLE 3 -- THE TARGET IS THIS INSTALLER'S OWN GENERATION.
identity_sabotage "the target evidence names the predecessor" \
  "TARGET_LIBRARY_EVIDENCE=\"/root/kyri-${GEN}-library-digests.txt\"" \
  'TARGET_LIBRARY_EVIDENCE="/root/kyri-gen23-library-digests.txt"'
identity_sabotage "the transaction root names the predecessor" \
  "TRANSACTION_ROOT=\"/root/kyri-${GEN}-transaction\"" \
  'TRANSACTION_ROOT="/root/kyri-gen23-transaction"'
identity_sabotage "the declared generation does not match the filename" \
  'GENERATION=24' \
  'GENERATION=25'
identity_sabotage "the generation does not sit on its immediate predecessor" \
  'PREDECESSOR_GENERATION=23' \
  'PREDECESSOR_GENERATION=22'

# ROLE 4 -- THE DIAGNOSTICS AGREE WITH THOSE ROLES.
identity_sabotage "a success diagnostic names a generation literally" \
  "ok \"Generation ${B}GENERATION} is already installed: nothing to do\"" \
  'ok "Generation 23 is already installed: nothing to do"'
identity_sabotage "a rollback diagnostic names a generation literally" \
  "bad \"the transaction rolled back: the host remains at Generation ${B}PREDECESSOR_GENERATION} and nothing was installed\"" \
  'bad "the transaction rolled back: the host is at Generation 22 and nothing was installed"'

# AND THE PREDECESSOR COMMIT IS THE PREDECESSOR'S, which is the defect the
# reworded message hid: the value and the claim have to be the same generation.
if grep -q 'PREDECESSOR_COMMIT="736c3716c037fabd9fca7c6b8eb97dc39de55c95"' "${INSTALLER}"; then
  pass "the predecessor commit is Generation 23's own reviewed authority"
else
  fail "the predecessor commit is not Generation 23's; a reworded message would hide it"
fi
# AN ASSIGNMENT, not any mention: the installer's own comments explain the
# GEN22_COMMIT defect by name, and a check that matched prose would refuse the
# explanation along with the defect.
if grep -qE '^GEN[0-9]+_COMMIT=' "${INSTALLER}"; then
  fail "the predecessor commit is still assigned under a generation-numbered name"
else
  pass "no assignment names a generation the installer does not install on"
fi

printf -- '\n--- the operator ceremony matches the installer ---\n'
if grep -q '7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99' "${CEREMONY}"; then
  pass "the ceremony pins the runtime aggregate and asks for it twice"
else
  fail "the ceremony does not pin the runtime store aggregate"
fi
if grep -q 'install-generation-24.sh --verify-installed' "${CEREMONY}"; then
  pass "the ceremony ends in --verify-installed"
else
  fail "the ceremony does not verify what it installed"
fi
# Generation 24 publishes a validator rule and performs no administrative act,
# so the ceremony must say that -- and must name the ONE observable difference
# the reviewer ratifies by running it, which is the exit code of a read-only
# verb changing from 1 to 0.
if grep -qi 'IT VALIDATES NOTHING AND REPAIRS NOTHING' "${CEREMONY}"; then
  pass "the ceremony states that it validates nothing and repairs nothing"
else
  fail "the ceremony does not say that it performs no administrative act"
fi
if grep -q 'findings": \[\]' "${CEREMONY}" \
   && grep -q 'exit=0' "${CEREMONY}"; then
  pass "the ceremony names the observable difference it ratifies: findings [] and exit 0"
else
  fail "the ceremony does not name what running it ratifies"
fi
if grep -q 'kyri-gen23-library-digests.txt' "${CEREMONY}"; then
  pass "the ceremony requires Generation 23's evidence before it starts"
else
  fail "the ceremony does not require Generation 23's evidence"
fi

# --- THE CEREMONY'S F7 VERDICT MUST RUN THE INSTALLED LIBRARY -------------
#
# WHY (G11-BC-AX). The ceremony starts `cd /opt/schott-platform`, so a bare
# `python3 -m tools.capability.cli` resolves the REPOSITORY copy -- which
# already carries the Generation-24 fix. Measured before installation, the two
# copies disagree completely:
#
#   /opt/schott-platform/tools/capability/cli.py   findings []  exit 0
#   /usr/lib/kyri/python/tools/capability/cli.py   2 findings   exit 1
#
# So the first version of that block would have printed `findings: []` and
# `exit=0` before anything was installed. The closure-blocking finding lives in
# the INSTALLED runtime, and only the installed runtime can retire it.
#
# The property is checked STRUCTURALLY, on the invocation itself: the validator
# call must be preceded, inside the same subshell, by an explicit change into
# the installed library -- or carry an explicit installed PYTHONPATH. Grepping
# the file for the string "/usr/lib/kyri/python" would pass on a ceremony that
# merely mentioned it in a comment.
printf -- '\n--- the ceremony proves F7 against the INSTALLED library ---\n'

ceremony_resolves_installed() {
  local file="$1"
  python3 - "$file" <<'RESOLVEPY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
lines = text.splitlines()

# Every validator invocation in the ceremony, by line index.
calls = [i for i, line in enumerate(lines)
         if "tools.capability.cli validate" in line and not line.lstrip().startswith("#")]
if not calls:
    sys.exit("no validator invocation in the ceremony")

for index in calls:
    # Walk back over the enclosing block to the subshell that opens it, and
    # require an explicit installed resolution between the two.
    resolved = False
    for j in range(index - 1, max(index - 25, -1), -1):
        bare = lines[j].strip()
        if bare.startswith("#"):
            continue
        if re.match(r"^cd /usr/lib/kyri/python\s*$", bare):
            resolved = True
            break
        if "PYTHONPATH=" in bare and "/usr/lib/kyri/python" in bare:
            resolved = True
            break
        # An opening subshell with nothing installed-resolving inside it means
        # this invocation resolves from wherever the ceremony last was.
        if bare.endswith('="$(') or bare == "(" or bare.startswith("installed_validate_out="):
            break
        if re.match(r"^cd /opt/schott-platform\s*$", bare):
            break
    if not resolved:
        sys.exit(f"the validator invocation at line {index + 1} does not "
                 "explicitly resolve the installed library")
print(f"ok  all {len(calls)} validator invocation(s) resolve the installed library")
RESOLVEPY
}

if ceremony_resolves_installed "${CEREMONY}" > "${WORK}/resolve.txt" 2>&1; then
  pass "$(sed -n 's/^ok  //p' "${WORK}/resolve.txt")"
else
  fail "the ceremony's F7 verdict can resolve tools.capability from the repository: $(cat "${WORK}/resolve.txt")"
fi

# AND THE VERDICT IS ASSERTED, not printed. All three conditions, and a
# non-zero exit must stop the ceremony rather than scroll past.
ceremony_body="$(cat "${CEREMONY}")"
for required in 'cd /usr/lib/kyri/python' 'installed_validate_rc'                 'F7 is not retired' 'not reported'; do
  if grep -qF -- "${required}" <<<"${ceremony_body}"; then
    pass "the ceremony carries: ${required}"
  else
    fail "the ceremony does not carry: ${required}"
  fi
done
if grep -vE '^\s*#' <<<"${ceremony_body}" | grep -qF 'echo "exit=$?"'; then
  fail "the ceremony still reads the exit code after a command set -e would have aborted on"
else
  pass "no executable line reads an exit code set -e would never let it reach"
fi

# SABOTAGE: put the verdict back to repository resolution.
#
# GUARDED, because the first version of this was not. Its heredoc lost a newline
# escape, the Python died with a SyntaxError, and the function returned WITHOUT
# calling pass or fail -- so the sabotage contributed no verdict at all and the
# suite reported 77 PASS / 0 FAIL with this case silently absent. Every failure
# path below now reports.
sabotage_ceremony_resolution() {
  local copy="${WORK}/ceremony-sabotage.txt"
  cp "${CEREMONY}" "${copy}"
  # Removing the installed-resolution line is the whole sabotage: the validator
  # call then runs wherever the ceremony last was, which is the repository.
  if ! grep -qx '  cd /usr/lib/kyri/python' "${copy}"; then
    fail "BROKEN SABOTAGE (repository resolution): the installed-resolution line is not in the ceremony"
    return
  fi
  grep -vx '  cd /usr/lib/kyri/python' "${copy}" > "${copy}.new" \
    || { fail "BROKEN SABOTAGE (repository resolution): could not produce the sabotaged copy"; return; }
  mv "${copy}.new" "${copy}"
  if grep -qx '  cd /usr/lib/kyri/python' "${copy}"; then
    fail "BROKEN SABOTAGE (repository resolution): the line survived removal"
    return
  fi
  if ceremony_resolves_installed "${copy}" > "${WORK}/resolve-sab.txt" 2>&1; then
    fail "NOT CAUGHT: the ceremony resolving the validator from the repository"
  else
    pass "caught: repository resolution -- $(head -1 "${WORK}/resolve-sab.txt" | cut -c1-62)"
  fi
}
sabotage_ceremony_resolution

printf -- '\n'
if (( FAILURES == 0 )); then
  printf 'Generation-23 installer validation passed.\n'
else
  printf 'Generation-23 installer validation FAILED: %d\n' "${FAILURES}" >&2
fi
exit $(( FAILURES > 0 ))
