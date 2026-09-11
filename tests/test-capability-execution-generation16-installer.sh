#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-16 runtime installation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the installer touches is rebound under
# --fixture. No production runtime object is read for state and none is written;
# no sudo, no helper, no Podman, no container, no invocation.
#
# WHAT GENERATION 16 IS
# =====================
# ONE object, in one coherence group:
#
#   R  supervised recovery discovery
#      recovery.py  f44ada7f -> fdad3cec   (REPLACE)
#      cli.py       7b4fac3e -> 7b4fac3e   (CARRYOVER, not a matrix row)
#
# `_invocation_identity` preferred the OPAQUE `invocation_id` over the record's
# `invocation_record_id`, so the lifecycle-journal lookup missed on every real
# invocation and `execution_safety` reported READY having inspected nothing.
#
# WHAT THIS SUITE IS FOR, BEYOND "THE INSTALLER WORKS"
# ====================================================
# A one-row generation is where the properties a multi-row generation got for
# free stop being free, and each of those is asserted here rather than argued:
#
#   * the CARRYOVER is really preserved. cli.py is deliberately NOT a matrix
#     row, so the suite proves it is byte-and-mode identical across a full
#     install, and that `verify_unchanged_surface` -- which skips matrix targets
#     -- is the thing actually judging it.
#   * group R is coherent with one member moving, and a split is still caught.
#   * publication is atomic, and the ceremony REFUSES if a later edit adds a row
#     without supplying the fail-closed order Generation 15 needed.
#   * execution readiness is UNCHANGED across this transaction, unlike
#     Generation 15 which deliberately closed it. A generation that quietly
#     moved the helper declaration would show up here.
#
# THE FIXTURE IS RECONSTRUCTED, NOT COPIED
# ========================================
# Copying the live runtime would make the fixture agree with production by
# construction and prove nothing about the declared baseline. The PATH SET comes
# from the installed library root -- which objects a generation actually
# published -- and the BYTES come from reviewed git objects: the Generation-15
# authority for the runtime half, and each accepted helper ceremony's own matrix
# for the objects it governs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-16.sh"
CEREMONY="${ROOT}/provisioning/execution/gen16-operator-ceremony.txt"

# HOST-ONLY, for the same reason every generation suite is: the fixture's PATH
# SET is the accepted Generation-15 surface, read from the installed runtime.
# Only the BYTES come from git. That is what makes the baseline a reconstruction
# of what a generation actually published rather than of whatever the repository
# happens to contain -- and it means this suite has nothing to reconstruct
# against on a machine with no installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

# Read from the installer rather than restated, so the two cannot drift.
GEN16_COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
GEN15_COMMIT="$(sed -n 's/^GEN15_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
[[ -n "${GEN16_COMMIT}" && -n "${GEN15_COMMIT}" ]] \
  || { printf 'cannot read the source authorities from the installer\n' >&2; exit 1; }

# The declared Generation-16 digests, likewise read rather than restated.
RECOVERY_BASELINE="$(sed -n 's/^"tools\/capability\/execution\/recovery\.py|.*|\([0-9a-f]\{64\}\)|[0-9a-f]\{64\}|R"$/\1/p' "${INSTALLER}")"
RECOVERY_TARGET="$(sed -n 's/^"tools\/capability\/execution\/recovery\.py|.*|[0-9a-f]\{64\}|\([0-9a-f]\{64\}\)|R"$/\1/p' "${INSTALLER}")"
CLI_CARRYOVER="$(sed -n 's/^"tools\/capability\/cli\.py|.*|\([0-9a-f]\{64\}\)|R"$/\1/p' "${INSTALLER}")"
[[ -n "${RECOVERY_BASELINE}" && -n "${RECOVERY_TARGET}" && -n "${CLI_CARRYOVER}" ]] \
  || { printf 'cannot read the declared Generation-16 digests\n' >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- the accepted Generation-15 baseline, reconstructed ---------------------

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
  ( cd "${ROOT}" && git archive --format=tar "${GEN15_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The PATH SET is the accepted Generation-15 surface; the BYTES come from the
  # Generation-15 authority. Generation 16 CREATEs nothing, so unlike the
  # Generation-15 fixture there is no successor pathname to subtract -- which is
  # itself asserted below, because a Generation 16 that grew a CREATE would make
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
  # not at either side of a pending ceremony, which is the state Generation 15
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

  # The evidence the installer requires of its predecessor. Generation-15
  # evidence records the Generation-15 surface as that ceremony wrote it: the
  # library hashed at the moment it committed. Both helper ceremonies that
  # govern library objects had already run by then EXCEPT G11-BB, which
  # published after Generation 15 -- so those rows carry G11-BB's PREDECESSOR
  # bytes, exactly as the real file does.
  local evidence="${root}/root/kyri-gen15-library-digests.txt"
  : > "${evidence}"
  local digest bbpre
  while IFS= read -r relative; do
    digest="$(sha256sum "${lib}/${relative}" | cut -d' ' -f1)"
    if bbpre="$(bb_predecessor "${relative}")"; then digest="${bbpre}"; fi
    printf '%s  /usr/lib/kyri/python/%s\n' "${digest}" "${relative}" >> "${evidence}"
  done < <( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort )

  # G11-BA installed the launch and reconcile grants. They are still installed,
  # unchanged, and the accepted deployment plan keeps them through Generation 16.
  # The verify grant stays absent.
  printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%s \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH\n' \
    "$(sha256sum /usr/libexec/kyri-exec-transition | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-launch"
  printf 'Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:%s \\\n    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE\n' \
    "$(sha256sum /usr/libexec/kyri-exec-reconcile | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-reconcile"
  chmod 0440 "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-reconcile"

  # Every declared privileged helper, carried as the host holds it. Generation 16
  # moves none of these; they are here so the fixture can be asked the real
  # readiness question and be expected to answer `compatible` throughout.
  local helper
  while IFS= read -r helper; do
    [[ "${helper}" == /usr/libexec/* ]] || continue
    install -D -m 0555 "${helper}" "${root}${helper}"   # prod-path-reference
  done < <(declared_helper_paths)

  : > "${root}/root/kyri-gen15-helper-digests.txt"
  for object in "${staging}"/provisioning/execution/kyri-exec-*; do
    [[ -f "${object}" ]] || continue
    printf '%s  /usr/libexec/%s\n' "$(sha256sum "${object}" | cut -d' ' -f1)" \
      "$(basename "${object}")" >> "${root}/root/kyri-gen15-helper-digests.txt"
  done

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"  # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"  # prod-path-reference

  rm -rf "${staging}"
}

# The G11-BB PREDECESSOR digest for one library-root object, or nothing. That
# ceremony published AFTER Generation 15 committed, so Generation-15 evidence
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
# What the fixture's own runtime says about helper compatibility. Generation 16
# must not move it, which is the opposite of what Generation 15 required.
fixture_verdict() {
  ( cd "$1/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys
sys.path.insert(0, ".")
from tools.capability.execution import helpers
print(helpers.compatibility().verdict)
' 2>/dev/null ) || printf 'unavailable'
}

cli_state() {
  local f="$1/usr/lib/kyri/python/tools/capability/cli.py"
  printf '%s %s' "$(sha256sum "${f}" | cut -d' ' -f1)" "$(stat -c '%a' "${f}")"
}

# ===========================================================================
# A. the declared shape
# ===========================================================================

if [[ "${RECOVERY_TARGET}" != "${RECOVERY_BASELINE}" ]]; then
  pass "the declaration moves recovery.py off its Generation-15 bytes"
else
  fail "the declared baseline and target are the same digest"
fi

# The carryover is the thing a one-row generation can most easily get wrong, so
# its defining property is asserted first: it does not move.
if [[ "${CLI_CARRYOVER}" == "$(git -C "${ROOT}" cat-file blob "${GEN16_COMMIT}:tools/capability/cli.py" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "the declared cli.py carryover is the bytes the reviewed commit carries"
else
  fail "the declared cli.py carryover does not match the reviewed commit"
fi
if [[ "${CLI_CARRYOVER}" == "$(git -C "${ROOT}" cat-file blob "${GEN15_COMMIT}:tools/capability/cli.py" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "and it is byte-identical at Generation 15: the carryover really is unchanged"
else
  fail "cli.py differs between the Generation-15 and Generation-16 authorities, so it is not a carryover"
fi

# The correction itself, in the reviewed bytes rather than in a commit message.
recovery_src="$(git -C "${ROOT}" show "${GEN16_COMMIT}:tools/capability/execution/recovery.py")"
if grep -q 'return record\.get("invocation_record_id") or record\.get("invocation_id")' <<<"${recovery_src}"; then
  pass "the reviewed recovery.py prefers the canonical invocation_record_id"
else
  fail "the reviewed recovery.py does not carry the G11-BC-A correction"
fi
if grep -q 'return record\.get("invocation_id") or record\.get("invocation_record_id")' <<<"${recovery_src}"; then
  fail "the reviewed recovery.py still carries the G11-BB-Z defect"
else
  pass "the G11-BB-Z ordering is gone from the reviewed bytes"
fi

# No CREATE and no REMOVE. The fixture reconstruction above depends on this, and
# the object-count expectations depend on it too.
if [[ "$(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep -c '^"')" == "1" ]]; then
  pass "the matrix declares exactly one object"
else
  fail "the matrix declares $(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep -c '^"') objects, expected 1"
fi
if sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"' | grep -qE '\|(CREATE|REMOVE)\|'; then
  fail "the matrix declares a CREATE or REMOVE; this generation replaces one object and nothing else"
else
  pass "the matrix declares no CREATE and no REMOVE"
fi

root="${WORK}/shape"; build_fixture "${root}"
baseline_count="$(library_count "${root}")"
if [[ "${baseline_count}" == "$(find /usr/lib/kyri/python -type f -name '*.py' ! -path '*__pycache__*' | wc -l)" ]]; then
  pass "the reconstructed Generation-15 fixture holds the accepted object count (${baseline_count})"
else
  fail "the fixture holds ${baseline_count} objects; the installed surface holds a different number"
fi

installed_recovery="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py" | cut -d' ' -f1)"
if [[ "${installed_recovery}" == "${RECOVERY_BASELINE}" ]]; then
  pass "the fixture carries the declared Generation-15 recovery.py baseline"
else
  fail "the fixture's recovery.py is ${installed_recovery}, expected ${RECOVERY_BASELINE}"
fi

# ===========================================================================
# B. verify is non-mutating
# ===========================================================================

root="${WORK}/verify"; build_fixture "${root}"
before="$(manifest "${root}")"
if run_installer "${root}" --verify; then
  pass "--verify accepts the reconstructed Generation-15 baseline"
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
cli_before_install="$(cli_state "${root}")"
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

target_recovery="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py" | cut -d' ' -f1)"
if [[ "${target_recovery}" == "${RECOVERY_TARGET}" ]]; then
  pass "recovery.py moved to the reviewed Generation-16 bytes"
else
  fail "recovery.py is ${target_recovery}, expected ${RECOVERY_TARGET}"
fi

if [[ "$(stat -c '%a' "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py")" == "444" ]]; then
  pass "the published object carries the declared 0444 mode"
else
  fail "the published object has mode $(stat -c '%a' "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py")"
fi

# THE CARRYOVER. Not a matrix row, so nothing republished it -- and that is
# exactly why it has to be checked here rather than assumed.
if [[ "$(cli_state "${root}")" == "${cli_before_install}" ]]; then
  pass "the group-R carryover cli.py is byte-and-mode identical across the install"
else
  fail "cli.py changed across the install: ${cli_before_install} -> $(cli_state "${root}")"
fi
if [[ "$(cli_state "${root}")" == "${CLI_CARRYOVER} 444" ]]; then
  pass "and it sits at the declared carryover digest"
else
  fail "cli.py is $(cli_state "${root}"), expected ${CLI_CARRYOVER} 444"
fi

if run_installer "${root}" --verify-installed; then
  pass "--verify-installed accepts the complete Generation-16 target"
else
  fail "--verify-installed rejected the target: $(grep -m4 -E '^(FAIL|STOP)' "${WORK}/last-run.log" | tr '\n' ' ')"
fi

# The correction is in the INSTALLED bytes, and the installed module imports.
if grep -q 'return record\.get("invocation_record_id") or record\.get("invocation_id")' \
     "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py"; then
  pass "the installed recovery.py carries the corrected identity preference"
else
  fail "the installed recovery.py does not carry the correction"
fi
if ( cd "${root}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c \
     'from tools.capability.execution import recovery; recovery.unresolved_invocations' \
     >/dev/null 2>&1 ); then
  pass "the installed recovery surface imports as a whole"
else
  fail "the installed recovery surface does not import"
fi

# ===========================================================================
# D. what this generation must NOT have moved
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
  pass "no /usr/libexec object changed: the privileged surface is untouched"
else
  fail "the installation changed /usr/libexec"
fi

# EXECUTION READINESS IS UNCHANGED, which is the opposite of Generation 15 and
# is the whole reason this generation needs no fail-closed publication order.
verdict_after_install="$(fixture_verdict "${root}")"
if [[ "${verdict_before_install}" == "compatible" ]]; then
  pass "the Generation-15 fixture reports helper compatibility 'compatible' to begin with"
else
  fail "the fixture reports '${verdict_before_install}' before installation, so the case below proves nothing"
fi
if [[ "${verdict_after_install}" == "${verdict_before_install}" ]]; then
  pass "helper compatibility is unchanged across the transaction (${verdict_after_install})"
else
  fail "helper compatibility moved ${verdict_before_install} -> ${verdict_after_install}"
fi

# ===========================================================================
# E. unknown bytes, on every side
# ===========================================================================

root="${WORK}/unknown-replace"; build_fixture "${root}"
target="${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py"
chmod u+w "${target}"; printf '\n# not the declared baseline\n' >> "${target}"
if run_installer "${root}" --verify; then
  fail "unknown bytes at the REPLACE baseline were accepted"
else
  pass "unknown bytes at the REPLACE baseline are refused"
fi

# THE CARRYOVER IS NOT A HOLE. cli.py is not a matrix row, so if the ceremony
# only judged matrix targets, drift here would pass unnoticed. It must not.
root="${WORK}/unknown-carryover-member"; build_fixture "${root}"
carry="${root}/usr/lib/kyri/python/tools/capability/cli.py"
chmod u+w "${carry}"; printf '\n# drift in the carryover\n' >> "${carry}"
if run_installer "${root}" --verify; then
  fail "drift in the group-R carryover was accepted"
else
  pass "drift in the group-R carryover is refused, though it is not a matrix row"
fi

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
# E3. the single-object property is CHECKED, not commented
# ===========================================================================
#
# The argument that publication is atomic holds for one rename and for nothing
# else. A Generation 16 that grew a second row would inherit a justification
# that had stopped applying, so the ceremony must refuse rather than proceed.
# Driven by mutating a COPY of the installer, so the shipped file is untouched.

root="${WORK}/two-rows"; build_fixture "${root}"
TWO_ROW_INSTALLER="${WORK}/install-generation-16-two-rows.sh"
# shellcheck disable=SC2016  # the matrix stores ${LIBRARY_ROOT} unexpanded
sed '/^"tools\/capability\/execution\/recovery\.py|/a\
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1|7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1|R"' \
  "${INSTALLER}" > "${TWO_ROW_INSTALLER}"
if [[ "$(sed -n '/^MATRIX=(/,/^)$/p' "${TWO_ROW_INSTALLER}" | grep -c '^"')" == "2" ]]; then
  pass "control: the mutated installer really does declare two rows"
else
  fail "control: the two-row mutation did not apply, so the case below proves nothing"
fi
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${TWO_ROW_INSTALLER}" --verify \
       --fixture "${root}" ) > "${WORK}/two-row.log" 2>&1; then
  fail "a two-row matrix was accepted without a fail-closed publication order"
else
  if grep -q 'publication is only atomic for a single rename' "${WORK}/two-row.log"; then
    pass "a second matrix row halts the ceremony, naming the property that stopped holding"
  else
    fail "a two-row matrix was refused, but not by the atomicity check: $(grep -m1 '^STOP' "${WORK}/two-row.log")"
  fi
fi

# And the carryover may not be declared twice. An object cannot be both
# republished and preserved, and the ceremony says so rather than doing both.
#
# Driven with the row count left at one, because `require_single_object_transaction`
# runs first and would halt before the collision check was ever reached -- which
# is correct ordering and would have made this case prove nothing.
COLLIDING_INSTALLER="${WORK}/install-generation-16-collision.sh"
# shellcheck disable=SC2016  # the carryover stores ${LIBRARY_ROOT} unexpanded
sed 's#^CARRYOVER=($#&\
"tools/capability/execution/recovery.py|${LIBRARY_ROOT}/tools/capability/execution/recovery.py|fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0|R"#' \
  "${INSTALLER}" > "${COLLIDING_INSTALLER}"
if [[ "$(sed -n '/^CARRYOVER=(/,/^)$/p' "${COLLIDING_INSTALLER}" | grep -c '^"')" == "2" ]]; then
  pass "control: the mutated installer really does declare a colliding carryover"
else
  fail "control: the collision mutation did not apply, so the case below proves nothing"
fi
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${COLLIDING_INSTALLER}" --verify-source --fixture "${WORK}/shape" ) \
     > "${WORK}/collision.log" 2>&1; then
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
        -e "s#/root/kyri-gen16-transaction#${root}/root/kyri-gen16-transaction#g" \
        -e "s#/root/kyri-gen15-library-digests.txt#${root}/root/kyri-gen15-library-digests.txt#g" \
        -e "s#/root/kyri-gen15-helper-digests.txt#${root}/root/kyri-gen15-helper-digests.txt#g" \
        -e "s#sudo bash /opt/schott-platform/provisioning/execution/install-generation-16.sh#bash ${stub}#g" \
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
if [[ "$(grep -n 'kyri-gen16-transaction' "${CEREMONY}" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'install-generation-16.sh' "${CEREMONY}" | head -1 | cut -d: -f1)" ]]; then
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
mkdir -p "${root}/root/kyri-gen16-transaction"
printf 'state=COMMITTING\n' > "${root}/root/kyri-gen16-transaction/journal"
journal_before="$(sha256sum "${root}/root/kyri-gen16-transaction/journal" | cut -d' ' -f1)"
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
if [[ "$(sha256sum "${root}/root/kyri-gen16-transaction/journal" | cut -d' ' -f1)" == "${journal_before}" ]]; then
  pass "ceremony: the unexpected transaction is left untouched"
else
  fail "ceremony: the unexpected transaction was modified"
fi

# ===========================================================================
# F. crash and recovery at every publication boundary
# ===========================================================================

for point in stage staged prepared precommit committing publish verify postcommit evidence cleanup; do
  root="${WORK}/crash-${point}"; build_fixture "${root}"
  baseline="$(manifest "${root}/usr/lib/kyri/python")"
  cli_at_baseline="$(cli_state "${root}")"
  run_installer "${root}" --install "KYRI_GEN16_FAIL_AT=${point}" || true

  count="$(library_count "${root}")"
  if [[ "${count}" != "${baseline_count}" ]]; then
    fail "a failure at '${point}' left ${count} objects; this generation creates and removes nothing"
    continue
  fi

  # Residue is acceptable only where the step that removes it is the step that
  # failed. Anywhere else it means an interrupted transaction left artefacts a
  # later run would have to reason about.
  residue="$(find "${root}/usr/lib/kyri/python" \
               \( -name '*.kyri-gen16.new' -o -name '*.kyri-gen16.gen15' \) 2>/dev/null | wc -l)"
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

  # One row, so the library is at exactly one of two states and never between
  # them. That is the atomicity claim, exercised at every boundary.
  observed="$(sha256sum \
    "${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py" | cut -d' ' -f1)"
  if [[ "${observed}" == "${RECOVERY_BASELINE}" ]]; then
    if [[ "$(manifest "${root}/usr/lib/kyri/python")" == "${baseline}" ]]; then
      pass "a failure at '${point}' recovers to the exact Generation-15 library"
    else
      fail "a failure at '${point}' rolled back recovery.py but altered the library"
    fi
  elif [[ "${observed}" == "${RECOVERY_TARGET}" ]]; then
    pass "a failure at '${point}' left the single object wholly at its Generation-16 bytes"
  else
    fail "a failure at '${point}' left recovery.py at ${observed}: neither generation"
  fi

  # Whichever side it landed on, the carryover never moved and readiness never
  # moved. An interruption must not do what the successful path does not.
  if [[ "$(cli_state "${root}")" == "${cli_at_baseline}" ]]; then
    pass "a failure at '${point}' left the group-R carryover untouched"
  else
    fail "a failure at '${point}' moved cli.py"
  fi
  verdict="$(fixture_verdict "${root}")"
  if [[ "${verdict}" == "compatible" ]]; then
    pass "a failure at '${point}' leaves helper compatibility unchanged"
  else
    fail "a failure at '${point}' left helper compatibility reporting ${verdict}"
  fi
done

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation-16 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation-16 installer validation passed.\n'
