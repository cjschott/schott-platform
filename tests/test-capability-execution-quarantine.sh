#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T15.
#
# T15 copies failed or untrusted output into forensic quarantine. It starts
# nothing and reconciles nothing: no Podman, no subprocess, no container. The
# administrative verbs that reach the two disposition operations belong to T17.
#
# QUARANTINED EVIDENCE IS PERMANENTLY UNTRUSTED. It cannot become a capability
# result, and nothing here can produce the type that would let it. The one
# direction that exists is output -> quarantine.
#
# THE RESERVATION IS THE ADMISSION. Sixteen mebibytes are reserved durably
# before a byte is copied, and the whole reservation is held until a terminal
# record commits. Actual usage never reduces it, because a reservation that
# shrank as it was consumed would let a second collection in on space the
# first one is still entitled to.
#
# ONE HOSTILE-TREE CONTRACT. Traversal reuses the T14 bounds through the same
# audited primitive, so quarantine sealing and normal collection cannot drift
# into two geometries. Reviewer ruling of 2026-08-12.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §15, §23
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T15

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
# The T15 backstop
# ===========================================================================
# Quarantine is the one execution component that writes. What it must not gain
# with that authority is the ability to delete, to grant, or to execute.

assert_quarantine_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/quarantine.py"

if not target.exists():
    print("quarantine.py is absent")
    raise SystemExit(0)

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "socket", "shutil", "signal", "ctypes",
    "runpy", "importlib", "http", "urllib", "requests", "asyncio", "podman",
    "docker", "pty", "shlex", "time", "datetime", "random", "tempfile",
}
# No deletion of any kind: v1 has no automatic deletion, and an escape hatch
# that could remove evidence would be the one that gets used by accident.
# No grant of any kind: the execution identity never gains write authority.
FORBIDDEN_CALLS = {
    "unlink", "remove", "rmdir", "removedirs", "rmtree", "truncate",
    "chmod", "chown", "fchmod", "fchown", "lchown", "symlink",
    "setuid", "setgid", "seteuid", "setegid", "setgroups", "umask",
    "system", "popen", "execv", "execve", "fork", "spawn", "kill",
    "now", "today", "monotonic", "sleep", "getenv", "putenv",
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

for token in ("podman", "Podman", "sudo", "O_TRUNC", "O_APPEND"):
    if token in source:
        findings.append(f"forbidden token: {token}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T15 cannot delete, grant, execute, escalate, or read an ambient clock"
  else
    fail "T15 backstop found: ${report}"
  fi
}

assert_quarantine_authority

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
    LOCKS_DIRECTORY, TRANSITIONS_DIRECTORY, _LockOrder)
from tools.capability.execution.types import Classification
from tools.capability.execution import collector as C
from tools.capability.execution import quarantine as Q

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
CINV = 'CINV-000001'

# A filesystem with room: one tebibyte total, half of it free.
TOTAL = 1024 ** 4
ROOMY = Q.FilesystemSpace(free_bytes=TOTAL // 2, total_bytes=TOTAL)


def space(free, total=TOTAL):
    return lambda: Q.FilesystemSpace(free_bytes=free, total_bytes=total)


def make(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for sub in ('root/mutations', 'root/state', 'root/' + TRANSITIONS_DIRECTORY,
                'root/' + LOCKS_DIRECTORY, 'root/' + Q.RESERVATIONS_DIRECTORY,
                'root/' + Q.RELEASES_DIRECTORY, 'store'):
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


def ready(name):
    base = make(name)
    return base, anchor(base, 'root'), anchor(base, 'store')


def output(base, files=(('result.json', b'{}'), ('log.txt', b'diagnostic'))):
    out = Path(base) / 'out'
    if out.is_dir():
        shutil.rmtree(out)
    out.mkdir(mode=0o700)
    for name, data in files:
        target = out / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(data)
    return out


def out_fd(out):
    return os.open(out, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)


def collect(root, store, reservation, out):
    handle = out_fd(out)
    try:
        return Q.collect(root, store, reservation, handle)
    finally:
        os.close(handle)


def refuses(action, classification, what):
    try:
        action()
    except Q.QuarantineError as error:
        assert error.classification is classification, (
            what + ': ' + str(error.classification))
        return error
    raise AssertionError(what + ': accepted instead of refused')
"

# --- admission and the physical reserve -------------------------------------

run_case "the physical reserve is 16 MiB plus the greater of 1 GiB and 5 percent" "${PRELUDE}
GIB = 1024 ** 3
# A small filesystem: 5 percent is under a gibibyte, so the floor governs.
assert Q.required_reserve(10 * GIB) == 16 * 1024 * 1024 + GIB, Q.required_reserve(10 * GIB)
# A large one: 5 percent governs instead.
assert Q.required_reserve(1024 * GIB) == 16 * 1024 * 1024 + (1024 * GIB) // 20, \\
    Q.required_reserve(1024 * GIB)
# The boundary between them is where 5 percent reaches a gibibyte.
assert Q.required_reserve(20 * GIB) == 16 * 1024 * 1024 + GIB
print('OK')
"

run_case "admission below the physical reserve is refused" "${PRELUDE}
base, root, store = ready('below')
reserve = Q.required_reserve(TOTAL)
# One byte short of what the reserve demands.
refuses(lambda: Q.admit(root, store, CINV, space=space(reserve - 1)),
        None, 'admitted below the physical reserve')
# Exactly enough is admitted.
reservation = Q.admit(root, store, CINV, space=space(reserve))
assert reservation.reserved_bytes == Q.RESERVATION_BYTES, reservation
print('OK')
"

run_case "admission subtracts outstanding reservations from physical free space" "${PRELUDE}
base, root, store = ready('outstanding')
reserve = Q.required_reserve(TOTAL)
Q.admit(root, store, CINV, space=space(reserve + Q.RESERVATION_BYTES))
assert Q.outstanding_reservations(root) == Q.RESERVATION_BYTES
# The same physical free space now admits nothing further: the first
# reservation is still entitled to its bytes even though none were written.
refuses(lambda: Q.admit(root, store, 'CINV-000002',
                        space=space(reserve + Q.RESERVATION_BYTES - 1)),
        None, 'admitted on space another reservation holds')
Q.admit(root, store, 'CINV-000002',
        space=space(reserve + 2 * Q.RESERVATION_BYTES))
assert Q.outstanding_reservations(root) == 2 * Q.RESERVATION_BYTES
print('OK')
"

run_case "admission rechecks physical free space on every attempt" "${PRELUDE}
base, root, store = ready('recheck')
reserve = Q.required_reserve(TOTAL)
seen = []

def shrinking():
    seen.append(len(seen))
    return Q.FilesystemSpace(free_bytes=reserve if not seen[:-1] else reserve - 1,
                             total_bytes=TOTAL)

Q.admit(root, store, CINV, space=shrinking)
refuses(lambda: Q.admit(root, store, 'CINV-000002', space=shrinking),
        None, 'admitted without rechecking free space')
assert len(seen) == 2, seen
print('OK')
"

run_case "a second admission for the same CINV is refused" "${PRELUDE}
base, root, store = ready('twice')
Q.admit(root, store, CINV, space=lambda: ROOMY)
refuses(lambda: Q.admit(root, store, CINV, space=lambda: ROOMY),
        None, 'admitted the same CINV twice')
print('OK')
"

run_case "admission refuses while another lock is held rather than choosing an order" "${PRELUDE}
from tools.capability.execution.state import LockOrderViolation
base, root, store = ready('locks')


def inverts(what):
    try:
        Q.admit(root, store, CINV, space=lambda: ROOMY)
    except LockOrderViolation:
        return
    raise AssertionError(what)


# Held by a different _LockOrder instance: the order rule is about the
# process, so an instance that only knows its own history is not enough.
locks = _LockOrder()
locks.acquire_capacity(root)
try:
    inverts('took the quarantine lock under the capacity lock')
finally:
    locks.release_all()
locks = _LockOrder()
locks.acquire_cinv(CINV, root)
try:
    inverts('took the quarantine lock under a CINV lock')
finally:
    locks.release_all()
# And the inversion is refused in the other direction too.
locks = _LockOrder()
locks.acquire_quarantine(root)
try:
    for take in (lambda: _LockOrder().acquire_capacity(root),
                 lambda: _LockOrder().acquire_cinv(CINV, root)):
        try:
            take()
        except LockOrderViolation:
            continue
        raise AssertionError('took another lock while quarantine was held')
finally:
    locks.release_all()
# With nothing held it proceeds.
Q.admit(root, store, CINV, space=lambda: ROOMY)
print('OK')
"

# --- collection -------------------------------------------------------------

run_case "collection copies the tree and holds the whole reservation" "${PRELUDE}
base, root, store = ready('collect')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
manifest = collect(root, store, reservation, output(base))
assert manifest.file_count == 2, manifest.file_count
paths = [entry.relative_path for entry in manifest.files]
assert paths == ['log.txt', 'result.json'], paths
copied = Path(base) / 'store' / CINV / Q.DATA_DIRECTORY / 'log.txt'
assert copied.read_bytes() == b'diagnostic'
# Usage never reduces the reservation incrementally.
assert Q.outstanding_reservations(root) == Q.RESERVATION_BYTES, \\
    Q.outstanding_reservations(root)
print('OK')
"

run_case "the reservation is held until the terminal record commits" "${PRELUDE}
base, root, store = ready('hold')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
manifest = collect(root, store, reservation, output(base))
assert Q.outstanding_reservations(root) == Q.RESERVATION_BYTES
Q.seal(root, store, reservation, manifest)
assert Q.outstanding_reservations(root) == 0, Q.outstanding_reservations(root)
assert Q.condition(store, CINV) == 'sealed', Q.condition(store, CINV)
print('OK')
"

run_case "quarantine directories and files are private to the coordinator" "${PRELUDE}
base, root, store = ready('modes')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
manifest = collect(root, store, reservation, output(base))
Q.seal(root, store, reservation, manifest)
namespace = Path(base) / 'store' / CINV
assert stat.S_IMODE(namespace.lstat().st_mode) == 0o700, oct(namespace.lstat().st_mode)
data = namespace / Q.DATA_DIRECTORY
assert stat.S_IMODE(data.lstat().st_mode) == 0o700
for entry in data.iterdir():
    assert stat.S_IMODE(entry.lstat().st_mode) == 0o600, entry
assert stat.S_IMODE((namespace / Q.MANIFEST_NAME).lstat().st_mode) == 0o600
print('OK')
"

run_case "a hostile output tree is refused and nothing is sealed" "${PRELUDE}
base, root, store = ready('hostile')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
out = output(base)
os.symlink('/etc/shadow', out / 'sneaky')
refuses(lambda: collect(root, store, reservation, out),
        Classification.QUARANTINE_COLLECTION_INCOMPLETE, 'collected a symlink')
assert Q.condition(store, CINV) != 'sealed', Q.condition(store, CINV)
print('OK')
"

run_case "collection refuses to resume, append, or overwrite" "${PRELUDE}
base, root, store = ready('once')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
manifest = collect(root, store, reservation, output(base))
refuses(lambda: collect(root, store, reservation, output(base)),
        None, 'collected into an existing namespace')
copied = Path(base) / 'store' / CINV / Q.DATA_DIRECTORY / 'log.txt'
assert copied.read_bytes() == b'diagnostic', 'the first collection was altered'
Q.seal(root, store, reservation, manifest)
refuses(lambda: Q.seal(root, store, reservation, manifest),
        None, 'sealed twice')
print('OK')
"

# --- the incomplete condition -----------------------------------------------

run_case "a namespace with no manifest is quarantine_collection_incomplete" "${PRELUDE}
base, root, store = ready('incomplete')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
collect(root, store, reservation, output(base))
# The crash: no seal ever happened.
assert Q.condition(store, CINV) == 'incomplete', Q.condition(store, CINV)
assert Q.outstanding_reservations(root) == Q.RESERVATION_BYTES, \\
    'the reservation was released without a terminal record'
print('OK')
"

run_case "retain-quarantine-incomplete seals a partial namespace within bounds" "${PRELUDE}
base, root, store = ready('seal-incomplete')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
collect(root, store, reservation, output(base))
manifest = Q.seal_incomplete(root, store, reservation)
assert manifest.file_count == 2, manifest.file_count
assert Q.condition(store, CINV) == 'sealed'
assert Q.outstanding_reservations(root) == 0
print('OK')
"

run_case "a partial namespace beyond the structural bounds cannot be sealed" "${PRELUDE}
GIB = 1024 ** 3
for label, plant in (
        ('symlink', lambda d: os.symlink('/etc/shadow', d / 'x')),
        ('fifo', lambda d: os.mkfifo(d / 'pipe')),
        ('depth', lambda d: (d / ('/'.join('n' * 17))).mkdir(parents=True)),
        ('files', lambda d: [(d / f'f{i}').write_bytes(b'x') for i in range(33)])):
    base, root, store = ready('bounds-' + label)
    reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
    collect(root, store, reservation, output(base))
    plant(Path(base) / 'store' / CINV / Q.DATA_DIRECTORY)
    refuses(lambda: Q.seal_incomplete(root, store, reservation),
            Classification.QUARANTINE_INCOMPLETE_INTEGRITY_FAILURE, label)
    assert Q.condition(store, CINV) == 'incomplete', label
    assert Q.outstanding_reservations(root) == Q.RESERVATION_BYTES, label
print('OK')
"

run_case "the structural bounds are exactly the T14 ones, shared not restated" "${PRELUDE}
assert Q.QUARANTINE_MAX_DEPTH is C.OUTPUT_TREE_MAX_DEPTH
assert Q.QUARANTINE_MAX_ENTRIES is C.OUTPUT_TREE_MAX_ENTRIES
assert Q.QUARANTINE_MAX_FILES is C.OUTPUT_MAXIMUM_FILES
assert Q.QUARANTINE_MAX_FILE_BYTES is C.OUTPUT_MAXIMUM_FILE_BYTES
assert Q.QUARANTINE_MAX_TOTAL_BYTES is C.OUTPUT_MAXIMUM_TOTAL_BYTES
assert Q.QUARANTINE_MAX_DEPTH == 16 and Q.QUARANTINE_MAX_ENTRIES == 256
import inspect
source = inspect.getsource(Q)
assert 'walk_tree' in source, 'quarantine does not reuse the audited primitive'
print('OK')
"

# --- residue ----------------------------------------------------------------

run_case "retain-quarantine-residue releases the reservation without a manifest" "${PRELUDE}
base, root, store = ready('residue')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
collect(root, store, reservation, output(base))
Q.retain_residue(root, store, reservation)
assert Q.condition(store, CINV) == 'residue', Q.condition(store, CINV)
assert Q.outstanding_reservations(root) == 0
assert not (Path(base) / 'store' / CINV / Q.MANIFEST_NAME).exists(), \\
    'residue produced a manifest'
# The bytes stay exactly where they were: no deletion authority anywhere.
assert (Path(base) / 'store' / CINV / Q.DATA_DIRECTORY / 'log.txt').exists()
print('OK')
"

run_case "residue is available where sealing was refused, and is terminal" "${PRELUDE}
base, root, store = ready('residue-after')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
collect(root, store, reservation, output(base))
os.mkfifo(Path(base) / 'store' / CINV / Q.DATA_DIRECTORY / 'pipe')
refuses(lambda: Q.seal_incomplete(root, store, reservation),
        Classification.QUARANTINE_INCOMPLETE_INTEGRITY_FAILURE, 'fifo')
# The operator's fallback still works on the tree that could not be sealed,
# and does not enumerate it.
Q.retain_residue(root, store, reservation)
assert Q.condition(store, CINV) == 'residue'
assert Q.outstanding_reservations(root) == 0
refuses(lambda: Q.seal_incomplete(root, store, reservation),
        None, 'sealed after residue')
refuses(lambda: Q.retain_residue(root, store, reservation),
        None, 'residue declared twice')
print('OK')
"

# --- evidence can never become a result -------------------------------------

run_case "quarantined evidence cannot become a capability result" "${PRELUDE}
import inspect
base, root, store = ready('never-result')
reservation = Q.admit(root, store, CINV, space=lambda: ROOMY)
manifest = collect(root, store, reservation, output(base))
Q.seal(root, store, reservation, manifest)
assert not isinstance(manifest, C.TrustedResult)
source = inspect.getsource(Q)
assert 'TrustedResult' not in source, 'quarantine can name the trusted type'
assert 'read_result' not in source, 'quarantine can reach result admission'
# A manifest is not an output tree and cannot be handed to result admission.
try:
    C.read_result(manifest, None)
except C.OutputRefused:
    pass
else:
    raise AssertionError('a quarantine manifest was admitted as a result')
print('OK')
"

run_case "no real Podman, container, or privilege was involved" "${PRELUDE}
import inspect
assert os.getuid() != 0
source = inspect.getsource(Q)
for token in ('subprocess', 'podman', 'setuid', 'sudo'):
    assert token not in source, token
print('OK')
"

run_case "the quarantine suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-quarantine.sh'
assert name in validation, 'local validation does not run the quarantine suite'
assert name in ci, 'ci does not run the quarantine suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T15 quarantine validation passed.\n'
else
  printf 'Capability execution T15 quarantine validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
