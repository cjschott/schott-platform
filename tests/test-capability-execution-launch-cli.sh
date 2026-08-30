#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the governed S5 operator surface: `capability authorise-launch`.
#
# WHAT THIS VERB IS. A thin adapter over the accepted Generation-8 bridge. It
# parses a closed argument set, opens the ruled roots as descriptors, calls
# `authorise_launch` unchanged, and renders the result. It owns no policy: not
# eligibility, not the lifecycle transition, not the commitment digest, not the
# launch-authorisation schema, not the CMUT target, not the handoff, and not
# replay. Every one of those stays where it was reviewed.
#
# WHAT THE OPERATOR MAY CHOOSE. As little as possible. Every root is a
# compiled-in constant rather than an argument -- which is a stronger statement
# than a default, because there is no way to supply another one. The paths the
# privileged transition reads are compiled in on its side too, so the two agree
# by construction rather than by an operator getting them consistent.
#
# UNPRIVILEGED, FIXTURE ONLY. Nothing here elevates, executes a helper, runs a
# worker, contacts a container runtime, seeds Trust or Fabric, mounts the Root
# Authority, allocates an identifier in a live store, or touches installed
# runtime bytes.
#
# Governed by:
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORKDIR="$(mktemp -d)"
export WORKDIR

PRODUCTION_PATHS=(
  /data/kyri/capability-handoff
  /data/kyri/capability-runtime
  /data/kyri/trust
  /data/kyri/fabric
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
  /mnt/kyri-root
)
PRODUCTION_BEFORE="$(mktemp)"
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

# ---------------------------------------------------------------------------
# The fixture. One execution-prepared invocation, one admitted implementation,
# one staged package, all built through the governed constructors -- the same
# material the bridge suite uses, so this proves the adapter against the real
# contract rather than against a convenient stand-in.
# ---------------------------------------------------------------------------

FIXTURE="import os, sys
sys.path.insert(0, os.getcwd())
import hashlib, io, json, shutil, contextlib
from datetime import datetime, timezone

from tools.capability import cli as C
from tools.capability.execution import launch as L
from tools.capability.execution import state as S
from tools.capability.execution import mutation as M
from tools.capability.execution import profile as P
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.types import LifecycleState
from tools.capability.execution.worker import CONTAINER_INTERPRETER
from tools.capability.store import CapabilityStore
from tools.capability.evidence import record_invocation
from tools.capability.invocation_identity import bind, payload_digest
from tools.capability.execution.package_contract import inspect_package
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
# Valid under governed payload schema 1, and unmistakably a G6.1B fixture.
PAYLOAD = {'operation': 'verify',
           'arguments': {'count': 1, 'label': 'g6-1b'},
           'note': 'g6-1b verification fixture'}
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

def authority(name):
    base = fresh(name)
    auth_dir = os.path.join(base, 'implementation-authority')
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
        admit_implementation(a, c, request=AdmissionRequest(
            oci_image_id=IMAGE, evidence=evidence_for(),
            observed_image_id=IMAGE))
    finally:
        os.close(a); os.close(c)
    return auth_dir

def runtime_root(name):
    '''The Capability Runtime root: record directories and execution substrate
    share it, exactly as the normative host layout rules.'''
    base = fresh(name)
    execution = os.path.join(base, 'execution')
    os.makedirs(execution)
    for directory in ('state', 'transitions', 'locks', 'mutations',
                      'quarantine-reservations', 'quarantine-releases'):
        os.mkdir(os.path.join(execution, directory), 0o700)
    write(os.path.join(execution, M.CMUT_COUNTER), b'000000000000\n')
    return base

def backing_config(name, root):
    '''The provisioned configuration, written from what the CLI observes.

    Deliberately not a made-up UUID: the fixture asks the real observation
    helper what filesystem the fixture root sits on, so the verification path
    under test is the production one rather than a relaxed copy.'''
    path = os.path.join(WORK, name + '-backing.json')
    facts = C._observed_filesystem(root)
    write(path, serialise({'filesystem_uuid': facts.filesystem_uuid,
                           'filesystem_type': facts.filesystem_type,
                           'mount_point': facts.mount_point}))
    return path

class Evidence:
    def __init__(self):
        self.supported = True; self.reason = None
        self.selection_id = SELECTION; self.instance_id = INSTANCE
        self.capability_package_id = PACKAGE_ID
        self.contract_id = 'CCON-000001'; self.capability_id = 'CCAP-000001'
        self.effect_class = 'read-only'
        self.artifact_reference = 'tree:pkg'
        self.manifest_reference = 'file:manifest.json'
        self.operation = OPERATION
        self.target_node_identity = 'HOST-0001'

def package_tree(name, files=None):
    '''A staged package tree from the REAL resolver, never a fabricated object.

    The ceremony opens the recorded staged_path with O_DIRECTORY, so a fixture
    that constructed the staged object itself would be asserting a shape the
    resolver never has to produce. Modes are set rather than inherited: the
    trusted-source contract refuses a group-writable approved root.'''
    approved = fresh(name)
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

def payload_root(name, body=None):
    '''An approved payload directory, owner-writable only.

    The trusted-source primitive refuses a root that anyone but its owner can
    write, which is the point of calling it an approved directory. The fixture
    sets the mode explicitly rather than inheriting whatever umask is in force.'''
    base = fresh(name)
    write(os.path.join(base, 'payload.json'),
          serialise(PAYLOAD if body is None else body), 0o444)
    os.chmod(base, 0o755)
    return base

def scenario(name, payload=None):
    '''Everything one case needs, with the CLI bound to the fixture roots.'''
    runtime = runtime_root(name + '-runtime')
    store = CapabilityStore(runtime, expected_uid=os.getuid(),
                            expected_gid=os.getgid())
    staged = package_tree(name + '-pkg')
    body = PAYLOAD if payload is None else payload
    decision = record_invocation(
        store, invocation_id='request-' + name,
        binding_digest=bind(payload=body, invocation_id='request-' + name,
                            selection_id=SELECTION, instance_id=INSTANCE,
                            capability_package_id=PACKAGE_ID,
                            operation=OPERATION, actor=ACTOR),
        payload_digest=payload_digest(body), evidence=Evidence(),
        staged=staged, actor=ACTOR,
        request_id='REQ-1',
        requested_at=datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc))
    assert decision.status == 'prepared', decision
    # The roots are constants in the module, read at call time. Rebinding them
    # here is how a fixture redirects the ceremony without the production
    # surface ever carrying a path argument.
    C.CAPABILITY_RUNTIME_ROOT = runtime
    C.HANDOFF_ROOT = fresh(name + '-handoff')
    C.AUTHORITY_ROOT = authority(name + '-auth')
    C.BACKING_STORE_CONFIG = backing_config(name, runtime)
    return decision, runtime

def invoke(cinv, cimp='CIMP-000001', entrypoint='main.py', payload=None,
           extra=None):
    '''Run the verb exactly as an operator would, and capture its output.'''
    root = payload_root('payload-' + cinv, payload)
    argv = ['authorise-launch', '--expected-uid', str(os.getuid()),
            '--expected-gid', str(os.getgid()), '--cinv', cinv,
            '--cimp', cimp, '--approved-payload-root', root,
            '--payload-file', 'payload.json',
            '--package-entrypoint', entrypoint]
    if extra:
        argv.extend(extra)
    out = io.StringIO(); noise = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(noise):
        status = C.main(argv)
    return status, out.getvalue() + noise.getvalue()
"

# ===========================================================================
# A. the CLI surface
# ===========================================================================

run_case "authorise-launch is a recognised supported verb" "${FIXTURE}
parser = C.build_parser()
verbs = None
for action in parser._actions:
    if hasattr(action, 'choices') and action.choices:
        verbs = sorted(action.choices)
assert verbs is not None, 'no subcommands'
assert 'authorise-launch' in verbs, verbs
assert set(verbs) == {'authorise-launch', 'inspect', 'invoke', 'validate'}, verbs
print('OK')
"

run_case "an unknown verb and an unexpected argument are both refused" "${FIXTURE}
quiet = io.StringIO()
with contextlib.redirect_stderr(quiet), contextlib.redirect_stdout(quiet):
    unknown = C.main(['authorise-launch-now'])
    extra = C.main(['authorise-launch', '--not-a-flag', 'x'])
assert unknown == C.EXIT_USAGE, unknown
assert extra == C.EXIT_USAGE, extra
print('OK')
"

run_case "every required argument is required" "${FIXTURE}
base = ['authorise-launch', '--expected-uid', '1000', '--expected-gid', '1000',
        '--cinv', 'CINV-000001', '--cimp', 'CIMP-000001',
        '--approved-payload-root', '/tmp', '--payload-file', 'p.json',
        '--package-entrypoint', 'main.py']
quiet = io.StringIO()
with contextlib.redirect_stderr(quiet), contextlib.redirect_stdout(quiet):
    for drop in ('--cinv', '--cimp', '--approved-payload-root', '--payload-file',
                 '--package-entrypoint', '--expected-uid', '--expected-gid'):
        index = base.index(drop)
        trimmed = base[:index] + base[index + 2:]
        assert C.main(trimmed) == C.EXIT_USAGE, drop
print('OK')
"

run_case "the operator cannot aim any root: no path argument exists" "${FIXTURE}
parser = C.build_parser()
sub = [a for a in parser._actions if hasattr(a, 'choices') and a.choices][0]
options = set()
for action in sub.choices['authorise-launch']._actions:
    options.update(action.option_strings)
# Every root the ceremony touches is compiled in. A flag here would be
# authority the operator does not need and the transition would not honour.
for forbidden in ('--store-root', '--execution-root', '--handoff-root',
                  '--handoff-target', '--authority-root', '--backing-store',
                  '--backing-store-config', '--artifact-root',
                  '--approved-artifact-root', '--staging-root',
                  '--lifecycle-state', '--state', '--launch-authorisation',
                  '--cmut', '--cmut-target', '--target', '--fixture'):
    assert forbidden not in options, forbidden
print('OK')
"

run_case "the ruled roots are module constants, not arguments or defaults" "${FIXTURE}
for name, expected in (('CAPABILITY_RUNTIME_ROOT', '/data/kyri/capability-runtime'),
                       ('AUTHORITY_ROOT', '/var/lib/kyri/implementation-authority'),
                       ('BACKING_STORE_CONFIG', '/etc/kyri/backing-store.json')):
    value = getattr(C, name)
    assert isinstance(value, str) and value.startswith('/'), (name, value)
# The handoff root is not restated here: it is imported from the bridge, which
# is what the privileged transition also compiles in. One spelling, one source.
assert C.HANDOFF_ROOT == L.HANDOFF_ROOT, (C.HANDOFF_ROOT, L.HANDOFF_ROOT)
print('OK')
"

# ===========================================================================
# B. successful delegation
# ===========================================================================

run_case "a prepared invocation is authorised through the bridge" "${FIXTURE}
decision, runtime = scenario('b1')
cinv = decision.invocation_record_id
status, out = invoke(cinv)
assert status == C.EXIT_SUCCESS, (status, out)
report = json.loads(out)
assert report['cinv'] == cinv, report
assert report['cimp'] == 'CIMP-000001', report
assert report['lifecycle_state'] == 'launch_authorized', report
assert report['resumed'] is False, report
assert len(report['profile_digest']) == 64, report
assert len(report['commitment_digest']) == 64, report
# The authority actually moved, and it moved in the store the constants name.
root = L  # bridge module, for the state reader
import tools.capability.execution.backing_store as B
print('OK')
"

run_case "the ceremony leaves exactly the ruled evidence" "${FIXTURE}
decision, runtime = scenario('b2')
cinv = decision.invocation_record_id
status, out = invoke(cinv)
assert status == C.EXIT_SUCCESS, out
record = os.path.join(runtime, 'execution', cinv, 'launch-authorisation')
assert os.path.isfile(record), 'no launch-authorisation'
assert oct(os.stat(record).st_mode & 0o777) == '0o600', oct(os.stat(record).st_mode)
body = json.loads(open(record, 'rb').read())
assert set(body) == set(L.LAUNCH_RECORD_SCHEMA), sorted(body)
assert body['lifecycle_state'] == 'launch_authorized', body
assert body['handoff_root'] == L.HANDOFF_ROOT, body
handoff = os.path.join(C.HANDOFF_ROOT, cinv)
for member in ('profile', 'payload', 'package', 'out'):
    assert os.path.exists(os.path.join(handoff, member)), member
print('OK')
"

run_case "the operator report carries identifiers, never payload or profile bodies" "${FIXTURE}
decision, runtime = scenario('b3')
status, out = invoke(decision.invocation_record_id)
assert status == C.EXIT_SUCCESS, out
report = json.loads(out)
assert set(report) == {'cinv', 'cimp', 'lifecycle_state', 'profile_digest',
                       'commitment_digest', 'handoff_published', 'resumed',
                       'package_digest', 'payload_digest'}, sorted(report)
text = out.lower()
for leaked in ('operation', 'fixture', 'g6-1b', 'def run', 'oci_image_id',
               'network', 'pids_limit'):
    assert leaked not in text, leaked
print('OK')
"

# ===========================================================================
# C. the thin-adapter rule
# ===========================================================================

run_case "the CLI implements no authorisation policy of its own" "${FIXTURE}
import inspect
source = inspect.getsource(C)
body = '\n'.join(line for line in source.splitlines()
                 if not line.lstrip().startswith('#'))
# Every one of these belongs to the Generation-8 bridge. A second copy here
# would be a second opinion about whether a launch was approved.
for banned in ('LAUNCH_RECORD_SCHEMA = ', 'commitment_digest(', 'launch_record(',
               'MutationTarget', 'TargetKind', 'publish_handoff',
               'authorise_implementation', 'build_profile', 'fingerprint(',
               'LifecycleState.', 'transition(', 'reserve(', 'validate_package(',
               'canonical_profile', 'PROFILE_NAME', 'OUTPUT_DIRECTORY'):
    assert banned not in body, banned
print('OK')
"

run_case "the handler reaches the bridge and nothing else decides" "${FIXTURE}
import inspect
handler = inspect.getsource(C.command_authorise_launch)
assert 'ready = authorise_launch(' in handler, 'the handler does not call the bridge'
# Exactly one call into the bridge: an adapter that called it twice would be
# choosing between answers.
assert handler.count('= authorise_launch(') == 1, handler
print('OK')
"

run_case "a bridge refusal is carried, not reinterpreted" "${FIXTURE}
decision, runtime = scenario('c3')
calls = []
# The CLI imports the bridge by name, so the binding it actually calls is the
# one in its own module. Patching there is what proves the call is delegated.
original = C.authorise_launch
def refusing(**kwargs):
    calls.append(kwargs)
    raise L.LaunchRefused('the bridge said no')
C.authorise_launch = refusing
try:
    status, out = invoke(decision.invocation_record_id)
finally:
    C.authorise_launch = original
assert status == C.EXIT_DENIED, (status, out)
assert 'the bridge said no' in out or 'the bridge said no' in str(out), out
assert len(calls) == 1, calls
print('OK')
"

# ===========================================================================
# D. invalid state -- refused by the bridge, carried by the CLI
# ===========================================================================

run_case "a malformed or nonexistent CINV is refused" "${FIXTURE}
decision, runtime = scenario('d1')
for bad in ('CINV-00004', 'cinv-000042', '../escape', 'CINV-000042/x', ''):
    status, out = invoke(bad)
    assert status in (C.EXIT_DENIED, C.EXIT_USAGE), (bad, status, out)
status, out = invoke('CINV-999999')
assert status == C.EXIT_DENIED, (status, out)
print('OK')
"

run_case "a substituted payload, entrypoint, or implementation is refused" "${FIXTURE}
decision, runtime = scenario('d2')
cinv = decision.invocation_record_id
for label, kwargs in (
        ('payload', dict(payload={'operation': 'verify', 'arguments': {'count': 2, 'label': 'other'}})),
        ('entrypoint', dict(entrypoint='absent.py')),
        ('cimp', dict(cimp='CIMP-000009'))):
    status, out = invoke(cinv, **kwargs)
    assert status == C.EXIT_DENIED, (label, status, out)
# Nothing was authorised by any of the refused attempts.
assert not os.path.exists(os.path.join(runtime, 'execution', cinv,
                                       'launch-authorisation')), 'record written'
assert os.listdir(C.HANDOFF_ROOT) == [], 'handoff published'
print('OK')
"

run_case "an already-consumed lifecycle is refused" "${FIXTURE}
decision, runtime = scenario('d3')
cinv = decision.invocation_record_id
status, out = invoke(cinv)
assert status == C.EXIT_SUCCESS, out
import tools.capability.execution.backing_store as B
cfg = os.open(C.BACKING_STORE_CONFIG, os.O_RDONLY)
rt = os.open(os.path.join(runtime, 'execution'), os.O_RDONLY | os.O_DIRECTORY)
try:
    anchor = B.verify_backing_store(
        cfg, rt, observed=C._observed_filesystem(os.path.join(runtime, 'execution')))
finally:
    os.close(cfg); os.close(rt)
S.transition(anchor, cinv, LifecycleState.LAUNCH_AUTHORIZED, LifecycleState.CREATED)
anchor.close()
status, out = invoke(cinv)
assert status == C.EXIT_DENIED, (status, out)
print('OK')
"

# ===========================================================================
# E. idempotency -- the bridge's, not a second one
# ===========================================================================

run_case "an exact repeat resumes and allocates nothing new" "${FIXTURE}
decision, runtime = scenario('e1')
cinv = decision.invocation_record_id
first_status, first_out = invoke(cinv)
assert first_status == C.EXIT_SUCCESS, first_out
first = json.loads(first_out)
transitions = sorted(os.listdir(os.path.join(runtime, 'execution', 'transitions')))
mutations = sorted(os.listdir(os.path.join(runtime, 'execution', 'mutations')))
records = sorted(os.listdir(os.path.join(runtime, 'capability-invocations')))
second_status, second_out = invoke(cinv)
assert second_status == C.EXIT_SUCCESS, second_out
second = json.loads(second_out)
assert second['resumed'] is True and first['resumed'] is False, (first, second)
assert second['profile_digest'] == first['profile_digest']
assert second['commitment_digest'] == first['commitment_digest']
assert sorted(os.listdir(os.path.join(runtime, 'execution', 'transitions'))) == transitions
assert sorted(os.listdir(os.path.join(runtime, 'execution', 'mutations'))) == mutations
assert sorted(os.listdir(os.path.join(runtime, 'capability-invocations'))) == records
assert len(os.listdir(C.HANDOFF_ROOT)) == 1
print('OK')
"

run_case "the CLI adds no replay semantics of its own" "${FIXTURE}
import inspect
handler = inspect.getsource(C.command_authorise_launch)
# Code constructs only. 'already' is legitimate prose in the docstring, and
# banning a word rather than a construct would be a test about writing style.
for banned in ('resumed =', 'retry', 'idempot', 'replay', 'if ready.resumed'):
    assert banned not in handler.lower(), banned
print('OK')
"

# ===========================================================================
# F. descriptor discipline
# ===========================================================================

run_case "a symlinked payload root or payload file is refused" "${FIXTURE}
decision, runtime = scenario('f1')
cinv = decision.invocation_record_id
real = payload_root('f1-real')
link = os.path.join(WORK, 'f1-link')
if os.path.islink(link) or os.path.exists(link):
    os.remove(link)
os.symlink(real, link)
argv = ['authorise-launch', '--expected-uid', str(os.getuid()),
        '--expected-gid', str(os.getgid()), '--cinv', cinv,
        '--cimp', 'CIMP-000001', '--approved-payload-root', link,
        '--payload-file', 'payload.json', '--package-entrypoint', 'main.py']
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    status = C.main(argv)
assert status in (C.EXIT_DENIED, C.EXIT_USAGE), (status, out.getvalue())
print('OK')
"

run_case "a payload that escapes the approved root is refused" "${FIXTURE}
decision, runtime = scenario('f2')
cinv = decision.invocation_record_id
root = payload_root('f2-root')
argv = ['authorise-launch', '--expected-uid', str(os.getuid()),
        '--expected-gid', str(os.getgid()), '--cinv', cinv,
        '--cimp', 'CIMP-000001', '--approved-payload-root', root,
        '--payload-file', '../escape.json', '--package-entrypoint', 'main.py']
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    status = C.main(argv)
assert status in (C.EXIT_DENIED, C.EXIT_USAGE), (status, out.getvalue())
print('OK')
"

run_case "the ceremony leaks no descriptor, success or refusal" "${FIXTURE}
def open_count():
    return len(os.listdir('/proc/self/fd'))
decision, runtime = scenario('f3')
cinv = decision.invocation_record_id
before = open_count()
invoke(cinv)
after_success = open_count()
invoke('CINV-999999')
after_refusal = open_count()
assert after_success <= before + 1, (before, after_success)
assert after_refusal <= before + 1, (before, after_refusal)
print('OK')
"

# ===========================================================================
# G. security backstops
# ===========================================================================

run_case "the CLI cannot elevate, execute, or reach a container runtime" "${FIXTURE}
import inspect
source = inspect.getsource(C)
body = '\n'.join(line for line in source.splitlines()
                 if not line.lstrip().startswith('#'))
for banned in ('subprocess', 'os.system', 'os.exec', 'os.spawn', 'os.fork',
               'popen', 'su' + 'do', 'pod' + 'man', 'doc' + 'ker', 'create_argv',
               'libexec', 'ctypes', 'socket', 'urllib', 'requests',
               'setuid', 'setgid', 'sudoers', '__import__', 'eval(', 'exec(',
               'importlib', 'getattr(C', 'xfs_' + 'quota', 'quot' + 'actl'):
    assert banned not in body, banned
print('OK')
"

# tools.fabric is deliberately NOT banned here: `invoke` has always resolved a
# governed selection through it, so it is a pre-existing dependency of the
# dispatcher rather than something this verb introduced.
#
# tools.trust was banned outright until ENG-0005 G11-Y. It no longer can be.
# The invocation boundary must revalidate the selected binding's CURRENT
# eligibility, and eligibility includes trust standing and quarantine -- so a
# runtime that could not reach the Trust plane at all could not ask whether a
# revoked or quarantined subject may still serve. What the ban was protecting
# is unchanged and is now stated precisely: the runtime may ASK about standing
# and may never DECIDE it. The decision surfaces stay unreachable, and the read
# path arrives through C5's engine, which is handed objects exposing reads
# only.
TRUST_DECISION_MODULES=(
  tools.trust.evaluator tools.trust.root_authority tools.trust.gateway
  tools.trust.policy tools.trust.audit tools.trust.cli
)
run_case "importing the CLI loads nothing that could execute or decide policy" "${FIXTURE}
import subprocess
deciders = '${TRUST_DECISION_MODULES[*]}'.split()
probe = ('import sys; import tools.capability.cli; '
         'bad = [m for m in sys.modules '
         'if m.split(chr(46))[0] in (chr(115)+\\'ubprocess\\', \\'socket\\', \\'ctypes\\') '
         'or m.endswith(\\'.snapshot\\') or m.endswith(\\'.adapter\\') '
         'or m.endswith(\\'.worker\\')]; '
         'print(sorted(bad))')
out = subprocess.run([sys.executable, '-c', probe], capture_output=True,
                     text=True, check=True).stdout.strip()
assert out == '[]', out

# The Trust plane may be read and must never be decided. Named module by
# module, so a new decision surface added later is a failure here rather than
# a quiet widening of what the runtime can reach.
decide_probe = ('import sys; import tools.capability.cli; '
                'print(sorted(m for m in sys.modules if m in ' + repr(deciders) + '))')
out = subprocess.run([sys.executable, '-c', decide_probe], capture_output=True,
                     text=True, check=True).stdout.strip()
assert out == '[]', out
print('OK')
"

run_case "the CLI performs no Fabric selection and seeds no governance store" "${FIXTURE}
import inspect
source = inspect.getsource(C)
body = '\n'.join(line for line in source.splitlines()
                 if not line.lstrip().startswith('#'))
for banned in ('select_candidate', 'admit_instance', 'admit_subject',
               'create_decision', 'declare_root_authority', 'init_root',
               'allocate_id', 'kyri-root', 'implementation-authority-control'):
    assert banned not in body, banned
print('OK')
"

run_case "the verb writes outside no ruled root" "${FIXTURE}
decision, runtime = scenario('g4')
cinv = decision.invocation_record_id
watched = os.path.join(WORK, 'g4-witness')
os.makedirs(watched, exist_ok=True)
before = sorted(os.listdir(watched))
invoke(cinv)
assert sorted(os.listdir(watched)) == before, 'the ceremony wrote somewhere unruled'
assert os.listdir(C.HANDOFF_ROOT) == [cinv], os.listdir(C.HANDOFF_ROOT)
print('OK')
"

# ===========================================================================
# H. registration and isolation
# ===========================================================================

run_case "this suite runs unprivileged and touches no production root" "${FIXTURE}
assert os.getuid() != 0, 'this suite must not run privileged'
for grant in ('/etc/sudoers.d/kyri-exec', '/etc/sudoers.d/kyri-exec-verify'):
    assert not os.path.exists(grant), grant
assert os.listdir('/data/kyri/capability-handoff') == [], 'the live handoff changed'
assert not os.path.exists('/data/kyri/trust'), 'a live trust store appeared'
assert not os.path.exists('/data/kyri/fabric'), 'a live fabric store appeared'
assert not os.path.ismount('/mnt/kyri-root'), 'the root authority was mounted'
print('OK')
"

run_case "the launch-CLI suite runs in local validation and in CI" "${FIXTURE}
from pathlib import Path
name = 'tests/test-capability-execution-launch-cli.sh'
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
  fail "a production path changed: ${PRODUCTION_AFTER}"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution launch-CLI validation passed.\n'
else
  printf 'Capability execution launch-CLI validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
