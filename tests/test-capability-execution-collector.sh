#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T14.
#
# T14 reads what the workload left behind. It creates nothing, deletes nothing,
# quarantines nothing, and starts nothing: no Podman, no subprocess, no
# container. Gates G6 and G7 stay closed.
#
# THE COMPLETE TREE IS THE UNIT. A result is admitted only out of a tree that
# passed in full. Stopping at a valid result.json would mean a hostile object
# one directory along was never looked at, and the object planted next to the
# result is exactly where an attacker would put it. A valid result inside a
# violating tree fails the invocation.
#
# THE TERMINAL CLASSIFICATION DECIDES, NOT THE BYTES. Result content is data.
# It selects no path, moves no bound, and cannot reach back and change what
# T13 concluded. A capability cannot self-declare success.
#
# STRUCTURE AND DOCUMENT ARE DIFFERENT FAILURES. A hostile filesystem shape is
# output_tree_policy_violation; an absent result is result_missing; a result
# that fails its document contract is result_invalid. Collapsing them would
# report an attack on the privileged reader as somebody's malformed JSON.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §11
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T14

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

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

# ===========================================================================
# The T14 backstop
# ===========================================================================
# The collector is the first component to read bytes an adversary wrote, from a
# directory the adversary owns, while running as the privileged reader. What it
# must not be able to do is act on them.

assert_collector_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/collector.py"

if not target.exists():
    print("collector.py is absent")
    raise SystemExit(0)

# Starting something, changing something, or reaching anything off this host.
FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "socket", "shutil", "signal", "ctypes",
    "runpy", "importlib", "http", "urllib", "requests", "asyncio", "podman",
    "docker", "pty", "shlex", "time", "datetime", "random", "tempfile",
}
# Mutation of any kind, privilege of any kind, and the ambient clock.
FORBIDDEN_CALLS = {
    "unlink", "remove", "rmdir", "removedirs", "mkdir", "makedirs", "rename",
    "replace", "chmod", "chown", "truncate", "symlink", "link", "mknod",
    "mkfifo", "write", "setuid", "setgid", "seteuid", "setegid", "setgroups",
    "system", "popen", "execv", "execve", "fork", "spawn", "now", "today",
    "monotonic", "time", "sleep", "getenv", "putenv",
}
FORBIDDEN_ATTRIBUTES = {"environ", "argv"}

findings = []
source = target.read_text(encoding="utf-8")
tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"forbidden import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {attr}")
    elif isinstance(node, ast.Attribute):
        if node.attr in FORBIDDEN_ATTRIBUTES:
            findings.append(f"forbidden attribute: {node.attr}")

# Open flags are the other half of "read-only": a descriptor asked for with any
# write intent would pass the call scan above untouched.
for token in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "O_APPEND", "podman",
              "Podman", "sudo", "quarantine"):
    if token in source:
        findings.append(f"forbidden token: {token}")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T14 cannot mutate, execute, escalate, or read an ambient clock"
  else
    fail "T14 backstop found: ${report}"
  fi
}

assert_collector_authority

# ===========================================================================
# Behaviour
# ===========================================================================

PRELUDE="
import hashlib, json, os, socket, stat
from pathlib import Path
from tempfile import TemporaryDirectory

from tools.capability.execution import collector as C
from tools.capability.execution import lifecycle as L
from tools.capability.execution.types import Classification

CID = 'c' * 64
RESULT = json.dumps({'ok': True, 'rows': 3}).encode('utf-8')


def terminal(state='exited', exit_code=0, timed_out=False,
             started_proven=True, trustworthy=None,
             started_at='2026-08-12T00:00:00Z',
             finished_at='2026-08-12T00:00:05Z'):
    observed = L.LifecycleObservation(
        container_id=CID, state=state, started_at=started_at,
        finished_at=finished_at, exit_code=exit_code,
        started_proven=started_proven,
        exit_code_trustworthy=started_proven if trustworthy is None
        else trustworthy)
    return L.classify(observed, timed_out=timed_out)


def build(tmp, files=(), result=RESULT):
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o755)
    if result is not None:
        (out / 'result.json').write_bytes(result)
    for name, data in files:
        target = out / name
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        target.write_bytes(data)
    return out


def collect(out):
    handle = os.open(out, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        return C.collect(handle)
    finally:
        os.close(handle)


def refused(action, classification):
    try:
        action()
    except C.OutputRefused as error:
        assert error.classification is classification, error.classification
        return error
    raise AssertionError('accepted instead of refused as ' + str(classification))


def inventory(where):
    seen = {}
    for path in sorted(Path(where).rglob('*')):
        info = path.lstat()
        seen[str(path)] = (info.st_mode, info.st_size, info.st_ino, info.st_nlink)
    return seen
"

# --- the accepted path ------------------------------------------------------

run_case "a proven zero exit with a valid result yields a trusted result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    tree = collect(out)
    trusted = C.read_result(tree, terminal())
    assert isinstance(trusted, C.TrustedResult), type(trusted)
    assert trusted.document['ok'] is True, trusted.document
    assert trusted.document['rows'] == 3, trusted.document
    assert trusted.container_id == CID
print('OK')
"

run_case "the result is parsed through the T2 canonical grammar" "${PRELUDE}
import inspect
source = inspect.getsource(C)
assert 'canonical_json' in source, 'the collector parses JSON on its own'
with TemporaryDirectory() as tmp:
    # A float is valid JSON and is outside the accepted grammar, so accepting
    # it would prove the collector reached a different parser.
    out = build(tmp, result=b'{' + json.dumps('n').encode() + b': 1.5}')
    refused(lambda: C.read_result(collect(out), terminal()),
            Classification.RESULT_INVALID)
print('OK')
"

run_case "nested files are collected in deterministic relative-path order" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('b.txt', b'bravo'), ('a.txt', b'alpha'),
                            ('sub/deep/z.txt', b'zulu'), ('sub/a.txt', b'sa')))
    first = collect(out)
    second = collect(out)
    paths = [entry.relative_path for entry in first.manifest.files]
    assert paths == ['a.txt', 'b.txt', 'result.json', 'sub/a.txt',
                     'sub/deep/z.txt'], paths
    assert [e.relative_path for e in second.manifest.files] == paths
    assert first.manifest == second.manifest, 'the manifest is not deterministic'
    C.read_result(first, terminal())
print('OK')
"

run_case "the manifest carries exact sizes and digests and no timestamp" "${PRELUDE}
import dataclasses
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('a.txt', b'alpha'),))
    tree = collect(out)
    entry = [e for e in tree.manifest.files if e.relative_path == 'a.txt'][0]
    assert entry.size == 5, entry.size
    assert entry.sha256 == hashlib.sha256(b'alpha').hexdigest(), entry.sha256
    assert tree.manifest.file_count == 2, tree.manifest.file_count
    assert tree.manifest.total_bytes == 5 + len(RESULT), tree.manifest.total_bytes
    assert tree.manifest.result_present is True
    fields = {f.name for f in dataclasses.fields(entry)}
    fields |= {f.name for f in dataclasses.fields(tree.manifest)}
    for forbidden in ('mtime', 'ctime', 'atime', 'inode', 'ino', 'timestamp'):
        assert forbidden not in fields, forbidden
    try:
        entry.size = 9
    except dataclasses.FrozenInstanceError:
        pass
    else:
        raise AssertionError('the manifest entry is mutable')
print('OK')
"

# --- the result document contract -------------------------------------------

run_case "an absent result is result_missing, not a tree violation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('notes.txt', b'diagnostic'),), result=None)
    tree = collect(out)
    assert tree.manifest.result_present is False
    refused(lambda: C.read_result(tree, terminal()), Classification.RESULT_MISSING)
print('OK')
"

run_case "a malformed result is result_invalid" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, result=b'{not json at all')
    refused(lambda: C.read_result(collect(out), terminal()),
            Classification.RESULT_INVALID)
print('OK')
"

run_case "a duplicate key at any depth is result_invalid" "${PRELUDE}
key = json.dumps('a').encode()
for body in (b'{' + key + b': 1, ' + key + b': 2}',
             b'{' + json.dumps('outer').encode() + b': {' + key + b': 1, '
             + key + b': 2}}'):
    with TemporaryDirectory() as tmp:
        out = build(tmp, result=body)
        refused(lambda: C.read_result(collect(out), terminal()),
                Classification.RESULT_INVALID)
print('OK')
"

run_case "a result that is not a top-level object is result_invalid" "${PRELUDE}
for body in (b'[1, 2, 3]', b'42', b'null', json.dumps('a string').encode(),
             b'true'):
    with TemporaryDirectory() as tmp:
        out = build(tmp, result=body)
        refused(lambda: C.read_result(collect(out), terminal()),
                Classification.RESULT_INVALID)
print('OK')
"

run_case "two JSON documents in the result file are result_invalid" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, result=RESULT + RESULT)
    refused(lambda: C.read_result(collect(out), terminal()),
            Classification.RESULT_INVALID)
print('OK')
"

run_case "a result that is not UTF-8 is result_invalid" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, result=b'{' + json.dumps('a').encode()[:-1]
                + bytes([0xff, 0x22]) + b': 1}')
    refused(lambda: C.read_result(collect(out), terminal()),
            Classification.RESULT_INVALID)
print('OK')
"

run_case "the result is only ever the exact root-level name" "${PRELUDE}
for name in ('result.JSON', 'Result.json', 'results.json', 'result.json.txt'):
    with TemporaryDirectory() as tmp:
        out = build(tmp, files=((name, RESULT),), result=None)
        tree = collect(out)
        assert tree.manifest.result_present is False, name
        refused(lambda: C.read_result(tree, terminal()),
                Classification.RESULT_MISSING)
with TemporaryDirectory() as tmp:
    # A nested result.json is an ordinary file and never the result.
    out = build(tmp, files=(('sub/result.json', RESULT),), result=None)
    tree = collect(out)
    assert tree.manifest.result_present is False
    refused(lambda: C.read_result(tree, terminal()),
            Classification.RESULT_MISSING)
print('OK')
"

run_case "a result beyond 2 MiB is refused as a tree violation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, result=b'{' + b' ' * (2 * 1024 * 1024) + b'}')
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

# --- the complete tree ------------------------------------------------------

run_case "a valid result beside a symlink fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    os.symlink('/etc/shadow', out / 'sneaky')
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "a valid result beside a FIFO or a socket fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    os.mkfifo(out / 'pipe')
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
with TemporaryDirectory() as tmp:
    out = build(tmp)
    bound = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        bound.bind(str(out / 'sock'))
        refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
    finally:
        bound.close()
print('OK')
"

run_case "a device node beside a valid result fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    try:
        os.mknod(out / 'chr', 0o600 | stat.S_IFCHR, os.makedev(1, 3))
    except OSError:
        pass
    else:
        refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "a hard-link anomaly beside a valid result fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('one.txt', b'once'),))
    os.link(out / 'one.txt', out / 'two.txt')
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
with TemporaryDirectory() as tmp:
    # The result file itself is not exempt from the invariant.
    out = build(tmp)
    os.link(out / 'result.json', out / 'alias.json')
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "the 33rd regular file fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=tuple((f'f{i:02d}.txt', b'x') for i in range(31)))
    assert collect(out).manifest.file_count == 32
with TemporaryDirectory() as tmp:
    out = build(tmp, files=tuple((f'f{i:02d}.txt', b'x') for i in range(32)))
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "a single regular file beyond 2 MiB fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('big.bin', b'x' * (2 * 1024 * 1024 + 1)),))
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('big.bin', b'x' * (2 * 1024 * 1024)),))
    assert collect(out).manifest.total_bytes == 2 * 1024 * 1024 + len(RESULT)
print('OK')
"

run_case "an aggregate beyond 16 MiB fails the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=tuple((f'f{i}.bin', b'x' * (2 * 1024 * 1024))
                                 for i in range(9)))
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "depth 17 and the 257th entry each fail the invocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('/'.join('d' * 16) + '/deep.txt', b'x'),))
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
with TemporaryDirectory() as tmp:
    # No regular file at all, and still refused: the entry ceiling is not the
    # file ceiling wearing a different number.
    out = build(tmp, result=None)
    for index in range(257):
        (out / f'e{index:03d}').mkdir(mode=0o755)
    refused(lambda: collect(out), Classification.OUTPUT_TREE_POLICY_VIOLATION)
print('OK')
"

run_case "the accepted bounds are exactly the specified ones" "${PRELUDE}
assert C.OUTPUT_TREE_MAX_DEPTH == 16, C.OUTPUT_TREE_MAX_DEPTH
assert C.OUTPUT_TREE_MAX_ENTRIES == 256, C.OUTPUT_TREE_MAX_ENTRIES
assert C.OUTPUT_MAXIMUM_FILES == 32, C.OUTPUT_MAXIMUM_FILES
assert C.OUTPUT_MAXIMUM_FILE_BYTES == 2 * 1024 * 1024
assert C.OUTPUT_MAXIMUM_TOTAL_BYTES == 16 * 1024 * 1024
assert C.RESULT_NAME == 'result.json', C.RESULT_NAME
print('OK')
"

# --- the terminal gate ------------------------------------------------------

run_case "a nonzero exit cannot yield a trusted result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    tree = collect(out)
    outcome = terminal(exit_code=1)
    assert outcome.outcome_class == 'provider-error', outcome.outcome_class
    error = refused(lambda: C.read_result(tree, outcome), None)
    assert 'collect' in str(error).lower() or 'permit' in str(error).lower()
print('OK')
"

run_case "a timeout cannot yield a trusted result even with a valid result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    outcome = terminal(timed_out=True)
    assert outcome.outcome_class == 'timeout'
    refused(lambda: C.read_result(tree, outcome), None)
print('OK')
"

run_case "a lifecycle integrity failure cannot yield a trusted result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    outcome = terminal(state='wedged')
    assert outcome.classification is Classification.EXECUTION_LIFECYCLE_INTEGRITY_FAILURE
    refused(lambda: C.read_result(tree, outcome), None)
print('OK')
"

run_case "an untrustworthy exit code cannot yield a trusted result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    outcome = terminal(trustworthy=False)
    assert outcome.outcome_class == 'adapter-error', outcome.outcome_class
    refused(lambda: C.read_result(tree, outcome), None)
print('OK')
"

run_case "a container that never started cannot yield a trusted result" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    outcome = terminal(state='created', started_proven=False, started_at=None,
                       finished_at=None)
    assert outcome.outcome_class == 'adapter-error'
    refused(lambda: C.read_result(tree, outcome), None)
print('OK')
"

run_case "a forged permission with a nonzero exit is still refused" "${PRELUDE}
import dataclasses
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    # may_collect_result alone is not the boundary: every condition the design
    # names is checked, so a classification that disagrees with itself cannot
    # let a result through.
    forged = dataclasses.replace(terminal(exit_code=7), may_collect_result=True)
    refused(lambda: C.read_result(tree, forged), None)
    forged = dataclasses.replace(terminal(), exit_code=7)
    refused(lambda: C.read_result(tree, forged), None)
    forged = dataclasses.replace(terminal(), started_proven=False)
    refused(lambda: C.read_result(tree, forged), None)
print('OK')
"

run_case "a refused gate reports the terminal failure, not a result failure" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    for outcome in (terminal(exit_code=1), terminal(timed_out=True),
                    terminal(state='wedged')):
        try:
            C.read_result(tree, outcome)
        except C.OutputRefused as error:
            assert error.classification is None, error.classification
        else:
            raise AssertionError('a failed terminal state admitted a result')
print('OK')
"

# --- the result cannot reach back -------------------------------------------

run_case "result content selects no path and moves no bound" "${PRELUDE}
with TemporaryDirectory() as tmp:
    hostile = json.dumps({
        'result_path': '../../etc/shadow',
        'maximum_files': 9999,
        'OUTPUT_MAXIMUM_FILES': 9999,
        'exit_code': 0,
        'outcome_class': 'completed',
        'succeeded': True,
        'may_collect_result': True,
        'timed_out': False,
    }).encode()
    out = build(tmp, result=hostile)
    outcome = terminal(exit_code=3)
    refused(lambda: C.read_result(collect(out), outcome), None)
    assert C.OUTPUT_MAXIMUM_FILES == 32, 'the payload moved a bound'
    trusted = C.read_result(collect(out), terminal())
    assert trusted.container_id == CID
    assert trusted.document['succeeded'] is True, 'the document is still data'
print('OK')
"

run_case "the collected tree is untrusted whatever the terminal said" "${PRELUDE}
with TemporaryDirectory() as tmp:
    tree = collect(build(tmp))
    assert not isinstance(tree, C.TrustedResult)
    assert not hasattr(tree, 'trusted'), 'a boolean flag invites being ignored'
    assert not hasattr(tree, 'succeeded')
    # Collection itself is neutral: it neither consults nor needs the terminal
    # state, so forensic collection after a failure uses the same call.
    import inspect
    assert list(inspect.signature(C.collect).parameters) == ['out_fd'], \
        inspect.signature(C.collect)
print('OK')
"

# --- descriptor authority and mutation --------------------------------------

run_case "collection is rooted on a descriptor and never on a name" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp)
    for supplied in (str(out), Path(out), None, True):
        refused(lambda s=supplied: C.collect(s),
                Classification.OUTPUT_TREE_POLICY_VIOLATION)
    handle = os.open(out, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        C.collect(handle)
        assert stat.S_ISDIR(os.fstat(handle).st_mode), 'the descriptor was closed'
    finally:
        os.close(handle)
print('OK')
"

run_case "collecting and refusing changes nothing on disk" "${PRELUDE}
with TemporaryDirectory() as tmp:
    out = build(tmp, files=(('a.txt', b'alpha'), ('sub/b.txt', b'bravo')))
    before = inventory(tmp)
    collect(out)
    C.read_result(collect(out), terminal())
    assert inventory(tmp) == before, 'a successful collection changed the tree'
    os.mkfifo(out / 'pipe')
    before = inventory(tmp)
    try:
        collect(out)
    except C.OutputRefused:
        pass
    assert inventory(tmp) == before, 'a refused collection changed the tree'
print('OK')
"

run_case "no real Podman, container, or privilege was involved" "${PRELUDE}
import inspect
assert os.getuid() != 0
source = inspect.getsource(C)
for token in ('subprocess', 'podman', 'setuid', 'sudo'):
    assert token not in source, token
print('OK')
"

# --- the suite is wired in --------------------------------------------------

run_case "the collector suite runs in local validation and in CI" "${PRELUDE}
root = Path('.')
validation = (root / 'tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = (root / '.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-collector.sh'
assert name in validation, 'local validation does not run the collector suite'
assert name in ci, 'ci does not run the collector suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T14 collector validation passed.\n'
else
  printf 'Capability execution T14 collector validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
