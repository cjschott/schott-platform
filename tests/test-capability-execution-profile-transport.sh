#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, Pass 3B-ii.
#
# 3B-ii is the SEALED PROFILE TRANSPORT across the privilege boundary: root
# authenticates the coordinator's published profile bytes, copies them into an
# object only root has ever written, seals it, hands it to the worker as a
# fixed descriptor, and the worker consumes it from there and nowhere else.
#
# THIS SUITE PERFORMS NO PRIVILEGED OPERATION. Every credential change and the
# exec itself run through an injected backend that records and does nothing.
# What is NOT injected is the part the ruling turns on: the open, the stat, the
# read, the hash, the memfd, the seals, the FD 3 placement, and the descriptor
# flags are the production code path running for real, unprivileged, against a
# temporary tree. A mock cannot falsify a mutation-resistance claim, so the two
# empirical cases below use real writable descriptors and a real execve.
#
# TWO MODELS WERE ACCEPTED AND THEN DISPROVED before this one -- a root-owned
# path freeze and descriptor anchoring to the coordinator's inode -- and the
# property that killed both is asserted here directly: WORKER BYTES == THE
# EXACT BYTES ROOT AUTHENTICATED, which is strictly stronger than same inode.
#
# ROOT STAYS POLICY-OPAQUE. It hashes, copies, and seals; it parses no
# execution field. That is asserted structurally rather than trusted.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §14.1
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "provisioning/execution/kyri-exec-transition.py"
assert_file "provisioning/execution/kyri-exec-transition-action.py"
assert_file "provisioning/execution/kyri-exec-worker.py"
assert_file "tools/capability/execution/worker.py"

WORK="$(mktemp -d)"
# The fixtures reproduce the production 0555 invocation directory, which its
# owner cannot delete from until it restores write access -- the same fact the
# rejected path-freeze model turned on.
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# Production objects this suite must never touch. Compared before and after
# rather than asserted absent: absence only ever asked whether G4 had run.
PRODUCTION_PATHS=(
  /data/kyri/capability-handoff
  /data/kyri/capability-runtime/execution
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-worker.py
  /etc/sudoers.d/kyri-exec
)
PRODUCTION_BEFORE="${WORK}/production-before.json"
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
    state[path] = [info.st_mode, info.st_uid, info.st_gid, info.st_size,
                   info.st_mtime_ns, info.st_ctime_ns]
print(json.dumps(state, sort_keys=True))
' "$@"
}
snapshot_production "${PRODUCTION_PATHS[@]}" > "${PRODUCTION_BEFORE}"

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
import fcntl, hashlib, importlib.util, os, stat, sys, types

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy_mod = load('kyri_exec_transition',
                  'provisioning/execution/kyri-exec-transition.py')
action = load('kyri_exec_transition_action',
              'provisioning/execution/kyri-exec-transition-action.py')

from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.profile import (
    ProfileBinding, build_profile, canonical_profile, fingerprint)

WORK = os.environ['WORKDIR']
DROP = object()

def admission(cimp='CIMP-000001', image=None):
    return Admission(
        cimp=cimp, oci_image_id=image if image else 'a' * 64,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=1,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)

def governed_profile(cinv='CINV-000042', cimp='CIMP-000001', image=None):
    return build_profile(ProfileBinding(cinv=cinv,
                                        admission=admission(cimp, image)))

class Backend:
    '''Records the privileged steps and performs none of them.

    The one real seam is open_directory: it hands back a descriptor to a
    temporary tree, so everything the transition does below that descriptor --
    open, stat, read, hash, copy, seal, place -- is production code running for
    real. Credentials and exec are recorded only.
    '''

    def __init__(self, roots, fail_at=None, uid=999, gid=987, groups=(987,),
                 nnp=1, exec_error=None, root_error=None):
        self.roots = roots
        self.calls = []
        self._fail_at = fail_at
        self._uid, self._gid, self._groups = uid, gid, groups
        self._nnp = nnp
        self._exec_error = exec_error
        self._root_error = root_error
        self.dropped = False

    def _step(self, name, *detail):
        self.calls.append((name,) + detail)
        if self._fail_at == name:
            raise OSError(1, name + ' refused')

    def open_directory(self, path):
        self.calls.append(('open_directory', path))
        if self._root_error is not None:
            raise self._root_error
        target = self.roots.get(path)
        if target is None:
            raise OSError(2, 'no such governed root', path)
        return os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                       | os.O_DIRECTORY)

    def close_extra_descriptors(self, allowlist):
        self._step('close_extra_descriptors', tuple(allowlist))

    def setgroups(self, groups):
        self._step('setgroups', tuple(groups))

    def setgid(self, gid):
        self._step('setgid', gid)

    def setuid(self, uid):
        self._step('setuid', uid)
        self.dropped = True

    def credentials(self):
        self.calls.append(('credentials',))
        if not self.dropped:
            return action.Credentials(0, 0, 0, 0, 0, 0, (0,))
        return action.Credentials(self._uid, self._uid, self._uid,
                                  self._gid, self._gid, self._gid,
                                  tuple(self._groups))

    def set_no_new_privs(self):
        self._step('set_no_new_privs')

    def get_no_new_privs(self):
        self.calls.append(('get_no_new_privs',))
        if self._fail_at == 'get_no_new_privs':
            raise OSError(1, 'refused')
        return self._nnp

    def execve(self, path, argv, environment):
        self.calls.append(('execve', path, tuple(argv), tuple(environment)))
        if self._exec_error is not None:
            raise self._exec_error
        raise action.WorkerExecuted(path)

class Quota:
    '''The injected quota component. Establishes nothing real.'''

    DERIVE = object()

    def __init__(self, error=None, project=DERIVE):
        self.calls = []
        self._error = error
        self._project = project

    def project_id(self, cinv):
        return 1_000_000 + int(cinv[5:])

    def apply(self, cinv):
        self.calls.append(('apply', cinv))
        if self._error is not None:
            raise self._error
        return (self.project_id(cinv) if self._project is Quota.DERIVE
                else self._project)

def names(backend):
    return [call[0] for call in backend.calls]

def scene(name, cinv='CINV-000042', cimp='CIMP-000001', profile=None,
          profile_body=None, profile_mode=0o444, invocation_mode=0o555,
          record_mode=0o600, record_overrides=None, record_body=None,
          publish_profile=True, publish_record=True, profile_kind='file'):
    '''One temporary execution root and handoff root, published for real.'''
    base = os.path.join(WORK, name)
    execution = os.path.join(base, 'execution')
    handoff = os.path.join(base, 'handoff')
    invocation = os.path.join(handoff, cinv)
    os.makedirs(os.path.join(execution, cinv))
    os.makedirs(invocation)

    governed = profile if profile is not None else governed_profile(cinv, cimp)
    body = profile_body if profile_body is not None else canonical_profile(governed)
    digest = hashlib.sha256(body).hexdigest()

    profile_path = os.path.join(invocation, policy_mod.PROFILE_NAME)
    writable = None
    if publish_profile:
        if profile_kind == 'file':
            handle = os.open(profile_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                             0o644)
            try:
                os.write(handle, body)
            finally:
                os.close(handle)
            # Retained BEFORE the mode is tightened, which is exactly the handle
            # a coordinator keeps from before publication. A 0444 file cannot be
            # opened O_RDWR by its owner, so a later open would prove nothing.
            writable = os.open(profile_path, os.O_RDWR)
            os.chmod(profile_path, profile_mode)
        elif profile_kind == 'directory':
            os.mkdir(profile_path, 0o555)
        elif profile_kind == 'fifo':
            os.mkfifo(profile_path, 0o444)
        elif profile_kind == 'symlink':
            target = os.path.join(base, 'elsewhere')
            with open(target, 'wb') as handle:
                handle.write(body)
            os.chmod(target, 0o444)
            os.symlink(target, profile_path)
        else:
            raise AssertionError('unknown profile kind ' + profile_kind)

    document = {
        'cinv': cinv,
        'cimp': cimp,
        'profile_digest': digest,
        'handoff_root': policy_mod.HANDOFF_ROOT,
        'profile_schema_version': 1,
        'commitment_digest': 'b' * 64,
        'lifecycle_state': 'launch_authorized',
    }
    for field, value in (record_overrides or {}).items():
        if value is DROP:
            document.pop(field, None)
        else:
            document[field] = value
    body_record = record_body if record_body is not None else serialise(document)

    record_path = os.path.join(execution, cinv, policy_mod.LAUNCH_RECORD_NAME)
    if publish_record:
        handle = os.open(record_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                         0o600)
        try:
            os.write(handle, body_record)
        finally:
            os.close(handle)
        os.chmod(record_path, record_mode)

    os.chmod(invocation, invocation_mode)

    return types.SimpleNamespace(
        base=base, cinv=cinv, cimp=cimp,
        policy=policy_mod.policy_for(['prog', cinv]),
        profile=governed, profile_bytes=body, profile_digest=digest,
        profile_path=profile_path, invocation=invocation,
        record_path=record_path, record=document,
        writable=writable,
        roots={policy_mod.EXECUTION_ROOT: execution,
               policy_mod.HANDOFF_ROOT: handoff},
        backend=None)

def backend_for(env, **kwargs):
    env.backend = Backend(env.roots, **kwargs)
    return env.backend

def authenticated(env, **kwargs):
    backend = backend_for(env, **kwargs) if env.backend is None else env.backend
    return action.authenticate_launch(env.policy, backend=backend)

def run(env, quota=None, root=True, launch=None, **kwargs):
    backend = backend_for(env, **kwargs) if env.backend is None else env.backend
    try:
        authorisation = launch if launch is not None else \\
            action.authenticate_launch(env.policy, backend=backend)
    except policy_mod.TransitionRefused as error:
        return error
    try:
        action.perform_transition(
            env.policy, launch_authorisation=authorisation, backend=backend,
            quota=Quota() if quota is None else quota, assume_root=root)
    except action.WorkerExecuted:
        return 'executed'
    except policy_mod.TransitionRefused as error:
        return error
    raise AssertionError('the transition returned without executing or refusing')

def sealed_of(backend):
    '''The descriptor the transition placed, taken from the recorded exec.'''
    return policy_mod.PROFILE_FD

def unseal_check(fd):
    return fcntl.fcntl(fd, fcntl.F_GET_SEALS)
"

# ===========================================================================
# EMPIRICAL A -- the retained writable source descriptor
# ===========================================================================
# This is the case that falsified descriptor anchoring. It must be real: a
# mocked write cannot demonstrate that a kernel-enforced seal is what stops it.

run_case "EMPIRICAL A: a retained writable source descriptor cannot change the authenticated bytes" "${PRELUDE}
env = scene('empirical-a')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
assert data == env.profile_bytes, 'the source read did not return the published bytes'
sealed = action.seal_profile_object(data, launch.profile_digest)

# Everything a coordinator holding a pre-publication handle can do.
os.pwrite(env.writable, b'X', 0)
os.ftruncate(env.writable, 4)
os.pwrite(env.writable, b'{}', 0)
os.ftruncate(env.writable, 2)
os.fsync(env.writable)
mutated = os.pread(env.writable, 4096, 0)
assert mutated != env.profile_bytes, 'the fixture failed to mutate the source'

# And the path itself: the coordinator owns the directory, so it can always
# restore write access to it and replace or remove what it published.
os.chmod(env.invocation, 0o755)
os.rename(env.profile_path, env.profile_path + '.moved')
os.unlink(env.profile_path + '.moved')
with open(env.profile_path, 'wb') as handle:
    handle.write(b'{\"cinv\":\"CINV-999999\"}')
os.chmod(env.invocation, 0o555)

seen = os.pread(sealed, len(env.profile_bytes) + 4096, 0)
assert seen == env.profile_bytes, 'the worker would have read mutated bytes'
assert hashlib.sha256(seen).hexdigest() == env.profile_digest, 'the digest moved'
os.close(sealed)
os.close(env.writable)
print('OK')
"

run_case "EMPIRICAL A: the sealed object refuses every mutation, including through a reopen" "${PRELUDE}
env = scene('empirical-a-seals')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
sealed = action.seal_profile_object(data, launch.profile_digest)
refused = 0
for attempt in ('write', 'grow', 'shrink', 'unseal'):
    try:
        if attempt == 'write':
            os.pwrite(sealed, b'X', 0)
        elif attempt == 'grow':
            os.ftruncate(sealed, len(data) + 16)
        elif attempt == 'shrink':
            os.ftruncate(sealed, 1)
        else:
            fcntl.fcntl(sealed, fcntl.F_ADD_SEALS, 0)
    except OSError:
        refused += 1
    else:
        raise AssertionError('the sealed object accepted ' + attempt)
assert refused == 4, refused
# The reopen succeeds and is harmless: the seal is enforced per inode.
reopened = os.open('/proc/self/fd/' + str(sealed), os.O_RDWR)
try:
    os.pwrite(reopened, b'X', 0)
except OSError:
    pass
else:
    raise AssertionError('a /proc reopen defeated the seal')
assert os.pread(reopened, len(data) + 16, 0) == data
os.close(reopened)
os.close(sealed)
print('OK')
"

# ===========================================================================
# EMPIRICAL B -- the memfd allocated as FD 3 survives a real execve
# ===========================================================================
# Source inspection does not count here. dup2(3, 3) is a POSIX no-op that
# leaves FD_CLOEXEC set, so only a real exec can distinguish the governed
# placement from the trap. The control arm runs the trap deliberately.

cat > "${WORK}/fd3-child.py" <<'CHILDPY'
"""Reads what actually crossed execve on FD 3, and says so."""
import fcntl
import hashlib
import os
import sys

REQUIRED = 0x1 | 0x2 | 0x4 | 0x8

try:
    seals = fcntl.fcntl(3, fcntl.F_GET_SEALS)
except OSError as error:
    print("NO-FD3:%d" % error.errno)
    raise SystemExit(0)
body = os.pread(3, 1 << 20, 0)
print("FD3:%d:%s:%d" % (seals & REQUIRED, hashlib.sha256(body).hexdigest(),
                        len(body)))
CHILDPY

cat > "${WORK}/fd3-parent.py" <<'PARENTPY'
"""Arranges the descriptor table so the memfd lands on FD 3, then execs."""
import importlib.util
import os
import sys

repository, profile_path, digest, child, mode = sys.argv[1:6]
os.chdir(repository)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


policy = load("kyri_exec_transition",
              "provisioning/execution/kyri-exec-transition.py")
action = load("kyri_exec_transition_action",
              "provisioning/execution/kyri-exec-transition-action.py")

with open(profile_path, "rb") as handle:
    body = handle.read()

# Free the table so the next allocation is 3. This is the measured trap case.
os.closerange(3, 256)

if mode == "governed":
    handle = action.seal_profile_object(body, digest)
    if handle != 3:
        raise SystemExit("the memfd was not allocated as FD 3: %d" % handle)
    action.place_profile_descriptor(handle)
else:
    # The trap, run deliberately: seal, then rely on dup2(3, 3) alone.
    import fcntl
    handle = os.memfd_create("kyri-exec-profile",
                             os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    if handle != 3:
        raise SystemExit("the memfd was not allocated as FD 3: %d" % handle)
    written = 0
    while written < len(body):
        written += os.write(handle, body[written:])
    fcntl.fcntl(handle, fcntl.F_ADD_SEALS, 0x8 | 0x4 | 0x2 | 0x1)
    os.dup2(handle, 3)

os.execv("/usr/bin/python3", ["/usr/bin/python3", child, digest])
PARENTPY

run_case "EMPIRICAL B: a memfd allocated as FD 3 survives a real execve and arrives sealed" "${PRELUDE}
import subprocess
env = scene('empirical-b')
outcome = subprocess.run(
    ['/usr/bin/python3', os.path.join(WORK, 'fd3-parent.py'), os.getcwd(),
     env.profile_path, env.profile_digest, os.path.join(WORK, 'fd3-child.py'),
     'governed'],
    capture_output=True, text=True)
combined = outcome.stdout + outcome.stderr
assert outcome.returncode == 0, combined
expected = 'FD3:15:' + env.profile_digest + ':' + str(len(env.profile_bytes))
assert expected in combined, combined
print('OK')
"

run_case "EMPIRICAL B: without the explicit FD_CLOEXEC clear the worker receives nothing" "${PRELUDE}
import subprocess
env = scene('empirical-b-control')
outcome = subprocess.run(
    ['/usr/bin/python3', os.path.join(WORK, 'fd3-parent.py'), os.getcwd(),
     env.profile_path, env.profile_digest, os.path.join(WORK, 'fd3-child.py'),
     'control'],
    capture_output=True, text=True)
combined = outcome.stdout + outcome.stderr
assert outcome.returncode == 0, combined
# EBADF is 9: the descriptor was closed by execve, exactly as the ruling records.
assert 'NO-FD3:9' in combined, combined
assert 'FD3:' not in combined.replace('NO-FD3:', ''), combined
print('OK')
"

run_case "EMPIRICAL B: a caller that pre-opens FD 3 has it replaced, not honoured" "${PRELUDE}
env = scene('empirical-b-caller')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
# A caller-owned object sitting on the governed number before the transition.
decoy = os.open(env.record_path, os.O_RDONLY)
if decoy != policy_mod.PROFILE_FD:
    os.dup2(decoy, policy_mod.PROFILE_FD)
    os.close(decoy)
before = os.pread(policy_mod.PROFILE_FD, 64, 0)
assert before and before != env.profile_bytes[:64]
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
handle = action.seal_profile_object(data, launch.profile_digest)
action.place_profile_descriptor(handle)
assert os.pread(policy_mod.PROFILE_FD, len(data) + 16, 0) == env.profile_bytes
assert fcntl.fcntl(policy_mod.PROFILE_FD, fcntl.F_GET_SEALS) \\
    & policy_mod.REQUIRED_SEALS == policy_mod.REQUIRED_SEALS
print('OK')
"

# ===========================================================================
# Launch record vNext
# ===========================================================================

run_case "the launch record schema is exactly the vNext seven fields" "${PRELUDE}
assert policy_mod.LAUNCH_RECORD_SCHEMA == (
    'cinv', 'cimp', 'profile_digest', 'handoff_root',
    'profile_schema_version', 'commitment_digest',
    'lifecycle_state'), policy_mod.LAUNCH_RECORD_SCHEMA
assert len(policy_mod.LAUNCH_RECORD_SCHEMA) == 7
assert 'oci_image_id' not in policy_mod.LAUNCH_RECORD_SCHEMA
source = open('provisioning/execution/kyri-exec-transition.py',
              encoding='utf-8').read()
assert 'oci_image_id' not in source, 'the helper still names an image identity'
print('OK')
"

run_case "an authenticated launch record is a closed, unforgeable projection" "${PRELUDE}
env = scene('vnext-closed')
launch = authenticated(env)
assert isinstance(launch, policy_mod.AuthenticatedLaunch)
assert launch.cinv == 'CINV-000042'
assert launch.cimp == 'CIMP-000001'
assert launch.profile_digest == env.profile_digest
# It cannot be constructed, mutated, or copied into a different shape.
try:
    policy_mod.AuthenticatedLaunch(cinv='CINV-000042', cimp='CIMP-000001',
                                   profile_digest='a' * 64,
                                   handoff_root=policy_mod.HANDOFF_ROOT,
                                   profile_schema_version=1,
                                   commitment_digest='b' * 64,
                                   lifecycle_state='launch_authorized')
except Exception:
    pass
else:
    raise AssertionError('an authenticated record was constructed directly')
for field in ('cinv', 'cimp', 'profile_digest'):
    try:
        setattr(launch, field, 'x')
    except Exception:
        continue
    raise AssertionError('the authenticated record was mutated at ' + field)
print('OK')
"

run_case "the profile digest is exactly 64 lowercase hex characters" "${PRELUDE}
for value in ('A' * 64, 'sha256:' + 'a' * 64, 'a' * 63, 'a' * 65, 'g' * 64,
              '', 1, None, True, 'a' * 32):
    env = scene('digest-' + str(abs(hash(repr(value)))),
                record_overrides={'profile_digest': value})
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (value, outcome)
print('OK')
"

run_case "CIMP-000000 is refused semantically, not merely by grammar" "${PRELUDE}
env = scene('cimp-zero', cimp='CIMP-000000')
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'execve' not in names(env.backend), names(env.backend)
for value in ('CIMP-00001', 'cimp-000001', 'CIMP-00000a', 'CIMP-0000001',
              'CINV-000001', '', None, 1):
    env = scene('cimp-' + str(abs(hash(repr(value)))),
                record_overrides={'cimp': value})
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (value, outcome)
print('OK')
"

run_case "an unknown, missing, or duplicated record field is refused" "${PRELUDE}
env = scene('extra-field', record_overrides={'oci_image_id': 'a' * 64})
assert isinstance(run(env), policy_mod.TransitionRefused)
for field in policy_mod.LAUNCH_RECORD_SCHEMA:
    env = scene('missing-' + field, record_overrides={field: DROP})
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (field, outcome)
env = scene('duplicate-key', record_body=b'{\"cinv\":\"CINV-000042\",\"cinv\":\"CINV-000042\"}')
assert isinstance(run(env), policy_mod.TransitionRefused)
env = scene('not-json', record_body=b'not json at all')
assert isinstance(run(env), policy_mod.TransitionRefused)
env = scene('not-object', record_body=b'[1,2,3]')
assert isinstance(run(env), policy_mod.TransitionRefused)
env = scene('oversized', record_body=b'{\"cinv\":\"' + b'x' * 8192 + b'\"}')
assert isinstance(run(env), policy_mod.TransitionRefused)
print('OK')
"

run_case "a record naming another invocation, root, state, or schema is refused" "${PRELUDE}
for overrides in ({'cinv': 'CINV-000043'},
                  {'handoff_root': '/tmp/elsewhere'},
                  {'lifecycle_state': 'reserved'},
                  {'lifecycle_state': 'created'},
                  {'profile_schema_version': 2},
                  {'profile_schema_version': '1'},
                  {'commitment_digest': 'z' * 64}):
    field = sorted(overrides)[0]
    env = scene('bad-' + field + str(abs(hash(repr(overrides)))),
                record_overrides=overrides)
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (overrides, outcome)
print('OK')
"

run_case "the launch record object must be a private regular file owned by the coordinator" "${PRELUDE}
env = scene('record-mode', record_mode=0o644)
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
env = scene('record-absent', publish_record=False)
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
print('OK')
"

# ===========================================================================
# The authenticated record reaches the privileged action, and nothing else does
# ===========================================================================

run_case "perform_transition takes the authenticated record and no loose identity" "${PRELUDE}
import inspect
params = list(inspect.signature(action.perform_transition).parameters)
assert params == ['policy', 'launch_authorisation', 'backend', 'quota',
                  'assume_root'], params
for banned in ('cinv', 'cimp', 'digest', 'profile_digest', 'uid', 'gid',
               'user', 'command', 'argv', 'executable', 'environment', 'cwd',
               'image', 'path', 'record', 'document'):
    assert banned not in params, banned
signature = inspect.signature(action.perform_transition)
assert signature.parameters['launch_authorisation'].default \\
    is inspect.Parameter.empty, 'the authenticated record can be omitted'
print('OK')
"

run_case "an unauthenticated stand-in for the launch record is refused" "${PRELUDE}
env = scene('bypass')
backend = backend_for(env)
forged = types.SimpleNamespace(
    cinv='CINV-000042', cimp='CIMP-000009', profile_digest='c' * 64,
    handoff_root=policy_mod.HANDOFF_ROOT, profile_schema_version=1,
    commitment_digest='b' * 64, lifecycle_state='launch_authorized')
for stand_in in (forged, dict(vars(forged)), 'CIMP-000009', None, 42,
                 ('CINV-000042', 'CIMP-000009')):
    backend = backend_for(env)
    try:
        action.perform_transition(env.policy, launch_authorisation=stand_in,
                                  backend=backend, quota=Quota(),
                                  assume_root=True)
    except policy_mod.TransitionRefused:
        assert 'execve' not in names(backend), names(backend)
        continue
    except action.WorkerExecuted:
        raise AssertionError('a forged launch record reached execve')
    raise AssertionError('a forged launch record was accepted')
print('OK')
"

run_case "an authenticated record for another invocation is refused" "${PRELUDE}
other = scene('other-invocation', cinv='CINV-000043')
env = scene('this-invocation')
launch = authenticated(other)
backend = backend_for(env)
outcome = run(env, launch=launch)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'execve' not in names(env.backend), names(env.backend)
print('OK')
"

run_case "the transition takes CIMP and the digest from the record, never the caller" "${PRELUDE}
import inspect
source = inspect.getsource(action)
# There is no argv, environment, or metadata route into either value.
for banned in ('sys.argv', 'os.environ', 'getenv', 'CIMP-', 'oci_image_id'):
    assert banned not in source, banned
env = scene('governed-values')
backend = backend_for(env)
assert run(env) == 'executed'
call = [c for c in backend.calls if c[0] == 'execve'][0]
assert call[2][3] == env.cimp, call
assert call[2][4] == env.profile_digest, call
print('OK')
"

# ===========================================================================
# Profile source authentication
# ===========================================================================

run_case "the source profile is authenticated against the record digest" "${PRELUDE}
env = scene('source-good')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
assert data == env.profile_bytes
assert hashlib.sha256(data).hexdigest() == launch.profile_digest
print('OK')
"

run_case "bytes that do not hash to the record digest are refused before any copy" "${PRELUDE}
env = scene('source-mismatch')
# The record commits to the published bytes; the file now holds different ones.
os.chmod(env.invocation, 0o755)
os.chmod(env.profile_path, 0o644)
with open(env.profile_path, 'wb') as handle:
    handle.write(env.profile_bytes.replace(b'\"gpu\":false', b'\"gpu\":true '))
os.chmod(env.profile_path, 0o444)
os.chmod(env.invocation, 0o555)
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'setuid' not in names(env.backend), names(env.backend)
assert 'execve' not in names(env.backend), names(env.backend)
print('OK')
"

run_case "a symlinked, missing, wrong-typed, or wrong-moded profile is refused" "${PRELUDE}
for kind, kwargs in (('symlink', {'profile_kind': 'symlink'}),
                     ('directory', {'profile_kind': 'directory'}),
                     ('fifo', {'profile_kind': 'fifo'}),
                     ('absent', {'publish_profile': False}),
                     ('mode', {'profile_mode': 0o644}),
                     ('world', {'profile_mode': 0o666})):
    env = scene('profile-' + kind, **kwargs)
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (kind, outcome)
    assert 'execve' not in names(env.backend), (kind, names(env.backend))
print('OK')
"

run_case "an oversized profile is refused rather than read" "${PRELUDE}
env = scene('profile-oversized',
            profile_body=b'{\"padding\":\"' + b'x' * 200000 + b'\"}')
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'execve' not in names(env.backend)
print('OK')
"

run_case "a replaced or wrongly-moded invocation directory is refused" "${PRELUDE}
env = scene('invocation-mode', invocation_mode=0o777)
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
env = scene('invocation-symlink')
os.rename(env.invocation, env.invocation + '-real')
os.symlink(env.invocation + '-real', env.invocation)
outcome = run(env)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
print('OK')
"

run_case "the governed handoff root is opened once, from the compiled-in constant" "${PRELUDE}
env = scene('root-once')
backend = backend_for(env)
assert run(env) == 'executed'
opens = [c for c in backend.calls if c[0] == 'open_directory']
assert opens == [('open_directory', policy_mod.EXECUTION_ROOT),
                 ('open_directory', policy_mod.HANDOFF_ROOT)], opens
env = scene('root-unusable')
outcome = run(env, root_error=OSError(13, 'permission denied'))
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
print('OK')
"

# ===========================================================================
# The sealed copy
# ===========================================================================

run_case "the sealed copy carries exactly the mandatory seal set" "${PRELUDE}
env = scene('seal-set')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
sealed = action.seal_profile_object(data, launch.profile_digest)
seals = fcntl.fcntl(sealed, fcntl.F_GET_SEALS)
required = policy_mod.REQUIRED_SEALS
assert required == 0xF, hex(required)
assert seals & required == required, hex(seals)
info = os.fstat(sealed)
assert stat.S_ISREG(info.st_mode), oct(info.st_mode)
assert info.st_size == len(data), info.st_size
assert os.pread(sealed, len(data) + 16, 0) == data
os.close(sealed)
print('OK')
"

run_case "a copy that does not read back byte-identically is refused" "${PRELUDE}
env = scene('copy-verified')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
# The digest is the commitment the copy is verified against; a disagreeing one
# must abort the copy rather than seal something nobody authenticated.
for wrong in ('c' * 64, hashlib.sha256(data + b' ').hexdigest()):
    try:
        action.seal_profile_object(data, wrong)
    except policy_mod.TransitionRefused:
        continue
    raise AssertionError('a copy was sealed against the wrong digest')
print('OK')
"

run_case "there is no temporary-file fallback anywhere in the transport" "${PRELUDE}
source = open('provisioning/execution/kyri-exec-transition-action.py',
              encoding='utf-8').read()
for banned in ('tempfile', 'mkstemp', 'NamedTemporary', 'TemporaryFile',
               '/tmp', '/var/tmp', 'O_TMPFILE'):
    assert banned not in source, banned
assert 'memfd_create' in source, 'the sealed object is not a memfd'
print('OK')
"

# ===========================================================================
# FD 3 placement, CLOEXEC, and descriptor cleanup
# ===========================================================================

run_case "the governed descriptor number is 3 and the inherited set is (0, 1, 2, 3)" "${PRELUDE}
assert policy_mod.PROFILE_FD == 3, policy_mod.PROFILE_FD
assert policy_mod.INHERITED_DESCRIPTORS == (0, 1, 2, 3), \\
    policy_mod.INHERITED_DESCRIPTORS
env = scene('inherited')
backend = backend_for(env)
assert run(env) == 'executed'
calls = dict((c[0], c[1:]) for c in backend.calls if len(c) > 1)
assert calls['close_extra_descriptors'] == ((0, 1, 2, 3),), \\
    calls['close_extra_descriptors']
print('OK')
"

run_case "FD_CLOEXEC is cleared explicitly rather than as a side effect of dup2" "${PRELUDE}
import ast
tree = ast.parse(open('provisioning/execution/kyri-exec-transition-action.py',
                      encoding='utf-8').read())
setfd = [n for n in ast.walk(tree)
         if isinstance(n, ast.Call) and 'F_SETFD' in ast.unparse(n)]
assert setfd, 'the transition never sets the descriptor flags explicitly'
env = scene('cloexec')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
handle = action.seal_profile_object(data, launch.profile_digest)
placed = action.place_profile_descriptor(handle)
assert placed == policy_mod.PROFILE_FD, placed
flags = fcntl.fcntl(policy_mod.PROFILE_FD, fcntl.F_GETFD)
assert not flags & fcntl.FD_CLOEXEC, oct(flags)
assert os.get_inheritable(policy_mod.PROFILE_FD), 'FD 3 is not inheritable'
assert os.lseek(policy_mod.PROFILE_FD, 0, os.SEEK_CUR) == 0, 'the offset is not rewound'
print('OK')
"

run_case "a duplicate of the sealed object does not become a second inherited descriptor" "${PRELUDE}
env = scene('duplicate')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
handle = action.seal_profile_object(data, launch.profile_digest)
if handle == policy_mod.PROFILE_FD:
    moved = os.dup(handle)
    os.close(handle)
    handle = moved
spare = os.dup(handle)
action.place_profile_descriptor(handle)
# The redundant original is closed by the placement; the test's own duplicate
# is exactly what close_extra_descriptors removes in production.
assert spare not in policy_mod.INHERITED_DESCRIPTORS
try:
    os.fstat(handle)
except OSError:
    pass
else:
    if handle != policy_mod.PROFILE_FD:
        raise AssertionError('the redundant sealed descriptor stayed open')
os.close(spare)
print('OK')
"

run_case "no writable capability over the profile reaches the worker" "${PRELUDE}
env = scene('read-only')
backend = backend_for(env)
assert run(env) == 'executed'
try:
    os.pwrite(policy_mod.PROFILE_FD, b'X', 0)
except OSError:
    pass
else:
    raise AssertionError('the descriptor handed to the worker is writable')
print('OK')
"

# ===========================================================================
# Ordering
# ===========================================================================

run_case "the accepted sequence runs in exactly the accepted order" "${PRELUDE}
env = scene('ordering')
backend = backend_for(env)
quota = Quota()
assert run(env, quota=quota) == 'executed'
assert names(backend) == [
    'open_directory', 'open_directory', 'close_extra_descriptors',
    'setgroups', 'setgid', 'setuid', 'credentials', 'set_no_new_privs',
    'get_no_new_privs', 'credentials', 'execve'], names(backend)
assert quota.calls == [('apply', env.cinv)], quota.calls
print('OK')
"

run_case "the source ordering of the transition is the accepted ordering" "${PRELUDE}
import inspect
# The docstring names several of these steps while explaining them, and a scan
# that cannot tell prose from a call would forbid explaining the reason.
source = inspect.getsource(action.perform_transition).split(chr(34) * 3)[2]
markers = [
    ('quota', 'quota.apply'),
    ('source', 'authenticate_profile_source'),
    ('seal', 'seal_profile_object'),
    ('place', 'place_profile_descriptor'),
    ('cleanup', 'close_extra_descriptors'),
    ('verify', 'verify_profile_descriptor'),
    ('setgroups', 'setgroups'),
    ('setgid', 'setgid'),
    ('setuid', 'setuid'),
    ('nnp', 'set_no_new_privs'),
    ('exec', 'execve'),
]
seen = []
for name, token in markers:
    index = source.find(token)
    assert index >= 0, 'the transition never calls ' + token
    seen.append((index, name))
assert seen == sorted(seen), [n for _, n in seen]
print('OK')
"

run_case "no profile or policy work happens after the credential drop" "${PRELUDE}
import inspect
source = inspect.getsource(action.perform_transition)
after = source.split('setuid')[-1]
for banned in ('memfd_create', 'F_ADD_SEALS', 'seal_profile_object',
               'authenticate_profile_source', 'place_profile_descriptor',
               'open_directory', 'sha256'):
    assert banned not in after, banned
print('OK')
"

run_case "a failure at any step prevents every later step and the exec" "${PRELUDE}
sequence = ['close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
            'set_no_new_privs', 'get_no_new_privs']
for step in sequence:
    env = scene('shortcircuit-' + step)
    backend = backend_for(env, fail_at=step)
    outcome = run(env)
    assert isinstance(outcome, policy_mod.TransitionRefused), (step, outcome)
    order = names(backend)
    assert 'execve' not in order, (step, order)
    for later in sequence[sequence.index(step) + 1:]:
        assert later not in order, (step, later, order)
print('OK')
"

run_case "an unquotaed transition does not exist" "${PRELUDE}
env = scene('quota-failure')
backend = backend_for(env)
outcome = run(env, quota=Quota(error=OSError(1, 'operation not permitted')))
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'setuid' not in names(backend), names(backend)
assert 'execve' not in names(backend), names(backend)
env = scene('quota-project')
outcome = run(env, quota=Quota(project=1_000_999))
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
print('OK')
"

run_case "the transition refuses unless it observes root" "${PRELUDE}
env = scene('not-root')
backend = backend_for(env)
outcome = run(env, root=False)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'execve' not in names(backend), names(backend)
print('OK')
"

# ===========================================================================
# The five-element worker argv
# ===========================================================================

run_case "execve receives exactly the five governed argv elements" "${PRELUDE}
env = scene('argv')
backend = backend_for(env)
assert run(env) == 'executed'
_, path, argv, environment = [c for c in backend.calls if c[0] == 'execve'][0]
assert path == '/usr/bin/python3', path
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-worker.py',
                'CINV-000042', 'CIMP-000001', env.profile_digest), argv
assert len(argv) == 5, argv
# The environment stays closed and carries none of the governed values.
assert dict(environment) == {'HOME': '/data/kyri/capability',
                             'XDG_RUNTIME_DIR': '/run/user/999'}, environment
for name, value in environment:
    assert 'CIMP' not in value and env.profile_digest not in value, (name, value)
    assert value != str(policy_mod.PROFILE_FD), (name, value)
print('OK')
"

run_case "the worker argv is built by policy from the authenticated record" "${PRELUDE}
env = scene('argv-policy')
launch = authenticated(env)
argv = policy_mod.worker_argv(launch)
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-worker.py',
                'CINV-000042', 'CIMP-000001', env.profile_digest), argv
for stand_in in (None, 'CINV-000042', {'cinv': 'CINV-000042'}, 42):
    try:
        policy_mod.worker_argv(stand_in)
    except policy_mod.TransitionRefused:
        continue
    raise AssertionError('argv was built from an unauthenticated value')
print('OK')
"

# ===========================================================================
# Root opacity
# ===========================================================================

run_case "root parses no execution profile and inspects no execution field" "${PRELUDE}
import ast

def code_only(path):
    '''The source with docstrings removed.

    Code, not prose: both files explain at length why root stays opaque, and a
    scan that cannot tell an explanation from a call would forbid the
    explanation rather than the behaviour.
    '''
    tree = ast.parse(open(path, encoding='utf-8').read())
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
    return ast.unparse(tree), tree

code, tree = code_only('provisioning/execution/kyri-exec-transition-action.py')
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        rendered = ast.unparse(node)
        for banned in ('tools', 'canonical_json', 'profile', 'json'):
            assert banned not in rendered, rendered
for banned in ('ExecutionProfile', 'oci_image_id', 'canonical_profile',
               'fingerprint', 'mounts', 'tmpfs', 'network', 'pids_limit',
               'create_argv', 'podman', 'Podman'):
    assert banned not in code, banned
policy_code, _ = code_only('provisioning/execution/kyri-exec-transition.py')
for banned in ('ExecutionProfile', 'oci_image_id', 'canonical_profile',
               'mounts', 'network', 'pids_limit'):
    assert banned not in policy_code, banned
print('OK')
"

run_case "the privileged layer treats the profile as opaque bytes end to end" "${PRELUDE}
import inspect
source = inspect.getsource(action)
# The only things done to the bytes: read, hash, compare, copy, seal.
assert 'sha256' in source
assert 'decode' not in source, 'the transition decodes the profile'
assert 'loads' not in source, 'the transition parses the profile'
env = scene('opaque')
backend = backend_for(env)
launch = action.authenticate_launch(env.policy, backend=backend)
data = action.authenticate_profile_source(env.policy, launch, backend=backend)
assert isinstance(data, bytes), type(data)
print('OK')
"

# ===========================================================================
# The worker side
# ===========================================================================

WORKER_PRELUDE="
import fcntl, hashlib, importlib.util, os, stat, sys, types

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

entry = load('kyri_exec_worker', 'provisioning/execution/kyri-exec-worker.py')

from tools.capability.execution import worker as W
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.profile import (
    ProfileBinding, build_profile, canonical_profile, fingerprint,
    parse_canonical_profile, ProfileError)

def admission(cimp='CIMP-000001', image=None):
    return Admission(
        cimp=cimp, oci_image_id=image if image else 'a' * 64,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=1,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)

def governed_profile(cinv='CINV-000042', cimp='CIMP-000001', image=None):
    return build_profile(ProfileBinding(cinv=cinv,
                                        admission=admission(cimp, image)))

def sealed(body, seals=None):
    '''A sealed anonymous object holding exactly body, as root would hand it.'''
    handle = os.memfd_create('kyri-exec-profile',
                             os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    written = 0
    while written < len(body):
        written += os.write(handle, body[written:])
    os.lseek(handle, 0, os.SEEK_SET)
    wanted = W.REQUIRED_SEALS if seals is None else seals
    if wanted:
        fcntl.fcntl(handle, fcntl.F_ADD_SEALS, wanted)
    return handle
"

run_case "the worker library requires the mandatory seals on the profile descriptor" "${WORKER_PRELUDE}
assert W.PROFILE_FD == 3, W.PROFILE_FD
assert W.REQUIRED_SEALS == 0xF, hex(W.REQUIRED_SEALS)
profile = governed_profile()
body = canonical_profile(profile)
digest = fingerprint(profile).profile_digest
handle = sealed(body)
context = W.require_launch_context(cinv='CINV-000042', cimp='CIMP-000001',
                                   profile_digest=digest)
verified = W.profile_from_descriptor(context, descriptor=handle)
assert verified.cinv == 'CINV-000042'
assert verified.cimp == 'CIMP-000001'
assert verified.oci_image_id == 'a' * 64
assert canonical_profile(verified) == body
os.close(handle)
print('OK')
"

run_case "an unsealed, partially sealed, or wrong-typed descriptor is refused" "${WORKER_PRELUDE}
profile = governed_profile()
body = canonical_profile(profile)
digest = fingerprint(profile).profile_digest
context = W.require_launch_context(cinv='CINV-000042', cimp='CIMP-000001',
                                   profile_digest=digest)
cases = []
cases.append(('unsealed', sealed(body, seals=0)))
cases.append(('write-only', sealed(body, seals=0x8)))
cases.append(('no-seal-seal', sealed(body, seals=0x8 | 0x4 | 0x2)))
path = os.path.join(os.environ['WORKDIR'], 'ordinary-profile')
with open(path, 'wb') as handle:
    handle.write(body)
cases.append(('ordinary file', os.open(path, os.O_RDONLY)))
reader, writer = os.pipe()
os.write(writer, body)
cases.append(('pipe', reader))
import socket as socket_module
left, right = socket_module.socketpair()
cases.append(('socket', left.fileno()))
for label, handle in cases:
    try:
        W.profile_from_descriptor(context, descriptor=handle)
    except W.WorkerRefused:
        continue
    raise AssertionError('accepted a ' + label + ' as the profile descriptor')
try:
    W.profile_from_descriptor(context, descriptor=4096)
except W.WorkerRefused:
    pass
else:
    raise AssertionError('accepted a missing descriptor')
print('OK')
"

run_case "the worker binds the profile to the argv CINV, CIMP, and digest" "${WORKER_PRELUDE}
profile = governed_profile()
body = canonical_profile(profile)
digest = fingerprint(profile).profile_digest
# Every substitution the threat matrix names, each against a genuine sealed
# object so the refusal comes from the binding rather than from the transport.
substitutions = [
    ('launch CIMP A / profile CIMP B',
     dict(cimp='CIMP-000002'), body, digest),
    ('launch CINV A / profile CINV B',
     dict(cinv='CINV-000043'), body, digest),
    ('bytes changed, old digest', dict(),
     canonical_profile(governed_profile(image='c' * 64)), digest),
    ('digest changed, old bytes', dict(profile_digest='d' * 64), body, 'd' * 64),
    ('image substituted', dict(),
     canonical_profile(governed_profile(image='e' * 64)), digest),
]
for label, overrides, published, argv_digest in substitutions:
    fields = dict(cinv='CINV-000042', cimp='CIMP-000001',
                  profile_digest=argv_digest)
    fields.update(overrides)
    context = W.require_launch_context(**fields)
    handle = sealed(published)
    try:
        W.profile_from_descriptor(context, descriptor=handle)
    except W.WorkerRefused:
        os.close(handle)
        continue
    raise AssertionError('accepted ' + label)
print('OK')
"

run_case "a non-canonical, malformed, or wrongly-shaped profile is refused" "${WORKER_PRELUDE}
profile = governed_profile()
body = canonical_profile(profile)
digest = fingerprint(profile).profile_digest
bad = [
    b' ' + body,
    body + b'\n',
    body.replace(b'{', b'{ ', 1),
    b'{}',
    b'not json',
    b'[]',
    body[:-1],
]
for candidate in bad:
    context = W.require_launch_context(
        cinv='CINV-000042', cimp='CIMP-000001',
        profile_digest=hashlib.sha256(candidate).hexdigest())
    handle = sealed(candidate)
    try:
        W.profile_from_descriptor(context, descriptor=handle)
    except W.WorkerRefused:
        os.close(handle)
        continue
    raise AssertionError('accepted a non-canonical profile: ' + repr(candidate[:32]))
print('OK')
"

run_case "the canonical decoder round-trips the governed profile exactly" "${WORKER_PRELUDE}
import dataclasses
profile = governed_profile()
body = canonical_profile(profile)
decoded = parse_canonical_profile(body)
# The canonical form sorts exactly the collections whose order carries no
# meaning, so the decoded profile carries that order rather than the order it
# was built in. Identity is the bytes and the fingerprint; everything else is
# compared field by field, with those collections compared as the sets they are.
assert canonical_profile(decoded) == body
assert fingerprint(decoded) == fingerprint(profile)
unordered = {'tmpfs_options', 'dropped_capabilities', 'devices', 'sockets',
             'mounts'}
for field in dataclasses.fields(profile):
    seen = getattr(decoded, field.name)
    expected = getattr(profile, field.name)
    if field.name in unordered:
        assert sorted(seen, key=repr) == sorted(expected, key=repr), field.name
    else:
        assert seen == expected, field.name
for mangled in (body.replace(b'\"gpu\":false', b'\"gpu\":true'),
                body.replace(b'\"schema\":1', b'\"schema\":2')):
    try:
        decoded = parse_canonical_profile(mangled)
    except ProfileError:
        continue
    # A field change that stays canonical must still decode to a different
    # profile, never silently to the original one.
    assert canonical_profile(decoded) == mangled
print('OK')
"

run_case "the worker entrypoint takes exactly five argv elements" "${WORKER_PRELUDE}
import inspect
assert list(inspect.signature(entry.main).parameters) == ['argv']
digest = 'a' * 64
bad = [
    [],
    ['x'],
    ['x', 'CINV-000001'],
    ['x', 'CINV-000001', 'CIMP-000001'],
    ['x', 'CINV-000001', 'CIMP-000001', digest, 'extra'],
    ['x', 'cinv-000001', 'CIMP-000001', digest],
    ['x', 'CINV-00001', 'CIMP-000001', digest],
    ['x', 'CINV-000001', 'CIMP-00001', digest],
    ['x', 'CINV-000001', 'CIMP-000000', digest],
    ['x', 'CINV-000001', 'CIMP-000001', digest.upper()],
    ['x', 'CINV-000001', 'CIMP-000001', 'sha256:' + digest],
    ['x', 'CINV-000001', 'CIMP-000001', 'a' * 63],
    ['x', 'CINV-000001', 'CIMP-000001', 'a' * 65],
    ['x', 'CINV-000001', 'CIMP-000001', 'g' * 64],
    ['x', 'CINV-000001', 'CIMP-000001', ''],
]
for argv in bad:
    try:
        entry.main(argv)
    except SystemExit:
        continue
    raise AssertionError('accepted argv ' + repr(argv))
print('OK')
"

run_case "the worker entrypoint validates before it touches any descriptor" "${WORKER_PRELUDE}
import ast
tree = ast.parse(open('provisioning/execution/kyri-exec-worker.py',
                      encoding='utf-8').read())
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
            and body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        del body[0]
ast.fix_missing_locations(tree)
code = ast.unparse(tree)
for token in ('podman', 'Podman', 'create_argv', 'oci_image_id', '--mount',
              'subprocess'):
    assert token not in code, token
assert 'PROFILE_FD' in code, 'the entrypoint does not name the governed descriptor'
# The legacy three-element form is gone, not merely tolerated.
assert 'profile_digest' in code, code[:200]
main = [n for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef) and n.name == 'main'][0]
rendered = ast.unparse(main)
assert rendered.index('require_launch_context') \\
    < rendered.index('profile_from_descriptor'), rendered
assert rendered.index('require_worker_identity') \\
    < rendered.index('profile_from_descriptor'), rendered
print('OK')
"

run_case "the worker reads the profile from the descriptor and never from a path" "${WORKER_PRELUDE}
import inspect
source = inspect.getsource(W)
consume = inspect.getsource(W.profile_from_descriptor)
for banned in ('capability-handoff/', 'PROFILE_NAME', 'launch-authorisation',
               'open(', 'proc/self/fd'):
    assert banned not in consume, banned
assert 'pread' in consume, 'the profile read depends on the inherited offset'
print('OK')
"

run_case "the worker refuses a profile whose recomputed fingerprint disagrees" "${WORKER_PRELUDE}
profile = governed_profile()
body = canonical_profile(profile)
digest = fingerprint(profile).profile_digest
context = W.require_launch_context(cinv='CINV-000042', cimp='CIMP-000001',
                                   profile_digest=digest)
handle = sealed(body)
verified = W.profile_from_descriptor(context, descriptor=handle)
assert fingerprint(verified).profile_digest == digest
os.close(handle)
# One byte of the sealed object cannot be changed, so the disagreement has to
# be manufactured on the argv side: the digest is the authority either way.
context = W.require_launch_context(cinv='CINV-000042', cimp='CIMP-000001',
                                   profile_digest=hashlib.sha256(body + b' ').hexdigest())
handle = sealed(body)
try:
    W.profile_from_descriptor(context, descriptor=handle)
except W.WorkerRefused:
    print('OK')
else:
    raise AssertionError('the worker accepted a profile the digest disowns')
"

# ===========================================================================
# The suite itself
# ===========================================================================

run_case "the suite runs unprivileged and mutates no production object" "${PRELUDE}
import json
assert os.getuid() != 0, 'these tests must not run as root'
assert os.getuid() != 999, 'these tests must not run as the execution identity'
with open('${PRODUCTION_BEFORE}', encoding='utf-8') as handle:
    before = json.load(handle)
assert before, 'the production baseline is empty'
for path, recorded in sorted(before.items()):
    try:
        info = os.lstat(path)
        current = [info.st_mode, info.st_uid, info.st_gid, info.st_size,
                   info.st_mtime_ns, info.st_ctime_ns]
    except FileNotFoundError:
        current = None
    assert current == recorded, path + ' changed while this suite ran'
assert not os.path.exists('/etc/sudoers.d/kyri-exec'), 'sudoers policy exists'
print('OK')
"

run_case "the suite runs in local validation and in CI" "${PRELUDE}
name = 'tests/test-capability-execution-profile-transport.sh'
validation = open('tools/dev/run-validation.sh', encoding='utf-8').read()
ci = open('.github/workflows/ci.yml', encoding='utf-8').read()
assert name in validation, 'local validation does not run the suite'
assert name in ci, 'ci does not run the suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution Pass 3B-ii sealed profile transport validation passed.\n'
else
  printf 'Capability execution Pass 3B-ii sealed profile transport validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
