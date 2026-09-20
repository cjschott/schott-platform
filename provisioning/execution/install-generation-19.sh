#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 19: governed administrative abandonment, deployed.
#
# WHAT THIS DEPLOYS. SEVEN objects, in ONE coherence group:
#
#   B  governed administrative abandonment (ADR-0015). `types.py` adds the
#      ABANDONED lifecycle member; `state.py` adds the two edges into it and
#      none out; `capacity.py` restates occupancy as an exclusion so ABANDONED
#      holds no slot; `recovery.py` classifies it as administratively closed;
#      `admin.py` adds the closed-set `abandon` verb; `abandonment.py` is the
#      operation; `cli.py` carries the operator surface.
#
# WHAT WENT WRONG. An invocation that reached `launch_authorized` and never went
# further held an execution slot for ever. `released` is reachable only from
# `cleaned`, `recover` writes nothing, no administrative verb repairs or forces,
# and `execute` refuses an invocation that already has a terminal result.
# CINV-000001 and CINV-000002 held both slots between them, and CINV-000003
# Stage 2 refused with `CapacityExhausted` before mutating anything. G11-BC-U
# found it; G11-BC-V is the correction and ADR-0015 is its architecture.
#
# MAXIMUM_SLOTS IS NOT CHANGED, and stays 2. The ceiling was never the defect --
# it did exactly what it is for. The defect was that a slot could never be
# given back.
#
# WHY THIS GENERATION EXISTS AT ALL, AND WHY IT COMES FIRST. G11-BC-V prepared a
# CINV-000002 reclamation ceremony that ran the coordinator CLI out of the
# checkout. That would have written an ABANDONED lifecycle record into the
# production runtime while the INSTALLED runtime was still Generation 18 --
# which cannot parse it:
#
#     StateIntegrityFailure: CINV-000002.000003 names an unknown state
#
# And `all_states` resolves every chain inside ONE comprehension, so that single
# unreadable record would raise out of `capacity.reserve`, `recovery` and
# `cleanup` for the WHOLE store, not just for CINV-000002. The installed
# execution plane would have stopped working entirely. The reviewer refused the
# ceremony on runtime-generation coherence; this installer is what has to
# happen first.
#
# WHY THESE SEVEN ARE ONE GROUP. Every one of them is reachable from
# `tools.capability.cli`, and no subset is a valid complete Generation 19:
# `state.py` at 19 against `types.py` at 18 names a target state the vocabulary
# has never heard of; `cli.py` at 19 against `abandonment.py` absent is a
# ModuleNotFoundError on every command; `abandonment.py` at 19 against
# `capacity.py` at 18 would close an invocation that still holds its slot, which
# is the defect this generation exists to remove, made durable.
# `require_group_coherence` refuses any committed state holding some at each
# generation.
#
# PUBLICATION ORDER IS THE SAFETY PROPERTY, AND IT IS DERIVED, NOT INHERITED.
# Generation 18's order came from an import edge between two objects; that
# reasoning does not transfer to seven. Each object here is published only after
# everything it imports, and every intermediate was MEASURED by importing
# `tools.capability.cli` against it:
#
#   published so far          tools.capability.cli   abandon verb reachable
#   ------------------------  ---------------------  ----------------------
#   (Generation 18)           imports                no
#   + types                   imports                no
#   + state                   imports                no
#   + capacity                imports                no
#   + recovery                imports                no
#   + admin                   imports                no
#   + abandonment             imports                no
#   + cli  (Generation 19)    imports                YES
#
# EVERY INTERMEDIATE IS STRICTLY SAFER THAN THE ACCEPTED GENERATION-18
# BASELINE, and the reason is stronger than "the CLI still imports": the verb
# appears only at the last step, and `abandonment.abandon` is unreachable
# without it, so NO INTERMEDIATE CAN WRITE AN ABANDONED RECORD. A
# Generation-18 reader is therefore never shown a state it cannot parse, at any
# point during the publication.
#
# The reverse order was measured too. `cli.py` first yields
# `ModuleNotFoundError: No module named 'tools.capability.execution.abandonment'`
# on every command -- including `recover`, the one an operator needs to resolve
# an interrupted transaction. That is fail-closed for the recovery surface,
# which is worse, not better.
#
# So: `types.py` FIRST and `cli.py` LAST. `require_fail_closed_first` holds the
# whole order as a checked property rather than the two ends only, and
# `rollback` restores in reverse -- `cli.py` back first -- so the
# ModuleNotFoundError state is unreachable from either direction.
#
# ONE OBJECT IS A CREATE. `abandonment.py` does not exist at Generation 18, so
# the installed library grows from 80 objects to 81 (plus the one published
# helper module, as at Generation 18). Both counts are stated, and rollback
# deletes the created file rather than restoring a backup that never existed.
#
# EXECUTION STAYS OPEN THROUGH THIS GENERATION, DELIBERATELY. No readiness
# authority moves: `helpers.py` is untouched, compatibility stays `compatible`,
# blocking stays 0 and supervision_ready stays true at every state. There is
# nothing to reopen and no helper ceremony to follow.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. No helper object, no entrypoint, no
# worker, no quota module, no readiness authority, no container-runtime binding,
# no sudoers grant, no execution image, no deployment identity authority, and
# not one byte of Fabric, Trust, or invocation history. No lifecycle record is
# written, no invocation is abandoned, and no execution slot changes hands --
# this publishes the ability to do that, under a separate reviewed ceremony,
# and does none of it.
#
# WHAT IT DOES NOT TOUCH IN THE RUNTIME STORE. CINV-000001, CINV-000002 and
# CINV-000003 are not read, not written and not referenced. CRES-000001 is
# final and is not touched. Occupancy stays 2 of 2 across this publication.
#
COMMIT="5ab509125963c2b8862815aba6f6ee6b878d0d92"

# The accepted Generation-18 source authority, and the baseline this transaction
# requires the host to be at.
GEN18_COMMIT="88a1e484f063ad0c4bb5d05ddac6de2df623491c"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# This transaction's own namespace. Generation 18's retained journal at
# /root/kyri-gen18-transaction is predecessor evidence: it records how the host
# reached the state this transaction starts from, it is never read as this
# transaction's state, and nothing here writes to or removes it. Deriving an
# installer from its predecessor and leaving the predecessor's path in place is
# what made the first real Generation-14 attempt halt against a COMMITTED
# journal belonging to a transaction that had already finished.
TRANSACTION_ROOT="/root/kyri-gen19-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen18-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen18-helper-digests.txt"
GEN19_LIBRARY_EVIDENCE="/root/kyri-gen19-library-digests.txt"
GEN19_HELPER_EVIDENCE="/root/kyri-gen19-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS="/etc/sudoers.d/kyri-exec-launch"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# The two deployment identity authorities. Read to prove this ceremony did not
# create them; never written. Generation 18 does not need them to install.
COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# No CREATE, so the count does not move. Both ends are stated ANYWAY and are
# deliberately equal: a matrix that quietly grew a CREATE row would change the
# installed object count, and stating the expectation on both sides is what
# turns that into a refusal here rather than a surprise at publication.
EXPECTED_LIBRARY_FILES_BASELINE=80
EXPECTED_LIBRARY_FILES_TARGET=81

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
  GEN19_LIBRARY_EVIDENCE="${FIXTURE}${GEN19_LIBRARY_EVIDENCE}"
  GEN19_HELPER_EVIDENCE="${FIXTURE}${GEN19_HELPER_EVIDENCE}"
  SUDOERS_DIR="${FIXTURE}${SUDOERS_DIR}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  RECONCILE_SUDOERS="${FIXTURE}${RECONCILE_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
  COORDINATOR_IDENTITY="${FIXTURE}${COORDINATOR_IDENTITY}"
  EXECUTION_IDENTITY="${FIXTURE}${EXECUTION_IDENTITY}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen19.new"
BACKUP_SUFFIX=".kyri-gen19.gen18"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

CLOSURE_STAGING=""
PREPARING=0

# --- the seven generation-19 objects, pinned both ways ---------------------
#
# source | target | mode | operation | gen18-sha256 | gen19-sha256 | group
#
# Six targets sit in directories that already exist at Generation 18. The
# seventh, `abandonment.py`, is a CREATE into an existing directory, so there is
# still no directory to make and none to remove on rollback -- rollback deletes
# the created file.
#
# THE ONE GROUP, AND WHY IT IS ONE.
#
#   B  governed administrative abandonment (ADR-0015). `types.py` owns the
#      ABANDONED member; `state.py` owns the two edges into it and none out;
#      `capacity.py` owns the occupancy exclusion that makes it hold no slot;
#      `recovery.py` owns its classification as administratively closed;
#      `admin.py` owns the closed-set verb; `abandonment.py` is the operation;
#      `cli.py` is the only operator surface that can reach it.
#
#      No member is a valid complete Generation 19 on its own. `state.py` at 19
#      against `types.py` at 18 names a target state the vocabulary has never
#      heard of. `cli.py` at 19 against `abandonment.py` absent is a
#      ModuleNotFoundError on every command. And `abandonment.py` at 19 against
#      `capacity.py` at 18 would close an invocation that still holds its slot,
#      which is the defect this generation exists to remove, made durable.
#
# THE LETTER. B for abandonment, and it is unused across Generations 13 to 18.
#
# There is no CARRYOVER: every member of B is a row here.
#
# source | target | mode | operation | gen18-sha256 | gen19-sha256 | group
MATRIX=(
# --- B: governed administrative abandonment. THE ORDER IS DEPENDENCY-SAFE AND
#        IT WAS MEASURED, NOT INHERITED. Each object is published only after
#        everything it imports, and every intermediate was run:
#
#          published so far          tools.capability.cli   abandon verb
#          ------------------------  ---------------------  ------------
#          (Generation 18)           imports                no
#          + types                   imports                no
#          + state                   imports                no
#          + capacity                imports                no
#          + recovery                imports                no
#          + admin                   imports                no
#          + abandonment             imports                no
#          + cli  (Generation 19)    imports                YES
#
#        NO INTERMEDIATE CAN WRITE AN ABANDONED RECORD. The verb appears only
#        at the last step, and `abandonment.abandon` is unreachable without it,
#        so no Generation-18 reader is ever shown a state it cannot parse.
#        That matters more here than in any previous generation: `all_states`
#        resolves every chain in one comprehension, so ONE unreadable record
#        would raise out of capacity, recovery and cleanup for the WHOLE store,
#        not merely for the invocation that carries it.
#
#        The reverse order was measured too: `cli.py` first yields
#        `ModuleNotFoundError: No module named
#        'tools.capability.execution.abandonment'` on every command, including
#        `recover` -- the one an operator needs to resolve an interrupted
#        transaction. Fail-closed for the recovery surface is worse, not better.
"tools/capability/execution/types.py|${LIBRARY_ROOT}/tools/capability/execution/types.py|0444|REPLACE|7dc35046fafdb4e7218739cdbc86deff18ed804b2a37d66a173df58016258b5c|da2e01f9f13a9b8dfbf736f7b66839cf2e688e350d8f0515340fd051e98e66ae|B"
"tools/capability/execution/state.py|${LIBRARY_ROOT}/tools/capability/execution/state.py|0444|REPLACE|f0b00112db5090f1885149e4eaee0df79ef03fa3c72a5b618d51cf9263486241|88b05c076d9da134ddb1dfe38c38624297246cd313e243b540eaff7af1901f3b|B"
"tools/capability/execution/capacity.py|${LIBRARY_ROOT}/tools/capability/execution/capacity.py|0444|REPLACE|25bab08cd2f517e28d5a9add58a4d0fff6d6d720cd20df241d4a4003eaa27afb|f037119f9a986558fe8e6c8bbc77a4ba49d28d97ddc3d4d5c4328b707757159e|B"
"tools/capability/execution/recovery.py|${LIBRARY_ROOT}/tools/capability/execution/recovery.py|0444|REPLACE|fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0|d044cb29a32714945d0d76db59ca3c44cd77d4978e5781fedc073e675b897173|B"
"tools/capability/execution/admin.py|${LIBRARY_ROOT}/tools/capability/execution/admin.py|0444|REPLACE|be899d7a193f6aa5c80d3887109fa07212d757f94503ba994bac104f217633d5|2dbc29412469a3a7060c133b4673ec3b0c60a2bd283929723fc7182a227b67f3|B"
"tools/capability/execution/abandonment.py|${LIBRARY_ROOT}/tools/capability/execution/abandonment.py|0444|CREATE|ABSENT|4fb431ca5f74e45aba8cb4ed7f80699e9a16b4743b5c554e992747926f9b1903|B"
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1|a350b7884471d57f55826331ea858f1210d2b10bbfb2486b330e8e1a3f0df407|B"
)

# No coherence-group member is left behind by this generation, so this is empty.
# Kept as a declaration rather than deleted: an empty list is a statement that
# the question was asked, and adding an entry later is then a reviewable edit.
CARRYOVER=()

# --- governed objects deliberately outside the execution closure -------------
#
# The closure is computed from the PRODUCTION EXECUTION roots and the surplus
# check refuses any matrix row the closure does not require. Both rows here are
# reached from those roots -- `coordinator.py` from `tools.capability.cli`, and
# `evidence.py` from `coordinator.py` -- so no exception is needed and the list
# stays empty.
OUTSIDE_EXECUTION_CLOSURE=()

declared_outside_closure() {
  local candidate="$1" entry
  for entry in "${OUTSIDE_EXECUTION_CLOSURE[@]}"; do
    [[ "${entry}" == "${candidate}" ]] && return 0
  done
  return 1
}

# Every group Generation 18 named is still spelled here, even though this
# generation only moves R. The names outlive the generation that introduced
# them, and a coherence failure naming "unknown group V" would be a worse
# report than one naming what V is.
group_name() {
  case "$1" in
    V) printf 'the runtime-side verification surface' ;;
    R) printf 'supervised recovery discovery' ;;
    H) printf 'helper declaration and refusal reporting' ;;
    A) printf 'the container-runtime binding' ;;
    T) printf 'the terminal-result authority' ;;
    B) printf 'governed administrative abandonment' ;;
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# EVERY LETTER THE MATRIX CAN CARRY HAS A CASE ABOVE, AND THAT IS CHECKED.
#
# Generation 18 put a row in group A and never added a case for it, so a split
# in that group would have reported "unknown group A" -- the exact failure its
# own comment said the names exist to prevent. A diagnostic defect only, and it
# is in an accepted installer so it is reported rather than edited here; this
# generation simply does not repeat it.
require_group_names_known() {
  local group unnamed=0
  for group in $(matrix_groups); do
    [[ "$(group_name "${group}")" == unknown\ group* ]] || continue
    bad "coherence group ${group} appears in the matrix with no name"
    unnamed=$((unnamed + 1))
  done
  (( unnamed == 0 )) \
    && ok "every coherence group in the matrix has a name ($(matrix_groups | tr '\n' ' '))"
  return 0
}

# The modules that must NOT be installed, carried forward from Generation 19
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
  [[ -n "${FIXTURE}" && "${KYRI_GEN19_FAIL_AT:-}" == "$1" ]]
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 18\n' \
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
    printf 'baseline_commit=%s\n' "${GEN18_COMMIT}"
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
      bad "group ${group} ($(group_name "${group}")) is split: ${at_baseline} object(s) at Generation 19 and ${at_target} at Generation 19"
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
    || halt "the reviewed Generation-19 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-19 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN18_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-18 authority is not an ancestor of the Generation-19 authority"
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
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-19 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-19 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
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

  # What the predecessor provides, decided from the reviewed Generation-18
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
    if git_as_owner cat-file -e "${GEN18_COMMIT}:${source}" 2>/dev/null; then
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
# Generation 18 read only the G11-AX ceremony here, because that was the only
# accepted ceremony with a library-root CREATE at the time. Two are accepted now,
# so this reads the declared ceremony lists instead of naming one. The answer is
# the same -- G11-BB creates no library-root object -- and the difference is that
# it stays the same when a later ceremony does.
helper_ceremony_library_creates() {
  local relative_ceremony ceremony present=0 line target operation
  # The matrix stores this token unexpanded, so the literal is the point.
  # shellcheck disable=SC2016  # intentional: the placeholder must not expand
  local _PLACEHOLDER='${LIBRARY_ROOT}/'
  for relative_ceremony in "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" \
                           ${CEREMONIES_AFTER_THIS_GENERATION[@]+"${CEREMONIES_AFTER_THIS_GENERATION[@]}"}; do
    ceremony="${REPOSITORY}/${relative_ceremony}"
    [[ -f "${ceremony}" ]] || continue
    while IFS= read -r line; do
      line="${line#\"}"; line="${line%\"}"
      IFS='|' read -r _ target _ operation _ _ _ <<<"${line}"
      [[ "${operation}" == "CREATE" ]] || continue
      [[ "${target}" == *"${_PLACEHOLDER}"* ]] || continue
      target="${LIBRARY_ROOT}/${target##*"${_PLACEHOLDER}"}"
      [[ -f "${target}" ]] && present=$((present + 1))
    done < <(sed -n '/^MATRIX=(/,/^)/p' "${ceremony}" | sed -n 's/^\(".*"\)$/\1/p')
  done
  printf '%s' "${present}"
}

# --- generation-18 baseline -------------------------------------------------
# The accepted digest an accepted ceremony published for one library-root
# object, or nothing if no such ceremony declares it.
#
# Read from that ceremony's own matrix rather than restated here, for the reason
# the count check already reads it: a list maintained in two places is a list
# that disagrees with itself, and the disagreement surfaces as a production
# refusal at the worst moment.
#
# THE ACCEPTED SET FOR AN OBJECT IS:
#
#   the ONE state it holds before this generation installs
#     -- the last ceremony accepted BEFORE Generation 19 that governs it,
#        or Generation-18 evidence when none does
#   PLUS the target of every ceremony accepted AFTER Generation 19 that governs it
#
# BOTH HELPER CEREMONIES ARE NOW "BEFORE", AND THAT IS THE WHOLE DIFFERENCE FROM
# GENERATION 15'S COPY OF THIS LIST. G11-BB was still pending when Generation 18
# installed, so that generation had to accept both sides of it -- an object could
# legitimately be at G11-AX's target or at G11-BB's depending on whether the
# ceremony had run yet. G11-BB was accepted at G11-BB-R, before this generation,
# so for Generation 19 there is exactly ONE accepted state per object again:
# kyri_exec_transition_action.py at b11a2f19 and kyri_exec_quota.py at 54a9b15c,
# with the earlier G11-AX states now superseded and correctly refused.
#
# The AFTER list is EMPTY, and that is a claim this ceremony is making: no
# accepted ceremony is scheduled to run after Generation 19. If one is later
# planned it must be added here before this generation installs, or the host
# will report its objects as drift.
#
# Ordering matters: `accepted_library_digest` takes the LAST governing row in
# this list as the pre-install state, so G11-BB must follow G11-AX.
CEREMONIES_BEFORE_THIS_GENERATION=(
  "provisioning/execution/install-g11-ax-helpers.sh"
  "provisioning/execution/install-g11-bb-helpers.sh"
  "provisioning/execution/install-g11-bc-e-helpers.sh"
)
# NO HELPER CEREMONY FOLLOWS THIS GENERATION, and that is a real difference from
# Generation 18 rather than an omission. G11-BC-E ran and was accepted, so it
# has moved from the AFTER list into the BEFORE list above -- its action module
# is now settled accepted bytes, not a legitimately-either-side reading. This
# generation moves no helper object and declares nothing about one, so there is
# nothing for a later ceremony to reopen.
#
# Kept as an empty declaration rather than deleted: an empty list states that
# the question was asked.
CEREMONIES_AFTER_THIS_GENERATION=()

helper_ceremony_library_rows() {
  local ceremony line target post relative_ceremony
  # shellcheck disable=SC2016  # the placeholder must not expand
  local _PLACEHOLDER='${LIBRARY_ROOT}/'
  local -a ceremonies=()
  for relative_ceremony in "$@"; do
    ceremonies+=("${REPOSITORY}/${relative_ceremony}")
  done
  for ceremony in "${ceremonies[@]}"; do
    [[ -f "${ceremony}" ]] || continue
    while IFS= read -r line; do
      line="${line#\"}"; line="${line%\"}"
      IFS='|' read -r _ target _ _ _ post _ <<<"${line}"
      [[ "${target}" == *"${_PLACEHOLDER}"* ]] || continue
      printf '%s %s\n' "${target##*"${_PLACEHOLDER}"}" "${post}"
    done < <(sed -n '/^MATRIX=(/,/^)$/p' "${ceremony}" | sed -n 's/^\(".*"\)$/\1/p')
  done
}

# Every digest an accepted ceremony declares for one library-root object, in
# chain order. Empty output means no ceremony in that chain governs it.
helper_ceremony_accepted_digests() {
  local relative="$1"; shift
  local path digest
  while read -r path digest; do
    [[ "${path}" == "${relative}" ]] || continue
    printf '%s\n' "${digest}"
  done < <(helper_ceremony_library_rows "$@")
}

# True when the observed bytes are one of the accepted states.
matches_accepted_state() {
  local observed="$1" candidate
  shift
  for candidate in $1; do
    [[ "${observed}" == "${candidate}" ]] && return 0
  done
  return 1
}

accepted_library_digest() {
  local relative="$1"
  local before after recorded authority='evidence' states=''

  # The state this object holds before this generation installs.
  before="$(helper_ceremony_accepted_digests "${relative}" \
              "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" | tail -1)"
  if [[ -n "${before}" ]]; then
    states="${before}"; authority='ceremony'
  else
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    states="${recorded}"
  fi

  # Plus whatever a ceremony accepted AFTER this generation declares for it.
  after="$(helper_ceremony_accepted_digests "${relative}" \
             "${CEREMONIES_AFTER_THIS_GENERATION[@]}")"
  if [[ -n "${after}" ]]; then
    states="${states:+${states} }${after//$'\n'/ }"; authority='ceremony'
  fi

  [[ -n "${states}" ]] || return 1
  printf '%s %s' "${authority}" "${states}"
}

# Nothing an accepted ceremony published may silently disappear. The object
# count cannot catch this: the count expectation is itself derived from how many
# of those objects are present, so a deletion moves both sides together.
overlay_complete() {
  local path digest missing=0
  while read -r path digest; do
    [[ -n "${path}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${path}" ]] && continue
    bad "the accepted helper ceremony published ${path}, which is not installed"
    missing=$((missing + 1))
  done < <(helper_ceremony_library_rows "$@")
  (( missing == 0 ))
}

require_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  local helpers_present expected_baseline
  helpers_present="$(helper_ceremony_library_creates)"
  expected_baseline=$((EXPECTED_LIBRARY_FILES_BASELINE + helpers_present))
  [[ "${count}" -eq "${expected_baseline}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-18 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-18 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-18 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"

    # This is not "ignore helper files". The overlay is read from an accepted
    # ceremony's own matrix, one path at a time; an object no ceremony declares
    # is still judged against Generation-18 evidence and still refuses.
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is absent from the Generation-18 evidence"
      drift=$((drift + 1)); continue
    fi
    read -r authority recorded <<<"${accepted}"
    observed="$(digest_of "${file}")"
    if matches_accepted_state "${observed}" "${recorded}"; then continue; fi
    if [[ "${authority}" == "ceremony" ]]; then
      bad "installed ${relative} is ${observed}, the accepted helper ceremon(ies) record ${recorded}"
    else
      bad "installed ${relative} is ${observed}, evidence records ${recorded}"
    fi
    drift=$((drift + 1))
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  overlay_complete "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" || drift=$((drift + 1))

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-18 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-18 baseline"
  ok "the installed runtime is exactly the accepted Generation-18 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-18 baseline nor the Generation-19 target"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 19 is installed and unaffected. Remove them with --recover or by hand."
  fi
}

# The elevation gates, as they actually stand rather than as Generation 13 found
# them.
#
# THIS ONCE REQUIRED EVERY GRANT TO BE ABSENT, and at Generation 13 that was
# simply true: G3 was closed and no grant existed, so "absent" and "not
# installed by anybody" were the same statement. G11-BA then installed the
# launch and reconcile grants, and this check -- inherited unchanged -- refused
# the production host for holding exactly the grants the accepted deployment
# plan says it should hold.
#
# WHY PRESENT GRANTS ARE SAFE HERE, AND IT IS NOT GENERATION 17's REASON.
#
# Generation 18 could say "readiness closes": helpers.py published first and
# declared a corrected action module against a predecessor that was still
# installed, so compatibility went `incompatible` immediately. THAT IS NOT TRUE
# OF THIS GENERATION and must not be inherited as though it were. No readiness
# authority is in this matrix; compatibility stays `compatible` and
# supervision_ready stays true throughout.
#
# The safety argument is the publication order instead. A Python process loads
# its modules once at start, so an execution racing this transaction sees one
# consistent set per process. Because `evidence.py` publishes FIRST, the only
# mixed set a starting process can observe is new-evidence/old-coordinator --
# which is Generation-18 behaviour with a HARDENED recording guard, strictly
# safer than the accepted status quo. The unsafe mix, old-evidence/new-
# coordinator, is unreachable in this direction and unreachable on rollback too,
# because rollback restores in reverse. Measured, not argued: see the header.
#
# The grants themselves are untouched either way. Neither entrypoint is a row
# here, both are byte-identical across this generation, and
# `privileged_fingerprint` checks that rather than assuming it.
#
# THE CHECK IS PRECISE RATHER THAN ABSOLUTE. The verify grant must still be
# absent -- nothing has ever authorised that entrypoint. The two execution
# grants may be present, and if they are they must pin the entrypoint bytes this
# host actually carries, because a grant naming bytes that are not there is a
# grant nobody reviewed. And no OTHER grant may appear under any name.
# The publication-order property, checked rather than commented.
#
# This generation publishes two objects and one of them imports the other, so
# there is exactly one intermediate state per order and they are not
# equivalent. Publication follows matrix order, so "evidence.py is published
# first" is only true while it is row one. A later edit that reordered the
# matrix would make every `tools.capability.cli` command -- including `recover`
# -- fail to import for the length of the transaction, and nothing else in the
# ceremony would notice. This refuses instead.
FAIL_CLOSED_FIRST="tools/capability/execution/types.py"
# The operator surface, which must be LAST: it is the only object that can
# reach the new operation, and publishing it earlier would either fail to
# import or expose a verb whose dependencies are still at Generation 18.
OPERATOR_SURFACE_LAST="tools/capability/cli.py"

# The dependency-safe publication order, in full. Each object is published
# only after everything it imports. Measured, see the MATRIX header.
PUBLICATION_ORDER=(
"tools/capability/execution/types.py"
"tools/capability/execution/state.py"
"tools/capability/execution/capacity.py"
"tools/capability/execution/recovery.py"
"tools/capability/execution/admin.py"
"tools/capability/execution/abandonment.py"
"tools/capability/cli.py"
)

# THE ORDER, HELD AS A CHECKED PROPERTY.
#
# Generation 18 named this after the object that closes execution. Nothing here
# closes execution, so the property is different and is stated as what it
# actually is: the module that DEFINES the reader publishes before the module
# that IMPORTS it. Reversed, the intermediate state is an ImportError on every
# `tools.capability.cli` command -- including `recover`.
require_fail_closed_first() {
  local index=0 declared actual
  (( ${#MATRIX[@]} == ${#PUBLICATION_ORDER[@]} )) \
    || halt "the matrix holds ${#MATRIX[@]} rows and the declared order ${#PUBLICATION_ORDER[@]}: every object must have a stated position"
  for declared in "${PUBLICATION_ORDER[@]}"; do
    actual="$(field "${MATRIX[${index}]}" 0)"
    [[ "${actual}" == "${declared}" ]] \
      || halt "matrix row ${index} is ${actual}, and the dependency-safe order puts ${declared} there: an object published before something it imports is an ImportError on every command"
    [[ "$(field "${MATRIX[${index}]}" 6)" == "B" ]] \
      || halt "${actual} is not in coherence group B: no member of this generation is valid alone"
    index=$((index + 1))
  done

  # The two ends carry the property, so they are named as well as ordered.
  [[ "$(field "${MATRIX[0]}" 0)" == "${FAIL_CLOSED_FIRST}" ]] \
    || halt "the first published object is not ${FAIL_CLOSED_FIRST}: the state vocabulary must exist before anything names a member of it"
  [[ "$(field "${MATRIX[$(( ${#MATRIX[@]} - 1 ))]}" 0)" == "${OPERATOR_SURFACE_LAST}" ]] \
    || halt "the last published object is not ${OPERATOR_SURFACE_LAST}: the operator surface must not be reachable before the operation it calls exists"

  ok "all ${#MATRIX[@]} objects publish in the measured dependency-safe order, group B, ${FAIL_CLOSED_FIRST##*/} first and ${OPERATOR_SURFACE_LAST##*/} last"
}

# The coherence-group member this generation does NOT move, checked on both
# sides. Empty for Generation 19 -- every member of both groups is a row -- but
# the check runs anyway, so that an entry added later is verified rather than
# merely written down.
require_carryover_unmoved() {
  local entry source target wanted group blob row drift=0
  for entry in ${CARRYOVER[@]+"${CARRYOVER[@]}"}; do
    source="$(field "${entry}" 0)"; target="$(field "${entry}" 1)"
    wanted="$(field "${entry}" 2)"; group="$(field "${entry}" 3)"
    for row in "${MATRIX[@]}"; do
      [[ "$(field "${row}" 0)" == "${source}" ]] \
        && { bad "${source} is declared both a carryover and a matrix row"; drift=$((drift + 1)); }
    done
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${wanted}" ]] \
      || { bad "the group-${group} carryover ${source} is ${blob:-absent} at ${COMMIT}, expected the unchanged ${wanted}"
           drift=$((drift + 1)); }
    [[ -n "${target}" ]] || { bad "${source} declares no installed target"; drift=$((drift + 1)); }
  done
  (( drift == 0 )) \
    && ok "${#CARRYOVER[@]} coherence-group carryover(s) verified; every group member this generation touches is a declared row"
}

require_gates_closed() {
  [[ ! -e "${VERIFY_SUDOERS}" ]] \
    || halt "${VERIFY_SUDOERS} exists: the verification entrypoint is not authorised"

  local grant entrypoint pinned installed
  for grant in "${SUDOERS}" "${RECONCILE_SUDOERS}"; do
    [[ -e "${grant}" ]] || continue
    case "${grant}" in
      *kyri-exec-launch)    entrypoint="${LIBEXEC_ROOT}/kyri-exec-transition" ;;
      *kyri-exec-reconcile) entrypoint="${LIBEXEC_ROOT}/kyri-exec-reconcile" ;;
      *) halt "${grant} is not a grant this ceremony can account for" ;;
    esac
    # The digest the grant pins, read out of the grant itself.
    pinned="$(grep -oE 'sha256:[0-9a-f]{64}' "${grant}" | head -1)"
    pinned="${pinned#sha256:}"
    [[ -n "${pinned}" ]] \
      || halt "${grant} pins no digest: this ceremony cannot confirm what it authorises"
    installed="$(digest_of "${entrypoint}")"
    [[ "${pinned}" == "${installed}" ]] \
      || halt "${grant} pins ${pinned}, but ${entrypoint} is ${installed:-absent}"
  done

  # Anything else under the grant directory is an elevation nobody declared.
  local unexpected
  unexpected="$(find "${SUDOERS_DIR}" -maxdepth 1 -type f -name 'kyri-*' \
                  ! -name "$(basename "${SUDOERS}")" \
                  ! -name "$(basename "${RECONCILE_SUDOERS}")" 2>/dev/null || true)"
  [[ -z "${unexpected}" ]] \
    || halt "an undeclared Kyri grant exists: ${unexpected}"

  local present=0
  [[ -e "${SUDOERS}" ]] && present=$((present + 1))
  [[ -e "${RECONCILE_SUDOERS}" ]] && present=$((present + 1))
  if (( present == 0 )); then
    ok "no sudoers grant exists: every elevation gate stays closed"
  else
    ok "${present} accepted execution grant(s) present, each pinning the installed entrypoint; the verification grant is absent"
  fi
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
    note "the coordinator identity authority is not installed; Generation 19 installs without it"
    ready=0
  fi
  if [[ ! -f "${EXECUTION_IDENTITY}" ]]; then
    note "the execution identity authority is not installed; Generation 19 installs without it"
    ready=0
  fi
  if (( ready == 1 )); then
    note "both deployment identity authorities are installed"
  else
    note "this host will be at Generation 19 and NOT execution-ready: the deployment identity ceremony is a separate one, and the runtime refuses execution until it has run"
  fi

  # This transaction does NOT change execution readiness, and saying so is the
  # point: Generation 18 closed execution on purpose and an operator who
  # remembers that would read an unchanged `compatible` here as a check that
  # failed to run. No readiness authority is in this matrix.
  note "this generation does not touch execution readiness: helper compatibility stays compatible, blocking stays 0 and supervision_ready stays true at every state, before and after"
  note "a host reporting incompatible after this ran means something OUTSIDE this matrix moved, and is a fault rather than an expected intermediate"
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
    injected_at staged && halt "injected failure after staging a Generation-19 object"
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN19_FAIL_AT:-}" == "${index}" ]]; then
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
    && bad "injected failure immediately after COMMITTED; Generation 19 stands"
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
  local row target operation wanted observed removed=0 index

  # Reverse of the publication order. With one row that is the same order, and
  # the loop is kept reversed rather than simplified away: it is the property
  # Generation 18 needed -- a fail-closed authority restored LAST, so the
  # predecessor declaration never returns while a successor object is still
  # published -- and a multi-row Generation 19 would need it back. Rewriting it
  # as a forward loop because one row cannot tell the difference is how that
  # property would be lost the next time it mattered.
  for (( index = ${#MATRIX[@]} - 1; index >= 0; index-- )); do
    row="${MATRIX[index]}"
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
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 18 (${removed} restored or removed)"
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
      bad "UNKNOWN bytes at ${target} (neither the Generation-18 baseline nor the Generation-19 target, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-19 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-19 object was published; the host is at Generation 18"
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
    || halt "Generation-18 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-19 evidence; Generation 19 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN19_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN19_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN19_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-19 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN18_COMMIT}"
    printf 'predecessor generation 18\n'
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
  } > "${GEN19_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN19_LIBRARY_EVIDENCE}.writing" "${GEN19_HELPER_EVIDENCE}.writing"
  sync_path "${GEN19_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN19_HELPER_EVIDENCE}.writing"
  mv -f "${GEN19_LIBRARY_EVIDENCE}.writing" "${GEN19_LIBRARY_EVIDENCE}"
  mv -f "${GEN19_HELPER_EVIDENCE}.writing" "${GEN19_HELPER_EVIDENCE}"
  sync_path "${GEN19_LIBRARY_EVIDENCE}"
  sync_path "${GEN19_HELPER_EVIDENCE}"
  ok "Generation-19 evidence written; Generation-18 evidence preserved"
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
    bad "injected cleanup failure after COMMITTED; Generation 19 remains installed"
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
    || bad "the installed library holds ${count} objects, expected the Generation-19 ${EXPECTED_LIBRARY_FILES_TARGET} plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) Generation-19 changed objects correspond to the reviewed commit ${COMMIT}"
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

# Every carried-over object must still be exactly what its accepted authority
# says, except the rows this transaction declares. A CREATE adds pathnames, so
# the created targets are legitimately absent from the predecessor evidence and
# are the only objects permitted to be.
#
# The accepted authority is Generation 18 PLUS what accepted ceremonies
# published after it -- the same overlay model `require_baseline` uses, through
# the same reader. Carrying a second, overlay-blind copy of this comparison is
# what refused a COMMITTED Generation-19 transaction: the four G11-AX
# library-root objects were reported as drift for holding exactly the bytes
# that ceremony was accepted for.
verify_unchanged_surface() {
  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is not accounted for by the Generation-18 evidence or any accepted ceremony, and is not a declared Generation-19 target"
      drift=$((drift + 1)); continue
    fi
    read -r authority recorded <<<"${accepted}"
    observed="$(digest_of "${file}")"
    if matches_accepted_state "${observed}" "${recorded}"; then continue; fi
    if [[ "${authority}" == "ceremony" ]]; then
      bad "${relative} changed: ${observed} but the accepted helper ceremon(ies) record ${recorded}"
    else
      bad "${relative} changed: ${observed} but Generation-18 evidence records ${recorded}"
    fi
    drift=$((drift + 1))
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  overlay_complete "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" || drift=$((drift + 1))

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-18 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every carried-over runtime object is exactly its accepted predecessor -- Generation 18, plus the $(helper_ceremony_library_rows "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" | wc -l) object(s) an accepted ceremony published after it -- and nothing was removed"
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
  require_fail_closed_first
  require_carryover_unmoved

  require_group_names_known

  # THE CORRECTION THIS GENERATION EXISTS TO DEPLOY, PROVED FROM THE REVIEWED
  # BYTES -- as ORDER, not as the presence of a word.
  #
  # A grep for `require_no_terminal_result` would pass on a coordinator that
  # called it after `supervisor.execute`, which is the defect. So the two call
  # sites are located by line number inside `execute_supervised` and compared.
  coordinator_source="$(git_as_owner show "${COMMIT}:tools/capability/coordinator.py")" \
    || halt "the reviewed commit carries no coordinator.py"
  evidence_source="$(git_as_owner show "${COMMIT}:tools/capability/evidence.py")" \
    || halt "the reviewed commit carries no evidence.py"

  gate_line="$(grep -n "require_no_terminal_result(store, invocation_record_id)" \
                 <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  exec_line="$(grep -n "outcome = supervisor.execute(binding)" \
                 <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  [[ -n "${gate_line}" ]] \
    || halt "the reviewed coordinator.py never asks whether a terminal result exists"
  [[ -n "${exec_line}" ]] \
    || halt "the reviewed coordinator.py has no supervised execution call to gate"
  (( gate_line < exec_line )) \
    || halt "the reviewed coordinator.py asks at line ${gate_line} and executes at line ${exec_line}: the gate is not in front of the provider"
  ok "the reviewed coordinator asks at line ${gate_line} and executes at line ${exec_line}"

  # The locally executed path carries the same gate, ahead of its own call.
  adapter_gate="$(grep -n "require_no_terminal_result(store, decision.invocation_record_id)" \
                    <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  adapter_exec="$(grep -n "outcome = adapter.execute(execution_binding)" \
                    <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  [[ -n "${adapter_gate}" && -n "${adapter_exec}" ]] \
    || halt "the reviewed coordinator.py does not gate the locally executed adapter path"
  (( adapter_gate < adapter_exec )) \
    || halt "the locally executed path is gated at line ${adapter_gate}, behind adapter.execute at ${adapter_exec}"
  ok "the locally executed path is gated at line ${adapter_gate}, ahead of line ${adapter_exec}"

  # The reader exists, is shared, and the fail-open the old guard carried is
  # gone. `attempt_number == 1` as a MATCH CONDITION is what let a result with
  # any other value block nothing.
  grep -q "^def existing_terminal_result" <<<"${evidence_source}" \
    || halt "the reviewed evidence.py defines no shared terminal-result reader"
  grep -q "^def require_no_terminal_result" <<<"${evidence_source}" \
    || halt "the reviewed evidence.py defines no gate wrapper"
  grep -q 'existing.get("attempt_number") == 1' <<<"${evidence_source}" \
    && halt "the reviewed evidence.py still matches on attempt_number == 1: a result carrying any other value would block nothing"
  ok "the reviewed evidence.py carries one shared reader and no attempt_number fail-open"

  # Both callers go through the one wrapper, so the gate and the recording guard
  # cannot drift into two different answers.
  [[ "$(grep -c "require_no_terminal_result" <<<"${evidence_source}")" -ge 2 ]] \
    || halt "the reviewed evidence.py does not use its own gate wrapper in record_terminal_result"
  ok "the gate and the recording guard answer through the same reader"

  note "no installed path was read for state and none was written"
  printf '\n'
  printf 'Generation 19 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded
  require_fail_closed_first
  require_carryover_unmoved

  classify_all
  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 19; use --verify-installed to audit the installed generation"
    require_gates_closed
    verify_excluded_absent
    require_group_coherence
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 19 / supervised execution runtime verify: already installed.\n'
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
    ok "the host is at Generation 18 and ready for the Generation-19 installation: $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE, $(matrix_count) changed objects across $(matrix_groups | wc -l) coherence groups, object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
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
  require_fail_closed_first
  require_carryover_unmoved
  require_gates_closed

  TRANSACTION_ID="gen18-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
      ok "Generation 19 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 19 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 18 and nothing was installed"
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
  require_fail_closed_first
  verify_installed_set
  verify_excluded_absent
  # Both halves of coherence group R, and each by the check that can actually
  # fail for it. `verify_unchanged_surface` judges cli.py because it is NOT a
  # matrix target; `require_carryover_unmoved` proves the source side did not
  # move underneath it.
  verify_unchanged_surface
  require_carryover_unmoved
  require_group_coherence
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"
  [[ -f "${GEN19_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-19 library evidence is missing"
  [[ -f "${GEN19_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-19 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-18 evidence was not preserved"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-18 helper evidence was not preserved"
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
    bad "recovery rolled the transaction back: the host is at Generation 18 and Generation 19 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 19 / supervised execution runtime %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 19 / supervised execution runtime %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
