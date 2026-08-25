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
# REBASELINED after HOST-0001 was admitted. The fixture cases once ran against
# copies of the live Trust store, which worked only while no subject in it was
# trusted yet. TREC-000001 is now durable and correct, so a copy of the live
# store can no longer answer what happens when a subject is trusted for the
# first time, and replaying that decision against the live store is refused --
# rightly, because 'trusted' -> 'trusted' is absent from the transition table.
#
# So the two questions are asked separately, of the store that can answer each:
#
#   * fresh fixture stores, built by the real declaration path, still prove
#     first-decision prediction and write reach identical identities;
#   * the live store proves the accepted decision is on record as ruled, that
#     replaying it is refused in words rather than a traceback, and that asking
#     either question spends no identifier and moves no byte.
#
# It creates no production decision, evidence, record, lineage or audit event,
# and proves every live Trust object and sequence is unchanged when it
# finishes.
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

# This suite used to assert the production record and decision namespaces were
# empty. That held until HOST-0001 was deliberately admitted, and asserting it
# now would report a governed ceremony succeeding as a test failure. The
# invariant underneath it never was emptiness -- it is that nothing this suite
# does can move the live Trust authority. That is asserted here object by
# object, which is the stronger claim: absence proves nothing was added, and
# this proves nothing was added, removed, or rewritten.
LIVE_OBJECTS=(
  "authorities/TAUTH-000001.yaml"
  "audit/TAUDIT-000001.yaml"
  "audit/TAUDIT-000002.yaml"
  "records/TREC-000001.yaml"
  "decisions/TDEC-000001.yaml"
  "lineages/TLIN-000002-v0001.yaml"
  "evidence-references/TEVID-000001.yaml"
  "evidence-references/TEVID-000002.yaml"
  "evidence-references/TEVID-000003.yaml"
  "evidence-references/TEVID-000004.yaml"
  "evidence-references/TEVID-000005.yaml"
  "evidence-references/TEVID-000006.yaml"
)
LIVE_SEQUENCES=(authority lineage evidence audit record decision scope)

object_digests() {
  local name
  for name in "${LIVE_OBJECTS[@]}"; do
    printf '%s %s\n' "${name}" \
      "$(sha256sum "${LIVE_TRUST}/${name}" 2>/dev/null | cut -d' ' -f1)"
  done
}
sequence_values() {
  local name
  for name in "${LIVE_SEQUENCES[@]}"; do
    printf '%s %s\n' "${name}" "$(cat "${LIVE_TRUST}/sequences/${name}.seq" 2>/dev/null)"
  done
}
OBJECTS_BEFORE="$(object_digests)"
SEQUENCES_BEFORE="$(sequence_values)"

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
import json, os, subprocess, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
sys.dont_write_bytecode = True

from tools.trust.store import TrustStore
from tools.trust.evaluator import create_decision, rehearsing
from tools.trust.models import (TrustEvidenceReference, TrustVerificationDetails,
                                TrustScope, TrustState, VerificationMethod)
from tools.trust.root_authority import declare_root_authority
from tools.trust.errors import TrustError

LIVE = '${LIVE_TRUST}'
WHEN = datetime(2026, 8, 25, 12, 0, 0, tzinfo=timezone.utc)
CEREMONY = datetime(2026, 8, 3, 22, 0, 6, tzinfo=timezone.utc)
REASON = ('The operator reviewed the governed Platform Evidence EVID-000001, which '
          'records the architecture of HOST-0001 as x86-64 from three corroborating '
          'host observations, together with the declared host entity in the platform '
          'model, and admitted HOST-0001 as a fabric node for the execution-boundary '
          'verification capability.')

ROOT_EVIDENCE = (
    ('out-of-band-verification-record', 'operator-root-verification.yaml'),
    ('fingerprint-record', 'FINGERPRINT.txt'),
    ('offline-signature', 'operator-root.yaml.asc'),
    ('public-key', 'operator-root-public.asc'),
    ('checksum-manifest', 'SHA256SUMS'),
)

def fixture(tmp):
    '''A fresh store holding one root establishment and nothing else.

    Built by the real declaration path rather than copied from the live store.
    The live store now holds the accepted HOST-0001 decision, so a copy of it
    can no longer answer what happens when a subject is first trusted -- and a
    fixture that has to be rebuilt every time a governed ceremony succeeds is a
    fixture that will be stale again by the next one.
    '''
    store = TrustStore(Path(tmp) / 'trust')
    declare_root_authority(store, {
        'display_name': 'Operator Root Authority',
        'external_identity_reference': 'openpgp-fingerprint://' + 'A' * 40,
        'verification_method': 'out-of-band-fingerprint-comparison',
        'verification_details': {
            'subject_property': 'operator-root-key-fingerprint',
            'observed_value_reference':
                '/etc/kyri/trust/evidence/operator-root/FINGERPRINT.txt',
            'comparison_source': 'independently-trusted-management-session',
            'performed_by': 'primary-platform-operator',
            'performed_at': CEREMONY.isoformat()},
        'evidence_references': [
            {'kind': kind, 'recorded_at': CEREMONY.isoformat(),
             'reference': '/etc/kyri/trust/evidence/operator-root/' + name}
            for kind, name in ROOT_EVIDENCE],
        'created_at': CEREMONY.isoformat(),
        'provenance': {'class': 'declared', 'source': 'operator-out-of-band'},
    })
    return store

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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
    store = fixture(tmp)
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
        store = fixture(tmp)
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
#
# HOST-0001 was admitted on 2026-08-25 and TREC-000001 is durable. This suite
# once rehearsed that decision against the live store and expected it to be
# accepted; it cannot be, and should not be. What is asserted here now is what
# the live store actually guarantees: the accepted decision is on record as
# ruled, replaying it is refused deterministically, and asking either question
# moves nothing.
# ===========================================================================

run_case "the accepted HOST-0001 decision is on record in the LIVE store as ruled" "${PRELUDE}
store = TrustStore.open_for_read(LIVE)
before = state(LIVE)
record = store.read('record', 'TREC-000001')
assert record['subject_id'] == 'HOST-0001', record
assert record['subject_type'] == 'fabric-node', record
assert record['state'] == 'trusted', record
assert record['decision_id'] == 'TDEC-000001', record
assert record['authority_id'] == 'TAUTH-000001', record
assert record['lineage_id'] == 'TLIN-000002', record
assert record['expiration'] is None and record['expires_at'] is None, record
scope = record['scope']
assert scope['scope_id'] == 'TSCOPE-000001', scope
assert scope['permitted_capabilities'] == ['CAPDEF-0001'], scope
assert scope['permitted_operations'] == ['execute'], scope
assert scope['permitted_data_classifications'] == ['internal'], scope
assert scope['permitted_targets'] == ['HOST-0001'], scope
decided = store.read('decision', 'TDEC-000001')
assert [e['evidence_id'] for e in decided['evidence']] == ['TEVID-000006'], decided
assert state(LIVE) == before, 'reading the live store mutated it'
print('OK')
"

# The transition table is code-owned, and 'trusted' -> 'trusted' is absent from
# it. Replaying an accepted decision is therefore refused rather than being
# quietly idempotent -- and the refusal must be a written reason, not a
# traceback, because this is the path an operator reaches by re-running a
# command they already ran.
run_case "replaying the accepted HOST-0001 request against the LIVE store is refused" "${PRELUDE}
store = TrustStore.open_for_read(LIVE)
before = state(LIVE)
try:
    with rehearsing():
        decision(store)
except TrustError as error:
    message = str(error)
    assert 'trusted' in message, message
    assert 'transition' in message, message
    assert len(message.split()) >= 5, message
else:
    raise AssertionError('the live store accepted a second trusted -> trusted decision')
assert state(LIVE) == before, 'a refused rehearsal against the live store mutated it'
print('OK')
"

run_case "the refused live replay spends no identifier and adds no object" "${PRELUDE}
store = TrustStore.open_for_read(LIVE)
sequences = {name: (Path(LIVE)/'sequences'/(name + '.seq')).read_text().strip()
             for name in ('authority', 'lineage', 'evidence', 'audit', 'record',
                          'decision', 'scope')}
counts = {kind: len(store.all_records(kind))
          for kind in ('authority', 'lineage', 'evidence', 'audit', 'record', 'decision')}
try:
    with rehearsing():
        decision(store)
except TrustError:
    pass
after_sequences = {name: (Path(LIVE)/'sequences'/(name + '.seq')).read_text().strip()
                   for name in sequences}
after_counts = {kind: len(store.all_records(kind)) for kind in counts}
assert after_sequences == sequences, (sequences, after_sequences)
assert after_counts == counts, (counts, after_counts)
print('OK')
"

run_case "the durable HOST-0001 record verifies through the Fabric adapter" "${PRELUDE}
from tools.fabric.trust_adapter import verify_trust_record
store = TrustStore.open_for_read(LIVE)
before = state(LIVE)
verdict = verify_trust_record(store, 'TREC-000001',
                              evaluated_at=datetime(2026, 8, 25, 18, 0, 0,
                                                    tzinfo=timezone.utc),
                              expected_subject_type='fabric-node')
assert verdict.status == 'verified', verdict
assert verdict.subject_id == 'HOST-0001', verdict
assert state(LIVE) == before, 'verifying the live record mutated the store'
print('OK')
"

run_case "the resulting record verifies through the Fabric adapter" "${PRELUDE}
from tools.fabric.trust_adapter import verify_trust_record
with tempfile.TemporaryDirectory() as tmp:
    store = fixture(tmp)
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
    store = fixture(tmp)
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

# A fresh store on disk holding one root establishment, for the CLI cases. The
# same shape `fixture()` builds in-process, written where a subprocess can
# reach it.
build_fixture_store() {
  (cd "${ROOT}" && python3 -c "${PRELUDE}
import sys
fixture(sys.argv[1])
print('OK')
" "$1") >/dev/null
}

assert_cli() {
  local tmp body out
  tmp="$(mktemp -d)"
  build_fixture_store "${tmp}"
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

# The same frozen body, presented to the real store through the real command.
# It must refuse, say why in words, and leave the store byte-identical.
assert_live_replay_refused() {
  local tmp out status before after
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/approved"
  cat > "${tmp}/approved/decision.json" <<'JSON'
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
  before="$(live_state "${LIVE_TRUST}")"
  status=0
  out="$(cd "${ROOT}" && python3 -m tools.trust.cli create-decision --preflight \
    --store-root "${LIVE_TRUST}" --input-file decision.json \
    --approved-directory "${tmp}/approved" 2>&1)" || status=$?
  after="$(live_state "${LIVE_TRUST}")"
  local problems=0
  (( status == 2 )) || { fail "live replay exited ${status}, expected 2"; problems=1; }
  [[ "${out}" == trust:* ]] || { fail "live replay refusal is not structured: ${out}"; problems=1; }
  [[ "${out}" == *"transition"* && "${out}" == *"trusted"* ]] \
    || { fail "live replay refusal does not name the transition: ${out}"; problems=1; }
  [[ "${out}" != *"Traceback"* ]] || { fail "live replay raised a traceback"; problems=1; }
  [[ "${before}" == "${after}" ]] || { fail "the live store moved during a refused replay"; problems=1; }
  if (( problems == 0 )); then
    pass "the CLI refuses the live replay in words and mutates nothing"
  fi
  rm -rf "${tmp}"
}
assert_live_replay_refused

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
  [[ "$(object_digests)" == "${OBJECTS_BEFORE}" ]] || { fail "a live Trust object changed"; problems=1; }
  [[ "$(sequence_values)" == "${SEQUENCES_BEFORE}" ]] || { fail "a live Trust sequence moved"; problems=1; }
  if (( problems == 0 )); then
    pass "every live Trust object and sequence is byte-identical; Fabric unchanged"
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
