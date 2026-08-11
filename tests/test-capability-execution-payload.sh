#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T3.
#
# T3 is payload validation and identity: read bounded bytes from an
# already-open trusted descriptor, parse them through the T2 canonical layer,
# validate against a governed closed schema chosen by the caller, and bind the
# result to a SHA-256 of the canonical bytes.
#
# T3 OWNS PAYLOAD IDENTITY. The digest established here is authoritative; T7
# later proves the handoff copy still matches it and must not redefine it.
#
# T3 IS DESCRIPTOR-ONLY. It reads the descriptor it is handed and has no way
# to name, resolve, reopen, or follow a source pathname -- proven statically by
# the backstop below and behaviourally by the replacement race case. There is
# no staging, no mount, no handoff, no lifecycle, and NO EXECUTION.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §10
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/payload.py"

# ===========================================================================
# The T3 authority backstop
# ===========================================================================
# T3 may read a descriptor -- that is its job. It may not acquire the ability
# to name a path. The distinction is the whole point of the increment, so it
# is proven by inspection rather than trusted.

assert_no_path_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/payload.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib",
}
# Reading a descriptor is permitted; naming a path is not. These are the calls
# that would turn a descriptor-only module into a path-resolving one.
FORBIDDEN_CALLS = {
    "open", "fdopen", "system", "popen", "exec", "eval", "compile",
    "__import__", "getenv", "putenv", "chmod", "chown", "mkdir", "makedirs",
    "remove", "unlink", "rename", "rmdir", "readlink", "realpath", "abspath",
    "expanduser", "listdir", "scandir", "walk", "now", "today", "monotonic",
    "uuid1", "uuid4", "normalize", "stat", "lstat",
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

# os.read and os.close are the only os surfaces T3 is permitted.
permitted_os = {"read", "close"}
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
            and node.value.id == "os" and node.attr not in permitted_os:
        findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T3 has no path-resolution authority: descriptor reads only"
  else
    fail "T3 authority backstop found: ${report}"
  fi
}

assert_no_path_authority

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

# The harness opens files and hands over descriptors, because opening is the
# caller's authority and never T3's.
PRELUDE="
import hashlib, os
from tools.capability.execution.payload import (
    validate_payload, PayloadBinding, PayloadError, SchemaViolation,
    UnsupportedSchemaVersion, PAYLOAD_MAXIMUM_BYTES)
from tools.capability.execution.canonical_json import CanonicalJSONError
# T3 lets T2's refusals propagate with their exact type rather than wrapping
# them, so a caller learns which rule was broken. Both families are therefore
# legitimate outcomes and the default expectation covers both.
REFUSAL = (PayloadError, CanonicalJSONError)
WORK = os.environ['WORKDIR']
def fd_for(data, name='p.json'):
    path = os.path.join(WORK, name)
    with open(path, 'wb') as handle:
        handle.write(data)
    return os.open(path, os.O_RDONLY), path
def refuses(data, schema_version=1, expect=REFUSAL):
    fd, _ = fd_for(data)
    try:
        validate_payload(fd, schema_version=schema_version)
    except expect:
        return True
    except Exception as error:
        raise AssertionError(f'wrong error: {type(error).__name__}: {error}')
    finally:
        os.close(fd)
    return False
VALID = b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}'
"

# --- acceptance and canonical identity -------------------------------------

run_case "accepts a valid governed payload" "${PRELUDE}
fd, _ = fd_for(VALID)
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert isinstance(binding, PayloadBinding)
assert binding.document == {'operation': 'sum', 'arguments': {'count': 3}}
assert binding.schema_version == 1
print('OK')
"

run_case "canonical bytes are the canonical serialisation, not the source text" "${PRELUDE}
fd, _ = fd_for(b'{ \"arguments\" : { \"count\" : 3 } , \"operation\" : \"sum\" }')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.canonical_bytes == b'{\"arguments\":{\"count\":3},\"operation\":\"sum\"}', binding.canonical_bytes
print('OK')
"

run_case "digest is SHA-256 of the canonical bytes" "${PRELUDE}
fd, _ = fd_for(VALID)
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.digest == hashlib.sha256(binding.canonical_bytes).hexdigest()
assert binding.digest != hashlib.sha256(VALID).hexdigest(), 'digest was taken over source spelling'
print('OK')
"

run_case "equivalent spellings bind to one identical digest" "${PRELUDE}
spellings = [
    b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}',
    b'{ \"operation\" : \"sum\" , \"arguments\" : { \"count\" : 3 } }',
    b'{\n  \"operation\": \"sum\",\n  \"arguments\": {\n    \"count\": 3\n  }\n}',
    b'{\"arguments\":{\"count\":3},\"operation\":\"sum\"}',
]
digests = set()
for index, data in enumerate(spellings):
    fd, _ = fd_for(data, f's{index}.json')
    binding = validate_payload(fd, schema_version=1)
    os.close(fd)
    digests.add(binding.digest)
assert len(digests) == 1, digests
print('OK')
"

run_case "distinct logical payloads bind to distinct digests" "${PRELUDE}
a_fd, _ = fd_for(b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}', 'a.json')
b_fd, _ = fd_for(b'{\"operation\":\"sum\",\"arguments\":{\"count\":4}}', 'b.json')
c_fd, _ = fd_for(b'{\"operation\":\"diff\",\"arguments\":{\"count\":3}}', 'c.json')
digests = set()
for fd in (a_fd, b_fd, c_fd):
    digests.add(validate_payload(fd, schema_version=1).digest)
    os.close(fd)
assert len(digests) == 3, digests
print('OK')
"

# --- descriptor discipline -------------------------------------------------

run_case "reads only the descriptor: replacing the path afterwards changes nothing" "${PRELUDE}
path = os.path.join(WORK, 'race.json')
with open(path, 'wb') as handle:
    handle.write(VALID)
fd = os.open(path, os.O_RDONLY)
# The classic swap: the name now refers to different, still-schema-valid bytes.
os.remove(path)
with open(path, 'wb') as handle:
    handle.write(b'{\"operation\":\"attacker\",\"arguments\":{\"count\":99}}')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.document['operation'] == 'sum', binding.document
assert binding.document['arguments']['count'] == 3
assert binding.digest == hashlib.sha256(
    b'{\"arguments\":{\"count\":3},\"operation\":\"sum\"}').hexdigest()
print('OK')
"

run_case "unlinking the source before validation does not prevent the read" "${PRELUDE}
path = os.path.join(WORK, 'gone.json')
with open(path, 'wb') as handle:
    handle.write(VALID)
fd = os.open(path, os.O_RDONLY)
os.remove(path)
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.document['operation'] == 'sum'
print('OK')
"

run_case "takes no pathname argument" "${PRELUDE}
import inspect
signature = inspect.signature(validate_payload)
names = list(signature.parameters)
assert names == ['descriptor', 'schema_version'], names
assert signature.parameters['schema_version'].kind.name == 'KEYWORD_ONLY'
print('OK')
"

# --- bounds ----------------------------------------------------------------

run_case "the accepted maximum is 2 MiB" "${PRELUDE}
assert PAYLOAD_MAXIMUM_BYTES == 2 * 1024 * 1024, PAYLOAD_MAXIMUM_BYTES
print('OK')
"

run_case "refuses a source over the bound" "${PRELUDE}
filler = b'x' * (2 * 1024 * 1024)
oversize = b'{\"operation\":\"' + filler + b'\",\"arguments\":{\"count\":3}}'
assert len(oversize) > PAYLOAD_MAXIMUM_BYTES
assert refuses(oversize)
print('OK')
"

run_case "the source read is bounded, not read-then-measure" "${PRELUDE}
# A descriptor far larger than the bound. An unbounded read would pull all of
# it into memory before noticing; a bounded read stops just past the limit.
path = os.path.join(WORK, 'huge.json')
with open(path, 'wb') as handle:
    handle.write(b'{\"operation\":\"' + b'x' * (8 * 1024 * 1024) + b'\"}')
fd = os.open(path, os.O_RDONLY)
try:
    validate_payload(fd, schema_version=1)
except REFUSAL:
    consumed = os.lseek(fd, 0, os.SEEK_CUR)
    assert consumed <= PAYLOAD_MAXIMUM_BYTES + 1, f'read {consumed} bytes past the bound'
    print('OK')
finally:
    os.close(fd)
"

run_case "accepts a payload sized exactly at the bound" "${PRELUDE}
prefix = b'{\"arguments\":{\"count\":3},\"operation\":\"'
suffix = b'\"}'
filler = PAYLOAD_MAXIMUM_BYTES - len(prefix) - len(suffix)
exact = prefix + b'x' * filler + suffix
assert len(exact) == PAYLOAD_MAXIMUM_BYTES
fd, _ = fd_for(exact, 'exact.json')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert len(binding.canonical_bytes) == PAYLOAD_MAXIMUM_BYTES
print('OK')
"

# --- canonical JSON reuse --------------------------------------------------

run_case "canonical rules are inherited from T2, not reimplemented" "${PRELUDE}
assert refuses(b'[]')
assert refuses(b'{\"operation\":\"sum\",\"operation\":\"sum\",\"arguments\":{\"count\":3}}')
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":1.5}}')
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":9223372036854775808}}')
assert refuses(b'{\"operation\":\"\\\\u0000\",\"arguments\":{\"count\":3}}')
assert refuses(b'{\"operation\":\"\\\\ud800\",\"arguments\":{\"count\":3}}')
assert refuses(b'{\"operation\":\"\xff\",\"arguments\":{\"count\":3}}')
print('OK')
"

run_case "T3 does not carry its own JSON parser" "${PRELUDE}
import tools.capability.execution.payload as module
source = open(module.__file__, 'rb').read().decode('utf-8')
assert 'import json' not in source, 'T3 imports json directly'
assert 'canonical_json' in source, 'T3 does not use the T2 layer'
print('OK')
"

# --- closed schema ---------------------------------------------------------

run_case "unknown top-level field refuses" "${PRELUDE}
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":3},\"extra\":1}',
               expect=SchemaViolation)
print('OK')
"

run_case "unknown nested field refuses -- nested objects stay closed" "${PRELUDE}
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":3,\"extra\":1}}',
               expect=SchemaViolation)
print('OK')
"

run_case "missing required field refuses, at both levels" "${PRELUDE}
assert refuses(b'{\"arguments\":{\"count\":3}}', expect=SchemaViolation)
assert refuses(b'{\"operation\":\"sum\"}', expect=SchemaViolation)
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{}}', expect=SchemaViolation)
print('OK')
"

run_case "type mismatch refuses, including bool-for-int" "${PRELUDE}
assert refuses(b'{\"operation\":1,\"arguments\":{\"count\":3}}', expect=SchemaViolation)
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":\"3\"}}', expect=SchemaViolation)
assert refuses(b'{\"operation\":\"sum\",\"arguments\":[]}', expect=SchemaViolation)
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":true}}', expect=SchemaViolation)
print('OK')
"

run_case "declared optional fields are accepted and absent ones are not invented" "${PRELUDE}
fd, _ = fd_for(b'{\"operation\":\"sum\",\"arguments\":{\"count\":3,\"label\":\"x\"},\"note\":\"n\"}',
               'opt.json')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.document['note'] == 'n'
assert binding.document['arguments']['label'] == 'x'
fd, _ = fd_for(VALID, 'noopt.json')
plain = validate_payload(fd, schema_version=1)
os.close(fd)
assert 'note' not in plain.document, plain.document
print('OK')
"

# --- schema version authority ----------------------------------------------

run_case "an unsupported schema version refuses" "${PRELUDE}
assert refuses(VALID, schema_version=2, expect=UnsupportedSchemaVersion)
assert refuses(VALID, schema_version=0, expect=UnsupportedSchemaVersion)
assert refuses(VALID, schema_version=-1, expect=UnsupportedSchemaVersion)
print('OK')
"

run_case "the payload cannot select its own schema version" "${PRELUDE}
# A schema_version key in the document is simply an unknown field: the closed
# schema has no slot for it, so it cannot be read as a selector.
assert refuses(b'{\"operation\":\"sum\",\"arguments\":{\"count\":3},\"schema_version\":2}',
               expect=SchemaViolation)
print('OK')
"

run_case "the bound schema version is the caller's, recorded verbatim" "${PRELUDE}
fd, _ = fd_for(VALID, 'v.json')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
assert binding.schema_version == 1
print('OK')
"

# --- binding immutability --------------------------------------------------

run_case "the binding is frozen" "${PRELUDE}
fd, _ = fd_for(VALID, 'f.json')
binding = validate_payload(fd, schema_version=1)
os.close(fd)
try:
    binding.digest = 'x' * 64
except Exception:
    print('OK')
else:
    raise AssertionError('PayloadBinding was mutated')
"

run_case "T3's own refusals are PayloadError subclasses" "${PRELUDE}
for cls in (SchemaViolation, UnsupportedSchemaVersion):
    assert issubclass(cls, PayloadError), cls
assert issubclass(PayloadError, ValueError)
print('OK')
"

# Wrapping T2's refusals in a T3 type would flatten them into one reason and
# lose which canonical rule was broken. They propagate unwrapped instead, so
# a caller can still tell an oversize payload from a duplicate key.
run_case "T2 refusals propagate with their exact type, unwrapped" "${PRELUDE}
import tools.capability.execution.canonical_json as cj
cases = [
    (b'[]', cj.MalformedDocument),
    (b'{\"operation\":\"sum\",\"operation\":\"x\",\"arguments\":{\"count\":3}}', cj.DuplicateKey),
    (b'{\"operation\":\"sum\",\"arguments\":{\"count\":1.5}}', cj.UnsupportedNumber),
    (b'{\"operation\":\"\\\\u0000\",\"arguments\":{\"count\":3}}', cj.InvalidString),
]
for data, expected in cases:
    fd, _ = fd_for(data, 'prop.json')
    try:
        validate_payload(fd, schema_version=1)
    except expected:
        pass
    except Exception as error:
        raise AssertionError(f'{expected.__name__} expected, got {type(error).__name__}')
    else:
        raise AssertionError(f'{data!r} was accepted')
    finally:
        os.close(fd)
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T3 payload validation passed.\n'
else
  printf 'Capability execution T3 payload validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
