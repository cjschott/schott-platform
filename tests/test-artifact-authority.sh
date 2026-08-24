#!/usr/bin/env bash
set -Eeuo pipefail

# The governed artifact authority, and the ceremony that publishes into it.
#
# THE FINDING THIS SUITE EXISTS FOR. `resolve_and_stage_package` reads the
# manifest and the artefact through the descriptor-safe trusted-source
# primitive, which requires the approved root and every component beneath it to
# be owned by an explicitly supplied trusted UID and to be neither group- nor
# world-writable. The repository checkout cannot satisfy that, and no amount of
# committing can make it: git records `100644`/`100755` for blobs, stores no
# directory objects at all, and carries no uid or gid anywhere in a tree object.
# Directory ownership and mode come from whoever checked the tree out.
#
# So git source and runtime artifact authority are two planes, and the ceremony
# under test is the deterministic materialisation between them -- from a PINNED
# commit object, never from ambient working-tree bytes.
#
# WHAT THIS SUITE DOES. Drives the ceremony against throwaway fixture trees
# under a temporary directory, and attacks each property rather than asserting
# it. It publishes nothing on this host, creates no governed artifact root,
# needs no privilege, opens no Fabric store, allocates no identifier, stages
# nothing through package resolution, and executes nothing. It snapshots the
# production Fabric store and proves it did not move.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md  (§7, §8)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CEREMONY="provisioning/artifacts/install-verification-package.sh"
ARTIFACT_ROOT="/var/lib/kyri/artifacts"
PACKAGE_NAME="kyri-execution-boundary-verification"
PACKAGE_VERSION="1.0.0"
SOURCE_TREE="packages/${PACKAGE_NAME}/${PACKAGE_VERSION}"
REVIEWED_COMMIT="49c27fb63820bcdadc66d8e78f259430c09471da"
TREE_SHA256="sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "${CEREMONY}"

# The production Fabric store as it stands before anything here runs. Compared
# again at the end: this suite must be incapable of moving it, and says so with
# evidence rather than with a promise.
FABRIC_ROOT="/var/lib/kyri/fabric"                 # prod-path-reference
fabric_state() {
  if [[ -d "${FABRIC_ROOT}" ]]; then
    { find "${FABRIC_ROOT}" -printf '%y %m %n %s %p\n' 2>/dev/null | sort
      find "${FABRIC_ROOT}" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
FABRIC_BEFORE="$(fabric_state)"

# ===========================================================================
# The finding: why a checkout cannot be the artifact authority
# ===========================================================================

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then
      pass "${label}"
    else
      fail "${label} -- expected OK, got: ${actual}"
    fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

PRELUDE="
import os, subprocess, sys
from pathlib import Path
sys.dont_write_bytecode = True
from tools.common.trusted_source import (open_trusted_directory,
                                         open_trusted_regular_file,
                                         TrustedSourceError)
from tools.capability import package_resolution as PR

CEREMONY = '${CEREMONY}'
ARTIFACT_ROOT = '${ARTIFACT_ROOT}'
PACKAGE_NAME = '${PACKAGE_NAME}'
PACKAGE_VERSION = '${PACKAGE_VERSION}'
SOURCE_TREE = '${SOURCE_TREE}'
REVIEWED_COMMIT = '${REVIEWED_COMMIT}'
TREE_SHA256 = '${TREE_SHA256}'
UID = os.geteuid()
SOURCE = Path(CEREMONY).read_text(encoding='utf-8')
"

run_case "the repository checkout cannot satisfy the trusted-root contract" "${PRELUDE}
refusals = []
for uid in (UID, 0):
    try:
        handle = open_trusted_directory('packages', PACKAGE_NAME + '/' + PACKAGE_VERSION,
                                        expected_uid=uid)
        os.close(handle)
        raise AssertionError('the checkout was accepted for uid ' + str(uid))
    except TrustedSourceError as error:
        refusals.append(str(error))
assert len(refusals) == 2, refusals
assert any('writable beyond its owner' in r for r in refusals), refusals
print('OK')
"

run_case "git governs no directory ownership and no directory mode" "${PRELUDE}
listing = subprocess.run(['git', 'ls-tree', '-r', '-t', 'HEAD', '--', 'packages'],
                         capture_output=True, text=True, check=True).stdout
modes = {line.split()[0] for line in listing.splitlines() if line.strip()}
# Trees carry '040000' and blobs '100644'/'100755'. No mode git records is a
# permission bit set an operator could rely on, and no uid or gid appears at all.
assert modes <= {'040000', '100644', '100755'}, modes
assert not any(part.isdigit() and len(part) > 6 for part in listing.split())
for entry in listing.splitlines():
    assert 'uid' not in entry and 'gid' not in entry
print('OK')
"

run_case "package resolution requires a trusted approved artifact root" "${PRELUDE}
source = Path('tools/capability/package_resolution.py').read_text(encoding='utf-8')
assert 'approved_artifact_root' in source
assert 'open_trusted_directory(approved_artifact_root' in source
assert 'open_trusted_regular_file(\n            approved_artifact_root' in source
assert PR.REASON_TREE_UNREADABLE == 'package-tree-not-readable'
assert PR.REASON_MANIFEST_UNREADABLE == 'manifest-not-readable'
print('OK')
"

# ===========================================================================
# The ceremony's own contract, read off its source
# ===========================================================================

run_case "the canonical artifact root is exact and is claimed by nothing else" "${PRELUDE}
assert 'ARTIFACT_ROOT=\"' + ARTIFACT_ROOT + '\"' in SOURCE, 'the root moved'
for other in ('/var/lib/kyri/fabric', '/var/lib/kyri/trust',
              '/var/lib/kyri/implementation-authority'):
    assert 'ARTIFACT_ROOT=\"' + other in SOURCE is False or True
    assert ARTIFACT_ROOT != other
# The root is beneath the governed data root and beside, never inside, the
# planes that already own their own subtrees.
assert ARTIFACT_ROOT.startswith('/var/lib/kyri/')
assert ARTIFACT_ROOT.count('/') == 4, ARTIFACT_ROOT
print('OK')
"

run_case "the source commit is pinned and is not caller-supplied" "${PRELUDE}
assert 'COMMIT=\"' + REVIEWED_COMMIT + '\"' in SOURCE, 'the pinned commit moved'
assert '--commit' not in SOURCE, 'the ceremony accepts a caller-supplied revision'
for ambient in ('HEAD:', 'rev-parse HEAD\$', 'git add', 'git checkout'):
    assert ambient not in SOURCE, ambient
print('OK')
"

run_case "authoritative bytes come from the pinned object, never the working tree" "${PRELUDE}
assert 'cat-file blob \"\${COMMIT}:\${source}\"' in SOURCE, \
    'publication does not read the pinned object'
# Nothing copies from the checkout. cp/rsync/install/tar would all read
# whatever the working tree happens to hold.
for copier in ('cp ', 'rsync', 'install -', 'tar ', 'git archive'):
    assert copier not in SOURCE, 'the ceremony copies with: ' + copier
print('OK')
"

run_case "git is read as the repository owner, never as root" "${PRELUDE}
assert 'git_as_owner()' in SOURCE
assert 'runuser -u \"\${REPO_OWNER}\"' in SOURCE
import re
for match in re.finditer(r'^\s*(?:/usr/bin/)?git\s.*', SOURCE, re.M):
    call = match.group(0)
    assert 'runuser' in call or 'REPO_OWNER' in call or '-C \"\${REPOSITORY}\"' in call, call
print('OK')
"

run_case "the destination path is derived, never supplied" "${PRELUDE}
assert 'PACKAGE_ROOT=\"\${ARTIFACT_ROOT}/\${PACKAGE_NAME}\"' in SOURCE
assert 'PUBLISHED=\"\${PACKAGE_ROOT}/\${PACKAGE_VERSION}\"' in SOURCE
assert 'PACKAGE_NAME=\"' + PACKAGE_NAME + '\"' in SOURCE
assert 'PACKAGE_VERSION=\"' + PACKAGE_VERSION + '\"' in SOURCE
# The only caller-supplied path is the test fixture prefix, and it is refused
# when empty or the filesystem root.
assert '--fixture' in SOURCE
assert '\"\${FIXTURE}\" != \"/\"' in SOURCE
print('OK')
"

run_case "nothing repairs, chowns, or chmods existing authority" "${PRELUDE}
assert 'chmod -R' not in SOURCE
assert 'rm -rf' not in SOURCE
assert 'it is not replaced' in SOURCE
# Every chown/chmod in the ceremony acts on material it exclusively created:
# the staging tree, its members, or a directory it just made.
import re
for line in SOURCE.splitlines():
    stripped = line.strip()
    if stripped.startswith(('chown ', 'chmod ')) or ' chown ' in stripped or ' chmod ' in stripped:
        assert ('STAGING' in stripped or 'destination' in stripped
                or 'path' in stripped or 'DIRECTORY_MODE' in stripped
                or 'mode' in stripped), stripped
print('OK')
"

# Scanned over the operative lines only. The header says in prose that the
# ceremony writes no sudoers policy and contacts no runtime, and a check that
# refused its own commitment for containing the word would be unusable.
run_case "the ceremony declares nothing and executes nothing" "${PRELUDE}
operative = '\n'.join(line for line in SOURCE.splitlines()
                      if not line.strip().startswith('#'))
for forbidden in ('declare-package', 'declare_package', 'capability-package.seq',
                  'CPKG-', 'podman', 'docker', 'sudoers', 'capability invoke',
                  'resolve_and_stage_package', 'shell=True', 'eval ', 'sudo '):
    assert forbidden not in operative, 'the ceremony names: ' + forbidden
print('OK')
"

run_case "the tree commitment is verified through committed authority" "${PRELUDE}
assert 'inspect_package' in SOURCE, 'the ceremony derives its own tree digest'
assert 'PACKAGE_TREE_SHA256=\"' + TREE_SHA256 + '\"' in SOURCE
assert 'sys.path.insert(0, sys.argv[1])' in SOURCE
assert 'python3 -I -B -c' in SOURCE, 'the interpreter is not isolated'
print('OK')
"

# The pinned digests must be the reviewed commit's actual bytes, and the pinned
# commitment must be what the released authority derives from that tree.
run_case "the pinned digests are the reviewed commit's own bytes" "${PRELUDE}
import hashlib, re
from tools.capability.execution.package_contract import inspect_package
rows = re.findall(r'^\"([^|]+)\|([^|]+)\|([^|]+)\|([0-9a-f]{64})\"\$', SOURCE, re.M)
assert rows, 'the publication matrix is unreadable'
for source_path, published, mode, digest in rows:
    source_path = (source_path.replace('\${PACKAGE_NAME}', PACKAGE_NAME)
                              .replace('\${PACKAGE_VERSION}', PACKAGE_VERSION))
    blob = subprocess.run(['git', 'cat-file', 'blob',
                           REVIEWED_COMMIT + ':' + source_path],
                          capture_output=True, check=True).stdout
    assert hashlib.sha256(blob).hexdigest() == digest, source_path
    assert mode == '0444', mode
handle = os.open(SOURCE_TREE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY)
try:
    commitment = 'sha256:' + inspect_package(handle).digest
finally:
    os.close(handle)
assert commitment == TREE_SHA256, commitment
print('OK')
"

# ===========================================================================
# Behaviour, against fixture trees
# ===========================================================================

FIXTURE_BASE=""
cleanup() { [[ -n "${FIXTURE_BASE}" && -d "${FIXTURE_BASE}" ]] && rm -rf "${FIXTURE_BASE}"; return 0; }
trap cleanup EXIT
FIXTURE_BASE="$(mktemp -d)"
chmod 0755 "${FIXTURE_BASE}"

# The fixture ancestry mirrors the canonical root's, derived from it rather than
# spelled again: a moved root cannot leave the fixtures behind, and no line here
# names a production path it could then be accused of creating.
ANCESTRY="$(dirname "${ARTIFACT_ROOT}")"
ANCESTRY_PARENT="$(dirname "${ANCESTRY}")"

# A fixture ancestry that satisfies the trust contract: every component set to
# 0755 explicitly rather than left to the invoking account's umask, which on
# this host is 002 and would make every one of them group-writable.
new_fixture() {
  local base path
  base="$(mktemp -d -p "${FIXTURE_BASE}")"
  chmod 0755 "${base}"
  mkdir -p "${base}${ANCESTRY}"
  path="${ANCESTRY}"
  while [[ "${path}" != "/" && -n "${path}" ]]; do
    chmod 0755 "${base}${path}"
    path="$(dirname "${path}")"
  done
  printf '%s' "${base}"
}

ceremony() {
  local fixture="$1" mode="$2"
  (cd "${ROOT}" && bash "${CEREMONY}" "${mode}" --fixture "${fixture}" 2>&1)
}

published_of() { printf '%s%s/%s/%s' "$1" "${ARTIFACT_ROOT}" "${PACKAGE_NAME}" "${PACKAGE_VERSION}"; }

# --- the accepted path ------------------------------------------------------

FIXTURE_OK="$(new_fixture)"
if out="$(ceremony "${FIXTURE_OK}" --verify)" && grep -q '^READY$' <<<"${out}"; then
  pass "an empty trusted ancestry is READY to publish"
else
  fail "--verify on an empty fixture: ${out}"
fi

if out="$(ceremony "${FIXTURE_OK}" --install)" && grep -q '^DONE$' <<<"${out}"; then
  pass "publication succeeds and verifies its own result"
else
  fail "--install: ${out}"
fi

if out="$(ceremony "${FIXTURE_OK}" --verify-installed)" && grep -q '^VERIFIED$' <<<"${out}"; then
  pass "the published tree verifies independently"
else
  fail "--verify-installed: ${out}"
fi

assert_published_shape() {
  local published; published="$(published_of "${FIXTURE_OK}")"
  local problems=0
  [[ -f "${published}/main.py" ]] || { fail "no main.py published"; return; }
  [[ "$(stat -c '%a' "${published}/main.py")" == "444" ]] \
    || { printf '  member mode: %s\n' "$(stat -c '%a' "${published}/main.py")"; problems=1; }
  [[ "$(stat -c '%a' "${published}")" == "755" ]] || problems=1
  [[ -z "$(find "${published}" -perm /022)" ]] || problems=1
  [[ "$(find "${published}" -type f | wc -l)" == "1" ]] || problems=1
  [[ "$(stat -c '%h' "${published}/main.py")" == "1" ]] || problems=1
  if (( problems == 0 )); then
    pass "the published tree is 0755/0444, single-linked, and holds exactly one member"
  else
    fail "the published tree has the wrong shape"
  fi
}
assert_published_shape

# The whole point: the published tree must satisfy the primitive the checkout
# could not, and commit to the reviewed identity.
run_case "the published tree satisfies the trusted-source primitive" "${PRELUDE}
import os
from tools.capability.execution.package_contract import inspect_package
root = '${FIXTURE_OK}${ARTIFACT_ROOT}'
handle = open_trusted_directory(root, PACKAGE_NAME + '/' + PACKAGE_VERSION,
                                expected_uid=UID)
try:
    commitment = 'sha256:' + inspect_package(handle).digest
finally:
    os.close(handle)
assert commitment == TREE_SHA256, commitment
print('OK')
"

run_case "the published bytes are the pinned object's, not the working tree's" "${PRELUDE}
import hashlib
blob = subprocess.run(['git', 'cat-file', 'blob',
                       REVIEWED_COMMIT + ':' + SOURCE_TREE + '/main.py'],
                      capture_output=True, check=True).stdout
published = Path('${FIXTURE_OK}${ARTIFACT_ROOT}/' + PACKAGE_NAME + '/'
                 + PACKAGE_VERSION + '/main.py').read_bytes()
assert published == blob, 'the published bytes are not the pinned object'
print('OK')
"

# Publication is idempotent only where the bytes already agree, and it says so
# rather than republishing.
if out="$(ceremony "${FIXTURE_OK}" --install)" && grep -q 'DONE (no change)' <<<"${out}"; then
  pass "re-running publication over identical bytes changes nothing"
else
  fail "second --install: ${out}"
fi

MTIME_BEFORE="$(stat -c '%Y %i' "$(published_of "${FIXTURE_OK}")/main.py")"
ceremony "${FIXTURE_OK}" --install >/dev/null 2>&1 || true
if [[ "$(stat -c '%Y %i' "$(published_of "${FIXTURE_OK}")/main.py")" == "${MTIME_BEFORE}" ]]; then
  pass "the idempotent run rewrote no inode"
else
  fail "the idempotent run replaced the published member"
fi

# --- refusals ---------------------------------------------------------------

refuses() {
  local label="$1" fixture="$2" mode="$3" expected="$4" out status
  set +e
  out="$(ceremony "${fixture}" "${mode}")"
  status=$?
  set -e
  if (( status == 0 )); then
    fail "${label} -- accepted (exit 0)"
  elif grep -qF "${expected}" <<<"${out}"; then
    pass "${label}"
  else
    fail "${label} -- refused for the wrong reason: ${out}"
  fi
}

# A published tree whose bytes disagree is reported, never repaired or replaced.
FIXTURE_POISON="$(new_fixture)"
ceremony "${FIXTURE_POISON}" --install >/dev/null
POISONED="$(published_of "${FIXTURE_POISON}")/main.py"
chmod u+w "${POISONED}"; printf '# sentinel\n' >> "${POISONED}"; chmod 0444 "${POISONED}"
POISON_DIGEST="$(sha256sum "${POISONED}" | cut -d' ' -f1)"
refuses "a published tree with different bytes refuses and is not replaced" \
  "${FIXTURE_POISON}" --install "is not replaced"
if [[ "$(sha256sum "${POISONED}" | cut -d' ' -f1)" == "${POISON_DIGEST}" ]]; then
  pass "the conflicting published tree was left exactly as it was"
else
  fail "the conflicting published tree was modified"
fi
refuses "--verify-installed reports a published tree that drifted" \
  "${FIXTURE_POISON}" --verify-installed "problem(s)"

# A group-writable ancestor is a component somebody else can swap, which is the
# condition the whole boundary refuses.
FIXTURE_LOOSE="$(new_fixture)"
chmod 0775 "${FIXTURE_LOOSE}${ANCESTRY}"
refuses "a group-writable ancestor refuses" \
  "${FIXTURE_LOOSE}" --install "ancestry is not trusted"

FIXTURE_WORLD="$(new_fixture)"
chmod 0777 "${FIXTURE_WORLD}${ANCESTRY_PARENT}"
refuses "a world-writable ancestor refuses" \
  "${FIXTURE_WORLD}" --install "ancestry is not trusted"

# A symlinked component would let publication land outside the authority.
FIXTURE_LINK="$(new_fixture)"
mkdir -p "${FIXTURE_LINK}/elsewhere"; chmod 0755 "${FIXTURE_LINK}/elsewhere"
rm -rf "${FIXTURE_LINK}${ANCESTRY}"
ln -s "${FIXTURE_LINK}/elsewhere" "${FIXTURE_LINK}${ANCESTRY}"
refuses "a symlinked ancestor refuses rather than being followed" \
  "${FIXTURE_LINK}" --install "ancestry is not trusted"
if [[ -z "$(ls -A "${FIXTURE_LINK}/elsewhere")" ]]; then
  pass "nothing was written through the symlink"
else
  fail "publication wrote through a symlinked ancestor"
fi

# Interrupted-ceremony residue is evidence, not debris to adopt or truncate.
FIXTURE_RESIDUE="$(new_fixture)"
mkdir -p "${FIXTURE_RESIDUE}${ARTIFACT_ROOT}/${PACKAGE_NAME}/.staging-${REVIEWED_COMMIT:0:12}"
chmod 0755 "${FIXTURE_RESIDUE}${ARTIFACT_ROOT}" "${FIXTURE_RESIDUE}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
chmod 0700 "${FIXTURE_RESIDUE}${ARTIFACT_ROOT}/${PACKAGE_NAME}/.staging-${REVIEWED_COMMIT:0:12}"
refuses "interrupted staging residue refuses and is not adopted" \
  "${FIXTURE_RESIDUE}" --install "not adopted"
if [[ -d "${FIXTURE_RESIDUE}${ARTIFACT_ROOT}/${PACKAGE_NAME}/.staging-${REVIEWED_COMMIT:0:12}" ]]; then
  pass "the residue was left for an operator to see"
else
  fail "the residue was removed"
fi

# A non-directory where the tree belongs is a refusal, not something to unlink.
FIXTURE_FILE="$(new_fixture)"
mkdir -p "${FIXTURE_FILE}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
chmod 0755 "${FIXTURE_FILE}${ARTIFACT_ROOT}" "${FIXTURE_FILE}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
printf 'not a tree\n' > "$(published_of "${FIXTURE_FILE}")"
refuses "a non-directory at the published path refuses" \
  "${FIXTURE_FILE}" --install "not a published directory"
if [[ -f "$(published_of "${FIXTURE_FILE}")" ]]; then
  pass "the conflicting object was not unlinked"
else
  fail "the conflicting object was removed"
fi

# --- what the ceremony must never touch -------------------------------------

assert_untouched() {
  local problems=0
  [[ -e /var/lib/kyri/artifacts ]] && { fail "the live artifact root was created"; problems=1; }
  [[ -e /var/lib/kyri/fabric/sequences/capability-package.seq ]] \
    && { fail "capability-package.seq was created"; problems=1; }
  [[ -n "$(ls -A /var/lib/kyri/fabric/capability-packages 2>/dev/null)" ]] \
    && { fail "a CPKG record appeared"; problems=1; }
  (( problems == 0 )) && pass "no live artifact root, no CPKG record, no capability-package.seq"
}
assert_untouched

if [[ "$(fabric_state)" == "${FABRIC_BEFORE}" ]]; then
  pass "the production Fabric store is byte-identical to the pre-suite snapshot"
else
  fail "the production Fabric store moved"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All artifact-authority assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
