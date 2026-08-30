#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 coordinator execution-authorization bridge.
#
# UNPRIVILEGED THROUGHOUT. Nothing here invokes sudo, executes a privileged
# helper, execs a worker, starts a subprocess that could reach a container
# runtime, or installs anything. The bridge is coordinator-plane source and the
# privileged boundary only ever *verifies* what it produces.
#
# THE LIFECYCLE TRANSITION IS THE AUTHORITY. The launch-authorisation file is a
# governed projection of that authority and the handoff is materialisation.
# That ordering is what makes an interrupted run recoverable: authority first,
# then the things derived from it, each reconstructible from the authority
# alone.
#
# RULING A. commitment_digest is the lowercase 64-hex body of the prepared
# invocation's existing binding_digest. No second canonicalisation and no
# second digest scheme.
#
# RULING B. The launch-authorisation is authority-bearing and is written only
# through the CMUT substrate, under one new closed target kind whose complete
# target is derived from a validated CINV.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §6, §13, §16
#   docs/superpowers/specs/2026-08-11-execution-transition-boundary.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORKDIR="$(mktemp -d)"
export WORKDIR
trap 'rm -rf "${WORKDIR}"' EXIT

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

# Production paths this suite must leave exactly as it found them. The handoff
# and execution roots are live coordinator state; the sudoers policies are gate
# state that must be absent whatever else is true.
PRODUCTION_PATHS=(
  /data/kyri/capability-handoff
  /data/kyri/capability-runtime/execution
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
)
PRODUCTION_BEFORE="$(mktemp)"
# The fixture publishes read-only trees on purpose, so cleanup has to restore
# write permission before it can remove them. Failing to do so would leave the
# suite reporting a spurious error from `rm` after every case had passed.
trap 'chmod -R u+w "${WORKDIR}" 2>/dev/null || true; rm -rf "${WORKDIR}"; rm -f "${PRODUCTION_BEFORE}"' EXIT
snapshot_production() {
  python3 -c '
import json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    except PermissionError:
        # /etc/sudoers.d is 0755 on the deployment host and 0750 on some
        # runners. Unreadable is a distinct answer from absent: record it so a
        # change either way is still visible, rather than crashing the snapshot.
        state[path] = "unreadable"
        continue
    state[path] = [info.st_mode, info.st_uid, info.st_gid, info.st_size,
                   info.st_mtime_ns, info.st_ctime_ns]
print(json.dumps(state, sort_keys=True))
' "$@"
}
snapshot_production "${PRODUCTION_PATHS[@]}" > "${PRODUCTION_BEFORE}"

PRELUDE="import os, sys
sys.path.insert(0, os.getcwd())
"

# ---------------------------------------------------------------------------
# The fixture. One prepared invocation, one admitted implementation, one staged
# package, one payload -- built through the governed constructors rather than
# by writing records by hand, so a fixture that drifts from the contract fails
# here rather than passing something the runtime would refuse.
# ---------------------------------------------------------------------------

FIXTURE="${PRELUDE}
import hashlib, json, shutil, stat
from datetime import datetime, timezone

from tools.capability.execution import launch as L
from tools.capability.execution import mutation as M
from tools.capability.execution import state as S
from tools.capability.execution import capacity as C
from tools.capability.execution import profile as P
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.package_contract import (
    inspect_package, validate_package)
from tools.capability.execution.payload import validate_payload
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.worker import CONTAINER_INTERPRETER
from tools.capability.store import CapabilityStore
from tools.capability.evidence import record_invocation
from tools.capability.invocation_identity import bind, payload_digest
from tools.capability.package_resolution import (
    MANIFEST_SCHEMA_VERSION, resolve_and_stage_package)
from tools.provisioning.authority_bootstrap import (
    provision_control_state, initialise_genesis)
from tools.provisioning.authority_admission import (
    admit_implementation, AdmissionRequest)
from tools.provisioning.provisioning_evidence import (
    GOVERNED_SBOM_PACKAGE, EVIDENCE_SCHEMA_VERSION, GOVERNED_PYTHON_VERSION,
    canonical_evidence)

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
IMAGE = 'a' * 64
PAYLOAD = {'operation': 'sum', 'arguments': {'count': 3}}
PACKAGE_FILES = {'main.py': b'def run():\n    return {}\n'}
ACTOR = 'operator'
SELECTION = 'CSEL-000001'
INSTANCE = 'CINS-000001'
PACKAGE_ID = 'CPKG-000001'
# The action the invocation asked for, carried through the durable record.
OPERATION = 'execute'

def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)
    os.chmod(path, mode)

def fresh(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    return base

def admission(cimp='CIMP-000001', image=None, **overrides):
    fields = dict(
        cimp=cimp, oci_image_id=image if image else IMAGE,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)
    fields.update(overrides)
    return Admission(**fields)

def anchored(base):
    '''A verified RootDescriptor over ``base``, through the governed path.'''
    cfg = os.path.join(base, '..', os.path.basename(base) + '-backing.json')
    write(os.path.normpath(cfg), serialise(
        {'filesystem_uuid': UUID, 'filesystem_type': 'xfs',
         'mount_point': '/data'}))
    cfg_fd = os.open(os.path.normpath(cfg), os.O_RDONLY)
    root_fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return verify_backing_store(cfg_fd, root_fd, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs', mount_point='/data',
            device_name='/dev/sdb1'))
    finally:
        os.close(cfg_fd); os.close(root_fd)

def execution_root(name='exec'):
    '''A provisioned execution namespace, exactly as an operator lays it out.'''
    base = fresh(name)
    for directory in ('state', 'transitions', 'locks', 'mutations',
                      'quarantine-reservations', 'quarantine-releases'):
        os.mkdir(os.path.join(base, directory), 0o700)
    write(os.path.join(base, M.CMUT_COUNTER), b'000000000000\n')
    return anchored(base)

def handoff_root(name='hand'):
    return anchored(fresh(name))

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

def authority(name='auth', images=(IMAGE,)):
    '''The published authority namespace, built by the governed tooling.

    Deliberately not hand-written records: the bridge resolves through the same
    reader an operator ceremony publishes for, so a fixture that drifted from
    that contract would prove the bridge works against something nobody runs.
    '''
    base = fresh(name)
    auth_dir = os.path.join(base, 'authority')
    control = os.path.join(base, 'control')
    os.makedirs(auth_dir); os.makedirs(control)
    os.chmod(auth_dir, 0o2750)
    os.mkdir(os.path.join(control, 'staging'), 0o2750)
    os.chmod(os.path.join(control, 'staging'), 0o2750)
    a = os.open(auth_dir, os.O_RDONLY | os.O_DIRECTORY)
    c = os.open(control, os.O_RDONLY | os.O_DIRECTORY)
    try:
        provision_control_state(c)
        initialise_genesis(a, c)
        for image in images:
            admit_implementation(a, c, request=AdmissionRequest(
                oci_image_id=image, evidence=evidence_for(image),
                observed_image_id=image))
    finally:
        os.close(a); os.close(c)
    return os.open(auth_dir, os.O_RDONLY | os.O_DIRECTORY)

class Evidence:
    '''The governed selection outcome, as the coordinator received it.'''
    def __init__(self, supported=True):
        self.supported = supported
        self.reason = None
        self.selection_id = SELECTION
        self.instance_id = INSTANCE
        self.capability_package_id = PACKAGE_ID
        self.contract_id = 'CCON-000001'
        self.capability_id = 'CCAP-000001'
        self.effect_class = 'read-only'
        self.artifact_reference = 'tree:pkg'
        self.manifest_reference = 'file:manifest.json'
        self.operation = OPERATION
        self.target_node_identity = 'HOST-0001'

def package_tree(name='pkg', files=None):
    '''A staged package tree, produced by the REAL generation-10 resolver.

    Deliberately not a hand-built object. Generation 9's bridge fixture
    fabricated a Staged whose staged_path was a directory, while the real S4
    resolver staged a regular file -- so every case here passed against an
    S4->S5 contract that could not execute once. A fixture that constructs the
    contract type itself can only ever agree with itself.
    '''
    # Modes are set rather than inherited: the trusted-source contract refuses a
    # group-writable approved root, and this suite runs under whatever umask the
    # operator has.
    approved = fresh(name + '-approved')
    os.chmod(approved, 0o755)
    tree = os.path.join(approved, 'pkg')
    os.makedirs(tree, 0o755)
    os.chmod(tree, 0o755)
    for relative, body in (PACKAGE_FILES if files is None else files).items():
        write(os.path.join(tree, relative), body)
    handle = os.open(tree, os.O_RDONLY | os.O_DIRECTORY)
    try:
        commitment = 'sha256:' + inspect_package(handle).digest
    finally:
        os.close(handle)
    write(os.path.join(approved, 'manifest.json'), serialise({
        'schema_version': MANIFEST_SCHEMA_VERSION,
        'capability_package_id': PACKAGE_ID, 'contract_id': 'CCON-000001',
        'capability_id': 'CCAP-000001', 'artifact_reference': 'tree:pkg',
        'package_tree_sha256': commitment}))
    staging = fresh(name + '-staging')
    os.chmod(staging, 0o700)
    staged = resolve_and_stage_package(
        evidence=Evidence(), approved_artifact_root=approved,
        trusted_source_uid=os.getuid(), staging_root=staging,
        coordinator_uid=os.getuid())
    assert staged.supported, staged.reason
    return staged

def capability_store(name='store'):
    base = fresh(name)
    return CapabilityStore(base, expected_uid=os.getuid(),
                           expected_gid=os.getgid())

def prepared(store, staged, invocation_id='request-1', payload=None,
             selection=SELECTION, instance=INSTANCE, package=PACKAGE_ID,
             actor=ACTOR):
    '''One durable execution-prepared invocation, through the real recorder.'''
    body = PAYLOAD if payload is None else payload
    decision = record_invocation(
        store, invocation_id=invocation_id,
        binding_digest=bind(payload=body, invocation_id=invocation_id,
                            selection_id=selection, instance_id=instance,
                            capability_package_id=package,
                            operation=OPERATION, actor=actor),
        payload_digest=payload_digest(body), evidence=Evidence(),
        staged=staged, actor=actor,
        request_id='REQ-1',
        requested_at=datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc))
    assert decision.status == 'prepared', decision
    return decision

def payload_fd(body=None, name='payload.json'):
    '''A descriptor on the payload, which is how the bridge accepts one.'''
    path = os.path.join(WORK, name)
    write(path, serialise(PAYLOAD if body is None else body))
    return os.open(path, os.O_RDONLY)

def bridge(store, decision, exec_root, hand_root, auth_fd, payload=None,
           entrypoint='main.py', cimp='CIMP-000001'):
    tree = os.open(decision.staged_path, os.O_RDONLY | os.O_DIRECTORY)
    handle = payload_fd(payload)
    try:
        return L.authorise_launch(
            store=store, execution_root=exec_root, handoff_root=hand_root,
            authority_fd=auth_fd, cinv=decision.invocation_record_id,
            cimp=cimp, payload_fd=handle,
            package_entrypoint=entrypoint, artefact_fd=tree)
    finally:
        os.close(tree); os.close(handle)

def scenario(name):
    '''Everything one case needs, freshly built and independent.'''
    store = capability_store(name + '-store')
    staged = package_tree(name + '-pkg')
    decision = prepared(store, staged)
    return (store, decision, execution_root(name + '-exec'),
            handoff_root(name + '-hand'), authority(name + '-auth'))
"

# ===========================================================================
# A. Ruling A -- the commitment digest
# ===========================================================================

run_case "the commitment is the binding digest body and nothing else" "${FIXTURE}
store, decision, ex, ha, auth = scenario('a1')
ready = bridge(store, decision, ex, ha, auth)
assert decision.binding_digest.startswith('sha256:'), decision.binding_digest
assert ready.commitment_digest == decision.binding_digest[7:], ready
assert len(ready.commitment_digest) == 64, ready.commitment_digest
assert ready.commitment_digest == ready.commitment_digest.lower()
print('OK')
"

run_case "the commitment derivation refuses every malformed binding" "${FIXTURE}
for bad in (None, 42, '', 'sha256:' + 'a' * 63, 'sha256:' + 'a' * 65,
            'sha256:' + 'A' * 64, 'a' * 64, 'sha512:' + 'a' * 64,
            'sha256:' + 'g' * 64, 'SHA256:' + 'a' * 64):
    try:
        L.commitment_digest(bad)
    except L.LaunchError:
        continue
    raise AssertionError('accepted ' + repr(bad))
assert L.commitment_digest('sha256:' + 'b' * 64) == 'b' * 64
print('OK')
"

run_case "the projection refuses a commitment that is not bare lowercase hex" "${FIXTURE}
good = dict(cinv='CINV-000001', cimp='CIMP-000001',
            profile_digest='c' * 64, commitment_digest='b' * 64)
L.launch_record(**good)
for bad in ('sha256:' + 'b' * 64, 'B' * 64, 'b' * 63, 'b' * 65, '', None, 5):
    try:
        L.launch_record(**dict(good, commitment_digest=bad))
    except L.LaunchError:
        continue
    raise AssertionError('accepted ' + repr(bad))
print('OK')
"

run_case "a substituted or differently bound invocation is refused" "${FIXTURE}
store, decision, ex, ha, auth = scenario('a2')
ready = bridge(store, decision, ex, ha, auth)
# The payload is re-presented at launch and checked against the digest the
# prepared record already committed to. A different payload is a different
# binding, and a different binding may not borrow this authorisation.
store2, decision2, ex2, ha2, auth2 = scenario('a3')
try:
    bridge(store2, decision2, ex2, ha2, auth2,
           payload={'operation': 'sum', 'arguments': {'count': 4}})
except L.LaunchError:
    print('OK')
else:
    raise AssertionError('a substituted payload was accepted')
"

# ===========================================================================
# B. Ruling B -- the fifth mutation target kind
# ===========================================================================

run_case "the launch-authorisation target derives its whole path from a CINV" "${FIXTURE}
target = M.MutationTarget(kind=M.TargetKind.LAUNCH_AUTHORISATION,
                          name='CINV-000042')
assert target.directory == 'CINV-000042', target.directory
assert target.record_name == 'launch-authorisation', target.record_name
print('OK')
"

run_case "the new target kind admits nothing but a canonical CINV" "${FIXTURE}
for bad in ('CINV-00004', 'CINV-0000422', 'cinv-000042', 'CINV-00004a',
            '../CINV-000042', 'CINV-000042/x', '/CINV-000042',
            'CINV-000042.1', 'launch-authorisation', '', '.', '..',
            'CINV-000042/../../etc', 'CINV-000042\x00'):
    try:
        M.MutationTarget(kind=M.TargetKind.LAUNCH_AUTHORISATION, name=bad)
    except ValueError:
        continue
    raise AssertionError('accepted ' + repr(bad))
print('OK')
"

run_case "the caller cannot choose the directory, filename, or suffix" "${FIXTURE}
import inspect
source = inspect.getsource(M)
# The record name is a module constant reached through the target, never a
# parameter: a caller that could name the file could name a different one.
assert 'LAUNCH_AUTHORISATION_NAME = ' in source, source[:0]
signature = inspect.signature(M.MutationTarget)
assert list(signature.parameters) == ['kind', 'name'], signature
target = M.MutationTarget(kind=M.TargetKind.LAUNCH_AUTHORISATION,
                          name='CINV-000042')
for attribute in ('directory', 'record_name'):
    try:
        setattr(target, attribute, 'elsewhere')
    except Exception:
        continue
    raise AssertionError(attribute + ' is settable')
print('OK')
"

run_case "the four existing target grammars are unchanged" "${FIXTURE}
assert M.MutationTarget(kind=M.TargetKind.EXECUTION_STATE,
                        name='CINV-000042').directory == 'state'
assert M.MutationTarget(kind=M.TargetKind.EXECUTION_TRANSITION,
                        name='CINV-000042.000001').directory == 'transitions'
assert M.MutationTarget(kind=M.TargetKind.QUARANTINE_RESERVATION,
                        name='CINV-000042').directory == 'quarantine-reservations'
assert M.MutationTarget(kind=M.TargetKind.QUARANTINE_RELEASE,
                        name='CINV-000042').directory == 'quarantine-releases'
# record_name is the name itself for every pre-existing kind, so the install
# path they resolve to is byte-identical to what it was.
for kind, name in ((M.TargetKind.EXECUTION_STATE, 'CINV-000042'),
                   (M.TargetKind.EXECUTION_TRANSITION, 'CINV-000042.000001'),
                   (M.TargetKind.QUARANTINE_RESERVATION, 'CINV-000042'),
                   (M.TargetKind.QUARANTINE_RELEASE, 'CINV-000042')):
    assert M.MutationTarget(kind=kind, name=name).record_name == name
# A sequenced name still belongs only to transitions.
try:
    M.MutationTarget(kind=M.TargetKind.EXECUTION_STATE, name='CINV-000042.000001')
except ValueError:
    pass
else:
    raise AssertionError('the execution-state grammar was widened')
print('OK')
"

run_case "an unknown target kind is refused" "${FIXTURE}
for bad in ('launch-authorisation', None, 5, object()):
    try:
        M.MutationTarget(kind=bad, name='CINV-000042')
    except (ValueError, KeyError):
        continue
    raise AssertionError('accepted ' + repr(bad))
try:
    M.TargetKind('not-a-kind')
except ValueError:
    print('OK')
else:
    raise AssertionError('an unknown kind value was accepted')
"

run_case "the launch-authorisation installs exactly once" "${FIXTURE}
store, decision, ex, ha, auth = scenario('b1')
ready = bridge(store, decision, ex, ha, auth)
cinv = decision.invocation_record_id
path = os.path.join('/proc/self/fd', str(ex.fd), cinv, 'launch-authorisation')
body = open(path, 'rb').read()
mutation = M.Mutation(ex)
cmut = mutation.begin(
    M.MutationTarget(kind=M.TargetKind.LAUNCH_AUTHORISATION, name=cinv),
    schema_type='launch-authorisation',
    expected_sha256=hashlib.sha256(body).hexdigest())
try:
    mutation.install(cmut, body)
except M.AlreadyInstalled:
    print('OK')
else:
    raise AssertionError('a second installation was accepted')
"

# ===========================================================================
# C. Lifecycle authority
# ===========================================================================

run_case "a prepared invocation advances to launch_authorized and stops" "${FIXTURE}
store, decision, ex, ha, auth = scenario('c1')
ready = bridge(store, decision, ex, ha, auth)
cinv = decision.invocation_record_id
assert S.current_state(ex, cinv) is LifecycleState.LAUNCH_AUTHORIZED, \\
    S.current_state(ex, cinv)
assert ready.cinv == cinv and ready.cimp == 'CIMP-000001', ready
assert ready.resumed is False, ready
print('OK')
"

run_case "an invocation that is not execution-prepared is refused" "${FIXTURE}
store, decision, ex, ha, auth = scenario('c2')
# A refused invocation records the refusal and consumes its identity; it is
# never a base for a launch decision.
for missing in ('CINV-999999', 'CINV-000000'):
    try:
        tree = os.open(decision.staged_path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            handle = payload_fd()
            try:
                L.authorise_launch(
                    store=store, execution_root=ex, handoff_root=ha,
                    authority_fd=auth, cinv=missing, cimp='CIMP-000001',
                    payload_fd=handle, package_entrypoint='main.py',
                    artefact_fd=tree)
            finally:
                os.close(handle)
        finally:
            os.close(tree)
    except L.LaunchError:
        continue
    raise AssertionError('accepted ' + missing)
print('OK')
"

run_case "a malformed CINV never reaches the substrate" "${FIXTURE}
store, decision, ex, ha, auth = scenario('c3')
tree = os.open(decision.staged_path, os.O_RDONLY | os.O_DIRECTORY)
try:
    for bad in ('CINV-00004', 'cinv-000042', '../x', 'CINV-000042/x', '', None):
        try:
            handle = payload_fd()
            try:
                L.authorise_launch(
                    store=store, execution_root=ex, handoff_root=ha,
                    authority_fd=auth, cinv=bad, cimp='CIMP-000001',
                    payload_fd=handle, package_entrypoint='main.py',
                    artefact_fd=tree)
            finally:
                os.close(handle)
        except (L.LaunchError, ValueError):
            continue
        raise AssertionError('accepted ' + repr(bad))
finally:
    os.close(tree)
assert os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'transitions')) == []
print('OK')
"

run_case "an already-terminal lifecycle refuses a second authorisation" "${FIXTURE}
store, decision, ex, ha, auth = scenario('c4')
cinv = decision.invocation_record_id
bridge(store, decision, ex, ha, auth)
S.transition(ex, cinv, LifecycleState.LAUNCH_AUTHORIZED, LifecycleState.CREATED)
try:
    bridge(store, decision, ex, ha, auth)
except L.LaunchError:
    print('OK')
else:
    raise AssertionError('a consumed lifecycle was authorised again')
"

run_case "an unadmitted implementation is refused before any authority commit" "${FIXTURE}
store, decision, ex, ha, auth = scenario('c5')
try:
    bridge(store, decision, ex, ha, auth, cimp='CIMP-000009')
except Exception as error:
    assert not isinstance(error, AssertionError), error
    assert S.current_state(ex, decision.invocation_record_id) is None, 'state was committed'
    assert os.listdir(os.path.join('/proc/self/fd', str(ha.fd))) == [], 'handoff published'
    print('OK')
else:
    raise AssertionError('an unadmitted CIMP was accepted')
"

run_case "the bridge reruns no Fabric selection and makes no Trust decision" "${FIXTURE}
import inspect
# Comments and docstrings are stripped: what matters is that the bridge cannot
# *call* these, and a file forbidden from naming them in prose could not
# explain why it does not.
source = inspect.getsource(L)
body = '\n'.join(line for line in source.splitlines()
                 if not line.lstrip().startswith('#'))
for banned in ('verify_selected_evidence', 'resolve_and_stage_package',
               'fabric_evidence', 'trust_adapter', 'compute_eligibility',
               'verify_selected', 'admit_implementation'):
    assert banned not in body, banned
import sys as _sys
loaded = [m for m in _sys.modules if '.fabric' in m or m.startswith('tools.fabric')
          or m.startswith('tools.trust')]
assert loaded == [], loaded
print('OK')
"

# ===========================================================================
# D. Interrupted states and deterministic resume
# ===========================================================================

run_case "State A -- authority committed, projection and handoff absent" "${FIXTURE}
store, decision, ex, ha, auth = scenario('d1')
cinv = decision.invocation_record_id
# Exactly the crash the ruling names: the lifecycle advanced and nothing after
# it happened. A rerun completes the deterministic remainder.
C.reserve(ex, cinv)
S.transition(ex, cinv, LifecycleState.RESERVED, LifecycleState.LAUNCH_AUTHORIZED)
ready = bridge(store, decision, ex, ha, auth)
assert ready.resumed is True, ready
assert S.current_state(ex, cinv) is LifecycleState.LAUNCH_AUTHORIZED
records = os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'transitions'))
assert len(records) == 2, records
print('OK')
"

run_case "State B -- authority and projection committed, handoff absent" "${FIXTURE}
store, decision, ex, ha, auth = scenario('d2')
cinv = decision.invocation_record_id
first = bridge(store, decision, ex, ha, auth)
# Remove only the materialisation, leaving authority and projection intact.
tree = os.path.join('/proc/self/fd', str(ha.fd), cinv)
for base, dirs, files in os.walk(tree):
    os.chmod(base, 0o755)
shutil.rmtree(tree)
second = bridge(store, decision, ex, ha, auth)
assert second.resumed is True, second
assert second.profile_digest == first.profile_digest, (first, second)
assert second.commitment_digest == first.commitment_digest
print('OK')
"

run_case "a projection that disagrees with the committed authority refuses" "${FIXTURE}
store, decision, ex, ha, auth = scenario('d3')
cinv = decision.invocation_record_id
bridge(store, decision, ex, ha, auth)
path = os.path.join('/proc/self/fd', str(ex.fd), cinv, 'launch-authorisation')
record = json.loads(open(path, 'rb').read())
record['commitment_digest'] = 'f' * 64
os.chmod(path, 0o600)
with open(path, 'wb') as handle:
    handle.write(serialise(record))
try:
    bridge(store, decision, ex, ha, auth)
except L.LaunchError:
    print('OK')
else:
    raise AssertionError('a disagreeing projection was accepted')
"

run_case "an existing handoff is verified completely, never assumed" "${FIXTURE}
store, decision, ex, ha, auth = scenario('d4')
cinv = decision.invocation_record_id
bridge(store, decision, ex, ha, auth)
payload_path = os.path.join('/proc/self/fd', str(ha.fd), cinv, 'payload')
os.chmod(os.path.join('/proc/self/fd', str(ha.fd), cinv), 0o755)
os.chmod(payload_path, 0o644)
with open(payload_path, 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":9}}')
try:
    bridge(store, decision, ex, ha, auth)
except L.LaunchError:
    print('OK')
else:
    raise AssertionError('a substituted handoff was accepted as equivalent')
"

run_case "a pathname that merely exists is not a handoff" "${FIXTURE}
store, decision, ex, ha, auth = scenario('d5')
cinv = decision.invocation_record_id
os.mkdir(os.path.join('/proc/self/fd', str(ha.fd), cinv), 0o555)
try:
    bridge(store, decision, ex, ha, auth)
except L.LaunchError:
    print('OK')
else:
    raise AssertionError('an empty directory was accepted as a handoff')
"

run_case "nothing is repaired, overwritten, or recreated on disagreement" "${FIXTURE}
import inspect
source = inspect.getsource(L)
body = '\n'.join(line for line in source.splitlines()
                 if not line.lstrip().startswith('#'))
for banned in ('rmtree(', 'os.unlink', 'os.remove', 'os.rmdir', 'os.chmod',
               'os.chown', 'O_TRUNC', 'O_CREAT'):
    assert banned not in body, banned
print('OK')
"

# ===========================================================================
# E. Idempotency
# ===========================================================================

run_case "an exact repeat returns the same authority without a second decision" "${FIXTURE}
store, decision, ex, ha, auth = scenario('e1')
cinv = decision.invocation_record_id
first = bridge(store, decision, ex, ha, auth)
before = sorted(os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'transitions')))
mutations_before = sorted(os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'mutations')))
second = bridge(store, decision, ex, ha, auth)
assert first.cinv == second.cinv
assert first.profile_digest == second.profile_digest
assert first.commitment_digest == second.commitment_digest
assert second.resumed is True and first.resumed is False, (first, second)
after = sorted(os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'transitions')))
mutations_after = sorted(os.listdir(os.path.join('/proc/self/fd', str(ex.fd), 'mutations')))
assert before == after, (before, after)
assert mutations_before == mutations_after, (mutations_before, mutations_after)
assert len(os.listdir(os.path.join('/proc/self/fd', str(ha.fd)))) == 1
print('OK')
"

run_case "no second invocation identity is allocated by a repeat" "${FIXTURE}
store, decision, ex, ha, auth = scenario('e2')
records = store.list_records('capability-invocation')
bridge(store, decision, ex, ha, auth)
bridge(store, decision, ex, ha, auth)
assert store.list_records('capability-invocation') == records, 'a record was written'
print('OK')
"

run_case "a conflicting repeat refuses rather than re-authorising" "${FIXTURE}
store, decision, ex, ha, auth = scenario('e3')
bridge(store, decision, ex, ha, auth)
for conflict in (dict(entrypoint='other.py'), dict(cimp='CIMP-000002')):
    try:
        bridge(store, decision, ex, ha, auth, **conflict)
    except Exception as error:
        assert not isinstance(error, AssertionError), error
        continue
    raise AssertionError('a conflicting repeat was accepted: ' + repr(conflict))
print('OK')
"

# ===========================================================================
# F. Security backstops
# ===========================================================================

run_case "the bridge cannot elevate, execute, or reach a container runtime" "${FIXTURE}
import inspect
source = inspect.getsource(L)
for banned in ('subprocess', 'os.system', 'os.exec', 'os.spawn', 'os.fork',
               'popen', 'sudo', 'podman', 'Podman', 'docker', 'create_argv',
               'kyri-exec', 'libexec', 'ctypes', 'socket', 'urllib',
               'requests', 'http', 'setuid', 'setgid', 'sudoers'):
    assert banned not in source, banned
print('OK')
"

run_case "the bridge imports nothing that could execute or decide policy" "${FIXTURE}
import subprocess
probe = ('import sys; import tools.capability.execution.launch; '
         'bad = [m for m in sys.modules '
         'if m.split(chr(46))[0] in (chr(115)+\\'ubprocess\\', \\'socket\\', \\'ctypes\\') '
         'or m.endswith(\\'.snapshot\\') or m.endswith(\\'.worker\\') '
         'or m.endswith(\\'.adapter\\')]; print(sorted(bad))')
out = subprocess.run([sys.executable, '-c', probe], capture_output=True,
                     text=True, check=True).stdout.strip()
assert out == '[]', out
print('OK')
"

run_case "the bridge writes no Fabric record and grants no authority" "${FIXTURE}
store, decision, ex, ha, auth = scenario('f1')
bridge(store, decision, ex, ha, auth)
# The authority namespace is opened read-only and is never a write target.
import inspect
source = inspect.getsource(L)
assert 'O_WRONLY' not in source and 'O_RDWR' not in source, source[:0]
assert 'authority_fd' in source
print('OK')
"

# ===========================================================================
# G. Registration and isolation
# ===========================================================================

run_case "this suite runs unprivileged and touches no production root" "${FIXTURE}
assert os.getuid() != 0, 'this suite must not run privileged'
for grant in ('/etc/sudoers.d/kyri-exec', '/etc/sudoers.d/kyri-exec-verify'):
    assert not os.path.exists(grant), grant + ' exists'
# The live handoff root is a production path. Where it exists this proves the
# suite left it empty; where there is no production layout at all there is
# nothing it could have touched, and asserting on an absent directory would
# fail for a reason that has nothing to do with isolation.
handoff = '/data/kyri/capability-handoff'
if os.path.isdir(handoff):
    assert os.listdir(handoff) == [], 'the live handoff root changed'
print('OK')
"

run_case "the launch-bridge suite runs in local validation and in CI" "${FIXTURE}
from pathlib import Path
name = 'tests/test-capability-execution-launch-bridge.sh'
assert name in Path('tools/dev/run-validation.sh').read_text(encoding='utf-8'), \\
    'local validation omits it'
assert name in Path('.github/workflows/ci.yml').read_text(encoding='utf-8'), \\
    'ci omits it'
print('OK')
"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "$(cat "${PRODUCTION_BEFORE}")" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path changed while this suite ran"
else
  fail "a production path changed: $(cat "${PRODUCTION_BEFORE}") -> ${PRODUCTION_AFTER}"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution launch-bridge validation passed.\n'
else
  printf 'Capability execution launch-bridge validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
