#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 16: the recovery-discovery key, deployed.
#
# WHAT THIS DEPLOYS. ONE object, in one coherence group:
#
#   R  supervised recovery discovery. `_invocation_identity` preferred the
#      OPAQUE `invocation_id` over the record's `invocation_record_id`. The
#      lifecycle journal is keyed by the CINV -- `authorise_launch` transitions
#      on it -- so `states.get(identity)` missed on every real invocation,
#      `unresolved_invocations` returned nothing, and `execution_safety`
#      reported READY having inspected nothing. Both production invocations sat
#      at `launch_authorized` and undiscoverable. G11-BC-A corrected it at the
#      source of the mismatch; this generation is how those bytes reach the
#      host.
#
# WHY THIS GENERATION EXISTS AT ALL. `recovery.py` is a Generation-15 declared
# runtime object, and the G5 preflight refuses a checkout carrying bytes no
# generation declares as a successor. That refusal is the deployment rule: a
# generation-declared object cannot be corrected in the repository without a
# generation declaring the successor. G11-BC-A stopped there deliberately rather
# than relax the check, and this is the governed way to resolve it.
#
# WHY GROUP R MOVES ALONE, AND WHY cli.py IS NOT CARRIED. Generation 15 put
# `recovery.py` and `cli.py` in group R together because the execution-root
# argument spans both: a recovery surface reading a root nobody passes, or a
# caller passing a root nobody reads, is neither generation. That contract was
# established at Generation 15 and this change does not touch it.
# `_invocation_identity` is private, has exactly one caller inside recovery.py,
# and no signature on the seam moves -- `unresolved_invocations`,
# `reconcile_unresolved`, `execution_safety` and the `Unresolved` record are all
# unchanged. `cli.py` is therefore BYTE-IDENTICAL across Generations 15 and 16
# at 7b4fac3e, and a carryover row for it would be actively wrong: `classify`
# tests the target digest FIRST, so a row whose baseline and target are the same
# value can never read BASELINE and can never register a split; and
# `verify_unchanged_surface` SKIPS every matrix target, so declaring cli.py
# would remove it from the one check that actually proves it did not move.
# Unchanged objects are proved by the accepted predecessor evidence, not by
# being republished. See CARRYOVER below.
#
# WHY ONE OBJECT NEEDS NO FAIL-CLOSED LEVER. Generation 15 published helpers.py
# first so that execution shut before any other object became observable; that
# was required because seven objects publish in sequence and every intermediate
# state is a mixed runtime. A single-row transaction has no intermediate state:
# publication is one `mv` onto one pathname, so a concurrent reader sees either
# the whole predecessor or the whole successor and never a mixture. Moving
# helpers.py to obtain a lever this transaction does not need would mean
# publishing an object this generation has no reason to touch.
# `require_single_object_transaction` holds that as a CHECKED property, so a
# later edit that adds a row halts here rather than quietly inheriting the
# argument that one rename is atomic.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. Not the launch helper, not the
# reconciliation helper, not the worker, not either sudoers grant, not the
# verify grant, not the deployment identity authorities, and not one byte of
# Fabric or Trust. `recovery.py` is absent from `helpers.REQUIRED_HELPERS`, so
# no helper ceremony is implied and no grant digest moves.
#
# AND IT LEAVES EXECUTION READINESS EXACTLY AS IT FOUND IT. Generation 15 closed
# execution on purpose because it moved the helper declaration. This one does
# not: helpers.py, both entrypoints and both grants are untouched, so helper
# compatibility stays `compatible` and supervision_ready stays true across the
# transaction. That is not a relaxation -- it is the consequence of a generation
# that moves nothing the readiness gate reads.
#
# WHAT CHANGES ON A HOST THAT INSTALLS THIS. `capability recover` stops being
# vacuous: it discovers both production invocations, asks the governed
# reconciler about each by CINV, and reports NOT_READY until each proves
# disposal. `command_execute` does NOT consult `execution_safety`, so this does
# not gate Stage 3. Running `recover` is a privileged action needing its own
# authorisation and is not authorised by installing this generation.
#
# Usage:
#   install-generation-16.sh --verify-source      reviewed bytes only; reads no installed state
#   install-generation-16.sh --verify             is this host a Generation-15 host ready for it?
#   install-generation-16.sh --install            the transaction
#   install-generation-16.sh --verify-installed   is this host a whole Generation 16?
#   install-generation-16.sh --recover            resolve an interrupted transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.

COMMIT="91cb1b601972ab43cc4c8b3335ed5022cd50158b"

# The accepted Generation-15 source authority, and the baseline this transaction
# requires the host to be at.
GEN15_COMMIT="ef4f7446200b668f8dcbf34d180c5102270f19f6"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

# This transaction's own namespace. Generation 15's retained journal at
# /root/kyri-gen15-transaction is predecessor evidence: it records how the host
# reached the state this transaction starts from, it is never read as this
# transaction's state, and nothing here writes to or removes it. Deriving an
# installer from its predecessor and leaving the predecessor's path in place is
# what made the first real Generation-14 attempt halt against a COMMITTED
# journal belonging to a transaction that had already finished.
TRANSACTION_ROOT="/root/kyri-gen16-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen15-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen15-helper-digests.txt"
GEN16_LIBRARY_EVIDENCE="/root/kyri-gen16-library-digests.txt"
GEN16_HELPER_EVIDENCE="/root/kyri-gen16-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS="/etc/sudoers.d/kyri-exec-launch"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# The two deployment identity authorities. Read to prove this ceremony did not
# create them; never written. Generation 16 does not need them to install.
COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# No CREATE, so the count does not move. Both ends are stated ANYWAY and are
# deliberately equal: a matrix that quietly grew a CREATE row would change the
# installed object count, and stating the expectation on both sides is what
# turns that into a refusal here rather than a surprise at publication.
EXPECTED_LIBRARY_FILES_BASELINE=80
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
  GEN16_LIBRARY_EVIDENCE="${FIXTURE}${GEN16_LIBRARY_EVIDENCE}"
  GEN16_HELPER_EVIDENCE="${FIXTURE}${GEN16_HELPER_EVIDENCE}"
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
PREPARED_SUFFIX=".kyri-gen16.new"
BACKUP_SUFFIX=".kyri-gen16.gen15"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

CLOSURE_STAGING=""
PREPARING=0

# --- the one generation-16 object, pinned both ways -------------------------
#
# source | target | mode | operation | gen15-sha256 | gen16-sha256 | group
#
# Every target sits in a directory that already exists at Generation 15, so
# there is no directory to create and none to remove on rollback -- the same
# reason Generation 15 carried no directory machinery, for the same reason.
#
# THE CARRYOVER, STATED SO IT IS REVIEWABLE RATHER THAN INFERRED FROM A GAP.
# Coherence group R has two members at Generation 15. This generation moves one
# of them:
#
#   CHANGED    tools/capability/execution/recovery.py  f44ada7f -> fdad3cec
#   CARRYOVER  tools/capability/cli.py                 7b4fac3e -> 7b4fac3e
#
# The carryover is deliberately NOT a matrix row, and that is a correctness
# requirement rather than a tidiness preference. `classify` tests the TARGET
# digest before the baseline, so a row whose two digests are the same value
# reads TARGET unconditionally and could never register the split
# `require_group_coherence` exists to catch. Worse, `verify_unchanged_surface`
# skips every matrix target by design -- so declaring cli.py would remove it
# from the only check that actually proves it did not move, and replace that
# proof with a row that cannot fail. And `prepare` would rewrite it: a REPLACE
# republishes the pathname, which contradicts "unrelated installed objects are
# preserved byte-for-byte".
#
# So the carryover is proved the way every other unchanged object is proved --
# against the accepted Generation-15 evidence, by `verify_unchanged_surface`,
# which reads it because it is NOT a target. The Generation-16 fixture suite
# asserts exactly that, including that cli.py's installed bytes and mode are
# untouched across a full install.
#
# WHY GROUP R IS COHERENT WITH ONE MEMBER MOVING. A group is split when some of
# its objects are at the predecessor and some at the successor. cli.py is the
# SAME BYTES in both generations, so it is at both simultaneously and cannot be
# on the wrong side of anything. The Generation-15 reason for binding the two --
# the execution-root argument spanning the seam -- is untouched here: no
# signature on that seam moves, and `_invocation_identity` is private with one
# caller inside recovery.py.
#
# PUBLICATION ORDER. Generation 15 made order a safety property because seven
# objects publish in sequence and every intermediate state is a mixed runtime;
# it published the readiness authority first so execution shut before anything
# else became observable. One row has no intermediate state -- publication is a
# single rename onto a single pathname, and a concurrent reader sees the whole
# predecessor or the whole successor. `require_single_object_transaction`
# refuses if a later edit adds a row, so that argument cannot be inherited by a
# transaction it stops being true of.
#
# source | target | mode | operation | gen15-sha256 | gen16-sha256 | group
# --- R: supervised recovery discovery ----------------------------------------
MATRIX=(
"tools/capability/execution/recovery.py|${LIBRARY_ROOT}/tools/capability/execution/recovery.py|0444|REPLACE|f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03|fdad3cecdf72eeb7b00c21f0ba04ee9bbc4ca3ebd6d6c4a571037518c2c567f0|R"
)

# The coherence-group member this generation does NOT move, declared as data so
# the ceremony can CHECK the carryover rather than leave it to prose. Each entry
# is "<repository source>|<installed target>|<digest that must not change>".
CARRYOVER=(
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1|R"
)

# --- governed objects deliberately outside the execution closure -------------
#
# The closure is computed from the PRODUCTION EXECUTION roots, and the surplus
# check below refuses any matrix row that closure does not require.
#
# Generation 15 needed three exceptions here. This generation needs NONE:
# recovery.py is reached from `tools.capability.cli`, so the closure requires it
# and the surplus check is satisfied without anything being named. An empty list
# is the strongest state this declaration can be in, and it is left empty rather
# than removed so that adding a row later is a visible edit to a reviewed list.
OUTSIDE_EXECUTION_CLOSURE=()

declared_outside_closure() {
  local candidate="$1" entry
  for entry in "${OUTSIDE_EXECUTION_CLOSURE[@]}"; do
    [[ "${entry}" == "${candidate}" ]] && return 0
  done
  return 1
}

# Every group Generation 15 named is still spelled here, even though this
# generation only moves R. The names outlive the generation that introduced
# them, and a coherence failure naming "unknown group V" would be a worse
# report than one naming what V is.
group_name() {
  case "$1" in
    V) printf 'the runtime-side verification surface' ;;
    R) printf 'supervised recovery discovery' ;;
    H) printf 'helper declaration and refusal reporting' ;;
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# The modules that must NOT be installed, carried forward from Generation 16
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
  [[ -n "${FIXTURE}" && "${KYRI_GEN16_FAIL_AT:-}" == "$1" ]]
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 15\n' \
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
    printf 'baseline_commit=%s\n' "${GEN15_COMMIT}"
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
      bad "group ${group} ($(group_name "${group}")) is split: ${at_baseline} object(s) at Generation 16 and ${at_target} at Generation 16"
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
    || halt "the reviewed Generation-16 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-16 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN15_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-15 authority is not an ancestor of the Generation-16 authority"
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
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-16 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-16 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
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

  # What the predecessor provides, decided from the reviewed Generation-15
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
    if git_as_owner cat-file -e "${GEN15_COMMIT}:${source}" 2>/dev/null; then
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
# Generation 15 read only the G11-AX ceremony here, because that was the only
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

# --- generation-15 baseline -------------------------------------------------
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
#     -- the last ceremony accepted BEFORE Generation 16 that governs it,
#        or Generation-15 evidence when none does
#   PLUS the target of every ceremony accepted AFTER Generation 16 that governs it
#
# BOTH HELPER CEREMONIES ARE NOW "BEFORE", AND THAT IS THE WHOLE DIFFERENCE FROM
# GENERATION 15'S COPY OF THIS LIST. G11-BB was still pending when Generation 15
# installed, so that generation had to accept both sides of it -- an object could
# legitimately be at G11-AX's target or at G11-BB's depending on whether the
# ceremony had run yet. G11-BB was accepted at G11-BB-R, before this generation,
# so for Generation 16 there is exactly ONE accepted state per object again:
# kyri_exec_transition_action.py at b11a2f19 and kyri_exec_quota.py at 54a9b15c,
# with the earlier G11-AX states now superseded and correctly refused.
#
# The AFTER list is EMPTY, and that is a claim this ceremony is making: no
# accepted ceremony is scheduled to run after Generation 16. If one is later
# planned it must be added here before this generation installs, or the host
# will report its objects as drift.
#
# Ordering matters: `accepted_library_digest` takes the LAST governing row in
# this list as the pre-install state, so G11-BB must follow G11-AX.
CEREMONIES_BEFORE_THIS_GENERATION=(
  "provisioning/execution/install-g11-ax-helpers.sh"
  "provisioning/execution/install-g11-bb-helpers.sh"
)
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
    || halt "the installed library holds ${count} objects, expected the Generation-15 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-15 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-15 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"

    # This is not "ignore helper files". The overlay is read from an accepted
    # ceremony's own matrix, one path at a time; an object no ceremony declares
    # is still judged against Generation-15 evidence and still refuses.
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is absent from the Generation-15 evidence"
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
      || { bad "the Generation-15 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-15 baseline"
  ok "the installed runtime is exactly the accepted Generation-15 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-15 baseline nor the Generation-16 target"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 16 is installed and unaffected. Remove them with --recover or by hand."
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
# WHY PRESENT GRANTS ARE SAFE HERE, AND WHY THE REASON IS NOT GENERATION 15'S.
# Generation 15 could argue that the grants were harmless because it SHUT
# readiness: it moved helpers.py against still-installed predecessor helpers, so
# compatibility went `incompatible` the moment the first object landed. That
# lever does not exist here and is not needed. This generation moves one object
# that no elevation path reads: `recovery.py` is not an entrypoint, is absent
# from `helpers.REQUIRED_HELPERS`, is not named by either grant, and is reached
# only from `command_recover` -- `command_execute` never imports it. So the
# privileged surface the grants authorise is byte-identical before, during and
# after this transaction, which `privileged_fingerprint` checks rather than
# assumes.
#
# THE CHECK IS PRECISE RATHER THAN ABSOLUTE. The verify grant must still be
# absent -- nothing has ever authorised that entrypoint. The two execution
# grants may be present, and if they are they must pin the entrypoint bytes this
# host actually carries, because a grant naming bytes that are not there is a
# grant nobody reviewed. And no OTHER grant may appear under any name.
# The atomicity property, checked rather than commented.
#
# Generation 15 needed a fail-closed lever -- publish the readiness authority
# first, so execution shuts before any other object becomes observable -- because
# seven objects publish in sequence and every intermediate state is a mixed
# runtime. This generation publishes ONE object, so the safety argument is
# different in kind: a single `mv` onto a single pathname has no intermediate
# state at all, and a concurrent reader gets the whole predecessor or the whole
# successor.
#
# THAT ARGUMENT IS TRUE OF A ONE-ROW MATRIX AND OF NOTHING ELSE. A later edit
# adding a second row would inherit a justification that had stopped applying,
# and the ceremony would carry no lever to replace it. So the row count is a
# checked precondition: a second row halts here and forces whoever added it to
# decide what shuts execution, exactly as Generation 15 had to.
#
# The group is pinned for the same reason. A row in some other group would mean
# this generation had quietly grown a second coherence concern.
require_single_object_transaction() {
  local count
  count="$(matrix_count)"
  [[ "${count}" == "1" ]] \
    || halt "this transaction declares ${count} objects, not 1: publication is only atomic for a single rename, and a multi-object Generation 16 needs a fail-closed publication order the way Generation 15 did"
  [[ "$(field "${MATRIX[0]}" 6)" == "R" ]] \
    || halt "the single declared object is in coherence group $(field "${MATRIX[0]}" 6), not R"
  [[ "$(field "${MATRIX[0]}" 3)" == "REPLACE" ]] \
    || halt "the single declared object is a $(field "${MATRIX[0]}" 3); this generation creates and removes nothing"
  ok "one object, one group, one rename: publication is atomic and has no mixed intermediate state"
}

# The coherence-group member this generation does NOT move, checked on both
# sides.
#
# An unchanged carryover is proved, not assumed. The REPOSITORY side must carry
# the declared digest at the reviewed commit -- so a carryover that silently
# moved in source is caught before installation rather than discovered as drift
# afterwards -- and no CARRYOVER path may also be a MATRIX row, because an
# object cannot be both republished and preserved.
#
# The INSTALLED side is deliberately not checked here. `verify_unchanged_surface`
# already judges every non-target object against the accepted Generation-15
# evidence, and cli.py is a non-target precisely so that it does. A second
# comparison here would be a copy of that judgement maintained separately, which
# is the duplication that let the Generation-15 post-install verifier keep a
# defect its pre-install twin had already had corrected.
require_carryover_unmoved() {
  local entry source target wanted group blob row drift=0
  for entry in "${CARRYOVER[@]}"; do
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
    && ok "${#CARRYOVER[@]} coherence-group carryover(s) are byte-identical at the reviewed commit and are not republished by this transaction"
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
    note "the coordinator identity authority is not installed; Generation 16 installs without it"
    ready=0
  fi
  if [[ ! -f "${EXECUTION_IDENTITY}" ]]; then
    note "the execution identity authority is not installed; Generation 16 installs without it"
    ready=0
  fi
  if (( ready == 1 )); then
    note "both deployment identity authorities are installed"
  else
    note "this host will be at Generation 16 and NOT execution-ready: the deployment identity ceremony is a separate one, and the runtime refuses execution until it has run"
  fi

  # Unlike Generation 15, this transaction does not change execution readiness
  # in either direction: it moves no helper, no entrypoint, no grant and not
  # helpers.py itself, so whatever `helpers.compatibility()` says before it runs
  # is what it says after. Reported so an operator does not go looking for the
  # `incompatible` intermediate state the previous generation deliberately
  # produced and this one deliberately does not.
  note "this generation does not move the helper declaration, either entrypoint or either grant: helper compatibility and supervision readiness are unchanged across it"
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
    injected_at staged && halt "injected failure after staging a Generation-16 object"
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN16_FAIL_AT:-}" == "${index}" ]]; then
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
    && bad "injected failure immediately after COMMITTED; Generation 16 stands"
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
  # Generation 15 needed -- a fail-closed authority restored LAST, so the
  # predecessor declaration never returns while a successor object is still
  # published -- and a multi-row Generation 16 would need it back. Rewriting it
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
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 15 (${removed} restored or removed)"
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
      bad "UNKNOWN bytes at ${target} (neither the Generation-15 baseline nor the Generation-16 target, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-16 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-16 object was published; the host is at Generation 15"
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
    || halt "Generation-15 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-16 evidence; Generation 16 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN16_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN16_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN16_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-16 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN15_COMMIT}"
    printf 'predecessor generation 15\n'
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
  } > "${GEN16_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN16_LIBRARY_EVIDENCE}.writing" "${GEN16_HELPER_EVIDENCE}.writing"
  sync_path "${GEN16_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN16_HELPER_EVIDENCE}.writing"
  mv -f "${GEN16_LIBRARY_EVIDENCE}.writing" "${GEN16_LIBRARY_EVIDENCE}"
  mv -f "${GEN16_HELPER_EVIDENCE}.writing" "${GEN16_HELPER_EVIDENCE}"
  sync_path "${GEN16_LIBRARY_EVIDENCE}"
  sync_path "${GEN16_HELPER_EVIDENCE}"
  ok "Generation-16 evidence written; Generation-15 evidence preserved"
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
    bad "injected cleanup failure after COMMITTED; Generation 16 remains installed"
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
    || bad "the installed library holds ${count} objects, expected the Generation-16 ${EXPECTED_LIBRARY_FILES_TARGET} plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) Generation-16 changed objects correspond to the reviewed commit ${COMMIT}"
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
# The accepted authority is Generation 15 PLUS what accepted ceremonies
# published after it -- the same overlay model `require_baseline` uses, through
# the same reader. Carrying a second, overlay-blind copy of this comparison is
# what refused a COMMITTED Generation-16 transaction: the four G11-AX
# library-root objects were reported as drift for holding exactly the bytes
# that ceremony was accepted for.
verify_unchanged_surface() {
  local drift=0 accepted authority recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    if ! accepted="$(accepted_library_digest "${relative}")"; then
      bad "installed object ${relative} is not accounted for by the Generation-15 evidence or any accepted ceremony, and is not a declared Generation-16 target"
      drift=$((drift + 1)); continue
    fi
    read -r authority recorded <<<"${accepted}"
    observed="$(digest_of "${file}")"
    if matches_accepted_state "${observed}" "${recorded}"; then continue; fi
    if [[ "${authority}" == "ceremony" ]]; then
      bad "${relative} changed: ${observed} but the accepted helper ceremon(ies) record ${recorded}"
    else
      bad "${relative} changed: ${observed} but Generation-15 evidence records ${recorded}"
    fi
    drift=$((drift + 1))
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  overlay_complete "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" || drift=$((drift + 1))

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-15 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every carried-over runtime object is exactly its accepted predecessor -- Generation 15, plus the $(helper_ceremony_library_rows "${CEREMONIES_BEFORE_THIS_GENERATION[@]}" "${CEREMONIES_AFTER_THIS_GENERATION[@]}" | wc -l) object(s) an accepted ceremony published after it -- and nothing was removed"
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
  require_single_object_transaction
  require_carryover_unmoved

  # The one correction this generation exists to deploy, proved present in the
  # reviewed source rather than assumed from a commit message.
  #
  # The digest pin above already fixes the bytes exactly, so this is not what
  # makes the install safe. It is what makes the install READABLE: a reviewer
  # running --verify-source sees the actual defect and the actual correction
  # named, rather than a hex string they would have to go and resolve.
  recovery_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/recovery.py")" \
    || halt "the reviewed commit carries no recovery.py"

  # The correction itself: the record identity is preferred, the opaque one is
  # the fallback. Checked as one line so the ORDER is what is proven -- both
  # names appear in either spelling, and it is which comes first that decides
  # whether the lifecycle journal is found.
  grep -q 'return record\.get("invocation_record_id") or record\.get("invocation_id")' \
    <<<"${recovery_source}" \
    || halt "the reviewed recovery.py does not prefer invocation_record_id over the opaque invocation_id: this is the G11-BC-A correction and without it this generation deploys nothing"
  grep -q 'return record\.get("invocation_id") or record\.get("invocation_record_id")' \
    <<<"${recovery_source}" \
    && halt "the reviewed recovery.py still carries the G11-BB-Z defect"
  ok "the reviewed source keys recovery discovery by the canonical invocation_record_id"

  # The surface around it is unchanged, which is what makes this a correction
  # rather than a redesign. A generation that moved any of these would be
  # changing the seam Generation 15 put group R together for.
  for marker in "unresolved_invocations" "reconcile_unresolved" \
                "execution_safety" "adapter_identity" "execution_root"; do
    grep -q -- "${marker}" <<<"${recovery_source}" \
      || halt "the reviewed recovery.py does not carry the G11-AT element ${marker}"
  done
  ok "the G11-AT recovery surface is intact around the correction"

  note "no installed path was read for state and none was written"
  printf '\n'
  printf 'Generation 16 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_closed_closure
  require_privileged_surface_excluded
  require_single_object_transaction
  require_carryover_unmoved

  classify_all
  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 16; use --verify-installed to audit the installed generation"
    require_gates_closed
    verify_excluded_absent
    require_group_coherence
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 16 / supervised execution runtime verify: already installed.\n'
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
    ok "the host is at Generation 15 and ready for the Generation-16 installation: $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE, $(matrix_count) changed objects across $(matrix_groups | wc -l) coherence groups, object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
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
  require_single_object_transaction
  require_carryover_unmoved
  require_gates_closed

  TRANSACTION_ID="gen16-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
      ok "Generation 16 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 16 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 15 and nothing was installed"
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
  require_single_object_transaction
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
  [[ -f "${GEN16_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-16 library evidence is missing"
  [[ -f "${GEN16_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-16 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-15 evidence was not preserved"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-15 helper evidence was not preserved"
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
    bad "recovery rolled the transaction back: the host is at Generation 15 and Generation 16 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 16 / supervised execution runtime %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 16 / supervised execution runtime %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
