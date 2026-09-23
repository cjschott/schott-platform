#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 21: a successful execution can be closed, and say so.
#
# WHAT THIS DEPLOYS. SEVEN objects, in ONE coherence group:
#
#   P  post-execution lifecycle conclusion (ADR-0017).
#      `types.py` appends the `CONCLUDED` state; `state.py` permits
#      `launch_authorized -> concluded` and nothing else; `capacity.py` names
#      it in the occupancy exclusion so it holds no slot; `recovery.py` treats
#      it as administratively closed so it is never offered as resumable;
#      `admin.py` adds the closed-set `conclude` verb; `conclusion.py` is the
#      operation; `cli.py` carries the new operator surface and closes a
#      supervised execution inline.
#
# WHAT WENT WRONG -- AND IT IS NOT STAGE 3. CINV-000003 executed successfully on
# 2026-09-22. The privileged transition dropped, the governed container ran the
# payload, disposal was proven, and the coordinator wrote CRES-000002:
# outcome_class completed, result_digest sha256:fd2d58e9...cbad7, reason null.
#
# And the invocation is still `launch_authorized`.
#
# That is designed behaviour, established at G11-BC-I: the journal is written by
# `authorise_launch` BEFORE the privilege boundary is crossed, and the states
# past `launch_authorized` are worker-side protocol states that exist on the
# wire and never in the journal. What had never been stated is the consequence:
#
#   EVERY SUCCESSFUL SUPERVISED EXECUTION STRANDS, holding an execution slot for
#   ever, because `released` is reachable only through states nothing writes.
#
# Measured, not inferred. An AST sweep of the released package shows the only
# lifecycle states any code writes are `launch_authorized`, `cleaned`,
# `released` and `abandoned`. Reachability from `launch_authorized` through
# states that can actually be written yields exactly one destination:
# `abandoned`.
#
# THE OBVIOUS FIX WAS TRIED FIRST, AND IT CANNOT WORK. G11-BC-AD implemented
# journalling the progression the coordinator drove and letting the existing
# `cleanup` and `capacity.release` finish. `cleanup` records `cleaned` only
# after the per-CINV handoff subtree is gone, and §13 transfers the output leaf
# to the execution identity:
#
#   /data/kyri/capability-handoff/CINV-000003        the coordinator, mode 0555
#   /data/kyri/capability-handoff/CINV-000003/out    the EXECUTION identity, 0700
#
# The deployment's actual numbers are deliberately not written here -- they are
# a fact about a deployment, which is why G11-AH removed the compiled-in ones.
# What matters is that the leaf is not the coordinator's: it cannot open it,
# empty it, or remove it.
# Released `cleanup` refuses with `CleanupIncomplete: directory 'out' could not
# be opened`, and nothing in the released system -- the reconcile helper, a
# tmpfiles rule, anything -- removes it. So `cleaned` is STRUCTURALLY
# UNREACHABLE for every supervised invocation, and `released` with it. That is a
# latent gap between §13 and the cleanup design, not a defect Stage 3 created,
# and this generation deliberately does not repair it.
#
# WHAT `CONCLUDED` CLAIMS, AND WHAT IT DOES NOT. It says the execution ran,
# concluded, and its terminal result is durable -- and that the cleanup
# progression did NOT run. It is not `released`, which additionally claims the
# invocation was classified, collected and cleaned. It is not `abandoned`, which
# declines to say what happened: because the supervised path strands EVERY
# success, reusing the exceptional closure for them would make `abandoned` the
# normal end of the happy path and destroy the property ADR-0015 exists to
# create -- that a stranded invocation is distinguishable from a completed one
# for ever.
#
# PUBLICATION ORDER IS THE SAFETY PROPERTY, AND IT WAS MEASURED, NOT INHERITED.
# Every intermediate was run by importing `tools.capability.cli` against it:
#
#   published so far                     tools.capability.cli   conclude verb
#   -----------------------------------  ---------------------  -------------
#   (Generation 20)                      imports                no
#   + types                              imports                no
#   + state                              imports                no
#   + capacity                           imports                no
#   + recovery                           imports                no
#   + admin                              imports                no
#   + conclusion                         imports                no
#   + cli  (Generation 21)               imports                YES
#
# NO INTERMEDIATE CAN CLOSE AN INVOCATION, and none changes an operator surface
# until the last step:
#
#   - `types.py` first ADDS A NAME. No transition reaches `CONCLUDED`, no
#     exclusion names it, and nothing writes it.
#   - `state.py` second permits a transition NOTHING CALLS.
#   - `capacity.py` third excludes a state that cannot yet exist, so occupancy
#     is arithmetically unchanged.
#   - `recovery.py` fourth closes a state nothing can be in.
#   - `admin.py` fifth adds a verb NOTHING CAN REACH -- `conclusion.py` does not
#     exist yet and no module names it.
#   - `conclusion.py` sixth is unreachable: no operator surface names it.
#   - `cli.py` last is the ONLY step that changes an operator surface.
#
# THE REVERSE ORDER WAS MEASURED TOO, and it fails differently from Generation
# 20's -- worse, not better. `cli.py` imports `conclusion` LAZILY, inside the
# two functions that use it, so publishing it first does NOT fail closed at
# import. It exposes a `conclude` verb that raises `ImportError` when used, and
# -- far worse -- `execute` would record a durable result and THEN raise from
# the inline closure. `conclusion.py` BEFORE `cli.py` is what makes that state
# unreachable, and `rollback` restores in reverse so it is unreachable from
# either direction.
#
# ONE OBJECT IS A CREATE. `conclusion.py` does not exist at Generation 20, so
# the installed library grows by one. Both counts are stated, and rollback
# deletes the created file rather than restoring a backup that never existed.
#
# EXECUTION STAYS OPEN THROUGH THIS GENERATION. No readiness authority moves:
# `helpers.py` is untouched, compatibility stays `compatible`, blocking stays 0
# and supervision_ready stays true at every state. There is nothing to reopen
# and no helper ceremony to follow.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. No helper object, no entrypoint, no
# worker, no quota module, no readiness authority, no container-runtime binding,
# no sudoers grant, no execution image, no deployment identity authority, and
# not one byte of Fabric, Trust, or invocation history. It does NOT repair the
# handoff residue and does NOT touch the privileged transition.
#
# WHAT IT DOES NOT TOUCH IN THE RUNTIME STORE. CINV-000001, CINV-000002 and
# CINV-000003 are not read, not written and not referenced. No CADM is read or
# touched. CRES-000001 and CRES-000002 are final and are not touched. Occupancy
# stays 2 of 2 across this publication -- closing CINV-000003 is a separate
# operator ceremony that runs AFTER this generation is accepted.
#
COMMIT="0bd3b8acf9953126b9e1ba3eda07b282debd7c78"

# The accepted Generation-21 source authority, and the baseline this transaction
# requires the host to be at.
GEN20_COMMIT="6ba8e5c951f8c98bb1e0e9cc0997d497f7445202"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# This transaction's own namespace. Generation 20's retained journal at
# /root/kyri-gen20-transaction is predecessor evidence: it records how the host
# reached the state this transaction starts from, it is never read as this
# transaction's state, and nothing here writes to or removes it. Deriving an
# installer from its predecessor and leaving the predecessor's path in place is
# what made the first real Generation-14 attempt halt against a COMMITTED
# journal belonging to a transaction that had already finished.
TRANSACTION_ROOT="/root/kyri-gen21-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen20-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen20-helper-digests.txt"
GEN21_LIBRARY_EVIDENCE="/root/kyri-gen21-library-digests.txt"
GEN21_HELPER_EVIDENCE="/root/kyri-gen21-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS="/etc/sudoers.d/kyri-exec-launch"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# The two deployment identity authorities. Read to prove this ceremony did not
# create them; never written. Generation 21 does not need them to install.
COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# ONE CREATE, so the count moves by one: `conclusion.py` does not exist at
# Generation 20. Both ends are stated so the move is declared rather than
# discovered -- a matrix that quietly gained or lost a CREATE row would change
# the installed object count, and stating the expectation on both sides is what
# turns that into a refusal here rather than a surprise at publication.
EXPECTED_LIBRARY_FILES_BASELINE=82
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
  GEN21_LIBRARY_EVIDENCE="${FIXTURE}${GEN21_LIBRARY_EVIDENCE}"
  GEN21_HELPER_EVIDENCE="${FIXTURE}${GEN21_HELPER_EVIDENCE}"
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
PREPARED_SUFFIX=".kyri-gen21.new"
BACKUP_SUFFIX=".kyri-gen21.gen20"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

CLOSURE_STAGING=""
PREPARING=0

# --- the seven generation-21 objects, pinned both ways ---------------------
#
# source | target | mode | operation | gen20-sha256 | gen21-sha256 | group
#
# Six targets sit in directories that already exist at Generation 20. The
# seventh, `conclusion.py`, is a CREATE into an existing directory, so there is
# still no directory to make and none to remove on rollback -- rollback deletes
# the created file.
#
# THE ONE GROUP, AND WHY IT IS ONE.
#
#   P  post-execution lifecycle conclusion (ADR-0017).
#      `types.py` owns the `CONCLUDED` state itself; `state.py` owns the one
#      transition that reaches it; `capacity.py` owns whether it holds a slot;
#      `recovery.py` owns whether it may be offered as resumable; `admin.py`
#      owns the closed-set verb; `conclusion.py` is the operation; `cli.py` is
#      the only operator surface that can reach it.
#
#      No member is a valid complete Generation 21 on its own, and each way it
#      breaks is different. `state.py` at 21 against `types.py` at 20 is an
#      AttributeError on `LifecycleState.CONCLUDED` -- and `state.py` is
#      imported by everything that reads a lifecycle, so that lands on every
#      command. `capacity.py` at 20 against a store holding a `concluded`
#      record would count it as holding a slot, which is an occupancy answer
#      that is wrong rather than an error. `recovery.py` at 20 would fall
#      through its positional lookup for a state that is not on the linear
#      order. `conclusion.py` at 21 against `admin.py` at 20 is an
#      AttributeError on `Verb.CONCLUDE`. `cli.py` at 21 against
#      `conclusion.py` absent is an ImportError -- and because `cli.py` imports
#      it LAZILY, not at module level, that one does not land until the verb is
#      used or an execution tries to close itself, which is why publication
#      order puts `conclusion.py` first and `cli.py` last.
#
# THE LETTER. P was Generation 20's, and it is reused here deliberately: this
# generation publishes one group and the letter names it for this matrix.
#
# There is no CARRYOVER: every member of P is a row here.
#
# source | target | mode | operation | gen20-sha256 | gen21-sha256 | group
MATRIX=(
# --- P: post-execution lifecycle conclusion. THE ORDER IS DEPENDENCY-SAFE AND
#        IT WAS MEASURED, NOT INHERITED. Each object is published only after
#        everything it imports, and every intermediate was run:
#
#          published so far        tools.capability.cli   conclude verb
#          ----------------------  ---------------------  -------------
#          (Generation 20)         imports                no
#          + types                 imports                no
#          + state                 imports                no
#          + capacity              imports                no
#          + recovery              imports                no
#          + admin                 imports                no
#          + conclusion            imports                no
#          + cli  (Generation 21)  imports                YES
#
#        NO INTERMEDIATE CAN CLOSE AN INVOCATION. `types.py` adds a name no
#        transition reaches; `state.py` permits a transition nothing calls;
#        `capacity.py` excludes a state that cannot exist yet, so occupancy is
#        arithmetically unchanged; `recovery.py` closes a state nothing can be
#        in; `admin.py` adds a verb nothing can reach; `conclusion.py` is
#        unreachable until an operator surface names it.
#
#        The reverse order fails DIFFERENTLY from Generation 20's, and worse.
#        `cli.py` imports `conclusion` lazily, inside the two functions that use
#        it, so publishing it first does not fail closed at import: it exposes a
#        `conclude` verb that raises ImportError when used, and `execute` would
#        record a durable result and THEN raise from the inline closure.
#        `conclusion.py` before `cli.py` is what makes that unreachable.
"tools/capability/execution/types.py|${LIBRARY_ROOT}/tools/capability/execution/types.py|0444|REPLACE|da2e01f9f13a9b8dfbf736f7b66839cf2e688e350d8f0515340fd051e98e66ae|6f0c8fa63333cb2880ba195c25fac35f15ad81a9fe82811e112d89f706520f44|P"
"tools/capability/execution/state.py|${LIBRARY_ROOT}/tools/capability/execution/state.py|0444|REPLACE|88b05c076d9da134ddb1dfe38c38624297246cd313e243b540eaff7af1901f3b|9257af07498d5922107f55502f9f07c26ca70ec7544ad4f4628c515964a07980|P"
"tools/capability/execution/capacity.py|${LIBRARY_ROOT}/tools/capability/execution/capacity.py|0444|REPLACE|f037119f9a986558fe8e6c8bbc77a4ba49d28d97ddc3d4d5c4328b707757159e|650c05dd3c5ebe3496c468181c7c8770954f79fe73675eec6efa210b01472eb3|P"
"tools/capability/execution/recovery.py|${LIBRARY_ROOT}/tools/capability/execution/recovery.py|0444|REPLACE|d044cb29a32714945d0d76db59ca3c44cd77d4978e5781fedc073e675b897173|5efec912fdf27add88dadefd2afcb50c698bae4db3296f9926897e272aad9490|P"
"tools/capability/execution/admin.py|${LIBRARY_ROOT}/tools/capability/execution/admin.py|0444|REPLACE|f691f914058491b1e7ccb3dd8498a667588a4fe36ffee13b0777733617845606|b4ea351b3e34e5d4674c72fce14465761eff1eb8444edb7019fcd7d1c0dc7be9|P"
"tools/capability/execution/conclusion.py|${LIBRARY_ROOT}/tools/capability/execution/conclusion.py|0444|CREATE|ABSENT|d24ad855e787fce1720df1f8d15f068f65aba46464c1e1382b5e3b68749297b2|P"
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|90979a0247d9cc0c28d9bce10be96e0b5205acca1d887db96f5794d6602c9c23|82eb3ffe2d73655913f8d5e6e9cb4e799f47d15b4b266843e58b9fea3cc7425c|P"
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
# this generation only moves P. The names outlive the generation that
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
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# EVERY LETTER THE MATRIX CAN CARRY HAS A CASE ABOVE, AND THAT IS CHECKED.
#
# Generation 18 put a row in group A and never added a case for it, so a split
# in that group would have reported "unknown group A" -- the exact failure its
# own comment said the names exist to prevent. A diagnostic defect only, and it
# is in an accepted installer so it is reported rather than edited here; neither
# Generation 20 nor this one repeats it, and P has a case.
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
  [[ -n "${FIXTURE}" && "${KYRI_GEN20_FAIL_AT:-}" == "$1" ]]
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 20\n' \
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
    printf 'baseline_commit=%s\n' "${GEN20_COMMIT}"
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
      bad "group ${group} ($(group_name "${group}")) is split: ${at_baseline} object(s) at Generation 21 and ${at_target} at Generation 21"
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
    || halt "the reviewed Generation-21 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-21 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN20_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-20 authority is not an ancestor of the Generation-21 authority"
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
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-21 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-21 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
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

  # What the predecessor provides, decided from the reviewed Generation-20
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
    if git_as_owner cat-file -e "${GEN20_COMMIT}:${source}" 2>/dev/null; then
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
#     -- the last ceremony accepted BEFORE Generation 21 that governs it,
#        or Generation-20 evidence when none does
#   PLUS the target of every ceremony accepted AFTER Generation 21 that governs it
#
# EVERY HELPER CEREMONY IS "BEFORE", AND THAT IS THE WHOLE DIFFERENCE FROM
# GENERATION 15'S COPY OF THIS LIST. G11-BB was still pending when Generation 15
# installed, so that generation had to accept both sides of it -- an object could
# legitimately be at G11-AX's target or at G11-BB's depending on whether the
# ceremony had run yet. G11-BB was accepted at G11-BB-R, and G11-BC-E before
# Generation 20, so there is exactly ONE accepted state per object again:
# kyri_exec_transition_action.py at b11a2f19 and kyri_exec_quota.py at 54a9b15c,
# with the earlier G11-AX states now superseded and correctly refused.
#
# The AFTER list is EMPTY, and that is a claim this ceremony is making: no
# accepted ceremony is scheduled to run after Generation 21. If one is later
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
# NO HELPER CEREMONY FOLLOWS THIS GENERATION, as none followed Generation 20.
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
    || halt "the installed library holds ${count} objects, expected the Generation-20 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-20 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-20 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"

    # This is not "ignore helper files". The overlay is read from an accepted
    # ceremony's own matrix, one path at a time; an object no ceremony declares
    # is still judged against Generation-20 evidence and still refuses.
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is absent from the Generation-20 evidence"
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
      || { bad "the Generation-20 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-20 baseline"
  ok "the installed runtime is exactly the accepted Generation-20 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-20 baseline nor the Generation-21 target"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 21 is installed and unaffected. Remove them with --recover or by hand."
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
# exists yet -- Generation-20 behaviour, with a name nothing imports and a verb
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
# This generation publishes five objects and four of them sit on one import
# chain, so the intermediates are not equivalent and there is exactly one safe
# sequence. Publication follows matrix order, so "backing_store.py is published
# first" is only true while it is row one. A later edit that reordered the
# matrix would make every `tools.capability.cli` command -- including `recover`
# -- fail to import for the length of the transaction, and nothing else in the
# ceremony would notice. This refuses instead.
FAIL_CLOSED_FIRST="tools/capability/execution/types.py"
# The operator surface, which must be LAST, and here for a sharper reason than
# at Generation 20. `cli.py` imports `conclusion` LAZILY, so publishing it early
# does not fail closed at import: it would expose a `conclude` verb that raises
# ImportError when used, and `execute` would record a durable result and THEN
# raise from the inline closure. Last is what makes that unreachable.
OPERATOR_SURFACE_LAST="tools/capability/cli.py"

# The dependency-safe publication order, in full. Each object is published
# only after everything it imports. Measured, see the MATRIX header.
PUBLICATION_ORDER=(
"tools/capability/execution/types.py"
"tools/capability/execution/state.py"
"tools/capability/execution/capacity.py"
"tools/capability/execution/recovery.py"
"tools/capability/execution/admin.py"
"tools/capability/execution/conclusion.py"
"tools/capability/cli.py"
)

require_fail_closed_first() {
  local index=0 declared actual
  (( ${#MATRIX[@]} == ${#PUBLICATION_ORDER[@]} )) \
    || halt "the matrix holds ${#MATRIX[@]} rows and the declared order ${#PUBLICATION_ORDER[@]}: every object must have a stated position"
  for declared in "${PUBLICATION_ORDER[@]}"; do
    actual="$(field "${MATRIX[${index}]}" 0)"
    [[ "${actual}" == "${declared}" ]] \
      || halt "matrix row ${index} is ${actual}, and the dependency-safe order puts ${declared} there: an object published before something it imports is an ImportError on every command"
    [[ "$(field "${MATRIX[${index}]}" 6)" == "P" ]] \
      || halt "${actual} is not in coherence group P: no member of this generation is valid alone"
    index=$((index + 1))
  done

  # The two ends carry the property, so they are named as well as ordered.
  [[ "$(field "${MATRIX[0]}" 0)" == "${FAIL_CLOSED_FIRST}" ]] \
    || halt "the first published object is not ${FAIL_CLOSED_FIRST}: the target fingerprint must exist before anything imports it"
  [[ "$(field "${MATRIX[$(( ${#MATRIX[@]} - 1 ))]}" 0)" == "${OPERATOR_SURFACE_LAST}" ]] \
    || halt "the last published object is not ${OPERATOR_SURFACE_LAST}: the operator surface must not be reachable before the operation it calls exists"

  ok "all ${#MATRIX[@]} objects publish in the measured dependency-safe order, group P, ${FAIL_CLOSED_FIRST##*/} first and ${OPERATOR_SURFACE_LAST##*/} last"
}

# The coherence-group member this generation does NOT move, checked on both
# sides. Empty for Generation 21 -- every member of both groups is a row -- but
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
  (( replaces == 6 )) \
    || bad "the matrix holds ${replaces} REPLACE rows, expected 6"
  (( creates == 1 )) \
    || bad "the matrix holds ${creates} CREATE rows, expected 1"
  [[ "${created_target}" == "${LIBRARY_ROOT}/tools/capability/execution/conclusion.py" ]] \
    || bad "this generation's CREATE is ${created_target:-absent}, expected conclusion.py"
  local expected_move=$(( EXPECTED_LIBRARY_FILES_TARGET - EXPECTED_LIBRARY_FILES_BASELINE ))
  (( expected_move == creates )) \
    || bad "the declared library count moves by ${expected_move} but the matrix holds ${creates} CREATE row(s)"
  (( FAILURES == 0 )) \
    && ok "the matrix is 6 REPLACE and 1 CREATE, the CREATE is conclusion.py, and the declared count moves ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET} by exactly that one row"
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
    note "the coordinator identity authority is not installed; Generation 21 installs without it"
    ready=0
  fi
  if [[ ! -f "${EXECUTION_IDENTITY}" ]]; then
    note "the execution identity authority is not installed; Generation 21 installs without it"
    ready=0
  fi
  if (( ready == 1 )); then
    note "both deployment identity authorities are installed"
  else
    note "this host will be at Generation 21 and NOT execution-ready: the deployment identity ceremony is a separate one, and the runtime refuses execution until it has run"
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
    injected_at staged && halt "injected failure after staging a Generation-21 object"
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN20_FAIL_AT:-}" == "${index}" ]]; then
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
    && bad "injected failure immediately after COMMITTED; Generation 21 stands"
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

  # Reverse of the publication order, and with five rows on one import chain it
  # is load-bearing rather than ceremonial: `cli.py` goes back FIRST, so the
  # restored surface never runs against a library that has already been rolled
  # back beneath it. Restoring forward would put the Generation-20 `cli.py`
  # against a Generation-21 `provenance.py` for the length of the unwind, which
  # is the ModuleNotFoundError state from the other direction.
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
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 20 (${removed} restored or removed)"
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
      bad "UNKNOWN bytes at ${target} (neither the Generation-20 baseline nor the Generation-21 target, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-21 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-21 object was published; the host is at Generation 20"
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
    || halt "Generation-20 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-21 evidence; Generation 21 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN21_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN21_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN21_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-21 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN20_COMMIT}"
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
  } > "${GEN21_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN21_LIBRARY_EVIDENCE}.writing" "${GEN21_HELPER_EVIDENCE}.writing"
  sync_path "${GEN21_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN21_HELPER_EVIDENCE}.writing"
  mv -f "${GEN21_LIBRARY_EVIDENCE}.writing" "${GEN21_LIBRARY_EVIDENCE}"
  mv -f "${GEN21_HELPER_EVIDENCE}.writing" "${GEN21_HELPER_EVIDENCE}"
  sync_path "${GEN21_LIBRARY_EVIDENCE}"
  sync_path "${GEN21_HELPER_EVIDENCE}"
  ok "Generation-21 evidence written; Generation-20 evidence preserved"
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
    bad "injected cleanup failure after COMMITTED; Generation 21 remains installed"
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
    || bad "the installed library holds ${count} objects, expected the Generation-21 ${EXPECTED_LIBRARY_FILES_TARGET} plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) Generation-21 changed objects correspond to the reviewed commit ${COMMIT}"
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
# The accepted authority is Generation 20 PLUS what accepted ceremonies
# published after it -- the same overlay model `require_baseline` uses, through
# the same reader. Carrying a second, overlay-blind copy of this comparison is
# what refused a COMMITTED Generation-21 transaction: the four G11-AX
# library-root objects were reported as drift for holding exactly the bytes
# that ceremony was accepted for.
verify_unchanged_surface() {
  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is not accounted for by the Generation-20 evidence or any accepted ceremony, and is not a declared Generation-21 target"
      drift=$((drift + 1)); continue
    fi
    read -r authority recorded <<<"${accepted}"
    observed="$(digest_of "${file}")"
    if matches_accepted_state "${observed}" "${recorded}"; then continue; fi
    if [[ "${authority}" == "ceremony" ]]; then
      bad "${relative} changed: ${observed} but the accepted helper ceremon(ies) record ${recorded}"
    else
      bad "${relative} changed: ${observed} but Generation-20 evidence records ${recorded}"
    fi
    drift=$((drift + 1))
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  overlay_complete "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" || drift=$((drift + 1))

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-20 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every carried-over runtime object is exactly its accepted predecessor -- Generation 20, plus the $(helper_ceremony_library_rows "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" | wc -l) object(s) an accepted ceremony published after it -- and nothing was removed"
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
  # A grep for "conclude" would pass on a verb that fabricated a result, claimed
  # a cleanup that never ran, or released a slot by some route other than
  # entering CONCLUDED. Each ADR-0017 property is checked where it is decided,
  # and the checks that a grep would be too weak for are done structurally
  # against the parsed source.
  admin_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/admin.py")"
  cli_source="$(git_as_owner show "${COMMIT}:tools/capability/cli.py")"
  types_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/types.py")"
  capacity_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/capacity.py")"

  # The reviewed bytes are staged so the structural checks parse exactly what
  # the matrix publishes, rather than whatever happens to be in the checkout.
  gen21_stage="$(mktemp -d)" || halt "cannot stage the reviewed Generation-21 source"
  for relative in tools/capability/execution/types.py \
                  tools/capability/execution/state.py \
                  tools/capability/execution/capacity.py \
                  tools/capability/execution/recovery.py \
                  tools/capability/execution/admin.py \
                  tools/capability/execution/conclusion.py \
                  tools/capability/cli.py; do
    mkdir -p "${gen21_stage}/$(dirname "${relative}")"
    git_as_owner show "${COMMIT}:${relative}" > "${gen21_stage}/${relative}" \
      || { rm -rf "${gen21_stage}"; halt "the reviewed commit carries no ${relative}"; }
  done

  gen21_report="$(python3 - "${gen21_stage}" <<'GEN21_PY'
"""Prove ADR-0017 from the reviewed source, structurally.

Printed one verdict per property: `ok <text>` or `FAIL <text>`. The caller
halts on the first FAIL. Nothing here imports the reviewed modules -- they are
parsed, because importing would run them.
"""
import ast
import os
import sys

STAGE = sys.argv[1]
findings = []


def parse(relative):
    with open(os.path.join(STAGE, relative), encoding="utf-8") as handle:
        return ast.parse(handle.read()), handle


def source(relative):
    with open(os.path.join(STAGE, relative), encoding="utf-8") as handle:
        return handle.read()


def check(condition, text):
    findings.append(("ok" if condition else "FAIL", text))
    return bool(condition)


def enum_members(tree, name):
    """The `NAME = "value"` members of a class, in declaration order."""
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == name:
            out = []
            for item in node.body:
                if (isinstance(item, ast.Assign) and len(item.targets) == 1
                        and isinstance(item.targets[0], ast.Name)
                        and isinstance(item.value, ast.Constant)):
                    out.append((item.targets[0].id, item.value.value))
            return out
    return []


def module_assign(tree, name):
    """The value node of a module-level `name = ...`."""
    for item in tree.body:
        if (isinstance(item, ast.Assign) and len(item.targets) == 1
                and isinstance(item.targets[0], ast.Name)
                and item.targets[0].id == name):
            return item.value
        if (isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name)
                and item.target.id == name):
            return item.value
    return None


def state_names(node):
    """Every `LifecycleState.X` named anywhere under `node`."""
    return {n.attr for n in ast.walk(node)
            if isinstance(n, ast.Attribute)
            and isinstance(n.value, ast.Name)
            and n.value.id == "LifecycleState"}


def function(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def dict_entry(node, key):
    """The value node for a string key in any dict literal under `node`.

    Structural on purpose. Matching the unparsed text would depend on how the
    printer quotes a key, which is a property of the printer and not of the
    reviewed source.
    """
    for literal in ast.walk(node):
        if isinstance(literal, ast.Dict):
            for k, value in zip(literal.keys, literal.values):
                if isinstance(k, ast.Constant) and k.value == key:
                    return value
    return None


# --- 1. the state exists, and is appended rather than inserted -------------
types_tree, _ = parse("tools/capability/execution/types.py")
members = enum_members(types_tree, "LifecycleState")
values = [value for _, value in members]
check("concluded" in values, "types.py declares CONCLUDED")
# Declaration order is read positionally when a transition is checked, so an
# INSERTION would silently redefine which transitions are legal.
check(values[:12] == ["reserved", "launch_authorized", "created",
                      "container_verified", "start_authorized", "started",
                      "running", "terminal", "classified", "collected",
                      "cleaned", "released"],
      "the linear progression is unchanged: CONCLUDED is appended, not inserted")

# --- 2/3. exactly one new edge, and it is terminal -------------------------
state_tree, _ = parse("tools/capability/execution/state.py")
allowed = module_assign(state_tree, "_ALLOWED")
edges = {}
if isinstance(allowed, ast.Dict):
    for key, value in zip(allowed.keys, allowed.values):
        if (isinstance(key, ast.Attribute) and isinstance(key.value, ast.Name)
                and key.value.id == "LifecycleState"):
            edges[key.attr] = state_names(value)
expected = {
    "RESERVED": {"LAUNCH_AUTHORIZED", "ABANDONED"},
    "LAUNCH_AUTHORIZED": {"CREATED", "ABANDONED", "CONCLUDED"},
    "CREATED": {"CONTAINER_VERIFIED"},
    "CONTAINER_VERIFIED": {"START_AUTHORIZED"},
    "START_AUTHORIZED": {"STARTED"},
    "STARTED": {"RUNNING"},
    "RUNNING": {"TERMINAL"},
    "TERMINAL": {"CLASSIFIED"},
    "CLASSIFIED": {"COLLECTED"},
    "COLLECTED": {"CLEANED"},
    "CLEANED": {"RELEASED"},
    "RELEASED": set(),
    "ABANDONED": set(),
    "CONCLUDED": set(),
}
check(edges == expected,
      "the transition relation is exactly the accepted one: launch_authorized "
      "gains concluded and NO other edge anywhere changes")
check(edges.get("CONCLUDED") == set(), "CONCLUDED is terminal: nothing leaves it")
reaching = {frm for frm, targets in edges.items() if "CONCLUDED" in targets}
check(reaching == {"LAUNCH_AUTHORIZED"},
      "launch_authorized is the ONLY state that reaches concluded")

# --- 4/5. capacity -----------------------------------------------------------
capacity_tree, _ = parse("tools/capability/execution/capacity.py")
non_holding = module_assign(capacity_tree, "NON_SLOT_HOLDING_STATES")
excluded = state_names(non_holding) if non_holding is not None else set()
check(excluded == {"RELEASED", "ABANDONED", "CONCLUDED"},
      "capacity excludes exactly RELEASED, ABANDONED and CONCLUDED from occupancy")
maximum = module_assign(capacity_tree, "MAXIMUM_SLOTS")
check(isinstance(maximum, ast.Constant) and maximum.value == 2,
      "MAXIMUM_SLOTS remains 2")

# --- 6. recovery -------------------------------------------------------------
recovery_tree, _ = parse("tools/capability/execution/recovery.py")
closed = module_assign(recovery_tree, "_ADMINISTRATIVELY_CLOSED")
closed_states = state_names(closed) if closed is not None else set()
check("CONCLUDED" in closed_states,
      "recovery treats CONCLUDED as administratively closed, never resumable")
order = module_assign(recovery_tree, "_LIFECYCLE_ORDER")
check("CONCLUDED" not in (state_names(order) if order is not None else set()),
      "CONCLUDED is off the linear order, so it is refused explicitly rather "
      "than by a positional lookup falling through")

# --- 7. the closed-set verb --------------------------------------------------
admin_tree, _ = parse("tools/capability/execution/admin.py")
verbs = dict(enum_members(admin_tree, "Verb"))
check(verbs.get("CONCLUDE") == "conclude", "admin declares the CONCLUDE verb")
destroys = module_assign(admin_tree, "_DESTROYS_UNDER")
check("CONCLUDE" not in {n.attr for n in ast.walk(destroys)
                         if isinstance(n, ast.Attribute)} if destroys is not None else False,
      "CONCLUDE carries NO destruction authority")

# --- 8. the operation itself -------------------------------------------------
conclusion_tree, _ = parse("tools/capability/execution/conclusion.py")
conclusion_text = source("tools/capability/execution/conclusion.py")
conclude_fn = function(conclusion_tree, "conclude")
body = ast.unparse(conclude_fn) if conclude_fn is not None else ""

check(conclude_fn is not None, "conclusion.py defines conclude")
startable = module_assign(conclusion_tree, "STARTABLE_STATE")
check(state_names(startable) == {"LAUNCH_AUTHORIZED"} if startable is not None else False,
      "the only state a conclusion may close is launch_authorized")
check("_terminal_result(store, identity)" in body
      and "has no terminal result" in body,
      "a terminal result for the SAME invocation is required, and its absence "
      "is a refusal that points at recovery")
check("result_record_id" in body and "capability_result_id" not in body.split("_terminal_result")[0],
      "the result is referenced by identity, not reconstructed")
# It must not allocate a result, mutate one, or reach a result writer.
for forbidden, why in (
        ("record_terminal_result", "fabricates a result"),
        ("allocate_cres", "allocates a result identity"),
        ("RESULT_KIND_WRITE", "writes through a result writer"),
        ("shutil", "reaches a tree remover"),
        ("unlink", "deletes"),
        ("rmdir", "removes a directory"),
        ("subprocess", "starts a process"),
        ("podman", "reaches a container runtime")):
    check(forbidden not in conclusion_text,
          f"conclusion.py never {why} ({forbidden} absent)")
# Exactly one lifecycle transition, and it is the one that releases the slot.
transitions = [n for n in ast.walk(conclude_fn or ast.Module(body=[], type_ignores=[]))
               if isinstance(n, ast.Call)
               and getattr(n.func, "attr", "") in ("transition", "transition_locked")]
check(len(transitions) == 1, "conclude writes exactly ONE lifecycle transition")
check(transitions and "CONCLUDED" in state_names(transitions[0]),
      "that one transition is the one into CONCLUDED, which is what releases "
      "the slot -- there is no separate release step")
check("allocate_cadm" in body and body.count("allocate_cadm") == 1,
      "conclude allocates exactly ONE CADM")
retained = dict_entry(conclude_fn, "handoff_retained") if conclude_fn else None
check(isinstance(retained, ast.Constant) and retained.value is True,
      "the handoff residue is RECORDED rather than implied: handoff_retained is written true")
# It must claim neither a cleanup, nor released, nor abandoned.
for claimed in ("CLEANED", "RELEASED", "ABANDONED"):
    check(claimed not in state_names(conclude_fn) if conclude_fn is not None else False,
          f"conclude never names {claimed}: it claims no cleanup and no other closure")
check("cleanup" not in conclusion_text.split('"""', 2)[-1],
      "conclusion.py reaches no cleanup module outside its own prose")

# --- 9/10/11. the two callers, and which claim each makes --------------------
cli_tree, _ = parse("tools/capability/cli.py")
cli_text = source("tools/capability/cli.py")
check('conclude.add_argument("--store-root", required=True' in cli_text,
      "capability conclude requires an explicit --store-root, with no default")
command_conclude = function(cli_tree, "command_conclude")
command_execute = function(cli_tree, "command_execute")
conclude_body = ast.unparse(command_conclude) if command_conclude else ""
execute_body = ast.unparse(command_execute) if command_execute else ""
check("conclusion.conclude(" in conclude_body,
      "the operator verb calls the SAME conclusion primitive")
check("conclusion.conclude(" in execute_body,
      "the inline closure calls the SAME conclusion primitive")
check("DERIVATION_OBSERVED" in execute_body,
      "the inline closure records derivation=observed: it supervised what it closes")
check("DERIVATION_RECONSTRUCTED" in conclude_body,
      "the operator verb records derivation=reconstructed: it did not observe the run")
check("CAPABILITY_RUNTIME_ROOT" not in conclude_body,
      "command_conclude cannot resolve the compiled-in production root")

# --- 12. a closure that fails must not cost the result -----------------------
result_at = execute_body.find("execute_supervised")
closure_at = execute_body.find("conclusion.conclude(")
check(result_at != -1 and closure_at != -1 and result_at < closure_at,
      "the result is recorded BEFORE the closure is attempted, so a closure "
      "that fails cannot lose a recorded execution")
handler = execute_body[closure_at:] if closure_at != -1 else ""
check("except Exception" in handler and "conclusion_refused" in handler,
      "a failed closure is caught and REPORTED, not raised over a durable result")
reported = dict_entry(command_execute, "lifecycle_state") if command_execute else None
check(reported is not None and "launch_authorized" in ast.unparse(reported),
      "and the invocation is reported as still launch_authorized -- slot-holding, "
      "never falsely marked concluded")

for verdict, text in findings:
    print(verdict, text)
sys.exit(1 if any(v == "FAIL" for v, _ in findings) else 0)
GEN21_PY
  )" || { printf '%s\n' "${gen21_report}" | sed -n 's/^FAIL /STOP: the reviewed Generation-21 source does not prove: /p' >&2
          rm -rf "${gen21_stage}"
          halt "the reviewed source does not carry the ADR-0017 properties this generation publishes"; }
  rm -rf "${gen21_stage}"
  printf '%s\n' "${gen21_report}" | sed 's/^ok /ok       /'
  ok "ADR-0017 proved from the reviewed bytes: $(printf '%s' "${gen21_report}" | grep -c '^ok ') properties"

  # --- carried forward from Generation 20 / ADR-0015, as regression ---------
  #
  # RETAINED, AND ONLY THESE. Generation 20's own purpose -- the provenance
  # correction -- was proved when Generation 20 was accepted, and its evidence
  # lives in that ceremony. What is kept here is the subset that touches a file
  # THIS generation republishes: `admin.py`, `cli.py`, `types.py` and
  # `capacity.py` all move, so a regression in them would ship under this
  # matrix and belongs in this verifier.
  #
  # The checks that referenced `backing_store.py`, `abandonment.py` and
  # `provenance.py` are gone: this generation does not publish those files, so
  # asserting their internals here claimed an authority this matrix does not
  # have.
  grep -q 'CORRECT_PROVENANCE = "correct-provenance"' <<<"${admin_source}" \
    || halt "regression: the reviewed admin.py no longer declares CORRECT_PROVENANCE"
  grep -q 'ABANDON = "abandon"' <<<"${admin_source}" \
    || halt "regression: the reviewed admin.py no longer declares ABANDON"
  if grep -A10 "_DESTROYS_UNDER = {" <<<"${admin_source}" | grep -qE "Verb.(CORRECT_PROVENANCE|ABANDON|CONCLUDE)"; then
    halt "regression: the reviewed admin.py grants an administrative-closure verb destruction authority"
  fi
  ok "regression: the closed verb set still holds ABANDON and CORRECT_PROVENANCE, and no closure verb may destroy"

  # The root cause of the 2026-09-20 incident, re-checked because this
  # generation edits the file that carries it -- and because it adds a third
  # administrative mutator that had to obey the same rule.
  grep -q 'abandon.add_argument("--store-root", required=True' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py does not require an explicit --store-root for abandon"
  grep -q 'correct.add_argument("--store-root", required=True' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py does not require an explicit --store-root for correct-provenance"
  grep -q "^def _explicit_root" <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py has no explicit-root guard"
  compiled_roots="$(grep -c "CapabilityStore(CAPABILITY_RUNTIME_ROOT" <<<"${cli_source}" || true)"
  [[ "${compiled_roots}" == "3" ]] \
    || halt "regression: the reviewed cli.py resolves the compiled-in store root ${compiled_roots} times, expected exactly 3 -- authorise-launch, execute and recover"
  if grep -A16 "^def command_abandon" <<<"${cli_source}" | grep -q "CAPABILITY_RUNTIME_ROOT"; then
    halt "regression: the reviewed command_abandon still resolves the compiled-in production root"
  fi
  if grep -A16 "^def command_correct_provenance" <<<"${cli_source}" | grep -q "CAPABILITY_RUNTIME_ROOT"; then
    halt "regression: the reviewed command_correct_provenance resolves the compiled-in production root"
  fi
  ok "regression: all three administrative mutators take an explicit target, and none can resolve the constant"

  grep -q '"target": outcome.target' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py does not report the target a mutation was written through"
  ok "regression: the surface still reports the root a mutation was written through"

  # The operator surface still offers no target state -- now across three verbs.
  for forbidden in "--force" "--to" "--target-state"; do
    if grep -q -- "\"${forbidden}\"" <<<"${cli_source}"; then
      halt "regression: the reviewed cli.py exposes ${forbidden}: no administrative verb may become a force-transition surface"
    fi
  done
  grep -q 'add_parser("abandon")' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py exposes no abandon subcommand"
  grep -q 'add_parser("correct-provenance")' <<<"${cli_source}" \
    || halt "regression: the reviewed cli.py exposes no correct-provenance subcommand"
  grep -q 'add_parser("conclude")' <<<"${cli_source}" \
    || halt "the reviewed cli.py exposes no conclude subcommand"
  ok "regression: all three administrative verbs are exposed and none takes a target state"

  # ADR-0015 is not regressed by the two files this generation edits that
  # carry it. `abandonment.py` itself does not move, so its internals are not
  # asserted here.
  grep -q 'ABANDONED = "abandoned"' <<<"${types_source}" \
    || halt "regression: the reviewed types.py no longer declares ABANDONED"
  grep -q 'RELEASED = "released"' <<<"${types_source}" \
    || halt "regression: the reviewed types.py no longer declares RELEASED"
  grep -q "MAXIMUM_SLOTS = 2" <<<"${capacity_source}" \
    || halt "regression: the reviewed capacity.py does not keep MAXIMUM_SLOTS at 2"
  ok "regression: ADR-0015 intact -- ABANDONED alongside RELEASED, and MAXIMUM_SLOTS still 2"

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
  printf 'Generation 21 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
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
    note "all $(matrix_count) targets are already at Generation 21; use --verify-installed to audit the installed generation"
    require_gates_closed
    verify_excluded_absent
    require_group_coherence
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 21 / supervised execution runtime verify: already installed.\n'
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
    ok "the host is at Generation 20 and ready for the Generation-21 installation: $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE, $(matrix_count) changed objects across $(matrix_groups | wc -l) coherence groups, object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
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

  # The generation that created it. This read `gen18-` through Generations 19,
  # 20 and 21: the prefix was carried forward with the installer and never
  # renamed, so every transaction since has identified itself as Generation 18's.
  # Transaction evidence that misnames its own generation is evidence an
  # operator has to correct by hand before it can be read.
  TRANSACTION_ID="gen21-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
      ok "Generation 21 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 21 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 20 and nothing was installed"
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
  # `verify_installed_set` judges the seven MATRIX TARGETS -- including
  # `cli.py`, which IS a target in this generation -- against the reviewed
  # Generation-21 digests. Every one of them being at its target digest is what
  # "no mixed-generation publication" means: a half-published matrix leaves at
  # least one target at its Generation-20 digest and fails there.
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
  [[ -f "${LIBRARY_ROOT}/tools/capability/execution/conclusion.py" ]] \
    || bad "conclusion.py is absent: this generation's CREATE did not land"
  [[ -f "${GEN21_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-21 library evidence is missing"
  [[ -f "${GEN21_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-21 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-20 evidence was not preserved"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-20 helper evidence was not preserved"
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
    bad "recovery rolled the transaction back: the host is at Generation 20 and Generation 21 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 21 / supervised execution runtime %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 21 / supervised execution runtime %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
