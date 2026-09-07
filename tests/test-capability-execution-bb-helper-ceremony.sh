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

  # G11-BA installed the launch and reconcile grants and the accepted deployment
  # plan keeps them through this ceremony. The fixture carried an EMPTY
  # sudoers.d, so every gate assertion here passed against a host shape that has
  # not existed since G11-BA -- which is why the stale all-grants-absent gate
  # survived to a production console. Each grant pins the entrypoint bytes this
  # fixture actually carries. The verify grant stays absent.
  printf 'Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:%s \\\n    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH\n' \
    "$(sha256sum "${root}/usr/libexec/kyri-exec-transition" | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-launch"
  printf 'Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:%s \\\n    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$\ncschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE\n' \
    "$(sha256sum "${root}/usr/libexec/kyri-exec-reconcile" | cut -d' ' -f1)" \
    > "${root}/etc/sudoers.d/kyri-exec-reconcile"
  chmod 0440 "${root}/etc/sudoers.d/kyri-exec-launch" "${root}/etc/sudoers.d/kyri-exec-reconcile"

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"                # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"                  # prod-path-reference
  rm -rf "${staging}"
}

# Publish the helper objects at a chosen generation. `which` is a matrix column
# index: 4 is the predecessor digest, 5 is the target.
# The reviewed bytes that hash to a declared digest, found in this repository's
# own history. Digest-pinned, so it cannot return anything but the declared
# predecessor -- and it does not consult the live host at all.
predecessor_blob() {
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
      # The predecessor bytes come from reviewed history, found BY DIGEST, not
      # from the live host. They used to be copied off the host, which was true
      # only until this ceremony was accepted -- after which "predecessor" and
      # "successor" became the same bytes and cases A, D and E silently inverted.
      # Same host-following class the succession work removed elsewhere.
      predecessor_blob "${source}" "${pre}" > "${target}.tmp" \
        || { printf 'FIXTURE: no reviewed bytes hash to %s for %s\n' "${pre}" "${source}" >&2
             rm -f "${target}.tmp"; return 1; }
      install -D -m "${mode}" "${target}.tmp" "${target}"
      rm -f "${target}.tmp"
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
# I2. the sudoers gate, exactly
# ===========================================================================
#
# The ceremony refused production for holding the launch and reconcile grants
# that G11-BA installed and the accepted plan keeps. The corrected model is
# precise, NOT permissive: it is not "grants may exist". Both accepted grants
# must be present, each pinning the installed entrypoint by digest AND naming it
# as its command; the verification grant must be absent; and no other kyri-*
# grant may exist.
#
# Every case below perturbs one thing about that state and requires --verify to
# refuse. The control immediately after them is what stops these passing for an
# unrelated reason.

gate_root="${WORK}/gates"; build_runtime "${gate_root}"; publish_helpers "${gate_root}" pre
run_gen15 "${gate_root}" --install || true

if run_ceremony "${gate_root}" --verify; then
  pass "gates: the accepted two-grant production state is accepted"
else
  fail "gates: the accepted state was refused: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi

gate_refuses() {                       # <case> <description> <mutator>
  local name="$1" description="$2" mutator="$3"
  local root="${WORK}/gate-${name}"
  rm -rf "${root}"; cp -a "${gate_root}" "${root}"
  chmod -R u+w "${root}/etc/sudoers.d"
  "${mutator}" "${root}"
  if run_ceremony "${root}" --verify; then
    fail "gates: ${description} was accepted"
  else
    pass "gates: ${description} is refused"
  fi
}

drop_launch()     { rm -f "$1/etc/sudoers.d/kyri-exec-launch"; }
drop_reconcile()  { rm -f "$1/etc/sudoers.d/kyri-exec-reconcile"; }
repin_launch()    { sed -i "s/sha256:[0-9a-f]\{64\}/sha256:$(printf 'a%.0s' {1..64})/" "$1/etc/sudoers.d/kyri-exec-launch"; }
repin_reconcile() { sed -i "s/sha256:[0-9a-f]\{64\}/sha256:$(printf 'b%.0s' {1..64})/" "$1/etc/sudoers.d/kyri-exec-reconcile"; }
wrong_command()   { sed -i 's|/usr/libexec/kyri-exec-transition|/usr/libexec/kyri-exec-somethingelse|' "$1/etc/sudoers.d/kyri-exec-launch"; }
add_verify()      { printf 'cschott ALL=(root) NOPASSWD: /usr/libexec/kyri-exec-verify\n' > "$1/etc/sudoers.d/kyri-exec-verify"; chmod 0440 "$1/etc/sudoers.d/kyri-exec-verify"; }
add_undeclared()  { printf 'cschott ALL=(root) NOPASSWD: /usr/libexec/kyri-exec-anything\n' > "$1/etc/sudoers.d/kyri-exec-extra"; chmod 0440 "$1/etc/sudoers.d/kyri-exec-extra"; }
move_entrypoint() {
  local f="$1/usr/libexec/kyri-exec-transition" mode
  mode="$(stat -c '%a' "${f}")"
  chmod u+w "${f}"; printf '\n# moved\n' >> "${f}"; chmod "${mode}" "${f}"
}

gate_refuses launch-missing    "a missing launch grant"                      drop_launch
gate_refuses reconcile-missing "a missing reconcile grant"                   drop_reconcile
gate_refuses launch-digest     "a launch grant pinning bytes the host does not carry"    repin_launch
gate_refuses reconcile-digest  "a reconcile grant pinning bytes the host does not carry" repin_reconcile
gate_refuses wrong-command     "a grant naming a command the host does not run"          wrong_command
gate_refuses verify-present    "the verification grant present"              add_verify
gate_refuses undeclared        "an undeclared kyri-* grant"                  add_undeclared
gate_refuses entrypoint-moved  "a pinned entrypoint whose bytes moved"       move_entrypoint

# The control. An unmutated copy must still verify, or the eight cases above
# prove nothing about what they name -- the trap an earlier draft of the
# Generation-15 controls fell into by relaxing modes tree-wide before mutating.
gate_control="${WORK}/gate-control"
rm -rf "${gate_control}"; cp -a "${gate_root}" "${gate_control}"
if run_ceremony "${gate_control}" --verify; then
  pass "gates control: an unmutated copy of the accepted state still verifies"
else
  fail "gates control: the copy alone refuses, so the cases above prove nothing: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi

# ===========================================================================
# I3. the invocation-history gate, exactly
# ===========================================================================
#
# BB-R found this check reporting `ok "no production CINV or CRES exists"` while
# scanning the Fabric and implementation-authority roots, which structurally
# never hold a CINV or a CRES. It could not fail, so it established nothing --
# and its "expects none" policy was separately stale, because CINV-000001 is
# accepted immutable UNRESOLVED history and a correctly scoped zero-history rule
# would have refused the accepted host for holding it.
#
# The corrected rule has two halves, and every case below perturbs exactly one
# thing about one of them:
#
#   OBSERVATION  the store it reads is /data/kyri/capability-runtime, through
#                the platform's own reader and validator.
#   POLICY       the reviewed history must be intact and nothing ungoverned may
#                exist -- NOT that the history is empty.
#
# The fixture host declares its own accepted history, because a fixture is a
# different host: production's pin names production's records.

STALE_AT="96653199be7084c080516bc3c789aac39ce25bb8"   # the pre-correction bytes

runtime_store_of() { printf '%s/data/kyri/capability-runtime' "$1"; }

# A governed Capability Runtime store, built from the platform's OWN record
# model rather than from a hand-copied literal -- so a record-shape change
# surfaces here instead of silently making every case below pass.
#
# <root> <invocations> <results> <declared-invocations> <declared-results>
build_invocation_store() {
  local root="$1" invocations="$2" results="$3"
  local declared_invocations="$4" declared_results="$5"
  ( cd "${ROOT}" && PYTHONDONTWRITEBYTECODE=1 python3 - \
      "$(runtime_store_of "${root}")" "${root}/root/kyri-accepted-invocation-history.txt" \
      "${invocations}" "${results}" "${declared_invocations}" "${declared_results}" <<'STOREPY'
import hashlib, pathlib, sys
sys.path.insert(0, ".")
import yaml
from tools.capability.evidence import OUTCOME_PREPARED
from tools.capability.execution.profile import ADAPTER_IDENTITY
from tools.capability.records import (INVOCATION_FIELDS, INVOCATION_KIND,
                                      INVOCATION_SCHEMA_VERSION, RESULT_FIELDS,
                                      RESULT_KIND, RESULT_SCHEMA_VERSION)

store = pathlib.Path(sys.argv[1])
declaration = pathlib.Path(sys.argv[2])
invocations, results = int(sys.argv[3]), int(sys.argv[4])
declared_invocations, declared_results = int(sys.argv[5]), int(sys.argv[6])

inv_dir = store / "capability-invocations"
res_dir = store / "capability-results"
seq_dir = store / "sequences"
for directory in (inv_dir, res_dir, seq_dir):
    directory.mkdir(parents=True, exist_ok=True)


def invocation(n, resolved):
    # An invocation that carries a terminal result must also carry the
    # execution mechanism that result came from. Without it the platform's own
    # validator reports `result-without-execution-authority` -- correctly -- and
    # every case built on this fixture would refuse for that instead of for
    # what it names.
    record = {
        "invocation_record_id": f"CINV-{n:06d}",
        "invocation_id": f"fixture-invoke-{n:06d}",
        "request_id": f"fixture-request-{n:06d}",
        "selection_id": "CSEL-000002",
        "instance_id": "CINST-000003",
        "capability_package_id": "CPKG-0001",
        "contract_id": "CCON-0001",
        "capability_id": "CAPDEF-0001",
        "operation": "execute",
        "actor": "fixture-operator",
        "payload_digest": "sha256:" + "0" * 64,
        "binding_digest": "sha256:" + "1" * 64,
        "effect_class": "computational",
        "artifact_digest": "sha256:" + "2" * 64,
        "staged_path": f"{store}/staging/fixture-{n:06d}",
        "adapter_identity": ADAPTER_IDENTITY if resolved else None,
        "requested_at": "2026-09-04 19:30:54-05:00",
        "kind": INVOCATION_KIND,
        "schema_version": INVOCATION_SCHEMA_VERSION,
        "evidence": {"actor": "fixture-operator", "outcome": OUTCOME_PREPARED,
                     "request_id": f"fixture-request-{n:06d}",
                     "selection_id": "CSEL-000002"},
    }
    assert set(record) == set(INVOCATION_FIELDS), sorted(
        set(record) ^ set(INVOCATION_FIELDS))
    return record


def result(n):
    record = {
        "capability_result_id": f"CRES-{n:06d}",
        "invocation_record_id": f"CINV-{n:06d}",
        "attempt_number": 1,
        "outcome_class": "completed",
        "reason": None,
        "result_digest": "sha256:" + "3" * 64,
        "result_artifact_reference": None,
        "started_at": "2026-09-04 19:31:00-05:00",
        "ended_at": "2026-09-04 19:31:05-05:00",
        "recorded_at": "2026-09-04 19:31:06-05:00",
        "kind": RESULT_KIND,
        "schema_version": RESULT_SCHEMA_VERSION,
        "evidence": {"actor": "fixture-operator", "outcome": "completed"},
    }
    assert set(record) == set(RESULT_FIELDS), sorted(
        set(record) ^ set(RESULT_FIELDS))
    return record


rows = []
for n in range(1, invocations + 1):
    path = inv_dir / f"CINV-{n:06d}.yaml"
    path.write_text(yaml.safe_dump(invocation(n, n <= results)), encoding="utf-8")
    path.chmod(0o600)
    if n <= declared_invocations:
        rows.append(f"CINV CINV-{n:06d} "
                    f"{hashlib.sha256(path.read_bytes()).hexdigest()}")
for n in range(1, results + 1):
    path = res_dir / f"CRES-{n:06d}.yaml"
    path.write_text(yaml.safe_dump(result(n)), encoding="utf-8")
    path.chmod(0o600)
    if n <= declared_results:
        rows.append(f"CRES CRES-{n:06d} "
                    f"{hashlib.sha256(path.read_bytes()).hexdigest()}")

(seq_dir / "capability-invocation.seq").write_text(f"{invocations}\n",
                                                   encoding="utf-8")
if results:
    (seq_dir / "capability-result.seq").write_text(f"{results}\n",
                                                   encoding="utf-8")
declaration.parent.mkdir(parents=True, exist_ok=True)
declaration.write_text("".join(f"{row}\n" for row in rows), encoding="utf-8")
STOREPY
  )
}

# The accepted host: Generation 15 installed, predecessor helpers, and exactly
# the reviewed invocation history -- one prepared invocation, no result.
history_root="${WORK}/history"
build_runtime "${history_root}"; publish_helpers "${history_root}" pre
run_gen15 "${history_root}" --install || true
build_invocation_store "${history_root}" 1 0 1 0

if run_ceremony "${history_root}" --verify; then
  pass "history: the accepted host -- one reviewed CINV, no CRES -- is accepted"
else
  fail "history: the accepted host was refused: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi

# The evidence line must name what was actually established. The pre-correction
# ceremony printed "no production CINV or CRES exists", which was false on this
# host and on production.
if grep -q 'invocation history' "${WORK}/last.log" \
   && ! grep -q 'no production CINV or CRES exists' "${WORK}/last.log"; then
  pass "history: the ceremony reports the history it verified, not an empty one"
else
  fail "history: the ceremony still claims an empty invocation history: $(grep -i 'CINV' "${WORK}/last.log" | head -2)"
fi

# The store it actually reads. A ceremony scanning the Fabric and authority
# roots for CINV/CRES cannot see any of the cases below.
if grep -q "$(runtime_store_of "${history_root}")" "${WORK}/last.log"; then
  pass "history: the ceremony names the capability-runtime store it read"
else
  fail "history: the ceremony did not name the capability-runtime store"
fi

history_refuses() {                    # <case> <description> <mutator>
  local name="$1" description="$2" mutator="$3"
  local root="${WORK}/history-${name}"
  rm -rf "${root}"; cp -a "${history_root}" "${root}"
  chmod -R u+w "$(runtime_store_of "${root}")"
  "${mutator}" "${root}"
  if run_ceremony "${root}" --verify; then
    fail "history: ${description} was accepted"
  elif grep -qEi 'invocation (history|store)|reviewed CINV-|not a governed |capability runtime store|disagrees with its own counter' \
         "${WORK}/last.log"; then
    pass "history: ${description} is refused"
  else
    fail "history: ${description} was refused for an unrelated reason: $(grep -m1 -E '^(STOP|FAIL)' "${WORK}/last.log")"
  fi
}

extra_invocation() {                   # an invocation nobody reviewed
  build_invocation_store "$1" 2 0 1 0
}
undeclared_result() {                  # a result nobody reviewed
  build_invocation_store "$1" 1 1 1 0
}
changed_invocation() {                 # the immutable record, rewritten
  local path
  path="$(runtime_store_of "$1")/capability-invocations/CINV-000001.yaml"
  printf 'actor: someone-else\n' >> "${path}"
}
missing_invocation() {                 # the reviewed record, removed
  rm -f "$(runtime_store_of "$1")/capability-invocations/CINV-000001.yaml"
}
spent_sequence() {                     # the next identity spent, no record for it
  printf '2\n' > "$(runtime_store_of "$1")/sequences/capability-invocation.seq"
}
malformed_record() {                   # a record whose meaning nobody reviewed
  local path
  path="$(runtime_store_of "$1")/capability-invocations/CINV-000002.yaml"
  printf 'invocation_record_id: CINV-000002\nkind: capability-invocation\n' > "${path}"
  printf '2\n' > "$(runtime_store_of "$1")/sequences/capability-invocation.seq"
}
write_residue() {                      # an interrupted write, left behind
  printf 'partial\n' \
    > "$(runtime_store_of "$1")/capability-invocations/.CINV-000002.tmp"
}
unexpected_object() {                  # an object no record kind accounts for
  printf 'notes\n' > "$(runtime_store_of "$1")/capability-invocations/README.txt"
}
absent_store() {                       # declared history with no store at all
  rm -rf "$(runtime_store_of "$1")"
}

history_refuses extra-cinv    "an invocation record nobody reviewed"        extra_invocation
history_refuses extra-cres    "a result record nobody reviewed"             undeclared_result
history_refuses changed-cinv  "the reviewed CINV rewritten"                 changed_invocation
history_refuses missing-cinv  "the reviewed CINV removed"                   missing_invocation
history_refuses spent-seq     "the next invocation identity spent"          spent_sequence
history_refuses malformed     "a malformed invocation record"               malformed_record
history_refuses residue       "a partial write left in the record store"    write_residue
history_refuses unexpected    "an unexpected object in the record store"    unexpected_object
history_refuses no-store      "declared history with no runtime store"      absent_store

# The control. Without it the nine cases above prove nothing about what they
# name.
history_control="${WORK}/history-control"
rm -rf "${history_control}"; cp -a "${history_root}" "${history_control}"
if run_ceremony "${history_control}" --verify; then
  pass "history control: an unmutated copy of the accepted host still verifies"
else
  fail "history control: the copy alone refuses: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi

# The freshness half belongs to the PREFLIGHT, not to the post-install
# attestation. A host whose invocation history legitimately advanced after this
# ceremony was accepted must not make an installed, accepted deployment start
# reporting FAIL -- that is the BB-L / BB-Q / BB-R staleness class, one grain
# finer. So --verify refuses an advanced history and --verify-installed does not.
advanced="${WORK}/history-advanced"
rm -rf "${advanced}"; cp -a "${history_root}" "${advanced}"
run_ceremony "${advanced}" --install || true
build_invocation_store "${advanced}" 2 2 1 0
if run_ceremony "${advanced}" --verify-installed; then
  pass "history: --verify-installed accepts a history that legitimately advanced"
else
  fail "history: --verify-installed refused an advanced history: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi
# The preflight half of the same pair. It is asserted on a host whose helper
# surface is still the predecessor, so the refusal cannot come from coherence or
# readiness -- which is what made an earlier draft of this case pass for a
# reason that had nothing to do with the invocation history.
advanced_pre="${WORK}/history-advanced-pre"
rm -rf "${advanced_pre}"; cp -a "${history_root}" "${advanced_pre}"
chmod -R u+w "$(runtime_store_of "${advanced_pre}")"
build_invocation_store "${advanced_pre}" 2 2 1 0
if run_ceremony "${advanced_pre}" --verify; then
  fail "history: --verify accepted a host that moved past the reviewed history"
elif grep -q 'moved past the reviewed one' "${WORK}/last.log"; then
  pass "history: --verify refuses a host that moved past the reviewed history"
else
  fail "history: --verify refused an advanced history for an unrelated reason: $(grep -m1 '^STOP' "${WORK}/last.log")"
fi
# ... and the reviewed record must still be intact even then.
chmod -R u+w "$(runtime_store_of "${advanced}")"
printf 'actor: someone-else\n' \
  >> "$(runtime_store_of "${advanced}")/capability-invocations/CINV-000001.yaml"
if run_ceremony "${advanced}" --verify-installed; then
  fail "history: --verify-installed accepted a rewritten reviewed record"
else
  pass "history: --verify-installed refuses a rewritten reviewed record"
fi

# THE SECOND DEFECT, PROVED AGAINST THE HISTORICAL BYTES.
#
# BB-R's ruling was that the two defects cancelled: scoped correctly, the stale
# "expects none" policy would have REFUSED the accepted host. This runs the
# pre-correction function verbatim out of ${STALE_AT} against the store it
# should always have been reading, and requires exactly that refusal -- so the
# claim is executed rather than asserted in prose.
stale_probe="${WORK}/stale-probe.sh"
{
  printf 'set -Eeuo pipefail\n'
  # shellcheck disable=SC2016  # the probe's own body, emitted verbatim
  printf 'halt() { printf "STOP: %%s\\n" "$1" >&2; exit 1; }\n'
  # shellcheck disable=SC2016  # the probe's own body, emitted verbatim
  printf 'ok() { printf "ok       %%s\\n" "$1"; }\n'
  git -C "${ROOT}" show \
    "${STALE_AT}:provisioning/execution/install-g11-bb-helpers.sh" \
    | sed -n '/^require_no_invocation_records() {$/,/^}$/p'
  printf 'require_no_invocation_records\n'
} > "${stale_probe}"
if [[ "$(grep -c 'invocation record(s) exist' "${stale_probe}")" -ne 1 ]]; then
  fail "history: the pre-correction function was not recovered from ${STALE_AT}"
elif FABRIC_ROOT="$(runtime_store_of "${history_root}")" \
     AUTHORITY_ROOT="$(runtime_store_of "${history_root}")" \
     bash "${stale_probe}" >/dev/null 2>&1; then
  fail "history: the stale zero-history policy accepted the accepted host, so BB-R's second defect is misstated"
else
  pass "history: the stale zero-history policy, scoped correctly, refuses the accepted host (BB-R defect 2)"
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

# ===========================================================================
# The operator ceremony fails fast
# ===========================================================================
#
# Held to the standard BB-M set for the Generation-15 block, and for the reason
# that block existed: an unchained list of stages reached --install after
# --verify had already refused. It refused again, safely -- but safety came from
# the installer, not from the ceremony. So the text is a governed artefact and
# this suite executes it against a stub that records every invocation.

OPERATOR_CEREMONY="${ROOT}/provisioning/execution/helper-operator-ceremony.txt"

run_operator_ceremony() {
  local root="$1" fail_at="${2:-}"
  local script="${WORK}/op-ceremony.sh" stub="${WORK}/op-stub.sh"
  : > "${WORK}/op-invocations"
  cat > "${stub}" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$1" >> "${STUB_LOG}"
[[ "$1" != "${STUB_FAIL_AT:-}" ]] || { printf 'stub refusal at %s\n' "$1" >&2; exit 1; }
STUB
  sed -e "s|^sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh|bash ${stub}|" \
      -e "s|  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh|  \&\& bash ${stub}|" \
      -e "s|^sudo test|test|" \
      -e "s|/root/|${root}/root/|g" \
      -e "s|/etc/sudoers.d|${root}/etc/sudoers.d|g" \
      -e "s|^cd /opt/schott-platform$|cd ${ROOT}|" \
      "${OPERATOR_CEREMONY}" > "${script}"
  STUB_LOG="${WORK}/op-invocations" STUB_FAIL_AT="${fail_at}" \
    bash "${script}" > "${WORK}/op-ceremony.log" 2>&1
}

op_invocations_of() { grep -c -- "^${1}$" "${WORK}/op-invocations" || true; }

# A host satisfying every precondition: Generation-15 evidence present, no
# helper transaction, verification grant absent.
build_op_host() {
  local root="$1"
  rm -rf "${root}"; mkdir -p "${root}/root" "${root}/etc/sudoers.d"
  printf 'gen15 evidence\n' > "${root}/root/kyri-gen15-library-digests.txt"
}

if grep -q '^set -Eeuo pipefail$' "${OPERATOR_CEREMONY}"; then
  pass "ceremony: the operator block sets -Eeuo pipefail"
else
  fail "ceremony: the operator block does not set -Eeuo pipefail"
fi

if [[ "$(grep -n 'kyri-g11-bb-helper-transaction/journal' "${OPERATOR_CEREMONY}" | head -1 | cut -d: -f1)" \
      -lt "$(grep -n 'install-g11-bb-helpers.sh' "${OPERATOR_CEREMONY}" | head -1 | cut -d: -f1)" ]]; then
  pass "ceremony: the journal check precedes every installer invocation"
else
  fail "ceremony: the journal check does not precede the installer invocations"
fi

op_root="${WORK}/op-clean"; build_op_host "${op_root}"
if run_operator_ceremony "${op_root}"; then
  pass "ceremony: with every stage passing, the ceremony completes"
else
  fail "ceremony: the all-passing run failed: $(tail -1 "${WORK}/op-ceremony.log")"
fi
if [[ "$(tr '\n' ' ' < "${WORK}/op-invocations")" \
      == "--verify-source --verify --install --verify-installed " ]]; then
  pass "ceremony: the stages run in the declared order"
else
  fail "ceremony: unexpected stage order: $(tr '\n' ' ' < "${WORK}/op-invocations")"
fi

op_root="${WORK}/op-verify-fails"; build_op_host "${op_root}"
if run_operator_ceremony "${op_root}" --verify; then
  fail "ceremony: a --verify refusal did not stop the ceremony"
fi
if [[ "$(op_invocations_of --install)" == 0 ]]; then
  pass "ceremony: --verify refused -> --install invocation count is 0"
else
  fail "ceremony: --verify refused but --install ran $(op_invocations_of --install) time(s)"
fi
if [[ "$(op_invocations_of --verify-installed)" == 0 ]]; then
  pass "ceremony: --verify refused -> --verify-installed invocation count is 0"
else
  fail "ceremony: --verify refused but --verify-installed still ran"
fi

op_root="${WORK}/op-source-fails"; build_op_host "${op_root}"
if run_operator_ceremony "${op_root}" --verify-source; then
  fail "ceremony: a --verify-source refusal did not stop the ceremony"
fi
if [[ "$(op_invocations_of --verify)" == 0 && "$(op_invocations_of --install)" == 0 ]]; then
  pass "ceremony: --verify-source refused -> --verify and --install counts are both 0"
else
  fail "ceremony: --verify-source refused but later stages ran"
fi

# The three preconditions, each of which must stop the ceremony before any
# installer runs at all.
op_root="${WORK}/op-transaction"; build_op_host "${op_root}"
mkdir -p "${op_root}/root/kyri-g11-bb-helper-transaction"
printf 'state=COMMITTING\n' > "${op_root}/root/kyri-g11-bb-helper-transaction/journal"
if run_operator_ceremony "${op_root}"; then
  fail "ceremony: an unexpected helper transaction did not stop the ceremony"
elif [[ "$(grep -c . "${WORK}/op-invocations")" == 0 ]]; then
  pass "ceremony: an unexpected helper transaction stops it before any installer runs"
else
  fail "ceremony: an unexpected helper transaction still reached the installer"
fi
if [[ -f "${op_root}/root/kyri-g11-bb-helper-transaction/journal" ]]; then
  pass "ceremony: the unexpected transaction is left untouched"
else
  fail "ceremony: the unexpected transaction was removed"
fi

op_root="${WORK}/op-no-gen15"; build_op_host "${op_root}"
rm -f "${op_root}/root/kyri-gen15-library-digests.txt"
if run_operator_ceremony "${op_root}"; then
  fail "ceremony: a host without Generation-15 evidence was accepted"
elif [[ "$(grep -c . "${WORK}/op-invocations")" == 0 ]]; then
  pass "ceremony: absent Generation-15 evidence stops it before any installer runs"
else
  fail "ceremony: absent Generation-15 evidence still reached the installer"
fi

op_root="${WORK}/op-verify-grant"; build_op_host "${op_root}"
printf 'x\n' > "${op_root}/etc/sudoers.d/kyri-exec-verify"
if run_operator_ceremony "${op_root}"; then
  fail "ceremony: a present verification grant was accepted"
elif [[ "$(grep -c . "${WORK}/op-invocations")" == 0 ]]; then
  pass "ceremony: a present verification grant stops it before any installer runs"
else
  fail "ceremony: a present verification grant still reached the installer"
fi

printf '\n'
if (( FAILURES > 0 )); then
  printf 'BB helper ceremony validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'BB helper ceremony validation passed.\n'
