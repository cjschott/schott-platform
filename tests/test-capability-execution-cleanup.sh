#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T16.
#
# T16 removes the per-invocation handoff subtree, and recovers nothing by
# itself. No Podman, no subprocess, no container: every post-crash observation
# arrives from the administrative helper, which is T17 and gate G6.
#
# CLEANUP IS NARROW BY CONSTRUCTION. The only thing it can remove is the
# internally derived per-CINV subtree beneath a verified handoff root. No
# caller path reaches it, there is no recursive fallback rooted anywhere else,
# and the module cannot create, write, chmod, or chown at all -- deletion is
# the whole of its authority.
#
# AMBIGUITY FAILS CLOSED. A missing root, a substituted object, a bound
# exceeded, a type that changed under the walk: each is
# execution_cleanup_incomplete with the CINV consumed, its slot still held, and
# whatever remains preserved for retry-cleanup or retain-residue.
#
# THE BOUNDS ARE DELETION-WORK BOUNDS, NOT ACCEPTANCE BOUNDS. Depth 32 and
# 8,192 entries, deliberately larger than §11 and §15, because this is the
# component that meets residue which already broke those. Reviewer ruling of
# 2026-08-12.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §18, §19
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T16

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
export WORKDIR

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

# ===========================================================================
# The T16 backstop
# ===========================================================================
# This module deletes. That is the one authority it is given, and the scan
# below is what keeps it the only one: nothing here may create, write, grant,
# execute, or reach a clock -- and no recursive deletion helper may appear that
# takes a pathname.

assert_cleanup_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/cleanup.py"

if not target.exists():
    print("cleanup.py is absent")
    raise SystemExit(0)

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "socket", "shutil", "signal", "ctypes",
    "runpy", "importlib", "http", "urllib", "requests", "asyncio", "podman",
    "docker", "pty", "shlex", "time", "datetime", "random", "tempfile",
    "glob", "fnmatch",
}
# Deletion is the authority. Creation, mutation of mode or owner, privilege,
# and the ambient clock are not.
FORBIDDEN_CALLS = {
    "mkdir", "makedirs", "rename", "replace", "link", "symlink", "mknod",
    "mkfifo", "truncate", "chmod", "chown", "fchmod", "fchown", "lchown",
    "umask", "write", "setuid", "setgid", "seteuid", "setegid", "setgroups",
    "system", "popen", "execv", "execve", "fork", "spawn", "kill",
    "now", "today", "monotonic", "sleep", "getenv", "putenv", "rmtree",
}
FORBIDDEN_ATTRIBUTES = {"environ", "argv"}

findings = []
source = target.read_text(encoding="utf-8")
tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"forbidden import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {attr}")
    elif isinstance(node, ast.Attribute):
        if node.attr in FORBIDDEN_ATTRIBUTES:
            findings.append(f"forbidden attribute: {node.attr}")

for token in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND",
              "podman", "Podman", "sudo", "walk_tree"):
    if token in source:
        findings.append(f"forbidden token: {token}")

# Every removal must be relative to a descriptor. A bare os.unlink(path) or
# os.rmdir(path) is the recursive-fallback shape this design forbids.
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    name = getattr(node.func, "attr", None)
    if name in ("unlink", "rmdir"):
        if not any(keyword.arg == "dir_fd" for keyword in node.keywords):
            findings.append(f"{name}() at line {node.lineno} is not descriptor-relative")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T16 may delete descriptor-relatively and do nothing else"
  else
    fail "T16 backstop found: ${report}"
  fi
}

assert_cleanup_authority

# ===========================================================================
# Behaviour
# ===========================================================================

PRELUDE="
import os, shutil, stat
from pathlib import Path

from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.state import (
    LOCKS_DIRECTORY, TRANSITIONS_DIRECTORY, current_state, transition)
from tools.capability.execution.types import Classification, LifecycleState
from tools.capability.execution import quarantine as Q
from tools.capability.execution import cleanup as K

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
CINV = 'CINV-000001'


def make(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for sub in ('root/mutations', 'root/state', 'root/' + TRANSITIONS_DIRECTORY,
                'root/' + LOCKS_DIRECTORY, 'root/' + Q.RESERVATIONS_DIRECTORY,
                'root/' + Q.RELEASES_DIRECTORY, 'handoff'):
        os.makedirs(os.path.join(base, sub), mode=0o700)
    with open(os.path.join(base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
        handle.write(b'000000000000\n')
    return base


def anchor(base, which):
    cfg = os.open(os.path.join(base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(base, which), os.O_RDONLY | os.O_DIRECTORY)
    try:
        return verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)


def advance(root, cinv, target):
    from tools.capability.execution.state import open_state_locked
    open_state_locked(root, cinv)
    order = list(LifecycleState)
    for index in range(order.index(LifecycleState.RESERVED),
                       order.index(target)):
        transition(root, cinv, order[index], order[index + 1])


def ready(name, state=LifecycleState.COLLECTED, cinv=CINV):
    base = make(name)
    root = anchor(base, 'root')
    handoff = anchor(base, 'handoff')
    advance(root, cinv, state)
    return base, root, handoff


def publish(base, cinv=CINV, files=(('package/entry.py', b'print(1)'),
                                    ('payload', b'{}'),
                                    ('out/result.json', b'{}'))):
    tree = Path(base) / 'handoff' / cinv
    tree.mkdir(mode=0o755)
    for name, data in files:
        target = tree / name
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        target.write_bytes(data)
    return tree


def refuses(action, classification, what):
    try:
        action()
    except K.CleanupError as error:
        assert error.classification is classification, (
            what + ': ' + str(error.classification))
        return error
    raise AssertionError(what + ': accepted instead of refused')
"

# --- the accepted path ------------------------------------------------------

run_case "cleanup removes exactly the per-CINV subtree and records cleaned" "${PRELUDE}
base, root, handoff = ready('accepted')
tree = publish(base)
sibling = Path(base) / 'handoff' / 'CINV-000002'
sibling.mkdir(mode=0o755)
(sibling / 'keep.txt').write_bytes(b'not mine')

K.cleanup(root, handoff, CINV)

assert not tree.exists(), 'the per-CINV subtree survived'
assert sibling.exists() and (sibling / 'keep.txt').exists(), \\
    'cleanup reached outside its own subtree'
assert current_state(root, CINV) is LifecycleState.CLEANED, current_state(root, CINV)
print('OK')
"

run_case "cleanup removes children before their parents" "${PRELUDE}
base, root, handoff = ready('postorder')
publish(base, files=(('a/b/c/deep.txt', b'x'), ('a/b/other.txt', b'y'),
                     ('payload', b'{}')))
K.cleanup(root, handoff, CINV)
assert not (Path(base) / 'handoff' / CINV).exists()
# A parent removed before its children would have raised ENOTEMPTY, so
# reaching here at all is the ordering proof; the state record confirms it
# completed rather than merely not raising.
assert current_state(root, CINV) is LifecycleState.CLEANED
print('OK')
"

run_case "cleanup releases no capacity of its own" "${PRELUDE}
base, root, handoff = ready('slot')
publish(base)
K.cleanup(root, handoff, CINV)
assert current_state(root, CINV) is LifecycleState.CLEANED, \\
    'cleanup advanced past cleaned'
print('OK')
"

# --- the evidence precondition ----------------------------------------------

run_case "cleanup refuses before the evidence is durable" "${PRELUDE}
for state in (LifecycleState.RESERVED, LifecycleState.RUNNING,
              LifecycleState.TERMINAL, LifecycleState.CLASSIFIED):
    base, root, handoff = ready('early-' + state.value, state=state)
    tree = publish(base)
    refuses(lambda: K.cleanup(root, handoff, CINV), None,
            'cleanup ran before evidence was durable (' + state.value + ')')
    assert tree.exists(), 'a refused cleanup deleted something anyway'
    assert current_state(root, CINV) is state
print('OK')
"

run_case "cleanup refuses to run twice" "${PRELUDE}
base, root, handoff = ready('twice')
publish(base)
K.cleanup(root, handoff, CINV)
refuses(lambda: K.cleanup(root, handoff, CINV), None, 'cleaned twice')
print('OK')
"

# --- ambiguity fails closed --------------------------------------------------

run_case "a missing handoff root is incomplete, never quiet success" "${PRELUDE}
base, root, handoff = ready('missing')
# No handoff published at all.
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, 'absent root')
assert current_state(root, CINV) is LifecycleState.COLLECTED, \\
    'the slot was advanced despite an uncertain cleanup'
print('OK')
"

run_case "a handoff root that is not a directory is incomplete" "${PRELUDE}
base, root, handoff = ready('notdir')
(Path(base) / 'handoff' / CINV).write_bytes(b'not a directory')
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, 'root is a file')
assert current_state(root, CINV) is LifecycleState.COLLECTED
print('OK')
"

run_case "a symlinked handoff root is refused rather than followed" "${PRELUDE}
base, root, handoff = ready('symroot')
outside = Path(base) / 'outside'
outside.mkdir(mode=0o755)
(outside / 'precious.txt').write_bytes(b'keep me')
os.symlink(str(outside), str(Path(base) / 'handoff' / CINV))
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, 'symlinked root')
assert (outside / 'precious.txt').exists(), 'cleanup followed a symlinked root'
assert current_state(root, CINV) is LifecycleState.COLLECTED
print('OK')
"

run_case "a symlink inside the subtree is unlinked, never traversed" "${PRELUDE}
base, root, handoff = ready('symchild')
tree = publish(base)
outside = Path(base) / 'outside'
outside.mkdir(mode=0o755)
(outside / 'precious.txt').write_bytes(b'keep me')
os.symlink(str(outside), str(tree / 'out' / 'escape'))
os.symlink('/etc/hostname', str(tree / 'out' / 'absolute'))
K.cleanup(root, handoff, CINV)
assert not tree.exists(), 'the subtree survived'
assert (outside / 'precious.txt').exists(), 'cleanup deleted through a symlink'
assert outside.exists(), 'cleanup removed a directory outside its subtree'
assert Path('/etc/hostname').exists()
print('OK')
"

run_case "FIFOs and sockets inside the subtree are unlinked, not refused" "${PRELUDE}
import socket
base, root, handoff = ready('special')
tree = publish(base)
os.mkfifo(tree / 'out' / 'pipe')
bound = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    bound.bind(str(tree / 'out' / 'sock'))
finally:
    bound.close()
K.cleanup(root, handoff, CINV)
assert not tree.exists(), 'a hostile but removable object stopped cleanup'
assert current_state(root, CINV) is LifecycleState.CLEANED
print('OK')
"

run_case "a directory substituted between the look and the open is incomplete" "${PRELUDE}
import tools.capability.execution.cleanup as module


class Racing:
    'The real os, with the first stat disturbing the tree afterwards.'

    def __init__(self, real, hook):
        self._real = real
        self._hook = hook
        self._fired = False

    def __getattr__(self, name):
        real = getattr(self._real, name)
        if name != 'stat' or self._fired:
            return real

        def wrapped(*arguments, **keywords):
            outcome = real(*arguments, **keywords)
            if not self._fired:
                self._fired = True
                self._hook(*arguments, **keywords)
            return outcome

        return wrapped


base, root, handoff = ready('substituted')
tree = publish(base, files=(('out/keep.txt', b'x'),))
outside = Path(base) / 'outside'
outside.mkdir(mode=0o755)
(outside / 'precious.txt').write_bytes(b'keep me')


def swap(name, dir_fd=None, **ignored):
    os.unlink('keep.txt', dir_fd=os.open(str(tree / 'out'), os.O_RDONLY | os.O_DIRECTORY))
    os.rmdir(name, dir_fd=dir_fd)
    os.symlink(str(outside), name, dir_fd=dir_fd)


real_os = module.os
module.os = Racing(real_os, swap)
try:
    refuses(lambda: K.cleanup(root, handoff, CINV),
            Classification.EXECUTION_CLEANUP_INCOMPLETE, 'substituted directory')
finally:
    module.os = real_os
assert (outside / 'precious.txt').exists(), 'cleanup deleted through a substitution'
assert current_state(root, CINV) is LifecycleState.COLLECTED
print('OK')
"

# --- the deletion-work bounds ------------------------------------------------

run_case "the deletion-work bounds are 32 and 8192, larger than acceptance" "${PRELUDE}
from tools.capability.execution import collector as C
assert K.CLEANUP_MAX_DEPTH == 32, K.CLEANUP_MAX_DEPTH
assert K.CLEANUP_MAX_ENTRIES == 8192, K.CLEANUP_MAX_ENTRIES
assert K.CLEANUP_MAX_DEPTH > C.OUTPUT_TREE_MAX_DEPTH
assert K.CLEANUP_MAX_ENTRIES > C.OUTPUT_TREE_MAX_ENTRIES
print('OK')
"

run_case "a subtree deeper than 32 is incomplete and stops deleting" "${PRELUDE}
base, root, handoff = ready('deep')
tree = publish(base, files=(('payload', b'{}'),))
deep = tree / 'out'
deep.mkdir(mode=0o755, parents=True)
for level in range(33):
    deep = deep / 'd'
deep.mkdir(mode=0o755, parents=True)
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, 'depth 33')
assert tree.exists(), 'the residue was not preserved'
assert current_state(root, CINV) is LifecycleState.COLLECTED, \\
    'the slot was released despite an incomplete cleanup'
print('OK')
"

run_case "a subtree at exactly depth 32 is removed" "${PRELUDE}
base, root, handoff = ready('deep-ok')
tree = publish(base, files=(('payload', b'{}'),))
deep = tree
for level in range(32):
    deep = deep / 'd'
deep.mkdir(mode=0o755, parents=True)
K.cleanup(root, handoff, CINV)
assert not tree.exists()
print('OK')
"

run_case "more than 8192 entries is incomplete and stops deleting" "${PRELUDE}
base, root, handoff = ready('wide')
tree = publish(base, files=(('payload', b'{}'),))
out = tree / 'out'
out.mkdir(mode=0o755, parents=True)
for index in range(8193):
    (out / ('f%05d' % index)).write_bytes(b'')
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, '8193 entries')
assert tree.exists(), 'the residue was not preserved'
assert current_state(root, CINV) is LifecycleState.COLLECTED
print('OK')
"

run_case "cleanup is idempotent over its own subtree after a bounded stop" "${PRELUDE}
base, root, handoff = ready('idempotent')
tree = publish(base, files=(('payload', b'{}'),))
out = tree / 'out'
out.mkdir(mode=0o755, parents=True)
for index in range(8193):
    (out / ('f%05d' % index)).write_bytes(b'')
refuses(lambda: K.cleanup(root, handoff, CINV),
        Classification.EXECUTION_CLEANUP_INCOMPLETE, 'first attempt')
# retry-cleanup runs the same algorithm with no broader authority. Once the
# residue is inside the bound it completes; nothing widened to make it so.
survivors = sorted(p for p in out.iterdir())
for path in survivors[:8193 - 8000]:
    path.unlink()
K.cleanup(root, handoff, CINV)
assert not tree.exists()
assert current_state(root, CINV) is LifecycleState.CLEANED
print('OK')
"

# --- no caller path, no broader authority ------------------------------------

run_case "no caller-supplied path reaches cleanup" "${PRELUDE}
import inspect
base, root, handoff = ready('paths')
publish(base)
names = list(inspect.signature(K.cleanup).parameters)
assert names == ['root', 'handoff', 'cinv'], names
for supplied in (str(Path(base) / 'handoff'), Path(base) / 'handoff', None, 3):
    refuses(lambda s=supplied: K.cleanup(root, s, CINV), None,
            'accepted a handoff root that was not verified')
for bad in ('../../etc', '/etc', 'CINV-00000', 'CINV-0000001', '', None):
    try:
        K.cleanup(root, handoff, bad)
    except Exception:
        pass
    else:
        raise AssertionError('accepted a CINV of ' + repr(bad))
assert (Path(base) / 'handoff' / CINV).exists()
print('OK')
"

run_case "cleanup never touches quarantine or execution state" "${PRELUDE}
import inspect
source = inspect.getsource(K)
assert 'import quarantine' not in source, 'cleanup reaches the quarantine plane'
assert 'from .quarantine' not in source, 'cleanup reaches the quarantine plane'
base, root, handoff = ready('planes')
publish(base)
before = sorted(p.name for p in (Path(base) / 'root').rglob('*'))
K.cleanup(root, handoff, CINV)
after = sorted(p.name for p in (Path(base) / 'root').rglob('*'))
# Cleanup commits its own transition record, and removes nothing.
assert set(before) <= set(after), 'cleanup removed durable authority state'
print('OK')
"

# --- recovery is admin-mediated ---------------------------------------------

run_case "recovery reports findings and performs no action" "${PRELUDE}
base, root, handoff = ready('recover', state=LifecycleState.LAUNCH_AUTHORIZED)
tree = publish(base)
findings = K.recover(root)
assert isinstance(findings, tuple), type(findings)
found = [f for f in findings if f.cinv == CINV]
assert len(found) == 1, findings
assert found[0].state is LifecycleState.LAUNCH_AUTHORIZED
assert tree.exists(), 'recovery deleted something'
assert current_state(root, CINV) is LifecycleState.LAUNCH_AUTHORIZED, \\
    'recovery advanced the lifecycle by itself'
print('OK')
"

run_case "every §18 row produces its specified classification" "${PRELUDE}
rows = (
    (LifecycleState.LAUNCH_AUTHORIZED,
     K.Observation(container_present=False),
     Classification.EXECUTION_STATE_LOST, 'acknowledge-state-lost'),
    (LifecycleState.LAUNCH_AUTHORIZED,
     K.Observation(container_present=True, candidate_matches=True),
     None, None),
    (LifecycleState.LAUNCH_AUTHORIZED,
     K.Observation(container_present=True, candidate_matches=False),
     Classification.EXECUTION_IDENTITY_MISMATCH, 'retain'),
    (LifecycleState.LAUNCH_AUTHORIZED,
     K.Observation(container_present=True, ambiguous=True),
     Classification.EXECUTION_IDENTITY_MISMATCH, 'retain'),
    (LifecycleState.START_AUTHORIZED,
     K.Observation(container_present=True, runtime_state='created'),
     Classification.EXECUTION_START_OUTCOME_UNKNOWN, 'retain-start-unknown'),
    (LifecycleState.START_AUTHORIZED,
     K.Observation(container_present=True, runtime_state='running'),
     Classification.START_RECONCILED_RUNNING, None),
    (LifecycleState.START_AUTHORIZED,
     K.Observation(container_present=True, runtime_state='exited',
                   started_proven=True),
     Classification.START_RECONCILED_TERMINAL, None),
    (LifecycleState.RUNNING,
     K.Observation(container_present=True, contradictory=True),
     Classification.EXECUTION_LIFECYCLE_INTEGRITY_FAILURE,
     'retain-lifecycle-failure'),
    (LifecycleState.RUNNING,
     K.Observation(container_present=False),
     Classification.EXECUTION_STATE_LOST, 'acknowledge-state-lost'),
    (LifecycleState.RUNNING,
     K.Observation(container_present=False, mutation_freeze=True),
     Classification.EXECUTION_STATE_LOST_DURING_MUTATION_FREEZE,
     'acknowledge-state-lost'),
)
for state, observation, classification, disposition in rows:
    finding = K.classify_recovery(CINV, state, observation)
    assert finding.classification is classification, (
        state.value, finding.classification)
    if disposition is not None:
        assert finding.disposition == disposition, (state.value, finding.disposition)
print('OK')
"

run_case "recovery refuses a cached observation and never retries" "${PRELUDE}
import inspect
base, root, handoff = ready('nocache', state=LifecycleState.START_AUTHORIZED)
# An observation is a value the caller supplies at the moment it asks. Nothing
# here reads one from disk, and nothing stores one.
source = inspect.getsource(K)
for token in ('retry', 'attempt_again', 're_execute'):
    assert 'automatic ' + token not in source, token
finding = K.classify_recovery(CINV, LifecycleState.START_AUTHORIZED, None)
assert finding.requires_observation is True, finding
assert finding.classification is None, finding
assert finding.disposition is None
print('OK')
"

run_case "no real Podman, container, or privilege was involved" "${PRELUDE}
import inspect
assert os.getuid() != 0
source = inspect.getsource(K)
for token in ('subprocess', 'podman', 'setuid', 'sudo'):
    assert token not in source, token
print('OK')
"

run_case "the cleanup suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-cleanup.sh'
assert name in validation, 'local validation does not run the cleanup suite'
assert name in ci, 'ci does not run the cleanup suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T16 cleanup validation passed.\n'
else
  printf 'Capability execution T16 cleanup validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
