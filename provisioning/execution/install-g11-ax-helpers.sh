#!/usr/bin/env bash
set -Eeuo pipefail

# The coherent privileged helper ceremony: ten objects, one transaction.
#
# NO PARTIAL HELPER DEPLOYMENT. The whole accepted helper set moves, or none of
# it does. That is the invariant this ceremony exists for, and it is the one
# G11-AI proved the cost of: a host carrying half of one commit, with the
# verification surface byte-exact while the transition modules from the same
# commit were not, and the consequence was live.
#
# WHAT RUNS BEFORE THIS
# =====================
# Generation 14. G11-AX drove the partial-deployment matrix and found the
# Generation-13 readiness rule accepting mixed states it should have refused, so
# the rule was hardened and installed FIRST, on its own, as a runtime generation.
# This ceremony therefore runs against a rule that was already installed and
# already verified -- it does not install the rule it is judged by. Every
# behavioural check below is driven through the INSTALLED Generation-14 bytes.
#
# TWO CLOSURES, AND THEY ARE NOT THE SAME
# =======================================
# RUNTIME READINESS CLOSURE is what `helpers.compatibility()` judges: the eight
# objects a supervised execution reaches. Seven of the ten are in it.
#
# HELPER CEREMONY COHERENCE CLOSURE is all ten. The three verification objects
# are outside runtime readiness -- `PERMITTED_HELPERS` in the launcher is exactly
# the transition and reconcile entrypoints, so supervision cannot reach them --
# but `kyri-exec-verify` loads `kyri_exec_transition_action`, so replacing that
# module while leaving the verify entrypoint stale would hand it a newer action
# layer than it was reviewed against. That is a deployment split even though it
# is not a readiness one, which is why this ceremony moves ten and not seven.
#
# PUBLICATION ORDER IS A SAFETY PROPERTY
# ======================================
# The three objects OUTSIDE the readiness closure publish first. Compatibility
# depends only on the seven inside it, so ordering this way means the verdict can
# only become `compatible` as the LAST of the ten publishes. No transient state
# is ever runtime-ready while the ceremony is incoherent -- by construction,
# rather than because sudoers happens to be closed.
#
# WHAT THIS CEREMONY DOES NOT TOUCH
# =================================
# No sudoers. No identity authority. No Fabric, Trust or implementation
# authority. No CINV, no CRES, no invocation. No Generation-14 runtime object.
#
# That last one needs saying precisely, because four of the ten targets live
# UNDER the runtime's own directory. `/usr/lib/kyri/python` holds the 78
# Generation-14 runtime objects and, beside them, the flattened privileged
# helper modules -- which belong to this ceremony. One of the ten is a CREATE
# into that directory, so the file count there legitimately goes from 78 to 79
# while every runtime object stays byte-identical. `require_runtime_generation`
# states the expectation that way rather than as a flat count, and the
# before/after fingerprint excludes this ceremony's own targets so that "a
# runtime object changed" means what it says.
#
# Modes:
#   --verify-source     the reviewed commit only; reads no installed path
#   --verify            production preconditions; mutates nothing
#   --install           the transaction
#   --verify-installed  what is installed, against the reviewed commit
#   --recover           resume or dispose of an interrupted transaction

# The reviewed authority carrying all ten target byte sets.
COMMIT="7709cf0443ab11f2b84c94eefbbb60f1eb95c98c"

# The runtime generation whose readiness rule judges this deployment. This
# ceremony refuses to run against anything else: the rule that decides whether
# the result is coherent must be the hardened one.
RUNTIME_COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"
RUNTIME_HELPERS_SHA256="74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874"
EXPECTED_RUNTIME_OBJECTS=78

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# A namespace of this ceremony's own. It must never collide with a runtime
# generation's journal: a helper ceremony and a runtime generation can be
# interrupted independently, and a shared transaction root would let one
# recovery dispose of the other's state.
TRANSACTION_ROOT="/root/kyri-g11-ax-helper-transaction"
HELPER_EVIDENCE="/root/kyri-g11-ax-helper-digests.txt"

SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
FABRIC_ROOT="/var/lib/kyri/fabric"
TRUST_ROOT="/var/lib/kyri/trust"

COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"
COORDINATOR_IDENTITY_SHA256="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
EXECUTION_IDENTITY_SHA256="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"

# Nothing this ceremony runs may leave bytecode in the tree it inspects. The
# Generation-14 verifier learned this the hard way: the readiness report imports
# from the library root, and on production it does that as root.
export PYTHONDONTWRITEBYTECODE=1

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-source|--verify|--install|--verify-installed|--recover)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] \
        || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify}"

if [[ -n "${FIXTURE}" ]]; then
  LIBRARY_ROOT="${FIXTURE}${LIBRARY_ROOT}"
  LIBEXEC_ROOT="${FIXTURE}${LIBEXEC_ROOT}"
  TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"
  HELPER_EVIDENCE="${FIXTURE}${HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  RECONCILE_SUDOERS="${FIXTURE}${RECONCILE_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  FABRIC_ROOT="${FIXTURE}${FABRIC_ROOT}"
  TRUST_ROOT="${FIXTURE}${TRUST_ROOT}"
  COORDINATOR_IDENTITY="${FIXTURE}${COORDINATOR_IDENTITY}"
  EXECUTION_IDENTITY="${FIXTURE}${EXECUTION_IDENTITY}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-axhelper.new"
BACKUP_SUFFIX=".kyri-axhelper.pre"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
PREPARING=0

# --- the ten objects, pinned both ways ---------------------------------------
#
# source | target | mode | operation | predecessor-sha256 | target-sha256 | closure
#
# The CLOSURE column is what makes publication order checkable rather than
# argued. `OUTSIDE` objects are not judged by the runtime readiness rule and are
# published first; `INSIDE` objects are, and are published last, so the verdict
# can only flip as the final object lands.
MATRIX=(
# --- OUTSIDE the runtime readiness closure: published first --------------------
"provisioning/execution/kyri-exec-verify.py|${LIBRARY_ROOT}/kyri_exec_verify.py|0444|REPLACE|3d70707d19c34fcc225775d7c1afd9a0f70e0615ca377f765e299730cc99853b|f49c29571a4e1f8724a7826d14f58b8b45af7662e11155318f5e40fbe33be51f|OUTSIDE"
"provisioning/execution/kyri-exec-verify-entrypoint.py|${LIBEXEC_ROOT}/kyri-exec-verify|0555|REPLACE|fad96924adbb7ec28d4c1170f104102ca656b5c04da2f129df5d77561ea6541b|1c87788c655922121ca352f27fc7508553e437480562a6f2edac4c52e68e81a0|OUTSIDE"
"provisioning/execution/kyri-exec-verify-worker.py|${LIBEXEC_ROOT}/kyri-exec-verify-worker.py|0444|REPLACE|5a614ff73c0dd06e0a1c7441e247a6fc046eeeb059a0f08aff8335d9cc71678d|c747c6d0c306b852bb990a7ede6a9b05e84fea34c3e0ea930ff2385b2a745774|OUTSIDE"
# --- INSIDE the runtime readiness closure: published last ----------------------
"provisioning/execution/kyri-exec-transition.py|${LIBRARY_ROOT}/kyri_exec_transition.py|0444|REPLACE|6488044bc82428658ee8eecc00c0bc3f123f16f1f4ff10e1b47e730ca47e81b4|de264c6490e08f6b7dc5f0bcddd15ffdde50278c183161fba04bf4cf1440f5a6|INSIDE"
"provisioning/execution/kyri-exec-transition-action.py|${LIBRARY_ROOT}/kyri_exec_transition_action.py|0444|REPLACE|bd32af5de4f3331d6fd107a7680e9725be9334eb5d4496839ab7cfea6ed238bd|7703231318f7a872f80abc0b033c2462c24ec63bd8669773d6643634af1d296a|INSIDE"
"provisioning/execution/kyri-exec-reconcile.py|${LIBRARY_ROOT}/kyri_exec_reconcile.py|0444|CREATE|ABSENT|29175d5a71759336cc869007c83f0c13cb093023ea4bd77344b4f62cd4275a46|INSIDE"
"provisioning/execution/kyri-exec-transition-entrypoint.py|${LIBEXEC_ROOT}/kyri-exec-transition|0555|REPLACE|bd31bcbf63423a9e9e418a28c974233ecb73d0d67f4b54837f8bbed2b8d5c932|0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1|INSIDE"
"provisioning/execution/kyri-exec-worker.py|${LIBEXEC_ROOT}/kyri-exec-worker.py|0444|REPLACE|64260190330b9d797937ef5be37c7e705ade90968a184e2c9e0d13a3e323956b|6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd|INSIDE"
"provisioning/execution/kyri-exec-reconcile-entrypoint.py|${LIBEXEC_ROOT}/kyri-exec-reconcile|0555|CREATE|ABSENT|2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77|INSIDE"
"provisioning/execution/kyri-exec-reconcile-worker.py|${LIBEXEC_ROOT}/kyri-exec-reconcile-worker.py|0444|CREATE|ABSENT|b0e3c047f689ad5d1e4ef2979f771ca4acdbc80cf8109df8a7cf59a790eb8d2a|INSIDE"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
matrix_count() { printf '%s' "${#MATRIX[@]}"; }
matrix_count_of() {
  local wanted="$1" row n=0
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 3)" == "${wanted}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}
matrix_count_in_closure() {
  local wanted="$1" row n=0
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 6)" == "${wanted}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}
plural() { [[ "$1" == "1" ]] && printf '%s' "$2" || printf '%s' "$3"; }

is_target() {
  local candidate="$1" row
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 1)" == "${candidate}" ]] && return 0
  done
  return 1
}

injected_at() {
  [[ -n "${FIXTURE}" && "${KYRI_AXHELPER_FAIL_AT:-}" == "$1" ]]
}

# An absent file is an empty digest, not a pipeline failure. Without the `|| true`
# an assignment from this under `set -o pipefail` ends the script through errexit,
# silently, before the check about to refuse can say why.
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || true; }

git_as_owner() {
  if [[ "$(id -un)" == "${REPO_OWNER}" ]]; then
    git -C "${REPOSITORY}" "$@"
  else
    runuser -u "${REPO_OWNER}" -- git -C "${REPOSITORY}" "$@"
  fi
}

sync_path() { python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
try:
    fd = os.open(path, os.O_RDONLY | (os.O_DIRECTORY if os.path.isdir(path) else 0))
except OSError:
    sys.exit(0)
try:
    os.fsync(fd)
finally:
    os.close(fd)
parent = os.path.dirname(os.path.abspath(path))
try:
    handle = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
except OSError:
    sys.exit(0)
try:
    os.fsync(handle)
finally:
    os.close(handle)
PY
}

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

unwind_preparation() {
  local row target removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && removed=$((removed + 1))
    rm -f "${target}${PREPARED_SUFFIX}"
    if [[ -f "${target}${BACKUP_SUFFIX}" ]]; then
      if [[ "$(digest_of "${target}")" == "$(digest_of "${target}${BACKUP_SUFFIX}")" ]]; then
        rm -f "${target}${BACKUP_SUFFIX}"
      fi
    fi
  done
  if [[ -f "${JOURNAL}" && "$(journal_state)" == "PREPARING" ]]; then
    rm -f "${JOURNAL}" "${JOURNAL}.writing"
    rmdir "${TRANSACTION_ROOT}" 2>/dev/null || true
  fi
  printf 'unwound  preparation: %d staged object(s) removed; the helper surface is unchanged\n' \
    "${removed}" >&2
}

cleanup_on_exit() {
  local status=$?
  (( PREPARING == 1 )) && unwind_preparation
  return "${status}"
}
trap cleanup_on_exit EXIT

# --- journal ---------------------------------------------------------------
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'ceremony=g11-ax-helpers\n'
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'runtime_commit=%s\n' "${RUNTIME_COMMIT}"
    printf 'state=%s\n' "${state}"
    local row index=0
    for row in "${MATRIX[@]}"; do
      index=$((index + 1))
      printf 'target%d=%s|%s|%s|%s|%s\n' "${index}" \
        "$(field "${row}" 1)" "$(field "${row}" 3)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)" "$(field "${row}" 6)"
    done
    local key
    for key in "${!PROGRESS[@]}"; do
      printf 'progress:%s=%s\n' "${key}" "${PROGRESS[${key}]}"
    done
  } > "${temporary}"
  sync_path "${temporary}"
  mv -f "${temporary}" "${JOURNAL}"
  sync_path "${JOURNAL}"
}

journal_state() {
  [[ -f "${JOURNAL}" ]] || { printf 'NONE'; return; }
  sed -n 's/^state=//p' "${JOURNAL}" | tail -1
}

journal_transaction() {
  [[ -f "${JOURNAL}" ]] || return 0
  sed -n 's/^transaction=//p' "${JOURNAL}" | tail -1
}

# The runtime generations' journals, which this ceremony must never touch or be
# confused with. Asserted rather than assumed: a shared namespace would let one
# recovery dispose of the other's transaction.
require_namespace_isolation() {
  local generation other
  for generation in gen12 gen13 gen14; do
    other="${FIXTURE}/root/kyri-${generation}-transaction"
    [[ "${TRANSACTION_ROOT}" != "${other}" ]] \
      || halt "this ceremony shares a transaction root with ${generation}"
  done
  [[ "${TRANSACTION_ROOT}" == *"g11-ax-helper"* ]] \
    || halt "the helper transaction root is not in this ceremony's namespace"
  ok "the transaction namespace is this ceremony's own and collides with no runtime generation"
}

# --- classification --------------------------------------------------------
classify() {
  local target="$1" baseline="$2" wanted="$3" observed
  if [[ "${baseline}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'BASELINE'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      [[ "${observed}" == "${wanted}" ]] && { printf 'TARGET'; return; }
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${wanted}" ]];   then printf 'TARGET'
  elif [[ "${observed}" == "${baseline}" ]]; then printf 'BASELINE'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  local row target state
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    state="$(classify "${target}" "$(field "${row}" 4)" "$(field "${row}" 5)")"
    case "${state}" in
      TARGET)   TARGET_COUNT=$((TARGET_COUNT + 1)) ;;
      BASELINE) BASELINE_COUNT=$((BASELINE_COUNT + 1)) ;;
      *)        UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# CEREMONY COHERENCE: all ten, or none. Distinct from runtime readiness, which
# judges eight objects and does not care about the verification surface.
report_ceremony_coherence() {
  classify_all
  local total="${#MATRIX[@]}"
  if (( TARGET_COUNT == total )); then
    ok "ceremony coherence: COMPLETE (${TARGET_COUNT}/${total} at target)"
    return 0
  fi
  if (( BASELINE_COUNT == total )); then
    ok "ceremony coherence: UNSTARTED (${BASELINE_COUNT}/${total} at predecessor)"
    return 0
  fi
  bad "ceremony coherence: INCOMPLETE (${TARGET_COUNT} target, ${BASELINE_COUNT} predecessor, ${UNKNOWN_COUNT} unknown of ${total})"
  return 1
}

# --- the installed runtime rule --------------------------------------------
#
# Every behavioural verdict below comes from the INSTALLED Generation-14 bytes.
# This ceremony does not carry its own copy of the rule it is judged by.
runtime_verdict() {
  python3 - "${LIBRARY_ROOT}" "${FIXTURE:-/}" <<'VERDICTPY'
import dataclasses, pathlib, sys
library, prefix = sys.argv[1], sys.argv[2]
sys.path = [p for p in sys.path if p not in ('', '.', '/opt/schott-platform')]
sys.path.insert(0, library)
try:
    from tools.capability.execution import helpers
except ImportError as error:
    print(f"UNAVAILABLE 0 {error}")
    raise SystemExit(1)
resolved = pathlib.Path(helpers.__file__).resolve()
if not str(resolved).startswith(str(pathlib.Path(library).resolve())):
    print(f"RESOLVED-OUTSIDE 0 {resolved}")
    raise SystemExit(1)
required = helpers.REQUIRED_HELPERS
if prefix not in ('', '/'):
    required = tuple(
        dataclasses.replace(h, path=str(pathlib.Path(prefix) / h.path.lstrip('/')))
        for h in required)
verdict = helpers.compatibility(required)
print(f"{verdict.verdict} {len(required)} "
      f"{','.join(h.path + ':' + h.state for h in verdict.blocking) or '-'}")
VERDICTPY
}

# Reports to the operator AND leaves the verdict in a global. Deliberately not
# returned on stdout: a function that prints prose and a value on the same
# channel gets its prose captured by every caller that wants the value, which is
# exactly what happened the first time this was written.
RUNTIME_READINESS=""

report_runtime_readiness() {
  local line verdict count blocking
  line="$(runtime_verdict)" || halt "the installed runtime readiness rule could not be read"
  verdict="${line%% *}"; line="${line#* }"
  count="${line%% *}"; blocking="${line#* }"
  note "installed readiness rule declares ${count} required object(s)"
  note "runtime readiness: ${verdict}"
  if [[ "${blocking}" != "-" ]]; then
    local entry
    for entry in ${blocking//,/ }; do
      note "  blocking ${entry}"
    done
  fi
  RUNTIME_READINESS="${verdict}"
}

# THE LIBRARY ROOT HOLDS TWO KINDS OF OBJECT.
#
# `/usr/lib/kyri/python` carries the 78 Generation-14 runtime objects AND the
# flattened privileged helper modules, which belong to this ceremony and not to
# any runtime generation. One of the ten is a CREATE into that directory
# (`kyri_exec_reconcile.py`), so the file count there legitimately becomes 79
# once this ceremony completes.
#
# A flat count would therefore be right before the ceremony and wrong after it.
# What is actually invariant is the 78 runtime objects, so the expectation is
# stated as that plus however many of this ceremony's own library-root CREATE
# targets are currently published.
require_runtime_generation() {
  local observed count expected row target created=0
  observed="$(digest_of "${LIBRARY_ROOT}/tools/capability/execution/helpers.py")"
  [[ "${observed}" == "${RUNTIME_HELPERS_SHA256}" ]] \
    || halt "the installed readiness rule is ${observed:-absent}, not the Generation-14 ${RUNTIME_HELPERS_SHA256}: install Generation 14 before this ceremony"

  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ "$(field "${row}" 3)" == "CREATE" && "${target}" == "${LIBRARY_ROOT}/"* ]] || continue
    [[ -f "${target}" ]] && created=$((created + 1))
  done
  expected=$((EXPECTED_RUNTIME_OBJECTS + created))
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' -not -path '*__pycache__*' | wc -l)"
  [[ "${count}" -eq "${expected}" ]] \
    || halt "the library root holds ${count} objects, expected ${EXPECTED_RUNTIME_OBJECTS} runtime objects plus ${created} published helper module(s)"
  ok "the installed runtime is Generation 14 (${EXPECTED_RUNTIME_OBJECTS} runtime objects, ${created} helper module(s) published; the hardened readiness rule)"
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)" \
    || halt "the repository at ${REPOSITORY} is not readable as ${REPO_OWNER}"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed helper authority ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed helper authority ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${COMMIT}" "${RUNTIME_COMMIT}" 2>/dev/null \
    || halt "the helper authority is not an ancestor of the runtime authority it will be judged by"
  [[ "$(git_as_owner rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]] \
    || halt "this is not the ${BRANCH} branch"
  residue="$(git_as_owner status --porcelain --untracked-files=all)"
  if [[ -n "${residue}" ]]; then
    if [[ -n "${FIXTURE}" ]]; then
      note "the working tree is not clean; permitted in fixture mode only"
    else
      halt "the working tree is not clean; a ceremony runs from reviewed bytes only"
    fi
  fi
  ok "repository at ${BRANCH}, reviewed helper authority ${COMMIT} present and an ancestor of HEAD"
}

require_source_digests() {
  local row source wanted blob drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; wanted="$(field "${row}" 5)"
    if ! git_as_owner cat-file -e "${COMMIT}:${source}" 2>/dev/null; then
      bad "${source} is not present at the reviewed commit ${COMMIT}"
      drift=$((drift + 1)); continue
    fi
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${wanted}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${wanted}"; drift=$((drift + 1)); }
  done
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned helper surface"
  local n; n="$(matrix_count)"
  ok "${n} helper source $(plural "${n}" object objects) match the reviewed commit ${COMMIT}"
}

# The predecessor digests are declared, so a host in an unreviewed state is
# refused rather than repaired. Derived against the live surface, not asserted.
require_predecessor_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target}: neither the declared predecessor nor the target"
    done
    halt "a helper target is in an unruled state and requires operator disposition"
  fi
  ok "all $(matrix_count) helper targets are in a declared state (${BASELINE_COUNT} predecessor, ${TARGET_COUNT} target)"
}

require_no_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && { bad "residue at ${target}${PREPARED_SUFFIX}"; extra=$((extra + 1)); }
    [[ -e "${target}${BACKUP_SUFFIX}" ]] && { bad "residue at ${target}${BACKUP_SUFFIX}"; extra=$((extra + 1)); }
  done
  (( extra == 0 )) || halt "transaction residue exists; resolve it before installing"
  ok "no transaction residue at any of the $(matrix_count) target pathnames"
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: the launch grant is installed"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: the verification grant is installed"
  [[ ! -e "${RECONCILE_SUDOERS}" ]] || halt "${RECONCILE_SUDOERS} exists: the reconcile grant is installed"
  ok "no sudoers grant exists: this ceremony installs helpers, not authority to run them"
}

require_identity_authorities() {
  local observed
  observed="$(digest_of "${COORDINATOR_IDENTITY}")"
  [[ "${observed}" == "${COORDINATOR_IDENTITY_SHA256}" ]] \
    || halt "the coordinator identity authority is ${observed:-absent}, expected ${COORDINATOR_IDENTITY_SHA256}"
  observed="$(digest_of "${EXECUTION_IDENTITY}")"
  [[ "${observed}" == "${EXECUTION_IDENTITY_SHA256}" ]] \
    || halt "the execution identity authority is ${observed:-absent}, expected ${EXECUTION_IDENTITY_SHA256}"
  ok "both deployment identity authorities are the accepted G11-AW bytes"
}

require_root_authority_unmounted() {
  mount 2>/dev/null | grep -qiE 'root-authority' \
    && halt "a Root Authority mount is present; this ceremony runs against an unmounted authority"
  ok "no Root Authority mount is present"
}

require_no_invocation_records() {
  local root count=0
  for root in "${FABRIC_ROOT}" "${AUTHORITY_ROOT}"; do
    [[ -d "${root}" ]] || continue
    count=$((count + $(find "${root}" -maxdepth 4 \( -name 'CINV-*' -o -name 'CRES-*' \) 2>/dev/null | wc -l)))
  done
  (( count == 0 )) || halt "${count} invocation record(s) exist; this ceremony expects none"
  ok "no production CINV or CRES exists"
}

# The runtime, MINUS this ceremony's own targets. Four of the ten flattened
# helper modules live under the library root, so a fingerprint of everything
# there would report "a runtime object changed" every single time -- which is
# true and useless. What must not change is everything else.
runtime_fingerprint() {
  local row target file digests=''
  # The library-root pathnames this ceremony is allowed to change.
  local -a mine=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ "${target}" == "${LIBRARY_ROOT}/"* ]] && mine+=("${target}")
  done
  while IFS= read -r file; do
    local skip=0 own
    for own in "${mine[@]}"; do
      [[ "${file}" == "${own}" ]] && { skip=1; break; }
    done
    (( skip == 1 )) && continue
    digests+="$(digest_of "${file}") "
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' -not -path '*__pycache__*' | sort)
  printf '%s' "${digests}" | sha256sum | cut -d' ' -f1
}

store_fingerprint() {
  local root state=''
  for root in "${AUTHORITY_ROOT}" "${FABRIC_ROOT}" "${TRUST_ROOT}"; do
    if [[ -d "${root}" ]]; then
      state+="${root}:$( (cd "${root}" && find . -type f | sort | xargs -r sha256sum \
                          | sha256sum | cut -d' ' -f1) 2>/dev/null || printf 'unreadable' ) "
    else
      state+="${root}:absent "
    fi
  done
  state+="${COORDINATOR_IDENTITY}:$(digest_of "${COORDINATOR_IDENTITY}") "
  state+="${EXECUTION_IDENTITY}:$(digest_of "${EXECUTION_IDENTITY}") "
  printf '%s' "${state}"
}

require_same_filesystem() {
  local row target prepared directory probe device
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    directory="$(dirname "${target}")"
    [[ "${directory}" == "$(dirname "${prepared}")" ]] \
      || halt "${target} does not stage beside itself"
    probe="${directory}"
    while [[ ! -d "${probe}" && "${probe}" != "/" ]]; do probe="$(dirname "${probe}")"; done
    [[ -d "${probe}" ]] || halt "no existing ancestor of ${directory} could be found"
    device="$(stat -c '%d' "${probe}")"
    [[ -n "${device}" ]] || halt "could not determine the filesystem of ${probe}"
  done
  ok "every target stages beside itself, so publication is a rename ($(matrix_count) objects across two roots)"
}

# --- the target fixture -----------------------------------------------------
#
# What the installed rule would say about a host carrying all ten target byte
# sets. Built in a temporary directory, judged by the installed Generation-14
# rule, and removed. Reads production; writes only under the temporary root.
report_target_fixture() {
  local staging verdict row target source
  staging="$(mktemp -d)"
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; source="$(field "${row}" 0)"
    local unprefixed="${target#"${FIXTURE}"}"
    mkdir -p "${staging}$(dirname "${unprefixed}")"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${staging}${unprefixed}" \
      || { rm -rf "${staging}"; halt "could not materialise ${source}"; }
  done
  # The readiness closure includes one object this ceremony does not move,
  # because it is already at its reviewed bytes. The fixture carries it as the
  # host does.
  mkdir -p "${staging}/usr/lib/kyri/python"
  if [[ -f "${LIBRARY_ROOT}/kyri_exec_quota.py" ]]; then
    cp "${LIBRARY_ROOT}/kyri_exec_quota.py" "${staging}/usr/lib/kyri/python/kyri_exec_quota.py"
  fi
  verdict="$(python3 - "${LIBRARY_ROOT}" "${staging}" <<'FIXTUREPY'
import dataclasses, pathlib, sys
library, staging = sys.argv[1], sys.argv[2]
sys.path = [p for p in sys.path if p not in ('', '.', '/opt/schott-platform')]
sys.path.insert(0, library)
from tools.capability.execution import helpers
required = tuple(
    dataclasses.replace(h, path=str(pathlib.Path(staging) / h.path.lstrip('/')))
    for h in helpers.REQUIRED_HELPERS)
print(helpers.compatibility(required).verdict)
FIXTUREPY
)" || { rm -rf "${staging}"; halt "the target fixture could not be judged"; }
  rm -rf "${staging}"
  printf '%s' "${verdict}"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode operation wanted prepared observed
  PREPARING=1
  journal_write PREPARING

  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    wanted="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    injected_at stage && halt "injected failure before staging"

    if [[ "${operation}" == "CREATE" ]]; then
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"
    elif [[ "${operation}" == "REPLACE" ]]; then
      [[ -f "${target}" && ! -L "${target}" ]] \
        || halt "${target} is declared REPLACE but is not a regular file"
      observed="$(digest_of "${target}")"
      [[ "${observed}" == "$(field "${row}" 4)" ]] \
        || halt "${target} is ${observed}, not the declared predecessor this REPLACE expects"
      [[ -e "${target}${BACKUP_SUFFIX}" ]] \
        && halt "${target}${BACKUP_SUFFIX} already exists: a previous transaction did not finish"
      cp -p "${target}" "${target}${BACKUP_SUFFIX}" \
        || halt "could not retain the predecessor object for ${target}"
      sync_path "${target}${BACKUP_SUFFIX}"
      [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${observed}" ]] \
        || halt "the retained predecessor for ${target} does not match what was retained from"
    else
      halt "${target} is declared ${operation}, which this transaction does not implement"
    fi

    rm -f "${prepared}"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${prepared}" \
      || halt "could not materialise ${source} from ${COMMIT}"
    chmod "${mode}" "${prepared}"
    [[ -z "${FIXTURE}" ]] && chown root:root "${prepared}"
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${wanted}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${wanted}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
    injected_at staged && halt "injected failure after staging a helper object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  PREPARING=0
  local n r c; n="$(matrix_count)"; r="$(matrix_count_of REPLACE)"; c="$(matrix_count_of CREATE)"
  ok "PREPARE complete: ${n} objects staged, ${c} $(plural "${c}" pathname pathnames) reserved, ${r} $(plural "${r}" predecessor predecessors) retained"
}

verify_prepared_set() {
  local row target wanted mode
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; wanted="$(field "${row}" 5)"; mode="$(field "${row}" 2)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${wanted}" ]] \
      || halt "prepared object for ${target} does not verify"
    [[ "$(stat -c '%a' "${target}${PREPARED_SUFFIX}")" == "${mode#0}" ]] \
      || halt "prepared object for ${target} has the wrong mode"
    if [[ -z "${FIXTURE}" ]]; then
      [[ "$(stat -c '%U:%G' "${target}${PREPARED_SUFFIX}")" == "root:root" ]] \
        || halt "prepared object for ${target} is not root-owned"
    fi
  done
  ok "all $(matrix_count) prepared objects verify: digest, mode and owner"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode baseline wanted prepared index=0 observed owner_now verdict
  journal_write COMMITTING
  if injected_at committing; then
    rollback "injected failure immediately after COMMITTING"
    return 1
  fi
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    baseline="$(field "${row}" 4)"; wanted="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    if [[ -n "${FIXTURE}" && "${KYRI_AXHELPER_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    if [[ "$(classify "${target}" "${baseline}" "${wanted}")" == "TARGET" ]]; then
      PROGRESS["${index}"]="TARGET"; journal_write COMMITTING; continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING
    if injected_at publish; then
      rollback "injected failure immediately before publication"
      return 1
    fi

    mv -f "${prepared}" "${target}"
    sync_path "${target}"

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${wanted}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"; journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${wanted}"
      return 1
    fi
    if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
      PROGRESS["${index}"]="MODE_FAILED"; journal_write COMMITTING
      rollback "target ${target} has the wrong mode after publication"
      return 1
    fi
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}")"
      if [[ "${owner_now}" != "root:root" ]]; then
        PROGRESS["${index}"]="OWNER_FAILED"; journal_write COMMITTING
        rollback "target ${target} is ${owner_now} after publication"
        return 1
      fi
    fi

    PROGRESS["${index}"]="TARGET"
    journal_write COMMITTING
  done

  if injected_at published; then
    rollback "injected failure after all publication, before the behavioural check"
    return 1
  fi

  # THE BEHAVIOURAL GATE. Ten objects at their target digests is not the same
  # claim as "the installed runtime will now supervise through them", and only
  # the second one matters. Asked of the INSTALLED Generation-14 rule, and a
  # `compatible` verdict is required before the commit point is reached.
  verdict="$(runtime_verdict | cut -d' ' -f1)"
  if [[ "${verdict}" != "compatible" ]]; then
    PROGRESS["behaviour"]="${verdict}"
    journal_write COMMITTING
    rollback "all ten objects published but the installed readiness rule reports ${verdict}"
    return 1
  fi
  ok "the installed Generation-14 readiness rule reports compatible"

  if ! report_ceremony_coherence; then
    rollback "ceremony coherence is incomplete after publication"
    return 1
  fi

  if injected_at precommit; then
    rollback "injected failure immediately before the durable commit point"
    return 1
  fi

  # THE COMMIT POINT. Reached only once all ten published AND verified AND the
  # installed rule agreed. Nothing after this may revert the ceremony.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; the helper set stands"
  OUTCOME="COMMITTED"
  ok "COMMIT complete: $(matrix_count) objects published and verified ($(matrix_count_of REPLACE) replaced, $(matrix_count_of CREATE) created)"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target operation baseline restored=0 removed=0 index="${#MATRIX[@]}"

  # Reverse publication order, so the readiness closure is torn down before the
  # objects outside it -- the mirror of why it was built up last.
  for (( index=${#MATRIX[@]} - 1; index >= 0; index-- )); do
    row="${MATRIX[${index}]}"
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    baseline="$(field "${row}" 4)"

    if [[ "${operation}" == "CREATE" ]]; then
      if [[ -f "${target}" && ! -L "${target}" ]]; then
        rm -f "${target}"; removed=$((removed + 1))
      fi
    elif [[ -f "${target}${BACKUP_SUFFIX}" && ! -L "${target}${BACKUP_SUFFIX}" ]]; then
      if [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" != "${baseline}" ]]; then
        bad "the retained predecessor for ${target} is not the declared predecessor; refusing to restore it"
        continue
      fi
      mv -f "${target}${BACKUP_SUFFIX}" "${target}"
      sync_path "${target}"
      [[ "$(digest_of "${target}")" == "${baseline}" ]] \
        || bad "restoring ${target} did not reproduce the declared predecessor"
      restored=$((restored + 1))
    fi
    rm -f "${target}${PREPARED_SUFFIX}"
  done

  journal_write ROLLED_BACK
  OUTCOME="ROLLED_BACK"
  printf 'rolled back: %d restored, %d removed; the helper surface is the pre-ceremony one\n' \
    "${restored}" "${removed}" >&2
}

# --- RECOVERY --------------------------------------------------------------
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: PREDECESSOR=%d TARGET=%d UNKNOWN=%d (of %d)\n' \
    "${state}" "${BASELINE_COUNT}" "${TARGET_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither the declared predecessor nor the target)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    local verdict; verdict="$(runtime_verdict | cut -d' ' -f1)"
    [[ "${verdict}" == "compatible" ]] \
      || halt "all ten objects are at target but the installed rule reports ${verdict}"
    journal_write COMMITTED; OUTCOME="COMMITTED"
    ok "recovery: the complete helper set is already installed and the installed rule agrees"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK; OUTCOME="ROLLED_BACK"
    ok "recovery: no helper object was published; the surface is the pre-ceremony one"
    return 0
  fi

  # Mixed. Forward only if every unpublished object's prepared bytes verify;
  # otherwise back to the pre-ceremony surface. A mixed helper surface is the
  # one state this ceremony exists to make impossible to leave behind.
  local row target baseline wanted forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; baseline="$(field "${row}" 4)"; wanted="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${baseline}" "${wanted}")" == "TARGET" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${wanted}" ]] || { forward=0; break; }
  done

  if (( forward == 1 )); then
    note "recovery direction: FORWARD (every remaining prepared object verifies)"
    commit_targets || return 1
    return 0
  fi
  note "recovery direction: ROLLBACK (prepared material is incomplete)"
  rollback "recovery could not prove forward completion"
}

# --- evidence --------------------------------------------------------------
write_evidence() {
  if injected_at evidence; then
    bad "injected failure while writing helper evidence; the helper set stands"
    return 0
  fi
  local row verdict
  verdict="$(runtime_verdict | cut -d' ' -f1)"
  {
    printf 'ceremony g11-ax-helpers\n'
    printf 'commit %s\n' "${COMMIT}"
    printf 'runtime_commit %s\n' "${RUNTIME_COMMIT}"
    printf 'runtime_generation 14\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    printf 'state COMMITTED\n'
    printf 'objects %s\n' "$(matrix_count)"
    printf 'replaced %s\n' "$(matrix_count_of REPLACE)"
    printf 'created %s\n' "$(matrix_count_of CREATE)"
    printf 'readiness_closure %s\n' "$(matrix_count_in_closure INSIDE)"
    printf 'ceremony_only %s\n' "$(matrix_count_in_closure OUTSIDE)"
    printf 'runtime_readiness %s\n' "${verdict}"
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)" "$(field "${row}" 6)"
    done
    for row in "${MATRIX[@]}"; do
      printf 'installed %s %s\n' "$(digest_of "$(field "${row}" 1)")" "$(field "${row}" 1)"
    done
  } > "${HELPER_EVIDENCE}.writing"
  chmod 0400 "${HELPER_EVIDENCE}.writing"
  sync_path "${HELPER_EVIDENCE}.writing"
  mv -f "${HELPER_EVIDENCE}.writing" "${HELPER_EVIDENCE}"
  sync_path "${HELPER_EVIDENCE}"
  ok "helper ceremony evidence written to ${HELPER_EVIDENCE}"
}

cleanup_transaction_artifacts() {
  local row target
  if injected_at cleanup; then
    bad "injected cleanup failure after COMMITTED; the helper set remains installed"
    return 0
  fi
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done
  ok "transaction artefacts removed"
}

report_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && extra=$((extra + 1))
    [[ -e "${target}${BACKUP_SUFFIX}" ]] && extra=$((extra + 1))
  done
  if (( extra == 0 )); then
    ok "no transaction artefacts remain"
  else
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; the helper set is installed and unaffected"
  fi
}

verify_installed_set() {
  local row source target wanted mode observed blob
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; wanted="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${wanted}" ]] \
      || bad "${source} at ${COMMIT} is ${blob:-absent}, expected the pinned ${wanted}"
    [[ -L "${target}" ]] && bad "installed ${target} is a symlink"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${wanted}" ]] \
      || bad "installed ${target} is ${observed:-absent}, expected ${wanted}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "${mode#0}" ]] \
      || bad "installed ${target} has mode $(stat -c '%a' "${target}" 2>/dev/null), expected ${mode#0}"
    if [[ -z "${FIXTURE}" && -f "${target}" ]]; then
      [[ "$(stat -c '%U:%G' "${target}")" == "root:root" ]] \
        || bad "installed ${target} is not root-owned"
    fi
  done
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) helper objects correspond to the reviewed commit ${COMMIT}"
}

# ===========================================================================
case "${MODE}" in
--verify-source)
  require_repository
  require_source_digests
  require_namespace_isolation
  note "no installed path was read for state and none was written"
  printf '\nHelper ceremony source verification: all checks passed. %s objects would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_namespace_isolation
  require_root_authority_unmounted
  require_runtime_generation
  require_identity_authorities
  require_gates_closed
  require_no_invocation_records
  require_predecessor_state
  require_no_transaction_residue
  require_same_filesystem
  report_ceremony_coherence || true

  printf '\ncurrent state, decided by the INSTALLED Generation-14 rule:\n'
  report_runtime_readiness
  [[ "${RUNTIME_READINESS}" == "incompatible" ]] \
    || bad "the installed rule already reports ${RUNTIME_READINESS}; this ceremony expects incompatible"

  printf '\nwhat the installed rule would say about the complete target set:\n'
  target_verdict="$(report_target_fixture)"
  note "target fixture readiness: ${target_verdict}"
  [[ "${target_verdict}" == "compatible" ]] \
    || bad "the complete target set would report ${target_verdict}, not compatible"

  printf '\nsurfaces this ceremony does not touch:\n'
  printf '  runtime  %s\n' "$(runtime_fingerprint)"
  printf '  stores   %s\n' "$(store_fingerprint)"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Helper ceremony verification: all checks passed. %s objects would change (%s REPLACE, %s CREATE). Nothing was written.\n' \
      "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
    exit 0
  fi
  printf 'Helper ceremony verification FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--install)
  require_repository
  require_source_digests
  require_namespace_isolation
  require_root_authority_unmounted
  require_runtime_generation
  require_identity_authorities
  require_gates_closed

  TRANSACTION_ID="axhelpers-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  RUNTIME_BEFORE="$(runtime_fingerprint)"
  STORES_BEFORE="$(store_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_predecessor_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "the helper set is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "the helper set is already installed: nothing to do"
      exit 0
    fi
    halt "the journal says COMMITTED but the targets do not agree; operator disposition required"
  else
    note "resuming an interrupted transaction from state ${state}"
    recover "${state}" || true
  fi

  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
    verify_installed_set
    report_ceremony_coherence || bad "ceremony coherence is incomplete after commit"
    report_runtime_readiness
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    report_ceremony_coherence || bad "the rollback did not restore a whole helper surface"
    bad "the transaction rolled back: the helper surface is the pre-ceremony one"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${RUNTIME_BEFORE}" == "$(runtime_fingerprint)" ]] \
    || bad "a runtime object changed during the helper ceremony"
  [[ "${STORES_BEFORE}" == "$(store_fingerprint)" ]] \
    || bad "a governed store or identity authority changed during the helper ceremony"
  require_gates_closed

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Helper ceremony installed and verified. Journal: %s\n' "${JOURNAL}"
    exit 0
  fi
  printf 'Helper ceremony installation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--verify-installed)
  require_repository
  require_source_digests
  require_runtime_generation
  verify_installed_set
  report_ceremony_coherence || bad "ceremony coherence is incomplete"
  require_identity_authorities
  require_gates_closed
  require_no_invocation_records
  report_transaction_residue
  printf '\n'
  report_runtime_readiness
  [[ "${RUNTIME_READINESS}" == "compatible" ]] \
    || bad "the installed rule reports ${RUNTIME_READINESS} after a completed ceremony"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Helper ceremony verified against %s; the installed Generation-14 rule reports compatible.\n' "${COMMIT}"
    exit 0
  fi
  printf 'Helper ceremony installed verification FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--recover)
  require_repository
  require_runtime_generation
  state="$(journal_state)"
  [[ "${state}" == "NONE" ]] && { ok "no transaction journal exists: nothing to recover"; exit 0; }
  TRANSACTION_ID="$(journal_transaction)"
  note "journal state ${state}, transaction ${TRANSACTION_ID}"
  recover "${state}" || true
  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
    verify_installed_set
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
  fi
  report_ceremony_coherence || bad "recovery did not settle on a whole helper surface"
  printf '\n'
  (( FAILURES == 0 )) || { printf 'recovery FAILED: %d\n' "${FAILURES}" >&2; exit 1; }
  printf 'recovery complete: %s\n' "${OUTCOME}"
  exit 0
  ;;
esac
