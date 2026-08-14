#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, Pass 4B.
#
# 4B closes the residual race design §14.5 rules. Pass 4A verifies the payload
# and package commitments, and that verification closed nothing: the bind
# sources create_argv emitted pointed straight at coordinator-owned handoff
# paths, and a bind mount shares the source tree for the container's whole
# lifetime. The coordinator could replace the payload and the entrypoint after
# the gate was satisfied and the container would have consumed the replacement.
#
# THE FIX IS A COPY, NOT A CHECK. The worker materialises verified material
# into a snapshot it owns, under ancestry the coordinator cannot write,
# traverse, rename or chmod, recomputes both commitments over the snapshot, and
# Podman binds only that. The source handoff may stay mutable; what the
# container consumes may not.
#
# NOTHING EXECUTES. No Podman, no container, no privilege, no transition. The
# snapshot root is an injected descriptor to a temporary directory, and the
# only thing built is an argv tuple. G6 stays closed.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §14.5
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

PRODUCTION_PATHS=(
  /run/kyri
  /data/kyri/capability-handoff
  /usr/lib/kyri/python
  /etc/tmpfiles.d/kyri-execution-material.conf
  /etc/sudoers.d/kyri-exec
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
from tools.capability.execution import snapshot as S
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.package_contract import validate_package
from tools.capability.execution.payload import validate_payload
from tools.capability.execution.handoff import publish_handoff
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

def admission(cimp='CIMP-000001', image=None):
    return Admission(
        cimp=cimp, oci_image_id=image if image else IMAGE,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)

def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)
    os.chmod(path, mode)

class Images:
    def present(self, oci_image_id):
        return True

class Scene:
    '''One published invocation plus the worker snapshot root it will use.'''

    def __init__(self, name, cinv='CINV-000042', files=None, payload=None,
                 entrypoint='main.py'):
        self.name, self.cinv = name, cinv
        base = os.path.join(WORK, name + '-pkg')
        if os.path.isdir(base):
            shutil.rmtree(base)
        os.makedirs(base)
        for relative, body in (PACKAGE_FILES if files is None else files).items():
            write(os.path.join(base, relative), body)
        handle = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
        try:
            self.package = validate_package(handle, entrypoint=entrypoint)
        finally:
            os.close(handle)
        ppath = os.path.join(WORK, name + '-payload.json')
        write(ppath, PAYLOAD_BYTES if payload is None else payload)
        fd = os.open(ppath, os.O_RDONLY)
        try:
            self.payload = validate_payload(fd, schema_version=1)
        finally:
            os.close(fd)
        self.profile = P.build_profile(P.ProfileBinding(
            cinv=cinv, admission=admission(),
            payload_digest=self.payload.digest,
            package_digest=self.package.digest,
            package_entrypoint=self.package.entrypoint))

        holder = os.path.join(WORK, name + '-hand')
        if os.path.isdir(holder):
            shutil.rmtree(holder)
        os.makedirs(os.path.join(holder, 'root'))
        with open(os.path.join(holder, 'backing-store.json'), 'wb') as fh:
            fh.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs', 'mount_point': '/data'}))
        cfg = os.open(os.path.join(holder, 'backing-store.json'), os.O_RDONLY)
        rt = os.open(os.path.join(holder, 'root'), os.O_RDONLY | os.O_DIRECTORY)
        try:
            anchor = verify_backing_store(cfg, rt, observed=ObservedFilesystem(
                filesystem_uuid=UUID, filesystem_type='xfs',
                mount_point='/data', device_name='/dev/sdb1'))
        finally:
            os.close(cfg); os.close(rt)
        artefact = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
        try:
            publish_handoff(anchor, cinv, artefact, self.payload, self.package,
                            profile=self.profile)
        finally:
            os.close(artefact)
        self.handoff = os.path.join(holder, 'root')
        self.invocation = os.path.join(self.handoff, cinv)
        # The worker snapshot root. In production this is
        # /run/kyri/execution-material, root:kyri-capability 0770; here it is a
        # directory the fixture owns, opened once and passed as a descriptor.
        self.snapshot_root = os.path.join(WORK, name + '-snap')
        os.makedirs(self.snapshot_root, exist_ok=True)

    def verified(self, images=None):
        root_fd = os.open(self.handoff, os.O_RDONLY | os.O_DIRECTORY)
        try:
            return W.verify_execution(
                W.require_launch_context(
                    cinv=self.cinv, cimp=self.profile.cimp,
                    profile_digest=P.fingerprint(self.profile).profile_digest),
                self.profile, root_fd=root_fd,
                images=Images() if images is None else images)
        finally:
            os.close(root_fd)

    def materialise(self, verified=None):
        '''Create the worker snapshot, exactly as the worker will.'''
        handoff_fd = os.open(self.handoff, os.O_RDONLY | os.O_DIRECTORY)
        snap_fd = os.open(self.snapshot_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            return S.materialise(verified if verified is not None else self.verified(),
                                 handoff_fd=handoff_fd, snapshot_fd=snap_fd)
        finally:
            os.close(handoff_fd); os.close(snap_fd)

    def unlock(self):
        '''What the coordinator can always do to material it owns.'''
        os.chmod(self.invocation, 0o755)
        pkg = os.path.join(self.invocation, 'package')
        if os.path.isdir(pkg):
            os.chmod(pkg, 0o755)
            for base, dirs, files in os.walk(pkg):
                for d in dirs:
                    os.chmod(os.path.join(base, d), 0o755)
                for f in files:
                    os.chmod(os.path.join(base, f), 0o644)
        target = os.path.join(self.invocation, 'payload')
        if os.path.exists(target):
            os.chmod(target, 0o644)

    def snapshot_payload(self):
        with open(os.path.join(self.snapshot_root, self.cinv, 'payload'), 'rb') as h:
            return h.read()

    @property
    def committed_payload(self):
        '''The canonical bytes actually published and committed to.

        Not the spelling the fixture wrote: canonicalisation sorts keys, and
        the commitment is over what gets published.
        '''
        return self.payload.canonical_bytes

    def snapshot_member(self, relative):
        with open(os.path.join(self.snapshot_root, self.cinv, 'package', relative),
                  'rb') as h:
            return h.read()

def refused(callable_, *args, **kwargs):
    try:
        callable_(*args, **kwargs)
    except (S.SnapshotRefused, W.WorkerRefused) as error:
        return error
    raise AssertionError('the snapshot accepted material it must refuse')
"

# ===========================================================================
# The race Pass 4A could not close
# ===========================================================================

run_case "the snapshot holds the committed payload after the source is rewritten" "${PRELUDE}
scene = Scene('payload-race')
binding = scene.materialise()
# Everything a coordinator can do to material it owns, after verification.
scene.unlock()
with open(os.path.join(scene.invocation, 'payload'), 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":999}}')
assert scene.snapshot_payload() == scene.committed_payload, 'the snapshot followed the source'
assert hashlib.sha256(scene.snapshot_payload()).hexdigest() == scene.profile.payload_digest
print('OK')
"

run_case "the snapshot holds the committed package after members are rewritten" "${PRELUDE}
scene = Scene('package-race')
binding = scene.materialise()
scene.unlock()
with open(os.path.join(scene.invocation, 'package', 'main.py'), 'wb') as handle:
    handle.write(b'import os\nos.system(\"id\")\n')
with open(os.path.join(scene.invocation, 'package', 'helper.py'), 'wb') as handle:
    handle.write(b'VALUE = 99\n')
assert scene.snapshot_member('main.py') == PACKAGE_FILES['main.py']
assert scene.snapshot_member('helper.py') == PACKAGE_FILES['helper.py']
print('OK')
"

run_case "MANDATORY: a retained writable source descriptor cannot change the snapshot" "${PRELUDE}
scene = Scene('retained-fd')
# Handles retained from before the modes were tightened -- the class of attack
# that disproved descriptor anchoring for the profile.
scene.unlock()
payload_fd = os.open(os.path.join(scene.invocation, 'payload'), os.O_RDWR)
member_fd = os.open(os.path.join(scene.invocation, 'package', 'main.py'), os.O_RDWR)
# Put the published modes back: the handles are already held, which is the
# whole point -- a mode never revoked an open descriptor.
os.chmod(os.path.join(scene.invocation, 'package', 'main.py'), 0o444)
os.chmod(os.path.join(scene.invocation, 'package'), 0o555)
os.chmod(os.path.join(scene.invocation, 'payload'), 0o444)
os.chmod(scene.invocation, 0o555)

binding = scene.materialise()

os.pwrite(payload_fd, b'X', 0)
os.ftruncate(payload_fd, 4)
os.pwrite(member_fd, b'import os\n', 0)
os.fsync(payload_fd); os.fsync(member_fd)
mutated = os.pread(payload_fd, 4096, 0)
assert mutated != scene.committed_payload, 'the fixture failed to mutate the source'

assert scene.snapshot_payload() == scene.committed_payload, 'a retained FD changed the snapshot'
assert scene.snapshot_member('main.py') == PACKAGE_FILES['main.py']
os.close(payload_fd); os.close(member_fd)
print('OK')
"

run_case "MANDATORY: replacing the handoff directory cannot change the snapshot" "${PRELUDE}
scene = Scene('parent-replace')
binding = scene.materialise()
before_payload = scene.snapshot_payload()
before_member = scene.snapshot_member('main.py')

# chmod the parent, rename members, replace the package directory outright --
# every route the profile path-freeze model was disproved by.
scene.unlock()
os.rename(os.path.join(scene.invocation, 'payload'),
          os.path.join(scene.invocation, 'payload.moved'))
with open(os.path.join(scene.invocation, 'payload'), 'wb') as handle:
    handle.write(b'{\"operation\":\"other\"}')
shutil.rmtree(os.path.join(scene.invocation, 'package'))
os.makedirs(os.path.join(scene.invocation, 'package'))
with open(os.path.join(scene.invocation, 'package', 'main.py'), 'wb') as handle:
    handle.write(b'HOSTILE = 1\n')

assert scene.snapshot_payload() == before_payload
assert scene.snapshot_member('main.py') == before_member
print('OK')
"

run_case "MANDATORY: repeated source mutation during container lifetime is invisible" "${PRELUDE}
scene = Scene('lifetime')
binding = scene.materialise()
argv = W.create_argv(binding)
# The paths create_argv hands Podman.
sources = [a.split('src=')[1].split(',')[0] for a in argv if a.startswith('type=bind')]
payload_source = [s for s in sources if s.endswith('/payload')][0]
package_source = [s for s in sources if s.endswith('/package')][0]
assert payload_source.startswith(S.SNAPSHOT_ROOT), payload_source
assert package_source.startswith(S.SNAPSHOT_ROOT), package_source
# Repeatedly mutate the coordinator source, as it could throughout execution.
for round_number in range(5):
    scene.unlock()
    with open(os.path.join(scene.invocation, 'payload'), 'wb') as handle:
        handle.write(b'{\"round\":' + str(round_number).encode() + b'}')
    with open(os.path.join(scene.invocation, 'package', 'main.py'), 'wb') as handle:
        handle.write(b'ROUND = ' + str(round_number).encode() + b'\n')
    assert scene.snapshot_payload() == scene.committed_payload
    assert scene.snapshot_member('main.py') == PACKAGE_FILES['main.py']
print('OK')
"

# ===========================================================================
# create_argv binds the snapshot and nothing else
# ===========================================================================

run_case "Podman bind sources are the snapshot, never the coordinator handoff" "${PRELUDE}
import inspect
scene = Scene('bindsrc')
argv = W.create_argv(scene.materialise())
binds = [a for a in argv if a.startswith('type=bind')]
payload_bind = [b for b in binds if 'input/payload' in b][0]
package_bind = [b for b in binds if 'dst=/kyri/package' in b][0]
assert 'src=' + S.SNAPSHOT_ROOT + '/CINV-000042/payload,' in payload_bind, payload_bind
assert 'src=' + S.SNAPSHOT_ROOT + '/CINV-000042/package,' in package_bind, package_bind
# The handoff path must not appear as any bind source at all.
for bind in binds:
    source = bind.split('src=')[1].split(',')[0]
    if source.endswith('/out'):
        assert source.startswith(W.HANDOFF_ROOT), source   # output does not move
    else:
        assert not source.startswith(W.HANDOFF_ROOT), 'a handoff path is a bind source'
# Structural: the argv builder derives input sources from the snapshot only.
code = inspect.getsource(W.create_argv)
assert 'snapshot' in code, code
print('OK')
"

run_case "the output leaf does not move and keeps its quota story" "${PRELUDE}
scene = Scene('outputpath')
argv = W.create_argv(scene.materialise())
out = [a.split('src=')[1].split(',')[0] for a in argv
       if a.startswith('type=bind') and 'dst=/kyri/output' in a][0]
assert out == W.HANDOFF_ROOT + '/CINV-000042/out', out
assert not out.startswith(S.SNAPSHOT_ROOT), 'the writable leaf moved off /data'
print('OK')
"

# ===========================================================================
# Snapshot root and per-CINV allocation
# ===========================================================================

run_case "the snapshot root is compiled in and cannot be injected" "${PRELUDE}
import inspect
assert S.SNAPSHOT_ROOT == '/run/kyri/execution-material', S.SNAPSHOT_ROOT
source = inspect.getsource(S)
for banned in ('os.environ', 'getenv', 'sys.argv', 'SNAPSHOT_ROOT =' + ' os'):
    assert banned not in source, banned
# The materialiser takes descriptors, never a destination path.
params = list(inspect.signature(S.materialise).parameters)
assert params == ['verified', 'handoff_fd', 'snapshot_fd'], params
for banned in ('root', 'path', 'destination', 'directory'):
    assert banned not in params, banned
print('OK')
"

run_case "the per-CINV snapshot is create-once and a collision refuses" "${PRELUDE}
scene = Scene('createonce')
scene.materialise()
# A second attempt is a refusal, not an adoption, an overwrite, or a delete.
outcome = refused(scene.materialise)
assert 'exists' in str(outcome).lower() or 'collision' in str(outcome).lower(), outcome
# The first snapshot is untouched by the refused attempt.
assert scene.snapshot_payload() == scene.committed_payload
print('OK')
"

run_case "unexpected pre-existing objects at the snapshot name refuse" "${PRELUDE}
for kind in ('file', 'symlink', 'directory'):
    scene = Scene('preexist-' + kind)
    target = os.path.join(scene.snapshot_root, scene.cinv)
    if kind == 'file':
        with open(target, 'wb') as handle:
            handle.write(b'x')
    elif kind == 'symlink':
        os.symlink('/tmp', target)
    else:
        os.makedirs(target)
    outcome = refused(scene.materialise)
    assert isinstance(outcome, S.SnapshotRefused), kind
print('OK')
"

# ===========================================================================
# Commitments recomputed over the snapshot
# ===========================================================================

run_case "both commitments are recomputed over the snapshot, not carried over" "${PRELUDE}
import inspect
scene = Scene('recompute')
binding = scene.materialise()
assert binding.payload_digest == scene.profile.payload_digest
assert binding.package_digest == scene.profile.package_digest
assert binding.entrypoint == 'main.py'
assert binding.cinv == scene.cinv
# Proven from the snapshot bytes themselves, independently of the module.
body = scene.snapshot_payload()
assert hashlib.sha256(body).hexdigest() == scene.profile.payload_digest
handle = os.open(os.path.join(scene.snapshot_root, scene.cinv, 'package'),
                 os.O_RDONLY | os.O_DIRECTORY)
try:
    again = validate_package(handle, entrypoint=scene.profile.package_entrypoint)
finally:
    os.close(handle)
assert again.digest == scene.profile.package_digest
# One commitment definition, shared with the publisher and the Pass 4A verifier.
source = inspect.getsource(S)
assert 'validate_package' in source, 'the snapshot invents a second package digest'
print('OK')
"

run_case "a source mutated between verification and copy is refused, not retried" "${PRELUDE}
import inspect
scene = Scene('midcopy')
verified = scene.verified()
# The window Pass 4A cannot close: mutate after the gate, before the copy.
scene.unlock()
with open(os.path.join(scene.invocation, 'package', 'helper.py'), 'wb') as handle:
    handle.write(b'VALUE = 2\n')
outcome = refused(scene.materialise, verified)
assert isinstance(outcome, S.SnapshotRefused), outcome
# And no retry loop exists to paper over it. Bounded read/write loops are
# fine -- copying bytes needs them; what must not exist is a second attempt at
# the copy, which against an adversary that can mutate again has no end.
source = inspect.getsource(S.materialise)
assert 'while ' not in source, 'the materialiser loops'
# Code, not the docstring that explains why there is no retry.
import ast
tree = ast.parse(inspect.getsource(S))
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
whole = ast.unparse(tree)
for banned in ('retry', 'attempt in range', 'for _ in range'):
    assert banned not in whole, banned
# No self-call: the copy is attempted once, and a failure is a refusal.
calls = [ast.unparse(n.func) for n in ast.walk(ast.parse(whole))
         if isinstance(n, ast.Call)]
assert 'materialise' not in calls, 'the materialiser calls itself'
print('OK')
"

run_case "a payload mutated between verification and copy is refused" "${PRELUDE}
scene = Scene('midcopy-payload')
verified = scene.verified()
scene.unlock()
with open(os.path.join(scene.invocation, 'payload'), 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":4}}')
# The payload snapshot is written from the bytes verification already read, so
# the copy itself is immune; the package re-check is what fails the invocation
# if anything else moved. Either way the snapshot equals the commitment.
binding = scene.materialise(verified)
assert scene.snapshot_payload() == scene.committed_payload
assert binding.payload_digest == scene.profile.payload_digest
print('OK')
"

# ===========================================================================
# Special files and traversal
# ===========================================================================

run_case "a special file in place of the payload refuses without blocking" "${PRELUDE}
import socket as socket_module
for kind in ('fifo', 'symlink', 'directory', 'socket'):
    scene = Scene('special-' + kind)
    verified = scene.verified()
    scene.unlock()
    target = os.path.join(scene.invocation, 'payload')
    os.unlink(target)
    if kind == 'fifo':
        os.mkfifo(target, 0o444)
    elif kind == 'symlink':
        elsewhere = os.path.join(WORK, 'else-' + kind)
        with open(elsewhere, 'wb') as handle:
            handle.write(PAYLOAD_BYTES)
        os.symlink(elsewhere, target)
    elif kind == 'directory':
        os.mkdir(target, 0o555)
    else:
        server = socket_module.socket(socket_module.AF_UNIX)
        server.bind(target)
    # The payload snapshot comes from verified bytes, so this must not even be
    # read -- but the package walk and the source checks must still refuse
    # rather than block, and the invocation must not silently continue.
    try:
        binding = scene.materialise(verified)
    except (S.SnapshotRefused, W.WorkerRefused):
        continue
    assert scene.snapshot_payload() == scene.committed_payload, kind
print('OK')
"

run_case "a symlink, FIFO, or special member in the package refuses" "${PRELUDE}
for kind in ('symlink', 'fifo'):
    scene = Scene('pkgspecial-' + kind)
    verified = scene.verified()
    scene.unlock()
    target = os.path.join(scene.invocation, 'package', 'sneak.py')
    if kind == 'symlink':
        os.symlink('/etc/passwd', target)
    else:
        os.mkfifo(target, 0o444)
    outcome = refused(scene.materialise, verified)
    assert isinstance(outcome, S.SnapshotRefused), kind
print('OK')
"

run_case "an oversized member is refused before the snapshot grows" "${PRELUDE}
from tools.capability.execution.package_contract import (
    MAXIMUM_FILE_BYTES, MAXIMUM_AGGREGATE_BYTES)
from tools.capability.execution.payload import PAYLOAD_MAXIMUM_BYTES
# The bounds are the package/payload contract's, not a second policy.
import inspect
source = inspect.getsource(S)
assert 'MAXIMUM' in source or 'validate_package' in source
assert MAXIMUM_AGGREGATE_BYTES == 64 * 1024 * 1024
assert PAYLOAD_MAXIMUM_BYTES == 2 * 1024 * 1024
scene = Scene('oversized')
verified = scene.verified()
scene.unlock()
with open(os.path.join(scene.invocation, 'package', 'big.py'), 'wb') as handle:
    handle.write(b'#' * (MAXIMUM_FILE_BYTES + 1))
outcome = refused(scene.materialise, verified)
assert isinstance(outcome, S.SnapshotRefused), outcome
print('OK')
"

# ===========================================================================
# Cross-CINV
# ===========================================================================

run_case "cross-CINV material cannot be snapshotted for another invocation" "${PRELUDE}
one = Scene('cross-a', cinv='CINV-000042', files={'main.py': b'A = 1\n'})
two = Scene('cross-b', cinv='CINV-000043', files={'main.py': b'B = 2\n'},
            payload=b'{\"operation\":\"sum\",\"arguments\":{\"count\":7}}')
verified = one.verified()
# The coordinator substitutes B's material into A's handoff before the copy.
one.unlock()
shutil.rmtree(os.path.join(one.invocation, 'package'))
shutil.copytree(os.path.join(two.invocation, 'package'),
                os.path.join(one.invocation, 'package'))
outcome = refused(one.materialise, verified)
assert isinstance(outcome, S.SnapshotRefused), outcome
# And after a successful snapshot, nothing about B can reach A.
three = Scene('cross-c', cinv='CINV-000042', files={'main.py': b'A = 1\n'})
binding = three.materialise()
two.unlock()
with open(os.path.join(two.invocation, 'package', 'main.py'), 'wb') as handle:
    handle.write(b'HOSTILE = 1\n')
assert three.snapshot_member('main.py') == b'A = 1\n'
print('OK')
"

# ===========================================================================
# Ordering and gate preservation
# ===========================================================================

run_case "no snapshot failure reaches create_argv" "${PRELUDE}
scene = Scene('spy')
calls = []
original = W.create_argv
def spy(binding):
    calls.append(binding)
    return original(binding)
W.create_argv = spy
try:
    collide = Scene('spy-collide')
    collide.materialise()
    try:
        collide.materialise()
    except S.SnapshotRefused:
        pass
    mid = Scene('spy-mid')
    verified = mid.verified()
    mid.unlock()
    with open(os.path.join(mid.invocation, 'package', 'helper.py'), 'wb') as h:
        h.write(b'VALUE = 3\n')
    try:
        mid.materialise(verified)
    except S.SnapshotRefused:
        pass
    assert calls == [], 'create_argv was reached on a refusal path'
    original(scene.materialise())
finally:
    W.create_argv = original
print('OK')
"

run_case "the snapshot requires a VerifiedExecution and cannot be told it is verified" "${PRELUDE}
import inspect
scene = Scene('gatereq')
handoff_fd = os.open(scene.handoff, os.O_RDONLY | os.O_DIRECTORY)
snap_fd = os.open(scene.snapshot_root, os.O_RDONLY | os.O_DIRECTORY)
try:
    for bad in (scene.profile, None, True, 'CINV-000042', scene.package,
                {'verified': True}):
        try:
            S.materialise(bad, handoff_fd=handoff_fd, snapshot_fd=snap_fd)
        except (S.SnapshotRefused, W.WorkerRefused):
            continue
        raise AssertionError('the snapshot accepted an unverified stand-in')
finally:
    os.close(handoff_fd); os.close(snap_fd)
# And the result cannot be manufactured either.
try:
    S.SnapshotBinding(cinv='CINV-000042', payload='/x', package='/y',
                      entrypoint='main.py', payload_digest='c' * 64,
                      package_digest='d' * 64)
except Exception:
    print('OK')
else:
    raise AssertionError('a snapshot binding was constructed directly')
"

run_case "Pass 4A conditions still run before any snapshot exists" "${PRELUDE}
import inspect
# The snapshot is not a bypass: it consumes a VerifiedExecution, which only
# the Pass 4A gate produces, and that gate is unchanged.
source = inspect.getsource(W.verify_execution)
for required in ('verify_governed_policy', 'require_runtime_contract',
                 'require_image_present', '_verify_payload', '_verify_package'):
    assert required in source, required
assert 'materialise' not in source, 'the gate performs the copy'
assert 'snapshot' not in inspect.getsource(W.verify_execution).lower()
print('OK')
"

# ===========================================================================
# Modes, lifetime, cleanup
# ===========================================================================

run_case "the finished snapshot is tightened, as defence in depth" "${PRELUDE}
scene = Scene('modes')
scene.materialise()
base = os.path.join(scene.snapshot_root, scene.cinv)
assert stat.S_IMODE(os.lstat(base).st_mode) == 0o500, oct(stat.S_IMODE(os.lstat(base).st_mode))
assert stat.S_IMODE(os.lstat(os.path.join(base, 'payload')).st_mode) == 0o444
assert stat.S_IMODE(os.lstat(os.path.join(base, 'package')).st_mode) == 0o500
for relative in PACKAGE_FILES:
    member = os.path.join(base, 'package', relative)
    assert stat.S_IMODE(os.lstat(member).st_mode) == 0o444, relative
print('OK')
"

run_case "the worker discards its own snapshot, and a discard is create-once safe" "${PRELUDE}
scene = Scene('discard')
scene.materialise()
base = os.path.join(scene.snapshot_root, scene.cinv)
assert os.path.isdir(base)
snap_fd = os.open(scene.snapshot_root, os.O_RDONLY | os.O_DIRECTORY)
try:
    S.discard(scene.cinv, snapshot_fd=snap_fd)
    assert not os.path.exists(base), 'the snapshot survived its discard'
    # Discarding what is not there is a refusal, not a silent success: a
    # cleanup that cannot see what it removed cannot claim it removed it.
    try:
        S.discard(scene.cinv, snapshot_fd=snap_fd)
    except S.SnapshotRefused:
        pass
    else:
        raise AssertionError('discarding an absent snapshot reported success')
finally:
    os.close(snap_fd)
# After discard the CINV may be materialised again only through the whole gate.
print('OK')
"

run_case "the snapshot module holds no privilege and runs no container" "${PRELUDE}
import ast, inspect
tree = ast.parse(open('tools/capability/execution/snapshot.py', encoding='utf-8').read())
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        rendered = ast.unparse(node)
        for banned in ('subprocess', 'ctypes', 'socket', 'multiprocessing'):
            assert banned not in rendered, rendered
    if isinstance(node, ast.Call):
        name = ast.unparse(node.func)
        for banned in ('chown', 'setuid', 'setgid', 'system', 'Popen', 'execv'):
            assert not name.endswith(banned), name
# Code, not the prose that explains this module never reaches a runtime.
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
code = ast.unparse(tree).lower()
for banned in ('podman', 'sudo', 'subprocess'):
    assert banned not in code, banned
print('OK')
"

# ===========================================================================
# The generation-6 host prerequisite
# ===========================================================================

run_case "the tmpfiles.d artifact names exactly the ruled root and modes" "${PRELUDE}
from pathlib import Path
conf = Path('provisioning/execution/tmpfiles.d/kyri-execution-material.conf')
assert conf.exists(), str(conf) + ' is absent'
lines = [line.strip() for line in conf.read_text(encoding='utf-8').splitlines()
         if line.strip() and not line.strip().startswith('#')]
assert len(lines) == 2, lines
fields = [line.split() for line in lines]
assert fields[0][:5] == ['d', '/run/kyri', '0755', 'root', 'root'], fields[0]
assert fields[1][:5] == ['d', '/run/kyri/execution-material', '0770', 'root',
                         'kyri-capability'], fields[1]
# No age field: nothing may sweep live execution material on a timer.
for row in fields:
    assert len(row) == 5 or (len(row) == 6 and row[5] == '-'), row
# The coordinator is granted nothing. It may be named in a comment -- the
# operator has to verify its group membership -- but never in a directive.
text = conf.read_text(encoding='utf-8')
for line in lines:
    assert 'cschott' not in line, 'the coordinator appears in a directive: ' + line
for line in lines:
    for banned in ('0777', '0775', '0707', '0666'):
        assert banned not in line, 'a directive grants ' + banned
    assert not line.startswith('R'), 'a directive removes recursively: ' + line
    assert not line.startswith('D '), 'a directive empties on boot: ' + line
print('OK')
"

run_case "the prerequisite is an artifact and is installed by nothing here" "${PRELUDE}
from pathlib import Path
# The claim is about this REPOSITORY, not about the host: nothing here installs
# the prerequisite. It asserted absence until generation 6 was installed, at
# which point an operator provisioned it through the ruled ceremony and the
# absence assertion started failing for the one reason that is not a defect.
# What survives the transition is the property actually being protected -- if
# the fragment is installed, it is byte-for-byte the artifact in this
# repository, so nothing here or anywhere else substituted one.
installed = Path('/etc/tmpfiles.d/kyri-execution-material.conf')
if installed.exists():
    committed = Path('provisioning/execution/tmpfiles.d/kyri-execution-material.conf')
    assert installed.read_bytes() == committed.read_bytes(), \
        'the installed fragment is not the artifact in this repository'
    assert os.path.isdir('/run/kyri/execution-material'), \
        'the fragment is installed but the snapshot root is not a directory'
# Two suites may NAME systemd-tmpfiles: this one, and the generation-6
# installer harness, whose whole purpose is to prove the installer never runs
# it. Naming it is allowed for exactly those two; RUNNING it is allowed for
# none, and that is now asserted directly rather than approximated by banning
# the word.
may_name = {'test-capability-execution-snapshot.sh',
            'test-capability-execution-generation6-installer.sh',
            'test-capability-execution-g5-preflight.sh'}
for suite in Path('tests').glob('*.sh'):
    text = suite.read_text(encoding='utf-8')
    assert 'systemd-tmpfiles' not in text or suite.name in may_name, suite.name
    for line in text.splitlines():
        stripped = line.strip()
        assert not stripped.startswith('systemd-tmpfiles'), (suite.name, line)
        assert not stripped.startswith('sudo systemd-tmpfiles'), (suite.name, line)
    assert '/etc/tmpfiles.d/kyri-execution-material.conf' not in text.replace(
        \"assert not os.path.exists('/etc/tmpfiles.d/kyri-execution-material.conf')\", '') \\
        or suite.name == 'test-capability-execution-snapshot.sh', suite.name
# The runbook records it as a generation-6 prerequisite with the group rule.
runbook = Path('provisioning/execution/README.md').read_text(encoding='utf-8')
assert '/run/kyri/execution-material' in runbook
assert 'kyri-capability' in runbook
print('OK')
"

run_case "the ruled ancestry and group assumption are recorded for the operator" "${PRELUDE}
from pathlib import Path
runbook = Path('provisioning/execution/README.md').read_text(encoding='utf-8')
design = Path('docs/superpowers/specs/2026-08-11-first-adapter-design.md').read_text(
    encoding='utf-8')
# The guarantee depends on cschott not being in group 987; the operator must
# verify it on the live host, so it must be written where they will look.
assert 'namei' in runbook, 'ancestry verification is not in the runbook'
for required in ('cschott', 'kyri-capability', '0770'):
    assert required in runbook, required
assert 'share no group' in design or 'no shared group' in design.lower()
print('OK')
"

run_case "the suite runs in local validation and in CI" "${PRELUDE}
name = 'tests/test-capability-execution-snapshot.sh'
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
  printf 'Capability execution Pass 4B snapshot validation passed.\n'
else
  printf 'Capability execution Pass 4B snapshot validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
