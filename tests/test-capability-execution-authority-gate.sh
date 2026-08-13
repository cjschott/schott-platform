#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, Pass 4A.
#
# 4A implements conditions 3-7 of the create_argv gate invariant recorded in
# design §14.2.5. The invariant, verbatim from the committed ruling:
#
#   create_argv MUST NOT be reachable unless, for the profile parsed from
#   sealed FD 3:
#     1. fingerprint(profile).profile_digest == the argv profile digest, and
#     2. profile.cinv == the argv CINV, and profile.cimp == the argv CIMP, and
#     3. every compiled-in field equals this build's constant in profile.py,
#     4. oci_image_id is 64 lowercase hex and is present in the execution
#        identity's rootless store, and
#     5. adapter_identity and payload_schema_version equal this build's
#        contract identities, and
#     6. the published package tree and payload verify against commitments
#        that crossed the privilege boundary under §14.1 protection, and
#     7. the governed entrypoint likewise crossed under that protection.
#
# IDENTITY IS NOT POLICY. Generation 5 proves the worker parses exactly the
# bytes the coordinator committed to. It cannot prove those values were the
# governed ones, because the same party authored the digest. Everything here
# is about the second question.
#
# NOTHING EXECUTES. No Podman, no container, no image, no privilege, no
# transition, no worker process. The image store is an injected seam and the
# only thing built is an argv tuple. G6 stays closed.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §14.2-§14.4
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

PRODUCTION_PATHS=(
  /data/kyri/capability-handoff
  /usr/lib/kyri/python
  /usr/libexec/kyri-exec-worker.py
  /etc/sudoers.d/kyri-exec
  /var/lib/kyri/implementation-authority
)
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
    except OSError:
        state[path] = "unreadable"
        continue
    state[path] = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
print(json.dumps(state, sort_keys=True))
' "$@"
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

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
import dataclasses, hashlib, os, shutil, stat, sys

from tools.capability.execution import worker as W
from tools.capability.execution import profile as P
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.package_contract import validate_package
from tools.capability.execution.payload import validate_payload
from tools.capability.execution.handoff import publish_handoff, PROFILE_NAME
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
IMAGE = 'a' * 64
PAYLOAD_BYTES = b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}'
PACKAGE_FILES = {
    'main.py': b'def run():\n    return {}\n',
    'helper.py': b'VALUE = 1\n',
    'data/table.json': b'{\"a\":1}',
}

def admission(cimp='CIMP-000001', image=None, **overrides):
    fields = dict(
        cimp=cimp, oci_image_id=image if image else IMAGE,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)
    fields.update(overrides)
    return Admission(**fields)

def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)
    os.chmod(path, mode)

def make_package(name, files=None):
    base = os.path.join(WORK, name + '-pkg')
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    for relative, body in (PACKAGE_FILES if files is None else files).items():
        write(os.path.join(base, relative), body)
    return base

def bindings(name, files=None, payload=None, entrypoint='main.py'):
    '''The three governed commitments, derived the way the coordinator does.'''
    base = make_package(name, files)
    handle = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        package = validate_package(handle, entrypoint=entrypoint)
    finally:
        os.close(handle)
    path = os.path.join(WORK, name + '-payload.json')
    write(path, PAYLOAD_BYTES if payload is None else payload)
    fd = os.open(path, os.O_RDONLY)
    try:
        payload_binding = validate_payload(fd, schema_version=1)
    finally:
        os.close(fd)
    return base, package, payload_binding

def governed(name='g', cinv='CINV-000042', cimp='CIMP-000001', image=None,
             files=None, payload=None, entrypoint='main.py', **overrides):
    '''A governed schema-2 profile carrying the invocation commitments.'''
    base, package, payload_binding = bindings(name, files, payload, entrypoint)
    binding = P.ProfileBinding(
        cinv=cinv, admission=admission(cimp, image),
        payload_digest=payload_binding.digest,
        package_digest=package.digest,
        package_entrypoint=package.entrypoint)
    return P.build_profile(binding), base, package, payload_binding

def published(name='h', cinv='CINV-000042', **kwargs):
    '''A real staged handoff, published through the accepted publisher.'''
    profile, base, package, payload_binding = governed(name, cinv=cinv, **kwargs)
    root_base = os.path.join(WORK, name + '-hand')
    if os.path.isdir(root_base):
        shutil.rmtree(root_base)
    os.makedirs(os.path.join(root_base, 'root'))
    with open(os.path.join(root_base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    cfg = os.open(os.path.join(root_base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(root_base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    try:
        anchor = verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)
    artefact = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        publish_handoff(anchor, cinv, artefact, payload_binding, package,
                        profile=profile)
    finally:
        os.close(artefact)
    return profile, os.path.join(root_base, 'root'), package, payload_binding

class Images:
    '''The injected image-presence seam. Contains no Podman and no authority.'''

    def __init__(self, present=(IMAGE,), error=None):
        self.asked = []
        self._present = tuple(present)
        self._error = error

    def present(self, oci_image_id):
        self.asked.append(oci_image_id)
        if self._error is not None:
            raise self._error
        return oci_image_id in self._present

def context(profile, cinv=None, cimp=None, digest=None):
    return W.require_launch_context(
        cinv=cinv or profile.cinv, cimp=cimp or profile.cimp,
        profile_digest=digest or P.fingerprint(profile).profile_digest)

def verify(profile, handoff_root, images=None, ctx=None):
    root_fd = os.open(handoff_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return W.verify_execution(
            ctx if ctx is not None else context(profile), profile,
            root_fd=root_fd, images=Images() if images is None else images)
    finally:
        os.close(root_fd)

def refused(profile, handoff_root, images=None, ctx=None):
    '''The refusal, or an assertion failure if the gate let it through.'''
    try:
        verify(profile, handoff_root, images, ctx)
    except W.WorkerRefused as error:
        return error
    raise AssertionError('the gate accepted material it must refuse')

def substituted(profile, **changes):
    '''A profile with governed values replaced, exactly as a hostile
    coordinator would author it: canonical, self-consistent, and wrong.'''
    return dataclasses.replace(profile, **changes)
"

# ===========================================================================
# The gate
# ===========================================================================

run_case "the whole verified chain accepts a governed invocation" "${PRELUDE}
profile, handoff, package, payload = published('happy')
verified = verify(profile, handoff)
assert isinstance(verified, W.VerifiedExecution)
assert verified.profile is profile
assert verified.entrypoint == 'main.py'
argv = W.create_argv(verified)
assert argv[0] == W.PODMAN and argv[1] == 'create'
assert argv[-1] == '/kyri/package/main.py'
assert profile.oci_image_id in argv
print('OK')
"

run_case "create_argv is reachable only through the verified gate" "${PRELUDE}
import inspect
params = list(inspect.signature(W.create_argv).parameters)
assert params == ['verified'], params
profile, handoff, package, payload = published('gateonly')
# Raw profile data, verified handoff sources, and a package binding are each
# refused: the gate result is the only admissible input.
for bad in (profile, None, 'CINV-000042', (profile, package), package,
            dataclasses.asdict(dataclasses.replace(profile))):
    try:
        W.create_argv(bad)
    except W.WorkerRefused:
        continue
    raise AssertionError('create_argv accepted unverified input')
# And the verified type cannot be built by hand.
try:
    W.VerifiedExecution(profile=profile,
                        sources=W.HandoffSources(cinv=profile.cinv, package='/x',
                                                 payload='/y', output='/z'),
                        entrypoint='main.py')
except Exception:
    print('OK')
else:
    raise AssertionError('a verified execution was constructed directly')
"

run_case "condition 1: a profile the digest disowns never reaches the gate" "${PRELUDE}
profile, handoff, package, payload = published('cond1')
outcome = refused(profile, handoff, ctx=context(profile, digest='c' * 64))
assert 'digest' in str(outcome).lower(), outcome
print('OK')
"

run_case "condition 2: CINV and CIMP must equal the authenticated argv" "${PRELUDE}
profile, handoff, package, payload = published('cond2')
assert refused(profile, handoff, ctx=context(profile, cinv='CINV-000043'))
assert refused(profile, handoff, ctx=context(profile, cimp='CIMP-000002'))
print('OK')
"

# ===========================================================================
# Condition 3 -- compiled-in policy, re-derived
# ===========================================================================

run_case "condition 3: every governed control is re-derived from this build" "${PRELUDE}
profile, handoff, package, payload = published('cond3')
# The exhaustive attack set: every field a hostile coordinator could weaken.
attacks = {
    'network': 'host',
    'memory_bytes': 8 * 1024 * 1024 * 1024,
    'memory_swap_bytes': 8 * 1024 * 1024 * 1024,
    'cpus': '8.0',
    'cpu_quota_us': 1000000,
    'cpu_period_us': 10000,
    'pids_limit': 4096,
    'timeout_seconds': 86400,
    'grace_seconds': 3600,
    'read_only_rootfs': False,
    'no_new_privileges': False,
    'cap_drop_all': False,
    'dropped_capabilities': (),
    'execution_uid': 0,
    'execution_gid': 0,
    'hostname': 'evil',
    'tmpfs_bytes': 1 << 30,
    'tmpfs_mode': 0o777,
    'tmpfs_options': ('exec', 'suid', 'dev'),
    'devices': ('/dev/kmsg',),
    'sockets': ('/run/docker.sock',),
    'privileged': True,
    'host_network': True,
    'host_pid': True,
    'gpu': True,
}
for field, value in sorted(attacks.items()):
    hostile = substituted(profile, **{field: value})
    try:
        P.verify_governed_policy(hostile)
    except P.ProfilePolicyViolation as error:
        assert field in str(error), (field, str(error))
    else:
        raise AssertionError('policy accepted a substituted ' + field)
    # And the whole gate refuses it, not merely the policy check in isolation.
    outcome = refused(hostile, handoff,
                      ctx=context(hostile, digest=P.fingerprint(hostile).profile_digest))
    assert isinstance(outcome, W.WorkerRefused), field
print('OK')
"

run_case "condition 3: a substituted mount topology is refused" "${PRELUDE}
from tools.capability.execution.types import Mount
profile, handoff, package, payload = published('mounts')
for hostile_mounts in (
        (),
        profile.mounts + (Mount(destination='/etc', read_only=False,
                                source_kind='bind'),),
        tuple(dataclasses.replace(m, read_only=False) for m in profile.mounts),
        tuple(dataclasses.replace(m, source_kind='volume') for m in profile.mounts),
        (dataclasses.replace(profile.mounts[0], destination='/host'),)
        + profile.mounts[1:]):
    hostile = substituted(profile, mounts=hostile_mounts)
    try:
        P.verify_governed_policy(hostile)
    except P.ProfilePolicyViolation:
        continue
    raise AssertionError('policy accepted a substituted mount topology')
print('OK')
"

run_case "condition 3: the policy check repairs nothing and normalises nothing" "${PRELUDE}
import inspect
profile, handoff, package, payload = published('norepair')
hostile = substituted(profile, network='host', pids_limit=4096)
try:
    P.verify_governed_policy(hostile)
except P.ProfilePolicyViolation:
    pass
# The hostile object is untouched: no field was corrected on the way through.
assert hostile.network == 'host' and hostile.pids_limit == 4096
source = inspect.getsource(P.verify_governed_policy)
# It may compare and collect; it may not assign, replace, or substitute.
for banned in ('replace(', 'setattr', 'object.__setattr__', 'or NETWORK',
               'profile.network =', 'actual = expected'):
    assert banned not in source, banned
assert 'raise ProfilePolicyViolation' in source
print('OK')
"

run_case "condition 3: the governed policy covers every field the profile carries" "${PRELUDE}
from tools.capability.execution.types import ExecutionProfile
covered = set(P.governed_policy())
carried = {f.name for f in dataclasses.fields(ExecutionProfile)}
# Identity and invocation commitments are not compiled-in policy; everything
# else must be governed, so a field added later cannot quietly escape.
exempt = {'cinv', 'cimp', 'oci_image_id', 'adapter_identity',
          'payload_schema_version', 'profile_schema_version',
          'payload_digest', 'package_digest', 'package_entrypoint'}
missing = carried - covered - exempt
assert not missing, 'ungoverned profile fields: ' + repr(sorted(missing))
assert not (covered & exempt), 'policy claims an identity field'
print('OK')
"

# ===========================================================================
# Condition 4 -- image presence, never image authority
# ===========================================================================

run_case "condition 4: the authorised image must be present in the store" "${PRELUDE}
profile, handoff, package, payload = published('img')
images = Images(present=(profile.oci_image_id,))
verified = verify(profile, handoff, images=images)
assert images.asked == [profile.oci_image_id], images.asked
# Absent, wrong-only, and empty stores all refuse.
for store in (Images(present=()), Images(present=('b' * 64,)),
              Images(present=('b' * 64, 'c' * 64, 'd' * 64))):
    outcome = refused(profile, handoff, images=store)
    assert 'image' in str(outcome).lower(), outcome
# Unrelated images alongside the authorised one are irrelevant.
verify(profile, handoff, images=Images(present=('b' * 64, profile.oci_image_id, 'c' * 64)))
print('OK')
"

run_case "condition 4: presence is asked as an exact bare hex id and nothing else" "${PRELUDE}
import inspect
profile, handoff, package, payload = published('imgexact')
images = Images(present=(profile.oci_image_id,))
verify(profile, handoff, images=images)
asked = images.asked[0]
assert len(asked) == 64 and asked == asked.lower()
assert ':' not in asked and '/' not in asked and 'sha256' not in asked
# A tag or a manifest digest in the store is not the authorised image.
for irrelevant in ('docker.io/library/alpine:latest', 'sha256:' + 'a' * 64,
                   profile.oci_image_id.upper()):
    outcome = refused(profile, handoff, images=Images(present=(irrelevant,)))
    assert isinstance(outcome, W.WorkerRefused), irrelevant
# The seam cannot select, enumerate, pull, or resolve.
source = inspect.getsource(W.require_image_present)
for banned in ('latest', 'RepoTag', 'RepoDigest', 'ImageDigest', 'pull(',
               'docker.io', 'resolve', 'list(', 'for '):
    assert banned not in source, banned
assert 'images.present(identity)' in source
print('OK')
"

run_case "condition 4: a store that cannot answer refuses rather than assumes" "${PRELUDE}
profile, handoff, package, payload = published('imgerr')
outcome = refused(profile, handoff, images=Images(error=OSError(2, 'no store')))
assert isinstance(outcome, W.WorkerRefused), outcome
for bad in (None, 'yes', 1, object()):
    class Odd:
        def present(self, image):
            return bad
    outcome = refused(profile, handoff, images=Odd())
    assert isinstance(outcome, W.WorkerRefused), bad
print('OK')
"

# ===========================================================================
# Condition 5 -- runtime contract equality
# ===========================================================================

run_case "condition 5: adapter identity and schema versions must be this build's" "${PRELUDE}
profile, handoff, package, payload = published('contract')
for field, value in (('adapter_identity', 'python-podman-v2'),
                     ('adapter_identity', 'other-adapter'),
                     ('adapter_identity', ''),
                     ('payload_schema_version', 2),
                     ('payload_schema_version', 0),
                     ('profile_schema_version', 1),
                     ('profile_schema_version', 3)):
    hostile = substituted(profile, **{field: value})
    outcome = refused(hostile, handoff,
                      ctx=context(hostile, digest=P.fingerprint(hostile).profile_digest))
    assert isinstance(outcome, W.WorkerRefused), (field, value)
print('OK')
"

run_case "condition 5: readable history is not executable authority" "${PRELUDE}
# A structurally valid schema-1 profile remains parseable where the canonical
# reader is asked to read one, and is refused for execution. Historical
# readability must never become an execution bypass.
profile, handoff, package, payload = published('v1')
legacy = substituted(profile, profile_schema_version=1)
outcome = refused(legacy, handoff,
                  ctx=context(legacy, digest=P.fingerprint(legacy).profile_digest))
assert 'schema' in str(outcome).lower(), outcome
assert P.PROFILE_SCHEMA_VERSION == 2, P.PROFILE_SCHEMA_VERSION
print('OK')
"

# ===========================================================================
# Conditions 6 and 7 -- payload and package commitments
# ===========================================================================

run_case "condition 6: the published payload must match the committed digest" "${PRELUDE}
profile, handoff, package, payload = published('payload')
assert profile.payload_digest == payload.digest
target = os.path.join(handoff, profile.cinv, 'payload')
invocation = os.path.join(handoff, profile.cinv)
os.chmod(invocation, 0o755)
os.chmod(target, 0o644)
with open(target, 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":9}}')
os.chmod(target, 0o444)
os.chmod(invocation, 0o555)
outcome = refused(profile, handoff)
assert 'payload' in str(outcome).lower(), outcome
print('OK')
"

run_case "condition 6: a replaced, added, or removed package member is refused" "${PRELUDE}
profile, handoff, package, payload = published('pkg')
assert profile.package_digest == package.digest
base = os.path.join(handoff, profile.cinv, 'package')
invocation = os.path.join(handoff, profile.cinv)

def unlock():
    os.chmod(invocation, 0o755); os.chmod(base, 0o755)

def relock():
    os.chmod(base, 0o555); os.chmod(invocation, 0o555)

# modified member
unlock(); os.chmod(os.path.join(base, 'helper.py'), 0o644)
with open(os.path.join(base, 'helper.py'), 'wb') as handle:
    handle.write(b'VALUE = 2\n')
os.chmod(os.path.join(base, 'helper.py'), 0o444); relock()
assert refused(profile, handoff)

profile, handoff, package, payload = published('pkgadd')
base = os.path.join(handoff, profile.cinv, 'package')
invocation = os.path.join(handoff, profile.cinv)
unlock()
with open(os.path.join(base, 'extra.py'), 'wb') as handle:
    handle.write(b'SNEAK = 1\n')
os.chmod(os.path.join(base, 'extra.py'), 0o444); relock()
assert refused(profile, handoff)

profile, handoff, package, payload = published('pkgdel')
base = os.path.join(handoff, profile.cinv, 'package')
invocation = os.path.join(handoff, profile.cinv)
unlock(); os.unlink(os.path.join(base, 'helper.py')); relock()
assert refused(profile, handoff)
print('OK')
"

run_case "condition 7: the entrypoint is the governed one and must be a member" "${PRELUDE}
profile, handoff, package, payload = published('entry')
assert profile.package_entrypoint == 'main.py'
verified = verify(profile, handoff)
assert verified.entrypoint == 'main.py'
assert W.create_argv(verified)[-1] == '/kyri/package/main.py'
# A substituted entrypoint is refused: it is committed like every other value.
# 'helper.py' is deliberately absent from this list: which validated member
# runs is the coordinator's own invocation authority, and it is committed like
# every other value. What must be refused is anything that is not a validated
# member of the committed tree.
for hostile_entry in ('../escape.py', '/etc/passwd', 'absent.py',
                      'data/table.json', '', 'main.py/x', 'package/main.py'):
    hostile = substituted(profile, package_entrypoint=hostile_entry)
    outcome = refused(hostile, handoff,
                      ctx=context(hostile, digest=P.fingerprint(hostile).profile_digest))
    assert isinstance(outcome, W.WorkerRefused), hostile_entry
print('OK')
"

run_case "conditions 6-7: cross-CINV material is refused" "${PRELUDE}
# Two invocations, each with genuinely different payload and package bytes.
one, root_one, pkg_one, pay_one = published(
    'x1', cinv='CINV-000042',
    payload=b'{\"operation\":\"sum\",\"arguments\":{\"count\":1}}',
    files={'main.py': b'A = 1\n'})
two, root_two, pkg_two, pay_two = published(
    'x2', cinv='CINV-000043',
    payload=b'{\"operation\":\"sum\",\"arguments\":{\"count\":2}}',
    files={'main.py': b'B = 2\n'})
assert one.payload_digest != two.payload_digest
assert one.package_digest != two.package_digest
# CINV-000042's profile against CINV-000043's published material.
outcome = refused(one, root_two)
assert isinstance(outcome, W.WorkerRefused), outcome
# And physically swapping the bytes under the right pathname is caught too.
target = os.path.join(root_one, one.cinv, 'payload')
invocation = os.path.join(root_one, one.cinv)
os.chmod(invocation, 0o755); os.chmod(target, 0o644)
with open(target, 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":2}}')
os.chmod(target, 0o444); os.chmod(invocation, 0o555)
assert refused(one, root_one)
print('OK')
"

# ===========================================================================
# Special files -- the generation-5 FIFO lesson, applied unprivileged
# ===========================================================================

run_case "a FIFO, socket, symlink, or directory in place of payload is refused" "${PRELUDE}
import socket as socket_module
for kind in ('fifo', 'symlink', 'directory', 'socket'):
    profile, handoff, package, payload = published('special-' + kind)
    invocation = os.path.join(handoff, profile.cinv)
    target = os.path.join(invocation, 'payload')
    os.chmod(invocation, 0o755)
    os.unlink(target)
    if kind == 'fifo':
        os.mkfifo(target, 0o444)
    elif kind == 'symlink':
        elsewhere = os.path.join(WORK, 'elsewhere-' + kind)
        with open(elsewhere, 'wb') as handle:
            handle.write(PAYLOAD_BYTES)
        os.symlink(elsewhere, target)
    elif kind == 'directory':
        os.mkdir(target, 0o555)
    else:
        server = socket_module.socket(socket_module.AF_UNIX)
        server.bind(target)
    os.chmod(invocation, 0o555)
    # The refusal must arrive rather than the open blocking forever.
    outcome = refused(profile, handoff)
    assert isinstance(outcome, W.WorkerRefused), kind
print('OK')
"

run_case "a symlink or special file inside the package tree is refused" "${PRELUDE}
profile, handoff, package, payload = published('pkgspecial')
invocation = os.path.join(handoff, profile.cinv)
base = os.path.join(invocation, 'package')
os.chmod(invocation, 0o755); os.chmod(base, 0o755)
os.symlink('/etc/passwd', os.path.join(base, 'link.py'))
os.chmod(base, 0o555); os.chmod(invocation, 0o555)
outcome = refused(profile, handoff)
assert isinstance(outcome, W.WorkerRefused), outcome

profile, handoff, package, payload = published('pkgfifo')
invocation = os.path.join(handoff, profile.cinv)
base = os.path.join(invocation, 'package')
os.chmod(invocation, 0o755); os.chmod(base, 0o755)
os.mkfifo(os.path.join(base, 'pipe.py'), 0o444)
os.chmod(base, 0o555); os.chmod(invocation, 0o555)
outcome = refused(profile, handoff)
assert isinstance(outcome, W.WorkerRefused), outcome
print('OK')
"

run_case "the worker opens governed material without blocking on it" "${PRELUDE}
import inspect
source = inspect.getsource(W)
assert 'O_NONBLOCK' in source, 'a coordinator-controlled open can block'
assert 'O_NOFOLLOW' in source
# The privileged transition still never reads this material at all. Read as
# code: the module's prose explains at length why root stays opaque, and a scan
# that cannot tell an explanation from a call would forbid the explanation.
import ast
tree = ast.parse(open('provisioning/execution/kyri-exec-transition-action.py',
                      encoding='utf-8').read())
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
            and body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        del body[0]
        if not body:
            body.append(ast.Pass())
ast.fix_missing_locations(tree)
action = ast.unparse(tree)
for banned in ('payload', 'package', 'entrypoint', 'ExecutionProfile'):
    assert banned not in action, banned
print('OK')
"

# ===========================================================================
# Ordering -- everything fails before create_argv
# ===========================================================================

run_case "no refusal path reaches create_argv" "${PRELUDE}
profile, handoff, package, payload = published('ordering')
calls = []
original = W.create_argv

def spy(verified):
    calls.append(verified)
    return original(verified)

W.create_argv = spy
try:
    # One representative from every condition.
    refused(substituted(profile, network='host'), handoff,
            ctx=context(substituted(profile, network='host'),
                        digest=P.fingerprint(substituted(profile, network='host')).profile_digest))
    refused(profile, handoff, images=Images(present=()))
    refused(substituted(profile, adapter_identity='nope'), handoff,
            ctx=context(substituted(profile, adapter_identity='nope'),
                        digest=P.fingerprint(substituted(profile, adapter_identity='nope')).profile_digest))
    refused(profile, handoff, ctx=context(profile, cimp='CIMP-000009'))
    assert calls == [], 'create_argv was reached on a refusal path'
    # And the accepted path does reach it exactly once.
    verified = verify(profile, handoff)
    W.create_argv(verified)
    assert len(calls) == 1, calls
finally:
    W.create_argv = original
print('OK')
"

run_case "the verified chain is one path with no optional branch" "${PRELUDE}
import inspect
source = inspect.getsource(W.verify_execution)
# Every condition is invoked from the one chain, and none is conditional.
for required in ('verify_governed_policy', 'require_runtime_contract',
                 'require_image_present', '_verify_payload', '_verify_package',
                 'verify_handoff', 'profile_digest', 'cinv', 'cimp'):
    assert required in source, required
# and the commitments are what the helpers actually compare against
helpers = inspect.getsource(W._verify_payload) + inspect.getsource(W._verify_package)
for required in ('payload_digest', 'package_digest', 'package_entrypoint'):
    assert required in helpers, required
# Code, not the docstring that explains there is no optional step.
body = source.split(chr(34) * 3)[2]
for banned in ('if skip', 'unless', 'optional', 'allow_unverified', 'force',
               'except WorkerRefused', 'pass  #'):
    assert banned not in body, banned
params = list(inspect.signature(W.verify_execution).parameters)
assert 'images' in params and 'root_fd' in params, params
print('OK')
"

# ===========================================================================
# Coordinator-side coherency
# ===========================================================================

run_case "the publisher refuses a profile that commits to other material" "${PRELUDE}
from tools.capability.execution.handoff import HandoffIdentityMismatch
import tools.capability.execution.handoff as H
# A profile whose commitments name material other than what is being staged
# must not publish: profile commits A while payload/package publish B is
# exactly the state the commitment exists to make impossible.
base, package, payload_binding = bindings('coherent')
for field, value in (('payload_digest', 'd' * 64),
                     ('package_digest', 'e' * 64),
                     ('package_entrypoint', 'helper.py')):
    binding = P.ProfileBinding(
        cinv='CINV-000042', admission=admission(),
        payload_digest=payload_binding.digest,
        package_digest=package.digest,
        package_entrypoint=package.entrypoint)
    hostile = substituted(P.build_profile(binding), **{field: value})
    root_base = os.path.join(WORK, 'coh-' + field)
    os.makedirs(os.path.join(root_base, 'root'))
    with open(os.path.join(root_base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    cfg = os.open(os.path.join(root_base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(root_base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    try:
        anchor = verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)
    artefact = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        publish_handoff(anchor, 'CINV-000042', artefact, payload_binding,
                        package, profile=hostile)
    except HandoffIdentityMismatch:
        pass
    else:
        raise AssertionError('published a profile committing to other material at ' + field)
    finally:
        os.close(artefact)
print('OK')
"

run_case "the profile builder still refuses caller metadata" "${PRELUDE}
base, package, payload_binding = bindings('nometa')
binding = P.ProfileBinding(
    cinv='CINV-000042', admission=admission(),
    payload_digest=payload_binding.digest,
    package_digest=package.digest,
    package_entrypoint=package.entrypoint)
for metadata in ({'network': 'host'}, {'oci_image_id': 'b' * 64},
                 {'privileged': True}, {'mounts': []}, {'anything': 1},
                 {'package_entrypoint': 'other.py'}, {'payload_digest': 'f' * 64}):
    try:
        P.build_profile(binding, metadata)
    except P.MetadataOverrideRefused:
        continue
    raise AssertionError('metadata influenced the profile: ' + repr(metadata))
print('OK')
"

# ===========================================================================
# G6 stays closed
# ===========================================================================

run_case "nothing here executes a container, and the entrypoint stays gated" "${PRELUDE}
import inspect
# The worker library still names Podman and invokes nothing. Imports and
# calls, not prose: the module docstring says it runs no subprocess, and that
# sentence must not be what fails the check.
import ast as ast_module
tree = ast_module.parse(open('tools/capability/execution/worker.py',
                             encoding='utf-8').read())
for node in ast_module.walk(tree):
    if isinstance(node, (ast_module.Import, ast_module.ImportFrom)):
        rendered = ast_module.unparse(node)
        for banned in ('subprocess', 'multiprocessing', 'socket', 'ctypes'):
            assert banned not in rendered, rendered
    if isinstance(node, ast_module.Call):
        rendered = ast_module.unparse(node.func)
        for banned in ('Popen', 'system', 'execv', 'execve', 'fork', 'spawn'):
            assert not rendered.endswith(banned), rendered
# The installed worker entrypoint still refuses at G6 and builds no argv.
entry = open('provisioning/execution/kyri-exec-worker.py', encoding='utf-8').read()
assert 'no governed runtime backend is bound' in entry
assert 'create_argv' not in entry and 'verify_execution' not in entry
print('OK')
"

run_case "the suite touched no production object" "${PRELUDE}
assert os.getuid() != 0
for path in ('/data/kyri/capability-handoff/CINV-000042',
             '/etc/sudoers.d/kyri-exec',
             '/var/lib/kyri/implementation-authority'):
    assert not os.path.exists(path), path
print('OK')
"

# ===========================================================================
# Registration
# ===========================================================================

run_case "the suite runs in local validation and in CI" "${PRELUDE}
name = 'tests/test-capability-execution-authority-gate.sh'
assert name in open('tools/dev/run-validation.sh', encoding='utf-8').read()
assert name in open('.github/workflows/ci.yml', encoding='utf-8').read()
print('OK')
"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no production path changed while this suite ran"
else
  fail "a production path changed while this suite ran"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Capability execution Pass 4A authority-gate validation passed.\n'
else
  printf 'Capability execution Pass 4A authority-gate validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
