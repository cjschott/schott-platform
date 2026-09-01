#!/usr/bin/env bash
set -Eeuo pipefail

# Which execution identities are deployment-bound, and which are still numbers
# compiled into the source.
#
# STATIC AND UNPRIVILEGED. No Podman, no container, no privileged path, no
# production read beyond source.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AH removed `COORDINATOR_UID = 1000` from the privileged helper and gave
# the coordinator a deployment identity read from root-owned authority. Its
# reasoning is in the source it left behind:
#
#   "A compiled-in coordinator uid used to live at this line. It was never
#    derived and never provisioned: it was true of `schai` because `cschott`
#    happens to be uid 1000, and three suites passed on that coincidence. A
#    helper meant to be deployment-independent cannot carry one deployment's
#    account number as if it were a property of Kyri."
#
# That reasoning applies word for word to the WORKER identity, and was never
# applied to it. `kyri-capability`, uid 999, gid 987 are still compiled-in
# universals, and `/run/user/999` is embedded in path strings so even the
# rootless runtime directory is assumed.
#
# G11-AR was to build a privileged reconciliation entrypoint, which must drop
# to the worker identity -- and could only have done so by reading those
# constants, reproducing exactly the defect G11-AH removed. So it stopped.
#
# WHAT THIS SUITE DOES, AND WHAT IT DELIBERATELY DOES NOT
# =======================================================
# It does not assert the gap is acceptable, and it does not assert the fix.
# It BOUNDS the gap: the worker identity is stated in exactly the places named
# below, so an eighth cannot appear unnoticed while the authority is missing, and
# the list is the migration checklist for whoever closes it.
#
# The coordinator half is asserted positively, because that half is correct and
# must stay correct.

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
sys.path.insert(0, '.')
from pathlib import Path

TRANSITION = Path('provisioning/execution/kyri-exec-transition.py')
WORKER_LIB = Path('tools/capability/execution/worker.py')
BACKEND = Path('provisioning/execution/kyri-exec-podman.py')
RECONCILE = Path('provisioning/execution/kyri-exec-reconcile.py')

def literals(path):
    '''Every string and integer constant in the CODE, docstrings removed.'''
    tree = ast.parse(path.read_text(encoding='utf-8'))
    for node in ast.walk(tree):
        body = getattr(node, 'body', None)
        if (isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef))
                and body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            del body[0]
    return [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)]
"

# --- the half that is correct ------------------------------------------------------

run_case "the coordinator identity is deployment-bound, with no fallback" "${PRELUDE}
import importlib.util
spec = importlib.util.spec_from_file_location('kyri_exec_transition', str(TRANSITION))
module = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_transition'] = module
spec.loader.exec_module(module)

# Read from root-owned authority, and there is deliberately nothing to fall
# back to if it is absent.
assert module.COORDINATOR_AUTHORITY_PATH == '/etc/kyri/coordinator-identity.json'
assert not hasattr(module, 'COORDINATOR_UID'), \\
    'a compiled-in coordinator uid has returned'
assert module.COORDINATOR_AUTHORITY_SCHEMA == (
    'coordinator_account', 'coordinator_uid', 'schema_version')
print('OK')
"

run_case "no deployment authority governs the worker identity" "${PRELUDE}
import importlib.util
spec = importlib.util.spec_from_file_location('kyri_exec_transition', str(TRANSITION))
module = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_transition'] = module
spec.loader.exec_module(module)

# The gap, stated as a fact rather than an opinion. The coordinator authority
# is a closed three-field schema and none of those fields names the execution
# identity, so there is nowhere in accepted authority for it to be provisioned.
assert 'worker_uid' not in module.COORDINATOR_AUTHORITY_SCHEMA
assert 'worker_account' not in module.COORDINATOR_AUTHORITY_SCHEMA
assert 'execution_uid' not in module.COORDINATOR_AUTHORITY_SCHEMA
# The only other root-owned deployment record is the backing store, which
# anchors a filesystem and carries no identity at all.
# Parsed keys, not a substring scan: 'uid' is inside 'filesystem_uuid' and a
# text search reads the anchor's own field as an identity.
import json
backing = json.loads(
    Path('provisioning/execution/backing-store.json.example').read_text())
assert set(backing) == {'filesystem_type', 'filesystem_uuid', 'mount_point'}, backing
for field in backing:
    assert field not in ('uid', 'gid', 'account', 'user', 'execution_uid'), field
print('OK')
"

# --- the gap, bounded --------------------------------------------------------------

run_case "the worker identity is compiled in, in exactly the known places" "${PRELUDE}
# Not an endorsement. This is the migration checklist: every site that must
# change when the execution identity becomes deployment-bound, and a guard so an
# eighth cannot appear unnoticed while it is not.
#
# The numbers are read from source rather than restated here, so this suite
# does not itself become a seventh place that states them.
import importlib.util
spec = importlib.util.spec_from_file_location('kyri_exec_transition', str(TRANSITION))
transition = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_transition'] = transition
spec.loader.exec_module(transition)
from tools.capability.execution import worker as W

uid, gid = transition.WORKER_UID, transition.WORKER_GID
# Duplicated deliberately across the privilege boundary -- the helper installs
# beneath a different root and cannot import the library -- and held together
# here, the same discipline PROFILE_FD already gets.
assert W.WORKER_UID == uid, (W.WORKER_UID, uid)
assert W.WORKER_GID == gid, (W.WORKER_GID, gid)
assert isinstance(transition.WORKER_USER, str) and transition.WORKER_USER

sites = 0
for path in (TRANSITION, WORKER_LIB):
    values = literals(path)
    sites += values.count(uid) + values.count(gid)
# And the rootless runtime directory, where the uid is inside a path string.
runtime_dir = f'/run/user/{uid}'
for path in (TRANSITION, WORKER_LIB, BACKEND):
    assert runtime_dir in literals(path), f'{path} no longer states {runtime_dir}'
    sites += literals(path).count(runtime_dir)

# Seven sites: the uid and gid constants in each of two modules, plus the
# rootless runtime directory in each of three. If this count moves, either the
# gap is being closed or it is being widened, and both deserve to be noticed.
assert sites == 7, (
    f'the worker identity is now stated at {sites} sites, not 7; '
    'update the migration checklist in the G11-AR report')
print('OK')
"

run_case "the reconciliation module states no execution identity of its own" "${PRELUDE}
# It takes an injected backend and never resolves an identity, which is why it
# was implementable in G11-AQ while the privileged entrypoint was not.
values = literals(RECONCILE)
for number in (999, 987, 1000):
    assert number not in values, (number, 'the reconciler names an identity')
for text in values:
    if isinstance(text, str):
        assert '/run/user/' not in text, text
        assert 'kyri-capability' not in text, text
print('OK')
"

run_case "no privileged reconciliation entrypoint exists yet" "${PRELUDE}
# G11-AR's deliverable, and its absence is the checkpoint's stop. Stated so the
# handoff cannot drift from the tree: when the entrypoint lands this case is
# the one that must be replaced.
import os
candidates = [p for p in Path('provisioning/execution').glob('kyri-exec-reconcile*')
              if p.name != 'kyri-exec-reconcile.py']
assert not candidates, f'an entrypoint appeared: {candidates}'
assert not os.path.exists('/usr/libexec/kyri-exec-reconcile'), \\
    'a reconciliation helper is installed on this host'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution identity authority validation passed.\n'
else
  printf 'Capability execution identity authority validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
