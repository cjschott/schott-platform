#!/usr/bin/env bash
set -Eeuo pipefail

# What the invocation record says about execution authority, and what an
# invocation with no result therefore means.
#
# UNPRIVILEGED AND HERMETIC. No Podman, no container, no production path.
# Every store is a temporary directory.
#
# WHY THIS SUITE EXISTS
# =====================
# Design section 17 says validation reports an invocation with no result as
# interrupted. G11-AN could not implement that, because two entirely different
# situations wrote the same record:
#
#   a preparation where no adapter was ever authorised -- nothing was
#   attempted, and calling it interrupted would libel it;
#
#   an execution that was authorised and then died before its outcome became
#   durable -- which is exactly what interrupted means.
#
# Section 14 already names the field that separates them: `adapter_identity` on
# the invocation record. It was in the accepted architecture and not in the
# implementation. This suite is that field and the classification it unlocks.
#
# THE WINDOW IS NOT CLOSED, DELIBERATELY. Binding execution authority durably
# and then crashing before the adapter's first instruction still reads as
# interrupted. Once authority is bound the platform cannot prove the adapter
# did not act, and a mutable "started" bit to narrow that window would be a
# second, weaker source of truth about the same question.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && WORKDIR="${WORK}" python3 -c "${script}" 2>&1)"; then
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
import os, sys
sys.path.insert(0, '.')
from datetime import datetime, timezone
from tools.capability import evidence as E
from tools.capability import inspection as I
from tools.capability import records as R
from tools.capability.execution.profile import ADAPTER_IDENTITY
from tools.capability.store import CapabilityStore
from tools.capability.errors import CapabilityError

WORK = os.environ['WORKDIR']
WHEN = datetime(2026, 8, 31, 12, 0, tzinfo=timezone.utc)

def store(name):
    return CapabilityStore(os.path.join(WORK, name), expected_uid=os.getuid(),
                           expected_gid=os.getgid())

def cinv(identity='CINV-000001', *, adapter_identity=None,
         outcome=E.OUTCOME_PREPARED, invocation_id='inv-a'):
    return {
        'invocation_record_id': identity, 'invocation_id': invocation_id,
        'request_id': 'req-1', 'selection_id': 'CSEL-000001',
        'instance_id': 'CINST-000001', 'capability_package_id': 'CPKG-0001',
        'contract_id': 'CCON-0001', 'capability_id': 'CAPDEF-0001',
        'operation': 'execute', 'actor': 'operator:cschott',
        'payload_digest': 'sha256:' + 'a' * 64,
        'binding_digest': 'sha256:' + 'b' * 64, 'effect_class': 'read-only',
        'artifact_digest': 'sha256:' + 'c' * 64, 'staged_path': '/staging/x',
        'adapter_identity': adapter_identity,
        'requested_at': WHEN, 'kind': R.INVOCATION_KIND,
        'schema_version': R.INVOCATION_SCHEMA_VERSION,
        'evidence': {'actor': 'operator:cschott', 'outcome': outcome,
                     'request_id': 'req-1', 'selection_id': 'CSEL-000001'},
    }

def cres(identity='CRES-000001', invocation_record_id='CINV-000001',
         outcome_class='completed', reason=None,
         result_digest='sha256:' + 'd' * 64):
    return {
        'capability_result_id': identity,
        'invocation_record_id': invocation_record_id, 'attempt_number': 1,
        'outcome_class': outcome_class, 'reason': reason,
        'result_digest': result_digest, 'result_artifact_reference': None,
        'started_at': WHEN, 'ended_at': WHEN, 'recorded_at': WHEN,
        'kind': R.RESULT_KIND, 'schema_version': R.RESULT_SCHEMA_VERSION,
        'evidence': {'actor': 'operator:cschott', 'outcome': outcome_class},
    }

def seeded(name, *records):
    handle = store(name)
    for body in records:
        kind = body['kind']
        key = ('invocation_record_id' if kind == R.INVOCATION_KIND
               else 'capability_result_id')
        handle.write_atomic(handle.path_for(kind, body[key]), body)
    return handle

def findings(handle):
    return list(I.validate_store(handle).findings)
"

# --- the field, and where it comes from -------------------------------------------

run_case "the invocation record carries the adapter identity" "${PRELUDE}
# Design section 14 names it among the invocation record's conceptual fields.
# It was accepted architecture before this checkpoint and simply absent from
# the implementation.
assert 'adapter_identity' in R.INVOCATION_FIELDS, R.INVOCATION_FIELDS
print('OK')
"

run_case "the invocation schema moved and the result schema did not" "${PRELUDE}
# The invocation record's closed field set changed, so its version moves. The
# result record did not change, so its version stays where G11-AN put it --
# versions are per kind precisely so one may move without relabelling another.
assert R.INVOCATION_SCHEMA_VERSION == 2, R.INVOCATION_SCHEMA_VERSION
assert R.RESULT_SCHEMA_VERSION == 2, R.RESULT_SCHEMA_VERSION
print('OK')
"

run_case "the identity is the governed one, and a caller cannot choose it" "${PRELUDE}
assert ADAPTER_IDENTITY == 'python-podman-v1', ADAPTER_IDENTITY
# Closed vocabulary: an unrecognised mechanism is refused rather than recorded.
for bad in ('python-docker-v1', 'PYTHON-PODMAN-V1', 'anything', ''):
    try:
        E.require_adapter_identity(bad)
    except CapabilityError:
        continue
    raise AssertionError(f'accepted an ungoverned adapter identity: {bad!r}')
assert E.require_adapter_identity(ADAPTER_IDENTITY) == ADAPTER_IDENTITY
# Null is the one other legal value: no execution mechanism was authorised.
assert E.require_adapter_identity(None) is None
print('OK')
"

# --- the state model ---------------------------------------------------------------

run_case "1. prepared with no adapter authorised is not interrupted" "${PRELUDE}
handle = seeded('prepared', cinv(adapter_identity=None))
result = findings(handle)
assert not [f for f in result if 'interrupted' in f], result
print('OK')
"

run_case "2. execution authorised with no result is interrupted" "${PRELUDE}
# The case section 17 describes. Authority was durably bound; no terminal
# outcome became durable; the platform cannot prove the adapter did not act.
handle = seeded('interrupted', cinv(adapter_identity=ADAPTER_IDENTITY))
result = findings(handle)
assert [f for f in result if I.FINDING_INTERRUPTED_EXECUTION in f], result
print('OK')
"

run_case "3. execution authorised with a terminal result is sound" "${PRELUDE}
handle = seeded('terminal', cinv(adapter_identity=ADAPTER_IDENTITY), cres())
assert findings(handle) == [], findings(handle)
print('OK')
"

run_case "4. a pre-execution refusal keeps its own semantics" "${PRELUDE}
handle = seeded('refusal',
                cinv(adapter_identity=None, outcome=E.OUTCOME_REFUSED),
                cres(outcome_class='refused', reason='instance-not-admitted',
                     result_digest=None))
result = findings(handle)
# Refused with its result is sound, and is never called interrupted.
assert not [f for f in result if 'interrupted' in f], result
print('OK')
"

run_case "a refusal with no result is still refusal-without-result" "${PRELUDE}
handle = seeded('lonely-refusal',
                cinv(adapter_identity=None, outcome=E.OUTCOME_REFUSED))
result = findings(handle)
assert [f for f in result if I.FINDING_INTERRUPTED_REFUSAL in f], result
# ...and not the execution finding, which means something different.
assert not [f for f in result if I.FINDING_INTERRUPTED_EXECUTION in f], result
print('OK')
"

# --- impossible records ------------------------------------------------------------

run_case "a terminal result under an unauthorised adapter is refused" "${PRELUDE}
# A result for an execution that was never authorised to happen.
handle = seeded('impossible', cinv(adapter_identity=None), cres())
result = findings(handle)
assert result, 'a result without execution authority was accepted'
print('OK')
"

run_case "an ungoverned adapter identity on a record is malformed" "${PRELUDE}
body = cinv(adapter_identity='python-docker-v1')
handle = seeded('ungoverned', body)
result = findings(handle)
assert [f for f in result if 'malformed' in f], result
print('OK')
"

run_case "two terminal results for one invocation are refused" "${PRELUDE}
handle = seeded('duplicate', cinv(adapter_identity=ADAPTER_IDENTITY),
                cres('CRES-000001'), cres('CRES-000002'))
assert findings(handle), 'two attempt-1 results were accepted'
print('OK')
"

# --- the historical shape ----------------------------------------------------------

run_case "a v1 invocation is never guessed into an execution attempt" "${PRELUDE}
# No production capability records exist, so there is no migration obligation.
# What matters is that a record written before the field existed is not read as
# evidence of something it never recorded.
legacy = cinv()
del legacy['adapter_identity']
legacy['schema_version'] = 1
handle = seeded('legacy', legacy)
result = findings(handle)
assert not [f for f in result if I.FINDING_INTERRUPTED_EXECUTION in f], \\
    'a v1 record was labelled interrupted on evidence it never carried'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability adapter binding validation passed.\n'
else
  printf 'Capability adapter binding validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
