#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T1.
#
# T1 is the execution-domain vocabulary and nothing else: immutable types and
# a closed classification set. There is no canonical JSON, no payload binding,
# no implementation-authority consumer, no CMUT, no capacity, no handoff, no
# profile construction, no protocol, no worker, no lifecycle, no collector, no
# quarantine, no cleanup, no administrative surface -- and above all NO
# EXECUTION. This suite asserts none of them.
#
# NOTHING HERE EXECUTES ANYTHING. T1 is pure: no I/O, no clock, no
# environment, no subprocess, no Podman, no filesystem mutation. The static
# backstop below proves the T1 production modules acquired none of those, and
# that is a security property rather than a matter of them not being written
# yet.
#
# The classification set is CLOSED by construction. Its purpose is to make an
# omission visible now rather than to let free-form reason strings accumulate
# later, so the suite asserts the exact specification vocabulary -- no more and
# no fewer.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXECUTION="tools/capability/execution"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

# The specification's §25 vocabulary, transcribed. This list is the test's own
# copy on purpose: if the specification changes, this file must be edited in
# the same reviewed increment, which is what keeps the vocabulary closed.
SPEC_CLASSIFICATIONS=(
  execution_capacity_exhausted
  execution_image_unavailable
  transition_failed_before_execution
  execution_container_name_collision
  execution_container_name_collision_unstable
  execution_state_lost
  execution_state_lost_during_mutation_freeze
  execution_identity_mismatch
  execution_profile_version_unsupported
  execution_profile_verifier_unavailable
  execution_start_outcome_unknown
  start_reconciled_running
  start_reconciled_terminal
  execution_lifecycle_integrity_failure
  execution_cleanup_incomplete
  execution_protocol_violation
  result_missing
  result_invalid
  output_tree_policy_violation
  quarantine_collection_incomplete
  quarantine_incomplete_integrity_failure
  quarantine_backing_store_mismatch
  quarantine_backing_store_config_integrity_failure
  implementation_authority_integrity_failure
  implementation_authority_scan_limit_exceeded
  implementation_authority_findings_truncated
  implementation_authority_capacity_exhausted
  administrative_record_integrity_failure
  administrative_record_unexpected_object
  administrative_integrity_findings_truncated
  administrative_integrity_scan_limit_exceeded
  inspection_audit_commit_failed
  mutation_journal_integrity_failure
)

# ===========================================================================
# Required files
# ===========================================================================

assert_file "${EXECUTION}/__init__.py"
assert_file "${EXECUTION}/types.py"

# ===========================================================================
# The T1 purity backstop
# ===========================================================================
# Runs before behaviour, and stays for the life of the adapter. T1 is the one
# increment that can be proven pure by inspection, so it is proven here rather
# than assumed later when the modules have grown.

# Scoped to T1's own modules. Each increment carries a backstop for the
# modules it adds, with the authority that increment actually accepted -- T3
# may read a descriptor, T1 may not, and one shared scan cannot express both.
# The coverage guard below makes sure narrowing the scope leaves nothing
# unscanned.
T1_MODULES=("__init__.py" "types.py")

assert_pure_types() {
  local report
  report="$(python3 - "${ROOT}" "${EXECUTION}" "${T1_MODULES[@]}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
package = root / sys.argv[2]
targets = sys.argv[3:]

# Every way T1 could stop being pure.
FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging",
}
# os and sys are not imported at all in T1: there is nothing to ask them.
FORBIDDEN_MODULES = {"os", "sys", "os.path"}
FORBIDDEN_CALLS = {
    "system", "popen", "exec", "eval", "compile", "open", "__import__",
    "getenv", "putenv", "chmod", "chown", "mkdir", "makedirs", "remove",
    "unlink", "rename", "rmdir", "write", "fsync", "now", "today", "time",
    "monotonic", "uuid1", "uuid4",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/")

findings = []
if not package.is_dir():
    print("package-absent")
    raise SystemExit(0)

for name in targets:
    path = package / name
    if not path.is_file():
        findings.append(f"{name}: absent")
        continue
    source = path.read_text(encoding="utf-8")
    rel = path.relative_to(root)
    try:
        tree = ast.parse(source)
    except SyntaxError as error:
        findings.append(f"{rel}: syntax error: {error}")
        continue

    # Text scan over code only. Comments are absent from the AST already;
    # docstrings are removed explicitly below, because ast.unparse would
    # otherwise put them back and prose about what T1 refuses to do would
    # trip a scan that is meant to be about code.
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
                top = alias.name.split(".")[0]
                if top in FORBIDDEN_IMPORTS or alias.name in FORBIDDEN_MODULES:
                    findings.append(f"{rel}: forbidden import: {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            name = node.module or ""
            top = name.split(".")[0]
            if top in FORBIDDEN_IMPORTS or name in FORBIDDEN_MODULES:
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
    pass "T1 production modules are pure: no I/O, clock, environment, or execution surface"
  else
    fail "T1 purity backstop found: ${report}"
  fi
}

assert_pure_types

# Narrowing the T1 scan must not let a module slip through unscanned. Every
# module in the package belongs to some increment and is covered by that
# increment's backstop; a new one appearing here without a backstop fails
# loudly rather than silently gaining whatever authority it likes.
assert_backstop_coverage() {
  local covered=("__init__.py" "types.py" "canonical_json.py" "payload.py"
                 "implementation_authority.py" "backing_store.py"
                 "mutation.py" "state.py" "capacity.py"
                 "package_contract.py" "handoff.py" "profile.py"
                 "protocol.py" "worker.py" "lifecycle.py" "collector.py"
                 "quarantine.py")
  local uncovered=()
  local path name known found
  for path in "${ROOT}/${EXECUTION}"/*.py; do
    [[ -f "${path}" ]] || continue
    name="${path##*/}"
    found=0
    for known in "${covered[@]}"; do
      if [[ "${name}" == "${known}" ]]; then found=1; break; fi
    done
    if [[ "${found}" -eq 0 ]]; then uncovered+=("${name}"); fi
  done

  if [[ "${#uncovered[@]}" -eq 0 ]]; then
    pass "every execution module is covered by an increment purity backstop"
  else
    fail "modules with no purity backstop: ${uncovered[*]}"
  fi
}

assert_backstop_coverage

# ===========================================================================
# Behaviour
# ===========================================================================

PROFILE_HELPER="
import dataclasses
from tools.capability.execution.types import Mount
PROFILE_FIELDS = dict(
    cinv='CINV-000042', image_digest='sha256:' + 'a' * 64, network='none',
    memory_bytes=268435456, memory_swap_bytes=268435456, cpus='0.5',
    pids_limit=64, timeout_seconds=30, grace_seconds=2,
    read_only_rootfs=True, no_new_privileges=True, cap_drop_all=True,
    tmpfs_bytes=16777216, profile_schema_version=1, cimp='CIMP-000001',
    adapter_identity='python-podman-v1', payload_schema_version=1,
    execution_uid=1000, execution_gid=1000, hostname='trackb',
    cpu_quota_us=50000, cpu_period_us=100000, tmpfs_mode=0o1777,
    tmpfs_options=('noexec', 'nosuid', 'nodev'),
    dropped_capabilities=('ALL',),
    mounts=(Mount(destination='/kyri/package', read_only=True, source_kind='bind'),),
    devices=(), sockets=(), privileged=False, host_network=False,
    host_pid=False, gpu=False)
FINGERPRINT_FIELDS = dict(
    cinv='CINV-000042', profile_digest='b' * 64,
    image_digest='sha256:' + 'a' * 64, cimp='CIMP-000001',
    adapter_identity='python-podman-v1', profile_schema_version=1,
    execution_uid=999, execution_gid=987)
"

run_python_case() {
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

# --- the closed classification vocabulary ---------------------------------

expected_list="$(printf '%s\n' "${SPEC_CLASSIFICATIONS[@]}" | sort)"
expected_count="${#SPEC_CLASSIFICATIONS[@]}"

run_python_case "classification vocabulary is exactly the specification's ${expected_count} entries" "
from tools.capability.execution.types import Classification
expected = sorted('''${expected_list}'''.split())
actual = sorted(c.value for c in Classification)
missing = [e for e in expected if e not in actual]
extra = [a for a in actual if a not in expected]
assert not missing, f'missing from Classification: {missing}'
assert not extra, f'not in the specification: {extra}'
assert len(actual) == ${expected_count}, f'expected ${expected_count}, got {len(actual)}'
print('OK')
"

run_python_case "each classification appears exactly once" "
from tools.capability.execution.types import Classification
values = [c.value for c in Classification]
assert len(values) == len(set(values)), 'duplicate classification value'
print('OK')
"

run_python_case "Classification.of resolves a known reason" "
from tools.capability.execution.types import Classification
assert Classification.of('result_missing') is Classification.RESULT_MISSING
print('OK')
"

run_python_case "Classification.of refuses an unknown reason rather than inventing one" "
from tools.capability.execution.types import Classification, UnknownClassification
try:
    Classification.of('execution_looks_fine_to_me')
except UnknownClassification as error:
    assert 'execution_looks_fine_to_me' in str(error)
    print('OK')
else:
    raise AssertionError('an unknown reason string was accepted')
"

# A stray class attribute is not the risk; a stray *member* is. Enum permits
# the former and it changes nothing that can be reported, so this asserts the
# property that matters -- the vocabulary cannot gain a member at runtime --
# rather than the mechanism by which Python happens to enforce it.
run_python_case "the vocabulary cannot gain a member at runtime" "
from tools.capability.execution.types import Classification, UnknownClassification
before = [c.value for c in Classification]
try:
    Classification.INVENTED = 'invented'
except AttributeError:
    pass
after = [c.value for c in Classification]
assert before == after, 'the member set changed'
try:
    Classification.of('invented')
except UnknownClassification:
    pass
else:
    raise AssertionError('an attached attribute became a usable classification')
print('OK')
"

run_python_case "an existing classification cannot be reassigned" "
from tools.capability.execution.types import Classification
try:
    Classification.RESULT_MISSING = 'something_else'
except AttributeError:
    print('OK')
else:
    raise AssertionError('an existing classification was reassigned')
"

# --- immutability ----------------------------------------------------------

run_python_case "LifecycleState is a closed ordered vocabulary" "
from tools.capability.execution.types import LifecycleState
expected = ['reserved', 'launch_authorized', 'created', 'container_verified',
            'start_authorized', 'started', 'running', 'terminal', 'classified',
            'collected', 'cleaned', 'released']
assert [s.value for s in LifecycleState] == expected, [s.value for s in LifecycleState]
print('OK')
"

run_python_case "ExecutionProfile is frozen" "${PROFILE_HELPER}
from tools.capability.execution.types import ExecutionProfile
p = ExecutionProfile(**PROFILE_FIELDS)
try:
    p.pids_limit = 4096
except Exception as error:
    assert type(error).__name__ in ('FrozenInstanceError', 'AttributeError'), type(error)
    print('OK')
else:
    raise AssertionError('ExecutionProfile was mutated')
"

run_python_case "ExecutionProfile rejects an unknown field" "${PROFILE_HELPER}
from tools.capability.execution.types import ExecutionProfile
try:
    ExecutionProfile(**PROFILE_FIELDS, unknown_control=True)
except TypeError as error:
    assert 'unknown_control' in str(error), str(error)
    print('OK')
else:
    raise AssertionError('an unknown profile field was accepted')
"

run_python_case "ExecutionFingerprint is frozen and compares by value" "${PROFILE_HELPER}
from tools.capability.execution.types import ExecutionFingerprint
kwargs = dict(FINGERPRINT_FIELDS)
a = ExecutionFingerprint(**kwargs)
b = ExecutionFingerprint(**kwargs)
assert a == b and hash(a) == hash(b), 'value equality failed'
try:
    a.execution_uid = 0
except Exception:
    print('OK')
else:
    raise AssertionError('ExecutionFingerprint was mutated')
"

run_python_case "SlotReservation is frozen and carries no clock-derived field" "
from tools.capability.execution.types import SlotReservation
import dataclasses
r = SlotReservation(cinv='CINV-000042', slot_index=0)
names = {f.name for f in dataclasses.fields(r)}
assert names == {'cinv', 'slot_index'}, names
try:
    r.slot_index = 1
except Exception:
    print('OK')
else:
    raise AssertionError('SlotReservation was mutated')
"

run_python_case "deterministic equality: identical values are equal across construction" "${PROFILE_HELPER}
from tools.capability.execution.types import ExecutionProfile
def make():
    return ExecutionProfile(**PROFILE_FIELDS)
assert make() == make()
assert hash(make()) == hash(make())
print('OK')
"

# ===========================================================================
# What T1 is not
# ===========================================================================

run_python_case "T1 exposes no module-level function -- it is types only" "
import types as pytypes
import tools.capability.execution.types as t
functions = [n for n, v in vars(t).items()
             if isinstance(v, pytypes.FunctionType) and not n.startswith('_')]
assert not functions, f'T1 defines module-level functions: {functions}'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T1 validation passed.\n'
else
  printf 'Capability execution T1 validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
