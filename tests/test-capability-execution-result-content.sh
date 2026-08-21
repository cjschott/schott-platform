#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the result-content authority.
#
# `collector.py` is the authority for the result ENVELOPE: that a root-level
# `result.json` exists, that it parses as canonical JSON, and that it is within
# bounds. It deliberately says nothing about what is inside. This module is the
# authority for what is inside one capability's result, and nothing else.
#
# It exists so a capability contract can REFERENCE an enforcement authority
# instead of restating one. A contract that merely listed the keys it expected
# would be a permanent, immutable, unexecuted copy of a schema -- a claim of
# enforcement no code performs. The contract names this module; this module
# performs the check.
#
# IT VALIDATES A DECODED DOCUMENT AND NOTHING ELSE. No descriptor, no path, no
# bytes, no clock. `collector.read_result` has already decided the envelope was
# believable and hands over what it decoded; re-parsing here would make this a
# second opinion about the envelope, which is the duplication the split avoids.
#
# Governed by:
#   platform-model/schemas/capability-contract.schema.yaml  (response_shape_parts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/result_content.py"

# ===========================================================================
# The authority backstop
# ===========================================================================
# This module reads a mapping somebody else decoded. It has no descriptor, no
# pathname, no bytes, and no clock, so there is nothing here to misuse rather
# than a rule against misusing it.

assert_pure_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/result_content.py"

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

# Everything. A module that only judges a decoded mapping needs no import at
# all beyond typing, so the permitted set is the honest one rather than a
# trimmed version of somebody else's list.
PERMITTED_IMPORTS = {"__future__", "typing"}
FORBIDDEN_CALLS = {
    "open", "fdopen", "read", "write", "system", "popen", "exec", "eval",
    "compile", "__import__", "getenv", "putenv", "now", "today", "monotonic",
    "uuid1", "uuid4", "normalize", "lower", "upper", "strip", "casefold",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "result.json")

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
            if alias.name.split(".")[0] not in PERMITTED_IMPORTS:
                findings.append(f"{rel}: unpermitted import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] not in PERMITTED_IMPORTS:
            findings.append(f"{rel}: unpermitted import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"{rel}: forbidden call: {attr}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "the content authority judges a decoded mapping and reaches nothing else"
  else
    fail "content authority backstop found: ${report}"
  fi
}

assert_pure_authority

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
from tools.capability.execution.result_content import (
    validate_result_content, ResultContentError, RESULT_CONTENT_SCHEMA,
    RESULT_CONTENT_SCHEMA_VERSION, VERIFICATION_CAPABILITY, OPERATIONS)
DIGEST = 'a' * 64
OTHER = 'b' * 64
def valid(**overrides):
    document = dict(capability=VERIFICATION_CAPABILITY,
                    result_schema_version=RESULT_CONTENT_SCHEMA_VERSION,
                    operation='verify-execution-boundary',
                    payload_digest=DIGEST, checksum=OTHER)
    document.update(overrides)
    return document
def refuses(document, why):
    try:
        validate_result_content(document)
    except ResultContentError:
        return
    raise AssertionError(why + ' was accepted')
"

run_case "a governed verification result is accepted" "${PRELUDE}
returned = validate_result_content(valid())
assert returned == valid(), 'the document was altered'
print('OK')
"

run_case "the accepted document is returned unchanged, never repaired" "${PRELUDE}
supplied = valid()
returned = validate_result_content(supplied)
assert returned is supplied, 'a copy was returned instead of the document'
print('OK')
"

# Closed means the field set is exhaustive. An ignored extra field would let a
# result carry data the contract never agreed to, and would let a future field
# name silently change meaning.
run_case "an unknown field is refused rather than ignored" "${PRELUDE}
refuses(valid(extra='anything'), 'an unknown field')
print('OK')
"

run_case "every required field is required" "${PRELUDE}
for name in ('capability', 'result_schema_version', 'operation',
             'payload_digest', 'checksum'):
    document = valid()
    del document[name]
    refuses(document, 'a document missing ' + name)
print('OK')
"

# A result that says it is some other capability's is refused rather than
# accepted and mislabelled: the point of the record is that it says what was
# actually proven.
run_case "a result claiming another capability is refused" "${PRELUDE}
refuses(valid(capability='something-else'), 'another capability')
refuses(valid(capability=''), 'an empty capability')
refuses(valid(capability=None), 'no capability')
print('OK')
"

run_case "the operation is a closed vocabulary, not free text" "${PRELUDE}
refuses(valid(operation='rm -rf /'), 'a shell fragment')
refuses(valid(operation='/usr/bin/true'), 'a path')
refuses(valid(operation='verify-execution-boundary '), 'a padded spelling')
refuses(valid(operation=''), 'an empty operation')
assert len(OPERATIONS) == 1, 'this release verifies exactly one operation'
print('OK')
"

run_case "the schema version is exactly the one this module implements" "${PRELUDE}
refuses(valid(result_schema_version=2), 'a version nobody implements')
refuses(valid(result_schema_version=0), 'a version of zero')
refuses(valid(result_schema_version='1'), 'a version written as text')
print('OK')
"

# bool is an int in Python, so True would otherwise pass as version 1.
run_case "a boolean is not a schema version" "${PRELUDE}
refuses(valid(result_schema_version=True), 'a boolean version')
print('OK')
"

# Nothing is normalised. A digest that had to be recased to be recognised was
# not the digest that was written, and accepting both spellings would make two
# strings compare equal here and unequal everywhere else.
run_case "digests are lowercase hex SHA-256, and nothing is normalised" "${PRELUDE}
for name in ('payload_digest', 'checksum'):
    refuses(valid(**{name: 'A' * 64}), 'an uppercase ' + name)
    refuses(valid(**{name: 'a' * 63}), 'a short ' + name)
    refuses(valid(**{name: 'a' * 65}), 'a long ' + name)
    refuses(valid(**{name: 'sha256:' + 'a' * 64}), 'a prefixed ' + name)
    refuses(valid(**{name: 'g' * 64}), 'a non-hex ' + name)
    refuses(valid(**{name: 7}), 'a numeric ' + name)
print('OK')
"

run_case "a document that is not an object is refused" "${PRELUDE}
for document in (None, 7, 'text', ['a'], ()):
    refuses(document, repr(document))
print('OK')
"

# A field name is safe to report; a value the workload wrote is not.
run_case "a refusal names fields and never echoes a value" "${PRELUDE}
try:
    validate_result_content(valid(smuggled='SECRET-VALUE'))
except ResultContentError as error:
    assert 'smuggled' in str(error), 'the field was not named'
    assert 'SECRET-VALUE' not in str(error), 'the value was echoed'
else:
    raise AssertionError('an unknown field was accepted')
print('OK')
"

# The contract references this schema by name and version. If the module and
# the reference could drift, the contract would claim enforcement of something
# else.
run_case "the module publishes the schema name and version a contract references" "${PRELUDE}
assert RESULT_CONTENT_SCHEMA == 'kyri-execution-verification-result'
assert RESULT_CONTENT_SCHEMA_VERSION == 1
print('OK')
"

# The envelope authority is a different module making a different claim, and it
# is referenced rather than changed -- it is installed runtime. The split is
# real in both directions: the envelope module decides a result document is
# believable at all and judges nothing inside it, and this module judges the
# inside and re-reads no envelope.
run_case "the envelope is a separate authority, and neither module does the other's job" "
from tools.capability.execution import collector, result_content
assert hasattr(collector, 'read_result'), 'the envelope authority is absent'
assert collector.RESULT_NAME == 'result.json'
assert not hasattr(result_content, 'read_result'), 'content re-reads the envelope'
assert not hasattr(result_content, 'RESULT_NAME'), 'content names the envelope document'
assert not hasattr(collector, 'validate_result_content'), 'the envelope judges content'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution result-content validation passed.\n'
else
  printf 'Capability execution result-content validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
