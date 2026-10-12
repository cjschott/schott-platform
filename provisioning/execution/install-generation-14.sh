#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 14: the readiness decision, hardened.
#
# ONE OBJECT. `tools/capability/execution/helpers.py` and nothing else. That is
# not a convenience -- it is the architecture ruling this generation exists to
# honour.
#
# WHY THIS IS A GENERATION AND NOT PART OF THE HELPER CEREMONY
# ============================================================
# G11-AX drove the partial-deployment matrix and found the installed
# Generation-13 compatibility check accepting SEVEN dangerous mixed helper
# states -- among them new privileged entrypoints beside a stale
# `kyri_exec_transition.py`, which is the G11-AI split-generation defect
# surviving inside the check written to prevent it, and a reconcile entrypoint
# installed without the `kyri_exec_reconcile.py` it execs for, where root
# elevates and drops privilege before the missing module fails the import.
#
# The obvious fix is to carry the corrected `helpers.py` along with the ten
# privileged objects it judges. That was refused, and the reason is worth
# writing down: `helpers.py` IS the security rule, and the ten objects are the
# privileged deployment that rule evaluates. Changing the rule and the thing
# being judged in one production transaction means no moment exists at which
# either can be checked against a fixed other. So the rule lands first, on its
# own, and is independently proved to leave production execution-closed. Only
# then does the helper ceremony run, and it must satisfy a rule that was already
# installed and already verified.
#
# WHAT THIS CEREMONY DOES NOT TOUCH
# =================================
# No `/usr/libexec` object. No flattened helper module. No sudoers. No identity
# authority. No Fabric, Trust or implementation authority. It installs one
# runtime object and writes its own evidence beside -- never over -- Generation
# 13's.
#
# Modes:
#   --verify-source     the reviewed commit only; reads no installed path
#   --verify            production preconditions; mutates nothing
#   --install           the transaction
#   --verify-installed  what is installed, against the reviewed commit
#   --recover           resume or dispose of an interrupted transaction

# The reviewed authority carrying the corrected readiness rule.
COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"

# The generation this one replaces, and whose evidence must survive it.
GEN13_COMMIT="7709cf0443ab11f2b84c94eefbbb60f1eb95c98c"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC_ROOT="/usr/libexec"

TRANSACTION_ROOT="/root/kyri-gen14-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen13-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen13-helper-digests.txt"
GEN14_LIBRARY_EVIDENCE="/root/kyri-gen14-library-digests.txt"
GEN14_HELPER_EVIDENCE="/root/kyri-gen14-helper-digests.txt"

SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"
RECONCILE_SUDOERS="/etc/sudoers.d/kyri-exec-reconcile"

AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"
FABRIC_ROOT="/var/lib/kyri/fabric"
TRUST_ROOT="/var/lib/kyri/trust"

COORDINATOR_IDENTITY="/etc/kyri/coordinator-identity.json"
EXECUTION_IDENTITY="/etc/kyri/execution-identity.json"

# The two deployment identities, as G11-AW accepted them. This generation does
# not install or alter either; it refuses to run without them, because the
# readiness rule it installs is meaningless on a host that has no identity to
# execute as.
COORDINATOR_IDENTITY_SHA256="3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811"
EXECUTION_IDENTITY_SHA256="891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373"

# A REPLACE-only generation, so the object count does not move.
EXPECTED_LIBRARY_FILES_BASELINE=78
EXPECTED_LIBRARY_FILES_TARGET=78

# Nothing this ceremony runs may leave bytecode in the tree it is inspecting.
# The readiness report and the evidence writer both import from the library
# root, and on production they do it as root -- so a stray __pycache__ would be
# a root-owned write into the runtime this ceremony exists to verify. The
# fixture suite caught it by asserting --verify writes nothing.
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
  BASELINE_LIBRARY_EVIDENCE="${FIXTURE}${BASELINE_LIBRARY_EVIDENCE}"
  BASELINE_HELPER_EVIDENCE="${FIXTURE}${BASELINE_HELPER_EVIDENCE}"
  GEN14_LIBRARY_EVIDENCE="${FIXTURE}${GEN14_LIBRARY_EVIDENCE}"
  GEN14_HELPER_EVIDENCE="${FIXTURE}${GEN14_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  RECONCILE_SUDOERS="${FIXTURE}${RECONCILE_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
  FABRIC_ROOT="${FIXTURE}${FABRIC_ROOT}"
  TRUST_ROOT="${FIXTURE}${TRUST_ROOT}"
  COORDINATOR_IDENTITY="${FIXTURE}${COORDINATOR_IDENTITY}"
  EXECUTION_IDENTITY="${FIXTURE}${EXECUTION_IDENTITY}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen14.new"
BACKUP_SUFFIX=".kyri-gen14.gen13"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
PREPARING=0

# --- the one generation-14 object, pinned both ways --------------------------
#
# source | target | mode | operation | gen13-sha256 | gen14-sha256 | group
#
# Group C is the same coherence group Generation 13 put this object in --
# identity, recovery and readiness -- because that is what it still is. A
# generation that renamed its own group would make the two ceremonies'
# coherence reports incomparable.
MATRIX=(
"tools/capability/execution/helpers.py|${LIBRARY_ROOT}/tools/capability/execution/helpers.py|0444|REPLACE|eff6c4fd6f7420ba86491b7923e14cb2951a9c078decacc09dc20f38cefd5cbb|74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874|C"
)

group_name() {
  case "$1" in
    C) printf 'identity, recovery and readiness' ;;
    *) printf 'unknown group %s' "$1" ;;
  esac
}

# The ten privileged objects the G11-AX helper ceremony will move. This
# generation must not touch any of them, and says so by name so that the
# fingerprint below has something to be checked against.
AX_HELPER_SURFACE=(
"${LIBEXEC_ROOT}/kyri-exec-transition"
"${LIBEXEC_ROOT}/kyri-exec-verify"
"${LIBEXEC_ROOT}/kyri-exec-worker.py"
"${LIBEXEC_ROOT}/kyri-exec-verify-worker.py"
"${LIBEXEC_ROOT}/kyri-exec-reconcile"
"${LIBEXEC_ROOT}/kyri-exec-reconcile-worker.py"
"${LIBRARY_ROOT}/kyri_exec_transition.py"
"${LIBRARY_ROOT}/kyri_exec_transition_action.py"
"${LIBRARY_ROOT}/kyri_exec_verify.py"
"${LIBRARY_ROOT}/kyri_exec_reconcile.py"
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
  [[ -n "${FIXTURE}" && "${KYRI_GEN14_FAIL_AT:-}" == "$1" ]]
}
# An absent file is an empty digest, not a failure. Under `set -o pipefail` a
# bare `sha256sum | cut` pipeline fails when the file is missing, and in a plain
# assignment that ends the script through errexit -- silently, before the check
# that was about to refuse could print why. The fixture suite caught exactly
# that: a host with no execution identity authority exited with no message
# instead of naming the missing authority.
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
  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 13\n' \
    "${removed}" >&2
}

cleanup_on_exit() {
  local status=$?
  (( PREPARING == 1 )) && unwind_preparation
  return "${status}"
}
trap cleanup_on_exit EXIT

# --- journal ---------------------------------------------------------------
#
# NONE -> PREPARING -> PREPARED -> COMMITTING -> COMMITTED, with ROLLING_BACK
# and ROLLED_BACK as the terminal failure path. Every irreversible step is
# preceded by a durable write, so recovery reads a fact rather than inferring
# one. One object does not make a journal unnecessary: it makes the window
# smaller, not absent.
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'generation=14\n'
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN13_COMMIT}"
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

# A one-object generation cannot be internally split, and saying so is not the
# same as skipping the check: the report states which group moved and that the
# group moved whole, so the shape of the evidence matches Generation 13's and
# the two can be read side by side.
require_group_coherence() {
  local row group at_target=0 total=0
  for row in "${MATRIX[@]}"; do
    total=$((total + 1))
    group="$(field "${row}" 6)"
    [[ "$(classify "$(field "${row}" 1)" "$(field "${row}" 4)" "$(field "${row}" 5)")" == "TARGET" ]] \
      && at_target=$((at_target + 1))
  done
  if (( at_target == total )); then
    ok "group ${group} ($(group_name "${group}")) is wholly at Generation 14 (${at_target}/${total})"
  elif (( at_target == 0 )); then
    ok "group ${group} ($(group_name "${group}")) is wholly at Generation 13 (0/${total})"
  else
    bad "group ${group} is split: ${at_target}/${total} at target"
  fi
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)" \
    || halt "the repository at ${REPOSITORY} is not readable as ${REPO_OWNER}"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed Generation-14 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-14 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN13_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-13 authority is not an ancestor of the Generation-14 authority"
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
  local row source wanted baseline blob drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; wanted="$(field "${row}" 5)"; baseline="$(field "${row}" 4)"
    if ! git_as_owner cat-file -e "${COMMIT}:${source}" 2>/dev/null; then
      bad "${source} is not present at the reviewed commit ${COMMIT}"
      drift=$((drift + 1)); continue
    fi
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${wanted}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${wanted}"; drift=$((drift + 1)); }
    # And the predecessor is the Generation-13 authority's own bytes, so the
    # REPLACE is pinned at both ends to reviewed history rather than to whatever
    # happens to be installed.
    blob="$(git_as_owner cat-file blob "${GEN13_COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${baseline}" ]] \
      || { bad "${source} at ${GEN13_COMMIT} is ${blob:-absent}, expected the declared predecessor ${baseline}"
           drift=$((drift + 1)); }
  done
  (( drift == 0 )) || halt "the reviewed commits do not carry the pinned Generation-14 surface"
  local n; n="$(matrix_count)"
  ok "${n} Generation-14 source $(plural "${n}" object objects) match ${COMMIT}, and the predecessor matches ${GEN13_COMMIT}"
}

# The semantic delta is exactly the matrix, derived from the reviewed commit
# rather than asserted. A generation that quietly carried a second runtime
# object would be caught here.
require_minimal_delta() {
  local changed runtime_changed=0 path
  changed="$(git_as_owner diff-tree --no-commit-id --name-only -r "${COMMIT}")"
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    case "${path}" in
      tests/*|docs/*|provisioning/*|.github/*) continue ;;
    esac
    runtime_changed=$((runtime_changed + 1))
    is_target "${LIBRARY_ROOT}/${path}" \
      || bad "${COMMIT} changes runtime object ${path}, which this generation does not declare"
  done <<<"${changed}"
  [[ "${runtime_changed}" -eq "$(matrix_count)" ]] \
    || bad "the reviewed commit changes ${runtime_changed} runtime object(s); the matrix declares $(matrix_count)"
  (( FAILURES == 0 )) \
    && ok "the reviewed commit's runtime delta is exactly the declared $(matrix_count) object"
}


# THE LIBRARY ROOT HOLDS TWO KINDS OF OBJECT, and only one of them is this
# generation's.
#
# `/usr/lib/kyri/python` carries the runtime objects AND the flattened
# privileged helper modules beside them. The G11-AX helper ceremony creates one
# of those (`kyri_exec_reconcile.py`), so once it has run the file count there is
# legitimately 79 while every runtime object is byte-identical.
#
# A flat count was therefore right before that ceremony and wrong after it --
# which G11-AX.2 recorded in writing as a follow-up before it happened. The
# expectation is now stated as the runtime objects plus however many of the
# helper ceremony's own library-root CREATE targets are currently published,
# read from that ceremony's matrix rather than named here.
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
    # The matrix text carries the LITERAL placeholder, so it must not expand
    # here. Held in a variable rather than repeated as a quoted literal, which
    # keeps the intent obvious and keeps ShellCheck from reading it as a mistake.
    [[ "${target}" == *"${_PLACEHOLDER}"* ]] || continue
    target="${LIBRARY_ROOT}/${target##*"${_PLACEHOLDER}"}"
    [[ -f "${target}" ]] && present=$((present + 1))
  done < <(sed -n '/^MATRIX=(/,/^)/p' "${ceremony}" | sed -n 's/^\(".*"\)$/\1/p')
  printf '%s' "${present}"
}

# --- installed baseline ----------------------------------------------------
require_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  local helpers_present expected_baseline
  helpers_present="$(helper_ceremony_library_creates)"
  expected_baseline=$((EXPECTED_LIBRARY_FILES_BASELINE + helpers_present))
  [[ "${count}" -eq "${expected_baseline}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-13 ${EXPECTED_LIBRARY_FILES_BASELINE} plus ${helpers_present} published helper module(s)"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-13 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-13 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-13 evidence"
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
      || { bad "the Generation-13 evidence records ${recorded_relative}, which is not installed"
           drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-13 baseline"
  ok "the installed runtime is exactly the accepted Generation-13 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither the Generation-13 baseline nor the Generation-14 target"
    done
    halt "a target is in an unruled state and requires operator disposition"
  fi
}

require_no_transaction_residue() {
  local row target extra=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && { bad "residue at ${target}${PREPARED_SUFFIX}"; extra=$((extra + 1)); }
    [[ -e "${target}${BACKUP_SUFFIX}" ]] && { bad "residue at ${target}${BACKUP_SUFFIX}"; extra=$((extra + 1)); }
  done
  (( extra == 0 )) || halt "transaction residue exists; resolve it before installing"
  ok "no transaction residue at the $(matrix_count) target pathname"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 14 is installed and unaffected"
  fi
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: the launch grant is installed"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: the verification grant is installed"
  [[ ! -e "${RECONCILE_SUDOERS}" ]] || halt "${RECONCILE_SUDOERS} exists: the reconcile grant is installed"
  ok "no sudoers grant exists: every elevation gate stays closed"
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
  if mount 2>/dev/null | grep -qiE 'root-authority'; then
    halt "a Root Authority mount is present; this ceremony runs against an unmounted authority"
  fi
  ok "no Root Authority mount is present"
}

# --- fingerprints ----------------------------------------------------------
#
# The surfaces this generation must not touch, sampled before and after. A
# helper, a grant, an identity or a governed store that changed while a runtime
# generation ran changed for some other reason, and an operator needs to know.
privileged_fingerprint() {
  local path state=''
  for path in "${AX_HELPER_SURFACE[@]}" "${SUDOERS}" "${VERIFY_SUDOERS}" \
              "${RECONCILE_SUDOERS}" "${COORDINATOR_IDENTITY}" "${EXECUTION_IDENTITY}"; do
    if [[ -f "${path}" ]]; then
      state+="${path}:$(digest_of "${path}") "
    else
      state+="${path}:absent "
    fi
  done
  printf '%s' "${state}"
}

store_fingerprint() {
  local root state=''
  for root in "${AUTHORITY_ROOT}" "${CONTROL_ROOT}" "${FABRIC_ROOT}" "${TRUST_ROOT}"; do
    if [[ -d "${root}" ]]; then
      state+="${root}:$( (cd "${root}" && find . -type f | sort | xargs -r sha256sum \
                          | sha256sum | cut -d' ' -f1) 2>/dev/null || printf 'unreadable' ) "
    else
      state+="${root}:absent "
    fi
  done
  printf '%s' "${state}"
}

report_helper_surface() {
  local path absent=0 present=0
  for path in "${AX_HELPER_SURFACE[@]}"; do
    if [[ -f "${path}" ]]; then present=$((present + 1)); else absent=$((absent + 1)); fi
  done
  note "the G11-AX privileged surface: ${present} present, ${absent} absent; this ceremony changes none of them"
}

# --- what the installed rule decides ---------------------------------------
#
# The point of the generation, reported rather than argued. Reads the library
# root as a plain sys.path entry, so it reports what the INSTALLED rule says.
report_readiness_closure() {
  local root="$1" label="$2"
  python3 - "${root}" "${label}" <<'CLOSUREPY'
import sys
root, label = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
try:
    from tools.capability.execution import helpers
except ImportError as error:
    print(f"FAIL     the {label} readiness rule could not be loaded: {error}")
    raise SystemExit(1)
verdict = helpers.compatibility()
print(f"note     the {label} readiness rule declares "
      f"{len(helpers.REQUIRED_HELPERS)} required object(s)")
for helper in helpers.REQUIRED_HELPERS:
    print(f"note       requires {helper.path}")
print(f"note     live helper compatibility: {verdict.verdict} "
      f"({len(verdict.blocking)} blocking)")
CLOSUREPY
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

    [[ "${operation}" == "REPLACE" ]] \
      || halt "${target} is declared ${operation}, which this generation does not implement"
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
    injected_at staged && halt "injected failure after staging the Generation-14 object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  PREPARING=0
  local n; n="$(matrix_count)"
  ok "PREPARE complete: ${n} $(plural "${n}" object objects) staged, ${n} $(plural "${n}" predecessor predecessors) retained"
}

verify_prepared_set() {
  local row target wanted
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; wanted="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${wanted}" ]] \
      || halt "prepared object for ${target} does not verify"
  done
  ok "all $(matrix_count) prepared object(s) verify against the reviewed commit"
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

    if [[ -n "${FIXTURE}" && "${KYRI_GEN14_FAIL_AT:-}" == "${index}" ]]; then
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

    if injected_at verify; then
      PROGRESS["${index}"]="VERIFY_FAILED"; journal_write COMMITTING
      rollback "injected failure during post-publication verification"
      return 1
    fi

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

  if injected_at precommit; then
    rollback "injected failure immediately before the durable commit point"
    return 1
  fi

  # THE COMMIT POINT. Everything after this is bookkeeping, and no failure in it
  # may revert the generation.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; Generation 14 stands"
  OUTCOME="COMMITTED"
  ok "COMMIT complete: $(matrix_count) object(s) published and verified"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target baseline restored=0

  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; baseline="$(field "${row}" 4)"
    if [[ -f "${target}${BACKUP_SUFFIX}" && ! -L "${target}${BACKUP_SUFFIX}" ]]; then
      if [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" != "${baseline}" ]]; then
        bad "the retained predecessor for ${target} is not the declared baseline; refusing to restore it"
        continue
      fi
      mv -f "${target}${BACKUP_SUFFIX}" "${target}"
      sync_path "${target}"
      [[ "$(digest_of "${target}")" == "${baseline}" ]] \
        || bad "restoring ${target} did not reproduce the Generation-13 baseline"
      restored=$((restored + 1))
    fi
    rm -f "${target}${PREPARED_SUFFIX}"
  done

  journal_write ROLLED_BACK
  OUTCOME="ROLLED_BACK"
  printf 'rolled back: %d object(s) restored; the host is at Generation 13\n' "${restored}" >&2
}

# --- RECOVERY --------------------------------------------------------------
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: BASELINE=%d TARGET=%d UNKNOWN=%d (of %d)\n' \
    "${state}" "${BASELINE_COUNT}" "${TARGET_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither the Generation-13 baseline nor the Generation-14 target)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED; OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-14 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    # Nothing published. Forward only if the prepared material verifies;
    # otherwise dispose of the transaction and leave Generation 13 standing.
    local row wanted forward=1
    for row in "${MATRIX[@]}"; do
      wanted="$(field "${row}" 5)"
      [[ "$(digest_of "$(field "${row}" 1)${PREPARED_SUFFIX}")" == "${wanted}" ]] || { forward=0; break; }
    done
    if (( forward == 1 )); then
      note "recovery direction: FORWARD (the prepared object verifies)"
      commit_targets || return 1
      return 0
    fi
    note "recovery direction: ROLLBACK (prepared material is incomplete)"
    rollback "recovery could not prove forward completion"
    return 0
  fi
  halt "recovery found a mixed state a one-object generation cannot produce"
}

# --- evidence --------------------------------------------------------------
write_evidence() {
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" && -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "Generation-13 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-14 evidence; Generation 14 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN14_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN14_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN14_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-14 evidence does not record ${target}"; }
  done
  {
    printf 'generation 14\n'
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN13_COMMIT}"
    printf 'predecessor generation 13\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    printf 'state COMMITTED\n'
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)" "$(field "${row}" 6)"
    done
    printf 'expects_coordinator_identity %s\n' "/etc/kyri/coordinator-identity.json"
    printf 'expects_execution_identity %s\n' "/etc/kyri/execution-identity.json"
    expected_helpers || halt "the installed runtime declares no helper expectation"
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN14_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN14_LIBRARY_EVIDENCE}.writing" "${GEN14_HELPER_EVIDENCE}.writing"
  sync_path "${GEN14_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN14_HELPER_EVIDENCE}.writing"
  mv -f "${GEN14_LIBRARY_EVIDENCE}.writing" "${GEN14_LIBRARY_EVIDENCE}"
  mv -f "${GEN14_HELPER_EVIDENCE}.writing" "${GEN14_HELPER_EVIDENCE}"
  sync_path "${GEN14_LIBRARY_EVIDENCE}"
  sync_path "${GEN14_HELPER_EVIDENCE}"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" && -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "Generation-13 evidence was destroyed by this ceremony"
  ok "Generation-14 evidence written; Generation-13 evidence preserved"
}

# What the newly installed runtime expects the privileged surface to be, read
# out of the installed module itself rather than restated here. After this
# generation that is eight objects, and the helper ceremony must satisfy all of
# them.
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
    bad "injected cleanup failure after COMMITTED; Generation 14 remains installed"
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
    || bad "the installed library holds ${count} objects, expected ${EXPECTED_LIBRARY_FILES_TARGET} runtime objects plus ${helpers_present} published helper module(s)"
  (( FAILURES == 0 )) \
    && ok "the $(matrix_count) Generation-14 changed object corresponds to the reviewed commit ${COMMIT}"
}

# Every object the Generation-13 evidence recorded must still be exactly what
# that evidence says, except the one row this transaction declares.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is not accounted for by the Generation-13 evidence and is not the declared target"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-13 evidence records ${recorded}"
           drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-13 evidence records ${recorded_relative}, which is no longer installed"
           drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every runtime object outside the declared target is exactly what the Generation-13 evidence records"
}

# ===========================================================================
case "${MODE}" in
--verify-source)
  require_repository
  require_source_digests
  require_minimal_delta

  # The capability this generation exists to install, proved present in the
  # reviewed source rather than assumed from a commit message.
  helpers_source="$(git_as_owner show "${COMMIT}:tools/capability/execution/helpers.py")" \
    || halt "the reviewed commit carries no helpers.py"
  for marker in "kyri_exec_transition.py" "kyri_exec_transition_action.py" \
                "kyri_exec_reconcile.py" "kyri_exec_quota.py"; do
    grep -q -- "${marker}" <<<"${helpers_source}" \
      || halt "the reviewed helpers.py does not declare ${marker}"
  done
  ok "the reviewed helpers.py declares the four privileged modules Generation 13 omitted"
  grep -q "kyri-exec-verify" <<<"${helpers_source}" \
    && halt "the reviewed helpers.py declares a verification object supervision cannot reach"
  ok "the reviewed helpers.py declares no verification object"

  note "no installed path was read for state and none was written"
  printf '\nGeneration 14 source verification: all checks passed. %s object(s) would change (%s REPLACE, %s CREATE).\n' \
    "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_minimal_delta
  require_root_authority_unmounted
  require_identity_authorities
  require_gates_closed
  require_baseline
  require_target_state
  require_no_transaction_residue
  report_helper_surface
  require_group_coherence
  report_readiness_closure "${LIBRARY_ROOT}" "installed Generation-13"

  printf '\nstores (unchanged by this ceremony):\n'
  printf '  %s\n' "$(store_fingerprint)"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Generation 14 verification: all checks passed. %s object would change (%s REPLACE, %s CREATE). Nothing was written.\n' \
      "$(matrix_count)" "$(matrix_count_of REPLACE)" "$(matrix_count_of CREATE)"
    exit 0
  fi
  printf 'Generation 14 verification FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--install)
  require_repository
  require_source_digests
  require_minimal_delta
  require_root_authority_unmounted
  require_identity_authorities
  require_gates_closed

  TRANSACTION_ID="gen14-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  PRIVILEGED_BEFORE="$(privileged_fingerprint)"
  STORES_BEFORE="$(store_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_baseline
    require_target_state
    require_no_transaction_residue
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 14 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 14 is already installed: nothing to do"
      exit 0
    fi
    halt "the journal says COMMITTED but the target does not agree; operator disposition required"
  else
    note "resuming an interrupted transaction from state ${state}"
    recover "${state}" || true
  fi

  if [[ "${OUTCOME}" == "COMMITTED" ]]; then
    write_evidence
    cleanup_transaction_artifacts
    verify_installed_set
    verify_unchanged_surface
    require_group_coherence
    report_readiness_closure "${LIBRARY_ROOT}" "installed Generation-14"
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    require_group_coherence
    bad "the transaction rolled back: the host is at Generation 13 and nothing was installed"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${PRIVILEGED_BEFORE}" == "$(privileged_fingerprint)" ]] \
    || bad "a helper, a grant or a deployment identity changed during installation"
  [[ "${STORES_BEFORE}" == "$(store_fingerprint)" ]] \
    || bad "a governed store changed during installation"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Generation 14 installed and verified. Journal: %s\n' "${JOURNAL}"
    exit 0
  fi
  printf 'Generation 14 installation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--verify-installed)
  require_repository
  require_source_digests
  verify_installed_set
  verify_unchanged_surface
  require_group_coherence
  require_identity_authorities
  require_gates_closed
  report_helper_surface
  report_transaction_residue
  report_readiness_closure "${LIBRARY_ROOT}" "installed"

  printf '\n'
  if (( FAILURES == 0 )); then
    printf 'Generation 14 is installed and verified against %s.\n' "${COMMIT}"
    exit 0
  fi
  printf 'Generation 14 installed verification FAILED: %d\n' "${FAILURES}" >&2
  exit 1
  ;;

--recover)
  require_repository
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
  require_group_coherence
  printf '\n'
  (( FAILURES == 0 )) || { printf 'recovery FAILED: %d\n' "${FAILURES}" >&2; exit 1; }
  printf 'recovery complete: %s\n' "${OUTCOME}"
  exit 0
  ;;
esac
