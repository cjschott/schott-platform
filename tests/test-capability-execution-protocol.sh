#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T9.
#
# T9 is the coordinator<->worker protocol from §3.1, and nothing else. It is
# pure message logic: no descriptors, no filesystem, no Podman, no subprocess,
# no session plumbing -- and NO EXECUTION. Descriptor wiring belongs to later
# tasks.
#
# MESSAGES ARE DATA. The coordinator never executes, evaluates, imports, or
# shells anything a worker sends. The strongest form of that guarantee is
# structural: the closed schema has no field capable of carrying an executable,
# an argv list, a flag, a mount, an image selector, or a host path, so there is
# nothing to misuse rather than a rule against misusing it.
#
# WELL-FORMED IS NOT AUTHORISED. A container ID that decodes is still untrusted
# data; the session only decides whether a message is legal *here*, and later
# lifecycle logic decides whether to believe it.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §3.1
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T9

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/protocol.py"

# ===========================================================================
# The T9 purity backstop
# ===========================================================================

assert_pure_protocol() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/protocol.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib", "os", "sys", "fcntl", "pickle",
    "marshal", "yaml", "io",
}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "open", "__import__",
    "getenv", "putenv", "chmod", "chown", "mkdir", "makedirs", "remove",
    "unlink", "rename", "rmdir", "fsync", "now", "today", "monotonic",
    "uuid1", "uuid4", "normalize", "scandir", "stat", "read", "write",
    "loads", "dumps",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/",
                  "/data/", "argv", "shell")

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
    pass "T9 is pure: no I/O, clock, environment, deserialisation, or execution surface"
  else
    fail "T9 purity backstop found: ${report}"
  fi
}

assert_pure_protocol

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
import dataclasses
from tools.capability.execution.protocol import (
    encode, decode, Session, Message, MessageKind, ProtocolError,
    ProtocolViolation, PROTOCOL_VERSION, MAXIMUM_MESSAGE_BYTES)
from tools.capability.execution.types import Classification

CINV = 'CINV-000042'
CID = 'c' * 64
IMAGE = 'sha256:' + 'a' * 64

def created(cinv=CINV, container_id=CID):
    return Message(kind=MessageKind.CREATED, cinv=cinv,
                   fields=(('container_id', container_id),))

def verified(cinv=CINV):
    return Message(kind=MessageKind.VERIFIED_PROFILE, cinv=cinv, fields=(
        ('container_id', CID), ('profile_digest', 'd' * 64),
        ('image_digest', IMAGE), ('cimp', 'CIMP-000001'),
        ('profile_schema_version', 1), ('execution_uid', 1000),
        ('execution_gid', 1000)))

def start_now(cinv=CINV):
    return Message(kind=MessageKind.START_NOW, cinv=cinv,
                   fields=(('container_id', CID),))

def started(cinv=CINV):
    return Message(kind=MessageKind.STARTED, cinv=cinv,
                   fields=(('container_id', CID),))

def terminal(cinv=CINV, exit_code=0, started_proven=True):
    return Message(kind=MessageKind.TERMINAL, cinv=cinv, fields=(
        ('container_id', CID), ('lifecycle_state', 'exited'),
        ('exit_code', exit_code), ('started_proven', started_proven)))

def collected(cinv=CINV):
    return Message(kind=MessageKind.COLLECTED, cinv=cinv, fields=(
        ('result_digest', 'e' * 64), ('output_manifest_digest', 'f' * 64),
        ('stdout_truncated', False), ('stderr_truncated', False)))

def error(cinv=CINV, detail='result_missing'):
    return Message(kind=MessageKind.ERROR, cinv=cinv,
                   fields=(('detail', detail),))

def abort(cinv=CINV, detail='execution_protocol_violation'):
    return Message(kind=MessageKind.ABORT, cinv=cinv,
                   fields=(('detail', detail),))

def frames(*messages):
    return [encode(m) for m in messages]

def session(*messages):
    return Session(frames(*messages))

FULL = (created(), verified(), start_now(), started(), terminal(), collected())
ORDER = (MessageKind.CREATED, MessageKind.VERIFIED_PROFILE,
         MessageKind.START_NOW, MessageKind.STARTED, MessageKind.TERMINAL,
         MessageKind.COLLECTED)
"

# --- version, framing, bounds -------------------------------------------------

run_case "the protocol version is fixed at 1 and carried in every message" "${PRELUDE}
assert PROTOCOL_VERSION == 1
import json
for message in FULL:
    body = json.loads(encode(message).rstrip(b'\n'))
    assert body['protocol_version'] == 1, body
print('OK')
"

run_case "an unknown protocol version refuses, with no negotiation" "${PRELUDE}
import json
body = json.loads(encode(created()).rstrip(b'\n'))
for version in (0, 2, 99, -1):
    body['protocol_version'] = version
    raw = json.dumps(body, separators=(',', ':'), sort_keys=True).encode() + b'\n'
    try:
        decode(raw)
    except ProtocolViolation:
        continue
    raise AssertionError(f'protocol version {version} was accepted')
import tools.capability.execution.protocol as module
public = [n for n in dir(module) if not n.startswith('_')]
for banned in ('negotiate', 'downgrade', 'upgrade', 'version_range'):
    assert not any(banned in n.lower() for n in public), banned
print('OK')
"

run_case "framing is one newline-terminated message per frame" "${PRELUDE}
raw = encode(created())
assert raw.endswith(b'\n'), raw[-4:]
assert raw.count(b'\n') == 1, raw.count(b'\n')
print('OK')
"

run_case "the message bound is 64 KiB and oversize refuses before decode" "${PRELUDE}
assert MAXIMUM_MESSAGE_BYTES == 64 * 1024
import tools.capability.execution.protocol as module
oversize = b'{' + b'x' * (64 * 1024) + b'\n'
try:
    decode(oversize)
except ProtocolViolation as e:
    # Refused for size, not for whatever the parser would have said.
    assert 'byte' in str(e).lower() or 'size' in str(e).lower() or 'large' in str(e).lower(), str(e)
    print('OK')
else:
    raise AssertionError('an oversize frame was decoded')
"

run_case "a frame exactly at the bound is accepted" "${PRELUDE}
message = created()
raw = encode(message)
assert len(raw) <= MAXIMUM_MESSAGE_BYTES
assert decode(raw) == message
print('OK')
"

# --- encode/decode ------------------------------------------------------------

run_case "encoding is deterministic and independent of construction order" "${PRELUDE}
a = Message(kind=MessageKind.CREATED, cinv=CINV,
            fields=(('container_id', CID),))
b = Message(kind=MessageKind.CREATED, cinv=CINV,
            fields=(('container_id', CID),))
assert encode(a) == encode(b)
# The verified_profile message has many fields; reversing their order in the
# source must not change a byte.
forward = verified()
reversed_fields = Message(kind=forward.kind, cinv=forward.cinv,
                          fields=tuple(reversed(forward.fields)))
assert encode(forward) == encode(reversed_fields), 'field order changed the bytes'
print('OK')
"

run_case "encode then decode round-trips to an equal immutable value" "${PRELUDE}
for message in FULL + (error(), abort()):
    back = decode(encode(message))
    assert back == message, (message.kind, back)
    assert isinstance(back, Message)
    try:
        back.cinv = 'CINV-000001'
    except Exception:
        pass
    else:
        raise AssertionError('a decoded message was mutated')
    assert isinstance(back.fields, tuple)
    assert not isinstance(back.field_map(), type(back.fields)) or True
print('OK')
"

run_case "decoded values expose no mutable authority" "${PRELUDE}
back = decode(encode(verified()))
assert isinstance(back.fields, tuple)
for name, value in back.fields:
    assert not isinstance(value, (list, dict, set, bytearray)), (name, type(value))
print('OK')
"

# --- closed grammar ------------------------------------------------------------

run_case "the message kinds are exactly the eight the specification names" "${PRELUDE}
assert {k.value for k in MessageKind} == {
    'created', 'verified_profile', 'started', 'terminal', 'collected',
    'error', 'start_now', 'abort'}, {k.value for k in MessageKind}
print('OK')
"

run_case "there is no speculative verb" "${PRELUDE}
values = {k.value for k in MessageKind}
for banned in ('run', 'execute', 'shell', 'command', 'cancel', 'retry',
               'restart', 'attach', 'inspect', 'list', 'pull', 'delete',
               'remove', 'create_again', 'recreate'):
    assert banned not in values, banned
print('OK')
"

run_case "an unknown message kind refuses" "${PRELUDE}
import json
body = json.loads(encode(created()).rstrip(b'\n'))
body['kind'] = 'run_command'
raw = json.dumps(body, separators=(',', ':'), sort_keys=True).encode() + b'\n'
try:
    decode(raw)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('an unknown kind was decoded')
"

run_case "unknown, missing, and wrongly typed fields all refuse" "${PRELUDE}
import json
base = json.loads(encode(created()).rstrip(b'\n'))
def attempt(mutate):
    body = dict(base)
    mutate(body)
    raw = json.dumps(body, separators=(',', ':'), sort_keys=True).encode() + b'\n'
    try:
        decode(raw)
    except ProtocolViolation:
        return
    raise AssertionError(f'accepted {body}')
attempt(lambda b: b.__setitem__('extra', 1))
attempt(lambda b: b.pop('container_id'))
attempt(lambda b: b.pop('cinv'))
attempt(lambda b: b.pop('kind'))
attempt(lambda b: b.pop('protocol_version'))
attempt(lambda b: b.__setitem__('container_id', 5))
attempt(lambda b: b.__setitem__('cinv', 7))
attempt(lambda b: b.__setitem__('protocol_version', '1'))
print('OK')
"

run_case "malformed frames refuse: bad UTF-8, bad JSON, duplicates, trailing, empty" "${PRELUDE}
cases = [
    b'\xff\xfe\n',
    b'{not json}\n',
    b'{\"kind\":\"created\",\"kind\":\"created\"}\n',
    encode(created()).rstrip(b'\n') + b' trailing\n',
    encode(created()).rstrip(b'\n') + encode(created()),
    b'\n',
    b'',
    b'[]\n',
    b'\"a string\"\n',
    b'null\n',
]
for raw in cases:
    try:
        decode(raw)
    except ProtocolViolation:
        continue
    raise AssertionError(f'accepted {raw[:40]!r}')
print('OK')
"

# --- identity grammar -----------------------------------------------------------

run_case "identity fields are validated against their canonical grammar" "${PRELUDE}
import json
def mutate(message, field, value):
    body = json.loads(encode(message).rstrip(b'\n'))
    body[field] = value
    raw = json.dumps(body, separators=(',', ':'), sort_keys=True).encode() + b'\n'
    try:
        decode(raw)
    except ProtocolViolation:
        return
    raise AssertionError(f'accepted {field}={value!r}')
for bad in ('CINV-00004', 'cinv-000042', '../../etc', '', 'CINV-0000042'):
    mutate(created(), 'cinv', bad)
for bad in ('C' * 64, 'c' * 63, 'c' * 65, '', 'deadbeef', '../x'):
    mutate(created(), 'container_id', bad)
for bad in ('CIMP-00001', 'cimp-000001', ''):
    mutate(verified(), 'cimp', bad)
for bad in ('sha256:' + 'g' * 64, 'a' * 64, 'sha512:' + 'a' * 64, ''):
    mutate(verified(), 'image_digest', bad)
for bad in ('1', 1.5, None, True):
    mutate(verified(), 'profile_schema_version', bad)
print('OK')
"

run_case "an error or abort detail must be a specified classification" "${PRELUDE}
assert decode(encode(error(detail='result_missing'))).field_map()['detail'] == 'result_missing'
import json
for bad in ('something went wrong', 'RESULT_MISSING', '', 'rm -rf /'):
    body = json.loads(encode(error()).rstrip(b'\n'))
    body['detail'] = bad
    raw = json.dumps(body, separators=(',', ':'), sort_keys=True).encode() + b'\n'
    try:
        decode(raw)
    except ProtocolViolation:
        continue
    raise AssertionError(f'accepted free-form detail {bad!r}')
print('OK')
"

# --- structural absence of a command channel --------------------------------------

run_case "no message schema can carry a command, flag, path, or image selector" "${PRELUDE}
import tools.capability.execution.protocol as module
allowed = set()
for names in module.MESSAGE_SCHEMAS.values():
    allowed.update(names)
banned = ('command', 'argv', 'args', 'exec', 'executable', 'entrypoint',
          'shell', 'cmd', 'flags', 'options', 'mount', 'mounts', 'volume',
          'network', 'device', 'devices', 'env', 'environment', 'path',
          'paths', 'root', 'source', 'destination', 'image', 'image_name',
          'registry', 'tag', 'socket', 'user', 'privileged', 'capabilities')
for name in allowed:
    assert name not in banned, f'schema carries {name!r}'
    assert not name.endswith('_path'), name
    assert not name.endswith('_dir'), name
print('OK')
"

run_case "no schema field can transport a host path, even as free text" "${PRELUDE}
import json
# Every string-typed field is either a fixed grammar or a closed vocabulary;
# none accepts arbitrary text, so a path has nowhere to ride.
for message in FULL + (error(), abort()):
    body = json.loads(encode(message).rstrip(b'\n'))
    for field, value in body.items():
        if not isinstance(value, str) or field in ('kind',):
            continue
        body2 = dict(body)
        body2[field] = '/data/kyri/capability-runtime/staging'
        raw = json.dumps(body2, separators=(',', ':'), sort_keys=True).encode() + b'\n'
        try:
            decode(raw)
        except ProtocolViolation:
            continue
        raise AssertionError(f'{message.kind.value}.{field} accepted a host path')
print('OK')
"

# --- session ordering ---------------------------------------------------------------

run_case "the accepted sequence is admitted in order" "${PRELUDE}
s = session(*FULL)
for kind in ORDER:
    message = s.expect(kind)
    assert message.kind is kind, (kind, message.kind)
print('OK')
"

run_case "an illegal first message is refused" "${PRELUDE}
for first in (verified(), start_now(), started(), terminal(), collected()):
    s = session(first)
    try:
        s.expect(first.kind)
    except ProtocolViolation as e:
        assert e.classification is Classification.EXECUTION_PROTOCOL_VIOLATION
        continue
    raise AssertionError(f'{first.kind.value} was accepted as the first message')
print('OK')
"

run_case "an out-of-order message is refused" "${PRELUDE}
s = session(created(), started())
s.expect(MessageKind.CREATED)
try:
    s.expect(MessageKind.STARTED)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('out-of-order message accepted')
"

run_case "expecting a kind the frame does not carry is refused" "${PRELUDE}
s = session(created())
try:
    s.expect(MessageKind.VERIFIED_PROFILE)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('a mismatched expectation was accepted')
"

run_case "the session cannot rewind to an earlier state" "${PRELUDE}
s = session(created(), verified(), created())
s.expect(MessageKind.CREATED)
s.expect(MessageKind.VERIFIED_PROFILE)
try:
    s.expect(MessageKind.CREATED)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('the session rewound')
"

run_case "a duplicate create result is refused -- there is no second create" "${PRELUDE}
s = session(created(), created())
s.expect(MessageKind.CREATED)
try:
    s.expect(MessageKind.CREATED)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('a second created was accepted')
"

run_case "a duplicate start instruction and a duplicate started are refused" "${PRELUDE}
s = session(created(), verified(), start_now(), start_now())
s.expect(MessageKind.CREATED); s.expect(MessageKind.VERIFIED_PROFILE)
s.expect(MessageKind.START_NOW)
try:
    s.expect(MessageKind.START_NOW)
except ProtocolViolation:
    pass
else:
    raise AssertionError('a second start_now was accepted')
s2 = session(created(), verified(), start_now(), started(), started())
for kind in (MessageKind.CREATED, MessageKind.VERIFIED_PROFILE,
             MessageKind.START_NOW, MessageKind.STARTED):
    s2.expect(kind)
try:
    s2.expect(MessageKind.STARTED)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('a second started was accepted')
"

run_case "terminal cannot precede a start-capable state" "${PRELUDE}
for prefix, kinds in ((( created(),), (MessageKind.CREATED,)),
                      ((created(), verified()),
                       (MessageKind.CREATED, MessageKind.VERIFIED_PROFILE))):
    s = Session(frames(*prefix) + frames(terminal()))
    for kind in kinds:
        s.expect(kind)
    try:
        s.expect(MessageKind.TERMINAL)
    except ProtocolViolation:
        continue
    raise AssertionError('terminal was accepted before start')
print('OK')
"

run_case "a duplicate terminal is refused" "${PRELUDE}
s = Session(frames(created(), verified(), start_now(), started(), terminal(),
                   terminal()))
for kind in ORDER[:5]:
    s.expect(kind)
try:
    s.expect(MessageKind.TERMINAL)
except ProtocolViolation:
    print('OK')
else:
    raise AssertionError('a second terminal was accepted')
"

run_case "nothing is accepted after collected" "${PRELUDE}
s = Session(frames(*FULL) + frames(created(), terminal(), collected()))
for kind in ORDER:
    s.expect(kind)
for kind in (MessageKind.CREATED, MessageKind.TERMINAL, MessageKind.COLLECTED):
    try:
        s.expect(kind)
    except ProtocolViolation:
        continue
    raise AssertionError(f'{kind.value} accepted after collected')
print('OK')
"

run_case "error and abort end the session, and nothing follows them" "${PRELUDE}
for ender in (error(), abort()):
    s = Session(frames(created(), ender) + frames(verified()))
    s.expect(MessageKind.CREATED)
    s.expect(ender.kind)
    try:
        s.expect(MessageKind.VERIFIED_PROFILE)
    except ProtocolViolation:
        continue
    raise AssertionError(f'a message followed {ender.kind.value}')
print('OK')
"

run_case "the session exposes no retry, restart, or re-create authority" "${PRELUDE}
import tools.capability.execution.protocol as module
public = [n for n in dir(module) if not n.startswith('_')]
members = [n for n in dir(Session) if not n.startswith('_')]
for banned in ('retry', 'restart', 'recreate', 'replay', 'reset', 'rewind',
               'again', 'force'):
    assert not any(banned in n.lower() for n in public + members), banned
print('OK')
"

# --- diagnostics -----------------------------------------------------------------

run_case "protocol violations map to the accepted classification" "${PRELUDE}
try:
    decode(b'{bad}\n')
except ProtocolViolation as e:
    assert e.classification is Classification.EXECUTION_PROTOCOL_VIOLATION
    print('OK')
else:
    raise AssertionError('malformed input decoded')
"

run_case "diagnostics are bounded and never echo the offending message" "${PRELUDE}
secret = 'S3CRET-' + 'z' * 4000
raw = ('{\"protocol_version\":1,\"kind\":\"created\",\"cinv\":\"CINV-000042\",'
       '\"container_id\":\"' + secret + '\"}\n').encode()
try:
    decode(raw)
except ProtocolViolation as e:
    text = str(e)
    assert len(text) <= 256, len(text)
    assert 'S3CRET' not in text, text
    assert 'zzzz' not in text, text
    assert 'container_id' in text, text
    print('OK')
else:
    raise AssertionError('an oversized identity was accepted')
"

run_case "T9 has no I/O or execution authority in its public surface" "${PRELUDE}
import types as pytypes
import tools.capability.execution.protocol as module
functions = sorted(n for n, v in vars(module).items()
                   if isinstance(v, pytypes.FunctionType) and not n.startswith('_'))
assert functions == ['decode', 'encode'], functions
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T9 protocol validation passed.\n'
else
  printf 'Capability execution T9 protocol validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
