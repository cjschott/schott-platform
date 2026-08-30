#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-Z1. The Generation-12 ceremony, against a host that looks like
# the real one.
#
# The reviewed Generation-12 installer failed on the production host in two
# ways, and both were mine, introduced by deriving the installer from
# Generation 11 without re-deriving what its host-facing gates were asserting:
#
#   A. it declared TRANSACTION_ROOT=/root/kyri-gen11-transaction -- the
#      predecessor's. Generation 12 therefore read Generation 11's retained
#      COMMITTED journal as its own transaction state and halted with "the
#      journal says COMMITTED but the targets do not agree".
#
#   B. require_same_filesystem() required every target's directory to equal the
#      package directory. That was true of Generation 11, whose nine CREATEs all
#      landed in tools/fabric. Generation 12's matrix spans tools/capability,
#      tools/fabric, and tools/trust, so the first REPLACE row could not pass.
#
# G11-Z tested the closure, the isolated runtime, and the packaged behaviour. It
# never ran the ceremony against a host, which is why both escaped. This suite
# is that missing test: it builds a Generation-11 host carrying a retained
# COMMITTED Generation-11 journal, and drives the whole ceremony against it.
#
# FIXTURE ONLY. Every case runs with --fixture against a throwaway root. Nothing
# here reads or writes a production path, installs anything, or touches /root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-12.sh"

# This suite drives an operator ceremony that pins its repository as
# production authority; where the checkout is not that pin the ceremony would
# read a different repository. Host-only rather than failing for a reason
# unrelated to what it tests.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${CEREMONY}"

LIBRARY_ROOT=/usr/lib/kyri/python
WORK="$(mktemp -d)"
FAILURES=0
INSTALLED_BEFORE="$(mktemp)"; INSTALLED_AFTER="$(mktemp)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"; rm -f "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}"' EXIT

[[ -d "${LIBRARY_ROOT}" ]] && \
  ( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "${INSTALLED_BEFORE}"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
check() { if [[ "$1" == "yes" ]]; then pass "$2"; else fail "$2"; fi; }

read_value() {
  sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1
}
GEN11_COMMIT="$(read_value GEN11_COMMIT)"
TARGET_N="$(sed -n 's/^EXPECTED_LIBRARY_FILES_TARGET=\([0-9]*\)$/\1/p' "${CEREMONY}" | head -1)"

mapfile -t ROWS < <(python3 - "${CEREMONY}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.index("MATRIX=(\n"); end = text.index("\n)", start)
for line in text[start + 9:end].split("\n"):
    line = line.strip()
    if line and not line.startswith("#"):
        print(line.strip('"'))
PY
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# ===========================================================================
# A fixture Generation-11 host, with the predecessor's retained journal
# ===========================================================================
build_host() {
  local root="$1" file flattened
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  rm -rf "${root}"
  mkdir -p "${root}/usr/lib/kyri/python" "${root}/usr/libexec" "${root}/root" \
           "${root}/etc/sudoers.d" "${root}/var/lib/kyri"

  # The library root exactly as Generation 11 leaves it: every .py the reviewed
  # Generation-11 authority installs, and nothing else.
  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    git -C "${REPOSITORY}" show "${GEN11_COMMIT}:${file}" \
      > "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN11_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common tools/fabric \
           | grep '\.py$' | grep -v '__pycache__' | sort)
  # Generation 11 installs only its own nine Fabric objects, not the whole
  # package: eligibility, trust_adapter, admission, selection and the Fabric CLI
  # are excluded there, so a faithful host does not carry them.
  for file in admission.py cli.py eligibility.py selection.py trust_adapter.py \
              resources.py evidence_authority.py; do
    rm -f "${root}/usr/lib/kyri/python/tools/fabric/${file}"
  done
  # And the installed capability surface predates two modules the reviewed
  # commit carries: no generation since has republished that tree wholesale, so
  # a faithful host does not have them either. Named rather than derived,
  # because a fixture that quietly matched whatever the commit held would stop
  # being a model of the host.
  for file in contract_outcome.py result_content.py; do
    rm -f "${root}/usr/lib/kyri/python/tools/capability/execution/${file}"
  done
  for flattened in quota transition transition-action verify; do
    git -C "${REPOSITORY}" show \
      "${GEN11_COMMIT}:provisioning/execution/kyri-exec-${flattened}.py" \
      > "${root}/usr/lib/kyri/python/kyri_exec_${flattened//-/_}.py"
  done
  find "${root}/usr/lib/kyri/python" -type f -name '*.py' -exec chmod 0444 {} +

  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen11-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN11_COMMIT}"
    printf 'predecessor generation 10\n'
    printf 'transaction gen11-fixture\n'
    printf 'state COMMITTED\n'
  } > "${root}/root/kyri-gen11-helper-digests.txt"
}

# The retained predecessor journal: exactly what the real host carries, and the
# thing Generation 12 must not read as its own.
retain_gen11_journal() {
  local root="$1"
  mkdir -p "${root}/root/kyri-gen11-transaction"
  {
    printf 'transaction gen11-2026-08-27\n'
    printf 'state COMMITTED\n'
    printf 'commit %s\n' "${GEN11_COMMIT}"
    printf 'package_dir /usr/lib/kyri/python/tools/fabric\n'
    printf 'package_dir_created yes\n'
  } > "${root}/root/kyri-gen11-transaction/journal"
  chmod 0400 "${root}/root/kyri-gen11-transaction/journal"
}

gen11_journal_digest() {
  sha256sum "$1/root/kyri-gen11-transaction/journal" 2>/dev/null | cut -d' ' -f1
}

run_ceremony() {
  local root="$1"; shift
  local status=0
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1 || status=$?
  printf '%s' "${status}"
}

target_states() {
  local root="$1" row src target digest out=""
  for row in "${ROWS[@]}"; do
    src="$(field "${row}" 0)"
    target="${root}/usr/lib/kyri/python/${src}"
    if [[ ! -e "${target}" ]]; then out+="- "
    else
      digest="$(sha256sum "${target}" | cut -d' ' -f1)"
      if   [[ "${digest}" == "$(field "${row}" 5)" ]]; then out+="12 "
      elif [[ "${digest}" == "$(field "${row}" 4)" ]]; then out+="11 "
      else out+="? "; fi
    fi
  done
  printf '%s' "${out% }"
}
BASELINE_STATES="11 11 11 11 11 11 - - - - - - - - - - - - -"
INSTALLED_STATES="12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12 12"

echo "=========================================================================="
echo "PART 1 — the ceremony against a real-shaped Generation-11 host"
echo "=========================================================================="

host="${WORK}/real"
build_host "${host}"
retain_gen11_journal "${host}"
JOURNAL_BEFORE="$(gen11_journal_digest "${host}")"

check "$([[ "$(target_states "${host}")" == "${BASELINE_STATES}" ]] && echo yes || echo no)" \
  "the fixture is a whole Generation 11: six at baseline, thirteen absent"
check "$([[ -f "${host}/root/kyri-gen11-transaction/journal" ]] && echo yes || echo no)" \
  "the fixture carries the retained Generation-11 COMMITTED journal"

status="$(run_ceremony "${host}" --verify)"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "--verify accepts the intact Generation-11 host (exit ${status})"
if [[ "${status}" != "0" ]]; then
  printf '    %s\n' "$(tail -3 "${host}/last-run.log")"
fi

echo
echo "=========================================================================="
echo "PART 2 — root cause A: the transaction namespace is generation-owned"
echo "=========================================================================="

# The invariant: a generation installer must never use another generation's
# transaction journal as its own transaction state.
check "$(grep -q 'TRANSACTION_ROOT="/root/kyri-gen12-transaction"' "${CEREMONY}" && echo yes || echo no)" \
  "Generation 12 declares its own transaction root"
# The predecessor's path may be named in prose -- saying what is deliberately
# left alone is worth having. What it may not be is used: no assignment, no
# expansion, no command touching it.
code_only="$(grep -v '^\s*#' "${CEREMONY}")"
check "$(grep -q 'kyri-gen11-transaction' <<<"${code_only}" && echo no || echo yes)" \
  "no executable line in Generation 12 refers to the Generation-11 transaction root"

status="$(run_ceremony "${host}" --verify)"
check "$(grep -qi 'no transaction in progress' "${host}/last-run.log" && echo yes || echo no)" \
  "with only a Generation-11 journal present, Generation 12 reports no transaction"
check "$([[ "$(gen11_journal_digest "${host}")" == "${JOURNAL_BEFORE}" ]] && echo yes || echo no)" \
  "--verify left the Generation-11 journal byte-identical"

status="$(run_ceremony "${host}" --recover)"
check "$([[ "$(gen11_journal_digest "${host}")" == "${JOURNAL_BEFORE}" ]] && echo yes || echo no)" \
  "--recover cannot mutate the Generation-11 journal (exit ${status})"
check "$([[ "$(target_states "${host}")" == "${BASELINE_STATES}" ]] && echo yes || echo no)" \
  "--recover against a foreign journal published nothing"

echo
echo "=========================================================================="
echo "PART 3 — root cause B: targets span three directories"
echo "=========================================================================="

directories="$(for row in "${ROWS[@]}"; do dirname "$(field "${row}" 0)"; done | sort -u)"
check "$([[ "$(wc -l <<<"${directories}")" -ge 3 ]] && echo yes || echo no)" \
  "the matrix genuinely spans several directories ($(tr '\n' ' ' <<<"${directories}"))"
check "$(grep -q 'is not inside the declared Fabric package directory' "${CEREMONY}" && echo no || echo yes)" \
  "the ceremony no longer requires every target to live in the package directory"
check "$(grep -q 'stages beside itself' "${CEREMONY}" && echo yes || echo no)" \
  "the ceremony still asserts each object stages beside its own target"

# The property that was actually intended: every publication is a same-filesystem
# rename beside its own target.
status="$(run_ceremony "${host}" --verify)"
check "$(grep -q 'publication is a rename' "${host}/last-run.log" && echo yes || echo no)" \
  "--verify proves same-filesystem publication across the mixed matrix"

echo
echo "=========================================================================="
echo "PART 4 — the whole transaction, end to end"
echo "=========================================================================="

status="$(run_ceremony "${host}" --install)"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "--install completes against the real-shaped host (exit ${status})"
if [[ "${status}" != "0" ]]; then printf '    %s\n' "$(tail -3 "${host}/last-run.log")"; fi

check "$([[ "$(target_states "${host}")" == "${INSTALLED_STATES}" ]] && echo yes || echo no)" \
  "all nineteen targets carry their Generation-12 bytes"
count="$(find "${host}/usr/lib/kyri/python" -type f -name '*.py' | wc -l)"
check "$([[ "${count}" == "${TARGET_N}" ]] && echo yes || echo no)" \
  "the installed object count is ${TARGET_N} (got ${count})"
check "$([[ -d "${host}/usr/lib/kyri/python/tools/trust" ]] && echo yes || echo no)" \
  "the Trust package directory was created"
check "$([[ "$(gen11_journal_digest "${host}")" == "${JOURNAL_BEFORE}" ]] && echo yes || echo no)" \
  "the Generation-11 journal survived the install byte-identical"
check "$([[ -f "${host}/root/kyri-gen12-transaction/journal" ]] && echo yes || echo no)" \
  "Generation 12 recorded its own journal"
check "$(grep -q 'COMMITTED' "${host}/root/kyri-gen12-transaction/journal" 2>/dev/null && echo yes || echo no)" \
  "the Generation-12 journal records a committed transaction"
check "$([[ -f "${host}/root/kyri-gen12-library-digests.txt" ]] && echo yes || echo no)" \
  "Generation 12 wrote its own evidence"
check "$([[ -f "${host}/root/kyri-gen11-library-digests.txt" ]] && echo yes || echo no)" \
  "the Generation-11 evidence was not overwritten"

status="$(run_ceremony "${host}" --verify-installed)"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "--verify-installed audits the result clean (exit ${status})"
if [[ "${status}" != "0" ]]; then printf '    %s\n' "$(tail -3 "${host}/last-run.log")"; fi

echo
echo "=========================================================================="
echo "PART 5 — interruption and recovery stay generation-specific"
echo "=========================================================================="

for stage in prepare directory 3 precommit; do
  interrupted="${WORK}/fail-${stage}"
  build_host "${interrupted}"
  retain_gen11_journal "${interrupted}"
  before="$(gen11_journal_digest "${interrupted}")"
  ( cd "${REPOSITORY}" && KYRI_GEN12_FAIL_AT="${stage}" \
      bash "${CEREMONY}" --fixture "${interrupted}" --install ) \
    > "${interrupted}/last-run.log" 2>&1 || true
  check "$([[ "$(gen11_journal_digest "${interrupted}")" == "${before}" ]] && echo yes || echo no)" \
    "a failure at '${stage}' leaves the Generation-11 journal untouched"
  check "$([[ -f "${interrupted}/root/kyri-gen11-library-digests.txt" ]] && echo yes || echo no)" \
    "a failure at '${stage}' leaves the Generation-11 evidence in place"
  residue="$(find "${interrupted}/usr/lib/kyri/python" -name '*.kyri-gen12.*' | wc -l)"
  states="$(target_states "${interrupted}")"
  check "$([[ "${states}" == "${BASELINE_STATES}" || "${states}" == "${INSTALLED_STATES}" ]] && echo yes || echo no)" \
    "a failure at '${stage}' leaves a whole generation, never a mixture (${states:0:30}…)"
  # Recovery must resolve whatever state it finds without touching Generation 11.
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${interrupted}" --recover ) \
    > "${interrupted}/recover.log" 2>&1 || true
  check "$([[ "$(gen11_journal_digest "${interrupted}")" == "${before}" ]] && echo yes || echo no)" \
    "recovery after '${stage}' still leaves the Generation-11 journal untouched"
  final="$(target_states "${interrupted}")"
  check "$([[ "${final}" == "${BASELINE_STATES}" || "${final}" == "${INSTALLED_STATES}" ]] && echo yes || echo no)" \
    "recovery after '${stage}' settles on a whole generation"
  if [[ "${residue}" != "0" ]]; then
    fail "a failure at '${stage}' left ${residue} prepared object(s) behind"
  fi
done

echo
echo "=========================================================================="
echo "PART 6 — a Generation-11 COMMITTED journal is not a Generation-12 one"
echo "=========================================================================="

lone="${WORK}/lone-g11-journal"
build_host "${lone}"
retain_gen11_journal "${lone}"
before="$(gen11_journal_digest "${lone}")"
status="$(run_ceremony "${lone}" --install)"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "an install proceeds despite the predecessor's COMMITTED journal (exit ${status})"
check "$(grep -q 'the journal says COMMITTED but the targets do not agree' "${lone}/last-run.log" && echo no || echo yes)" \
  "the predecessor's journal never produces the cross-generation disposition halt"
check "$([[ "$(gen11_journal_digest "${lone}")" == "${before}" ]] && echo yes || echo no)" \
  "and it survives byte-identical"

echo
echo "=========================================================================="
echo "PART 7 — the operator is told which generation was installed"
echo "=========================================================================="

# G11-Z2 installed Generation 12 on the production host and the ceremony
# announced Generation 11 throughout. The transaction was correct; the strings
# were the predecessor's. An operator who believes the install did not take is
# an operator reaching for --install or --recover, and that is the same
# confusion that produced root cause A.
#
# These assert both directions: the corrected phrase is present AND the stale
# phrase is gone. Asserting only presence would pass while the stale line still
# sits beside it.

REPLACE_N=0; CREATE_N=0
for row in "${ROWS[@]}"; do
  case "$(field "${row}" 3)" in
    REPLACE) REPLACE_N=$((REPLACE_N + 1)) ;;
    CREATE)  CREATE_N=$((CREATE_N + 1)) ;;
  esac
done
TOTAL_N=${#ROWS[@]}

says()     { grep -qF "$1" "$2" && echo yes || echo no; }
says_not() { grep -qF "$1" "$2" && echo no || echo yes; }

reporting="${WORK}/reporting"
build_host "${reporting}"
retain_gen11_journal "${reporting}"

# --- readiness ------------------------------------------------------------
run_ceremony "${reporting}" --verify >/dev/null
verify_log="${reporting}/last-run.log"

check "$(says "${REPLACE_N} REPLACE, ${CREATE_N} CREATE, ${TOTAL_N} changed objects" "${verify_log}")" \
  "--verify reports the matrix disposition (${REPLACE_N} REPLACE, ${CREATE_N} CREATE, ${TOTAL_N} changed)"
check "$(says_not "${TOTAL_N} CREATE operation" "${verify_log}")" \
  "--verify no longer calls all ${TOTAL_N} rows CREATE operations"
# Describing the host before installation as Generation 11 is correct and must
# survive the correction: this is the overcorrection guard.
check "$(says "the host is at Generation 11 and ready for the Generation-12 installation" "${verify_log}")" \
  "--verify still describes the PRE-INSTALL host as Generation 11"

# --- the transaction ------------------------------------------------------
status="$(run_ceremony "${reporting}" --install)"
install_log="${reporting}/last-run.log"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "--install still succeeds with corrected reporting (exit ${status})"

check "$(says "PREPARE complete: ${TOTAL_N} objects staged" "${install_log}")" \
  "PREPARE reports ${TOTAL_N} staged"
check "$(says "${CREATE_N} pathnames reserved" "${install_log}")" \
  "PREPARE distinguishes the ${CREATE_N} reserved CREATE pathnames"
check "$(says "${REPLACE_N} predecessors retained" "${install_log}")" \
  "PREPARE reports the ${REPLACE_N} retained REPLACE predecessors"

check "$(says "COMMIT complete: ${TOTAL_N} objects published and verified (${REPLACE_N} replaced, ${CREATE_N} created)" "${install_log}")" \
  "COMMIT reports ${TOTAL_N} published as ${REPLACE_N} replaced + ${CREATE_N} created"
check "$(says_not "${TOTAL_N} objects created and verified" "${install_log}")" \
  "COMMIT no longer describes all ${TOTAL_N} objects as created"

check "$(says "Generation-12 evidence written; Generation-11 evidence preserved" "${install_log}")" \
  "evidence output names the written generation and the preserved one separately"
check "$(says_not "Generation-11 evidence written" "${install_log}")" \
  "evidence output no longer claims Generation-11 evidence was written"

check "$(says "all ${TOTAL_N} Generation-12 changed objects correspond to the reviewed commit" "${install_log}")" \
  "the installed-set check names Generation-12, which is what it compares against"
check "$(says_not "installed Generation-11 objects correspond" "${install_log}")" \
  "the installed-set check no longer calls the changed objects Generation-11"

check "$(says "every carried-over runtime object is exactly its accepted Generation-11 baseline" "${install_log}")" \
  "the carry-over check distinctly describes the unchanged predecessor-derived objects"

check "$(says "Generation 12 / installed Fabric dependency closure install: all checks passed" "${install_log}")" \
  "the --install banner identifies Generation 12"
check "$(says_not "Generation 11 / installed Fabric dependency closure install" "${install_log}")" \
  "the --install banner no longer identifies Generation 11"

# --- audit of the installed generation ------------------------------------
status="$(run_ceremony "${reporting}" --verify-installed)"
installed_log="${reporting}/last-run.log"
check "$([[ "${status}" == "0" ]] && echo yes || echo no)" \
  "--verify-installed still passes with corrected reporting (exit ${status})"
check "$(says "Generation 12 / installed Fabric dependency closure verify-installed: all checks passed" "${installed_log}")" \
  "the --verify-installed banner identifies Generation 12"
check "$(says_not "Generation 11 / installed Fabric dependency closure verify-installed" "${installed_log}")" \
  "the --verify-installed banner no longer identifies Generation 11"

# --- an already-installed host speaks in target-generation terms ----------
run_ceremony "${reporting}" --verify >/dev/null
already_log="${reporting}/last-run.log"
check "$(says "already at Generation 12" "${already_log}")" \
  "--verify against an installed host uses target-generation language"

# --- counts are derived from the matrix, not typed in --------------------
# A future matrix change must not be able to leave the operator output lying.
check "$(grep -q 'matrix_count_of REPLACE' "${CEREMONY}" && echo yes || echo no)" \
  "the REPLACE count is derived from the matrix"
check "$(grep -q 'matrix_count_of CREATE' "${CEREMONY}" && echo yes || echo no)" \
  "the CREATE count is derived from the matrix"
check "$(grep -qE '"(6|13|19)"? (REPLACE|CREATE|changed|replaced|created)' "${CEREMONY}" && echo no || echo yes)" \
  "no disposition count is hard-coded in an operator string"

# --- stale predecessor vocabulary is gone from post-commit paths ---------
for stale in \
  "recovery: the complete Generation-11 set is already installed" \
  "no Generation-11 object was published" \
  "the Generation-11 evidence does not record" \
  "Generation 11 remains installed" \
  "injected failure after staging a Generation-11 object" \
  "the Generation-11 library evidence is missing" \
  "the Generation-11 helper evidence is missing"
do
  check "$(grep -qF "${stale}" "${CEREMONY}" && echo no || echo yes)" \
    "stale post-commit string removed: \"${stale}\""
done

echo
if [[ -d "${LIBRARY_ROOT}" ]]; then
  ( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "${INSTALLED_AFTER}"
  if diff -q "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}" >/dev/null; then
    pass "the production installed runtime was not modified"
  else
    fail "the production installed runtime changed"
  fi
fi

if (( FAILURES > 0 )); then
  printf '\nGeneration-12 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf '\nGeneration-12 installer validation passed.\n'
