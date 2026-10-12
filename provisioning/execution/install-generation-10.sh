#!/usr/bin/env bash
set -Eeuo pipefail

# The ENG-0005 Generation-10 installation ceremony: the package pipeline becomes
# tree-native.
#
# WHAT IS DIFFERENT FROM GENERATION 9. Generation 9 was one REPLACE.
# Generation 10 is FOUR. The installed object count is unchanged at 48 in both
# directions, no pathname is created, and no pathname is removed. What four
# replaces costs is that `rename(2)` is atomic for ONE pathname and there is no
# atomic multi-file publication anywhere in POSIX. So between the first and the
# fourth rename the installed runtime is genuinely a mixture, and the
# transaction is what makes that window bounded, durable, and recoverable
# rather than a state nobody can account for.
#
# THE COUPLED PAIR, STATED RATHER THAN GLOSSED. Publication order is
# dependency-first: trusted_source (adds an opener), package_contract (adds an
# entry point), package_resolution (uses both), evidence (reads what
# package_resolution returns). The first two orderings are genuinely safe --
# each adds API without removing any, so a Generation-9 caller still resolves.
# The last two are NOT, and no ordering fixes it: Generation-10
# package_resolution returns `package_tree_sha256` and Generation-10 evidence
# reads it, while Generation 9 used `artifact_sha256` on both sides. Whichever
# of the two is published first, there is a window in which a coordinator that
# invoked preparation would raise AttributeError.
#
# That window is accepted, and here is why it is not smuggled past: it fails
# CLOSED (a refusal, never a wrong answer), it is bounded by two adjacent
# renames, this ceremony invokes no coordinator surface, and first governance
# has not begun so there is no live invocation traffic to catch. Ordering the
# coupled pair last makes the window as short as the transaction can make it.
# Pretending ordering solved it would be the lie.
#
# WHAT THIS INSTALLS. Exactly four REPLACE operations, materialised from the
# reviewed commit object below and from nothing else.
#
# WHAT THIS DOES NOT DO. It writes no sudoers policy, invokes no privileged
# helper, never calls the transition or the worker, contacts no container
# runtime, allocates no governance identifier, creates no Trust, Fabric, or
# Capability store, provisions no fixture package material, does not mount the
# Root Authority, and does not touch the implementation-authority namespace
# except to read a fingerprint and prove it did not move. It resolves no part of
# the Fabric resource vocabulary, which remains a separate open blocker.
#
# Usage:
#   install-generation-10.sh --verify            read-only: is the host at G9?
#   install-generation-10.sh --install           perform the four-object transaction
#   install-generation-10.sh --verify-installed  read-only: is the host at G10?
#   install-generation-10.sh --recover           resume an interrupted transaction
#
# Test-only:
#   --fixture DIR   operate on a fixture tree instead of the host.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

# The reviewed Generation-10 source authority. Pinned, never HEAD: a mutable
# reference is not an authority, and every runtime byte below is materialised
# from this commit object rather than from the working tree. This ceremony's own
# commit is necessarily later than the authority it installs.
COMMIT="83da574bacde762de3222c60eb1873b2a750e54c"

# The accepted Generation-9 source authority, and the baseline this transaction
# requires the host to be at.
GEN9_COMMIT="a1fcaae7bd9b495fa05497be9eff1f62a9150986"

BRANCH="arch/eng-0005-execution-transition"
REPOSITORY="/opt/schott-platform"
REPO_OWNER="cschott"

LIBRARY_ROOT="/usr/lib/kyri/python"
LIBEXEC="/usr/libexec"
TRANSACTION_ROOT="/root/kyri-gen10-transaction"
GEN9_LIBRARY_EVIDENCE="/root/kyri-gen9-library-digests.txt"
GEN9_HELPER_EVIDENCE="/root/kyri-gen9-helper-digests.txt"
GEN10_LIBRARY_EVIDENCE="/root/kyri-gen10-library-digests.txt"
GEN10_HELPER_EVIDENCE="/root/kyri-gen10-helper-digests.txt"

# Both grants. Neither may exist while this runs, and neither is written by it.
SUDOERS="/etc/sudoers.d/kyri-exec"
VERIFY_SUDOERS="/etc/sudoers.d/kyri-exec-verify"

# The authority namespace. Read to prove it was not disturbed; never written.
AUTHORITY_ROOT="/var/lib/kyri/implementation-authority"
CONTROL_ROOT="/var/lib/kyri/implementation-authority-control"

# A pure REPLACE moves no object count. Both are stated anyway, so a matrix that
# quietly grew an object fails here rather than at publication.
EXPECTED_LIBRARY_FILES_GEN9=48
EXPECTED_LIBRARY_FILES_GEN10=48

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
  LIBEXEC="${FIXTURE}${LIBEXEC}"
  TRANSACTION_ROOT="${FIXTURE}${TRANSACTION_ROOT}"
  GEN9_LIBRARY_EVIDENCE="${FIXTURE}${GEN9_LIBRARY_EVIDENCE}"
  GEN9_HELPER_EVIDENCE="${FIXTURE}${GEN9_HELPER_EVIDENCE}"
  GEN10_LIBRARY_EVIDENCE="${FIXTURE}${GEN10_LIBRARY_EVIDENCE}"
  GEN10_HELPER_EVIDENCE="${FIXTURE}${GEN10_HELPER_EVIDENCE}"
  SUDOERS="${FIXTURE}${SUDOERS}"
  VERIFY_SUDOERS="${FIXTURE}${VERIFY_SUDOERS}"
  AUTHORITY_ROOT="${FIXTURE}${AUTHORITY_ROOT}"
  CONTROL_ROOT="${FIXTURE}${CONTROL_ROOT}"
fi

JOURNAL="${TRANSACTION_ROOT}/journal"
PREPARED_SUFFIX=".kyri-gen10.new"
BACKUP_SUFFIX=".kyri-gen10.gen9"

FAILURES=0
OUTCOME=""
TRANSACTION_ID=""
GEN9_COUNT=0; GEN10_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()

ok()   { printf 'ok       %s\n' "$1"; }
note() { printf 'note     %s\n' "$1"; }
bad()  { printf 'FAIL     %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }
halt() { printf '\nSTOP: %s\n' "$1" >&2; exit 1; }

# --- the four generation-10 objects, pinned both ways -----------------------
#
# source | target | mode | operation | gen9-sha256 | gen10-sha256
#
# Order is publication order and is deliberate: see the coupled-pair note at the
# top of this file. Nothing here is a CREATE, so the installed object count is
# identical on both sides of the transaction.
MATRIX=(
"tools/common/trusted_source.py|${LIBRARY_ROOT}/tools/common/trusted_source.py|0444|REPLACE|e0f32e1f5372dbdb24ebf22e35cfa7d3a52af570f87a3160f634dae2fffea4f8|d1e8ac5933834deb7b7aa07a847312ac10d8c4e3f0c0d2d93400c6eafe04865f"
"tools/capability/execution/package_contract.py|${LIBRARY_ROOT}/tools/capability/execution/package_contract.py|0444|REPLACE|812dc878cb7b7082b42086a9adce714a152617e718536c039ed759b12d3e511a|79a9f7d4befb490833c5c5b764a03c02696ab3555e8081a89af92f5f79a4dc13"
"tools/capability/package_resolution.py|${LIBRARY_ROOT}/tools/capability/package_resolution.py|0444|REPLACE|678bcabd341f8a76fa7000cfe0f66174b443c4ca5b2782846bed7baf94681f6c|0c5c94874570d38693fe46bbc4d1193e59751941c1d25199589c4cdfaa9e5d1b"
"tools/capability/evidence.py|${LIBRARY_ROOT}/tools/capability/evidence.py|0444|REPLACE|6240ad761004808051bf4d9685a02220c7b911ed90ff96155a15c8e4f7b7b59e|394bc94fe8f5aee36c81ef97b6228b6f32c577c05724d7277072d58471f2cfc7"
)

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }

# Operator-visible prose is derived from the matrix rather than written out, so
# a ceremony can no longer describe a transaction it is not performing. That is
# not a style preference: ceremony output is audit evidence, and a run that
# installs four objects while reporting one leaves a record nobody can reconcile
# against the host afterwards. Generation 9 shipped exactly that defect.
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
# "object" or "objects", so a four-row matrix does not report in the singular.
plural() { [[ "$1" == "1" ]] && printf '%s' "$2" || printf '%s' "$3"; }

# Whether a pathname is one of this transaction's declared targets.
is_target() {
  local candidate="$1" row
  for row in "${MATRIX[@]}"; do
    [[ "$(field "${row}" 1)" == "${candidate}" ]] && return 0
  done
  return 1
}

# Test-only failure injection. Impossible without --fixture, so a production run
# cannot reach any of it. Every boundary the transaction can be interrupted at
# has a seam, because "we reasoned it is safe" is a weaker claim than "we cut
# the power there and looked".
injected_at() {
  [[ -n "${FIXTURE}" && "${KYRI_GEN10_FAIL_AT:-}" == "$1" ]]
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
# by a durable write, so recovery reads a fact rather than inferring one. With
# four targets the per-target progress rows are what make "how far did it get"
# answerable without trusting the pathnames.
declare -A PROGRESS=()

journal_write() {
  local state="$1"
  local temporary="${JOURNAL}.writing"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  {
    printf 'transaction=%s\n' "${TRANSACTION_ID}"
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN9_COMMIT}"
    printf 'state=%s\n' "${state}"
    printf 'library_root=%s\n' "${LIBRARY_ROOT}"
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

# --- classification --------------------------------------------------------
#
# GEN9 / GEN10 / UNKNOWN, decided from actual bytes and never from the journal
# or from a pathname existing. This matrix is four REPLACE rows and declares no
# CREATE; the ABSENT branch is retained generic capability so that a future
# matrix cannot silently lose it.
classify() {
  local target="$1" gen9="$2" gen10="$3" observed
  if [[ "${gen9}" == "ABSENT" ]]; then
    if [[ ! -e "${target}" && ! -L "${target}" ]]; then printf 'GEN9'; return; fi
    if [[ -f "${target}" && ! -L "${target}" ]]; then
      observed="$(digest_of "${target}")"
      if [[ "${observed}" == "${gen10}" ]]; then printf 'GEN10'; return; fi
    fi
    printf 'UNKNOWN'; return
  fi
  if [[ -L "${target}" || ! -f "${target}" ]]; then printf 'UNKNOWN'; return; fi
  observed="$(digest_of "${target}")"
  if   [[ "${observed}" == "${gen10}" ]]; then printf 'GEN10'
  elif [[ "${observed}" == "${gen9}" ]];  then printf 'GEN9'
  else printf 'UNKNOWN'; fi
}

classify_all() {
  local row target gen9 gen10 state
  GEN9_COUNT=0; GEN10_COUNT=0; UNKNOWN_COUNT=0; UNKNOWN_TARGETS=()
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    state="$(classify "${target}" "${gen9}" "${gen10}")"
    case "${state}" in
      GEN9)  GEN9_COUNT=$((GEN9_COUNT + 1)) ;;
      GEN10) GEN10_COUNT=$((GEN10_COUNT + 1)) ;;
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
    || halt "the reviewed Generation-10 commit ${COMMIT} is not in this repository"
  # The branch carries this ceremony's own later commit, exactly as Generations
  # 8 and 9 permitted: what must hold is that the reviewed authority is an
  # ancestor of HEAD, not that it IS HEAD. A ceremony whose own commit were the
  # runtime authority would be installing bytes nobody reviewed separately.
  git_as_owner merge-base --is-ancestor "${COMMIT}" HEAD 2>/dev/null \
    || halt "the reviewed Generation-10 commit ${COMMIT} is not an ancestor of HEAD (${head_now})"
  git_as_owner merge-base --is-ancestor "${GEN9_COMMIT}" "${COMMIT}" 2>/dev/null \
    || halt "the Generation-9 authority is not an ancestor of the Generation-10 authority"
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

# Every Generation-10 runtime byte must equal the reviewed commit object, and
# every Generation-9 predecessor must equal the accepted predecessor authority.
# Both ends are re-derived here rather than trusted from the matrix alone.
require_source_digests() {
  local row source gen9 gen10 blob predecessor worktree drift=0
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen10}" ]] \
      || { bad "${source} at ${COMMIT} is ${blob:-absent}, expected ${gen10}"; drift=$((drift + 1)); }
    predecessor="$(git_as_owner cat-file blob "${GEN9_COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${predecessor}" == "${gen9}" ]] \
      || { bad "${source} at ${GEN9_COMMIT} is ${predecessor:-absent}, expected the declared predecessor ${gen9}"; drift=$((drift + 1)); }
    worktree="$(digest_of "${REPOSITORY}/${source}")"
    [[ "${worktree}" == "${gen10}" ]] \
      || note "${source} in the working tree is ${worktree:-absent}; the ceremony installs the commit object, not this"
  done
  (( drift == 0 )) || halt "the reviewed commits do not carry the pinned Generation-10 delta"
  local checked_n
  checked_n="$(matrix_count)"
  ok "${checked_n} Generation-10 source $(plural "${checked_n}" object objects) ($(matrix_names)) match the reviewed commit, and ${checked_n} Generation-9 $(plural "${checked_n}" predecessor predecessors) match the accepted baseline authority"
}

# The delta must be exactly the difference between the two authorities. A row
# missing here would be an installed object nobody declared; a row extra would
# be a claim the reviewed commit does not support.
require_closed_delta() {
  local declared="" actual="" row source
  for row in "${MATRIX[@]}"; do declared+="$(field "${row}" 0)"$'\n'; done
  while IFS= read -r source; do
    [[ -n "${source}" ]] || continue
    actual+="${source}"$'\n'
  done < <(git_as_owner diff --name-only "${GEN9_COMMIT}" "${COMMIT}" -- 'tools/*.py' | sort)
  declared="$(printf '%s' "${declared}" | sort)"
  actual="$(printf '%s' "${actual}" | sort)"
  [[ "${declared}" == "${actual}" ]] \
    || halt "the declared matrix is not the runtime difference between ${GEN9_COMMIT} and ${COMMIT}"
  local n; n="$(matrix_count)"
  ok "the matrix is exactly the runtime delta between the two authorities (${n} $(plural "${n}" object objects), $(matrix_count_of REPLACE) REPLACE, $(matrix_count_of CREATE) CREATE)"
}

# --- generation-9 baseline --------------------------------------------------
require_gen9_baseline() {
  [[ -d "${LIBRARY_ROOT}" ]] || halt "${LIBRARY_ROOT} does not exist: this is not a Kyri host"
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN9}" ]] \
    || halt "the installed library holds ${count} objects, expected the Generation-9 ${EXPECTED_LIBRARY_FILES_GEN9}"

  [[ -f "${GEN9_LIBRARY_EVIDENCE}" ]] \
    || halt "the Generation-9 library evidence at ${GEN9_LIBRARY_EVIDENCE} is missing"
  [[ -f "${GEN9_HELPER_EVIDENCE}" ]] \
    || halt "the Generation-9 helper evidence at ${GEN9_HELPER_EVIDENCE} is missing"

  # Every installed object accounted for by the accepted evidence, and every
  # recorded digest matching the bytes actually there. This is what makes "the
  # host is at Generation 9" a proof over the whole runtime surface rather than
  # a check of the four objects about to move.
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN9_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      bad "installed object ${relative} is absent from the Generation-9 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "installed ${relative} is ${observed}, evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)

  # And the other direction: an object the evidence records but the host no
  # longer has is missing, which a walk of what is present cannot see.
  local recorded_relative
  while IFS= read -r recorded_relative; do
    [[ -n "${recorded_relative}" ]] || continue
    [[ -f "${LIBRARY_ROOT}/${recorded_relative}" ]] \
      || { bad "the Generation-9 evidence records ${recorded_relative}, which is not installed"; drift=$((drift + 1)); }
  done < <(sed -n 's#^[0-9a-f]\{64\}  /usr/lib/kyri/python/##p' "${GEN9_LIBRARY_EVIDENCE}")

  (( drift == 0 )) || halt "the installed runtime is not the accepted Generation-9 baseline"
  ok "the installed runtime is exactly the accepted Generation-9 baseline (${count} objects)"
}

# The targets themselves, and nothing pretending to be one. Each REPLACE target
# must be exactly the accepted Generation-9 bytes.
require_target_state() {
  classify_all
  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN object at ${target}: neither Generation 9 nor Generation 10"
    done
    halt "a target is in an unruled state and requires operator disposition"
  fi
}

# No object of this transaction's own may already be lying around outside a
# transaction: a stray prepared or retained object is residue from a run nobody
# accounted for.
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

# After COMMITTED, leftover artefacts are untidy rather than disqualifying. The
# generation is installed and verified from its own bytes; a failed cleanup does
# not make that less true, and reporting it as a verification failure would
# invite exactly the reflex this transaction forbids -- reverting a committed
# generation to tidy up.
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
    note "${extra} transaction artefact(s) remain from a cleanup that did not finish; Generation 10 is installed and unaffected. Remove them with --recover or by hand."
  fi
}

require_gates_closed() {
  [[ ! -e "${SUDOERS}" ]] || halt "${SUDOERS} exists: G3 has already run"
  [[ ! -e "${VERIFY_SUDOERS}" ]] || halt "${VERIFY_SUDOERS} exists: G6.1B has already run"
  ok "neither sudoers grant exists: G3 and G6.1B stay closed"
}

require_same_filesystem() {
  local row target prepared
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    prepared="${target}${PREPARED_SUFFIX}"
    [[ "$(stat -c '%d' "$(dirname "${target}")" 2>/dev/null)" \
       == "$(stat -c '%d' "$(dirname "${prepared}")" 2>/dev/null)" ]] \
      || halt "${target} and its staging pathname are not on one filesystem"
  done
  ok "every target stages beside itself, so publication is a rename"
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
# All four Generation-9 objects are retained and verified, and all four
# Generation-10 objects are staged and verified, BEFORE a single publication
# happens. With four targets that ordering is the whole safety argument: a
# transaction that staged and published one object at a time would discover a
# bad fourth object with three already live.
prepare() {
  local row source target mode operation gen9 gen10 prepared backup observed
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; operation="$(field "${row}" 3)"
    gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"
    backup="${target}${BACKUP_SUFFIX}"

    injected_at stage && halt "injected failure before staging"

    if [[ "${operation}" == "REPLACE" ]]; then
      # The Generation-9 bytes are retained BEFORE anything is staged, because a
      # rollback with no material to roll back to is a wish rather than a plan.
      # And the retained copy is verified against the accepted digest: "whatever
      # was installed" is not a rollback target until it is proven to be the
      # generation this transaction claims to be leaving.
      rm -f "${backup}"
      cp -p "${target}" "${backup}"
      observed="$(digest_of "${backup}")"
      [[ "${observed}" == "${gen9}" ]] \
        || halt "the retained Generation-9 copy of ${target} is ${observed}, expected ${gen9}"
      sync_path "${backup}"
      injected_at retained && halt "injected failure after retaining the rollback object"
      # Test-only. Impossible without --fixture.
      if [[ -n "${FIXTURE}" && "${KYRI_GEN10_FAIL_AT:-}" == "backup" ]]; then
        printf '\n# injected corruption\n' >> "${backup}"
        observed="$(digest_of "${backup}")"
        [[ "${observed}" == "${gen9}" ]] \
          || halt "the retained Generation-9 copy of ${target} is ${observed}, expected ${gen9}"
      fi
    else
      # Generic capability, unused by this matrix: a CREATE has no predecessor
      # bytes to retain, so its rollback is removal. What it does require is
      # that the pathname is genuinely free.
      [[ ! -e "${target}" && ! -L "${target}" ]] \
        || halt "${target} already exists and this transaction did not create it: refusing to overwrite an unknown object"
      rm -f "${backup}"
    fi

    rm -f "${prepared}"
    git_as_owner cat-file blob "${COMMIT}:${source}" > "${prepared}" \
      || halt "could not materialise ${source} from ${COMMIT}"
    chmod "${mode}" "${prepared}"
    if [[ -z "${FIXTURE}" ]]; then
      chown root:root "${prepared}"
    fi
    observed="$(digest_of "${prepared}")"
    [[ "${observed}" == "${gen10}" ]] \
      || halt "the prepared object for ${target} is ${observed}, expected ${gen10}"
    [[ "$(stat -c '%a' "${prepared}")" == "${mode#0}" ]] \
      || halt "the prepared object for ${target} has the wrong mode"
    sync_path "${prepared}"
    injected_at staged && halt "injected failure after staging a Generation-10 object"
  done
  injected_at prepared && halt "injected failure before the PREPARED journal write"
  journal_write PREPARED
  local staged_n replaced_n created_n
  staged_n="$(matrix_count)"; replaced_n="$(matrix_count_of REPLACE)"
  created_n="$(matrix_count_of CREATE)"
  local reserved_clause=""
  (( created_n > 0 )) && reserved_clause=", ${created_n} $(plural "${created_n}" pathname pathnames) reserved"
  ok "PREPARE complete: ${staged_n} $(plural "${staged_n}" object objects) staged ($(matrix_names)), ${replaced_n} Generation-9 $(plural "${replaced_n}" copy copies) retained and verified${reserved_clause}"
}

verify_prepared_set() {
  local row target operation gen9 gen10
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; operation="$(field "${row}" 3)"
    gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen10}" ]] \
      || halt "prepared object for ${target} does not verify"
    if [[ "${operation}" == "REPLACE" ]]; then
      [[ "$(digest_of "${target}${BACKUP_SUFFIX}")" == "${gen9}" ]] \
        || halt "retained Generation-9 copy for ${target} does not verify"
    fi
  done
  local n; n="$(matrix_count)"
  ok "all ${n} prepared objects verify, and so do all ${n} pieces of retained rollback material"
}

# --- COMMIT ----------------------------------------------------------------
commit_targets() {
  local row target mode operation gen9 gen10 prepared index=0 observed owner_now
  journal_write COMMITTING
  if injected_at committing; then
    rollback "injected failure immediately after COMMITTING"
    return 1
  fi
  for row in "${MATRIX[@]}"; do
    index=$((index + 1))
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    prepared="${target}${PREPARED_SUFFIX}"

    # Test-only failure injection at each of the four publication positions.
    # Impossible without --fixture.
    if [[ -n "${FIXTURE}" && "${KYRI_GEN10_FAIL_AT:-}" == "${index}" ]]; then
      PROGRESS["${index}"]="INJECTED_FAILURE"
      journal_write COMMITTING
      rollback "injected failure at commit position ${index}"
      return 1
    fi

    # Already published by an earlier, interrupted run. Decided from the
    # target's actual bytes, never from the journal.
    if [[ "$(classify "${target}" "${gen9}" "${gen10}")" == "GEN10" ]]; then
      PROGRESS["${index}"]="GEN10"
      journal_write COMMITTING
      continue
    fi

    PROGRESS["${index}"]="PUBLISHING"
    journal_write COMMITTING
    if injected_at publish; then
      rollback "injected failure immediately before publication"
      return 1
    fi

    # rename(2): atomic for this pathname. The live object is never truncated,
    # never opened for writing, and never holds a partially written module --
    # readers see the old inode or the new one and nothing between. It is atomic
    # for ONE pathname and this transaction has four, which is what the journal
    # and the retained rollback material exist to carry.
    mv -f "${prepared}" "${target}"
    sync_path "${target}"

    # Injected between the rename and its verification: the one window where the
    # target already holds the new bytes and nothing has yet proved it.
    if injected_at verify; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "injected failure during post-publication verification"
      return 1
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" != "${gen10}" ]]; then
      PROGRESS["${index}"]="VERIFY_FAILED"
      journal_write COMMITTING
      rollback "target ${target} is ${observed} after publication, expected ${gen10}"
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

    PROGRESS["${index}"]="GEN10"
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
    && bad "injected failure immediately after COMMITTED; Generation 10 stands"
  OUTCOME="COMMITTED"
  local published_n
  published_n="$(matrix_count)"
  ok "COMMIT complete: ${published_n} $(plural "${published_n}" object objects) replaced and verified ($(matrix_names))"
  return 0
}

# --- ROLLBACK --------------------------------------------------------------
#
# Reachable only before COMMITTED. Every target in this matrix is a REPLACE and
# is restored from its retained, verified Generation-9 copy. The CREATE branch
# is generic implementation retained from the accepted Generation-8 transaction
# and is never taken here.
rollback() {
  local reason="$1"
  printf '\nROLLING BACK: %s\n' "${reason}" >&2
  journal_write ROLLING_BACK
  local row target mode operation gen9 gen10 backup observed restored=0 removed=0
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; mode="$(field "${row}" 2)"
    operation="$(field "${row}" 3)"
    gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"

    if [[ "${operation}" == "CREATE" ]]; then
      if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        continue
      fi
      if [[ -L "${target}" || ! -f "${target}" ]]; then
        bad "${target} is not the regular file this transaction created; NOT removing it"
        continue
      fi
      observed="$(digest_of "${target}")"
      if [[ "${observed}" != "${gen10}" ]]; then
        bad "${target} is ${observed}, not the Generation-10 object this transaction installed; NOT removing it"
        continue
      fi
      rm -f "${target}"
      sync_path "${target}"
      removed=$((removed + 1))
      continue
    fi

    observed="$(digest_of "${target}")"
    if [[ "${observed}" == "${gen9}" ]]; then
      continue
    fi
    # An UNKNOWN target is never restored over. Bytes that are neither
    # generation belong to somebody else, and a rollback that overwrites them
    # destroys the only evidence of what happened.
    if [[ "${observed}" != "${gen10}" ]]; then
      bad "${target} is ${observed:-absent}, neither Generation 9 nor Generation 10; NOT restoring over it"
      continue
    fi
    backup="${target}${BACKUP_SUFFIX}"
    [[ -f "${backup}" ]] || { bad "no retained Generation-9 copy for ${target}"; continue; }
    [[ "$(digest_of "${backup}")" == "${gen9}" ]] \
      || { bad "the retained copy for ${target} does not verify; not restoring from it"; continue; }
    cp -p "${backup}" "${target}.restoring"
    mv -f "${target}.restoring" "${target}"
    sync_path "${target}"
    restored=$((restored + 1))
  done

  classify_all
  if (( GEN9_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    local rolled_n
    rolled_n="$(matrix_count)"
    ok "ROLLBACK complete: ${rolled_n} $(plural "${rolled_n}" target targets) back at Generation 9 (${restored} restored, ${removed} removed)"
  else
    journal_write ROLLING_BACK
    bad "ROLLBACK INCOMPLETE: GEN9=${GEN9_COUNT} GEN10=${GEN10_COUNT} UNKNOWN=${UNKNOWN_COUNT}"
    halt "the host is in a mixed state and requires operator disposition; the journal is at ${JOURNAL}"
  fi
}

# --- RECOVERY --------------------------------------------------------------
#
# Direction is decided from provable material, never guessed. This is the
# accepted Generation-8/9 model applied unchanged to four targets; four rows
# expose no new ambiguity, because every rule below is stated over counts and
# per-target bytes rather than over a single object:
#
#   * unknown bytes anywhere              -> fail closed for operator disposition
#   * every target already Generation 10  -> already committed
#   * every target still Generation 9     -> nothing was published
#   * mixed, and every remaining prepared object verifies -> complete FORWARD
#   * mixed otherwise                     -> roll BACK to a complete Generation 9
#
# The mixed cases this matrix can actually reach are 1, 2, or 3 of 4 published,
# in matrix order, and each resolves by the same two rules.
recover() {
  local state="$1"
  classify_all
  printf '\nRECOVERY from journal state %s: GEN9=%d GEN10=%d UNKNOWN=%d (of %d targets)\n' \
    "${state}" "${GEN9_COUNT}" "${GEN10_COUNT}" "${UNKNOWN_COUNT}" "${#MATRIX[@]}"

  if (( UNKNOWN_COUNT > 0 )); then
    local target
    for target in "${UNKNOWN_TARGETS[@]}"; do
      bad "UNKNOWN bytes at ${target} (neither Generation 9 nor Generation 10)"
    done
    halt "recovery refuses to guess: unknown bytes require operator disposition"
  fi

  if (( GEN10_COUNT == ${#MATRIX[@]} )); then
    journal_write COMMITTED
    OUTCOME="COMMITTED"
    ok "recovery: the complete Generation-10 set is already installed"
    return 0
  fi
  if (( GEN9_COUNT == ${#MATRIX[@]} )); then
    journal_write ROLLED_BACK
    OUTCOME="ROLLED_BACK"
    ok "recovery: the complete Generation-9 set is intact; nothing was committed"
    return 0
  fi

  local row target gen9 gen10 forward=1
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"; gen9="$(field "${row}" 4)"; gen10="$(field "${row}" 5)"
    [[ "$(classify "${target}" "${gen9}" "${gen10}")" == "GEN10" ]] && continue
    [[ "$(digest_of "${target}${PREPARED_SUFFIX}")" == "${gen10}" ]] || { forward=0; break; }
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
# Written only after COMMITTED, and under new names. Generation-9 evidence is
# the record of what that gate accepted and is never overwritten: a generation
# that consumed its own baseline could not be audited afterwards.
write_evidence() {
  [[ -f "${GEN9_LIBRARY_EVIDENCE}" && -f "${GEN9_HELPER_EVIDENCE}" ]] \
    || halt "Generation-9 evidence vanished during installation"
  if injected_at evidence; then
    bad "injected failure while writing Generation-10 evidence; Generation 10 stands"
    return 0
  fi
  find "${LIBRARY_ROOT}" -type f -name '*.py' -print0 \
    | sort -z | xargs -0 sha256sum > "${GEN10_LIBRARY_EVIDENCE}.writing"
  # Every replaced object must appear in the evidence by name. Generation 9
  # checked one; a four-object transaction that checked one would be reporting a
  # quarter of what it did.
  local row target
  for row in "${MATRIX[@]}"; do
    target="$(field "${row}" 1)"
    grep -q "${target}\$" "${GEN10_LIBRARY_EVIDENCE}.writing" \
      || { rm -f "${GEN10_LIBRARY_EVIDENCE}.writing"
           halt "the Generation-10 evidence does not record ${target}"; }
  done
  {
    printf 'commit %s\n' "${COMMIT}"
    printf 'baseline_commit %s\n' "${GEN9_COMMIT}"
    printf 'predecessor generation 9\n'
    printf 'transaction %s\n' "${TRANSACTION_ID}"
    printf 'state COMMITTED\n'
    for row in "${MATRIX[@]}"; do
      printf 'delta %s %s %s %s\n' \
        "$(field "${row}" 3)" "$(field "${row}" 1)" \
        "$(field "${row}" 4)" "$(field "${row}" 5)"
    done
    printf 'library_objects %s\n' "$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  } > "${GEN10_HELPER_EVIDENCE}.writing"
  chmod 0400 "${GEN10_LIBRARY_EVIDENCE}.writing" "${GEN10_HELPER_EVIDENCE}.writing"
  sync_path "${GEN10_LIBRARY_EVIDENCE}.writing"
  sync_path "${GEN10_HELPER_EVIDENCE}.writing"
  mv -f "${GEN10_LIBRARY_EVIDENCE}.writing" "${GEN10_LIBRARY_EVIDENCE}"
  mv -f "${GEN10_HELPER_EVIDENCE}.writing" "${GEN10_HELPER_EVIDENCE}"
  sync_path "${GEN10_LIBRARY_EVIDENCE}"
  sync_path "${GEN10_HELPER_EVIDENCE}"
  ok "Generation-10 evidence written; Generation-9 evidence preserved"
}

cleanup_transaction_artifacts() {
  local row target
  # Test-only. Proves a cleanup failure after COMMITTED does not revert.
  if injected_at cleanup; then
    bad "injected cleanup failure after COMMITTED; Generation 10 remains installed"
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
  local row source target gen10 observed blob mode
  for row in "${MATRIX[@]}"; do
    source="$(field "${row}" 0)"; target="$(field "${row}" 1)"
    mode="$(field "${row}" 2)"; gen10="$(field "${row}" 5)"
    blob="$(git_as_owner cat-file blob "${COMMIT}:${source}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [[ "${blob}" == "${gen10}" ]] \
      || bad "${source} at ${COMMIT} is ${blob:-absent}, expected the pinned ${gen10}"
    observed="$(digest_of "${target}")"
    [[ "${observed}" == "${gen10}" ]] \
      || bad "installed ${target} is ${observed:-absent}, expected ${gen10}"
    [[ "$(stat -c '%a' "${target}" 2>/dev/null)" == "${mode#0}" ]] \
      || bad "installed ${target} has mode $(stat -c '%a' "${target}" 2>/dev/null), expected ${mode#0}"
  done
  local count
  count="$(find "${LIBRARY_ROOT}" -type f -name '*.py' | wc -l)"
  [[ "${count}" -eq "${EXPECTED_LIBRARY_FILES_GEN10}" ]] \
    || bad "the installed library holds ${count} objects, expected the Generation-10 ${EXPECTED_LIBRARY_FILES_GEN10}"
  (( FAILURES == 0 )) \
    && ok "all $(matrix_count) installed Generation-10 objects correspond to the reviewed commit ${COMMIT}"
}

# Every object the Generation-9 evidence recorded, other than the four this
# transaction replaced, must still be exactly what that evidence says.
verify_unchanged_surface() {
  local drift=0 recorded observed file relative
  while IFS= read -r file; do
    is_target "${file}" && continue
    relative="${file#"${LIBRARY_ROOT}"/}"
    recorded="$(sed -n "s#^\\([0-9a-f]\\{64\\}\\)  /usr/lib/kyri/python/${relative}\$#\\1#p" \
                  "${GEN9_LIBRARY_EVIDENCE}" | head -1)"
    if [[ -z "${recorded}" ]]; then
      # A pure REPLACE adds nothing, so there is no object legitimately absent
      # from the predecessor evidence. Anything unrecorded is unaccounted for.
      bad "installed object ${relative} is not accounted for by the Generation-9 evidence"
      drift=$((drift + 1)); continue
    fi
    observed="$(digest_of "${file}")"
    [[ "${observed}" == "${recorded}" ]] \
      || { bad "${relative} changed: ${observed} but Generation-9 evidence records ${recorded}"; drift=$((drift + 1)); }
  done < <(find "${LIBRARY_ROOT}" -type f -name '*.py' | sort)
  (( drift == 0 )) \
    && ok "every other installed runtime object is exactly its accepted Generation-9 baseline"
}

# ===========================================================================
# main
# ===========================================================================
[[ -n "${FIXTURE}" ]] && note "FIXTURE MODE: operating under ${FIXTURE}; owner enforcement relaxed"

case "${MODE}" in
--verify)
  require_repository
  require_source_digests
  require_closed_delta
  require_gen9_baseline
  require_target_state
  require_no_transaction_residue
  require_gates_closed
  require_same_filesystem

  state="$(journal_state)"
  if [[ "${state}" == "NONE" ]]; then
    ok "no transaction in progress"
  else
    note "a transaction journal exists in state ${state}: --install will recover, not start fresh"
  fi

  if (( GEN9_COUNT == ${#MATRIX[@]} )); then
    ok "the host is at Generation 9 and ready for the Generation-10 installation: $(matrix_count) REPLACE $(plural "$(matrix_count)" operation operations) ($(matrix_names)), object count unchanged at ${EXPECTED_LIBRARY_FILES_GEN10}"
  elif (( GEN10_COUNT == ${#MATRIX[@]} )); then
    note "all $(matrix_count) targets are already at Generation 10"
  else
    bad "mixed target state: GEN9=${GEN9_COUNT} GEN10=${GEN10_COUNT}"
  fi
  note "authority namespace fingerprint: $(authority_fingerprint)"
  ;;

--install)
  require_repository
  require_source_digests
  require_closed_delta
  require_gates_closed

  TRANSACTION_ID="gen10-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "${TRANSACTION_ROOT}"
  chmod 0700 "${TRANSACTION_ROOT}"
  state="$(journal_state)"
  [[ -n "$(journal_transaction)" ]] && TRANSACTION_ID="$(journal_transaction)"

  AUTHORITY_BEFORE="$(authority_fingerprint)"

  if [[ "${state}" == "NONE" ]]; then
    require_gen9_baseline
    require_target_state
    require_no_transaction_residue
    require_same_filesystem
    classify_all
    if (( GEN10_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 10 is already installed: nothing to do"
      exit 0
    fi
    prepare
    verify_prepared_set
    commit_targets || true
  elif [[ "${state}" == "COMMITTED" ]]; then
    classify_all
    if (( GEN10_COUNT == ${#MATRIX[@]} )); then
      ok "Generation 10 is already installed: nothing to do"
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
    verify_unchanged_surface
  elif [[ "${OUTCOME}" == "ROLLED_BACK" ]]; then
    cleanup_transaction_artifacts
    # The host is in a correct state and the request was not carried out. Both
    # are true, and the exit status reports the second: an operator who asked
    # for an installation and got a rollback must not read success.
    bad "the transaction rolled back: the host is at Generation 9 and nothing was installed"
  else
    halt "the transaction reached no terminal outcome; the journal is at ${JOURNAL}"
  fi

  [[ "${AUTHORITY_BEFORE}" == "$(authority_fingerprint)" ]] \
    || bad "the implementation-authority namespace changed during installation"
  ;;

--verify-installed)
  require_repository
  verify_installed_set
  verify_unchanged_surface
  require_gates_closed
  state="$(journal_state)"
  [[ "${state}" == "COMMITTED" ]] \
    || bad "the transaction journal is ${state}, expected COMMITTED"
  [[ -f "${GEN10_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-10 library evidence is missing"
  [[ -f "${GEN10_HELPER_EVIDENCE}" ]] \
    || bad "the Generation-10 helper evidence is missing"
  [[ -f "${GEN9_LIBRARY_EVIDENCE}" ]] \
    || bad "the Generation-9 evidence was not preserved"
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
    # The same distinction --install draws, drawn here too. Recovery reaching a
    # coherent Generation 9 is a correct outcome and it is NOT the outcome the
    # operator asked for, and a mode that exits 0 either way cannot tell them
    # apart. Generation 9's --recover reported success after a rollback while
    # its own --install reported failure; with one object that inconsistency was
    # nearly unreachable, and with four it is the likely path.
    bad "recovery rolled the transaction back: the host is at Generation 9 and Generation 10 is not installed"
  else
    halt "recovery reached no terminal outcome; the journal is at ${JOURNAL}"
  fi
  ;;
esac

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Generation 10 / tree-native package pipeline %s: all checks passed.\n' "${MODE#--}"
else
  printf 'Generation 10 / tree-native package pipeline %s FAILED: %d\n' "${MODE#--}" "${FAILURES}" >&2
  exit 1
fi
