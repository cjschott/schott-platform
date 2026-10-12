#!/usr/bin/env bash
set -Eeuo pipefail

# The privileged helper must move as one thing.
#
# STATIC AND UNPRIVILEGED. Nothing here installs, executes, or reads a
# privileged path. It compares repository source against itself and, where the
# host has the runtime installed, reports what is there.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AI found the installed helper carrying half of one commit. The
# verification surface from 16f285e was installed and byte-exact; the
# transition modules from the same commit were not. The consequence was live:
#
#   /usr/libexec/kyri-exec-verify builds a policy naming the verification
#   worker and explicitly refuses one naming the production worker -- and then
#   calls a perform_transition that ignores policy.worker_script and execs the
#   production worker anyway.
#
# Its own guard was defeated by the older module underneath it. Nothing was
# tampered with; the commit simply went in in halves.
#
# So the property pinned here is not "the helper is at some version". It is
# that the pieces are COHERENT: the exec site and the argv builder must agree
# about whether the target comes from the policy, because a helper where one
# half was updated and the other was not is exactly the failure above.

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

PRELUDE="
import ast, sys
from pathlib import Path

TRANSITION = Path('provisioning/execution/kyri-exec-transition.py')
ACTION = Path('provisioning/execution/kyri-exec-transition-action.py')
VERIFY = Path('provisioning/execution/kyri-exec-verify.py')
ENTRYPOINT = Path('provisioning/execution/kyri-exec-verify-entrypoint.py')

def tree(path):
    return ast.parse(path.read_text(encoding='utf-8'))

def function(path, name):
    for node in ast.walk(tree(path)):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f'{path}: no function {name}')
"

# --- the coherence property ------------------------------------------------------

run_case "the argv builder requires the target from the policy" "${PRELUDE}
builder = function(TRANSITION, 'worker_argv')
names = [a.arg for a in builder.args.kwonlyargs]
assert 'worker_script' in names, names
# Required, with no default: a default would silently restore the divergence
# by letting the exec site fall back to this module's own constant.
defaults = builder.args.kw_defaults[names.index('worker_script')]
assert defaults is None, 'worker_script has a default'
print('OK')
"

run_case "the exec site passes the policy's target, not a module constant" "${PRELUDE}
site = function(ACTION, 'perform_transition')
calls = [n for n in ast.walk(site)
         if isinstance(n, ast.Call)
         and getattr(n.func, 'attr', None) == 'worker_argv']
assert len(calls) == 1, calls
keywords = {k.arg for k in calls[0].keywords}
assert 'worker_script' in keywords, \\
    'the exec site does not pass the policy target -- this is the split defect'
# ...and it comes from the policy rather than from the module.
argument = [k.value for k in calls[0].keywords if k.arg == 'worker_script'][0]
assert isinstance(argument, ast.Attribute) and argument.attr == 'worker_script', \\
    ast.dump(argument)
print('OK')
"

run_case "a mixed helper is detectable from the two halves alone" "${PRELUDE}
# The exact shape of the installed defect: an argv builder that requires the
# keyword paired with an exec site that does not pass it, or the reverse.
builder = function(TRANSITION, 'worker_argv')
requires = 'worker_script' in [a.arg for a in builder.args.kwonlyargs]
site = function(ACTION, 'perform_transition')
call = [n for n in ast.walk(site)
        if isinstance(n, ast.Call)
        and getattr(n.func, 'attr', None) == 'worker_argv'][0]
supplies = 'worker_script' in {k.arg for k in call.keywords}
assert requires == supplies, (
    'the helper halves disagree about the worker target: '
    f'builder requires={requires} exec site supplies={supplies}')
print('OK')
"

run_case "the verification entrypoint's guard is not self-sufficient" "${PRELUDE}
# The entrypoint refuses a policy naming the production worker. That guard is
# necessary and was never sufficient: with the old action module beneath it the
# refusal passed and the production worker ran anyway. Recorded so nobody reads
# the guard as protection on its own.
source = ENTRYPOINT.read_text(encoding='utf-8')
assert 'PRODUCTION_WORKER_SCRIPT' in source, source[:200]
assert 'worker_script' in source
# The verification policy names its own worker, and it is not the production one.
verify = VERIFY.read_text(encoding='utf-8')
assert '/usr/libexec/kyri-exec-verify-worker.py' in verify, verify[:200]
print('OK')
"

# --- the ceremony must be atomic ---------------------------------------------------

run_case "the ceremony's pieces are named together, not one at a time" "${PRELUDE}
# The objects that move as one. A ceremony that installs a subset reproduces
# the split, which is how the live defect arose in the first place.
#
# G11-AS added the reconciliation surface. It is part of THIS set rather than a
# ceremony of its own because it shares the policy module, the action module and
# the credential drop with the launch path -- a host carrying a reconcile
# entrypoint over an older action module would be the 16f285e defect again,
# with a different pair of halves.
pieces = [TRANSITION, ACTION, VERIFY, ENTRYPOINT,
          Path('provisioning/execution/kyri-exec-verify-worker.py'),
          Path('provisioning/execution/kyri-exec-transition-entrypoint.py'),
          Path('provisioning/execution/kyri-exec-reconcile.py'),
          Path('provisioning/execution/kyri-exec-reconcile-entrypoint.py'),
          Path('provisioning/execution/kyri-exec-reconcile-worker.py'),
          Path('provisioning/execution/kyri-exec-podman.py')]
for piece in pieces:
    assert piece.is_file(), f'{piece} is absent from the ceremony set'
print('OK')
"

run_case "a reconcile entrypoint over an older action module is detectable" "${PRELUDE}
# The same coherence question the launch halves get, asked of the pair G11-AS
# introduced. The entrypoint calls two things the action module must provide;
# an action module predating this checkpoint has neither, and the mismatch is
# visible from the two files alone.
entry = Path('provisioning/execution/kyri-exec-reconcile-entrypoint.py')
tree = ast.parse(entry.read_text(encoding='utf-8'))
required = {getattr(n.func, 'attr', None) for n in ast.walk(tree)
            if isinstance(n, ast.Call)}
provided = {n.name for n in ast.walk(ast.parse(ACTION.read_text(encoding='utf-8')))
            if isinstance(n, ast.FunctionDef)}
for name in ('execution_identity', 'perform_reconciliation'):
    assert name in required, (name, 'the entrypoint stopped calling it')
    assert name in provided, (name, 'the action module cannot provide it')
# And the policy the entrypoint asks for must exist in the policy module.
policy_names = {n.name for n in
                ast.walk(ast.parse(TRANSITION.read_text(encoding='utf-8')))
                if isinstance(n, ast.FunctionDef)}
assert 'reconciliation_policy_for' in policy_names, policy_names
print('OK')
"

run_case "both privileged paths drop through one implementation" "${PRELUDE}
# Two credential drops would be two things to keep correct and one thing to get
# wrong -- the argument kyri_exec_verify already makes about the policy. Each
# transition calls the shared drop; neither performs its own.
tree = ast.parse(ACTION.read_text(encoding='utf-8'))
functions = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
assert 'drop_privilege' in functions, 'the shared credential drop is gone'
inside = {n.attr for n in ast.walk(functions['drop_privilege'])
          if isinstance(n, ast.Attribute)}
assert {'setgroups', 'setgid', 'setuid', 'set_no_new_privs'} <= inside, inside
for name in ('perform_transition', 'perform_reconciliation'):
    body = functions[name]
    called = {getattr(n.func, 'id', None) for n in ast.walk(body)
              if isinstance(n, ast.Call)}
    assert 'drop_privilege' in called, (name, 'it does not use the shared drop')
    own = {n.attr for n in ast.walk(body) if isinstance(n, ast.Attribute)}
    assert not ({'setgroups', 'setgid', 'setuid'} & own), (name, own)
print('OK')
"

run_case "the ceremony's identity expectation is one path and one schema" "${PRELUDE}
# The helper and the runtime read the same authority. The helper cannot import
# the runtime package, so the contract is stated twice and held together here:
# a ceremony that installed a helper expecting one schema onto a runtime
# expecting another would be a mixed state nothing else would notice.
import importlib.util
spec = importlib.util.spec_from_file_location('kyri_exec_transition', str(TRANSITION))
policy = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_transition'] = policy
spec.loader.exec_module(policy)
sys.path.insert(0, '.')
from tools.capability.execution import identity as runtime
assert policy.EXECUTION_AUTHORITY_PATH == runtime.EXECUTION_AUTHORITY_PATH
assert policy.EXECUTION_AUTHORITY_SCHEMA == runtime.EXECUTION_AUTHORITY_SCHEMA
assert policy.SUPPORTED_EXECUTION_SCHEMA_VERSION \\
    == runtime.SUPPORTED_EXECUTION_SCHEMA_VERSION
# And the authority file is NOT one of the ceremony's objects. It is deployment
# authority with its own ceremony, and a helper that installed it would be
# choosing the deployment's identity rather than reading it.
for piece in Path('provisioning/execution').glob('*'):
    assert 'execution-identity.json' != piece.name, piece
print('OK')
"

# --- what is actually installed, where that is observable ---------------------------

INSTALLED_LIB="/usr/lib/kyri/python"
if [[ -d "${INSTALLED_LIB}" ]]; then
  report="$(cd "${ROOT}" && python3 - <<'PY'
import hashlib, pathlib
lib = pathlib.Path('/usr/lib/kyri/python')
repo = pathlib.Path('provisioning/execution')
pairs = [('kyri_exec_transition.py', 'kyri-exec-transition.py'),
         ('kyri_exec_transition_action.py', 'kyri-exec-transition-action.py'),
         ('kyri_exec_verify.py', 'kyri-exec-verify.py'),
         ('kyri_exec_podman.py', 'kyri-exec-podman.py'),
         ('kyri_exec_reconcile.py', 'kyri-exec-reconcile.py')]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
lines = []
for installed, source in pairs:
    target = lib / installed
    if not target.is_file():
        lines.append(f"{installed}: absent")
        continue
    lines.append(f"{installed}: "
                 + ("current" if digest(target) == digest(repo / source)
                    else "BEHIND"))
print(" | ".join(lines))
PY
)"
  printf 'NOTE installed helper state: %s\n' "${report}"
  # Reported, never enforced: this suite must pass on a machine with no
  # installed runtime, and the installed state is a deployment fact rather
  # than a property of the source under review.
  pass "the installed helper state is reported"
else
  pass "no installed runtime on this machine; source coherence only"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution helper coherence validation passed.\n'
else
  printf 'Capability execution helper coherence validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
