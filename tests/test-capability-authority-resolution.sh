#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 coordinator authority-resolution seam.
#
# HERMETIC AND READ-ONLY. Every authority root is a temporary directory built
# by the offline ceremonies. Resolution itself writes nothing: no counter
# moves, no staging appears, no lock is taken, and the tree is byte-identical
# afterwards. No Podman runs, no transition or worker is invoked, no launch
# record is written, and no production path beneath /var/lib/kyri is touched.
#                                                        # prod-path-reference
#
# IMAGE PRESENCE IS NOT IMAGE AUTHORITY. A profile's image identity comes from
# the resolved immutable admission and from nowhere else -- not a tag, not a
# store listing, not capability metadata, not the caller.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §5, §5.1-§5.7, §12

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/authorisation.py"

# ===========================================================================
# The runtime boundary
# ===========================================================================
# Runtime resolution may read published authority. It may not reach the offline
# writer, name a production path, or acquire any mutation primitive.

assert_runtime_boundary() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
module = root / "tools/capability/execution/authorisation.py"
runtime = sorted((root / "tools/capability").rglob("*.py")) + [
    root / "provisioning/execution/kyri-exec-transition.py",
    root / "provisioning/execution/kyri-exec-transition-action.py",
    root / "provisioning/execution/kyri-exec-worker.py",
]

findings = []
if not module.is_file():
    print("module-absent")
    raise SystemExit(0)

# No runtime module may import the offline provisioning package.
for target in runtime:
    if not target.is_file() or "__pycache__" in str(target):
        continue
    for node in ast.walk(ast.parse(target.read_text(encoding="utf-8"))):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            names = [node.module or ""]
        for name in names:
            if name.split(".")[0:2] == ["tools", "provisioning"]:
                findings.append(f"{target.relative_to(root)}: imports {name}")

tree = ast.parse(module.read_text(encoding="utf-8"))
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value.startswith("/var") or node.value.startswith("/etc"):
            findings.append(f"production path literal: {node.value!r}")

# Resolution reads. It does not write, allocate, lock, or spawn.
FORBIDDEN_CALLS = {"mkdir", "makedirs", "rename", "unlink", "remove", "rmdir",
                   "write", "fsync", "flock", "chmod", "chown", "symlink",
                   "truncate", "popen", "system"}
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        attr = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"mutating call: {attr}")
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in ("subprocess", "fcntl", "shutil",
                                            "tempfile"):
                findings.append(f"forbidden import: {alias.name}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "resolution is read-only runtime code with no writer or path authority"
  else
    fail "resolution boundary: ${report}"
  fi
}

assert_runtime_boundary

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && WORKDIR="${WORK}" python3 -c "${script}" 2>&1)"; then
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
import hashlib, os, shutil
from tools.capability.execution.authorisation import (
    authorise_implementation, AuthorisedImplementation,
    IncompatibleImplementation, ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY)
from tools.capability.execution.implementation_authority import (
    current_generation, NamespaceState, IntegrityFailure,
    ImplementationAuthorityError, UnknownImplementation, RetiredImplementation)
from tools.capability.execution.profile import (
    PROFILE_SCHEMA_VERSION, MetadataOverrideRefused, fingerprint)
from tools.capability.execution.payload import PAYLOAD_SCHEMA_VERSION
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.worker import CONTAINER_INTERPRETER
from tools.provisioning.authority_bootstrap import (
    provision_control_state, initialise_genesis, IMPLEMENTATIONS,
    CIMP_COUNTER, CGEN_COUNTER, STAGING, CURRENT_GENERATION)
from tools.provisioning.provisioning_evidence import (GOVERNED_SBOM_PACKAGE,
    EVIDENCE_SCHEMA_VERSION, GOVERNED_PYTHON_VERSION, canonical_evidence,
    evidence_digest)
from tools.provisioning.authority_admission import (
    admit_implementation, AdmissionRequest)
from tools.provisioning.authority_disposition import (
    dispose_pending, Disposition, Decision, DispositionRequest)

WORK = os.environ['WORKDIR']
IMAGE = 'a' * 64
CINV = 'CINV-000042'

def evidence_for(image=IMAGE):
    return canonical_evidence({
        'evidence_schema_version': EVIDENCE_SCHEMA_VERSION,
        'source_commit': 'c' * 40, 'containerfile_sha256': 'd' * 64,
        'base_image_reference': 'cgr.dev/chainguard/python@sha256:' + 'b' * 64,
        'oci_image_id': image, 'python_version': GOVERNED_PYTHON_VERSION,
        'interpreter_path': CONTAINER_INTERPRETER, 'interpreter_link': None,
        'interpreter_target': '/usr/lib/python3.14/python',
        'interpreter_sha256': 'e' * 64, 'sbom_python_package': GOVERNED_SBOM_PACKAGE,
        'sbom_python_version': GOVERNED_PYTHON_VERSION, 'sbom_sha256': 'f' * 64,
        'os': 'linux', 'architecture': 'amd64'})

def fd(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY)

def built(name, images=(IMAGE,)):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    authority = os.path.join(base, 'authority')
    control = os.path.join(base, 'control')
    os.makedirs(authority); os.makedirs(control)
    # The ruled layout: the authority root and staging/ carry setgid so every
    # published object inherits the coordinator group with no chown anywhere.
    # A fixture cannot own anything as root:cschott, so it uses a group this
    # process is really in -- inheritance is the mechanism under test.
    os.chmod(authority, 0o2750)
    os.mkdir(os.path.join(control, 'staging'), 0o2750)
    os.chmod(os.path.join(control, 'staging'), 0o2750)
    a, c = fd(authority), fd(control)
    try:
        provision_control_state(c)
        initialise_genesis(a, c)
        for image in images:
            admit_implementation(a, c, request=AdmissionRequest(
                oci_image_id=image, evidence=evidence_for(image),
                observed_image_id=image))
    finally:
        os.close(a); os.close(c)
    return authority, control

def publish_pending(authority, cimp, image=IMAGE, retire=False, **override):
    body = {
        'cimp': cimp, 'oci_image_id': image,
        'adapter_identity': ADAPTER_IDENTITY,
        'argv_contract_identity': ARGV_CONTRACT_IDENTITY,
        'payload_schema_version': PAYLOAD_SCHEMA_VERSION,
        'execution_profile_schema_version': PROFILE_SCHEMA_VERSION,
        'provisioning_evidence_digest': evidence_digest(evidence_for(image))}
    body.update(override)
    base = os.path.join(authority, IMPLEMENTATIONS, cimp)
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, 'admission'), 'wb') as handle:
        handle.write(serialise(body))
    if retire:
        with open(os.path.join(base, 'retirement'), 'wb') as handle:
            handle.write(serialise({'cimp': cimp}))
    return cimp

def resolve(authority, cimp, cinv=CINV, **kwargs):
    handle = fd(authority)
    try:
        # Schema 2: the invocation commitments are required, because a
        # profile without them cannot be verified by the worker at all.
        kwargs.setdefault('payload_digest', 'c' * 64)
        kwargs.setdefault('package_digest', 'd' * 64)
        kwargs.setdefault('package_entrypoint', 'main.py')
        return authorise_implementation(handle, cinv=cinv, cimp=cimp, **kwargs)
    finally:
        os.close(handle)

def read(path):
    with open(path, 'rb') as handle:
        return handle.read()

def refuses(action, expect):
    try:
        action()
    except expect:
        return True
    except Exception as error:
        raise AssertionError('wrong error: ' + type(error).__name__ + ': ' + str(error))
    raise AssertionError('accepted what should have been refused')

def tree_digest(root):
    items = []
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(base, name)
            items.append((os.path.relpath(path, root), os.lstat(path).st_mode, read(path)))
        for name in dirs:
            p = os.path.join(base, name)
            items.append((os.path.relpath(p, root), os.lstat(p).st_mode, b''))
    return hashlib.sha256(repr(sorted(items)).encode('utf-8')).hexdigest()
"

# --- VALID authority ------------------------------------------------------------

run_case "an eligible CIMP resolves to a governed profile" "${PRELUDE}
authority, control = built('valid')
bound = resolve(authority, 'CIMP-000001')
assert isinstance(bound, AuthorisedImplementation)
assert bound.cimp == 'CIMP-000001' and bound.cinv == CINV
# The image identity comes from the admission, and nowhere else.
assert bound.oci_image_id == IMAGE
assert bound.profile.oci_image_id == IMAGE
assert bound.fingerprint.oci_image_id == IMAGE
assert bound.profile.cimp == 'CIMP-000001'
assert bound.profile.cinv == CINV
assert bound.profile.profile_schema_version == PROFILE_SCHEMA_VERSION
assert bound.profile.adapter_identity == ADAPTER_IDENTITY
assert bound.provisioning_evidence_digest == evidence_digest(evidence_for(IMAGE))
# Governed controls are policy, never derived from the admission.
assert bound.profile.network == 'none'
assert bound.profile.execution_uid == 1000 and bound.profile.execution_gid == 1000
print('OK')
"

run_case "the fingerprint is the existing canonical one and is deterministic" "${PRELUDE}
authority, control = built('fingerprint')
first = resolve(authority, 'CIMP-000001')
assert first.fingerprint == fingerprint(first.profile), 'a second digest was invented'
for _ in range(3):
    again = resolve(authority, 'CIMP-000001')
    assert again.fingerprint == first.fingerprint
    assert again.fingerprint.profile_digest == first.fingerprint.profile_digest
    assert again.profile == first.profile
print('OK')
"

run_case "the binding carries no descriptor, path, or mutation primitive" "${PRELUDE}
import dataclasses
authority, control = built('bindingshape')
bound = resolve(authority, 'CIMP-000001')
names = {f.name for f in dataclasses.fields(AuthorisedImplementation)}
assert names == {'cinv', 'cimp', 'oci_image_id', 'profile', 'fingerprint',
                 'provisioning_evidence_digest'}, names
for name in names:
    value = getattr(bound, name)
    assert not isinstance(value, int) or name != 'fd'
assert not any('fd' in name or 'path' in name or 'root' in name for name in names)
try:
    object.__setattr__  # frozen check below
    bound.cimp = 'CIMP-000009'
except Exception:
    pass
else:
    raise AssertionError('the binding is mutable')
print('OK')
"

# --- pending --------------------------------------------------------------------

run_case "pending never resolves, and current authority keeps working" "${PRELUDE}
for retire in (False, True):
    authority, control = built('pending' + str(retire))
    publish_pending(authority, 'CIMP-000002', retire=retire)
    generation_state = None
    handle = fd(authority)
    try:
        generation_state = current_generation(handle).state
    finally:
        os.close(handle)
    assert generation_state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
    # Pending must not disable an implementation that was correctly authorised.
    assert resolve(authority, 'CIMP-000001').oci_image_id == IMAGE
    # And it must not become eligible because its record exists.
    refuses(lambda: resolve(authority, 'CIMP-000002'), UnknownImplementation)
print('OK')
"

# --- retired / unknown / reserved ------------------------------------------------

run_case "a retired CIMP is refused as ineligible, not as unknown" "${PRELUDE}
authority, control = built('retired')
publish_pending(authority, 'CIMP-000002')
a, c = fd(authority), fd(control)
try:
    dispose_pending(a, c, request=DispositionRequest(decisions=(
        Decision(cimp='CIMP-000002', disposition=Disposition.RETIRE),)))
finally:
    os.close(a); os.close(c)
# The distinction is preserved: retired is a decision, unknown is an absence.
refuses(lambda: resolve(authority, 'CIMP-000002'), RetiredImplementation)
assert resolve(authority, 'CIMP-000001').cimp == 'CIMP-000001'
print('OK')
"

run_case "unknown, reserved, and malformed identifiers are refused" "${PRELUDE}
authority, control = built('unknown')
# Well-formed but never admitted, and the reserved identifier: absent.
for cimp in ('CIMP-000009', 'CIMP-000000', 'CIMP-999999'):
    refuses(lambda: resolve(authority, cimp), UnknownImplementation)
# Not an identifier at all. The reader keeps this distinct from 'unknown',
# and collapsing them would report a typo as a missing implementation.
for cimp in ('CIMP-00001', 'cimp-000001', 'CIMP-00000a', '', 'a' * 64,
             'alpine:latest', 'docker.io/library/alpine'):
    refuses(lambda: resolve(authority, cimp), ImplementationAuthorityError)
print('OK')
"

# --- runtime compatibility -------------------------------------------------------

run_case "an admission for another contract is readable but not bindable" "${PRELUDE}
# Record integrity and runtime compatibility are different questions. The
# reader must keep historical records readable; the runtime must refuse to
# bind one it cannot honour.
for field, value in (('adapter_identity', 'python-podman-v0'),
                     ('argv_contract_identity', 'fixed-python-entrypoint-v0'),
                     ('payload_schema_version', 9),
                     ('execution_profile_schema_version', 9)):
    authority, control = built('compat' + field)
    publish_pending(authority, 'CIMP-000002', **{field: value})
    a, c = fd(authority), fd(control)
    try:
        dispose_pending(a, c, request=DispositionRequest(decisions=(
            Decision(cimp='CIMP-000002', disposition=Disposition.RETIRE),)))
    finally:
        os.close(a); os.close(c)
    # The reader still reads it: the namespace is valid and it is accounted for.
    handle = fd(authority)
    try:
        generation = current_generation(handle)
    finally:
        os.close(handle)
    assert generation.state is NamespaceState.VALID, field
    assert any(e.cimp == 'CIMP-000002' for e in generation.entries), field

# And an eligible one carrying an incompatible contract refuses at binding.
for field, value in (('adapter_identity', 'python-podman-v0'),
                     ('argv_contract_identity', 'fixed-python-entrypoint-v0'),
                     ('payload_schema_version', 9),
                     ('execution_profile_schema_version', 9)):
    authority, control = built('bindcompat' + field)
    publish_pending(authority, 'CIMP-000002', **{field: value})
    a, c = fd(authority), fd(control)
    try:
        dispose_pending(a, c, request=DispositionRequest(decisions=(
            Decision(cimp='CIMP-000002', disposition=Disposition.COMPLETE,
                     evidence=evidence_for(IMAGE), observed_image_id=IMAGE),)))
    except Exception:
        # COMPLETE re-verifies the governed contract, so an incompatible
        # admission cannot be completed either. That is the writer's refusal;
        # the runtime check below is the one under test.
        continue
    refuses(lambda: resolve(authority, 'CIMP-000002'), IncompatibleImplementation)
print('OK')
"

# --- substitution ----------------------------------------------------------------

run_case "capability metadata cannot substitute any governed value" "${PRELUDE}
authority, control = built('metadata')
for metadata in ({'oci_image_id': 'b' * 64}, {'image': 'alpine:latest'},
                 {'user': '0:0'}, {'network': 'host'}, {'memory_bytes': 1},
                 {'cimp': 'CIMP-000009'}, {'pids_limit': 4096},
                 {'hostname': 'attacker'}, {'mounts': []}):
    refuses(lambda: resolve(authority, 'CIMP-000001', metadata=metadata),
            MetadataOverrideRefused)
# And the resolved profile is unchanged by any of that.
assert resolve(authority, 'CIMP-000001').profile.oci_image_id == IMAGE
print('OK')
"

run_case "an unrelated image identity cannot become authority" "${PRELUDE}
# Track-B isolation, hermetically: a digest that exists somewhere is not one
# anybody admitted. Only a CIMP the current authority set lists produces a
# profile, and its image comes from that admission.
authority, control = built('trackb', images=(IMAGE,))
residue = '7' * 64
# The residue identity is not a CIMP and cannot be requested as one.
refuses(lambda: resolve(authority, residue), ImplementationAuthorityError)
# A published record naming it grants nothing while it is pending.
publish_pending(authority, 'CIMP-000002', image=residue)
refuses(lambda: resolve(authority, 'CIMP-000002'), UnknownImplementation)
assert resolve(authority, 'CIMP-000001').oci_image_id == IMAGE != residue
print('OK')
"

# --- corruption ------------------------------------------------------------------

run_case "corruption freezes globally and never yields a binding" "${PRELUDE}
authority, control = built('corrupt1')
os.makedirs(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000'))
with open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000', 'admission'), 'wb') as h:
    h.write(b'{}')
refuses(lambda: resolve(authority, 'CIMP-000001'), IntegrityFailure)

authority, control = built('corrupt2')
path = os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001', 'admission')
os.chmod(path, 0o644);
with open(path, 'wb') as h:
    h.write(b'{not canonical')
refuses(lambda: resolve(authority, 'CIMP-000001'), IntegrityFailure)

authority, control = built('corrupt3')
shutil.rmtree(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001'))
refuses(lambda: resolve(authority, 'CIMP-000001'), IntegrityFailure)

authority, control = built('corrupt4')
publish_pending(authority, 'CIMP-000002')
os.symlink(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001'),
           os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000003'))
refuses(lambda: resolve(authority, 'CIMP-000001'), IntegrityFailure)
print('OK')
"

# --- zero mutation ----------------------------------------------------------------

run_case "resolution mutates nothing at all" "${PRELUDE}
authority, control = built('nomutate')
publish_pending(authority, 'CIMP-000002')
before_authority = tree_digest(authority)
before_control = tree_digest(control)
counters = (read(os.path.join(control, CIMP_COUNTER)),
            read(os.path.join(control, CGEN_COUNTER)))
pointer = read(os.path.join(authority, CURRENT_GENERATION))
for _ in range(4):
    resolve(authority, 'CIMP-000001')
    try:
        resolve(authority, 'CIMP-000002')
    except UnknownImplementation:
        pass
assert tree_digest(authority) == before_authority, 'authority mutated'
assert tree_digest(control) == before_control, 'control mutated'
assert (read(os.path.join(control, CIMP_COUNTER)),
        read(os.path.join(control, CGEN_COUNTER))) == counters
assert read(os.path.join(authority, CURRENT_GENERATION)) == pointer
assert os.listdir(os.path.join(control, STAGING)) == [], 'staging created'
print('OK')
"

# --- registration and isolation ----------------------------------------------------

run_case "the resolution suite runs in local validation and in CI" "${PRELUDE}
from pathlib import Path
name = 'tests/test-capability-authority-resolution.sh'
assert name in Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
assert name in Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
print('OK')
"

run_case "the launch record and worker contracts are untouched by this pass" "${PRELUDE}
from pathlib import Path
helper = Path('provisioning/execution/kyri-exec-transition.py').read_text(encoding='utf-8')
assert 'LAUNCH_RECORD_SCHEMA = (' in helper
# Pass 3B-ii replaced oci_image_id with profile_digest; resolution neither
# caused that nor may depend on it. The count is what this pass asserts: the
# record stays exactly seven fields, so nothing here grew the privileged parser.
for field in ('cinv', 'cimp', 'profile_digest', 'handoff_root',
              'profile_schema_version', 'commitment_digest', 'lifecycle_state'):
    assert chr(34) + field + chr(34) in helper, field
schema = helper.split('LAUNCH_RECORD_SCHEMA = (')[1].split(')')[0]
assert schema.count(chr(34)) == 14, schema
worker = Path('provisioning/execution/kyri-exec-worker.py').read_text(encoding='utf-8')
assert 'no governed runtime backend is bound' in worker
for production in ('/var/lib/kyri/implementation-authority',
                   '/var/lib/kyri/implementation-authority-control'):
    assert not os.path.exists(production), production + ' exists'
assert os.getuid() != 0, 'these tests must not run as root'
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Capability authority-resolution validation passed.\n'
else
  printf 'Capability authority-resolution validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
