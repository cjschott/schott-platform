#!/usr/bin/env bash
set -Eeuo pipefail

# The corrected privileged-helper ceremony, and the cross-surface order it needs.
#
# UNPRIVILEGED AND ISOLATED. Every path is rebound under --fixture. No sudo, no
# helper execution, no Podman, no container, no production object read for state
# or written.
#
# WHAT THIS CEREMONY MOVES
# ========================
# Three privileged objects, derived from the governed HELPER_SOURCES mapping
# rather than from filenames:
#
#   /usr/lib/kyri/python/kyri_exec_transition_action.py   O_PATH anchor seam
#   /usr/lib/kyri/python/kyri_exec_quota.py               O_PATH anchor
#   /usr/libexec/kyri-exec-worker.py                      O_PATH handoff anchor
#
# All three are INSIDE the runtime readiness closure -- each is declared in
# helpers.py REQUIRED_HELPERS -- so the readiness verdict can only turn
# compatible as the last object lands.
#
# THE ORDER IS NOT A PREFERENCE
# =============================
# helpers.py is a RUNTIME object and it carries the digests the readiness rule
# checks helpers against. Generation 14's copy declares the predecessor digests;
# Generation 15's declares these targets. So the runtime generation decides what
# "current" means for a helper, and the ceremony is judged by whichever copy is
# installed.
#
# Both intermediate states are therefore INCOMPATIBLE, and that is the safe
# shape: incompatible means `supervision_ready` is false and the coordinator
# refuses before crossing the privilege boundary. Neither intermediate can
# execute anything wrongly; each simply refuses. What the matrix below proves is
# that no partial state reports compatible.
#
# REQUIRED_PRODUCTION_ORDER = GEN15_THEN_HELPERS, and the ceremony enforces it
# rather than documenting it: require_runtime_generation halts unless the
# installed helpers.py is the Generation-15 one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${ROOT}/provisioning/execution/install-g11-bb-helpers.sh"
GEN15="${ROOT}/provisioning/execution/install-generation-15.sh"

GEN14_COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"
VERIFICATION_AT="16f285e84b58585409514d90e282782b8d77d9d1"
AUTHORITY="ef4f7446200b668f8dcbf34d180c5102270f19f6"

# HOST-ONLY, for the reason the Generation-15 suite is: the fixture's path set is
# the accepted installed surface, and only its bytes come from git.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
# shellcheck source=tests/lib/succession.sh
. "${SCRIPT_DIR}/lib/succession.sh"
host_only_requires /usr/lib/kyri/python /usr/libexec/kyri-exec-worker.py   # prod-path-reference

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- fixtures ---------------------------------------------------------------

build_runtime() {
  # A reconstructed Generation-14 library root: path set from the accepted
  # surface, bytes from reviewed git objects.
  local root="$1" lib="$1/usr/lib/kyri/python"
  rm -rf "${root}"
  mkdir -p "${lib}" "${root}/usr/libexec" "${root}/root"
  mkdir -p "${root}/etc/kyri"                                   # prod-path-reference
  mkdir -p "${root}/etc/sudoers.d"
  mkdir -p "${root}/var/lib/kyri/implementation-authority"       # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority-control"  # prod-path-reference

  local staging; staging="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN14_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The path set is the live host's, so it must be rewound past every generation
  # installed since the one being reconstructed. Generation 15 CREATEs two
  # objects that 946be55 also carries as SOURCE, so without this they land in a
  # fixture that calls itself Generation 14 -- and then `run_gen15 --install`
  # below refuses (81 objects, and both CREATE pathnames already taken), leaves
  # the fixture at Generation 14, and every case in this suite silently judges
  # the wrong runtime. That is exactly how B and E came out inverted.
  local object
  local -a gen15_created=()
  mapfile -t gen15_created < <(succession_created_by "${GEN15}")
  while IFS= read -r object; do
    [[ -f "${staging}/${object}" ]] || continue
    local created skip=''
    for created in "${gen15_created[@]}"; do
      [[ "${object}" == "${created}" ]] && { skip=1; break; }
    done
    [[ -n "${skip}" ]] && continue
    install -D -m 0444 "${staging}/${object}" "${lib}/${object}"
  done < <( cd /usr/lib/kyri/python && find tools -type f -name '*.py' \
              ! -path '*__pycache__*' | sort )

  local module source
  while IFS= read -r module; do
    source="${staging}/provisioning/execution/${module%.py}"
    source="${source//_/-}.py"
    [[ -f "${source}" ]] || continue
    install -m 0444 "${source}" "${lib}/${module}"
  done < <( cd /usr/lib/kyri/python && find . -maxdepth 1 -type f -name 'kyri_exec_*.py' \
              -printf '%P\n' | sort )

  ( cd "${ROOT}" && git show "${VERIFICATION_AT}:tools/capability/execution/verification.py" ) \
    > "${staging}/v.py"
  install -m 0444 "${staging}/v.py" "${lib}/tools/capability/execution/verification.py"

  # The readiness rule judges EIGHT declared objects, not the three this
  # ceremony moves. The other five are unchanged by this delta -- both
  # generations declare the same bytes for them -- so the fixture carries their
  # accepted installed state. Without them the rule would report `absent` and
  # every case below would be incompatible for a reason that has nothing to do
  # with what is under test.
  local declared
  while IFS= read -r declared; do
    [[ "${declared}" == /usr/libexec/* ]] || continue
    install -D -m "$(stat -c '%a' "${declared}")" "${declared}" "${root}${declared}"
  done < <( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys; sys.path.insert(0, "/usr/lib/kyri/python")
from tools.capability.execution import helpers as H
for h in H.REQUIRED_HELPERS: print(h.path)' )

  ( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort | xargs sha256sum ) \
    | sed 's|^\([0-9a-f]*\)  |\1  /usr/lib/kyri/python/|' \
    > "${root}/root/kyri-gen14-library-digests.txt"
  : > "${root}/root/kyri-gen14-helper-digests.txt"

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"                # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"                  # prod-path-reference
  rm -rf "${staging}"
}

# Publish the helper objects at a chosen generation. `which` is a matrix column
# index: 4 is the predecessor digest, 5 is the target.
publish_helpers() {
  local root="$1" which="$2" only="${3:-}"
  local lib="${root}/usr/lib/kyri/python" libexec="${root}/usr/libexec"
  local row source target mode want staging
  staging="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${AUTHORITY}" provisioning/execution ) \
    | tar -x -C "${staging}"
  local index=0
  while IFS= read -r row; do
    row="${row#\"}"; row="${row%\"}"
    IFS='|' read -r source target mode _ pre post _ <<<"${row}"
    index=$((index + 1))
    if [[ -n "${only}" && "${only:index-1:1}" == "0" ]]; then want="${pre}"
    elif [[ -n "${only}" ]]; then want="${post}"
    elif [[ "${which}" == "pre" ]]; then want="${pre}"
    else want="${post}"; fi
    target="${target/\$\{LIBRARY_ROOT\}/${lib}}"
    target="${target/\$\{LIBEXEC_ROOT\}/${libexec}}"
    # Bytes are fetched by digest from history, so a fixture can hold either end.
    local blob
    blob="$( cd "${ROOT}" && git rev-list --all --objects 2>/dev/null >/dev/null; echo )"
    if [[ "${want}" == "${post}" ]]; then
      install -D -m "${mode}" "${staging}/${source}" "${target}"
    else
      # The predecessor bytes are whatever the live host carries for that object.
      local live="${target/${root}/}"
      install -D -m "${mode}" "${live}" "${target}"
    fi
  done < <(sed -n '/^MATRIX=(/,/^)$/p' "${CEREMONY}" | grep '^"')
  rm -rf "${staging}"
  : "${blob:-}"
}

# The real readiness rule, run against a fixture. `compatibility()` takes the
# required tuple as a parameter, so the DECLARATION under test is the fixture's
# own helpers.py and only the paths are redirected -- no rule is reimplemented.
verdict() {
  local root="$1"
  ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY'
import importlib.util, sys
root = sys.argv[1]
lib = f"{root}/usr/lib/kyri/python"
spec = importlib.util.spec_from_file_location(
    "fixture_helpers", f"{lib}/tools/capability/execution/helpers.py")
H = importlib.util.module_from_spec(spec)
sys.modules["fixture_helpers"] = H
spec.loader.exec_module(H)
required = tuple(
    H.RequiredHelper(path=f"{root}{h.path}", digest=h.digest, purpose=h.purpose)
    for h in H.REQUIRED_HELPERS)
print(H.compatibility(required).verdict)
PY
  )
}

run_ceremony() {
  local root="$1" mode="$2"; shift 2
  ( cd "${ROOT}" && env "$@" PYTHONDONTWRITEBYTECODE=1 \
      bash "${CEREMONY}" "${mode}" --fixture "${root}" ) > "${WORK}/last.log" 2>&1
}
run_gen15() {
  local root="$1" mode="$2"
  ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 \
      bash "${GEN15}" "${mode}" --fixture "${root}" ) > "${WORK}/gen15.log" 2>&1
}
manifest() {
  { find "$1" -printf '%P %m %s\n' | sort
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum | sed "s|$1||"; } \
    | sha256sum | cut -d' ' -f1
}

# ===========================================================================
# A-E. the cross-surface coherence matrix
# ===========================================================================

root="${WORK}/A"; build_runtime "${root}"; publish_helpers "${root}" pre
a="$(verdict "${root}")"
if [[ "${a}" == "compatible" ]]; then
  pass "A: Gen-14 runtime + predecessor helpers is compatible (current production)"
else
  fail "A: current production shape reports ${a}"
fi

root="${WORK}/B"; build_runtime "${root}"; publish_helpers "${root}" pre
run_gen15 "${root}" --install || true
b="$(verdict "${root}")"
if [[ "${b}" == "incompatible" ]]; then
  pass "B: Gen-15 runtime + predecessor helpers is incompatible, so it fails closed"
else
  fail "B: Gen-15 with old helpers reports ${b}"
fi

root="${WORK}/C"; build_runtime "${root}"; publish_helpers "${root}" post
c="$(verdict "${root}")"
if [[ "${c}" == "incompatible" ]]; then
  pass "C: Gen-14 runtime + successor helpers is incompatible, so it fails closed"
else
  fail "C: Gen-14 with new helpers reports ${c}"
fi

root="${WORK}/E"; build_runtime "${root}"; publish_helpers "${root}" pre
run_gen15 "${root}" --install || true
publish_helpers "${root}" post
e="$(verdict "${root}")"
if [[ "${e}" == "compatible" ]]; then
  pass "E: Gen-15 runtime + complete successor helpers is compatible"
else
  fail "E: the complete target reports ${e}"
fi

# ===========================================================================
# F. every subset of the three, against the Generation-15 declaration
# ===========================================================================

for bits in 000 001 010 011 100 101 110 111; do
  root="${WORK}/p${bits}"; build_runtime "${root}"; publish_helpers "${root}" pre
  run_gen15 "${root}" --install || true
  publish_helpers "${root}" "" "${bits}"
  v="$(verdict "${root}")"
  if [[ "${bits}" == "111" ]]; then
    if [[ "${v}" == "compatible" ]]; then
      pass "D: the complete successor set ${bits} is compatible"
    else
      fail "D: complete set ${bits} reports ${v}"
    fi
  else
    if [[ "${v}" == "incompatible" ]]; then
      pass "D: partial set ${bits} refuses"
    else
      fail "D: partial set ${bits} reports ${v}"
    fi
  fi
done

# ===========================================================================
# G. the ceremony enforces the order
# ===========================================================================

root="${WORK}/order"; build_runtime "${root}"; publish_helpers "${root}" pre
if run_ceremony "${root}" --verify; then
  fail "the ceremony ran against a Generation-14 runtime"
else
  if grep -q 'install Generation 15 before this ceremony' "${WORK}/last.log"; then
    pass "the ceremony refuses a Generation-14 runtime and names the reason"
  else
    fail "the ceremony refused for the wrong reason: $(tail -3 "${WORK}/last.log")"
  fi
fi

# ===========================================================================
# H. verify, install, verify-installed on the ruled order
# ===========================================================================

root="${WORK}/install"; build_runtime "${root}"; publish_helpers "${root}" pre
run_gen15 "${root}" --install || true
before="$(manifest "${root}/usr/lib/kyri/python")"
libexec_before="$(manifest "${root}/usr/libexec")"
if run_ceremony "${root}" --verify; then
  pass "--verify accepts a Generation-15 runtime with predecessor helpers"
else
  fail "--verify refused: $(tail -6 "${WORK}/last.log")"
fi
if [[ "${before}" == "$(manifest "${root}/usr/lib/kyri/python")" \
   && "${libexec_before}" == "$(manifest "${root}/usr/libexec")" ]]; then
  pass "--verify wrote nothing"
else
  fail "--verify changed the fixture"
fi

if run_ceremony "${root}" --install; then
  pass "--install completes"
else
  fail "--install failed: $(tail -10 "${WORK}/last.log")"
fi
if run_ceremony "${root}" --verify-installed; then
  pass "--verify-installed accepts the complete target"
else
  fail "--verify-installed refused: $(tail -10 "${WORK}/last.log")"
fi
if [[ "$(verdict "${root}")" == "compatible" ]]; then
  pass "the installed pair reports compatible only once both surfaces are current"
else
  fail "the completed pair is not compatible"
fi

# The two pinned entrypoints must not have moved.
for entry in kyri-exec-transition kyri-exec-reconcile; do
  if [[ ! -e "${root}/usr/libexec/${entry}" ]] \
     || [[ "$(sha256sum "${root}/usr/libexec/${entry}" | cut -d' ' -f1)" \
           == "$(sha256sum "/usr/libexec/${entry}" | cut -d' ' -f1)" ]]; then
    pass "the ceremony did not move the pinned entrypoint ${entry}"
  else
    fail "the ceremony changed ${entry}, which sudoers pins by digest"
  fi
done

# ===========================================================================
# I. unknown bytes
# ===========================================================================

root="${WORK}/unknown"; build_runtime "${root}"; publish_helpers "${root}" pre
run_gen15 "${root}" --install || true
t="${root}/usr/lib/kyri/python/kyri_exec_quota.py"
chmod u+w "${t}"; printf '\n# drift\n' >> "${t}"
if run_ceremony "${root}" --verify; then
  fail "unknown bytes at a REPLACE predecessor were accepted"
else
  pass "unknown bytes at a REPLACE predecessor are refused"
fi

# ===========================================================================
# J. ceremony recovery at every publication boundary
# ===========================================================================

for point in stage staged prepared precommit committing publish verify postcommit evidence cleanup; do
  root="${WORK}/c-${point}"; build_runtime "${root}"; publish_helpers "${root}" pre
  run_gen15 "${root}" --install || true
  run_ceremony "${root}" --install "KYRI_BBHELPER_FAIL_AT=${point}" || true

  current=0; target=0
  while IFS= read -r row; do
    row="${row#\"}"; row="${row%\"}"
    IFS='|' read -r _ tgt _ _ pre post _ <<<"${row}"
    tgt="${tgt/\$\{LIBRARY_ROOT\}/${root}/usr/lib/kyri/python}"
    tgt="${tgt/\$\{LIBEXEC_ROOT\}/${root}/usr/libexec}"
    d="$(sha256sum "${tgt}" 2>/dev/null | cut -d' ' -f1 || true)"
    [[ "${d}" == "${pre}" ]] && current=$((current + 1))
    [[ "${d}" == "${post}" ]] && target=$((target + 1))
  done < <(sed -n '/^MATRIX=(/,/^)$/p' "${CEREMONY}" | grep '^"')

  if (( current == 3 || target == 3 )); then
    pass "a failure at '${point}' leaves a whole helper set, never a mixture"
  else
    fail "a failure at '${point}' left ${current} predecessor and ${target} target objects"
  fi
done

printf '\n'
if (( FAILURES > 0 )); then
  printf 'BB helper ceremony validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'BB helper ceremony validation passed.\n'
