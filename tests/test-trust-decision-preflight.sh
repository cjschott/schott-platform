#!/usr/bin/env bash
set -Eeuo pipefail

# Trust Evidence identity integrity, and rehearsing a decision without spending
# one.
#
# TWO DEFECTS THIS SUITE EXISTS FOR.
#
# 1. `create_decision` DISCARDED the cited evidence identity and allocated a
#    fresh one. A decision body citing TEVID-000001 produced a durable record
#    citing TEVID-000006, and the CLI made it worse by hardcoding a
#    TEVID-000000 placeholder "replaced by the store on write". So the approved
#    body and the durable record disagreed about which evidence was examined,
#    silently, and neither looked wrong on its own.
#
# 2. There was no rehearsal. `create-decision` allocated and wrote
#    unconditionally, so the only way to find out whether the first fabric-node
#    decision would be accepted was to make it -- and the identity it would
#    spend is the one thing that cannot be taken back.
#
# WHAT IS NOT CHANGED. The transition table, the authority rule, the lineage
# rules and the minimum-substance guard on a decision reason are untouched. A
# rehearsal runs all of them against the real store; it is the same algorithm
# stopping at the allocation boundary, not a second one.
#
# Fixture-only. Copies of the live Trust store under a temporary directory, and
# read-only opens of the live one. It creates no production decision, evidence,
# record, lineage or audit event, and proves the live store is byte-identical
# when it finishes.
#
# Governed by:
#   docs/decisions/ADR-0011-trust-plane.md
#   platform-model/schemas/trust-record.schema.yaml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

LIVE_TRUST="/var/lib/kyri/trust"                   # prod-path-reference
LIVE_FABRIC="/var/lib/kyri/fabric"                 # prod-path-reference
live_state() {
  if [[ -e "$1" ]]; then
    { find "$1" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "$1" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
TRUST_BEFORE="$(live_state "${LIVE_TRUST}")"
FABRIC_BEFORE="$(live_state "${LIVE_FABRIC}")"

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

# The accepted first fabric-node decision, as ruled. Test-only: this body is
# never written into an approved production directory by this suite.
PRELUDE="
import json, os, shutil, subprocess, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
sys.dont_write_bytecode = True

from tools.trust.store import TrustStore
from tools.trust.evaluator import create_decision, rehearsing
from tools.trust.models import (TrustEvidenceReference, TrustVerificationDetails,
                                TrustScope, TrustState, VerificationMethod)
from tools.trust.errors import TrustError

LIVE = '${LIVE_TRUST}'
WHEN = datetime(2026, 8, 25, 12, 0, 0, tzinfo=timezone.utc)
REASON = ('The operator reviewed the governed Platform Evidence EVID-000001, which '
          'records the architecture of HOST-0001 as x86-64 from three corroborating '
          'host observations, together with the declared host entity in the platform '
          'model, and admitted HOST-0001 as a fabric node for the execution-boundary '
          'verification capability.')

def mirror(tmp):
    root = Path(tmp) / 'trust'
    shutil.copytree(LIVE, root)
    return TrustStore(root)

def evidence(evidence_id='TEVID-000006', **overrides):
    call = dict(evidence_id=evidence_id, kind='reviewed-source-inspection-record',
                reference='/etc/kyri/trust/evidence/fabric-node/HOST-0001-verification.yaml',
                recorded_at=WHEN)
    call.update(overrides)
    return TrustEvidenceReference(**call)

def decision(store, **overrides):
    call = dict(subject_id='HOST-0001', subject_type='fabric-node',
                requested_state=TrustState.TRUSTED.value,
                actor_authority_id='TAUTH-000001', decided_at=WHEN, reason=REASON,
                evidence_references=(evidence(),),
                verification_method=VerificationMethod.REVIEWED_SOURCE_INSPECTION.value,
                verification_details=TrustVerificationDetails(
                    subject_property='fabric-node-identity',
                    observed_value_reference='/var/lib/kyri/evidence/EVID-000001.yaml',
                    comparison_source='reviewed-governed-platform-evidence',
                    performed_by='primary-platform-operator', performed_at=WHEN),
                scope=TrustScope(scope_id='TSCOPE-000001', subject_type='fabric-node',
                                 permitted_capabilities=('CAPDEF-0001',),
                                 permitted_operations=('execute',),
                                 permitted_data_classifications=('internal',),
                                 permitted_targets=('HOST-0001',)),
                expiration=None)
    call.update(overrides)
    return create_decision(store, **call)

def state(root):
    import hashlib
    entries = []
    for item in sorted(Path(root).rglob('*')):
        info = item.lstat()
        entries.append(f'{item} {info.st_mode} {info.st_size}')
        if item.is_file():
            entries.append(hashlib.sha256(item.read_bytes()).hexdigest())
    return hashlib.sha256('\n'.join(entries).encode()).hexdigest()
"

# ===========================================================================
# Defect 1 -- a Trust Evidence identity has one meaning
# ===========================================================================

run_case "a cited evidence identity is carried, not re-labelled" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    outcome = decision(store)
    cited = outcome.decision.evidence_references[0].evidence_id
    assert cited == 'TEVID-000006', cited
    written = Path(store.root) / 'evidence-references' / 'TEVID-000006.yaml'
    assert written.exists(), 'the cited evidence was not written under its identity'
print('OK')
"

# The invariant: store[TEVID-X] and the decision's representation of TEVID-X can
# never disagree while the decision succeeds.
run_case "citing an existing identity with different content refuses" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    before = state(store.root)
    stored = store.read('evidence', 'TEVID-000001')
    try:
        decision(store, evidence_references=(evidence(evidence_id='TEVID-000001'),))
    except TrustError as error:
        assert 'already exists and does not match' in str(error), error
    else:
        raise AssertionError('a conflicting citation was accepted')
    # Nothing repaired, superseded, reinterpreted, or spent.
    assert store.read('evidence', 'TEVID-000001') == stored
    assert state(store.root) == before, 'a refused citation changed the store'
print('OK')
"

# Exact replay of an existing citation is the one case that may stand: the
# identity already means exactly what the decision says it means.
run_case "citing an existing identity with identical content is accepted" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    stored = store.read('evidence', 'TEVID-000001')
    identical = TrustEvidenceReference(
        evidence_id=stored['evidence_id'], kind=stored['kind'],
        reference=stored['reference'],
        recorded_at=datetime.fromisoformat(stored['recorded_at']))
    before_bytes = (Path(store.root)/'evidence-references'/'TEVID-000001.yaml').read_bytes()
    outcome = decision(store, evidence_references=(identical,))
    assert outcome.decision.evidence_references[0].evidence_id == 'TEVID-000001'
    # Cited, never rewritten.
    assert (Path(store.root)/'evidence-references'/'TEVID-000001.yaml').read_bytes() \\
        == before_bytes
    # And no new evidence identity was spent for a citation.
    assert (Path(store.root)/'sequences'/'evidence.seq').read_text().strip() == '5'
print('OK')
"

run_case "citing an identity the store is not about to hand out refuses" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    before = state(store.root)
    for absent in ('TEVID-000009', 'TEVID-000000', 'TEVID-000007'):
        try:
            decision(store, evidence_references=(evidence(evidence_id=absent),))
        except TrustError as error:
            assert 'does not exist and the next evidence identity' in str(error), error
        else:
            raise AssertionError('accepted ' + absent)
    assert state(store.root) == before, 'a refused citation spent something'
print('OK')
"

run_case "a malformed evidence identity is refused rather than resolved" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    before = state(store.root)
    for bad in ('tevid-000006', 'TEVID-6', '../TEVID-000001', 'EVID-000001', ''):
        try:
            decision(store, evidence_references=(evidence(evidence_id=bad),))
        except Exception:
            continue
        raise AssertionError('accepted evidence identity ' + repr(bad))
    assert state(store.root) == before
print('OK')
"

# Platform Evidence is a different plane with a different identity space.
run_case "a Platform Evidence identity is not Trust Evidence" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    try:
        decision(store, evidence_references=(evidence(evidence_id='EVID-000001'),))
    except Exception:
        print('OK')
    else:
        raise AssertionError('a Platform Evidence identity was accepted as Trust Evidence')
"

# ===========================================================================
# Defect 2 -- a rehearsal that spends nothing
# ===========================================================================

run_case "a rehearsal predicts every identity and writes nothing" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    before = state(store.root)
    with rehearsing():
        outcome = decision(store)
    assert outcome.record.record_id == 'TREC-000001', outcome.record.record_id
    assert outcome.decision.decision_id == 'TDEC-000001'
    assert outcome.lineage.lineage_id == 'TLIN-000002'
    assert outcome.audit_event.audit_id == 'TAUDIT-000002'
    assert outcome.decision.evidence_references[0].evidence_id == 'TEVID-000006'
    assert state(store.root) == before, 'the rehearsal mutated the store'
    for kind in ('record', 'decision', 'scope'):
        assert not (Path(store.root)/'sequences'/(kind + '.seq')).exists(), kind
    assert (Path(store.root)/'sequences'/'evidence.seq').read_text().strip() == '5'
    assert (Path(store.root)/'sequences'/'lineage.seq').read_text().strip() == '1'
    assert (Path(store.root)/'sequences'/'audit.seq').read_text().strip() == '1'
    assert not any((Path(store.root)/'records').iterdir())
    assert not any((Path(store.root)/'decisions').iterdir())
print('OK')
"

# The whole point: the rehearsal must answer what the write answers.
run_case "the rehearsal and the write reach the same identities" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    with rehearsing():
        rehearsed = decision(store)
    written = decision(store)
    assert rehearsed.record.record_id == written.record.record_id
    assert rehearsed.decision.decision_id == written.decision.decision_id
    assert rehearsed.lineage.lineage_id == written.lineage.lineage_id
    assert rehearsed.audit_event.audit_id == written.audit_event.audit_id
    assert rehearsed.decision.evidence_references[0].evidence_id \\
        == written.decision.evidence_references[0].evidence_id
    assert rehearsed.decision.decision_fingerprint == written.decision.decision_fingerprint
    assert rehearsed.record.fingerprint == written.record.fingerprint
print('OK')
"

# A rehearsal that skipped a rule would be a different algorithm. Every refusal
# the write makes, the rehearsal makes too.
run_case "the rehearsal refuses everything the write refuses" "${PRELUDE}
refusals = [
    dict(actor_authority_id='TAUTH-000009'),
    dict(reason='no'),
    dict(requested_state='banana'),
    dict(subject_id='TAUTH-000001'),
    dict(evidence_references=(evidence(evidence_id='TEVID-000009'),)),
]
for overrides in refusals:
    with tempfile.TemporaryDirectory() as tmp:
        store = mirror(tmp)
        rehearsed_error = written_error = None
        with rehearsing():
            try:
                decision(store, **overrides)
            except Exception as error:
                rehearsed_error = type(error).__name__
        try:
            decision(store, **overrides)
        except Exception as error:
            written_error = type(error).__name__
        assert rehearsed_error is not None, overrides
        assert rehearsed_error == written_error, (overrides, rehearsed_error, written_error)
print('OK')
"

# ===========================================================================
# The accepted first fabric-node decision, end to end
# ===========================================================================

run_case "the accepted HOST-0001 decision rehearses against the LIVE store" "${PRELUDE}
store = TrustStore.open_for_read(LIVE)
before = state(LIVE)
with rehearsing():
    outcome = decision(store)
assert outcome.record.subject_id == 'HOST-0001'
assert outcome.record.subject_type == 'fabric-node'
assert outcome.record.state == 'trusted'
assert outcome.record.record_id == 'TREC-000001'
assert outcome.decision.evidence_references[0].evidence_id == 'TEVID-000006'
scope = outcome.record.scope
assert tuple(scope.permitted_capabilities) == ('CAPDEF-0001',), scope
assert tuple(scope.permitted_operations) == ('execute',), scope
assert tuple(scope.permitted_data_classifications) == ('internal',), scope
assert tuple(scope.permitted_targets) == ('HOST-0001',), scope
assert outcome.record.expiration is None
assert state(LIVE) == before, 'rehearsing against the live store mutated it'
print('OK')
"

run_case "the resulting record verifies through the Fabric adapter" "${PRELUDE}
from tools.fabric.trust_adapter import verify_trust_record
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    outcome = decision(store)
    verdict = verify_trust_record(store, outcome.record.record_id,
                                  evaluated_at=datetime(2026, 8, 25, 13, 0, 0,
                                                        tzinfo=timezone.utc),
                                  expected_subject_type='fabric-node')
    assert verdict.status == 'verified', verdict
    assert verdict.subject_id == 'HOST-0001', verdict
print('OK')
"

# Presenting the same decision twice is refused by the transition table, which
# is code-owned. Characterised rather than asserted to be idempotent: it is not.
run_case "presenting the accepted decision twice is refused deterministically" "${PRELUDE}
with tempfile.TemporaryDirectory() as tmp:
    store = mirror(tmp)
    decision(store)
    try:
        decision(store)
    except TrustError as error:
        assert 'trusted' in str(error), error
    else:
        raise AssertionError('a duplicate decision was accepted')
print('OK')
"

# ===========================================================================
# The CLI surface
# ===========================================================================

assert_cli() {
  local tmp body out
  tmp="$(mktemp -d)"
  cp -a "${LIVE_TRUST}" "${tmp}/trust"
  mkdir -p "${tmp}/approved"
  body="${tmp}/approved/decision.json"
  cat > "${body}" <<'JSON'
{
  "subject_id": "HOST-0001",
  "subject_type": "fabric-node",
  "requested_state": "trusted",
  "actor_authority_id": "TAUTH-000001",
  "decided_at": "2026-08-25T12:00:00+00:00",
  "reason": "The operator reviewed the governed Platform Evidence EVID-000001, which records the architecture of HOST-0001 as x86-64 from three corroborating host observations, together with the declared host entity in the platform model, and admitted HOST-0001 as a fabric node for the execution-boundary verification capability.",
  "verification_method": "reviewed-source-inspection",
  "verification_details": {
    "subject_property": "fabric-node-identity",
    "observed_value_reference": "/var/lib/kyri/evidence/EVID-000001.yaml",
    "comparison_source": "reviewed-governed-platform-evidence",
    "performed_by": "primary-platform-operator",
    "performed_at": "2026-08-25T12:00:00+00:00"
  },
  "evidence_references": [
    {
      "evidence_id": "TEVID-000006",
      "kind": "reviewed-source-inspection-record",
      "reference": "/etc/kyri/trust/evidence/fabric-node/HOST-0001-verification.yaml",
      "recorded_at": "2026-08-25T12:00:00+00:00"
    }
  ],
  "trust_scope": {
    "subject_type": "fabric-node",
    "permitted_capabilities": ["CAPDEF-0001"],
    "permitted_operations": ["execute"],
    "permitted_data_classifications": ["internal"],
    "permitted_targets": ["HOST-0001"]
  },
  "expiration": null
}
JSON
  local before after
  before="$(live_state "${tmp}/trust")"
  out="$(cd "${ROOT}" && python3 -m tools.trust.cli create-decision --preflight \
    --store-root "${tmp}/trust" --input-file decision.json \
    --approved-directory "${tmp}/approved" 2>&1)" || {
      fail "cli preflight failed: ${out}"; rm -rf "${tmp}"; return; }
  after="$(live_state "${tmp}/trust")"
  local problems=0
  python3 - "${out}" <<'PY' || problems=1
import json, sys
d = json.loads(sys.argv[1])
want = {"outcome": "preflight", "would_accept": True, "mutated": False,
        "predicted_record_id": "TREC-000001",
        "predicted_decision_id": "TDEC-000001",
        "predicted_lineage_id": "TLIN-000002",
        "predicted_audit_id": "TAUDIT-000002",
        "predicted_scope_id": "TSCOPE-000001",
        "predicted_evidence_ids": ["TEVID-000006"],
        "destination_exists": False, "subject_id": "HOST-0001",
        "subject_type": "fabric-node", "state": "trusted"}
bad = [k for k, v in want.items() if d.get(k) != v]
assert not bad, [(k, d.get(k)) for k in bad]
assert d["decision_fingerprint"].startswith("sha256:")
PY
  [[ "${before}" == "${after}" ]] || problems=1
  if (( problems == 0 )); then
    pass "the CLI preflight reports structured predictions and mutates nothing"
  else
    fail "the CLI preflight output or mutation check failed"
  fi
  # And the real write reproduces exactly what the preflight predicted.
  local real
  real="$(cd "${ROOT}" && python3 -m tools.trust.cli create-decision \
    --store-root "${tmp}/trust" --input-file decision.json \
    --approved-directory "${tmp}/approved" 2>&1)" || {
      fail "cli write failed: ${real}"; rm -rf "${tmp}"; return; }
  if [[ -f "${tmp}/trust/records/TREC-000001.yaml" \
     && -f "${tmp}/trust/decisions/TDEC-000001.yaml" \
     && -f "${tmp}/trust/evidence-references/TEVID-000006.yaml" ]]; then
    pass "the write produces exactly the predicted record, decision and evidence"
  else
    fail "the write did not produce the predicted identities"
  fi
  rm -rf "${tmp}"
}
assert_cli

# The placeholder that caused the divergence is gone.
run_case "the CLI carries the operator's cited identity" "${PRELUDE}
cli = Path('tools/trust/cli.py').read_text(encoding='utf-8')
assert 'TEVID-000000' not in cli, 'the placeholder identity survives'
assert 'evidence_id=str(item[\"evidence_id\"])' in cli
assert '--preflight' in cli
print('OK')
"

# ===========================================================================
# What this suite did not touch
# ===========================================================================

assert_untouched() {
  local problems=0
  [[ "$(live_state "${LIVE_TRUST}")" == "${TRUST_BEFORE}" ]] || { fail "the live Trust store moved"; problems=1; }
  [[ "$(live_state "${LIVE_FABRIC}")" == "${FABRIC_BEFORE}" ]] || { fail "the live Fabric store moved"; problems=1; }
  [[ -z "$(ls -A "${LIVE_TRUST}/records" 2>/dev/null)" ]] || { fail "a production TREC appeared"; problems=1; }
  [[ -z "$(ls -A "${LIVE_TRUST}/decisions" 2>/dev/null)" ]] || { fail "a production TDEC appeared"; problems=1; }
  if (( problems == 0 )); then
    pass "the live Trust and Fabric stores are unchanged; no production TREC or TDEC"
  fi
}
assert_untouched

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All trust-preflight assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
