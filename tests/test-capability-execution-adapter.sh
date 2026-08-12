#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T18.
#
# T18 wires the adapter into the runtime. It runs against an injected backend
# only: no Podman, no subprocess, no container, no provisioned runtime. Gates
# G4, G5, and G6 stay closed, and the CLI still reaches no adapter at all.
#
# THE ADAPTER DECIDES NOTHING. The profile comparison is T8's, the terminal
# classification is T13's, and result admission is T14's. The outcome class it
# reports is copied from T13 rather than recomputed, and the suite proves the
# module holds no second implementation of any of them.
#
# AMBIGUITY IS NEVER RESOLVED IN ITS OWN FAVOUR. Where execution cannot be
# excluded, nothing here says it did not happen: there is no
# transition_failed_before_execution to emit, no manufactured cleanup success,
# and no favourable lifecycle invented from a failure.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §7, §9
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T18

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
# The T18 backstop
# ===========================================================================
# The adapter is the one place every governed component meets. What it must
# not become is a place where any of them is implemented a second time.

assert_no_duplicated_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/adapter.py"

if not target.exists():
    print("adapter.py is absent")
    raise SystemExit(0)

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "socket", "shutil", "signal", "ctypes",
    "runpy", "importlib", "http", "urllib", "requests", "asyncio", "podman",
    "docker", "pty", "shlex", "tempfile", "json", "os", "hashlib", "time",
    "datetime", "random",
}
# Each of these is somebody else's single implementation. A call to one from
# here would mean a second one exists.
FORBIDDEN_CALLS = {
    "loads", "dumps", "scandir", "listdir", "walk", "unlink", "rmdir", "mkdir",
    "open", "system", "popen", "execv", "fork", "spawn", "statvfs",
    "sha256", "now", "monotonic", "sleep", "getenv",
}
# `argv` names a governed field on the binding, built by T12. What must not
# appear is the process's own argv, so the check is on `sys.argv` specifically.
FORBIDDEN_ATTRIBUTES = {"environ"}


def strip_documentation(tree):
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return ast.unparse(tree)


findings = []
source = target.read_text(encoding="utf-8")
tree = ast.parse(source)
code = strip_documentation(ast.parse(source))

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        module = node.module or ""
        if node.level == 0 and module.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"forbidden import-from: {module}")
    elif isinstance(node, ast.Call):
        attr = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"forbidden call: {attr}")
    elif isinstance(node, ast.Attribute):
        if node.attr in FORBIDDEN_ATTRIBUTES:
            findings.append(f"forbidden attribute: {node.attr}")
        if (node.attr == "argv"
                and isinstance(node.value, ast.Name) and node.value.id == "sys"):
            findings.append("forbidden attribute: sys.argv")

# Authority that must live elsewhere, named as code rather than as English.
for token, description in (
        ("podman ", "a Podman command"),
        ("--network", "argv construction"),
        ("def classify", "a second classification"),
        ("def collect", "a second collector"),
        ("def cleanup", "a second cleanup"),
        ("CADM", "administrative identity"),
        ("quarantine", "quarantine authority"),
        ("walk_tree", "filesystem traversal"),
        ("transition_failed_before_execution", "an excluded-execution claim")):
    if token in code:
        findings.append(f"adapter.py carries {description} ('{token}')")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T18 duplicates no authority and claims no excluded execution"
  else
    fail "T18 backstop found: ${report}"
  fi
}

assert_no_duplicated_authority

# ===========================================================================
# Behaviour
# ===========================================================================

PRELUDE="
import os
from tools.capability.execution import adapter as AD
from tools.capability.execution import lifecycle as L
from tools.capability.execution.protocol import MessageKind
from tools.capability.execution.types import Classification
from tools.capability.execution.profile import (
    ExecutionProfile, ObservedProfile, ProfileMismatch)

CID = 'a' * 64
OTHER = 'b' * 64


class Session:
    '''Start authority, as the coordinator would grant it.'''

    def __init__(self, container_id=CID, refuse=False):
        self.container_id = container_id
        self.refuse = refuse
        self.expected = 0

    def expect(self, kind):
        self.expected += 1
        if self.refuse:
            raise L.LifecycleRefused('no start authorisation was issued')

        class Message:
            def __init__(self, container_id):
                self._id = container_id

            def field_map(self):
                return {'container_id': self._id}

        return Message(self.container_id)


class Backend:
    '''The injected runtime seam. Creates nothing and starts nothing real.'''

    def __init__(self, *, state='exited', exit_code=0, started=True,
                 profile_matches=True, create_fails=False, container_id=CID):
        self.state = state
        self.exit_code = exit_code
        self.started = started
        self.profile_matches = profile_matches
        self.create_fails = create_fails
        self.container_id = container_id
        self.creates = 0
        self.starts = 0

    def create(self, argv, environment):
        self.creates += 1
        if self.create_fails:
            raise OSError('the runtime refused to create')
        return self.container_id

    def inspect(self, container_id):
        return {'ProfileSchemaVersion': 1 if self.profile_matches else 99}

    def start(self, container_id):
        self.starts += 1

    def lifecycle(self, container_id):
        return {'container_id': container_id, 'state': self.state,
                'started_at': '2026-08-12T00:00:00Z' if self.started else None,
                'finished_at': '2026-08-12T00:00:05Z',
                'exit_code': self.exit_code}


class Clock:
    def __init__(self, elapsed=0.0):
        self.values = [0.0, elapsed]

    def __call__(self):
        return self.values.pop(0) if self.values else 0.0


class Profile:
    '''Stands in for the T8 profile; comparison stays T8's to perform.'''


def binding(output_fd=None):
    return AD.ExecutionBinding(cinv='CINV-000001', profile=Profile(),
                               argv=('create',), environment=(),
                               output_fd=output_fd)


def build(backend=None, session=None, clock=None):
    return AD.PythonPodmanAdapter(backend=backend or Backend(),
                                  session=session or Session(),
                                  clock=clock or Clock())
"

run_case "the adapter reports the outcome class T13 concluded" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
adapter = build()
outcome = adapter.execute(binding())
assert outcome.outcome_class == 'completed', outcome.outcome_class
assert outcome.terminal.outcome_class == outcome.outcome_class, \\
    'the adapter recomputed the outcome instead of carrying it'
assert outcome.container_id == CID
print('OK')
"

run_case "a nonzero exit is provider-error, carried and not reinterpreted" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
adapter = build(backend=Backend(exit_code=3))
outcome = adapter.execute(binding())
assert outcome.outcome_class == 'provider-error', outcome.outcome_class
assert outcome.succeeded is False
print('OK')
"

run_case "a container that never started is never called started" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
adapter = build(backend=Backend(state='created', started=False, exit_code=0))
outcome = adapter.execute(binding())
assert outcome.outcome_class == 'adapter-error', outcome.outcome_class
assert outcome.started_proven is False
assert outcome.succeeded is False
print('OK')
"

run_case "a timeout stays a timeout however the workload finished" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
adapter = build(clock=Clock(elapsed=L.TIMEOUT_SECONDS + 1))
outcome = adapter.execute(binding())
assert outcome.outcome_class == 'timeout', outcome.outcome_class
assert outcome.succeeded is False
print('OK')
"

run_case "exactly one create and one start happen, and start needs authority" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
backend = Backend()
adapter = build(backend=backend)
adapter.execute(binding())
assert backend.creates == 1, backend.creates
assert backend.starts == 1, backend.starts

# Without authorisation nothing starts, and nothing is retried.
backend = Backend()
adapter = build(backend=backend, session=Session(refuse=True))
outcome = adapter.execute(binding())
assert backend.starts == 0, 'the adapter started without authorisation'
assert outcome.outcome_class == 'adapter-error'
print('OK')
"

run_case "a start authorising a different container is refused" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
backend = Backend()
adapter = build(backend=backend, session=Session(container_id=OTHER))
outcome = adapter.execute(binding())
assert backend.starts == 0, 'the adapter started a container it was not given'
assert outcome.outcome_class == 'adapter-error'
print('OK')
"

run_case "a profile mismatch is T8's refusal, carried as identity mismatch" "${PRELUDE}
import tools.capability.execution.adapter as module


def mismatch(profile, observed):
    raise ProfileMismatch(('profile_schema_version',))


module.verify_observed = mismatch
backend = Backend()
adapter = build(backend=backend)
outcome = adapter.execute(binding())
assert outcome.classification is Classification.EXECUTION_IDENTITY_MISMATCH, \\
    outcome.classification
assert backend.starts == 0, 'a mismatched container was started anyway'
assert outcome.succeeded is False
print('OK')
"

run_case "a failure that cannot exclude execution claims nothing about it" "${PRELUDE}
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None
adapter = build(backend=Backend(create_fails=True))
outcome = adapter.execute(binding())
assert outcome.outcome_class == 'adapter-error', outcome.outcome_class
assert outcome.classification is not \\
    Classification.TRANSITION_FAILED_BEFORE_EXECUTION
assert outcome.started_proven is False
assert outcome.succeeded is False
assert outcome.terminal is None, 'a lifecycle conclusion was manufactured'
print('OK')
"

run_case "success needs a trusted result, not merely a clean exit" "${PRELUDE}
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None

with TemporaryDirectory() as tmp:
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o700)
    handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
    try:
        outcome = build().execute(binding(output_fd=handle))
        # Exit zero, but no result.json: T14 admits nothing and so neither
        # does the adapter.
        assert outcome.outcome_class == 'completed', outcome.outcome_class
        assert outcome.succeeded is False, 'success without a trusted result'
        assert outcome.result is None
        assert outcome.output is not None, 'the tree was not collected'
    finally:
        os.close(handle)

with TemporaryDirectory() as tmp:
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o700)
    (out / 'result.json').write_bytes(json.dumps({'ok': True}).encode())
    handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
    try:
        outcome = build().execute(binding(output_fd=handle))
        assert outcome.succeeded is True, 'a valid result was not admitted'
        assert outcome.result.document['ok'] is True
    finally:
        os.close(handle)
print('OK')
"

run_case "a failed execution collects evidence but admits no result" "${PRELUDE}
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None

with TemporaryDirectory() as tmp:
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o700)
    (out / 'result.json').write_bytes(json.dumps({'ok': True}).encode())
    handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
    try:
        adapter = build(backend=Backend(exit_code=1))
        outcome = adapter.execute(binding(output_fd=handle))
        assert outcome.outcome_class == 'provider-error'
        assert outcome.output is not None, 'evidence was not collected'
        assert outcome.result is None, 'a failed execution produced a result'
        assert outcome.succeeded is False
    finally:
        os.close(handle)
print('OK')
"

run_case "a hostile output tree fails the invocation without a result" "${PRELUDE}
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import tools.capability.execution.adapter as module
module.verify_observed = lambda profile, observed: None

with TemporaryDirectory() as tmp:
    out = Path(tmp) / 'out'
    out.mkdir(mode=0o700)
    (out / 'result.json').write_bytes(json.dumps({'ok': True}).encode())
    os.symlink('/etc/shadow', out / 'sneaky')
    handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
    try:
        outcome = build().execute(binding(output_fd=handle))
        assert outcome.succeeded is False, 'a violating tree produced a result'
        assert outcome.result is None
        assert outcome.output is None
    finally:
        os.close(handle)
print('OK')
"

run_case "the adapter refuses anything that is not a governed binding" "${PRELUDE}
adapter = build()
for supplied in (None, 'CINV-000001', {'cinv': 'CINV-000001'}, object()):
    try:
        adapter.execute(supplied)
    except AD.AdapterRefused:
        continue
    raise AssertionError('accepted a binding of ' + repr(type(supplied)))
print('OK')
"

# --- coordinator wiring ------------------------------------------------------

run_case "the coordinator refuses without an adapter and without a binding" "${PRELUDE}
import inspect
from tools.capability.coordinator import prepare_invocation, REASON_NO_ADAPTER
names = inspect.signature(prepare_invocation).parameters
assert 'adapter' in names and 'execution_binding' in names, list(names)
assert names['adapter'].default is None, 'an adapter is wired in by default'
assert names['execution_binding'].default is None
assert REASON_NO_ADAPTER == 'no_authorised_adapter'
print('OK')
"

run_case "the CLI constructs no adapter and reaches no runtime" "${PRELUDE}
from pathlib import Path
body = Path('tools/capability/cli.py').read_text(encoding='utf-8')
for token in ('adapter', 'Adapter', 'podman', 'execution_binding'):
    assert token not in body, 'the CLI reaches ' + token
print('OK')
"

run_case "no real Podman, container, subprocess, or privilege was involved" "${PRELUDE}
import inspect
assert os.getuid() != 0
source = inspect.getsource(AD)
for token in ('subprocess', 'podman', 'setuid', 'sudo'):
    assert token not in source, token
print('OK')
"

run_case "the adapter suite runs in local validation and in CI" "${PRELUDE}
from pathlib import Path
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-adapter.sh'
assert name in validation, 'local validation does not run the adapter suite'
assert name in ci, 'ci does not run the adapter suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T18 adapter validation passed.\n'
else
  printf 'Capability execution T18 adapter validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
