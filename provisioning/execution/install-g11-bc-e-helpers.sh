#!/usr/bin/env bash
set -Eeuo pipefail

# The G11-BC-E privileged helper ceremony: one object, one transaction.
#
# WHAT THIS MOVES, AND WHY
# ========================
#   kyri_exec_transition_action.py   the privileged action layer. It gains the
#                                    two operations Stage 3 for CINV-000002
#                                    proved missing:
#
#     * the OUTPUT-LEAF TRANSFER. §13 fixes `.../<CINV>/out/` at
#       `kyri-capability:kyri-capability 0700`. The mode was always right; the
#       owner was never set, because publication runs as the coordinator and
#       cannot create a directory owned by another uid, and §34 fixes the quota
#       step before the credential drop so the worker cannot create it either.
#       handoff.py names this layer as the owner of the job -- "Transferring the
#       writable leaf to the execution identity is the privileged transition's
#       job" -- and the job was never written. The worker refused with
#       "the handoff 'out' is unusable: Permission denied".
#
#     * the WORKING-DIRECTORY CLOSURE. cwd survives the privilege boundary while
#       uid and gid do not, so a process that becomes the execution identity was
#       left standing where only the coordinator could reach. The reconciliation
#       could not read container state as a result. The drop now consumes the
#       policy's own `working_directory`, which had been declared since T10 and
#       never read.
#
# The transfer is descriptor-based: the leaf is opened no-follow, checked for
# type and mode, transferred by `fchown` on that descriptor, and re-checked.
# Path-based `chown` remains forbidden to this layer.
#
# WHAT RUNS BEFORE THIS
# =====================
# GENERATION 17, AND THIS CEREMONY REFUSES WITHOUT IT. helpers.py is a RUNTIME
# object carrying the digests the readiness rule checks helpers against, so the
# installed generation decides what "current" means for a helper. Generation
# 16's copy declares the predecessor; Generation 17's declares this target.
# `require_runtime_generation` halts unless the Generation-17 rule is installed.
#
# THE ORDER IS DERIVED, NOT INHERITED FROM THE G11-BB PRECEDENT. Simulating
# every publication point across both surfaces:
#
#   Generation 17 then this ceremony : 0 states where a mixed runtime is executable
#   this ceremony then Generation 17 : 3 such states
#
# Running first would be actively unsafe: Generation 17 publishes helpers.py
# before its other two objects, so with the action module already corrected that
# publication would REOPEN execution mid-transaction, while the Podman backend
# and the launcher were still predecessors.
#
# Both intermediate states of the CORRECT order are incompatible and therefore
# FAIL CLOSED: supervision_ready is false and the coordinator refuses before
# crossing the privilege boundary. That is why no cross-surface atomic
# transaction is needed, and none is invented.
#
# INSIDE THE RUNTIME READINESS CLOSURE
# ====================================
# The action module is declared in helpers.py REQUIRED_HELPERS, so it is INSIDE
# the closure and there is no OUTSIDE group to publish first. The readiness
# verdict turns compatible exactly as this object lands, which is the moment the
# whole two-surface deployment becomes coherent.
#
# WHAT THIS DELIBERATELY DOES NOT TOUCH
# =====================================
# Neither sudoers grant, and neither digest-pinned entrypoint. The launch and
# reconcile entrypoints are unchanged by this delta -- they are not rows here
# and their bytes do not move -- so the installed grants keep matching by digest
# and no sudoers edit is required or performed. The worker and the quota helper
# are likewise untouched: the G11-BB ceremony already moved them and this one
# has no reason to.
#
COMMIT="15a8c738f97394a4f114070c011db22562466ed6"

# The runtime generation whose readiness rule judges this deployment. This
# ceremony refuses to run against anything else: the rule that decides whether
# the result is coherent must be the hardened one.
RUNTIME_COMMIT="15a8c738f97394a4f114070c011db22562466ed6"
RUNTIME_HELPERS_SHA256="78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f"
EXPECTED_RUNTIME_OBJECTS=81

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# A namespace of this ceremony's own. It must never collide with a runtime
# generation's journal: a helper ceremony and a runtime generation can be
# interrupted independently, and a shared transaction root would let one
# recovery dispose of the other's state.
TRANSACTION_ROOT="/root/kyri-g11-bc-e-helper-transaction"
HELPER_EVIDENCE="/root/kyri-g11-bb-helper-digests.txt"

SUDOERS_DIR="/etc/sudoers.d"
# G11-BA installed the launch grant as `kyri-exec-launch`. This ceremony looked
# for `kyri-exec`, a pathname no ceremony ever created, so its launch check
# passed vacuously against every host that has existed since -- and the refusal
# an operator saw named the reconcile grant while the launch grant went unread.
SUDOERS="/etc/sudoers.d/kyri-exec-launch"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
FABRIC_ROOT="/var/lib/kyri/fabric"
TRUST_ROOT="/var/lib/kyri/trust"

# THE CAPABILITY RUNTIME STORE. A second plane, with its own root, its own
# identifier space and its own sequences: invocations and results have never
# lived under the Fabric or the implementation authority, and never will --
# `CINV`/`CRES` are not Fabric kinds. The check below used to scan those two
# roots for them, so it could not fail, and said so anyway.
RUNTIME_STORE="/data/kyri/capability-runtime"

# THE INVOCATION HISTORY THIS CEREMONY WAS REVIEWED AGAINST, by identity and by
# digest -- the same shape as the identity authorities above, and for the same
# reason: what the reviewer looked at is named, so a host carrying something
# else is a host nobody reviewed.
#
# It is NOT "expects none". That was a G11-AX-era statement about a host on
# which nothing had ever been invoked, and it is the third instance of one
# defect: BB-L found it in the Generation-17 preflight, BB-Q in the sudoers
# gate, and BB-R here. `CINV-000001` is accepted, immutable, permanently
# UNRESOLVED history (G11-BB-D; resume NOT authorised), so a ceremony requiring
# zero invocation records would refuse the accepted host forever.
#
# A `CINV` is immutable pre-execution evidence, so pinning a declared record's
# digest is durable -- it can never legitimately change. What is NOT durable is
# pinning the SIZE of the history, because the platform is built to invoke and
# the next controlled invocation is expected. So freshness -- "the host has not
# moved past the review" -- is asserted by the PREFLIGHT only. The post-install
# attestation requires the reviewed history to be intact and the store to be
# sound, and tolerates governed history written after this ceremony was
# accepted. Otherwise an accepted deployment would start reporting FAIL the
# moment the platform did the thing it exists for.
ACCEPTED_INVOCATION_HISTORY=(
  "CINV-000001 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa"
)
ACCEPTED_RESULT_HISTORY=()

COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"
COORDINATOR_IDENTITY_SHA256="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
EXECUTION_IDENTITY_SHA256="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"

# Nothing this ceremony runs may leave bytecode in the tree it inspects. The
# Generation-17 verifier learned this the hard way: the readiness report imports
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
  SUDOERS_DIR="${FIXTURE}${SUDOERS_DIR}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  RECONCILE_SUDOERS="${FIXTURE}${RECONCILE_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  FABRIC_ROOT="${FIXTURE}${FABRIC_ROOT}"
  TRUST_ROOT="${FIXTURE}${TRUST_ROOT}"
  COORDINATOR_IDENTITY="${FIXTURE}${COORDINATOR_IDENTITY}"
  EXECUTION_IDENTITY="${FIXTURE}${EXECUTION_IDENTITY}"
  RUNTIME_STORE="${FIXTURE}${RUNTIME_STORE}"
  # A fixture is a DIFFERENT HOST, and production's pin names production's
  # records. So the fixture declares its own accepted history beside the other
  # evidence files this ceremony already reads out of the fixture's /root, and
  # a fixture that declares none is a host on which nothing was ever invoked.
  # This is not a production override: under --fixture every root above is
  # rebound too, so no production path is read for state either way.
  ACCEPTED_INVOCATION_HISTORY=()
  ACCEPTED_RESULT_HISTORY=()
  ACCEPTED_HISTORY_DECLARATION="${FIXTURE}/root/kyri-accepted-invocation-history.txt"
  if [[ -f "${ACCEPTED_HISTORY_DECLARATION}" ]]; then
    while read -r _kind _identifier _digest _rest; do
      [[ -z "${_kind}" || "${_kind}" == \#* ]] && continue
      [[ -n "${_identifier}" && -n "${_digest}" && -z "${_rest}" ]] \
        || { printf 'ERROR malformed accepted-history row: %s\n' "${_kind}" >&2; exit 2; }
      case "${_kind}" in
        CINV) ACCEPTED_INVOCATION_HISTORY+=("${_identifier} ${_digest}") ;;
        CRES) ACCEPTED_RESULT_HISTORY+=("${_identifier} ${_digest}") ;;
        *) printf 'ERROR unknown accepted-history kind: %s\n' "${_kind}" >&2; exit 2 ;;
      esac
    done < "${ACCEPTED_HISTORY_DECLARATION}"
  fi
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-bbhelper.new"
BACKUP_SUFFIX=".kyri-bbhelper.pre"

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
# ONE object, and it is INSIDE the runtime readiness closure -- it is declared
# in the installed helpers.py REQUIRED_HELPERS -- so there is no OUTSIDE group
# to publish first. The readiness verdict turns compatible exactly as this
# object lands, which is the property the closure column exists to make
# checkable rather than argued.
#
# The worker and the quota helper are NOT rows here. G11-BB moved both and
# nothing in these corrections touches them; republishing an object to make a
# ceremony look symmetrical would change what root executes for no stated
# reason.
#
# source | target | mode | operation | predecessor-sha256 | target-sha256 | closure
"provisioning/execution/kyri-exec-transition-action.py|${LIBRARY_ROOT}/kyri_exec_transition_action.py|0444|REPLACE|b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315|d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de|INSIDE"
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
  [[ -n "${FIXTURE}" && "${KYRI_BCEHELPER_FAIL_AT:-}" == "$1" ]]
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
    printf 'ceremony=g11-bb-helpers\n'
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
  # Every runtime generation this host has seen, and the EARLIER helper
  # ceremonies. A shared namespace would let one recovery dispose of another's
  # transaction, so each is named rather than assumed distinct.
  for generation in gen12 gen13 gen14 gen15 gen16 gen17; do
    other="${FIXTURE}/root/kyri-${generation}-transaction"
    [[ "${TRANSACTION_ROOT}" != "${other}" ]] \
      || halt "this ceremony shares a transaction root with ${generation}"
  done
  for earlier in g11-ax-helper g11-bb-helper; do
    other="${FIXTURE}/root/kyri-${earlier}-transaction"
    [[ "${TRANSACTION_ROOT}" != "${other}" ]] \
      || halt "this ceremony shares a transaction root with the ${earlier} ceremony"
  done
  [[ "${TRANSACTION_ROOT}" == *"g11-bc-e-helper"* ]] \
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
# Every behavioural verdict below comes from the INSTALLED Generation-17 bytes.
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
# `/usr/lib/kyri/python` carries the Generation-17 runtime objects AND the
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
    || halt "the installed readiness rule is ${observed:-absent}, not the Generation-17 ${RUNTIME_HELPERS_SHA256}: install Generation 17 before this ceremony"

  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ "$(field "${row}" 3)" == "CREATE" && "${target}" == "${LIBRARY_ROOT}/"* ]] || continue
    [[ -f "${target}" ]] && created=$((created + 1))
  done
  expected=$((EXPECTED_RUNTIME_OBJECTS + created))
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' -not -path '*__pycache__*' | wc -l)"
  [[ "${count}" -eq "${expected}" ]] \
    || halt "the library root holds ${count} objects, expected ${EXPECTED_RUNTIME_OBJECTS} runtime objects plus ${created} published helper module(s)"
  ok "the installed runtime is Generation 17 (${EXPECTED_RUNTIME_OBJECTS} runtime objects, ${created} helper module(s) published; the hardened readiness rule)"
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

# The accepted grant state this ceremony runs against, checked exactly.
#
# This check used to require all three grants ABSENT. At G11-AX that was simply
# a true statement about the host: nothing had ever been granted, so "absent"
# and "not installed by anybody" were the same claim. G11-BA then installed the
# launch and reconcile grants, the accepted deployment plan keeps them through
# Phase 8, and this inherited check refused production for holding exactly the
# grants it is supposed to hold. That is the same stale model BB-L corrected in
# the Generation-17 ceremony; this is the other copy of it.
#
# No stronger reason requires their absence. This ceremony moves three helper
# OBJECTS and neither digest-pinned entrypoint: `require_entrypoints_unmoved`
# asserts the pinned bytes do not change, and a grant is permission to ask while
# readiness is permission to proceed. Readiness is what stays shut until the
# last helper lands.
#
# So the model is precise rather than absolute, and it is stricter than the
# Generation-17 one: by Phase 8 both grants MUST be present, because a host
# missing them is not the accepted host this ceremony was derived against.
require_gates_closed() {
  [[ ! -e "${VERIFY_SUDOERS}" ]] \
    || halt "${VERIFY_SUDOERS} exists: the verification entrypoint is not authorised"

  local grant entrypoint pinned installed
  for grant in "${SUDOERS}" "${RECONCILE_SUDOERS}"; do
    case "${grant}" in
      *kyri-exec-launch)    entrypoint="${LIBEXEC_ROOT}/kyri-exec-transition" ;;
      *kyri-exec-reconcile) entrypoint="${LIBEXEC_ROOT}/kyri-exec-reconcile" ;;
      *) halt "${grant} is not a grant this ceremony can account for" ;;
    esac
    [[ -e "${grant}" ]] \
      || halt "${grant} is missing: this ceremony expects the accepted G11-BA execution grants to be installed"
    # The digest the grant pins, read out of the grant itself.
    pinned="$(grep -oE 'sha256:[0-9a-f]{64}' "${grant}" | head -1 || true)"
    pinned="${pinned#sha256:}"
    [[ -n "${pinned}" ]] \
      || halt "${grant} pins no digest: this ceremony cannot confirm what it authorises"
    installed="$(digest_of "${entrypoint}")"
    [[ "${pinned}" == "${installed}" ]] \
      || halt "${grant} pins ${pinned}, but ${entrypoint} is ${installed:-absent}"
    # A grant that pins the right bytes at the wrong command is a grant nobody
    # reviewed, so the command path is checked too rather than inferred. The
    # grant text names the PRODUCTION path even when this runs under --fixture,
    # so the fixture prefix comes off before the comparison.
    local commanded="${entrypoint#"${FIXTURE}"}"
    grep -q -- "${commanded}" "${grant}" \
      || halt "${grant} does not name ${commanded} as its command"
  done

  # Anything else under the grant directory is an elevation nobody declared.
  local unexpected
  unexpected="$(find "${SUDOERS_DIR}" -maxdepth 1 -type f -name 'kyri-*' \
                  ! -name "$(basename "${SUDOERS}")" \
                  ! -name "$(basename "${RECONCILE_SUDOERS}")" 2>/dev/null || true)"
  [[ -z "${unexpected}" ]] \
    || halt "an undeclared Kyri grant exists: ${unexpected}"

  ok "both accepted execution grants are present, each pinning the installed entrypoint by digest and command; the verification grant is absent"
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

# --- the governed invocation history ---------------------------------------
#
# Read through the PLATFORM'S OWN readers, exactly as `runtime_verdict` takes
# the readiness rule from the installed runtime rather than carrying a copy:
# the store class, its validator, and the identifier model all come from
# ${LIBRARY_ROOT}. Nothing here is a second interpretation of the store.
#
# The store's expected ownership is not guessed and not taken from the store
# itself, which would be circular. It comes from the coordinator identity
# authority -- whose bytes `require_identity_authorities` has already pinned --
# resolved through the platform's own account resolver.
#
# Emits one fact per line and judges nothing; every refusal below is bash's.
invocation_history_report() {
  python3 - "${LIBRARY_ROOT}" "${RUNTIME_STORE}" "${COORDINATOR_IDENTITY}" <<'HISTORYPY'
import json, pathlib, sys

library, store_root, identity_path = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path = [p for p in sys.path if p not in ('', '.', '/opt/schott-platform')]
sys.path.insert(0, library)

root = pathlib.Path(store_root)
if not root.is_dir():
    print("STORE absent")
    raise SystemExit(0)
try:
    account = json.loads(
        pathlib.Path(identity_path).read_text(encoding="utf-8"))["coordinator_account"]
except Exception as error:                       # noqa: BLE001 - reported, not raised
    print(f"STORE unusable the coordinator identity authority is unreadable ({error})")
    raise SystemExit(0)
try:
    from tools.capability import inspection
    from tools.capability.identifiers import ID_FIELDS
    from tools.capability.store import CapabilityStore
    from tools.capability.execution.identity import resolve_account
except ImportError as error:
    print(f"STORE unusable {error}")
    raise SystemExit(0)
try:
    uid, gid = resolve_account(account)
    store = CapabilityStore.open_for_read(str(root), expected_uid=uid, expected_gid=gid)
except Exception as error:                       # noqa: BLE001 - reported, not raised
    print(f"STORE unusable {error}")
    raise SystemExit(0)

print("STORE ok")
report = inspection.validate_store(store)
if report.status != inspection.STATUS_REPORTED:
    print(f"FINDING the store reports status {report.status}")
for finding in report.findings:
    print(f"FINDING {finding}")

for kind, label in (("capability-invocation", "INVOCATION"),
                    ("capability-result", "RESULT")):
    directory = root / store.record_dirs[kind]
    for entry in sorted(path.name for path in directory.iterdir()):
        print(f"ENTRY {label} {entry}")
    for record in store.list_records(kind):
        identifier = record.get(ID_FIELDS[kind])
        print(f"RECORD {label} {identifier} {store.path_for(kind, identifier)}")
    # The counter itself, not the identity derived from it: an identity skips
    # names a record already occupies, so it cannot tell a counter that
    # disagrees with the record set from one that agrees.
    raw = ""
    try:
        raw = (root / "sequences" / f"{kind}.seq").read_text(encoding="utf-8").strip()
    except OSError:
        raw = ""
    print(f"SEQUENCE {label} {raw if raw.isdigit() else 0}")
    print(f"NEXT {label} {store.peek_next_id(kind)}")
HISTORYPY
}

# The accepted invocation history, checked against the store that actually
# holds it. `freshness` is `reviewed` for the preflight -- the history must be
# EXACTLY the reviewed one -- and `installed` for the post-install attestation,
# which requires the reviewed history intact and the store sound but tolerates
# governed history written after this ceremony was accepted. See the
# declaration above for why those are different questions.
require_accepted_invocation_history() {
  local freshness="$1" line kind identifier digest observed
  local -a findings=() entries=() records=() declared=()
  local -A sequence=() next=() path_of=()
  local store_state=""

  while IFS= read -r line; do
    case "${line}" in
      "STORE "*)    store_state="${line#STORE }" ;;
      "FINDING "*)  findings+=("${line#FINDING }") ;;
      "ENTRY "*)    entries+=("${line#ENTRY }") ;;
      "RECORD "*)   read -r kind identifier observed <<<"${line#RECORD }"
                    records+=("${kind} ${identifier}")
                    path_of["${kind} ${identifier}"]="${observed}" ;;
      "SEQUENCE "*) read -r kind observed <<<"${line#SEQUENCE }"
                    sequence["${kind}"]="${observed}" ;;
      "NEXT "*)     read -r kind observed <<<"${line#NEXT }"
                    next["${kind}"]="${observed}" ;;
    esac
  done < <(invocation_history_report)

  for line in "${ACCEPTED_INVOCATION_HISTORY[@]}"; do declared+=("INVOCATION ${line}"); done
  for line in "${ACCEPTED_RESULT_HISTORY[@]}";     do declared+=("RESULT ${line}"); done

  # FAIL CLOSED. An absent or unreadable store is a refusal whenever anything
  # was reviewed, and never a quiet pass -- which is the whole of what was
  # wrong here.
  if [[ "${store_state}" != "ok" ]]; then
    (( ${#declared[@]} == 0 )) \
      || halt "the invocation history at ${RUNTIME_STORE} could not be read (${store_state:-no report}), and ${#declared[@]} record(s) were reviewed"
    ok "no capability runtime store exists at ${RUNTIME_STORE} and none was reviewed"
    return 0
  fi

  local finding
  for finding in "${findings[@]}"; do bad "invocation store: ${finding}"; done
  (( ${#findings[@]} == 0 )) \
    || halt "the invocation store at ${RUNTIME_STORE} is not sound; operator disposition required"

  # Nothing in a record directory but the records themselves. The validator
  # names a partial write; an object of any other shape is one nobody declared.
  local entry expected found
  for entry in "${entries[@]}"; do
    read -r kind identifier <<<"${entry}"
    found=""
    for line in "${records[@]}"; do
      [[ "${line}" == "${kind} "* ]] || continue
      [[ "${identifier}" == "${line#* }.yaml" ]] && { found=1; break; }
    done
    [[ -n "${found}" ]] \
      || halt "${RUNTIME_STORE} holds ${identifier}, which is not a governed ${kind,,} record"
  done

  # Every reviewed record, present and byte-identical. A CINV is immutable
  # pre-execution evidence; a CRES is a terminal outcome. Neither may move.
  for line in "${declared[@]}"; do
    read -r kind identifier digest <<<"${line}"
    expected="${path_of["${kind} ${identifier}"]:-}"
    [[ -n "${expected}" ]] \
      || halt "the reviewed ${identifier} is absent from ${RUNTIME_STORE}"
    observed="$(digest_of "${expected}")"
    [[ "${observed}" == "${digest}" ]] \
      || halt "the reviewed ${identifier} is ${observed:-unreadable}, expected ${digest}: immutable evidence was rewritten"
  done

  # The record set and its own counter must agree, per kind. A counter ahead of
  # the records means an identity was spent and its record never landed; a
  # counter behind them means a record exists that no allocation produced.
  for kind in INVOCATION RESULT; do
    found=0
    for line in "${records[@]}"; do [[ "${line}" == "${kind} "* ]] && found=$((found + 1)); done
    [[ "${sequence[${kind}]:-0}" == "${found}" ]] \
      || halt "${RUNTIME_STORE} holds ${found} ${kind,,} record(s) and a sequence at ${sequence[${kind}]:-0}: the store disagrees with its own counter"
  done

  local invocations=0 results=0
  for line in "${records[@]}"; do
    [[ "${line}" == "INVOCATION "* ]] && invocations=$((invocations + 1))
    [[ "${line}" == "RESULT "* ]] && results=$((results + 1))
  done

  if [[ "${freshness}" == "reviewed" ]]; then
    (( invocations == ${#ACCEPTED_INVOCATION_HISTORY[@]} && results == ${#ACCEPTED_RESULT_HISTORY[@]} )) \
      || halt "the invocation history has moved past the reviewed one (${invocations} invocation(s), ${results} result(s) against ${#ACCEPTED_INVOCATION_HISTORY[@]} and ${#ACCEPTED_RESULT_HISTORY[@]} reviewed); re-review before installing"
    ok "the invocation history at ${RUNTIME_STORE} is exactly the reviewed one: ${invocations} invocation(s), ${results} result(s), ${next[INVOCATION]:-?} unspent"
  else
    ok "the invocation history at ${RUNTIME_STORE} carries all ${#declared[@]} reviewed record(s) unchanged; ${invocations} invocation(s), ${results} result(s), ${next[INVOCATION]:-?} unspent"
  fi
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
# sets. Built in a temporary directory, judged by the installed Generation-17
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
  # The readiness closure is EIGHT declared objects and this ceremony moves
  # three. The other five are already at their reviewed bytes and are unchanged
  # by this delta, so the fixture carries them exactly as the host does --
  # otherwise the rule would judge them absent and the verdict would be about
  # this function's staging rather than about the target byte set.
  #
  # Derived from the installed declaration rather than listed here: a helper
  # added to REQUIRED_HELPERS later must not silently fall out of this fixture.
  local declared
  while IFS= read -r declared; do
    [[ -n "${declared}" ]] || continue
    is_target "${FIXTURE}${declared}" && continue
    [[ -f "${FIXTURE}${declared}" ]] || continue
    mkdir -p "${staging}$(dirname "${declared}")"
    cp "${FIXTURE}${declared}" "${staging}${declared}"
  done < <(python3 - "${LIBRARY_ROOT}" <<'DECLAREDPY'
import sys
library = sys.argv[1]
sys.path = [p for p in sys.path if p not in ('', '.', '/opt/schott-platform')]
sys.path.insert(0, library)
from tools.capability.execution import helpers
for helper in helpers.REQUIRED_HELPERS:
    print(helper.path)
DECLAREDPY
)
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

    if [[ -n "${FIXTURE}" && "${KYRI_BCEHELPER_FAIL_AT:-}" == "${index}" ]]; then
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
  # the second one matters. Asked of the INSTALLED Generation-17 rule, and a
  # `compatible` verdict is required before the commit point is reached.
  verdict="$(runtime_verdict | cut -d' ' -f1)"
  if [[ "${verdict}" != "compatible" ]]; then
    PROGRESS["behaviour"]="${verdict}"
    journal_write COMMITTING
    rollback "all ten objects published but the installed readiness rule reports ${verdict}"
    return 1
  fi
  ok "the installed Generation-17 readiness rule reports compatible"

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
    printf 'ceremony g11-bb-helpers\n'
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
  require_accepted_invocation_history reviewed
  require_predecessor_state
  require_no_transaction_residue
  require_same_filesystem
  report_ceremony_coherence || true

  printf '\ncurrent state, decided by the INSTALLED Generation-17 rule:\n'
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
  require_accepted_invocation_history installed
  report_transaction_residue
  printf '\n'
  report_runtime_readiness
  [[ "${RUNTIME_READINESS}" == "compatible" ]] \
    || bad "the installed rule reports ${RUNTIME_READINESS} after a completed ceremony"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Helper ceremony verified against %s; the installed Generation-17 rule reports compatible.\n' "${COMMIT}"
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
