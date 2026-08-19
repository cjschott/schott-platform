#!/usr/bin/env bash
set -Eeuo pipefail

# Empirical failure-injection tests for the Generation-10 installation ceremony.
#
# WHAT IS DIFFERENT FROM GENERATION 9. Generation 9 was ONE replacement.
# Generation 10 is FOUR, and every interesting property follows from that:
# `rename(2)` is atomic for one pathname and there is no atomic multi-file
# publication, so between the first and the fourth rename the installed runtime
# is genuinely mixed. This suite therefore proves the mixed states directly --
# G10/G9/G9/G9, G10/G10/G9/G9, G10/G10/G10/G9 -- rather than reasoning that the
# single-object argument still holds.
#
# FIXTURE ONLY. Every case builds a throwaway Generation-9 host under a
# temporary root and runs the ceremony with --fixture against it. Nothing here
# touches /usr/lib/kyri/python, /usr/libexec, /etc/sudoers.d, the governance
# stores, or the authority namespace, and the production paths are snapshotted
# before and after to prove it.
#
# WHAT IT MUST NOT DO. This suite installs nothing outside its fixtures, writes
# no sudoers policy, invokes no privileged helper, allocates no identifier,
# creates no governance store, and contacts no container runtime.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-10.sh"
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
[[ "${#RAW_ROWS[@]}" -eq 4 ]] || {
  printf 'expected exactly 4 matrix rows, found %s\n' "${#RAW_ROWS[@]}" >&2; exit 1; }
ROWS=()
for raw in "${RAW_ROWS[@]}"; do ROWS+=("${raw//\$\{LIBRARY_ROOT\}/%LIB%}"); done

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
read_number() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p" "${CEREMONY}" | head -1; }
COMMIT="$(read_pin COMMIT)"
GEN9_COMMIT="$(read_pin GEN9_COMMIT)"
# The Generation-9 installer is what wrote the Generation-9 helper evidence, so
# its own predecessor pin is read from there rather than restated here.
GEN8_COMMIT="$(sed -n 's/^GEN8_COMMIT="\(.*\)"$/\1/p' \
  "${REPOSITORY}/provisioning/execution/install-generation-9.sh" | head -1)"
SUDOERS_ABS="$(read_pin SUDOERS)"
VERIFY_SUDOERS_ABS="$(read_pin VERIFY_SUDOERS)"
PREPARED_SUFFIX="$(read_pin PREPARED_SUFFIX)"
BACKUP_SUFFIX="$(read_pin BACKUP_SUFFIX)"
EXPECTED_GEN9="$(read_number EXPECTED_LIBRARY_FILES_GEN9)"
EXPECTED_GEN10="$(read_number EXPECTED_LIBRARY_FILES_GEN10)"
for name in COMMIT GEN9_COMMIT GEN8_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'no full 40-character %s available\n' "${name}" >&2; exit 1; }
done
# A pure REPLACE moves no object count. If these ever differ, the matrix grew.
[[ "${EXPECTED_GEN9}" == "48" && "${EXPECTED_GEN10}" == "48" ]] || {
  printf 'unexpected library counts: gen9=%s gen10=%s\n' "${EXPECTED_GEN9}" "${EXPECTED_GEN10}" >&2
  exit 1; }

field() { IFS='|' read -r -a _f <<<"$1"; printf '%s' "${_f[$2]}"; }
digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
bind_target() { local root="$1" t="$2"; printf '%s' "${t//%LIB%/${root}/usr/lib/kyri/python}"; }
materialise() {
  local commit="$1" source="$2" destination="$3"
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
}

# Indexed accessors: everything below is written over all four rows.
row_source() { field "${ROWS[$1]}" 0; }
row_gen9()   { field "${ROWS[$1]}" 4; }
row_gen10()  { field "${ROWS[$1]}" 5; }
row_target() { bind_target "$2" "$(field "${ROWS[$1]}" 1)"; }
row_at()     { digest_of "$(row_target "$1" "$2")"; }
INDICES=(0 1 2 3)

# The exact state of all four targets, as a compact string like "10 9 9 9".
target_states() {
  local root="$1" i out="" d
  for i in "${INDICES[@]}"; do
    d="$(row_at "${i}" "${root}")"
    if   [[ "${d}" == "$(row_gen10 "${i}")" ]]; then out+="10 "
    elif [[ "${d}" == "$(row_gen9 "${i}")"  ]]; then out+="9 "
    else out+="? "; fi
  done
  printf '%s' "${out% }"
}

# ===========================================================================
# A fixture Generation-9 host
# ===========================================================================
build_fixture() {
  local root="$1" file flattened
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/lib/kyri/python/tools/common" \
           "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/var/lib/kyri"

  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN9_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN9_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py \
                   kyri-exec-verify:kyri_exec_verify.py; do
    materialise "${GEN9_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  materialise "${GEN9_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN9_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN9_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  materialise "${GEN9_COMMIT}" provisioning/execution/kyri-exec-verify-worker.py \
    "${root}/usr/libexec/kyri-exec-verify-worker.py"
  materialise "${GEN9_COMMIT}" provisioning/execution/kyri-exec-verify-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-verify"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition" \
             "${root}/usr/libexec/kyri-exec-quota" \
             "${root}/usr/libexec/kyri-exec-verify"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py" \
             "${root}/usr/libexec/kyri-exec-verify-worker.py"

  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' -print0 | sort -z | xargs -0 sha256sum ) \
    | sed 's#  \./#  /usr/lib/kyri/python/#' \
    > "${root}/root/kyri-gen9-library-digests.txt"
  {
    printf 'commit %s\n' "${GEN9_COMMIT}"
    printf 'baseline_commit %s\n' "${GEN8_COMMIT}"
    printf 'predecessor generation 8\n'
    printf 'transaction gen9-fixture\n'
  } > "${root}/root/kyri-gen9-helper-digests.txt"
}

run_ceremony() {
  local root="$1" failat="$2"; shift 2
  local status=0
  if [[ -n "${failat}" ]]; then
    ( cd "${REPOSITORY}" && KYRI_GEN10_FAIL_AT="${failat}" \
        bash "${CEREMONY}" --fixture "${root}" "$@" ) > "${root}/last-run.log" 2>&1 || status=$?
  else
    ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
      > "${root}/last-run.log" 2>&1 || status=$?
  fi
  return "${status}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }

# The installed surface with all four targets excluded, so "nothing else moved"
# is a statement about the other 44 objects.
surface_digest() {
  local root="$1" i excludes=()
  for i in "${INDICES[@]}"; do
    excludes+=(! -name "$(basename "$(row_source "${i}")")")
  done
  ( cd "${root}/usr/lib/kyri/python" \
    && find . -type f -name '*.py' "${excludes[@]}" -print0 | sort -z | xargs -0 sha256sum ) \
    | sha256sum | cut -d' ' -f1
}

residue_count() {
  local root="$1" n=0 suffix i
  for i in "${INDICES[@]}"; do
    for suffix in "${PREPARED_SUFFIX}" "${BACKUP_SUFFIX}"; do
      [[ -e "$(row_target "${i}" "${root}")${suffix}" ]] && n=$((n + 1))
    done
  done
  printf '%s' "${n}"
}

JOURNAL_REL="root/kyri-gen10-transaction/journal"

# Build a genuine interrupted transaction: all four staged and retained, the
# first `published` targets already renamed into place, and a durable journal at
# COMMITTING. This is exactly what a crash mid-publication leaves behind, and it
# is constructed rather than simulated so recovery is tested against the real
# on-disk shape.
stage_interrupted() {
  local root="$1" published="$2" i target
  build_fixture "${root}"
  for i in "${INDICES[@]}"; do
    target="$(row_target "${i}" "${root}")"
    chmod u+w "$(dirname "${target}")"
    materialise "${COMMIT}" "$(row_source "${i}")" "${target}${PREPARED_SUFFIX}"
    chmod 0444 "${target}${PREPARED_SUFFIX}"
    cp -p "${target}" "${target}${BACKUP_SUFFIX}"
    if (( i < published )); then
      cp -p "${target}${PREPARED_SUFFIX}" "${target}.publishing"
      mv -f "${target}.publishing" "${target}"
      rm -f "${target}${PREPARED_SUFFIX}"
    fi
  done
  mkdir -p "${root}/root/kyri-gen10-transaction"
  {
    printf 'transaction=gen10-interrupted\n'
    printf 'commit=%s\n' "${COMMIT}"
    printf 'baseline_commit=%s\n' "${GEN9_COMMIT}"
    printf 'state=COMMITTING\n'
  } > "${root}/${JOURNAL_REL}"
}

# ===========================================================================
# 1. the matrix is exactly the reviewed generation-10 delta
# ===========================================================================
expected_sources="$(git -C "${REPOSITORY}" diff --name-only "${GEN9_COMMIT}" "${COMMIT}" -- 'tools/*.py' | sort)"
declared_sources="$(for i in "${INDICES[@]}"; do printf '%s\n' "$(row_source "${i}")"; done | sort)"
if [[ "${declared_sources}" == "${expected_sources}" ]]; then
  pass "the matrix is exactly the runtime delta between the two reviewed authorities"
else
  fail "the matrix is not the reviewed delta: declared=[${declared_sources//$'\n'/,}] actual=[${expected_sources//$'\n'/,}]"
fi

replace_n=0; create_n=0
for i in "${INDICES[@]}"; do
  case "$(field "${ROWS[$i]}" 3)" in
    REPLACE) replace_n=$((replace_n + 1)) ;;
    CREATE)  create_n=$((create_n + 1)) ;;
  esac
done
if [[ "${replace_n}" -eq 4 && "${create_n}" -eq 0 ]]; then
  pass "the matrix is four REPLACE operations and no CREATE"
else
  fail "the matrix is ${replace_n} REPLACE and ${create_n} CREATE, expected 4 and 0"
fi

digest_problems=""
for i in "${INDICES[@]}"; do
  source="$(row_source "${i}")"
  actual_gen9="$(git -C "${REPOSITORY}" cat-file blob "${GEN9_COMMIT}:${source}" | sha256sum | cut -d' ' -f1)"
  actual_gen10="$(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${source}" | sha256sum | cut -d' ' -f1)"
  [[ "$(row_gen9 "${i}")"  == "${actual_gen9}"  ]] || digest_problems+=" ${source}:gen9"
  [[ "$(row_gen10 "${i}")" == "${actual_gen10}" ]] || digest_problems+=" ${source}:gen10"
  [[ "$(row_gen9 "${i}")"  != "$(row_gen10 "${i}")" ]] || digest_problems+=" ${source}:no-change"
done
if [[ -z "${digest_problems}" ]]; then
  pass "every declared predecessor and result digest is the corresponding commit object"
else
  fail "declared digests disagree with the commit objects:${digest_problems}"
fi

if ! grep -qE '^"tools/capability/cli\.py\|' <<<"${RAW_ROWS[*]}"; then
  pass "cli.py is not a Generation-10 delta: the launch bridge needed no change"
else
  fail "cli.py appears in the Generation-10 matrix"
fi

if git -C "${REPOSITORY}" merge-base --is-ancestor "${GEN9_COMMIT}" "${COMMIT}"; then
  pass "the Generation-9 authority is an ancestor of the Generation-10 authority"
else
  fail "the pinned authorities are not in ancestry order"
fi

# ===========================================================================
# 2. --verify on a clean generation-9 host
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if [[ "$(library_count "${clean}")" -eq "${EXPECTED_GEN9}" ]]; then
  pass "the fixture is a generation-9 host: ${EXPECTED_GEN9} library objects"
else
  fail "the fixture holds $(library_count "${clean}") objects, expected ${EXPECTED_GEN9}"
fi

if [[ "$(target_states "${clean}")" == "9 9 9 9" ]]; then
  pass "the fixture starts with all four targets at Generation 9"
else
  fail "the fixture target states are [$(target_states "${clean}")]"
fi

if run_ceremony "${clean}" "" --verify; then
  pass "--verify accepts a host at the accepted generation-9 baseline"
else
  fail "--verify rejected a valid generation-9 host: $(tail -14 "${clean}/last-run.log")"
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
  fail "--verify accepted a host whose generation-9 baseline had drifted"
else
  pass "unrelated generation-9 runtime drift refuses the transaction"
fi

missing="${WORK}/missingobject"; build_fixture "${missing}"
chmod u+w "${missing}/usr/lib/kyri/python/tools/capability"
rm -f "${missing}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${missing}" "" --verify; then
  fail "--verify accepted a host missing a runtime object"
else
  pass "a runtime object the evidence records but the host lacks refuses"
fi

extra="${WORK}/extraobject"; build_fixture "${extra}"
printf '# unexpected\n' > "${extra}/usr/lib/kyri/python/tools/capability/intruder.py"
chmod 0444 "${extra}/usr/lib/kyri/python/tools/capability/intruder.py"
if run_ceremony "${extra}" "" --verify; then
  fail "--verify accepted a host carrying an unexpected runtime object"
else
  pass "an unexpected runtime object refuses"
fi

# Each of the four targets, individually made not-the-predecessor.
for i in "${INDICES[@]}"; do
  wrong="${WORK}/wrongtarget${i}"; build_fixture "${wrong}"
  chmod u+w "$(row_target "${i}" "${wrong}")"
  printf '\n# not generation 9\n' >> "$(row_target "${i}" "${wrong}")"
  if run_ceremony "${wrong}" "" --verify; then
    fail "--verify accepted target $(basename "$(row_source "${i}")") in an unruled state"
  else
    pass "an installed $(basename "$(row_source "${i}")") that is neither generation refuses"
  fi
done

# One target already at Generation 10 before a fresh transaction: a mixture, and
# it must not pass as a clean Generation-9 baseline.
ahead="${WORK}/oneahead"; build_fixture "${ahead}"
chmod u+w "$(dirname "$(row_target 0 "${ahead}")")"
materialise "${COMMIT}" "$(row_source 0)" "$(row_target 0 "${ahead}")"
chmod 0444 "$(row_target 0 "${ahead}")"
if run_ceremony "${ahead}" "" --verify; then
  fail "--verify accepted a host with one target already at Generation 10"
else
  if grep -qE 'not the accepted Generation-9 baseline|mixed target state' "${ahead}/last-run.log"; then
    pass "one target already at Generation 10 cannot pass as a Generation-9 baseline"
  else
    fail "the mixture refused for the wrong reason: $(tail -6 "${ahead}/last-run.log")"
  fi
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
rm -f "${noevidence}/root/kyri-gen9-library-digests.txt"
if run_ceremony "${noevidence}" "" --verify; then
  fail "--verify accepted a host with no generation-9 evidence"
else
  pass "missing generation-9 evidence refuses the transaction"
fi

residue="${WORK}/residue"; build_fixture "${residue}"
touch "$(row_target 2 "${residue}")${PREPARED_SUFFIX}"
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
  pass "--install completes on a clean generation-9 host"
else
  fail "--install failed on a clean host: $(tail -24 "${happy}/last-run.log")"
fi

if [[ "$(target_states "${happy}")" == "10 10 10 10" ]]; then
  pass "all four REPLACE operations published the exact generation-10 bytes"
else
  fail "target states after install are [$(target_states "${happy}")]"
fi
if [[ "$(surface_digest "${happy}")" == "${surface_before}" ]]; then
  pass "no fifth runtime object changed"
else
  fail "the installed runtime surface changed beyond the four targets"
fi
if [[ "$(library_count "${happy}")" -eq "${EXPECTED_GEN10}" ]]; then
  pass "four pure REPLACEs left the object count at ${EXPECTED_GEN10}"
else
  fail "the library holds $(library_count "${happy}") objects, expected ${EXPECTED_GEN10}"
fi
mode_problems=""
for i in "${INDICES[@]}"; do
  [[ "$(stat -c '%a' "$(row_target "${i}" "${happy}")")" == "444" ]] \
    || mode_problems+=" $(basename "$(row_source "${i}")")=$(stat -c '%a' "$(row_target "${i}" "${happy}")")"
done
if [[ -z "${mode_problems}" ]]; then
  pass "all four targets are published 0444"
else
  fail "published modes are wrong:${mode_problems}"
fi
if [[ -f "${happy}/root/kyri-gen10-library-digests.txt" \
   && -f "${happy}/root/kyri-gen10-helper-digests.txt" \
   && -f "${happy}/root/kyri-gen9-library-digests.txt" \
   && -f "${happy}/root/kyri-gen9-helper-digests.txt" ]]; then
  pass "generation-10 evidence was written and generation-9 evidence preserved"
else
  fail "generation-10 evidence is missing or generation-9 evidence was consumed"
fi

# The Generation-9 evidence must be byte-identical to what the fixture wrote.
gen9_evidence_before="$(digest_of "${clean}/root/kyri-gen9-library-digests.txt")"
if [[ "$(digest_of "${happy}/root/kyri-gen9-library-digests.txt")" == "${gen9_evidence_before}" ]]; then
  pass "the generation-9 evidence is byte-identical after installation"
else
  fail "the generation-9 evidence changed during installation"
fi

evidence_problems=""
for i in "${INDICES[@]}"; do
  grep -q "$(row_gen10 "${i}")" "${happy}/root/kyri-gen10-library-digests.txt" \
    || evidence_problems+=" missing-digest-$(basename "$(row_source "${i}")")"
  grep -qE "^delta REPLACE .*$(basename "$(row_source "${i}")") $(row_gen9 "${i}") $(row_gen10 "${i}")\$" \
    "${happy}/root/kyri-gen10-helper-digests.txt" \
    || evidence_problems+=" missing-delta-$(basename "$(row_source "${i}")")"
done
grep -q "^commit ${COMMIT}\$" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-authority"
grep -q "^baseline_commit ${GEN9_COMMIT}\$" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-predecessor-authority"
grep -q "^predecessor generation 9\$" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-predecessor-generation"
grep -q "^library_objects ${EXPECTED_GEN10}\$" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-object-count"
grep -q "^state COMMITTED\$" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-durable-state"
grep -q "^transaction gen10-" "${happy}/root/kyri-gen10-helper-digests.txt" \
  || evidence_problems+=" no-transaction-identity"
if [[ -z "${evidence_problems}" ]]; then
  pass "the generation-10 evidence records the authority, predecessor, four deltas, count and state"
else
  fail "the generation-10 evidence is incomplete:${evidence_problems}"
fi

if grep -q "^state=COMMITTED" "${happy}/${JOURNAL_REL}"; then
  pass "the journal records COMMITTED"
else
  fail "the journal is not COMMITTED: $(head -6 "${happy}/${JOURNAL_REL}" 2>&1)"
fi
if [[ "$(grep -c '^target[1-4]=' "${happy}/${JOURNAL_REL}")" -eq 4 ]]; then
  pass "the journal durably records all four targets"
else
  fail "the journal records $(grep -c '^target[1-4]=' "${happy}/${JOURNAL_REL}") targets, expected 4"
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
  pass "--verify-installed accepts the freshly installed generation 10"
else
  fail "--verify-installed rejected a good install: $(tail -24 "${happy}/last-run.log")"
fi

before_vi="$(snapshot_production "${happy}")"
run_ceremony "${happy}" "" --verify-installed || true
if [[ "${before_vi}" == "$(snapshot_production "${happy}")" ]]; then
  pass "--verify-installed mutates nothing"
else
  fail "--verify-installed changed the fixture"
fi

# --verify-installed must fail when a single G10 byte is wrong.
for i in 0 3; do
  tampered="${WORK}/tampered${i}"; build_fixture "${tampered}"
  run_ceremony "${tampered}" "" --install >/dev/null 2>&1 || true
  chmod u+w "$(row_target "${i}" "${tampered}")"
  printf '\n# tampered\n' >> "$(row_target "${i}" "${tampered}")"
  if run_ceremony "${tampered}" "" --verify-installed; then
    fail "--verify-installed accepted a tampered $(basename "$(row_source "${i}")")"
  else
    pass "--verify-installed refuses a tampered $(basename "$(row_source "${i}")")"
  fi
done

# and when an unaffected object drifts.
surfacedrift="${WORK}/surfacedrift"; build_fixture "${surfacedrift}"
run_ceremony "${surfacedrift}" "" --install >/dev/null 2>&1 || true
chmod u+w "${surfacedrift}/usr/lib/kyri/python/tools/capability/store.py"
printf '\n# drift\n' >> "${surfacedrift}/usr/lib/kyri/python/tools/capability/store.py"
if run_ceremony "${surfacedrift}" "" --verify-installed; then
  fail "--verify-installed accepted drift in an unaffected object"
else
  pass "--verify-installed refuses drift in an object the transaction did not touch"
fi

if run_ceremony "${happy}" "" --install \
   && grep -qi "already installed" "${happy}/last-run.log"; then
  pass "a rerun on an installed host is a no-op, not a second transaction"
else
  fail "a rerun did not recognise generation 10: $(tail -10 "${happy}/last-run.log")"
fi

# ===========================================================================
# 5. failure injection before the durable commit point
# ===========================================================================
# Every boundary the transaction can be interrupted at, injected rather than
# reasoned about. Positions 1..4 are the four publications. All of these must
# leave the exact accepted generation-9 bytes at all four targets.
for boundary in stage staged retained prepared committing publish verify precommit 1 2 3 4; do
  injected="${WORK}/fail-${boundary}"; build_fixture "${injected}"
  surface_before="$(surface_digest "${injected}")"
  if run_ceremony "${injected}" "${boundary}" --install; then
    fail "an injected failure at '${boundary}' still reported success"
    continue
  fi
  problems=""
  [[ "$(target_states "${injected}")" == "9 9 9 9" ]] \
    || problems+=" states=[$(target_states "${injected}")]"
  [[ "$(surface_digest "${injected}")" == "${surface_before}" ]] \
    || problems+=" surface-changed"
  [[ -f "${injected}/root/kyri-gen10-library-digests.txt" ]] \
    && problems+=" gen10-evidence-written"
  [[ -f "${injected}/root/kyri-gen9-library-digests.txt" ]] \
    || problems+=" gen9-evidence-lost"
  [[ "$(library_count "${injected}")" -eq "${EXPECTED_GEN9}" ]] \
    || problems+=" object-count=$(library_count "${injected}")"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves all four targets at the exact generation-9 bytes"
  else
    fail "rollback at '${boundary}' left:${problems}"
  fi
done

# The retained rollback object must itself verify before it can be used.
forged="${WORK}/forgedbackup"; build_fixture "${forged}"
if run_ceremony "${forged}" "backup" --install; then
  fail "the ceremony proceeded with an unverifiable rollback object"
else
  if [[ "$(target_states "${forged}")" == "9 9 9 9" ]]; then
    pass "a rollback object that does not verify halts before any publication"
  else
    fail "a target was published despite an unverifiable rollback object: [$(target_states "${forged}")]"
  fi
fi

# ===========================================================================
# 6. after the durable commit point, generation 10 is authoritative
# ===========================================================================
for boundary in postcommit evidence cleanup; do
  after="${WORK}/after-${boundary}"; build_fixture "${after}"
  run_ceremony "${after}" "${boundary}" --install || true
  problems=""
  [[ "$(target_states "${after}")" == "10 10 10 10" ]] \
    || problems+=" reverted=[$(target_states "${after}")]"
  grep -q "^state=COMMITTED" "${after}/${JOURNAL_REL}" || problems+=" journal-not-committed"
  [[ -f "${after}/root/kyri-gen9-library-digests.txt" ]] || problems+=" gen9-evidence-lost"
  if [[ -z "${problems}" ]]; then
    pass "a failure at '${boundary}' leaves generation 10 installed and committed"
  else
    fail "a post-commit failure at '${boundary}' damaged the installation:${problems}"
  fi
done

recoverable="${WORK}/after-cleanup"
if run_ceremony "${recoverable}" "" --verify-installed; then
  pass "--verify-installed accepts generation 10 after a cleanup failure"
else
  fail "--verify-installed rejected a committed generation 10: $(tail -14 "${recoverable}/last-run.log")"
fi

# ===========================================================================
# 7. mixed states: the four-object case, proven directly
# ===========================================================================
# 1, 2 and 3 of 4 published, with the remaining prepared material intact. The
# accepted model completes FORWARD when every remaining prepared object
# verifies, so each of these must reach a complete Generation 10.
for published in 1 2 3; do
  mixed="${WORK}/mixed-forward-${published}"
  stage_interrupted "${mixed}" "${published}"
  expected_before=""
  for i in "${INDICES[@]}"; do
    if (( i < published )); then expected_before+="10 "; else expected_before+="9 "; fi
  done
  expected_before="${expected_before% }"
  if [[ "$(target_states "${mixed}")" != "${expected_before}" ]]; then
    fail "the interrupted fixture is [$(target_states "${mixed}")], expected [${expected_before}]"
    continue
  fi
  if run_ceremony "${mixed}" "" --recover; then
    if [[ "$(target_states "${mixed}")" == "10 10 10 10" ]] \
       && grep -q "^state=COMMITTED" "${mixed}/${JOURNAL_REL}"; then
      pass "recovery from [${expected_before}] completes FORWARD to a whole Generation 10"
    else
      fail "recovery from [${expected_before}] left [$(target_states "${mixed}")]"
    fi
  else
    fail "recovery from [${expected_before}] failed: $(tail -14 "${mixed}/last-run.log")"
  fi
  if grep -q "FORWARD" "${mixed}/last-run.log"; then
    pass "recovery from [${expected_before}] states its direction as FORWARD"
  else
    fail "recovery from [${expected_before}] did not report a FORWARD direction"
  fi
done

# The same mixed shapes, but with prepared material incomplete, so forward
# cannot be proven and the accepted model rolls back to a whole Generation 9.
for published in 1 2 3; do
  back="${WORK}/mixed-back-${published}"
  stage_interrupted "${back}" "${published}"
  # Destroy one remaining prepared object: forward is no longer provable.
  rm -f "$(row_target 3 "${back}")${PREPARED_SUFFIX}"
  if run_ceremony "${back}" "" --recover; then
    fail "recovery claimed success with incomplete prepared material"
  else
    if [[ "$(target_states "${back}")" == "9 9 9 9" ]]; then
      pass "recovery from [$(printf '%s' "${published}")-published with missing prepared material rolls BACK to a whole Generation 9"
    else
      fail "rollback from a mixed state left [$(target_states "${back}")]"
    fi
  fi
done

# ===========================================================================
# 8. UNKNOWN bytes fail closed at every relevant phase
# ===========================================================================
# A target that is neither generation, in a fresh transaction and in each mixed
# recovery shape. Recovery must never overwrite it.
for published in 0 1 2 3; do
  unknown="${WORK}/unknown-${published}"
  if (( published == 0 )); then
    build_fixture "${unknown}"
    mkdir -p "${unknown}/root/kyri-gen10-transaction"
    printf 'state=COMMITTING\n' > "${unknown}/${JOURNAL_REL}"
  else
    stage_interrupted "${unknown}" "${published}"
  fi
  victim=3
  chmod u+w "$(row_target "${victim}" "${unknown}")"
  printf '\n# neither generation\n' >> "$(row_target "${victim}" "${unknown}")"
  before_unknown="$(row_at "${victim}" "${unknown}")"
  if run_ceremony "${unknown}" "" --install; then
    fail "recovery accepted unknown bytes with ${published} published"
  else
    if [[ "$(row_at "${victim}" "${unknown}")" == "${before_unknown}" ]]; then
      pass "unknown bytes halt recovery with ${published} published, and are left exactly as found"
    else
      fail "recovery modified unknown bytes instead of refusing (${published} published)"
    fi
  fi
done

gone="${WORK}/gonetarget"; build_fixture "${gone}"
chmod u+w "$(dirname "$(row_target 1 "${gone}")")"
rm -f "$(row_target 1 "${gone}")"
mkdir -p "${gone}/root/kyri-gen10-transaction"
printf 'state=COMMITTING\n' > "${gone}/${JOURNAL_REL}"
if run_ceremony "${gone}" "" --install; then
  fail "recovery accepted an absent target with no rollback material"
else
  pass "an absent target with no rollback material halts for operator disposition"
fi

# Rollback material that drifted must not be restored from.
driftback="${WORK}/driftbackup"; stage_interrupted "${driftback}" 2
rm -f "$(row_target 3 "${driftback}")${PREPARED_SUFFIX}"
chmod u+w "$(row_target 0 "${driftback}")${BACKUP_SUFFIX}"
printf '\n# corrupted rollback material\n' >> "$(row_target 0 "${driftback}")${BACKUP_SUFFIX}"
if run_ceremony "${driftback}" "" --recover; then
  fail "recovery restored from rollback material that does not verify"
else
  pass "rollback material that does not verify is refused, not used"
fi

# ===========================================================================
# 9. security backstops, proven structurally
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

# The Fabric resource vocabulary is a separate open blocker and must not be
# touched, worked around, or decided here.
if grep -qE 'resource_requirements|verified_resource_profile|resource_profile_vocabulary|amd64|x86_64' \
     "${CEREMONY}"; then
  fail "the ceremony touches the unresolved Fabric resource vocabulary"
else
  pass "the ceremony carries no Fabric resource-vocabulary decision or workaround"
fi

if grep -qE '(printf|echo|cat|tee|cp |mv |install |chmod|chown|rm |mkdir|>|>>)[^|]*(AUTHORITY_ROOT|CONTROL_ROOT)' \
     <<<"${body}"; then
  fail "the ceremony carries a write verb aimed at the authority namespace"
else
  pass "the authority namespace is only ever read, never written"
fi

for mode_branch in --verify --verify-installed; do
  if grep -qE '^\s*(chmod|chown|rm|mv|cp|install|mkdir)\b' \
       <<<"$(sed -n "/^${mode_branch})/,/^\s*;;/p" "${CEREMONY}")"; then
    fail "${mode_branch} carries a mutating command"
  else
    pass "the ${mode_branch} branch carries no mutating command"
  fi
done

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
# 10. the ceremony describes the transaction it actually performs
# ===========================================================================
# Ceremony output is audit evidence. Generation 9 shipped a ceremony that
# described Generation 8's two-object transaction, and that is why these cases
# exist. A four-object transaction has the inverse failure mode: inheriting a
# one-object narrative.
STALE_CLAIMS='cli\.py|mutation\.py|\bone REPLACE\b|single replacement|one object\b|\b47\b|\b49\b|Generation 9 is a single'
messages="$(grep -oE '\b(ok|note|bad|halt)[[:space:]]+"[^"]*"' "${CEREMONY}" || true)"
if grep -qiE "${STALE_CLAIMS}" <<<"${messages}"; then
  grep -oiE "${STALE_CLAIMS}" <<<"${messages}" | sort -u \
    | while IFS= read -r hit; do
        printf 'stale operator message contains %s\n' "${hit}" >&2
      done
  fail "an operator-visible message still describes a one-object transaction"
else
  pass "no operator-visible message claims anything the four-row matrix cannot support"
fi

header="$(sed -n '1,60p' "${CEREMONY}")"
problems=""
grep -qiE 'FOUR|four REPLACE' <<<"${header}" || problems+=" header-does-not-say-four"
grep -qE '\bCREATE\b' <<<"$(grep -A 4 'WHAT THIS INSTALLS' <<<"${header}")" \
  && problems+=" installs-section-claims-a-create"
grep -qE '48[[:space:]]*(->|→)[[:space:]]*49|47[[:space:]]*(->|→)[[:space:]]*48' <<<"${header}" \
  && problems+=" claims-count-growth"
grep -qiE 'object count is unchanged at 48' <<<"${header}" \
  || problems+=" header-does-not-state-the-count-is-unchanged"
if [[ -z "${problems}" ]]; then
  pass "the header describes four REPLACE operations at an unchanged object count"
else
  fail "the header misdescribes the transaction:${problems}"
fi

# The strongest check: a real run, and what it actually printed.
spoken="${WORK}/spoken"; build_fixture "${spoken}"
run_ceremony "${spoken}" "" --install || true
spoken_problems=""
grep -qE 'PREPARE complete' "${spoken}/last-run.log" || spoken_problems+=" no-prepare-line"
grep -qE 'COMMIT complete' "${spoken}/last-run.log" || spoken_problems+=" no-commit-line"
grep -qE 'COMMIT complete: 4 objects' "${spoken}/last-run.log" \
  || spoken_problems+=" commit-line-does-not-say-4-objects"
grep -qE 'PREPARE complete: 4 objects' "${spoken}/last-run.log" \
  || spoken_problems+=" prepare-line-does-not-say-4-objects"
if grep -qiE "${STALE_CLAIMS}" "${spoken}/last-run.log"; then
  spoken_problems+=" said:$(grep -oiE "${STALE_CLAIMS}" "${spoken}/last-run.log" \
    | sort -u | tr '\n' ',' | tr ' ' '_')"
fi
for i in "${INDICES[@]}"; do
  grep -qF "$(basename "$(row_source "${i}")")" "${spoken}/last-run.log" \
    || spoken_problems+=" never-named-$(basename "$(row_source "${i}")")"
done
grep -qi 'Generation 10' "${spoken}/last-run.log" || spoken_problems+=" never-named-generation-10"
if [[ -z "${spoken_problems}" ]]; then
  pass "an actual --install run names all four objects and describes only what it did"
else
  fail "an actual --install run misreported itself:${spoken_problems}"
fi

for mode in --verify --verify-installed; do
  spoken_mode="${WORK}/spoken${mode}"; build_fixture "${spoken_mode}"
  [[ "${mode}" == "--verify-installed" ]] && run_ceremony "${spoken_mode}" "" --install >/dev/null 2>&1
  run_ceremony "${spoken_mode}" "" "${mode}" || true
  mode_problems=""
  if grep -qiE "${STALE_CLAIMS}" "${spoken_mode}/last-run.log"; then
    mode_problems+=" said:$(grep -oiE "${STALE_CLAIMS}" "${spoken_mode}/last-run.log" \
      | sort -u | tr '\n' ',' | tr ' ' '_')"
  fi
  grep -qi 'Generation 10' "${spoken_mode}/last-run.log" || mode_problems+=" never-named-generation-10"
  if [[ -z "${mode_problems}" ]]; then
    pass "${mode} output describes only the Generation-10 transaction"
  else
    fail "${mode} output misdescribes the transaction:${mode_problems}"
  fi
done

# ===========================================================================
# 11. registration and isolation
# ===========================================================================
if grep -q "tests/test-capability-execution-generation10-installer.sh" \
     "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "tests/test-capability-execution-generation10-installer.sh" \
     "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the generation-10 installer suite runs in local validation and in CI"
else
  fail "the generation-10 installer suite is not registered"
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
  printf 'Capability execution generation-10 installer validation passed.\n'
else
  printf 'Capability execution generation-10 installer validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
