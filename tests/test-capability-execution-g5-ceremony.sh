#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the G5 operator ceremony.
#
# ISOLATED BY CONSTRUCTION. Every behavioural case runs the ceremony with
# --fixture against a throwaway tree. Nothing here builds an image, creates a
# production authority root, runs genesis, allocates an identifier, admits an
# implementation, writes sudoers, or invokes Podman, the transition, or the
# worker.
#
# WHAT IS PROVEN. The trust boundary the ceremony rests on: root executes only
# bytes materialised from pinned git objects and verified against a pinned
# manifest digest, and the coordinator's working tree, PYTHONPATH, PYTHONHOME,
# working directory, and bytecode caches cannot reach the interpreter. Each of
# those is demonstrated by attacking it, not by asserting it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/g5-ceremony.sh"
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

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
MANIFEST_DIGEST="$(read_pin MANIFEST_DIGEST)"
MANIFEST_ENTRIES="$(sed -n 's/^MANIFEST_ENTRIES=\([0-9]*\)$/\1/p' "${CEREMONY}" | head -1)"
BASE_REPOSITORY="$(read_pin BASE_REPOSITORY)"
SUPPLY="${REPOSITORY}/provisioning/execution/g5-supply-chain.sh"
supply_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${SUPPLY}" | head -1; }
PREDICATE_TYPE="$(supply_pin PREDICATE_TYPE)"
COSIGN_VERSION="$(supply_pin COSIGN_VERSION)"
COSIGN_BINARY_SHA256="$(supply_pin COSIGN_BINARY_SHA256)"
CHAINGUARD_IDENTITY="$(supply_pin CHAINGUARD_IDENTITY)"
MANIFEST_DIGEST_CANDIDATE="$(supply_pin CANDIDATE_MANIFEST_DIGEST)"
CONFIG_DIGEST_CANDIDATE="$(supply_pin CANDIDATE_CONFIG_DIGEST)"
[[ "${MANIFEST_DIGEST}" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'the ceremony pins no manifest digest\n' >&2; exit 1; }

# The commit under test. The ceremony deliberately refuses to infer this: a
# production run names the reviewed commit explicitly. A suite may use HEAD,
# because HEAD in a test run IS the revision being validated.
COMMIT="$(git -C "${REPOSITORY}" rev-parse HEAD)"

# ===========================================================================
# Fixture-only guard
# ===========================================================================
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /etc/sudoers.d/kyri-exec
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
        entry.append(manifest.hexdigest())
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# A fixture host at the ruled G5 starting position: generation 6 installed, no
# authority state, no sudoers. Built from pinned git objects.
build_fixture() {
  local root="$1" file
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python" "${root}/usr/libexec" \
           "${root}/var/lib/kyri" "${root}/etc/sudoers.d" "${root}/root"
  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${file}" \
      > "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__')
  local flattened
  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py; do
    git -C "${REPOSITORY}" cat-file blob "${COMMIT}:provisioning/execution/${flattened%%:*}.py" \
      > "${root}/usr/lib/kyri/python/${flattened##*:}"
  done
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1
}

# ===========================================================================
# 1. read-only phases accept the ruled starting position and mutate nothing
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if run_ceremony "${clean}" --verify-host; then
  pass "--verify-host accepts the ruled G5 starting position"
else
  fail "--verify-host rejected a valid fixture: $(tail -8 "${clean}/last-run.log")"
fi
if run_ceremony "${clean}" --verify-authority-prerequisites \
   && grep -q "root:cschott 2750" "${clean}/last-run.log" \
   && grep -q "root:root 700" "${clean}/last-run.log"; then
  pass "--verify-authority-prerequisites states the ruled setgid layout"
else
  fail "--verify-authority-prerequisites did not state the ruled layout"
fi
for absent in var/lib/kyri/implementation-authority var/lib/kyri/implementation-authority-control; do
  [[ -e "${clean}/${absent}" ]] && fail "a read-only phase created ${absent}"
done
pass "no read-only phase created an authority root"

# ===========================================================================
# 2. materialisation from pinned git objects
# ===========================================================================
root="${WORK}/materialise"; build_fixture "${root}"
if run_ceremony "${root}" --verify-source --commit "${COMMIT}"; then
  if grep -q "matches the pinned digest (${MANIFEST_ENTRIES} objects" "${root}/last-run.log" \
     && grep -q "resolves inside the root-owned tree" "${root}/last-run.log"; then
    pass "--verify-source materialises ${MANIFEST_ENTRIES} pinned objects and imports only from them"
  else
    fail "--verify-source did not report the pinned manifest: $(tail -8 "${root}/last-run.log")"
  fi
else
  fail "--verify-source failed: $(tail -12 "${root}/last-run.log")"
fi
# The root-owned tree is removed only after the phase completes.
if find "${root}/root" -maxdepth 1 -name 'kyri-g5-ceremony-*' | grep -q .; then
  fail "the materialised tree survived a completed phase"
else
  pass "the materialised tree is removed once the operator phase is complete"
fi

# The ceremony must refuse to infer the commit.
root="${WORK}/nocommit"; build_fixture "${root}"
if run_ceremony "${root}" --verify-source; then
  fail "--verify-source ran without an explicit --commit"
else
  if grep -q "requires --commit" "${root}/last-run.log"; then
    pass "the ceremony refuses to trust HEAD and requires an explicit reviewed commit"
  else
    fail "missing --commit refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
fi

# A commit whose operator package is not the reviewed one must fail the digest
# gate, even though it is a perfectly valid ancestor of HEAD.
#
# The commit is SEARCHED FOR, not assumed to be HEAD~1. It was HEAD~1 once and
# the case silently stopped testing anything the moment a commit landed that
# touched only docs and tests: HEAD~1's manifest was then identical to the pin,
# so the gate had nothing to refuse and passed for the wrong reason.
manifest_at() {
  local commit="$1" file
  git -C "${REPOSITORY}" ls-tree -r --name-only "${commit}" \
      -- tools/__init__.py tools/capability tools/common tools/provisioning \
    | grep '\.py$' | grep -v '__pycache__' | LC_ALL=C sort \
    | while IFS= read -r file; do
        printf '%s  %s\n' \
          "$(git -C "${REPOSITORY}" cat-file blob "${commit}:${file}" | sha256sum | cut -d' ' -f1)" \
          "${file}"
      done | sha256sum | cut -d' ' -f1
}

OLD_COMMIT=""
while IFS= read -r candidate; do
  [[ "${candidate}" != "${COMMIT}" ]] || continue
  if [[ "$(manifest_at "${candidate}")" != "${MANIFEST_DIGEST}" ]]; then
    OLD_COMMIT="${candidate}"; break
  fi
done < <(git -C "${REPOSITORY}" rev-list --max-count=40 HEAD)

if [[ -z "${OLD_COMMIT}" ]]; then
  fail "no ancestor within 40 commits carries a different operator package; the gate is untested"
else
  root="${WORK}/wrongcommit"; build_fixture "${root}"
  if run_ceremony "${root}" --verify-source --commit "${OLD_COMMIT}"; then
    fail "an unreviewed commit passed the manifest gate"
  elif grep -q "manifest at ${OLD_COMMIT} is" "${root}/last-run.log"; then
    pass "a valid ancestor whose operator package differs fails the pinned manifest digest"
  else
    fail "wrong commit refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
fi

# ===========================================================================
# 3. the isolation properties, proven by attacking them
# ===========================================================================
root="${WORK}/isolation"; build_fixture "${root}"

# A decoy that impersonates the operator package. If any of PYTHONPATH, the
# working directory, or a bytecode cache could reach the interpreter, this is
# what would be imported instead of the pinned object.
decoy="${WORK}/decoy"
mkdir -p "${decoy}/tools/provisioning" "${decoy}/tools/capability/execution" \
         "${decoy}/tools/provisioning/__pycache__"
printf 'HOSTILE_SENTINEL = "WORKING-TREE-CODE-EXECUTED"\nraise SystemExit("hostile module imported")\n' \
  > "${decoy}/tools/provisioning/authority_bootstrap.py"
printf '' > "${decoy}/tools/__init__.py"
printf '' > "${decoy}/tools/provisioning/__init__.py"
# A bytecode cache is the specific thing -B and PYTHONDONTWRITEBYTECODE do not
# protect against: they stop root writing one, never reading one.
python3 - "${decoy}" <<'PY'
import compileall, pathlib, sys
compileall.compile_dir(str(pathlib.Path(sys.argv[1]) / "tools"), quiet=2)
PY

if ( cd "${decoy}" && PYTHONPATH="${decoy}" PYTHONHOME="/nonexistent" \
     bash "${CEREMONY}" --fixture "${root}" --verify-materialisation --commit "${COMMIT}" ) \
     > "${root}/isolation.log" 2>&1; then
  if grep -q "PYTHONPATH and PYTHONHOME dropped, no cwd import, no checkout on sys.path" \
       "${root}/isolation.log" \
     && ! grep -q "HOSTILE_SENTINEL\|hostile module imported\|WORKING-TREE-CODE-EXECUTED" \
       "${root}/isolation.log"; then
    pass "a hostile decoy on PYTHONPATH, in the working directory, and in a bytecode cache is never imported"
  else
    fail "isolation reported wrongly: $(tail -10 "${root}/isolation.log")"
  fi
else
  fail "--verify-materialisation failed under attack: $(tail -12 "${root}/isolation.log")"
fi

# The decoy really would win without the isolation, or the case above proves
# nothing. Demonstrated against a plain interpreter.
if ( cd "${decoy}" && python3 -c "import tools.provisioning.authority_bootstrap" ) \
     > "${root}/decoy-control.log" 2>&1; then
  fail "the hostile decoy did not even load: the attack case is vacuous"
else
  if grep -q "hostile module imported" "${root}/decoy-control.log"; then
    pass "control arm: the same decoy IS imported by an unisolated interpreter"
  else
    fail "the decoy failed for the wrong reason: $(tail -3 "${root}/decoy-control.log")"
  fi
fi

# ===========================================================================
# 4. structural properties of the materialiser
# ===========================================================================
# Bytes come from git objects, never from working-tree files.
materialiser="$(sed -n '/^build_manifest()/,/^}/p;/^materialise()/,/^}/p' "${CEREMONY}")"
if printf '%s' "${materialiser}" | grep -qE 'cat-file blob "\$\{COMMIT\}:'; then
  pass "the materialiser reads bytes from pinned git objects"
else
  fail "the materialiser does not read from git objects"
fi
# The one construct that would reintroduce the working tree.
# shellcheck disable=SC2016
if printf '%s' "${materialiser}" | grep -qE '(cp|cat|install)[^|]*\$\{REPOSITORY\}/\$\{?path'; then
  fail "the materialiser copies a working-tree file"
else
  pass "the materialiser never opens a working-tree source file"
fi
# It may be NAMED in the header, which explains why it is not used; what must
# be absent is an invocation.
if grep -qE '^[^#]*git archive' "${CEREMONY}"; then
  fail "the materialiser invokes git archive, whose output is attribute-filtered"
else
  pass "the materialiser does not invoke git archive"
fi
# Git never runs as root.
# shellcheck disable=SC2016
if grep -qF 'runuser -u "${REPO_OWNER}" -- /usr/bin/git' "${CEREMONY}"; then
  pass "git runs as the repository owner, never as root inside a coordinator-controlled repository"
else
  fail "the ceremony may run git as root"
fi
# Isolation flags, asserted as the exact reviewed invocation.
# shellcheck disable=SC2016
if grep -qF '/usr/bin/env -i' "${CEREMONY}" \
   && grep -qF '/usr/bin/python3 -I -B -c' "${CEREMONY}" \
   && grep -qF 'PYTHONDONTWRITEBYTECODE=1' "${CEREMONY}"; then
  pass "the interpreter is invoked with env -i, -I, -B and PYTHONDONTWRITEBYTECODE"
else
  fail "the reviewed isolated invocation changed"
fi
# Path safety, asserted as the exact reviewed guards.
guards_missing=0
while IFS= read -r guard; do
  grep -qF -- "${guard}" "${CEREMONY}" || {
    fail "the path guard is missing: ${guard}"; guards_missing=$((guards_missing + 1)); }
done <<'GUARDS'
[[ "${path}" == tools/* ]] || return 1
[[ "${path}" == *.py ]] || return 1
[[ "${path}" != *".."* ]] || return 1
[[ "${path}" != /* ]] || return 1
GUARDS
(( guards_missing == 0 )) \
  && pass "materialised paths are constrained to tools/*.py and reject traversal and absolute paths"
# Non-regular objects, writability, and bytecode are all refused.
tree_missing=0
while IFS= read -r guard; do
  grep -qF -- "${guard}" "${CEREMONY}" || {
    fail "the materialised-tree guard is missing: ${guard}"; tree_missing=$((tree_missing + 1)); }
done <<'TREEGUARDS'
! -type d ! -type f
-perm /022
-name '__pycache__'
umask 077
TREEGUARDS
(( tree_missing == 0 )) \
  && pass "the materialised tree refuses symlinks, writable objects, and bytecode"
# Verification happens after the bytes are in root-owned space.
if grep -q 'Verified AFTER the bytes are in root-owned' "${CEREMONY}"; then
  pass "manifest verification runs after materialisation, inside the 0700 tree"
else
  fail "the verify-after-materialisation ordering is not documented as reviewed"
fi

# ===========================================================================
# 5. base approval: candidate is not approval
# ===========================================================================
root="${WORK}/nobase"; build_fixture "${root}"
if run_ceremony "${root}" --verify-build-inputs \
   && grep -q "BASE IMAGE NOT APPROVED" "${root}/last-run.log"; then
  pass "with no approval recorded, the production build is reported ineligible"
else
  fail "an unapproved base was not reported: $(tail -6 "${root}/last-run.log")"
fi

# The approval SCHEMA belongs to the supply-chain tooling and is exercised
# field by field there. What the ceremony owes is delegation: it must consult
# that one definition rather than carrying a second, looser copy.
write_approval() {
  local root="$1" reference="$2"
  cat > "${root}/root/kyri-g5-approved-base.txt" <<EOF
base_image_reference=${reference}
platform=linux/amd64
manifest_digest=sha256:${MANIFEST_DIGEST_CANDIDATE}
config_digest=sha256:${CONFIG_DIGEST_CANDIDATE}
sbom_source=decoded DSSE payload, in-toto Statement v0.1, predicateType ${PREDICATE_TYPE}
sbom_sha256=$(printf 'd%.0s' {1..64})
cosign_version=${COSIGN_VERSION}
cosign_sha256=${COSIGN_BINARY_SHA256}
attestation_predicate_type=${PREDICATE_TYPE}
attestation_signer=${CHAINGUARD_IDENTITY}
approved_by=cschott
approved_at=2026-08-14T12:30:00Z
EOF
}

root="${WORK}/floatingbase"; build_fixture "${root}"
write_approval "${root}" "${BASE_REPOSITORY}:latest"
if run_ceremony "${root}" --verify-build-inputs; then
  fail "a floating tag was accepted as an approved base"
else
  if grep -q "not a digest-pinned" "${root}/last-run.log"; then
    pass "a tag can never be an approved production base"
  else
    fail "a floating base refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

root="${WORK}/nosbom"; build_fixture "${root}"
write_approval "${root}" "${BASE_REPOSITORY}@sha256:${MANIFEST_DIGEST_CANDIDATE}"
grep -v '^sbom_source=' "${root}/root/kyri-g5-approved-base.txt" > "${root}/tmp"
mv "${root}/tmp" "${root}/root/kyri-g5-approved-base.txt"
if run_ceremony "${root}" --verify-build-inputs; then
  fail "an approval without a named SBOM source was accepted"
else
  if grep -q "missing sbom_source" "${root}/last-run.log"; then
    pass "an approval must name the exact bytes whose SHA-256 becomes sbom_sha256"
  else
    fail "missing sbom_source refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

root="${WORK}/goodbase"; build_fixture "${root}"
write_approval "${root}" "${BASE_REPOSITORY}@sha256:${MANIFEST_DIGEST_CANDIDATE}"
if run_ceremony "${root}" --verify-build-inputs \
   && grep -q "the production base approval verifies" "${root}/last-run.log"; then
  pass "a complete approval verifies through the single supply-chain definition"
else
  fail "a valid approval was rejected: $(tail -8 "${root}/last-run.log")"
fi
# The index must never be accepted as the build base: the attestation subject
# is the child, and approving the index would hand the builder a platform the
# signature never covered.
root="${WORK}/indexbase"; build_fixture "${root}"
write_approval "${root}" "${BASE_REPOSITORY}@sha256:$(supply_pin CANDIDATE_INDEX_DIGEST)"
if run_ceremony "${root}" --verify-build-inputs; then
  fail "the multi-arch index was accepted as the approved build base"
else
  pass "the index is refused as a build base: only the verified child manifest qualifies"
fi

# Delegation, not duplication: a second copy of the schema here would drift.
if grep -q 'g5-supply-chain.sh' "${CEREMONY}" \
   && ! grep -q 'attestation_signer' "${CEREMONY}"; then
  pass "the ceremony delegates the approval schema instead of restating it"
else
  fail "the ceremony carries its own copy of the approval schema"
fi

# ===========================================================================
# 6. mutation phases refuse, and nothing chains
# ===========================================================================
# Eligibility is derived from ruled evidence, and the authority suite owns the
# detail of that derivation. What this suite requires is the invariant: with no
# evidence in the fixture, no mutation phase proceeds and none creates anything.
for phase in bootstrap-authority genesis admit; do
  root="${WORK}/mut-${phase}"; build_fixture "${root}"
  run_ceremony "${root}" "--${phase}" --commit "${COMMIT}" \
    && fail "--${phase} ran with no approval and no evidence"
  for created in var/lib/kyri/implementation-authority var/lib/kyri/implementation-authority-control; do
    [[ -e "${root}/${created}" ]] && fail "--${phase} created ${created}"
  done
done
pass "no mutation phase proceeds or creates an authority root while ineligible"
# The gate must be evidence-derived, never a build-time constant an operator
# cannot satisfy by doing the work.
if grep -q 'mutation phases are not enabled in this build' "${CEREMONY}"; then
  fail "the mutation gate is a build-time refusal"
else
  pass "the mutation gate is not a build-time refusal"
fi

# A verification phase must never run a mutation phase.
if grep -qE '^--verify[a-z-]*\).*(bootstrap_authority|run_genesis|run_admit)' "${CEREMONY}"; then
  fail "a verification mode dispatches into a mutation phase"
else
  pass "no verification mode chains into a mutation phase"
fi

# ===========================================================================
# 7. nothing here starts a container, a transition, or a worker
# ===========================================================================
mutations=0
for forbidden in 'podman (build|run|create|start|pull|load)' 'buildah' \
                 'docker (build|run)' 'kyri-exec-transition[[:space:]]+CINV' \
                 'kyri-exec-worker\.py[[:space:]]+CINV'; do
  # The printed procedures quote the build command for the operator to read;
  # what must be absent is an executable occurrence, so those heredocs are
  # excluded and everything else is searched.
  if sed -e '/^print_plan()/,/^}/d' -e '/^print_production_build()/,/^}/d' \
       "${CEREMONY}" | grep -qE "${forbidden}"; then
    fail "the ceremony executes: ${forbidden}"
    mutations=$((mutations + 1))
  fi
done
(( mutations == 0 )) && pass "outside the printed plan the ceremony starts no container, transition, or worker"

# Checked against the RENDERED output: identities are variables in the source,
# and what the operator will read is what matters. The build command now lives
# in its own phase -- the context has to exist before the build can run at all
# -- and the build-context suite owns its detail.
root="${WORK}/plan"; build_fixture "${root}"
if run_ceremony "${root}" --print-production-build \
   && grep -q 'runuser -u kyri-capability' "${root}/last-run.log" \
   && grep -q 'HOME=/data/kyri/capability' "${root}/last-run.log" \
   && grep -q 'XDG_RUNTIME_DIR=/run/user/999' "${root}/last-run.log"; then
  pass "the documented build runs as the execution identity"
else
  fail "the documented build command is not scoped to the execution identity"
fi
if run_ceremony "${root}" --print-plan \
   && grep -q 'PHASE 4 -- BUILD CONTEXT' "${root}/last-run.log" \
   && grep -q 'PHASE 5 -- PRODUCTION BUILD' "${root}/last-run.log"; then
  pass "the plan puts build-context materialisation before the build, as its own phase"
else
  fail "the plan does not separate build-context materialisation from the build"
fi
if grep -q 'CANDIDATE, never an' "${root}/last-run.log" \
   && grep -q 'OPERATOR REVIEW' "${root}/last-run.log"; then
  pass "the plan separates candidate discovery from approval with an explicit review"
else
  fail "the plan does not separate candidate discovery from approval"
fi

# ===========================================================================
# 8. bootstrap trust boundary is documented and bounded
# ===========================================================================
root="${WORK}/boot"; build_fixture "${root}"
if run_ceremony "${root}" --bootstrap-instructions; then
  missing=0
  for required in "cat-file blob" "0700" "sha256sum" "SHA-1 preimage" \
                  "Exactly one coordinator-authored artefact"; do
    grep -qF "${required}" "${root}/last-run.log" || {
      fail "--bootstrap-instructions omits: ${required}"; missing=$((missing + 1)); }
  done
  (( missing == 0 )) && pass "--bootstrap-instructions names the exact pre-boundary surface and bounds it"
else
  fail "--bootstrap-instructions failed"
fi
# The script must not source anything: a sourced file is a second artefact root
# executes before the boundary, and the instructions claim there is only one.
if grep -qE '^[[:space:]]*(source|\.)[[:space:]]+' "${CEREMONY}"; then
  fail "the ceremony sources a file before the trust boundary exists"
else
  pass "the ceremony sources nothing"
fi

# ===========================================================================
# 9. registration and the host is untouched
# ===========================================================================
name="tests/test-capability-execution-g5-ceremony.sh"
if grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the suite runs in local validation and in CI"
else
  fail "the suite is not registered in local validation and CI"
fi
if grep -q 'g5-ceremony.sh' "${REPOSITORY}/provisioning/execution/README.md"; then
  pass "the runbook documents the ceremony"
else
  fail "the runbook does not document the ceremony"
fi

for absent in /var/lib/kyri/implementation-authority \
              /var/lib/kyri/implementation-authority-control \
              /etc/sudoers.d/kyri-exec; do
  [[ -e "${absent}" ]] && fail "G5 state exists on this host: ${absent}"
done
if find /root -maxdepth 1 -name 'kyri-g5-ceremony-*' 2>/dev/null | grep -q .; then
  fail "a materialised ceremony tree exists under /root"
fi
pass "no authority state and no ceremony residue on this host: G5 is closed"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated while this suite ran"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 ceremony validation passed.\n'
else
  printf 'G5 ceremony validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
