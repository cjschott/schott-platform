#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 22: a record's claimed authority can be disputed in full.
#
# WHAT THIS DEPLOYS. TWO objects, in ONE coherence group:
#
#   C  multi-field provenance correction (ADR-0018).
#      `provenance.py` widens the correctable set to the three assertions that
#      make up a record's claimed AUTHORITY and adds one finding for a value no
#      authority ever asserted; `cli.py` carries the operator surface, including
#      the separate instant that says when the disputed action actually
#      happened.
#
# WHAT IT FIXES. On 2026-09-24 an unauthorised test harness abandoned
# CINV-000001 in production. The reviewer RETAINED the lifecycle effect -- the
# invocation had no terminal result and `historical-incomplete-execution` is the
# category the store admits -- and REJECTED the asserted authority. CADM-000004
# records that truthful effect under three false assertions:
#
#   actor        = x
#   request_id   = y
#   recorded_at  = 2026-09-20T20:00:00-05:00   (backdated four days)
#
# ADR-0016 could record ONE of the three. `CORRECTABLE_FIELDS` was
# `{actor}`, so two thirds of the falsehood was unrecordable, and the backdating
# -- which places the action before the Generation-20 publication that was meant
# to prevent it -- could not be disputed at all.
#
# WHAT IT DOES NOT TOUCH, AND THIS IS THE POINT. `reason` is NOT correctable.
# It is a claim about what happened rather than about who claimed it, and the
# abandonment validates it against the store before writing: a category that
# survived that check is a fact. Making it correctable would let an EFFECT be
# disputed through a mechanism built for an ATTRIBUTION, which is the one thing
# this verb must never become.
#
# THREE INSTANTS, THREE NAMES. A `recorded_at` correction involves the subject's
# false timestamp (`disputed_value`), when the action observably happened
# (`actual_occurrence_at`, new here), and when the correction itself is written
# (`recorded_at`). One field carrying two of them would be the defect being
# corrected, so `actual_occurrence_at` is its own required field and asserts no
# authority -- it is an observation.
#
# PUBLICATION ORDER IS THE SAFETY PROPERTY, AND IT WAS MEASURED, NOT INHERITED.
#
#   published so far          tools.capability.cli   --actual-occurrence-at
#   ------------------------  ---------------------  ----------------------
#   (Generation 21)           imports                no
#   + provenance              imports                no
#   + cli  (Generation 22)    imports                YES
#
# BOTH INTERMEDIATES FAIL CLOSED, and that was measured rather than argued.
# `cli.py` reads the correctable set from `provenance.py` when it builds its
# parser, so the two objects are coupled in both directions and NEITHER order
# leaves a working `correct-provenance`:
#
#   provenance new / cli OLD:
#     TypeError: correct_provenance() missing 1 required keyword-only
#     argument: 'actual_occurrence_at'
#   cli new / provenance OLD:
#     TypeError: correct_provenance() got an unexpected keyword argument
#     'actual_occurrence_at'
#
# A TypeError before any lock is taken is a refusal, not a partial write: no
# `CADM` is allocated and nothing is recorded. So the verb is unavailable for the
# length of the transaction whichever way round it goes, and it cannot write a
# malformed correction in either.
#
# The order is therefore chosen by the rule every generation here follows rather
# than by which intermediate works: the object that is NOT an operator surface
# goes first, and the operator surface goes LAST -- so the widened flag only
# appears once the operation behind it can accept it. `rollback` restores in
# reverse.
#
# NO CREATE. Both objects already exist at Generation 21, so the installed
# object count does NOT move: 83 declared objects plus the published helper
# module, before and after. Generation 21 moved 82 -> 83 by creating
# `conclusion.py`; this generation moves nothing.
#
# EXECUTION STAYS OPEN THROUGH THIS GENERATION. No readiness authority moves:
# `helpers.py` is untouched, compatibility stays `compatible`, blocking stays 0
# and supervision_ready stays true at every state.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. No lifecycle state, no transition, no
# capacity change, no helper object, no entrypoint, no worker, no readiness
# authority, no container-runtime binding, no sudoers grant, no execution image,
# no deployment identity authority, and not one byte of Fabric, Trust, or
# invocation history. `MAXIMUM_SLOTS` is unchanged at 2. Abandonment semantics,
# CONCLUDED semantics and result semantics are untouched.
#
# WHAT IT DOES NOT TOUCH IN THE RUNTIME STORE. No CINV, no CRES, no CADM and no
# CMUT is read, written or referenced. CADM-000004 is NOT corrected here:
# occupancy stays 0 of 2 and the store is byte-identical across this
# publication. Correcting it is a separate operator ceremony that runs AFTER
# this generation is accepted.
#
COMMIT="646b12799a0b5438d1d346f56a9a9a9f9e65299a"

# The accepted Generation-21 source authority, and the baseline this transaction
# requires the host to be at.
GEN21_COMMIT="0bd3b8acf9953126b9e1ba3eda07b282debd7c78"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# This transaction's own namespace. Generation 21's retained journal at
# /root/kyri-gen21-transaction is predecessor evidence: it records how the host
# reached the state this transaction starts from, it is never read as this
# transaction's state, and nothing here writes to or removes it. Deriving an
# installer from its predecessor and leaving the predecessor's path in place is
# what made the first real Generation-14 attempt halt against a COMMITTED
# journal belonging to a transaction that had already finished.
TRANSACTION_ROOT="/root/kyri-gen22-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen21-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen21-helper-digests.txt"
GEN22_LIBRARY_EVIDENCE="/root/kyri-gen22-library-digests.txt"
GEN22_HELPER_EVIDENCE="/root/kyri-gen22-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS="/etc/sudoers.d/kyri-exec-launch"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# The two deployment identity authorities. Read to prove this ceremony did not
# create them; never written. Generation 22 does not need them to install.
COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# NO CREATE, so the count does not move. Both ends are stated anyway, and they
# are stated as EQUAL: a matrix that quietly gained a CREATE row would change the
# installed object count, and declaring the expectation on both sides is what
# turns that into a refusal here rather than a surprise at publication.
EXPECTED_LIBRARY_FILES_BASELINE=83
EXPECTED_LIBRARY_FILES_TARGET=83

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
  GEN22_LIBRARY_EVIDENCE="${FIXTURE}${GEN22_LIBRARY_EVIDENCE}"
  GEN22_HELPER_EVIDENCE="${FIXTURE}${GEN22_HELPER_EVIDENCE}"
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
PREPARED_SUFFIX=".kyri-gen22.new"
BACKUP_SUFFIX=".kyri-gen22.gen21"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

CLOSURE_STAGING=""
ADR0018_STAGING=""
PREPARING=0

# --- the two generation-22 objects, pinned both ways -----------------------
#
# source | target | mode | operation | gen21-sha256 | gen22-sha256 | group
#
# Both targets already exist at Generation 21, so both rows are REPLACE. There
# is no CREATE, no directory to make, and nothing for rollback to delete: a
# rollback restores two files to bytes this installer pinned before it moved
# them.
#
# THE ONE GROUP, AND WHY IT IS ONE.
#
#   C  multi-field provenance correction (ADR-0018).
#      `provenance.py` owns the closed set of correctable claims, the third
#      instant, and every refusal; `cli.py` is the only operator surface that
#      can reach the verb, and it BUILDS ITS PARSER FROM that closed set.
#
#      Neither is a valid complete Generation 22 on its own, and the two ways it
#      breaks are different -- see the publication note in the matrix below.
#
# THE LETTER, AND WHY IT IS NOT P.
#
#      P names post-execution lifecycle conclusion, which is Generation 21's
#      group and still means that. Reusing it here would put two unrelated
#      architectures behind one name, and would make a coherence report name the
#      wrong architecture -- and worse, it would make `conclusion.py`, a P
#      member this generation does not move, an undeclared member left behind.
#      A new letter is the truthful answer, so C is added to the names below.
#
#      There is no CARRYOVER, and that is a measured claim rather than a
#      convenience: C has exactly two members and both are rows here.

MATRIX=(
# --- P: multi-field provenance correction. THE ORDER IS DEPENDENCY-SAFE AND IT
#        WAS MEASURED, NOT INHERITED.
#
#          published so far        tools.capability.cli   --actual-occurrence-at
#          ----------------------  ---------------------  ----------------------
#          (Generation 21)         imports                no
#          + provenance            imports                no
#          + cli  (Generation 22)  imports                YES
#
#        BOTH INTERMEDIATES FAIL CLOSED. `cli.py` reads the correctable set from
#        `provenance.py` when it builds its parser, so the two are coupled both
#        ways and neither order leaves a working `correct-provenance`:
#
#          provenance new / cli OLD -> TypeError: missing 1 required
#            keyword-only argument: 'actual_occurrence_at'
#          cli new / provenance OLD -> TypeError: got an unexpected keyword
#            argument 'actual_occurrence_at'
#
#        Both raise before any lock is taken, so no CADM is allocated and
#        nothing is recorded. The verb is simply unavailable for the length of
#        the transaction, in either direction, and cannot write a malformed
#        correction in either.
#
#        The order is therefore the rule every generation here follows rather
#        than whichever intermediate happens to work: the object that is not an
#        operator surface first, the operator surface LAST, so the widened flag
#        appears only once the operation behind it accepts it.
"tools/capability/execution/provenance.py|${LIBRARY_ROOT}/tools/capability/execution/provenance.py|0444|REPLACE|2783c5438f1154111dc3700b6b9da74f54b3a71d7ec9fc12f17585bc01ab0bd6|e0f6ffeb57f78db460a126e6e1e8b58a7575401c13e681ac0d7d6e8cd21c0435|C"
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|82eb3ffe2d73655913f8d5e6e9cb4e799f47d15b4b266843e58b9fea3cc7425c|9459b09f2d0545c3a490f21e5223c2cfe95f2f4431132e275b6eae0b4502927f|C"
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

# Every group any previous generation named is still spelled here, even though
# this generation only moves C. The names outlive the generation that
# introduced them, and a coherence failure naming "unknown group V" would be a
# worse report than one naming what V is.
group_name() {
  case "$1" in
    V) printf 'the runtime-side verification surface' ;;
    R) printf 'supervised recovery discovery' ;;
    H) printf 'helper declaration and refusal reporting' ;;
    A) printf 'the container-runtime binding' ;;
    T) printf 'the terminal-result authority' ;;
    B) printf 'governed administrative abandonment' ;;
    P) printf 'post-execution lifecycle conclusion' ;;
    C) printf 'multi-field provenance correction' ;;
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# EVERY LETTER THE MATRIX CAN CARRY HAS A CASE ABOVE, AND THAT IS CHECKED.
#
# Generation 18 put a row in group A and never added a case for it, so a split
# in that group would have reported "unknown group A" -- the exact failure its
# own comment said the names exist to prevent. A diagnostic defect only, and it
# is in an accepted installer so it is reported rather than edited here; neither
# Generation 21 nor this one repeats it, and C has a case.
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

# The modules that must NOT be installed, carried forward from Generation 21
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
  [[ -n "${FIXTURE}" && "${KYRI_GEN22_FAIL_AT:-}" == "$1" ]]
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 21\n' \
    "${removed}" >&2
}

cleanup_on_exit() {
  local status=$?
  [[ -n "${CLOSURE_STAGING}" ]] && rm -rf "${CLOSURE_STAGING}"
  [[ -n "${ADR0018_STAGING}" ]] && rm -rf "${ADR0018_STAGING}"
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
    printf 'baseline_commit=%s\n' "${GEN21_COMMIT}"
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
      bad "group ${group} ($(group_name "${group}")) is split: ${at_baseline} object(s) at Generation 22 and ${at_target} at Generation 22"
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
    || halt "the reviewed Generation-22 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-22 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN21_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-21 authority is not an ancestor of the Generation-22 authority"
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
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-22 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-22 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
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

  # What the predecessor provides, decided from the reviewed Generation-21
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
    if git_as_owner cat-file -e "${GEN21_COMMIT}:${source}" 2>/dev/null; then
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
# accepted ceremony with a library-root CREATE at the time. Three are accepted
# now, so this reads the declared ceremony lists instead of naming one. The answer is
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

# --- generation-19 baseline -------------------------------------------------
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
#     -- the last ceremony accepted BEFORE Generation 22 that governs it,
#        or Generation-21 evidence when none does
#   PLUS the target of every ceremony accepted AFTER Generation 22 that governs it
#
# EVERY HELPER CEREMONY IS "BEFORE", AND THAT IS THE WHOLE DIFFERENCE FROM
# GENERATION 15'S COPY OF THIS LIST. G11-BB was still pending when Generation 15
# installed, so that generation had to accept both sides of it -- an object could
# legitimately be at G11-AX's target or at G11-BB's depending on whether the
# ceremony had run yet. G11-BB was accepted at G11-BB-R, and G11-BC-E before
# Generation 21, so there is exactly ONE accepted state per object again:
# kyri_exec_transition_action.py at b11a2f19 and kyri_exec_quota.py at 54a9b15c,
# with the earlier G11-AX states now superseded and correctly refused.
#
# The AFTER list is EMPTY, and that is a claim this ceremony is making: no
# accepted ceremony is scheduled to run after Generation 22. If one is later
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
# NO HELPER CEREMONY FOLLOWS THIS GENERATION, as none followed Generation 21.
# G11-BC-E ran and was accepted before that generation, so its action module is
# settled accepted bytes rather than a legitimately-either-side reading. This
# generation moves no helper object and declares nothing about one, so there is
# nothing for a later ceremony to reopen. The list is kept and re-stated rather
# than assumed: an empty AFTER list is a claim, and it is this one's claim.
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
    || halt "the installed library holds ${count} objects, expected the Generation-21 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-21 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-21 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"

    # This is not "ignore helper files". The overlay is read from an accepted
    # ceremony's own matrix, one path at a time; an object no ceremony declares
    # is still judged against Generation-21 evidence and still refuses.
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is absent from the Generation-21 evidence"
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
      || { bad "the Generation-21 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-21 baseline"
  ok "the installed runtime is exactly the accepted Generation-21 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-21 baseline nor the Generation-22 target"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 22 is installed and unaffected. Remove them with --recover or by hand."
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
# Generation 17 could say "readiness closes": helpers.py published first and
# declared a corrected action module against a predecessor that was still
# installed, so compatibility went `incompatible` immediately. THAT IS NOT TRUE
# OF THIS GENERATION, any more than it was of Generations 18 or 19, and must not
# be inherited as though it were. No readiness
# authority is in this matrix; compatibility stays `compatible` and
# supervision_ready stays true throughout.
#
# The safety argument is the publication order instead. A Python process loads
# its modules once at start, so an execution racing this transaction sees one
# consistent set per process. Because `cli.py` publishes LAST, the only mixed
# sets a starting process can observe are ones in which no new operator surface
# exists yet -- Generation-21 behaviour, with a name nothing imports and a verb
# nothing can reach. The unsafe mix, new-cli/old-library, is unreachable in this
# direction and unreachable on rollback too, because rollback restores in
# reverse. Measured, not argued: see the header.
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
# This generation publishes two objects and `cli.py` imports `provenance.py` at
# module level, so the two orders are not equivalent. Publication follows matrix
# order, so "provenance.py is published first" is only true while it is row one.
# A later edit that reordered the matrix would put the widened operator surface
# in front of the operation it calls, and nothing else in the ceremony would
# notice. This refuses instead.
FAIL_CLOSED_FIRST="tools/capability/execution/provenance.py"
# The operator surface, which must be LAST. Both intermediates fail closed, so
# this is not about avoiding a broken state -- it is about which broken state an
# operator meets. Publishing `cli.py` last means the widened `--disputed-field`
# choices and the new `--actual-occurrence-at` appear only when the operation
# behind them accepts them, rather than offering a flag that cannot work.
OPERATOR_SURFACE_LAST="tools/capability/cli.py"

# The dependency-safe publication order, in full. Each object is published
# only after everything it imports. Measured, see the MATRIX header.
PUBLICATION_ORDER=(
"tools/capability/execution/provenance.py"
"tools/capability/cli.py"
)

# --- ADR-0018, proved structurally from whichever tree is named --------------
#
# ONE VERIFIER, TWO TREES. `--verify-source` runs it against the reviewed bytes
# and `--verify-installed` runs it against the installed library, which has the
# same relative layout. A single implementation is the point: a source check and
# an installed check that could disagree would be two claims, not one property.
ADR0018_SOURCES=(
"tools/capability/execution/provenance.py"
"tools/capability/execution/abandonment.py"
"tools/capability/cli.py"
)

prove_adr0018() {
  local root="$1" what="$2" report relative
  for relative in "${ADR0018_SOURCES[@]}"; do
    [[ -f "${root}/${relative}" ]] \
      || halt "${what} carries no ${relative}"
  done

  report="$(python3 - "${root}" <<'GEN22_PY'
"""Prove ADR-0018 from the reviewed source, structurally.

One verdict per property: `ok <text>` or `FAIL <text>`. The caller halts on the
first FAIL. Nothing here imports the reviewed modules -- they are parsed,
because importing would run them.
"""
import ast
import os
import sys

STAGE = sys.argv[1]
findings = []


def parse(relative):
    with open(os.path.join(STAGE, relative), encoding="utf-8") as handle:
        return ast.parse(handle.read())


def source(relative):
    with open(os.path.join(STAGE, relative), encoding="utf-8") as handle:
        return handle.read()


def check(condition, text):
    findings.append(("ok" if condition else "FAIL", text))
    return bool(condition)


def module_assign(tree, name):
    for item in tree.body:
        if (isinstance(item, ast.Assign) and len(item.targets) == 1
                and isinstance(item.targets[0], ast.Name)
                and item.targets[0].id == name):
            return item.value
        if (isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name)
                and item.target.id == name):
            return item.value
    return None


def constants(tree):
    """Every module-level `NAME = "literal"` in the module."""
    out = {}
    for item in tree.body:
        if (isinstance(item, ast.Assign) and len(item.targets) == 1
                and isinstance(item.targets[0], ast.Name)
                and isinstance(item.value, ast.Constant)):
            out[item.targets[0].id] = item.value.value
    return out


def frozenset_members(node, names):
    """The literal values a `frozenset({A, B})` of module constants holds."""
    if node is None:
        return None
    found = set()
    for element in ast.walk(node):
        if isinstance(element, ast.Name) and element.id in names:
            found.add(names[element.id])
        elif isinstance(element, ast.Constant) and isinstance(element.value, str):
            found.add(element.value)
    return found


def function(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


provenance = parse("tools/capability/execution/provenance.py")
provenance_text = source("tools/capability/execution/provenance.py")
names = constants(provenance)

# --- 1. the correctable set is exactly the three authority assertions ------
fields = frozenset_members(module_assign(provenance, "CORRECTABLE_FIELDS"), names)
check(fields == {"actor", "request_id", "recorded_at"},
      "the correctable set is exactly actor, request_id and recorded_at")

# --- 2. AND THE EFFECT IS STILL OUT OF REACH. This is the property the whole
#        generation turns on: a widened set that admitted a lifecycle claim
#        would turn a correction into a reversal.
for forbidden in ("reason", "state", "previous_state", "slot_released",
                  "result_record_id", "cinv", "lifecycle_state", "effect"):
    check(forbidden not in (fields or set()),
          f"{forbidden!r} is NOT correctable: a correction disputes an "
          f"attribution, never an effect")

# --- 3. two findings, saying different things ------------------------------
found = frozenset_members(module_assign(provenance, "FINDINGS"), names)
check(found == {"attribution-not-authorised", "assertion-synthetic"},
      "exactly two findings: attribution-not-authorised and assertion-synthetic")
check(names.get("FINDING_SYNTHETIC") == "assertion-synthetic",
      "assertion-synthetic is declared: a value no authority ever asserted")

# --- 4. the initiator set names the harness, and keeps `unknown` -----------
initiators = frozenset_members(module_assign(provenance, "INITIATORS"), names)
check("unauthorised-test-harness" in (initiators or set()),
      "the initiator set names the unauthorised test harness")
check("unknown" in (initiators or set()),
      "`unknown` remains a first-class initiator rather than an invitation to guess")

# --- 5. three instants, three names, none overloaded ----------------------
correct = function(provenance, "correct_provenance")
body = ast.unparse(correct) if correct is not None else ""
check(correct is not None, "provenance.py defines correct_provenance")
arguments = [a.arg for a in (correct.args.kwonlyargs if correct else [])]
check("actual_occurrence_at" in arguments,
      "actual_occurrence_at is a required keyword: when the disputed action "
      "observably happened")
check("occurrence_text = _instant(actual_occurrence_at" in body,
      "the occurrence is validated as its own instant, named in its own refusal")
for key in ("'actual_occurrence_at': occurrence_text",
            "'recorded_at': recorded_text",
            "'disputed_value': claimed"):
    check(key in body,
          f"the record keeps {key.split(chr(39))[1]} distinct rather than "
          f"deriving it from another instant")

# --- 6. bound to the member, and to its bytes -----------------------------
check("subject_member" in body and "subject_digest" in body,
      "a correction is bound to the subject MEMBER and to that member's digest")
member_fn = function(provenance, "_subject_member")
member_body = ast.unparse(member_fn) if member_fn is not None else ""
check("more than one member" in member_body,
      "a field carried by two members is refused as ambiguous rather than guessed")
check("refusing to correct a claim that is not there" in body,
      "the disputed value must match what the record says")

# --- 7. it cannot reach an effect, a slot, or a mutation ------------------
for forbidden, why in (("acquire_capacity", "takes a capacity lock"),
                       ("transition_locked", "writes a lifecycle transition"),
                       ("Mutation(", "opens a mutation"),
                       ("record_terminal_result", "fabricates a result"),
                       ("shutil", "removes a tree"),
                       ("unlink", "deletes")):
    check(forbidden not in provenance_text,
          f"provenance.py never {why} ({forbidden} absent)")
check("action_reversed" in body and "lifecycle_unchanged" in body,
      "the record states explicitly that nothing was reversed and the lifecycle "
      "did not move")

# --- 8. `reason` is excluded for a stated reason, not by omission ---------
abandonment_text = source("tools/capability/execution/abandonment.py")
check("_REASON_REQUIRES_RESULT" in abandonment_text,
      "the abandonment still validates its reason category against the store, "
      "which is why reason is a fact rather than an attribution")

# --- 9. the operator surface --------------------------------------------
cli = parse("tools/capability/cli.py")
cli_text = source("tools/capability/cli.py")
check('correct.add_argument("--actual-occurrence-at", required=True' in cli_text,
      "capability correct-provenance requires --actual-occurrence-at")
check('correct.add_argument("--store-root", required=True' in cli_text,
      "and still requires an explicit --store-root, with no default")
command = function(cli, "command_correct_provenance")
command_body = ast.unparse(command) if command else ""
check("actual_occurrence_at=args.actual_occurrence_at" in command_body,
      "the surface passes the occurrence through rather than deriving it")
check("CAPABILITY_RUNTIME_ROOT" not in command_body,
      "command_correct_provenance cannot resolve the compiled-in production root")
# THE DRIFT THE G21 VERIFIER ALLOWED. A surface that RESTATES the closed set
# passes any grep for the name while diverging from the module that decides it,
# so each choice list is read where argparse is given it.
def choice_source(flag):
    """What the `choices=` of one flag is built from: (names, literals)."""
    for node in ast.walk(cli):
        if not (isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "add_argument"
                and node.args
                and getattr(node.args[0], "value", None) == flag):
            continue
        for keyword in node.keywords:
            if keyword.arg == "choices":
                walked = list(ast.walk(keyword.value))
                return ({n.id for n in walked if isinstance(n, ast.Name)},
                        {n.value for n in walked
                         if isinstance(n, ast.Constant)
                         and isinstance(n.value, str)})
        return (set(), set())
    return (None, None)


imported = set()
for node in ast.walk(cli):
    if isinstance(node, ast.ImportFrom) and "provenance" in (node.module or ""):
        imported |= {a.asname or a.name for a in node.names}

for flag, alias, original in (("--disputed-field", "_CORRECTABLE_FIELDS",
                               "CORRECTABLE_FIELDS"),
                              ("--finding", "_CORRECTION_FINDINGS", "FINDINGS"),
                              ("--actual-initiator", "_CORRECTION_INITIATORS",
                               "INITIATORS")):
    offered, spelled = choice_source(flag)
    # The alias must be there, and NO literal may be: a hand-written list is
    # exactly how a surface comes to offer a choice the module refuses.
    check(offered is not None and alias in offered and not spelled,
          f"{flag} offers the module {original} itself, with no choice spelled "
          f"out on the surface")
    check(alias in imported,
          f"{alias} is imported from provenance, so the surface cannot drift "
          f"from the set that decides refusals")
for forbidden in ("--force", "--to", "--target-state"):
    check(forbidden not in cli_text,
          f"the surface exposes no {forbidden}: a correction is not a "
          f"force-transition")

for verdict, text in findings:
    print(verdict, text)
sys.exit(1 if any(v == "FAIL" for v, _ in findings) else 0)
GEN22_PY
  )" || { printf '%s\n' "${report}" \
            | sed -n "s/^FAIL /STOP: ${what} does not prove: /p" >&2
          halt "${what} does not carry the ADR-0018 properties this generation publishes"; }
  printf '%s\n' "${report}" | sed 's/^ok /ok       /'
  ok "ADR-0018 proved from ${what}: $(printf '%s' "${report}" | grep -c '^ok ') properties"
}

require_fail_closed_first() {
  local index=0 declared actual
  (( ${#MATRIX[@]} == ${#PUBLICATION_ORDER[@]} )) \
    || halt "the matrix holds ${#MATRIX[@]} rows and the declared order ${#PUBLICATION_ORDER[@]}: every object must have a stated position"
  for declared in "${PUBLICATION_ORDER[@]}"; do
    actual="$(field "${MATRIX[${index}]}" 0)"
    [[ "${actual}" == "${declared}" ]] \
      || halt "matrix row ${index} is ${actual}, and the dependency-safe order puts ${declared} there: an object published before something it imports is an ImportError on every command"
    [[ "$(field "${MATRIX[${index}]}" 6)" == "C" ]] \
      || halt "${actual} is not in coherence group C: no member of this generation is valid alone"
    index=$((index + 1))
  done

  # The two ends carry the property, so they are named as well as ordered.
  [[ "$(field "${MATRIX[0]}" 0)" == "${FAIL_CLOSED_FIRST}" ]] \
    || halt "the first published object is not ${FAIL_CLOSED_FIRST}: the module that decides the closed set must be in place before the surface that reads it"
  [[ "$(field "${MATRIX[$(( ${#MATRIX[@]} - 1 ))]}" 0)" == "${OPERATOR_SURFACE_LAST}" ]] \
    || halt "the last published object is not ${OPERATOR_SURFACE_LAST}: the operator surface must not be reachable before the operation it calls exists"

  ok "all ${#MATRIX[@]} objects publish in the measured dependency-safe order, group C, ${FAIL_CLOSED_FIRST##*/} first and ${OPERATOR_SURFACE_LAST##*/} last"
}

# The coherence-group member this generation does NOT move, checked on both
# sides. Empty for Generation 22 -- group C has two members and both are rows --
# but the check runs anyway, so that an entry added later is verified rather than
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

# Publication cannot reach a governed store, and that is proved from the matrix
# rather than from a snapshot taken either side of the install.
#
# A before/after comparison would only show that nothing DID move. This shows
# that nothing COULD: every row publishes beneath the library root, and no row
# names a path under the capability runtime, the handoff, Fabric, Trust, or the
# implementation-authority namespaces. An installer that gained the ability to
# write a governed store would fail here rather than at the moment it used it.
require_governed_stores_unreachable() {
  local row target prefix reach=0
  local -a governed=(
    "/data/kyri/capability-runtime"
    "/data/kyri/capability-handoff"
    "/var/lib/kyri/fabric"
    "/var/lib/kyri/trust"
    "${AUTHORITY_ROOT}"
    "${CONTROL_ROOT}"
  )
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ "${target}" == "${LIBRARY_ROOT}/"* ]] \
      || { bad "the matrix publishes ${target}, which is outside the library root"; reach=$((reach + 1)); }
    for prefix in "${governed[@]}"; do
      [[ "${target}" == "${prefix}"* ]] \
        && { bad "the matrix would publish ${target} into the governed store ${prefix}"; reach=$((reach + 1)); }
    done
  done
  (( reach == 0 )) \
    && ok "publication is confined to ${LIBRARY_ROOT}: no row can reach the capability runtime, the handoff, Fabric, Trust or the authority namespaces"
}

# The shape of the matrix, asserted rather than described. The counts are in the
# header prose and in EXPECTED_LIBRARY_FILES_*; this is where they are checked
# against the rows themselves, so the three cannot drift apart.
require_operation_shape() {
  local row operation replaces=0 creates=0 created_target=""
  for row in "${MATRIX[@]}"; do
    operation="$(field "${row}" 3)"
    case "${operation}" in
      REPLACE) replaces=$((replaces + 1)) ;;
      CREATE)  creates=$((creates + 1)); created_target="$(field "${row}" 1)" ;;
      *) bad "matrix row $(field "${row}" 0) declares the unknown operation ${operation}" ;;
    esac
  done
  (( replaces == 2 )) \
    || bad "the matrix holds ${replaces} REPLACE rows, expected 2"
  (( creates == 0 )) \
    || bad "the matrix holds ${creates} CREATE rows, expected 0: this generation creates nothing, and ${created_target:-a row} says otherwise"
  local expected_move=$(( EXPECTED_LIBRARY_FILES_TARGET - EXPECTED_LIBRARY_FILES_BASELINE ))
  (( expected_move == creates )) \
    || bad "the declared library count moves by ${expected_move} but the matrix holds ${creates} CREATE row(s)"
  (( FAILURES == 0 )) \
    && ok "the matrix is 2 REPLACE and 0 CREATE, and the declared count stays at ${EXPECTED_LIBRARY_FILES_BASELINE} because nothing is created"
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
    note "the coordinator identity authority is not installed; Generation 22 installs without it"
    ready=0
  fi
  if [[ ! -f "${EXECUTION_IDENTITY}" ]]; then
    note "the execution identity authority is not installed; Generation 22 installs without it"
    ready=0
  fi
  if (( ready == 1 )); then
    note "both deployment identity authorities are installed"
  else
    note "this host will be at Generation 22 and NOT execution-ready: the deployment identity ceremony is a separate one, and the runtime refuses execution until it has run"
  fi

  # This transaction does NOT change execution readiness, and saying so is the
  # point: Generation 17 closed execution on purpose and an operator who
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
    injected_at staged && halt "injected failure after staging a Generation-22 object"
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN22_FAIL_AT:-}" == "${index}" ]]; then
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
  # target has published AND verified -- not on a count, and not on
  # the journal's own say-so.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; Generation 22 stands"
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

  # Reverse of the publication order, and with two coupled rows it is
  # load-bearing rather than ceremonial: `cli.py` goes back FIRST, so the
  # restored surface never runs against a library that has already been rolled
  # back beneath it. Restoring forward would put the Generation-22 `cli.py`
  # against a Generation-21 `provenance.py` for the length of the unwind, which
  # is the unexpected-keyword TypeError from the other direction.
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
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 21 (${removed} restored or removed)"
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
      bad "UNKNOWN bytes at ${target} (neither the Generation-21 baseline nor the Generation-22 target, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-22 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-22 object was published; the host is at Generation 21"
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
    || halt "Generation-21 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-22 evidence; Generation 22 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN22_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN22_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN22_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-22 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN21_COMMIT}"
    printf 'predecessor generation 19\n'
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
  } > "${GEN22_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN22_LIBRARY_EVIDENCE}.writing" "${GEN22_HELPER_EVIDENCE}.writing"
  sync_path "${GEN22_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN22_HELPER_EVIDENCE}.writing"
  mv -f "${GEN22_LIBRARY_EVIDENCE}.writing" "${GEN22_LIBRARY_EVIDENCE}"
  mv -f "${GEN22_HELPER_EVIDENCE}.writing" "${GEN22_HELPER_EVIDENCE}"
  sync_path "${GEN22_LIBRARY_EVIDENCE}"
  sync_path "${GEN22_HELPER_EVIDENCE}"
  ok "Generation-22 evidence written; Generation-21 evidence preserved"
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
    bad "injected cleanup failure after COMMITTED; Generation 22 remains installed"
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
    || bad "the installed library holds ${count} objects, expected the Generation-22 ${EXPECTED_LIBRARY_FILES_TARGET} plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) Generation-22 changed objects correspond to the reviewed commit ${COMMIT}"
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
# The accepted authority is Generation 21 PLUS what accepted ceremonies
# published after it -- the same overlay model `require_baseline` uses, through
# the same reader. Carrying a second, overlay-blind copy of this comparison is
# what refused a COMMITTED Generation-22 transaction: the four G11-AX
# library-root objects were reported as drift for holding exactly the bytes
# that ceremony was accepted for.
verify_unchanged_surface() {
  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is not accounted for by the Generation-21 evidence or any accepted ceremony, and is not a declared Generation-22 target"
      drift=$((drift + 1)); continue
    fi
    read -r authority recorded <<<"${accepted}"
    observed="$(digest_of "${file}")"
    if matches_accepted_state "${observed}" "${recorded}"; then continue; fi
    if [[ "${authority}" == "ceremony" ]]; then
      bad "${relative} changed: ${observed} but the accepted helper ceremon(ies) record ${recorded}"
    else
      bad "${relative} changed: ${observed} but Generation-21 evidence records ${recorded}"
    fi
    drift=$((drift + 1))
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  overlay_complete "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" || drift=$((drift + 1))

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-21 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every carried-over runtime object is exactly its accepted predecessor -- Generation 21, plus the $(helper_ceremony_library_rows "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" | wc -l) object(s) an accepted ceremony published after it -- and nothing was removed"
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
  require_governed_stores_unreachable
  require_operation_shape
  require_fail_closed_first
  require_carryover_unmoved

  require_group_names_known

  # THE ARCHITECTURE THIS GENERATION EXISTS TO DEPLOY, PROVED FROM THE REVIEWED
  # BYTES -- as PROPERTIES, not as the presence of a word.
  #
  # A grep for "request_id" would pass on a verb that had gained the field and
  # lost the boundary. The properties that matter are what the closed sets HOLD
  # and, more importantly, what they still REFUSE -- so each is read from the
  # parsed source where it is decided.
  ADR0018_STAGING="$(mktemp -d)" || halt "cannot stage the reviewed Generation-22 source"
  for relative in "${ADR0018_SOURCES[@]}"; do
    mkdir -p "${ADR0018_STAGING}/$(dirname "${relative}")"
    git_as_owner show "${COMMIT}:${relative}" > "${ADR0018_STAGING}/${relative}" \
      || halt "the reviewed commit carries no ${relative}"
  done
  prove_adr0018 "${ADR0018_STAGING}" "the reviewed bytes at ${COMMIT:0:7}"
  rm -rf "${ADR0018_STAGING}"; ADR0018_STAGING=""

  # --- carried forward from Generation 21 / ADR-0017, as regression ---------
  #
  # RETAINED, AND ONLY THESE. Generation 21's own purpose -- the CONCLUDED
  # closure -- was proved when Generation 21 was accepted. What is kept here is
  # the subset that touches a file THIS generation republishes: `cli.py` moves,
  # so a regression in the surfaces it carries would ship under this matrix.
  #
  # `provenance.py` is this generation's own subject and is proved above.
  cli_source="$(git_as_owner show "${COMMIT}:tools/capability/cli.py")"
  grep -q 'add_parser("conclude")' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py no longer exposes the conclude verb"
  grep -q 'add_parser("abandon")' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py no longer exposes the abandon verb"
  grep -q 'conclude.add_argument("--store-root", required=True' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py does not require an explicit --store-root for conclude"
  grep -q 'abandon.add_argument("--store-root", required=True' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py does not require an explicit --store-root for abandon"
  compiled_roots="$(grep -c "CapabilityStore(CAPABILITY_RUNTIME_ROOT" <<<"${cli_source}" || true)"
  [[ "${compiled_roots}" == "3" ]] \
    || halt "regression: the reviewed cli.py resolves the compiled-in store root ${compiled_roots} times, expected exactly 3 -- authorise-launch, execute and recover"
  ok "regression: all three administrative mutators still take an explicit target, and conclude is intact"

  # ADR-0017 and ADR-0015 are not regressed by anything this generation moves.
  types_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/types.py")"
  capacity_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/capacity.py")"
  grep -q 'CONCLUDED = "concluded"' <<<"${types_source}" \
    || halt "regression: the reviewed types.py no longer declares CONCLUDED"
  grep -q 'ABANDONED = "abandoned"' <<<"${types_source}" \
    || halt "regression: the reviewed types.py no longer declares ABANDONED"
  grep -q "MAXIMUM_SLOTS = 2" <<<"${capacity_source}" \
    || halt "regression: the reviewed capacity.py does not keep MAXIMUM_SLOTS at 2"
  ok "regression: CONCLUDED and ABANDONED intact, and MAXIMUM_SLOTS still 2"

  # --- carried forward from Generation 18, as regression --------------------
  #
  # `evidence.py` and `coordinator.py` do not move in this generation. These
  # checks are kept so the Generation-18 correction is proved not to have
  # regressed under it, and they are labelled as what they are.
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
  ok "carried forward: the coordinator asks at line ${gate_line} and executes at line ${exec_line}"

  # The locally executed path carries the same gate, ahead of its own call.
  adapter_gate="$(grep -n "require_no_terminal_result(store, decision.invocation_record_id)" \
                    <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  adapter_exec="$(grep -n "outcome = adapter.execute(execution_binding)" \
                    <<<"${coordinator_source}" | head -1 | cut -d: -f1)"
  [[ -n "${adapter_gate}" && -n "${adapter_exec}" ]] \
    || halt "the reviewed coordinator.py does not gate the locally executed adapter path"
  (( adapter_gate < adapter_exec )) \
    || halt "the locally executed path is gated at line ${adapter_gate}, behind adapter.execute at ${adapter_exec}"
  ok "carried forward: the locally executed path is gated at line ${adapter_gate}, ahead of line ${adapter_exec}"

  # The reader exists, is shared, and the fail-open the old guard carried is
  # gone. `attempt_number == 1` as a MATCH CONDITION is what let a result with
  # any other value block nothing.
  grep -q "^def existing_terminal_result" <<<"${evidence_source}" \
    || halt "the reviewed evidence.py defines no shared terminal-result reader"
  grep -q "^def require_no_terminal_result" <<<"${evidence_source}" \
    || halt "the reviewed evidence.py defines no gate wrapper"
  grep -q 'existing.get("attempt_number") == 1' <<<"${evidence_source}" \
    && halt "the reviewed evidence.py still matches on attempt_number == 1: a result carrying any other value would block nothing"
  ok "carried forward: evidence.py carries one shared reader and no attempt_number fail-open"

  # Both callers go through the one wrapper, so the gate and the recording guard
  # cannot drift into two different answers.
  [[ "$(grep -c "require_no_terminal_result" <<<"${evidence_source}")" -ge 2 ]] \
    || halt "the reviewed evidence.py does not use its own gate wrapper in record_terminal_result"
  ok "carried forward: the gate and the recording guard answer through the same reader"

  note "no installed path was read for state and none was written"
  printf '\n'
  printf 'Generation 22 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded
  require_governed_stores_unreachable
  require_operation_shape
  require_fail_closed_first
  require_carryover_unmoved

  classify_all
  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 22; use --verify-installed to audit the installed generation"
    require_gates_closed
    verify_excluded_absent
    require_group_coherence
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 22 / supervised execution runtime verify: already installed.\n'
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
    ok "the host is at Generation 21 and ready for the Generation-22 installation: $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE, $(matrix_count) changed objects across $(matrix_groups | wc -l) coherence groups, object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
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
  require_governed_stores_unreachable
  require_operation_shape
  require_fail_closed_first
  require_carryover_unmoved
  require_gates_closed

  # The generation that created it. Generations 19 and 20 read `gen18-`: the
  # prefix was carried forward with the installer and never renamed, so those
  # transactions identified themselves as Generation 18's. Generation 21
  # corrected that, and this generation is named too. Transaction evidence that
  # misnames its own generation is evidence an operator has to correct by hand
  # before it can be read.
  TRANSACTION_ID="gen22-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
      ok "Generation 22 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 22 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 21 and nothing was installed"
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
  require_operation_shape
  require_privileged_surface_excluded
  require_governed_stores_unreachable
  verify_installed_set
  verify_excluded_absent
  # THE TWO HALVES OF THE INSTALLED SURFACE, each by the check that can
  # actually fail for it.
  #
  # `verify_installed_set` judges the two MATRIX TARGETS -- both of them, and
  # `cli.py` IS one in this generation -- against the reviewed Generation-22
  # digests. Every one of them being at its target digest is what
  # "no mixed-generation publication" means: a half-published matrix leaves at
  # least one target at its Generation-21 digest and fails there.
  #
  # `verify_unchanged_surface` judges EVERYTHING ELSE. It skips matrix targets
  # deliberately -- they are judged above -- and proves no other installed
  # object moved. `require_carryover_unmoved` then proves the source side did
  # not move underneath either of them.
  verify_unchanged_surface
  require_carryover_unmoved
  require_group_coherence
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"

  # THE INSTALLED BYTES, NOT THE REVIEWED ONES. `verify_installed_set` already
  # proves each target is at its pinned digest, which is a comparison against a
  # number written in this file. This runs the same property verifier the source
  # mode runs, against what is actually on the host -- so "installed" means the
  # architecture is there, and not merely that two hashes matched.
  prove_adr0018 "${LIBRARY_ROOT}" "the installed library at ${LIBRARY_ROOT}"
  [[ -f "${GEN22_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-22 library evidence is missing"
  [[ -f "${GEN22_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-22 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-21 evidence was not preserved"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-21 helper evidence was not preserved"
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
    bad "recovery rolled the transaction back: the host is at Generation 21 and Generation 22 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 22 / supervised execution runtime %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 22 / supervised execution runtime %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
