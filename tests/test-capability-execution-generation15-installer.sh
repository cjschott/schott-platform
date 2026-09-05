#!/usr/bin/env bash
set -Eeuo pipefail

# The Generation-15 runtime installation, proven in a fixture.
#
# UNPRIVILEGED AND ISOLATED. Every path the installer touches is rebound under
# --fixture. No production runtime object is read for state and none is written;
# no sudo, no helper, no Podman, no container.
#
# WHAT GENERATION 15 IS
# =====================
# Seven objects, derived mechanically from the accepted installed Generation-14
# authority to the reviewed source at ef4f744: five REPLACE and two CREATE,
# across three coherence groups.
#
#   V  the runtime-side verification surface
#      verification.py (REPLACE) + result_content.py, contract_outcome.py (CREATE)
#   R  supervised recovery discovery
#      recovery.py + cli.py
#   H  helper declaration and refusal reporting
#      helpers.py + kyri_exec_launcher.py
#
# THE FIXTURE IS RECONSTRUCTED, NOT COPIED
# ========================================
# Copying the live runtime would make the fixture agree with production by
# construction and prove nothing about the declared baseline. It is built from
# accepted Generation-14 evidence instead:
#
#   every object from the Generation-14 authority 946be55, EXCEPT
#   verification.py, whose accepted installed bytes are 16f285e's.
#
# That exception is the defect this generation repairs, and it is why the
# baseline has to be reconstructed per object rather than taken from one commit:
# the installed Generation-14 runtime does not match its own source authority
# for that object, which is exactly the split G11-BB found.
#
# WHAT IS NOT HERE
# ================
# No privileged helper is installed, no grant is written, and the verify
# entrypoint is not authorised. Group V repairs the verification LIBRARY; the
# entrypoint that would use it stays ungranted, and this suite asserts that.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${ROOT}/provisioning/execution/install-generation-15.sh"

# HOST-ONLY. The fixture's PATH SET is the accepted Generation-14 surface, read
# from the installed runtime; only the BYTES come from git. That is what makes
# the baseline a reconstruction of what a generation actually published rather
# than of whatever the repository happens to contain -- and it means this suite
# has nothing to reconstruct against on a machine with no installed runtime.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /usr/lib/kyri/python          # prod-path-reference

GEN14_COMMIT="946be553ab9f25542590eb908c42ce14a81d6ec3"
VERIFICATION_AT="16f285e84b58585409514d90e282782b8d77d9d1"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# --- the accepted Generation-14 baseline, reconstructed ---------------------
build_fixture() {
  local root="$1"
  rm -rf "${root}"
  local lib="${root}/usr/lib/kyri/python"
  # Every path here is prefixed with the fixture root and none is the production
  # path it mirrors. Each line carries the marker so the exception is greppable
  # rather than hidden, which is what the guard asks for.
  mkdir -p "${lib}" "${root}/usr/libexec" "${root}/root" "${root}/etc/sudoers.d"
  mkdir -p "${root}/etc/kyri"                                # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority"    # prod-path-reference
  mkdir -p "${root}/var/lib/kyri/implementation-authority-control"  # prod-path-reference

  local staging; staging="$(mktemp -d)"
  ( cd "${ROOT}" && git archive --format=tar "${GEN14_COMMIT}" tools provisioning/execution ) \
    | tar -x -C "${staging}"

  # The PATH SET is the accepted Generation-14 surface -- which objects that
  # generation installed, not every file the repository happens to carry. The
  # BYTES come from reviewed git objects. Taking the list from the live tree and
  # the content from git is what makes this a reconstruction rather than a copy:
  # a fixture built by copying production would agree with production by
  # construction and prove nothing about the declared baseline.
  local object
  while IFS= read -r object; do
    [[ -f "${staging}/${object}" ]] || continue
    install -D -m 0444 "${staging}/${object}" "${lib}/${object}"
  done < <( cd /usr/lib/kyri/python && find tools -type f -name '*.py' \
              ! -path '*__pycache__*' | sort )

  # Library-root modules, by the same rule: the accepted generation decides
  # WHICH, git decides what. provisioning/execution also holds entrypoints that
  # are installed to /usr/libexec rather than here, and copying those in would
  # invent a baseline no generation ever published.
  local module source
  while IFS= read -r module; do
    source="${staging}/provisioning/execution/${module%.py}"
    source="${source//_/-}.py"
    [[ -f "${source}" ]] || continue
    install -m 0444 "${source}" "${lib}/${module}"
  done < <( cd /usr/lib/kyri/python && find . -maxdepth 1 -type f -name 'kyri_exec_*.py' \
              -printf '%P\n' | sort )

  # The one object whose accepted installed bytes are not the authority's.
  ( cd "${ROOT}" && git show "${VERIFICATION_AT}:tools/capability/execution/verification.py" ) \
    > "${staging}/verification.py"
  install -m 0444 "${staging}/verification.py" \
    "${lib}/tools/capability/execution/verification.py"

  # The evidence the installer requires of its predecessor.
  ( cd "${lib}" && find . -type f -name '*.py' | sed 's|^\./||' | sort \
      | xargs sha256sum ) | sed "s|^\([0-9a-f]*\)  |\1  /usr/lib/kyri/python/|" \
      > "${root}/root/kyri-gen14-library-digests.txt"
  : > "${root}/root/kyri-gen14-helper-digests.txt"
  for object in "${staging}"/provisioning/execution/kyri-exec-*; do
    [[ -f "${object}" ]] || continue
    printf '%s  /usr/libexec/%s\n' "$(sha256sum "${object}" | cut -d' ' -f1)" \
      "$(basename "${object}")" >> "${root}/root/kyri-gen14-helper-digests.txt"
  done

  printf '{"coordinator_account":"cschott","coordinator_uid":1000,"schema_version":1}\n' \
    > "${root}/etc/kyri/coordinator-identity.json"  # prod-path-reference
  printf '{"execution_account":"kyri-capability","execution_gid":987,"execution_uid":999,"schema_version":1}\n' \
    > "${root}/etc/kyri/execution-identity.json"  # prod-path-reference

  rm -rf "${staging}"
}

library_count() { find "$1/usr/lib/kyri/python" -type f -name '*.py' | wc -l; }
manifest() {
  { find "$1" -printf '%P %m %s\n' | sort
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum \
      | sed "s|${1}||"; } | sha256sum | cut -d' ' -f1
}
run_installer() {
  local root="$1" mode="$2"
  shift 2
  ( cd "${ROOT}" && env "$@" PYTHONDONTWRITEBYTECODE=1 \
      bash "${INSTALLER}" "${mode}" --fixture "${root}" ) \
    > "${WORK}/last-run.log" 2>&1
}

# ===========================================================================
# A. the declared shape
# ===========================================================================

root="${WORK}/shape"; build_fixture "${root}"
if [[ "$(library_count "${root}")" == "79" ]]; then
  pass "the reconstructed Generation-14 fixture holds 79 objects (78 governed + 1 helper-published)"
else
  fail "the fixture holds $(library_count "${root}") objects, expected 79"
fi

installed_verification="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/verification.py" | cut -d' ' -f1)"
if [[ "${installed_verification}" == "ed5b49ed03add16c8ba7a233d53a8c5528e5ba4d0fc23f53cdd41bb788bd2e73" ]]; then
  pass "the fixture carries the accepted stale verification.py, not the authority's"
else
  fail "the fixture's verification.py is ${installed_verification}"
fi

# ===========================================================================
# B. verify is non-mutating
# ===========================================================================

root="${WORK}/verify"; build_fixture "${root}"
before="$(manifest "${root}")"
if run_installer "${root}" --verify; then
  pass "--verify accepts the reconstructed Generation-14 baseline"
else
  fail "--verify rejected the baseline: $(tail -6 "${WORK}/last-run.log")"
fi
after="$(manifest "${root}")"
if [[ "${before}" == "${after}" ]]; then
  pass "--verify wrote nothing"
else
  fail "--verify changed the fixture"
fi
if [[ -z "$(find "${root}" -name '__pycache__' -type d)" ]]; then
  pass "--verify left no bytecode behind"
else
  fail "--verify created __pycache__"
fi

# ===========================================================================
# C. install and verify-installed
# ===========================================================================

root="${WORK}/install"; build_fixture "${root}"
if run_installer "${root}" --install; then
  pass "--install completes"
else
  fail "--install failed: $(tail -12 "${WORK}/last-run.log")"
fi

if [[ "$(library_count "${root}")" == "81" ]]; then
  pass "the installed library moves 79 -> 81 objects (two CREATEs)"
else
  fail "the installed library holds $(library_count "${root}"), expected 81"
fi

if run_installer "${root}" --verify-installed; then
  pass "--verify-installed accepts the complete Generation-15 target"
else
  fail "--verify-installed rejected the target: $(tail -12 "${WORK}/last-run.log")"
fi

for object in tools/capability/execution/result_content.py \
              tools/capability/execution/contract_outcome.py; do
  if [[ -f "${root}/usr/lib/kyri/python/${object}" ]]; then
    pass "the CREATE published ${object##*/}"
  else
    fail "${object} was not created"
  fi
done

target_verification="$(sha256sum \
  "${root}/usr/lib/kyri/python/tools/capability/execution/verification.py" | cut -d' ' -f1)"
if [[ "${target_verification}" == "7a792aaf3c59ed0bb4bd32cb55267e6fc26dfae06f5da1b8b36efff9e1efa952" ]]; then
  pass "verification.py moved to the reviewed bytes"
else
  fail "verification.py is ${target_verification}"
fi

# The whole point of group V: the repaired library imports.
if ( cd "${root}/usr/lib/kyri/python" && PYTHONDONTWRITEBYTECODE=1 python3 -c \
     'from tools.capability.execution import verification, result_content, contract_outcome' \
     >/dev/null 2>&1 ); then
  pass "the installed verification surface imports as a whole"
else
  fail "the installed verification surface does not import"
fi

# ===========================================================================
# D. the verify entrypoint stays unauthorised
# ===========================================================================

if [[ ! -e "${root}/etc/sudoers.d/kyri-exec-verify" ]]; then
  pass "no verify grant was written"
else
  fail "the installation wrote a verify grant"
fi
if [[ -z "$(find "${root}/usr/libexec" -type f 2>/dev/null)" ]]; then
  pass "no /usr/libexec object was installed"
else
  fail "the installation touched /usr/libexec"
fi

# ===========================================================================
# E. unknown bytes, REPLACE and CREATE
# ===========================================================================

root="${WORK}/unknown-replace"; build_fixture "${root}"
target="${root}/usr/lib/kyri/python/tools/capability/execution/recovery.py"
chmod u+w "${target}"; printf '\n# not the declared baseline\n' >> "${target}"
if run_installer "${root}" --verify; then
  fail "unknown bytes at a REPLACE baseline were accepted"
else
  pass "unknown bytes at a REPLACE baseline are refused"
fi

root="${WORK}/unknown-create"; build_fixture "${root}"
printf '# somebody else\n' > \
  "${root}/usr/lib/kyri/python/tools/capability/execution/result_content.py"
if run_installer "${root}" --verify; then
  fail "a pre-existing CREATE pathname was accepted"
else
  pass "a pre-existing CREATE pathname is refused"
fi

root="${WORK}/unknown-carryover"; build_fixture "${root}"
carry="${root}/usr/lib/kyri/python/tools/capability/execution/snapshot.py"
chmod u+w "${carry}"; printf '\n# drift\n' >> "${carry}"
if run_installer "${root}" --verify; then
  fail "unknown bytes in a carryover object were accepted"
else
  pass "unknown bytes in a carryover object are refused"
fi

# ===========================================================================
# F. crash and recovery at every publication boundary
# ===========================================================================

for point in stage staged prepared precommit committing publish verify postcommit evidence cleanup; do
  root="${WORK}/crash-${point}"; build_fixture "${root}"
  baseline="$(manifest "${root}/usr/lib/kyri/python")"
  run_installer "${root}" --install "KYRI_GEN15_FAIL_AT=${point}" || true

  count="$(library_count "${root}")"
  if [[ "${count}" != "79" && "${count}" != "81" ]]; then
    fail "a failure at '${point}' left ${count} objects: neither generation"
    continue
  fi

  # Residue is acceptable only where the step that removes it is the step that
  # failed. Anywhere else it means an interrupted transaction left artefacts a
  # later run would have to reason about.
  residue="$(find "${root}/usr/lib/kyri/python" \
               \( -name '*.kyri-gen15.new' -o -name '*.kyri-gen15.gen14' \) 2>/dev/null | wc -l)"
  if [[ "${point}" == "cleanup" ]]; then
    if (( residue > 0 )); then
      pass "a failure at 'cleanup' leaves exactly the artefacts cleanup removes"
    else
      fail "a failure at 'cleanup' left nothing for cleanup to remove"
    fi
  elif (( residue == 0 )); then
    pass "a failure at '${point}' leaves no transaction residue"
  else
    fail "a failure at '${point}' left ${residue} transaction artefact(s) behind"
  fi

  # The library root is the generation. The transaction journal and the evidence
  # files are this ceremony's own bookkeeping and are expected to move.
  if [[ "${count}" == "79" ]]; then
    if [[ "$(manifest "${root}/usr/lib/kyri/python")" == "${baseline}" ]]; then
      pass "a failure at '${point}' recovers to the exact Generation-14 library"
    else
      fail "a failure at '${point}' left the Generation-14 library altered"
    fi
  else
    # At target. Every matrix row must hold its Generation-15 bytes; whether the
    # ceremony got as far as writing evidence is a separate question, and
    # --verify-installed refusing without it is correct rather than a defect.
    incomplete=0
    while IFS='|' read -r _ target _ _ _ want _; do
      target="${target/\$\{LIBRARY_ROOT\}/${root}/usr/lib/kyri/python}"
      [[ "$(sha256sum "${target}" 2>/dev/null | cut -d' ' -f1)" == "${want}" ]] \
        || incomplete=1
    done < <(sed -n '/^MATRIX=(/,/^)$/p' "${INSTALLER}" | grep '^"' | tr -d '"')
    if (( incomplete == 0 )); then
      pass "a failure at '${point}' left every matrix row at its Generation-15 bytes"
    else
      fail "a failure at '${point}' left a partially published matrix"
    fi
  fi
done

printf '\n'
if (( FAILURES > 0 )); then
  printf 'Generation-15 installer validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
printf 'Generation-15 installer validation passed.\n'
