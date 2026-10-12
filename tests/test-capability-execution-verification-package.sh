#!/usr/bin/env bash
set -Eeuo pipefail

# The governed boundary-verification package, and the contract it closes.
#
# CAPDEF-0001 declares the capability, CCON-0001 binds the governed execution
# payload to a bounded verification result, and nothing implemented either. This
# suite is the proof that one package tree does -- driven through the released
# authorities themselves rather than through a second copy of their rules.
#
# WHAT IS EXERCISED, AND BY WHOSE AUTHORITY:
#   package tree      tools/capability/execution/package_contract.py  (Gen 10)
#   tree reference    tools/capability/package_resolution.py          (Gen 10)
#   payload           tools/capability/execution/payload.py
#   canonical form    tools/capability/execution/canonical_json.py
#   result envelope   tools/capability/execution/collector.py
#   result content    tools/capability/execution/result_content.py
#   contract outcome  tools/capability/execution/contract_outcome.py
#   terminal state    tools/capability/execution/lifecycle.py
#   mount paths       tools/capability/execution/profile.py
#
# The entrypoint is imported from the tree and driven against fixture paths in a
# temporary directory. It is never executed against `/run/kyri` or `/kyri`, no
# container is created, no governance store is opened, and no privileged
# operation is attempted. The package tree itself is read; nothing writes to it.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  (§8, §9, §10, §11)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The governed package tree, its entrypoint, and the artifact root the tree
# reference is relative to. Written once here and read by every case below, so a
# suite that moved the tree cannot keep asserting against where it used to be.
ARTIFACT_ROOT="packages"
TREE_RELATIVE="kyri-execution-boundary-verification/1.0.0"
PACKAGE_TREE="${ARTIFACT_ROOT}/${TREE_RELATIVE}"
ENTRYPOINT="main.py"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_dir() {
  if [[ -d "${ROOT}/$1" ]]; then pass "directory exists: $1"; else fail "required directory missing: $1"; fi
}

assert_dir "${PACKAGE_TREE}"
assert_file "${PACKAGE_TREE}/${ENTRYPOINT}"

# ===========================================================================
# The tree, as committed
# ===========================================================================
# Git records the executable bit, so a package member that would be refused by
# the package contract must be refused before it is ever staged.

assert_tracked_modes() {
  local offenders
  offenders="$(cd "${ROOT}" && git ls-files -s -- "${PACKAGE_TREE}" \
    | awk '$1 != "100644" { print $1 " " $4 }')"
  if [[ -z "${offenders}" ]]; then
    pass "every tracked package member is a non-executable regular file"
  else
    fail "package members with a refused git mode: ${offenders}"
  fi
}

assert_tracked_modes

# ===========================================================================
# Package-tree contract -- the real Generation-10 authority
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
import hashlib, importlib.util, json, os, stat, sys
from pathlib import Path
from tempfile import TemporaryDirectory

from tools.capability.execution import canonical_json
from tools.capability.execution import collector as C
from tools.capability.execution import contract_outcome as CO
from tools.capability.execution import lifecycle as L
from tools.capability.execution import package_contract as PC
from tools.capability.execution import payload as P
from tools.capability.execution import profile as PROFILE
from tools.capability.execution import result_content as RC
from tools.capability import package_resolution as PR

ARTIFACT_ROOT = '${ARTIFACT_ROOT}'
TREE_RELATIVE = '${TREE_RELATIVE}'
PACKAGE_TREE = '${PACKAGE_TREE}'
ENTRYPOINT = '${ENTRYPOINT}'
CID = 'c' * 64

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY


def tree_fd():
    return os.open(PACKAGE_TREE, _DIR_FLAGS)


def inspected():
    handle = tree_fd()
    try:
        return PC.inspect_package(handle)
    finally:
        os.close(handle)


def bound(entrypoint=ENTRYPOINT):
    handle = tree_fd()
    try:
        return PC.validate_package(handle, entrypoint=entrypoint)
    finally:
        os.close(handle)


def entry_module():
    '''The committed entrypoint, loaded from the tree it will be staged from.

    Bytecode writes are disabled first. The container disables them too, with
    PYTHONDONTWRITEBYTECODE, which is what makes a read-only package mount
    viable -- and a cache directory written here would be a compiled member the
    package contract refuses, so loading the entrypoint would break the tree it
    was loaded from.
    '''
    sys.dont_write_bytecode = True
    location = os.path.join(PACKAGE_TREE, ENTRYPOINT)
    spec = importlib.util.spec_from_file_location('kyri_verification_entry',
                                                  location)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def governed_payload(document):
    '''One payload through the released validator, returning its binding.'''
    with TemporaryDirectory() as tmp:
        source = Path(tmp) / 'payload'
        source.write_bytes(json.dumps(document).encode('utf-8'))
        handle = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        try:
            return P.validate_payload(
                handle, schema_version=P.PAYLOAD_SCHEMA_VERSION)
        finally:
            os.close(handle)


DEFAULT_DOCUMENT = {'operation': 'verify-execution-boundary',
                    'arguments': {'count': 3, 'label': 'checkpoint'}}


def scene(tmp, payload_bytes=None, document=None):
    '''A fixture payload file and an empty output directory.'''
    if payload_bytes is None:
        payload_bytes = governed_payload(
            DEFAULT_DOCUMENT if document is None else document).canonical_bytes
    base = Path(tmp)
    payload_path = base / 'payload'
    payload_path.write_bytes(payload_bytes)
    out = base / 'out'
    out.mkdir(mode=0o700)
    return str(payload_path), str(out / C.RESULT_NAME)


def collect(out):
    handle = os.open(out, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        return C.collect(handle)
    finally:
        os.close(handle)


def terminal(exit_code=0, timed_out=False, started_proven=True):
    observed = L.LifecycleObservation(
        container_id=CID, state='exited',
        started_at='2026-08-24T00:00:00Z', finished_at='2026-08-24T00:00:01Z',
        exit_code=exit_code, started_proven=started_proven,
        exit_code_trustworthy=started_proven)
    return L.classify(observed, timed_out=timed_out)
"

# --- §8 bounds, membership, and the entrypoint ------------------------------

run_case "the tree satisfies the Generation-10 package contract" "${PRELUDE}
report = inspected()
assert report.entry_count >= 1, 'the tree holds no member'
assert report.entry_count <= PC.MAXIMUM_ENTRIES, report.entry_count
assert report.aggregate_bytes <= PC.MAXIMUM_AGGREGATE_BYTES, report.aggregate_bytes
for entry in report.entries:
    assert entry.size <= PC.MAXIMUM_FILE_BYTES, entry.relative_path
print('OK')
"

run_case "the tree is exactly the members the capability requires" "${PRELUDE}
names = sorted(entry.relative_path for entry in inspected().entries)
assert names == [ENTRYPOINT], names
print('OK')
"

# Every refusal the contract makes is structural, and a tree that satisfies it
# has none of them. Asserted over the real members rather than assumed from the
# fact that inspection returned.
run_case "no member is a symlink, a device, hard-linked, or executable" "${PRELUDE}
for path in sorted(Path(PACKAGE_TREE).rglob('*')):
    info = path.lstat()
    assert not stat.S_ISLNK(info.st_mode), path
    assert stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode), path
    if stat.S_ISREG(info.st_mode):
        assert info.st_nlink == 1, path
        assert not (info.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)), path
print('OK')
"

run_case "no member carries a forbidden suffix or forbidden magic" "${PRELUDE}
for entry in inspected().entries:
    body = (Path(PACKAGE_TREE) / entry.relative_path).read_bytes()
    PC._check_content(entry.relative_path, body)
print('OK')
"

run_case "the tree holds no empty directory the commitment cannot witness" "${PRELUDE}
for path in sorted(Path(PACKAGE_TREE).rglob('*')):
    if path.is_dir():
        assert any(child.is_file() for child in path.rglob('*')), path
print('OK')
"

run_case "the governed entrypoint resolves inside the tree" "${PRELUDE}
binding = bound()
assert binding.entrypoint == ENTRYPOINT, binding.entrypoint
assert binding.digest == inspected().digest, 'the identity moved'
print('OK')
"

run_case "an entrypoint the tree does not hold is refused" "${PRELUDE}
for candidate in ('absent.py', '/etc/passwd', '../main.py', 'main', ''):
    try:
        bound(candidate)
    except PC.InvalidEntrypoint:
        continue
    raise AssertionError('accepted ' + repr(candidate))
print('OK')
"

# The tree stays within the depth the staging plane will walk it at.
run_case "the tree is shallower than the staging depth bound" "${PRELUDE}
deepest = max(len(entry.relative_path.split('/')) for entry in inspected().entries)
assert deepest <= PR.PACKAGE_MAXIMUM_DEPTH, deepest
print('OK')
"

# --- the tree reference grammar ---------------------------------------------

run_case "the candidate tree reference satisfies the Generation-10 grammar" "${PRELUDE}
reference = 'tree:' + TREE_RELATIVE
resolved = PR._relative_from_reference(reference, PR._TREE_SCHEME)
assert resolved == TREE_RELATIVE, resolved
assert PR._relative_from_reference(reference, PR._FILE_SCHEME) is None, \
    'a tree reference must not resolve as a file reference'
print('OK')
"

# ===========================================================================
# The entrypoint: what it is, before what it does
# ===========================================================================
# The container mounts the package read-only and runs one interpreter on one
# file. There is no `tools` package inside it, so the entrypoint may import the
# standard library and nothing else -- and the standard-library surface it does
# import is the honest list rather than a trimmed version of somebody else's.

assert_entrypoint_authority() {
  local report
  report="$(python3 - "${ROOT}/${PACKAGE_TREE}/${ENTRYPOINT}" <<'SCANPY'
import ast
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
if not target.is_file():
    print("entrypoint-absent")
    raise SystemExit(0)

# Everything the entrypoint may reach. It reads one file, hashes bytes, and
# writes one file: nothing here can open a socket, start a process, read a
# clock, or produce a value that differs between two identical runs.
PERMITTED_IMPORTS = {"__future__", "hashlib", "json", "os", "stat", "sys"}

# A deterministic result may not depend on when it ran, where it ran, who ran
# it, or on any entropy source.
FORBIDDEN_CALLS = {
    "system", "popen", "spawn", "fork", "execv", "execve", "exec", "eval",
    "compile", "__import__", "getenv", "putenv", "unsetenv", "now", "today",
    "time", "monotonic", "time_ns", "gethostname", "uname", "getpid",
    "urandom", "random", "randint", "choice", "uuid1", "uuid4", "getuid",
    "geteuid", "chmod", "chown", "unlink", "remove", "rmdir", "rename",
    "symlink", "link", "mkdir", "makedirs", "connect", "socket", "urlopen",
}

# Nothing that names a runtime, a privilege path, a governance store, or a
# network may appear anywhere in the source, comments included.
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "socket",
                  "urllib", "http", "subprocess", "/var/lib/kyri", "/etc/kyri",
                  "environ", "getpass", "PYTHONPATH")

findings = []
source = target.read_text(encoding="utf-8")
tree = ast.parse(source)

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            root = alias.name.split(".")[0]
            if root not in PERMITTED_IMPORTS:
                findings.append(f"import outside the standard-library set: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        root = (node.module or "").split(".")[0]
        if node.level or root not in PERMITTED_IMPORTS:
            findings.append(f"import outside the standard-library set: {node.module}")
    elif isinstance(node, ast.Call):
        name = None
        if isinstance(node.func, ast.Attribute):
            name = node.func.attr
        elif isinstance(node.func, ast.Name):
            name = node.func.id
        if name in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {name}")

lowered = source.lower()
for token in FORBIDDEN_TEXT:
    if token in lowered:
        findings.append(f"forbidden token: {token}")

# A module-level docstring, then constants and functions. Nothing may run at
# import time except the `__main__` guard, so loading the file cannot be the
# side effect.
for node in tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef,
                         ast.ClassDef, ast.Assign, ast.AnnAssign, ast.Expr)):
        continue
    if isinstance(node, ast.If):
        continue
    findings.append(f"executable statement at module level: {type(node).__name__}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "the entrypoint imports only the standard library and reaches nothing else"
  else
    fail "entrypoint backstop found: ${report}"
  fi
}

assert_entrypoint_authority

# The container mounts are governed by profile.py. The entrypoint must name
# exactly those, and must not restate them as something similar.
run_case "the entrypoint names the governed mounts and no others" "${PRELUDE}
module = entry_module()
assert module.PAYLOAD_PATH == PROFILE.PAYLOAD_MOUNT, module.PAYLOAD_PATH
assert module.RESULT_PATH == PROFILE.OUTPUT_MOUNT + '/' + C.RESULT_NAME, \
    module.RESULT_PATH
print('OK')
"

# The three governed constants in the result are the released authority's, read
# from it rather than copied into a second place that can drift.
run_case "the entrypoint carries the governed capability, operation, and version" "${PRELUDE}
module = entry_module()
assert module.CAPABILITY == RC.VERIFICATION_CAPABILITY, module.CAPABILITY
assert module.OPERATION in RC.OPERATIONS, module.OPERATION
assert module.RESULT_SCHEMA_VERSION == RC.RESULT_CONTENT_SCHEMA_VERSION, \
    module.RESULT_SCHEMA_VERSION
assert module.PAYLOAD_MAXIMUM_BYTES == P.PAYLOAD_MAXIMUM_BYTES, \
    module.PAYLOAD_MAXIMUM_BYTES
print('OK')
"

# ===========================================================================
# Payload binding
# ===========================================================================
# The bytes at the payload mount are the canonical bytes the coordinator bound,
# so the digest the entrypoint takes over them is the governed payload identity
# and not a second opinion about it.

run_case "payload_digest is the governed payload identity" "${PRELUDE}
module = entry_module()
binding = governed_payload(DEFAULT_DOCUMENT)
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp, binding.canonical_bytes)
    document = module.verify(payload_path, result_path)
assert document['payload_digest'] == binding.digest, document['payload_digest']
assert document['payload_digest'] == hashlib.sha256(
    binding.canonical_bytes).hexdigest()
print('OK')
"

# Two payloads that differ only in spelling are one governed payload, so they
# must bind identically -- and two that differ in value must not.
run_case "the binding follows canonical identity, not source spelling" "${PRELUDE}
module = entry_module()
spaced = governed_payload(DEFAULT_DOCUMENT)
reordered = governed_payload({'arguments': {'label': 'checkpoint', 'count': 3},
                              'operation': 'verify-execution-boundary'})
assert spaced.canonical_bytes == reordered.canonical_bytes, 'canonicalisation moved'
different = governed_payload({'operation': 'verify-execution-boundary',
                              'arguments': {'count': 4}})
with TemporaryDirectory() as tmp:
    one, one_result = scene(tmp, spaced.canonical_bytes)
    first = module.verify(one, one_result)
with TemporaryDirectory() as tmp:
    two, two_result = scene(tmp, reordered.canonical_bytes)
    second = module.verify(two, two_result)
with TemporaryDirectory() as tmp:
    three, three_result = scene(tmp, different.canonical_bytes)
    third = module.verify(three, three_result)
assert first == second, 'one governed payload bound two ways'
assert third['payload_digest'] != first['payload_digest'], 'two payloads bound alike'
print('OK')
"

# ===========================================================================
# Result content and the checksum binding
# ===========================================================================

run_case "the result is a governed verification result" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    document = module.verify(payload_path, result_path)
returned = RC.validate_result_content(document)
assert returned == document, 'the validator altered the result'
assert document['capability'] == RC.VERIFICATION_CAPABILITY
assert document['operation'] == 'verify-execution-boundary'
assert document['result_schema_version'] == RC.RESULT_CONTENT_SCHEMA_VERSION
print('OK')
"

# The checksum commits to the rest of the result, so any reader holding only
# `result.json` can re-derive it. Re-derived here through the released
# canonical serialiser rather than through the entrypoint's own.
run_case "the checksum commits to the result body and is re-derivable" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    document = module.verify(payload_path, result_path)
body = {name: value for name, value in document.items() if name != 'checksum'}
expected = hashlib.sha256(canonical_json.serialise(body)).hexdigest()
assert document['checksum'] == expected, document['checksum']
assert document['checksum'] != document['payload_digest'], \
    'the checksum restates the payload digest'
print('OK')
"

# The entrypoint cannot import the released serialiser -- there is no `tools`
# package inside the container -- so the two must be proven to agree instead.
run_case "the entrypoint's canonical form is the released canonical form" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    document = module.verify(payload_path, result_path)
    written = Path(result_path).read_bytes()
assert written == canonical_json.serialise(dict(document)), 'the bytes disagree'
assert module.canonical(dict(document)) == canonical_json.serialise(dict(document))
print('OK')
"

run_case "identical input produces byte-identical output" "${PRELUDE}
module = entry_module()
bodies = []
for _ in range(3):
    with TemporaryDirectory() as tmp:
        payload_path, result_path = scene(tmp)
        module.verify(payload_path, result_path)
        bodies.append(Path(result_path).read_bytes())
assert len(set(bodies)) == 1, 'the entrypoint is not deterministic'
print('OK')
"

# ===========================================================================
# Contract closure -- the released collection and outcome path
# ===========================================================================

run_case "the written result is admitted by the envelope authority" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    module.verify(payload_path, result_path)
    out = str(Path(result_path).parent)
    tree = collect(out)
    assert tree.manifest.result_present, 'no root-level result was collected'
    assert tree.manifest.file_count == 1, tree.manifest.file_count
    trusted = C.read_result(tree, terminal())
RC.validate_result_content(dict(trusted.document))
print('OK')
"

run_case "the invocation presents through CCON-0001 as a success" "${PRELUDE}
module = entry_module()


class Outcome:
    def __init__(self, outcome_class, succeeded, output):
        self.outcome_class = outcome_class
        self.succeeded = succeeded
        self.output = output


with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    module.verify(payload_path, result_path)
    tree = collect(str(Path(result_path).parent))
    C.read_result(tree, terminal())
    mode = CO.contract_failure_mode(Outcome(CO.COMPLETED, True, tree))
assert mode is None, mode
print('OK')
"

# CCON-0001 declares its request and response shapes by naming the modules that
# enforce them and the version each implements. The package must implement the
# same versions, or the contract names an authority the package does not meet.
run_case "the package implements the versions CCON-0001 declares" "${PRELUDE}
module = entry_module()
assert P.PAYLOAD_SCHEMA_VERSION == 1, P.PAYLOAD_SCHEMA_VERSION
assert RC.RESULT_CONTENT_SCHEMA == 'kyri-execution-verification-result', \
    RC.RESULT_CONTENT_SCHEMA
assert RC.RESULT_CONTENT_SCHEMA_VERSION == 1, RC.RESULT_CONTENT_SCHEMA_VERSION
assert module.RESULT_SCHEMA_VERSION == RC.RESULT_CONTENT_SCHEMA_VERSION
print('OK')
"

# A refusal is not a success wearing a different exit code. Every failure mode
# CCON-0001 declares for a run that produced nothing is reachable from a state
# this package can actually be in.
run_case "a result-free output tree presents as result-missing" "${PRELUDE}
class Outcome:
    def __init__(self, outcome_class, succeeded, output):
        self.outcome_class = outcome_class
        self.succeeded = succeeded
        self.output = output


with TemporaryDirectory() as tmp:
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o700)
    tree = collect(str(out))
    assert not tree.manifest.result_present
    mode = CO.contract_failure_mode(Outcome(CO.COMPLETED, False, tree))
assert mode == 'result-missing', mode
print('OK')
"

run_case "a nonzero exit presents as a declared failure mode" "${PRELUDE}
class Outcome:
    def __init__(self, outcome_class, succeeded, output):
        self.outcome_class = outcome_class
        self.succeeded = succeeded
        self.output = output


mode = CO.contract_failure_mode(Outcome('provider-error', False, None))
assert mode == 'adapter-error', mode
print('OK')
"

# ===========================================================================
# Controlled failure semantics
# ===========================================================================
# The governed result schema is closed at five fields and none of them can say
# "this went wrong", so there is no valid result that reports a failure. Every
# refusal therefore leaves no result behind and returns nonzero, and the
# lifecycle -- not the document -- is what reports it.

run_case "an absent payload is refused and writes nothing" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    os.unlink(payload_path)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('an absent payload was accepted')
    assert not Path(result_path).exists(), 'a result was written anyway'
print('OK')
"

run_case "a payload that is not a regular file is refused" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    os.unlink(payload_path)
    os.mkdir(payload_path, 0o700)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('a directory was read as a payload')
    assert not Path(result_path).exists()
print('OK')
"

run_case "a symlinked payload is refused rather than followed" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    elsewhere = Path(tmp) / 'elsewhere'
    elsewhere.write_bytes(Path(payload_path).read_bytes())
    os.unlink(payload_path)
    os.symlink(elsewhere, payload_path)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('a symlinked payload was followed')
    assert not Path(result_path).exists()
print('OK')
"

run_case "an oversized payload is refused without being read whole" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    with open(payload_path, 'wb') as handle:
        handle.write(b'{\"operation\":\"verify-execution-boundary\",\"note\":\"')
        handle.write(b'x' * (P.PAYLOAD_MAXIMUM_BYTES + 16))
        handle.write(b'\"}')
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('an oversized payload was accepted')
    assert not Path(result_path).exists()
print('OK')
"

run_case "a payload that is not one JSON object is refused" "${PRELUDE}
module = entry_module()
for body in (b'', b'not json', b'[1,2,3]', b'\"text\"', b'null', b'{}{}',
             b'\xff\xfe'):
    with TemporaryDirectory() as tmp:
        payload_path, result_path = scene(tmp, body)
        try:
            module.verify(payload_path, result_path)
        except module.VerificationRefused:
            pass
        else:
            raise AssertionError('accepted ' + repr(body))
        assert not Path(result_path).exists()
print('OK')
"

# The operation is the one field the entrypoint must agree with to name
# honestly what it performed. A payload asking for anything else is a request
# this capability cannot serve, and the closed result schema has no way to say
# so -- so it refuses.
run_case "a payload requesting another operation is refused" "${PRELUDE}
module = entry_module()
for operation in ('verify-something-else', '', 'VERIFY-EXECUTION-BOUNDARY',
                  'verify-execution-boundary '):
    body = json.dumps({'operation': operation,
                       'arguments': {'count': 1}}).encode('utf-8')
    with TemporaryDirectory() as tmp:
        payload_path, result_path = scene(tmp, body)
        try:
            module.verify(payload_path, result_path)
        except module.VerificationRefused:
            pass
        else:
            raise AssertionError('accepted operation ' + repr(operation))
        assert not Path(result_path).exists()
print('OK')
"

run_case "an existing result is never overwritten" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    Path(result_path).write_bytes(b'{\"planted\":true}')
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('an existing result was replaced')
    assert Path(result_path).read_bytes() == b'{\"planted\":true}'
print('OK')
"

run_case "a symlinked result path is refused rather than followed" "${PRELUDE}
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    target = Path(tmp) / 'target'
    os.symlink(target, result_path)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('a symlinked result path was followed')
    assert not target.exists(), 'the link was written through'
print('OK')
"

# A refusal is reported by the process, because the result document cannot
# report one. `main` is what the container runs, so that is what is checked.
run_case "main returns zero on success and nonzero on refusal" "${PRELUDE}
import contextlib, io
module = entry_module()
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    module.PAYLOAD_PATH = payload_path
    module.RESULT_PATH = result_path
    assert module.main() == 0, 'a governed run did not return zero'
    assert Path(result_path).exists()
    reported = io.StringIO()
    with contextlib.redirect_stderr(reported):
        assert module.main() != 0, 'a second run overwrote and returned zero'
assert reported.getvalue().startswith('refused: '), reported.getvalue()
print('OK')
"

# ===========================================================================
# What the package does not touch
# ===========================================================================

run_case "verification mutates nothing outside the result it writes" "${PRELUDE}
module = entry_module()


def inventory(where):
    seen = {}
    for path in sorted(Path(where).rglob('*')):
        info = path.lstat()
        seen[str(path)] = (info.st_mode, info.st_size, info.st_ino, info.st_nlink)
    return seen


with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    before = inventory(tmp)
    module.verify(payload_path, result_path)
    after = inventory(tmp)
assert set(after) - set(before) == {result_path}, sorted(set(after) - set(before))
assert not set(before) - set(after), 'something was removed'
for name, facts in before.items():
    assert after[name] == facts, name
print('OK')
"

run_case "the package tree is unchanged by exercising it" "${PRELUDE}
module = entry_module()
before = inspected().digest
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp)
    module.verify(payload_path, result_path)
assert inspected().digest == before, 'the package tree moved'
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All verification-package assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
