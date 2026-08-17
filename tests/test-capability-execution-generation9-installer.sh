#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-9 installation ceremony.
#
# WHAT IS DIFFERENT FROM GENERATION 8. Generation 8 was one REPLACE and one
# CREATE. Generation 9 is one REPLACE and nothing else, so the installed object
# count does not move and the entire transaction turns on a single atomic
# replacement of a live Python module. That makes the retained rollback object
# the only thing standing between an interrupted run and a host with no working
# CLI, which is why every boundary below is injected at rather than reasoned
# about.
#
# FIXTURE ONLY. Every case builds a throwaway Generation-8 host under a
# temporary root and runs the ceremony with --fixture against it. Nothing here
# touches /usr/lib/kyri/python, /usr/libexec, /etc/sudoers.d, the governance
# stores, or the authority namespace, and the production paths are snapshotted
# before and after to prove it.
#
# WHAT IT MUST NOT DO. Installing the operator surface and USING it are separate
# ceremonies. This suite installs nothing outside its fixtures, writes no
# sudoers policy, invokes no privileged helper, never calls authorise-launch,
# allocates no identifier, and contacts no container runtime.
#
# Governed by:
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-9.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }
PINNED_REPOSITORY="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${CEREMONY}" | head -1)"
[[ "${PINNED_REPOSITORY}" == "${REPOSITORY}" ]] || {
  printf 'this checkout is %s but the ceremony pins %s\n' "${REPOSITORY}" "${PINNED_REPOSITORY}" >&2
  exit 1
}

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

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
  /mnt/kyri-root
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
[[ "${#RAW_ROWS[@]}" -eq 1 ]] || {
  printf 'expected exactly 1 matrix row, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
ROW="${RAW_ROWS[0]//\$\{LIBRARY_ROOT\}/%LIB%}"

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
read_number() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1; }
COMMIT="$(read_pin COMMIT)"
GEN8_COMMIT="$(read_pin GEN8_COMMIT)"
# The Generation-8 installer is what wrote the Generation-8 helper evidence, so
# its own predecessor pin is read from there rather than restated in the
# Generation-9 ceremony, which has no use for it.
GEN7_COMMIT="$(sed -n 's/^GEN7_COMMIT="\(.*\)"$/\1/p' \
  "${REPOSITORY}/provisioning/execution/install-generation-8.sh" | head -1)"
SUDOERS_ABS="$(read_pin SUDOERS)"
VERIFY_SUDOERS_ABS="$(read_pin VERIFY_SUDOERS)"
PREPARED_SUFFIX="$(read_pin PREPARED_SUFFIX)"
BACKUP_SUFFIX="$(read_pin BACKUP_SUFFIX)"
EXPECTED_GEN8="$(read_number EXPECTED_LIBRARY_FILES_GEN8)"
EXPECTED_GEN9="$(read_number EXPECTED_LIBRARY_FILES_GEN9)"
for name in COMMIT GEN8_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'the ceremony pins no full 40-character %s\n' "${name}" >&2; exit 1; }
done
# A pure REPLACE moves no object count. If these ever differ, the matrix grew.
[[ "${EXPECTED_GEN8}" == "48" && "${EXPECTED_GEN9}" == "48" ]] || {
  printf 'unexpected library counts: gen8=%s gen9=%s\n' "${EXPECTED_GEN8}" "${EXPECTED_GEN9}" >&2
  exit 1; }

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
bind_target() { local root="$1" t="$2"; printf '%s' "${t//%LIB%/${root}/usr/lib/kyri/python}"; }
materialise() {
  local commit="$1" source="$2" destination="$3"
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
}

SOURCE_PATH="$(field "${ROW}" 0)"
GEN8_DIGEST="$(field "${ROW}" 4)"
GEN9_DIGEST="$(field "${ROW}" 5)"
target_path() { bind_target "$1" "$(field "${ROW}" 1)"; }
target_at() { digest_of "$(target_path "$1")"; }

# ===========================================================================
# A fixture Generation-8 host
# ===========================================================================
build_fixture() {
  local root="$1" file flattened
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/var/lib/kyri"

  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN8_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN8_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py \
                   kyri-exec-verify:kyri_exec_verify.py; do
    materialise "${GEN8_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  materialise "${GEN8_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN8_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN8_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  materialise "${GEN8_COMMIT}" provisioning/execution/kyri-exec-verify-worker.py \
    "${root}/usr/libexec/kyri-exec-verify-worker.py"
  materialise "${GEN8_COMMIT}" provisioning/execution/kyri-exec-verify-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-verify"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition" \
             "${root}/usr/libexec/kyri-exec-quota" \
             "${root}/usr/libexec/kyri-exec-verify"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py" \
             "${root}/usr/libexec/kyri-exec-verify-worker.py"

  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen8-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN8_COMMIT}"
    printf 'baseline_commit %s\n' "${GEN7_COMMIT}"
    printf 'transaction gen8-fixture\n'
  } > "${root}/root/kyri-gen8-helper-digests.txt"
}

run_ceremony() {
  local root="$1" failat="$2"; shift 2
  local status=0
  if [[ -n "${failat}" ]]; then
    ( cd "${REPOSITORY}" && KYRI_GEN9_FAIL_AT="${failat}" \
        bash "${CEREMONY}" --fixture "${root}" "$@" ) > "${root}/last-run.log" 2>&1 || status=$?
  else
    ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1 || status=$?
  fi
  return "${status}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }
surface_digest() {
  ( cd "$1/usr/lib/kyri/python" && find . -type f -name '*.py' \
      ! -name cli.py -print0 | sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1
}
residue_count() {
  local root="$1" n=0 suffix
  for suffix in "${PREPARED_SUFFIX}" "${BACKUP_SUFFIX}"; do
    [[ -e "$(target_path "${root}")${suffix}" ]] && n=$((n + 1))
  done
  printf '%s' "${n}"
}

# ===========================================================================
# 1. the matrix is exactly the reviewed generation-9 delta
# ===========================================================================
if [[ "$(field "${ROW}" 3)" == "REPLACE" && "${SOURCE_PATH}" == "tools/capability/cli.py" ]]; then
  pass "the matrix is exactly one REPLACE of tools/capability/cli.py"
else
  fail "the matrix is not the reviewed single replacement"
fi

if [[ "${GEN8_DIGEST}" == "$(git -C "${REPOSITORY}" cat-file blob "${GEN8_COMMIT}:${SOURCE_PATH}" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "the declared generation-8 predecessor is the generation-8 commit object"
else
  fail "the declared predecessor does not match the generation-8 commit"
fi

if [[ "${GEN9_DIGEST}" == "$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${SOURCE_PATH}" | sha256sum | cut -d' ' -f1)" ]]; then
  pass "the declared generation-9 result is the reviewed source-authority commit object"
else
  fail "the declared result does not match the reviewed commit object"
fi

if [[ "${GEN8_DIGEST}" != "${GEN9_DIGEST}" ]]; then
  pass "the transition is a real change"
else
  fail "the declared predecessor and result are the same bytes"
fi

# ===========================================================================
# 2. --verify on a clean generation-8 host
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if [[ "$(library_count "${clean}")" -eq "${EXPECTED_GEN8}" ]]; then
  pass "the fixture is a generation-8 host: ${EXPECTED_GEN8} library objects"
else
  fail "the fixture holds $(library_count "${clean}") objects, expected ${EXPECTED_GEN8}"
fi

if run_ceremony "${clean}" "" --verify; then
  pass "--verify accepts a host at the accepted generation-8 baseline"
else
  fail "--verify rejected a valid generation-8 host: $(tail -12 "${clean}/last-run.log")"
fi

before_verify="$(snapshot_production "${clean}")"
run_ceremony "${clean}" "" --verify || true
if [[ "${before_verify}" == "$(snapshot_production "${clean}")" && "$(residue_count "${clean}")" == "0" ]]; then
  pass "--verify mutates nothing and creates no transaction material"
else
  fail "--verify changed the fixture or left transaction material"
fi

# ===========================================================================
# 3. preflight refusals
# ===========================================================================
drift="${WORK}/drift"; build_fixture "${drift}"
chmod u+w "${drift}/usr/lib/kyri/python/tools/capability/store.py"
printf '\n# drift\n' >> "${drift}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${drift}" "" --verify; then
  fail "--verify accepted a host whose generation-8 baseline had drifted"
else
  pass "unknown generation-8 runtime drift refuses the transaction"
fi

wrong="${WORK}/wrongtarget"; build_fixture "${wrong}"
chmod u+w "$(target_path "${wrong}")"
printf '\n# not generation 8\n' >> "$(target_path "${wrong}")"
if run_ceremony "${wrong}" "" --verify; then
  fail "--verify accepted a target that is not the accepted predecessor"
else
  pass "an installed cli.py that is not the generation-8 predecessor refuses"
fi

absent="${WORK}/absent"; build_fixture "${absent}"
chmod u+w "$(dirname "$(target_path "${absent}")")"
rm -f "$(target_path "${absent}")"
if run_ceremony "${absent}" "" --verify; then
  fail "--verify accepted a host with no cli.py at all"
else
  pass "an absent target refuses rather than being treated as a fresh create"
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

noevidence="${WORK}/noevidence"; build_fixture "${noevidence}"
rm -f "${noevidence}/root/kyri-gen8-library-digests.txt"
if run_ceremony "${noevidence}" "" --verify; then
  fail "--verify accepted a host with no generation-8 evidence"
else
  pass "missing generation-8 evidence refuses the transaction"
fi

residue="${WORK}/residue"; build_fixture "${residue}"
touch "$(target_path "${residue}")${PREPARED_SUFFIX}"
if run_ceremony "${residue}" "" --verify; then
  fail "--verify accepted a host carrying transaction residue"
else
  pass "pre-existing transaction residue refuses"
fi

# ===========================================================================
# 4. a clean installation
# ===========================================================================
happy="${WORK}/happy"; build_fixture "${happy}"
surface_before="$(surface_digest "${happy}")"
if run_ceremony "${happy}" "" --install; then
  pass "--install completes on a clean generation-8 host"
else
  fail "--install failed on a clean host: $(tail -20 "${happy}/last-run.log")"
fi

if [[ "$(target_at "${happy}")" == "${GEN9_DIGEST}" ]]; then
  pass "the REPLACE published the exact generation-9 cli.py"
else
  fail "cli.py is $(target_at "${happy}"), expected ${GEN9_DIGEST}"
fi
if [[ "$(surface_digest "${happy}")" == "${surface_before}" ]]; then
  pass "no other installed runtime object changed"
else
  fail "the installed runtime surface changed beyond cli.py"
fi
if [[ "$(library_count "${happy}")" -eq "${EXPECTED_GEN9}" ]]; then
  pass "a pure REPLACE left the object count at ${EXPECTED_GEN9}"
else
  fail "the library holds $(library_count "${happy}") objects, expected ${EXPECTED_GEN9}"
fi
if [[ "$(stat -c '%a' "$(target_path "${happy}")")" == "444" ]]; then
  pass "cli.py is published 0444"
else
  fail "cli.py is $(stat -c '%a' "$(target_path "${happy}")"), expected 444"
fi
if [[ -f "${happy}/root/kyri-gen9-library-digests.txt" \
   && -f "${happy}/root/kyri-gen8-library-digests.txt" ]]; then
  pass "generation-9 evidence was written and generation-8 evidence preserved"
else
  fail "generation-9 evidence is missing or generation-8 evidence was consumed"
fi
if grep -q "^state=COMMITTED" "${happy}/root/kyri-gen9-transaction/journal"; then
  pass "the journal records COMMITTED"
else
  fail "the journal is not COMMITTED: $(head -5 "${happy}/root/kyri-gen9-transaction/journal" 2>&1)"
fi
if [[ "$(residue_count "${happy}")" == "0" ]]; then
  pass "prepared and rollback artefacts are removed after commit"
else
  fail "$(residue_count "${happy}") transaction artefact(s) survived the commit"
fi
if [[ ! -e "${happy}${SUDOERS_ABS}" && ! -e "${happy}${VERIFY_SUDOERS_ABS}" ]]; then
  pass "the ceremony installed no sudoers grant: G3 and G6.1B stay closed"
else
  fail "the ceremony wrote a sudoers grant"
fi

if run_ceremony "${happy}" "" --verify-installed; then
  pass "--verify-installed accepts the freshly installed generation 9"
else
  fail "--verify-installed rejected a good install: $(tail -20 "${happy}/last-run.log")"
fi

before_vi="$(snapshot_production "${happy}")"
run_ceremony "${happy}" "" --verify-installed || true
if [[ "${before_vi}" == "$(snapshot_production "${happy}")" ]]; then
  pass "--verify-installed mutates nothing"
else
  fail "--verify-installed changed the fixture"
fi

if run_ceremony "${happy}" "" --install \
   && grep -qi "already installed" "${happy}/last-run.log"; then
  pass "a rerun on an installed host is a no-op, not a second transaction"
else
  fail "a rerun did not recognise generation 9: $(tail -10 "${happy}/last-run.log")"
fi

# ===========================================================================
# 5. failure injection before the durable commit point
# ===========================================================================
# Every boundary the transaction can be interrupted at, injected rather than
# reasoned about. All of these must leave the exact accepted generation-8 bytes.
for boundary in stage staged retained prepared committing publish verify precommit; do
  injected="${WORK}/fail-${boundary}"; build_fixture "${injected}"
  surface_before="$(surface_digest "${injected}")"
  if run_ceremony "${injected}" "${boundary}" --install; then
    fail "an injected failure at '${boundary}' still reported success"
    continue
  fi
  problems=""
  [[ "$(target_at "${injected}")" == "${GEN8_DIGEST}" ]] \
    || problems+=" cli.py=$(target_at "${injected}")"
  [[ "$(surface_digest "${injected}")" == "${surface_before}" ]] \
    || problems+=" surface-changed"
  [[ -f "${injected}/root/kyri-gen9-library-digests.txt" ]] \
    && problems+=" gen9-evidence-written"
  [[ -f "${injected}/root/kyri-gen8-library-digests.txt" ]] \
    || problems+=" gen8-evidence-lost"
  [[ "$(library_count "${injected}")" -eq "${EXPECTED_GEN8}" ]] \
    || problems+=" object-count=$(library_count "${injected}")"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves the exact generation-8 bytes"
  else
    fail "rollback at '${boundary}' left:${problems}"
  fi
done

# The retained rollback object must itself verify before it can be used.
forged="${WORK}/forgedbackup"; build_fixture "${forged}"
if run_ceremony "${forged}" "backup" --install; then
  fail "the ceremony proceeded with an unverifiable rollback object"
else
  if [[ "$(target_at "${forged}")" == "${GEN8_DIGEST}" ]]; then
    pass "a rollback object that does not verify halts before publication"
  else
    fail "cli.py was published despite an unverifiable rollback object"
  fi
fi

# ===========================================================================
# 6. after the durable commit point, generation 9 is authoritative
# ===========================================================================
for boundary in postcommit evidence cleanup; do
  after="${WORK}/after-${boundary}"; build_fixture "${after}"
  run_ceremony "${after}" "${boundary}" --install || true
  problems=""
  [[ "$(target_at "${after}")" == "${GEN9_DIGEST}" ]] || problems+=" cli.py-reverted"
  grep -q "^state=COMMITTED" "${after}/root/kyri-gen9-transaction/journal" \
    || problems+=" journal-not-committed"
  [[ -f "${after}/root/kyri-gen8-library-digests.txt" ]] || problems+=" gen8-evidence-lost"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves generation 9 installed and committed"
  else
    fail "a post-commit failure at '${boundary}' damaged the installation:${problems}"
  fi
done

recoverable="${WORK}/after-cleanup"
if run_ceremony "${recoverable}" "" --verify-installed; then
  pass "--verify-installed accepts generation 9 after a cleanup failure"
else
  fail "--verify-installed rejected a committed generation 9: $(tail -12 "${recoverable}/last-run.log")"
fi

# ===========================================================================
# 7. unknown state
# ===========================================================================
unknown="${WORK}/unknown"; build_fixture "${unknown}"
chmod u+w "$(target_path "${unknown}")"
printf '\n# neither generation\n' >> "$(target_path "${unknown}")"
mkdir -p "${unknown}/root/kyri-gen9-transaction"
printf 'state=COMMITTING\n' > "${unknown}/root/kyri-gen9-transaction/journal"
before_unknown="$(target_at "${unknown}")"
if run_ceremony "${unknown}" "" --install; then
  fail "recovery accepted unknown bytes at cli.py"
else
  if [[ "$(target_at "${unknown}")" == "${before_unknown}" ]]; then
    pass "unknown bytes halt recovery and are left exactly as found"
  else
    fail "recovery modified unknown bytes instead of refusing"
  fi
fi

gone="${WORK}/gonetarget"; build_fixture "${gone}"
chmod u+w "$(dirname "$(target_path "${gone}")")"
rm -f "$(target_path "${gone}")"
mkdir -p "${gone}/root/kyri-gen9-transaction"
printf 'state=COMMITTING\n' > "${gone}/root/kyri-gen9-transaction/journal"
if run_ceremony "${gone}" "" --install; then
  fail "recovery accepted an absent target with no rollback material"
else
  pass "an absent target with no rollback material halts for operator disposition"
fi

# ===========================================================================
# 8. security backstops, proven structurally
# ===========================================================================
body="$(grep -v '^[[:space:]]*#' "${CEREMONY}")"
forbidden=0
for token in "vi""sudo" "pod""man" "doc""ker" "xfs_""quota" "quot""actl" \
             "set""cap" "CINV""-" "CRES""-" "CADM""-" "authorise-launch" \
             "kyri-exec-verify " "kyri-exec-transition " "capability-handoff" \
             "kyri-root"; do
  if grep -qF "${token}" <<<"${body}"; then
    printf 'unexpected token in ceremony: %s\n' "${token}" >&2
    forbidden=$((forbidden + 1))
  fi
done
if (( forbidden == 0 )); then
  pass "the ceremony executes no helper, seeds no store, and grants no authority"
else
  fail "${forbidden} forbidden token(s) appear in the ceremony"
fi

# The authority namespace is named, and that is the point: the ceremony
# fingerprints it before and after to prove it was not disturbed. What must be
# absent is any verb that could write it, not the name of the thing being
# watched.
if grep -qE '(printf|echo|cat|tee|cp |mv |install |chmod|chown|rm |mkdir|>|>>)[^|]*(AUTHORITY_ROOT|CONTROL_ROOT)' \
     <<<"${body}"; then
  fail "the ceremony carries a write verb aimed at the authority namespace"
else
  pass "the authority namespace is only ever read, never written"
fi

if grep -qE '^\s*(chmod|chown|rm|mv|cp|install|mkdir)\b' \
     <<<"$(sed -n '/^--verify)/,/^\s*;;/p' "${CEREMONY}")"; then
  fail "--verify carries a mutating command"
else
  pass "the --verify branch carries no mutating command"
fi

if grep -qE '^\s*(chmod|chown|rm|mv|cp|install|mkdir)\b' \
     <<<"$(sed -n '/^--verify-installed)/,/^\s*;;/p' "${CEREMONY}")"; then
  fail "--verify-installed carries a mutating command"
else
  pass "the --verify-installed branch carries no mutating command"
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
if grep -q "tests/test-capability-execution-generation9-installer.sh" \
     "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "tests/test-capability-execution-generation9-installer.sh" \
     "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the generation-9 installer suite runs in local validation and in CI"
else
  fail "the generation-9 installer suite is not registered"
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
  printf 'Capability execution generation-9 installer validation passed.\n'
else
  printf 'Capability execution generation-9 installer validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
