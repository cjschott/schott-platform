#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-18 runtime installation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the installer touches is rebound under
# --fixture. No production runtime object is read for state and none is written;
# no sudo, no helper, no Podman, no container, no invocation.
#
# WHAT GENERATION 18 IS
# =====================
# TWO objects, in ONE coherence group, no CREATE and no carryover:
#
#   T  tools/capability/evidence.py       REPLACE, published FIRST
#      tools/capability/coordinator.py    REPLACE
#
# `evidence.py` gains the one reader answering "does this invocation already
# have a governed terminal result"; `coordinator.py` asks it before
# `supervisor.execute` rather than after.
#
# WHAT THIS SUITE IS FOR, BEYOND "THE INSTALLER WORKS"
# ====================================================
#   * THE ORDERING IS THE SAFETY PROPERTY, AND IT IS A DIFFERENT ONE. Generation
#     17's order came from a readiness authority closing execution first. NOTHING
#     HERE CLOSES EXECUTION. The order is instead: the module that DEFINES the
#     reader publishes before the module that IMPORTS it, because the reverse
#     intermediate is an ImportError on every `tools.capability.cli` command --
#     including `recover`. A reordered matrix must be refused.
#   * THIS GENERATION LEAVES READINESS UNTOUCHED -- the opposite of Generation
#     17. A fixture reporting `incompatible` afterwards would mean something
#     outside the matrix moved. Inheriting Generation 17's assertion here would
#     have been the defect, not the check.
#   * ONE GROUP MOVES WHOLLY, and neither member is a valid complete Generation
#     18 alone. That is asserted directly, by importing each mix.
#
# THE FIXTURE IS RECONSTRUCTED, NOT COPIED
# ========================================
# The PATH SET comes from the installed library root -- which objects a
# generation actually published -- and the BYTES from reviewed git objects: the
# Generation-17 authority for the runtime half, and each accepted helper
# ceremony's own matrix for the objects it governs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-18.sh"
CEREMONY="${ROOT}/provisioning/execution/gen18-operator-ceremony.txt"

# HOST-ONLY, for the same reason every generation suite is: the fixture's PATH
# SET is the accepted Generation-17 surface, read from the installed runtime.
# Only the BYTES come from git. That is what makes the baseline a reconstruction
# of what a generation actually published rather than of whatever the repository
# happens to contain -- and it means this suite has nothing to reconstruct
# against on a machine with no installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

# Read from the installer rather than restated, so the two cannot drift.
GEN18_COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
GEN17_COMMIT="$(sed -n 's/^GEN17_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
[[ -n "${GEN18_COMMIT}" && -n "${GEN17_COMMIT}" ]] \
  || { printf 'cannot read the source authorities from the installer\n' >&2; exit 1; }

# The declared Generation-18 rows, read rather than restated.
matrix_rows() { sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"'; }
row_for()   { matrix_rows | grep -F "\"$1|" | head -1; }
row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

EVIDENCE_ROW="$(row_for 'tools/capability/evidence.py')"
COORDINATOR_ROW="$(row_for 'tools/capability/coordinator.py')"
[[ -n "${EVIDENCE_ROW}" && -n "${COORDINATOR_ROW}" ]] \
  || { printf 'cannot read the declared Generation-18 rows\n' >&2; exit 1; }

EVIDENCE_BASE="$(row_field "${EVIDENCE_ROW}" 5)"
EVIDENCE_WANT="$(row_field "${EVIDENCE_ROW}" 6)"
COORDINATOR_BASE="$(row_field "${COORDINATOR_ROW}" 5)"
COORDINATOR_WANT="$(row_field "${COORDINATOR_ROW}" 6)"

# Installed-path helpers, so assertions read the same way for both.
installed_of() {
  case "$1" in
    evidence)    printf 'usr/lib/kyri/python/tools/capability/evidence.py' ;;
    coordinator) printf 'usr/lib/kyri/python/tools/capability/coordinator.py' ;;
  esac
}
digest_at() { sha256sum "$1/$(installed_of "$2")" | cut -d' ' -f1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- the accepted Generation-17 baseline, reconstructed ---------------------

# The declared privileged helper paths, read from the INSTALLED declaration so a
# helper added later cannot quietly fall out of the fixture.
declared_helper_paths() {
  PYTHONDONTWRITEBYTECODE=1 python3 - <<'HELPERPY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location(
    "installed_helpers",
    "/usr/lib/kyri/python/tools/capability/execution/helpers.py")  # prod-path-reference
mod = importlib.util.module_from_spec(spec)
sys.modules["installed_helpers"] = mod
spec.loader.exec_module(mod)
for helper in mod.REQUIRED_HELPERS:
    print(helper.path)
HELPERPY
}

# The accepted POST digest for one library-root-relative object, taken from the
# last accepted helper ceremony that governs it. The ceremony list and its order
# are read from the installer, so the fixture cannot disagree with the thing it
# is a fixture for.
ceremonies() {
  sed -n '/^CEREMONIES_BEFORE_THIS_GENERATION=(/,/^)$/p' "${INSTALLER}" \
    | sed -n 's/^ *"\(.*\)"$/\1/p'
}

ceremony_post() {
  local relative="$1" ceremony line target post answer=''
  # shellcheck disable=SC2016  # the matrix stores the placeholder literally
  local ph='${LIBRARY_ROOT}/'
  while IFS= read -r ceremony; do
    [[ -f "${ROOT}/${ceremony}" ]] || continue
    while IFS= read -r line; do
      line="${line#\"}"; line="${line%\"}"
      IFS='|' read -r _ target _ _ _ post _ <<<"${line}"
      [[ "${target}" == *"${ph}"* ]] || continue
      [[ "${target##*"${ph}"}" == "${relative}" ]] || continue
      answer="${post}"
    done < <(sed -n '/^MATRIX=(/,/^)$/p' "${ROOT}/${ceremony}" | grep '^"')
  done < <(ceremonies)
  [[ -n "${answer}" ]] || return 1
  printf '%s' "${answer}"
}

# The reviewed bytes that hash to a declared digest, found in this repository's
# own history. Digest-pinned, so it cannot return anything but what was declared.
blob_by_digest() {
  local source="$1" wanted="$2" commit
  while IFS= read -r commit; do
    [[ -n "${commit}" ]] || continue
    if [[ "$(git -C "${ROOT}" show "${commit}:${source}" 2>/dev/null \
               | sha256sum | cut -d' ' -f1)" == "${wanted}" ]]; then
      git -C "${ROOT}" show "${commit}:${source}"
      return 0
    fi
  done < <(git -C "${ROOT}" log --format=%H -- "${source}")
  return 1
}

build_fixture() {
  local root="$1"
  rm -rf "${root}"
  local lib="${root}/usr/lib/kyri/python"
  # Every path here is prefixed with the fixture root and none is the production
  # path it mirrors. Each line carries the marker so the exception is greppable
  # rather than hidden.
  mkdir -p "${lib}" "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d"
  mkdir -p "${root}/etc/kyri"                                       # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority"          # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority-control"  # prod-path-reference

  local staging; staging="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN17_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The PATH SET is the accepted Generation-17 surface; the BYTES come from the
  # Generation-17 authority. Generation 18 CREATEs nothing, so unlike the
  # Generation-17 fixture there is no successor pathname to subtract -- which is
  # itself asserted below, because a Generation 18 that grew a CREATE would make
  # this reconstruction silently wrong.
  local object
  while IFS= read -r object; do
    [[ -f "${staging}/${object}" ]] || continue
    install -D -m 0444 "${staging}/${object}" "${lib}/${object}"
  done < <( cd /usr/lib/kyri/python && find tools -type f -name '*.py' \
              ! -path '*__pycache__*' | sort )

  # Library-root modules, by the same rule: the accepted generation decides
  # WHICH, git decides what.
  local module source
  while IFS= read -r module; do
    source="${staging}/provisioning/execution/${module%.py}"
    source="${source//_/-}.py"
    [[ -f "${source}" ]] || continue
    install -m 0444 "${source}" "${lib}/${module}"
  done < <( cd /usr/lib/kyri/python && find . -maxdepth 1 -type f -name 'kyri_exec_*.py' \
              -printf '%P\n' | sort )

  # The accepted helper-ceremony overlay. BOTH ceremonies are accepted before
  # this generation, so each governed object sits at the LAST accepted target --
  # not at either side of a pending ceremony, which is the state Generation 17
  # had to tolerate and this one does not.
  local relative post
  while IFS= read -r relative; do
    post="$(ceremony_post "${relative}")" || continue
    blob_by_digest "provisioning/execution/$(printf '%s' "${relative%.py}" | tr '_' '-').py" \
      "${post}" > "${lib}/${relative}.tmp" 2>/dev/null || {
        printf 'FIXTURE: no reviewed bytes hash to %s for %s\n' "${post}" "${relative}" >&2
        rm -f "${lib}/${relative}.tmp"; rm -rf "${staging}"; return 1; }
    install -m 0444 "${lib}/${relative}.tmp" "${lib}/${relative}"
    rm -f "${lib}/${relative}.tmp"
  done < <( cd "${lib}" && find . -maxdepth 1 -type f -name 'kyri_exec_*.py' -printf '%P\n' | sort )

  # The evidence the installer requires of its predecessor. Generation-17
  # evidence records the Generation-17 surface as that ceremony wrote it: the
  # library hashed at the moment it committed. Both helper ceremonies that
  # govern library objects had already run by then EXCEPT G11-BB, which
  # published after Generation 17 -- so those rows carry G11-BB's PREDECESSOR
  # bytes, exactly as the real file does.
  local evidence="${root}/root/kyri-gen17-library-digests.txt"
  : > "${evidence}"
  local digest bbpre
  while IFS= read -r relative; do
    digest="$(sha256sum "${lib}/${relative}" | cut -d' ' -f1)"
    if bbpre="$(bb_predecessor "${relative}")"; then digest="${bbpre}"; fi
    printf '%s  /usr/lib/kyri/python/%s\n' "${digest}" "${relative}" >> "${evidence}"
  done < <( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort )

  # G11-BA installed the launch and reconcile grants. They are still installed,
  # unchanged, and the accepted deployment plan keeps them through Generation 18.
  # The verify grant stays absent.
  printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%s \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH\n' \
    "$(sha256sum /usr/libexec/kyri-exec-transition | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-launch"
  printf 'Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:%s \\\n    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE\n' \
    "$(sha256sum /usr/libexec/kyri-exec-reconcile | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-reconcile"
  chmod 0440 "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-reconcile"

  # Every declared privileged helper, carried as the host holds it. Generation 18
  # moves none of these; they are here so the fixture can be asked the real
  # readiness question and be expected to answer `compatible` throughout.
  local helper
  while IFS= read -r helper; do
    [[ "${helper}" == /usr/libexec/* ]] || continue
    install -D -m 0555 "${helper}" "${root}${helper}"   # prod-path-reference
  done < <(declared_helper_paths)

  : > "${root}/root/kyri-gen17-helper-digests.txt"
  for object in "${staging}"/provisioning/execution/kyri-exec-*; do
    [[ -f "${object}" ]] || continue
    printf '%s  /usr/libexec/%s\n' "$(sha256sum "${object}" | cut -d' ' -f1)" \
      "$(basename "${object}")" >> "${root}/root/kyri-gen17-helper-digests.txt"
  done

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"  # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"  # prod-path-reference

  rm -rf "${staging}"
}

# The G11-BB PREDECESSOR digest for one library-root object, or nothing. That
# ceremony published AFTER Generation 17 committed, so Generation-17 evidence
# records the bytes that were there before it ran -- and a fixture whose evidence
# recorded the post bytes would be describing a host that never existed.
bb_predecessor() {
  local relative="$1" line target pre
  # shellcheck disable=SC2016  # the matrix stores the placeholder literally
  local ph='${LIBRARY_ROOT}/'
  while IFS= read -r line; do
    line="${line#\"}"; line="${line%\"}"
    IFS='|' read -r _ target _ _ pre _ _ <<<"${line}"
    [[ "${target}" == *"${ph}"* ]] || continue
    [[ "${target##*"${ph}"}" == "${relative}" ]] || continue
    printf '%s' "${pre}"; return 0
  done < <(sed -n '/^MATRIX=(/,/^)$/p' \
             "${ROOT}/provisioning/execution/install-g11-bb-helpers.sh" | grep '^"')
  return 1
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }
manifest() {
  { find "$1" -printf '%P %m %s\n' | sort
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum \
      | sed "s|${1}||"; } | sha256sum | cut -d' ' -f1
}
run_installer() {
  local root="$1" mode="$2"
  shift 2
  ( cd "${ROOT}" && env "$@" PYTHONDONTWRITEBYTECODE=1 \
      bash "${INSTALLER}" "${mode}" --fixture "${root}" ) \
    > "${WORK}/last-run.log" 2>&1
}
# What the fixture's own runtime says about helper compatibility. Generation 18
# must not move it, which is the opposite of what Generation 17 required.
fixture_verdict() {
  # THE PATHS IN REQUIRED_HELPERS ARE COMPILED-IN AND ABSOLUTE, so a bare
  # `helpers.compatibility()` judges the LIVE host no matter which tree the
  # module was imported from. That made this assertion silently about
  # production: it held only while the live helper surface still matched this
  # generation's declaration, and inverted the moment the G11-BC-E ceremony
  # moved the action module (G11-BC-G).
  #
  # The question this case asks is "what does THIS FIXTURE report", so the
  # declared paths are rebased onto the fixture root and passed in explicitly.
  # `compatibility()` takes `required` for exactly this reason.
  ( cd "$1/usr/lib/kyri/python" && FIXTURE_ROOT="$1" \
      PYTHONDONTWRITEBYTECODE=1 python3 -c '
import os, sys
sys.path.insert(0, ".")
from tools.capability.execution import helpers
root = os.environ["FIXTURE_ROOT"]
rebased = tuple(
    helpers.RequiredHelper(path=root + h.path, digest=h.digest, purpose=h.purpose)
    for h in helpers.REQUIRED_HELPERS)
print(helpers.compatibility(required=rebased).verdict)
' 2>/dev/null ) || printf 'unavailable'
}

# Does this fixture's library still import? That is the Generation-18 safety
# property in one question. `tools.capability.cli` is the entry every governed
# command loads, and it imports `coordinator`, which imports `evidence` at
# module load -- so old-evidence beside new-coordinator fails HERE, which is
# exactly the state publication order exists to make unreachable.
importable() {
  ( cd "$1/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
sys.path.insert(0, ".")
import tools.capability.cli
' ) >/dev/null 2>&1
}

# ===========================================================================
# A. the declared shape
# ===========================================================================

for pair in "evidence ${EVIDENCE_BASE} ${EVIDENCE_WANT}" \
            "coordinator ${COORDINATOR_BASE} ${COORDINATOR_WANT}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$2" != "$3" ]]; then
    pass "the declaration moves $1 off its Generation-17 bytes"
  else
    fail "the declared baseline and target for $1 are the same digest"
  fi
done

# Two rows, no CREATE, no REMOVE. The object-count expectations depend on it.
declared_rows="$(matrix_rows | wc -l)"
if [[ "${declared_rows}" == "2" ]]; then
  pass "the matrix declares exactly two objects"
else
  fail "the matrix declares ${declared_rows} objects, expected 2"
fi
if matrix_rows | grep -qE '\|(CREATE|REMOVE)\|'; then
  fail "the matrix declares a CREATE or REMOVE; this generation replaces two objects and nothing else"
else
  pass "the matrix declares no CREATE and no REMOVE"
fi
if [[ "$(matrix_rows | wc -l)" == "2" ]]; then
  pass "the matrix declares exactly two rows"
else
  fail "the matrix declares $(matrix_rows | wc -l) rows, expected 2"
fi

# ONE group, and it moves WHOLLY. A group with a member left behind is the split
# require_group_coherence exists to catch -- and here a split is not a
# degradation, it is an ImportError or a gate nobody calls.
groups="$(matrix_rows | rev | cut -d'|' -f1 | rev | tr -d '"' | sort -u | tr '\n' ' ')"
if [[ "${groups}" == "T " ]]; then
  pass "the matrix declares exactly one group, T"
else
  fail "the matrix declares groups '${groups}', expected 'T '"
fi

# Every letter the matrix carries must have a name. Generation 17 shipped a row
# in group A with no case for it, so a split there would have reported "unknown
# group A" -- the exact failure its own comment said the names prevent.
unnamed=0
while IFS= read -r letter; do
  grep -qE "^    ${letter}\) printf" "${INSTALLER}" || { unnamed=$((unnamed + 1)); }
done < <(matrix_rows | rev | cut -d'|' -f1 | rev | tr -d '"' | sort -u)
if (( unnamed == 0 )); then
  pass "every coherence group in the matrix has a name in group_name"
else
  fail "${unnamed} coherence group(s) in the matrix have no name"
fi

# THE ORDERING. evidence.py must be row one: it DEFINES the reader coordinator.py
# imports at module load. This is NOT Generation 17's reason -- nothing here
# closes execution -- and inheriting that reason would have been the defect.
if [[ "$(matrix_rows | head -1)" == "${EVIDENCE_ROW}" ]]; then
  pass "evidence.py is the first published row, so the definition precedes its importer"
else
  fail "the first published row is not evidence.py"
fi
if [[ "$(matrix_rows | tail -1)" == "${COORDINATOR_ROW}" ]]; then
  pass "coordinator.py is the second published row"
else
  fail "the second published row is not coordinator.py"
fi

# No carryover: every group member is a row.
carryover_entries() {
  # CARRYOVER=() is a single line, so a range ending at /^)$/ would run to EOF
  # and count the matrix rows instead. Handle the empty form explicitly.
  grep -q '^CARRYOVER=()$' "${INSTALLER}" && { printf '0'; return; }
  sed -n '/^CARRYOVER=(/,/^)$/p' "${INSTALLER}" | grep -c '^"'
}
if [[ "$(carryover_entries)" == "0" ]]; then
  pass "the carryover list is empty: every member of both groups is a declared row"
else
  fail "a carryover is declared; this generation moves every group member"
fi

# The correction, in the reviewed bytes rather than in a commit message -- and
# as ORDER, not as the presence of a word. A grep for the gate would pass on a
# coordinator that called it AFTER supervisor.execute, which is the defect.
coordinator_src="$(git -C "${ROOT}" show "${GEN18_COMMIT}:tools/capability/coordinator.py")"
evidence_src="$(git -C "${ROOT}" show "${GEN18_COMMIT}:tools/capability/evidence.py")"
gate_line="$(grep -n 'require_no_terminal_result(store, invocation_record_id)' \
               <<<"${coordinator_src}" | head -1 | cut -d: -f1)"
exec_line="$(grep -n 'outcome = supervisor.execute(binding)' \
               <<<"${coordinator_src}" | head -1 | cut -d: -f1)"
if [[ -n "${gate_line}" && -n "${exec_line}" ]] && (( gate_line < exec_line )); then
  pass "the reviewed coordinator asks at line ${gate_line} and executes at line ${exec_line}"
else
  fail "the reviewed coordinator does not gate ahead of supervisor.execute (${gate_line:-absent} vs ${exec_line:-absent})"
fi
adapter_gate="$(grep -n 'require_no_terminal_result(store, decision.invocation_record_id)' \
                  <<<"${coordinator_src}" | head -1 | cut -d: -f1)"
adapter_exec="$(grep -n 'outcome = adapter.execute(execution_binding)' \
                  <<<"${coordinator_src}" | head -1 | cut -d: -f1)"
if [[ -n "${adapter_gate}" && -n "${adapter_exec}" ]] && (( adapter_gate < adapter_exec )); then
  pass "the locally executed path is gated at line ${adapter_gate}, ahead of ${adapter_exec}"
else
  fail "the reviewed coordinator does not gate the locally executed adapter path"
fi
if grep -q '^def existing_terminal_result' <<<"${evidence_src}" \
   && grep -q '^def require_no_terminal_result' <<<"${evidence_src}"; then
  pass "the reviewed evidence.py carries the shared reader and the gate wrapper"
else
  fail "the reviewed evidence.py is missing the shared reader or the gate wrapper"
fi
# The fail-open the old guard carried: matching on attempt_number == 1 meant a
# result with any other value blocked nothing.
if grep -q 'existing.get("attempt_number") == 1' <<<"${evidence_src}"; then
  fail "the reviewed evidence.py still matches on attempt_number == 1"
else
  pass "the attempt_number fail-open is gone from the reviewed evidence.py"
fi
if [[ "$(grep -c 'require_no_terminal_result' <<<"${evidence_src}")" -ge 2 ]]; then
  pass "record_terminal_result answers through the same wrapper as the gate"
else
  fail "the gate and the recording guard do not share a reader"
fi

# The live count MINUS every library-root pathname a later generation created
# AND actually published. The raw live count was the comparison until
# Generation 19 published abandonment.py, at which point the reconstruction was
# correct and the assertion about it was not: a fixture rebuilt from an earlier
# tree cannot hold an object that did not exist then. A generation that is
# declared but not installed is not subtracted -- that would describe a host
# nobody has.
successor_created_since() {
  local floor="$1" installer number row target operation created=0
  for installer in "${ROOT}"/provisioning/execution/install-generation-*.sh; do
    number="${installer##*-}"; number="${number%.sh}"
    [[ "${number}" =~ ^[0-9]+$ ]] || continue
    (( number > floor )) || continue
    # shellcheck disable=SC2016  # the matrix stores the placeholder literally
    while IFS= read -r row; do
      row="${row#\"}"; row="${row%\"}"
      IFS='|' read -r _ target _ operation _ <<<"${row}"
      [[ "${operation}" == "CREATE" ]] || continue
      [[ "${target}" == *'${LIBRARY_ROOT}/'* ]] || continue
      [[ -f "/usr/lib/kyri/python/${target##*'${LIBRARY_ROOT}/'}" ]] || continue
      created=$(( created + 1 ))
    done < <(sed -n '/^MATRIX=(/,/^)$/p' "${installer}" | grep '^"')
  done
  printf '%s' "${created}"
}

root="${WORK}/shape"; build_fixture "${root}"
baseline_count="$(library_count "${root}")"
live_count="$(find /usr/lib/kyri/python -type f -name '*.py' ! -path '*__pycache__*' | wc -l)"
expected_count=$(( live_count - $(successor_created_since 17) ))
if [[ "${baseline_count}" == "${expected_count}" ]]; then
  pass "the reconstructed Generation-17 fixture holds the accepted object count (${baseline_count})"
else
  fail "the fixture holds ${baseline_count} objects; the installed surface (${live_count}) less later creates gives ${expected_count}"
fi
for pair in "evidence ${EVIDENCE_BASE}" "coordinator ${COORDINATOR_BASE}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$(digest_at "${root}" "$1")" == "$2" ]]; then
    pass "the fixture carries the declared Generation-17 baseline for $1"
  else
    fail "the fixture's $1 is $(digest_at "${root}" "$1"), expected $2"
  fi
done

# ===========================================================================
# B. verify is non-mutating
# ===========================================================================

root="${WORK}/verify"; build_fixture "${root}"
before="$(manifest "${root}")"
if run_installer "${root}" --verify; then
  pass "--verify accepts the reconstructed Generation-17 baseline"
else
  fail "--verify rejected the baseline: $(grep -m3 -E '^(FAIL|STOP)' "${WORK}/last-run.log" | tr '\n' ' ')"
fi
after="$(manifest "${root}")"
if [[ "${before}" == "${after}" ]]; then
  pass "--verify wrote nothing"
else
  fail "--verify changed the fixture"
fi
if [[ -z "$(find "${root}" -name '__pycache__' -type d)" ]]; then
  pass "--verify left no bytecode behind"
else
  fail "--verify created __pycache__"
fi

# ===========================================================================
# C. install, verify-installed, and the carryover
# ===========================================================================

root="${WORK}/install"; build_fixture "${root}"
libexec_before_install="$(manifest "${root}/usr/libexec")"
sudoers_before_install="$(manifest "${root}/etc/sudoers.d")"
verdict_before_install="$(fixture_verdict "${root}")"

if run_installer "${root}" --install; then
  pass "--install completes"
else
  fail "--install failed: $(grep -m4 -E '^(FAIL|STOP)' "${WORK}/last-run.log" | tr '\n' ' ')"
fi

if [[ "$(library_count "${root}")" == "${baseline_count}" ]]; then
  pass "the installed library object count is unchanged (${baseline_count}): no CREATE, no REMOVE"
else
  fail "the installed library holds $(library_count "${root}"), expected ${baseline_count}"
fi

for pair in "evidence ${EVIDENCE_WANT}" "coordinator ${COORDINATOR_WANT}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$(digest_at "${root}" "$1")" == "$2" ]]; then
    pass "$1 moved to the reviewed Generation-18 bytes"
  else
    fail "$1 is $(digest_at "${root}" "$1"), expected $2"
  fi
  if [[ "$(stat -c '%a' "${root}/$(installed_of "$1")")" == "444" ]]; then
    pass "$1 carries the declared 0444 mode"
  else
    fail "$1 has mode $(stat -c '%a' "${root}/$(installed_of "$1")")"
  fi
done

if run_installer "${root}" --verify-installed; then
  pass "--verify-installed accepts the complete Generation-18 target"
else
  fail "--verify-installed rejected the target: $(grep -m4 -E '^(FAIL|STOP)' "${WORK}/last-run.log" | tr '\n' ' ')"
fi

# The corrections are in the INSTALLED bytes, and the runtime still imports.
if grep -q "cwd=SAFE_WORKING_DIRECTORY" "${root}/usr/lib/kyri/python/kyri_exec_podman.py"; then
  pass "the installed Podman backend states its working directory"
else
  fail "the installed Podman backend does not state cwd"
fi
if grep -q "cwd=SAFE_WORKING_DIRECTORY" "${root}/usr/lib/kyri/python/kyri_exec_launcher.py"; then
  pass "the installed launcher states the working directory of both helpers"
else
  fail "the installed launcher does not state cwd"
fi
if ( cd "${root}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c \
     'from tools.capability.execution import helpers; helpers.REQUIRED_HELPERS' \
     >/dev/null 2>&1 ); then
  pass "the installed declaration imports as a whole"
else
  fail "the installed declaration does not import"
fi

# ===========================================================================
# D. what this generation must NOT have moved, and what it MUST have closed
# ===========================================================================

if [[ ! -e "${root}/etc/sudoers.d/kyri-exec-verify" ]]; then
  pass "no verify grant was written"
else
  fail "the installation wrote a verify grant"
fi
if [[ "${sudoers_before_install}" == "$(manifest "${root}/etc/sudoers.d")" ]]; then
  pass "no grant changed: sudoers is byte-for-byte what the ceremony found"
else
  fail "the installation changed a sudoers grant"
fi
if [[ "${libexec_before_install}" == "$(manifest "${root}/usr/libexec")" ]]; then
  pass "no /usr/libexec object changed: both pinned entrypoints are untouched"
else
  fail "the installation changed /usr/libexec"
fi

# EXECUTION READINESS IS UNCHANGED, and that is the point. Generation 17 closed
# it deliberately; this generation moves no readiness authority, so `compatible`
# before and `compatible` after is the correct result. Inheriting Generation
# 17's `incompatible` expectation here would have asserted a property this
# generation does not have.
verdict_after_install="$(fixture_verdict "${root}")"
if [[ "${verdict_before_install}" == "compatible" ]]; then
  pass "the Generation-17 fixture reports 'compatible' to begin with"
else
  fail "the fixture reports '${verdict_before_install}' before installation, so the case below proves nothing"
fi
if [[ "${verdict_after_install}" == "compatible" ]]; then
  pass "helper compatibility is UNCHANGED at 'compatible': no readiness authority moved"
else
  fail "helper compatibility is '${verdict_after_install}' after installation, expected it unchanged at compatible"
fi

# THE COHERENCE GROUP, PROVEN BY IMPORT RATHER THAN BY THE MATRIX SAYING SO.
# Neither object is a valid complete Generation 18 alone, and the two failures
# are different: coordinator-alone cannot import, evidence-alone imports fine
# and defines a gate nobody calls.
mix="${WORK}/mix"; rm -rf "${mix}"; cp -a "${root}" "${mix}"; chmod -R u+w "${mix}"
cp "${root}.gen17-evidence" "${mix}/$(installed_of evidence)" 2>/dev/null ||   git -C "${ROOT}" show "${GEN17_COMMIT}:tools/capability/evidence.py"     > "${mix}/$(installed_of evidence)"
if importable "${mix}"; then
  fail "old evidence.py beside new coordinator.py imported; the ordering property is not real"
else
  pass "coordinator.py at Generation 18 against evidence.py at 17 cannot import"
fi

mix2="${WORK}/mix2"; rm -rf "${mix2}"; cp -a "${root}" "${mix2}"; chmod -R u+w "${mix2}"
git -C "${ROOT}" show "${GEN17_COMMIT}:tools/capability/coordinator.py" \
  > "${mix2}/$(installed_of coordinator)"
if importable "${mix2}"; then
  pass "evidence.py at Generation 18 against coordinator.py at 17 imports: the safe intermediate"
else
  fail "the safe intermediate does not import; publication order would have no safe state"
fi
if ( cd "${mix2}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import inspect, sys
sys.path.insert(0, ".")
from tools.capability import coordinator
raise SystemExit(0 if "require_no_terminal_result"
                 not in inspect.getsource(coordinator.execute_supervised) else 1)
' ); then
  pass "and in that intermediate the gate is defined but not called: a host that is not yet corrected"
else
  fail "the intermediate coordinator already calls the gate; the mix was not built as intended"
fi

# ===========================================================================
# D2. the invariant this generation exists to deploy, against the INSTALLED
#     fixture library rather than the repository
# ===========================================================================
#
# Everything above proves the right bytes landed. This proves the bytes DO the
# thing: a re-execute of an invocation that already has a terminal result
# refuses before the privileged helper is launched. Driven through the fixture's
# own `tools.capability`, so it is the deployed library answering.

if ( cd "${root}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 - "${WORK}/d2" <<'GATEPY'
import os, sys, tempfile
from datetime import datetime, timezone, timedelta
sys.path.insert(0, ".")
from tools.capability.store import CapabilityStore
from tools.capability.coordinator import execute_supervised
from tools.capability import evidence as E
from tools.capability.execution.supervision import (ExecutionSupervisor,
                                                    SupervisedBinding)

CENTRAL = timezone(timedelta(hours=-5))
WHEN = datetime(2026, 9, 14, 9, 0, 0, tzinfo=CENTRAL)
root = tempfile.mkdtemp(dir=sys.argv[1] if os.path.isdir(sys.argv[1]) else None)
store = CapabilityStore(root, expected_uid=os.getuid(), expected_gid=os.getgid())

def invocation(cinv):
    return {"kind": "capability-invocation", "schema_version": 2,
            "invocation_record_id": cinv, "invocation_id": "fixture-" + cinv,
            "request_id": "r", "actor": "op", "operation": "execute",
            "effect_class": "computational", "capability_id": "CAPDEF-0001",
            "contract_id": "CCON-0001", "capability_package_id": "CPKG-0001",
            "selection_id": "CSEL-000003", "instance_id": "CINST-000004",
            "adapter_identity": None, "payload_digest": "sha256:" + "0" * 64,
            "binding_digest": "sha256:" + "1" * 64,
            "artifact_digest": "sha256:" + "2" * 64,
            "staged_path": "/nowhere", "requested_at": WHEN,
            "evidence": {"actor": "op", "outcome": "execution-prepared"}}

store.write_atomic(store.path_for("capability-invocation", "CINV-000002"),
                   invocation("CINV-000002"))
store.write_atomic(store.path_for("capability-invocation", "CINV-000003"),
                   invocation("CINV-000003"))
store.write_atomic(store.path_for("capability-result", "CRES-000001"), {
    "kind": "capability-result", "schema_version": 2,
    "capability_result_id": "CRES-000001",
    "invocation_record_id": "CINV-000002", "attempt_number": 1,
    "outcome_class": "provider-error", "reason": "provider-error",
    "result_digest": None, "result_artifact_reference": None,
    "started_at": None, "ended_at": None, "recorded_at": WHEN,
    "evidence": {"actor": "op", "outcome": "provider-error"}})

def attempt(cinv):
    calls = []
    class Recorder:
        # Every method stands for a boundary the gate must sit in FRONT of:
        # helper launch, transition action, container creation, provider start,
        # handoff ownership transfer. Reaching any of them is the failure.
        def launch(self, c):
            calls.append("launch:" + c)
            raise AssertionError("the privileged helper was launched")
        def reconcile(self, c):
            calls.append("reconcile:" + c); return {}
    r = Recorder()
    try:
        execute_supervised(
            store, invocation_record_id=cinv, invocation_id=cinv,
            supervisor=ExecutionSupervisor(launcher=r, reconciler=r.reconcile),
            binding=SupervisedBinding(cinv=cinv, profile=None,
                                      profile_digest="f" * 64),
            actor="op", recorded_at=WHEN)
        return None, calls
    except BaseException as error:
        return error, calls

error, calls = attempt("CINV-000002")
assert isinstance(error, E.TerminalResultExists), type(error).__name__
assert calls == [], "boundaries reached before the refusal: %r" % (calls,)
assert "CRES-000001" in str(error), str(error)

# And a first execution is not blocked.
error3, calls3 = attempt("CINV-000003")
assert calls3 == ["launch:CINV-000003"], calls3
assert not isinstance(error3, E.TerminalResultExists), str(error3)

# CRES semantics are not reinterpreted: the existing record is untouched.
written = store.read_record("capability-result", "CRES-000001")
assert written["outcome_class"] == "provider-error", written
assert written["result_digest"] is None and written["result_artifact_reference"] is None
assert written["attempt_number"] == 1
GATEPY
) >/dev/null 2>&1; then
  pass "the INSTALLED Generation-18 library refuses a resolved CINV before any boundary, and does not block a first execution"
else
  fail "the installed Generation-18 library does not enforce the duplicate-result gate"
fi

# The predecessor library must NOT enforce it -- otherwise the case above would
# pass whether or not this generation changed anything.
if ( cd "${WORK}/shape/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import inspect, sys
sys.path.insert(0, ".")
from tools.capability import coordinator
raise SystemExit(0 if "require_no_terminal_result"
                 not in inspect.getsource(coordinator.execute_supervised) else 1)
' ); then
  pass "control: the Generation-17 fixture library does NOT gate, so the case above measures this generation"
else
  fail "control: the Generation-17 fixture already gates; the case above proves nothing"
fi

# ===========================================================================
# E. unknown bytes, on every side
# ===========================================================================

root="${WORK}/unknown-replace"; build_fixture "${root}"
target="${root}/usr/lib/kyri/python/tools/capability/execution/helpers.py"
chmod u+w "${target}"; printf '\n# not the declared baseline\n' >> "${target}"
if run_installer "${root}" --verify; then
  fail "unknown bytes at the REPLACE baseline were accepted"
else
  pass "unknown bytes at the REPLACE baseline are refused"
fi

# Every group member is a matrix row here, so there is no carryover to drift.
# What must still refuse is an unrelated carried-over object.
root="${WORK}/unknown-carryover"; build_fixture "${root}"
other="${root}/usr/lib/kyri/python/tools/capability/execution/snapshot.py"
chmod u+w "${other}"; printf '\n# drift\n' >> "${other}"
if run_installer "${root}" --verify; then
  fail "unknown bytes in an unrelated carried-over object were accepted"
else
  pass "unknown bytes in an unrelated carried-over object are refused"
fi

root="${WORK}/overlay-unknown"; build_fixture "${root}"
o="${root}/usr/lib/kyri/python/kyri_exec_transition_action.py"
chmod u+w "${o}"; printf '\n# not the accepted ceremony bytes\n' >> "${o}"
if run_installer "${root}" --verify; then
  fail "a ceremony-governed object at undeclared bytes was accepted"
else
  pass "a ceremony-governed object at undeclared bytes is still refused"
fi

# A SUPERSEDED CEREMONY STATE IS STILL DRIFT. Both helper ceremonies are
# accepted before this generation, so G11-AX's target for an object G11-BB later
# moved is no longer an accepted state -- and accepting it would be the mixed
# helper surface the ceremony exists to refuse.
root="${WORK}/overlay-superseded"; build_fixture "${root}"
if superseded="$(sed -n '/^MATRIX=(/,/^)$/p' \
    "${ROOT}/provisioning/execution/install-g11-bb-helpers.sh" | grep '^"' \
    | grep 'kyri_exec_transition_action' | tr -d '"' | cut -d'|' -f5)" \
   && [[ -n "${superseded}" ]] \
   && blob_by_digest provisioning/execution/kyri-exec-transition-action.py "${superseded}" \
        > "${WORK}/superseded.py" 2>/dev/null; then
  install -m 0444 "${WORK}/superseded.py" \
    "${root}/usr/lib/kyri/python/kyri_exec_transition_action.py"
  if run_installer "${root}" --verify; then
    fail "a superseded helper-ceremony state was accepted as current"
  else
    pass "a superseded helper-ceremony state is refused: the accepted set is the last one, not any one"
  fi
else
  fail "could not materialise the superseded helper state, so this case proves nothing"
fi

root="${WORK}/stranger"; build_fixture "${root}"
printf '# nobody governs this\n' > "${root}/usr/lib/kyri/python/tools/capability/stranger.py"
if run_installer "${root}" --verify; then
  fail "an ungoverned extra library-root object was accepted"
else
  pass "an ungoverned extra library-root object is refused"
fi

root="${WORK}/missing"; build_fixture "${root}"
rm -f "${root}/usr/lib/kyri/python/tools/capability/execution/snapshot.py"
if run_installer "${root}" --verify; then
  fail "a missing accepted object was accepted"
else
  pass "a missing accepted object is refused"
fi

# ===========================================================================
# E2. the gates that must stay shut
# ===========================================================================

root="${WORK}/gate-verify"; build_fixture "${root}"
printf 'cschott ALL=(root) NOPASSWD: /usr/libexec/kyri-exec-verify\n' \
  > "${root}/etc/sudoers.d/kyri-exec-verify"
if run_installer "${root}" --verify; then
  fail "the ceremony ran with the verification grant present"
else
  pass "the verification grant present halts the ceremony"
fi

root="${WORK}/gate-repin"; build_fixture "${root}"
chmod u+w "${root}/etc/sudoers.d/kyri-exec-launch"
printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%064d \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\n' 0 \
  > "${root}/etc/sudoers.d/kyri-exec-launch"
if run_installer "${root}" --verify; then
  fail "a grant pinning bytes the host does not carry was accepted"
else
  pass "a grant pinning bytes the host does not carry halts the ceremony"
fi

root="${WORK}/gate-stranger"; build_fixture "${root}"
printf 'cschott ALL=(root) NOPASSWD: /bin/true\n' > "${root}/etc/sudoers.d/kyri-something"
if run_installer "${root}" --verify; then
  fail "an undeclared Kyri grant was accepted"
else
  pass "an undeclared Kyri grant halts the ceremony"
fi

# ===========================================================================
# E3. the publication ORDER is CHECKED, not commented
# ===========================================================================
#
# evidence.py first is what puts the definition ahead of its importer.
# Reordering the matrix would make every `tools.capability.cli` command -- including
# `recover` -- fail to import for the length of the transaction, and nothing
# else in the ceremony would notice, so the ceremony must refuse. Driven by
# mutating a COPY of the installer, so the shipped file is untouched.

root="${WORK}/reordered"; build_fixture "${root}"
REORDERED="${WORK}/install-generation-18-reordered.sh"
python3 - "${INSTALLER}" "${REORDERED}" <<'REORDERPY'
import pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
head, rest = text.split("MATRIX=(", 1)
block, tail = rest.split("\n)", 1)
lines = block.splitlines()
rows = [i for i, l in enumerate(lines) if l.startswith('"')]
assert len(rows) == 2, rows
# Move the defining module (row one) to LAST, leaving comments in place.
first = lines[rows[0]]
for a, b in zip(rows, rows[1:]):
    lines[a] = lines[b]
lines[rows[-1]] = first
dst.write_text(head + "MATRIX=(" + "\n".join(lines) + "\n)" + tail)
REORDERPY
if [[ "$(sed -n '/^MATRIX=(/,/^)$/p' "${REORDERED}" | grep '^"' | head -1)" \
      != "$(matrix_rows | head -1)" ]]; then
  pass "control: the mutated installer really does publish evidence.py later"
else
  fail "control: the reorder did not apply, so the case below proves nothing"
fi
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${REORDERED}" --verify \
       --fixture "${root}" ) > "${WORK}/reordered.log" 2>&1; then
  fail "a matrix that publishes the defining module late was accepted"
else
  if grep -q 'would be published against a definition that does not exist yet' "${WORK}/reordered.log"; then
    pass "a late defining module halts the ceremony, naming what it would break"
  else
    fail "the reorder was refused, but not by the ordering check: $(grep -m1 '^STOP' "${WORK}/reordered.log")"
  fi
fi

# And the carryover collision check still refuses, with an entry added.
COLLIDING="${WORK}/install-generation-18-collision.sh"
# shellcheck disable=SC2016  # the carryover stores ${LIBRARY_ROOT} unexpanded
sed 's#^CARRYOVER=()$#CARRYOVER=(\
"tools/capability/evidence.py|${LIBRARY_ROOT}/tools/capability/evidence.py|'"${EVIDENCE_WANT}"'|T"\
)#' "${INSTALLER}" > "${COLLIDING}"
if [[ "$(sed -n '/^CARRYOVER=(/,/^)$/p' "${COLLIDING}" | grep -c '^"')" == "1" ]]; then
  pass "control: the mutated installer really does declare a colliding carryover"
else
  fail "control: the collision mutation did not apply"
fi
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${COLLIDING}" --verify-source \
       --fixture "${WORK}/shape" ) > "${WORK}/collision.log" 2>&1; then
  fail "an object declared as both a matrix row and a carryover was accepted"
elif grep -q 'is declared both a carryover and a matrix row' "${WORK}/collision.log"; then
  pass "an object declared as both a matrix row and a carryover is reported as such"
else
  fail "the collision was refused, but not by the carryover check: $(grep -m1 -E '^(FAIL|STOP)' "${WORK}/collision.log")"
fi

# ===========================================================================
# E4. the operator ceremony fails fast
# ===========================================================================
#
# The ceremony text is executed against a stub installer so the control flow is
# proven rather than read. No real installer runs here.

run_ceremony() {
  local root="$1" fail_mode="${2:-}"
  local script="${WORK}/ceremony.sh" stub="${WORK}/stub-installer.sh"
  : > "${WORK}/stub-invocations"
  cat > "${stub}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${WORK}/stub-invocations"
[[ "\$1" == "${fail_mode}" ]] && exit 1
exit 0
STUB
  chmod +x "${stub}"
  # `sudo` and the installer path are redirected at the fixture and the stub.
  {
    # shellcheck disable=SC2016  # emitted into the generated script, not expanded here
    printf 'sudo() { if [[ "$1" == "test" ]]; then shift; test "$@" ; else shift; "$@"; fi; }\n'
    printf 'export -f sudo\n'
    sed -e "s#^cd /opt/schott-platform\$#cd ${ROOT}#" \
        -e "s#/root/kyri-gen18-transaction#${root}/root/kyri-gen18-transaction#g" \
        -e "s#/root/kyri-gen17-library-digests.txt#${root}/root/kyri-gen17-library-digests.txt#g" \
        -e "s#/root/kyri-gen17-helper-digests.txt#${root}/root/kyri-gen17-helper-digests.txt#g" \
        -e "s#sudo bash /opt/schott-platform/provisioning/execution/install-generation-18.sh#bash ${stub}#g" \
        "${CEREMONY}"
  } > "${script}"
  ( bash "${script}" ) > "${WORK}/ceremony.log" 2>&1
}
# `grep -c` prints its count AND exits non-zero when that count is zero, so a
# `|| printf 0` fallback appends a second zero and every "ran 0 times" assertion
# compares against "00". Capture, then default.
invocations_of() {
  local n
  n="$(grep -c -- "^$1\$" "${WORK}/stub-invocations" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

if head -20 "${CEREMONY}" | grep -q '^set -Eeuo pipefail$'; then
  pass "ceremony: the operator block sets -Eeuo pipefail"
else
  fail "ceremony: the operator block does not set -Eeuo pipefail"
fi
if [[ "$(grep -n 'kyri-gen18-transaction' "${CEREMONY}" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'install-generation-18.sh' "${CEREMONY}" | head -1 | cut -d: -f1)" ]]; then
  pass "ceremony: the journal check precedes every installer invocation"
else
  fail "ceremony: the journal check does not precede the installer invocations"
fi

root="${WORK}/ceremony-clean"; build_fixture "${root}"
if run_ceremony "${root}"; then
  pass "ceremony: with every stage passing, the ceremony completes"
else
  fail "ceremony: the all-passing run failed: $(tail -2 "${WORK}/ceremony.log")"
fi
if [[ "$(tr '\n' ' ' < "${WORK}/stub-invocations")" == "--verify-source --verify --install --verify-installed " ]]; then
  pass "ceremony: the stages run in the declared order"
else
  fail "ceremony: unexpected stage order: $(tr '\n' ' ' < "${WORK}/stub-invocations")"
fi

root="${WORK}/ceremony-verify-fails"; build_fixture "${root}"
if run_ceremony "${root}" --verify; then fail "ceremony: a --verify refusal did not stop the ceremony"; fi
if [[ "$(invocations_of --install)" == "0" && "$(invocations_of --verify-installed)" == "0" ]]; then
  pass "ceremony: --verify refused -> neither --install nor --verify-installed ran"
else
  fail "ceremony: --verify refused but later stages ran"
fi

root="${WORK}/ceremony-source-fails"; build_fixture "${root}"
if run_ceremony "${root}" --verify-source; then fail "ceremony: a --verify-source refusal did not stop the ceremony"; fi
if [[ "$(invocations_of --verify)" == "0" && "$(invocations_of --install)" == "0" ]]; then
  pass "ceremony: --verify-source refused -> --verify and --install both ran 0 times"
else
  fail "ceremony: --verify-source refused but later stages ran"
fi

root="${WORK}/ceremony-journal"; build_fixture "${root}"
mkdir -p "${root}/root/kyri-gen18-transaction"
printf 'state=COMMITTING\n' > "${root}/root/kyri-gen18-transaction/journal"
journal_before="$(sha256sum "${root}/root/kyri-gen18-transaction/journal" | cut -d' ' -f1)"
if run_ceremony "${root}"; then fail "ceremony: an unexpected transaction journal did not stop the ceremony"; fi
if [[ "$(invocations_of --verify-source)" == "0" ]]; then
  pass "ceremony: an unexpected transaction journal stops the ceremony before any installer runs"
else
  fail "ceremony: the installer ran despite an unexpected transaction journal"
fi
if grep -q 'Do not delete it' "${WORK}/ceremony.log"; then
  pass "ceremony: the refusal tells the operator to preserve the transaction for inspection"
else
  fail "ceremony: the refusal did not say to preserve the transaction"
fi
if [[ "$(sha256sum "${root}/root/kyri-gen18-transaction/journal" | cut -d' ' -f1)" == "${journal_before}" ]]; then
  pass "ceremony: the unexpected transaction is left untouched"
else
  fail "ceremony: the unexpected transaction was modified"
fi

# ===========================================================================
# F. crash and recovery at every publication boundary
# ===========================================================================

# THE CROSS-SURFACE INTERRUPTION MATRIX. At every point the host must be either
# fail-closed or a complete coherent state. There must be no point where a mixed
# runtime is executable -- that is the property the whole ordering exists for.
MIXED_AND_EXECUTABLE=0

for point in stage staged prepared precommit committing publish verify postcommit evidence cleanup; do
  root="${WORK}/crash-${point}"; build_fixture "${root}"
  baseline="$(manifest "${root}/usr/lib/kyri/python")"
  run_installer "${root}" --install "KYRI_GEN18_FAIL_AT=${point}" || true

  count="$(library_count "${root}")"
  if [[ "${count}" != "${baseline_count}" ]]; then
    fail "a failure at '${point}' left ${count} objects; this generation creates and removes nothing"
    continue
  fi

  residue="$(find "${root}/usr/lib/kyri/python" \
               \( -name '*.kyri-gen18.new' -o -name '*.kyri-gen18.gen17' \) 2>/dev/null | wc -l)"
  if [[ "${point}" == "cleanup" ]]; then
    if (( residue > 0 )); then
      pass "a failure at 'cleanup' leaves exactly the artefacts cleanup removes"
    else
      fail "a failure at 'cleanup' left nothing for cleanup to remove"
    fi
  elif (( residue == 0 )); then
    pass "a failure at '${point}' leaves no transaction residue"
  else
    fail "a failure at '${point}' left ${residue} transaction artefact(s) behind"
  fi

  # Every row is at exactly one of its two declared digests, and all three agree
  # -- wholly Generation 17, or wholly Generation 18. Never between.
  at_base=0; at_target=0; unknown=0
  for pair in "evidence ${EVIDENCE_BASE} ${EVIDENCE_WANT}" \
              "coordinator ${COORDINATOR_BASE} ${COORDINATOR_WANT}"; do
    # shellcheck disable=SC2086  # deliberate split: the row is three fields
    set -- ${pair}
    observed="$(digest_at "${root}" "$1")"
    if   [[ "${observed}" == "$2" ]]; then at_base=$((at_base + 1))
    elif [[ "${observed}" == "$3" ]]; then at_target=$((at_target + 1))
    else unknown=$((unknown + 1)); fi
  done
  if (( unknown > 0 )); then
    fail "a failure at '${point}' left ${unknown} object(s) at neither generation"
  elif (( at_base == 2 )); then
    if [[ "$(manifest "${root}/usr/lib/kyri/python")" == "${baseline}" ]]; then
      pass "a failure at '${point}' recovers to the exact Generation-17 library"
    else
      fail "a failure at '${point}' rolled back the rows but altered the library"
    fi
  elif (( at_target == 2 )); then
    pass "a failure at '${point}' left both rows wholly at Generation 18"
  else
    pass "a failure at '${point}' left a partial set (${at_base} base, ${at_target} target)"
  fi

  # THE PROPERTY THAT MATTERS, AND IT IS NOT GENERATION 17's.
  #
  # Generation 17 required execution to be CLOSED unless the state was complete
  # and coherent, because its first published object shut readiness. Nothing
  # here shuts readiness, so inheriting that assertion would test a property
  # this generation does not have -- and it would pass vacuously or fail for the
  # wrong reason.
  #
  # The property this generation does have: whatever state the interruption
  # left, `tools.capability.cli` must still IMPORT. The one state that breaks it
  # is old-evidence/new-coordinator, and publication order plus reverse rollback
  # are what make it unreachable. So that is what is measured.
  if importable "${root}"; then
    pass "a failure at '${point}' leaves a library that still imports"
  else
    fail "a failure at '${point}' left a library that cannot import: the unsafe mix is reachable"
    MIXED_AND_EXECUTABLE=$((MIXED_AND_EXECUTABLE + 1))
  fi

  # And readiness is unchanged either way -- no readiness authority moved.
  verdict="$(fixture_verdict "${root}")"
  if [[ "${verdict}" == "compatible" ]]; then
    pass "a failure at '${point}' leaves helper compatibility unchanged at 'compatible'"
  else
    fail "a failure at '${point}' changed helper compatibility to '${verdict}'; no readiness authority is in this matrix"
  fi
done

if (( MIXED_AND_EXECUTABLE == 0 )); then
  pass "UNSAFE_MIX_REACHABLE=NO across every interruption point"
else
  fail "UNSAFE_MIX_REACHABLE=YES at ${MIXED_AND_EXECUTABLE} point(s)"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation-18 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation-18 installer validation passed.\n'
