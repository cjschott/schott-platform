#!/usr/bin/env bash
# This suite uses `<test> && pass ... || fail ...` in places. SC2015 warns the C
# branch can run when A succeeded -- impossible here, because `pass` is a single
# printf and cannot fail.
# shellcheck disable=SC2015
set -Eeuo pipefail

# Validation for the G5 production build context.
#
# WHY IT EXISTS. The first production build named the coordinator's checkout as
# both --file and context, and failed before Podman started:
#
#   cannot chdir to /opt/schott-platform: Permission denied
#
# /opt/schott-platform is cschott:cschott 0750 and kyri-capability is in neither
# the owner nor the group, so it has no traverse bit. That is the authority
# split working. The correction gives the execution identity a context it can
# read, on ancestry the coordinator cannot touch, holding exactly the reviewed
# bytes -- and this suite proves each of those three, the last one by attacking
# it with a hostile working tree.
#
# ISOLATED BY CONSTRUCTION. Every case runs against a throwaway fixture. Nothing
# here builds an image, pulls a base, creates authority state, invokes Podman,
# or writes anywhere outside its own temporary directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/g5-ceremony.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
# The published context is 0550 and its members 0440 -- deliberately not
# writable even by their owner -- so cleanup has to restore write first.
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
BUILD_CONTEXT_ABS="$(read_pin BUILD_CONTEXT)"
STAGING_ABS="$(read_pin BUILD_CONTEXT_STAGING)"
EXECUTION_USER="$(read_pin EXECUTION_USER)"
EXECUTION_GROUP="$(read_pin EXECUTION_GROUP)"
COORDINATOR="$(read_pin COORDINATOR)"
BUILD_TAG="$(read_pin BUILD_TAG)"
DIR_MODE="$(read_pin BUILD_CONTEXT_DIR_MODE)"
COMMIT="$(git -C "${REPOSITORY}" rev-parse HEAD)"
[[ -n "${BUILD_CONTEXT_ABS}" && -n "${STAGING_ABS}" ]] || {
  printf 'the ceremony pins no build-context paths\n' >&2; exit 1; }

# The sudoers path is last: the provisioning suite bans that literal followed
# by a space, so that no test can be reading it as a command argument.
PRODUCTION_PATHS=(/run/kyri /var/lib/kyri /usr/lib/kyri/python /etc/sudoers.d/kyri-exec)
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
    entry = [info.st_mode, info.st_uid, info.st_gid]
    if os.path.isdir(path) and not os.path.islink(path):
        names = hashlib.sha256()
        for base, directories, files in os.walk(path):
            directories.sort()
            for name in sorted(directories) + sorted(files):
                names.update(os.path.join(base, name).encode("utf-8"))
        entry.append(names.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# A fixture host: /run/kyri as the ruled root:root 0755, with the sibling
# execution-material present so the suite can prove it is left alone.
build_fixture() {
  local root="$1"
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  rm -rf "${root}"
  mkdir -p "${root}/run/kyri/execution-material" "${root}/usr/lib/kyri/python" \
           "${root}/var/lib/kyri" "${root}/etc/sudoers.d" "${root}/root" "${root}/tmp"
  chmod 0755 "${root}/run/kyri"
  chmod 0770 "${root}/run/kyri/execution-material"
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1
}

context_of() { printf '%s' "$1${BUILD_CONTEXT_ABS}"; }

# ===========================================================================
# 1. the invariant that caused the failure, asserted the other way round
# ===========================================================================
mode="$(stat -c '%a' "${REPOSITORY}")"
if (( (8#${mode} & 8#0001) == 0 )); then
  pass "the checkout is mode ${mode}: ${EXECUTION_USER} still cannot traverse it"
else
  fail "the checkout is mode ${mode}: world-traversable, so somebody opened it to the execution identity"
fi
if id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n' | grep -qx "${EXECUTION_GROUP}"; then
  fail "${COORDINATOR} is a member of ${EXECUTION_GROUP}: the split was weakened"
else
  pass "${COORDINATOR} is not a member of ${EXECUTION_GROUP}"
fi

# ===========================================================================
# 2. the corrected build command names no checkout path
# ===========================================================================
root="${WORK}/plan"; build_fixture "${root}"
if ( cd "${REPOSITORY}" && bash "${CEREMONY}" --print-production-build ) \
     > "${root}/last-run.log" 2>&1; then
  # The command block only: the prose below it explains the original failure
  # and necessarily names the checkout to do so.
  command_block="$(sed -n '/podman build/,/podman image inspect/p' "${root}/last-run.log")"
  if grep -q "${REPOSITORY}" <<<"${command_block}"; then
    fail "the production build command still names the checkout"
  else
    pass "the production build command names no checkout path"
  fi
  grep -q 'cd /tmp' "${root}/last-run.log" \
    && pass "the command runs from a cwd the execution identity can traverse" \
    || fail "the command does not move off the inherited working directory"
  grep -qF -- "--file ${BUILD_CONTEXT_ABS}/Containerfile" "${root}/last-run.log" \
    && grep -qF -- "runuser -u ${EXECUTION_USER}" "${root}/last-run.log" \
    && pass "the build reads the root-owned context and runs as the execution identity" \
    || fail "the build command is not scoped to the context and identity"
  grep -q 'Permission denied' "${root}/last-run.log" \
    && pass "the command records why cd /tmp is there, so the trap is not re-set" \
    || fail "the reason for the safe cwd is not recorded"
  # Selection is by tag at build time and by exact .Id thereafter; the tag must
  # be the reviewed one and must never be what authority is derived from.
  grep -qF -- "--tag ${BUILD_TAG}" "${root}/last-run.log" \
    && grep -qF "podman image inspect --format '{{.Id}}' ${BUILD_TAG}" "${root}/last-run.log" \
    && pass "the build tags the reviewed name and immediately captures the immutable .Id" \
    || fail "the build does not capture the local .Id from the reviewed tag"
else
  fail "--print-production-build failed"
fi
# The whole point is that no checkout path survives into the build phase.
if sed -n '/^print_production_build()/,/^}/p' "${CEREMONY}" | grep -q 'REPOSITORY}/provisioning/image'; then
  fail "the build phase still refers to the checkout image directory"
else
  pass "the build phase refers to no checkout image directory"
fi

# ===========================================================================
# 3. materialisation from pinned git objects
# ===========================================================================
root="${WORK}/materialise"; build_fixture "${root}"
if run_ceremony "${root}" --verify-build-context --commit "${COMMIT}"; then
  pass "--verify-build-context reports an absent context as eligible"
else
  fail "eligibility was refused on a clean fixture: $(tail -6 "${root}/last-run.log")"
fi
[[ -e "$(context_of "${root}")" ]] \
  && fail "a verification phase created the context" \
  || pass "no verification phase created the context"

if run_ceremony "${root}" --materialise-build-context --commit "${COMMIT}"; then
  pass "--materialise-build-context publishes the context"
else
  fail "materialisation failed: $(tail -8 "${root}/last-run.log")"
fi
if cmp -s <(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:provisioning/image/Containerfile") \
          "$(context_of "${root}")/Containerfile"; then
  pass "the published Containerfile is byte-identical to the pinned git object"
else
  fail "the published Containerfile is not the pinned object"
fi
[[ "$(stat -c '%a' "$(context_of "${root}")")" == "${DIR_MODE}" ]] \
  && pass "the context directory is 0${DIR_MODE}: readable and traversable, writable by nobody" \
  || fail "the context directory is mode $(stat -c '%a' "$(context_of "${root}")")"
[[ "$(stat -c '%a' "$(context_of "${root}")/Containerfile")" == "440" ]] \
  && pass "the context member is 0440: writable by nobody, not even its owner" \
  || fail "the context member has the wrong mode"
[[ ! -e "${root}${STAGING_ABS}" ]] \
  && pass "no staging residue survives a successful materialisation" \
  || fail "staging residue remains"
[[ -d "${root}/run/kyri/execution-material" ]] \
  && pass "the sibling execution-material root was not disturbed" \
  || fail "execution-material was disturbed"
if run_ceremony "${root}" --verify-materialised-build-context; then
  pass "--verify-materialised-build-context accepts the published context"
else
  fail "the published context was rejected: $(tail -8 "${root}/last-run.log")"
fi

# Create-once. An existing context is an operator's problem, not something to
# overwrite on the way past.
if run_ceremony "${root}" --materialise-build-context --commit "${COMMIT}"; then
  fail "materialisation overwrote an existing context"
else
  grep -q "create-once" "${root}/last-run.log" \
    && pass "an existing context is refused create-once, for operator disposition" \
    || fail "an existing context was refused for the wrong reason"
fi

# Interrupted staging is residue an operator disposes of; it is never adopted.
root="${WORK}/staging"; build_fixture "${root}"
mkdir -p "${root}${STAGING_ABS}"
if run_ceremony "${root}" --verify-build-context --commit "${COMMIT}"; then
  fail "staging residue was ignored"
else
  grep -q "interrupted" "${root}/last-run.log" \
    && pass "staging residue fails closed rather than being adopted or deleted" \
    || fail "staging residue refused for the wrong reason"
fi
[[ -d "${root}${STAGING_ABS}" ]] \
  && pass "the residue was left in place for disposition, not silently removed" \
  || fail "the residue was deleted"

# ===========================================================================
# 4. the hostile working tree
# ===========================================================================
# The property: materialisation reads git OBJECTS, never working-tree files.
# Proven by pointing a copy of the ceremony at a throwaway clone whose working
# tree has been poisoned, and requiring the pinned bytes to win. The live
# checkout is never modified.
clone="${WORK}/clone"
git -C "${REPOSITORY}" worktree list >/dev/null 2>&1 || true
git clone --quiet --no-hardlinks --shared "${REPOSITORY}" "${clone}" 2>/dev/null \
  || git clone --quiet "${REPOSITORY}" "${clone}"
BRANCH="$(git -C "${REPOSITORY}" rev-parse --abbrev-ref HEAD)"
# The ceremony requires the reviewed branch, so the clone carries it too;
# a detached checkout would be refused before the property under test.
git -C "${clone}" checkout --quiet -B "${BRANCH}" "${COMMIT}" 2>/dev/null
chmod 0750 "${clone}"
SENTINEL="HOSTILE-WORKING-TREE-BYTES-MUST-NEVER-BUILD"
printf '\n# %s\nRUN echo owned\n' "${SENTINEL}" >> "${clone}/provisioning/image/Containerfile"
hostile="${WORK}/hostile-ceremony.sh"
python3 - "${CEREMONY}" "${hostile}" "${clone}" <<'REPOINT'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
old = 'REPOSITORY="/opt/schott-platform"'
if source.count(old) != 1:
    raise SystemExit("the ceremony no longer pins REPOSITORY once")
pathlib.Path(sys.argv[2]).write_text(
    source.replace(old, 'REPOSITORY="%s"' % sys.argv[3], 1))
REPOINT
if grep -q "${SENTINEL}" "${clone}/provisioning/image/Containerfile"; then
  pass "the fixture working tree really is poisoned"
else
  fail "the poisoning did not take: the case would prove nothing"
fi
root="${WORK}/hostiletree"; build_fixture "${root}"
if ( cd "${clone}" && bash "${hostile}" --fixture "${root}" \
       --materialise-build-context --commit "${COMMIT}" ) \
     > "${root}/hostile.log" 2>&1; then
  if grep -q "${SENTINEL}" "$(context_of "${root}")/Containerfile"; then
    fail "the hostile working-tree bytes reached the build context"
  elif cmp -s <(git -C "${REPOSITORY}" cat-file blob "${COMMIT}:provisioning/image/Containerfile") \
              "$(context_of "${root}")/Containerfile"; then
    pass "a poisoned working tree is ignored: the context holds the pinned object bytes"
  else
    fail "the context is neither the sentinel nor the pinned object"
  fi
else
  fail "materialisation from a poisoned tree failed outright: $(tail -6 "${root}/hostile.log")"
fi
# Structural, alongside the empirical: nothing reads a working-tree path.
if sed -n '/^materialise_build_context()/,/^}/p' "${CEREMONY}" \
   | grep -qE '(cp|cat|install)[^|]*\$\{REPOSITORY\}'; then
  fail "materialisation reads a working-tree file"
else
  pass "materialisation opens no working-tree file: bytes come from cat-file blob"
fi

# A pinned digest that does not match the object must refuse before publishing.
wrong="${WORK}/wrong-ceremony.sh"
python3 - "${CEREMONY}" "${wrong}" <<'BREAK'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
new, count = re.subn(r'\|f543c458[0-9a-f]{56}\|', '|' + 'a' * 64 + '|', source)
if count != 1:
    raise SystemExit("the pinned context digest is no longer a single literal")
pathlib.Path(sys.argv[2]).write_text(new)
BREAK
root="${WORK}/wrongdigest"; build_fixture "${root}"
if ( cd "${REPOSITORY}" && bash "${wrong}" --fixture "${root}" \
       --materialise-build-context --commit "${COMMIT}" ) > "${root}/w.log" 2>&1; then
  fail "a context member whose digest does not match the pin was published"
else
  [[ ! -e "$(context_of "${root}")" ]] \
    && pass "a digest mismatch refuses and publishes nothing" \
    || fail "a digest mismatch still published a context"
fi

# ===========================================================================
# 5. the published context: extra, missing, and special members
# ===========================================================================
prepare_published() {
  local root="$1"; build_fixture "${root}"
  run_ceremony "${root}" --materialise-build-context --commit "${COMMIT}" >/dev/null 2>&1
  chmod u+w "$(context_of "${root}")"
}

root="${WORK}/extra"; prepare_published "${root}"
printf 'not reviewed\n' > "$(context_of "${root}")/extra.txt"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "an extra context member was accepted" \
  || pass "an extra context member is refused"

root="${WORK}/missing"; prepare_published "${root}"
chmod u+w "$(context_of "${root}")/Containerfile"; rm -f "$(context_of "${root}")/Containerfile"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "a missing context member was accepted" \
  || pass "a missing context member is refused"

root="${WORK}/symlink"; prepare_published "${root}"
ln -s /etc/passwd "$(context_of "${root}")/link"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "a symlink in the context was accepted" \
  || pass "a symlink in the context is refused"

root="${WORK}/fifo"; prepare_published "${root}"
mkfifo "$(context_of "${root}")/pipe"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "a FIFO in the context was accepted" \
  || pass "a FIFO in the context is refused"

root="${WORK}/writable"; prepare_published "${root}"
chmod 0770 "$(context_of "${root}")"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "a group-writable context was accepted" \
  || pass "a group- or other-writable context is refused"

root="${WORK}/tampered"; prepare_published "${root}"
chmod u+w "$(context_of "${root}")/Containerfile"
printf '\nRUN echo tampered\n' >> "$(context_of "${root}")/Containerfile"
run_ceremony "${root}" --verify-materialised-build-context \
  && fail "a tampered Containerfile was accepted" \
  || pass "a member whose bytes changed after publication is refused"

# ===========================================================================
# 6. the manifest cannot silently become incomplete
# ===========================================================================
# One member is only the whole context while the definition copies nothing in.
copying="${WORK}/copying"
mkdir -p "${copying}"
if git -C "${REPOSITORY}" cat-file blob "${COMMIT}:provisioning/image/Containerfile" \
     | grep -qE '^[[:space:]]*(COPY|ADD)[[:space:]]'; then
  fail "the Containerfile copies files in but the context manifest has one member"
else
  pass "the Containerfile carries no COPY or ADD: one member is the whole context"
fi
if grep -q 'the one-member build-context manifest is incomplete' "${CEREMONY}"; then
  pass "a future COPY is required to refuse rather than silently build without its inputs"
else
  fail "nothing guards the manifest against the definition gaining a COPY"
fi

# ===========================================================================
# 7. phase separation
# ===========================================================================
if sed -n '/^materialise_build_context()/,/^}/p' "${CEREMONY}" \
   | grep -qE '(^|[^-[:alnum:]_])podman|buildah|docker'; then
  fail "materialisation invokes a container runtime"
else
  pass "materialisation invokes no container runtime"
fi
for phase in verify-build-context verify-materialised-build-context print-production-build; do
  root="${WORK}/ro-${phase}"; build_fixture "${root}"
  run_ceremony "${root}" "--${phase}" --commit "${COMMIT}" >/dev/null 2>&1 || true
  if [[ -e "${root}/var/lib/kyri/implementation-authority" \
     || -e "${root}/var/lib/kyri/implementation-authority-control" \
     || -e "${root}/etc/sudoers.d/kyri-exec" ]]; then
    fail "--${phase} created authority or sudoers state"
  fi
done
pass "no build-context phase creates authority state or sudoers"
root="${WORK}/noauth"; build_fixture "${root}"
run_ceremony "${root}" --materialise-build-context --commit "${COMMIT}" >/dev/null 2>&1 || true
if [[ -e "${root}/var/lib/kyri/implementation-authority" ]]; then
  fail "materialisation created authority state"
else
  pass "materialisation creates no authority state: building is not admitting"
fi

# ===========================================================================
# 8. Track-B residue grants nothing
# ===========================================================================
root="${WORK}/trackb"; build_fixture "${root}"
run_ceremony "${root}" --print-production-build >/dev/null 2>&1 || true
if grep -q 'TRACK-B RESIDUE' "${root}/last-run.log" \
   && grep -q 'exact local .Id' "${root}/last-run.log"; then
  pass "the procedure records that Track-B residue grants nothing and selection is by exact .Id"
else
  fail "the procedure does not state how the production image is selected"
fi
if grep -qi 'building is not admitting' "${root}/last-run.log"; then
  pass "the procedure states that building is not admitting"
else
  fail "the build/admission separation is not stated"
fi

# ===========================================================================
# 9. registration, and the host is untouched
# ===========================================================================
name="tests/test-capability-execution-g5-build-context.sh"
grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
  && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml" \
  && pass "the suite runs in local validation and in CI" \
  || fail "the suite is not registered in local validation and CI"
grep -q 'g5-build-context' "${REPOSITORY}/provisioning/execution/README.md" \
  && pass "the runbook documents the build context" \
  || fail "the runbook does not document the build context"

# The operator has since materialised the production context, which is the
# ceremony working. What this suite owes is that IT did not create one, and the
# production-path snapshot below is what proves that. If a context exists it
# must be the ruled shape -- readable by the execution group, writable by none.
if [[ -e "${BUILD_CONTEXT_ABS}" ]]; then
  observed="$(stat -c '%U:%G %a' "${BUILD_CONTEXT_ABS}")"
  [[ "${observed}" == "root:${EXECUTION_GROUP} ${DIR_MODE}" ]] \
    && pass "the production build context exists and is exactly root:${EXECUTION_GROUP} 0${DIR_MODE}" \
    || fail "the production build context is ${observed}, expected root:${EXECUTION_GROUP} 0${DIR_MODE}"
else
  pass "no production build context exists on this host"
fi
# G3 stays a separate gate and its marker must still be absent. The authority
# namespace legitimately exists once an operator has admitted an implementation
# -- G5 is admitted, not closed -- so what this suite owes is that it created
# nothing there.
if [[ -e "/etc/sudoers.d/kyri-exec" ]]; then
  fail "a sudoers policy exists on this host: G3 is not closed"
fi
for namespace in /var/lib/kyri/implementation-authority \
                 /var/lib/kyri/implementation-authority-control; do
  if [[ -e "${namespace}" ]]; then
    [[ "$(stat -c '%U' "${namespace}")" == "root" && ! -w "${namespace}" ]] \
      || fail "${namespace} is not root-owned and unwritable here"
  fi
done
pass "no sudoers policy, and the authority namespace is root-owned and untouched by this suite"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated while this suite ran"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 build-context validation passed.\n'
else
  printf 'G5 build-context validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
