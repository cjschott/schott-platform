#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T2.
#
# T2 is the canonical JSON layer and nothing else: parse bytes that a caller
# already holds, and serialise a value back into canonical form. There is no
# payload binding, no descriptor, no schema registry, no execution state, no
# capacity, no profile, no protocol -- and above all NO EXECUTION. This suite
# asserts none of them.
#
# T2 IS PURE. It receives bytes and returns values. It opens no file, reads no
# clock or environment, starts no process, and mutates nothing. The static
# backstop below proves the production module acquired none of those.
#
# The grammar is CLOSED and the parser REFUSES rather than repairs. Every rule
# below exists because the alternative -- accepting the input and normalising
# it -- would mean the bytes a capability sees are not the bytes whose digest
# was bound to the invocation.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §10
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/canonical_json.py"

# ===========================================================================
# The T2 purity backstop
# ===========================================================================

assert_pure_canonical_json() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/canonical_json.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "os", "sys", "pathlib",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "open", "__import__",
    "getenv", "putenv", "chmod", "chown", "mkdir", "makedirs", "remove",
    "unlink", "rename", "rmdir", "fsync", "now", "today", "monotonic",
    "uuid1", "uuid4", "normalize",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

findings = []
source = target.read_text(encoding="utf-8")
rel = target.relative_to(root)
tree = ast.parse(source)

# Strip docstrings so prose about what T2 refuses to do cannot trip a scan
# that is making a claim about code.
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
    pass "T2 production module is pure: no I/O, clock, environment, or execution surface"
  else
    fail "T2 purity backstop found: ${report}"
  fi
}

assert_pure_canonical_json

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
from tools.capability.execution.canonical_json import (
    parse, serialise, CanonicalJSONError)
MAX = 2 * 1024 * 1024
def refuses(data, maximum_bytes=MAX):
    try:
        parse(data, maximum_bytes=maximum_bytes)
    except CanonicalJSONError:
        return True
    return False
"

# --- document shape --------------------------------------------------------

run_case "accepts a minimal top-level object" "${PRELUDE}
assert parse(b'{}', maximum_bytes=MAX) == {}
assert parse(b'{\"a\":1}', maximum_bytes=MAX) == {'a': 1}
print('OK')
"

run_case "refuses a non-object top level" "${PRELUDE}
for data in (b'[]', b'1', b'\"s\"', b'true', b'false', b'null'):
    assert refuses(data), data
print('OK')
"

run_case "refuses more than one document" "${PRELUDE}
assert refuses(b'{}{}')
assert refuses(b'{} {}')
assert refuses(b'{}\n{}')
print('OK')
"

run_case "refuses empty input and trailing garbage" "${PRELUDE}
assert refuses(b'')
assert refuses(b'{} trailing')
assert refuses(b'{},')
print('OK')
"

# --- size bounds -----------------------------------------------------------

run_case "refuses input over the 2 MiB bound" "${PRELUDE}
oversize = b'{\"a\":\"' + b'x' * (2 * 1024 * 1024) + b'\"}'
assert len(oversize) > MAX
assert refuses(oversize)
print('OK')
"

run_case "the bound is checked before parsing, not after" "${PRELUDE}
# Oversize AND malformed: if the bound were checked after parsing, the parse
# would fail first and a caller could not tell that the limit did its job.
import tools.capability.execution.canonical_json as cj
oversize_bad = b'{' + b'x' * (2 * 1024 * 1024 + 10)
try:
    parse(oversize_bad, maximum_bytes=MAX)
except cj.PayloadTooLarge:
    print('OK')
except cj.CanonicalJSONError as error:
    raise AssertionError(f'bound not checked first: {type(error).__name__}')
"

run_case "accepts input exactly at the bound" "${PRELUDE}
filler = MAX - len(b'{\"a\":\"\"}')
exact = b'{\"a\":\"' + b'x' * filler + b'\"}'
assert len(exact) == MAX
assert parse(exact, maximum_bytes=MAX)['a'] == 'x' * filler
print('OK')
"

# --- duplicate keys --------------------------------------------------------

run_case "refuses duplicate keys at the top level" "${PRELUDE}
assert refuses(b'{\"a\":1,\"a\":2}')
print('OK')
"

run_case "refuses duplicate keys at nesting depth 3" "${PRELUDE}
assert refuses(b'{\"a\":{\"b\":{\"c\":{\"d\":1,\"d\":2}}}}')
print('OK')
"

run_case "refuses duplicate keys inside an array element" "${PRELUDE}
assert refuses(b'{\"a\":[{\"b\":1,\"b\":2}]}')
print('OK')
"

run_case "duplicate detection precedes canonicalisation" "${PRELUDE}
# Canonicalising first would collapse the duplicate and hide it.
import tools.capability.execution.canonical_json as cj
try:
    parse(b'{\"a\":1,\"a\":1}', maximum_bytes=MAX)
except cj.DuplicateKey as error:
    assert 'a' in str(error)
    print('OK')
else:
    raise AssertionError('identical duplicate values were collapsed')
"

# --- numbers ---------------------------------------------------------------

run_case "accepts int64 boundaries exactly" "${PRELUDE}
lo, hi = -9223372036854775808, 9223372036854775807
assert parse(b'{\"a\":-9223372036854775808}', maximum_bytes=MAX)['a'] == lo
assert parse(b'{\"a\":9223372036854775807}', maximum_bytes=MAX)['a'] == hi
print('OK')
"

run_case "refuses integers outside int64" "${PRELUDE}
assert refuses(b'{\"a\":9223372036854775808}')
assert refuses(b'{\"a\":-9223372036854775809}')
print('OK')
"

run_case "refuses fractions and exponents" "${PRELUDE}
for data in (b'{\"a\":1.0}', b'{\"a\":0.5}', b'{\"a\":1e3}', b'{\"a\":1E3}',
             b'{\"a\":1.5e2}', b'{\"a\":1e+3}', b'{\"a\":1e-3}'):
    assert refuses(data), data
print('OK')
"

run_case "refuses NaN and infinities in every spelling" "${PRELUDE}
for data in (b'{\"a\":NaN}', b'{\"a\":Infinity}', b'{\"a\":-Infinity}',
             b'{\"a\":nan}', b'{\"a\":inf}'):
    assert refuses(data), data
print('OK')
"

run_case "refuses non-canonical integer spellings" "${PRELUDE}
for data in (b'{\"a\":01}', b'{\"a\":+1}', b'{\"a\":-0}', b'{\"a\":1_0}'):
    assert refuses(data), data
print('OK')
"

# bool is a subclass of int in Python, so an int64 range check written
# carelessly would accept True as a number and emit 1. These assert booleans
# survive as booleans in both directions.
run_case "booleans stay booleans and are not treated as integers" "${PRELUDE}
value = parse(b'{\"a\":true,\"b\":false}', maximum_bytes=MAX)
assert value['a'] is True and value['b'] is False, value
assert serialise({'a': True, 'b': False}) == b'{\"a\":true,\"b\":false}'
assert serialise(parse(b'{\"a\":1}', maximum_bytes=MAX)) == b'{\"a\":1}'
print('OK')
"

# --- strings and Unicode ---------------------------------------------------

run_case "refuses invalid UTF-8 bytes" "${PRELUDE}
assert refuses(b'{\"a\":\"\xff\xfe\"}')
assert refuses(b'{\"\xc3\x28\":1}')
print('OK')
"

run_case "refuses U+0000 however it is written" "${PRELUDE}
assert refuses(b'{\"a\":\"\\\\u0000\"}')
assert refuses(b'{\"a\":\"x\\\\u0000y\"}')
assert refuses(b'{\"\\\\u0000\":1}')
print('OK')
"

run_case "refuses unpaired surrogates in values and keys" "${PRELUDE}
assert refuses(b'{\"a\":\"\\\\ud800\"}')
assert refuses(b'{\"a\":\"\\\\udfff\"}')
assert refuses(b'{\"\\\\ud800\":1}')
print('OK')
"

run_case "accepts a correctly paired surrogate escape" "${PRELUDE}
assert parse(b'{\"a\":\"\\\\ud83d\\\\ude00\"}', maximum_bytes=MAX)['a'] == '\U0001f600'
print('OK')
"

run_case "applies no Unicode normalisation" "${PRELUDE}
composed = b'{\"a\":\"\\\\u00e9\"}'
decomposed = b'{\"a\":\"e\\\\u0301\"}'
a = parse(composed, maximum_bytes=MAX)['a']
b = parse(decomposed, maximum_bytes=MAX)['a']
assert a != b, 'NFC/NFD were normalised together'
assert len(a) == 1 and len(b) == 2
print('OK')
"

run_case "keys keep exact decoded identity with no case folding" "${PRELUDE}
value = parse(b'{\"A\":1,\"a\":2}', maximum_bytes=MAX)
assert set(value) == {'A', 'a'}, value
composed = parse(b'{\"\\\\u00e9\":1,\"e\\\\u0301\":2}', maximum_bytes=MAX)
assert len(composed) == 2, composed
print('OK')
"

# --- canonical serialisation ----------------------------------------------

run_case "serialises keys in deterministic UTF-8 byte order" "${PRELUDE}
out = serialise({'b': 1, 'a': 2, 'A': 3, 'é': 4, 'Z': 5})
assert out == b'{\"A\":3,\"Z\":5,\"a\":2,\"b\":1,\"\\xc3\\xa9\":4}', out
print('OK')
"

# UTF-8 preserves code-point order, so byte order and ordinal order can never
# disagree -- there is no input that distinguishes them. What can disagree is
# any ordering that is neither: case-insensitive, locale-aware, or
# normalisation-aware. Those are what this pins down.
run_case "ordering is neither case-insensitive nor locale-aware" "${PRELUDE}
out = serialise({'a': 1, 'B': 2})
assert out == b'{\"B\":2,\"a\":1}', out
out = serialise({'z': 1, 'Ａ': 2})
assert out.index(b'\"z\"') < out.index(b'\\xef\\xbc\\xa1'), out
composed = serialise({'é': 1, 'é': 2})
assert composed == b'{\"e\\xcc\\x81\":2,\"\\xc3\\xa9\":1}', composed
print('OK')
"

run_case "serialisation emits no whitespace and no ASCII escaping" "${PRELUDE}
assert serialise({'a': 1, 'b': 'x'}) == b'{\"a\":1,\"b\":\"x\"}'
assert serialise({'a': 'é'}) == b'{\"a\":\"\\xc3\\xa9\"}'
print('OK')
"

run_case "round trip is byte-stable" "${PRELUDE}
original = b'{\"a\":1,\"b\":[1,2,{\"c\":\"x\"}],\"d\":null,\"e\":true}'
once = serialise(parse(original, maximum_bytes=MAX))
twice = serialise(parse(once, maximum_bytes=MAX))
assert once == twice == original, (once, twice)
print('OK')
"

run_case "serialise refuses a value the parser would refuse" "${PRELUDE}
for value in ({'a': 1.5}, {'a': 2**63}, {'a': -2**63 - 1}, {'a': '\x00'},
              {'a': float('nan')}, {'a': float('inf')}):
    try:
        serialise(value)
    except CanonicalJSONError:
        continue
    raise AssertionError(f'serialise accepted {value!r}')
print('OK')
"

run_case "serialise refuses a non-object top level and non-string keys" "${PRELUDE}
for value in ([], 1, 'x', None, True):
    try:
        serialise(value)
    except CanonicalJSONError:
        continue
    raise AssertionError(f'serialise accepted {value!r}')
try:
    serialise({1: 'a'})
except CanonicalJSONError:
    print('OK')
else:
    raise AssertionError('serialise accepted a non-string key')
"

# --- refusal discipline ----------------------------------------------------

run_case "every refusal is a CanonicalJSONError subclass" "${PRELUDE}
import tools.capability.execution.canonical_json as cj
for name in ('PayloadTooLarge', 'DuplicateKey', 'MalformedDocument',
             'UnsupportedNumber', 'InvalidString'):
    cls = getattr(cj, name)
    assert issubclass(cls, CanonicalJSONError), name
print('OK')
"

run_case "T2 exposes exactly parse and serialise as its functions" "${PRELUDE}
import types as pytypes
import tools.capability.execution.canonical_json as cj
functions = sorted(n for n, v in vars(cj).items()
                   if isinstance(v, pytypes.FunctionType) and not n.startswith('_'))
assert functions == ['parse', 'serialise'], functions
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T2 canonical JSON validation passed.\n'
else
  printf 'Capability execution T2 canonical JSON validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
