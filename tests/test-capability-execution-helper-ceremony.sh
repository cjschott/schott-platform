#!/usr/bin/env bash
set -Eeuo pipefail

# The ten-object privileged helper ceremony, and everything that can interrupt it.
#
# FIXTURE ONLY. Every case builds a throwaway host under a temporary root and
# drives the ceremony with --fixture. No case writes to /usr, /etc, /root or
# /var, none uses sudo, and none invokes a privileged helper or starts a
# container.
#
# HOST-ONLY, because the fixture needs the installed Generation-14 readiness
# rule: this ceremony is judged by the rule that is installed, not by a copy of
# it, and there is no honest way to fake that. The portable half of the proof --
# that the Generation-14 rule refuses every dangerous mixed state -- lives in
# tests/test-capability-generation14-readiness.sh and runs everywhere.
#
# THE INVARIANT
# =============
# NO PARTIAL HELPER DEPLOYMENT. Every crash case below asserts the same thing:
# all ten objects at their target bytes, or all ten at their predecessor state,
# and never a mixture. G11-AI is what happens when that does not hold.
#
# THE SECOND INVARIANT, WHICH IS EASIER TO MISS
# =============================================
# At no point before COMMITTED may the installed rule report `compatible` while
# the ceremony is incoherent. That is not left to sudoers being closed: the three
# objects outside the readiness closure publish FIRST, so the verdict can only
# flip as the tenth object lands. The cases below check that at every publication
# boundary, not just at the end.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python /etc/kyri/coordinator-identity.json
host_only_requires_pinned_checkout "${ROOT}/provisioning/execution/install-g11-ax-helpers.sh"

CEREMONY="provisioning/execution/install-g11-ax-helpers.sh"
LIBRARY_ROOT="/usr/lib/kyri/python"          # prod-path-reference
LIBEXEC_ROOT="/usr/libexec"
COMMIT="7709cf0443ab11f2b84c94eefbbb60f1eb95c98c"
RUNTIME_HELPERS_SHA="74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
check() {
  local label="$1" condition="$2"
  if [[ "${condition}" == "yes" ]]; then pass "${label}"; else fail "${label}"; fi
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true; }

# The ceremony's own matrix, read as data. Nothing about the ten objects is
# restated here: a suite carrying its own copy of the list would agree with
# itself rather than with the ceremony.
matrix_rows() {
  sed -n '/^MATRIX=(/,/^)/p' "${ROOT}/${CEREMONY}" | sed -n 's/^"\(.*\)"$/\1/p'
}
row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
row_target() {
  local target; target="$(row_field "$1" 2)"
  target="${target//\$\{LIBRARY_ROOT\}/${LIBRARY_ROOT}}"
  printf '%s' "${target//\$\{LIBEXEC_ROOT\}/${LIBEXEC_ROOT}}"
}

# A pre-ceremony host: the installed Generation-14 runtime, the accepted identity
# authorities, and the privileged surface exactly as production carries it --
# seven stale, three absent. Predecessor bytes come from the live host because
# that IS the reviewed predecessor state the matrix declares, and the build
# asserts each one against that declaration rather than trusting the copy.
build_host() {
  local root="$1" row target predecessor
  rm -rf "${root}"
  mkdir -p "${root}${LIBRARY_ROOT}" "${root}${LIBEXEC_ROOT}" "${root}/root" \
           "${root}/etc/sudoers.d" "${root}/etc/kyri" \
           "${root}/var/lib/kyri/fabric" "${root}/var/lib/kyri/trust" \
           "${root}/var/lib/kyri/implementation-authority"

  ( cd "${LIBRARY_ROOT}" && find . -type f -name '*.py' -not -path '*__pycache__*' -print0 ) \
    | ( cd "${LIBRARY_ROOT}" && xargs -0 -I{} cp --parents {} "${root}${LIBRARY_ROOT}/" )
  [[ "$(digest_of "${root}${LIBRARY_ROOT}/tools/capability/execution/helpers.py")" \
      == "${RUNTIME_HELPERS_SHA}" ]] || return 1

  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="$(row_target "${row}")"
    predecessor="$(row_field "${row}" 5)"
    mkdir -p "$(dirname "${root}${target}")"
    rm -f "${root}${target}"
    if [[ "${predecessor}" == "ABSENT" ]]; then
      continue
    fi
    cp "${target}" "${root}${target}" || return 1
    [[ "$(digest_of "${root}${target}")" == "${predecessor}" ]] || return 1
    chmod "$(row_field "${row}" 3)" "${root}${target}"
  done < <(matrix_rows)

  # The quota pair: inside the readiness closure, already at reviewed bytes, and
  # not this ceremony's to move.
  cp "${LIBRARY_ROOT}/kyri_exec_quota.py" "${root}${LIBRARY_ROOT}/kyri_exec_quota.py" 2>/dev/null || true
  cp "${LIBEXEC_ROOT}/kyri-exec-quota" "${root}${LIBEXEC_ROOT}/kyri-exec-quota" 2>/dev/null || true

  cp /etc/kyri/coordinator-identity.json "${root}/etc/kyri/" || return 1   # prod-path-reference
  cp /etc/kyri/execution-identity.json "${root}/etc/kyri/" || return 1     # prod-path-reference
  return 0
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${ROOT}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) > "${root}.log" 2>&1
}

journal_of() { printf '%s' "$1/root/kyri-g11-ax-helper-transaction/journal"; }
state_of() { sed -n 's/^state=//p' "$(journal_of "$1")" 2>/dev/null | tail -1; }

# Where the fixture's helper surface stands: every object at target, every object
# at its predecessor, or a mixture that must never be left behind.
surface_state() {
  local root="$1" row target predecessor want observed at_target=0 at_pre=0 total=0
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    total=$((total + 1))
    target="${root}$(row_target "${row}")"
    predecessor="$(row_field "${row}" 5)"; want="$(row_field "${row}" 6)"
    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${want}" ]]; then at_target=$((at_target + 1))
    elif [[ "${predecessor}" == "ABSENT" && -z "${observed}" ]]; then at_pre=$((at_pre + 1))
    elif [[ "${observed}" == "${predecessor}" ]]; then at_pre=$((at_pre + 1))
    fi
  done < <(matrix_rows)
  if   (( at_target == total )); then printf 'COMPLETE'
  elif (( at_pre == total ));    then printf 'PRE'
  else printf 'MIXED(%d target,%d pre of %d)' "${at_target}" "${at_pre}" "${total}"; fi
}

# The installed rule's verdict about a fixture surface, imported from the
# fixture's own runtime with the repository off sys.path.
fixture_verdict() {
  local root="$1"
  python3 - "${root}${LIBRARY_ROOT}" "${root}" "${ROOT}" <<'PY'
import dataclasses, pathlib, sys
library, prefix, repository = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path = [p for p in sys.path if p not in ('', '.', repository)]
sys.path.insert(0, library)
from tools.capability.execution import helpers
resolved = pathlib.Path(helpers.__file__).resolve()
if not str(resolved).startswith(str(pathlib.Path(library).resolve())):
    print('RESOLVED-OUTSIDE'); raise SystemExit(1)
required = tuple(
    dataclasses.replace(h, path=str(pathlib.Path(prefix) / h.path.lstrip('/')))
    for h in helpers.REQUIRED_HELPERS)
print(helpers.compatibility(required).verdict)
PY
}

printf '=== the fixture is a pre-ceremony Generation-14 host ===\n'

HOST="${WORK}/base"
if build_host "${HOST}"; then
  pass "a pre-ceremony host builds, every predecessor matching its declaration"
else
  fail "the pre-ceremony fixture could not be built"
  printf '%d helper ceremony check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
check "the fixture runtime is Generation 14" \
  "$([[ "$(digest_of "${HOST}${LIBRARY_ROOT}/tools/capability/execution/helpers.py")" \
      == "${RUNTIME_HELPERS_SHA}" ]] && echo yes || echo no)"
check "the fixture helper surface is the pre-ceremony one" \
  "$([[ "$(surface_state "${HOST}")" == "PRE" ]] && echo yes || echo no)"
check "the matrix is ten rows, 7 REPLACE and 3 CREATE" \
  "$([[ "$(matrix_rows | wc -l)" -eq 10 \
     && "$(matrix_rows | cut -d'|' -f4 | grep -c REPLACE)" -eq 7 \
     && "$(matrix_rows | cut -d'|' -f4 | grep -c CREATE)" -eq 3 ]] && echo yes || echo no)"
check "three rows are outside the readiness closure and publish first" \
  "$([[ "$(matrix_rows | head -3 | cut -d'|' -f7 | grep -c OUTSIDE)" -eq 3 \
     && "$(matrix_rows | tail -7 | cut -d'|' -f7 | grep -c INSIDE)" -eq 7 ]] && echo yes || echo no)"

printf '\n=== PART 1 — verify is read-only and establishes the preconditions ===\n'

VERIFY="${WORK}/verify"
build_host "${VERIFY}"
BEFORE="$(cd "${VERIFY}" && find . -type f | sort | xargs sha256sum | sha256sum)"
if run_ceremony "${VERIFY}" --verify; then
  pass "--verify passes against a pre-ceremony host"
else
  fail "--verify failed: $(tail -6 "${VERIFY}.log")"
fi
check "--verify wrote nothing at all" \
  "$([[ "$(cd "${VERIFY}" && find . -type f | sort | xargs sha256sum | sha256sum)" == "${BEFORE}" ]] \
    && echo yes || echo no)"
check "--verify left no __pycache__ behind" \
  "$([[ "$(find "${VERIFY}" -name '__pycache__' | wc -l)" -eq 0 ]] && echo yes || echo no)"
for expected in "the installed runtime is Generation 14" \
                "both deployment identity authorities are the accepted G11-AW bytes" \
                "no sudoers grant exists" \
                "no production CINV or CRES exists" \
                "all 10 helper targets are in a declared state" \
                "no transaction residue" \
                "every target stages beside itself" \
                "the transaction namespace is this ceremony's own" \
                "no Root Authority mount is present"; do
  check "--verify establishes: ${expected}" \
    "$(grep -qF "${expected}" "${VERIFY}.log" && echo yes || echo no)"
done
check "--verify reports current readiness as incompatible" \
  "$(grep -qF 'runtime readiness: incompatible' "${VERIFY}.log" && echo yes || echo no)"
check "--verify reports the complete target set as compatible" \
  "$(grep -qF 'target fixture readiness: compatible' "${VERIFY}.log" && echo yes || echo no)"

printf '\n=== PART 2 — unknown bytes are refused, never repaired ===\n'

UNKNOWN_REPLACE="${WORK}/unknown-replace"
build_host "${UNKNOWN_REPLACE}"
UR_TARGET="${UNKNOWN_REPLACE}${LIBRARY_ROOT}/kyri_exec_transition.py"
rm -f "${UR_TARGET}"; printf 'neither predecessor nor target\n' > "${UR_TARGET}"
if run_ceremony "${UNKNOWN_REPLACE}" --verify; then
  fail "--verify accepted unknown bytes at a REPLACE target"
else
  check "--verify refuses unknown bytes at a REPLACE target" \
    "$(grep -q 'UNKNOWN bytes at' "${UNKNOWN_REPLACE}.log" && echo yes || echo no)"
fi
if run_ceremony "${UNKNOWN_REPLACE}" --install; then
  fail "--install overwrote unknown bytes at a REPLACE target"
else
  check "--install refuses rather than overwriting unknown REPLACE bytes" \
    "$(grep -qE 'UNKNOWN bytes at|unruled state' "${UNKNOWN_REPLACE}.log" && echo yes || echo no)"
fi
check "the unknown object was left exactly as found" \
  "$([[ "$(cat "${UR_TARGET}")" == "neither predecessor nor target" ]] && echo yes || echo no)"

UNKNOWN_CREATE="${WORK}/unknown-create"
build_host "${UNKNOWN_CREATE}"
UC_TARGET="${UNKNOWN_CREATE}${LIBEXEC_ROOT}/kyri-exec-reconcile"
printf 'something already here\n' > "${UC_TARGET}"
if run_ceremony "${UNKNOWN_CREATE}" --install; then
  fail "--install overwrote an unexpected object at a CREATE target"
else
  check "--install refuses an unexpected object at a CREATE target" \
    "$(grep -qE 'UNKNOWN bytes at|already exists' "${UNKNOWN_CREATE}.log" && echo yes || echo no)"
fi
check "the unexpected CREATE object was left exactly as found" \
  "$([[ "$(cat "${UC_TARGET}")" == "something already here" ]] && echo yes || echo no)"

printf '\n=== PART 3 — the ceremony refuses a host it must not run on ===\n'

GEN13="${WORK}/gen13"
build_host "${GEN13}"
G13_RULE="${GEN13}${LIBRARY_ROOT}/tools/capability/execution/helpers.py"
rm -f "${G13_RULE}"
git -C "${ROOT}" show "7709cf0443ab11f2b84c94eefbbb60f1eb95c98c:tools/capability/execution/helpers.py" \
  > "${G13_RULE}"
if run_ceremony "${GEN13}" --verify; then
  fail "the ceremony ran against a Generation-13 readiness rule"
else
  check "the ceremony refuses a host still on the Generation-13 rule" \
    "$(grep -q 'install Generation 14 before this ceremony' "${GEN13}.log" && echo yes || echo no)"
fi

NOIDENT="${WORK}/noident"
build_host "${NOIDENT}"
NOIDENT_AUTHORITY="${NOIDENT}/etc/kyri/execution-identity.json"
[[ "${NOIDENT_AUTHORITY}" == "${WORK}/"* ]] || { printf 'fixture escaped\n' >&2; exit 1; }
rm -f "${NOIDENT_AUTHORITY}"                                          # prod-path-reference
if run_ceremony "${NOIDENT}" --verify; then
  fail "the ceremony ran without an execution identity authority"
else
  check "the ceremony refuses a host missing an identity authority" \
    "$(grep -q 'execution identity authority is absent' "${NOIDENT}.log" && echo yes || echo no)"
fi

OPENGATE="${WORK}/opengate"
build_host "${OPENGATE}"
printf 'placeholder\n' > "${OPENGATE}/etc/sudoers.d/kyri-exec"
if run_ceremony "${OPENGATE}" --verify; then
  fail "the ceremony ran with an elevation gate already open"
else
  check "the ceremony refuses a host with a sudoers grant installed" \
    "$(grep -q 'the launch grant is installed' "${OPENGATE}.log" && echo yes || echo no)"
fi

printf '\n=== PART 4 — the whole ceremony ===\n'

INSTALL="${WORK}/install"
build_host "${INSTALL}"
# The runtime, minus this ceremony's own library-root targets. Four of the ten
# live under the runtime's directory, so a flat fingerprint would always differ.
runtime_only_fingerprint() {
  ( cd "$1${LIBRARY_ROOT}" && find . -type f -name '*.py' \
      -not -name 'kyri_exec_transition.py' \
      -not -name 'kyri_exec_transition_action.py' \
      -not -name 'kyri_exec_verify.py' \
      -not -name 'kyri_exec_reconcile.py' \
      | sort | xargs sha256sum | sha256sum )
}
RUNTIME_BEFORE="$(runtime_only_fingerprint "${HOST}")"
if run_ceremony "${INSTALL}" --install; then
  pass "--install completes against a pre-ceremony host"
else
  fail "--install failed: $(tail -10 "${INSTALL}.log")"
fi
check "all ten objects are at their target bytes" \
  "$([[ "$(surface_state "${INSTALL}")" == "COMPLETE" ]] && echo yes || echo no)"
check "the journal is COMMITTED" \
  "$([[ "$(state_of "${INSTALL}")" == "COMMITTED" ]] && echo yes || echo no)"
check "the installed rule now reports compatible" \
  "$([[ "$(fixture_verdict "${INSTALL}")" == "compatible" ]] && echo yes || echo no)"
check "ceremony coherence is COMPLETE" \
  "$(grep -q 'ceremony coherence: COMPLETE (10/10' "${INSTALL}.log" && echo yes || echo no)"
check "the behavioural gate ran before the commit point" \
  "$(grep -q 'the installed Generation-14 readiness rule reports compatible' "${INSTALL}.log" \
      && echo yes || echo no)"

# Every declared mode, checked against what actually landed.
MODE_OK=yes
while IFS= read -r row; do
  [[ -n "${row}" ]] || continue
  t="${INSTALL}$(row_target "${row}")"
  [[ "$(stat -c '%a' "${t}" 2>/dev/null)" == "$(row_field "${row}" 3 | sed 's/^0//')" ]] \
    || MODE_OK=no
done < <(matrix_rows)
check "every object landed at its declared mode" "${MODE_OK}"

check "no runtime object outside the ceremony's targets changed" \
  "$([[ "$(runtime_only_fingerprint "${INSTALL}")" == "${RUNTIME_BEFORE}" ]] \
    && echo yes || echo no)"
check "the library root gained exactly one object (the created helper module)" \
  "$([[ "$(find "${INSTALL}${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)" \
      -eq "$(( $(find "${HOST}${LIBRARY_ROOT}" -type f -name '*.py' | wc -l) + 1 ))" ]] \
    && echo yes || echo no)"
check "both identity authorities are unchanged" \
  "$([[ "$(digest_of "${INSTALL}/etc/kyri/coordinator-identity.json")" \
      == "$(digest_of "${HOST}/etc/kyri/coordinator-identity.json")" \
     && "$(digest_of "${INSTALL}/etc/kyri/execution-identity.json")" \
      == "$(digest_of "${HOST}/etc/kyri/execution-identity.json")" ]] && echo yes || echo no)"
check "no sudoers grant appeared" \
  "$([[ "$(find "${INSTALL}/etc/sudoers.d" -type f | wc -l)" -eq 0 ]] && echo yes || echo no)"
check "no transaction artefact remains" \
  "$([[ "$(find "${INSTALL}" -name '*.kyri-axhelper.*' | wc -l)" -eq 0 ]] && echo yes || echo no)"

EVIDENCE="${INSTALL}/root/kyri-g11-ax-helper-digests.txt"
check "helper ceremony evidence is written" "$([[ -f "${EVIDENCE}" ]] && echo yes || echo no)"
for field in "ceremony g11-ax-helpers" "runtime_generation 14" "state COMMITTED" \
             "objects 10" "replaced 7" "created 3" "readiness_closure 7" \
             "ceremony_only 3" "runtime_readiness compatible"; do
  check "the evidence pins: ${field}" \
    "$(grep -qF "${field}" "${EVIDENCE}" && echo yes || echo no)"
done

if run_ceremony "${INSTALL}" --verify-installed; then
  pass "--verify-installed passes after the ceremony"
else
  fail "--verify-installed failed: $(tail -10 "${INSTALL}.log")"
fi
if run_ceremony "${INSTALL}" --install; then
  check "a second --install is a no-op" \
    "$(grep -q 'already installed' "${INSTALL}.log" && echo yes || echo no)"
else
  fail "a second --install did not report the set as already installed"
fi

printf '\n=== PART 5 — PHASE 15: readiness can never precede coherence ===\n'

# Publish position by position and ask the installed rule after each one. The
# ceremony is only safe if `compatible` first appears at position 10.
PROBE="${WORK}/probe"
FIRST_COMPATIBLE=0
POSITION=0
build_host "${PROBE}"
while IFS= read -r row; do
  [[ -n "${row}" ]] || continue
  POSITION=$((POSITION + 1))
  target="${PROBE}$(row_target "${row}")"
  mkdir -p "$(dirname "${target}")"
  rm -f "${target}"
  ( cd "${ROOT}" && git show "${COMMIT}:$(row_field "${row}" 1)" ) > "${target}"
  chmod "$(row_field "${row}" 3)" "${target}"
  if [[ "$(fixture_verdict "${PROBE}")" == "compatible" && "${FIRST_COMPATIBLE}" -eq 0 ]]; then
    FIRST_COMPATIBLE="${POSITION}"
  fi
done < <(matrix_rows)
check "readiness first reports compatible only at the tenth publication (was ${FIRST_COMPATIBLE})" \
  "$([[ "${FIRST_COMPATIBLE}" -eq 10 ]] && echo yes || echo no)"
check "the fully published surface is coherent" \
  "$([[ "$(surface_state "${PROBE}")" == "COMPLETE" ]] && echo yes || echo no)"

printf '\n=== PART 6 — PHASE 8: partial states are refused by the installed rule ===\n'

partial_case() {
  local label="$1" omit="$2" expect="$3" root
  root="${WORK}/partial-$(printf '%s' "${label}" | tr -c 'a-z0-9' '-')"
  build_host "${root}"
  local row target
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="$(row_target "${row}")"
    [[ "${target}" == *"${omit}"* ]] && continue
    mkdir -p "$(dirname "${root}${target}")"
    rm -f "${root}${target}"
    ( cd "${ROOT}" && git show "${COMMIT}:$(row_field "${row}" 1)" ) > "${root}${target}"
    chmod "$(row_field "${row}" 3)" "${root}${target}"
  done < <(matrix_rows)
  local got; got="$(fixture_verdict "${root}")"
  check "nine of ten, ${label}: installed rule says ${expect}" \
    "$([[ "${got}" == "${expect}" ]] && echo yes || echo no)"
  check "nine of ten, ${label}: ceremony coherence is incomplete" \
    "$([[ "$(surface_state "${root}")" == MIXED* ]] && echo yes || echo no)"
}

partial_case "policy module stale" "kyri_exec_transition.py" "incompatible"
partial_case "action module stale" "kyri_exec_transition_action.py" "incompatible"
partial_case "reconcile module absent" "kyri_exec_reconcile.py" "incompatible"
partial_case "reconcile entrypoint absent" "libexec/kyri-exec-reconcile" "incompatible"
partial_case "worker stale" "kyri-exec-worker.py" "incompatible"
partial_case "transition entrypoint stale" "libexec/kyri-exec-transition" "incompatible"
# The one case where the two closures deliberately disagree.
partial_case "verify entrypoint stale" "libexec/kyri-exec-verify" "compatible"

printf '\n=== PART 7 — PHASE 14: interruption and recovery ===\n'

crash_case() {
  local label="$1" injection="$2" expect="$3" root
  root="${WORK}/crash-$(printf '%s' "${injection}" | tr -c 'a-z0-9' '-')"
  build_host "${root}"
  ( cd "${ROOT}" && KYRI_AXHELPER_FAIL_AT="${injection}" \
      bash "${CEREMONY}" --fixture "${root}" --install ) > "${root}.log" 2>&1 || true
  local where; where="$(surface_state "${root}")"
  check "${label}: leaves a whole surface (${where})" \
    "$([[ "${where}" == "${expect}" ]] && echo yes || echo no)"
  # And the rule must never call an interrupted surface ready unless it is
  # complete -- which is the property publication order exists to give.
  local verdict; verdict="$(fixture_verdict "${root}")"
  check "${label}: readiness is ${verdict}, consistent with the surface" \
    "$([[ ( "${where}" == "COMPLETE" && "${verdict}" == "compatible" ) \
       || ( "${where}" != "COMPLETE" && "${verdict}" == "incompatible" ) ]] \
      && echo yes || echo no)"
}

crash_case "failure before staging" stage PRE
crash_case "failure during staging" staged PRE
crash_case "failure after all staging" prepared PRE
crash_case "failure immediately after COMMITTING" committing PRE
crash_case "failure immediately before publication" publish PRE
crash_case "failure after the first OUTSIDE publication" 2 PRE
crash_case "failure during the REPLACE set" 5 PRE
crash_case "failure before the first CREATE" 6 PRE
crash_case "failure after nine publications" 10 PRE
crash_case "failure after ten publications, before the behavioural check" published PRE
crash_case "failure after the behavioural check, before COMMITTED" precommit PRE
crash_case "failure immediately after COMMITTED" postcommit COMPLETE
crash_case "failure while writing evidence" evidence COMPLETE
crash_case "failure during cleanup" cleanup COMPLETE

# An interrupted preparation must be resumable, and must resume forward.
RESUME="${WORK}/resume"
build_host "${RESUME}"
( cd "${ROOT}" && KYRI_AXHELPER_FAIL_AT=prepared bash "${CEREMONY}" \
    --fixture "${RESUME}" --install ) > "${RESUME}.log" 2>&1 || true
check "an interrupted preparation unwinds to the pre-ceremony surface" \
  "$([[ "$(surface_state "${RESUME}")" == "PRE" ]] && echo yes || echo no)"
if run_ceremony "${RESUME}" --install; then
  check "a rerun after an unwound preparation installs the complete set" \
    "$([[ "$(surface_state "${RESUME}")" == "COMPLETE" ]] && echo yes || echo no)"
else
  fail "a rerun after an unwound preparation did not complete"
fi

# Past the commit point, recovery must settle forward and never revert.
RECOVER="${WORK}/recover"
build_host "${RECOVER}"
( cd "${ROOT}" && KYRI_AXHELPER_FAIL_AT=evidence bash "${CEREMONY}" \
    --fixture "${RECOVER}" --install ) > "${RECOVER}.log" 2>&1 || true
check "an evidence failure leaves the complete set published" \
  "$([[ "$(surface_state "${RECOVER}")" == "COMPLETE" ]] && echo yes || echo no)"
if run_ceremony "${RECOVER}" --recover; then
  check "--recover settles COMMITTED and writes the evidence" \
    "$([[ "$(state_of "${RECOVER}")" == "COMMITTED" \
       && -f "${RECOVER}/root/kyri-g11-ax-helper-digests.txt" ]] && echo yes || echo no)"
else
  fail "--recover did not complete: $(tail -6 "${RECOVER}.log")"
fi

printf '\n=== PART 8 — namespace isolation ===\n'

check "the transaction root is this ceremony's own namespace" \
  "$(grep -q 'TRANSACTION_ROOT="/root/kyri-g11-ax-helper-transaction"' "${ROOT}/${CEREMONY}" \
      && echo yes || echo no)"
NS_OK=yes
for generation in gen12 gen13 gen14; do
  grep -q "kyri-${generation}-transaction\"" "${ROOT}/${CEREMONY}" && NS_OK=no
done
check "no runtime generation's transaction root is used by this ceremony" "${NS_OK}"
check "the prepared and backup suffixes are this ceremony's own" \
  "$([[ "$(grep -c 'kyri-axhelper\.' "${ROOT}/${CEREMONY}")" -ge 2 \
     && "$(grep -c 'kyri-gen1[234]\.' "${ROOT}/${CEREMONY}")" -eq 0 ]] && echo yes || echo no)"
check "a completed helper ceremony leaves no runtime generation journal" \
  "$([[ ! -e "${INSTALL}/root/kyri-gen14-transaction" \
     && ! -e "${INSTALL}/root/kyri-gen13-transaction" ]] && echo yes || echo no)"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All helper ceremony checks passed.\n'
else
  printf '%d helper ceremony check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
