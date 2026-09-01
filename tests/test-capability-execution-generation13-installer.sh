#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-AU. The Generation-13 ceremony, against a host shaped like the
# real one, and every way it can be interrupted.
#
# WHAT MAKES THIS GENERATION DIFFERENT FROM ITS PREDECESSORS. Generation 13
# installs a runtime that EXECUTES. A host carrying the new supervisor with the
# old result writer would run real workloads and record their outcomes under a
# contract that predates `succeeded`; one carrying the new worker without the
# Podman backend would fail at the moment it mattered most; one carrying
# execution without the recovery enumeration would leave orphaned containers
# nothing looks for. Those are not degraded generations, they are unreviewed
# ones -- so the only two acceptable outcomes of a failed install are a WHOLE
# Generation 12 or a WHOLE Generation 13, and the failure-injection matrix below
# is how that is proven rather than asserted.
#
# FIXTURE ONLY. Every case runs with --fixture against a throwaway root built
# from the live installed library. Nothing here reads or writes a production
# path, installs anything, or touches /root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-13.sh"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${CEREMONY}"

LIBRARY_ROOT=/usr/lib/kyri/python
host_only_requires "${LIBRARY_ROOT}"

WORK="$(mktemp -d)"
FAILURES=0
INSTALLED_BEFORE="$(mktemp)"; INSTALLED_AFTER="$(mktemp)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"; rm -f "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}"' EXIT

( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) \
  > "${INSTALLED_BEFORE}"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
check() { if [[ "$1" == "yes" ]]; then pass "$2"; else fail "$2"; fi; }

read_number() {
  sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1
}
BASELINE_N="$(read_number EXPECTED_LIBRARY_FILES_BASELINE)"
TARGET_N="$(read_number EXPECTED_LIBRARY_FILES_TARGET)"
GEN12_COMMIT="$(sed -n 's/^GEN12_COMMIT="\(.*\)"$/\1/p' "${CEREMONY}" | head -1)"

# The matrix, read out of the ceremony rather than restated. A suite carrying
# its own copy would test its copy.
matrix_rows() {
  sed -n '/^MATRIX=(/,/^)/p' "${CEREMONY}" | sed -n 's/^"\(.*\)"$/\1/p'
}
row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
row_target() {
  local target; target="$(row_field "$1" 2)"
  printf '%s' "${target#\$\{LIBRARY_ROOT\}/}"
}

# --- a Generation-12 host -------------------------------------------------------
#
# Built from the live installed library, which is the shape this ceremony
# governs. Its Generation-12 evidence is a sha256sum listing keyed by the real
# installed pathnames, exactly as that transaction wrote it.
# A Generation-12 library root, reconstructed from REVIEWED DATA rather than
# copied from the live host.
#
# This suite used to copy `/usr/lib/kyri/python` and call the result a
# Generation-12 host. That was true right up until the generation was installed
# on production, at which point the fixture silently became a Generation-13 tree
# and every case that starts at the predecessor failed. A baseline is reviewed
# data, so it is rebuilt from reviewed data: carried-over objects come from the
# host (they are identical in both generations, which the matrix is what
# establishes), REPLACE targets are restored to the baseline bytes the matrix
# pins, and CREATE targets are removed.
#
# The helper library modules are copied as they are: they belong to the helper
# ceremony, are unchanged by either generation, and are the stale state a real
# host carries.
gen12_blob() {
  # The reviewed bytes whose digest is "$2", for repository path "$1". Tried at
  # the Generation-12 authority first, then searched back through the history of
  # that path. A row whose baseline is in neither is a matrix that does not
  # describe any reviewed state, which is a failure rather than something to
  # work around.
  local source="$1" wanted="$2" commit
  if [[ "$(git -C "${REPOSITORY}" show "${GEN12_COMMIT}:${source}" 2>/dev/null \
             | sha256sum | cut -d' ' -f1)" == "${wanted}" ]]; then
    git -C "${REPOSITORY}" show "${GEN12_COMMIT}:${source}"
    return 0
  fi
  while IFS= read -r commit; do
    if [[ "$(git -C "${REPOSITORY}" show "${commit}:${source}" 2>/dev/null \
               | sha256sum | cut -d' ' -f1)" == "${wanted}" ]]; then
      git -C "${REPOSITORY}" show "${commit}:${source}"
      return 0
    fi
  done < <(git -C "${REPOSITORY}" log --format=%H -- "${source}")
  return 1
}

build_host() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}${LIBRARY_ROOT}" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/usr/libexec" "${root}/etc/kyri"
  ( cd "${LIBRARY_ROOT}" && find . -type f -name '*.py' -not -path '*__pycache__*' -print0 ) \
    | ( cd "${LIBRARY_ROOT}" && xargs -0 -I{} cp --parents {} "${root}${LIBRARY_ROOT}/" )

  local row target source base
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="${root}${LIBRARY_ROOT}/$(row_target "${row}")"
    source="$(row_field "${row}" 1)"
    base="$(row_field "${row}" 5)"
    if [[ "$(row_field "${row}" 4)" == "CREATE" ]]; then
      rm -f "${target}"
      continue
    fi
    mkdir -p "$(dirname "${target}")"
    # The copied objects arrive 0444, so the baseline is written into a fresh
    # file rather than over a read-only one.
    rm -f "${target}"
    gen12_blob "${source}" "${base}" > "${target}" \
      || { printf 'FIXTURE: no reviewed bytes hash to %s for %s\n' \
             "${base}" "${source}" >&2; return 1; }
    [[ "$(sha256sum "${target}" | cut -d' ' -f1)" == "${base}" ]] \
      || { printf 'FIXTURE: %s did not restore to its baseline\n' "${source}" >&2; return 1; }
    chmod 0444 "${target}"
  done < <(matrix_rows)

  ( cd "${root}${LIBRARY_ROOT}" && find . -type f -name '*.py' -print0 | sort -z \
      | xargs -0 sha256sum ) \
    | sed "s#  \\./#  ${LIBRARY_ROOT}/#" > "${root}/root/kyri-gen12-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN12_COMMIT}"
    printf 'state COMMITTED\n'
  } > "${root}/root/kyri-gen12-helper-digests.txt"
  # The privileged surface as a real host carries it: stale, and none of it
  # this ceremony's to touch.
  local helper
  for helper in kyri-exec-transition kyri-exec-verify kyri-exec-quota \
                kyri-exec-worker.py kyri-exec-verify-worker.py; do
    [[ -f "/usr/libexec/${helper}" ]] && cp "/usr/libexec/${helper}" "${root}/usr/libexec/${helper}"
  done
  return 0
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1
}

library_count() { find "$1${LIBRARY_ROOT}" -type f -name '*.py' | wc -l; }

# Every target at baseline, every CREATE absent: a whole Generation 12.
is_whole_gen12() {
  local root="$1" row target want state
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="${root}${LIBRARY_ROOT}/$(row_target "${row}")"
    if [[ "$(row_field "${row}" 4)" == "CREATE" ]]; then
      [[ -e "${target}" ]] && { printf 'no'; return; }
    else
      want="$(row_field "${row}" 5)"
      [[ "$(sha256sum "${target}" 2>/dev/null | cut -d' ' -f1)" == "${want}" ]] \
        || { printf 'no'; return; }
    fi
  done < <(matrix_rows)
  [[ "$(library_count "${root}")" == "${BASELINE_N}" ]] || { printf 'no'; return; }
  printf 'yes'
}

is_whole_gen13() {
  local root="$1" row target want
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="${root}${LIBRARY_ROOT}/$(row_target "${row}")"
    want="$(row_field "${row}" 6)"
    [[ "$(sha256sum "${target}" 2>/dev/null | cut -d' ' -f1)" == "${want}" ]] \
      || { printf 'no'; return; }
  done < <(matrix_rows)
  [[ "$(library_count "${root}")" == "${TARGET_N}" ]] || { printf 'no'; return; }
  printf 'yes'
}

no_residue() {
  local root="$1"
  if find "${root}${LIBRARY_ROOT}" \( -name '*.kyri-gen13.new' -o -name '*.kyri-gen13.gen12' \) \
       -print -quit | grep -q .; then printf 'no'; else printf 'yes'; fi
}

# ===========================================================================
# 1. the package, before any host is touched
# ===========================================================================
root="${WORK}/source"; build_host "${root}"
if run_ceremony "${root}" --verify-source; then
  pass "--verify-source accepts the package"
else
  fail "--verify-source refused: $(grep -E '^(FAIL|STOP)' "${root}/last-run.log" | head -3)"
fi
if grep -q "no installed path was read for state" "${root}/last-run.log"; then
  pass "--verify-source reasons about the package, not the host"
else
  fail "--verify-source did not state its source-only claim"
fi

# The claim is checked rather than believed: an empty root has no installed
# library at all, and the package must still verify.
root="${WORK}/source-empty"; mkdir -p "${root}"
if run_ceremony "${root}" --verify-source; then
  pass "--verify-source needs no installed runtime to answer"
else
  fail "--verify-source consulted the host: $(grep -E '^(FAIL|STOP)' "${root}/last-run.log" | head -3)"
fi

# ===========================================================================
# 2. the host, read-only
# ===========================================================================
root="${WORK}/verify"; build_host "${root}"
if run_ceremony "${root}" --verify && grep -q "ready for the Generation-13 installation" "${root}/last-run.log"; then
  pass "--verify reports a Generation-12 host ready to install"
else
  fail "--verify did not accept a Generation-12 host: $(grep -E '^(FAIL|STOP)' "${root}/last-run.log" | head -3)"
fi
check "$(is_whole_gen12 "${root}")" "--verify mutated nothing"
if grep -q "NOT execution-ready" "${root}/last-run.log"; then
  pass "--verify says installable and not execution-ready, separately"
else
  fail "--verify did not distinguish installable from execution-ready"
fi

# ===========================================================================
# 3. the whole transaction
# ===========================================================================
root="${WORK}/install"; build_host "${root}"
if run_ceremony "${root}" --install; then
  pass "--install completes on a Generation-12 host"
else
  fail "--install failed: $(grep -E '^(FAIL|STOP)' "${root}/last-run.log" | head -5)"
fi
check "$(is_whole_gen13 "${root}")" "the host is a whole Generation 13 ($(library_count "${root}") objects)"
check "$(no_residue "${root}")" "no transaction artefact remains"
if [[ -f "${root}/root/kyri-gen13-library-digests.txt" \
   && -f "${root}/root/kyri-gen13-helper-digests.txt" ]]; then
  pass "Generation-13 evidence was written"
else
  fail "Generation-13 evidence is missing"
fi
if [[ -f "${root}/root/kyri-gen12-library-digests.txt" ]]; then
  pass "Generation-12 evidence was preserved"
else
  fail "Generation-12 evidence was consumed"
fi
if grep -q '^state=COMMITTED' "${root}/root/kyri-gen13-transaction/journal"; then
  pass "the journal is COMMITTED"
else
  fail "the journal is not COMMITTED"
fi
if [[ ! -e "${root}/root/kyri-gen12-transaction" ]]; then
  pass "the predecessor's transaction namespace was never created or read as this one's"
else
  fail "this ceremony touched the Generation-12 transaction namespace"
fi

if run_ceremony "${root}" --verify-installed; then
  pass "--verify-installed accepts the result"
else
  fail "--verify-installed refused: $(grep -E '^(FAIL|STOP)' "${root}/last-run.log" | head -3)"
fi

# ===========================================================================
# 4. already installed
# ===========================================================================
before="$(cd "${root}${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
journal_before="$(sha256sum "${root}/root/kyri-gen13-transaction/journal" | cut -d' ' -f1)"
evidence_before="$(sha256sum "${root}/root/kyri-gen13-library-digests.txt" | cut -d' ' -f1)"
if run_ceremony "${root}" --install && grep -q "already installed: nothing to do" "${root}/last-run.log"; then
  pass "a second --install detects the installed generation and stops"
else
  fail "a second --install did not report already-installed"
fi
after="$(cd "${root}${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)"
check "$([[ "${before}" == "${after}" ]] && printf yes || printf no)" \
  "a second --install mutated nothing"
check "$([[ "${journal_before}" == "$(sha256sum "${root}/root/kyri-gen13-transaction/journal" | cut -d' ' -f1)" ]] && printf yes || printf no)" \
  "a second --install rewrote no journal"
check "$([[ "${evidence_before}" == "$(sha256sum "${root}/root/kyri-gen13-library-digests.txt" | cut -d' ' -f1)" ]] && printf yes || printf no)" \
  "a second --install rewrote no evidence"

# ===========================================================================
# 5. the failure-injection matrix
# ===========================================================================
#
# Every named point, plus a commit position inside each coherence group and
# between the two objects whose split G11-AL found. After each one the host must
# be a WHOLE Generation 12 -- not merely "mostly" -- and recovery must agree.
inject_case() {
  local label="$1" fail_at="$2"
  local root="${WORK}/fail-${label//[^a-zA-Z0-9]/_}"
  build_host "${root}"
  KYRI_GEN13_FAIL_AT="${fail_at}" run_ceremony "${root}" --install || true
  local state; state="$(is_whole_gen12 "${root}")"
  if [[ "${state}" != "yes" ]]; then
    fail "failure at ${label}: the host is not a whole Generation 12"
    return
  fi
  # Then recovery, which must agree rather than change its mind.
  if [[ -f "${root}/root/kyri-gen13-transaction/journal" ]]; then
    run_ceremony "${root}" --recover || true
    [[ "$(is_whole_gen12 "${root}")" == "yes" ]] \
      || { fail "recovery after ${label} did not leave a whole Generation 12"; return; }
  fi
  [[ "$(no_residue "${root}")" == "yes" ]] \
    || { fail "failure at ${label} left transaction residue"; return; }
  pass "failure at ${label}: whole Generation 12, recovered, no residue"
}

for point in stage staged prepared committing publish verify precommit; do
  inject_case "${point}" "${point}"
done

# ===========================================================================
# 6. the coherence splits, by commit position
# ===========================================================================
#
# A publication that stops part way through is the only way a split could
# happen, so each of these stops at a position chosen to straddle a boundary
# that would matter. The assertion is the same every time and that is the point:
# the transaction has no partial success to expose.
group_boundary() {
  local wanted="$1" index=0 row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    index=$((index + 1))
    [[ "$(row_field "${row}" 7)" == "${wanted}" ]] && { printf '%s' "${index}"; return; }
  done < <(matrix_rows)
  printf '1'
}
position_of() {
  local wanted="$1" index=0 row
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    index=$((index + 1))
    [[ "$(row_target "${row}")" == "${wanted}" ]] && { printf '%s' "${index}"; return; }
  done < <(matrix_rows)
  printf '0'
}

WORKER_AT="$(position_of tools/capability/execution/worker.py)"
BACKEND_AT="$(position_of kyri_exec_podman.py)"
SUPERVISION_AT="$(position_of tools/capability/execution/supervision.py)"
RECORDS_AT="$(position_of tools/capability/records.py)"
RECOVERY_AT="$(position_of tools/capability/execution/recovery.py)"

if [[ "${WORKER_AT}" != "0" && "${BACKEND_AT}" != "0" && "${SUPERVISION_AT}" != "0" \
   && "${RECORDS_AT}" != "0" && "${RECOVERY_AT}" != "0" ]]; then
  pass "every coherence-critical object is in the matrix"
else
  fail "a coherence-critical object is missing from the matrix: worker=${WORKER_AT} backend=${BACKEND_AT} supervision=${SUPERVISION_AT} records=${RECORDS_AT} recovery=${RECOVERY_AT}"
fi

# The G11-AL split: a new worker with the backend it imports still missing.
inject_case "between the worker and the Podman backend" \
  "$(( WORKER_AT < BACKEND_AT ? BACKEND_AT : WORKER_AT ))"
# The safety-critical split: new execution bytes over an old result writer.
inject_case "between the supervisor and the result writer" \
  "$(( SUPERVISION_AT < RECORDS_AT ? RECORDS_AT : SUPERVISION_AT ))"
# Execution without the recovery semantics that clean up after it.
inject_case "between execution and the recovery enumeration" \
  "$(( SUPERVISION_AT < RECOVERY_AT ? RECOVERY_AT : SUPERVISION_AT ))"
# And the last object before the commit point, which is the closest a partial
# publication can get to looking complete.
inject_case "the last target before the commit point" "$(matrix_rows | grep -c .)"

# ===========================================================================
# 7. after the commit point, the generation stands
# ===========================================================================
for point in postcommit evidence cleanup; do
  root="${WORK}/after-${point}"; build_host "${root}"
  KYRI_GEN13_FAIL_AT="${point}" run_ceremony "${root}" --install || true
  if [[ "$(is_whole_gen13 "${root}")" == "yes" ]]; then
    pass "failure at ${point}: Generation 13 stands, as the commit point requires"
  else
    fail "failure at ${point} reverted a committed generation"
  fi
done

# A COMMITTED journal whose targets agree settles without rolling anything back.
root="${WORK}/recover-committed"; build_host "${root}"
run_ceremony "${root}" --install || true
if run_ceremony "${root}" --recover \
   && grep -q "already installed" "${root}/last-run.log"; then
  pass "--recover on a committed transaction settles without a rollback"
else
  fail "--recover downgraded or refused an accepted Generation 13"
fi
check "$(is_whole_gen13 "${root}")" "--recover left Generation 13 installed"

# ===========================================================================
# 8. journal and truth disagree
# ===========================================================================
root="${WORK}/journal-lies"; build_host "${root}"
run_ceremony "${root}" --install || true
# A committed journal, and one target quietly reverted underneath it. The
# ceremony must refuse rather than believe either side.
target="${root}${LIBRARY_ROOT}/tools/capability/records.py"
chmod u+w "${target}"; printf '# not the generation-13 object\n' > "${target}"
if run_ceremony "${root}" --install; then
  fail "a COMMITTED journal was believed over the bytes on disk"
else
  if grep -qE "operator disposition|UNKNOWN" "${root}/last-run.log"; then
    pass "a COMMITTED journal disagreeing with the targets requires operator disposition"
  else
    fail "the disagreement was refused for the wrong reason: $(tail -3 "${root}/last-run.log")"
  fi
fi

# ===========================================================================
# 9. unknown bytes are never overwritten
# ===========================================================================
unknown_case() {
  local label="$1" relative="$2"
  local root="${WORK}/unknown-${label}"
  build_host "${root}"
  local target="${root}${LIBRARY_ROOT}/${relative}"
  mkdir -p "$(dirname "${target}")"
  chmod u+w "${target}" 2>/dev/null || true
  printf '# an operator put this here and nobody knows why\n' > "${target}"
  local before; before="$(sha256sum "${target}" | cut -d' ' -f1)"
  if run_ceremony "${root}" --install; then
    fail "unknown bytes at ${relative} were installed over"
    return
  fi
  if [[ "$(sha256sum "${target}" | cut -d' ' -f1)" != "${before}" ]]; then
    fail "unknown bytes at ${relative} were modified by a refused install"
    return
  fi
  if run_ceremony "${root}" --recover; then
    fail "recovery overwrote unknown bytes at ${relative}"
    return
  fi
  if [[ "$(sha256sum "${target}" | cut -d' ' -f1)" != "${before}" ]]; then
    fail "recovery modified unknown bytes at ${relative}"
    return
  fi
  pass "unknown bytes at ${relative} are refused and left exactly as found"
}
# One of each class: a REPLACE whose predecessor is not the baseline, and a
# CREATE whose pathname is already occupied.
unknown_case replace tools/capability/coordinator.py
unknown_case create tools/capability/execution/supervision.py

# ===========================================================================
# 10. the privileged surface is untouched
# ===========================================================================
root="${WORK}/privileged"; build_host "${root}"
privileged_manifest() {
  local root="$1"
  { find "${root}/usr/libexec" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum
    find "${root}/etc/sudoers.d" "${root}/etc/kyri" -type f -print0 2>/dev/null \
      | sort -z | xargs -0 sha256sum
    printf 'sudoers-entries %s\n' "$(find "${root}/etc/sudoers.d" -type f 2>/dev/null | wc -l)"
    printf 'etc-kyri-entries %s\n' "$(find "${root}/etc/kyri" -type f 2>/dev/null | wc -l)"
    local helper
    for helper in kyri_exec_transition kyri_exec_transition_action kyri_exec_verify kyri_exec_quota; do
      printf '%s %s\n' "${helper}" \
        "$(sha256sum "${root}${LIBRARY_ROOT}/${helper}.py" 2>/dev/null | cut -d' ' -f1 || printf absent)"
    done
  } 2>/dev/null
}
before_privileged="$(privileged_manifest "${root}")"
run_ceremony "${root}" --install || true
after_privileged="$(privileged_manifest "${root}")"
check "$([[ "${before_privileged}" == "${after_privileged}" ]] && printf yes || printf no)" \
  "the helper set, both grants and both deployment identities are byte-identical after the install"
check "$([[ ! -e "${root}/etc/kyri/coordinator-identity.json" \
          && ! -e "${root}/etc/kyri/execution-identity.json" ]] && printf yes || printf no)" \
  "the runtime installer created no deployment identity authority"
check "$([[ -z "$(find "${root}/etc/sudoers.d" -type f 2>/dev/null)" ]] && printf yes || printf no)" \
  "the runtime installer created no sudoers grant"

# ===========================================================================
# 11. the ceremony speaks in its own generation
# ===========================================================================
root="${WORK}/vocabulary"; build_host "${root}"
run_ceremony "${root}" --install || true
if grep -qE "Generation 12 (installed|stands)|Generation-12 evidence written|kyri-gen12-transaction" \
     "${root}/last-run.log"; then
  fail "the ceremony reported in predecessor-generation terms: $(grep -nE 'Generation 12 (installed|stands)|Generation-12 evidence written' "${root}/last-run.log" | head -2)"
else
  pass "no stale-generation success vocabulary in the install output"
fi
if grep -q "Generation-13 evidence written; Generation-12 evidence preserved" "${root}/last-run.log"; then
  pass "the evidence sentence names both generations truthfully"
else
  fail "the evidence sentence is missing or wrong"
fi
if grep -q "KYRI_GEN12_FAIL_AT" "${CEREMONY}"; then
  fail "the ceremony reuses the predecessor's fault namespace"
else
  pass "the fault namespace is this generation's own"
fi

# ===========================================================================
# 12. nothing production changed
# ===========================================================================
( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) \
  > "${INSTALLED_AFTER}"
if diff -q "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}" >/dev/null; then
  pass "the installed production runtime is byte-identical after this suite"
else
  fail "the installed production runtime changed while this suite ran"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Generation-13 installer validation passed.\n'
else
  printf 'Generation-13 installer validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
