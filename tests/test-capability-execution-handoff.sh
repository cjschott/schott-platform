#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T7.
#
# T7 is the package contract and the immutable per-invocation handoff. It
# validates a governed package tree and publishes exactly the bytes that were
# validated. There is no privileged transition, no worker protocol, no Podman,
# no image, no capacity policy, no result collection, no quarantine, no
# cleanup, no CADM, no host provisioning -- and NO EXECUTION.
#
# PUBLICATION IS DESCRIPTOR-ANCHORED in both directions. The source cannot be
# redirected by replacing its pathname after it was opened, and neither can the
# destination: writes land through the verified root descriptor, not through a
# name that something else may now own.
#
# COPY, NEVER HARD LINK. Execution-visible data must have a lifetime and a
# permission story separable from the canonical source, which an aliased inode
# cannot provide. Link counts are asserted, not assumed.
#
# MODES ARE DECLARED, NOT PROVISIONED. These tests model the §13 matrix and
# never chown anything or touch a host path; real ownership transfer belongs to
# the transition helper behind G4.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §8, §13, §14
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/package_contract.py"
assert_file "tools/capability/execution/handoff.py"

# ===========================================================================
# The T7 authority backstop
# ===========================================================================

assert_bounded_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
targets = [root / "tools/capability/execution/package_contract.py",
           root / "tools/capability/execution/handoff.py"]

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "chown", "rmtree", "removedirs", "symlink", "link",
    "readlink", "realpath", "abspath", "expanduser", "chdir", "now", "today",
    "monotonic", "uuid1", "uuid4", "normalize", "walk",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "st_mtime", "/data/")

if any(not t.is_file() for t in targets):
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

    # chmod is permitted only on objects T7 itself creates, and only
    # descriptor-relatively. chown is forbidden outright: ownership transfer to
    # the execution identity belongs to the privileged transition, not here.
    permitted_os = {
        "open", "read", "write", "close", "fstat", "stat", "scandir", "fsync",
        "rename", "unlink", "mkdir", "rmdir", "chmod", "O_RDONLY", "O_WRONLY",
        "O_RDWR", "O_CREAT", "O_EXCL", "O_NOFOLLOW", "O_CLOEXEC",
        "O_DIRECTORY",
    }
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                and node.value.id == "os" and node.attr not in permitted_os:
            findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

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
            if name in {"unlink", "mkdir", "rmdir", "stat", "chmod"} \
                    and "dir_fd" not in kwargs:
                findings.append(f"{rel}: os.{name} without dir_fd")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T7 authority is bounded: descriptor-relative, no chown, no path reopen"
  else
    fail "T7 authority backstop found: ${report}"
  fi
}

assert_bounded_authority

# ===========================================================================
# Behaviour
# ===========================================================================

WORK="$(mktemp -d)"
# Published handoffs really are read-only trees, so the fixture has to restore
# write permission before it can clean up after itself. Needing this is a small
# confirmation that the §13 modes are applied rather than merely declared.
cleanup() {
  chmod -R u+rwX "${WORK}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

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
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.payload import validate_payload
from tools.capability.execution.package_contract import (
    validate_package, PackageBinding, PackageError, PackageBoundExceeded,
    ForbiddenContent, InvalidEntrypoint,
    MAXIMUM_ENTRIES, MAXIMUM_AGGREGATE_BYTES, MAXIMUM_FILE_BYTES)
from tools.capability.execution.handoff import (
    publish_handoff, HandoffBinding, HandoffError, HandoffTargetExists,
    HandoffIdentityMismatch, HANDOFF_MODES, PACKAGE_DIRECTORY,
    PAYLOAD_NAME, OUTPUT_DIRECTORY, PROFILE_NAME)
from tools.capability.execution.profile import (
    ProfileBinding, build_profile, canonical_profile, fingerprint)
from tools.capability.execution.implementation_authority import Admission
WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def read(path):
    with open(path, 'rb') as handle:
        return handle.read()

def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)
    os.chmod(path, mode)

def make_package(name, files=None, entrypoint='main.py'):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    files = files if files is not None else {
        'main.py': b'def run():\n    return {}\n',
        'helper.py': b'VALUE = 1\n',
        'data/table.json': b'{\"a\":1}',
    }
    for rel, body in files.items():
        write(os.path.join(base, rel), body)
    return base, entrypoint

def make_handoff_root(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(os.path.join(base, 'root'))
    with open(os.path.join(base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    return base

def anchor(base):
    cfg = os.open(os.path.join(base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    try:
        return verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)

VALID_PAYLOAD = b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}'

def payload_binding(name='pl'):
    path = os.path.join(WORK, name + '.json')
    with open(path, 'wb') as handle:
        handle.write(VALID_PAYLOAD)
    fd = os.open(path, os.O_RDONLY)
    try:
        return validate_payload(fd, schema_version=1)
    finally:
        os.close(fd)

def package_of(base, entrypoint='main.py'):
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return fd, validate_package(fd, entrypoint=entrypoint)
    except BaseException:
        os.close(fd)
        raise

def admission(cimp='CIMP-000001', image=None):
    return Admission(
        cimp=cimp, oci_image_id=image if image else 'a' * 64,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=1,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)

def governed_profile(cinv='CINV-000042', cimp='CIMP-000001', image=None):
    return build_profile(ProfileBinding(cinv=cinv, admission=admission(cimp, image)))

def publish(name='p', cinv='CINV-000042', files=None, entrypoint='main.py',
            profile=None):
    pkg_base, ep = make_package(name + '-pkg', files=files, entrypoint=entrypoint)
    hb = make_handoff_root(name + '-hand')
    root = anchor(hb)
    fd, binding = package_of(pkg_base, ep)
    try:
        published = publish_handoff(
            root, cinv, fd, payload_binding(name), binding,
            profile=governed_profile(cinv) if profile is None else profile)
    finally:
        os.close(fd)
    return hb, root, published, binding
"

# --- the governed profile object --------------------------------------------
#
# PUBLICATION MATERIAL ONLY. These bytes are what the privileged transition
# will later authenticate and copy into a sealed root-authored object; the file
# published here is coordinator-owned and stays that way. It is NOT execution
# authority by itself, nothing consumes it yet, and the worker must never read
# it directly. That transport is Pass 3B-ii and does not exist.

run_case "the profile is published as exactly the canonical profile bytes" "${PRELUDE}
profile = governed_profile()
hb, root, published, binding = publish('prof', profile=profile)
body = read(os.path.join(hb, 'root', 'CINV-000042', PROFILE_NAME))
assert body == canonical_profile(profile), 'the published bytes are not canonical'
# One serialiser: the bytes are the same object the fingerprint digests.
assert sha(body) == fingerprint(profile).profile_digest
assert published.profile_digest == fingerprint(profile).profile_digest
print('OK')
"

run_case "the published profile carries the accepted ownership and mode" "${PRELUDE}
hb, root, published, binding = publish('profmode')
path = os.path.join(hb, 'root', 'CINV-000042', PROFILE_NAME)
status = os.lstat(path)
assert stat.S_ISREG(status.st_mode), oct(status.st_mode)
assert stat.S_IMODE(status.st_mode) == HANDOFF_MODES['profile'] == 0o444, \
    oct(stat.S_IMODE(status.st_mode))
# Coordinator-owned, exactly as the payload is. It is NOT re-owned to root:
# the sealed copy in Pass 3B-ii is what protects these bytes, not this mode.
assert status.st_uid == os.getuid(), status.st_uid
assert not os.path.islink(path)
print('OK')
"

run_case "the profile must name the invocation it is published for" "${PRELUDE}
hb = make_handoff_root('cinvbind')
root = anchor(hb)
pkg_base, ep = make_package('cinvbind-pkg')
fd, binding = package_of(pkg_base, ep)
try:
    # A profile built for another CINV is refused rather than published.
    publish_handoff(root, 'CINV-000042', fd, payload_binding('cinvbind'),
                    binding, profile=governed_profile(cinv='CINV-000099'))
except HandoffIdentityMismatch:
    pass
else:
    raise AssertionError('a profile for another invocation was published')
finally:
    os.close(fd)
assert not os.path.exists(os.path.join(hb, 'root', 'CINV-000042')), 'partial handoff'
print('OK')
"

run_case "a malformed profile is refused and publishes nothing" "${PRELUDE}
for bad in (None, 'profile', 42, object()):
    hb = make_handoff_root('badprof' + str(abs(hash(repr(bad))) % 99999))
    root = anchor(hb)
    pkg_base, ep = make_package('badprof-pkg')
    fd, binding = package_of(pkg_base, ep)
    try:
        publish_handoff(root, 'CINV-000042', fd, payload_binding('bad'),
                        binding, profile=bad)
    except HandoffError:
        pass
    else:
        raise AssertionError('accepted ' + repr(bad))
    finally:
        os.close(fd)
    assert not os.path.exists(os.path.join(hb, 'root', 'CINV-000042'))
    assert os.listdir(os.path.join(hb, 'root')) == [], 'staging residue'
print('OK')
"

run_case "profile publication is create-once and a collision changes nothing" "${PRELUDE}
hb, root, published, binding = publish('collide')
path = os.path.join(hb, 'root', 'CINV-000042', PROFILE_NAME)
before = read(path)
pkg_base, ep = make_package('collide-again')
fd, second = package_of(pkg_base, ep)
try:
    publish_handoff(root, 'CINV-000042', fd, payload_binding('collide'),
                    second, profile=governed_profile(image='9' * 64))
except HandoffTargetExists:
    pass
else:
    raise AssertionError('a second handoff overwrote the first')
finally:
    os.close(fd)
assert read(path) == before, 'the published profile was replaced'
print('OK')
"

run_case "the profile cannot be aimed anywhere but its governed name" "${PRELUDE}
import inspect
# There is no path, name, or destination parameter to aim: the filename is a
# module constant and the directory is derived from the validated CINV.
assert PROFILE_NAME == 'profile', PROFILE_NAME
source = inspect.getsource(publish_handoff)
assert '..' not in source
for token in ('profile_path', 'profile_name=', 'destination'):
    assert token not in source, token
# And a traversal-shaped CINV never reaches publication at all.
hb = make_handoff_root('escape')
root = anchor(hb)
pkg_base, ep = make_package('escape-pkg')
fd, binding = package_of(pkg_base, ep)
try:
    for cinv in ('../CINV-000042', 'CINV-000042/../..', 'CINV-000042/profile'):
        try:
            publish_handoff(root, cinv, fd, payload_binding('escape'), binding,
                            profile=governed_profile())
        except HandoffError:
            continue
        raise AssertionError('accepted ' + repr(cinv))
finally:
    os.close(fd)
print('OK')
"

run_case "serialisation is deterministic across repeated publication" "${PRELUDE}
first = publish('det1')[2].profile_digest
second = publish('det2')[2].profile_digest
assert first == second, (first, second)
profile = governed_profile()
assert canonical_profile(profile) == canonical_profile(profile)
print('OK')
"

run_case "publishing the profile changes nothing else in the handoff" "${PRELUDE}
hb, root, published, binding = publish('unchanged')
base = os.path.join(hb, 'root', 'CINV-000042')
# Exactly the accepted members, plus the profile, and nothing more.
assert sorted(os.listdir(base)) == sorted(
    [PACKAGE_DIRECTORY, PAYLOAD_NAME, OUTPUT_DIRECTORY, PROFILE_NAME]), \
    sorted(os.listdir(base))
# Payload and package keep their own modes and bytes untouched.
assert stat.S_IMODE(os.lstat(os.path.join(base, PAYLOAD_NAME)).st_mode) == \
    HANDOFF_MODES['payload']
assert stat.S_IMODE(os.lstat(os.path.join(base, PACKAGE_DIRECTORY)).st_mode) == \
    HANDOFF_MODES['package']
assert stat.S_IMODE(os.lstat(os.path.join(base, OUTPUT_DIRECTORY)).st_mode) == \
    HANDOFF_MODES['output']
assert stat.S_IMODE(os.lstat(base).st_mode) == HANDOFF_MODES['invocation']
assert sha(read(os.path.join(base, PAYLOAD_NAME))) == published.payload_digest
print('OK')
"

run_case "publication stays coordinator-side of the privilege boundary" "${PRELUDE}
from pathlib import Path
# Pass 3B-ii moved the boundary; this asserts publication did not move with it.
# The launch record is the vNext seven fields, the profile digest replaced the
# image identity, and the sealed transport lives in the privileged helper --
# none of which this module may know about.
helper = Path('provisioning/execution/kyri-exec-transition.py').read_text(encoding='utf-8')
schema = helper.split('LAUNCH_RECORD_SCHEMA = (')[1].split(')')[0]
assert chr(34) + 'profile_digest' + chr(34) in schema, schema
assert chr(34) + 'oci_image_id' + chr(34) not in schema, schema
assert schema.count(chr(34)) == 14, schema
assert 'INHERITED_DESCRIPTORS = (0, 1, 2, 3)' in helper
assert 'PROFILE_FD = 3' in helper
# The transport belongs to the action layer; the policy layer decides and the
# worker consumes. Publication does none of the three.
action = Path('provisioning/execution/kyri-exec-transition-action.py').read_text(encoding='utf-8')
assert 'memfd_create' in action and 'F_ADD_SEALS' in action
assert 'memfd' not in helper, 'the policy layer performs the copy'
worker = Path('tools/capability/execution/worker.py').read_text(encoding='utf-8')
assert 'F_GET_SEALS' in worker and 'PROFILE_FD = 3' in worker
assert 'memfd_create' not in worker, 'the worker creates the object it consumes'
# Handoff publication reaches no runtime, container, or privileged surface, and
# knows nothing about how its bytes later cross the boundary.
source = Path('tools/capability/execution/handoff.py').read_text(encoding='utf-8')
for token in ('podman', 'Podman', 'subprocess', 'execve', 'setuid', 'memfd',
              'sudo', 'no_new_privs', 'F_ADD_SEALS', 'F_GET_SEALS',
              'PROFILE_FD', 'launch-authorisation'):
    assert token not in source, token
print('OK')
"

run_case "the published profile is exactly what the transition will authenticate" "${PRELUDE}
import hashlib
base, root, published, binding = publish('boundary-bytes')
body = read(os.path.join(base, 'root', 'CINV-000042', PROFILE_NAME))
# The whole transport rests on this equality: the transition hashes these bytes
# and refuses unless they match the digest the launch record committed to.
assert body == canonical_profile(governed_profile()), 'publication is not canonical'
assert hashlib.sha256(body).hexdigest() == published.profile_digest
assert published.profile_digest == fingerprint(governed_profile()).profile_digest
# And it stays coordinator-owned and coordinator-replaceable, which is exactly
# why the sealed copy exists rather than a freeze on this file.
info = os.lstat(os.path.join(base, 'root', 'CINV-000042', PROFILE_NAME))
assert stat.S_IMODE(info.st_mode) == HANDOFF_MODES['profile'] == 0o444
assert info.st_uid == os.getuid()
print('OK')
"

# --- interface shape --------------------------------------------------------

run_case "publication requires a RootDescriptor and takes no destination path" "${PRELUDE}
import inspect
params = list(inspect.signature(publish_handoff).parameters)
assert params == ['root', 'cinv', 'artefact_fd', 'payload', 'package',
                  'profile'], params
for name, p in inspect.signature(publish_handoff).parameters.items():
    assert 'path' not in name.lower(), name
    assert str(p.annotation) != 'Path', name
assert list(inspect.signature(validate_package).parameters) == ['descriptor', 'entrypoint']
print('OK')
"

run_case "a raw handoff pathname is refused" "${PRELUDE}
hb = make_handoff_root('rawdest')
pkg_base, ep = make_package('rawdest-pkg')
fd, binding = package_of(pkg_base, ep)
try:
    publish_handoff(os.path.join(hb, 'root'), 'CINV-000042', fd,
                    payload_binding('rawdest'), binding,
                    profile=governed_profile())
except (HandoffError, AttributeError, TypeError):
    print('OK')
else:
    raise AssertionError('a pathname was accepted as the handoff root')
finally:
    os.close(fd)
"

run_case "only canonical CINV reaches the handoff namespace" "${PRELUDE}
hb = make_handoff_root('cinvgram')
root = anchor(hb)
pkg_base, ep = make_package('cinvgram-pkg')
fd, binding = package_of(pkg_base, ep)
try:
    for bad in ('CINV-00004', '../../etc', '/etc/passwd', 'CINV-000042/x',
                'cinv-000042', '', 'opaque-invocation-id'):
        try:
            publish_handoff(root, bad, fd, payload_binding('cg'), binding,
                            profile=governed_profile())
        except HandoffError:
            continue
        raise AssertionError(f'accepted CINV {bad!r}')
finally:
    os.close(fd); root.close()
print('OK')
"

# --- package bounds ---------------------------------------------------------

run_case "the accepted package bounds are 1024 entries, 64 MiB, 16 MiB per file" "${PRELUDE}
assert MAXIMUM_ENTRIES == 1024
assert MAXIMUM_AGGREGATE_BYTES == 64 * 1024 * 1024
assert MAXIMUM_FILE_BYTES == 16 * 1024 * 1024
print('OK')
"

run_case "a valid package validates and reports its contents" "${PRELUDE}
base, ep = make_package('valid')
fd, binding = package_of(base, ep)
os.close(fd)
assert isinstance(binding, PackageBinding)
assert binding.entrypoint == 'main.py'
assert binding.entry_count == 3, binding.entry_count
assert {e.relative_path for e in binding.entries} == {
    'main.py', 'helper.py', 'data/table.json'}
assert len(binding.digest) == 64
print('OK')
"

run_case "more than 1024 entries is refused during enumeration" "${PRELUDE}
files = {f'm{i:05d}.py': b'x = 1\n' for i in range(MAXIMUM_ENTRIES + 1)}
files['main.py'] = b'def run():\n    return {}\n'
base, ep = make_package('toomany', files=files)
try:
    fd, _ = package_of(base, ep)
except PackageBoundExceeded:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('an oversized entry count was accepted')
"

run_case "a single file over 16 MiB is refused" "${PRELUDE}
files = {'main.py': b'def run():\n    return {}\n',
         'big.py': b'#' + b'x' * (16 * 1024 * 1024)}
base, ep = make_package('bigfile', files=files)
try:
    fd, _ = package_of(base, ep)
except PackageBoundExceeded:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('an oversized file was accepted')
"

run_case "aggregate bytes over 64 MiB is refused" "${PRELUDE}
chunk = b'#' + b'x' * (8 * 1024 * 1024 - 1)
files = {'main.py': b'def run():\n    return {}\n'}
for index in range(9):
    files[f'blob{index}.py'] = chunk
base, ep = make_package('bigagg', files=files)
try:
    fd, _ = package_of(base, ep)
except PackageBoundExceeded:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('an oversized aggregate was accepted')
"

# --- forbidden content -------------------------------------------------------

run_case "an ELF binary is refused" "${PRELUDE}
files = {'main.py': b'def run():\n    return {}\n',
         'tool': b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 64}
base, ep = make_package('elf', files=files)
try:
    fd, _ = package_of(base, ep)
except ForbiddenContent:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('an ELF binary was accepted')
"

run_case "a native extension is refused by suffix and by content" "${PRELUDE}
for name, body in (('ext.so', b'not really elf'),
                   ('ext.cpython-312-x86_64-linux-gnu.so', b'x'),
                   ('ext.pyd', b'x'), ('wheel.whl', b'PK\x03\x04')):
    files = {'main.py': b'def run():\n    return {}\n', name: body}
    base, ep = make_package('native', files=files)
    try:
        fd, _ = package_of(base, ep)
    except ForbiddenContent:
        continue
    os.close(fd)
    raise AssertionError(f'accepted {name}')
print('OK')
"

run_case "an executable-mode file is refused" "${PRELUDE}
base, ep = make_package('execmode')
os.chmod(os.path.join(base, 'helper.py'), 0o755)
try:
    fd, _ = package_of(base, ep)
except ForbiddenContent:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('an executable file was accepted')
"

run_case "a symlink inside the package is refused, not followed" "${PRELUDE}
base, ep = make_package('symlink')
os.symlink('/etc/passwd', os.path.join(base, 'escape.py'))
try:
    fd, _ = package_of(base, ep)
except ForbiddenContent:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('a symlink was accepted')
"

run_case "a FIFO or socket in the package is refused" "${PRELUDE}
base, ep = make_package('fifo')
os.mkfifo(os.path.join(base, 'pipe'))
try:
    fd, _ = package_of(base, ep)
except ForbiddenContent:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('a FIFO was accepted')
"

run_case "a hard-linked package file is refused" "${PRELUDE}
base, ep = make_package('hardlink')
os.link(os.path.join(base, 'helper.py'), os.path.join(base, 'alias.py'))
try:
    fd, _ = package_of(base, ep)
except ForbiddenContent:
    print('OK')
else:
    os.close(fd)
    raise AssertionError('a hard-linked file was accepted')
"

# --- entrypoint ---------------------------------------------------------------

run_case "the entrypoint must exist, be relative, and end in .py" "${PRELUDE}
base, _ = make_package('entry')
for bad in ('/abs/main.py', '../main.py', 'data/../../main.py', 'missing.py',
            'data/table.json', 'main', '', 'data'):
    try:
        fd, _ = package_of(base, bad)
    except InvalidEntrypoint:
        continue
    os.close(fd)
    raise AssertionError(f'accepted entrypoint {bad!r}')
print('OK')
"

run_case "a nested governed entrypoint beneath the root is accepted" "${PRELUDE}
files = {'pkg/main.py': b'def run():\n    return {}\n', 'pkg/util.py': b'X = 1\n'}
base, _ = make_package('nested', files=files)
fd, binding = package_of(base, 'pkg/main.py')
os.close(fd)
assert binding.entrypoint == 'pkg/main.py'
print('OK')
"

# --- publication ---------------------------------------------------------------

run_case "publication creates the accepted per-CINV layout" "${PRELUDE}
hb, root, published, binding = publish('layout')
try:
    assert isinstance(published, HandoffBinding)
    cinv_dir = os.path.join(hb, 'root', 'CINV-000042')
    assert os.path.isdir(cinv_dir)
    assert os.path.isdir(os.path.join(cinv_dir, PACKAGE_DIRECTORY))
    assert os.path.isfile(os.path.join(cinv_dir, PAYLOAD_NAME))
    assert os.path.isdir(os.path.join(cinv_dir, OUTPUT_DIRECTORY))
    assert os.path.isfile(os.path.join(cinv_dir, PACKAGE_DIRECTORY, 'main.py'))
    assert os.path.isfile(os.path.join(cinv_dir, PACKAGE_DIRECTORY, 'data', 'table.json'))
finally:
    root.close()
print('OK')
"

run_case "the declared mode matrix matches the accepted §13 table" "${PRELUDE}
assert HANDOFF_MODES['invocation'] == 0o555, oct(HANDOFF_MODES['invocation'])
assert HANDOFF_MODES['package'] == 0o555
assert HANDOFF_MODES['package_file'] == 0o444
assert HANDOFF_MODES['payload'] == 0o444
assert HANDOFF_MODES['output'] == 0o700
print('OK')
"

run_case "published package bytes are exactly the validated bytes" "${PRELUDE}
hb, root, published, binding = publish('bytes')
try:
    for entry in binding.entries:
        with open(os.path.join(hb, 'root', 'CINV-000042', PACKAGE_DIRECTORY,
                               entry.relative_path), 'rb') as handle:
            assert sha(handle.read()) == entry.digest, entry.relative_path
    assert published.package_digest == binding.digest
finally:
    root.close()
print('OK')
"

run_case "published payload bytes and digest are exactly T3's" "${PRELUDE}
hb, root, published, binding = publish('payload')
try:
    binding_payload = payload_binding('payload')
    with open(os.path.join(hb, 'root', 'CINV-000042', PAYLOAD_NAME), 'rb') as handle:
        body = handle.read()
    assert body == binding_payload.canonical_bytes
    assert sha(body) == binding_payload.digest
    assert published.payload_digest == binding_payload.digest
finally:
    root.close()
print('OK')
"

run_case "the original JSON spelling cannot affect handoff bytes" "${PRELUDE}
# A different textual spelling of the same governed payload must publish
# byte-identically, because T3 already reduced it to canonical form.
hb = make_handoff_root('spelling')
root = anchor(hb)
spaced = os.path.join(WORK, 'spaced.json')
with open(spaced, 'wb') as handle:
    handle.write(b'{ \"arguments\" : { \"count\" : 3 } , \"operation\" : \"sum\" }')
fd = os.open(spaced, os.O_RDONLY)
try:
    other = validate_payload(fd, schema_version=1)
finally:
    os.close(fd)
pkg_base, ep = make_package('spelling-pkg')
pfd, binding = package_of(pkg_base, ep)
try:
    published = publish_handoff(root, 'CINV-000042', pfd, other, binding,
                                profile=governed_profile())
finally:
    os.close(pfd)
with open(os.path.join(hb, 'root', 'CINV-000042', PAYLOAD_NAME), 'rb') as handle:
    assert handle.read() == payload_binding('sp').canonical_bytes
assert published.payload_digest == payload_binding('sp2').digest
root.close()
print('OK')
"

run_case "publication copies rather than hard-linking the canonical inode" "${PRELUDE}
hb, root, published, binding = publish('copy')
try:
    pkg_source = os.path.join(WORK, 'copy-pkg', 'main.py')
    published_file = os.path.join(hb, 'root', 'CINV-000042',
                                  PACKAGE_DIRECTORY, 'main.py')
    assert os.stat(published_file).st_nlink == 1, 'published file is hard-linked'
    assert os.stat(published_file).st_ino != os.stat(pkg_source).st_ino, \
        'published file aliases the canonical inode'
    payload_file = os.path.join(hb, 'root', 'CINV-000042', PAYLOAD_NAME)
    assert os.stat(payload_file).st_nlink == 1
finally:
    root.close()
print('OK')
"

# --- races --------------------------------------------------------------------

run_case "replacing the source pathname cannot redirect published bytes" "${PRELUDE}
pkg_base, ep = make_package('srcrace')
hb = make_handoff_root('srcrace-hand')
root = anchor(hb)
fd, binding = package_of(pkg_base, ep)
# The name now refers to a different tree entirely.
moved = os.path.join(WORK, 'srcrace-moved')
os.rename(pkg_base, moved)
evil, _ = make_package('srcrace', files={
    'main.py': b'ATTACKER = True\n', 'helper.py': b'X = 9\n',
    'data/table.json': b'{\"a\":99}'})
try:
    published = publish_handoff(root, 'CINV-000042', fd, payload_binding('sr'),
                                binding, profile=governed_profile())
finally:
    os.close(fd)
with open(os.path.join(hb, 'root', 'CINV-000042', PACKAGE_DIRECTORY, 'main.py'), 'rb') as handle:
    body = handle.read()
assert b'ATTACKER' not in body, body
assert published.package_digest == binding.digest
root.close()
print('OK')
"

run_case "replacing the destination root pathname cannot redirect publication" "${PRELUDE}
hb = make_handoff_root('dstrace')
evil = make_handoff_root('dstrace-evil')
root = anchor(hb)
good = os.path.join(hb, 'root')
os.rename(good, os.path.join(hb, 'root-moved'))
os.rename(os.path.join(evil, 'root'), good)
pkg_base, ep = make_package('dstrace-pkg')
fd, binding = package_of(pkg_base, ep)
try:
    publish_handoff(root, 'CINV-000042', fd, payload_binding('dr'), binding,
                    profile=governed_profile())
finally:
    os.close(fd)
assert os.path.isdir(os.path.join(hb, 'root-moved', 'CINV-000042'))
assert not os.path.exists(os.path.join(good, 'CINV-000042'))
root.close()
print('OK')
"

# --- existing target and atomicity ---------------------------------------------

run_case "a pre-existing CINV handoff refuses and is left untouched" "${PRELUDE}
hb, root, published, binding = publish('exists')
try:
    marker = os.path.join(hb, 'root', 'CINV-000042', PAYLOAD_NAME)
    before = os.stat(marker).st_ino
    pkg_base, ep = make_package('exists-again')
    fd, second = package_of(pkg_base, ep)
    try:
        publish_handoff(root, 'CINV-000042', fd, payload_binding('ex2'), second,
                        profile=governed_profile())
    except HandoffTargetExists:
        pass
    else:
        raise AssertionError('an existing handoff was overwritten')
    finally:
        os.close(fd)
    assert os.stat(marker).st_ino == before, 'the existing handoff was replaced'
finally:
    root.close()
print('OK')
"

run_case "publication leaves no temporary residue" "${PRELUDE}
hb, root, published, binding = publish('residue')
try:
    names = os.listdir(os.path.join(hb, 'root'))
    assert names == ['CINV-000042'], names
    inner = sorted(os.listdir(os.path.join(hb, 'root', 'CINV-000042')))
    assert inner == sorted([PACKAGE_DIRECTORY, PAYLOAD_NAME, OUTPUT_DIRECTORY,
                            PROFILE_NAME]), inner
finally:
    root.close()
print('OK')
"

run_case "a failed publication never becomes authoritative" "${PRELUDE}
# The package binding disagrees with the tree that will be copied, so identity
# verification must fail after the bytes are staged but before installation.
pkg_base, ep = make_package('failpub')
hb = make_handoff_root('failpub-hand')
root = anchor(hb)
fd, binding = package_of(pkg_base, ep)
tampered = binding.__class__(
    entries=binding.entries, entry_count=binding.entry_count,
    aggregate_bytes=binding.aggregate_bytes, entrypoint=binding.entrypoint,
    digest='f' * 64)
try:
    publish_handoff(root, 'CINV-000042', fd, payload_binding('fp'), tampered,
                    profile=governed_profile())
except HandoffIdentityMismatch:
    pass
else:
    raise AssertionError('a mismatched publication succeeded')
finally:
    os.close(fd)
assert os.listdir(os.path.join(hb, 'root')) == [], os.listdir(os.path.join(hb, 'root'))
root.close()
print('OK')
"

run_case "publication fsyncs files and directories before installing" "${PRELUDE}
import ast, inspect
import tools.capability.execution.handoff as module
tree = ast.parse(inspect.getsource(module))
fsyncs = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
          and isinstance(n.func, ast.Attribute) and n.func.attr == 'fsync']
assert len(fsyncs) >= 2, f'only {len(fsyncs)} fsync sites'
fn = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
      and n.name == 'publish_handoff']
body = ast.unparse(fn[0])
assert 'os.rename' in body, 'publication is not rename-atomic'
assert body.index('os.rename') < body.rindex('os.fsync'), \
    'no directory fsync after the atomic install'
print('OK')
"

run_case "T7 creates no runtime, quarantine, admin, or image root" "${PRELUDE}
hb, root, published, binding = publish('noexpand')
try:
    names = set(os.listdir(os.path.join(hb, 'root')))
    for forbidden in ('mutations', 'transitions', 'locks', 'quarantine',
                      'admin-records', 'state', 'storage', 'images'):
        assert forbidden not in names, forbidden
finally:
    root.close()
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T7 package and handoff validation passed.\n'
else
  printf 'Capability execution T7 package and handoff validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
