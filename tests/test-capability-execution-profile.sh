#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T8.
#
# T8 defines WHAT the governed sandbox must be. It does not create one: no
# Podman, no subprocess, no namespace, no mount, no filesystem mutation, no
# host contact -- and NO EXECUTION.
#
# THE PROFILE IS ADAPTER-OWNED. Capability metadata that asks for a different
# network, image, mount, device, capability, or resource limit is REFUSED, not
# ignored. A silently dropped request looks identical to a request that was
# never made, and only one of those is safe to be wrong about.
#
# VERIFICATION IS EXACT. There is no "close enough", no normalisation that
# weakens a control, and no filling a missing observation from the expected
# value -- expecting a control is not evidence Podman enforced it.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §12, §17
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/profile.py"

# ===========================================================================
# The T8 purity backstop
# ===========================================================================

assert_pure_profile() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/profile.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib", "os", "sys", "fcntl",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "open", "__import__",
    "getenv", "putenv", "chmod", "chown", "mkdir", "makedirs", "remove",
    "unlink", "rename", "rmdir", "write", "read", "fsync", "now", "today",
    "monotonic", "uuid1", "uuid4", "normalize", "scandir", "stat",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

findings = []
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

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T8 is pure: no I/O, clock, environment, or execution surface"
  else
    fail "T8 purity backstop found: ${report}"
  fi
}

assert_pure_profile

# ===========================================================================
# Behaviour
# ===========================================================================

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

PRELUDE="
import dataclasses, hashlib
from tools.capability.execution.types import ExecutionProfile, ExecutionFingerprint
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.profile import (
    build_profile, fingerprint, verify_observed, canonical_profile,
    ProfileBinding, Mount, ProfileError, MetadataOverrideRefused,
    ProfileMismatch, UnsupportedProfileSchema, ObservedProfile,
    PROFILE_SCHEMA_VERSION, EXECUTION_UID, EXECUTION_GID, HOSTNAME,
    MEMORY_BYTES, MEMORY_SWAP_BYTES, CPU_QUOTA_US, CPU_PERIOD_US, CPUS,
    PIDS_LIMIT, TIMEOUT_SECONDS, GRACE_SECONDS, TMPFS_BYTES, TMPFS_MODE,
    TMPFS_OPTIONS, PACKAGE_MOUNT, PAYLOAD_MOUNT, OUTPUT_MOUNT)
from tools.capability.execution.types import Classification

IMAGE = 'sha256:' + 'a' * 64

def admission(cimp='CIMP-000001', image=IMAGE):
    return Admission(cimp=cimp, oci_digest=image,
                     adapter_identity='python-podman-v1',
                     payload_schema_version=1,
                     execution_profile_schema_version=PROFILE_SCHEMA_VERSION,
                     argv_contract_identity='fixed-python-entrypoint-v1',
                     provisioning_evidence_digest='b' * 64)

def binding(cinv='CINV-000042', **kw):
    return ProfileBinding(cinv=cinv, admission=admission(**kw))

def profile(**kw):
    return build_profile(binding(**kw))

def observed_from(p, **overrides):
    fields = dict(
        image_digest=p.image_digest, network=p.network,
        read_only_rootfs=p.read_only_rootfs,
        no_new_privileges=p.no_new_privileges,
        dropped_capabilities=p.dropped_capabilities,
        effective_capabilities=(),
        memory_bytes=p.memory_bytes, memory_swap_bytes=p.memory_swap_bytes,
        cpu_quota_us=p.cpu_quota_us, cpu_period_us=p.cpu_period_us,
        pids_limit=p.pids_limit, execution_uid=p.execution_uid,
        execution_gid=p.execution_gid, hostname=p.hostname,
        mounts=p.mounts, devices=p.devices, sockets=(),
        tmpfs_bytes=p.tmpfs_bytes, tmpfs_mode=p.tmpfs_mode,
        tmpfs_options=p.tmpfs_options,
        profile_schema_version=p.profile_schema_version)
    fields.update(overrides)
    return ObservedProfile(**fields)
"

# --- fixed constants ---------------------------------------------------------

run_case "the accepted v1 constants are exactly the specification's" "${PRELUDE}
assert PROFILE_SCHEMA_VERSION == 1
assert MEMORY_BYTES == 256 * 1024 * 1024, MEMORY_BYTES
assert MEMORY_SWAP_BYTES == 256 * 1024 * 1024
assert CPUS == '0.5', CPUS
assert (CPU_QUOTA_US, CPU_PERIOD_US) == (50000, 100000)
assert PIDS_LIMIT == 64
assert TIMEOUT_SECONDS == 30
assert GRACE_SECONDS == 2
assert TMPFS_BYTES == 16 * 1024 * 1024
assert TMPFS_MODE == 0o1777, oct(TMPFS_MODE)
assert TMPFS_OPTIONS == ('noexec', 'nosuid', 'nodev'), TMPFS_OPTIONS
assert EXECUTION_UID != 0 and EXECUTION_GID != 0, 'container identity must be non-root'
print('OK')
"

run_case "the built profile carries the fixed security controls" "${PRELUDE}
p = profile()
assert isinstance(p, ExecutionProfile)
assert p.network == 'none'
assert p.read_only_rootfs is True
assert p.no_new_privileges is True
assert p.cap_drop_all is True
assert p.dropped_capabilities == ('ALL',)
assert p.devices == ()
assert p.sockets == ()
assert p.privileged is False
assert p.host_network is False
assert p.host_pid is False
assert p.gpu is False
assert p.pids_limit == PIDS_LIMIT
assert p.memory_bytes == MEMORY_BYTES and p.memory_swap_bytes == MEMORY_SWAP_BYTES
assert p.cpu_quota_us == CPU_QUOTA_US and p.cpu_period_us == CPU_PERIOD_US
assert p.timeout_seconds == TIMEOUT_SECONDS and p.grace_seconds == GRACE_SECONDS
assert p.execution_uid == EXECUTION_UID and p.execution_gid == EXECUTION_GID
assert p.hostname == HOSTNAME
assert p.profile_schema_version == PROFILE_SCHEMA_VERSION
print('OK')
"

run_case "the mount topology is exactly package ro, payload ro, output rw" "${PRELUDE}
p = profile()
by_dest = {m.destination: m for m in p.mounts}
assert set(by_dest) == {'/kyri/package', '/run/kyri/input/payload', '/kyri/output'}, by_dest
assert by_dest['/kyri/package'].read_only is True
assert by_dest['/run/kyri/input/payload'].read_only is True
assert by_dest['/kyri/output'].read_only is False
assert (PACKAGE_MOUNT, PAYLOAD_MOUNT, OUTPUT_MOUNT) == (
    '/kyri/package', '/run/kyri/input/payload', '/kyri/output')
print('OK')
"

run_case "the profile is immutable" "${PRELUDE}
p = profile()
for field in ('network', 'pids_limit', 'memory_bytes'):
    try:
        setattr(p, field, 'x')
    except Exception:
        continue
    raise AssertionError(f'ExecutionProfile.{field} was mutated')
try:
    p.mounts[0].read_only = False
except Exception:
    pass
else:
    raise AssertionError('a mount was mutated')
print('OK')
"

# --- canonical representation and digest --------------------------------------

run_case "the canonical representation is deterministic across constructions" "${PRELUDE}
a, b = profile(), profile()
assert canonical_profile(a) == canonical_profile(b)
assert isinstance(canonical_profile(a), bytes)
assert fingerprint(a).profile_digest == fingerprint(b).profile_digest
print('OK')
"

run_case "the digest is SHA-256 of the canonical bytes, not of a repr" "${PRELUDE}
p = profile()
fp = fingerprint(p)
assert isinstance(fp, ExecutionFingerprint)
assert fp.profile_digest == hashlib.sha256(canonical_profile(p)).hexdigest()
assert fp.profile_digest != hashlib.sha256(repr(p).encode()).hexdigest()
print('OK')
"

run_case "the fingerprint carries the explicit security-critical fields too" "${PRELUDE}
fp = fingerprint(profile())
assert fp.image_digest == IMAGE
assert fp.cimp == 'CIMP-000001'
assert fp.profile_schema_version == PROFILE_SCHEMA_VERSION
assert fp.execution_uid == EXECUTION_UID and fp.execution_gid == EXECUTION_GID
print('OK')
"

run_case "capability-set order is semantically irrelevant and does not alter the digest" "${PRELUDE}
p = profile()
reordered = dataclasses.replace(p, dropped_capabilities=tuple(
    reversed(p.dropped_capabilities)))
assert canonical_profile(p) == canonical_profile(reordered), 'set order changed the digest'
# Mount order is likewise canonicalised by destination, not by report order.
shuffled = dataclasses.replace(p, mounts=tuple(reversed(p.mounts)))
assert canonical_profile(p) == canonical_profile(shuffled)
print('OK')
"

run_case "every security-critical field change alters the digest" "${PRELUDE}
p = profile()
base = fingerprint(p).profile_digest
changes = {
    'network': 'bridge', 'read_only_rootfs': False, 'no_new_privileges': False,
    'cap_drop_all': False, 'memory_bytes': 257 * 1024 * 1024,
    'memory_swap_bytes': 512 * 1024 * 1024, 'cpu_quota_us': 100000,
    'cpu_period_us': 50000, 'pids_limit': 4096, 'timeout_seconds': 60,
    'grace_seconds': 5, 'execution_uid': 0, 'execution_gid': 0,
    'hostname': 'other', 'tmpfs_bytes': 32 * 1024 * 1024,
    'tmpfs_mode': 0o777, 'tmpfs_options': ('noexec',),
    'profile_schema_version': 2, 'image_digest': 'sha256:' + 'b' * 64,
    'cimp': 'CIMP-000002', 'adapter_identity': 'other-v2',
    'payload_schema_version': 9, 'privileged': True, 'host_network': True,
    'host_pid': True, 'gpu': True, 'devices': ('/dev/nvidia0',),
    'sockets': ('/run/podman.sock',),
    'dropped_capabilities': ('CHOWN',),
}
for field, value in changes.items():
    altered = dataclasses.replace(p, **{field: value})
    assert fingerprint(altered).profile_digest != base, f'{field} did not alter the digest'
# And a mount attribute change.
mounts = list(p.mounts)
mounts[0] = dataclasses.replace(mounts[0], read_only=not mounts[0].read_only)
assert fingerprint(dataclasses.replace(p, mounts=tuple(mounts))).profile_digest != base
print('OK')
"

run_case "non-authoritative metadata is excluded from the digest" "${PRELUDE}
# The profile has no field for any of these, which is the strongest form of
# exclusion: there is nothing to accidentally hash.
names = {f.name for f in dataclasses.fields(ExecutionProfile)}
for banned in ('container_id', 'pid', 'created_at', 'started_at', 'inode',
               'timestamp', 'labels', 'host_load'):
    assert banned not in names, banned
import json
keys = set(json.loads(canonical_profile(profile()).decode('utf-8')))
for banned in ('container_id', 'created_at', 'started_at', 'timestamp', 'pid',
               'inode', 'labels', 'host_load'):
    assert banned not in keys, banned
print('OK')
"

run_case "the CINV association is bound into the fingerprint context" "${PRELUDE}
a = fingerprint(build_profile(binding(cinv='CINV-000042')))
b = fingerprint(build_profile(binding(cinv='CINV-000043')))
assert a.cinv == 'CINV-000042' and b.cinv == 'CINV-000043'
assert a != b
print('OK')
"

# --- metadata override refusal -------------------------------------------------

run_case "metadata attempting to set a governed control is refused, not ignored" "${PRELUDE}
attempts = [
    {'network': 'host'}, {'memory': '1g'}, {'memory_bytes': 1}, {'cpus': '4'},
    {'pids_limit': 4096}, {'privileged': True}, {'devices': ['/dev/nvidia0']},
    {'cap_add': ['SYS_ADMIN']}, {'mounts': [{'src': '/', 'dst': '/host'}]},
    {'image': 'alpine:latest'}, {'oci_digest': 'sha256:' + 'c' * 64},
    {'user': '0:0'}, {'hostname': 'attacker'}, {'read_only': False},
    {'security_opt': ['seccomp=unconfined']}, {'timeout_seconds': 3600},
]
for metadata in attempts:
    try:
        build_profile(binding(), metadata=metadata)
    except MetadataOverrideRefused as error:
        assert list(metadata)[0] in str(error), (metadata, str(error))
        continue
    raise AssertionError(f'metadata {metadata} was accepted')
print('OK')
"

run_case "unrelated metadata is still refused rather than silently dropped" "${PRELUDE}
# The contract is refusal, not filtering: a caller that sent anything at all
# believed it would take effect.
try:
    build_profile(binding(), metadata={'harmless_note': 'hello'})
except MetadataOverrideRefused:
    print('OK')
else:
    raise AssertionError('unknown metadata was silently ignored')
"

run_case "there is no override surface on the builder itself" "${PRELUDE}
import inspect
params = list(inspect.signature(build_profile).parameters)
assert params == ['binding', 'metadata'], params
assert inspect.signature(build_profile).parameters['metadata'].default is None
print('OK')
"

# --- observed verification ------------------------------------------------------

run_case "an exactly matching observation verifies" "${PRELUDE}
p = profile()
assert verify_observed(p, observed_from(p)) is None
print('OK')
"

run_case "each security-critical mismatch is refused" "${PRELUDE}
p = profile()
mismatches = {
    'network': 'bridge', 'image_digest': 'sha256:' + 'b' * 64,
    'read_only_rootfs': False, 'no_new_privileges': False,
    'memory_bytes': 257 * 1024 * 1024, 'memory_swap_bytes': 1,
    'cpu_quota_us': 100000, 'cpu_period_us': 1000, 'pids_limit': 4096,
    'execution_uid': 0, 'execution_gid': 0, 'hostname': 'other',
    'tmpfs_bytes': 1, 'tmpfs_mode': 0o777, 'tmpfs_options': ('noexec',),
    'profile_schema_version': 2, 'devices': ('/dev/nvidia0',),
    'sockets': ('/run/podman/podman.sock',),
    'effective_capabilities': ('CAP_SYS_ADMIN',),
    'dropped_capabilities': (),
}
for field, value in mismatches.items():
    try:
        verify_observed(p, observed_from(p, **{field: value}))
    except ProfileMismatch as error:
        assert error.classification is Classification.EXECUTION_IDENTITY_MISMATCH
        assert field in error.differing_fields, (field, error.differing_fields)
        continue
    raise AssertionError(f'{field} mismatch was accepted')
print('OK')
"

run_case "a mount mismatch is refused, including a flipped access mode" "${PRELUDE}
p = profile()
mounts = list(p.mounts)
index = next(i for i, m in enumerate(mounts) if m.destination == '/kyri/package')
mounts[index] = dataclasses.replace(mounts[index], read_only=False)
try:
    verify_observed(p, observed_from(p, mounts=tuple(mounts)))
except ProfileMismatch as error:
    assert 'mounts' in error.differing_fields
else:
    raise AssertionError('a writable package mount was accepted')
# An extra mount is also a mismatch.
extra = tuple(list(p.mounts) + [Mount(destination='/host', read_only=False,
                                      source_kind='bind')])
try:
    verify_observed(p, observed_from(p, mounts=extra))
except ProfileMismatch:
    print('OK')
else:
    raise AssertionError('an extra mount was accepted')
"

run_case "mount comparison is by destination, not by report order" "${PRELUDE}
p = profile()
assert verify_observed(p, observed_from(p, mounts=tuple(reversed(p.mounts)))) is None
print('OK')
"

run_case "a missing observed field fails rather than being filled from expectation" "${PRELUDE}
p = profile()
for field in ('network', 'read_only_rootfs', 'pids_limit', 'memory_bytes',
              'no_new_privileges', 'execution_uid', 'mounts'):
    try:
        verify_observed(p, observed_from(p, **{field: None}))
    except ProfileMismatch as error:
        assert field in error.differing_fields, (field, error.differing_fields)
        continue
    raise AssertionError(f'a missing {field} was filled from the expected profile')
print('OK')
"

run_case "the mismatch report is bounded, deterministic, and metadata-only" "${PRELUDE}
p = profile()
try:
    verify_observed(p, observed_from(p, network='bridge', pids_limit=4096))
except ProfileMismatch as error:
    assert error.differing_fields == ('network', 'pids_limit'), error.differing_fields
    text = str(error)
    assert len(text) < 2048, len(text)
    for leak in ('payload', 'result', 'secret', 'operation'):
        assert leak not in text.lower(), leak
    # Deterministic: the same mismatch reports the same way.
    try:
        verify_observed(p, observed_from(p, network='bridge', pids_limit=4096))
    except ProfileMismatch as again:
        assert str(again) == text and again.differing_fields == error.differing_fields
    print('OK')
else:
    raise AssertionError('a double mismatch verified')
"

# --- schema version ---------------------------------------------------------------

run_case "an unsupported profile schema version is refused" "${PRELUDE}
p = profile()
for version in (0, 2, 99, -1):
    altered = dataclasses.replace(p, profile_schema_version=version)
    try:
        verify_observed(altered, observed_from(altered))
    except UnsupportedProfileSchema as error:
        assert error.classification is Classification.EXECUTION_PROFILE_VERSION_UNSUPPORTED
        continue
    raise AssertionError(f'schema version {version} was verified with v1 semantics')
print('OK')
"

run_case "an admission declaring a different profile schema refuses at build" "${PRELUDE}
from tools.capability.execution.implementation_authority import Admission
bad = ProfileBinding(cinv='CINV-000042', admission=Admission(
    cimp='CIMP-000001', oci_digest=IMAGE, adapter_identity='python-podman-v1',
    payload_schema_version=1, execution_profile_schema_version=2,
    argv_contract_identity='fixed-python-entrypoint-v1',
    provisioning_evidence_digest='b' * 64))
try:
    build_profile(bad)
except UnsupportedProfileSchema:
    print('OK')
else:
    raise AssertionError('an admission naming schema 2 built a v1 profile')
"

run_case "T8 exposes no execution or I/O authority" "${PRELUDE}
import types as pytypes
import tools.capability.execution.profile as module
functions = [n for n, v in vars(module).items()
             if isinstance(v, pytypes.FunctionType) and not n.startswith('_')]
assert sorted(functions) == ['build_profile', 'canonical_profile',
                             'fingerprint', 'verify_observed'], functions
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T8 profile validation passed.\n'
else
  printf 'Capability execution T8 profile validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
