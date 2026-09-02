#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-14 transaction, and everything that can interrupt it.
#
# FIXTURE ONLY. Every case builds a throwaway host under a temporary root and
# drives the ceremony against that with --fixture. No case writes to /usr, /etc,
# /root or /var, none uses sudo, and none invokes a privileged helper.
#
# HOST-ONLY, because the fixture is built from the installed Generation-13
# runtime. `tests/test-capability-generation14-readiness.sh` proves the security
# property this generation exists for, from reviewed git objects alone, and runs
# everywhere. This suite proves the TRANSACTION, which needs a runtime to
# install over.
#
# WHY A ONE-OBJECT GENERATION STILL GETS THIS
# ===========================================
# It would be easy to argue that a single REPLACE cannot be interrupted
# meaningfully. It can. `mv -f` is atomic, but everything around it is not:
# staging can fail, the predecessor can fail to be retained, the journal can be
# written and the process killed before publication, and the evidence can fail
# after the commit point. Each of those leaves a different obligation, and the
# only way to know the ceremony discharges them is to cause them.
#
# The property every case below asserts is the same one Generation 13 was held
# to: the host ends at the OLD generation or the NEW one, never between, and
# never in a state a later run would mistake for either.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python
host_only_requires_pinned_checkout "${ROOT}/provisioning/execution/install-generation-14.sh"

CEREMONY="provisioning/execution/install-generation-14.sh"
LIBRARY_ROOT="/usr/lib/kyri/python"                    # prod-path-reference
TARGET_RELATIVE="tools/capability/execution/helpers.py"
GEN13_SHA="eff6c4fd6f7420ba86491b7923e14cb2951a9c078decacc09dc20f38cefd5cbb"
GEN14_SHA="74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874"
GEN13_COMMIT="7709cf0443ab11f2b84c94eefbbb60f1eb95c98c"
COORDINATOR_SHA="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
EXECUTION_SHA="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
check() {
  local label="$1" condition="$2"
  if [[ "${condition}" == "yes" ]]; then pass "${label}"; else fail "${label}"; fi
}

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# A Generation-13 host, reconstructed from reviewed data rather than merely
# copied. The carried-over objects come from the installed tree -- they are
# identical in both generations, which is what the one-row matrix establishes --
# and the single REPLACE target is restored to the bytes the Generation-13
# authority pins. That keeps the fixture a Generation-13 host after Generation
# 14 is installed on production, which is the trap three suites fell into when
# Generation 13 landed.
build_host() {
  local root="$1" target
  rm -rf "${root}"
  mkdir -p "${root}${LIBRARY_ROOT}" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/usr/libexec" "${root}/etc/kyri" \
           "${root}/var/lib/kyri/fabric" "${root}/var/lib/kyri/trust" \
           "${root}/var/lib/kyri/implementation-authority"
  ( cd "${LIBRARY_ROOT}" && find . -type f -name '*.py' -not -path '*__pycache__*' -print0 ) \
    | ( cd "${LIBRARY_ROOT}" && xargs -0 -I{} cp --parents {} "${root}${LIBRARY_ROOT}/" )

  # The installed objects are 0444, so the copies are too. Remove before writing
  # rather than relaxing the mode: the fixture should carry the modes a real
  # host carries.
  target="${root}${LIBRARY_ROOT}/${TARGET_RELATIVE}"
  rm -f "${target}"
  git -C "${ROOT}" show "${GEN13_COMMIT}:${TARGET_RELATIVE}" > "${target}" \
    || return 1
  [[ "$(digest_of "${target}")" == "${GEN13_SHA}" ]] || return 1
  chmod 0444 "${target}"

  # The Generation-13 evidence this ceremony reads as its baseline.
  ( cd "${root}${LIBRARY_ROOT}" && find . -type f -name '*.py' -print0 | sort -z \
      | xargs -0 sha256sum ) \
    | sed "s#  \\./#  ${LIBRARY_ROOT}/#" > "${root}/root/kyri-gen13-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN13_COMMIT}"
    printf 'state COMMITTED\n'
  } > "${root}/root/kyri-gen13-helper-digests.txt"

  # The two accepted identity authorities, byte-exact: the ceremony refuses
  # without them, and using the real ones is the point -- a fixture with
  # invented identity bytes would prove the ceremony accepts something no host
  # has. These are READS of a production path into a disposable root; nothing is
  # written back, and the digests are asserted against the accepted G11-AW
  # values immediately after.
  cp /etc/kyri/coordinator-identity.json "${root}/etc/kyri/" 2>/dev/null || return 1   # prod-path-reference
  cp /etc/kyri/execution-identity.json "${root}/etc/kyri/" 2>/dev/null || return 1     # prod-path-reference

  # The privileged surface as this host really carries it: stale and absent,
  # and none of it this ceremony's to touch.
  local helper
  for helper in kyri-exec-transition kyri-exec-verify kyri-exec-quota \
                kyri-exec-worker.py kyri-exec-verify-worker.py; do
    [[ -f "/usr/libexec/${helper}" ]] \
      && cp "/usr/libexec/${helper}" "${root}/usr/libexec/${helper}"
  done
  return 0
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${ROOT}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}.log" 2>&1
}

target_of() { printf '%s' "$1${LIBRARY_ROOT}/${TARGET_RELATIVE}"; }
journal_of() { printf '%s' "$1/root/kyri-gen14-transaction/journal"; }
state_of() { sed -n 's/^state=//p' "$(journal_of "$1")" 2>/dev/null | tail -1; }

# The invariant every crash case is held to: the object is at exactly one of its
# two declared digests, and never at anything else.
whole_generation() {
  local root="$1" observed
  observed="$(digest_of "$(target_of "${root}")")"
  case "${observed}" in
    "${GEN13_SHA}") printf 'GEN13' ;;
    "${GEN14_SHA}") printf 'GEN14' ;;
    *) printf 'BROKEN(%s)' "${observed:-absent}" ;;
  esac
}

printf '=== the fixture is a Generation-13 host ===\n'

HOST="${WORK}/base"
if build_host "${HOST}"; then
  pass "a Generation-13 fixture host builds from reviewed data"
else
  fail "the Generation-13 fixture could not be built"
  printf '%d Generation-14 installer check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
check "the fixture target is the Generation-13 bytes" \
  "$([[ "$(digest_of "$(target_of "${HOST}")")" == "${GEN13_SHA}" ]] && echo yes || echo no)"
check "the fixture carries both accepted identity authorities" \
  "$([[ "$(digest_of "${HOST}/etc/kyri/coordinator-identity.json")" == "${COORDINATOR_SHA}" \
     && "$(digest_of "${HOST}/etc/kyri/execution-identity.json")" == "${EXECUTION_SHA}" ]] \
    && echo yes || echo no)"

printf '\n=== PART 1 — verify establishes the preconditions and writes nothing ===\n'

VERIFY="${WORK}/verify"
build_host "${VERIFY}"
BEFORE="$(cd "${VERIFY}" && find . -type f | sort | xargs sha256sum | sha256sum)"
if run_ceremony "${VERIFY}" --verify; then
  pass "--verify passes against an accepted Generation-13 fixture"
else
  fail "--verify failed: $(tail -5 "${VERIFY}.log")"
fi
check "--verify wrote nothing" \
  "$([[ "$(cd "${VERIFY}" && find . -type f | sort | xargs sha256sum | sha256sum)" == "${BEFORE}" ]] \
    && echo yes || echo no)"
for expected in "the installed runtime is exactly the accepted Generation-13 baseline" \
                "both deployment identity authorities are the accepted G11-AW bytes" \
                "no sudoers grant exists" \
                "no transaction residue" \
                "the reviewed commit's runtime delta is exactly the declared 1 object"; do
  check "--verify establishes: ${expected}" \
    "$(grep -qF "${expected}" "${VERIFY}.log" && echo yes || echo no)"
done
check "--verify reports the installed rule as the Generation-13 one (4 objects)" \
  "$(grep -qF 'installed Generation-13 readiness rule declares 4 required object(s)' \
      "${VERIFY}.log" && echo yes || echo no)"

printf '\n=== PART 2 — verify refuses a host that is not the accepted baseline ===\n'

DRIFT="${WORK}/drift"
build_host "${DRIFT}"
# Installed objects are 0444, so drift is introduced by replacing rather than
# appending -- which is also what real drift looks like.
rm -f "${DRIFT}${LIBRARY_ROOT}/tools/capability/cli.py"
printf 'drifted\n' > "${DRIFT}${LIBRARY_ROOT}/tools/capability/cli.py"
if run_ceremony "${DRIFT}" --verify; then
  fail "--verify accepted a host whose runtime drifted from the evidence"
else
  check "--verify refuses a drifted Generation-13 runtime" \
    "$(grep -q 'not the accepted Generation-13 baseline' "${DRIFT}.log" && echo yes || echo no)"
fi

UNKNOWN="${WORK}/unknown"
build_host "${UNKNOWN}"
rm -f "$(target_of "${UNKNOWN}")"
printf 'neither generation\n' > "$(target_of "${UNKNOWN}")"
# The evidence must agree with the tampered object, so the refusal is about the
# TARGET being unruled rather than about baseline drift.
( cd "${UNKNOWN}${LIBRARY_ROOT}" && find . -type f -name '*.py' -print0 | sort -z \
    | xargs -0 sha256sum ) | sed "s#  \\./#  ${LIBRARY_ROOT}/#" \
  > "${UNKNOWN}/root/kyri-gen13-library-digests.txt"
if run_ceremony "${UNKNOWN}" --verify; then
  fail "--verify accepted an unknown predecessor at the target"
else
  check "--verify refuses unknown predecessor bytes at the target" \
    "$(grep -qE 'UNKNOWN object at|unruled state' "${UNKNOWN}.log" && echo yes || echo no)"
fi

NOIDENT="${WORK}/noident"
build_host "${NOIDENT}"
# Removed from the FIXTURE, never from the host. The guard is what makes that a
# property rather than a claim; the marker records the exception the static
# check requires for a line naming the shape of a production path.
NOIDENT_AUTHORITY="${NOIDENT}/etc/kyri/execution-identity.json"
[[ "${NOIDENT_AUTHORITY}" == "${WORK}/"* ]] \
  || { printf 'the fixture escaped the disposable root\n' >&2; exit 1; }
rm -f "${NOIDENT_AUTHORITY}"                             # prod-path-reference
if run_ceremony "${NOIDENT}" --verify; then
  fail "--verify accepted a host with no execution identity authority"
else
  check "--verify refuses a host missing an identity authority" \
    "$(grep -q 'execution identity authority is absent' "${NOIDENT}.log" && echo yes || echo no)"
fi

OPEN="${WORK}/opengate"
build_host "${OPEN}"
printf 'placeholder\n' > "${OPEN}/etc/sudoers.d/kyri-exec"
if run_ceremony "${OPEN}" --verify; then
  fail "--verify accepted a host with an open elevation gate"
else
  check "--verify refuses a host with a sudoers grant installed" \
    "$(grep -q 'the launch grant is installed' "${OPEN}.log" && echo yes || echo no)"
fi

RESIDUE="${WORK}/residue"
build_host "${RESIDUE}"
printf 'left over\n' > "$(target_of "${RESIDUE}").kyri-gen14.new"
if run_ceremony "${RESIDUE}" --verify; then
  fail "--verify accepted a host with transaction residue"
else
  check "--verify refuses transaction residue" \
    "$(grep -q 'residue' "${RESIDUE}.log" && echo yes || echo no)"
fi

printf '\n=== PART 3 — the whole transaction ===\n'

INSTALL="${WORK}/install"
build_host "${INSTALL}"
if run_ceremony "${INSTALL}" --install; then
  pass "--install completes against an accepted Generation-13 fixture"
else
  fail "--install failed: $(tail -8 "${INSTALL}.log")"
fi
check "the target is at the Generation-14 bytes" \
  "$([[ "$(whole_generation "${INSTALL}")" == "GEN14" ]] && echo yes || echo no)"
check "the target keeps mode 0444" \
  "$([[ "$(stat -c '%a' "$(target_of "${INSTALL}")")" == "444" ]] && echo yes || echo no)"
check "the journal is COMMITTED" \
  "$([[ "$(state_of "${INSTALL}")" == "COMMITTED" ]] && echo yes || echo no)"
# A REPLACE-only generation moves no count. Expressed against the fixture rather
# than against a hardcoded 78: the library root also carries the flattened helper
# modules, and the G11-AX ceremony added one of those, so the absolute number
# depends on what else has been installed. What this generation must not do is
# change it.
FIXTURE_OBJECTS="$(find "${HOST}${LIBRARY_ROOT}" -type f -name '*.py' \
  -not -path '*__pycache__*' | wc -l)"
check "the object count did not move (${FIXTURE_OBJECTS})" \
  "$([[ "$(find "${INSTALL}${LIBRARY_ROOT}" -type f -name '*.py' \
        -not -path '*__pycache__*' | wc -l)" -eq "${FIXTURE_OBJECTS}" ]] \
    && echo yes || echo no)"
check "no transaction artefact remains" \
  "$([[ ! -e "$(target_of "${INSTALL}").kyri-gen14.new" \
     && ! -e "$(target_of "${INSTALL}").kyri-gen14.gen13" ]] && echo yes || echo no)"

check "Generation-13 evidence is preserved" \
  "$([[ -f "${INSTALL}/root/kyri-gen13-library-digests.txt" \
     && -f "${INSTALL}/root/kyri-gen13-helper-digests.txt" ]] && echo yes || echo no)"
check "Generation-14 evidence is written" \
  "$([[ -f "${INSTALL}/root/kyri-gen14-library-digests.txt" \
     && -f "${INSTALL}/root/kyri-gen14-helper-digests.txt" ]] && echo yes || echo no)"
for field in "generation 14" "predecessor generation 13" "state COMMITTED" \
             "library_objects ${FIXTURE_OBJECTS}" "delta REPLACE"; do
  check "the evidence pins: ${field}" \
    "$(grep -qF "${field}" "${INSTALL}/root/kyri-gen14-helper-digests.txt" \
        && echo yes || echo no)"
done
check "the evidence records the installed rule's eight expectations" \
  "$([[ "$(grep -c '^expects_helper ' "${INSTALL}/root/kyri-gen14-helper-digests.txt")" -eq 8 ]] \
    && echo yes || echo no)"

# The privileged surface is untouched by a runtime generation.
check "no /usr/libexec object changed" \
  "$([[ "$(cd "${INSTALL}/usr/libexec" && find . -type f | sort | xargs -r sha256sum | sha256sum)" \
      == "$(cd "${HOST}/usr/libexec" && find . -type f | sort | xargs -r sha256sum | sha256sum)" ]] \
    && echo yes || echo no)"
check "both identity authorities are unchanged" \
  "$([[ "$(digest_of "${INSTALL}/etc/kyri/coordinator-identity.json")" == "${COORDINATOR_SHA}" \
     && "$(digest_of "${INSTALL}/etc/kyri/execution-identity.json")" == "${EXECUTION_SHA}" ]] \
    && echo yes || echo no)"
check "no sudoers grant appeared" \
  "$([[ "$(find "${INSTALL}/etc/sudoers.d" -type f | wc -l)" -eq 0 ]] && echo yes || echo no)"

if run_ceremony "${INSTALL}" --verify-installed; then
  pass "--verify-installed passes after the transaction"
else
  fail "--verify-installed failed: $(tail -8 "${INSTALL}.log")"
fi
check "--verify-installed reports the installed rule as eight objects" \
  "$(grep -qF 'installed readiness rule declares 8 required object(s)' "${INSTALL}.log" \
      && echo yes || echo no)"

if run_ceremony "${INSTALL}" --install; then
  check "a second --install is a no-op" \
    "$(grep -q 'already installed' "${INSTALL}.log" && echo yes || echo no)"
else
  fail "a second --install did not report the generation as already installed"
fi

printf '\n=== PART 4 — PHASE 6: the installed rule, imported from the fixture only ===\n'

# The rule that decides must be the INSTALLED one. Driven with the repository
# absent from sys.path, so a module resolving from the checkout would fail
# rather than silently answer.
readiness_from_fixture() {
  local root="$1" surface="$2"
  python3 - "${root}${LIBRARY_ROOT}" "${surface}" "${ROOT}" <<'PY'
import dataclasses, pathlib, sys
library, surface, repository = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path = [p for p in sys.path if p not in ('', '.', repository)]
sys.path.insert(0, library)
from tools.capability.execution import helpers
resolved = pathlib.Path(helpers.__file__).resolve()
if not str(resolved).startswith(str(pathlib.Path(library).resolve())):
    print(f"RESOLVED-OUTSIDE {resolved}")
    raise SystemExit(1)
required = tuple(
    dataclasses.replace(h, path=str(pathlib.Path(surface) / h.path.lstrip('/')))
    for h in helpers.REQUIRED_HELPERS)
print(f"{helpers.compatibility(required).verdict} {len(helpers.REQUIRED_HELPERS)}")
PY
}

# A. the current stale/absent production helper surface
SURFACE_A="${WORK}/surface-stale"
mkdir -p "${SURFACE_A}/usr/libexec" "${SURFACE_A}${LIBRARY_ROOT}"
for h in kyri-exec-transition kyri-exec-worker.py kyri-exec-verify kyri-exec-verify-worker.py kyri-exec-quota; do
  [[ -f "/usr/libexec/${h}" ]] && cp "/usr/libexec/${h}" "${SURFACE_A}/usr/libexec/${h}"
done
for m in kyri_exec_transition kyri_exec_transition_action kyri_exec_verify kyri_exec_quota; do
  [[ -f "${LIBRARY_ROOT}/${m}.py" ]] && cp "${LIBRARY_ROOT}/${m}.py" "${SURFACE_A}${LIBRARY_ROOT}/${m}.py"
done
RESULT_A="$(readiness_from_fixture "${INSTALL}" "${SURFACE_A}")"
check "A: the current production helper surface is incompatible under Gen14" \
  "$([[ "${RESULT_A}" == "incompatible 8" ]] && echo yes || echo no)"

# B. the complete ten-object AX target
SURFACE_B="${WORK}/surface-target"
mkdir -p "${SURFACE_B}/usr/libexec" "${SURFACE_B}${LIBRARY_ROOT}"
while IFS='|' read -r target source; do
  [[ -n "${target}" ]] || continue
  mkdir -p "$(dirname "${SURFACE_B}${target}")"
  git -C "${ROOT}" show "${GEN13_COMMIT}:${source}" > "${SURFACE_B}${target}"
done <<TARGETS
${LIBRARY_ROOT}/kyri_exec_transition.py|provisioning/execution/kyri-exec-transition.py
${LIBRARY_ROOT}/kyri_exec_transition_action.py|provisioning/execution/kyri-exec-transition-action.py
${LIBRARY_ROOT}/kyri_exec_reconcile.py|provisioning/execution/kyri-exec-reconcile.py
${LIBRARY_ROOT}/kyri_exec_quota.py|provisioning/execution/kyri-exec-quota.py
/usr/libexec/kyri-exec-transition|provisioning/execution/kyri-exec-transition-entrypoint.py
/usr/libexec/kyri-exec-worker.py|provisioning/execution/kyri-exec-worker.py
/usr/libexec/kyri-exec-reconcile|provisioning/execution/kyri-exec-reconcile-entrypoint.py
/usr/libexec/kyri-exec-reconcile-worker.py|provisioning/execution/kyri-exec-reconcile-worker.py
TARGETS
RESULT_B="$(readiness_from_fixture "${INSTALL}" "${SURFACE_B}")"
check "B: the complete AX target surface is compatible under Gen14" \
  "$([[ "${RESULT_B}" == "compatible 8" ]] && echo yes || echo no)"

# C. a dangerous partial state: the policy module left stale
SURFACE_C="${WORK}/surface-partial"
cp -r "${SURFACE_B}" "${SURFACE_C}"
rm -f "${SURFACE_C}${LIBRARY_ROOT}/kyri_exec_transition.py"
printf 'stale policy module\n' > "${SURFACE_C}${LIBRARY_ROOT}/kyri_exec_transition.py"
RESULT_C="$(readiness_from_fixture "${INSTALL}" "${SURFACE_C}")"
check "C: a stale policy module beside new entrypoints is incompatible under Gen14" \
  "$([[ "${RESULT_C}" == "incompatible 8" ]] && echo yes || echo no)"

# And the same three, decided by the Generation-13 rule, so the difference the
# generation makes is visible rather than asserted.
RESULT_C13="$(readiness_from_fixture "${HOST}" "${SURFACE_C}")"
check "C: the same partial state was COMPATIBLE under Gen13" \
  "$([[ "${RESULT_C13}" == "compatible 4" ]] && echo yes || echo no)"

printf '\n=== PART 5 — PHASE 11: interruption and recovery ===\n'

# Returns nothing on stdout: the pass/fail lines ARE its output. An earlier
# version returned the fixture path and every caller redirected stdout to
# /dev/null to swallow it -- which swallowed all eleven crash results too, and
# the suite reported them as neither passed nor failed.
crash_case() {
  local label="$1" injection="$2" expect_state="$3"
  local root="${WORK}/crash-${injection}"
  build_host "${root}"
  ( cd "${ROOT}" && KYRI_GEN14_FAIL_AT="${injection}" \
      bash "${CEREMONY}" --fixture "${root}" --install ) > "${root}.log" 2>&1 || true
  local where; where="$(whole_generation "${root}")"
  check "${label}: leaves a whole generation (${where})" \
    "$([[ "${where}" == "${expect_state}" ]] && echo yes || echo no)"
  check "${label}: leaves no unruled bytes" \
    "$([[ "${where}" != BROKEN* ]] && echo yes || echo no)"
}

crash_case "failure before staging" stage GEN13
crash_case "failure after staging" staged GEN13
crash_case "failure before the PREPARED journal write" prepared GEN13
crash_case "failure immediately after COMMITTING" committing GEN13
crash_case "failure immediately before publication" publish GEN13
crash_case "failure during post-publication verification" verify GEN13
crash_case "failure at commit position 1" 1 GEN13
crash_case "failure immediately before the commit point" precommit GEN13
# Past the commit point the generation stands: a failure in bookkeeping must not
# revert a published generation.
crash_case "failure immediately after COMMITTED" postcommit GEN14
crash_case "failure while writing evidence" evidence GEN14
crash_case "failure during cleanup" cleanup GEN14

# An interruption that leaves a PREPARED journal must be resumable, and must
# resume forward because the prepared object verifies.
RESUME="${WORK}/resume"
build_host "${RESUME}"
( cd "${ROOT}" && KYRI_GEN14_FAIL_AT=prepared bash "${CEREMONY}" \
    --fixture "${RESUME}" --install ) > "${RESUME}.log" 2>&1 || true
check "an interrupted preparation unwinds and leaves Generation 13" \
  "$([[ "$(whole_generation "${RESUME}")" == "GEN13" ]] && echo yes || echo no)"
if run_ceremony "${RESUME}" --install; then
  check "a rerun after an unwound preparation installs Generation 14" \
    "$([[ "$(whole_generation "${RESUME}")" == "GEN14" ]] && echo yes || echo no)"
else
  fail "a rerun after an unwound preparation did not complete"
fi

# Evidence failure is past the commit point, so --recover must settle COMMITTED
# rather than revert.
RECOVER="${WORK}/recover"
build_host "${RECOVER}"
( cd "${ROOT}" && KYRI_GEN14_FAIL_AT=evidence bash "${CEREMONY}" \
    --fixture "${RECOVER}" --install ) > "${RECOVER}.log" 2>&1 || true
check "an evidence failure leaves Generation 14 published" \
  "$([[ "$(whole_generation "${RECOVER}")" == "GEN14" ]] && echo yes || echo no)"
if run_ceremony "${RECOVER}" --recover; then
  check "--recover settles on COMMITTED and writes the evidence" \
    "$([[ "$(state_of "${RECOVER}")" == "COMMITTED" \
       && -f "${RECOVER}/root/kyri-gen14-helper-digests.txt" ]] && echo yes || echo no)"
else
  fail "--recover did not complete: $(tail -5 "${RECOVER}.log")"
fi
check "--recover preserved the Generation-13 evidence" \
  "$([[ -f "${RECOVER}/root/kyri-gen13-library-digests.txt" ]] && echo yes || echo no)"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All Generation-14 installer checks passed.\n'
else
  printf '%d Generation-14 installer check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
