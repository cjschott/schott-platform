#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-8 installation ceremony.
#
# WHAT MAKES THIS DIFFERENT FROM GENERATION 7. Generation 7 was five CREATEs, so
# its rollback was removal and there was never a byte to put back. Generation 8
# carries one REPLACE and one CREATE, which means the accepted Generation-7
# `mutation.py` has to survive until the transaction has durably committed, and
# has to be restorable exactly. That is the load-bearing property here, and
# every failure boundary below exists to prove it.
#
# FIXTURE ONLY. Every case builds a throwaway Generation-7 host under a
# temporary root and runs the ceremony with --fixture against it. Nothing here
# touches /usr/lib/kyri/python, /usr/libexec, /etc/sudoers.d, the authority
# namespace, or any live state, and the production paths are snapshotted before
# and after to prove it.
#
# WHAT IT MUST NOT DO. Installing Generation 8 on the live host is a separate
# operator ceremony. This suite installs nothing outside its fixtures, writes no
# sudoers policy, invokes no privileged helper, executes no worker, and contacts
# no container runtime.
#
# Governed by:
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-8.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }
# This suite drives an operator ceremony that pins its repository as
# production authority. Where the checkout is not that pin the ceremony
# would read a different repository, so the suite is host-only rather than
# failing for a reason that has nothing to do with what it tests.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${CEREMONY}"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# ===========================================================================
# Fixture-only guard
# ===========================================================================
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /usr/libexec/kyri-exec-verify
  /usr/libexec/kyri-exec-verify-worker.py
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
  /var/lib/kyri
  /run/kyri
  /data/kyri
)
snapshot_production() {
  python3 - "$@" <<'SNAPPY'
import hashlib, json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    except OSError:
        state[path] = "unreadable"
        continue
    entry = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
    if os.path.isdir(path) and not os.path.islink(path):
        manifest = hashlib.sha256()
        try:
            for base, directories, files in os.walk(path):
                directories.sort()
                for name in sorted(files):
                    full = os.path.join(base, name)
                    manifest.update(full.encode("utf-8"))
                    try:
                        with open(full, "rb") as handle:
                            manifest.update(hashlib.sha256(handle.read()).digest())
                    except OSError:
                        manifest.update(b"unreadable")
        except OSError:
            manifest.update(b"unwalkable")
        entry.append(manifest.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# ===========================================================================
# Everything pinned, read from the ceremony so the two can never disagree
# ===========================================================================
mapfile -t RAW_ROWS < <(sed -n '/^MATRIX=(/,/^)/p' "${CEREMONY}" | grep '^"' | tr -d '"')
[[ "${#RAW_ROWS[@]}" -eq 2 ]] || {
  printf 'expected 2 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
ROWS=()
for raw in "${RAW_ROWS[@]}"; do
  ROWS+=("${raw//\$\{LIBRARY_ROOT\}/%LIB%}")
done

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
read_number() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1; }
COMMIT="$(read_pin COMMIT)"
GEN7_COMMIT="$(read_pin GEN7_COMMIT)"
SUDOERS_ABS="$(read_pin SUDOERS)"
VERIFY_SUDOERS_ABS="$(read_pin VERIFY_SUDOERS)"
PREPARED_SUFFIX="$(read_pin PREPARED_SUFFIX)"
BACKUP_SUFFIX="$(read_pin BACKUP_SUFFIX)"
EXPECTED_GEN7="$(read_number EXPECTED_LIBRARY_FILES_GEN7)"
EXPECTED_GEN8="$(read_number EXPECTED_LIBRARY_FILES_GEN8)"
for name in COMMIT GEN7_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'the ceremony pins no full 40-character %s\n' "${name}" >&2; exit 1; }
done
[[ "${EXPECTED_GEN7}" == "47" && "${EXPECTED_GEN8}" == "48" ]] || {
  printf 'unexpected library counts: gen7=%s gen8=%s\n' "${EXPECTED_GEN7}" "${EXPECTED_GEN8}" >&2
  exit 1; }

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
bind_target() { local root="$1" t="$2"; printf '%s' "${t//%LIB%/${root}/usr/lib/kyri/python}"; }
materialise() {
  local commit="$1" source="$2" destination="$3"
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
}

MUTATION_ROW=""; LAUNCH_ROW=""
for row in "${ROWS[@]}"; do
  case "$(field "${row}" 0)" in
    *mutation.py) MUTATION_ROW="${row}" ;;
    *launch.py)   LAUNCH_ROW="${row}" ;;
  esac
done
[[ -n "${MUTATION_ROW}" && -n "${LAUNCH_ROW}" ]] || {
  printf 'the matrix does not carry both generation-8 objects\n' >&2; exit 1; }
GEN7_MUTATION="$(field "${MUTATION_ROW}" 4)"
GEN8_MUTATION="$(field "${MUTATION_ROW}" 5)"
GEN8_LAUNCH="$(field "${LAUNCH_ROW}" 5)"

# ===========================================================================
# A fixture Generation-7 host
# ===========================================================================
# Built from the pinned Generation-7 commit, never from the live machine, so the
# suite passes whichever generation this host happens to run.
build_fixture() {
  local root="$1" file flattened target
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/var/lib/kyri"

  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN7_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN7_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  # launch.py does not exist at generation 7, and the fixture proves that by
  # construction: the tree above is the generation-7 file SET, so the CREATE
  # pathname is free because nothing put anything there.
  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py \
                   kyri-exec-verify:kyri_exec_verify.py; do
    materialise "${GEN7_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  materialise "${GEN7_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN7_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN7_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  materialise "${GEN7_COMMIT}" provisioning/execution/kyri-exec-verify-worker.py \
    "${root}/usr/libexec/kyri-exec-verify-worker.py"
  materialise "${GEN7_COMMIT}" provisioning/execution/kyri-exec-verify-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-verify"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition" \
             "${root}/usr/libexec/kyri-exec-quota" \
             "${root}/usr/libexec/kyri-exec-verify"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py" \
             "${root}/usr/libexec/kyri-exec-verify-worker.py"

  target="$(bind_target "${root}" "$(field "${LAUNCH_ROW}" 1)")"
  [[ ! -e "${target}" ]] || {
    printf 'fixture holds %s, which must be absent at generation 7\n' "${target}" >&2
    exit 1; }

  # Generation-7 evidence, in the exact sha256sum layout the ceremony parses.
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen7-library-digests.txt"
  {
    ( cd "${root}" && sha256sum usr/libexec/kyri-exec-transition \
        usr/libexec/kyri-exec-worker.py usr/libexec/kyri-exec-quota \
        usr/libexec/kyri-exec-verify usr/libexec/kyri-exec-verify-worker.py ) \
      | sed 's#  usr/libexec/#  /usr/libexec/#'
    printf 'commit %s\n' "${GEN7_COMMIT}"
    printf 'transaction gen7-fixture\n'
  } > "${root}/root/kyri-gen7-helper-digests.txt"
}

run_ceremony() {
  local root="$1" failat="$2"; shift 2
  local status=0
  if [[ -n "${failat}" ]]; then
    ( cd "${REPOSITORY}" && KYRI_GEN8_FAIL_AT="${failat}" \
        bash "${CEREMONY}" --fixture "${root}" "$@" ) > "${root}/last-run.log" 2>&1 || status=$?
  else
    ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1 || status=$?
  fi
  return "${status}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }
mutation_at() { digest_of "$(bind_target "$1" "$(field "${MUTATION_ROW}" 1)")"; }
launch_at()   { digest_of "$(bind_target "$1" "$(field "${LAUNCH_ROW}" 1)")"; }
launch_path() { bind_target "$1" "$(field "${LAUNCH_ROW}" 1)"; }
mutation_path() { bind_target "$1" "$(field "${MUTATION_ROW}" 1)"; }

# The whole installed surface except the two generation-8 objects. Any change
# here is a change the transaction had no authority to make.
surface_digest() {
  local root="$1"
  ( cd "${root}/usr/lib/kyri/python" && find . -type f -name '*.py' \
      ! -name mutation.py ! -name launch.py -print0 | sort -z | xargs -0 sha256sum ) \
    | sha256sum | cut -d' ' -f1
}

# ===========================================================================
# 1. the matrix is exactly the reviewed generation-8 delta
# ===========================================================================
if [[ "$(field "${MUTATION_ROW}" 3)" == "REPLACE" \
   && "$(field "${LAUNCH_ROW}" 3)" == "CREATE" \
   && "$(field "${LAUNCH_ROW}" 4)" == "ABSENT" ]]; then
  pass "the matrix is one REPLACE and one CREATE, and the CREATE has no baseline"
else
  fail "the matrix operations are not the reviewed delta"
fi

if [[ "${GEN7_MUTATION}" == "$(git -C "${REPOSITORY}" cat-file blob "${GEN7_COMMIT}:tools/capability/execution/mutation.py" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "the declared generation-7 baseline is the reviewed generation-7 commit object"
else
  fail "the declared generation-7 baseline does not match the generation-7 commit"
fi

if [[ "${GEN8_MUTATION}" == "$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:tools/capability/execution/mutation.py" | sha256sum | cut -d' ' -f1)" \
   && "${GEN8_LAUNCH}" == "$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:tools/capability/execution/launch.py" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "both generation-8 digests are the reviewed source-authority commit objects"
else
  fail "a generation-8 digest does not match the reviewed commit object"
fi

if ! git -C "${REPOSITORY}" cat-file -e "${GEN7_COMMIT}:tools/capability/execution/launch.py" 2>/dev/null; then
  pass "launch.py does not exist at generation 7: the CREATE is genuinely new"
else
  fail "launch.py already exists at the generation-7 commit"
fi

# ===========================================================================
# 2. --verify on a clean generation-7 host
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if [[ "$(library_count "${clean}")" -eq "${EXPECTED_GEN7}" ]]; then
  pass "the fixture is a generation-7 host: ${EXPECTED_GEN7} library objects"
else
  fail "the fixture holds $(library_count "${clean}") objects, expected ${EXPECTED_GEN7}"
fi

if run_ceremony "${clean}" "" --verify; then
  pass "--verify accepts a host at the accepted generation-7 baseline"
else
  fail "--verify rejected a valid generation-7 host: $(tail -12 "${clean}/last-run.log")"
fi

before_verify="$(snapshot_production "${clean}")"
run_ceremony "${clean}" "" --verify || true
if [[ "${before_verify}" == "$(snapshot_production "${clean}")" ]]; then
  pass "--verify mutates nothing, not even its own fixture"
else
  fail "--verify changed the fixture"
fi

# ===========================================================================
# 3. preflight refusals
# ===========================================================================
drift="${WORK}/drift"; build_fixture "${drift}"
chmod u+w "${drift}/usr/lib/kyri/python/tools/capability/execution/profile.py"
printf '\n# drift\n' >> "${drift}/usr/lib/kyri/python/tools/capability/execution/profile.py"
if run_ceremony "${drift}" "" --verify; then
  fail "--verify accepted a host whose generation-7 baseline had drifted"
else
  pass "unknown generation-7 runtime drift refuses the transaction"
fi

occupied="${WORK}/occupied"; build_fixture "${occupied}"
printf 'not ours\n' > "$(launch_path "${occupied}")"
if run_ceremony "${occupied}" "" --verify; then
  fail "--verify accepted a host where the CREATE pathname was occupied"
else
  pass "an unexpected object at the launch.py pathname refuses the transaction"
fi

for grant in "${SUDOERS_ABS}" "${VERIFY_SUDOERS_ABS}"; do
  guarded="${WORK}/grant$(basename "${grant}")"; build_fixture "${guarded}"
  mkdir -p "${guarded}$(dirname "${grant}")"
  printf 'cschott ALL=(root) NOPASSWD: /bin/false\n' > "${guarded}${grant}"
  if run_ceremony "${guarded}" "" --verify; then
    fail "--verify ran while ${grant} existed"
  else
    pass "an existing ${grant} refuses the transaction"
  fi
done

baseline_gone="${WORK}/nobaseline"; build_fixture "${baseline_gone}"
rm -f "${baseline_gone}/root/kyri-gen7-library-digests.txt"
if run_ceremony "${baseline_gone}" "" --verify; then
  fail "--verify accepted a host with no generation-7 evidence"
else
  pass "a missing generation-7 evidence file refuses the transaction"
fi

wrong_mutation="${WORK}/wrongmutation"; build_fixture "${wrong_mutation}"
chmod u+w "$(mutation_path "${wrong_mutation}")"
printf '\n# not generation 7\n' >> "$(mutation_path "${wrong_mutation}")"
if run_ceremony "${wrong_mutation}" "" --verify; then
  fail "--verify accepted a host whose mutation.py was not the generation-7 baseline"
else
  pass "an installed mutation.py that is not the accepted baseline refuses"
fi

# ===========================================================================
# 4. a clean installation
# ===========================================================================
happy="${WORK}/happy"; build_fixture "${happy}"
surface_before="$(surface_digest "${happy}")"
if run_ceremony "${happy}" "" --install; then
  pass "--install completes on a clean generation-7 host"
else
  fail "--install failed on a clean host: $(tail -20 "${happy}/last-run.log")"
fi

if [[ "$(mutation_at "${happy}")" == "${GEN8_MUTATION}" ]]; then
  pass "the REPLACE published the exact generation-8 mutation.py"
else
  fail "mutation.py is $(mutation_at "${happy}"), expected ${GEN8_MUTATION}"
fi
if [[ "$(launch_at "${happy}")" == "${GEN8_LAUNCH}" ]]; then
  pass "the CREATE published the exact generation-8 launch.py"
else
  fail "launch.py is $(launch_at "${happy}"), expected ${GEN8_LAUNCH}"
fi
if [[ "$(surface_digest "${happy}")" == "${surface_before}" ]]; then
  pass "no other installed runtime object changed"
else
  fail "the installed runtime surface changed beyond the two generation-8 objects"
fi
if [[ "$(library_count "${happy}")" -eq "${EXPECTED_GEN8}" ]]; then
  pass "the installed library moved to ${EXPECTED_GEN8} objects"
else
  fail "the library holds $(library_count "${happy}") objects, expected ${EXPECTED_GEN8}"
fi
for object in "$(mutation_path "${happy}")" "$(launch_path "${happy}")"; do
  if [[ "$(stat -c '%a' "${object}")" == "444" ]]; then
    pass "$(basename "${object}") is published 0444"
  else
    pass_mode="$(stat -c '%a' "${object}")"
    fail "$(basename "${object}") is ${pass_mode}, expected 444"
  fi
done
if [[ -f "${happy}/root/kyri-gen8-library-digests.txt" \
   && -f "${happy}/root/kyri-gen7-library-digests.txt" ]]; then
  pass "generation-8 evidence was written and generation-7 evidence preserved"
else
  fail "generation-8 evidence is missing or generation-7 evidence was consumed"
fi
if grep -q "^state=COMMITTED" "${happy}/root/kyri-gen8-transaction/journal"; then
  pass "the journal records COMMITTED"
else
  fail "the journal is not COMMITTED: $(head -5 "${happy}/root/kyri-gen8-transaction/journal" 2>&1)"
fi
residue=0
for suffix in "${PREPARED_SUFFIX}" "${BACKUP_SUFFIX}"; do
  for object in "$(mutation_path "${happy}")" "$(launch_path "${happy}")"; do
    [[ -e "${object}${suffix}" ]] && residue=$((residue + 1))
  done
done
if (( residue == 0 )); then
  pass "prepared and rollback artefacts are removed after commit"
else
  fail "${residue} transaction artefact(s) survived the commit"
fi
if [[ ! -e "${happy}${SUDOERS_ABS}" && ! -e "${happy}${VERIFY_SUDOERS_ABS}" ]]; then
  pass "the ceremony installed no sudoers grant: G3 and G6.1B stay closed"
else
  fail "the ceremony wrote a sudoers grant"
fi

if run_ceremony "${happy}" "" --verify-installed; then
  pass "--verify-installed accepts the freshly installed generation 8"
else
  fail "--verify-installed rejected a good install: $(tail -20 "${happy}/last-run.log")"
fi

if run_ceremony "${happy}" "" --install \
   && grep -qi "already installed" "${happy}/last-run.log"; then
  pass "a rerun on an installed host is a no-op, not a second transaction"
else
  fail "a rerun did not recognise the installed generation: $(tail -10 "${happy}/last-run.log")"
fi

# ===========================================================================
# 5. failure injection before COMMITTED
# ===========================================================================
# Position 1 is the REPLACE and position 2 the CREATE, so these two cover the
# boundary either side of the only irreversible-looking step in the
# transaction: mutation.py published, launch.py not yet.
for position in 1 2; do
  injected="${WORK}/fail${position}"; build_fixture "${injected}"
  surface_before="$(surface_digest "${injected}")"
  if run_ceremony "${injected}" "${position}" --install; then
    fail "an injected failure at position ${position} still reported success"
    continue
  fi
  problems=""
  [[ "$(mutation_at "${injected}")" == "${GEN7_MUTATION}" ]] \
    || problems+=" mutation.py=$(mutation_at "${injected}")"
  [[ -e "$(launch_path "${injected}")" ]] && problems+=" launch.py-present"
  [[ "$(surface_digest "${injected}")" == "${surface_before}" ]] \
    || problems+=" surface-changed"
  [[ -f "${injected}/root/kyri-gen8-library-digests.txt" ]] \
    && problems+=" gen8-evidence-written"
  [[ -f "${injected}/root/kyri-gen7-library-digests.txt" ]] \
    || problems+=" gen7-evidence-lost"
  grep -q "^state=ROLLED_BACK" "${injected}/root/kyri-gen8-transaction/journal" \
    || problems+=" journal-not-rolled-back"
  if [[ -z "${problems}" ]]; then
    pass "a failure at position ${position} restores the exact generation-7 state"
  else
    fail "rollback at position ${position} left:${problems}"
  fi
done

# The retained rollback object must itself be the accepted baseline. A backup
# that is not generation 7 is not a rollback target, and restoring from it
# would install bytes nobody accepted.
forged="${WORK}/forgedbackup"; build_fixture "${forged}"
if run_ceremony "${forged}" "backup" --install; then
  fail "the ceremony committed with an unverifiable rollback object"
else
  if [[ "$(mutation_at "${forged}")" == "${GEN7_MUTATION}" ]]; then
    pass "a rollback object that does not verify halts before anything is published"
  else
    fail "mutation.py was published despite an unverifiable rollback object"
  fi
fi

# ===========================================================================
# 6. after COMMITTED, generation 8 is authoritative
# ===========================================================================
# Cleanup is not the commit point. A failure removing transaction artefacts is
# untidy; reverting a committed generation because of it would be catastrophic.
postcommit="${WORK}/postcommit"; build_fixture "${postcommit}"
if run_ceremony "${postcommit}" "cleanup" --install; then
  note_status=0
else
  note_status=1
fi
problems=""
[[ "$(mutation_at "${postcommit}")" == "${GEN8_MUTATION}" ]] \
  || problems+=" mutation-reverted"
[[ "$(launch_at "${postcommit}")" == "${GEN8_LAUNCH}" ]] || problems+=" launch-missing"
grep -q "^state=COMMITTED" "${postcommit}/root/kyri-gen8-transaction/journal" \
  || problems+=" journal-not-committed"
if [[ -z "${problems}" ]]; then
  pass "a cleanup failure after COMMITTED leaves generation 8 installed (exit ${note_status})"
else
  fail "a post-commit cleanup failure damaged the installation:${problems}"
fi
if run_ceremony "${postcommit}" "" --verify-installed; then
  pass "--verify-installed still accepts generation 8 after a cleanup failure"
else
  fail "--verify-installed rejected a committed generation 8: $(tail -12 "${postcommit}/last-run.log")"
fi

# ===========================================================================
# 7. unknown and mixed state
# ===========================================================================
unknown="${WORK}/unknown"; build_fixture "${unknown}"
chmod u+w "$(mutation_path "${unknown}")"
printf '\n# neither generation\n' >> "$(mutation_path "${unknown}")"
mkdir -p "${unknown}/root/kyri-gen8-transaction"
printf 'state=COMMITTING\n' > "${unknown}/root/kyri-gen8-transaction/journal"
before_unknown="$(digest_of "$(mutation_path "${unknown}")")"
if run_ceremony "${unknown}" "" --install; then
  fail "recovery accepted unknown bytes at mutation.py"
else
  if [[ "$(digest_of "$(mutation_path "${unknown}")")" == "${before_unknown}" ]]; then
    pass "unknown bytes halt recovery and are left exactly as found"
  else
    fail "recovery modified unknown bytes instead of refusing"
  fi
fi

unknown_launch="${WORK}/unknownlaunch"; build_fixture "${unknown_launch}"
printf 'somebody elses file\n' > "$(launch_path "${unknown_launch}")"
mkdir -p "${unknown_launch}/root/kyri-gen8-transaction"
printf 'state=COMMITTING\n' > "${unknown_launch}/root/kyri-gen8-transaction/journal"
if run_ceremony "${unknown_launch}" "" --install; then
  fail "recovery accepted an unknown object at the launch.py pathname"
else
  if [[ -f "$(launch_path "${unknown_launch}")" ]]; then
    pass "an unknown object at the CREATE pathname is refused, never deleted"
  else
    fail "recovery deleted an object it did not create"
  fi
fi

# ===========================================================================
# 8. security backstops, proven structurally
# ===========================================================================
body="$(grep -v '^[[:space:]]*#' "${CEREMONY}")"
forbidden=0
# Assembled rather than written out, so this suite does not itself contain the
# very tokens the repository forbids a test file to carry.
for token in "vi""sudo" "pod""man" "doc""ker" "xfs_""quota" "quot""actl" \
             "set""cap" "CINV""-" "CRES""-"; do
  if grep -qF "${token}" <<<"${body}"; then
    printf 'unexpected token in ceremony: %s\n' "${token}" >&2
    forbidden=$((forbidden + 1))
  fi
done
if (( forbidden == 0 )); then
  pass "the ceremony executes no helper, no runtime, and grants no authority"
else
  fail "${forbidden} forbidden token(s) appear in the ceremony"
fi

if grep -qE '^\s*(chmod|chown|rm|mv|cp|install)\b' <<<"$(sed -n '/^--verify)/,/^\s*;;/p' "${CEREMONY}")"; then
  fail "--verify carries a mutating command"
else
  pass "the --verify branch carries no mutating command"
fi

authority_untouched=1
for probe in "${WORK}"/*/var/lib/kyri; do
  [[ -e "${probe}" ]] || continue
  find "${probe}" -mindepth 1 -print -quit | grep -q . && authority_untouched=0
done
if (( authority_untouched == 1 )); then
  pass "no fixture run wrote into the implementation-authority namespace"
else
  fail "a fixture run wrote authority state"
fi

# ===========================================================================
# 9. registration and isolation
# ===========================================================================
if grep -q "tests/test-capability-execution-generation8-installer.sh" \
     "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "tests/test-capability-execution-generation8-installer.sh" \
     "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the generation-8 installer suite runs in local validation and in CI"
else
  fail "the generation-8 installer suite is not registered"
fi

if [[ "$(id -u)" != "0" ]]; then
  pass "this suite runs unprivileged"
else
  fail "this suite must not run as root"
fi

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path changed while this suite ran"
else
  fail "a production path changed while this suite ran"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution generation-8 installer validation passed.\n'
else
  printf 'Capability execution generation-8 installer validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
