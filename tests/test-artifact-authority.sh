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

# The live artifact authority as it stands before anything here runs. Its
# ABSENCE was the right property to assert only until an operator provisioned
# it; afterwards, absence is not a finding and presence is not one either. What
# matters is unchanged: this suite is fixture-only and must be incapable of
# creating, modifying, or removing the live authority. Snapshotted and compared
# exactly as the Fabric store is, so the assertion holds in both states.
LIVE_ARTIFACT_ROOT="/var/lib/kyri/artifacts"       # prod-path-reference
artifact_state() {
  if [[ -e "${LIVE_ARTIFACT_ROOT}" ]]; then
    { find "${LIVE_ARTIFACT_ROOT}" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "${LIVE_ARTIFACT_ROOT}" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
ARTIFACT_BEFORE="$(artifact_state)"
LIVE_MANIFEST="${LIVE_ARTIFACT_ROOT}/kyri-execution-boundary-verification/1.0.0.manifest.json"
LIVE_MANIFEST_BEFORE="$(sha256sum "${LIVE_MANIFEST}" 2>/dev/null | cut -d' ' -f1 || printf absent)"

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
TREE_RELATIVE_LIVE = PACKAGE_NAME + '/' + PACKAGE_VERSION
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

# A real inspection of ACTIVE authority, not a claim. Every path any active
# provisioning ceremony or runtime module binds as an artifact root must be this
# one, and this root must not collide with a plane that already owns a subtree.
# Historical documents are not scanned: they are not authority, and a suite that
# failed on a superseded prose mention would be unmaintainable.
run_case "no active authority claims a conflicting artifact root" "${PRELUDE}
import re
assert 'ARTIFACT_ROOT=\"' + ARTIFACT_ROOT + '\"' in SOURCE, 'the root moved'

# Active authority: provisioning ceremonies, the runtime tree, and the declared
# model. Tests are excluded -- they assert about authority, they are not it.
active = []
for directory in ('provisioning', 'tools', 'platform-model'):
    for path in sorted(Path(directory).rglob('*')):
        if path.is_file() and path.suffix in ('.sh', '.py', '.yaml', '.json') \
                and '__pycache__' not in str(path):
            active.append(path)
assert len(active) > 50, len(active)

# Every literal binding of an artifact-root-shaped name, wherever it is made.
bindings = {}
pattern = re.compile(
    r'(?:ARTIFACT_ROOT|artifact_root|approved_artifact_root|APPROVED_ARTIFACT_ROOT)'
    r'\s*[:=]\s*[\"\']([^\"\']+)[\"\']')
for path in active:
    for value in pattern.findall(path.read_text(encoding='utf-8', errors='replace')):
        if value.startswith('/'):
            bindings.setdefault(value, []).append(str(path))
conflicting = {v: p for v, p in bindings.items() if v != ARTIFACT_ROOT}
assert not conflicting, 'another active authority binds an artifact root: ' + repr(conflicting)

# And the root must not collide with a plane that already owns a subtree.
governed = set()
subtree = re.compile(r'(/var/lib/kyri/[A-Za-z0-9_.-]+)')
for path in active:
    governed.update(subtree.findall(path.read_text(encoding='utf-8', errors='replace')))
owners = {claim for claim in governed
          if claim != ARTIFACT_ROOT
          and (claim.startswith(ARTIFACT_ROOT + '/') or ARTIFACT_ROOT.startswith(claim + '/'))}
assert not owners, 'the artifact root overlaps a governed subtree: ' + repr(owners)
assert ARTIFACT_ROOT.startswith('/var/lib/kyri/') and ARTIFACT_ROOT.count('/') == 4
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
if out="$(ceremony "${FIXTURE_OK}" --install)" \
   && grep -q 'the tree is already published and byte-identical' <<<"${out}"; then
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
  "${FIXTURE_LOOSE}" --install "authority is not trusted"

FIXTURE_WORLD="$(new_fixture)"
chmod 0777 "${FIXTURE_WORLD}${ANCESTRY_PARENT}"
refuses "a world-writable ancestor refuses" \
  "${FIXTURE_WORLD}" --install "authority is not trusted"

# A symlinked component would let publication land outside the authority.
FIXTURE_LINK="$(new_fixture)"
mkdir -p "${FIXTURE_LINK}/elsewhere"; chmod 0755 "${FIXTURE_LINK}/elsewhere"
rm -rf "${FIXTURE_LINK}${ANCESTRY}"
ln -s "${FIXTURE_LINK}/elsewhere" "${FIXTURE_LINK}${ANCESTRY}"
refuses "a symlinked ancestor refuses rather than being followed" \
  "${FIXTURE_LINK}" --install "authority is not trusted"
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

# --- every component, not only the ancestry ---------------------------------
#
# The trusted-source primitive walks EVERY component of the resolved path and
# applies the same rule to each. A ceremony that validated only the ancestors
# ABOVE its root would publish beneath an intermediate package directory the
# runtime later refuses -- reporting DONE and VERIFIED for a tree that can never
# resolve. The provisioning boundary and the resolution boundary have to be the
# same boundary, so these cases attack the components between them.

# The package parent, poisoned before the ceremony ever runs.
poisoned_parent() {
  local mode="$1" base
  base="$(new_fixture)"
  mkdir -p "${base}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
  chmod 0755 "${base}${ARTIFACT_ROOT}"
  chmod "${mode}" "${base}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
  printf '%s' "${base}"
}

parent_state() { stat -c '%a %U %i %h' "$1${ARTIFACT_ROOT}/${PACKAGE_NAME}"; }

for POISON_MODE in 0775 0777; do
  FIXTURE_PARENT="$(poisoned_parent "${POISON_MODE}")"
  PARENT_BEFORE="$(parent_state "${FIXTURE_PARENT}")"

  refuses "a ${POISON_MODE} package parent refuses --install" \
    "${FIXTURE_PARENT}" --install "not trusted"

  # Refused BEFORE anything was created beneath it: no staging tree, no
  # extracted object, no published version, and the parent itself untouched.
  problems=0
  [[ -z "$(ls -A "${FIXTURE_PARENT}${ARTIFACT_ROOT}/${PACKAGE_NAME}")" ]] || problems=1
  [[ ! -e "$(published_of "${FIXTURE_PARENT}")" ]] || problems=1
  [[ "$(parent_state "${FIXTURE_PARENT}")" == "${PARENT_BEFORE}" ]] || problems=1
  if (( problems == 0 )); then
    pass "the ${POISON_MODE} parent is refused before staging, extraction, or publication"
  else
    fail "the ${POISON_MODE} parent was written beneath or modified"
  fi

  refuses "a ${POISON_MODE} package parent refuses --verify" \
    "${FIXTURE_PARENT}" --verify "not trusted"
done

# The inconsistency the correction exists to close: a version tree that is
# itself perfect, beneath a parent the runtime refuses. --verify-installed must
# not report VERIFIED where package resolution would refuse.
FIXTURE_LATE="$(new_fixture)"
ceremony "${FIXTURE_LATE}" --install >/dev/null
chmod 0775 "${FIXTURE_LATE}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
refuses "--verify-installed refuses a published tree under a writable parent" \
  "${FIXTURE_LATE}" --verify-installed "not trusted"

run_case "the ceremony and the released primitive agree on the same tree" "${PRELUDE}
import os
root = '${FIXTURE_LATE}${ARTIFACT_ROOT}'
try:
    handle = open_trusted_directory(root, PACKAGE_NAME + '/' + PACKAGE_VERSION,
                                    expected_uid=UID)
    os.close(handle)
    raise AssertionError('the primitive accepted a writable component')
except TrustedSourceError as error:
    assert 'writable beyond its owner' in str(error), error
# And the owner half of the same rule, which the fixture cannot represent as a
# real foreign uid without privilege: the primitive is the oracle, and the
# ceremony must carry the same requirement rather than a weaker one.
try:
    handle = open_trusted_directory(root, PACKAGE_NAME + '/' + PACKAGE_VERSION,
                                    expected_uid=UID + 1)
    os.close(handle)
    raise AssertionError('the primitive accepted a foreign owner')
except TrustedSourceError as error:
    assert 'not owned by the trusted uid' in str(error), error
print('OK')
"

# A symlinked package parent would let publication land outside the authority
# entirely, and a regular file there is an operator condition to report.
FIXTURE_PLINK="$(new_fixture)"
mkdir -p "${FIXTURE_PLINK}${ARTIFACT_ROOT}" "${FIXTURE_PLINK}/elsewhere"
chmod 0755 "${FIXTURE_PLINK}${ARTIFACT_ROOT}" "${FIXTURE_PLINK}/elsewhere"
ln -s "${FIXTURE_PLINK}/elsewhere" "${FIXTURE_PLINK}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
refuses "a symlinked package parent refuses rather than being followed" \
  "${FIXTURE_PLINK}" --install "not trusted"
if [[ -z "$(ls -A "${FIXTURE_PLINK}/elsewhere")" ]]; then
  pass "nothing was written through the symlinked package parent"
else
  fail "publication wrote through a symlinked package parent"
fi

FIXTURE_PFILE="$(new_fixture)"
mkdir -p "${FIXTURE_PFILE}${ARTIFACT_ROOT}"
chmod 0755 "${FIXTURE_PFILE}${ARTIFACT_ROOT}"
printf 'not a package directory\n' > "${FIXTURE_PFILE}${ARTIFACT_ROOT}/${PACKAGE_NAME}"
PFILE_BEFORE="$(sha256sum "${FIXTURE_PFILE}${ARTIFACT_ROOT}/${PACKAGE_NAME}" | cut -d' ' -f1)"
refuses "a regular file at the package parent refuses" \
  "${FIXTURE_PFILE}" --install "not trusted"
if [[ "$(sha256sum "${FIXTURE_PFILE}${ARTIFACT_ROOT}/${PACKAGE_NAME}" | cut -d' ' -f1)" == "${PFILE_BEFORE}" ]]; then
  pass "the conflicting package parent was neither repaired nor removed"
else
  fail "the conflicting package parent was modified"
fi

# A poisoned ARTIFACT ROOT is the same condition one level up, and the same
# refusal. Proven separately because the root is the component the ceremony may
# create, and creating is where an unchecked assumption would hide.
FIXTURE_ROOTW="$(new_fixture)"
mkdir -p "${FIXTURE_ROOTW}${ARTIFACT_ROOT}"
chmod 0777 "${FIXTURE_ROOTW}${ARTIFACT_ROOT}"
refuses "a world-writable artifact root refuses" \
  "${FIXTURE_ROOTW}" --install "not trusted"

# Nothing is repaired anywhere: every poisoned fixture above must still carry
# exactly the mode it was poisoned with.
assert_no_repair() {
  local problems=0
  [[ "$(stat -c '%a' "${FIXTURE_LATE}${ARTIFACT_ROOT}/${PACKAGE_NAME}")" == "775" ]] || problems=1
  [[ "$(stat -c '%a' "${FIXTURE_ROOTW}${ARTIFACT_ROOT}")" == "777" ]] || problems=1
  [[ -L "${FIXTURE_PLINK}${ARTIFACT_ROOT}/${PACKAGE_NAME}" ]] || problems=1
  if (( problems == 0 )); then
    pass "no refused component was chmod'ed, chown'ed, removed, or renamed"
  else
    fail "the ceremony repaired a component it refused"
  fi
}
assert_no_repair

# The component rule is the primitive's rule, stated once and applied to every
# component -- not a second, weaker interpretation living beside it.
run_case "component validation compares owner and writability on every component" "${PRELUDE}
assert 'check_trusted_component()' in SOURCE, 'there is no single component rule'
component = SOURCE.split('check_trusted_component()')[1].split('\n}')[0]
assert 'stat -c \'%U\'' in component, 'the component rule does not read the owner'
assert 'EXPECTED_OWNER' in component, 'the component rule compares no expected owner'
assert '-perm /022' in component, 'the component rule does not test writability'
assert '-L ' in component, 'the component rule does not refuse a symlink'
assert '-d ' in component, 'the component rule does not require a directory'
# The owner comparison must not be skipped under a fixture: a rule that only
# runs in production is a rule no test exercises.
assert 'FIXTURE' not in component, 'the component rule is weakened under a fixture'
# Applied to the components the ceremony writes beneath, not only the ancestry.
assert 'check_trusted_component \"\${PACKAGE_ROOT}\"' in SOURCE \
    or 'PACKAGE_ROOT' in SOURCE.split('require_trusted_authority()')[1].split('\n}')[0], \
    'the package parent is not validated'
print('OK')
"

# --- the executable manifest ------------------------------------------------
#
# The manifest was authored on the host during S2f, so for one checkpoint the
# answer to "which reviewed object authorised these bytes" was "none". It now
# has its own reviewed source and its own pinned commit -- a different commit
# from the tree's, because the manifest names CPKG-0001 and could not exist
# until that identity was predicted. Pretending one commit authorised both
# would be a pin that never held.

MANIFEST_SOURCE="packages/${PACKAGE_NAME}/${PACKAGE_VERSION}.manifest.json"
MANIFEST_NAME="${PACKAGE_VERSION}.manifest.json"
LIVE_MANIFEST_SHA256="53d4624b5136fbf6a7f5c3d0c577d86419828e0dd6d12c5a031fdeeb64244d4b"

manifest_of() { printf '%s%s/%s/%s' "$1" "${ARTIFACT_ROOT}" "${PACKAGE_NAME}" "${MANIFEST_NAME}"; }

assert_file "${MANIFEST_SOURCE}"

# The whole point of recording it: the repository can reproduce the accepted
# bytes exactly, byte-for-byte, newline included.
assert_source_digest() {
  local observed
  observed="$(sha256sum "${ROOT}/${MANIFEST_SOURCE}" | cut -d' ' -f1)"
  if [[ "${observed}" == "${LIVE_MANIFEST_SHA256}" ]]; then
    pass "the repository manifest source reproduces the accepted digest exactly"
  else
    fail "manifest source is ${observed}, accepted is ${LIVE_MANIFEST_SHA256}"
  fi
}
assert_source_digest

run_case "the manifest source is the governed six fields and nothing else" "${PRELUDE}
import json
body = json.loads(Path('${MANIFEST_SOURCE}').read_text(encoding='utf-8'))
assert set(body) == set(PR.MANIFEST_FIELDS), sorted(body)
assert body['schema_version'] == PR.MANIFEST_SCHEMA_VERSION
assert body['capability_package_id'] == 'CPKG-0001'
assert body['artifact_reference'] == 'tree:' + TREE_RELATIVE_LIVE
assert body['package_tree_sha256'] == TREE_SHA256
assert Path('${MANIFEST_SOURCE}').stat().st_size <= PR.MANIFEST_MAXIMUM_BYTES
print('OK')
"

# Beside the tree, never inside it: a manifest within the tree would have to
# carry a digest taken over its own bytes.
run_case "the manifest source is a sibling of the tree, not a member" "${PRELUDE}
import os
source = Path('${MANIFEST_SOURCE}')
assert source.parent == Path(SOURCE_TREE).parent, source
assert not str(source).startswith(SOURCE_TREE + '/'), source
from tools.capability.execution.package_contract import inspect_package
handle = os.open(SOURCE_TREE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY)
try:
    inspected = inspect_package(handle)
finally:
    os.close(handle)
assert [e.relative_path for e in inspected.entries] == ['main.py'], inspected.entries
assert 'sha256:' + inspected.digest == TREE_SHA256
print('OK')
"

run_case "the manifest is pinned to its own reviewed commit, stated separately" "${PRELUDE}
import re
manifest_commit = re.search(r'MANIFEST_COMMIT=\"([0-9a-f]{40})\"', SOURCE).group(1)
tree_commit = re.search(r'^COMMIT=\"([0-9a-f]{40})\"', SOURCE, re.M).group(1)
assert tree_commit == REVIEWED_COMMIT, tree_commit
assert manifest_commit != tree_commit, 'both objects claim one commit'
assert 'MANIFEST_SHA256=\"' + '${LIVE_MANIFEST_SHA256}' + '\"' in SOURCE
# The manifest exists at its own commit and does NOT exist at the tree's, which
# is exactly why the two pins cannot be collapsed.
present = subprocess.run(['git', 'cat-file', '-e', manifest_commit + ':' + '${MANIFEST_SOURCE}'],
                         capture_output=True)
absent = subprocess.run(['git', 'cat-file', '-e', tree_commit + ':' + '${MANIFEST_SOURCE}'],
                        capture_output=True)
assert present.returncode == 0, 'the manifest is absent at its own pinned commit'
assert absent.returncode != 0, 'the manifest already existed at the tree commit'
blob = subprocess.run(['git', 'cat-file', 'blob', manifest_commit + ':' + '${MANIFEST_SOURCE}'],
                      capture_output=True, check=True).stdout
import hashlib
assert hashlib.sha256(blob).hexdigest() == '${LIVE_MANIFEST_SHA256}'
print('OK')
"

# --- manifest publication, against fixtures ---------------------------------

FIXTURE_MAN="$(new_fixture)"
if out="$(ceremony "${FIXTURE_MAN}" --verify)" && grep -q 'would publish it from' <<<"${out}"; then
  pass "--verify reports an absent manifest as publishable"
else
  fail "--verify on an empty fixture: ${out}"
fi

ceremony "${FIXTURE_MAN}" --install >/dev/null
assert_manifest_shape() {
  local m; m="$(manifest_of "${FIXTURE_MAN}")"
  local problems=0
  [[ -f "${m}" && ! -L "${m}" ]] || { fail "no manifest published"; return; }
  [[ "$(sha256sum "${m}" | cut -d' ' -f1)" == "${LIVE_MANIFEST_SHA256}" ]] || problems=1
  [[ "$(stat -c '%a' "${m}")" == "444" ]] || problems=1
  [[ "$(stat -c '%h' "${m}")" == "1" ]] || problems=1
  [[ -z "$(find "${m}" -perm /022)" ]] || problems=1
  # Published beside the tree, and the tree still holds exactly one member.
  [[ "$(dirname "${m}")" == "$(dirname "$(published_of "${FIXTURE_MAN}")")" ]] || problems=1
  [[ "$(find "$(published_of "${FIXTURE_MAN}")" -type f | wc -l)" == "1" ]] || problems=1
  if (( problems == 0 )); then
    pass "the published manifest is 0444, single-linked, beside the tree, and byte-exact"
  else
    fail "the published manifest has the wrong shape"
  fi
}
assert_manifest_shape

run_case "the published manifest satisfies the trusted-source file contract" "${PRELUDE}
import json, os
root = '${FIXTURE_MAN}${ARTIFACT_ROOT}'
handle = open_trusted_regular_file(
    root, PACKAGE_NAME + '/' + '${MANIFEST_NAME}', expected_uid=UID,
    require_single_link=True, maximum_bytes=PR.MANIFEST_MAXIMUM_BYTES,
    refuse_oversize=True)
try:
    body = json.loads(os.read(handle, PR.MANIFEST_MAXIMUM_BYTES + 1).decode('utf-8'))
finally:
    os.close(handle)

class Evidence:
    capability_package_id = 'CPKG-0001'
    contract_id = 'CCON-0001'
    capability_id = 'CAPDEF-0001'
    artifact_reference = 'tree:' + TREE_RELATIVE_LIVE
    manifest_reference = 'file:' + PACKAGE_NAME + '/' + '${MANIFEST_NAME}'

validated, reason = PR._validated_manifest(body, Evidence())
assert validated is not None, reason
print('OK')
"

# The bytes are the pinned object's. A poisoned working tree must not reach the
# published manifest -- proven by attack, in a clone whose checkout is edited.
run_case "ambient working-tree bytes are not manifest authority" "${PRELUDE}
import re, shutil, subprocess, tempfile
manifest_commit = re.search(r'MANIFEST_COMMIT=\"([0-9a-f]{40})\"', SOURCE).group(1)
with tempfile.TemporaryDirectory() as tmp:
    clone = os.path.join(tmp, 'clone')
    subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', '.', clone], check=True)
    subprocess.run(['git', '-C', clone, 'checkout', '--quiet', '-B',
                    'arch/eng-0005-execution-transition', 'HEAD'], check=True)
    poisoned = os.path.join(clone, '${MANIFEST_SOURCE}')
    Path(poisoned).write_text('{\"poisoned\": true}\n', encoding='utf-8')
    blob = subprocess.run(['git', '-C', clone, 'cat-file', 'blob',
                           manifest_commit + ':' + '${MANIFEST_SOURCE}'],
                          capture_output=True, check=True).stdout
    import hashlib
    assert hashlib.sha256(blob).hexdigest() == '${LIVE_MANIFEST_SHA256}', \
        'the pinned object followed the poisoned working tree'
    assert Path(poisoned).read_bytes() != blob, 'the poison did not take'
print('OK')
"

# Idempotence, and the refusals. Each proves the ceremony changed nothing.
if out="$(ceremony "${FIXTURE_MAN}" --install)" && grep -q 'already published and byte-identical' <<<"${out}"; then
  pass "re-running publication over an identical manifest changes nothing"
else
  fail "second --install: ${out}"
fi

MAN_INODE_BEFORE="$(stat -c '%i %Y' "$(manifest_of "${FIXTURE_MAN}")")"
TREE_INODE_BEFORE="$(stat -c '%i %Y' "$(published_of "${FIXTURE_MAN}")/main.py")"
ceremony "${FIXTURE_MAN}" --install >/dev/null 2>&1 || true
problems=0
[[ "$(stat -c '%i %Y' "$(manifest_of "${FIXTURE_MAN}")")" == "${MAN_INODE_BEFORE}" ]] || problems=1
[[ "$(stat -c '%i %Y' "$(published_of "${FIXTURE_MAN}")/main.py")" == "${TREE_INODE_BEFORE}" ]] || problems=1
if (( problems == 0 )); then
  pass "an idempotent run rewrites neither the manifest nor the package tree"
else
  fail "an idempotent run replaced a published object"
fi

# A manifest installed where the TREE is already correct must still publish,
# without the tree being republished, renamed, or rewritten.
FIXTURE_LATE_MAN="$(new_fixture)"
ceremony "${FIXTURE_LATE_MAN}" --install >/dev/null
chmod u+w "$(dirname "$(manifest_of "${FIXTURE_LATE_MAN}")")"
rm -f "$(manifest_of "${FIXTURE_LATE_MAN}")"
TREE_BEFORE="$(stat -c '%i %Y' "$(published_of "${FIXTURE_LATE_MAN}")/main.py")"
if out="$(ceremony "${FIXTURE_LATE_MAN}" --install)" \
   && grep -q 'the tree is already published and byte-identical' <<<"${out}" \
   && [[ -f "$(manifest_of "${FIXTURE_LATE_MAN}")" ]] \
   && [[ "$(stat -c '%i %Y' "$(published_of "${FIXTURE_LATE_MAN}")/main.py")" == "${TREE_BEFORE}" ]]; then
  pass "a missing manifest is published without the existing tree being touched"
else
  fail "installing a manifest disturbed the published tree: ${out}"
fi

poisoned_manifest() {
  local how="$1" base m
  base="$(new_fixture)"
  ceremony "${base}" --install >/dev/null
  m="$(manifest_of "${base}")"
  chmod u+w "$(dirname "${m}")"
  case "${how}" in
    differing) chmod u+w "${m}"; printf '{"different": true}\n' > "${m}"; chmod 0444 "${m}" ;;
    writable)  chmod 0666 "${m}" ;;
    symlink)   rm -f "${m}"; printf '{}\n' > "$(dirname "${m}")/elsewhere.json"
               ln -s "$(dirname "${m}")/elsewhere.json" "${m}" ;;
    multilink) rm -f "${m}"; printf '%s' "$(cat "${ROOT}/${MANIFEST_SOURCE}")" > "$(dirname "${m}")/other.json"
               cp "${ROOT}/${MANIFEST_SOURCE}" "${m}"; ln -f "${m}" "$(dirname "${m}")/alias.json"
               chmod 0444 "${m}" ;;
  esac
  printf '%s' "${base}"
}

for HOW in differing writable symlink multilink; do
  FIXTURE_PM="$(poisoned_manifest "${HOW}")"
  MPATH="$(manifest_of "${FIXTURE_PM}")"
  STATE_BEFORE="$(stat -c '%a %U %i %h' "${MPATH}" 2>/dev/null || printf 'symlink')"
  refuses "a ${HOW} manifest refuses --install" "${FIXTURE_PM}" --install "not replaced or repaired"
  refuses "a ${HOW} manifest refuses --verify-installed" "${FIXTURE_PM}" --verify-installed "problem(s)"
  STATE_AFTER="$(stat -c '%a %U %i %h' "${MPATH}" 2>/dev/null || printf 'symlink')"
  if [[ "${STATE_BEFORE}" == "${STATE_AFTER}" ]]; then
    pass "the ${HOW} manifest was neither repaired nor replaced"
  else
    fail "the ${HOW} manifest was modified: ${STATE_BEFORE} -> ${STATE_AFTER}"
  fi
done

# --- the operator invocation contract ---------------------------------------
#
# Four values carry a trust boundary each and have no default anywhere in the
# runtime. Before this runbook existed they lived only in a session transcript.

RUNBOOK="provisioning/artifacts/README.md"
assert_file "${RUNBOOK}"

assert_runbook() {
  local missing=()
  local needle
  for needle in "/var/lib/kyri/artifacts" "--trusted-source-uid" "--approved-artifact-root" \
                "--expected-uid" "--expected-gid" "/etc/kyri/fabric" \
                "declare-package --preflight" "geteuid" "2575c042" "49c27fb6"; do
    grep -qF -- "${needle}" "${ROOT}/${RUNBOOK}" || missing+=("${needle}")
  done
  if (( ${#missing[@]} == 0 )); then
    pass "the runbook records every load-bearing value, both pins, and both invocations"
  else
    fail "the runbook omits: ${missing[*]}"
  fi
}
assert_runbook

# The values are documented, never turned into runtime defaults: a default is
# the runtime deciding for itself whose bytes to trust.
run_case "no runtime surface defaults these values" "${PRELUDE}
cli = Path('tools/capability/cli.py').read_text(encoding='utf-8')
for flag in ('--approved-artifact-root', '--trusted-source-uid', '--coordinator-uid'):
    line = [row for row in cli.splitlines() if flag in row]
    assert line, flag
    assert all('default=' not in row for row in line), flag + ' acquired a default'
    assert any('required=True' in row for row in line), flag + ' is no longer required'
fabric = Path('tools/fabric/cli.py').read_text(encoding='utf-8')
for flag in ('--store-root', '--expected-uid', '--expected-gid'):
    rows = [row for row in fabric.splitlines() if flag in row and 'add_argument' in row]
    assert rows, flag
    assert all('default=' not in row for row in rows), flag + ' acquired a default'
resolution = Path('tools/capability/package_resolution.py').read_text(encoding='utf-8')
assert 'geteuid' not in resolution, 'resolution infers a uid from the process'
assert 'getuid' not in resolution, 'resolution infers a uid from the process'
trusted = Path('tools/common/trusted_source.py').read_text(encoding='utf-8')
assert 'geteuid' not in trusted and 'getuid' not in trusted, \
    'the trusted-source primitive infers a uid from the process'
print('OK')
"

# --- what the ceremony must never touch -------------------------------------

assert_untouched() {
  local problems=0
  if [[ "$(artifact_state)" != "${ARTIFACT_BEFORE}" ]]; then
    fail "the live artifact authority moved"; problems=1
  fi
  # An ABSENT package sequence and an empty CPKG namespace were the right
  # properties to assert only until an operator declared the first package.
  # Afterwards neither emptiness nor a record is a finding. The property that
  # never changes -- this suite cannot write into the production store -- is
  # already asserted below by comparing the whole store against its pre-suite
  # snapshot, which covers the sequence and the namespace together.
  if [[ "$(sha256sum "${LIVE_MANIFEST}" 2>/dev/null | cut -d' ' -f1 || printf absent)" \
        != "${LIVE_MANIFEST_BEFORE}" ]]; then
    fail "the live manifest moved"; problems=1
  fi
  if (( problems == 0 )); then
    pass "the live artifact authority and its manifest are unchanged"
  fi
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
