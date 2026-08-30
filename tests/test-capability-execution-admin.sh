#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T17.
#
# T17 binds already-designed reconciliation operations to authenticated
# administrative authority and a CADM record. It creates no power the bound
# operations did not already have: no shell, no arbitrary Podman argv, no
# caller path, no caller-supplied container ID, no repair, no replay.
#
# THE VERB SET IS CLOSED. Thirteen mutating verbs and one inspection, exactly
# as §20 lists them. There is no generic delete, cleanup, force, repair, or
# exec verb, and the suite asserts the set rather than sampling it.
#
# INTENT, ONE ATTEMPT, OUTCOME. In that order, each durable, each create-once.
# A crash between intent and outcome is intent-with-unknown-outcome and is
# never replayed: a retry is a fresh authentication and a fresh CADM.
#
# DESTRUCTION IS NARROWER THAN DISCOVERY. It may target only an immutable ID
# already durably bound to the condition being reconciled. A name never
# substitutes, an unstable collision has no destruction authority, and a target
# that disappeared is recorded absent rather than retargeted at a replacement.
#
# UNPRIVILEGED THROUGHOUT. No sudoers, no real authentication, no helper
# installation, no privileged deletion. Gates G2, G3, and G6 stay closed.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §17, §20
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T17

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
export WORKDIR

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
# The T17 backstop
# ===========================================================================
# This is the component an operator drives, which makes it the one an attacker
# would most like to widen. The scan below is what keeps administrative
# authority equal to the operations it dispatches and no larger.

assert_admin_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
targets = [root / "tools/capability/execution/admin.py",
           root / "provisioning/execution/kyri-exec-admin.py"]

missing = [str(t.relative_to(root)) for t in targets if not t.exists()]
if missing:
    print("absent: " + ", ".join(missing))
    raise SystemExit(0)

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "socket", "shutil", "signal", "ctypes",
    "runpy", "importlib", "http", "urllib", "requests", "asyncio", "podman",
    "docker", "pty", "shlex", "tempfile", "glob", "fnmatch", "time",
    "datetime", "random",
}
# Repair, reset, replay, and privilege are the four widenings that would each
# turn reconciliation into something that acts on its own.
FORBIDDEN_CALLS = {
    "system", "popen", "execv", "execve", "execvp", "fork", "spawn", "kill",
    "setuid", "setgid", "seteuid", "setegid", "setgroups", "umask",
    "chmod", "chown", "rmtree", "makedirs", "now", "today", "monotonic",
    "sleep", "getenv", "putenv", "input",
}
# argv belongs to the helper, which is a command-line entry point and has to
# read its own arguments. It does not belong to the dispatcher.
FORBIDDEN_ATTRIBUTES = {"admin.py": {"environ", "argv"},
                        "kyri-exec-admin.py": {"environ"}}
# Widened authority named as code rather than as English. The scan runs over
# the source with comments and docstrings removed, because prose stating that
# a power is absent would otherwise read as the power being present.
FORBIDDEN_TEXT = ("podman system", "podman rmi", "prune", "--force",
                  "--privileged", "image rm", "volume rm", "network rm",
                  "reset_counter", "auto_replay", "self_repair")


def strip_documentation(tree):
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", None)
        if (body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return ast.unparse(tree)


findings = []
for target in targets:
    name = target.name
    source = target.read_text(encoding="utf-8")
    tree = ast.parse(source)
    code = strip_documentation(ast.parse(source))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                    findings.append(f"{name}: forbidden import: {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{name}: forbidden import-from: {module}")
        elif isinstance(node, ast.Call):
            attr = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
            if attr in FORBIDDEN_CALLS:
                findings.append(f"{name}: forbidden call: {attr}")
        elif isinstance(node, ast.Attribute):
            if node.attr in FORBIDDEN_ATTRIBUTES[name]:
                findings.append(f"{name}: forbidden attribute: {node.attr}")
    for phrase in FORBIDDEN_TEXT:
        if phrase in code:
            findings.append(f"{name}: carries the widened authority '{phrase}'")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T17 gains no shell, privilege, repair, replay, or Podman authority"
  else
    fail "T17 backstop found: ${report}"
  fi
}

assert_admin_authority

# ===========================================================================
# Behaviour
# ===========================================================================

PRELUDE="
import os, shutil, stat
from pathlib import Path

from tools.capability.execution.canonical_json import serialise, parse
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)
from tools.capability.execution.mutation import (
    CMUT_COUNTER, Mutation, MutationTarget, TargetKind)
from tools.capability.execution.state import (
    LOCKS_DIRECTORY, TRANSITIONS_DIRECTORY, current_state, transition,
    open_state_locked)
from tools.capability.execution.types import Classification, LifecycleState
from tools.capability.execution import quarantine as Q
from tools.capability.execution import cleanup as K
from tools.capability.execution import admin as A

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
CINV = 'CINV-000001'
CONTAINER = 'a' * 64
OTHER = 'b' * 64


class Backend:
    '''The injected destruction backend. Records; destroys nothing real.'''

    def __init__(self, absent=False):
        self.destroyed = []
        self.absent = absent

    def destroy(self, container_id):
        self.destroyed.append(container_id)
        if self.absent:
            raise LookupError('no such container')


def make(name):
    base = os.path.join(WORK, name)
    if os.path.isdir(base):
        shutil.rmtree(base)
    for sub in ('root/mutations', 'root/state', 'root/' + TRANSITIONS_DIRECTORY,
                'root/' + LOCKS_DIRECTORY, 'root/' + Q.RESERVATIONS_DIRECTORY,
                'root/' + Q.RELEASES_DIRECTORY, 'root/' + A.ADMIN_RECORDS,
                'root/' + A.INSPECTION_AUDIT, 'handoff', 'store'):
        os.makedirs(os.path.join(base, sub), mode=0o700)
    with open(os.path.join(base, 'backing-store.json'), 'wb') as handle:
        handle.write(serialise({'filesystem_uuid': UUID,
                                'filesystem_type': 'xfs',
                                'mount_point': '/data'}))
    with open(os.path.join(base, 'root', CMUT_COUNTER), 'wb') as handle:
        handle.write(b'000000000000\n')
    with open(os.path.join(base, 'root', A.CADM_COUNTER), 'wb') as handle:
        handle.write(b'000000\n')
    return base


def anchor(base, which):
    cfg = os.open(os.path.join(base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(base, which), os.O_RDONLY | os.O_DIRECTORY)
    try:
        return verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)


def ready(name, backend=None):
    base = make(name)
    root = anchor(base, 'root')
    context = A.AdminContext(root=root, handoff=anchor(base, 'handoff'),
                             store=anchor(base, 'store'),
                             backend=Backend() if backend is None else backend)
    return base, context


def bind(context, cinv=CINV, container_id=CONTAINER, condition='execution'):
    '''Write the create-once binding T18 will own.'''
    body = serialise({'cinv': cinv, 'schema_version': A.BINDING_SCHEMA_VERSION,
                      'container_id': container_id, 'condition': condition})
    import hashlib
    mutation = Mutation(context.root)
    cadm = mutation.begin(
        MutationTarget(kind=TargetKind.EXECUTION_STATE, name=cinv),
        schema_type='execution-binding',
        expected_sha256=hashlib.sha256(body).hexdigest())
    mutation.install(cadm, body)
    mutation.commit(cadm)


def granted(verb, operator='operator'):
    return A.Authorisation(verb=verb, operator=operator)


def refuses(action, classification, what):
    try:
        action()
    except A.AdminError as error:
        assert error.classification is classification, (
            what + ': ' + str(error.classification))
        return error
    raise AssertionError(what + ': accepted instead of refused')
"

# --- the closed verb set ----------------------------------------------------

run_case "the verb set is exactly the fourteen §20 verbs" "${PRELUDE}
expected = {'retain', 'destroy', 'retain-residue', 'retry-cleanup',
            'retain-collision', 'destroy-collision', 'retain-start-unknown',
            'destroy-start-unknown', 'retain-lifecycle-failure',
            'destroy-lifecycle-failure', 'acknowledge-state-lost',
            'retain-quarantine-incomplete', 'retain-quarantine-residue',
            'inspect-admin-integrity'}
actual = {verb.value for verb in A.Verb}
assert actual == expected, sorted(actual ^ expected)
for invented in ('delete', 'cleanup', 'podman', 'repair', 'force', 'exec',
                 'prune', 'destroy-residue', 'reset'):
    try:
        A.Verb(invented)
    except ValueError:
        continue
    raise AssertionError('an invented verb exists: ' + invented)
print('OK')
"

run_case "only inspection is non-mutating and only it allocates no CADM" "${PRELUDE}
mutating = {v for v in A.Verb if A.is_mutating(v)}
assert A.Verb.INSPECT_ADMIN_INTEGRITY not in mutating
assert len(mutating) == 13, len(mutating)
print('OK')
"

# --- CADM allocation ---------------------------------------------------------

run_case "CADM is six digits, monotonic, and gaps are permanent" "${PRELUDE}
base, context = ready('cadm')
first = A.allocate_cadm(context.root)
second = A.allocate_cadm(context.root)
assert first == 'CADM-000001', first
assert second == 'CADM-000002', second
import re
assert re.fullmatch(r'CADM-[0-9]{6}', first), first
# A gap opened by an abandoned allocation is never reused.
third = A.allocate_cadm(context.root)
assert third == 'CADM-000003', third
print('OK')
"

run_case "the CADM counter is provisioned and never bootstrapped at runtime" "${PRELUDE}
base, context = ready('nobootstrap')
os.unlink(os.path.join(base, 'root', A.CADM_COUNTER))
refuses(lambda: A.allocate_cadm(context.root),
        Classification.ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE,
        'allocated without a provisioned counter')
assert not os.path.exists(os.path.join(base, 'root', A.CADM_COUNTER)), \\
    'the counter was created at runtime'
print('OK')
"

run_case "a rolled-back counter is detected and fails closed" "${PRELUDE}
base, context = ready('rollback')
# A bare allocation leaves no trace by design -- gaps are permanent. The
# witness for a rollback is the records that exist, so make two.
for _ in range(2):
    cadm = A.allocate_cadm(context.root)
    A.record_intent(context.root, cadm, A.Verb.RETAIN, CINV, None)
with open(os.path.join(base, 'root', A.CADM_COUNTER), 'wb') as handle:
    handle.write(b'000000\n')
refuses(lambda: A.allocate_cadm(context.root),
        Classification.ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE,
        'allocated behind the recorded high-water mark')
print('OK')
"

run_case "an exhausted counter fails closed rather than wrapping" "${PRELUDE}
base, context = ready('exhausted')
with open(os.path.join(base, 'root', A.CADM_COUNTER), 'wb') as handle:
    handle.write(b'999999\n')
refuses(lambda: A.allocate_cadm(context.root), None, 'allocated past exhaustion')
print('OK')
"

run_case "a malformed counter is integrity failure, never a guess" "${PRELUDE}
for body in (b'12345\n', b'0000001\n', b'abcdef\n', b'000001', b'', b'-00001\n'):
    base, context = ready('malformed')
    with open(os.path.join(base, 'root', A.CADM_COUNTER), 'wb') as handle:
        handle.write(body)
    refuses(lambda: A.allocate_cadm(context.root),
            Classification.ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE,
            'accepted counter ' + repr(body))
print('OK')
"

# --- intent, one attempt, outcome -------------------------------------------

run_case "intent precedes the attempt and outcome follows it" "${PRELUDE}
base, context = ready('ordering')
bind(context)
outcome = A.perform(context, granted(A.Verb.RETAIN), CINV)
records = Path(base) / 'root' / A.ADMIN_RECORDS / outcome.cadm
assert (records / A.INTENT).exists(), 'no durable intent'
assert (records / A.OUTCOME).exists(), 'no durable outcome'
intent = parse((records / A.INTENT).read_bytes(), maximum_bytes=65536)
assert intent['verb'] == 'retain', intent
assert intent['cinv'] == CINV
print('OK')
"

run_case "intent and outcome are create-once" "${PRELUDE}
base, context = ready('createonce')
cadm = A.allocate_cadm(context.root)
A.record_intent(context.root, cadm, A.Verb.RETAIN, CINV, None)
refuses(lambda: A.record_intent(context.root, cadm, A.Verb.RETAIN, CINV, None),
        None, 'intent was rewritten')
A.record_outcome(context.root, cadm, 'retained')
refuses(lambda: A.record_outcome(context.root, cadm, 'retained-again'),
        None, 'outcome was rewritten')
print('OK')
"

run_case "a crash between intent and outcome is unknown, never replayed" "${PRELUDE}
base, context = ready('unknown')
cadm = A.allocate_cadm(context.root)
A.record_intent(context.root, cadm, A.Verb.DESTROY, CINV, CONTAINER)
# The process died here. Nothing resumes it.
assert A.unknown_outcomes(context.root) == (cadm,), A.unknown_outcomes(context.root)
backend = context.backend
assert backend.destroyed == [], 'an unknown outcome was replayed'
# A retry is a new authentication and a new CADM, never this one.
bind(context)
second = A.perform(context, granted(A.Verb.RETAIN), CINV)
assert second.cadm != cadm, 'a retry reused the abandoned CADM'
assert cadm in A.unknown_outcomes(context.root), \\
    'the unknown outcome was quietly resolved'
print('OK')
"

run_case "reconciliation sequence is derived from records, not a counter" "${PRELUDE}
base, context = ready('reconciliations')
cadm = A.allocate_cadm(context.root)
A.record_intent(context.root, cadm, A.Verb.RETAIN, CINV, None)
first = A.record_reconciliation(context.root, cadm, 'observed absent')
second = A.record_reconciliation(context.root, cadm, 'observed again')
assert first == '000001' and second == '000002', (first, second)
directory = Path(base) / 'root' / A.ADMIN_RECORDS / cadm / A.RECONCILIATIONS
assert sorted(p.name for p in directory.iterdir()) == ['000001', '000002']
# No mutable per-CADM counter exists to be rolled back.
assert not (directory.parent / 'counter').exists()
assert not (directory / 'counter').exists()
print('OK')
"

# --- the destruction invariant ----------------------------------------------

run_case "destroy refuses a container name and every caller-supplied identity" "${PRELUDE}
base, context = ready('names')
bind(context)
names = list(__import__('inspect').signature(A.perform).parameters)
assert names == ['context', 'authorisation', 'cinv'], names
# There is nowhere to put a container ID, which is the point: the only
# identity destruction can reach is the one already durably bound.
try:
    A.perform(context, granted(A.Verb.DESTROY), CINV, container_id='kyri-CINV-000001')
except TypeError:
    pass
else:
    raise AssertionError('destroy accepted a container name')
print('OK')
"

run_case "destruction targets only the durably bound immutable identity" "${PRELUDE}
base, context = ready('bound')
bind(context, container_id=CONTAINER)
outcome = A.perform(context, granted(A.Verb.DESTROY), CINV)
assert context.backend.destroyed == [CONTAINER], context.backend.destroyed
assert outcome.target == CONTAINER, outcome.target
print('OK')
"

run_case "destruction without a durable binding refuses entirely" "${PRELUDE}
for verb in (A.Verb.DESTROY, A.Verb.DESTROY_COLLISION,
             A.Verb.DESTROY_START_UNKNOWN, A.Verb.DESTROY_LIFECYCLE_FAILURE):
    base, context = ready('unbound')
    refuses(lambda v=verb: A.perform(context, granted(v), CINV), None,
            'destroyed without a binding (' + verb.value + ')')
    assert context.backend.destroyed == [], verb.value
print('OK')
"

run_case "an unstable collision admits retain only, never destruction" "${PRELUDE}
base, context = ready('unstable')
bind(context, condition=A.CONDITION_COLLISION_UNSTABLE)
refuses(lambda: A.perform(context, granted(A.Verb.DESTROY_COLLISION), CINV),
        None, 'destroyed an unstable collision')
assert context.backend.destroyed == []
# The stable condition is what admits destruction.
base, context = ready('stable')
bind(context, condition=A.CONDITION_COLLISION_STABLE)
A.perform(context, granted(A.Verb.DESTROY_COLLISION), CINV)
assert context.backend.destroyed == [CONTAINER]
# retain-collision is available for both.
base, context = ready('unstable-retain')
bind(context, condition=A.CONDITION_COLLISION_UNSTABLE)
A.perform(context, granted(A.Verb.RETAIN_COLLISION), CINV)
print('OK')
"

run_case "a destroying verb refuses a binding made for another condition" "${PRELUDE}
base, context = ready('wrongcondition')
bind(context, condition=A.CONDITION_COLLISION_STABLE)
refuses(lambda: A.perform(context, granted(A.Verb.DESTROY_START_UNKNOWN), CINV),
        None, 'destroyed against a binding for another condition')
assert context.backend.destroyed == []
print('OK')
"

run_case "state-lost has no destruction target at all" "${PRELUDE}
base, context = ready('statelost')
bind(context, condition=A.CONDITION_STATE_LOST)
A.perform(context, granted(A.Verb.ACKNOWLEDGE_STATE_LOST), CINV)
assert context.backend.destroyed == [], 'acknowledgement destroyed something'
for verb in (A.Verb.DESTROY, A.Verb.DESTROY_COLLISION):
    refuses(lambda v=verb: A.perform(context, granted(v), CINV), None,
            'destroyed a state-lost condition')
print('OK')
"

run_case "a target that disappeared is recorded absent, never retargeted" "${PRELUDE}
base, context = ready('absent', backend=Backend(absent=True))
bind(context, container_id=CONTAINER)
outcome = A.perform(context, granted(A.Verb.DESTROY), CINV)
assert outcome.result == A.RESULT_ABSENT, outcome.result
assert context.backend.destroyed == [CONTAINER], 'a replacement was targeted'
records = Path(base) / 'root' / A.ADMIN_RECORDS / outcome.cadm
body = parse((records / A.OUTCOME).read_bytes(), maximum_bytes=65536)
assert body['result'] == A.RESULT_ABSENT, body
print('OK')
"

run_case "exactly one side-effect attempt is made per CADM" "${PRELUDE}
base, context = ready('once')
bind(context)
A.perform(context, granted(A.Verb.DESTROY), CINV)
assert len(context.backend.destroyed) == 1, context.backend.destroyed
# A second authenticated attempt is a new CADM and refuses on the closed
# outcome rather than destroying twice under the first.
refuses(lambda: A.perform(context, granted(A.Verb.DESTROY), CINV), None,
        'destroyed twice for one condition')
assert len(context.backend.destroyed) == 1, context.backend.destroyed
print('OK')
"

# --- verbs bind to the existing narrow operations ---------------------------

run_case "retry-cleanup runs the exact T16 algorithm with no larger limits" "${PRELUDE}
import inspect
base, context = ready('retrycleanup')
# The invocation is where cleanup left it, with its subtree still present.
open_state_locked(context.root, CINV)
order = list(LifecycleState)
for index in range(order.index(LifecycleState.RESERVED),
                   order.index(LifecycleState.COLLECTED)):
    transition(context.root, CINV, order[index], order[index + 1])
tree = Path(base) / 'handoff' / CINV
(tree / 'out').mkdir(mode=0o755, parents=True)
(tree / 'out' / 'leftover.txt').write_bytes(b'residue')

outcome = A.perform(context, granted(A.Verb.RETRY_CLEANUP), CINV)
assert not tree.exists(), 'retry-cleanup did not run the cleanup'
assert current_state(context.root, CINV) is LifecycleState.CLEANED
# No larger limits, and no force mode: the bounds it uses are T16's own.
source = inspect.getsource(A)
assert not hasattr(A, 'CLEANUP_MAX_DEPTH'), 'admin defines its own cleanup depth'
assert not hasattr(A, 'CLEANUP_MAX_ENTRIES'), 'admin defines its own cleanup width'
assert 'cleanup(' in source, 'retry-cleanup does not call the cleanup operation'
print('OK')
"

run_case "retry-cleanup reports T16's failure without widening anything" "${PRELUDE}
base, context = ready('retryfail')
open_state_locked(context.root, CINV)
order = list(LifecycleState)
for index in range(order.index(LifecycleState.RESERVED),
                   order.index(LifecycleState.COLLECTED)):
    transition(context.root, CINV, order[index], order[index + 1])
tree = Path(base) / 'handoff' / CINV
deep = tree / 'out'
deep.mkdir(mode=0o755, parents=True)
for level in range(33):
    deep = deep / 'd'
deep.mkdir(mode=0o755, parents=True)

outcome = A.perform(context, granted(A.Verb.RETRY_CLEANUP), CINV)
assert outcome.classification is Classification.EXECUTION_CLEANUP_INCOMPLETE, \\
    outcome.classification
assert tree.exists(), 'a failed retry deleted anyway'
assert current_state(context.root, CINV) is LifecycleState.COLLECTED
# Each retry is separately authenticated with its own CADM.
second = A.perform(context, granted(A.Verb.RETRY_CLEANUP), CINV)
assert second.cadm != outcome.cadm, 'a retry reused a CADM'
print('OK')
"

run_case "the quarantine verbs bind to T15 and add no deletion" "${PRELUDE}
base, context = ready('quarantine')
reservation = Q.admit(context.root, context.store, CINV,
                      space=lambda: Q.FilesystemSpace(free_bytes=1024 ** 4,
                                                      total_bytes=2 * 1024 ** 4))
out = Path(base) / 'out'
out.mkdir(mode=0o700)
(out / 'result.json').write_bytes(b'{}')
handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
try:
    Q.collect(context.root, context.store, reservation, handle)
finally:
    os.close(handle)

outcome = A.perform(context, granted(A.Verb.RETAIN_QUARANTINE_INCOMPLETE), CINV)
assert Q.condition(context.store, CINV) == 'sealed', outcome
print('OK')
"

run_case "a partial namespace beyond T15 limits keeps its own classification" "${PRELUDE}
base, context = ready('quarantine-bad')
reservation = Q.admit(context.root, context.store, CINV,
                      space=lambda: Q.FilesystemSpace(free_bytes=1024 ** 4,
                                                      total_bytes=2 * 1024 ** 4))
out = Path(base) / 'out'
out.mkdir(mode=0o700)
(out / 'result.json').write_bytes(b'{}')
handle = os.open(out, os.O_RDONLY | os.O_DIRECTORY)
try:
    Q.collect(context.root, context.store, reservation, handle)
finally:
    os.close(handle)
os.mkfifo(Path(base) / 'store' / CINV / Q.DATA_DIRECTORY / 'pipe')

outcome = A.perform(context, granted(A.Verb.RETAIN_QUARANTINE_INCOMPLETE), CINV)
assert outcome.classification is \\
    Classification.QUARANTINE_INCOMPLETE_INTEGRITY_FAILURE, outcome.classification
assert Q.condition(context.store, CINV) == 'incomplete'
# Residue remains the only onward move, and adds no deletion verb.
A.perform(context, granted(A.Verb.RETAIN_QUARANTINE_RESIDUE), CINV)
assert Q.condition(context.store, CINV) == 'residue'
print('OK')
"

# --- authorisation ------------------------------------------------------------

run_case "an authorisation is granted for exactly one verb" "${PRELUDE}
base, context = ready('auth')
bind(context)
# The authorisation names the verb, and only a real one is accepted.
authorisation = granted(A.Verb.RETAIN)
outcome = A.perform(context, authorisation, CINV)
assert outcome.verb is A.Verb.RETAIN
for supplied in (None, 'retain', A.Verb.RETAIN.value, object()):
    refuses(lambda s=supplied: A.perform(context, s, CINV), None,
            'accepted a non-authorisation')
print('OK')
"

run_case "inspection allocates no CADM and mutates nothing" "${PRELUDE}
base, context = ready('inspect')
before = A.allocate_cadm(context.root)
summary = A.inspect_admin_integrity(context.root, audit=A.Audit())
after = A.allocate_cadm(context.root)
assert int(after[5:]) == int(before[5:]) + 1, (before, after)
assert summary.entries_scanned >= 0
print('OK')
"

run_case "the inspection audit commits before the summary is emitted" "${PRELUDE}
base, context = ready('audit')


class FailingAudit(A.Audit):
    def commit(self, root, body):
        raise OSError('the audit device is full')


refuses(lambda: A.inspect_admin_integrity(context.root, audit=FailingAudit()),
        Classification.INSPECTION_AUDIT_COMMIT_FAILED,
        'emitted a summary after a failed audit commit')

order = []


class WatchingAudit(A.Audit):
    def commit(self, root, body):
        order.append('audit')
        return super().commit(root, body)


summary = A.inspect_admin_integrity(context.root, audit=WatchingAudit())
order.append('summary')
assert order == ['audit', 'summary'], order
events = list((Path(base) / 'root' / A.INSPECTION_AUDIT).iterdir())
assert len(events) == 1, events
print('OK')
"

run_case "an unexpected object in the admin namespace blocks mutation globally" "${PRELUDE}
base, context = ready('unexpected')
os.mkfifo(Path(base) / 'root' / A.ADMIN_RECORDS / 'pipe')
refuses(lambda: A.allocate_cadm(context.root),
        Classification.ADMINISTRATIVE_RECORD_UNEXPECTED_OBJECT,
        'allocated over an unexpected object')
refuses(lambda: A.perform(context, granted(A.Verb.RETAIN), CINV),
        Classification.ADMINISTRATIVE_RECORD_UNEXPECTED_OBJECT,
        'dispatched over an unexpected object')
# Inspection stays available at any time, which is the point of it.
summary = A.inspect_admin_integrity(context.root, audit=A.Audit())
assert summary.blocked is True, summary
print('OK')
"

run_case "a malformed record name is integrity failure and blocks mutation" "${PRELUDE}
base, context = ready('corrupt')
os.mkdir(Path(base) / 'root' / A.ADMIN_RECORDS / 'CADM-00001')
refuses(lambda: A.allocate_cadm(context.root),
        Classification.ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE,
        'allocated over a malformed record name')
print('OK')
"

run_case "the scan ceiling counts every entry and blocks mutation when exceeded" "${PRELUDE}
base, context = ready('ceiling')
assert A.MAXIMUM_SCAN_ENTRIES == 10_000, A.MAXIMUM_SCAN_ENTRIES
assert A.MAXIMUM_SUMMARY_BYTES == 2 * 1024 * 1024, A.MAXIMUM_SUMMARY_BYTES
records = Path(base) / 'root' / A.ADMIN_RECORDS
for index in range(1, 10_002):
    (records / ('CADM-%06d' % index)).mkdir()
summary = A.inspect_admin_integrity(context.root, audit=A.Audit())
assert summary.classification is \\
    Classification.ADMINISTRATIVE_INTEGRITY_SCAN_LIMIT_EXCEEDED, summary
assert summary.blocked is True
refuses(lambda: A.allocate_cadm(context.root),
        Classification.ADMINISTRATIVE_INTEGRITY_SCAN_LIMIT_EXCEEDED,
        'allocated past the scan ceiling')
print('OK')
"

run_case "inspection is deterministically ordered with no pagination" "${PRELUDE}
import inspect
base, context = ready('ordering2')
for name in ('CADM-000003', 'CADM-000001', 'CADM-000002'):
    (Path(base) / 'root' / A.ADMIN_RECORDS / name).mkdir()
first = A.inspect_admin_integrity(context.root, audit=A.Audit())
second = A.inspect_admin_integrity(context.root, audit=A.Audit())
assert first.records == ('CADM-000001', 'CADM-000002', 'CADM-000003'), first.records
assert first.records == second.records
signature = inspect.signature(A.inspect_admin_integrity)
for forbidden in ('offset', 'page', 'cursor', 'limit', 'filter', 'since'):
    assert forbidden not in signature.parameters, forbidden
print('OK')
"

# --- the helper source -------------------------------------------------------

run_case "the admin helper source exists, is not installed, and has no NOPASSWD" "${PRELUDE}
helper = Path('provisioning/execution/kyri-exec-admin.py')
assert helper.exists(), 'the helper source is absent'
body = helper.read_text(encoding='utf-8')
assert 'NOPASSWD:' not in body, 'the helper source requests NOPASSWD'
assert 'ALL=' not in body, 'the helper source carries a sudoers directive'
for token in ('podman', 'subprocess', 'os.system'):
    assert token not in body, token
# Nothing is installed by this suite or by the source itself.
assert not Path('/usr/libexec/kyri-exec-admin').exists()
# /etc/sudoers.d is 0755 on the deployment host, so absence is observable
# there -- and that is the machine where the grant could exist at all. Some
# runners keep it 0750, where a stat raises EACCES rather than answering: the
# grant is not readable as absent, which is not the same as present, and
# treating an unreadable directory as a failure would report a distribution
# default as a policy breach.
import errno
try:
    installed = Path('/etc/sudoers.d/kyri-exec').exists()
except PermissionError as error:
    assert error.errno == errno.EACCES, error
else:
    assert not installed, 'the sudoers grant is installed'
print('OK')
"

run_case "no real Podman, sudo, privilege, or authentication was involved" "${PRELUDE}
import inspect
assert os.getuid() != 0
source = inspect.getsource(A)
for token in ('subprocess', 'podman', 'setuid', 'sudo', 'getpass'):
    assert token not in source, token
print('OK')
"

run_case "the admin suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-admin.sh'
assert name in validation, 'local validation does not run the admin suite'
assert name in ci, 'ci does not run the admin suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T17 administrative validation passed.\n'
else
  printf 'Capability execution T17 administrative validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
