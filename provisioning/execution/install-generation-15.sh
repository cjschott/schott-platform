#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 15: the coordinator learns what happened, deployed.
#
# WHAT THIS DEPLOYS. The supervised execution path ENG-0005 G11-AS through
# G11-AT built, as one transaction:
#
#   G11-AS  the execution identity becomes deployment-bound authority, and the
#           runtime gains the reader for it.
#   G11-AT  the coordinator supervises the governed worker protocol, concludes
#           a terminal result from what the worker reports, enumerates
#           executions whose supervision was lost, and refuses to call a
#           supervision path current when the helper bytes it reaches are not.
#
# WHY IT IS ONE TRANSACTION AND NOT THREE. The runtime that supervises, the
# runtime that records results, and the runtime that recovers interrupted
# executions are the same runtime. A host carrying the new supervisor with the
# old result writer would execute real workloads and record their outcomes under
# a contract that predates `succeeded`; one carrying the new worker without the
# Podman backend would fail at the moment it mattered most; one carrying
# execution without the recovery enumeration would leave orphans nothing looks
# for. Those are not degraded generations, they are unreviewed ones, so the
# journal treats all twenty-one objects as a single logical state and any
# pre-COMMITTED failure returns the host to a whole Generation 14.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. Not the launch helper, not the
# reconciliation helper, not either sudoers grant, and not the two deployment
# identity authorities. Each has its own ceremony and its own review; a runtime
# installer that touched them would be granting privilege as a side effect of
# packaging. They are asserted untouched on every run.
#
# INSTALLABLE IS NOT EXECUTION-READY. This generation may be installed onto a
# host whose helpers are stale and whose identity authorities are absent -- the
# runtime imports fine without them, because every one of those is read at
# execution time and refused there. What such a host cannot do is execute:
# `helpers.compatibility()` reports the supervision path incompatible, and the
# supervised preflight reports it not ready. That is the honest split, and it is
# why this installer does not demand future deployment files it does not need.
#
# THE CLOSURE IS COMPUTED, NOT ASSERTED. `tools/dev/runtime_closure.py` walks
# the import graph from the roots the installed runtime is actually entered
# through. Nothing here is whitelisted into the surface: two modules G11-AT
# added were reached only by accident of how they were imported, and both were
# fixed at the source rather than listed.
#
# USAGE
#   install-generation-15.sh --verify-source     read-only: is the PACKAGE sound?
#   install-generation-15.sh --verify            read-only: is the host at G12?
#   install-generation-15.sh --install           the transaction (root)
#   install-generation-15.sh --verify-installed  read-only: is the host at G13?
#   install-generation-15.sh --recover           finish or unwind a transaction

# The reviewed Generation-15 authority: the accepted G11-AT report commit, which
# carries every one of the twenty-one runtime objects below at exactly the bytes
# this matrix pins. It is not HEAD, and it is not this installer's own commit --
# a ceremony that installed from a moving reference would install whatever
# happened to be there.
COMMIT="ef4f7446200b668f8dcbf34d180c5102270f19f6"

# The accepted Generation-14 source authority, and the baseline this transaction
# requires the host to be at.
GEN14_COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# This transaction's own namespace. Generation 14's retained journal at
# /root/kyri-gen14-transaction is predecessor evidence: it records how the host
# reached the state this transaction starts from, it is never read as this
# transaction's state, and nothing here writes to or removes it. Deriving an
# installer from its predecessor and leaving the predecessor's path in place is
# what made the first real Generation-14 attempt halt against a COMMITTED
# journal belonging to a transaction that had already finished.
TRANSACTION_ROOT="/root/kyri-gen15-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen14-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen14-helper-digests.txt"
GEN15_LIBRARY_EVIDENCE="/root/kyri-gen15-library-digests.txt"
GEN15_HELPER_EVIDENCE="/root/kyri-gen15-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# The two deployment identity authorities. Read to prove this ceremony did not
# create them; never written. Generation 15 does not need them to install.
COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# Eight CREATEs move the count by eight. Both ends are stated, so a matrix that
# quietly grew or lost a row fails here rather than at publication.
EXPECTED_LIBRARY_FILES_BASELINE=78
EXPECTED_LIBRARY_FILES_TARGET=80

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify-source|--verify|--install|--verify-installed|--recover)
      [[ -z "${MODE}" ]] || { printf 'ERROR one mode only\n' >&2; exit 2; }
      MODE="$1"; shift ;;
    --fixture)
      FIXTURE="${2:-}"; shift 2
      [[ -n "${FIXTURE}" && "${FIXTURE}" != "/" ]] || { printf 'ERROR --fixture needs a directory\n' >&2; exit 2; }
      ;;
    *) printf 'ERROR unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
MODE="${MODE:---verify}"

if [[ -n "${FIXTURE}" ]]; then
  LIBRARY_ROOT="${FIXTURE}${LIBRARY_ROOT}"
  LIBEXEC_ROOT="${FIXTURE}${LIBEXEC_ROOT}"
  TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"
  BASELINE_LIBRARY_EVIDENCE="${FIXTURE}${BASELINE_LIBRARY_EVIDENCE}"
  BASELINE_HELPER_EVIDENCE="${FIXTURE}${BASELINE_HELPER_EVIDENCE}"
  GEN15_LIBRARY_EVIDENCE="${FIXTURE}${GEN15_LIBRARY_EVIDENCE}"
  GEN15_HELPER_EVIDENCE="${FIXTURE}${GEN15_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  RECONCILE_SUDOERS="${FIXTURE}${RECONCILE_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
  COORDINATOR_IDENTITY="${FIXTURE}${COORDINATOR_IDENTITY}"
  EXECUTION_IDENTITY="${FIXTURE}${EXECUTION_IDENTITY}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen15.new"
BACKUP_SUFFIX=".kyri-gen15.gen14"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

CLOSURE_STAGING=""
PREPARING=0

# --- the twenty-one generation-15 objects, pinned both ways ---------------------
#
# source | target | mode | operation | gen14-sha256 | gen15-sha256 | group
#
# Generation 14 created a package directory and its matrix carried the machinery
# for it. This one does not: every target sits in a directory that already
# exists at Generation 14, so there is no directory to create, none to remove on
# rollback, and none of that code is carried forward. Copying it would have
# meant maintaining a branch nothing takes.
#
# The GROUP column is new and is what makes coherence checkable rather than
# argued. A host must never expose one group's Generation-15 bytes beside
# another's Generation-14 bytes -- see require_group_coherence.
MATRIX=(
# --- V: the runtime-side verification surface ------------------------------
#
# Moved as ONE group because it is one surface. The installed verification.py
# predates 03a2e90 and cannot import -- it asks worker.py for WORKER_GID and
# WORKER_UID, which that commit removed in favour of the identity authority.
# Replacing it alone would leave the two modules a contract already names
# absent; creating those alone would leave the module that fails to import.
# Neither half is a coherent state, so the group is the unit.
#
# This does NOT authorise the verify entrypoint. /etc/sudoers.d/kyri-exec-verify
# stays absent and is refused below, exactly as it was before.
"tools/capability/execution/verification.py|${LIBRARY_ROOT}/tools/capability/execution/verification.py|0444|REPLACE|ed5b49ed03add16c8ba7a233d53a8c5528e5ba4d0fc23f53cdd41bb788bd2e73|7a792aaf3c59ed0bb4bd32cb55267e6fc26dfae06f5da1b8b36efff9e1efa952|V"
"tools/capability/execution/result_content.py|${LIBRARY_ROOT}/tools/capability/execution/result_content.py|0444|CREATE|ABSENT|b1c5a89fd5b8b2a368bb8908394052c18475a36adae1b4d88d2f65cb9bcd0bba|V"
"tools/capability/execution/contract_outcome.py|${LIBRARY_ROOT}/tools/capability/execution/contract_outcome.py|0444|CREATE|ABSENT|139b77b7065f88d05ed472bbf9de0c2665a74b29d21f132445848b0ee4dd16a5|V"
# --- R: supervised recovery discovery ---------------------------------------
#
# recovery.py discovers an interrupted invocation from the lifecycle journal
# rather than from CINV.adapter_identity, which the supervised path never
# writes; cli.py opens the execution root and threads it in. A host with one
# and not the other either passes a root nothing reads or reads a root nothing
# passes, so they move together.
"tools/capability/execution/recovery.py|${LIBRARY_ROOT}/tools/capability/execution/recovery.py|0444|REPLACE|a93819d1400d981097eab6e2f31413ea90bc094d5dfd09265a368ccc0e59ab8f|f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03|R"
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|752951f7688af9ced5b326ad5be6d690c47e0ddee89d6b511f31296683e3d295|7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1|R"
# --- H: what the runtime declares about the privileged surface --------------
#
# helpers.py carries the digests of the three helper objects the separate
# ceremony will move; kyri_exec_launcher.py is the seam that carries a helper
# refusal back. Both are runtime objects. NEITHER IS A PRIVILEGED HELPER: this
# generation installs no /usr/libexec object and no library-root helper module.
"tools/capability/execution/helpers.py|${LIBRARY_ROOT}/tools/capability/execution/helpers.py|0444|REPLACE|74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874|6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07|H"
"provisioning/execution/kyri-exec-launcher.py|${LIBRARY_ROOT}/kyri_exec_launcher.py|0444|REPLACE|269258f3a407aaea5269312dda2a3b3c78fa50c2512c8f32475840e76c9fbb5d|78c6de9093a535618b6fee54cd90c8eab388bc7ba6e4bd39d42de7f2e019bc83|H"
)

# What each group is, so a coherence failure names something an operator can act
# on rather than a set of pathnames.
# --- governed objects deliberately outside the execution closure -------------
#
# The closure is computed from the PRODUCTION EXECUTION roots, and the surplus
# check below refuses any matrix row that closure does not require. That check
# is right and is not widened here: these three are named, one by one, with the
# reason each is governed, and anything not named still refuses.
#
# They are NOT added to CLOSURE_ROOTS and NOT reachable from them. Making them
# reachable would mean inventing an import the runtime does not perform, which
# would be forging the evidence the closure check exists to read.
#
#   verification.py      Reached only by /usr/libexec/kyri-exec-verify-worker.py,
#                        a governed ALTERNATIVE entrypoint that is not a
#                        production execution root. It has been an installed
#                        governed object since Generation 13 and is already part
#                        of the accepted Generation-14 surface; this generation
#                        moves it because its installed bytes cannot import.
#
#   result_content.py    Named BY PATH as an authority in a live Fabric record:
#                        CCON-0001.response_shape.content.authority. A contract
#                        that names a module the deployment does not carry is a
#                        claim of enforcement no code performs.
#
#   contract_outcome.py  The declared translation between the runtime's
#                        records.OUTCOME_CLASSES and a capability contract's
#                        failure_modes. Nothing imports it yet; it exists so
#                        "every failure this capability can suffer is one the
#                        contract declares" is checkable rather than asserted.
#
# Each is verified, published and rolled back exactly like every other row. The
# only thing this list changes is that the surplus check knows they were meant.
OUTSIDE_EXECUTION_CLOSURE=(
"tools/capability/execution/verification.py"
"tools/capability/execution/result_content.py"
"tools/capability/execution/contract_outcome.py"
)

declared_outside_closure() {
  local candidate="$1" entry
  for entry in "${OUTSIDE_EXECUTION_CLOSURE[@]}"; do
    [[ "${entry}" == "${candidate}" ]] && return 0
  done
  return 1
}

group_name() {
  case "$1" in
    V) printf 'the runtime-side verification surface' ;;
    R) printf 'supervised recovery discovery' ;;
    H) printf 'helper declaration and refusal reporting' ;;
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# The modules that must NOT be installed, carried forward from Generation 14
# unchanged. The runtime may not reach anything that DECIDES: the governed
# Fabric write path, the operator input surface, and the Trust decision surface.
EXCLUDED=(
"tools/fabric/admission.py"
"tools/fabric/cli.py"
"tools/fabric/selection.py"
"tools/trust/evaluator.py"
"tools/trust/root_authority.py"
"tools/trust/gateway.py"
"tools/trust/policy.py"
"tools/trust/audit.py"
"tools/trust/cli.py"
"tools/trust/transitions_cli.py"
)

# The privileged surface this ceremony must leave exactly as it found it. Each
# is installed by the helper ceremony, under its own review; a runtime installer
# that republished any of them would be changing what root executes as a side
# effect of packaging.
#
# `kyri_exec_worker` is the interesting one. It is a production entry root -- the
# closure is computed through it, which is how the Podman backend enters the
# graph naturally rather than by being listed -- but its object lives at
# /usr/libexec, not in the library root. So the closure is satisfied for it by
# the entrypoint being installed, and the matrix does not carry it.
EXCLUDED_HELPER_LIBRARY=(
"kyri_exec_transition.py"
"kyri_exec_transition_action.py"
"kyri_exec_verify.py"
"kyri_exec_quota.py"
)
ENTRYPOINT_OBJECTS=(
"kyri_exec_worker.py|${LIBEXEC_ROOT}/kyri-exec-worker.py"
)
EXCLUDED_PRIVILEGED=(
"${LIBEXEC_ROOT}/kyri-exec-transition"
"${LIBEXEC_ROOT}/kyri-exec-verify"
"${LIBEXEC_ROOT}/kyri-exec-quota"
"${LIBEXEC_ROOT}/kyri-exec-worker.py"
"${LIBEXEC_ROOT}/kyri-exec-verify-worker.py"
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
matrix_count_in_group() {
  local wanted="$1" row n=0
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 6)" == "${wanted}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}
matrix_groups() {
  local row
  for row in "${MATRIX[@]}"; do printf '%s\n' "$(field "${row}" 6)"; done | sort -u
}
matrix_names() {
  local row out=""
  for row in "${MATRIX[@]}"; do
    out+="${out:+, }$(basename "$(field "${row}" 1)")"
  done
  printf '%s' "${out}"
}
plural() { [[ "$1" == "1" ]] && printf '%s' "$2" || printf '%s' "$3"; }

is_target() {
  local candidate="$1" row
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 1)" == "${candidate}" ]] && return 0
  done
  return 1
}

# Test-only failure injection, in this generation's own namespace. Impossible
# without --fixture, so a production run cannot reach any of it.
injected_at() {
  [[ -n "${FIXTURE}" && "${KYRI_GEN15_FAIL_AT:-}" == "$1" ]]
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

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
    if os.path.isdir(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    else:
        fd = os.open(path, os.O_RDONLY)
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
    # A retained predecessor is removed only where the target is still that
    # predecessor. Past that point removal is rollback's fenced job, not ours.
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 14\n' \
    "${removed}" >&2
}

cleanup_on_exit() {
  local status=$?
  [[ -n "${CLOSURE_STAGING}" ]] && rm -rf "${CLOSURE_STAGING}"
  (( PREPARING == 1 )) && unwind_preparation
  return "${status}"
}
trap cleanup_on_exit EXIT

# --- journal ---------------------------------------------------------------
#
# States: NONE -> PREPARING -> PREPARED -> COMMITTING -> COMMITTED, with
# ROLLING_BACK and ROLLED_BACK as the terminal failure path. Every irreversible
# step is preceded by a durable write, so recovery reads a fact rather than
# inferring one.
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN14_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
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

# --- classification --------------------------------------------------------
classify() {
  local target="$1" baseline="$2" wanted="$3" observed
  if [[ "${baseline}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'BASELINE'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${wanted}" ]]; then printf 'TARGET'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${wanted}" ]]; then printf 'TARGET'
  elif [[ "${observed}" == "${baseline}" ]]; then printf 'BASELINE'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target baseline wanted state
  BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; baseline="$(field "${row}" 4)"; wanted="$(field "${row}" 5)"
    state="$(classify "${target}" "${baseline}" "${wanted}")"
    case "${state}" in
      BASELINE) BASELINE_COUNT=$((BASELINE_COUNT + 1)) ;;
      TARGET) TARGET_COUNT=$((TARGET_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# Every group is wholly at one generation or the other. The transaction already
# guarantees that -- any pre-COMMITTED failure returns every row to baseline --
# so this is the statement of what would be wrong if it ever did not, named per
# group so the diagnostic says which capability is split.
require_group_coherence() {
  local group row target state split=0 at_baseline at_target
  for group in $(matrix_groups); do
    at_baseline=0; at_target=0
    for row in "${MATRIX[@]}"; do
      [[ "$(field "${row}" 6)" == "${group}" ]] || continue
      target="$(field "${row}" 1)"
      state="$(classify "${target}" "$(field "${row}" 4)" "$(field "${row}" 5)")"
      case "${state}" in
        BASELINE) at_baseline=$((at_baseline + 1)) ;;
        TARGET) at_target=$((at_target + 1)) ;;
      esac
    done
    if (( at_baseline > 0 && at_target > 0 )); then
      bad "group ${group} ($(group_name "${group}")) is split: ${at_baseline} object(s) at Generation 14 and ${at_target} at Generation 15"
      split=$((split + 1))
    fi
  done
  (( split == 0 )) \
    && ok "every coherence group is wholly at one generation ($(matrix_groups | tr '\n' ' '))"
  return 0
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)" \
    || halt "the repository at ${REPOSITORY} is not readable as ${REPO_OWNER}"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed Generation-15 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-15 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN14_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-14 authority is not an ancestor of the Generation-15 authority"
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
  ok "repository at ${BRANCH}, reviewed authority ${COMMIT} present and an ancestor of HEAD"
}

require_source_digests() {
  local row source wanted blob worktree drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; wanted="$(field "${row}" 5)"
    if ! git_as_owner cat-file -e "${COMMIT}:${source}" 2>/dev/null; then
      bad "${source} is not present at the reviewed commit ${COMMIT}"
      drift=$((drift + 1)); continue
    fi
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${wanted}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${wanted}"; drift=$((drift + 1)); }
    worktree="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${worktree}" == "${wanted}" ]] \
      || note "${source} in the working tree is ${worktree:-absent}; the ceremony installs the commit object, not this"
  done
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-15 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-15 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
}

# --- the closed closure ----------------------------------------------------
#
# The roots the installed runtime is actually entered through. `kyri_exec_worker`
# is here because the released worker entrypoint is one -- and because it is how
# the Podman backend enters the graph naturally. G11-AT found two modules that
# entered only by accident of how they were imported and fixed both at the
# source; nothing is whitelisted into this surface.
CLOSURE_ROOTS=(
"tools.capability.cli"
"tools.capability.execution.worker"
"kyri_exec_worker"
"kyri_exec_transition"
"kyri_exec_transition_action"
"kyri_exec_verify"
"kyri_exec_quota"
)

require_closed_closure() {
  local staging exported=0
  staging="$(mktemp -d)"
  CLOSURE_STAGING="${staging}"

  git_as_owner archive --format=tar "${COMMIT}" tools provisioning/execution \
    | tar -x -C "${staging}" \
    || halt "could not materialise the reviewed tree from ${COMMIT}"
  local helper flattened
  for helper in quota transition transition-action verify worker podman launcher; do
    flattened="kyri_exec_${helper//-/_}"
    [[ -f "${staging}/provisioning/execution/kyri-exec-${helper}.py" ]] \
      || halt "the reviewed commit carries no kyri-exec-${helper}.py"
    cp "${staging}/provisioning/execution/kyri-exec-${helper}.py" \
       "${staging}/${flattened}.py" \
      || halt "could not flatten kyri-exec-${helper}.py"
  done
  exported="$(find "${staging}/tools" -type f -name '*.py' | wc -l)"
  (( exported > 0 )) || halt "the reviewed commit exposes no tools sources"

  local root_args=() root
  for root in "${CLOSURE_ROOTS[@]}"; do root_args+=(--root "${root}"); done

  local computed
  computed="$(python3 "${REPOSITORY}/tools/dev/runtime_closure.py" \
    --source-root "${staging}" "${root_args[@]}" --format files | sort)" \
    || halt "the import closure could not be computed"

  # Declared: every matrix row, plus what is already installed, plus the entry
  # points whose objects live outside the library root. The third set is stated
  # as data rather than assumed: an entry root's own file does not have to be a
  # library module, but it does have to exist somewhere, and the ceremony that
  # installs it is named.
  # The closure names installed-tree paths, and so must the declared set. A
  # matrix row's SOURCE is a repository path -- `provisioning/execution/
  # kyri-exec-podman.py` -- while the object it becomes is `kyri_exec_podman.py`
  # in the library root. Comparing the wrong one would make every flattened row
  # look undeclared.
  local declared="" row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    declared+="${target#"${LIBRARY_ROOT}"/}"$'\n'
  done

  # What the predecessor provides, decided from the reviewed Generation-14
  # AUTHORITY rather than from the host. `--verify-source` answers "is this
  # package sound?" before anything is installed, so a gate that consulted the
  # library root would be answering a different question -- and would report a
  # sound package as broken when run against an empty fixture, which is exactly
  # what it did the first time this was written.
  local carried="" entry candidate source
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    # The flattened privileged modules live under provisioning/execution in the
    # repository and at the library root once installed. The mapping is the same
    # data `runtime_closure.py` carries, restated here because this side has to
    # go the other way.
    case "${candidate}" in
      kyri_exec_*.py)
        source="provisioning/execution/$(printf '%s' "${candidate%.py}" | tr '_' '-').py"
        ;;
      *) source="${candidate}" ;;
    esac
    if git_as_owner cat-file -e "${GEN14_COMMIT}:${source}" 2>/dev/null; then
      carried+="${candidate}"$'\n'
    fi
  done < <(printf '%s\n' "${computed}")

  local entrypoints=""
  for entry in "${ENTRYPOINT_OBJECTS[@]}"; do
    entrypoints+="$(field "${entry}" 0)"$'\n'
  done

  local missing
  missing="$(comm -23 <(printf '%s\n' "${computed}") \
                      <(printf '%s\n%s\n%s\n' "${declared}" "${carried}" \
                        "${entrypoints}" | grep -v '^$' | sort -u))"
  if [[ -n "${missing}" ]]; then
    printf 'STOP: the import closure needs objects neither this generation nor its predecessor provides:\n' >&2
    printf '%s\n' "${missing}" | sed 's/^/  /' >&2
    halt "the declared surface does not close the import graph"
  fi

  # Surplus is a matrix row the closure does not require. Every one must be
  # named in OUTSIDE_EXECUTION_CLOSURE with its reason; an unnamed one still
  # halts, which is what keeps this a declaration rather than a hole.
  local surplus unexplained="" candidate
  surplus="$(comm -13 <(printf '%s\n' "${computed}") \
                      <(printf '%s\n' "${declared}" | grep -v '^$' | sort -u))"
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    if declared_outside_closure "${candidate}"; then
      note "governed outside the execution closure by declaration: ${candidate}"
    else
      unexplained+="${candidate}"$'\n'
    fi
  done < <(printf '%s\n' "${surplus}")
  surplus="$(printf '%s' "${unexplained}")"
  if [[ -n "${surplus}" ]]; then
    printf 'STOP: the matrix declares objects the import closure does not require:\n' >&2
    printf '%s\n' "${surplus}" | sed 's/^/  /' >&2
    halt "the declared surface exceeds the import closure"
  fi

  rm -rf "${staging}"; CLOSURE_STAGING=""
  ok "the import closure of $(printf '%s ' "${CLOSURE_ROOTS[@]}")closes over the declared surface ($(printf '%s\n' "${computed}" | wc -l) modules)"
}


# THE LIBRARY ROOT HOLDS TWO KINDS OF OBJECT, and only one of them is this
# generation's. `/usr/lib/kyri/python` carries the runtime objects AND the
# flattened privileged helper modules beside them. The G11-AX helper ceremony
# creates one of those, so once it has run the file count there is legitimately
# one higher while every runtime object is byte-identical.
#
# A flat count was right before that ceremony and wrong after it, which
# G11-AX.2 recorded as a follow-up before it happened. The expectation is stated
# as the runtime objects plus however many of the helper ceremony's own
# library-root CREATE targets are published, read from that ceremony's matrix.
helper_ceremony_library_creates() {
  local ceremony="${REPOSITORY}/provisioning/execution/install-g11-ax-helpers.sh"
  local present=0 line target operation
  # The matrix stores this token unexpanded, so the literal is the point.
  # shellcheck disable=SC2016  # intentional: the placeholder must not expand
  local _PLACEHOLDER='${LIBRARY_ROOT}/'
  [[ -f "${ceremony}" ]] || { printf '0'; return; }
  while IFS= read -r line; do
    line="${line#\"}"; line="${line%\"}"
    IFS='|' read -r _ target _ operation _ _ _ <<<"${line}"
    [[ "${operation}" == "CREATE" ]] || continue
    [[ "${target}" == *"${_PLACEHOLDER}"* ]] || continue
    target="${LIBRARY_ROOT}/${target##*"${_PLACEHOLDER}"}"
    [[ -f "${target}" ]] && present=$((present + 1))
  done < <(sed -n '/^MATRIX=(/,/^)/p' "${ceremony}" | sed -n 's/^\(".*"\)$/\1/p')
  printf '%s' "${present}"
}

# --- generation-14 baseline -------------------------------------------------
require_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  local helpers_present expected_baseline
  helpers_present="$(helper_ceremony_library_creates)"
  expected_baseline=$((EXPECTED_LIBRARY_FILES_BASELINE + helpers_present))
  [[ "${count}" -eq "${expected_baseline}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-14 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-14 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-14 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-14 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "installed ${relative} is ${observed}, evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-14 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-14 baseline"
  ok "the installed runtime is exactly the accepted Generation-14 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-14 baseline nor the Generation-15 target"
    done
    halt "a target is in an unruled state and requires operator disposition"
  fi
}

require_no_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    if [[ -e "${target}${PREPARED_SUFFIX}" ]]; then
      bad "residue at ${target}${PREPARED_SUFFIX}"; extra=$((extra + 1))
    fi
    if [[ -e "${target}${BACKUP_SUFFIX}" ]]; then
      bad "residue at ${target}${BACKUP_SUFFIX}"; extra=$((extra + 1))
    fi
  done
  (( extra == 0 )) || halt "transaction residue exists; resolve it before installing"
  ok "no transaction residue at any of the $(matrix_count) target pathnames"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 15 is installed and unaffected. Remove them with --recover or by hand."
  fi
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: the launch grant is installed"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: the verification grant is installed"
  [[ ! -e "${RECONCILE_SUDOERS}" ]] || halt "${RECONCILE_SUDOERS} exists: the reconcile grant is installed"
  ok "no sudoers grant exists: every elevation gate stays closed"
}

# The privileged surface, fingerprinted before and after. This ceremony installs
# a runtime; a helper, a grant or a deployment identity that changed while it
# ran changed for some other reason, and an operator needs to know that.
privileged_fingerprint() {
  local path state=''
  for path in "${EXCLUDED_PRIVILEGED[@]}" "${COORDINATOR_IDENTITY}" \
              "${EXECUTION_IDENTITY}" "${SUDOERS}" "${VERIFY_SUDOERS}" \
              "${RECONCILE_SUDOERS}"; do
    if [[ -f "${path}" ]]; then
      state+="${path}:$(digest_of "${path}") "
    elif [[ -e "${path}" ]]; then
      state+="${path}:present-not-regular "
    else
      state+="${path}:absent "
    fi
  done
  local helper
  for helper in "${EXCLUDED_HELPER_LIBRARY[@]}"; do
    if [[ -f "${LIBRARY_ROOT}/${helper}" ]]; then
      state+="${helper}:$(digest_of "${LIBRARY_ROOT}/${helper}") "
    else
      state+="${helper}:absent "
    fi
  done
  printf '%s' "${state}"
}

authority_fingerprint() {
  local path state=''
  for path in "${AUTHORITY_ROOT}" "${CONTROL_ROOT}"; do
    if [[ -e "${path}" ]]; then
      state+="${path}:$(find "${path}" -printf '%p %s %m\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1) "
    else
      state+="${path}:absent "
    fi
  done
  printf '%s' "${state}"
}

# No matrix row may name a privileged object. Checked structurally rather than
# trusted, because "the runtime installer does not touch the helper" is the kind
# of claim that should not depend on nobody having added a row.
require_privileged_surface_excluded() {
  local row target excluded helper collision=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    for excluded in "${EXCLUDED_PRIVILEGED[@]}" "${COORDINATOR_IDENTITY}" \
                    "${EXECUTION_IDENTITY}" "${SUDOERS}" "${VERIFY_SUDOERS}" \
                    "${RECONCILE_SUDOERS}"; do
      [[ "${target}" == "${excluded}" ]] \
        && { bad "the matrix declares the privileged object ${target}"; collision=$((collision + 1)); }
    done
    for helper in "${EXCLUDED_HELPER_LIBRARY[@]}"; do
      [[ "${target}" == "${LIBRARY_ROOT}/${helper}" ]] \
        && { bad "the matrix declares the helper-ceremony object ${helper}"; collision=$((collision + 1)); }
    done
  done
  (( collision == 0 )) \
    && ok "no matrix row names a helper, a grant or a deployment identity: $(( ${#EXCLUDED_PRIVILEGED[@]} + ${#EXCLUDED_HELPER_LIBRARY[@]} + 5 )) privileged objects are outside this ceremony"
}

# Installable is not execution-ready, and an operator sizing up this
# transaction needs both facts stated separately. Nothing here is required to
# INSTALL a runtime: the runtime imports fine without either authority, because
# both are read at execution time and refused there. What a host missing them
# cannot do is execute, and saying so here is the difference between a truthful
# report and one an operator would read as a blocker.
report_execution_readiness() {
  local ready=1
  if [[ ! -f "${COORDINATOR_IDENTITY}" ]]; then
    note "the coordinator identity authority is not installed; Generation 15 installs without it"
    ready=0
  fi
  if [[ ! -f "${EXECUTION_IDENTITY}" ]]; then
    note "the execution identity authority is not installed; Generation 15 installs without it"
    ready=0
  fi
  if (( ready == 1 )); then
    note "both deployment identity authorities are installed"
  else
    note "this host will be at Generation 15 and NOT execution-ready: the deployment identity and helper ceremonies come after, and the runtime refuses execution until they do"
  fi
}

# Where the entry points are, reported by the host modes only. `--verify-source`
# reasons about the package and reads no installed path at all; asking this
# there would have made that claim false for a note nobody needed yet.
report_entrypoints() {
  local entry where
  for entry in "${ENTRYPOINT_OBJECTS[@]}"; do
    where="$(field "${entry}" 1)"
    if [[ -f "${where}" ]]; then
      note "the entry point $(field "${entry}" 0) is installed at ${where} by the helper ceremony"
    else
      note "the entry point $(field "${entry}" 0) is not installed at ${where}; the helper ceremony installs it, not this one"
    fi
  done
}

require_same_filesystem() {
  local row target prepared directory library_device probe
  [[ -d "${LIBRARY_ROOT}" ]] \
    || halt "${LIBRARY_ROOT} does not exist: there is nowhere to install"
  library_device="$(stat -c '%d' "${LIBRARY_ROOT}")"
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    directory="$(dirname "${target}")"
    [[ "${directory}" == "$(dirname "${prepared}")" ]] \
      || halt "${target} does not stage beside itself"
    probe="${directory}"
    while [[ ! -d "${probe}" && "${probe}" != "/" ]]; do probe="$(dirname "${probe}")"; done
    [[ -d "${probe}" ]] \
      || halt "no existing ancestor of ${directory} could be found"
    [[ "$(stat -c '%d' "${probe}")" == "${library_device}" ]] \
      || halt "${target} would publish across a filesystem boundary (${probe} is not on the library root's device)"
  done
  ok "every target stages beside itself on the library root's filesystem, so publication is a rename ($(matrix_count) objects across $(for row in "${MATRIX[@]}"; do dirname "$(field "${row}" 1)"; done | sort -u | wc -l) directories)"
}

# --- PREPARE ---------------------------------------------------------------
prepare() {
  local row source target mode operation wanted prepared observed
  PREPARING=1

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
        || halt "${target} is ${observed}, not the declared baseline this REPLACE expects"
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
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${wanted}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${wanted}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
    injected_at staged && halt "injected failure after staging a Generation-15 object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  PREPARING=0
  local staged_n created_n replaced_n
  staged_n="$(matrix_count)"; created_n="$(matrix_count_of CREATE)"
  replaced_n="$(matrix_count_of REPLACE)"
  ok "PREPARE complete: ${staged_n} $(plural "${staged_n}" object objects) staged, ${created_n} $(plural "${created_n}" pathname pathnames) reserved, ${replaced_n} $(plural "${replaced_n}" predecessor predecessors) retained"
}

verify_prepared_set() {
  local row target wanted
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; wanted="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${wanted}" ]] \
      || halt "prepared object for ${target} does not verify"
  done
  local n; n="$(matrix_count)"
  ok "all ${n} prepared objects verify against the reviewed commit"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode baseline wanted prepared index=0 observed owner_now
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN15_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    if [[ "$(classify "${target}" "${baseline}" "${wanted}")" == "TARGET" ]]; then
      PROGRESS["${index}"]="TARGET"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING
    if injected_at publish; then
      rollback "injected failure immediately before publication"
      return 1
    fi

    mv -f "${prepared}" "${target}"
    sync_path "${target}"

    if injected_at verify; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "injected failure during post-publication verification"
      return 1
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${wanted}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${wanted}"
      return 1
    fi
    if [[ "$(stat -c '%a' "${target}")" != "${mode#0}" ]]; then
      PROGRESS["${index}"]="MODE_FAILED"
      journal_write COMMITTING
      rollback "target ${target} has the wrong mode after publication"
      return 1
    fi
    if [[ -z "${FIXTURE}" ]]; then
      owner_now="$(stat -c '%U:%G' "${target}")"
      if [[ "${owner_now}" != "root:root" ]]; then
        PROGRESS["${index}"]="OWNER_FAILED"
        journal_write COMMITTING
        rollback "target ${target} is ${owner_now} after publication"
        return 1
      fi
    fi

    PROGRESS["${index}"]="TARGET"
    journal_write COMMITTING
  done

  if injected_at precommit; then
    rollback "injected failure immediately before the durable commit point"
    return 1
  fi

  # THE COMMIT POINT. Everything after this line is bookkeeping, and no failure
  # in it may revert the generation. It is reached only once every one of the
  # twenty-one targets has published AND verified -- not on a count, and not on
  # the journal's own say-so.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; Generation 15 stands"
  OUTCOME="COMMITTED"
  local published_n replaced_n created_n
  published_n="$(matrix_count)"
  replaced_n="$(matrix_count_of REPLACE)"; created_n="$(matrix_count_of CREATE)"
  ok "COMMIT complete: ${published_n} $(plural "${published_n}" object objects) published and verified (${replaced_n} replaced, ${created_n} created)"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target operation wanted observed removed=0

  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    wanted="$(field "${row}" 5)"

    if [[ "${operation}" == "REPLACE" ]]; then
      if [[ -f "${target}${BACKUP_SUFFIX}" && ! -L "${target}${BACKUP_SUFFIX}" ]]; then
        if [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" != "$(field "${row}" 4)" ]]; then
          bad "the retained predecessor for ${target} is not the declared baseline; NOT restoring it"
          continue
        fi
        mv -f "${target}${BACKUP_SUFFIX}" "${target}"
        sync_path "${target}"
        removed=$((removed + 1))
      elif [[ "$(digest_of "${target}")" != "$(field "${row}" 4)" ]]; then
        bad "${target} is neither the declared baseline nor restorable from a retained predecessor"
      fi
      continue
    fi
    [[ "${operation}" == "CREATE" ]] || { bad "${target} is ${operation}; this transaction cannot roll that back"; continue; }

    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
      continue
    fi
    if [[ -L "${target}" || ! -f "${target}" ]]; then
      bad "${target} is not the regular file this transaction created; NOT removing it"
      continue
    fi
    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${wanted}" ]]; then
      bad "${target} is ${observed}, not the object this transaction installed; NOT removing it"
      continue
    fi
    rm -f "${target}"
    sync_path "${target}"
    removed=$((removed + 1))
  done

  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done

  classify_all
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    local rolled_n
    rolled_n="$(matrix_count)"
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 14 (${removed} restored or removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: BASELINE=${BASELINE_COUNT} TARGET=${TARGET_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: BASELINE=%d TARGET=%d UNKNOWN=%d (of %d targets)\n' \
    "${state}" "${BASELINE_COUNT}" "${TARGET_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither the Generation-14 baseline nor the Generation-15 target, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-15 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-15 object was published; the host is at Generation 14"
    return 0
  fi

  # Mixed. A mixed host is by definition a split generation, so the direction is
  # decided from what can be PROVED rather than from which side has more rows:
  # forward only if every unpublished object's prepared bytes verify.
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
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" && -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "Generation-14 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-15 evidence; Generation 15 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN15_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN15_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN15_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-15 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN14_COMMIT}"
    printf 'predecessor generation 14\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    printf 'state COMMITTED\n'
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)" "$(field "${row}" 6)"
    done
    local excluded
    for excluded in "${EXCLUDED[@]}"; do
      printf 'excluded %s\n' "${excluded}"
    done
    for excluded in "${EXCLUDED_HELPER_LIBRARY[@]}"; do
      printf 'helper_ceremony %s\n' "${excluded}"
    done
    # What this runtime expects the rest of the deployment to be. Recorded here
    # rather than in a new authority plane: the evidence file is where a
    # generation already states what it installed, and "what it needs beside it"
    # belongs with that. Nothing reads it at execution time -- the runtime asks
    # `helpers.compatibility()` and the supervised preflight, both of which
    # decide from installed bytes -- so this is the auditable record of the same
    # expectation, written once, at the moment it became true.
    printf 'expects_coordinator_identity %s\n' "/etc/kyri/coordinator-identity.json"
    printf 'expects_execution_identity %s\n' "/etc/kyri/execution-identity.json"
    expected_helpers || halt "the installed runtime declares no helper expectation"
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN15_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN15_LIBRARY_EVIDENCE}.writing" "${GEN15_HELPER_EVIDENCE}.writing"
  sync_path "${GEN15_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN15_HELPER_EVIDENCE}.writing"
  mv -f "${GEN15_LIBRARY_EVIDENCE}.writing" "${GEN15_LIBRARY_EVIDENCE}"
  mv -f "${GEN15_HELPER_EVIDENCE}.writing" "${GEN15_HELPER_EVIDENCE}"
  sync_path "${GEN15_LIBRARY_EVIDENCE}"
  sync_path "${GEN15_HELPER_EVIDENCE}"
  ok "Generation-15 evidence written; Generation-14 evidence preserved"
}

# The privileged bytes the installed runtime was built against, read out of
# the runtime's own declaration rather than restated here. Two copies of a
# compatibility expectation would be two things to keep true, and the one
# that decides is the module -- so this reads that module and records what
# it says.
expected_helpers() {
  python3 - "${LIBRARY_ROOT}" <<'EXPECTPY'
import sys
sys.path.insert(0, sys.argv[1])
try:
    from tools.capability.execution import helpers
except ImportError as error:
    print(f"expects_helper UNAVAILABLE {error}")
    raise SystemExit(1)
for helper in helpers.REQUIRED_HELPERS:
    print(f"expects_helper {helper.path} {helper.digest}")
EXPECTPY
}

cleanup_transaction_artifacts() {
  local row target
  if injected_at cleanup; then
    bad "injected cleanup failure after COMMITTED; Generation 15 remains installed"
    return 0
  fi
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done
  ok "transaction artefacts removed"
}

# --- installed-set verification --------------------------------------------
verify_installed_set() {
  local row source target wanted observed blob mode
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
  done
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  local helpers_present expected_target
  helpers_present="$(helper_ceremony_library_creates)"
  expected_target=$((EXPECTED_LIBRARY_FILES_TARGET + helpers_present))
  [[ "${count}" -eq "${expected_target}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-15 ${EXPECTED_LIBRARY_FILES_TARGET} plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) Generation-15 changed objects correspond to the reviewed commit ${COMMIT}"
}

verify_excluded_absent() {
  local excluded present=0
  for excluded in "${EXCLUDED[@]}"; do
    if [[ -e "${LIBRARY_ROOT}/${excluded}" || -L "${LIBRARY_ROOT}/${excluded}" ]]; then
      bad "the excluded module ${excluded} is present in the installed runtime"
      present=$((present + 1))
    fi
  done
  (( present == 0 )) \
    && ok "the governed write path and every Trust decision surface are absent"
}

# Every object the Generation-14 evidence recorded must still be exactly what
# that evidence says, except the rows this transaction declares. A CREATE adds
# pathnames, so the created targets are legitimately absent from the predecessor
# evidence and are the only objects permitted to be.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is not accounted for by the Generation-14 evidence and is not a declared Generation-15 target"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-14 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-14 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every carried-over runtime object is exactly its accepted Generation-14 baseline, and nothing was removed"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify-source)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded

  # The two capabilities this generation exists to deploy, proved present in the
  # reviewed source rather than assumed from a commit message.
  supervision_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/supervision.py")" \
    || halt "the reviewed commit carries no supervision.py"
  for marker in "ExecutionSupervisor" "SupervisedBinding" "_dispose" \
                "ProtocolEnded" "disposal_proven"; do
    grep -q -- "${marker}" <<<"${supervision_source}" \
      || halt "the reviewed supervision.py does not carry the G11-AT element ${marker}"
  done
  ok "the reviewed source carries the G11-AT coordinator supervision path"

  recovery_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/recovery.py")" \
    || halt "the reviewed commit carries no recovery.py"
  for marker in "unresolved_invocations" "reconcile_unresolved" \
                "execution_safety" "adapter_identity"; do
    grep -q -- "${marker}" <<<"${recovery_source}" \
      || halt "the reviewed recovery.py does not carry the G11-AT element ${marker}"
  done
  ok "the reviewed source carries the G11-AT interrupted-execution recovery"

  note "no installed path was read for state and none was written"
  printf '\n'
  printf 'Generation 15 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded

  classify_all
  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 15; use --verify-installed to audit the installed generation"
    require_gates_closed
    verify_excluded_absent
    require_group_coherence
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 15 / supervised execution runtime verify: already installed.\n'
    exit 0
  fi

  require_baseline
  require_target_state
  require_no_transaction_residue
  require_gates_closed
  require_same_filesystem
  verify_excluded_absent
  require_group_coherence
  report_entrypoints

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  report_execution_readiness

  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 14 and ready for the Generation-15 installation: $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE, $(matrix_count) changed objects across $(matrix_groups | wc -l) coherence groups, object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
  else
    bad "mixed target state: baseline=${BASELINE_COUNT} target=${TARGET_COUNT} unknown=${UNKNOWN_COUNT}"
  fi
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--install)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded
  require_gates_closed

  TRANSACTION_ID="gen15-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  AUTHORITY_BEFORE="$(authority_fingerprint)"
  PRIVILEGED_BEFORE="$(privileged_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 15 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 15 is already installed: nothing to do"
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
    verify_excluded_absent
    verify_unchanged_surface
    require_group_coherence
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    require_group_coherence
    bad "the transaction rolled back: the host is at Generation 14 and nothing was installed"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${AUTHORITY_BEFORE}" == "$(authority_fingerprint)" ]] \
    || bad "the implementation-authority namespace changed during installation"
  [[ "${PRIVILEGED_BEFORE}" == "$(privileged_fingerprint)" ]] \
    || bad "a helper, a grant or a deployment identity changed during installation"
  ;;

--verify-installed)
  require_repository
  verify_installed_set
  verify_excluded_absent
  verify_unchanged_surface
  require_group_coherence
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"
  [[ -f "${GEN15_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-15 library evidence is missing"
  [[ -f "${GEN15_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-15 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-14 evidence was not preserved"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-14 helper evidence was not preserved"
  report_transaction_residue
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--recover)
  require_repository
  require_source_digests
  TRANSACTION_ID="$(journal_transaction)"
  state="$(journal_state)"
  [[ "${state}" == "NONE" ]] && halt "there is no transaction to recover"
  recover "${state}" || true
  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
    require_group_coherence
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    require_group_coherence
    bad "recovery rolled the transaction back: the host is at Generation 14 and Generation 15 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 15 / supervised execution runtime %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 15 / supervised execution runtime %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
