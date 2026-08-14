#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the read-only G5 ceremony preflight.
#
# ISOLATED BY CONSTRUCTION. Every behavioural case builds a throwaway fixture
# tree and runs the preflight with --fixture against it. Nothing here builds an
# image, creates an authority root, runs genesis, allocates an identifier,
# writes sudoers, or invokes Podman, the transition, or the worker.
#
# WHAT IS PROVEN. The preflight is read-only in every mode -- asserted
# structurally against its own source as well as by snapshotting the production
# paths -- it refuses a host that is not at the ruled G5 starting position, and
# it reports the three outstanding rulings rather than encoding a ceremony
# around them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFLIGHT="${REPOSITORY}/provisioning/execution/g5-preflight.sh"
[[ -f "${PREFLIGHT}" ]] || { printf 'preflight missing: %s\n' "${PREFLIGHT}" >&2; exit 1; }
PINNED_REPOSITORY="$(sed -n 's/^REPOSITORY="\(.*\)"$/\1/p' "${PREFLIGHT}" | head -1)"
[[ "${PINNED_REPOSITORY}" == "${REPOSITORY}" ]] || {
  printf 'this checkout is %s but the preflight pins %s\n' "${REPOSITORY}" "${PINNED_REPOSITORY}" >&2
  exit 1
}

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# Every pinned constant is read out of the preflight rather than restated here,
# so the two can never disagree. The tmpfiles pathname in particular is only
# ever derived: the snapshot suite reserves that literal to itself, and a
# second copy of it in a test would be a second thing to keep in agreement.
read_pin() { sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "${PREFLIGHT}" | head -1; }
GEN6_COMMIT="$(read_pin GEN6_COMMIT)"
GEN5_COMMIT="$(read_pin GEN5_COMMIT)"
TMPFILES_TARGET_ABS="$(read_pin TMPFILES_TARGET)"
TMPFILES_SOURCE="provisioning/execution/tmpfiles.d/kyri-execution-material.conf"
for name in GEN6_COMMIT GEN5_COMMIT; do
  [[ "${!name}" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'the preflight pins no full 40-character %s\n' "${name}" >&2; exit 1; }
done
[[ -n "${TMPFILES_TARGET_ABS}" ]] || {
  printf 'the preflight pins no tmpfiles target\n' >&2; exit 1; }

# ===========================================================================
# Fixture-only guard
# ===========================================================================
PRODUCTION_PATHS=(
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-quota
  /etc/sudoers.d/kyri-exec
  "${TMPFILES_TARGET_ABS}"
  /run/kyri
  /var/lib/kyri
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

digest_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
materialise() {
  local commit="$1" source="$2" destination="$3"
  rm -f "${destination}"
  git -C "${REPOSITORY}" cat-file blob "${commit}:${source}" > "${destination}"
}

# ===========================================================================
# A fixture at the ruled G5 starting position
# ===========================================================================
# Generation 6 installed, prerequisite provisioned, every gate closed, no
# authority state. Built from pinned git objects, never from the live host --
# the suite must pass whichever generation this machine happens to run.
build_fixture() {
  local root="$1" file
  [[ -d "${root}" ]] && chmod -R u+w "${root}" >/dev/null 2>&1
  mkdir -p "${root}/usr/lib/kyri/python/tools/capability/execution" \
           "${root}/usr/lib/kyri/python/tools/common" \
           "${root}/usr/libexec" "${root}/var/lib/kyri" \
           "${root}$(dirname "${TMPFILES_TARGET_ABS}")" "${root}/etc/sudoers.d" \
           "${root}/run/kyri/execution-material"

  while IFS= read -r file; do
    mkdir -p "${root}/usr/lib/kyri/python/$(dirname "${file}")"
    materialise "${GEN6_COMMIT}" "${file}" "${root}/usr/lib/kyri/python/${file}"
    chmod 0444 "${root}/usr/lib/kyri/python/${file}"
  done < <(git -C "${REPOSITORY}" ls-tree -r --name-only "${GEN6_COMMIT}" \
             -- tools/__init__.py tools/capability tools/common \
           | grep '\.py$' | grep -v '__pycache__' | sort)

  local flattened
  for flattened in kyri-exec-quota:kyri_exec_quota.py \
                   kyri-exec-transition:kyri_exec_transition.py \
                   kyri-exec-transition-action:kyri_exec_transition_action.py; do
    materialise "${GEN6_COMMIT}" "provisioning/execution/${flattened%%:*}.py" \
      "${root}/usr/lib/kyri/python/${flattened##*:}"
    chmod 0444 "${root}/usr/lib/kyri/python/${flattened##*:}"
  done

  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-transition-entrypoint.py \
    "${root}/usr/libexec/kyri-exec-transition"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-worker.py \
    "${root}/usr/libexec/kyri-exec-worker.py"
  materialise "${GEN5_COMMIT}" provisioning/execution/kyri-exec-quota.py \
    "${root}/usr/libexec/kyri-exec-quota"
  chmod 0555 "${root}/usr/libexec/kyri-exec-transition" "${root}/usr/libexec/kyri-exec-quota"
  chmod 0444 "${root}/usr/libexec/kyri-exec-worker.py"

  materialise "${GEN6_COMMIT}" "${TMPFILES_SOURCE}" "${root}${TMPFILES_TARGET_ABS}"
  chmod 0644 "${root}${TMPFILES_TARGET_ABS}"
  chmod 0755 "${root}/run/kyri"
  chmod 0770 "${root}/run/kyri/execution-material"
}

run_preflight() {
  local root="$1"; shift
  ( cd "${REPOSITORY}" && bash "${PREFLIGHT}" --fixture "${root}" "$@" ) \
    > "${root}/last-run.log" 2>&1
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }

# ===========================================================================
# 1. the ruled starting position is accepted
# ===========================================================================
clean="${WORK}/clean"; build_fixture "${clean}"
if [[ "$(library_count "${clean}")" -eq 44 ]]; then
  pass "the fixture is a generation-6 host: 44 library objects"
else
  fail "the fixture holds $(library_count "${clean}") library objects, expected 44"
fi
if run_preflight "${clean}" --verify-host; then
  pass "--verify-host accepts a host at the ruled G5 starting position"
else
  fail "--verify-host rejected a valid starting position: $(tail -12 "${clean}/last-run.log")"
fi

# ===========================================================================
# 2. every departure from that position is refused
# ===========================================================================
# A host still running generation 5 is not ready for G5 admission: the snapshot
# hardening the ceremony assumes is simply not installed.
root="${WORK}/gen5-host"; build_fixture "${root}"
rm -f "${root}/usr/lib/kyri/python/tools/capability/execution/snapshot.py"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted a host that is not generation 6"
else
  if grep -q "expected 44" "${root}/last-run.log"; then
    pass "a host that is not generation 6 is refused"
  else
    fail "wrong generation refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# A drifted privileged helper means the generation-5 boundary is not intact,
# and every argument about what root will do rests on that boundary.
root="${WORK}/helper-drift"; build_fixture "${root}"
chmod u+w "${root}/usr/libexec/kyri-exec-worker.py"
printf '# drift\n' >> "${root}/usr/libexec/kyri-exec-worker.py"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted a drifted privileged helper"
else
  if grep -q "not the accepted Generation-5 object" "${root}/last-run.log"; then
    pass "a drifted /usr/libexec object is refused"
  else
    fail "helper drift refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# Authority state that already exists means either a ceremony already ran or
# something else wrote the namespace. Neither may be started over.
for existing in implementation-authority implementation-authority-control; do
  root="${WORK}/authority-${existing}"; build_fixture "${root}"
  # Inside the fixture root, never on the host: the leading ${root} is what
  # makes this a synthetic namespace rather than the production one.
  mkdir -p "${root}/var/lib/kyri/${existing}"   # prod-path-reference
  if run_preflight "${root}" --verify-host; then
    fail "--verify-host accepted an existing ${existing}"
  else
    if grep -q "already exists" "${root}/last-run.log"; then
      pass "an existing ${existing} is refused"
    else
      fail "existing ${existing} refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
    fi
  fi
done

# G3 is a separate gate and image admission must not depend on it.
root="${WORK}/sudoers"; build_fixture "${root}"
printf 'cschott ALL=(root) NOPASSWD: /usr/libexec/kyri-exec-transition\n' \
  > "${root}/etc/sudoers.d/kyri-exec"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted a host carrying a sudoers policy"
else
  if grep -q "G3 is not closed" "${root}/last-run.log"; then
    pass "an existing sudoers policy is refused: G5 must not depend on G3"
  else
    fail "sudoers refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# The generation-6 prerequisite must still be exactly what was provisioned.
root="${WORK}/prereq-drift"; build_fixture "${root}"
printf 'd /run/kyri/execution-material 0777 root root -\n' \
  > "${root}${TMPFILES_TARGET_ABS}"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted a substituted tmpfiles fragment"
else
  if grep -q "not the reviewed artifact" "${root}/last-run.log"; then
    pass "a substituted tmpfiles fragment is refused"
  else
    fail "fragment drift refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# A snapshot root that already holds material means something ran.
root="${WORK}/snapshot-residue"; build_fixture "${root}"
mkdir -p "${root}/run/kyri/execution-material/CINV-000001"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted invocation material under the snapshot root"
else
  if grep -q "no worker has run" "${root}/last-run.log"; then
    pass "existing invocation material under the snapshot root is refused"
  else
    fail "snapshot residue refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# Operator tooling inside the runtime library is the boundary violation the
# whole authority split exists to prevent.
root="${WORK}/installed-tooling"; build_fixture "${root}"
mkdir -p "${root}/usr/lib/kyri/python/tools/provisioning"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted installed operator tooling"
else
  if grep -q "operator provisioning modules are installed" "${root}/last-run.log"; then
    pass "operator tooling installed into the runtime library is refused"
  else
    fail "installed tooling refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# Installation residue means a generation transaction did not finish.
root="${WORK}/install-residue"; build_fixture "${root}"
touch "${root}/usr/lib/kyri/python/tools/capability/execution/worker.py.kyri-gen6.new"
if run_preflight "${root}" --verify-host; then
  fail "--verify-host accepted installation transaction residue"
else
  if grep -q "transaction artefacts remain" "${root}/last-run.log"; then
    pass "installation transaction residue is refused"
  else
    fail "residue refused for the wrong reason: $(tail -6 "${root}/last-run.log")"
  fi
fi

# ===========================================================================
# 3. the image definition contract
# ===========================================================================
if run_preflight "${clean}" --verify-host \
   && grep -q "names no base, and pins no floating tag" "${clean}/last-run.log"; then
  pass "the reviewed image definition names no base and pins no floating tag"
else
  fail "the image definition contract was not verified"
fi

# ===========================================================================
# 4. the blockers are reported, not encoded around
# ===========================================================================
root="${WORK}/blockers"; build_fixture "${root}"
if run_preflight "${root}" --blockers; then
  pass "--blockers exits 0: the three rulings are resolved, not outstanding"
else
  fail "--blockers exited non-zero: $(tail -6 "${root}/last-run.log")"
fi
missing=0
for required in "BASE IMAGE AUTHORITY -- RESOLVED IN MECHANISM" \
                "AUTHORITY OWNERSHIP -- RESOLVED" \
                "ROOT EXECUTION -- RESOLVED"; do
  grep -q "${required}" "${root}/last-run.log" || {
    fail "--blockers omits the resolution of: ${required}"; missing=$((missing + 1)); }
done
(( missing == 0 )) && pass "--blockers records how each of the three rulings was resolved"
# The one thing still genuinely outstanding must stay visible: nobody has
# chosen a base image, and the report must not read as though the build is
# ready merely because the mechanism is.
if grep -q "STILL REQUIRED" "${root}/last-run.log"; then
  pass "--blockers still names the candidate digest and SBOM bytes as operator inputs"
else
  fail "--blockers no longer says a base image is unchosen"
fi

# --verify-source now proves the mechanism rather than reporting a blocker.
root="${WORK}/source"; build_fixture "${root}"
if run_preflight "${root}" --verify-source \
   && grep -q "the checkout is never imported" "${root}/last-run.log"; then
  pass "--verify-source confirms root-owned pinned-code execution is implemented"
else
  fail "--verify-source did not confirm the execution model: $(tail -8 "${root}/last-run.log")"
fi

# ===========================================================================
# 5. read-only in every mode, proven structurally
# ===========================================================================
# The preflight drives nothing, but it is the script an operator will run as
# root against a host with no authority state, so "it only reads" has to be a
# property of the source rather than of this run.
mutations=0
for forbidden in '^[[:space:]]*mkdir' '^[[:space:]]*chown' '^[[:space:]]*chmod' \
                 '^[[:space:]]*rm ' '^[[:space:]]*mv ' '^[[:space:]]*install ' \
                 '^[[:space:]]*touch' '^[[:space:]]*ln ' 'systemd-tmpfiles' \
                 'groupadd' 'useradd' 'usermod' 'podman' 'buildah' 'docker'; do
  if grep -qE "${forbidden}" "${PREFLIGHT}"; then
    fail "the preflight contains a mutating or container command: ${forbidden}"
    mutations=$((mutations + 1))
  fi
done
if (( mutations == 0 )); then
  pass "the preflight builds nothing, creates nothing, and invokes no container runtime"
fi
# Naming a module in a digest table or in the blockers prose is the point; what
# must be absent is any construct that IMPORTS or RUNS one. Asserted against
# those constructs directly, so the check cannot be satisfied by paraphrase and
# cannot fire on a filename.
if grep -qE 'from tools\.provisioning|import (authority_|provisioning_evidence)|initialise_genesis\(|allocate_cimp\(|allocate_cgen\(|admit_implementation\(' "${PREFLIGHT}"; then
  fail "the preflight imports or drives the authority mutation modules"
else
  pass "the preflight drives no authority mutation module: it names them, it never calls them"
fi
if grep -qE '^[[:space:]]*(sudo )?(python3?|/usr/bin/python3?) ' "${PREFLIGHT}"; then
  fail "the preflight executes Python: root execution of checkout code is a blocker, not a step"
else
  pass "the preflight executes no Python from the checkout"
fi

# Every mutable root is fixture-prefixed, in one block, with no exceptions.
missing_prefix=0
for name in LIBRARY_ROOT LIBEXEC KYRI_STATE AUTHORITY_ROOT CONTROL_ROOT \
            SUDOERS TMPFILES_TARGET SNAPSHOT_PARENT SNAPSHOT_ROOT; do
  if ! grep -qE "^  ${name}=\"\\\$\{FIXTURE\}\\\$\{${name}\}\"$" "${PREFLIGHT}"; then
    fail "preflight root ${name} is not rebound under the fixture prefix"
    missing_prefix=$((missing_prefix + 1))
  fi
done
(( missing_prefix == 0 )) && pass "every preflight root is rebound under the fixture prefix"

# The clean-tree gate is scoped to production runs, as everywhere else.
# The unexpanded literals ARE the assertion, so they must not expand.
# shellcheck disable=SC2016
if grep -qF '[[ -n "${FIXTURE}" ]] || halt "the working tree is not clean:"' "${PREFLIGHT}"; then
  pass "a dirty tree halts a production run and is only noted in fixture mode"
else
  fail "the clean-tree gate is not scoped to production runs"
fi

# ===========================================================================
# 6. fixture hermeticity and registration
# ===========================================================================
builder="$(sed -n '/^build_fixture()/,/^}/p;/^materialise()/,/^}/p' "$0")"
if printf '%s' "${builder}" | grep -qE '(cp|cat|sha256sum|find|install)[[:space:]]+/(usr|etc|run|var)/'; then
  fail "fixture construction reads an absolute production path"
else
  pass "fixture construction reads no absolute production path"
fi
if printf '%s' "${builder}" | grep -q 'cat-file blob'; then
  pass "fixture bytes come from pinned git objects"
else
  fail "fixture bytes do not come from git objects"
fi
if grep -qE '^(GEN5|GEN6)_COMMIT="\$\(read_pin' "$0"; then
  pass "both pinned commits are read from the preflight, not restated here"
else
  fail "a pinned commit is restated in the harness and could drift"
fi

name="tests/test-capability-execution-g5-preflight.sh"
if grep -q "${name}" "${REPOSITORY}/tools/dev/run-validation.sh" \
   && grep -q "${name}" "${REPOSITORY}/.github/workflows/ci.yml"; then
  pass "the suite runs in local validation and in CI"
else
  fail "the suite is not registered in local validation and CI"
fi
if grep -q 'g5-preflight.sh' "${REPOSITORY}/provisioning/execution/README.md"; then
  pass "the runbook documents the G5 preflight"
else
  fail "the runbook does not document the G5 preflight"
fi

# ===========================================================================
# 7. G5 is still closed, and this suite left the host alone
# ===========================================================================
for absent in /var/lib/kyri/implementation-authority \
              /var/lib/kyri/implementation-authority-control \
              /etc/sudoers.d/kyri-exec; do
  if [[ -e "${absent}" ]]; then
    fail "G5 state exists on this host: ${absent}"
  fi
done
pass "no sudoers policy and no authority state exist on this host: G5 is closed"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path was mutated while this suite ran"
else
  fail "a production path changed while this suite ran"
  diff <(printf '%s\n' "${PRODUCTION_BEFORE}") <(printf '%s\n' "${PRODUCTION_AFTER}") >&2 || true
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'G5 preflight validation passed.\n'
else
  printf 'G5 preflight validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
