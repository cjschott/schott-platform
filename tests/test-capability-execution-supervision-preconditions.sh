#!/usr/bin/env bash
set -Eeuo pipefail

# The two preconditions a coordinator supervisor depends on, pinned before one
# is written.
#
# UNPRIVILEGED AND STATIC. No Podman, no container, no helper, no production
# path. Every assertion is over source.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AP set out to build the coordinator-side supervision loop -- the missing
# half of the production execution path. Two of its preconditions were checked
# first, because either failing would make the loop unbuildable rather than
# merely unbuilt.
#
# One holds and is pinned here, because a future helper ceremony must not
# silently break it: the privileged transition already inherits exactly the
# descriptors a supervisor needs, and no more.
#
# The other does not hold, and this suite records the boundary rather than
# asserting a property the platform does not have. See the G11-AP report:
# a worker killed mid-execution leaves its container RUNNING, and the
# coordinator has no authority to stop it. That is not a defect in any module
# here -- it is a consequence of the privilege split working -- but a
# supervision loop that promised "no orphan" would be promising something it
# cannot deliver.

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
from tools.capability.execution import protocol as P

TRANSITION = Path('provisioning/execution/kyri-exec-transition.py')
WORKER = Path('provisioning/execution/kyri-exec-worker.py')
"

# --- the descriptor topology a supervisor needs ------------------------------------

run_case "the transition inherits exactly the protocol descriptors and the profile" "${PRELUDE}
import importlib.util
spec = importlib.util.spec_from_file_location('kyri_exec_transition', str(TRANSITION))
module = importlib.util.module_from_spec(spec)
sys.modules['kyri_exec_transition'] = module
spec.loader.exec_module(module)

# 0, 1 and 2 are the protocol channels the coordinator would own; 3 is the
# sealed profile the transition authors itself. A supervisor needs exactly
# these and the helper already passes exactly these -- no widening required,
# and none may appear later.
assert module.INHERITED_DESCRIPTORS == (0, 1, 2, 3), module.INHERITED_DESCRIPTORS
assert module.PROFILE_FD == 3, module.PROFILE_FD
print('OK')
"

run_case "no caller may name a descriptor the transition will honour" "${PRELUDE}
# The allowlist is compiled in. A caller descriptor that happens to occupy a
# governed number is replaced rather than honoured, which is what keeps the
# supervisor's channels the supervisor's.
source = TRANSITION.read_text(encoding='utf-8')
tree = ast.parse(source)
assignments = [n for n in ast.walk(tree)
               if isinstance(n, ast.Assign)
               and any(getattr(t, 'id', None) == 'INHERITED_DESCRIPTORS'
                       for t in n.targets)]
assert len(assignments) == 1, assignments
# A literal tuple, not a computation over anything a caller supplies.
assert isinstance(assignments[0].value, ast.Tuple), ast.dump(assignments[0])
for element in assignments[0].value.elts:
    assert isinstance(element, ast.Constant) and isinstance(element.value, int)
print('OK')
"

# --- the state machine a supervisor must implement ---------------------------------

run_case "the accepted protocol admits exactly one success sequence" "${PRELUDE}
# Enumerated from the released transition table rather than described, so a
# supervisor written against this cannot drift from what the parser enforces.
expected = [
    ('start', 'created', 'created'),
    ('created', 'verified_profile', 'profile_verified'),
    ('profile_verified', 'start_now', 'start_sent'),
    ('start_sent', 'started', 'started'),
    ('started', 'terminal', 'terminal'),
    ('terminal', 'collected', 'collected'),
]
observed = [(state.value, kind.value, nxt.value)
            for state, allowed in P._TRANSITIONS.items()
            for kind, nxt in allowed.items()]
assert observed == expected, observed
print('OK')
"

run_case "start authority is reachable only after the profile is verified" "${PRELUDE}
# The load-bearing ordering. A worker cannot self-start, and no state other
# than profile_verified admits start_now -- so a malformed message cannot walk
# the session to a point where starting looks legal.
starts = [(state.value, nxt.value)
          for state, allowed in P._TRANSITIONS.items()
          for kind, nxt in allowed.items()
          if kind is P.MessageKind.START_NOW]
assert starts == [('profile_verified', 'start_sent')], starts
print('OK')
"

run_case "error and abort terminate, and only where a session can be alive" "${PRELUDE}
assert set(P._TERMINATING) == {P.MessageKind.ERROR, P.MessageKind.ABORT}
# Not legal after the conversation already ended, which is what stops a second
# terminating message from re-opening a closed session.
assert P.SessionState.ENDED not in P._MAY_TERMINATE
assert P.SessionState.COLLECTED not in P._MAY_TERMINATE
print('OK')
"

run_case "the worker reports and the coordinator decides" "${PRELUDE}
# Direction is part of the contract: the two coordinator-to-worker kinds are
# the only ones carrying authority, and the worker's six are observations.
worker_kinds = {P.MessageKind.CREATED, P.MessageKind.VERIFIED_PROFILE,
                P.MessageKind.STARTED, P.MessageKind.TERMINAL,
                P.MessageKind.COLLECTED, P.MessageKind.ERROR}
coordinator_kinds = {P.MessageKind.START_NOW, P.MessageKind.ABORT}
assert worker_kinds | coordinator_kinds == set(P.MessageKind), set(P.MessageKind)
assert not (worker_kinds & coordinator_kinds)
print('OK')
"

# --- the authority split the supervisor must not cross -----------------------------

run_case "the worker writes no capability runtime record" "${PRELUDE}
# The coordinator is the sole authority writer. The worker observes and
# reports; if it could write a result there would be two authors of the same
# fact, and the one holding Podman authority would be the weaker of them.
code = ast.unparse(ast.parse(WORKER.read_text(encoding='utf-8')))
for banned in ('CapabilityStore', 'record_terminal_result', 'record_invocation',
               'capability-result', 'capability-invocation', 'allocate_id'):
    assert banned not in code, banned
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution supervision precondition validation passed.\n'
else
  printf 'Capability execution supervision precondition validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
