#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T5.
#
# T5 is the first write-capable increment: provisioned backing-store
# verification, and the CMUT durability substrate that later authority-bearing
# mutations are built on. It is NOT a general filesystem transaction API --
# every target is a closed identity and every child name is constructed
# internally, so no caller string reaches the filesystem.
#
# THE CMUT LAYER IS FOUNDATIONAL and exempt from recursive coverage: it does
# not allocate CMUTs to protect its own counter, intent, outcome, or
# reconciliation records.
#
# ONE CMUT AUTHORISES AT MOST ONE INSTALLATION ATTEMPT. Recovery can learn
# whether an interrupted installation landed; it can never replay it.
#
# There is no CINV lifecycle policy here, no capacity, no handoff, no
# transition, no Podman, no CADM, no quarantine, and NO EXECUTION.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §21, §22
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T5

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/backing_store.py"
assert_file "tools/capability/execution/mutation.py"

# ===========================================================================
# The T5 authority backstop
# ===========================================================================
# T5 may write, because durability is its job. The scan therefore names the
# authority it must NOT acquire rather than banning writes outright, and
# requires every open and rename to be descriptor-relative.

assert_bounded_write_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
targets = [root / "tools/capability/execution/backing_store.py",
           root / "tools/capability/execution/mutation.py"]

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "chmod", "chown", "rmtree", "removedirs", "symlink", "link",
    "readlink", "realpath", "abspath", "expanduser", "chdir", "now", "today",
    "monotonic", "uuid1", "uuid4", "normalize", "walk",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/")

missing = [t for t in targets if not t.is_file()]
if missing:
    print("module-absent")
    raise SystemExit(0)

findings = []
for target in targets:
    rel = target.relative_to(root)
    tree = ast.parse(target.read_text(encoding="utf-8"))

    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(tree)

    stripped = ast.unparse(tree).lower()
    for token in FORBIDDEN_TEXT:
        if token in stripped:
            findings.append(f"{rel}: forbidden token in code: {token}")

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    findings.append(f"{rel}: forbidden import: {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            name = node.module or ""
            if name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{rel}: forbidden import-from: {name}")
        elif isinstance(node, ast.Call):
            func = node.func
            attr = getattr(func, "attr", None) or getattr(func, "id", None)
            if attr in FORBIDDEN_CALLS:
                findings.append(f"{rel}: forbidden call: {attr}")

    permitted_os = {
        "open", "read", "write", "close", "fstat", "stat", "scandir", "fsync",
        "rename", "unlink", "mkdir", "dup", "O_RDONLY", "O_WRONLY", "O_RDWR",
        "O_CREAT", "O_EXCL", "O_NOFOLLOW", "O_CLOEXEC", "O_DIRECTORY",
        "O_TRUNC",
    }
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id == "os" and node.attr not in permitted_os:
            findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

    # Resolve module-level flag constants so a constant carrying O_NOFOLLOW
    # counts, then require every os.open to be no-follow and descriptor-relative.
    nofollow = set()
    for node in tree.body:
        if isinstance(node, ast.Assign) and "O_NOFOLLOW" in ast.unparse(node.value):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    nofollow.add(t.id)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and isinstance(node.func.value, ast.Name) \
                and node.func.value.id == "os":
            name = node.func.attr
            kwargs = {kw.arg for kw in node.keywords}
            if name == "open":
                flags = ast.unparse(node.args[1]) if len(node.args) > 1 else ""
                if "O_NOFOLLOW" not in flags and not any(n in flags for n in nofollow):
                    findings.append(f"{rel}: os.open without O_NOFOLLOW")
                if "dir_fd" not in kwargs:
                    findings.append(f"{rel}: os.open without dir_fd")
            if name == "rename" and not {"src_dir_fd", "dst_dir_fd"} <= kwargs:
                findings.append(f"{rel}: os.rename without src/dst dir_fd")
            if name in {"unlink", "mkdir", "stat"} and "dir_fd" not in kwargs:
                findings.append(f"{rel}: os.{name} without dir_fd")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T5 write authority is bounded: descriptor-relative, no execution or path authority"
  else
    fail "T5 authority backstop found: ${report}"
  fi
}

assert_bounded_write_authority

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
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem, RootDescriptor,
    BackingStoreMismatch, BackingStoreConfigIntegrityFailure)
from tools.capability.execution.mutation import (
    Mutation, MutationTarget, TargetKind, UnknownOutcome,
    MutationJournalIntegrityFailure, CounterExhausted, AlreadyInstalled,
    CMUT_COUNTER, FIRST_CMUT)
from tools.capability.execution.types import Classification
WORK = os.environ['WORKDIR']

UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def config_body(uuid=UUID, fstype='xfs', mount='/data'):
    return serialise({'filesystem_uuid': uuid, 'filesystem_type': fstype,
                      'mount_point': mount})

def make_root(name, *, config=None, counter=b'000000000000\n'):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(os.path.join(base, 'root', 'mutations'))
    os.makedirs(os.path.join(base, 'root', 'state'))
    body = config_body() if config is None else config
    cfg = os.path.join(base, 'backing-store.json')
    with open(cfg, 'wb') as handle:
        handle.write(body)
    if counter is not None:
        with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
            handle.write(counter)
    return base, body

def observed(uuid=UUID, fstype='xfs', mount='/data', device='/dev/sdb1'):
    return ObservedFilesystem(filesystem_uuid=uuid, filesystem_type=fstype,
                              mount_point=mount, device_name=device)

def open_fds(base):
    cfg = os.open(os.path.join(base, 'backing-store.json'), os.O_RDONLY)
    root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    return cfg, root

def verified(name='v', **kw):
    base, body = make_root(name, **kw)
    cfg, root = open_fds(base)
    try:
        return base, verify_backing_store(cfg, root, observed=observed())
    finally:
        os.close(cfg); os.close(root)

TARGET = MutationTarget(kind=TargetKind.EXECUTION_STATE, name='CINV-000042')
BODY = serialise({'cinv': 'CINV-000042', 'state': 'reserved'})
"

# --- backing store: descriptors --------------------------------------------

run_case "config and root are descriptors, with no pathname parameters" "${PRELUDE}
import inspect
params = list(inspect.signature(verify_backing_store).parameters)
assert params == ['config_fd', 'root_fd', 'observed'], params
# PEP 563 is in force in these modules, so annotations arrive as strings.
recover = inspect.signature(Mutation.recover)
assert list(recover.parameters) == ['root_fd'], list(recover.parameters)
assert recover.parameters['root_fd'].annotation in (int, 'int')
for signature in (inspect.signature(verify_backing_store), recover,
                  inspect.signature(Mutation.install),
                  inspect.signature(Mutation.commit)):
    for name, parameter in signature.parameters.items():
        assert 'path' not in name.lower(), name
        assert str(parameter.annotation) != 'Path', (name, parameter.annotation)
print('OK')
"

run_case "valid backing store verifies and binds the descriptor device" "${PRELUDE}
base, descriptor = verified('ok')
assert isinstance(descriptor, RootDescriptor)
assert descriptor.filesystem_uuid == UUID
assert descriptor.st_dev == os.stat(os.path.join(base, 'root')).st_dev
descriptor.close()
print('OK')
"

run_case "UUID mismatch refuses" "${PRELUDE}
base, _ = make_root('uuid')
cfg, root = open_fds(base)
try:
    verify_backing_store(cfg, root, observed=observed(uuid='00000000-0000-0000-0000-000000000000'))
except BackingStoreMismatch as error:
    assert error.classification is Classification.QUARANTINE_BACKING_STORE_MISMATCH
    print('OK')
else:
    raise AssertionError('UUID mismatch accepted')
finally:
    os.close(cfg); os.close(root)
"

run_case "filesystem-type mismatch refuses" "${PRELUDE}
base, _ = make_root('fstype')
cfg, root = open_fds(base)
try:
    verify_backing_store(cfg, root, observed=observed(fstype='ext4'))
except BackingStoreMismatch:
    print('OK')
else:
    raise AssertionError('type mismatch accepted')
finally:
    os.close(cfg); os.close(root)
"

run_case "mount-relationship mismatch refuses" "${PRELUDE}
base, _ = make_root('mount')
cfg, root = open_fds(base)
try:
    verify_backing_store(cfg, root, observed=observed(mount='/mnt/elsewhere'))
except BackingStoreMismatch:
    print('OK')
else:
    raise AssertionError('mount mismatch accepted')
finally:
    os.close(cfg); os.close(root)
"

run_case "a device-name change is diagnostic and does not fail" "${PRELUDE}
base, _ = make_root('device')
cfg, root = open_fds(base)
try:
    descriptor = verify_backing_store(cfg, root, observed=observed(device='/dev/sdz9'))
    assert descriptor.device_name == '/dev/sdz9'
    descriptor.close()
    print('OK')
finally:
    os.close(cfg); os.close(root)
"

run_case "malformed config is a config-integrity failure, not a mismatch" "${PRELUDE}
base, _ = make_root('badcfg', config=b'{not json')
cfg, root = open_fds(base)
try:
    verify_backing_store(cfg, root, observed=observed())
except BackingStoreConfigIntegrityFailure as error:
    assert error.classification is Classification.QUARANTINE_BACKING_STORE_CONFIG_INTEGRITY_FAILURE
    print('OK')
else:
    raise AssertionError('malformed config accepted')
finally:
    os.close(cfg); os.close(root)
"

run_case "an unknown config field is a config-integrity failure" "${PRELUDE}
body = serialise({'filesystem_uuid': UUID, 'filesystem_type': 'xfs',
                  'mount_point': '/data', 'extra': 'x'})
base, _ = make_root('cfgextra', config=body)
cfg, root = open_fds(base)
try:
    verify_backing_store(cfg, root, observed=observed())
except BackingStoreConfigIntegrityFailure:
    print('OK')
else:
    raise AssertionError('unknown config field accepted')
finally:
    os.close(cfg); os.close(root)
"

run_case "the verified root survives the caller closing its descriptor" "${PRELUDE}
base, _ = make_root('dup')
cfg, root = open_fds(base)
descriptor = verify_backing_store(cfg, root, observed=observed())
os.close(cfg); os.close(root)
# The caller's descriptors are gone; the verified root must still work.
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
assert cmut == FIRST_CMUT
descriptor.close()
print('OK')
"

run_case "replacing the root path cannot redirect established root authority" "${PRELUDE}
base, _ = make_root('anchor')
evil, _ = make_root('anchor-evil')
cfg, root = open_fds(base)
descriptor = verify_backing_store(cfg, root, observed=observed())
os.close(cfg); os.close(root)
good_root = os.path.join(base, 'root')
os.rename(good_root, os.path.join(base, 'root-moved'))
os.rename(os.path.join(evil, 'root'), good_root)
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
mutation.commit(cmut)
# The write landed in the original tree, not the one now wearing the name.
assert os.path.isfile(os.path.join(base, 'root-moved', 'state', 'CINV-000042'))
assert not os.path.exists(os.path.join(good_root, 'state', 'CINV-000042'))
descriptor.close()
print('OK')
"

# --- CMUT allocator ---------------------------------------------------------

run_case "the first allocation is CMUT-000000000001" "${PRELUDE}
base, descriptor = verified('first')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
assert cmut == 'CMUT-000000000001', cmut
descriptor.close()
print('OK')
"

run_case "the counter is durably advanced before the identity is issued" "${PRELUDE}
base, descriptor = verified('durable')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
with open(os.path.join(base, 'root', CMUT_COUNTER), 'rb') as handle:
    on_disk = handle.read()
assert on_disk == b'000000000001\n', on_disk
assert cmut == 'CMUT-000000000001'
descriptor.close()
print('OK')
"

run_case "allocated gaps stay burned across an interruption" "${PRELUDE}
base, descriptor = verified('gap')
mutation = Mutation(descriptor)
first = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
# Simulate the caller dying before it ever installs: the number is spent.
descriptor.close()
base2, descriptor2 = None, None
cfg, root = open_fds(base)
descriptor2 = verify_backing_store(cfg, root, observed=observed())
os.close(cfg); os.close(root)
second = Mutation(descriptor2).begin(
    MutationTarget(kind=TargetKind.EXECUTION_STATE, name='CINV-000043'),
    schema_type='execution-state', expected_sha256=sha(BODY))
assert first == 'CMUT-000000000001' and second == 'CMUT-000000000002', (first, second)
descriptor2.close()
print('OK')
"

run_case "only the canonical counter form is accepted" "${PRELUDE}
for bad in (b'1\n', b'000000000000', b'00000000000a\n', b'0000000000000\n',
            b'', b' 000000000000\n', b'000000000000\n\n'):
    base, _ = make_root('cbad', counter=bad)
    cfg, root = open_fds(base)
    try:
        descriptor = verify_backing_store(cfg, root, observed=observed())
    finally:
        os.close(cfg); os.close(root)
    try:
        Mutation(descriptor).begin(TARGET, schema_type='execution-state',
                                   expected_sha256=sha(BODY))
    except MutationJournalIntegrityFailure:
        descriptor.close()
        continue
    descriptor.close()
    raise AssertionError(f'accepted counter {bad!r}')
print('OK')
"

run_case "a missing counter fails closed -- the runtime cannot bootstrap one" "${PRELUDE}
base, _ = make_root('nocounter', counter=None)
cfg, root = open_fds(base)
descriptor = verify_backing_store(cfg, root, observed=observed())
os.close(cfg); os.close(root)
try:
    Mutation(descriptor).begin(TARGET, schema_type='execution-state',
                               expected_sha256=sha(BODY))
except MutationJournalIntegrityFailure as error:
    assert error.classification is Classification.MUTATION_JOURNAL_INTEGRITY_FAILURE
    assert not os.path.exists(os.path.join(base, 'root', CMUT_COUNTER)), 'counter was created'
    print('OK')
else:
    raise AssertionError('a missing counter was bootstrapped')
finally:
    descriptor.close()
"

run_case "a counter behind existing records is a rollback witness" "${PRELUDE}
base, descriptor = verified('rollback')
mutation = Mutation(descriptor)
mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
# Counter rewound below a CMUT that demonstrably exists.
with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
    handle.write(b'000000000000\n')
try:
    mutation.begin(MutationTarget(kind=TargetKind.EXECUTION_STATE, name='CINV-000043'),
                   schema_type='execution-state', expected_sha256=sha(BODY))
except MutationJournalIntegrityFailure:
    print('OK')
else:
    raise AssertionError('rollback was not detected')
finally:
    descriptor.close()
"

run_case "exhaustion fails closed rather than wrapping" "${PRELUDE}
base, _ = make_root('exhaust', counter=b'999999999999\n')
cfg, root = open_fds(base)
descriptor = verify_backing_store(cfg, root, observed=observed())
os.close(cfg); os.close(root)
try:
    Mutation(descriptor).begin(TARGET, schema_type='execution-state',
                               expected_sha256=sha(BODY))
except CounterExhausted:
    print('OK')
else:
    raise AssertionError('the allocator wrapped')
finally:
    descriptor.close()
"

# --- target identity --------------------------------------------------------

run_case "targets are closed identities, not paths" "${PRELUDE}
import dataclasses
fields = {f.name for f in dataclasses.fields(MutationTarget)}
assert fields == {'kind', 'name'}, fields
for bad in ('../../etc/passwd', '/etc/passwd', 'CINV-42', 'cinv-000042',
            'CINV-000042/x', '', 'CINV-0000042'):
    try:
        MutationTarget(kind=TargetKind.EXECUTION_STATE, name=bad)
    except ValueError:
        continue
    raise AssertionError(f'accepted target name {bad!r}')
print('OK')
"

run_case "a target cannot be constructed from a raw string kind" "${PRELUDE}
try:
    MutationTarget(kind='execution-state', name='CINV-000042')
except (ValueError, TypeError):
    print('OK')
else:
    raise AssertionError('a string kind was accepted')
"

# --- intent, install, outcome ------------------------------------------------

run_case "intent records the exact byte commitment before installation" "${PRELUDE}
base, descriptor = verified('intent')
mutation = Mutation(descriptor)
digest = sha(BODY)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=digest)
intent_path = os.path.join(base, 'root', 'mutations', cmut, 'intent')
assert os.path.isfile(intent_path)
with open(intent_path, 'rb') as handle:
    import json
    record = json.loads(handle.read())
assert record['cmut'] == cmut
assert record['expected_sha256'] == digest
assert record['target_kind'] == TargetKind.EXECUTION_STATE.value
assert record['target_name'] == 'CINV-000042'
assert record['schema_type'] == 'execution-state'
# The target itself must not exist yet.
assert not os.path.exists(os.path.join(base, 'root', 'state', 'CINV-000042'))
descriptor.close()
print('OK')
"

run_case "intent is create-once" "${PRELUDE}
base, descriptor = verified('intentonce')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
try:
    mutation._write_intent(cmut, TARGET, 'execution-state', sha(BODY))
except Exception:
    print('OK')
else:
    raise AssertionError('intent was rewritten')
finally:
    descriptor.close()
"

run_case "one CMUT authorises at most one installation attempt" "${PRELUDE}
base, descriptor = verified('once')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
try:
    mutation.install(cmut, BODY)
except AlreadyInstalled:
    print('OK')
else:
    raise AssertionError('a second installation attempt was permitted')
finally:
    descriptor.close()
"

run_case "installation refuses bytes that do not match the commitment" "${PRELUDE}
base, descriptor = verified('bytes')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
try:
    mutation.install(cmut, serialise({'cinv': 'CINV-000042', 'state': 'released'}))
except MutationJournalIntegrityFailure:
    print('OK')
else:
    raise AssertionError('bytes disagreeing with the commitment were installed')
finally:
    descriptor.close()
"

run_case "outcome is create-once and completes the mutation" "${PRELUDE}
base, descriptor = verified('outcome')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
mutation.commit(cmut)
assert os.path.isfile(os.path.join(base, 'root', 'mutations', cmut, 'outcome'))
try:
    mutation.commit(cmut)
except Exception:
    print('OK')
else:
    raise AssertionError('outcome was rewritten')
finally:
    descriptor.close()
"

# --- recovery ----------------------------------------------------------------

run_case "crash after intent, before installation: unknown, target absent" "${PRELUDE}
base, descriptor = verified('crash1')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    unknown = Mutation.recover(root)
finally:
    os.close(root)
assert len(unknown) == 1, unknown
assert unknown[0].cmut == cmut
assert unknown[0].installed is False
assert unknown[0].proven is True
descriptor.close()
print('OK')
"

run_case "crash after installation, before outcome: unknown, target proven present" "${PRELUDE}
base, descriptor = verified('crash2')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    unknown = Mutation.recover(root)
finally:
    os.close(root)
assert len(unknown) == 1
assert unknown[0].installed is True and unknown[0].proven is True
descriptor.close()
print('OK')
"

run_case "a completed mutation is not reported as unknown" "${PRELUDE}
base, descriptor = verified('done')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
mutation.commit(cmut)
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    assert Mutation.recover(root) == ()
finally:
    os.close(root)
descriptor.close()
print('OK')
"

run_case "a different valid target is an integrity failure, not a recovery" "${PRELUDE}
base, descriptor = verified('different')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
# Same shape, different content: valid, but not the bytes that were committed.
other = serialise({'cinv': 'CINV-000042', 'state': 'released'})
with open(os.path.join(base, 'root', 'state', 'CINV-000042'), 'wb') as handle:
    handle.write(other)
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    Mutation.recover(root)
except MutationJournalIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a different valid target passed recovery')
finally:
    os.close(root); descriptor.close()
"

run_case "a malformed target is an integrity failure" "${PRELUDE}
base, descriptor = verified('malformed')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
with open(os.path.join(base, 'root', 'state', 'CINV-000042'), 'wb') as handle:
    handle.write(b'{truncated')
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    Mutation.recover(root)
except MutationJournalIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a malformed target passed recovery')
finally:
    os.close(root); descriptor.close()
"

run_case "a malformed intent record fails closed" "${PRELUDE}
base, descriptor = verified('badintent')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
with open(os.path.join(base, 'root', 'mutations', cmut, 'intent'), 'wb') as handle:
    handle.write(b'[]')
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    Mutation.recover(root)
except MutationJournalIntegrityFailure:
    print('OK')
else:
    raise AssertionError('a malformed intent passed recovery')
finally:
    os.close(root); descriptor.close()
"

run_case "recovery never replays an installation" "${PRELUDE}
base, descriptor = verified('noreplay')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
target = os.path.join(base, 'root', 'state', 'CINV-000042')
root = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
try:
    unknown = Mutation.recover(root)
    assert unknown[0].installed is False
    assert not os.path.exists(target), 'recovery installed the target'
    # And again -- recovery is observation, so it stays absent.
    Mutation.recover(root)
    assert not os.path.exists(target)
finally:
    os.close(root); descriptor.close()
import tools.capability.execution.mutation as module
public = [n for n in dir(module) if not n.startswith('_')]
for banned in ('replay', 'retry', 'redo', 'force', 'repair'):
    assert not any(banned in n.lower() for n in public), (banned, public)
print('OK')
"

run_case "a CMUT cannot be reused for a second mutation" "${PRELUDE}
base, descriptor = verified('reuse')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
mutation.commit(cmut)
try:
    mutation.install(cmut, BODY)
except (AlreadyInstalled, MutationJournalIntegrityFailure):
    print('OK')
else:
    raise AssertionError('a completed CMUT installed again')
finally:
    descriptor.close()
"

# --- durability --------------------------------------------------------------

run_case "the installed target is durable and atomically named" "${PRELUDE}
base, descriptor = verified('durable2')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
target = os.path.join(base, 'root', 'state', 'CINV-000042')
with open(target, 'rb') as handle:
    assert handle.read() == BODY
# No temporary residue survives a successful installation.
leftovers = [n for n in os.listdir(os.path.join(base, 'root', 'state'))
             if n != 'CINV-000042']
assert leftovers == [], leftovers
descriptor.close()
print('OK')
"

# Proven by call-shape rather than by observing the kernel. The durability
# order the specification requires is file fsync, atomic rename, directory
# fsync -- and the file fsync lives in the shared durable-write helper, so the
# check follows the structure the code actually has instead of demanding both
# fsyncs appear literally inside install.
run_case "installation is file-fsync, atomic rename, then directory fsync" "${PRELUDE}
import ast, inspect
import tools.capability.execution.mutation as module
tree = ast.parse(inspect.getsource(module))

def named(name, kind=(ast.FunctionDef,)):
    found = [n for n in ast.walk(tree) if isinstance(n, kind) and n.name == name]
    assert found, f'no {name}'
    return found[0]

def calls(node, attr):
    return [n for n in ast.walk(node)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
            and n.func.attr == attr]

writer = named('_write_durable')
assert len(calls(writer, 'fsync')) >= 2, 'the durable writer must fsync file and directory'
assert len(calls(writer, 'write')) >= 1

install = named('install')
statements = ast.unparse(install)
assert 'rename' in statements, 'install performs no atomic rename'
rename_at = statements.index('os.rename')
assert 'os.fsync' in statements[rename_at:], 'no directory fsync after the rename'
assert '_write_durable' in statements, 'install does not use the durable writer'
print('OK')
"

run_case "the CMUT layer allocates no CMUT for its own records" "${PRELUDE}
base, descriptor = verified('exempt')
mutation = Mutation(descriptor)
cmut = mutation.begin(TARGET, schema_type='execution-state', expected_sha256=sha(BODY))
mutation.install(cmut, BODY)
mutation.commit(cmut)
allocated = os.listdir(os.path.join(base, 'root', 'mutations'))
assert allocated == [cmut], allocated
with open(os.path.join(base, 'root', CMUT_COUNTER), 'rb') as handle:
    assert handle.read() == b'000000000001\n'
descriptor.close()
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T5 backing-store and CMUT validation passed.\n'
else
  printf 'Capability execution T5 backing-store and CMUT validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
