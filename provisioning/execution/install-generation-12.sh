#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 12: the execution boundary the Fabric already decided, deployed.
#
# WHAT THIS DEPLOYS, AND NOTHING ELSE. Two reviewed corrections, both committed
# and both currently absent from the installed runtime:
#
#   ENG-0005 G11-X  the invocation boundary names the operation being requested
#                   and checks it, with the capability, the classification, and
#                   the node identity, against the admitted binding's
#                   effective_scope -- before staging.
#   ENG-0005 G11-Y  the boundary revalidates the selected binding's CURRENT
#                   eligibility through C5 at the invocation instant, so an
#                   advertisement that lapsed, a grant that was revoked, a
#                   subject that was quarantined, or a machine an operator
#                   drained is refused rather than served.
#
# WHY THE PACKAGE GREW BY THIRTEEN OBJECTS. Generation 11 computed its closure
# from one root, `tools.fabric.inspection`, and its surface declaration said in
# as many words that the runtime "reaches nothing in tools.trust". That was true
# when it was written. G11-Y made it false: asking C5 whether a binding is still
# eligible means asking C3 about standing and quarantine, so `tools.fabric.
# eligibility`, its `resources` dependency, `trust_adapter`, and the read path
# through `tools.trust` are now genuinely reachable from the installed runtime.
#
# Two of those thirteen -- `eligibility.py` and `trust_adapter.py` -- were named
# in Generation 11's EXCLUDED list on the reasoning that the runtime consumes
# read-only inspection and not the governed write path. That reasoning still
# holds for the write path, and `admission.py`, `selection.py`, and the Fabric
# `cli.py` remain excluded. What changed is that eligibility is not a write
# path: it allocates nothing, writes nothing, and takes no lock, and the
# boundary hands it surfaces that expose reads and nothing else.
#
# IMPORTING IS NOT AUTHORITY. Installing a module lets the runtime resolve an
# import. It grants no filesystem access, no Trust standing, no operator input,
# and no permission to mutate anything. The Trust modules installed here are the
# query and store path; `tools/trust/evaluator.py`, `root_authority.py`,
# `gateway.py`, `policy.py`, `audit.py`, and `cli.py` -- everything that
# *decides* trust -- are excluded and unreachable.
#
# WHAT THIS DELIBERATELY DOES NOT DEPLOY. The installed `kyri_exec_transition`
# and `kyri_exec_transition_action` have lagged repository source since a commit
# ancestral to the Generation-11 authority, first recorded at ENG-0005 G11-E.
# That drift is a substantive change to the root-executed transition and it was
# never reviewed in this checkpoint chain, so republishing it as a side effect
# of deploying an unrelated correction is exactly the quiet widening this
# ceremony exists to prevent. Both stay at their reviewed installed bytes and
# are named in EXCLUDED_HELPERS below.
#
# THE CLOSURE IS COMPUTED, NOT ASSERTED. `tools/dev/runtime_closure.py` walks
# the import graph from the roots the installed runtime is actually entered
# through and reports what it needs. Generation 11 kept that rule inside its own
# heredoc, which is why nothing noticed when it went stale. One implementation
# now answers the installer, the packaging test, and the soundness test.
#
# USAGE
#   install-generation-12.sh --verify-source     read-only: is the PACKAGE sound?
#   install-generation-12.sh --verify            read-only: is the host at G11?
#   install-generation-12.sh --install           the transaction (root)
#   install-generation-12.sh --verify-installed  read-only: is the host at G12?
#   install-generation-12.sh --recover           finish or unwind a transaction
#
# `--verify-source` is new at Generation 12 and touches no installed path at
# all: it proves the proposed package before anything is installed, which is the
# question an operator has at the moment they are deciding whether to install.

COMMIT="1313df019472a73e139cfc294ee8e016ad1355c0"

# The accepted Generation-11 source authority, and the baseline this transaction
# requires the host to be at.
GEN11_COMMIT="6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
TRANSACTION_ROOT="/root/kyri-gen11-transaction"
BASELINE_LIBRARY_EVIDENCE="/root/kyri-gen11-library-digests.txt"
BASELINE_HELPER_EVIDENCE="/root/kyri-gen11-helper-digests.txt"
GEN11_LIBRARY_EVIDENCE="/root/kyri-gen11-library-digests.txt"
GEN11_HELPER_EVIDENCE="/root/kyri-gen11-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# Nine CREATEs move the count by nine. Both ends are stated, so a matrix that
# quietly grew or lost a row fails here rather than at publication.
EXPECTED_LIBRARY_FILES_BASELINE=57
EXPECTED_LIBRARY_FILES_TARGET=70

# Generation 11 declared the already-installed subset by hand so its closure
# gate could subtract it. This one reads the installed set from the host's own
# library root instead, so the gate cannot drift from what is really there --
# which is how the Generation-11 closure went stale without anything noticing.

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
  TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"
  BASELINE_LIBRARY_EVIDENCE="${FIXTURE}${BASELINE_LIBRARY_EVIDENCE}"
  BASELINE_HELPER_EVIDENCE="${FIXTURE}${BASELINE_HELPER_EVIDENCE}"
  GEN11_LIBRARY_EVIDENCE="${FIXTURE}${GEN11_LIBRARY_EVIDENCE}"
  GEN11_HELPER_EVIDENCE="${FIXTURE}${GEN11_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

# The package directory the ten Trust objects live in. It does not exist at
# Generation 11 and is not a matrix row: a directory has no bytes to pin, so it
# is created and verified by property (owner, mode, and emptiness of anything
# this transaction did not declare) rather than by digest.
PACKAGE_DIR="${LIBRARY_ROOT}/tools/trust"
PACKAGE_DIR_MODE="0755"

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen12.new"
BACKUP_SUFFIX=".kyri-gen12.gen11"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
PACKAGE_DIR_CREATED="no"

# The closure check materialises the reviewed tools tree into a temporary
# directory. It is removed on every exit path, including a halt, so a refusal
# never leaves reviewed source lying around outside the repository.
CLOSURE_STAGING=""

# Set for the duration of PREPARE and cleared once the transaction is durably
# PREPARED. While it is set, nothing has been published, so any exit at all --
# a halt, an injected failure, an unexpected error -- must leave the host at a
# whole Generation 11 rather than at Generation 11 plus this transaction's
# litter. See unwind_preparation.
PREPARING=0

# Unwind an interrupted PREPARE. Reachable only before anything is published,
# so there is no generation to protect -- only litter to remove.
#
# Generation 11 could leave its prepared and retained copies behind after a
# failed preparation, and did: its targets were REPLACE, every pathname already
# existed, and the next run refused on residue. Generation 11 cannot be so
# relaxed, because its litter includes a `tools/fabric` DIRECTORY, and the
# accepted Generation-11 installed surface is one in which that directory does
# not exist. Leaving it would mean a host that reports itself at Generation 11
# while carrying a pathname Generation 11 never had.
#
# The journal is removed rather than moved to a terminal state, and that is the
# honest record: PREPARING is written only by this function's own transaction,
# nothing was published under it, and a host with no transaction should say so.
# A retry then starts cleanly instead of being refused as a rollback.
unwind_preparation() {
  local row target removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    # Paranoia, not ceremony: if a target somehow exists we are past the point
    # this function may act, and removal is rollback's fenced job, not ours.
    [[ -e "${target}" && ! -L "${target}" ]] && continue
    [[ -e "${target}${PREPARED_SUFFIX}" ]] && removed=$((removed + 1))
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done

  if [[ "${PACKAGE_DIR_CREATED}" == "yes" && -d "${PACKAGE_DIR}" && ! -L "${PACKAGE_DIR}" ]]; then
    if [[ -z "$(find "${PACKAGE_DIR}" -mindepth 1 -print -quit)" ]]; then
      rmdir "${PACKAGE_DIR}" && PACKAGE_DIR_CREATED="no"
    fi
  fi

  if [[ -f "${JOURNAL}" && "$(journal_state)" == "PREPARING" ]]; then
    rm -f "${JOURNAL}" "${JOURNAL}.writing"
    rmdir "${TRANSACTION_ROOT}" 2>/dev/null || true
  fi

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 11\n' \
    "${removed}" >&2
}

cleanup_on_exit() {
  local status=$?
  [[ -n "${CLOSURE_STAGING}" ]] && rm -rf "${CLOSURE_STAGING}"
  (( PREPARING == 1 )) && unwind_preparation
  return "${status}"
}
trap cleanup_on_exit EXIT

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the nineteen generation-12 objects, pinned both ways -----------------------
#
# source | target | mode | operation | gen10-sha256 | gen11-sha256
#
# The Generation-11 column is ABSENT for every row, because at Generation 11 not
# one of these pathnames exists. That is the same ABSENT vocabulary the
# Generation-11 ceremony carried as generic CREATE capability and never
# exercised; Generation 11 is the transaction it was retained for.
#
# Order is publication order and is the order the reviewed surface declaration
# fixed: the package initialiser, then the leaves, then the modules that import
# them. It is preserved here rather than re-decided, because it is reviewed
# authority. It is also not load-bearing for safety -- every intermediate state
# fails closed either way, as the header records -- so preserving it costs
# nothing and re-deciding it would silently amend an accepted declaration.
MATRIX=(
"tools/capability/cli.py|${LIBRARY_ROOT}/tools/capability/cli.py|0444|REPLACE|c10bf11e8382face3d8020ea6be971c359f8a4bcd0b5fe9e862a460c0d7c4305|b45f5332dcd98f38c2479c13cca17e1e61c535b6a6b4b6e2c89beaebfc7c3d98"
"tools/capability/coordinator.py|${LIBRARY_ROOT}/tools/capability/coordinator.py|0444|REPLACE|829eca2aa56a9b03909243dce75716021cdf2eaafcfe417ae1187bf9e333c924|1df5e494d5cbf35e98b1ac70c1ef7e852d18c94797d3779794029dcf66be48ea"
"tools/capability/evidence.py|${LIBRARY_ROOT}/tools/capability/evidence.py|0444|REPLACE|394bc94fe8f5aee36c81ef97b6228b6f32c577c05724d7277072d58471f2cfc7|d2429646966462508fb27e4c6b96d1a0f698cf93fa841d66f0640bd344232426"
"tools/capability/fabric_evidence.py|${LIBRARY_ROOT}/tools/capability/fabric_evidence.py|0444|REPLACE|e1e508e5db9a589bf007362a252d45b2c60fe506d9ad51121f6aab8913023742|e51d893936ba5e465fa94893a46a3f85c66ad4904a29970f66dc00f63fb67e67"
"tools/capability/invocation_identity.py|${LIBRARY_ROOT}/tools/capability/invocation_identity.py|0444|REPLACE|617d2f5a4c98e25bfc753e73a3f81836030c1b24d6a4c5e3218c511ccbd8b2a2|3a01471a43c1f0b27aac987c77941446368e17ba293cfaf0451191a587c5def8"
"tools/capability/records.py|${LIBRARY_ROOT}/tools/capability/records.py|0444|REPLACE|563e4adc72ae8f12a422f787dad775d907048f5d4732aa369696362e1f9ccc31|a6744501a1f58eafb926f128fec1eadcc2ccced9ebb601718c8cc55a4b1da38e"
"tools/fabric/eligibility.py|${LIBRARY_ROOT}/tools/fabric/eligibility.py|0444|CREATE|ABSENT|4e6e58e9cebf84419f4e91f6e8390a5429722e0094a31a832a7fe2b0dbe8332b"
"tools/fabric/resources.py|${LIBRARY_ROOT}/tools/fabric/resources.py|0444|CREATE|ABSENT|4c89f86e2c712ba0a253599eb2f7a554cffc8ce4c3aceb030b177b23192fa041"
"tools/fabric/trust_adapter.py|${LIBRARY_ROOT}/tools/fabric/trust_adapter.py|0444|CREATE|ABSENT|3e78a406b8ca620edeb98dfcc3178229103624c849107133abe7677f37b1b280"
"tools/trust/__init__.py|${LIBRARY_ROOT}/tools/trust/__init__.py|0444|CREATE|ABSENT|ccc959621390c4dcfb05367fce121f304a7b61e850a331d01bd59a8b479de8f9"
"tools/trust/errors.py|${LIBRARY_ROOT}/tools/trust/errors.py|0444|CREATE|ABSENT|7dbaa48b109e70d00bbe31570495c60dfbf112e65ebc9c441f68c4e409795057"
"tools/trust/expiry.py|${LIBRARY_ROOT}/tools/trust/expiry.py|0444|CREATE|ABSENT|f4324597e4ad59dd5ff9db7b03e1416b0b88545a236b5a7883a59261a241cc67"
"tools/trust/identifiers.py|${LIBRARY_ROOT}/tools/trust/identifiers.py|0444|CREATE|ABSENT|77ce2453b4c7fb494bc16de9d95ac5d0dab5fe2af6efac16801992a1b6ad32cc"
"tools/trust/lineage.py|${LIBRARY_ROOT}/tools/trust/lineage.py|0444|CREATE|ABSENT|491714ae51fcb1c0707a1f474c82d876aed338726f651e73ce76c238c58f272e"
"tools/trust/models.py|${LIBRARY_ROOT}/tools/trust/models.py|0444|CREATE|ABSENT|c957037e37d67364352d4ed29eed1fe42263587548387438f2c226e137a06e66"
"tools/trust/query.py|${LIBRARY_ROOT}/tools/trust/query.py|0444|CREATE|ABSENT|0e12e07f59642944547f09b8d0c21753bff50cdc8bdef4390472e4aeb2284d7a"
"tools/trust/scope.py|${LIBRARY_ROOT}/tools/trust/scope.py|0444|CREATE|ABSENT|1054d8796c8b16a984882113490d4bcd0811c1ac3e27660aea807f9661c2ffc9"
"tools/trust/store.py|${LIBRARY_ROOT}/tools/trust/store.py|0444|CREATE|ABSENT|1d0e7cb657e3f6773d52018464cfa608101d49e004009d9e6447c09aba83bed9"
"tools/trust/transitions.py|${LIBRARY_ROOT}/tools/trust/transitions.py|0444|CREATE|ABSENT|662421864357067c260583e740e6c5bba72d6fdda1bc582c8c17e84e84887513"
)


# The Fabric modules the closure deliberately excludes, restated from the
# reviewed surface declaration. These are the governed write path, the operator
# input surface, and the modules only they reach. Each is asserted absent from
# the computed closure, absent from the matrix, and absent from the installed
# tree -- three independent checks, because a runtime that acquired the mutation
# surface by accident would look exactly like one that acquired it on purpose.
# The modules that must NOT be installed, checked on every run. Generation 11
# listed `eligibility.py` and `trust_adapter.py` here; both are installed at
# Generation 12, because asking whether a binding is still eligible is a read
# and the boundary now has to ask it. What has not changed is that the runtime
# may not reach anything that DECIDES -- so the governed write path and the
# Trust decision surface are named individually, and a future module that
# decides is a failure here rather than a quiet widening.
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


field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# Operator-visible prose is derived from the matrix rather than written out, so
# a ceremony can no longer describe a transaction it is not performing.
matrix_count() { printf '%s' "${#MATRIX[@]}"; }
matrix_count_of() {
  local wanted="$1" row n=0
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 3)" == "${wanted}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
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

# Test-only failure injection. Impossible without --fixture, so a production run
# cannot reach any of it.
injected_at() {
  [[ -n "${FIXTURE}" && "${KYRI_GEN11_FAIL_AT:-}" == "$1" ]]
}
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Git is read as the repository owner, never as root. A ceremony that ran git as
# root would be executing hooks and config nobody reviewed.
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

# --- journal ---------------------------------------------------------------
#
# States: NONE -> PREPARED -> COMMITTING -> COMMITTED, with ROLLING_BACK and
# ROLLED_BACK as the terminal failure path. Every irreversible step is preceded
# by a durable write, so recovery reads a fact rather than inferring one.
#
# One field is new against Generation 11: `package_dir_created`. A CREATE
# transaction that made the directory must be able to remove it on rollback, and
# a transaction that found it already there must not. That is not derivable from
# the targets afterwards -- an empty directory looks the same either way -- so it
# is recorded durably at the moment it is decided.
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN11_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
    printf 'package_dir=%s\n' "${PACKAGE_DIR}"
    printf 'package_dir_created=%s\n' "${PACKAGE_DIR_CREATED}"
    local row index=0
    for row in "${MATRIX[@]}"; do
      index=$((index + 1))
      printf 'target%d=%s|%s|%s|%s\n' "${index}" \
        "$(field "${row}" 1)" "$(field "${row}" 3)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
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

journal_package_dir_created() {
  [[ -f "${JOURNAL}" ]] || { printf 'no'; return; }
  local value
  value="$(sed -n 's/^package_dir_created=//p' "${JOURNAL}" | tail -1)"
  printf '%s' "${value:-no}"
}

# --- classification --------------------------------------------------------
#
# GEN10 / GEN11 / UNKNOWN, decided from actual bytes and never from the journal
# or from a pathname existing. Every row of this matrix is a CREATE whose
# predecessor state is ABSENT, so "GEN10" here means the pathname is genuinely
# free -- not a symlink, not a directory, not a file with other bytes.
classify() {
  local target="$1" gen10="$2" gen11="$3" observed
  if [[ "${gen10}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN10'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${gen11}" ]]; then printf 'GEN11'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen11}" ]]; then printf 'GEN11'
  elif [[ "${observed}" == "${gen10}" ]]; then printf 'GEN10'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen10 gen11 state
  BASELINE_COUNT=0; TARGET_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen10="$(field "${row}" 4)"; gen11="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen10}" "${gen11}")"
    case "${state}" in
      GEN10) BASELINE_COUNT=$((BASELINE_COUNT + 1)) ;;
      GEN11) TARGET_COUNT=$((TARGET_COUNT + 1)) ;;
      *) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); UNKNOWN_TARGETS+=("${target}") ;;
    esac
  done
}

# --- repository preflight --------------------------------------------------
require_repository() {
  cd "${REPOSITORY}" || halt "the repository is not at ${REPOSITORY}"
  local head_now residue
  head_now="$(git_as_owner rev-parse HEAD)" \
    || halt "the repository at ${REPOSITORY} is not readable as ${REPO_OWNER}"
  git_as_owner cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
    || halt "the reviewed Generation-12 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-12 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN11_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-11 authority is not an ancestor of the Generation-12 authority"
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

# Every Generation-12 runtime byte must equal the reviewed commit object, and
# every target must be genuinely new: a row whose source already existed at the
# Generation-11 authority with these bytes would be a REPLACE wearing a CREATE's
# label. The predecessor assertion for a CREATE is that the pathname is not part
# of the Generation-11 installed surface, which require_baseline proves
# over the whole tree; here the source side is pinned.
require_source_digests() {
  local row source gen11 blob worktree drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen11="$(field "${row}" 5)"
    # Existence first, and separately. A row naming a path the reviewed commit
    # does not carry would otherwise fail inside the command substitution below
    # -- `pipefail` makes the pipeline fail, and an assignment from a failed
    # substitution ends the script under `set -e` with no diagnostic at all. It
    # would still fail closed, but an operator would be told nothing about why.
    if ! git_as_owner cat-file -e "${COMMIT}:${source}" 2>/dev/null; then
      bad "${source} is not present at the reviewed commit ${COMMIT}"
      drift=$((drift + 1)); continue
    fi
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen11}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${gen11}"; drift=$((drift + 1)); }
    worktree="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${worktree}" == "${gen11}" ]] \
      || note "${source} in the working tree is ${worktree:-absent}; the ceremony installs the commit object, not this"
  done
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-12 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-12 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
}

# --- the closed closure ----------------------------------------------------
#
# The load-bearing gate. The installed runtime must be able to import everything
# it is entered through, and the matrix plus what is already installed must
# cover exactly that -- no more, no less.
#
# Generation 11 asked this question of one root, `tools.fabric.inspection`, and
# answered it inside a heredoc nothing else could read. When ENG-0005 G11-Y made
# the invocation boundary reach C5 eligibility and the Trust read path, that
# answer went stale and the installer had no way to notice. So the roots are now
# stated as the set of modules the runtime is actually entered through, and the
# computation lives in `tools/dev/runtime_closure.py`, which the packaging tests
# ask the same way.
#
# The roots, and why each is one:
#
#   tools.capability.cli                     the operator interface: invoke,
#                                            inspect, validate, authorise-launch
#   tools.capability.execution.worker        the far side of execve; entered by
#                                            pathname, never imported by the CLI
#   kyri_exec_transition                     the privileged transition, executed
#   kyri_exec_transition_action              by root through the flattened
#   kyri_exec_verify                         library-root copies rather than
#   kyri_exec_quota                          through the package
#
# The blobs are materialised from the reviewed commit into a temporary tree as
# the repository owner. The working tree is never the input.
CLOSURE_ROOTS=(
"tools.capability.cli"
"tools.capability.execution.worker"
"kyri_exec_transition"
"kyri_exec_transition_action"
"kyri_exec_verify"
"kyri_exec_quota"
)

require_closed_closure() {
  local staging exported=0
  staging="$(mktemp -d)"
  CLOSURE_STAGING="${staging}"

  # The whole tools tree as the reviewed commit recorded it, plus the flattened
  # privileged helpers under the names the library root holds them by. A closure
  # computed only over the declared files could never discover that it needs a
  # file nobody declared, which is the failure this gate exists to prevent.
  git_as_owner archive --format=tar "${COMMIT}" tools provisioning/execution \
    | tar -x -C "${staging}" \
    || halt "could not materialise the reviewed tree from ${COMMIT}"
  local helper flattened
  for helper in quota transition transition-action verify; do
    flattened="kyri_exec_${helper//-/_}"
    [[ -f "${staging}/provisioning/execution/kyri-exec-${helper}.py" ]] \
      || halt "the reviewed commit carries no kyri-exec-${helper}.py"
    cp "${staging}/provisioning/execution/kyri-exec-${helper}.py" \
       "${staging}/${flattened}.py" \
      || halt "could not flatten kyri-exec-${helper}.py"
  done
  exported="$(find "${staging}/tools" -type f -name '*.py' | wc -l)"
  (( exported > 0 )) || halt "the reviewed commit exposes no tools sources"

  local root_args=()
  for helper in "${CLOSURE_ROOTS[@]}"; do root_args+=(--root "${helper}"); done

  local computed
  computed="$(python3 "${REPOSITORY}/tools/dev/runtime_closure.py" \
    --source-root "${staging}" "${root_args[@]}" --format files | sort)" \
    || halt "the import closure could not be computed"

  # Declared: every matrix row, plus what the baseline already installs. The
  # baseline set is read from the host's own accepted evidence rather than
  # listed here, so this gate cannot drift from what is really installed.
  local declared="" row
  for row in "${MATRIX[@]}"; do declared+="$(field "${row}" 0)"$'\n'; done
  local installed_now=""
  if [[ -d "${LIBRARY_ROOT}" ]]; then
    installed_now="$(cd "${LIBRARY_ROOT}" && find . -type f -name '*.py' \
      | sed 's#^\./##' | sort)"
  fi

  local missing
  missing="$(comm -23 <(printf '%s\n' "${computed}") \
                      <(printf '%s\n%s\n' "${declared}" "${installed_now}" \
                        | grep -v '^$' | sort -u))"
  if [[ -n "${missing}" ]]; then
    printf 'STOP: the import closure needs objects this generation does not provide:\n' >&2
    printf '  %s\n' ${missing} >&2
    halt "the declared surface does not close the import graph"
  fi

  # And nothing declared that the closure does not require. A matrix row the
  # graph does not need widens the installed runtime for no stated reason.
  local surplus
  surplus="$(comm -13 <(printf '%s\n' "${computed}") \
                      <(printf '%s\n' "${declared}" | grep -v '^$' | sort -u))"
  if [[ -n "${surplus}" ]]; then
    printf 'STOP: the matrix declares objects the import closure does not require:\n' >&2
    printf '  %s\n' ${surplus} >&2
    halt "the declared surface exceeds the import closure"
  fi

  rm -rf "${staging}"; CLOSURE_STAGING=""
  ok "the import closure of $(printf '%s ' "${CLOSURE_ROOTS[@]}")closes over the declared surface ($(printf '%s\n' "${computed}" | wc -l) modules)"
}

# --- generation-11 baseline -------------------------------------------------
require_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_BASELINE}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-11 ${EXPECTED_LIBRARY_FILES_BASELINE}"

  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-11 library evidence at ${BASELINE_LIBRARY_EVIDENCE} is missing"
  [[ -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-11 helper evidence at ${BASELINE_HELPER_EVIDENCE} is missing"

  # Every installed object accounted for by the accepted evidence, and every
  # recorded digest matching the bytes actually there.
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-11 evidence"
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
      || { bad "the Generation-11 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-11 baseline"
  ok "the installed runtime is exactly the accepted Generation-11 baseline (${count} objects)"
}

require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: this transaction creates it and something is already there"
    done
    halt "a target is in an unruled state and requires operator disposition"
  fi
}

# Nothing may live in the package directory that this transaction did not
# declare. This is what stops an unreviewed Fabric module from arriving in the
# installed runtime alongside the closure -- whether by a hand-copied file, a
# widened matrix that was reverted in source but not on the host, or residue
# from a run nobody accounted for.
require_no_foreign_package_objects() {
  [[ -e "${PACKAGE_DIR}" ]] || { ok "the Trust package directory does not exist yet, as Generation 11 requires"; return; }
  [[ -L "${PACKAGE_DIR}" ]] && halt "${PACKAGE_DIR} is a symlink; refusing to install through it"
  [[ -d "${PACKAGE_DIR}" ]] || halt "${PACKAGE_DIR} exists and is not a directory"

  local entry foreign=0
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    is_target "${entry}" && continue
    [[ "${entry}" == *"${PREPARED_SUFFIX}" || "${entry}" == *"${BACKUP_SUFFIX}" ]] && continue
    # Bytecode caches are the interpreter's, not this transaction's. Every other
    # installed package on this host already carries one -- the Generation-11
    # runtime has `__pycache__` under the library root, `tools`, `capability`
    # and `execution` -- and they appear the first time the runtime imports
    # anything, without anyone installing them. Refusing them would mean a
    # healthy Generation-11 host stopped verifying the moment it was first used.
    # They are also not an import surface: CPython will not load a cached module
    # whose source is absent in this layout, so a stray `.pyc` cannot smuggle in
    # a module -- which is what verify_excluded_absent checks, over the sources.
    [[ "${entry}" == *"/__pycache__" || "${entry}" == *"/__pycache__/"* ]] && continue
    bad "foreign object in the Trust package directory: ${entry#"${LIBRARY_ROOT}"/}"
    foreign=$((foreign + 1))
  done < <(find "${PACKAGE_DIR}" -mindepth 1 -print | sort)

  (( foreign == 0 )) \
    || halt "the Trust package directory holds objects this transaction did not declare"
  ok "the Trust package directory holds only declared objects"
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 11 is installed and unaffected. Remove them with --recover or by hand."
  fi
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: G3 has already run"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: G6.1B has already run"
  ok "neither sudoers grant exists: G3 and G6.1B stay closed"
}

# Every target stages beside itself inside the package directory, so publication
# is a rename within one directory. Before the directory exists this is a
# statement about where the matrix puts things, which is exactly when it needs
# checking: a row that staged somewhere else would publish by copy, not rename.
require_same_filesystem() {
  local row target prepared parent
  parent="$(dirname "${PACKAGE_DIR}")"
  [[ -d "${parent}" ]] || halt "${parent} does not exist: the Fabric package has nowhere to go"
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    [[ "$(dirname "${target}")" == "$(dirname "${prepared}")" ]] \
      || halt "${target} does not stage beside itself"
    [[ "$(dirname "${target}")" == "${PACKAGE_DIR}" ]] \
      || halt "${target} is not inside the declared Fabric package directory"
  done
  if [[ -d "${PACKAGE_DIR}" ]]; then
    [[ "$(stat -c '%d' "${PACKAGE_DIR}")" == "$(stat -c '%d' "${parent}")" ]] \
      || halt "the Trust package directory is not on the same filesystem as the library root"
  fi
  ok "every target stages beside itself inside ${PACKAGE_DIR#"${LIBRARY_ROOT}"/}, so publication is a rename"
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

# --- PREPARE ---------------------------------------------------------------
#
# All nine Generation-11 objects are staged and verified BEFORE a single
# publication happens. With nine targets that ordering is the whole safety
# argument: a transaction that staged and published one object at a time would
# discover a bad ninth object with eight already live.
#
# There is no rollback material to retain, because there is nothing to roll back
# to: a CREATE's predecessor is an absent pathname, and its rollback is removal.
prepare() {
  local row source target mode operation gen11 prepared observed
  PREPARING=1

  # The package directory first: nothing can stage beside a target that has no
  # directory to live in. Whether this transaction created it is recorded
  # durably before anything is staged, because rollback depends on it.
  if [[ ! -e "${PACKAGE_DIR}" ]]; then
    injected_at directory && halt "injected failure before creating the package directory"
    mkdir "${PACKAGE_DIR}"
    chmod "${PACKAGE_DIR_MODE}" "${PACKAGE_DIR}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${PACKAGE_DIR}"
    fi
    sync_path "${PACKAGE_DIR}"
    PACKAGE_DIR_CREATED="yes"
    journal_write PREPARING
    injected_at created && halt "injected failure after creating the package directory"
  fi

  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    gen11="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    injected_at stage && halt "injected failure before staging"

    if [[ "${operation}" == "CREATE" ]]; then
      # A CREATE has no predecessor bytes to retain. What it does require is
      # that the pathname is genuinely free -- and a symlink sitting at the
      # target is exactly the substitution this refuses to publish through.
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"
    else
      # Generic capability, unused by this matrix. Retained so a future
      # Generation-11-shaped matrix cannot silently lose the REPLACE path.
      halt "${target} is declared ${operation}, which this transaction does not implement"
    fi
    rm -f "${target}${BACKUP_SUFFIX}"

    rm -f "${prepared}"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${prepared}" \
      || halt "could not materialise ${source} from ${COMMIT}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen11}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen11}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
    injected_at staged && halt "injected failure after staging a Generation-11 object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  # Durably PREPARED: the staged material is now the transaction's property and
  # recovery may complete it forward. Unwinding it silently would discard
  # material a recovery is entitled to use.
  PREPARING=0
  local staged_n created_n
  staged_n="$(matrix_count)"; created_n="$(matrix_count_of CREATE)"
  ok "PREPARE complete: ${staged_n} $(plural "${staged_n}" object objects) staged ($(matrix_names)), ${created_n} $(plural "${created_n}" pathname pathnames) reserved, no rollback material required for a CREATE"
}

verify_prepared_set() {
  local row target gen11
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen11="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen11}" ]] \
      || halt "prepared object for ${target} does not verify"
  done
  local n; n="$(matrix_count)"
  ok "all ${n} prepared objects verify against the reviewed commit"
}

# --- COMMIT ----------------------------------------------------------------
#
# Publication consumes prepared bytes only. No git call, and no read of the
# repository, happens between here and COMMITTED: everything the transaction
# needs from the reviewed commit was materialised and verified in PREPARE. That
# is a property of the Generation-11 model carried forward unchanged, and it is
# what makes the publication window independent of the checkout.
commit_targets() {
  local row target mode gen10 gen11 prepared index=0 observed owner_now
  journal_write COMMITTING
  if injected_at committing; then
    rollback "injected failure immediately after COMMITTING"
    return 1
  fi
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    gen10="$(field "${row}" 4)"; gen11="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    if [[ -n "${FIXTURE}" && "${KYRI_GEN11_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run. Decided from the
    # target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen10}" "${gen11}")" == "GEN11" ]]; then
      PROGRESS["${index}"]="GEN11"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING
    if injected_at publish; then
      rollback "injected failure immediately before publication"
      return 1
    fi

    # rename(2): atomic for this pathname. A reader sees the pathname absent or
    # sees the complete module, never a partially written one. It is atomic for
    # ONE pathname and this transaction has nine, which is what the journal
    # exists to carry -- and why every intermediate state must fail closed.
    mv -f "${prepared}" "${target}"
    sync_path "${target}"

    if injected_at verify; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "injected failure during post-publication verification"
      return 1
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen11}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen11}"
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

    PROGRESS["${index}"]="GEN11"
    journal_write COMMITTING
  done

  if injected_at precommit; then
    rollback "injected failure immediately before the durable commit point"
    return 1
  fi

  # THE COMMIT POINT. Everything after this line is bookkeeping, and no failure
  # in it may revert the generation.
  journal_write COMMITTED
  injected_at postcommit \
    && bad "injected failure immediately after COMMITTED; Generation 11 stands"
  OUTCOME="COMMITTED"
  local published_n
  published_n="$(matrix_count)"
  ok "COMMIT complete: ${published_n} $(plural "${published_n}" object objects) created and verified ($(matrix_names))"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# Reachable only before COMMITTED. Every target in this matrix is a CREATE, so
# rollback is removal -- fenced by proof that what is being removed is exactly
# what this transaction published. The REPLACE branch is generic implementation
# carried from the accepted Generation-11 transaction and is never taken here.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target operation gen11 observed removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    gen11="$(field "${row}" 5)"

    [[ "${operation}" == "CREATE" ]] || { bad "${target} is ${operation}; this transaction cannot roll that back"; continue; }

    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
      continue
    fi
    if [[ -L "${target}" || ! -f "${target}" ]]; then
      bad "${target} is not the regular file this transaction created; NOT removing it"
      continue
    fi
    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen11}" ]]; then
      bad "${target} is ${observed}, not the Generation-11 object this transaction installed; NOT removing it"
      continue
    fi
    rm -f "${target}"
    sync_path "${target}"
    removed=$((removed + 1))
  done

  # Prepared material belongs to a transaction that is not going to finish.
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    rm -f "${target}${PREPARED_SUFFIX}" "${target}${BACKUP_SUFFIX}"
  done

  classify_all
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    # The directory goes only if this transaction made it and nothing else has
    # moved in. An empty directory left behind is untidy; a directory removed
    # out from under somebody else's file is a fault.
    local dir_note=""
    if [[ "${PACKAGE_DIR_CREATED}" == "yes" && -d "${PACKAGE_DIR}" ]]; then
      if [[ -z "$(find "${PACKAGE_DIR}" -mindepth 1 -print -quit)" ]]; then
        rmdir "${PACKAGE_DIR}"
        sync_path "$(dirname "${PACKAGE_DIR}")"
        PACKAGE_DIR_CREATED="no"
        dir_note=", and the package directory this transaction created was removed"
      else
        dir_note=", and the package directory was left in place because it is not empty"
      fi
    fi
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    local rolled_n
    rolled_n="$(matrix_count)"
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 11 (${removed} removed)${dir_note}"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN10=${BASELINE_COUNT} GEN11=${TARGET_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed. This is the
# accepted Generation-8/9/10 model applied to nine CREATE targets:
#
#   * unknown bytes anywhere              -> fail closed for operator disposition
#   * every target already Generation 12  -> already committed
#   * every target still absent           -> nothing was published
#   * mixed, and every remaining prepared object verifies -> complete FORWARD
#   * mixed otherwise                     -> roll BACK by removing what landed
recover() {
  local state="$1"
  PACKAGE_DIR_CREATED="$(journal_package_dir_created)"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN10=%d GEN11=%d UNKNOWN=%d (of %d targets)\n' \
    "${state}" "${BASELINE_COUNT}" "${TARGET_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (not the Generation-11 object, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-11 set is already installed"
    return 0
  fi
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-11 object was published; the host is at Generation 11"
    return 0
  fi

  local row target gen10 gen11 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen10="$(field "${row}" 4)"; gen11="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen10}" "${gen11}")" == "GEN11" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen11}" ]] || { forward=0; break; }
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
#
# Written only after COMMITTED, and under new names. Generation-11 evidence is
# the record of what that gate accepted and is never overwritten: a generation
# that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" && -f "${BASELINE_HELPER_EVIDENCE}" ]] \
    || halt "Generation-11 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-11 evidence; Generation 11 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN11_LIBRARY_EVIDENCE}.writing"
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN11_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN11_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-11 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN11_COMMIT}"
    printf 'predecessor generation 10\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    printf 'state COMMITTED\n'
    printf 'package_dir %s\n' "${PACKAGE_DIR}"
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
    done
    local excluded
    for excluded in "${EXCLUDED[@]}"; do
      printf 'excluded %s\n' "${excluded}"
    done
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN11_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN11_LIBRARY_EVIDENCE}.writing" "${GEN11_HELPER_EVIDENCE}.writing"
  sync_path "${GEN11_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN11_HELPER_EVIDENCE}.writing"
  mv -f "${GEN11_LIBRARY_EVIDENCE}.writing" "${GEN11_LIBRARY_EVIDENCE}"
  mv -f "${GEN11_HELPER_EVIDENCE}.writing" "${GEN11_HELPER_EVIDENCE}"
  sync_path "${GEN11_LIBRARY_EVIDENCE}"
  sync_path "${GEN11_HELPER_EVIDENCE}"
  ok "Generation-11 evidence written; Generation-11 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  if injected_at cleanup; then
    bad "injected cleanup failure after COMMITTED; Generation 11 remains installed"
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
  local row source target gen11 observed blob mode
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; gen11="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen11}" ]] \
      || bad "${source} at ${COMMIT} is ${blob:-absent}, expected the pinned ${gen11}"
    [[ -L "${target}" ]] && bad "installed ${target} is a symlink"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen11}" ]] \
      || bad "installed ${target} is ${observed:-absent}, expected ${gen11}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "${mode#0}" ]] \
      || bad "installed ${target} has mode $(stat -c '%a' "${target}" 2>/dev/null), expected ${mode#0}"
  done
  [[ -d "${PACKAGE_DIR}" && ! -L "${PACKAGE_DIR}" ]] \
    || bad "${PACKAGE_DIR} is not a directory"
  [[ "$(stat -c '%a' "${PACKAGE_DIR}" 2>/dev/null)" == "${PACKAGE_DIR_MODE#0}" ]] \
    || bad "${PACKAGE_DIR} has mode $(stat -c '%a' "${PACKAGE_DIR}" 2>/dev/null), expected ${PACKAGE_DIR_MODE#0}"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_TARGET}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-11 ${EXPECTED_LIBRARY_FILES_TARGET}"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) installed Generation-11 objects correspond to the reviewed commit ${COMMIT}"
}

# The mutation and control-plane surfaces must not be installed. Asserted over
# the installed tree rather than over the matrix, because the question is what
# the runtime can reach, not what this ceremony intended.
verify_excluded_absent() {
  local excluded present=0
  for excluded in "${EXCLUDED[@]}"; do
    if [[ -e "${LIBRARY_ROOT}/${excluded}" || -L "${LIBRARY_ROOT}/${excluded}" ]]; then
      bad "the excluded module ${excluded} is present in the installed runtime"
      present=$((present + 1))
    fi
  done
  if [[ -e "${LIBRARY_ROOT}/tools/trust" || -L "${LIBRARY_ROOT}/tools/trust" ]]; then
    bad "the Trust plane is present in the installed runtime"
    present=$((present + 1))
  fi
  (( present == 0 )) \
    && ok "the governed write path, the operator input surface and the Trust plane are all absent from the installed runtime"
}

# Every object the Generation-11 evidence recorded must still be exactly what
# that evidence says, and every installed object that is not a declared target
# must be accounted for by it. A CREATE adds pathnames, so the targets are
# legitimately absent from the predecessor evidence and are the only objects
# permitted to be.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${BASELINE_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is not accounted for by the Generation-11 evidence and is not a declared Generation-11 target"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-11 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-11 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${BASELINE_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every Generation-11 runtime object is exactly its accepted baseline, and nothing was removed"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify-source)
  # Source-only, and it touches no installed path at all. The question an
  # operator has before installing is "is this package sound?", and Generation
  # 11 had no way to ask it: every mode reasoned about the host. This one
  # reasons about the proposal -- repository authority, pinned source digests,
  # and the import closure -- so a package can be refused before anything is
  # staged rather than after.
  require_repository
  require_source_digests
  require_closed_closure

  # The two corrections this generation exists to deploy, proved present in the
  # reviewed source rather than assumed from a commit message.
  evidence_source="$(git_as_owner show "${COMMIT}:tools/capability/fabric_evidence.py")" \
    || halt "the reviewed commit carries no fabric_evidence.py"
  for marker in "operation-not-permitted-by-scope" "capability-not-permitted-by-scope" \
                "classification-not-permitted-by-scope" "target-not-permitted-by-scope" \
                "operation-not-supplied" "invalid-effective-scope"; do
    grep -q -- "${marker}" <<<"${evidence_source}" \
      || halt "the reviewed fabric_evidence.py does not carry the G11-X refusal ${marker}"
  done
  ok "the reviewed source carries the G11-X per-invocation operation and scope authority"
  for marker in "selected-instance-no-longer-eligible" "evaluate_eligibility" \
                "_FabricReader" "_TrustReader"; do
    grep -q -- "${marker}" <<<"${evidence_source}" \
      || halt "the reviewed fabric_evidence.py does not carry the G11-Y element ${marker}"
  done
  ok "the reviewed source carries the G11-Y current-eligibility revalidation"

  note "no installed path was read for state and none was written"
  printf '\n'
  printf 'Generation 12 source verification: all checks passed. %s object(s) would change.\n' \
    "$(matrix_count)"
  exit 0
  ;;

--verify)
  require_repository
  require_source_digests
  require_closed_closure

  # An already-installed host is answered before the Generation-11 baseline gate
  # rather than by it. That gate proves the host is at the accepted predecessor
  # and necessarily fails once thirteen objects have been added -- on object
  # count alone, 70 against 57. Letting it answer would report a correct
  # Generation-12 installation as a corrupt Generation-11 one, which is the
  # wrong sentence
  # about a healthy host. --verify asks "is this host ready to install"; the
  # truthful answer here is "no, because it already has", and the mode that
  # audits the result is --verify-installed.
  classify_all
  if (( TARGET_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 12; use --verify-installed to audit the installed generation"
    require_no_foreign_package_objects
    require_gates_closed
    verify_excluded_absent
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 12 / installed Fabric dependency closure verify: already installed.\n'
    exit 0
  fi

  # The foreign-object gate runs before the baseline gate deliberately. Both
  # refuse an undeclared module in the Trust package directory -- the baseline
  # gate would notice it as a 58th object -- but "the installed library holds 58
  # objects, expected 57" tells an operator far less than the name of the file.
  # The more specific diagnostic should be the one they read.
  require_no_foreign_package_objects
  require_baseline
  require_target_state
  require_no_transaction_residue
  require_gates_closed
  require_same_filesystem
  verify_excluded_absent

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  # The fully-installed case exited above, so only two states remain here.
  if (( BASELINE_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 11 and ready for the Generation-12 installation: $(matrix_count) CREATE $(plural "$(matrix_count)" operation operations) ($(matrix_names)), object count ${EXPECTED_LIBRARY_FILES_BASELINE} -> ${EXPECTED_LIBRARY_FILES_TARGET}"
  else
    bad "mixed target state: baseline=${BASELINE_COUNT} target=${TARGET_COUNT} unknown=${UNKNOWN_COUNT}"
  fi
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--install)
  require_repository
  require_source_digests
  require_closed_closure
  require_gates_closed

  TRANSACTION_ID="gen11-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  AUTHORITY_BEFORE="$(authority_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_no_foreign_package_objects
    require_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 12 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( TARGET_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 12 is already installed: nothing to do"
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
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    # The host is in a correct state and the request was not carried out. Both
    # are true, and the exit status reports the second: an operator who asked
    # for an installation and got a rollback must not read success.
    bad "the transaction rolled back: the host is at Generation 11 and nothing was installed"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${AUTHORITY_BEFORE}" == "$(authority_fingerprint)" ]] \
    || bad "the implementation-authority namespace changed during installation"
  ;;

--verify-installed)
  require_repository
  verify_installed_set
  verify_excluded_absent
  verify_unchanged_surface
  require_no_foreign_package_objects
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"
  [[ -f "${GEN11_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-11 library evidence is missing"
  [[ -f "${GEN11_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-11 helper evidence is missing"
  [[ -f "${BASELINE_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-11 evidence was not preserved"
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
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    bad "recovery rolled the transaction back: the host is at Generation 11 and Generation 11 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 11 / installed Fabric dependency closure %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 11 / installed Fabric dependency closure %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
