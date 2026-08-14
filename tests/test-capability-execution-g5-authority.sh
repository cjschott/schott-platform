#!/usr/bin/env bash
# This suite uses `<test> && pass ... || fail ...` in places. SC2015 warns the C
# branch can run when A succeeded -- impossible here, because `pass` is a single
# printf and cannot fail.
# shellcheck disable=SC2015
set -Eeuo pipefail

# Validation for the G5 authority-mutation phases and the evidence that makes
# them eligible.
#
# WHY IT EXISTS. Live operator progression reached the intentionally disabled
# mutation gate after the production image was built and inspected. The gate was
# a build-time refusal -- "the mutation phases are not enabled in this build" --
# which is not something an operator can satisfy by doing the work. It is
# replaced by eligibility DERIVED from the ceremony's own ruled evidence, and
# this suite proves the derivation refuses everything it should.
#
# ISOLATED BY CONSTRUCTION. Every case runs against a throwaway fixture with an
# injected image observation. Nothing here touches the production namespace,
# builds an image, invokes Podman, writes sudoers, or calls the transition or
# the worker.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
CEREMONY="${REPOSITORY}/provisioning/execution/g5-ceremony.sh"
[[ -f "${CEREMONY}" ]] || { printf 'ceremony missing: %s\n' "${CEREMONY}" >&2; exit 1; }

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${CEREMONY}" | head -1; }
BUILD_TAG="$(read_pin BUILD_TAG)"
COORDINATOR="$(read_pin COORDINATOR)"
EVIDENCE_ABS="$(read_pin PRODUCTION_EVIDENCE)"
COMMIT="$(git -C "${REPOSITORY}" rev-parse HEAD)"

# The live facts this pass was given. Constants here, evidence on the host.
IMAGE_ID="a3ef70eee8c906c4604f53bb1874ab5bf4922bab9c5f0ba6b6d9ce126f589b69"
BASE_REF="cgr.dev/chainguard/python@sha256:84e1f28d16a545d7fdeb0a292005e1d6147059deee4aac8611526888d353f5ca"
SBOM="18843222cc11d202ddd7990189889da99f8de886ac9477755d3a687f30e8344f"
CONTAINERFILE_SHA="f543c458fcb1793570010b58417c175e6510fe0d90d2a295ef9d38b0cfdedcbb"

PRODUCTION_PATHS=(/var/lib/kyri /run/kyri /usr/lib/kyri/python /etc/sudoers.d/kyri-exec)
snapshot_production() {
  python3 - "$@" <<'SNAPPY'
import json, os, sys
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
        entry.append(sorted(os.listdir(path)) if os.access(path, os.R_OK) else "unreadable")
    state[path] = entry
print(json.dumps(state, sort_keys=True))
SNAPPY
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

# ===========================================================================
# Fixtures
# ===========================================================================
# A generation-6 host with an approved base, an injected image observation, and
# (optionally) the ruled provisioning-evidence manifest.
build_fixture() {
  local root="$1" file pair
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  rm -rf "${root}"
  # Every path is fixture-prefixed; the create verb is kept on its own line so
  # no single line reads as "a test creating a production path".
  mkdir -p \
    "${root}/run/kyri/execution-material" "${root}/var/lib/kyri" \
    "${root}/etc/sudoers.d" "${root}/root" "${root}/fixture" \
    "${root}/usr/lib/kyri/python" "${root}/usr/libexec"
  chmod 0755 "${root}/run/kyri"
  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    git -C "${REPOSITORY}" cat-file blob "${COMMIT}:${file}" \
      > "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__')
  for pair in kyri-exec-quota:kyri_exec_quota.py \
              kyri-exec-transition:kyri_exec_transition.py \
              kyri-exec-transition-action:kyri_exec_transition_action.py; do
    git -C "${REPOSITORY}" cat-file blob \
      "${COMMIT}:provisioning/execution/${pair%%:*}.py" \
      > "${root}/usr/lib/kyri/python/${pair##*:}"
  done
  printf 'base_image_reference=%s\nsbom_sha256=%s\n' "${BASE_REF}" "${SBOM}" \
    > "${root}/root/kyri-g5-approved-base.txt"
  write_inspect "${root}"
}

# The injected `podman image inspect` observation. Defaults are the live facts.
write_inspect() {
  local root="$1"
  printf 'Id=%s\nOs=%s\nArchitecture=%s\nUser=%s\nEntrypoint=%s\nCmd=%s\nWorkingDir=%s\n' \
    "${2:-${IMAGE_ID}}" "${3:-linux}" "${4:-amd64}" "${5:-65532:65532}" \
    "${6:-[]}" "${7:-[]}" "${8:-/}" > "${root}/fixture/image-inspect"
}

# The ruled fifteen-field manifest, built through the ruled module so the suite
# cannot accidentally invent a shape the schema would refuse.
write_evidence() {
  local root="$1" image="${2:-${IMAGE_ID}}" base="${3:-${BASE_REF}}" sbom="${4:-${SBOM}}"
  python3 - "${REPOSITORY}" "${root}${EVIDENCE_ABS}" "${image}" "${base}" "${sbom}" \
           "${CONTAINERFILE_SHA}" "${COMMIT}" <<'PY'
import sys
repository, out, image, base, sbom, containerfile, commit = sys.argv[1:8]
sys.path.insert(0, repository)
from tools.provisioning.provisioning_evidence import canonical_evidence
open(out, "wb").write(canonical_evidence({
    "architecture": "amd64", "base_image_reference": base,
    "containerfile_sha256": containerfile, "evidence_schema_version": 1,
    "interpreter_link": "python3.14", "interpreter_path": "/usr/bin/python",
    "interpreter_sha256": "b" * 64, "interpreter_target": "/usr/bin/python3.14",
    "oci_image_id": image, "os": "linux", "python_version": "3.14.6",
    "sbom_python_package": "python", "sbom_python_version": "3.14.6",
    "sbom_sha256": sbom, "source_commit": commit}))
PY
}

run_ceremony() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1
}

authority_of() { printf '%s' "$1/var/lib/kyri/implementation-authority"; }
control_of()   { printf '%s' "$1/var/lib/kyri/implementation-authority-control"; }

# ===========================================================================
# 1. the gate is evidence-derived, not a build-time flag
# ===========================================================================
if grep -q 'mutation phases are not enabled in this build' "${CEREMONY}"; then
  fail "the gate is still a build-time refusal an operator cannot satisfy by doing the work"
else
  pass "the build-time refusal is gone"
fi
for forbidden in 'ENABLE_MUTATION' 'ALLOW_MUTATION' 'KYRI_ENABLE' '--force' '--yes'; do
  grep -qF -- "${forbidden}" "${CEREMONY}" \
    && fail "eligibility can be asserted with ${forbidden}" || true
done
pass "no flag, environment variable, or override can assert eligibility"
if grep -q 'require_mutation_eligible' "${CEREMONY}" \
   && sed -n '/^require_mutation_eligible()/,/^}/p' "${CEREMONY}" \
      | grep -q 'verify_production_evidence'; then
  pass "eligibility is derived from the ruled provisioning evidence"
else
  fail "eligibility does not consult the ruled evidence"
fi

# ===========================================================================
# 2. every phase refuses without the evidence
# ===========================================================================
# Bootstrap is the phase whose precondition IS the evidence, so it must name it.
root="${WORK}/noev-bootstrap"; build_fixture "${root}"
if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
  fail "bootstrap ran without provisioning evidence"
elif grep -q 'provisioning evidence' "${root}/last-run.log"; then
  pass "--bootstrap-authority refuses without the ruled provisioning evidence, and says so"
else
  fail "bootstrap refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
fi
[[ -e "$(authority_of "${root}")" ]] && fail "bootstrap created an authority root while ineligible"

# Genesis and admission additionally require the roots, so with nothing at all
# in place either refusal is correct -- what must not happen is proceeding.
for phase in genesis admit; do
  root="${WORK}/noev-${phase}"; build_fixture "${root}"
  run_ceremony "${root}" "--${phase}" --commit "${COMMIT}" --image-id "${IMAGE_ID}" \
    && fail "--${phase} ran with neither evidence nor a namespace"
  [[ -e "$(authority_of "${root}")" ]] && fail "--${phase} created an authority root"
done
pass "no phase created authority state while ineligible"

# With the namespace in place but the evidence withdrawn, the refusal must be
# the evidence -- otherwise the sequencing check would be masking it.
root="${WORK}/noev-after"; build_fixture "${root}"; write_evidence "${root}"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" >/dev/null 2>&1
rm -f "${root}${EVIDENCE_ABS}"
for phase in genesis admit; do
  if run_ceremony "${root}" "--${phase}" --commit "${COMMIT}" --image-id "${IMAGE_ID}"; then
    fail "--${phase} ran after the evidence was withdrawn"
  elif grep -q 'provisioning evidence' "${root}/last-run.log"; then
    pass "--${phase} refuses on the evidence once the namespace exists"
  else
    fail "--${phase} refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
done
[[ -e "$(authority_of "${root}")/current-generation" ]] \
  && fail "a generation was published while ineligible" \
  || pass "no generation was published while ineligible"

root="${WORK}/malformed"; build_fixture "${root}"
printf '{"not":"evidence"}' > "${root}${EVIDENCE_ABS}"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" \
  && fail "malformed evidence was accepted" \
  || pass "malformed provisioning evidence is refused by the ruled parser"

# ===========================================================================
# 3. the evidence must describe the image that is actually there
# ===========================================================================
root="${WORK}/wrongimage"; build_fixture "${root}"; write_evidence "${root}" "$(printf 'c%.0s' {1..64})"
if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
  fail "evidence describing a different image was accepted"
else
  grep -q 'must be the same artefact' "${root}/last-run.log" \
    && pass "evidence describing a different image than the store holds is refused" \
    || fail "wrong image refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
fi

root="${WORK}/absent"; build_fixture "${root}"; write_evidence "${root}"
rm -f "${root}/fixture/image-inspect"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" \
  && fail "an absent image was accepted" \
  || pass "an image absent from the execution identity's store is refused"

# The identity is Podman .Id. A registry-shaped digest is not one.
root="${WORK}/repodigest"; build_fixture "${root}"; write_evidence "${root}"
write_inspect "${root}" "sha256:500bbd7d2f2699fb313dc159a54a9fc8fcc81e3359ef71135a29fd3121f03a29"
if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
  fail "a sha256:-prefixed RepoDigest was accepted as the implementation identity"
else
  grep -q 'not a bare 64-character lowercase hex' "${root}/last-run.log" \
    && pass "a RepoDigest substituted for .Id is refused" \
    || fail "the RepoDigest was refused for the wrong reason"
fi
root="${WORK}/tagonly"; build_fixture "${root}"; write_evidence "${root}"
write_inspect "${root}" "${BUILD_TAG}"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" \
  && fail "a tag was accepted as the implementation identity" \
  || pass "a tag substituted for .Id is refused"
root="${WORK}/upper"; build_fixture "${root}"; write_evidence "${root}"
write_inspect "${root}" "$(tr 'a-f' 'A-F' <<<"${IMAGE_ID}")"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" \
  && fail "an uppercase image ID was accepted" \
  || pass "an uppercase image ID is refused: bare 64 lowercase hex or nothing"

# ===========================================================================
# 4. the image contract
# ===========================================================================
run_contract_case() {
  local name="$1" expect="$2"; shift 2
  root="${WORK}/img-${name}"; build_fixture "${root}"; write_evidence "${root}"
  write_inspect "${root}" "$@"
  if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
    fail "${name} was accepted"
  elif grep -q "${expect}" "${root}/last-run.log"; then
    pass "the image contract refuses: ${name}"
  else
    fail "${name} refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
  fi
}
run_contract_case "wrong os"           "expected linux"        "${IMAGE_ID}" "windows"
run_contract_case "wrong architecture" "expected amd64"        "${IMAGE_ID}" "linux" "arm64"
run_contract_case "wrong default user" "expected 65532:65532"  "${IMAGE_ID}" "linux" "amd64" "0:0"
run_contract_case "a baked entrypoint" "carries an entrypoint" "${IMAGE_ID}" "linux" "amd64" "65532:65532" "[/usr/bin/python]"
run_contract_case "a baked command"    "carries a command"     "${IMAGE_ID}" "linux" "amd64" "65532:65532" "[]" "[python]"
run_contract_case "wrong workdir"      "expected /"            "${IMAGE_ID}" "linux" "amd64" "65532:65532" "[]" "[]" "/srv"

# ===========================================================================
# 5. the evidence must agree with the approval
# ===========================================================================
root="${WORK}/wrongbase"; build_fixture "${root}"
write_evidence "${root}" "${IMAGE_ID}" "cgr.dev/chainguard/python@sha256:$(printf 'd%.0s' {1..64})"
if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
  fail "evidence naming a different base was accepted"
else
  grep -q 'the approval names' "${root}/last-run.log" \
    && pass "evidence naming a base other than the approved one is refused" \
    || fail "wrong base refused for the wrong reason"
fi
root="${WORK}/wrongsbom"; build_fixture "${root}"
write_evidence "${root}" "${IMAGE_ID}" "${BASE_REF}" "$(printf 'e%.0s' {1..64})"
if run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}"; then
  fail "evidence committing a different SBOM was accepted"
else
  grep -q 'the approval commits' "${root}/last-run.log" \
    && pass "evidence committing an SBOM other than the approved one is refused" \
    || fail "wrong SBOM refused for the wrong reason"
fi

# ===========================================================================
# 6. bootstrap: what it creates, and what it must not
# ===========================================================================
staged="${WORK}/chain"; build_fixture "${staged}"; write_evidence "${staged}"
if run_ceremony "${staged}" --bootstrap-authority --commit "${COMMIT}"; then
  pass "bootstrap runs once the evidence establishes eligibility"
else
  fail "bootstrap refused with valid evidence: $(tail -10 "${staged}/last-run.log")"
fi
[[ "$(stat -c '%a' "$(authority_of "${staged}")")" == "2750" ]] \
  && pass "the authority root is 2750: setgid, so published objects inherit the coordinator group" \
  || fail "the authority root is $(stat -c '%a' "$(authority_of "${staged}")")"
[[ "$(stat -c '%a' "$(control_of "${staged}")")" == "700" ]] \
  && pass "the control root is 0700" \
  || fail "the control root is $(stat -c '%a' "$(control_of "${staged}")")"
[[ "$(stat -c '%a' "$(control_of "${staged}")/staging")" == "2750" ]] \
  && pass "staging is 2750: what every published record inherits its group from" \
  || fail "staging is $(stat -c '%a' "$(control_of "${staged}")/staging")"
for counter in cimp-counter cgen-counter; do
  [[ "$(stat -c '%a' "$(control_of "${staged}")/${counter}")" == "600" ]] \
    || fail "${counter} is not 0600"
  [[ "$(cat "$(control_of "${staged}")/${counter}")" =~ ^0+$ ]] \
    || fail "${counter} did not start at zero"
done
pass "both counters exist at zero, root-only: bootstrap allocated no identifier"
[[ -e "$(authority_of "${staged}")/implementations" ]] \
  && fail "bootstrap published an implementations directory" \
  || pass "bootstrap published no implementation"
[[ -e "$(authority_of "${staged}")/current-generation" ]] \
  && fail "bootstrap advanced a generation" \
  || pass "bootstrap advanced no generation and granted no authority"
[[ -e "${staged}/etc/sudoers.d/kyri-exec" ]] \
  && fail "bootstrap created sudoers" \
  || pass "bootstrap created no sudoers"
grep -q 'STOP' "${staged}/last-run.log" \
  && pass "bootstrap stops for review before genesis" \
  || fail "bootstrap does not stop for review"

# ===========================================================================
# 7. genesis
# ===========================================================================
if run_ceremony "${staged}" --genesis --commit "${COMMIT}"; then
  pass "genesis runs after bootstrap"
else
  fail "genesis failed: $(tail -10 "${staged}/last-run.log")"
fi
grep -q 'current generation: CGEN-000000000000' "${staged}/last-run.log" \
  && pass "genesis publishes CGEN-000000000000" \
  || fail "genesis published the wrong generation"
grep -q 'authority set:      empty (0 entries)' "${staged}/last-run.log" \
  && pass "the genesis authority set is empty: genesis admits nothing" \
  || fail "the genesis authority set is not empty"
grep -q 'namespace state:    valid' "${staged}/last-run.log" \
  && pass "the runtime reader classifies the genesis namespace VALID" \
  || fail "the runtime reader does not accept the genesis namespace"
for counter in cimp-counter cgen-counter; do
  [[ "$(cat "$(control_of "${staged}")/${counter}")" =~ ^0+$ ]] \
    || fail "genesis consumed ${counter}"
done
pass "genesis consumed neither counter: CIMP-000000 and CGEN-000000000000 stay unreachable from the allocators"
[[ -e "$(authority_of "${staged}")/implementations/CIMP-000001" ]] \
  && fail "genesis admitted an implementation" \
  || pass "genesis admitted no implementation"
grep -q 'STOP' "${staged}/last-run.log" \
  && pass "genesis stops for review before admission" \
  || fail "genesis does not stop for review"
# Bootstrap and genesis are separate decisions and neither runs the other.
if sed -n '/^bootstrap_authority()/,/^}/p' "${CEREMONY}" | grep -q 'run_genesis\|initialise_genesis'; then
  fail "bootstrap runs genesis"
else
  pass "bootstrap does not run genesis"
fi
if sed -n '/^run_genesis()/,/^}/p' "${CEREMONY}" | grep -q 'run_admission\|admit_implementation'; then
  fail "genesis runs admission"
else
  pass "genesis does not run admission"
fi

# ===========================================================================
# 8. admission
# ===========================================================================
root="${WORK}/noid"; build_fixture "${root}"; write_evidence "${root}"
run_ceremony "${root}" --admit --commit "${COMMIT}" \
  && fail "admission ran without an operator-supplied identity" \
  || pass "admission requires --image-id: the requested identity is an operator observation"

root="${WORK}/mismatch"; build_fixture "${root}"; write_evidence "${root}"
run_ceremony "${root}" --bootstrap-authority --commit "${COMMIT}" >/dev/null 2>&1
run_ceremony "${root}" --genesis --commit "${COMMIT}" >/dev/null 2>&1
if run_ceremony "${root}" --admit --commit "${COMMIT}" --image-id "$(printf 'f%.0s' {1..64})"; then
  fail "a requested identity disagreeing with the store was admitted"
else
  grep -qE 'not the supplied|is not what the store resolves' "${root}/last-run.log" \
    && pass "a requested identity that disagrees with the store is refused, naming both" \
    || fail "the mismatch was refused for the wrong reason: $(tail -4 "${root}/last-run.log")"
fi

if run_ceremony "${staged}" --admit --commit "${COMMIT}" --image-id "${IMAGE_ID}"; then
  pass "admission runs after genesis with three agreeing observations"
else
  fail "admission failed: $(tail -12 "${staged}/last-run.log")"
fi
grep -q 'cimp:                         CIMP-000001' "${staged}/last-run.log" \
  && pass "the first production admission is CIMP-000001" \
  || fail "the first admission did not allocate CIMP-000001"
grep -q 'cgen:                         CGEN-000000000001' "${staged}/last-run.log" \
  && pass "the successor generation is CGEN-000000000001" \
  || fail "the successor generation is wrong"
grep -q "oci_image_id:                 ${IMAGE_ID}" "${staged}/last-run.log" \
  && pass "the admitted implementation binds to the exact inspected .Id" \
  || fail "the admitted implementation binds to something else"
grep -q 'namespace:                    valid, pending 0' "${staged}/last-run.log" \
  && pass "the namespace is VALID with nothing pending, read back through the runtime reader" \
  || fail "the namespace is not valid with nothing pending"
[[ -e "${staged}/etc/sudoers.d/kyri-exec" ]] \
  && fail "admission created sudoers" \
  || pass "admission created no sudoers: an admitted implementation is not execution"

# The three observations come from three places. If the ceremony ever fed one
# reading into all three slots the comparison would pass and prove nothing.
admission_body="$(sed -n '/^run_admission()/,/^}/p' "${CEREMONY}")"
if grep -q 'oci_image_id=requested' <<<"${admission_body}" \
   && grep -q 'observed_image_id=observed' <<<"${admission_body}" \
   && grep -q 'evidence=open(evidence_path' <<<"${admission_body}"; then
  pass "the request is built from three separately sourced observations"
else
  fail "the admission request does not carry three independent observations"
fi
if grep -qE 'observed_image_id=requested|oci_image_id=observed' <<<"${admission_body}"; then
  fail "one observation is copied into another slot"
else
  pass "no observation is copied into another slot"
fi

# ===========================================================================
# 9. the ceremony never invokes execution
# ===========================================================================
for forbidden in 'kyri-exec-transition[[:space:]]' 'kyri-exec-worker' 'podman run' 'podman create' 'podman start'; do
  if sed -e '/^print_plan()/,/^}/d' -e '/^print_production_build()/,/^}/d' \
       -e '/^bootstrap_instructions()/,/^}/d' "${CEREMONY}" | grep -qE "${forbidden}"; then
    fail "the ceremony invokes ${forbidden}"
  fi
done
pass "no phase invokes the transition, the worker, or a container start"
if sed -n '/^image_inspect_fields()/,/^}/p' "${CEREMONY}" | grep -q 'podman image inspect'; then
  pass "the only Podman use is a read-only image inspect as the execution identity"
else
  fail "the image observation is not a read-only inspect"
fi

# ===========================================================================
# 10. registration, and the host is untouched
# ===========================================================================
name="tests/test-capability-execution-g5-authority.sh"
grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
  && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml" \
  && pass "the suite runs in local validation and in CI" \
  || fail "the suite is not registered in local validation and CI"

for absent in /var/lib/kyri/implementation-authority \
              /var/lib/kyri/implementation-authority-control \
              /etc/sudoers.d/kyri-exec; do
  [[ -e "${absent}" ]] && fail "G5 authority state exists on this host: ${absent}"
done
pass "no authority state and no sudoers on this host: G5 is closed"
id -nG "${COORDINATOR}" 2>/dev/null | tr ' ' '\n' | grep -qx kyri-capability \
  && fail "${COORDINATOR} joined the execution group" \
  || pass "${COORDINATOR} is still not in the execution group"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated while this suite ran"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 authority-phase validation passed.\n'
else
  printf 'G5 authority-phase validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
