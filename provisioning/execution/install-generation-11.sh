#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 Generation-11 installation ceremony: the installed Capability
# Runtime stops borrowing a checkout.
#
# WHAT IS DIFFERENT FROM GENERATION 10. Generation 10 was four REPLACE
# operations at an unchanged object count of 48. Generation 11 is NINE CREATE
# operations and no REPLACE, and the installed object count rises 48 -> 57. Not
# one Generation-10 object is named by this matrix, so none can be altered: the
# transaction can only add a package that is not there.
#
# THAT INVERTS THE SAFETY ARGUMENT RATHER THAN REMOVING IT. Generation 10's
# hazard was the mixed window -- `rename(2)` is atomic for one pathname, four
# renames are not atomic together, and a Generation-9 caller could observe a
# mixture in which Generation-10 `package_resolution` had landed and
# Generation-10 `evidence` had not. Generation 11 has no such coupled pair,
# because there is no predecessor to be mixed with: every intermediate state of
# this transaction is a package that is incomplete, and an incomplete package
# fails CLOSED. Measured, not assumed -- with the directory present and any
# module absent, `import tools.fabric.inspection` raises ModuleNotFoundError,
# both when `__init__.py` has landed and when it has not (Python resolves the
# bare directory as a namespace package and still finds no submodule). The
# caller that would observe the window, `tools/capability/fabric_evidence.py`,
# cannot import today either, so no intermediate state is a regression on the
# Generation-10 baseline.
#
# WHAT REPLACES THE ROLLBACK OBJECT. A REPLACE rolls back by restoring retained
# predecessor bytes. A CREATE has no predecessor bytes, so its rollback is
# removal -- and removal is the more dangerous verb. It is therefore fenced:
# this transaction removes a target only when the target is a regular file whose
# bytes are exactly the Generation-11 object it published. Anything else --
# absent, a symlink, a directory, or bytes that are neither -- is left exactly
# as found for operator disposition. A rollback that deleted unknown bytes would
# destroy the only evidence of what happened.
#
# THE CLOSURE IS THE DELTA, AND IT IS RE-DERIVED HERE. Generation 10 proved its
# matrix closed by asking git for the source diff between two authorities.
# Generation 11 cannot: its delta is not a diff, it is the transitive import
# closure of `tools.fabric.inspection` minus what Generation 10 already
# installs. So the closure is recomputed from the reviewed commit's own blobs on
# every run, and the matrix must equal it exactly. A module that entered the
# closure since review -- or a module added to the matrix that the closure does
# not require -- refuses the transaction. That is what keeps "install only the
# reviewed dependency closure" a check rather than a promise.
#
# WHAT THIS INSTALLS. Exactly nine CREATE operations plus the package directory
# that holds them, materialised from the reviewed commit object below and from
# nothing else.
#
# WHAT THIS DOES NOT DO. It writes no sudoers policy, invokes no privileged
# helper, never calls the transition or the worker, contacts no container
# runtime, allocates no governance identifier, creates no Trust, Fabric, or
# Capability store, provisions no fixture package material, does not mount the
# Root Authority, and does not touch the implementation-authority namespace
# except to read a fingerprint and prove it did not move. In particular it does
# NOT advance `current-generation`: CGEN is the governed implementation
# authority and is moved by admission, not by a library installation. The two
# numbering schemes are independent and this ceremony touches only the second.
#
# Usage:
#   install-generation-11.sh --verify            read-only: is the host at G10?
#   install-generation-11.sh --install           perform the nine-object transaction
#   install-generation-11.sh --verify-installed  read-only: is the host at G11?
#   install-generation-11.sh --recover           resume an interrupted transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   docs/development/reports/eng-0005/2026-08-26-g11-b-runtime-dependency-closure.md
#   docs/development/reports/eng-0005/2026-08-26-g11-c-selection-preflight.md
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

# The reviewed Generation-11 source authority. Pinned, never HEAD. This is the
# commit at which all five known Generation-11 source blockers were closed
# (G11-A1, G11-A2, G11-A3, G11-B, G11-C) and at which the reviewed nine-file
# closure carries the digests declared in generation-11-surface.sh.
COMMIT="6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75"

# The accepted Generation-10 source authority, and the baseline this transaction
# requires the host to be at.
GEN10_COMMIT="83da574bacde762de3222c60eb1873b2a750e54c"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
TRANSACTION_ROOT="/root/kyri-gen11-transaction"
GEN10_LIBRARY_EVIDENCE="/root/kyri-gen10-library-digests.txt"
GEN10_HELPER_EVIDENCE="/root/kyri-gen10-helper-digests.txt"
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
EXPECTED_LIBRARY_FILES_GEN10=48
EXPECTED_LIBRARY_FILES_GEN11=57

# The one module in the closure Generation 10 already installs. Named so the
# closure check can subtract it by declaration rather than by coincidence.
ALREADY_INSTALLED=(
"tools/__init__.py"
"tools/common/__init__.py"
"tools/common/immutable_store.py"
)

MODE=""
FIXTURE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify|--install|--verify-installed|--recover)
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
  GEN10_LIBRARY_EVIDENCE="${FIXTURE}${GEN10_LIBRARY_EVIDENCE}"
  GEN10_HELPER_EVIDENCE="${FIXTURE}${GEN10_HELPER_EVIDENCE}"
  GEN11_LIBRARY_EVIDENCE="${FIXTURE}${GEN11_LIBRARY_EVIDENCE}"
  GEN11_HELPER_EVIDENCE="${FIXTURE}${GEN11_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

# The package directory the nine objects live in. It does not exist at
# Generation 10 and is not a matrix row: a directory has no bytes to pin, so it
# is created and verified by property (owner, mode, and emptiness of anything
# this transaction did not declare) rather than by digest.
PACKAGE_DIR="${LIBRARY_ROOT}/tools/fabric"
PACKAGE_DIR_MODE="0755"

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen11.new"
BACKUP_SUFFIX=".kyri-gen11.gen10"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
GEN10_COUNT=0; GEN11_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
PACKAGE_DIR_CREATED="no"

# The closure check materialises the reviewed tools tree into a temporary
# directory. It is removed on every exit path, including a halt, so a refusal
# never leaves reviewed source lying around outside the repository.
CLOSURE_STAGING=""

# Set for the duration of PREPARE and cleared once the transaction is durably
# PREPARED. While it is set, nothing has been published, so any exit at all --
# a halt, an injected failure, an unexpected error -- must leave the host at a
# whole Generation 10 rather than at Generation 10 plus this transaction's
# litter. See unwind_preparation.
PREPARING=0

# Unwind an interrupted PREPARE. Reachable only before anything is published,
# so there is no generation to protect -- only litter to remove.
#
# Generation 10 could leave its prepared and retained copies behind after a
# failed preparation, and did: its targets were REPLACE, every pathname already
# existed, and the next run refused on residue. Generation 11 cannot be so
# relaxed, because its litter includes a `tools/fabric` DIRECTORY, and the
# accepted Generation-10 installed surface is one in which that directory does
# not exist. Leaving it would mean a host that reports itself at Generation 10
# while carrying a pathname Generation 10 never had.
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

  printf 'unwound  preparation: %d staged object(s) removed; the host is at Generation 10\n' \
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

# --- the nine generation-11 objects, pinned both ways -----------------------
#
# source | target | mode | operation | gen10-sha256 | gen11-sha256
#
# The Generation-10 column is ABSENT for every row, because at Generation 10 not
# one of these pathnames exists. That is the same ABSENT vocabulary the
# Generation-10 ceremony carried as generic CREATE capability and never
# exercised; Generation 11 is the transaction it was retained for.
#
# Order is publication order and is the order the reviewed surface declaration
# fixed: the package initialiser, then the leaves, then the modules that import
# them. It is preserved here rather than re-decided, because it is reviewed
# authority. It is also not load-bearing for safety -- every intermediate state
# fails closed either way, as the header records -- so preserving it costs
# nothing and re-deciding it would silently amend an accepted declaration.
MATRIX=(
"tools/fabric/__init__.py|${LIBRARY_ROOT}/tools/fabric/__init__.py|0444|CREATE|ABSENT|e761edea8dfe6df49080d58441f41b48558c335d82a309ca12e7cd271bdf6230"
"tools/fabric/errors.py|${LIBRARY_ROOT}/tools/fabric/errors.py|0444|CREATE|ABSENT|ddc6a7654ca5e38aa828070bd5400a7bc93bee48db231494e235ff8d9c1e954a"
"tools/fabric/identifiers.py|${LIBRARY_ROOT}/tools/fabric/identifiers.py|0444|CREATE|ABSENT|e523096cb23864d0970ccd038c8ad1532ca0a245b268a51838195c6328b63226"
"tools/fabric/models.py|${LIBRARY_ROOT}/tools/fabric/models.py|0444|CREATE|ABSENT|c6e0ce6d4b70a077072794ffd2cde548ea3b031c061e108eb37769dccd5d657b"
"tools/fabric/request_identity.py|${LIBRARY_ROOT}/tools/fabric/request_identity.py|0444|CREATE|ABSENT|b0ff8b1dde147d186b0675b55ecdc9999d603dede9e4f459b1cd3d8bccfc1267"
"tools/fabric/evidence.py|${LIBRARY_ROOT}/tools/fabric/evidence.py|0444|CREATE|ABSENT|48abf37c7a8c4bb4a16398aa2f4c32c98ecf8af72dfbb85df96f2f9dcf5e1be1"
"tools/fabric/store.py|${LIBRARY_ROOT}/tools/fabric/store.py|0444|CREATE|ABSENT|beda03b71cbdc5568afe0c54d682afbdce94b508b4d18beefa0c78704aa3a13a"
"tools/fabric/validator.py|${LIBRARY_ROOT}/tools/fabric/validator.py|0444|CREATE|ABSENT|dfdc02ffe0f6040751250216de7fad135e59b174c9084287e039eb0d02c1acda"
"tools/fabric/inspection.py|${LIBRARY_ROOT}/tools/fabric/inspection.py|0444|CREATE|ABSENT|a59d36b1900fcd3b25bdd649c3e4cb37c1de8fd2e9700234d4355833c250ca4a"
)

# The Fabric modules the closure deliberately excludes, restated from the
# reviewed surface declaration. These are the governed write path, the operator
# input surface, and the modules only they reach. Each is asserted absent from
# the computed closure, absent from the matrix, and absent from the installed
# tree -- three independent checks, because a runtime that acquired the mutation
# surface by accident would look exactly like one that acquired it on purpose.
EXCLUDED=(
"tools/fabric/admission.py"
"tools/fabric/cli.py"
"tools/fabric/eligibility.py"
"tools/fabric/selection.py"
"tools/fabric/trust_adapter.py"
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
# One field is new against Generation 10: `package_dir_created`. A CREATE
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
    printf 'baseline_commit=%s\n' "${GEN10_COMMIT}"
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
  GEN10_COUNT=0; GEN11_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen10="$(field "${row}" 4)"; gen11="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen10}" "${gen11}")"
    case "${state}" in
      GEN10) GEN10_COUNT=$((GEN10_COUNT + 1)) ;;
      GEN11) GEN11_COUNT=$((GEN11_COUNT + 1)) ;;
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
    || halt "the reviewed Generation-11 commit ${COMMIT} is not in this repository"
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-11 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN10_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-10 authority is not an ancestor of the Generation-11 authority"
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

# Every Generation-11 runtime byte must equal the reviewed commit object, and
# every target must be genuinely new: a row whose source already existed at the
# Generation-10 authority with these bytes would be a REPLACE wearing a CREATE's
# label. The predecessor assertion for a CREATE is that the pathname is not part
# of the Generation-10 installed surface, which require_gen10_baseline proves
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
  (( drift == 0 )) || halt "the reviewed commit does not carry the pinned Generation-11 surface"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-11 source $(plural "${checked_n}" object objects) match the reviewed commit ${COMMIT}"
}

# --- the closed closure ----------------------------------------------------
#
# The load-bearing gate, and the one that has no Generation-10 analogue. The
# matrix must be exactly the transitive import closure of
# `tools.fabric.inspection` -- the single symbol the installed Capability
# Runtime reaches into Fabric for -- minus the modules Generation 10 already
# installs. Computed here from the reviewed commit's own blobs, by walking the
# import statements, so that:
#
#   * a module that entered the closure since review refuses the transaction
#     rather than being silently left out of an installed package that now needs
#     it;
#   * a module added to the matrix that the closure does not require refuses
#     rather than widening the installed runtime surface;
#   * "install only the reviewed closure" is verified on every run instead of
#     being asserted once in a report.
#
# The blobs are materialised from the reviewed commit into a temporary tree as
# the repository owner. The working tree is never the input.
require_closed_closure() {
  local staging exported=0
  staging="$(mktemp -d)"
  CLOSURE_STAGING="${staging}"

  # One git invocation, and the whole `tools` tree as the reviewed commit
  # recorded it. Extracting the tree rather than the modules the matrix names is
  # deliberate: a closure computed only over the declared files could never
  # discover that it needs a file nobody declared.
  git_as_owner archive --format=tar "${COMMIT}" tools | tar -x -C "${staging}" \
    || halt "could not materialise the tools tree from ${COMMIT}"
  exported="$(find "${staging}/tools" -type f -name '*.py' | wc -l)"
  (( exported > 0 )) || halt "the reviewed commit exposes no tools sources"

  local declared="" already="" excluded_list="" row
  for row in "${MATRIX[@]}"; do declared+="$(field "${row}" 0)"$'\n'; done
  for path in "${ALREADY_INSTALLED[@]}"; do already+="${path}"$'\n'; done
  for path in "${EXCLUDED[@]}"; do excluded_list+="${path}"$'\n'; done

  local verdict
  verdict="$(DECLARED="${declared}" ALREADY="${already}" EXCLUDED_LIST="${excluded_list}" \
    python3 - "${staging}" <<'PY'
import ast, os, sys

root = sys.argv[1]

def module_path(module):
    candidate = os.path.join(root, module.replace(".", "/") + ".py")
    if os.path.isfile(candidate):
        return candidate
    package = os.path.join(root, module.replace(".", "/"), "__init__.py")
    if os.path.isfile(package):
        return package
    return None

def imported_by(module, path):
    package = module if path.endswith("__init__.py") else module.rsplit(".", 1)[0]
    names = set()
    for node in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                parts = package.split(".")
                if node.level > 1:
                    parts = parts[: len(parts) - (node.level - 1)]
                target = ".".join(parts) + ("." + node.module if node.module else "")
            else:
                target = node.module or ""
            names.add(target)
            # `from x import y` may name a submodule rather than an attribute.
            names.update(target + "." + alias.name for alias in node.names)
    return names

# Transitive closure of the one entry point the installed runtime reaches.
seen, pending = set(), ["tools.fabric.inspection"]
while pending:
    module = pending.pop()
    if module in seen:
        continue
    path = module_path(module)
    if path is None:
        continue
    seen.add(module)
    for name in imported_by(module, path):
        if name.startswith("tools.") and module_path(name):
            pending.append(name)

# Every package initialiser on the way to a closure member is executed by the
# import system and is therefore part of the closure too.
for module in list(seen):
    parts = module.split(".")
    for depth in range(1, len(parts)):
        parent = ".".join(parts[:depth])
        if module_path(parent):
            seen.add(parent)

closure = {os.path.relpath(module_path(m), root) for m in seen}

def lines(name):
    return {line for line in os.environ.get(name, "").split("\n") if line}

declared = lines("DECLARED")
already = lines("ALREADY")
excluded = lines("EXCLUDED_LIST")

required = closure - already
problems = []

for missing in sorted(required - declared):
    problems.append(f"the closure requires {missing}, which the matrix does not declare")
for extra in sorted(declared - required):
    problems.append(f"the matrix declares {extra}, which the closure does not require")
for stale in sorted(already - closure):
    problems.append(f"{stale} is declared already-installed but is not in the closure")
for forbidden in sorted(excluded & closure):
    problems.append(f"EXCLUDED module {forbidden} has entered the closure")
for forbidden in sorted(excluded & declared):
    problems.append(f"EXCLUDED module {forbidden} appears in the matrix")

if problems:
    print("MISMATCH")
    for problem in problems:
        print(problem)
else:
    print("CLOSED")
    print(f"{len(closure)} {len(required)}")
PY
  )" || halt "the closure could not be computed from ${COMMIT}"

  if [[ "$(head -1 <<<"${verdict}")" != "CLOSED" ]]; then
    local problem
    while IFS= read -r problem; do
      [[ -n "${problem}" && "${problem}" != "MISMATCH" ]] && bad "${problem}"
    done <<<"${verdict}"
    halt "the declared matrix is not the reviewed dependency closure"
  fi

  local counts total required_n
  counts="$(sed -n '2p' <<<"${verdict}")"
  total="${counts%% *}"; required_n="${counts##* }"
  ok "the matrix is exactly the reviewed dependency closure: ${total} modules reachable from tools.fabric.inspection, ${#ALREADY_INSTALLED[@]} already installed, ${required_n} to install ($(matrix_count_of CREATE) CREATE, $(matrix_count_of REPLACE) REPLACE)"
  ok "all ${#EXCLUDED[@]} deliberately excluded Fabric modules are outside the closure and outside the matrix"
  rm -rf "${staging}"
  CLOSURE_STAGING=""
}

# --- generation-10 baseline -------------------------------------------------
require_gen10_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN10}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-10 ${EXPECTED_LIBRARY_FILES_GEN10}"

  [[ -f "${GEN10_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-10 library evidence at ${GEN10_LIBRARY_EVIDENCE} is missing"
  [[ -f "${GEN10_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-10 helper evidence at ${GEN10_HELPER_EVIDENCE} is missing"

  # Every installed object accounted for by the accepted evidence, and every
  # recorded digest matching the bytes actually there.
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN10_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-10 evidence"
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
      || { bad "the Generation-10 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${GEN10_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-10 baseline"
  ok "the installed runtime is exactly the accepted Generation-10 baseline (${count} objects)"
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
  [[ -e "${PACKAGE_DIR}" ]] || { ok "the Fabric package directory does not exist yet, as Generation 10 requires"; return; }
  [[ -L "${PACKAGE_DIR}" ]] && halt "${PACKAGE_DIR} is a symlink; refusing to install through it"
  [[ -d "${PACKAGE_DIR}" ]] || halt "${PACKAGE_DIR} exists and is not a directory"

  local entry foreign=0
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    is_target "${entry}" && continue
    [[ "${entry}" == *"${PREPARED_SUFFIX}" || "${entry}" == *"${BACKUP_SUFFIX}" ]] && continue
    # Bytecode caches are the interpreter's, not this transaction's. Every other
    # installed package on this host already carries one -- the Generation-10
    # runtime has `__pycache__` under the library root, `tools`, `capability`
    # and `execution` -- and they appear the first time the runtime imports
    # anything, without anyone installing them. Refusing them would mean a
    # healthy Generation-11 host stopped verifying the moment it was first used.
    # They are also not an import surface: CPython will not load a cached module
    # whose source is absent in this layout, so a stray `.pyc` cannot smuggle in
    # a module -- which is what verify_excluded_absent checks, over the sources.
    [[ "${entry}" == *"/__pycache__" || "${entry}" == *"/__pycache__/"* ]] && continue
    bad "foreign object in the Fabric package directory: ${entry#"${LIBRARY_ROOT}"/}"
    foreign=$((foreign + 1))
  done < <(find "${PACKAGE_DIR}" -mindepth 1 -print | sort)

  (( foreign == 0 )) \
    || halt "the Fabric package directory holds objects this transaction did not declare"
  ok "the Fabric package directory holds only declared objects"
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
      || halt "the Fabric package directory is not on the same filesystem as the library root"
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
# is a property of the Generation-10 model carried forward unchanged, and it is
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
# carried from the accepted Generation-10 transaction and is never taken here.
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
  if (( GEN10_COUNT == ${#MATRIX[@]} )); then
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
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 10 (${removed} removed)${dir_note}"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN10=${GEN10_COUNT} GEN11=${GEN11_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed. This is the
# accepted Generation-8/9/10 model applied to nine CREATE targets:
#
#   * unknown bytes anywhere              -> fail closed for operator disposition
#   * every target already Generation 11  -> already committed
#   * every target still absent           -> nothing was published
#   * mixed, and every remaining prepared object verifies -> complete FORWARD
#   * mixed otherwise                     -> roll BACK by removing what landed
recover() {
  local state="$1"
  PACKAGE_DIR_CREATED="$(journal_package_dir_created)"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN10=%d GEN11=%d UNKNOWN=%d (of %d targets)\n' \
    "${state}" "${GEN10_COUNT}" "${GEN11_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (not the Generation-11 object, and not absent)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN11_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-11 set is already installed"
    return 0
  fi
  if (( GEN10_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: no Generation-11 object was published; the host is at Generation 10"
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
# Written only after COMMITTED, and under new names. Generation-10 evidence is
# the record of what that gate accepted and is never overwritten: a generation
# that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${GEN10_LIBRARY_EVIDENCE}" && -f "${GEN10_HELPER_EVIDENCE}" ]] \
    || halt "Generation-10 evidence vanished during installation"
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
    printf 'baseline_commit %s\n' "${GEN10_COMMIT}"
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
  ok "Generation-11 evidence written; Generation-10 evidence preserved"
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
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN11}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-11 ${EXPECTED_LIBRARY_FILES_GEN11}"
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

# Every object the Generation-10 evidence recorded must still be exactly what
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
                  "${GEN10_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is not accounted for by the Generation-10 evidence and is not a declared Generation-11 target"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-10 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-10 evidence records ${recorded_relative}, which is no longer installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${GEN10_LIBRARY_EVIDENCE}")

  (( drift == 0 )) \
    && ok "every Generation-10 runtime object is exactly its accepted baseline, and nothing was removed"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  require_repository
  require_source_digests
  require_closed_closure

  # An already-installed host is answered before the Generation-10 baseline gate
  # rather than by it. That gate proves the host is at the accepted predecessor
  # and necessarily fails once nine objects have been added -- on object count
  # alone, 57 against 48. Letting it answer would report a correct Generation-11
  # installation as a corrupt Generation-10 one, which is the wrong sentence
  # about a healthy host. --verify asks "is this host ready to install"; the
  # truthful answer here is "no, because it already has", and the mode that
  # audits the result is --verify-installed.
  classify_all
  if (( GEN11_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 11; use --verify-installed to audit the installed generation"
    require_no_foreign_package_objects
    require_gates_closed
    verify_excluded_absent
    note "authority namespace fingerprint: $(authority_fingerprint)"
    printf '\n'
    printf 'Generation 11 / installed Fabric dependency closure verify: already installed.\n'
    exit 0
  fi

  # The foreign-object gate runs before the baseline gate deliberately. Both
  # refuse an undeclared module in the Fabric package directory -- the baseline
  # gate would notice it as a 49th object -- but "the installed library holds 49
  # objects, expected 48" tells an operator far less than the name of the file.
  # The more specific diagnostic should be the one they read.
  require_no_foreign_package_objects
  require_gen10_baseline
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
  if (( GEN10_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 10 and ready for the Generation-11 installation: $(matrix_count) CREATE $(plural "$(matrix_count)" operation operations) ($(matrix_names)), object count ${EXPECTED_LIBRARY_FILES_GEN10} -> ${EXPECTED_LIBRARY_FILES_GEN11}"
  else
    bad "mixed target state: GEN10=${GEN10_COUNT} GEN11=${GEN11_COUNT}"
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
    require_gen10_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( GEN11_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 11 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( GEN11_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 11 is already installed: nothing to do"
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
    bad "the transaction rolled back: the host is at Generation 10 and nothing was installed"
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
  [[ -f "${GEN10_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-10 evidence was not preserved"
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
    bad "recovery rolled the transaction back: the host is at Generation 10 and Generation 11 is not installed"
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
