#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-17 runtime installation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the installer touches is rebound under
# --fixture. No production runtime object is read for state and none is written;
# no sudo, no helper, no Podman, no container, no invocation.
#
# WHAT GENERATION 17 IS
# =====================
# THREE objects, in TWO coherence groups, no CREATE and no carryover:
#
#   H  tools/capability/execution/helpers.py      REPLACE, published FIRST
#      provisioning/execution/kyri-exec-launcher.py  REPLACE
#   A  provisioning/execution/kyri-exec-podman.py    REPLACE
#
# helpers.py moves to declare the corrected privileged action module; the other
# two state the working directory of every process they create.
#
# WHAT THIS SUITE IS FOR, BEYOND "THE INSTALLER WORKS"
# ====================================================
#   * THE ORDERING IS THE SAFETY PROPERTY, AND IT IS CHECKED. helpers.py is the
#     rule deciding whether installed helper bytes are current. Published FIRST
#     it turns compatibility `incompatible` before either other object becomes
#     observable; published last, execution stays open while the runtime changes
#     underneath it. A reordered matrix must be refused.
#   * THIS GENERATION CLOSES EXECUTION, deliberately -- the opposite of
#     Generation 16, which had to leave readiness untouched. A fixture reporting
#     `compatible` afterwards would mean the declaration never moved.
#   * TWO GROUPS MOVE WHOLLY, which Generation 16 could not exercise with one.
#
# THE FIXTURE IS RECONSTRUCTED, NOT COPIED
# ========================================
# The PATH SET comes from the installed library root -- which objects a
# generation actually published -- and the BYTES from reviewed git objects: the
# Generation-16 authority for the runtime half, and each accepted helper
# ceremony's own matrix for the objects it governs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-17.sh"
CEREMONY="${ROOT}/provisioning/execution/gen17-operator-ceremony.txt"

# HOST-ONLY, for the same reason every generation suite is: the fixture's PATH
# SET is the accepted Generation-16 surface, read from the installed runtime.
# Only the BYTES come from git. That is what makes the baseline a reconstruction
# of what a generation actually published rather than of whatever the repository
# happens to contain -- and it means this suite has nothing to reconstruct
# against on a machine with no installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

# Read from the installer rather than restated, so the two cannot drift.
GEN17_COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
GEN16_COMMIT="$(sed -n 's/^GEN16_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
[[ -n "${GEN17_COMMIT}" && -n "${GEN16_COMMIT}" ]] \
  || { printf 'cannot read the source authorities from the installer\n' >&2; exit 1; }

# The declared Generation-17 rows, read rather than restated.
matrix_rows() { sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"'; }
row_for()   { matrix_rows | grep -F "\"$1|" | head -1; }
row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

HELPERS_ROW="$(row_for 'tools/capability/execution/helpers.py')"
LAUNCHER_ROW="$(row_for 'provisioning/execution/kyri-exec-launcher.py')"
PODMAN_ROW="$(row_for 'provisioning/execution/kyri-exec-podman.py')"
[[ -n "${HELPERS_ROW}" && -n "${LAUNCHER_ROW}" && -n "${PODMAN_ROW}" ]] \
  || { printf 'cannot read the declared Generation-17 rows\n' >&2; exit 1; }

HELPERS_BASE="$(row_field "${HELPERS_ROW}" 5)";  HELPERS_WANT="$(row_field "${HELPERS_ROW}" 6)"
LAUNCHER_BASE="$(row_field "${LAUNCHER_ROW}" 5)"; LAUNCHER_WANT="$(row_field "${LAUNCHER_ROW}" 6)"
PODMAN_BASE="$(row_field "${PODMAN_ROW}" 5)";    PODMAN_WANT="$(row_field "${PODMAN_ROW}" 6)"

# Installed-path helpers, so assertions read the same way for all three.
installed_of() {
  case "$1" in
    helpers)  printf 'usr/lib/kyri/python/tools/capability/execution/helpers.py' ;;
    launcher) printf 'usr/lib/kyri/python/kyri_exec_launcher.py' ;;
    podman)   printf 'usr/lib/kyri/python/kyri_exec_podman.py' ;;
  esac
}
digest_at() { sha256sum "$1/$(installed_of "$2")" | cut -d' ' -f1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- the accepted Generation-16 baseline, reconstructed ---------------------

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
  ( cd "${ROOT}" && git archive --format=tar "${GEN16_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The PATH SET is the accepted Generation-16 surface; the BYTES come from the
  # Generation-16 authority. Generation 17 CREATEs nothing, so unlike the
  # Generation-16 fixture there is no successor pathname to subtract -- which is
  # itself asserted below, because a Generation 17 that grew a CREATE would make
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
  # not at either side of a pending ceremony, which is the state Generation 16
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

  # The evidence the installer requires of its predecessor. Generation-16
  # evidence records the Generation-16 surface as that ceremony wrote it: the
  # library hashed at the moment it committed. Both helper ceremonies that
  # govern library objects had already run by then EXCEPT G11-BB, which
  # published after Generation 16 -- so those rows carry G11-BB's PREDECESSOR
  # bytes, exactly as the real file does.
  local evidence="${root}/root/kyri-gen16-library-digests.txt"
  : > "${evidence}"
  local digest bbpre
  while IFS= read -r relative; do
    digest="$(sha256sum "${lib}/${relative}" | cut -d' ' -f1)"
    if bbpre="$(bb_predecessor "${relative}")"; then digest="${bbpre}"; fi
    printf '%s  /usr/lib/kyri/python/%s\n' "${digest}" "${relative}" >> "${evidence}"
  done < <( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort )

  # G11-BA installed the launch and reconcile grants. They are still installed,
  # unchanged, and the accepted deployment plan keeps them through Generation 17.
  # The verify grant stays absent.
  printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%s \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH\n' \
    "$(sha256sum /usr/libexec/kyri-exec-transition | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-launch"
  printf 'Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:%s \\\n    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE\n' \
    "$(sha256sum /usr/libexec/kyri-exec-reconcile | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-reconcile"
  chmod 0440 "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-reconcile"

  # Every declared privileged helper, carried as the host holds it. Generation 17
  # moves none of these; they are here so the fixture can be asked the real
  # readiness question and be expected to answer `compatible` throughout.
  local helper
  while IFS= read -r helper; do
    [[ "${helper}" == /usr/libexec/* ]] || continue
    install -D -m 0555 "${helper}" "${root}${helper}"   # prod-path-reference
  done < <(declared_helper_paths)

  : > "${root}/root/kyri-gen16-helper-digests.txt"
  for object in "${staging}"/provisioning/execution/kyri-exec-*; do
    [[ -f "${object}" ]] || continue
    printf '%s  /usr/libexec/%s\n' "$(sha256sum "${object}" | cut -d' ' -f1)" \
      "$(basename "${object}")" >> "${root}/root/kyri-gen16-helper-digests.txt"
  done

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"  # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"  # prod-path-reference

  rm -rf "${staging}"
}

# The G11-BB PREDECESSOR digest for one library-root object, or nothing. That
# ceremony published AFTER Generation 16 committed, so Generation-16 evidence
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
# What the fixture's own runtime says about helper compatibility. Generation 17
# must not move it, which is the opposite of what Generation 16 required.
fixture_verdict() {
  ( cd "$1/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
sys.path.insert(0, ".")
from tools.capability.execution import helpers
print(helpers.compatibility().verdict)
' 2>/dev/null ) || printf 'unavailable'
}

# ===========================================================================
# A. the declared shape
# ===========================================================================

for pair in "helpers ${HELPERS_BASE} ${HELPERS_WANT}" \
            "launcher ${LAUNCHER_BASE} ${LAUNCHER_WANT}" \
            "podman ${PODMAN_BASE} ${PODMAN_WANT}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$2" != "$3" ]]; then
    pass "the declaration moves $1 off its Generation-16 bytes"
  else
    fail "the declared baseline and target for $1 are the same digest"
  fi
done

# Three rows, no CREATE, no REMOVE. The object-count expectations depend on it.
declared_rows="$(matrix_rows | wc -l)"
if [[ "${declared_rows}" == "3" ]]; then
  pass "the matrix declares exactly three objects"
else
  fail "the matrix declares ${declared_rows} objects, expected 3"
fi
if matrix_rows | grep -qE '\|(CREATE|REMOVE)\|'; then
  fail "the matrix declares a CREATE or REMOVE; this generation replaces three objects and nothing else"
else
  pass "the matrix declares no CREATE and no REMOVE"
fi

# TWO groups, and each moves WHOLLY. A group with a member left behind is the
# split require_group_coherence exists to catch.
groups="$(matrix_rows | rev | cut -d'|' -f1 | rev | tr -d '"' | sort -u | tr '\n' ' ')"
if [[ "${groups}" == "A H " ]]; then
  pass "the matrix declares exactly the two groups A and H"
else
  fail "the matrix declares groups '${groups}', expected 'A H '"
fi
if [[ "$(row_field "${HELPERS_ROW}" 7)" == 'H"' || "$(row_field "${HELPERS_ROW}" 7)" == 'H' ]]; then
  pass "the readiness authority is in group H"
else
  fail "helpers.py is in group $(row_field "${HELPERS_ROW}" 7), not H"
fi

# THE ORDERING. helpers.py must be row one: it is what closes execution.
if [[ "$(matrix_rows | head -1)" == "${HELPERS_ROW}" ]]; then
  pass "helpers.py is the first published row, so execution closes first"
else
  fail "the first published row is not helpers.py"
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

# The corrections, in the reviewed bytes rather than in a commit message.
helpers_src="$(git -C "${ROOT}" show "${GEN17_COMMIT}:tools/capability/execution/helpers.py")"
action_now="$(git -C "${ROOT}" cat-file blob \
  "${GEN17_COMMIT}:provisioning/execution/kyri-exec-transition-action.py" \
  | sha256sum | cut -d' ' -f1)"
if grep -q "${action_now}" <<<"${helpers_src}"; then
  pass "the reviewed declaration names the corrected privileged action module"
else
  fail "the reviewed helpers.py does not declare the corrected action module"
fi
for source in provisioning/execution/kyri-exec-podman.py \
              provisioning/execution/kyri-exec-launcher.py; do
  body="$(git -C "${ROOT}" show "${GEN17_COMMIT}:${source}")"
  creations="$(grep -cE 'subprocess\.(run|Popen)\(' <<<"${body}")"
  stated="$(grep -c 'cwd=' <<<"${body}")"
  if (( creations > 0 && stated >= creations )); then
    pass "${source##*/} states cwd at all ${creations} process creation(s)"
  else
    fail "${source##*/} creates ${creations} process(es) and states cwd ${stated} time(s)"
  fi
done

root="${WORK}/shape"; build_fixture "${root}"
baseline_count="$(library_count "${root}")"
if [[ "${baseline_count}" == "$(find /usr/lib/kyri/python -type f -name '*.py' ! -path '*__pycache__*' | wc -l)" ]]; then
  pass "the reconstructed Generation-16 fixture holds the accepted object count (${baseline_count})"
else
  fail "the fixture holds ${baseline_count} objects; the installed surface holds a different number"
fi
for pair in "helpers ${HELPERS_BASE}" "launcher ${LAUNCHER_BASE}" "podman ${PODMAN_BASE}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$(digest_at "${root}" "$1")" == "$2" ]]; then
    pass "the fixture carries the declared Generation-16 baseline for $1"
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
  pass "--verify accepts the reconstructed Generation-16 baseline"
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

for pair in "helpers ${HELPERS_WANT}" "launcher ${LAUNCHER_WANT}" "podman ${PODMAN_WANT}"; do
  # shellcheck disable=SC2086  # deliberate split: the row is three fields
  set -- ${pair}
  if [[ "$(digest_at "${root}" "$1")" == "$2" ]]; then
    pass "$1 moved to the reviewed Generation-17 bytes"
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
  pass "--verify-installed accepts the complete Generation-17 target"
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

# EXECUTION READINESS CLOSES, and that is the point of this generation. The
# declaration now names an action module the host does not carry, so the runtime
# refuses to supervise through it until the helper ceremony runs.
verdict_after_install="$(fixture_verdict "${root}")"
if [[ "${verdict_before_install}" == "compatible" ]]; then
  pass "the Generation-16 fixture reports 'compatible' to begin with"
else
  fail "the fixture reports '${verdict_before_install}' before installation, so the case below proves nothing"
fi
if [[ "${verdict_after_install}" == "incompatible" ]]; then
  pass "helper compatibility CLOSES to incompatible, as the deployment matrix requires"
else
  fail "helper compatibility is '${verdict_after_install}' after installation, expected incompatible"
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
# helpers.py first is what closes execution before anything else is observable.
# Reordering the matrix would silently reopen that window and nothing else in
# the ceremony would notice, so the ceremony must refuse. Driven by mutating a
# COPY of the installer, so the shipped file is untouched.

root="${WORK}/reordered"; build_fixture "${root}"
REORDERED="${WORK}/install-generation-17-reordered.sh"
python3 - "${INSTALLER}" "${REORDERED}" <<'REORDERPY'
import pathlib, sys
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = src.read_text()
head, rest = text.split("MATRIX=(", 1)
block, tail = rest.split("\n)", 1)
lines = block.splitlines()
rows = [i for i, l in enumerate(lines) if l.startswith('"')]
assert len(rows) == 3, rows
# Move the readiness authority (row one) to LAST, leaving comments in place.
first = lines[rows[0]]
for a, b in zip(rows, rows[1:]):
    lines[a] = lines[b]
lines[rows[-1]] = first
dst.write_text(head + "MATRIX=(" + "\n".join(lines) + "\n)" + tail)
REORDERPY
if [[ "$(sed -n '/^MATRIX=(/,/^)$/p' "${REORDERED}" | grep '^"' | head -1)" \
      != "$(matrix_rows | head -1)" ]]; then
  pass "control: the mutated installer really does publish helpers.py later"
else
  fail "control: the reorder did not apply, so the case below proves nothing"
fi
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${REORDERED}" --verify \
       --fixture "${root}" ) > "${WORK}/reordered.log" 2>&1; then
  fail "a matrix that publishes the readiness authority late was accepted"
else
  if grep -q 'would leave execution open' "${WORK}/reordered.log"; then
    pass "a late readiness authority halts the ceremony, naming what it would reopen"
  else
    fail "the reorder was refused, but not by the ordering check: $(grep -m1 '^STOP' "${WORK}/reordered.log")"
  fi
fi

# And the carryover collision check still refuses, with an entry added.
COLLIDING="${WORK}/install-generation-17-collision.sh"
# shellcheck disable=SC2016  # the carryover stores ${LIBRARY_ROOT} unexpanded
sed 's#^CARRYOVER=()$#CARRYOVER=(\
"tools/capability/execution/helpers.py|${LIBRARY_ROOT}/tools/capability/execution/helpers.py|'"${HELPERS_WANT}"'|H"\
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
        -e "s#/root/kyri-gen17-transaction#${root}/root/kyri-gen17-transaction#g" \
        -e "s#/root/kyri-gen16-library-digests.txt#${root}/root/kyri-gen16-library-digests.txt#g" \
        -e "s#/root/kyri-gen16-helper-digests.txt#${root}/root/kyri-gen16-helper-digests.txt#g" \
        -e "s#sudo bash /opt/schott-platform/provisioning/execution/install-generation-17.sh#bash ${stub}#g" \
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
if [[ "$(grep -n 'kyri-gen17-transaction' "${CEREMONY}" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'install-generation-17.sh' "${CEREMONY}" | head -1 | cut -d: -f1)" ]]; then
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
mkdir -p "${root}/root/kyri-gen17-transaction"
printf 'state=COMMITTING\n' > "${root}/root/kyri-gen17-transaction/journal"
journal_before="$(sha256sum "${root}/root/kyri-gen17-transaction/journal" | cut -d' ' -f1)"
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
if [[ "$(sha256sum "${root}/root/kyri-gen17-transaction/journal" | cut -d' ' -f1)" == "${journal_before}" ]]; then
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
  run_installer "${root}" --install "KYRI_GEN17_FAIL_AT=${point}" || true

  count="$(library_count "${root}")"
  if [[ "${count}" != "${baseline_count}" ]]; then
    fail "a failure at '${point}' left ${count} objects; this generation creates and removes nothing"
    continue
  fi

  residue="$(find "${root}/usr/lib/kyri/python" \
               \( -name '*.kyri-gen17.new' -o -name '*.kyri-gen17.gen16' \) 2>/dev/null | wc -l)"
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
  # -- wholly Generation 16, or wholly Generation 17. Never between.
  at_base=0; at_target=0; unknown=0
  for pair in "helpers ${HELPERS_BASE} ${HELPERS_WANT}" \
              "launcher ${LAUNCHER_BASE} ${LAUNCHER_WANT}" \
              "podman ${PODMAN_BASE} ${PODMAN_WANT}"; do
    # shellcheck disable=SC2086  # deliberate split: the row is three fields
    set -- ${pair}
    observed="$(digest_at "${root}" "$1")"
    if   [[ "${observed}" == "$2" ]]; then at_base=$((at_base + 1))
    elif [[ "${observed}" == "$3" ]]; then at_target=$((at_target + 1))
    else unknown=$((unknown + 1)); fi
  done
  if (( unknown > 0 )); then
    fail "a failure at '${point}' left ${unknown} object(s) at neither generation"
  elif (( at_base == 3 )); then
    if [[ "$(manifest "${root}/usr/lib/kyri/python")" == "${baseline}" ]]; then
      pass "a failure at '${point}' recovers to the exact Generation-16 library"
    else
      fail "a failure at '${point}' rolled back the rows but altered the library"
    fi
  elif (( at_target == 3 )); then
    pass "a failure at '${point}' left all three rows wholly at Generation 17"
  else
    pass "a failure at '${point}' left a partial set (${at_base} base, ${at_target} target)"
  fi

  # THE PROPERTY THAT MATTERS. Whatever state the interruption left, execution
  # must be closed unless the state is complete and coherent.
  verdict="$(fixture_verdict "${root}")"
  helpers_moved=0
  [[ "$(digest_at "${root}" helpers)" == "${HELPERS_WANT}" ]] && helpers_moved=1
  coherent=0
  (( at_base == 3 || at_target == 3 )) && coherent=1
  if [[ "${verdict}" == "incompatible" ]]; then
    pass "a failure at '${point}' leaves execution CLOSED"
  elif (( coherent == 1 && helpers_moved == 0 )); then
    # Wholly Generation 16: the predecessor is a complete coherent state and is
    # correctly executable. That is what rollback means.
    pass "a failure at '${point}' rolled back to the complete Generation-16 runtime, which is executable and coherent"
  else
    fail "a failure at '${point}' left execution OPEN against a mixed runtime (${verdict})"
    MIXED_AND_EXECUTABLE=$((MIXED_AND_EXECUTABLE + 1))
  fi
done

if (( MIXED_AND_EXECUTABLE == 0 )); then
  pass "MIXED_RUNTIME_EXECUTABLE=NO across every interruption point"
else
  fail "MIXED_RUNTIME_EXECUTABLE=YES at ${MIXED_AND_EXECUTABLE} point(s)"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation-17 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation-17 installer validation passed.\n'
