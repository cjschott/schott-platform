#!/usr/bin/env bash
set -Eeuo pipefail

# Validation for the ENG-0005 per-invocation output containment, G4 increment.
#
# UNPRIVILEGED THROUGHOUT. Nothing here sets a quota, opens a block device,
# calls quotactl, runs xfs_quota, or requires XFS. The privileged operation is
# source only and installed by nothing; gates G2 and G3 stay closed.
#
# THE PROJECT IDENTITY IS DERIVED, NEVER ALLOCATED. A CINV is already unique
# and never reused, so a second allocator would be a second thing to keep
# monotonic and fail closed on. Project 0 is never produced, because 0 is the
# filesystem default and assigning a tree to it would mean unlimited.
#
# THE PRIVILEGED SIDE TAKES NO PARAMETER IT COULD BE AIMED WITH. No path, no
# project ID, no limit -- one CINV, validated, and a compiled-in root reached
# descriptor-relative.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §34
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md

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
# The quota backstop
# ===========================================================================
# The mechanism was chosen to keep the privileged surface to one ioctl. This is
# what stops it growing back into an external-command runner.

assert_quota_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
policy = root / "tools/capability/execution/quota.py"
privileged = root / "provisioning/execution/kyri-exec-quota.py"

missing = [str(p.relative_to(root)) for p in (policy, privileged) if not p.exists()]
if missing:
    print("absent: " + ", ".join(missing))
    raise SystemExit(0)


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

# The policy module is pure: it derives numbers and touches nothing.
# Typing and __future__ carry no capability; a relative import stays inside
# the package. Anything else would be this module acquiring a reach it has no
# use for.
PURE_IMPORTS = {"__future__", "typing"}
policy_tree = ast.parse(policy.read_text(encoding="utf-8"))
for node in ast.walk(policy_tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            findings.append(f"quota.py imports {alias.name}")
    elif isinstance(node, ast.ImportFrom) and node.level == 0:
        if (node.module or "") not in PURE_IMPORTS:
            findings.append(f"quota.py imports from {node.module}")
    elif isinstance(node, ast.Call):
        attr = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
        if attr in {"ioctl", "open", "system", "popen", "run"}:
            findings.append(f"quota.py calls {attr}")

# The privileged source may reach exactly one kernel interface.
source = privileged.read_text(encoding="utf-8")
code = strip_documentation(ast.parse(source))
FORBIDDEN_IMPORTS = {"subprocess", "ctypes", "shutil", "socket", "shlex",
                     "multiprocessing", "importlib", "runpy", "pty", "tempfile"}
FORBIDDEN_CALLS = {"system", "popen", "run", "execv", "execvp", "fork", "spawn",
                   "quotactl", "setuid", "setgid", "chmod", "chown", "mkdir",
                   "unlink", "rmdir", "rename", "write", "getenv"}
for node in ast.walk(ast.parse(source)):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"helper imports {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        module = node.module or ""
        if module.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"helper imports from {module}")
    elif isinstance(node, ast.Call):
        attr = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"helper calls {attr}")
    elif isinstance(node, ast.Attribute) and node.attr in ("environ", "argv"):
        if not (isinstance(node.value, ast.Name) and node.value.id == "sys"):
            findings.append(f"helper reads {node.attr}")

for token in ("xfs_quota", "quotactl", "/bin/sh", "shell=True", "sudo",
              "os.system", "Popen"):
    if token in code:
        findings.append(f"helper carries {token}")

# It must not import the runtime package: root reading from a tree the
# execution identity can influence is the wrong direction entirely.
if "tools.capability" in code:
    findings.append("helper imports the runtime package")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "quota authority is one ioctl: no xfs_quota, quotactl, ctypes, or shell"
  else
    fail "quota backstop found: ${report}"
  fi
}

assert_quota_authority

# ===========================================================================
# Behaviour
# ===========================================================================

PRELUDE="
import importlib.util
from pathlib import Path

from tools.capability.execution import quota as Q
from tools.capability.execution.state import InvalidCinv

_spec = importlib.util.spec_from_file_location(
    'kyri_exec_quota', 'provisioning/execution/kyri-exec-quota.py')
H = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(H)
"

run_case "the project ID is derived from the CINV and never allocated" "${PRELUDE}
assert Q.project_id('CINV-000001') == 1000001
assert Q.project_id('CINV-042731') == 1042731
assert Q.project_id('CINV-999999') == 1999999
# Derivation is a pure function: the same identity always gives the same ID,
# and two identities never collide.
seen = {Q.project_id('CINV-%06d' % n) for n in range(1, 500)}
assert len(seen) == 499, len(seen)
assert Q.project_id('CINV-000001') == Q.project_id('CINV-000001')
print('OK')
"

run_case "project zero is never produced" "${PRELUDE}
assert Q.PROJECT_ID_BASE == 1_000_000
assert Q.PROJECT_ID_MINIMUM == 1_000_001
# CINV-000000 is not a reachable identity, and the range refuses it anyway.
try:
    Q.project_id('CINV-000000')
except Q.QuotaPolicyError:
    pass
else:
    raise AssertionError('CINV-000000 derived a project ID')
print('OK')
"

run_case "the derivation refuses anything that is not a CINV" "${PRELUDE}
for bad in ('CINV-00001', 'CINV-0000001', 'cinv-000001', 'CINV-00000a',
            '../000001', '1000001', '', None, 1, True):
    try:
        Q.project_id(bad)
    except (InvalidCinv, Q.QuotaPolicyError):
        continue
    raise AssertionError('accepted ' + repr(bad))
print('OK')
"

run_case "the inverse recovers the CINV without a lookup table" "${PRELUDE}
for cinv in ('CINV-000001', 'CINV-042731', 'CINV-999999'):
    assert Q.cinv_for(Q.project_id(cinv)) == cinv, cinv
for bad in (0, 1_000_000, 2_000_000, -1, 'x', True, None):
    try:
        Q.cinv_for(bad)
    except Q.QuotaPolicyError:
        continue
    raise AssertionError('accepted project ' + repr(bad))
print('OK')
"

run_case "the limits are the accepted write-time envelope, twice §11" "${PRELUDE}
from tools.capability.execution import collector as C
assert Q.BLOCK_HARD_BYTES == 32 * 1024 * 1024, Q.BLOCK_HARD_BYTES
assert Q.INODE_HARD == 512, Q.INODE_HARD
assert Q.BLOCK_HARD_BYTES == 2 * C.OUTPUT_MAXIMUM_TOTAL_BYTES
assert Q.INODE_HARD == 2 * C.OUTPUT_TREE_MAX_ENTRIES
print('OK')
"

run_case "the quota covers the output leaf only, never the whole handoff" "${PRELUDE}
from tools.capability.execution.worker import OUTPUT_NAME
assert Q.QUOTA_SUBTREE == OUTPUT_NAME == 'out', (Q.QUOTA_SUBTREE, OUTPUT_NAME)
assert H.QUOTA_SUBTREE == Q.QUOTA_SUBTREE, 'the two sides disagree on the subtree'
print('OK')
"

run_case "both sides derive identically, without one importing the other" "${PRELUDE}
for cinv in ('CINV-000001', 'CINV-042731', 'CINV-999999'):
    assert H.project_id(cinv) == Q.project_id(cinv), cinv
assert H.PROJECT_ID_BASE == Q.PROJECT_ID_BASE
source = Path('provisioning/execution/kyri-exec-quota.py').read_text(encoding='utf-8')
assert 'from tools' not in source and 'import tools' not in source
print('OK')
"

run_case "the privileged side accepts one CINV and nothing else" "${PRELUDE}
import inspect
assert list(inspect.signature(H.main).parameters) == ['argv'], \\
    inspect.signature(H.main)
for argv in ([], ['x'], ['x', 'CINV-000001', 'extra'],
             ['x', '/data/kyri/capability-handoff/CINV-000001/out'],
             ['x', 'CINV-000001', '--bhard=1g']):
    try:
        H.main(argv)
    except SystemExit:
        continue
    except OSError:
        # A valid single argument may reach the filesystem and fail there;
        # these argument shapes must not get that far.
        raise AssertionError('accepted argv ' + repr(argv))
    raise AssertionError('accepted argv ' + repr(argv))
print('OK')
"

run_case "no path, project ID, or limit can be supplied by a caller" "${PRELUDE}
import ast, inspect
# Instructions only: the docstring explains that limits are provisioned by
# xfs_quota elsewhere, and scanning prose would fail the file for saying so.
tree = ast.parse(inspect.getsource(H))
for node in ast.walk(tree):
    body = getattr(node, 'body', None)
    if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
            and body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        del body[0]
source = ast.unparse(tree)
# The root is compiled in and the subtree is a constant.
assert H.HANDOFF_ROOT == '/data/kyri/capability-handoff', H.HANDOFF_ROOT
establish = [n for n in ast.walk(tree)
             if isinstance(n, ast.FunctionDef) and n.name == 'establish']
assert len(establish) == 1, establish
taken = [a.arg for a in establish[0].args.args]
assert taken == ['descriptor', 'project'], taken
assert not establish[0].args.kwonlyargs and not establish[0].args.defaults, \\
    'the privileged operation takes an optional parameter'
for taken in ('bhard', 'ihard', 'limit=', 'path=', 'project=1'):
    assert taken not in source, taken
print('OK')
"

run_case "the ioctl is the documented FSSETXATTR interface, read-modify-write" "${PRELUDE}
import struct
assert H.FS_IOC_FSSETXATTR == 0x401C5820, hex(H.FS_IOC_FSSETXATTR)
assert H.FS_IOC_FSGETXATTR == 0x801C581F, hex(H.FS_IOC_FSGETXATTR)
assert H.FS_XFLAG_PROJINHERIT == 0x00000200
# struct fsxattr is 28 bytes; a wrong layout would corrupt neighbouring fields.
assert struct.calcsize(H.FSXATTR_FORMAT) == 28, struct.calcsize(H.FSXATTR_FORMAT)
packed = struct.pack(H.FSXATTR_FORMAT, 0x200, 1, 2, 1000001, 3, b'\\0' * 8)
xflags, _, _, projid, _, _ = struct.unpack(H.FSXATTR_FORMAT, packed)
assert projid == 1000001 and xflags & H.FS_XFLAG_PROJINHERIT
print('OK')
"

run_case "the decision refuses an existing foreign project assignment" "${PRELUDE}
# Unassigned or already ours is fine; anybody else's is not, because taking it
# over would move their accounted usage onto this invocation.
assert H.decide(0, 0, 1000042) == H.FS_XFLAG_PROJINHERIT
assert H.decide(0, 1000042, 1000042) == H.FS_XFLAG_PROJINHERIT
for foreign in (7, 1, 1000041, 999999):
    try:
        H.decide(0, foreign, 1000042)
    except H.QuotaRefused:
        continue
    raise AssertionError('accepted an existing project ' + str(foreign))
print('OK')
"

run_case "the decision preserves every unrelated inode flag" "${PRELUDE}
# 0x1 is FS_XFLAG_REALTIME, 0x8 is FS_XFLAG_APPEND: neither is ours to clear.
existing = 0x1 | 0x8
updated = H.decide(existing, 0, 1000042)
assert updated & existing == existing, hex(updated)
assert updated & H.FS_XFLAG_PROJINHERIT
print('OK')
"

run_case "a successful setter call is not accepted as evidence" "${PRELUDE}
project = 1000042
# The readback must show exactly this project.
H.confirm(0, H.FS_XFLAG_PROJINHERIT, project, project)
for observed_projid in (0, 7, project + 1, project - 1):
    try:
        H.confirm(0, H.FS_XFLAG_PROJINHERIT, observed_projid, project)
    except H.QuotaRefused:
        continue
    raise AssertionError('accepted a readback of project ' + str(observed_projid))
# Inheritance must actually be set.
try:
    H.confirm(0, 0, project, project)
except H.QuotaRefused:
    pass
else:
    raise AssertionError('accepted a readback without PROJINHERIT')
# And nothing else may have changed underneath.
try:
    H.confirm(0x1, H.FS_XFLAG_PROJINHERIT, project, project)
except H.QuotaRefused:
    pass
else:
    raise AssertionError('accepted a readback that cleared an unrelated flag')
try:
    H.confirm(0, H.FS_XFLAG_PROJINHERIT | 0x8, project, project)
except H.QuotaRefused:
    pass
else:
    raise AssertionError('accepted a readback that added an unrelated flag')
print('OK')
"

run_case "the transition cannot reach execve without an established project" "${PRELUDE}
import ast
source = Path('provisioning/execution/kyri-exec-transition-action.py').read_text(
    encoding='utf-8')
tree = ast.parse(source)
transition = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef) and n.name == 'perform_transition']
assert len(transition) == 1, transition
taken = [a.arg for a in transition[0].args.args] + \\
        [a.arg for a in transition[0].args.kwonlyargs]
assert 'quota' in taken, taken
# Mandatory: a default would be a path through the transition with no project.
assert all(d is None for d in transition[0].args.kw_defaults), \\
    'the quota seam carries a default'
# The quota call precedes every credential-spending call in source order.
lines = {}
for node in ast.walk(transition[0]):
    if isinstance(node, ast.Attribute) and node.attr in (
            'apply', 'setgroups', 'setgid', 'setuid', 'execve',
            'close_extra_descriptors'):
        lines.setdefault(node.attr, node.lineno)
for later in ('close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
              'execve'):
    assert lines['apply'] < lines[later], (later, lines)
print('OK')
"

run_case "nothing is installed and no quota was established" "${PRELUDE}
import os
assert os.getuid() != 0, 'this suite must not run privileged'
for path in ('/usr/libexec/kyri-exec-quota', '/etc/sudoers.d/kyri-exec',
             '/run/kyri', '/data/kyri/capability-handoff'):
    assert not Path(path).exists(), path + ' exists'
print('OK')
"

run_case "the quota suite runs in local validation and in CI" "${PRELUDE}
validation = Path('tools/dev/run-validation.sh').read_text(encoding='utf-8')
ci = Path('.github/workflows/ci.yml').read_text(encoding='utf-8')
name = 'tests/test-capability-execution-quota.sh'
assert name in validation, 'local validation does not run the quota suite'
assert name in ci, 'ci does not run the quota suite'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution output-quota validation passed.\n'
else
  printf 'Capability execution output-quota validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
