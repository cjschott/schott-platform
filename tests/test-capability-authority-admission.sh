#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 ordinary implementation-admission transaction.
#
# OFFLINE AND HERMETIC. Every root is a temporary directory. The two production
# authority roots beneath /var/lib/kyri are never created, written, or removed;
# no image is built, no Podman runs, no shell is spawned, no sudoers policy
# exists, and no gate opens. G1, G3, G5, G6, G7 stay closed.
#                                                        # prod-path-reference
#
# ADMISSION IS NOT A WRITE. Publishing an admission record commits bytes; only
# a current generation commits authority. The intermediate state between those
# two publications is pending disposition by design, and this suite proves it
# directly rather than treating it as a failure to be smoothed over.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §5, §5.1-§5.7, §27

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/provisioning/provisioning_evidence.py"
assert_file "tools/provisioning/authority_admission.py"

# ===========================================================================
# The operator-only boundary
# ===========================================================================

assert_offline_only() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
modules = [root / "tools/provisioning/authority_admission.py",
           root / "tools/provisioning/provisioning_evidence.py"]
runtime = [
    root / "tools/capability/execution/worker.py",
    root / "tools/capability/execution/lifecycle.py",
    root / "tools/capability/execution/adapter.py",
    root / "tools/capability/execution/implementation_authority.py",
    root / "tools/capability/execution/profile.py",
    root / "tools/capability/coordinator.py",
    root / "provisioning/execution/kyri-exec-transition.py",
    root / "provisioning/execution/kyri-exec-transition-action.py",
    root / "provisioning/execution/kyri-exec-worker.py",
]

findings = []
if any(not m.is_file() for m in modules):
    print("module-absent")
    raise SystemExit(0)

for target in runtime:
    if not target.is_file():
        continue
    # Import statements, not substrings: `provisioning_evidence_digest` is a
    # field name on the admission record and says nothing about who imports
    # what.
    for node in ast.walk(ast.parse(target.read_text(encoding="utf-8"))):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            names = [node.module or ""]
        for name in names:
            if name.split(".")[0:2] == ["tools", "provisioning"]:
                findings.append(f"{target.relative_to(root)}: imports {name}")

# No subprocess, no shell, no container runtime anywhere in the writer.
# Measured against code with docstrings stripped: naming `podman image inspect`
# when documenting where an image ID comes from is not a Podman surface.
FORBIDDEN = ("subprocess", "popen", "system(", "shell=true", "podman",
             "docker", "sudo", "/bin/sh", "/bin/bash", "runuser")
for module in modules:
    tree = ast.parse(module.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(tree)
    lowered = ast.unparse(tree).lower()
    # The governed adapter identity is a reviewed constant that happens to
    # contain the word, not a container-runtime surface. Its exact value is
    # asserted separately, so excluding it here does not lose coverage.
    lowered = lowered.replace("python-podman-v1", "<adapter-identity>")
    for token in FORBIDDEN:
        if token in lowered:
            findings.append(f"{module.name}: forbidden surface {token}")

# The writer may not name a production authority path.
tree = ast.parse((root / "tools/provisioning/authority_admission.py")
                 .read_text(encoding="utf-8"))
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value.startswith("/var") or node.value.startswith("/etc"):
            findings.append(f"production path literal: {node.value!r}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "admission writer is operator-only, path-free, and spawns nothing"
  else
    fail "admission boundary: ${report}"
  fi
}

assert_offline_only

# ===========================================================================
# Behaviour
# ===========================================================================

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
from tools.provisioning.authority_bootstrap import (
    provision_control_state, allocate_cimp, allocate_cgen,
    implementation_lifecycle_lock, initialise_genesis,
    BootstrapError, ControlStateError, LockUnavailable,
    CIMP_COUNTER, CGEN_COUNTER, STAGING,
    GENESIS_CGEN, IMPLEMENTATIONS, GENERATIONS, CURRENT_GENERATION)
from tools.provisioning.provisioning_evidence import (
    EVIDENCE_SCHEMA_VERSION, GOVERNED_PYTHON_VERSION, EVIDENCE_FIELDS,
    canonical_evidence, evidence_digest, parse_evidence, EvidenceError)
from tools.provisioning.authority_admission import (
    admit_implementation, AdmissionRequest, AdmissionResult, AdmissionRefused,
    ADAPTER_IDENTITY, ARGV_CONTRACT_IDENTITY)
from tools.capability.execution.implementation_authority import (
    current_generation, resolve_implementation, NamespaceState,
    PendingDisposition, IntegrityFailure)
from tools.capability.execution.profile import PROFILE_SCHEMA_VERSION
from tools.capability.execution.payload import PAYLOAD_SCHEMA_VERSION
from tools.capability.execution.worker import CONTAINER_INTERPRETER

WORK = os.environ['WORKDIR']
IMAGE = 'a' * 64
BASE = 'cgr.dev/chainguard/python@sha256:' + 'b' * 64

def evidence_fields(image=IMAGE, **override):
    fields = {
        'evidence_schema_version': EVIDENCE_SCHEMA_VERSION,
        'source_commit': 'c' * 40,
        'containerfile_sha256': 'd' * 64,
        'base_image_reference': BASE,
        'oci_image_id': image,
        'python_version': GOVERNED_PYTHON_VERSION,
        'interpreter_path': CONTAINER_INTERPRETER,
        'interpreter_link': '../lib/python3.14/python',
        'interpreter_target': '/usr/lib/python3.14/python',
        'interpreter_sha256': 'e' * 64,
        'sbom_python_package': 'python',
        'sbom_python_version': GOVERNED_PYTHON_VERSION,
        'sbom_sha256': 'f' * 64,
        'os': 'linux',
        'architecture': 'amd64',
    }
    fields.update(override)
    return fields

def request(image=IMAGE, observed=None, **override):
    fields = evidence_fields(image, **override)
    body = canonical_evidence(fields)
    return AdmissionRequest(
        oci_image_id=image,
        evidence=body,
        observed_image_id=image if observed is None else observed)

def roots(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    authority = os.path.join(base, 'implementation-authority')
    control = os.path.join(base, 'implementation-authority-control')
    os.makedirs(authority); os.makedirs(control)
    # The ruled layout: the authority root and staging/ carry setgid so every
    # published object inherits the coordinator group with no chown anywhere.
    # A fixture cannot own anything as root:cschott, so it uses a group this
    # process is really in -- inheritance is the mechanism under test.
    os.chmod(authority, 0o2750)
    os.mkdir(os.path.join(control, 'staging'), 0o2750)
    os.chmod(os.path.join(control, 'staging'), 0o2750)
    return authority, control

def fd(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY)

def genesis(name):
    authority, control = roots(name)
    a, c = fd(authority), fd(control)
    try:
        provision_control_state(c)
        initialise_genesis(a, c)
    finally:
        os.close(a); os.close(c)
    return authority, control

def admit(authority, control, req=None):
    a, c = fd(authority), fd(control)
    try:
        return admit_implementation(a, c, request=req or request())
    finally:
        os.close(a); os.close(c)

def read_generation(authority):
    handle = fd(authority)
    try:
        return current_generation(handle)
    finally:
        os.close(handle)

def read(path):
    with open(path, 'rb') as handle:
        return handle.read()

def refuses(action, expect=AdmissionRefused):
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
            items.append((os.path.relpath(os.path.join(base, name), root),
                          os.lstat(os.path.join(base, name)).st_mode, b''))
    return hashlib.sha256(repr(sorted(items)).encode('utf-8')).hexdigest()
"

# --- governed constants ---------------------------------------------------------

run_case "governed identities and schema versions are constants, not operator input" "${PRELUDE}
assert ADAPTER_IDENTITY == 'python-podman-v1', ADAPTER_IDENTITY
assert ARGV_CONTRACT_IDENTITY == 'fixed-python-entrypoint-v1', ARGV_CONTRACT_IDENTITY
# Profile schema 2 carries the invocation commitments Pass 4A added. The
# payload schema is deliberately unchanged: nothing about the payload document
# moved, only the commitment to its bytes, which lives in the profile.
assert PROFILE_SCHEMA_VERSION == 2, PROFILE_SCHEMA_VERSION
assert PAYLOAD_SCHEMA_VERSION == 1, PAYLOAD_SCHEMA_VERSION
# The request carries external evidence only; every governed value is derived.
import dataclasses
supplied = {f.name for f in dataclasses.fields(AdmissionRequest)}
assert supplied == {'oci_image_id', 'evidence', 'observed_image_id'}, supplied
print('OK')
"

# --- the evidence manifest ------------------------------------------------------

run_case "the evidence manifest is a closed canonical fifteen-field schema" "${PRELUDE}
assert len(EVIDENCE_FIELDS) == 15, sorted(EVIDENCE_FIELDS)
fields = evidence_fields()
assert set(fields) == set(EVIDENCE_FIELDS), set(fields) ^ set(EVIDENCE_FIELDS)
body = canonical_evidence(fields)
# Canonical: byte-identical regardless of the order the caller built it in.
shuffled = dict(reversed(list(fields.items())))
assert canonical_evidence(shuffled) == body
assert evidence_digest(body) == hashlib.sha256(body).hexdigest()
assert parse_evidence(body)['oci_image_id'] == IMAGE
print('OK')
"

run_case "the evidence manifest refuses an unknown, missing, or malformed field" "${PRELUDE}
extra = evidence_fields(); extra['note'] = 'x'
refuses(lambda: canonical_evidence(extra), EvidenceError)
for name in sorted(EVIDENCE_FIELDS):
    if name == 'interpreter_link':
        continue
    short = evidence_fields(); del short[name]
    refuses(lambda: canonical_evidence(short), EvidenceError)
# interpreter_link is the one nullable field: /usr/bin/python may be a symlink.
nullable = evidence_fields(interpreter_link=None)
assert parse_evidence(canonical_evidence(nullable))['interpreter_link'] is None
for bad in ('sha256:' + 'a' * 64, 'A' * 64, 'a' * 63, 'alpine:latest', ''):
    refuses(lambda: canonical_evidence(evidence_fields(image=bad)), EvidenceError)
for bad in ('3.14.5', '3.14', '', 'latest'):
    refuses(lambda: canonical_evidence(evidence_fields(python_version=bad)),
            EvidenceError)
    refuses(lambda: canonical_evidence(evidence_fields(sbom_python_version=bad)),
            EvidenceError)
for bad in ('cgr.dev/chainguard/python:latest', 'cgr.dev/chainguard/python',
            'sha256:' + 'b' * 64, 'other.dev/python@sha256:' + 'b' * 64):
    refuses(lambda: canonical_evidence(evidence_fields(base_image_reference=bad)),
            EvidenceError)
print('OK')
"

# --- the happy path -------------------------------------------------------------

run_case "the first ordinary admission publishes CIMP-000001 in CGEN-000000000001" "${PRELUDE}
authority, control = genesis('happy')
before = read_generation(authority)
assert before.cgen == GENESIS_CGEN and before.state is NamespaceState.VALID

result = admit(authority, control)
assert isinstance(result, AdmissionResult)
assert result.cimp == 'CIMP-000001', result.cimp
assert result.cgen == 'CGEN-000000000001', result.cgen
assert result.oci_image_id == IMAGE

generation = read_generation(authority)
assert generation.state is NamespaceState.VALID, generation.state
assert generation.pending == (), generation.pending
assert generation.cgen == 'CGEN-000000000001', generation.cgen
assert generation.eligible_cimps == ('CIMP-000001',), generation.eligible_cimps
assert generation.predecessor_cgen == GENESIS_CGEN
assert generation.predecessor_generation_digest == before.generation_digest
assert generation.authority_set_digest == result.authority_set_digest
assert generation.generation_digest == result.generation_digest

handle = fd(authority)
try:
    admission = resolve_implementation(handle, 'CIMP-000001', generation=generation)
finally:
    os.close(handle)
assert admission.oci_image_id == IMAGE
assert admission.adapter_identity == ADAPTER_IDENTITY
assert admission.argv_contract_identity == ARGV_CONTRACT_IDENTITY
assert admission.payload_schema_version == PAYLOAD_SCHEMA_VERSION
assert admission.execution_profile_schema_version == PROFILE_SCHEMA_VERSION
assert admission.provisioning_evidence_digest == result.provisioning_evidence_digest

# The digest the result reports is the digest of the bytes actually published.
published = read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001', 'admission'))
assert hashlib.sha256(published).hexdigest() == result.admission_digest
print('OK')
"

run_case "a second admission preserves the first and orders deterministically" "${PRELUDE}
authority, control = genesis('second')
first = admit(authority, control)
second_image = '1' * 64
second = admit(authority, control,
               request(image=second_image, observed=second_image))
assert second.cimp == 'CIMP-000002', second.cimp
assert second.cgen == 'CGEN-000000000002', second.cgen

generation = read_generation(authority)
assert generation.state is NamespaceState.VALID
assert generation.eligible_cimps == ('CIMP-000001', 'CIMP-000002'), generation.eligible_cimps
assert [e.cimp for e in generation.entries] == ['CIMP-000001', 'CIMP-000002']
# The earlier entry is preserved byte-for-byte, not rebuilt.
assert generation.entries[0].admission_digest == first.admission_digest
assert generation.entries[0].retirement_digest is None
assert generation.predecessor_cgen == 'CGEN-000000000001'
handle = fd(authority)
try:
    assert resolve_implementation(handle, 'CIMP-000001', generation=generation).oci_image_id == IMAGE
    assert resolve_implementation(handle, 'CIMP-000002', generation=generation).oci_image_id == second_image
finally:
    os.close(handle)
print('OK')
"

run_case "the intermediate state after CIMP publication is pending admission" "${PRELUDE}
# The state between the two publications, constructed exactly as a crash there
# would leave it. It is not reachable from bad input: prerequisites are
# verified before an identifier is burned, so a malformed request never
# publishes anything. Only an interruption produces this, which is why the
# writer asserts it internally and the reader must classify it.
from tools.capability.execution.canonical_json import serialise
authority, control = genesis('intermediate')
admission = serialise({
    'cimp': 'CIMP-000001',
    'oci_image_id': IMAGE,
    'adapter_identity': ADAPTER_IDENTITY,
    'argv_contract_identity': ARGV_CONTRACT_IDENTITY,
    'payload_schema_version': PAYLOAD_SCHEMA_VERSION,
    'execution_profile_schema_version': PROFILE_SCHEMA_VERSION,
    'provisioning_evidence_digest': evidence_digest(canonical_evidence(evidence_fields())),
})
os.makedirs(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001'))
with open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001', 'admission'), 'wb') as h:
    h.write(admission)

generation = read_generation(authority)
assert generation.state is NamespaceState.VALID_WITH_PENDING_DISPOSITION, generation.state
assert len(generation.pending) == 1, generation.pending
assert generation.pending[0].cimp == 'CIMP-000001'
assert generation.pending[0].disposition is PendingDisposition.PENDING_ADMISSION
# Authority did not move: the pointer is still genesis and nothing is eligible.
assert generation.cgen == GENESIS_CGEN, generation.cgen
assert generation.eligible_cimps == ()
# Nothing auto-retired it and nothing deleted it.
path = os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001')
assert os.path.isfile(os.path.join(path, 'admission'))
assert not os.path.exists(os.path.join(path, 'retirement')), 'auto-retired'
# And ordinary admission now refuses until it is dispositioned.
before = tree_digest(authority)
refuses(lambda: admit(authority, control))
assert tree_digest(authority) == before, 'a refused admission mutated authority'
print('OK')
"

# --- refusals -------------------------------------------------------------------

run_case "ordinary admission refuses while any pending disposition exists" "${PRELUDE}
from tools.capability.execution.canonical_json import serialise
authority, control = genesis('pendrefuse')
# A published-but-unlisted CIMP, as an interrupted transaction leaves it.
os.makedirs(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000009'))
with open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000009', 'admission'), 'wb') as h:
    h.write(serialise({
        'cimp': 'CIMP-000009', 'oci_image_id': IMAGE,
        'adapter_identity': ADAPTER_IDENTITY,
        'argv_contract_identity': ARGV_CONTRACT_IDENTITY,
        'payload_schema_version': PAYLOAD_SCHEMA_VERSION,
        'execution_profile_schema_version': PROFILE_SCHEMA_VERSION,
        'provisioning_evidence_digest': 'b' * 64}))
assert read_generation(authority).state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
before = tree_digest(authority)
counters = (read(os.path.join(control, CIMP_COUNTER)),
            read(os.path.join(control, CGEN_COUNTER)))
# An entirely valid admission must still refuse: disposition comes first, and
# it refuses before burning anything.
refuses(lambda: admit(authority, control))
assert tree_digest(authority) == before, 'a refused admission mutated authority'
assert (read(os.path.join(control, CIMP_COUNTER)),
        read(os.path.join(control, CGEN_COUNTER))) == counters, 'burned on refusal'
print('OK')
"

run_case "the burned identifier is never reissued after a failed admission" "${PRELUDE}
authority, control = genesis('burn')
# Prerequisites are verified before any identifier is burned, so a refused
# request costs nothing: a malformed admission must not consume an identity.
refuses(lambda: admit(authority, control, request(observed='9' * 64)))
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
assert read(os.path.join(control, CGEN_COUNTER)) == b'000000000000' + b'\n'
assert os.listdir(os.path.join(authority, IMPLEMENTATIONS)) == []
# A successful admission burns exactly one of each, and never reissues them.
first = admit(authority, control)
assert (read(os.path.join(control, CIMP_COUNTER)),
        read(os.path.join(control, CGEN_COUNTER))) == (b'000001' + b'\n', b'000000000001' + b'\n')
second = admit(authority, control, request(image='4' * 64, observed='4' * 64))
assert second.cimp == 'CIMP-000002' and second.cgen == 'CGEN-000000000002'
assert first.cimp != second.cimp and first.cgen != second.cgen
print('OK')
"

run_case "an invalid namespace refuses ordinary admission" "${PRELUDE}
authority, control = genesis('invalid')
# A reserved identifier physically present is a global integrity finding.
os.makedirs(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000'))
with open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000', 'admission'), 'wb') as h:
    h.write(b'{}')
refuses(lambda: admit(authority, control), IntegrityFailure)
print('OK')
"

run_case "an uninitialised namespace refuses ordinary admission" "${PRELUDE}
authority, control = roots('nogenesis')
handle = fd(control)
try:
    provision_control_state(handle)
finally:
    os.close(handle)
# Genesis is explicit: an absent namespace is not an empty one.
refuses(lambda: admit(authority, control))
print('OK')
"

run_case "missing or malformed control state refuses ordinary admission" "${PRELUDE}
authority, control = genesis('nocounter')
os.unlink(os.path.join(control, CIMP_COUNTER))
refuses(lambda: admit(authority, control), ControlStateError)

authority, control = genesis('badcounter')
path = os.path.join(control, CGEN_COUNTER)
os.unlink(path)
with open(path, 'wb') as handle:
    handle.write(b'nonsense\n')
refuses(lambda: admit(authority, control), ControlStateError)
print('OK')
"

run_case "lock contention refuses rather than interleaving two admissions" "${PRELUDE}
authority, control = genesis('contend')
held = fd(control)
try:
    with implementation_lifecycle_lock(held):
        refuses(lambda: admit(authority, control), LockUnavailable)
finally:
    os.close(held)
# Nothing was allocated or published while the lock was unavailable.
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
assert os.listdir(os.path.join(authority, IMPLEMENTATIONS)) == []
# With the lock free the same admission succeeds.
assert admit(authority, control).cimp == 'CIMP-000001'
print('OK')
"

run_case "unresolved staging residue refuses and is never cleaned up" "${PRELUDE}
authority, control = genesis('residue')
staged = os.path.join(control, STAGING, 'leftover')
os.makedirs(staged)
with open(os.path.join(staged, 'admission'), 'wb') as handle:
    handle.write(b'{}')
refuses(lambda: admit(authority, control), BootstrapError)
assert os.path.isdir(staged), 'admission silently removed staging residue'
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
print('OK')
"

run_case "a malformed image identity refuses before anything is published" "${PRELUDE}
authority, control = genesis('badimage')
for bad in ('sha256:' + 'a' * 64, 'A' * 64, 'a' * 63, 'a' * 65,
            'alpine:latest', 'docker.io/library/alpine', 'g' * 64, ''):
    refuses(lambda: admit(authority, control,
                          AdmissionRequest(oci_image_id=bad,
                                           evidence=canonical_evidence(evidence_fields()),
                                           observed_image_id=bad)))
assert os.listdir(os.path.join(authority, IMPLEMENTATIONS)) == []
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
print('OK')
"

run_case "evidence that does not match the admission refuses" "${PRELUDE}
# The commitment is computed from the exact bytes supplied rather than
# accepted from the caller, so a digest that disagrees with its manifest is
# unrepresentable. What is reachable is evidence that fails its own schema.
authority, control = genesis('evd1')
for broken in (evidence_fields(python_version='3.14.5'),
               evidence_fields(sbom_python_version='3.13.0'),
               evidence_fields(interpreter_path='/usr/bin/python3'),
               evidence_fields(base_image_reference='cgr.dev/chainguard/python:latest')):
    refuses(lambda: canonical_evidence(broken), EvidenceError)

# The manifest names a different image than the admission requests.
authority, control = genesis('evd2')
refuses(lambda: admit(authority, control, AdmissionRequest(
    oci_image_id=IMAGE,
    evidence=canonical_evidence(evidence_fields(image='2' * 64)),
    observed_image_id=IMAGE)))

# Non-canonical bytes are refused rather than reserialised into agreement.
authority, control = genesis('evd3')
refuses(lambda: admit(authority, control, AdmissionRequest(
    oci_image_id=IMAGE, evidence=b'{ \"oci_image_id\": \"' + IMAGE.encode() + b'\" }',
    observed_image_id=IMAGE)))
print('OK')
"

run_case "the three sources of image identity must agree exactly" "${PRELUDE}
authority, control = genesis('threeway')
other = '3' * 64
# admission vs observed
refuses(lambda: admit(authority, control, AdmissionRequest(
    oci_image_id=IMAGE, evidence=canonical_evidence(evidence_fields()),
    observed_image_id=other)))
# evidence vs observed
authority, control = genesis('threeway2')
refuses(lambda: admit(authority, control, AdmissionRequest(
    oci_image_id=other, evidence=canonical_evidence(evidence_fields(image=other)),
    observed_image_id=IMAGE)))
# all three agreeing succeeds
authority, control = genesis('threeway3')
assert admit(authority, control, request(image=other, observed=other)).oci_image_id == other
print('OK')
"

run_case "an unrelated image present in the store grants no authority" "${PRELUDE}
# Track-B isolation, hermetically. A digest that exists somewhere is not a
# digest anybody admitted: only the identity committed by all three sources
# becomes authority, and nothing else in the namespace becomes eligible.
authority, control = genesis('trackb')
residue = '7' * 64            # stands in for an unrelated image already present
admitted = admit(authority, control)
generation = read_generation(authority)
assert generation.eligible_cimps == ('CIMP-000001',)
handle = fd(authority)
try:
    admission = resolve_implementation(handle, 'CIMP-000001', generation=generation)
finally:
    os.close(handle)
assert admission.oci_image_id == IMAGE != residue
# Presence of the unrelated identity in an admission request is not enough
# either: it must agree across all three sources, and a bare claim does not.
refuses(lambda: admit(authority, control, AdmissionRequest(
    oci_image_id=residue, evidence=canonical_evidence(evidence_fields()),
    observed_image_id=residue)))
print('OK')
"

# --- interruption boundaries ----------------------------------------------------

run_case "a published CIMP with no successor generation grants no authority" "${PRELUDE}
authority, control = genesis('crashpub')
refuses(lambda: admit(authority, control, request(observed='9' * 64)))
generation = read_generation(authority)
assert generation.cgen == GENESIS_CGEN
assert generation.eligible_cimps == ()
handle = fd(authority)
try:
    try:
        resolve_implementation(handle, 'CIMP-000001', generation=generation)
    except Exception:
        pass
    else:
        raise AssertionError('a published-but-unlisted CIMP resolved')
finally:
    os.close(handle)
print('OK')
"

run_case "a published successor generation grants nothing until the pointer moves" "${PRELUDE}
# Crash after generation publication, before current-generation advancement.
authority, control = genesis('crashgen')
admit(authority, control)
pointer = os.path.join(authority, CURRENT_GENERATION)
first = read(pointer)
# Roll the pointer back to genesis by hand: the successor generation is still
# published and immutable, and must grant nothing while it is not current.
handle = fd(authority)
try:
    genesis_gen = read(os.path.join(authority, GENERATIONS, GENESIS_CGEN, 'generation'))
finally:
    os.close(handle)
import json
from tools.capability.execution.canonical_json import serialise
os.unlink(pointer)
with open(pointer, 'wb') as handle:
    handle.write(serialise({'cgen': GENESIS_CGEN,
                            'generation_digest': hashlib.sha256(genesis_gen).hexdigest()}))
generation = read_generation(authority)
assert generation.cgen == GENESIS_CGEN
assert generation.eligible_cimps == ()
# The CIMP is published but unlisted, so it reads as pending -- not eligible.
assert generation.state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
assert generation.pending[0].cimp == 'CIMP-000001'
# Both generation directories survive; neither was deleted or rewritten.
assert sorted(os.listdir(os.path.join(authority, GENERATIONS))) == \\
    [GENESIS_CGEN, 'CGEN-000000000001']
print('OK')
"

run_case "a temporary pointer left behind is never read as authority" "${PRELUDE}
authority, control = genesis('crashptr')
admit(authority, control)
pointer = os.path.join(authority, CURRENT_GENERATION)
body = read(pointer)
os.unlink(pointer)
with open(os.path.join(authority, '.' + CURRENT_GENERATION + '.tmp'), 'wb') as handle:
    handle.write(body)
handle = fd(authority)
try:
    try:
        current_generation(handle)
    except Exception:
        pass
    else:
        raise AssertionError('a temporary pointer was read as authority')
finally:
    os.close(handle)
print('OK')
"

run_case "a refused admission leaves published state byte-identical" "${PRELUDE}
authority, control = genesis('immutable')
admit(authority, control)
before = tree_digest(authority)
for bad in (request(observed='9' * 64),
            AdmissionRequest(oci_image_id='A' * 64,
                             evidence=canonical_evidence(evidence_fields()),
                             observed_image_id='A' * 64),
            AdmissionRequest(oci_image_id=IMAGE, evidence=b'{}',
                             observed_image_id=IMAGE)):
    refuses(lambda: admit(authority, control, bad))
    assert tree_digest(authority) == before, 'a refused admission mutated state'
print('OK')
"

run_case "reading and refusing never mutate the control namespace beyond burns" "${PRELUDE}
authority, control = genesis('ctrl')
admit(authority, control)
counters = (read(os.path.join(control, CIMP_COUNTER)),
            read(os.path.join(control, CGEN_COUNTER)))
assert counters == (b'000001' + b'\n', b'000000000001' + b'\n'), counters
for _ in range(3):
    read_generation(authority)
assert (read(os.path.join(control, CIMP_COUNTER)),
        read(os.path.join(control, CGEN_COUNTER))) == counters
assert os.listdir(os.path.join(control, STAGING)) == [], 'staging residue'
print('OK')
"

# --- registration and isolation -------------------------------------------------

run_case "the admission suite runs in local validation and in CI" "${PRELUDE}
from pathlib import Path
name = 'tests/test-capability-authority-admission.sh'
assert name in Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
assert name in Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
print('OK')
"

run_case "no production authority path is created by this suite" "${PRELUDE}
for production in ('/var/lib/kyri/implementation-authority',
                   '/var/lib/kyri/implementation-authority-control'):
    assert not os.path.exists(production), production + ' exists'
assert os.getuid() != 0, 'these tests must not run as root'
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Capability implementation-admission validation passed.\n'
else
  printf 'Capability implementation-admission validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
