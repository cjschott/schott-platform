#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 pending-disposition ceremonies: COMPLETE and
# RETIRE.
#
# OFFLINE AND HERMETIC. Every root is a temporary directory. The two production
# authority roots beneath /var/lib/kyri are never created, written, or removed;
# no image is built, no Podman runs, no shell is spawned, and no gate opens.
# G1, G3, G5, G6, G7 stay closed.
#                                                        # prod-path-reference
#
# ONE GENERATION FOR THE WHOLE PENDING SET. Disposing of pending CIMPs one at a
# time would raise the high-water mark past a still-pending lower ordinal --
# the INVALID condition -- so a sequential ceremony would transit through
# global freeze. Every decision lands in a single successor generation.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §5.1-§5.7, §27

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/provisioning/authority_disposition.py"

assert_offline_only() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
module = root / "tools/provisioning/authority_disposition.py"
runtime = [
    root / "tools/capability/execution/worker.py",
    root / "tools/capability/execution/lifecycle.py",
    root / "tools/capability/execution/adapter.py",
    root / "tools/capability/execution/implementation_authority.py",
    root / "tools/capability/coordinator.py",
    root / "provisioning/execution/kyri-exec-transition.py",
]

findings = []
if not module.is_file():
    print("module-absent")
    raise SystemExit(0)

for target in runtime:
    if not target.is_file():
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
    body = getattr(node, "body", None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
            and body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body.pop(0)
        if not body:
            body.append(ast.Pass())
ast.fix_missing_locations(tree)
code = ast.unparse(tree).lower().replace("python-podman-v1", "<adapter-identity>")
for token in ("subprocess", "popen", "shell=true", "podman", "docker", "sudo",
              "/bin/sh", "runuser"):
    if token in code:
        findings.append(f"forbidden surface {token}")

# The dispositions the architecture permits, and no others.
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value.upper() in ("DELETE", "IGNORE", "REPAIR", "REUSE",
                                  "FORCE", "AUTO"):
            findings.append(f"forbidden disposition {node.value!r}")
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value.startswith("/var") or node.value.startswith("/etc"):
            findings.append(f"production path literal: {node.value!r}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "disposition is operator-only, path-free, and adds no extra verb"
  else
    fail "disposition boundary: ${report}"
  fi
}

assert_offline_only

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
    provision_control_state, implementation_lifecycle_lock, initialise_genesis,
    BootstrapError, ControlStateError, LockUnavailable,
    CIMP_COUNTER, CGEN_COUNTER, STAGING,
    GENESIS_CGEN, IMPLEMENTATIONS, GENERATIONS, CURRENT_GENERATION)
from tools.provisioning.provisioning_evidence import (
    EVIDENCE_SCHEMA_VERSION, GOVERNED_PYTHON_VERSION,
    canonical_evidence, evidence_digest)
from tools.provisioning.authority_admission import (
    admit_implementation, AdmissionRequest, ADAPTER_IDENTITY,
    ARGV_CONTRACT_IDENTITY)
from tools.provisioning.authority_disposition import (
    dispose_pending, Disposition, Decision, DispositionRequest,
    DispositionResult, DispositionRefused)
from tools.capability.execution.implementation_authority import (
    current_generation, resolve_implementation, NamespaceState,
    PendingDisposition, RetiredImplementation, UnknownImplementation,
    IntegrityFailure)
from tools.capability.execution.canonical_json import serialise
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
        'interpreter_link': None,
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

def evidence_for(image=IMAGE):
    return canonical_evidence(evidence_fields(image))

def roots(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    authority = os.path.join(base, 'implementation-authority')
    control = os.path.join(base, 'implementation-authority-control')
    os.makedirs(authority); os.makedirs(control)
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

def admit(authority, control, image=IMAGE):
    a, c = fd(authority), fd(control)
    try:
        return admit_implementation(a, c, request=AdmissionRequest(
            oci_image_id=image, evidence=evidence_for(image),
            observed_image_id=image))
    finally:
        os.close(a); os.close(c)

def publish_pending(authority, cimp, image=IMAGE, retire=False):
    '''An interrupted transaction, exactly as a crash leaves it.'''
    body = serialise({
        'cimp': cimp,
        'oci_image_id': image,
        'adapter_identity': ADAPTER_IDENTITY,
        'argv_contract_identity': ARGV_CONTRACT_IDENTITY,
        'payload_schema_version': PAYLOAD_SCHEMA_VERSION,
        'execution_profile_schema_version': PROFILE_SCHEMA_VERSION,
        'provisioning_evidence_digest': evidence_digest(evidence_for(image)),
    })
    base = os.path.join(authority, IMPLEMENTATIONS, cimp)
    os.makedirs(base, exist_ok=True)
    with open(os.path.join(base, 'admission'), 'wb') as handle:
        handle.write(body)
    if retire:
        with open(os.path.join(base, 'retirement'), 'wb') as handle:
            handle.write(serialise({'cimp': cimp}))
    return cimp

def complete(cimp, image=IMAGE, evidence=None, observed=None):
    return Decision(cimp=cimp, disposition=Disposition.COMPLETE,
                    evidence=evidence_for(image) if evidence is None else evidence,
                    observed_image_id=image if observed is None else observed)

def retire(cimp):
    return Decision(cimp=cimp, disposition=Disposition.RETIRE)

def dispose(authority, control, *decisions):
    a, c = fd(authority), fd(control)
    try:
        return dispose_pending(a, c, request=DispositionRequest(
            decisions=tuple(decisions)))
    finally:
        os.close(a); os.close(c)

def generation_of(authority):
    handle = fd(authority)
    try:
        return current_generation(handle)
    finally:
        os.close(handle)

def read(path):
    with open(path, 'rb') as handle:
        return handle.read()

def refuses(action, expect=DispositionRefused):
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

def counters(control):
    return (read(os.path.join(control, CIMP_COUNTER)),
            read(os.path.join(control, CGEN_COUNTER)))
"

# --- COMPLETE -------------------------------------------------------------------

run_case "COMPLETE makes an interrupted admission eligible under a fresh CGEN" "${PRELUDE}
authority, control = genesis('complete')
admit(authority, control)                      # CIMP-000001 / CGEN-...0001
publish_pending(authority, 'CIMP-000002')
before = generation_of(authority)
assert before.state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
assert before.pending[0].disposition is PendingDisposition.PENDING_ADMISSION

result = dispose(authority, control, complete('CIMP-000002'))
assert isinstance(result, DispositionResult)
assert result.cgen == 'CGEN-000000000002', result.cgen
assert result.completed == ('CIMP-000002',), result.completed
assert result.retired == (), result.retired

generation = generation_of(authority)
assert generation.state is NamespaceState.VALID, generation.state
assert generation.pending == ()
assert generation.cgen == 'CGEN-000000000002'
assert generation.eligible_cimps == ('CIMP-000001', 'CIMP-000002')
assert generation.predecessor_cgen == 'CGEN-000000000001'
assert generation.predecessor_generation_digest == before.generation_digest
handle = fd(authority)
try:
    # The identity comes from the immutable admission, not from the request.
    assert resolve_implementation(handle, 'CIMP-000002', generation=generation).oci_image_id == IMAGE
    assert resolve_implementation(handle, 'CIMP-000001', generation=generation).oci_image_id == IMAGE
finally:
    os.close(handle)
print('OK')
"

run_case "COMPLETE re-performs every authority-publication prerequisite" "${PRELUDE}
# A valid immutable admission proves a record was written, never that the
# external evidence still holds. Each of these is refused before mutation.
for name, decision in (
        ('wrong observed image', lambda: complete('CIMP-000002', observed='9' * 64)),
        ('evidence names another image',
         lambda: Decision(cimp='CIMP-000002', disposition=Disposition.COMPLETE,
                          evidence=evidence_for('9' * 64), observed_image_id=IMAGE)),
        ('evidence digest disagrees with the admission',
         lambda: Decision(cimp='CIMP-000002', disposition=Disposition.COMPLETE,
                          evidence=canonical_evidence(evidence_fields(interpreter_sha256='1' * 64)),
                          observed_image_id=IMAGE)),
        ('evidence is absent',
         lambda: Decision(cimp='CIMP-000002', disposition=Disposition.COMPLETE)),
        ('evidence is not canonical',
         lambda: Decision(cimp='CIMP-000002', disposition=Disposition.COMPLETE,
                          evidence=b'{}', observed_image_id=IMAGE))):
    authority, control = genesis('prereq' + str(abs(hash(name)) % 99999))
    admit(authority, control)
    publish_pending(authority, 'CIMP-000002')
    before, counted = tree_digest(authority), counters(control)
    refuses(lambda: dispose(authority, control, decision()))
    assert tree_digest(authority) == before, name + ': mutated authority'
    assert counters(control) == counted, name + ': burned an identifier'
print('OK')
"

# --- RETIRE ---------------------------------------------------------------------

run_case "RETIRE publishes a retirement and accounts for the CIMP as ineligible" "${PRELUDE}
authority, control = genesis('retire')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
admission_before = read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000002', 'admission'))

result = dispose(authority, control, retire('CIMP-000002'))
assert result.retired == ('CIMP-000002',), result.retired
assert result.completed == ()

generation = generation_of(authority)
assert generation.state is NamespaceState.VALID and generation.pending == ()
assert generation.eligible_cimps == ('CIMP-000001',), generation.eligible_cimps
# Accounted for, and ineligible -- history is not dropped.
entry = [e for e in generation.entries if e.cimp == 'CIMP-000002'][0]
assert entry.retirement_digest is not None
retirement = read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000002', 'retirement'))
assert hashlib.sha256(retirement).hexdigest() == entry.retirement_digest
assert retirement == serialise({'cimp': 'CIMP-000002'})
# The admission was not rewritten.
assert read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000002', 'admission')) == admission_before
handle = fd(authority)
try:
    refuses(lambda: resolve_implementation(handle, 'CIMP-000002', generation=generation),
            RetiredImplementation)
finally:
    os.close(handle)
print('OK')
"

run_case "an interrupted RETIRE resumes without rewriting its retirement" "${PRELUDE}
authority, control = genesis('resume')
admit(authority, control)
publish_pending(authority, 'CIMP-000002', retire=True)
before = generation_of(authority)
assert before.pending[0].disposition is PendingDisposition.PENDING_RETIREMENT
retirement_before = read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000002', 'retirement'))

result = dispose(authority, control, retire('CIMP-000002'))
assert result.retired == ('CIMP-000002',)
assert read(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000002', 'retirement')) == retirement_before
generation = generation_of(authority)
assert generation.state is NamespaceState.VALID and generation.pending == ()
entry = [e for e in generation.entries if e.cimp == 'CIMP-000002'][0]
assert entry.retirement_digest == hashlib.sha256(retirement_before).hexdigest()
print('OK')
"

run_case "COMPLETE is refused for a CIMP whose retirement is already published" "${PRELUDE}
authority, control = genesis('noreverse')
admit(authority, control)
publish_pending(authority, 'CIMP-000002', retire=True)
before, counted = tree_digest(authority), counters(control)
# An immutable retirement is not reversible by a later operator.
refuses(lambda: dispose(authority, control, complete('CIMP-000002')))
assert tree_digest(authority) == before, 'a refused COMPLETE mutated authority'
assert counters(control) == counted, 'a refused COMPLETE burned an identifier'
print('OK')
"

run_case "one wrong decision refuses the whole request before any mutation" "${PRELUDE}
authority, control = genesis('allornothing')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
publish_pending(authority, 'CIMP-000003', retire=True)
before, counted = tree_digest(authority), counters(control)
# CIMP-000003 is already retired, so COMPLETE for it is unlawful -- and the
# lawful RETIRE for CIMP-000002 must not be partially applied.
refuses(lambda: dispose(authority, control,
                        retire('CIMP-000002'), complete('CIMP-000003')))
assert tree_digest(authority) == before, 'a partial disposition was applied'
assert counters(control) == counted
print('OK')
"

# --- mixed --------------------------------------------------------------------

run_case "a mixed pending set is dispositioned in exactly one generation" "${PRELUDE}
authority, control = genesis('mixed')
admit(authority, control)
image4 = '4' * 64
publish_pending(authority, 'CIMP-000004', image=image4)
publish_pending(authority, 'CIMP-000005', retire=True)
publish_pending(authority, 'CIMP-000006')
generation = generation_of(authority)
assert [e.cimp for e in generation.pending] == ['CIMP-000004', 'CIMP-000005', 'CIMP-000006']
cimp_before, cgen_before = counters(control)

result = dispose(authority, control,
                 retire('CIMP-000006'),
                 complete('CIMP-000004', image=image4),
                 retire('CIMP-000005'))
assert result.completed == ('CIMP-000004',), result.completed
assert result.retired == ('CIMP-000005', 'CIMP-000006'), result.retired
assert result.cgen == 'CGEN-000000000002', result.cgen

# Exactly one CGEN for the whole set, and no CIMP allocated at all.
after_cimp, after_cgen = counters(control)
assert after_cimp == cimp_before, 'disposition allocated a CIMP'
assert after_cgen == b'000000000002' + b'\n', after_cgen

generation = generation_of(authority)
assert generation.state is NamespaceState.VALID and generation.pending == ()
assert generation.eligible_cimps == ('CIMP-000001', 'CIMP-000004'), generation.eligible_cimps
assert [e.cimp for e in generation.entries] == \\
    ['CIMP-000001', 'CIMP-000004', 'CIMP-000005', 'CIMP-000006']
for cimp in ('CIMP-000005', 'CIMP-000006'):
    entry = [e for e in generation.entries if e.cimp == cimp][0]
    assert entry.retirement_digest is not None, cimp
handle = fd(authority)
try:
    assert resolve_implementation(handle, 'CIMP-000004', generation=generation).oci_image_id == image4
    assert resolve_implementation(handle, 'CIMP-000001', generation=generation).oci_image_id == IMAGE
    for cimp in ('CIMP-000005', 'CIMP-000006'):
        refuses(lambda: resolve_implementation(handle, cimp, generation=generation),
                RetiredImplementation)
finally:
    os.close(handle)
print('OK')
"

run_case "prior retired entries stay retired across a disposition" "${PRELUDE}
authority, control = genesis('priorretired')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
dispose(authority, control, retire('CIMP-000002'))
publish_pending(authority, 'CIMP-000003')
dispose(authority, control, complete('CIMP-000003'))
generation = generation_of(authority)
assert generation.eligible_cimps == ('CIMP-000001', 'CIMP-000003'), generation.eligible_cimps
retired = [e for e in generation.entries if e.cimp == 'CIMP-000002'][0]
assert retired.retirement_digest is not None, 'a prior retirement was dropped'
print('OK')
"

# --- decision-set validation ----------------------------------------------------

run_case "the decision set must cover the pending set exactly" "${PRELUDE}
authority, control = genesis('cover')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
publish_pending(authority, 'CIMP-000003')
before, counted = tree_digest(authority), counters(control)

# Omitting one would raise the high-water mark past the other and make the
# namespace INVALID, so an incomplete set is refused rather than applied.
refuses(lambda: dispose(authority, control, complete('CIMP-000002')))
# A CIMP that is not pending is not this ceremony's business.
refuses(lambda: dispose(authority, control, complete('CIMP-000002'),
                        complete('CIMP-000003'), complete('CIMP-000009')))
# The already-eligible CIMP is not pending either.
refuses(lambda: dispose(authority, control, complete('CIMP-000002'),
                        complete('CIMP-000003'), retire('CIMP-000001')))
# A CIMP may receive exactly one decision.
refuses(lambda: dispose(authority, control, complete('CIMP-000002'),
                        retire('CIMP-000002'), complete('CIMP-000003')))
# An empty request decides nothing.
refuses(lambda: dispose(authority, control))
assert tree_digest(authority) == before
assert counters(control) == counted
print('OK')
"

run_case "disposition refuses a namespace with nothing pending" "${PRELUDE}
authority, control = genesis('nothing')
admit(authority, control)
assert generation_of(authority).state is NamespaceState.VALID
refuses(lambda: dispose(authority, control, complete('CIMP-000001')))
print('OK')
"

run_case "disposition fails closed on an invalid namespace" "${PRELUDE}
authority, control = genesis('invalid')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
os.makedirs(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000'))
with open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000000', 'admission'), 'wb') as h:
    h.write(b'{}')
refuses(lambda: dispose(authority, control, complete('CIMP-000002')), IntegrityFailure)
print('OK')
"

run_case "lock contention and staging residue refuse before mutation" "${PRELUDE}
authority, control = genesis('guards')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
held = fd(control)
try:
    with implementation_lifecycle_lock(held):
        refuses(lambda: dispose(authority, control, retire('CIMP-000002')),
                LockUnavailable)
finally:
    os.close(held)

staged = os.path.join(control, STAGING, 'leftover')
os.makedirs(staged)
before, counted = tree_digest(authority), counters(control)
refuses(lambda: dispose(authority, control, retire('CIMP-000002')), BootstrapError)
assert os.path.isdir(staged), 'disposition removed staging residue'
assert tree_digest(authority) == before
assert counters(control) == counted
print('OK')
"

# --- interruption boundaries ----------------------------------------------------

run_case "a published retirement changes the subtype and survives interruption" "${PRELUDE}
# The state after RETIRE publishes its record but before the generation
# becomes current: the decision is immutable, the CIMP is still pending, and
# ordinary admission stays blocked.
authority, control = genesis('subtype')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
assert generation_of(authority).pending[0].disposition is PendingDisposition.PENDING_ADMISSION
publish_pending(authority, 'CIMP-000002', retire=True)   # retirement now published
generation = generation_of(authority)
assert generation.state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
assert generation.pending[0].disposition is PendingDisposition.PENDING_RETIREMENT
assert generation.cgen == 'CGEN-000000000001', 'authority moved'
assert generation.eligible_cimps == ('CIMP-000001',)
# Ordinary admission is still blocked, and COMPLETE is no longer available.
refuses(lambda: dispose(authority, control, complete('CIMP-000002')))
print('OK')
"

run_case "a partly retired pending set reports accurate mixed subtypes" "${PRELUDE}
# Crash after publishing some retirement records but not all.
authority, control = genesis('partial')
admit(authority, control)
publish_pending(authority, 'CIMP-000002', retire=True)
publish_pending(authority, 'CIMP-000003')
publish_pending(authority, 'CIMP-000004', retire=True)
generation = generation_of(authority)
assert [e.cimp for e in generation.pending] == \\
    ['CIMP-000002', 'CIMP-000003', 'CIMP-000004']
assert [e.disposition for e in generation.pending] == [
    PendingDisposition.PENDING_RETIREMENT,
    PendingDisposition.PENDING_ADMISSION,
    PendingDisposition.PENDING_RETIREMENT]
# A resumed request must respect the already-published decisions.
refuses(lambda: dispose(authority, control, retire('CIMP-000002'),
                        complete('CIMP-000003'), complete('CIMP-000004')))
retirements = {c: read(os.path.join(authority, IMPLEMENTATIONS, c, 'retirement'))
               for c in ('CIMP-000002', 'CIMP-000004')}
result = dispose(authority, control, retire('CIMP-000002'),
                 complete('CIMP-000003'), retire('CIMP-000004'))
assert result.completed == ('CIMP-000003',)
assert result.retired == ('CIMP-000002', 'CIMP-000004')
for cimp, body in retirements.items():
    assert read(os.path.join(authority, IMPLEMENTATIONS, cimp, 'retirement')) == body, \\
        cimp + ': retirement was rewritten'
generation = generation_of(authority)
assert generation.state is NamespaceState.VALID and generation.pending == ()
assert generation.eligible_cimps == ('CIMP-000001', 'CIMP-000003')
print('OK')
"

run_case "a published successor generation grants nothing until the pointer moves" "${PRELUDE}
authority, control = genesis('pointer')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
dispose(authority, control, complete('CIMP-000002'))
pointer = os.path.join(authority, CURRENT_GENERATION)
previous = read(os.path.join(authority, GENERATIONS, 'CGEN-000000000001', 'generation'))
os.unlink(pointer)
with open(pointer, 'wb') as handle:
    handle.write(serialise({'cgen': 'CGEN-000000000001',
                            'generation_digest': hashlib.sha256(previous).hexdigest()}))
generation = generation_of(authority)
assert generation.cgen == 'CGEN-000000000001'
assert generation.eligible_cimps == ('CIMP-000001',)
assert generation.state is NamespaceState.VALID_WITH_PENDING_DISPOSITION
assert generation.pending[0].cimp == 'CIMP-000002'
# Both generations survive; nothing was deleted or rewritten.
assert sorted(os.listdir(os.path.join(authority, GENERATIONS))) == \\
    ['CGEN-000000000000', 'CGEN-000000000001', 'CGEN-000000000002']
print('OK')
"

run_case "a temporary pointer left behind is never read as authority" "${PRELUDE}
authority, control = genesis('temp')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
dispose(authority, control, retire('CIMP-000002'))
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

run_case "disposition leaves no staging residue and touches no CIMP counter" "${PRELUDE}
authority, control = genesis('clean')
admit(authority, control)
publish_pending(authority, 'CIMP-000002')
publish_pending(authority, 'CIMP-000003', retire=True)
cimp_before = counters(control)[0]
dispose(authority, control, retire('CIMP-000002'), retire('CIMP-000003'))
assert os.listdir(os.path.join(control, STAGING)) == [], 'staging residue'
assert counters(control)[0] == cimp_before, 'disposition allocated a CIMP'
assert counters(control)[1] == b'000000000002' + b'\n'
print('OK')
"

# --- registration and isolation -------------------------------------------------

run_case "the disposition suite runs in local validation and in CI" "${PRELUDE}
from pathlib import Path
name = 'tests/test-capability-authority-disposition.sh'
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
  printf 'Capability pending-disposition validation passed.\n'
else
  printf 'Capability pending-disposition validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
