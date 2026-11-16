#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the shared canonical JSON encoder (ENG-0006-H7a, ruling O-3).
#
# `tools/common/canonical_json.py` is a BYTE-IDENTICAL COPY of the Capability
# encoder `tools/capability/execution/canonical_json.py`, not a re-export. The
# ruling is explicit about why: turning the Capability module into a re-export
# would change the import closure of the installed Capability Runtime, which
# the digest-pinned generation installers depend on. So the Capability file is
# not modified, and two copies exist on purpose.
#
# Two copies of a correctness-critical routine are only safe while nothing can
# make them differ. This suite is that guarantee, and it is layered so that no
# single check carries it:
#
#   1. the two files are byte-identical, and the Capability file still has the
#      digest it was reviewed with;
#   2. golden vectors -- expected bytes WRITTEN OUT HERE, not produced by
#      either module -- pin the representation the Health approval digest is
#      computed over (`kyri-strict-canonical-json/v1`);
#   3. a differential run feeds one corpus to both modules and requires the
#      same bytes or the same refusal from each;
#   4. static checks: the copy is pure, imports nothing from another plane, and
#      no Capability module was moved onto it.
#
# Nothing here writes outside a temporary directory or touches a production path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import ast
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


COMMON = root / "tools/common/canonical_json.py"
CAPABILITY = root / "tools/capability/execution/canonical_json.py"

# The digest of the Capability encoder as introduced (acafae2) and as reviewed
# into every generation since. Pinned so this increment provably left it alone:
# if this changes, the Capability Runtime changed, and that is not Health's to do.
CAPABILITY_REVIEWED_SHA256 = (
    "11c76d9750290e6196532984afa420084ce41b918a828079d19a1ae27742f2e4")

print("--- the copy is byte-identical, and the original is untouched ---")
check(COMMON.is_file(), "tools/common/canonical_json.py exists")
check(CAPABILITY.is_file(), "the Capability encoder still exists")
common_bytes = COMMON.read_bytes() if COMMON.is_file() else b""
capability_bytes = CAPABILITY.read_bytes() if CAPABILITY.is_file() else b""
check(hashlib.sha256(capability_bytes).hexdigest() == CAPABILITY_REVIEWED_SHA256,
      "the Capability encoder still carries its reviewed digest")
check(common_bytes == capability_bytes,
      "the shared copy is byte-identical to the Capability encoder")

from tools.common import canonical_json as common  # noqa: E402
from tools.capability.execution import canonical_json as capability  # noqa: E402

check(common is not capability, "the shared copy is a distinct module, not an alias")

print("--- golden vectors: kyri-strict-canonical-json/v1 ---")
# Expected bytes are literals. Each vector names the rule it pins.
GOLDEN = [
    ("an empty object", {}, b"{}"),
    ("keys ordered by their UTF-8 bytes, not insertion order",
     {"b": 1, "a": 2, "B": 3}, b'{"B":3,"a":2,"b":1}'),
    ("a key ordering decided by bytes beyond ASCII",
     {"é": 1, "z": 2}, b'{"z":2,"\xc3\xa9":1}'),
    ("non-ASCII emitted literally as UTF-8, never escaped",
     {"notes": "café"}, b'{"notes":"caf\xc3\xa9"}'),
    ("no insignificant whitespace in nested structures",
     {"a": [1, {"b": None, "c": True}, False], "d": "x y"},
     b'{"a":[1,{"b":null,"c":true},false],"d":"x y"}'),
    ("JSON escapes for quote, backslash and control characters",
     {"s": "a\"b\\c\nd\te\u0001"}, b'{"s":"a\\"b\\\\c\\nd\\te\\u0001"}'),
    ("the signed 64-bit bounds, exactly",
     {"max": 9223372036854775807, "min": -9223372036854775808},
     b'{"max":9223372036854775807,"min":-9223372036854775808}'),
    ("zero and negative integers in their one spelling",
     {"n": -1, "z": 0}, b'{"n":-1,"z":0}'),
    ("a decimal threshold stays a string",
     {"value": "2000.5"}, b'{"value":"2000.5"}'),
    ("an empty array and an empty string", {"a": [], "s": ""}, b'{"a":[],"s":""}'),
]
for description, value, expected in GOLDEN:
    for name, module in (("shared", common), ("capability", capability)):
        try:
            produced = module.serialise(value)
        except Exception as error:  # noqa: BLE001
            produced = f"refused: {type(error).__name__}".encode()
        check(produced == expected, f"{name}: {description}")
    # The parse direction: the canonical bytes read back to the same value, and
    # re-serialise to themselves. That round trip is the acceptance rule the
    # approval statement is held to.
    try:
        parsed = common.parse(expected, maximum_bytes=65536)
        check(parsed == value and common.serialise(parsed) == expected,
              f"round trip: {description}")
    except Exception as error:  # noqa: BLE001
        check(False, f"round trip: {description} ({type(error).__name__})")

# A pinned digest over one representative statement-shaped object, so a change
# to the representation cannot pass silently even if every vector above was
# edited along with it.
STATEMENT = {
    "approval_statement_version": 1,
    "approval_domain": "capability-health-envelope",
    "operation": "initial",
    "request_id": "REQ-0001",
    "actor": "operator",
    "approving_authority": "operator-review",
    "approved_at": "2026-11-16T09:00:00-06:00",
    "canonicalisation": "kyri-strict-canonical-json/v1",
    "digest_algorithm": "sha256",
    "envelope": {"envelope_version": 1, "subject_id": "CINST-000007",
                 "notes": "café"},
}
STATEMENT_BYTES = (
    b'{"actor":"operator","approval_domain":"capability-health-envelope",'
    b'"approval_statement_version":1,"approved_at":"2026-11-16T09:00:00-06:00",'
    b'"approving_authority":"operator-review",'
    b'"canonicalisation":"kyri-strict-canonical-json/v1",'
    b'"digest_algorithm":"sha256","envelope":{"envelope_version":1,'
    b'"notes":"caf\xc3\xa9","subject_id":"CINST-000007"},'
    b'"operation":"initial","request_id":"REQ-0001"}')
check(common.serialise(STATEMENT) == STATEMENT_BYTES,
      "a statement-shaped object has the expected canonical bytes")
check(hashlib.sha256(common.serialise(STATEMENT)).hexdigest()
      == "163e20930741810c138c303f18a76b66af9f6fbee00a1ed732f746b1f4133cb7",
      "a statement-shaped object has the pinned sha256 digest")

print("--- refusals: the grammar refuses, it never repairs ---")
PARSE_REFUSALS = [
    ("a float", b'{"a":1.5}'),
    ("an exponent", b'{"a":1e3}'),
    ("NaN", b'{"a":NaN}'),
    ("Infinity", b'{"a":Infinity}'),
    ("negative zero", b'{"a":-0}'),
    ("a leading zero", b'{"a":01}'),
    ("an integer above int64", b'{"a":9223372036854775808}'),
    ("an integer below int64", b'{"a":-9223372036854775809}'),
    ("a duplicate key", b'{"a":1,"a":1}'),
    ("an escaped U+0000", b'{"a":"\\u0000"}'),
    ("an escaped lone surrogate", b'{"a":"\\ud800"}'),
    ("a top-level array", b'[1]'),
    ("a top-level string", b'"a"'),
    ("trailing data", b'{"a":1} {}'),
    ("invalid UTF-8", b'{"a":"\xff"}'),
    ("an empty document", b''),
]
for description, data in PARSE_REFUSALS:
    for name, module in (("shared", common), ("capability", capability)):
        try:
            module.parse(data, maximum_bytes=65536)
            check(False, f"{name}: parse refuses {description}")
        except module.CanonicalJSONError:
            check(True, f"{name}: parse refuses {description}")
        except Exception as error:  # noqa: BLE001
            check(False, f"{name}: parse refuses {description} with an "
                         f"unexpected {type(error).__name__}")
for name, module in (("shared", common), ("capability", capability)):
    try:
        module.parse(b'{"a":"' + b"x" * 64 + b'"}', maximum_bytes=16)
        check(False, f"{name}: an oversized document is refused")
    except module.PayloadTooLarge:
        check(True, f"{name}: an oversized document is refused before parsing")

# Non-canonical spellings PARSE -- JSON permits them -- and are caught only by
# the canonical-bytes rule serialise(parse(b)) == b. Pinned, because the
# approval statement's acceptance rule depends on exactly this behaviour.
for description, data in (("unsorted keys", b'{"b":1,"a":2}'),
                          ("insignificant whitespace", b'{ "a": 2 }'),
                          ("an escaped non-ASCII character", b'{"a":"caf\\u00e9"}'),
                          ("a trailing newline", b'{"a":2}\n')):
    parsed = common.parse(data, maximum_bytes=65536)
    check(common.serialise(parsed) != data,
          f"{description} parses but fails the canonical-bytes rule")

SERIALISE_REFUSALS = [
    ("a float", {"a": 1.5}),
    ("an integer above int64", {"a": 2 ** 63}),
    ("an integer below int64", {"a": -(2 ** 63) - 1}),
    ("a non-string key", {1: 2}),
    ("U+0000 in a value", {"a": "\x00"}),
    ("a lone surrogate in a key", {"\ud800": 1}),
    ("a tuple", {"a": (1, 2)}),
    ("a set", {"a": {1}}),
    ("bytes", {"a": b"x"}),
    ("a top-level list", [1]),
]
for description, value in SERIALISE_REFUSALS:
    for name, module in (("shared", common), ("capability", capability)):
        try:
            module.serialise(value)
            check(False, f"{name}: serialise refuses {description}")
        except module.CanonicalJSONError:
            check(True, f"{name}: serialise refuses {description}")

print("--- differential: one corpus, both modules, identical answers ---")


def outcome(module, function, argument):
    try:
        if function == "parse":
            return ("value", module.parse(argument, maximum_bytes=65536))
        return ("bytes", module.serialise(argument))
    except Exception as error:  # noqa: BLE001
        return ("refused", type(error).__name__, str(error))


corpus = ([("serialise", value) for _, value, _ in GOLDEN]
          + [("serialise", value) for _, value in SERIALISE_REFUSALS]
          + [("serialise", STATEMENT)]
          + [("parse", expected) for _, _, expected in GOLDEN]
          + [("parse", data) for _, data in PARSE_REFUSALS])
disagreements = [index for index, (function, argument) in enumerate(corpus)
                 if outcome(common, function, argument)
                 != outcome(capability, function, argument)]
check(not disagreements,
      f"both encoders agree on all {len(corpus)} corpus entries, refusals included")

print("--- static: pure, and independent of every plane ---")
tree = ast.parse(common_bytes.decode("utf-8"))
imported = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imported.update(alias.name.split(".")[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom):
        imported.add((node.module or "").split(".")[0] if node.level == 0
                     else f"relative:{node.module}")
check(imported <= {"__future__", "json", "typing"},
      f"the shared copy imports only the standard library it needs: {sorted(imported)}")

# The ruling forbids moving any Capability module onto the shared copy: that
# would change the installed Capability Runtime's import closure.
moved = []
for path in sorted((root / "tools/capability").rglob("*.py")):
    if "__pycache__" in path.parts:
        continue
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        module_name = None
        if isinstance(node, ast.ImportFrom) and node.level == 0:
            module_name = node.module or ""
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("tools.common.canonical_json"):
                    moved.append(path.relative_to(root).as_posix())
            continue
        if module_name is None:
            continue
        if module_name == "tools.common.canonical_json" or (
                module_name == "tools.common" and "canonical_json" in names):
            moved.append(path.relative_to(root).as_posix())
check(not moved,
      f"no Capability module imports the shared copy: {moved}")

if failures:
    print(f"\nShared canonical JSON validation FAILED with {failures} error(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("\nAll shared canonical JSON assertions passed.")
PY
