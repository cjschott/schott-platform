#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-15 runtime installation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the installer touches is rebound under
# --fixture. No production runtime object is read for state and none is written;
# no sudo, no helper, no Podman, no container.
#
# WHAT GENERATION 15 IS
# =====================
# Seven objects, derived mechanically from the accepted installed Generation-14
# authority to the reviewed source at ef4f744: five REPLACE and two CREATE,
# across three coherence groups.
#
#   V  the runtime-side verification surface
#      verification.py (REPLACE) + result_content.py, contract_outcome.py (CREATE)
#   R  supervised recovery discovery
#      recovery.py + cli.py
#   H  helper declaration and refusal reporting
#      helpers.py + kyri_exec_launcher.py
#
# THE FIXTURE IS RECONSTRUCTED, NOT COPIED
# ========================================
# Copying the live runtime would make the fixture agree with production by
# construction and prove nothing about the declared baseline. It is built from
# accepted Generation-14 evidence instead:
#
#   every object from the Generation-14 authority 946be55, EXCEPT
#   verification.py, whose accepted installed bytes are 16f285e's.
#
# That exception is the defect this generation repairs, and it is why the
# baseline has to be reconstructed per object rather than taken from one commit:
# the installed Generation-14 runtime does not match its own source authority
# for that object, which is exactly the split G11-BB found.
#
# WHAT IS NOT HERE
# ================
# No privileged helper is installed, no grant is written, and the verify
# entrypoint is not authorised. Group V repairs the verification LIBRARY; the
# entrypoint that would use it stays ungranted, and this suite asserts that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-15.sh"

# HOST-ONLY. The fixture's PATH SET is the accepted Generation-14 surface, read
# from the installed runtime; only the BYTES come from git. That is what makes
# the baseline a reconstruction of what a generation actually published rather
# than of whatever the repository happens to contain -- and it means this suite
# has nothing to reconstruct against on a machine with no installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

GEN14_COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"
VERIFICATION_AT="16f285e84b58585409514d90e282782b8d77d9d1"
AX_COMMIT="7709cf0443ab11f2b84c94eefbbb60f1eb95c98c"
# Read from the installer rather than restated, so the two cannot drift.
GEN15_COMMIT="$(sed -n 's/^COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "${INSTALLER}")"
[[ -n "${GEN15_COMMIT}" ]] || { printf 'cannot read the source authority\n' >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- the accepted Generation-14 baseline, reconstructed ---------------------
# The declared privileged helper paths, read from the installed declaration.
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

build_fixture() {
  local root="$1"
  rm -rf "${root}"
  local lib="${root}/usr/lib/kyri/python"
  # Every path here is prefixed with the fixture root and none is the production
  # path it mirrors. Each line carries the marker so the exception is greppable
  # rather than hidden, which is what the guard asks for.
  mkdir -p "${lib}" "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d"
  mkdir -p "${root}/etc/kyri"                                # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority"    # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority-control"  # prod-path-reference

  local staging; staging="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN14_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The PATH SET is the accepted Generation-14 surface -- which objects that
  # generation installed, not every file the repository happens to carry. The
  # BYTES come from reviewed git objects. Taking the list from the live tree and
  # the content from git is what makes this a reconstruction rather than a copy:
  # a fixture built by copying production would agree with production by
  # construction and prove nothing about the declared baseline.
  local object
  while IFS= read -r object; do
    [[ -f "${staging}/${object}" ]] || continue
    install -D -m 0444 "${staging}/${object}" "${lib}/${object}"
  done < <( cd /usr/lib/kyri/python && find tools -type f -name '*.py' \
              ! -path '*__pycache__*' | sort )

  # Library-root modules, by the same rule: the accepted generation decides
  # WHICH, git decides what. provisioning/execution also holds entrypoints that
  # are installed to /usr/libexec rather than here, and copying those in would
  # invent a baseline no generation ever published.
  local module source
  while IFS= read -r module; do
    source="${staging}/provisioning/execution/${module%.py}"
    source="${source//_/-}.py"
    [[ -f "${source}" ]] || continue
    install -m 0444 "${source}" "${lib}/${module}"
  done < <( cd /usr/lib/kyri/python && find . -maxdepth 1 -type f -name 'kyri_exec_*.py' \
              -printf '%P\n' | sort )

  # The one object whose accepted installed bytes are not the authority's.
  ( cd "${ROOT}" && git show "${VERIFICATION_AT}:tools/capability/execution/verification.py" ) \
    > "${staging}/verification.py"
  install -m 0444 "${staging}/verification.py" \
    "${lib}/tools/capability/execution/verification.py"

  # The evidence the installer requires of its predecessor.
  # Generation-14 evidence is written BEFORE the later ceremonies are overlaid,
  # because that is what it is: a record of the Generation-14 surface, frozen and
  # immutable. Everything applied after this line postdates it deliberately.
  ( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort \
      | xargs sha256sum ) | sed "s|^\([0-9a-f]*\)  |\1  /usr/lib/kyri/python/|" \
      > "${root}/root/kyri-gen14-library-digests.txt"

  # --- the accepted production predecessor is Generation 14 PLUS what came
  # --- after it, and the host really is in that shape -----------------------
  #
  # G11-AX published four library-root objects after Generation 14: three
  # REPLACE and one CREATE. Their installed bytes intentionally differ from, or
  # are absent from, Generation-14 evidence. A verifier that compares the whole
  # library against that evidence alone reports all four as drift, which is
  # exactly what production did.
  local axrow axsrc axtgt axmode
  while IFS= read -r axrow; do
    axrow="${axrow#\"}"; axrow="${axrow%\"}"
    IFS='|' read -r axsrc axtgt axmode _ _ _ _ <<<"${axrow}"
    # The matrix stores the placeholder literally, so it must NOT expand here.
    # shellcheck disable=SC2016  # intentional: matching the literal placeholder
    local _PLACEHOLDER='${LIBRARY_ROOT}/'
    [[ "${axtgt}" == *"${_PLACEHOLDER}"* ]] || continue
    axtgt="${lib}/${axtgt##*"${_PLACEHOLDER}"}"
    ( cd "${ROOT}" && git show "${AX_COMMIT}:${axsrc}" ) > "${axtgt}.tmp" 2>/dev/null || continue
    install -m "${axmode}" "${axtgt}.tmp" "${axtgt}"
    rm -f "${axtgt}.tmp"
  done < <(sed -n '/^MATRIX=(/,/^)$/p' "${ROOT}/provisioning/execution/install-g11-ax-helpers.sh" \
             | grep '^"')

  # G11-BA installed the launch and reconcile grants. They are still installed,
  # unchanged, and the accepted deployment plan keeps them through Generation 15.
  # The verify grant stays absent.
  printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%s \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH\n' \
    "$(sha256sum /usr/libexec/kyri-exec-transition | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-launch"
  printf 'Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:%s \\\n    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE\n' \
    "$(sha256sum /usr/libexec/kyri-exec-reconcile | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-reconcile"
  chmod 0440 "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-reconcile"
  # Every declared privileged helper, carried as the host holds it -- the list
  # comes from the installed declaration, so a helper added later cannot quietly
  # fall out of the fixture. Generation 15 moves none of these; they are here so
  # the fixture can be asked the real readiness question.
  local helper
  while IFS= read -r helper; do
    [[ "${helper}" == /usr/libexec/* ]] || continue
    install -D -m 0555 "${helper}" "${root}${helper}"   # prod-path-reference
  done < <(declared_helper_paths)
  : > "${root}/root/kyri-gen14-helper-digests.txt"
  for object in "${staging}"/provisioning/execution/kyri-exec-*; do
    [[ -f "${object}" ]] || continue
    printf '%s  /usr/libexec/%s\n' "$(sha256sum "${object}" | cut -d' ' -f1)" \
      "$(basename "${object}")" >> "${root}/root/kyri-gen14-helper-digests.txt"
  done

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"  # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"  # prod-path-reference

  rm -rf "${staging}"
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

# ===========================================================================
# A. the declared shape
# ===========================================================================

root="${WORK}/shape"; build_fixture "${root}"
if [[ "$(library_count "${root}")" == "79" ]]; then
  pass "the reconstructed Generation-14 fixture holds 79 objects (78 governed + 1 helper-published)"
else
  fail "the fixture holds $(library_count "${root}") objects, expected 79"
fi

installed_verification="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/verification.py" | cut -d' ' -f1)"
if [[ "${installed_verification}" == "ed5b49ed03add16c8ba7a233d53a8c5528e5ba4d0fc23f53cdd41bb788bd2e73" ]]; then
  pass "the fixture carries the accepted stale verification.py, not the authority's"
else
  fail "the fixture's verification.py is ${installed_verification}"
fi

# ===========================================================================
# B. verify is non-mutating
# ===========================================================================

root="${WORK}/verify"; build_fixture "${root}"
before="$(manifest "${root}")"
if run_installer "${root}" --verify; then
  pass "--verify accepts the reconstructed Generation-14 baseline"
else
  fail "--verify rejected the baseline: $(tail -6 "${WORK}/last-run.log")"
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
# C. install and verify-installed
# ===========================================================================

root="${WORK}/install"; build_fixture "${root}"
libexec_before_install="$(manifest "${root}/usr/libexec")"
if run_installer "${root}" --install; then
  pass "--install completes"
else
  fail "--install failed: $(tail -12 "${WORK}/last-run.log")"
fi

if [[ "$(library_count "${root}")" == "81" ]]; then
  pass "the installed library moves 79 -> 81 objects (two CREATEs)"
else
  fail "the installed library holds $(library_count "${root}"), expected 81"
fi

if run_installer "${root}" --verify-installed; then
  pass "--verify-installed accepts the complete Generation-15 target"
else
  fail "--verify-installed rejected the target: $(tail -12 "${WORK}/last-run.log")"
fi

for object in tools/capability/execution/result_content.py \
              tools/capability/execution/contract_outcome.py; do
  if [[ -f "${root}/usr/lib/kyri/python/${object}" ]]; then
    pass "the CREATE published ${object##*/}"
  else
    fail "${object} was not created"
  fi
done

target_verification="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/verification.py" | cut -d' ' -f1)"
if [[ "${target_verification}" == "7a792aaf3c59ed0bb4bd32cb55267e6fc26dfae06f5da1b8b36efff9e1efa952" ]]; then
  pass "verification.py moved to the reviewed bytes"
else
  fail "verification.py is ${target_verification}"
fi

# The whole point of group V: the repaired library imports.
if ( cd "${root}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c \
     'from tools.capability.execution import verification, result_content, contract_outcome' \
     >/dev/null 2>&1 ); then
  pass "the installed verification surface imports as a whole"
else
  fail "the installed verification surface does not import"
fi

# ===========================================================================
# D. the verify entrypoint stays unauthorised
# ===========================================================================

if [[ ! -e "${root}/etc/sudoers.d/kyri-exec-verify" ]]; then
  pass "no verify grant was written"
else
  fail "the installation wrote a verify grant"
fi
# Not "empty" -- the production-shape fixture carries the two pinned
# entrypoints, exactly as the host does. What matters is that this generation
# left them alone.
if [[ "${libexec_before_install}" == "$(manifest "${root}/usr/libexec")" ]]; then
  pass "no /usr/libexec object changed: the privileged surface is untouched"
else
  fail "the installation changed /usr/libexec"
fi

# ===========================================================================
# E. unknown bytes, REPLACE and CREATE
# ===========================================================================

root="${WORK}/unknown-replace"; build_fixture "${root}"
target="${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py"
chmod u+w "${target}"; printf '\n# not the declared baseline\n' >> "${target}"
if run_installer "${root}" --verify; then
  fail "unknown bytes at a REPLACE baseline were accepted"
else
  pass "unknown bytes at a REPLACE baseline are refused"
fi

root="${WORK}/unknown-create"; build_fixture "${root}"
printf '# somebody else\n' > \
  "${root}/usr/lib/kyri/python/tools/capability/execution/result_content.py"
if run_installer "${root}" --verify; then
  fail "a pre-existing CREATE pathname was accepted"
else
  pass "a pre-existing CREATE pathname is refused"
fi

root="${WORK}/unknown-carryover"; build_fixture "${root}"
carry="${root}/usr/lib/kyri/python/tools/capability/execution/snapshot.py"
chmod u+w "${carry}"; printf '\n# drift\n' >> "${carry}"
if run_installer "${root}" --verify; then
  fail "unknown bytes in a carryover object were accepted"
else
  pass "unknown bytes in a carryover object are refused"
fi

# ===========================================================================
# E2. the accepted predecessor overlay, and its negative controls
# ===========================================================================
#
# Production is Generation 14 PLUS the G11-AX library-root publications PLUS the
# G11-BA grants. The first Generation-15 production attempt refused it on both
# counts. These cases hold the corrected model to exactly that shape, and hold
# the boundary that was NOT weakened to reach it.

# An AX-published object at bytes no ceremony declares is still drift.
root="${WORK}/overlay-unknown"; build_fixture "${root}"
o="${root}/usr/lib/kyri/python/kyri_exec_transition_action.py"
chmod u+w "${o}"; printf '\n# not the accepted ceremony bytes\n' >> "${o}"
if run_installer "${root}" --verify; then
  fail "an AX-governed object at undeclared bytes was accepted"
else
  pass "an AX-governed object at undeclared bytes is still refused"
fi

# A library-root object no ceremony governs at all is still drift.
root="${WORK}/overlay-stranger"; build_fixture "${root}"
printf '# nobody governs this\n' > "${root}/usr/lib/kyri/python/kyri_exec_stranger.py"
if run_installer "${root}" --verify; then
  fail "an ungoverned extra library-root object was accepted"
else
  pass "an ungoverned extra library-root object is refused"
fi

# The verify grant is still forbidden.
root="${WORK}/grant-verify"; build_fixture "${root}"
cp "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-verify"
if run_installer "${root}" --verify; then
  fail "the verification grant was accepted"
else
  pass "the verification grant is still refused"
fi

# A grant pinning bytes this host does not carry is a grant nobody reviewed.
root="${WORK}/grant-altered"; build_fixture "${root}"
sed -i 's/sha256:[0-9a-f]\{64\}/sha256:'"$(printf 'f%.0s' {1..64})"'/' \
  "${root}/etc/sudoers.d/kyri-exec-launch"
if run_installer "${root}" --verify; then
  fail "a grant pinning absent bytes was accepted"
else
  pass "a grant pinning bytes the host does not carry is refused"
fi

# An undeclared Kyri grant is an elevation nobody accounted for.
root="${WORK}/grant-extra"; build_fixture "${root}"
cp "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-something"
if run_installer "${root}" --verify; then
  fail "an undeclared Kyri grant was accepted"
else
  pass "an undeclared Kyri grant is refused"
fi

# A pinned entrypoint whose bytes moved must refuse, because the grant would
# then authorise something other than what was reviewed.
root="${WORK}/entrypoint-moved"; build_fixture "${root}"
chmod u+w "${root}/usr/libexec/kyri-exec-transition"
printf '\n# moved\n' >> "${root}/usr/libexec/kyri-exec-transition"
if run_installer "${root}" --verify; then
  fail "a moved pinned entrypoint was accepted"
else
  pass "a pinned entrypoint whose bytes moved is refused"
fi

# ===========================================================================
# E3. fail-closed first: execution shuts before anything else is observable
# ===========================================================================
#
# The launch and reconcile grants stay installed through this generation, so a
# partially published runtime must not be executable. helpers.py is the runtime
# authority that decides whether installed helper bytes are current, and this
# generation moves it to declare the CORRECTED digests. Published FIRST against
# predecessor helpers, it shuts execution on the very first rename.
#
# This section walks the transaction one publication at a time and asks the real
# readiness rule at every position, using the fixture's own helpers.py as the
# declaration and redirecting only paths.

# The blocking helpers the real rule names, one path per line.
fixture_blocking() {
  ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'BLOCKINGPY'
import importlib.util, sys
root = sys.argv[1]
lib = f"{root}/usr/lib/kyri/python"
spec = importlib.util.spec_from_file_location(
    "fx_blocking", f"{lib}/tools/capability/execution/helpers.py")
H = importlib.util.module_from_spec(spec)
sys.modules["fx_blocking"] = H
spec.loader.exec_module(H)
required = tuple(
    H.RequiredHelper(path=f"{root}{h.path}", digest=h.digest, purpose=h.purpose)
    for h in H.REQUIRED_HELPERS)
for helper in H.compatibility(required).blocking:
    print(helper.path[len(root):])
BLOCKINGPY
  )
}

# The real rule, run against a fixture library root.
fixture_verdict() {
  ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'VERDICTPY'
import importlib.util, sys
root = sys.argv[1]
lib = f"{root}/usr/lib/kyri/python"
spec = importlib.util.spec_from_file_location(
    "fx_helpers", f"{lib}/tools/capability/execution/helpers.py")
H = importlib.util.module_from_spec(spec)
sys.modules["fx_helpers"] = H
spec.loader.exec_module(H)
required = tuple(
    H.RequiredHelper(path=f"{root}{h.path}", digest=h.digest, purpose=h.purpose)
    for h in H.REQUIRED_HELPERS)
print(H.compatibility(required).verdict)
VERDICTPY
  )
}

# The declared order is a checked property of the artefact, not a convention.
first_row="$(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"' | head -1)"
if [[ "${first_row%%|*}" == '"tools/capability/execution/helpers.py' ]]; then
  pass "the readiness authority is declared first in the matrix"
else
  fail "the first matrix row is ${first_row%%|*}, not helpers.py"
fi

# The artefact refuses to run at all if the order is ever edited away. Without
# this, "helpers.py is first" would be a comment, and the window would reopen
# silently the next time somebody tidied the matrix.
reordered="${WORK}/reordered-installer.sh"
python3 - "${INSTALLER}" "${reordered}" <<'REORDERPY'
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r'^MATRIX=\(\n(.*?)^\)$', text, re.S | re.M)
rows = [r for r in block.group(1).splitlines() if r.startswith('"')]
moved = [r for r in rows if 'helpers.py' not in r] + [r for r in rows if 'helpers.py' in r]
open(sys.argv[2], 'w').write(text[:block.start(1)] + "\n".join(moved) + "\n" + text[block.end(1):])
REORDERPY
root="${WORK}/reordered"; build_fixture "${root}"
if ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 bash "${reordered}" --verify --fixture "${root}" ) \
     > "${WORK}/reordered.log" 2>&1; then
  fail "an installer with the readiness authority moved out of first place was accepted"
elif grep -q 'not tools/capability/execution/helpers.py' "${WORK}/reordered.log"; then
  pass "an installer whose matrix no longer publishes the readiness authority first refuses"
else
  fail "the reordered installer refused for the wrong reason: $(tail -1 "${WORK}/reordered.log")"
fi

root="${WORK}/order"; build_fixture "${root}"
if [[ "$(fixture_verdict "${root}")" == "compatible" ]]; then
  pass "order: before publication the host is compatible"
else
  fail "order: the predecessor fixture is not compatible"
fi

# Interrupt at each commit position and ask the rule what the host would say.
# Position 1 is the state immediately after helpers.py is published.
for position in 1 2 3 4 5 6 7; do
  # A real failure at position N rolls back (section F proves that), so this
  # asks the question mid-flight instead: publish by hand up to N using the
  # installer's own matrix, then put the real rule to the resulting host.
  root="${WORK}/partial-${position}"; build_fixture "${root}"
  staged="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN15_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staged}"
  n=0
  while IFS= read -r row; do
    row="${row#\"}"; row="${row%\"}"
    IFS='|' read -r src tgt mode _ _ _ _ <<<"${row}"
    n=$((n + 1)); (( n <= position )) || break
    # shellcheck disable=SC2016  # the placeholder must not expand
    ph='${LIBRARY_ROOT}/'
    tgt="${root}/usr/lib/kyri/python/${tgt##*"${ph}"}"
    install -D -m "${mode}" "${staged}/${src}" "${tgt}"
  done < <(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"')
  rm -rf "${staged}"
  v="$(fixture_verdict "${root}")"
  if [[ "${v}" == "incompatible" ]]; then
    pass "order: after publication #${position} the host is incompatible"
  else
    fail "order: after publication #${position} the host reports ${v}"
  fi
done

# Why the order is load-bearing rather than tidy: every OTHER Generation-15
# object is invisible to the readiness rule. Published first, it would leave the
# host reporting compatible while a Generation-15 object was already live -- the
# open window. This asserts that directly, one row at a time.
row_index=0
while IFS= read -r row; do
  row="${row#\"}"; row="${row%\"}"
  IFS='|' read -r src tgt mode _ _ _ _ <<<"${row}"
  row_index=$((row_index + 1))
  (( row_index > 1 )) || continue          # row 1 is helpers.py, proved above
  root="${WORK}/first-${row_index}"; build_fixture "${root}"
  staged="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN15_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staged}"
  # shellcheck disable=SC2016  # the placeholder must not expand
  ph='${LIBRARY_ROOT}/'
  install -D -m "${mode}" "${staged}/${src}" \
    "${root}/usr/lib/kyri/python/${tgt##*"${ph}"}"
  rm -rf "${staged}"
  if [[ "$(fixture_verdict "${root}")" == "compatible" ]]; then
    pass "order: publishing ${src##*/} first would leave execution OPEN, so it may not be first"
  else
    fail "order: ${src##*/} unexpectedly closes execution; the fail-closed-first rationale needs rechecking"
  fi
done < <(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"')

# And it stays closed once all seven have landed, because the helpers have not
# moved. Only the separate helper ceremony can reopen it.
root="${WORK}/order-complete"; build_fixture "${root}"
run_installer "${root}" --install || true
v="$(fixture_verdict "${root}")"
if [[ "${v}" == "incompatible" ]]; then
  pass "order: a complete Generation 15 with predecessor helpers stays incompatible"
else
  fail "order: the complete generation reports ${v}"
fi

# Exactly the three objects the separate helper ceremony moves, and nothing
# else. supervision_ready is the conjunction of the two identity authorities
# with this verdict, so an incompatible verdict is what makes it false; the
# count matters because a different number would mean the two ceremonies
# disagree about the delta between them.
blocking="$(fixture_blocking "${root}")"
if [[ "$(printf '%s\n' "${blocking}" | grep -c .)" == 3 ]]; then
  pass "order: exactly 3 helpers block, so supervision_ready is false until the helper ceremony runs"
else
  fail "order: $(printf '%s\n' "${blocking}" | grep -c .) helpers block, not 3"
fi
for expected in /usr/libexec/kyri-exec-worker.py \
                /usr/lib/kyri/python/kyri_exec_transition_action.py \
                /usr/lib/kyri/python/kyri_exec_quota.py; do
  if printf '%s\n' "${blocking}" | grep -qx -- "${expected}"; then
    pass "order: ${expected##*/} is named as blocking"
  else
    fail "order: ${expected} is not among the blocking helpers"
  fi
done

# ===========================================================================
# E4. the operator ceremony fails fast
# ===========================================================================
#
# The Generation-15 install attempt reached --install after --verify had already
# refused, because the block listed the stages as separate unchained commands.
# It refused again, safely -- but safety came from the installer, not from the
# ceremony. These assertions execute the real ceremony text against a stub
# installer that records every invocation, so the control flow is proved rather
# than described.

CEREMONY="${ROOT}/provisioning/execution/gen15-operator-ceremony.txt"

# Run the ceremony with the privileged commands redirected at a fixture and the
# installer redirected at a stub. Nothing else about the text is altered.
run_ceremony() {
  local root="$1" fail_at="${2:-}"
  local script="${WORK}/ceremony.sh" stub="${WORK}/stub-installer.sh"
  : > "${WORK}/stub-invocations"
  cat > "${stub}" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$1" >> "${STUB_LOG}"
[[ "$1" != "${STUB_FAIL_AT:-}" ]] || { printf 'stub refusal at %s\n' "$1" >&2; exit 1; }
STUB
  sed -e "s|^sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh|bash ${stub}|" \
      -e "s|  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh|  \&\& bash ${stub}|" \
      -e "s|^sudo test|test|" \
      -e "s|/root/|${root}/root/|g" \
      -e "s|^cd /opt/schott-platform$|cd ${ROOT}|" \
      "${CEREMONY}" > "${script}"
  STUB_LOG="${WORK}/stub-invocations" STUB_FAIL_AT="${fail_at}" \
    bash "${script}" > "${WORK}/ceremony.log" 2>&1
}

invocations_of() { grep -c -- "^${1}$" "${WORK}/stub-invocations" || true; }

# The text itself must carry the fail-fast preamble; a block without it would
# pass the stub runs by accident on a shell that happened to stop anyway.
if grep -q '^set -Eeuo pipefail$' "${CEREMONY}"; then
  pass "ceremony: the operator block sets -Eeuo pipefail"
else
  fail "ceremony: the operator block does not set -Eeuo pipefail"
fi
if [[ "$(grep -m1 -c 'kyri-gen15-transaction/journal' "${CEREMONY}")" == 1 ]] \
   && [[ "$(grep -n 'kyri-gen15-transaction/journal' "${CEREMONY}" | head -1 | cut -d: -f1)" \
         -lt "$(grep -n 'install-generation-15.sh' "${CEREMONY}" | head -1 | cut -d: -f1)" ]]; then
  pass "ceremony: the journal check precedes every installer invocation"
else
  fail "ceremony: the journal check does not precede the installer invocations"
fi

root="${WORK}/ceremony-clean"; build_fixture "${root}"
if run_ceremony "${root}"; then
  pass "ceremony: with every stage passing, the ceremony completes"
else
  fail "ceremony: the all-passing run failed: $(tail -1 "${WORK}/ceremony.log")"
fi
if [[ "$(tr '\n' ' ' < "${WORK}/stub-invocations")" \
      == "--verify-source --verify --install --verify-installed " ]]; then
  pass "ceremony: the stages run in the declared order"
else
  fail "ceremony: unexpected stage order: $(tr '\n' ' ' < "${WORK}/stub-invocations")"
fi

# The defect that reached production: --verify refused and --install ran anyway.
root="${WORK}/ceremony-verify-fails"; build_fixture "${root}"
if run_ceremony "${root}" --verify; then fail "ceremony: a --verify refusal did not stop the ceremony"; fi
if [[ "$(invocations_of --install)" == 0 ]]; then
  pass "ceremony: --verify refused -> --install invocation count is 0"
else
  fail "ceremony: --verify refused but --install ran $(invocations_of --install) time(s)"
fi
if [[ "$(invocations_of --verify-installed)" == 0 ]]; then
  pass "ceremony: --verify refused -> --verify-installed invocation count is 0"
else
  fail "ceremony: --verify refused but --verify-installed still ran"
fi

root="${WORK}/ceremony-source-fails"; build_fixture "${root}"
if run_ceremony "${root}" --verify-source; then fail "ceremony: a --verify-source refusal did not stop the ceremony"; fi
if [[ "$(invocations_of --verify)" == 0 && "$(invocations_of --install)" == 0 ]]; then
  pass "ceremony: --verify-source refused -> --verify and --install invocation counts are both 0"
else
  fail "ceremony: --verify-source refused but later stages ran"
fi

# The control that gives the three assertions above their teeth: the BB-K block
# shape -- unchained stages, no fail-fast preamble -- run against the same stub
# with the same refusal. If this did NOT reach --install, the assertions would
# be passing for some reason other than the chaining, and would not be evidence.
: > "${WORK}/stub-invocations"
STUB_LOG="${WORK}/stub-invocations" STUB_FAIL_AT="--verify" bash <<CONTROL \
  > "${WORK}/control.log" 2>&1 || true
bash "${WORK}/stub-installer.sh" --verify-source
bash "${WORK}/stub-installer.sh" --verify
bash "${WORK}/stub-installer.sh" --install
CONTROL
if [[ "$(invocations_of --install)" == 1 ]]; then
  pass "ceremony control: the superseded unchained block does reach --install after a refusal"
else
  fail "ceremony control: the superseded block did not reproduce the defect, so the fix is unproven"
fi

# An unexpected transaction stops the ceremony before any installer runs, and
# says so rather than exiting silently.
root="${WORK}/ceremony-journal"; build_fixture "${root}"
mkdir -p "${root}/root/kyri-gen15-transaction"
printf 'unexpected\n' > "${root}/root/kyri-gen15-transaction/journal"
if run_ceremony "${root}"; then fail "ceremony: an unexpected transaction journal did not stop the ceremony"; fi
if [[ "$(wc -l < "${WORK}/stub-invocations")" == 0 ]]; then
  pass "ceremony: an unexpected transaction journal stops the ceremony before any installer runs"
else
  fail "ceremony: the installer ran despite an unexpected transaction journal"
fi
if grep -q 'Do not delete it' "${WORK}/ceremony.log"; then
  pass "ceremony: the refusal tells the operator to preserve the transaction for inspection"
else
  fail "ceremony: the refusal did not say to preserve the transaction"
fi
if [[ -f "${root}/root/kyri-gen15-transaction/journal" ]]; then
  pass "ceremony: the unexpected transaction is left untouched"
else
  fail "ceremony: the unexpected transaction was removed"
fi

# ===========================================================================
# F. crash and recovery at every publication boundary
# ===========================================================================

for point in stage staged prepared precommit committing publish verify postcommit evidence cleanup; do
  root="${WORK}/crash-${point}"; build_fixture "${root}"
  baseline="$(manifest "${root}/usr/lib/kyri/python")"
  run_installer "${root}" --install "KYRI_GEN15_FAIL_AT=${point}" || true

  count="$(library_count "${root}")"
  if [[ "${count}" != "79" && "${count}" != "81" ]]; then
    fail "a failure at '${point}' left ${count} objects: neither generation"
    continue
  fi

  # Residue is acceptable only where the step that removes it is the step that
  # failed. Anywhere else it means an interrupted transaction left artefacts a
  # later run would have to reason about.
  residue="$(find "${root}/usr/lib/kyri/python" \
               \( -name '*.kyri-gen15.new' -o -name '*.kyri-gen15.gen14' \) 2>/dev/null | wc -l)"
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

  # The library root is the generation. The transaction journal and the evidence
  # files are this ceremony's own bookkeeping and are expected to move.
  if [[ "${count}" == "79" ]]; then
    if [[ "$(manifest "${root}/usr/lib/kyri/python")" == "${baseline}" ]]; then
      pass "a failure at '${point}' recovers to the exact Generation-14 library"
    else
      fail "a failure at '${point}' left the Generation-14 library altered"
    fi
  else
    # At target. Every matrix row must hold its Generation-15 bytes; whether the
    # ceremony got as far as writing evidence is a separate question, and
    # --verify-installed refusing without it is correct rather than a defect.
    incomplete=0
    while IFS='|' read -r _ target _ _ _ want _; do
      target="${target/\$\{LIBRARY_ROOT\}/${root}/usr/lib/kyri/python}"
      [[ "$(sha256sum "${target}" 2>/dev/null | cut -d' ' -f1)" == "${want}" ]] \
        || incomplete=1
    done < <(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"' | tr -d '"')
    if (( incomplete == 0 )); then
      pass "a failure at '${point}' left every matrix row at its Generation-15 bytes"
    else
      fail "a failure at '${point}' left a partially published matrix"
    fi
  fi

  # Bytes are not the whole question: what matters operationally is whether the
  # host would execute in the state the interruption left behind. Rolled back to
  # the complete predecessor, execution is open again and should be -- that is
  # what rollback means. Left at the target, it stays closed until the separate
  # helper ceremony runs. There is no interruption point that leaves it open
  # against a mixed runtime.
  verdict="$(fixture_verdict "${root}")"
  if [[ "${count}" == "79" && "${verdict}" == "compatible" ]]; then
    pass "a failure at '${point}' reopens execution only against the complete Generation-14 runtime"
  elif [[ "${count}" == "81" && "${verdict}" == "incompatible" ]]; then
    pass "a failure at '${point}' leaves execution closed at the Generation-15 target"
  else
    fail "a failure at '${point}' left ${count} objects reporting ${verdict}"
  fi
done

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation-15 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation-15 installer validation passed.\n'
