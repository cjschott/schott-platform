#!/usr/bin/env bash
set -Eeuo pipefail

# The trusted deployment Evidence authority, and the resolution that closes R7.
#
# WHAT WAS MISSING. `verification_reference` was required to be present and was
# never resolved, so a host could claim a verified profile against a reference
# naming nothing. Resolving it out of `platform-model/evidence/` was not an
# option: that would make a permanent, immutable governance record depend on a
# mutable Git working tree, which is the argument the artifact authority already
# settled for package bytes.
#
# THREE EVIDENCE PLANES, and this suite exercises the bridge between two:
#
#   platform-model/evidence/   declarative, reviewed, Git-governed.  SOURCE
#   /var/lib/kyri/evidence     root-owned deployment authority.      DESTINATION
#   tools/observation store    dynamic collector history; refuses a root inside
#                              a repository. NOT USED HERE, and not reusable:
#                              it provisions directories on construction and
#                              allocates from a sequence, and there is nothing
#                              to allocate for an identity the model fixed.
#
# EXISTENCE IS NOT VERIFICATION. A record that exists, parses and fingerprints
# correctly can still be about a different machine or a different dimension.
# The binding half is tested separately from the resolution half for exactly
# that reason.
#
# Fixture-only. Builds throwaway authorities under a temporary directory,
# publishes nothing on this host, needs no privilege, and proves the production
# Fabric, Trust and Evidence state is unchanged when it finishes.
#
# Governed by:
#   platform-model/schemas/evidence.schema.yaml
#   platform-model/schemas/capability-host.schema.yaml (platform_model_node_identity)
#   docs/standards/evidence-standard.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CEREMONY="provisioning/evidence/install-host-evidence.sh"

# This suite drives an operator ceremony that pins its repository as
# production authority; where the checkout is not that pin the ceremony would
# read a different repository. Host-only rather than failing for a reason
# unrelated to what it tests.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${ROOT}/${CEREMONY}"

EVIDENCE_ROOT="/var/lib/kyri/evidence"
EVIDENCE_ID="EVID-000001"
EVIDENCE_SOURCE="platform-model/evidence/evid-000001-schai-host-architecture.yaml"
REVIEWED_COMMIT="061a1a158575553c1e02d33c4d237e63e0a702e9"
EVIDENCE_SHA256="ee88f34e2f28b0bf5b8b16e85320b91d30a371496b810a6a0baa3ef4df8c5c53"
EVIDENCE_FINGERPRINT="sha256:ef8e46f8fdafd0342853b8f802665ecb9be8246c820d866373eb88cc75b30537"
HOST_IDENTITY="HOST-0001"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

FABRIC_ROOT="/var/lib/kyri/fabric"                 # prod-path-reference
TRUST_ROOT="/var/lib/kyri/trust"                   # prod-path-reference
LIVE_EVIDENCE="/var/lib/kyri/evidence"             # prod-path-reference
production_state() {
  if [[ -e "$1" ]]; then
    { find "$1" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "$1" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
FABRIC_BEFORE="$(production_state "${FABRIC_ROOT}")"
TRUST_BEFORE="$(production_state "${TRUST_ROOT}")"
LIVE_EVIDENCE_BEFORE="$(production_state "${LIVE_EVIDENCE}")"
SOURCE_BEFORE="$(sha256sum "${ROOT}/${EVIDENCE_SOURCE}" | cut -d' ' -f1)"

assert_file "${CEREMONY}"
assert_file "tools/fabric/evidence_authority.py"

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
import hashlib, os, subprocess, sys
from pathlib import Path
from tempfile import TemporaryDirectory
sys.dont_write_bytecode = True

from tools.common.yaml_strict import load_strict
from tools.fabric import admission as A
from tools.fabric import evidence_authority as EA
from tools.fabric.store import FabricStore
from tools.trust.store import TrustStore

UID = os.geteuid()
GID = os.getegid()
CEREMONY = '${CEREMONY}'
EVIDENCE_ROOT = '${EVIDENCE_ROOT}'
EVIDENCE_ID = '${EVIDENCE_ID}'
EVIDENCE_SOURCE = '${EVIDENCE_SOURCE}'
REVIEWED_COMMIT = '${REVIEWED_COMMIT}'
EVIDENCE_SHA256 = '${EVIDENCE_SHA256}'
EVIDENCE_FINGERPRINT = '${EVIDENCE_FINGERPRINT}'
HOST_IDENTITY = '${HOST_IDENTITY}'
SOURCE = Path(CEREMONY).read_text(encoding='utf-8')
RESOLVER_SOURCE = Path('tools/fabric/evidence_authority.py').read_text(encoding='utf-8')

def operative(text):
    '''Code only. These modules state in prose exactly what they refuse to do,
    and a raw scan would read the explanation as the offence.'''
    out, in_doc = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(('\'\'\'', '\"\"\"')) or stripped.endswith(('\'\'\'', '\"\"\"')):
            if stripped.count('\'\'\'') == 2 or stripped.count('\"\"\"') == 2:
                continue
            in_doc = not in_doc
            continue
        if in_doc or stripped.startswith('#'):
            continue
        out.append(line)
    return '\n'.join(out)
"

# ===========================================================================
# The authority: root, distinction, and pinning
# ===========================================================================

run_case "the deployment Evidence root is unclaimed by any other plane" "${PRELUDE}
import re
active = []
for directory in ('provisioning', 'tools', 'platform-model'):
    for path in sorted(Path(directory).rglob('*')):
        if path.is_file() and path.suffix in ('.sh', '.py', '.yaml', '.json') \\
                and '__pycache__' not in str(path):
            active.append(path)
claims = set()
for path in active:
    claims.update(re.findall(r'(/var/lib/kyri/[A-Za-z0-9_.-]+)',
                             path.read_text(encoding='utf-8', errors='replace')))
overlapping = {c for c in claims if c != EVIDENCE_ROOT
               and (c.startswith(EVIDENCE_ROOT + '/') or EVIDENCE_ROOT.startswith(c + '/'))}
assert not overlapping, sorted(overlapping)
for owned in ('/var/lib/kyri/fabric', '/var/lib/kyri/trust', '/var/lib/kyri/artifacts',
              '/var/lib/kyri/implementation-authority'):
    assert EVIDENCE_ROOT != owned
print('OK')
"

# The dynamic store is not reused, and the reason is behavioural rather than
# stylistic: it creates what it is asked to describe.
run_case "the dynamic Observation store is not reused, and could not be" "${PRELUDE}
from tools.observation.evidence_store import EvidenceStore
with TemporaryDirectory() as tmp:
    root = Path(tmp) / 'dynamic'
    EvidenceStore(root)
    assert root.exists(), 'the dynamic store did not create its root'
    created = sorted(p.name for p in root.iterdir())
    assert 'evidence' in created, created
assert 'EvidenceStore' not in SOURCE, 'the ceremony instantiates the dynamic store'
code = operative(RESOLVER_SOURCE)
assert 'EvidenceStore' not in code, 'the resolver instantiates the dynamic store'
# And the resolver creates nothing of its own.
for forbidden in ('mkdir', 'makedirs', 'chmod', 'chown', 'O_CREAT', 'write('):
    assert forbidden not in code, 'the resolver can write: ' + forbidden
print('OK')
"

run_case "the ceremony pins the reviewed commit and is not caller-selected" "${PRELUDE}
assert 'EVIDENCE_COMMIT=\"' + REVIEWED_COMMIT + '\"' in SOURCE, 'the pin moved'
assert 'EVIDENCE_SHA256=\"' + EVIDENCE_SHA256 + '\"' in SOURCE
assert 'EVIDENCE_FINGERPRINT=\"' + EVIDENCE_FINGERPRINT + '\"' in SOURCE
assert '--commit' not in SOURCE and '--evid' not in SOURCE, \\
    'the ceremony accepts a caller-selected source'
assert 'cat-file blob \"\${EVIDENCE_COMMIT}:\${EVIDENCE_SOURCE}\"' in SOURCE
for copier in ('cp ', 'rsync', 'install -', 'tar ', 'git archive'):
    assert copier not in SOURCE, 'the ceremony copies with: ' + copier
# The pinned commit is the only commit that has ever touched the record, so it
# is unambiguously the reviewing one.
touching = subprocess.run(['git', 'log', '--format=%H', '--', EVIDENCE_SOURCE],
                          capture_output=True, text=True, check=True).stdout.split()
assert touching == [REVIEWED_COMMIT], touching
blob = subprocess.run(['git', 'cat-file', 'blob', REVIEWED_COMMIT + ':' + EVIDENCE_SOURCE],
                      capture_output=True, check=True).stdout
assert hashlib.sha256(blob).hexdigest() == EVIDENCE_SHA256
print('OK')
"

# ===========================================================================
# The ceremony, against fixtures
# ===========================================================================

FIXTURE_BASE=""
cleanup() { [[ -n "${FIXTURE_BASE}" && -d "${FIXTURE_BASE}" ]] && rm -rf "${FIXTURE_BASE}"; return 0; }
trap cleanup EXIT
FIXTURE_BASE="$(mktemp -d)"
chmod 0755 "${FIXTURE_BASE}"

ANCESTRY="$(dirname "${EVIDENCE_ROOT}")"
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

ceremony() { (cd "${ROOT}" && bash "${CEREMONY}" "$2" --fixture "$1" 2>&1); }
published_of() { printf '%s%s/%s.yaml' "$1" "${EVIDENCE_ROOT}" "${EVIDENCE_ID}"; }

FIXTURE_OK="$(new_fixture)"
if out="$(ceremony "${FIXTURE_OK}" --verify)" && grep -q '^READY$' <<<"${out}"; then
  pass "an empty trusted ancestry is READY to publish"
else
  fail "--verify: ${out}"
fi
if out="$(ceremony "${FIXTURE_OK}" --install)" && grep -q '^DONE$' <<<"${out}"; then
  pass "publication succeeds and verifies its own result"
else
  fail "--install: ${out}"
fi
if out="$(ceremony "${FIXTURE_OK}" --verify-installed)" && grep -q '^VERIFIED$' <<<"${out}"; then
  pass "the published evidence verifies independently"
else
  fail "--verify-installed: ${out}"
fi

assert_published_shape() {
  local record; record="$(published_of "${FIXTURE_OK}")"
  local problems=0
  [[ -f "${record}" && ! -L "${record}" ]] || { fail "no evidence published"; return; }
  [[ "$(sha256sum "${record}" | cut -d' ' -f1)" == "${EVIDENCE_SHA256}" ]] || problems=1
  [[ "$(stat -c '%a' "${record}")" == "444" ]] || problems=1
  [[ "$(stat -c '%h' "${record}")" == "1" ]] || problems=1
  [[ -z "$(find "$(dirname "${record}")" -perm /022)" ]] || problems=1
  [[ "$(basename "${record}")" == "${EVIDENCE_ID}.yaml" ]] || problems=1
  # No sequence is minted: the identity was already governed.
  [[ -z "$(find "$(dirname "${record}")" -name '*.seq')" ]] || problems=1
  if (( problems == 0 )); then
    pass "the published record is 0444, single-linked, identity-named, and byte-exact"
  else
    fail "the published record has the wrong shape"
  fi
}
assert_published_shape

run_case "the published record is still logically EVID-000001" "${PRELUDE}
record = load_strict('${FIXTURE_OK}${EVIDENCE_ROOT}/${EVIDENCE_ID}.yaml')
source = load_strict(EVIDENCE_SOURCE)
assert record == source, 'the published record is not the reviewed record'
assert record['id'] == EVIDENCE_ID and record['target'] == HOST_IDENTITY
assert record['content_fingerprint'] == EVIDENCE_FINGERPRINT
print('OK')
"

run_case "ambient working-tree bytes are not evidence authority" "${PRELUDE}
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    clone = os.path.join(tmp, 'clone')
    subprocess.run(['git', 'clone', '--quiet', '--no-hardlinks', '.', clone], check=True)
    subprocess.run(['git', '-C', clone, 'checkout', '--quiet', '-B',
                    'arch/eng-0005-execution-transition', 'HEAD'], check=True)
    poisoned = os.path.join(clone, EVIDENCE_SOURCE)
    Path(poisoned).write_text('id: EVID-000001\npoisoned: true\n', encoding='utf-8')
    blob = subprocess.run(['git', '-C', clone, 'cat-file', 'blob',
                           REVIEWED_COMMIT + ':' + EVIDENCE_SOURCE],
                          capture_output=True, check=True).stdout
    assert hashlib.sha256(blob).hexdigest() == EVIDENCE_SHA256, \\
        'the pinned object followed the poisoned working tree'
    assert Path(poisoned).read_bytes() != blob
print('OK')
"

if out="$(ceremony "${FIXTURE_OK}" --install)" && grep -q 'DONE (no change)' <<<"${out}"; then
  pass "re-publishing identical evidence changes nothing"
else
  fail "second --install: ${out}"
fi
INODE_BEFORE="$(stat -c '%i %Y' "$(published_of "${FIXTURE_OK}")")"
ceremony "${FIXTURE_OK}" --install >/dev/null 2>&1 || true
if [[ "$(stat -c '%i %Y' "$(published_of "${FIXTURE_OK}")")" == "${INODE_BEFORE}" ]]; then
  pass "the idempotent run rewrote no inode"
else
  fail "the idempotent run replaced the published record"
fi

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

poisoned_record() {
  local how="$1" base record
  base="$(new_fixture)"
  ceremony "${base}" --install >/dev/null
  record="$(published_of "${base}")"
  chmod u+w "$(dirname "${record}")"
  case "${how}" in
    differing) chmod u+w "${record}"; printf 'id: EVID-000001\n' > "${record}"; chmod 0444 "${record}" ;;
    writable)  chmod 0666 "${record}" ;;
    symlink)   rm -f "${record}"; printf 'x\n' > "$(dirname "${record}")/elsewhere.yaml"
               ln -s "$(dirname "${record}")/elsewhere.yaml" "${record}" ;;
    multilink) rm -f "${record}"; cp "${ROOT}/${EVIDENCE_SOURCE}" "${record}"
               ln -f "${record}" "$(dirname "${record}")/alias.yaml"; chmod 0444 "${record}" ;;
    directory) rm -f "${record}"; mkdir -m 0755 "${record}" ;;
  esac
  printf '%s' "${base}"
}

for HOW in differing writable symlink multilink directory; do
  FIXTURE_P="$(poisoned_record "${HOW}")"
  RECORD="$(published_of "${FIXTURE_P}")"
  STATE_BEFORE="$(stat -c '%a %U %i %h' "${RECORD}" 2>/dev/null || printf 'link')"
  refuses "a ${HOW} published record refuses --install" \
    "${FIXTURE_P}" --install "not replaced or repaired"
  refuses "a ${HOW} published record refuses --verify-installed" \
    "${FIXTURE_P}" --verify-installed "problem(s)"
  STATE_AFTER="$(stat -c '%a %U %i %h' "${RECORD}" 2>/dev/null || printf 'link')"
  if [[ "${STATE_BEFORE}" == "${STATE_AFTER}" ]]; then
    pass "the ${HOW} record was neither repaired nor replaced"
  else
    fail "the ${HOW} record was modified"
  fi
done

FIXTURE_LOOSE="$(new_fixture)"
mkdir -p "${FIXTURE_LOOSE}${EVIDENCE_ROOT}"; chmod 0777 "${FIXTURE_LOOSE}${EVIDENCE_ROOT}"
refuses "a world-writable evidence root refuses" \
  "${FIXTURE_LOOSE}" --install "authority is not trusted"

FIXTURE_LINKED="$(new_fixture)"
mkdir -p "${FIXTURE_LINKED}/elsewhere"; chmod 0755 "${FIXTURE_LINKED}/elsewhere"
ln -s "${FIXTURE_LINKED}/elsewhere" "${FIXTURE_LINKED}${EVIDENCE_ROOT}"
refuses "a symlinked evidence root refuses rather than being followed" \
  "${FIXTURE_LINKED}" --install "authority is not trusted"
if [[ -z "$(ls -A "${FIXTURE_LINKED}/elsewhere")" ]]; then
  pass "nothing was written through the symlinked root"
else
  fail "publication wrote through a symlinked root"
fi

# ===========================================================================
# The resolver
# ===========================================================================

RESOLVER="${PRELUDE}
AUTHORITY = '${FIXTURE_OK}${EVIDENCE_ROOT}'
def resolve(**overrides):
    call = dict(evidence_id=EVIDENCE_ID, evidence_root=AUTHORITY, trusted_source_uid=UID)
    call.update(overrides)
    return EA.resolve_evidence(**call)
"

run_case "the resolver returns the governed evidence for a valid identity" "${RESOLVER}
resolved = resolve()
assert resolved.supported is True, resolved
assert resolved.reason is None
assert resolved.evidence_id == EVIDENCE_ID
assert resolved.target == HOST_IDENTITY
assert resolved.governed_field == 'architecture'
assert resolved.canonical_value == 'x86-64'
assert resolved.status == 'success'
print('OK')
"

run_case "the governed identity grammar is enforced, and paths are not identities" "${RESOLVER}
for bad in ('evid-000001', 'EVID-1', 'EVID-0000001', 'EVID-000001.yaml',
            '../../etc/passwd', 'file:EVID-000001.yaml',
            '/var/lib/kyri/evidence/EVID-000001.yaml', '', None, 1):
    assert resolve(evidence_id=bad).reason == EA.REASON_IDENTITY, bad
# The governed pattern is the one the schema and the observation model both use.
schema = load_strict('platform-model/schemas/evidence.schema.yaml')
assert EA.EVIDENCE_ID.pattern == schema['id_pattern'], EA.EVIDENCE_ID.pattern
from tools.observation.models import EVIDENCE_ID as OBSERVED
assert EA.EVIDENCE_ID.pattern == OBSERVED.pattern
print('OK')
"

run_case "the authority root and trusted uid are supplied, never inferred" "${RESOLVER}
assert resolve(evidence_root=None).reason == EA.REASON_UNAVAILABLE
assert resolve(evidence_root='').reason == EA.REASON_UNAVAILABLE
assert resolve(trusted_source_uid=None).reason == EA.REASON_UNAVAILABLE
assert resolve(trusted_source_uid=True).reason == EA.REASON_UNAVAILABLE
# A different trusted uid is a different trust boundary, and is refused.
assert resolve(trusted_source_uid=UID + 1).reason == EA.REASON_UNAVAILABLE
code = operative(RESOLVER_SOURCE)
assert 'geteuid' not in code and 'getuid' not in code
assert 'environ' not in code and 'getenv' not in code
print('OK')
"

run_case "an absent evidence record is unavailable, not fabricated" "${RESOLVER}
assert resolve(evidence_id='EVID-999999').reason == EA.REASON_UNAVAILABLE
with TemporaryDirectory() as tmp:
    empty = Path(tmp) / 'empty'
    empty.mkdir(mode=0o755)
    os.chmod(tmp, 0o755)
    assert resolve(evidence_root=empty).reason == EA.REASON_UNAVAILABLE
    assert not any(empty.iterdir()), 'the resolver created something'
print('OK')
"

# Fingerprint, schema and status are checked on the bytes that were read, not
# taken on trust from the ceremony that published them.
run_case "a tampered record is refused by fingerprint, schema, or status" "${RESOLVER}
import shutil
source = load_strict(EVIDENCE_SOURCE)
cases = {
    EA.REASON_FINGERPRINT: [
        ('content_fingerprint', 'sha256:' + '0' * 64),
        ('facts', {'governed_field': 'architecture', 'canonical_value': 'arm64'}),
        ('target', 'HOST-0009'),
    ],
    EA.REASON_STATUS: [('status', 'failed')],
    EA.REASON_SCHEMA: [('type', 'observation'), ('id', 'EVID-000002')],
}
import yaml
for reason, edits in cases.items():
    for field, value in edits:
        with TemporaryDirectory() as tmp:
            os.chmod(tmp, 0o755)
            authority = Path(tmp) / 'authority'
            authority.mkdir(mode=0o755)
            record = dict(source)
            record[field] = value
            if reason == EA.REASON_STATUS or field in ('type', 'id'):
                # Keep the fingerprint honest so the refusal is the one under
                # test rather than an earlier one.
                from tools.platform_model import evidence_fingerprint
                try:
                    record['content_fingerprint'] = evidence_fingerprint.fingerprint(record)
                except Exception:
                    pass
            (authority / (EVIDENCE_ID + '.yaml')).write_text(
                yaml.safe_dump(record, sort_keys=True), encoding='utf-8')
            os.chmod(authority / (EVIDENCE_ID + '.yaml'), 0o444)
            got = resolve(evidence_root=authority).reason
            assert got == reason, (field, value, got, reason)
print('OK')
"

run_case "unreadable bytes are refused rather than guessed at" "${RESOLVER}
with TemporaryDirectory() as tmp:
    os.chmod(tmp, 0o755)
    authority = Path(tmp) / 'authority'
    authority.mkdir(mode=0o755)
    target = authority / (EVIDENCE_ID + '.yaml')
    for body in (b'\xff\xfe', b'not: [unclosed', b'[]', b'', b'a: 1\na: 2\n'):
        target.write_bytes(body)
        os.chmod(target, 0o444)
        got = resolve(evidence_root=authority).reason
        assert got in (EA.REASON_MALFORMED, EA.REASON_SCHEMA), (body, got)
        os.chmod(target, 0o644)
print('OK')
"

# ===========================================================================
# Evidence-to-profile binding: existence is not verification
# ===========================================================================

run_case "the evidence binds to the claimed host and the claimed dimension" "${RESOLVER}
resolved = resolve()
assert EA.supports_profile(resolved, node_identity_reference=HOST_IDENTITY,
                           verified_resource_profile={'architecture': 'x86-64'}) is None
print('OK')
"

run_case "evidence about another machine does not support this host" "${RESOLVER}
resolved = resolve()
for other in ('HOST-0009', 'HOST-0002', 'node/schai', 'schai', ''):
    assert EA.supports_profile(resolved, node_identity_reference=other,
                               verified_resource_profile={'architecture': 'x86-64'}) \\
        == EA.REASON_TARGET, other
print('OK')
"

run_case "a dimension the record does not govern is never authorised" "${RESOLVER}
resolved = resolve()
for profile in ({'host_memory_mb': 8192}, {'host_cpu_cores': 4},
                {'accelerator_class': 'discrete-gpu'},
                {'architecture': 'x86-64', 'host_cpu_cores': 4}):
    assert EA.supports_profile(resolved, node_identity_reference=HOST_IDENTITY,
                               verified_resource_profile=profile) \\
        == EA.REASON_DIMENSION, profile
print('OK')
"

run_case "a governed dimension with a different value is refused" "${RESOLVER}
resolved = resolve()
for wrong in ('arm64', 'x86_64', 'amd64', 'X86-64', ''):
    assert EA.supports_profile(resolved, node_identity_reference=HOST_IDENTITY,
                               verified_resource_profile={'architecture': wrong}) \\
        == EA.REASON_VALUE, wrong
print('OK')
"

# The canonical value is compared, never normalised: normalising here would
# decide what a governed record meant at the moment it was read.
run_case "the resolver compares canonical values and normalises nothing" "${RESOLVER}
import ast
tree = ast.parse(RESOLVER_SOURCE)
binder = [n for n in ast.walk(tree)
          if isinstance(n, ast.FunctionDef) and n.name == 'supports_profile']
assert len(binder) == 1, binder
body = ast.get_source_segment(RESOLVER_SOURCE, binder[0])
body = operative(body)
# The comparison transforms neither side. A comparison that normalised its
# inputs would be deciding what a governed record meant as it was read.
for transform in ('.lower(', '.upper(', '.casefold(', '.strip(', '.replace(',
                  'normalise', 'normalize'):
    assert transform not in body, 'the binding transforms a value: ' + transform
assert 'claimed != evidence.canonical_value' in body, body
print('OK')
"

# ===========================================================================
# Admission integration: preflight and write ask the same question
# ===========================================================================

ADMISSION="${RESOLVER}
from datetime import datetime, timedelta, timezone
STAMP = datetime(2026, 8, 25, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
OPERATOR = 'operator:cschott'
PROV = {'class': 'declared', 'source': 'operator'}

def stores(base):
    return (FabricStore(Path(base) / 'fabric', expected_uid=UID, expected_gid=GID),
            TrustStore(Path(base) / 'trust'))

def body(**overrides):
    call = dict(request_id='req-host', actor=OPERATOR, approving_authority=OPERATOR,
                recorded_at=STAMP, evaluated_at=STAMP,
                node_identity_reference=HOST_IDENTITY,
                fabric_node_trust_record_id='TREC-000001',
                verified_resource_profile={'architecture': 'x86-64'},
                verification_reference=EVIDENCE_ID,
                location_class='on-premises', data_classification='internal',
                availability_intent='in-service', provenance=dict(PROV),
                evidence_root=AUTHORITY, evidence_trusted_uid=UID)
    call.update(overrides)
    return call
"

# The whole point of resolving before the trust query: an evidence failure must
# be reported as itself, not behind the trust standing nobody has established.
run_case "evidence failures are not masked by the later trust failure" "${ADMISSION}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    expected = {
        'target mismatch': (dict(node_identity_reference='HOST-0009'), EA.REASON_TARGET),
        'ungoverned dimension': (dict(verified_resource_profile={'host_memory_mb': 8192}),
                                 EA.REASON_DIMENSION),
        'absent evidence': (dict(verification_reference='EVID-999999'),
                            EA.REASON_UNAVAILABLE),
        'authority not supplied': (dict(evidence_root=None), EA.REASON_UNAVAILABLE),
        'uid not supplied': (dict(evidence_trusted_uid=None), EA.REASON_UNAVAILABLE),
    }
    for index, (label, (overrides, reason)) in enumerate(expected.items()):
        result = A.admit_subject(fabric, trust, **body(request_id='r%d' % index, **overrides))
        assert result.reason == reason, (label, result.to_dict())
        assert result.reason != 'trust-unavailable', label
    # And valid evidence reaches the trust query, which is the honest end state
    # while no fabric-node trust record exists.
    result = A.admit_subject(fabric, trust, **body(request_id='r-ok'))
    assert result.reason == 'trust-unavailable', result.to_dict()
    assert not (Path(fabric.root) / 'sequences' / 'capability-host.seq').exists()
print('OK')
"

# An opaque operator reference is not a governed identity and stays unresolved,
# so the non-modelled hosts the schema permits are not forbidden.
run_case "an opaque reference is not resolved as a governed identity" "${ADMISSION}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    result = A.admit_subject(fabric, trust, **body(
        verification_reference='/approved/evidence/host-observed.txt'))
    assert result.reason == 'trust-unavailable', result.to_dict()
print('OK')
"

run_case "a rehearsal asks exactly what the write asks, and mutates nothing" "${ADMISSION}
def state(path):
    entries = []
    for item in sorted(Path(path).rglob('*')):
        info = item.lstat()
        entries.append(f'{item} {info.st_mode} {info.st_size}')
        if item.is_file():
            entries.append(hashlib.sha256(item.read_bytes()).hexdigest())
    return hashlib.sha256('\n'.join(entries).encode()).hexdigest()

with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    before_fabric, before_trust = state(fabric.root), state(trust.root)
    before_evidence = state(AUTHORITY)
    reader = FabricStore.open_for_read(fabric.root, expected_uid=UID, expected_gid=GID)
    trust_reader = TrustStore.open_for_read(trust.root)
    for overrides in ({}, dict(node_identity_reference='HOST-0009'),
                      dict(verified_resource_profile={'host_cpu_cores': 4})):
        with A.rehearsing():
            rehearsed = A.admit_subject(reader, trust_reader, **body(**overrides))
        written = A.admit_subject(fabric, trust, **body(**overrides))
        assert rehearsed.outcome == written.outcome, (overrides, rehearsed.to_dict())
        assert rehearsed.reason == written.reason, (overrides, rehearsed.reason)
        assert rehearsed.request_digest == written.request_digest
    assert state(fabric.root) == before_fabric, 'the fabric store moved'
    assert state(trust.root) == before_trust, 'the trust store moved'
    assert state(AUTHORITY) == before_evidence, 'the evidence authority moved'
print('OK')
"

# The authority root is an invocation parameter, not part of what was decided.
run_case "the evidence authority does not enter the request digest" "${ADMISSION}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    one = A.admit_subject(fabric, trust, **body(request_id='same'))
    two = A.admit_subject(fabric, trust, **body(request_id='same',
                                                evidence_root=AUTHORITY + '/.'))
assert one.request_digest == two.request_digest, (one.request_digest, two.request_digest)
print('OK')
"

# The same rule where a declaration is restated, not only where it is created.
run_case "refresh applies the same evidence rule as admission" "${ADMISSION}
import inspect
for operation in (A.admit_subject, A.refresh_subject):
    parameters = inspect.signature(operation).parameters
    for name in ('evidence_root', 'evidence_trusted_uid'):
        assert name in parameters, (operation.__name__, name)
        assert parameters[name].default is None
source = Path('tools/fabric/admission.py').read_text(encoding='utf-8')
assert source.count('_require_supporting_evidence(') == 3, \\
    'the evidence rule is not applied by both host operations'
print('OK')
"

# The CLI passes the boundary through where it is consumed and nowhere else.
run_case "the released CLI carries the evidence boundary explicitly" "${ADMISSION}
cli = Path('tools/fabric/cli.py').read_text(encoding='utf-8')
assert '--evidence-root' in cli and '--evidence-trusted-uid' in cli
assert 'NEEDS_EVIDENCE = (' in cli
assert 'admit-subject' in cli and 'refresh-subject' in cli
for flag in ('--evidence-root', '--evidence-trusted-uid'):
    rows = [row for row in cli.splitlines() if flag in row and 'add_argument' in row]
    assert rows, flag
    assert all('required=True' not in row for row in rows), flag
    assert all(\"default=None\" in row for row in rows), flag
print('OK')
"

# ===========================================================================
# What this suite did not touch
# ===========================================================================

assert_untouched() {
  local problems=0
  [[ "$(production_state "${FABRIC_ROOT}")" == "${FABRIC_BEFORE}" ]] || { fail "the production Fabric store moved"; problems=1; }
  [[ "$(production_state "${TRUST_ROOT}")" == "${TRUST_BEFORE}" ]] || { fail "the production Trust store moved"; problems=1; }
  [[ "$(production_state "${LIVE_EVIDENCE}")" == "${LIVE_EVIDENCE_BEFORE}" ]] || { fail "the live evidence authority moved"; problems=1; }
  [[ "$(sha256sum "${ROOT}/${EVIDENCE_SOURCE}" | cut -d' ' -f1)" == "${SOURCE_BEFORE}" ]] || { fail "the reviewed evidence source was modified"; problems=1; }
  if (( problems == 0 )); then
    pass "production Fabric, Trust and Evidence state, and the reviewed source, are unchanged"
  fi
}
assert_untouched

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All evidence-authority assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
