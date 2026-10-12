#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 offline implementation-authority bootstrap
# primitives: the CIMP and CGEN counters, the lifecycle mutation lock, and the
# genesis ceremony.
#
# OFFLINE AND HERMETIC. Every root here is a temporary directory. The two
# production authority roots beneath /var/lib/kyri are never created, written,
# or removed — the last case asserts their absence — and no image is built, no
# CIMP is admitted, and no gate opens. G1, G3, G5, G6, G7 stay closed.
#                                                        # prod-path-reference
#
# THESE PRIMITIVES ARE OPERATOR TOOLING. They live outside the installed
# runtime library on purpose: the coordinator reads published authority and
# never writes it, the worker holds none of it, and the root transition helper
# understands one launch record and nothing else. This suite proves the
# boundary as well as the behaviour.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §5, §5.1-§5.7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/provisioning/authority_bootstrap.py"

# ===========================================================================
# The operator-only boundary
# ===========================================================================
# The bootstrap primitives allocate identifiers and publish authority. Nothing
# on the execution path may reach them, and they must carry no production path.

assert_offline_only() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
module = root / "tools/provisioning/authority_bootstrap.py"
runtime = [
    root / "tools/capability/execution/worker.py",
    root / "tools/capability/execution/lifecycle.py",
    root / "tools/capability/execution/adapter.py",
    root / "tools/capability/execution/implementation_authority.py",
    root / "tools/capability/coordinator.py",
    root / "provisioning/execution/kyri-exec-transition.py",
    root / "provisioning/execution/kyri-exec-transition-action.py",
    root / "provisioning/execution/kyri-exec-worker.py",
    root / "provisioning/execution/kyri-exec-transition-entrypoint.py",
]

findings = []
if not module.is_file():
    print("module-absent")
    raise SystemExit(0)

# No runtime module may import the bootstrap primitives.
for target in runtime:
    if not target.is_file():
        continue
    source = target.read_text(encoding="utf-8")
    if "authority_bootstrap" in source or "tools.provisioning" in source:
        findings.append(f"{target.relative_to(root)}: imports offline bootstrap")

# The absolute production mapping belongs to operator integration, never code.
text = module.read_text(encoding="utf-8")
tree = ast.parse(text)
for node in ast.walk(tree):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        if node.value.startswith("/"):
            findings.append(f"absolute path literal: {node.value!r}")

# The allocator must never derive an identifier by looking at the namespace.
# Scoped to the allocation path rather than the module: genesis legitimately
# enumerates to prove a directory is empty, which is a different question from
# "what number comes next".
ALLOCATORS = {"_advance", "_read_counter", "allocate_cimp", "allocate_cgen"}
for node in ast.walk(tree):
    if not isinstance(node, ast.FunctionDef) or node.name not in ALLOCATORS:
        continue
    for inner in ast.walk(node):
        if isinstance(inner, ast.Call):
            attr = (getattr(inner.func, "attr", None)
                    or getattr(inner.func, "id", None))
            if attr in ("scandir", "listdir", "walk", "glob"):
                findings.append(
                    f"{node.name} scans the namespace to allocate: {attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "bootstrap is operator-only, path-free, and never scans to allocate"
  else
    fail "bootstrap boundary: ${report}"
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
import hashlib, os, shutil, stat
from tools.provisioning.authority_bootstrap import (
    provision_control_state, allocate_cimp, allocate_cgen,
    implementation_lifecycle_lock, initialise_genesis,
    BootstrapError, ControlStateError, LockUnavailable, AlreadyInitialised,
    CIMP_COUNTER, CGEN_COUNTER, LIFECYCLE_LOCK, STAGING,
    GENESIS_CGEN, IMPLEMENTATIONS, GENERATIONS, CURRENT_GENERATION,
    AUTHORITY_SET, GENERATION)
from tools.capability.execution.implementation_authority import (
    current_generation, NamespaceState)
WORK = os.environ['WORKDIR']
# A group this process is genuinely a member of, preferring one that is not the
# primary group so inheritance is visibly different from 'whatever root made'.
_candidates = [g for g in os.getgroups() if g != os.getgid()]
INHERITED_GID = _candidates[0] if _candidates else os.getgid()

def roots(name):
    '''One hermetic pair: published authority and operator control.

    Both live under a single temporary directory because publication renames
    staged material into the published namespace, which requires one
    filesystem -- the same assumption the handoff makes under /data.
    '''
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    authority = os.path.join(base, 'implementation-authority')
    control = os.path.join(base, 'implementation-authority-control')
    os.makedirs(authority)
    os.makedirs(control)
    # Ruled layout: the authority root and staging/ carry setgid so every
    # object published beneath them inherits the coordinator group without any
    # chown. A fixture cannot own anything as root:cschott, so it uses a group
    # this process really is in -- the mechanism under test is inheritance,
    # not the particular group name.
    os.chown(authority, -1, INHERITED_GID)
    os.chmod(authority, 0o2750)
    staging = os.path.join(control, STAGING)
    os.mkdir(staging)
    os.chown(staging, -1, INHERITED_GID)
    os.chmod(staging, 0o2750)
    return authority, control

def fd(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY)

def provisioned(name):
    authority, control = roots(name)
    handle = fd(control)
    try:
        provision_control_state(handle)
    finally:
        os.close(handle)
    return authority, control

def with_authority(authority, control, action):
    a, c = fd(authority), fd(control)
    try:
        return action(a, c)
    finally:
        os.close(a); os.close(c)

def with_control(control, action):
    handle = fd(control)
    try:
        return action(handle)
    finally:
        os.close(handle)

def read(path):
    with open(path, 'rb') as handle:
        return handle.read()

def refuses(action, expect=BootstrapError):
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
            path = os.path.join(base, name)
            items.append((os.path.relpath(path, root), os.lstat(path).st_mode, b''))
    return hashlib.sha256(repr(sorted(items)).encode('utf-8')).hexdigest()
"

# --- control state ------------------------------------------------------------

run_case "provisioning creates counters at zero over an operator-provisioned staging root" "${PRELUDE}
authority, control = roots('prov')
with_control(control, provision_control_state)
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
assert read(os.path.join(control, CGEN_COUNTER)) == b'000000000000' + b'\n'
assert os.path.isdir(os.path.join(control, STAGING))
assert os.listdir(os.path.join(control, STAGING)) == []
print('OK')
"

run_case "provisioning refuses to create staging itself" "${PRELUDE}
# staging/ is what every published object inherits its group from, and this
# module has no production identity to give it. Creating it here would hand
# published authority the group root, and the coordinator would be unable to
# read a namespace it is required to read.
authority, control = roots('nostaging')
shutil.rmtree(os.path.join(control, STAGING))
refuses(lambda: with_control(control, provision_control_state), ControlStateError)
assert not os.path.exists(os.path.join(control, CIMP_COUNTER)), \\
    'a counter was provisioned over an absent staging root'
print('OK')
"

run_case "provisioning refuses a staging root that already carries material" "${PRELUDE}
authority, control = roots('dirtystaging')
open(os.path.join(control, STAGING, 'residue'), 'wb').close()
refuses(lambda: with_control(control, provision_control_state), ControlStateError)
print('OK')
"

run_case "provisioning refuses a staging root that is not a directory" "${PRELUDE}
authority, control = roots('filestaging')
os.rmdir(os.path.join(control, STAGING))
open(os.path.join(control, STAGING), 'wb').close()
refuses(lambda: with_control(control, provision_control_state), ControlStateError)
print('OK')
"

run_case "provisioning is create-once and never overwrites a counter" "${PRELUDE}
authority, control = provisioned('provtwice')
with_control(control, lambda h: allocate_cimp(h))
before = read(os.path.join(control, CIMP_COUNTER))
refuses(lambda: with_control(control, provision_control_state), ControlStateError)
assert read(os.path.join(control, CIMP_COUNTER)) == before, 'a counter was reset'
print('OK')
"

# --- the CIMP allocator -------------------------------------------------------

run_case "the first CIMP is CIMP-000001 and allocation is monotonic" "${PRELUDE}
authority, control = provisioned('cimpseq')
got = [with_control(control, allocate_cimp) for _ in range(3)]
assert got == ['CIMP-000001', 'CIMP-000002', 'CIMP-000003'], got
print('OK')
"

run_case "CIMP-000000 is unreachable from the allocator" "${PRELUDE}
authority, control = provisioned('cimpzero')
# The provisioned state is zero and allocation increments before returning, so
# the reserved identifier is never emitted -- it is not filtered afterwards.
assert with_control(control, allocate_cimp) != 'CIMP-000000'
print('OK')
"

run_case "a failure after allocation burns the identifier permanently" "${PRELUDE}
authority, control = provisioned('cimpburn')
first = with_control(control, allocate_cimp)
assert first == 'CIMP-000001'
# The counter is durable before the caller ever sees the identifier, so a
# caller that dies here cannot hand the number out again.
assert read(os.path.join(control, CIMP_COUNTER)) == b'000001' + b'\n'
second = with_control(control, allocate_cimp)
assert second == 'CIMP-000002', second
print('OK')
"

run_case "an absent, malformed, or unsafe CIMP counter fails closed" "${PRELUDE}
authority, control = roots('cimpbad')
# Absent: runtime never bootstraps an allocator, and neither does this.
refuses(lambda: with_control(control, allocate_cimp), ControlStateError)

for body in (b'', b'00000' + b'\n', b'0000000' + b'\n', b'000000',
             b'00000a' + b'\n', b'0000 0' + b'\n', b'-00001' + b'\n',
             b'000000' + b'\n' + b'x', b'999999' + b'\n'):
    authority, control = provisioned('cimpbad' + str(abs(hash(body)) % 99999))
    path = os.path.join(control, CIMP_COUNTER)
    os.unlink(path)
    with open(path, 'wb') as handle:
        handle.write(body)
    if body == b'999999' + b'\n':
        refuses(lambda: with_control(control, allocate_cimp), BootstrapError)
    else:
        refuses(lambda: with_control(control, allocate_cimp), ControlStateError)

# A symlink is refused at open, not followed and then judged.
authority, control = provisioned('cimplink')
path = os.path.join(control, CIMP_COUNTER)
os.unlink(path)
os.symlink(os.path.join(control, CGEN_COUNTER), path)
refuses(lambda: with_control(control, allocate_cimp), ControlStateError)

# A directory where a counter belongs is not a counter.
authority, control = provisioned('cimpdir')
path = os.path.join(control, CIMP_COUNTER)
os.unlink(path)
os.mkdir(path)
refuses(lambda: with_control(control, allocate_cimp), ControlStateError)
print('OK')
"

# --- the CGEN allocator -------------------------------------------------------

run_case "the first normal CGEN is CGEN-000000000001, never genesis" "${PRELUDE}
authority, control = provisioned('cgenseq')
got = [with_control(control, allocate_cgen) for _ in range(2)]
assert got == ['CGEN-000000000001', 'CGEN-000000000002'], got
assert GENESIS_CGEN not in got
print('OK')
"

run_case "the CGEN allocator never emits genesis and never reads the namespace" "${PRELUDE}
authority, control = provisioned('cgengen')
# Genesis is a ceremony, not an allocation: the counter is provisioned at zero
# and increments before returning, so zero is never handed out.
for _ in range(5):
    assert with_control(control, allocate_cgen) != GENESIS_CGEN
print('OK')
"

run_case "a failure after CGEN allocation burns the identifier permanently" "${PRELUDE}
authority, control = provisioned('cgenburn')
assert with_control(control, allocate_cgen) == 'CGEN-000000000001'
assert read(os.path.join(control, CGEN_COUNTER)) == b'000000000001' + b'\n'
assert with_control(control, allocate_cgen) == 'CGEN-000000000002'
print('OK')
"

run_case "an absent, malformed, or unsafe CGEN counter fails closed" "${PRELUDE}
authority, control = roots('cgenbad')
refuses(lambda: with_control(control, allocate_cgen), ControlStateError)

for body in (b'', b'00000000000' + b'\n', b'0000000000000' + b'\n',
             b'000000000000', b'00000000000z' + b'\n'):
    authority, control = provisioned('cgenbad' + str(abs(hash(body)) % 99999))
    path = os.path.join(control, CGEN_COUNTER)
    os.unlink(path)
    with open(path, 'wb') as handle:
        handle.write(body)
    refuses(lambda: with_control(control, allocate_cgen), ControlStateError)

authority, control = provisioned('cgenlink')
path = os.path.join(control, CGEN_COUNTER)
os.unlink(path)
os.symlink(os.path.join(control, CIMP_COUNTER), path)
refuses(lambda: with_control(control, allocate_cgen), ControlStateError)
print('OK')
"

run_case "the two counters are independent" "${PRELUDE}
authority, control = provisioned('indep')
with_control(control, allocate_cimp)
with_control(control, allocate_cimp)
assert with_control(control, allocate_cgen) == 'CGEN-000000000001'
assert with_control(control, allocate_cimp) == 'CIMP-000003'
print('OK')
"

# --- the lifecycle lock -------------------------------------------------------

run_case "one holder takes the lifecycle lock and a second is refused" "${PRELUDE}
authority, control = provisioned('lock1')
first = fd(control)
second = fd(control)
try:
    with implementation_lifecycle_lock(first):
        # A separate open file description, so this is a real conflict rather
        # than the same handle re-entering.
        refuses(lambda: implementation_lifecycle_lock(second).__enter__(),
                LockUnavailable)
    # Released on scope exit, so the second context now succeeds.
    with implementation_lifecycle_lock(second):
        pass
finally:
    os.close(first); os.close(second)
print('OK')
"

run_case "the lifecycle lock is released when the scope raises" "${PRELUDE}
authority, control = provisioned('lock2')
first = fd(control)
second = fd(control)
try:
    class Boom(Exception):
        pass
    try:
        with implementation_lifecycle_lock(first):
            raise Boom()
    except Boom:
        pass
    with implementation_lifecycle_lock(second):
        pass
finally:
    os.close(first); os.close(second)
print('OK')
"

run_case "an unsafe lock object is refused rather than used" "${PRELUDE}
authority, control = provisioned('lock3')
path = os.path.join(control, LIFECYCLE_LOCK)
if os.path.exists(path):
    os.unlink(path)
os.mkdir(path)
refuses(lambda: with_control(control, lambda h: implementation_lifecycle_lock(h).__enter__()),
        ControlStateError)
shutil.rmtree(path)
os.symlink(os.path.join(control, CIMP_COUNTER), path)
refuses(lambda: with_control(control, lambda h: implementation_lifecycle_lock(h).__enter__()),
        ControlStateError)
print('OK')
"

# --- genesis ------------------------------------------------------------------

run_case "genesis publishes an empty authority set the reader accepts" "${PRELUDE}
authority, control = provisioned('gen1')
a, c = fd(authority), fd(control)
try:
    assert initialise_genesis(a, c) == GENESIS_CGEN
finally:
    os.close(a); os.close(c)
handle = fd(authority)
try:
    generation = current_generation(handle)
finally:
    os.close(handle)
assert generation.cgen == GENESIS_CGEN, generation.cgen
assert generation.state is NamespaceState.VALID, generation.state
assert generation.pending == (), generation.pending
assert generation.entries == (), generation.entries
assert generation.eligible_cimps == (), generation.eligible_cimps
assert generation.predecessor_cgen is None
assert generation.predecessor_generation_digest is None
print('OK')
"

run_case "genesis consumes no normal identifier from either counter" "${PRELUDE}
authority, control = provisioned('gen2')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
assert read(os.path.join(control, CIMP_COUNTER)) == b'000000' + b'\n'
assert read(os.path.join(control, CGEN_COUNTER)) == b'000000000000' + b'\n'
assert with_control(control, allocate_cimp) == 'CIMP-000001'
assert with_control(control, allocate_cgen) == 'CGEN-000000000001'
print('OK')
"

run_case "current-generation is a regular canonical file, never a symlink" "${PRELUDE}
authority, control = provisioned('gen3')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
pointer = os.path.join(authority, CURRENT_GENERATION)
status = os.lstat(pointer)
assert not os.path.islink(pointer), 'the pointer is a symlink'
assert (status.st_mode & 0o170000) == 0o100000, oct(status.st_mode)
body = read(pointer)
assert body.startswith(b'{') and body.endswith(b'}'), body
assert b'CGEN-000000000000' in body
print('OK')
"

# --- setgid inheritance: the ruled ownership, with no chown anywhere ----------
#
# The design rules published authority directories 2750 and records 0440, both
# group-owned by the coordinator so the reader can enumerate implementations/.
# Nothing chowns: the group arrives by inheritance from two setgid roots, and
# these cases prove that end to end rather than by reading the mode off a
# directory somebody set by hand.

run_case "genesis publishes every object with the inherited group and no chown" "${PRELUDE}
authority, control = provisioned('inherit')
with_authority(authority, control, initialise_genesis)
published = []
for base, dirs, files in os.walk(authority):
    for name in sorted(dirs) + sorted(files):
        published.append(os.path.join(base, name))
published.append(authority)
assert len(published) > 4, published
for path in published:
    status = os.lstat(path)
    assert status.st_gid == INHERITED_GID, (path, status.st_gid, INHERITED_GID)
    if stat.S_ISDIR(status.st_mode):
        # Directories carry setgid so the next publication inherits too: the
        # property has to survive being extended, not just being created once.
        assert status.st_mode & stat.S_ISGID, (path, oct(status.st_mode))
        assert stat.S_IMODE(status.st_mode) == 0o2750, (path, oct(status.st_mode))
    else:
        assert stat.S_IMODE(status.st_mode) == 0o440, (path, oct(status.st_mode))
print('OK')
"

run_case "rename out of staging preserves the group the object was created with" "${PRELUDE}
# The step the whole model rests on: a generation directory is created inside
# staging and renamed into generations/, and rename(2) carries ownership with
# it. If it did not, publication would need a chown and there would be a
# window where authority is readable by nobody.
authority, control = provisioned('renamegroup')
with_authority(authority, control, initialise_genesis)
staged = os.path.join(authority, GENERATIONS, GENESIS_CGEN)
assert os.path.isdir(staged), staged
assert os.lstat(staged).st_gid == INHERITED_GID
for name in (AUTHORITY_SET, GENERATION):
    record = os.path.join(staged, name)
    assert os.lstat(record).st_gid == INHERITED_GID, record
    assert stat.S_IMODE(os.lstat(record).st_mode) == 0o440, record
print('OK')
"

run_case "a staging root without setgid publishes the wrong group" "${PRELUDE}
# The negative that gives the positive its meaning. Strip setgid from staging
# and the published generation directory comes back with this process's group
# instead of the inherited one -- which on a production host is root, and the
# coordinator cannot read it. This is exactly the defect the ruling closed.
authority, control = provisioned('nosetgid')
staging = os.path.join(control, STAGING)
os.chmod(staging, 0o750)
os.chown(staging, -1, os.getgid())
with_authority(authority, control, initialise_genesis)
published = os.path.join(authority, GENERATIONS, GENESIS_CGEN)
assert os.lstat(published).st_gid == os.getgid(), 'inheritance came from nowhere'
if INHERITED_GID != os.getgid():
    assert os.lstat(published).st_gid != INHERITED_GID, \\
        'the ruled group appeared without setgid'
print('OK')
"

run_case "the control root itself is never group-inheriting" "${PRELUDE}
# Counters and the lock must stay root-only. They are created directly in the
# control root, which is deliberately NOT setgid, so they inherit nothing --
# and 0600 means the group name could not grant access even if it did.
authority, control = provisioned('controlgroup')
with_control(control, allocate_cimp)
with_control(control, allocate_cgen)
for name in (CIMP_COUNTER, CGEN_COUNTER):
    status = os.lstat(os.path.join(control, name))
    assert status.st_gid == os.getgid(), (name, status.st_gid)
    assert stat.S_IMODE(status.st_mode) == 0o600, (name, oct(status.st_mode))
assert not (os.lstat(control).st_mode & stat.S_ISGID), 'the control root is setgid'
print('OK')
"

# --- coordinator readability, under a hostile umask ---------------------------
#
# THE DEFECT THESE EXIST FOR. Group ownership inheritance and group READABILITY
# are different properties, and the earlier cases only proved the first. The
# mode assertions were right; nothing ever challenged them, because the harness
# ran under the developer's umask 022 and the modes came out correct by
# accident. The live ceremony ran under umask 077 -- materialise() set it and
# never restored it -- and every published object came out 2700 or 0400. Root
# verification passed, because root ignores mode bits; the coordinator could not
# read the namespace at all.
#
# So these run the primitives under umask 077 and require the ruled modes
# anyway, and they ask the question the old cases did not: can the GROUP read
# it?

run_case "genesis publishes coordinator-readable objects under a hostile umask" "${PRELUDE}
authority, control = roots('hostileumask')
os.umask(0o077)
try:
    with_control(control, provision_control_state)
    with_authority(authority, control, initialise_genesis)
finally:
    os.umask(0o022)
published = [authority]
for base, dirs, files in os.walk(authority):
    published.extend(os.path.join(base, name) for name in sorted(dirs) + sorted(files))
assert len(published) > 4, published
for path in published:
    status = os.lstat(path)
    mode = stat.S_IMODE(status.st_mode)
    if stat.S_ISDIR(status.st_mode):
        assert mode == 0o2750, (path, oct(mode))
        # r-x for the group: the reader ENUMERATES implementations/, so
        # traverse alone is not enough.
        assert mode & 0o050 == 0o050, (path, oct(mode))
    else:
        assert mode == 0o440, (path, oct(mode))
        assert mode & 0o040, (path, oct(mode))
    assert not mode & 0o022, ('group- or other-writable', path, oct(mode))
    assert status.st_gid == INHERITED_GID, (path, status.st_gid)
print('OK')
"

run_case "the runtime reader works on a namespace published under a hostile umask" "${PRELUDE}
authority, control = roots('hostilereader')
os.umask(0o077)
try:
    with_control(control, provision_control_state)
    with_authority(authority, control, initialise_genesis)
finally:
    os.umask(0o022)
handle = fd(authority)
try:
    generation = current_generation(handle)
finally:
    os.close(handle)
assert generation.cgen == GENESIS_CGEN, generation.cgen
assert generation.state is NamespaceState.VALID, generation.state
print('OK')
"

run_case "control state stays root-only when the namespace is group-readable" "${PRELUDE}
# Widening the published namespace must not widen the control namespace: the
# counters and the lock are the two things the coordinator must never see.
authority, control = provisioned('controlisolation')
with_control(control, allocate_cimp)
for name in (CIMP_COUNTER, CGEN_COUNTER):
    mode = stat.S_IMODE(os.lstat(os.path.join(control, name)).st_mode)
    assert mode == 0o600, (name, oct(mode))
    assert not mode & 0o077, ('readable beyond root', name, oct(mode))
print('OK')
"

run_case "the lifecycle lock is root-only however it was created" "${PRELUDE}
authority, control = provisioned('lockmode')
os.umask(0o000)
try:
    def take(handle):
        with implementation_lifecycle_lock(handle):
            return True
    assert with_control(control, take)
finally:
    os.umask(0o022)
mode = stat.S_IMODE(os.lstat(os.path.join(control, LIFECYCLE_LOCK)).st_mode)
assert mode == 0o600, oct(mode)
print('OK')
"

run_case "genesis leaves no staging residue behind" "${PRELUDE}
authority, control = provisioned('gen4')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
assert os.listdir(os.path.join(control, STAGING)) == [], 'staging residue'
entries = sorted(os.listdir(authority))
assert entries == sorted([IMPLEMENTATIONS, GENERATIONS, CURRENT_GENERATION]), entries
assert os.listdir(os.path.join(authority, IMPLEMENTATIONS)) == []
assert os.listdir(os.path.join(authority, GENERATIONS)) == [GENESIS_CGEN]
print('OK')
"

run_case "genesis refuses to run a second time" "${PRELUDE}
authority, control = provisioned('gen5')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
    before = tree_digest(authority)
    refuses(lambda: initialise_genesis(a, c), AlreadyInitialised)
    assert tree_digest(authority) == before, 'a second genesis mutated authority'
finally:
    os.close(a); os.close(c)
print('OK')
"

run_case "genesis refuses any pre-existing authority material" "${PRELUDE}
# Each of these means somebody has already published something. Genesis is not
# a repair, so it never writes over evidence it did not create.
authority, control = provisioned('gen6a')
os.makedirs(os.path.join(authority, IMPLEMENTATIONS))
open(os.path.join(authority, IMPLEMENTATIONS, 'CIMP-000001'), 'wb').close()
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        AlreadyInitialised)

authority, control = provisioned('gen6b')
os.makedirs(os.path.join(authority, GENERATIONS, GENESIS_CGEN))
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        AlreadyInitialised)

authority, control = provisioned('gen6c')
with open(os.path.join(authority, CURRENT_GENERATION), 'wb') as handle:
    handle.write(b'{}')
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        AlreadyInitialised)
print('OK')
"

run_case "genesis refuses a symlinked or wrong-typed authority object" "${PRELUDE}
authority, control = provisioned('gen7a')
os.symlink(os.path.join(control, STAGING), os.path.join(authority, IMPLEMENTATIONS))
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        BootstrapError)

authority, control = provisioned('gen7b')
os.symlink(os.path.join(control, CIMP_COUNTER),
           os.path.join(authority, CURRENT_GENERATION))
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        BootstrapError)

authority, control = provisioned('gen7c')
os.makedirs(os.path.join(authority, CURRENT_GENERATION))
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        BootstrapError)
print('OK')
"

run_case "genesis refuses when control state is missing or malformed" "${PRELUDE}
authority, control = roots('gen8a')
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        ControlStateError)

authority, control = provisioned('gen8b')
path = os.path.join(control, CGEN_COUNTER)
os.unlink(path)
with open(path, 'wb') as handle:
    handle.write(b'nonsense\n')
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        ControlStateError)
print('OK')
"

# --- interruption boundaries --------------------------------------------------
#
# Each state below is constructed directly rather than by killing a process
# mid-call: the point is what the on-disk result means, and building it by hand
# makes the boundary explicit instead of timing-dependent.

run_case "staged material never becomes authority and is left for recovery" "${PRELUDE}
# Crash during staging: the staged generation exists under the control root and
# nothing was published. The reader sees an uninitialised namespace, and
# ordinary genesis refuses rather than adopting somebody else's staging.
authority, control = provisioned('crash1')
staged = os.path.join(control, STAGING, 'residue')
os.makedirs(staged)
with open(os.path.join(staged, 'generation'), 'wb') as handle:
    handle.write(b'{}')
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        BootstrapError)
# The residue is still there for an explicit recovery action to look at.
assert os.path.isdir(staged), 'genesis silently removed staging'
print('OK')
"

run_case "a published generation without a pointer is never silently repaired" "${PRELUDE}
# Crash after the generation was published but before current-generation was
# installed. The generation is immutable published state; ordinary genesis must
# not complete somebody else's interrupted transaction.
authority, control = provisioned('crash2')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
os.unlink(os.path.join(authority, CURRENT_GENERATION))
before = tree_digest(authority)
refuses(lambda: with_control(control, lambda c: initialise_genesis(fd(authority), c)),
        AlreadyInitialised)
assert tree_digest(authority) == before, 'genesis rewrote published state'
# And the namespace grants no authority while the pointer is missing.
handle = fd(authority)
try:
    try:
        current_generation(handle)
    except Exception:
        pass
    else:
        raise AssertionError('a pointerless namespace resolved')
finally:
    os.close(handle)
print('OK')
"

run_case "a temporary pointer left behind grants no authority" "${PRELUDE}
# Crash during the temporary pointer write, before the atomic rename.
authority, control = provisioned('crash3')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
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
        raise AssertionError('a temporary pointer was treated as authority')
finally:
    os.close(handle)
print('OK')
"

run_case "genesis publication is verified through the normal reader" "${PRELUDE}
# The ceremony does not re-implement authority interpretation: it asks the same
# reader the runtime uses, so a genesis that the reader would reject cannot be
# reported as successful.
authority, control = provisioned('verify')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
handle = fd(authority)
try:
    first = current_generation(handle)
    for _ in range(3):
        again = current_generation(handle)
        assert again.cgen == first.cgen
        assert again.state is first.state
        assert again.generation_digest == first.generation_digest
        assert again.pending == first.pending
finally:
    os.close(handle)
print('OK')
"

run_case "reading a genesis namespace writes nothing" "${PRELUDE}
authority, control = provisioned('noside')
a, c = fd(authority), fd(control)
try:
    initialise_genesis(a, c)
finally:
    os.close(a); os.close(c)
before = tree_digest(authority)
handle = fd(authority)
try:
    for _ in range(3):
        current_generation(handle)
finally:
    os.close(handle)
assert tree_digest(authority) == before, 'the reader mutated the namespace'
print('OK')
"

# --- suite registration -------------------------------------------------------

run_case "the bootstrap suite runs in local validation and in CI" "${PRELUDE}
from pathlib import Path
name = 'tests/test-capability-authority-bootstrap.sh'
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
assert name in validation, 'local validation does not run the bootstrap suite'
assert name in ci, 'CI does not run the bootstrap suite'
print('OK')
"

run_case "no production authority path is created by this suite" "${PRELUDE}
# The production namespace legitimately exists once an operator has run the
# admission ceremony, so its absence stopped being the thing to assert. What
# this suite owes is that IT creates nothing there -- which the fixture-only
# design gives structurally, and which is checked by requiring the suite to be
# unprivileged and every root it writes to be under WORK.
assert os.getuid() != 0, 'these tests must not run as root'
assert WORK.startswith('/tmp/') or WORK.startswith('/var/tmp/'), WORK
for production in ('/var/lib/kyri/implementation-authority',
                   '/var/lib/kyri/implementation-authority-control'):
    assert not production.startswith(WORK), production
    # Unprivileged and root-owned: this suite could not have created it and
    # cannot write into it.
    if os.path.exists(production):
        assert os.stat(production).st_uid == 0, production + ' is not root-owned'
        assert not os.access(production, os.W_OK), production + ' is writable here'
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Capability implementation-authority bootstrap validation passed.\n'
else
  printf 'Capability implementation-authority bootstrap validation FAILED: %d\n' \
    "${FAILURES}" >&2
  exit 1
fi
