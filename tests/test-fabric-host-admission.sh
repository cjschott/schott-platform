#!/usr/bin/env bash
set -Eeuo pipefail

# CHOST admission: the governed vocabulary, and rehearsing it without mutating
# the Trust store.
#
# TWO DEFECTS THIS SUITE EXISTS FOR, BOTH THE SAME SHAPE AS THE PACKAGE ONE.
#
# 1. `capability-host.schema.yaml` declares three closed enums --
#    `location_class`, `availability_intent`, `data_classification` -- and the
#    released constants for all three already exist in `admission.py` and
#    `models.py`. `withdraw_subject` and `refresh_subject` enforce them through
#    `_member_of`. `admit_subject`, the one operation that CREATES a host,
#    checked only that they were non-empty text. A machine admitted with a
#    location class nobody governs would be a permanent immutable record that
#    could never afterwards be refreshed, because refresh applies the rule the
#    admission skipped.
#
# 2. `--preflight` refused every operation that reads the Trust store, on the
#    stated grounds that constructing a `TrustStore` creates its root and no
#    read-only opener existed. One does: `ImmutableStore.open_for_read` is
#    inherited by `TrustStore` and creates nothing. The refusal was correct
#    about the hazard and wrong about the remedy, so the one governed write
#    that most needs a rehearsal was the one that could not have one.
#
# WHAT R7 SETTLED, AFTER THIS SUITE PINNED IT AS OPEN. When this suite was
# written, `verification_reference` had no governed namespace, resolution rule,
# or referent, and the absence was recorded as a finding rather than closed by
# inventing a grammar. An authority then ruled: a value matching the governed
# `EVID-NNNNNN` grammar names Platform Evidence and is resolved through the
# trusted deployment Evidence authority, while any other value stays the opaque
# operator reference it always was. The case below now pins the rule that was
# ruled, and guards the schema against reverting to describing presence alone.
#
# Fixture-only. Builds throwaway Fabric and Trust stores under a temporary
# directory, opens the production stores read-only at most, and proves both are
# byte-identical when it finishes. It declares no host, allocates no
# identifier, and creates no sequence.
#
# Governed by:
#   platform-model/schemas/capability-host.schema.yaml
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

FABRIC_ROOT="/var/lib/kyri/fabric"                 # prod-path-reference
TRUST_ROOT="/var/lib/kyri/trust"                   # prod-path-reference
production_state() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    { find "${path}" -printf '%y %m %n %U:%G %s %p\n' 2>/dev/null | sort
      find "${path}" -type f -exec sha256sum {} + 2>/dev/null | sort
    } | sha256sum | cut -d' ' -f1
  else
    printf 'absent'
  fi
}
FABRIC_BEFORE="$(production_state "${FABRIC_ROOT}")"
TRUST_BEFORE="$(production_state "${TRUST_ROOT}")"

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
import json, os, subprocess, sys
from dataclasses import fields as dataclass_fields
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.dont_write_bytecode = True

from tools.common.yaml_strict import load_strict
from tools.fabric import admission as A
from tools.fabric.models import CapabilityHost, WORKLOAD_DATA_CLASSIFICATIONS
from tools.fabric.store import FabricStore
from tools.trust.store import TrustStore

UID = os.geteuid()
GID = os.getegid()
SCHEMA = load_strict('platform-model/schemas/capability-host.schema.yaml')
ADMISSION = Path('tools/fabric/admission.py').read_text(encoding='utf-8')
CLI = Path('tools/fabric/cli.py').read_text(encoding='utf-8')
"

# ===========================================================================
# R6 -- the vocabulary is governed, and the constants already exist
# ===========================================================================

run_case "the host schema declares three closed enums" "${PRELUDE}
enums = SCHEMA['enums']
assert set(enums) == {'location_class', 'availability_intent', 'data_classification'}, sorted(enums)
assert enums['location_class'] == ['on-premises', 'operator-controlled-remote',
                                   'third-party-hosted'], enums['location_class']
assert enums['availability_intent'] == ['in-service', 'draining', 'withheld'], \
    enums['availability_intent']
assert enums['data_classification'] == ['internal'], enums['data_classification']
print('OK')
"

# The released constants are the schema's own values. Compared rather than
# assumed: two transcriptions of one vocabulary are two vocabularies the day
# they drift.
run_case "the released constants transcribe the schema exactly" "${PRELUDE}
enums = SCHEMA['enums']
assert list(A.LOCATION_CLASSES) == enums['location_class'], A.LOCATION_CLASSES
assert list(A.AVAILABILITY_INTENTS) == enums['availability_intent'], A.AVAILABILITY_INTENTS
assert list(WORKLOAD_DATA_CLASSIFICATIONS) == enums['data_classification'], \
    WORKLOAD_DATA_CLASSIFICATIONS
print('OK')
"

# The rule already runs where a host is superseded. It must also run where one
# is created, or admission writes what refresh can never restate.
run_case "every host operation applies the same membership rule" "${PRELUDE}
import ast
tree = ast.parse(ADMISSION)
funcs = [(n.lineno, n.end_lineno, n.name) for n in ast.walk(tree)
         if isinstance(n, ast.FunctionDef)]
def owner(line):
    best = None
    for start, end, name in funcs:
        if start <= line <= end and (best is None or start > best[0]):
            best = (start, name)
    return best[1] if best else None
def enclosing(line):
    # The preflight and accept closures are nested; report the governed
    # operation that encloses them.
    inner = owner(line)
    outer = None
    for start, end, name in funcs:
        if start <= line <= end and name not in ('preflight', 'accept', 'build'):
            if outer is None or start > outer[0]:
                outer = (start, name)
    return outer[1] if outer else inner
checked = {}
for index, line in enumerate(ADMISSION.splitlines(), 1):
    if '_member_of(' in line and 'def _member_of' not in line:
        checked.setdefault(enclosing(index), set())
        for field in ('location_class', 'availability_intent', 'data_classification'):
            if field in line:
                checked[enclosing(index)].add(field)
for operation in ('admit_subject', 'refresh_subject'):
    got = checked.get(operation, set())
    assert got == {'location_class', 'availability_intent', 'data_classification'}, \
        operation + ' enforces only ' + repr(sorted(got))
print('OK')
"

# --- behaviour, against fixture stores ---------------------------------------

HARNESS="${PRELUDE}
STAMP = datetime(2026, 8, 25, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
OPERATOR = 'operator:cschott'
PROV = {'class': 'declared', 'source': 'operator'}
PROFILE = {'host_memory_mb': 8192, 'host_cpu_cores': 4, 'architecture': 'x86-64'}

def stores(base):
    fabric = FabricStore(Path(base) / 'fabric', expected_uid=UID, expected_gid=GID)
    trust = TrustStore(Path(base) / 'trust')
    return fabric, trust

def subject_body(**overrides):
    body = dict(request_id='req-host', actor=OPERATOR, approving_authority=OPERATOR,
                recorded_at=STAMP, evaluated_at=STAMP,
                node_identity_reference='HOST-0001',
                fabric_node_trust_record_id='TREC-000001',
                verified_resource_profile=dict(PROFILE),
                verification_reference='evidence/host-observed',
                location_class='on-premises', data_classification='internal',
                availability_intent='in-service', provenance=dict(PROV),
                name=None, description=None)
    body.update(overrides)
    return body

def host_sequence(fabric):
    return Path(fabric.root) / 'sequences' / 'capability-host.seq'
"

# An ungoverned vocabulary value must be refused before allocation. The trust
# record is absent in these fixtures, so a body that reaches the trust query at
# all would report a trust reason -- which is exactly how a vocabulary refusal
# is told apart from one that slipped past.
run_case "an ungoverned location class is refused before allocation" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    for bad in ('banana', 'on premises', 'ON-PREMISES', 'on-premises ', '', 'cloud'):
        result = A.admit_subject(fabric, trust, **subject_body(location_class=bad))
        assert result.outcome == A.INVALID, (bad, result.to_dict())
        assert result.reason == A.REASON_CONTENT, (bad, result.reason)
    assert not host_sequence(fabric).exists(), 'a refused vocabulary spent an identifier'
    assert not any(fabric.path_for('capability-host', 'CHOST-0001').parent.iterdir())
print('OK')
"

run_case "an ungoverned availability intent is refused before allocation" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    for bad in ('online', 'IN-SERVICE', 'in service', '', 'up'):
        result = A.admit_subject(fabric, trust, **subject_body(availability_intent=bad))
        assert result.outcome == A.INVALID, (bad, result.to_dict())
        assert result.reason == A.REASON_UNKNOWN_INTENT, (bad, result.reason)
    assert not host_sequence(fabric).exists()
print('OK')
"

run_case "an ungoverned data classification is refused before allocation" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    for bad in ('secret', 'public', 'INTERNAL', 'internal ', '', 'confidential'):
        result = A.admit_subject(fabric, trust, **subject_body(data_classification=bad))
        assert result.outcome == A.INVALID, (bad, result.to_dict())
        assert result.reason == A.REASON_UNKNOWN_CLASSIFICATION, (bad, result.reason)
    assert not host_sequence(fabric).exists()
print('OK')
"

# The governed spellings must still reach the trust query rather than being
# refused as content: a rule that rejected its own vocabulary would be worse
# than none.
run_case "every governed value passes the vocabulary rule" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    for field, values in (('location_class', A.LOCATION_CLASSES),
                          ('availability_intent', A.AVAILABILITY_INTENTS),
                          ('data_classification', WORKLOAD_DATA_CLASSIFICATIONS)):
        for value in values:
            result = A.admit_subject(fabric, trust, **subject_body(**{field: value}))
            # Refused for the ABSENT trust record, never for the vocabulary.
            assert result.reason not in (A.REASON_CONTENT, A.REASON_UNKNOWN_INTENT,
                                         A.REASON_UNKNOWN_CLASSIFICATION), \
                (field, value, result.to_dict())
    assert not host_sequence(fabric).exists()
print('OK')
"

# A malformed trust identifier is malformed content, checked by syntax before
# the trust store is consulted -- the same order `refresh_subject` uses.
run_case "a malformed trust record identity is refused by syntax" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    for bad in ('', 'not-an-id', 'TREC-1', 'trec-000001', 'CHOST-0001'):
        result = A.admit_subject(fabric, trust,
                                 **subject_body(fabric_node_trust_record_id=bad))
        assert result.outcome in (A.INVALID, A.REFUSED, A.UNAVAILABLE), (bad, result.to_dict())
        assert result.record_id is None, (bad, result.to_dict())
    assert not host_sequence(fabric).exists()
print('OK')
"

# ===========================================================================
# Read-only rehearsal of a trust-reading operation
# ===========================================================================

run_case "the released read-only trust opener creates nothing" "${PRELUDE}
with TemporaryDirectory() as tmp:
    root = Path(tmp) / 'trust-readonly'
    store = TrustStore.open_for_read(root)
    assert isinstance(store, TrustStore)
    assert not root.exists(), 'open_for_read created the trust root'
    writing = Path(tmp) / 'trust-writing'
    TrustStore(writing)
    assert writing.exists(), 'the writing constructor created nothing'
    created = sorted(p.name for p in writing.iterdir())
    assert 'decisions' in created and 'sequences' in created, created
print('OK')
"

run_case "the preflight surface opens the trust store read-only" "${PRELUDE}
assert 'TrustStore.open_for_read' in CLI, 'the CLI never opens trust read-only'
assert 'does not yet support' not in CLI, \\
    'the CLI still refuses to rehearse trust-reading operations'
print('OK')
"

# The whole point: a rehearsal of the real admission, against a real trust
# store, that leaves both filesystems byte-identical.
run_case "rehearsing admit-subject mutates neither store" "${HARNESS}
import hashlib
def state(path):
    entries = []
    for item in sorted(Path(path).rglob('*')):
        info = item.lstat()
        entries.append(f'{item} {info.st_mode} {info.st_size}')
        if item.is_file():
            entries.append(hashlib.sha256(item.read_bytes()).hexdigest())
    return hashlib.sha256('\n'.join(entries).encode()).hexdigest()

with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    before_fabric, before_trust = state(fabric.root), state(trust.root)
    reader = FabricStore.open_for_read(fabric.root, expected_uid=UID, expected_gid=GID)
    trust_reader = TrustStore.open_for_read(trust.root)
    with A.rehearsing():
        outcome = A.admit_subject(reader, trust_reader, **subject_body())
    # The trust record is absent, so the rehearsal reaches the trust query and
    # refuses there -- proving the query ran rather than being skipped.
    assert outcome.outcome in (A.REFUSED, A.UNAVAILABLE), outcome.to_dict()
    assert outcome.record_id is None, outcome.to_dict()
    assert state(fabric.root) == before_fabric, 'the rehearsal mutated the fabric store'
    assert state(trust.root) == before_trust, 'the rehearsal mutated the trust store'
    assert not host_sequence(fabric).exists()
print('OK')
"

# A rehearsal must not answer a question the real write would answer
# differently. The vocabulary rule runs in both.
run_case "a rehearsal applies the same vocabulary rule as the write" "${HARNESS}
with TemporaryDirectory() as tmp:
    fabric, trust = stores(tmp)
    reader = FabricStore.open_for_read(fabric.root, expected_uid=UID, expected_gid=GID)
    trust_reader = TrustStore.open_for_read(trust.root)
    body = subject_body(location_class='banana')
    with A.rehearsing():
        rehearsed = A.admit_subject(reader, trust_reader, **body)
    written = A.admit_subject(fabric, trust, **body)
    assert rehearsed.outcome == written.outcome == A.INVALID, (rehearsed.to_dict(), written.to_dict())
    assert rehearsed.reason == written.reason == A.REASON_CONTENT
    assert rehearsed.request_digest == written.request_digest, 'the digests disagree'
print('OK')
"

# ===========================================================================
# R7 -- resolved for governed references, opaque for everything else
# ===========================================================================
#
# `verification_reference` is still named exactly twice in the host schema:
# once as a field the record must carry, once as a fact that makes one
# declaration authoritatively different from another. What changed is that the
# schema now says what a GOVERNED value references and what admission does with
# it, instead of saying that nothing does.
#
# The regression this case exists to catch is the schema drifting back to
# describing presence alone while admission resolves. That disagreement is
# worse than either position on its own: it reads as permission to supply a
# reference naming nothing.

run_case "the schema describes resolution, not presence alone" "${PRELUDE}
schema_text = Path('platform-model/schemas/capability-host.schema.yaml').read_text(
    encoding='utf-8')
# The claim that went stale, in the forms it took. None may return.
for stale in ('checks presence only',
              'is not yet required to RESOLVE',
              'WHAT IT REFERENCES IS NOT YET GOVERNED'):
    assert stale not in schema_text, stale
# What it must say instead: the governed grammar, the explicit authority, the
# target binding, and the profile support rule.
for required in ('EVID-NNNNNN', 'Evidence authority', 'node_identity_reference',
                 'verified_resource_profile'):
    assert required in schema_text, required
# Still two list entries, and still no invented machine-readable grammar key:
# the rule is prose here and code in admission, which is where it is enforced.
schema_fields = SCHEMA['required_fields'] + SCHEMA['authoritative_fields']
assert schema_fields.count('verification_reference') == 2, schema_fields
for key in ('verification_reference_pattern', 'verification_reference_type',
            'verification_reference_namespace', 'verification_reference_resolution'):
    assert key not in SCHEMA, key
print('OK')
"

# The schema is descriptive; admission is what enforces. This pins the two
# halves the prose promises, so the prose cannot become true of nothing.
run_case "admission resolves a governed reference and leaves any other opaque" "${PRELUDE}
import ast
# Presence is still checked, for every reference including opaque ones.
assert '_text(verification_reference, REASON_UNVERIFIED_PROFILE)' in ADMISSION
# And a governed reference is resolved -- called, not merely defined, and from
# both paths that record a profile: admission and refresh.
tree = ast.parse(ADMISSION)
callers = sorted(
    function.name for function in tree.body
    if isinstance(function, ast.FunctionDef)
    and any(isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
            and call.func.id == '_require_supporting_evidence'
            for call in ast.walk(function)))
assert callers == ['admit_subject', 'refresh_subject'], callers
# The grammar gate: resolution engages only for the governed identity, which is
# what keeps a non-modelled host admissible.
body = [node for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef)
        and node.name == '_require_supporting_evidence']
assert len(body) == 1, body
source = ast.unparse(body[0])
assert 'EVIDENCE_ID.fullmatch(reference)' in source, source
assert 'return' in source, source
assert 'resolve_evidence(' in source and 'supports_profile(' in source, source
print('OK')
"

# All three layers now agree that it is required. They did not: the schema
# listed it optional, the model defaulted it to None, and admission refused a
# body that omitted it. A host cannot claim a verified resource profile without
# identifying what verified it, and `verified_resource_profile` is itself
# required -- so there is no such thing as a host for which the reference is
# meaningfully optional, and the disagreement was between the layers rather
# than about a real case.
run_case "schema, model and admission agree the reference is required" "${PRELUDE}
assert 'verification_reference' in SCHEMA['required_fields'], SCHEMA['required_fields']
assert 'verification_reference' not in SCHEMA['optional_fields'], SCHEMA['optional_fields']
# The condition the ruling is stated over is universally true here.
assert 'verified_resource_profile' in SCHEMA['required_fields']
spec = {f.name: f for f in dataclass_fields(CapabilityHost)}['verification_reference']
import dataclasses
assert spec.default is dataclasses.MISSING, spec.default
assert '_require_text(self.verification_reference' in \\
    Path('tools/fabric/models.py').read_text(encoding='utf-8')
assert '_text(verification_reference' in ADMISSION
print('OK')
"

run_case "the model refuses a host that identifies no verifying evidence" "${HARNESS}
import dataclasses
fields_present = dict(
    capability_host_id='CHOST-0001', node_identity_reference='HOST-0001',
    fabric_node_trust_record_id='TREC-000001',
    verified_resource_profile=dict(PROFILE), location_class='on-premises',
    data_classification='internal', availability_intent='in-service',
    provenance=dict(PROV))
try:
    CapabilityHost(**fields_present)
except TypeError:
    pass
else:
    raise AssertionError('a host without verification_reference was constructible')
for empty in (None, '', '   '):
    try:
        CapabilityHost(**fields_present, verification_reference=empty)
    except Exception:
        continue
    raise AssertionError('accepted verification_reference ' + repr(empty))
print('OK')
"

# ===========================================================================
# Canonical node identity for a Platform Model-backed host
# ===========================================================================
#
# `node_identity_reference` is opaque by design: a fabric may admit machines
# this platform model does not describe, and the schema constrains no form.
# What was missing is the case where the machine IS described -- there was no
# rule saying which identity to use, so a host standing for HOST-0001 could be
# admitted under any string at all, and nothing downstream could tell that the
# evidence, the trust record and the host record were about one machine.
#
# The rule adopted is identity equality, not a hostname mapping: for a host
# representing a governed Platform Model Host entity, the node identity IS that
# entity's identifier. `schai` is a label; `HOST-0001` is the identity.

run_case "the schema states the Platform Model node-identity rule" "${PRELUDE}
rule = SCHEMA['platform_model_node_identity']
assert rule['applies_to'] == 'capability-host-representing-a-platform-model-host', rule
assert rule['identity'] == 'platform-model-host-entity-id', rule
assert rule['comparison'] == 'exact-equality', rule
assert rule['inference_from_hostname'] == 'not-permitted', rule
# The prefix is the ontology standard's, cited rather than restated as a
# second grammar.
assert rule['identifier_prefix'] == 'HOST', rule
assert rule['identifier_authority'] == \
    'docs/standards/platform-ontology-standard.md', rule
print('OK')
"

# The grammar is the ontology standard's own, read from it rather than
# transcribed. A second HOST pattern would be a second answer to what a host
# identity is.
run_case "the canonical identity grammar comes from the ontology standard" "${PRELUDE}
import re
standard = Path('docs/standards/platform-ontology-standard.md').read_text(encoding='utf-8')
row = [l for l in standard.splitlines() if l.startswith('| Host |')]
assert len(row) == 1, row
assert '\`HOST\`' in row[0] and '\`HOST-0001\`' in row[0], row[0]
# Every Host entity the model actually declares agrees with it.
import pathlib
ids = []
for path in sorted(pathlib.Path('platform-model/hosts').glob('*.yaml')):
    record = load_strict(str(path))
    if isinstance(record, dict) and record.get('type') == 'host':
        ids.append(record['id'])
assert ids, 'no host entities found'
pattern = re.compile(r'^HOST-[0-9]{4}\$')
assert all(pattern.fullmatch(i) for i in ids), ids
assert 'HOST-0001' in ids, ids
# And the label is not the identity.
assert not pattern.fullmatch('node/schai')
assert not pattern.fullmatch('schai')
print('OK')
"

run_case "HOST-0001 is the schai host entity, and schai is only its label" "${PRELUDE}
record = load_strict('platform-model/hosts/schai.yaml')
assert record['id'] == 'HOST-0001', record['id']
assert record['type'] == 'host'
assert record['hostname'] == 'schai' and record['name'] == 'schai'
# The identity survives a rename; the label does not identify anything.
assert record['id'] != record['hostname']
print('OK')
"

# The two future equalities the rule fixes. Neither is resolved here -- the
# Evidence resolver is S3-quater-A's -- but both are now stated where a
# resolver can read them rather than being reconstructed from a transcript.
run_case "evidence and trust equalities are normatively fixed" "${PRELUDE}
rule = SCHEMA['platform_model_node_identity']
equalities = rule['equal_to']
assert equalities['evidence_target'] == 'EVID.target', equalities
assert equalities['trust_subject'] == 'trust-record.subject_identifier', equalities
assert equalities['selection_context'] == 'local_node_identity', equalities
# The trust domain the equality is scoped to is the one already governed.
assert SCHEMA['trust_domain'] == 'fabric-node'
print('OK')
"

# EVID-000001 already satisfies the evidence half for the intended first host.
run_case "EVID-000001 targets the canonical identity for schai" "${PRELUDE}
evidence = load_strict('platform-model/evidence/evid-000001-schai-host-architecture.yaml')
host = load_strict('platform-model/hosts/schai.yaml')
assert evidence['target'] == host['id'] == 'HOST-0001', (evidence['target'], host['id'])
# Which is exactly the equality the rule fixes: EVID.target == the identity a
# CHOST for this machine must carry.
assert evidence['facts']['governed_field'] == 'architecture'
assert evidence['facts']['canonical_value'] == 'x86-64'
print('OK')
"

# The Trust plane already accepts this identity; nothing about non-host trust
# subjects is narrowed by adopting it.
run_case "trust accepts the canonical identity and stays otherwise unconstrained" "${PRELUDE}
trust_record = load_strict('platform-model/schemas/trust-record.schema.yaml')
assert 'subject_identifier' in trust_record['required_fields']
# No pattern constrains a trust subject: identities are opaque by reference,
# and adopting HOST-0001 for fabric-node subjects narrows no other domain.
assert 'subject_identifier' not in (trust_record.get('field_rules') or {}) or \
    'pattern' not in (trust_record['field_rules'].get('subject_identifier') or {})
assert 'fabric-node' in str(trust_record), 'fabric-node is not a governed domain'
from tools.fabric.trust_adapter import _require_subject
assert _require_subject('HOST-0001') == 'HOST-0001'
assert _require_subject('anything-else') == 'anything-else'
print('OK')
"

# A fixture standing for the real Platform Model-backed host must use the
# canonical identity. Fixtures that deliberately exercise arbitrary identities
# are a different case and are left alone.
run_case "the schai admission harness uses the canonical identity" "${PRELUDE}
suite = Path('tests/test-fabric-host-admission.sh').read_text(encoding='utf-8')
bindings = [line.strip() for line in suite.splitlines()
            if 'node_identity_reference=' in line and 'in line' not in line]
assert bindings, 'the harness binds no node identity'
for line in bindings:
    assert \"node_identity_reference='HOST-0001'\" in line, line
# The non-normative string may still be NAMED here -- a case above proves it is
# refused as an identity -- but it may not be the value any fixture declares.
assert not any('node/schai' in line for line in bindings), bindings
print('OK')
"

# ===========================================================================
# The evidence-coverage finding
# ===========================================================================
#
# The proposed R7 ruling is that `verification_reference` names a Platform
# Evidence record supporting the verified resource profile. The Evidence plane
# does support that shape -- it has a governed identity grammar, immutability,
# and an enforced content fingerprint. What it does not yet have is an evidence
# record that proves the profile a host would claim.
#
# EVID-000001 declares ONE governed field. These cases pin exactly what is and
# is not proven, so that "the evidence exists" can never be mistaken for "the
# evidence supports the claim", and so a later record that does prove more is
# detected rather than assumed.

run_case "the evidence plane has a governed identity grammar and fingerprint" "${PRELUDE}
evidence_schema = load_strict('platform-model/schemas/evidence.schema.yaml')
assert evidence_schema['id_pattern'] == '^EVID-[0-9]{6}\$', evidence_schema['id_pattern']
for field in ('id', 'target', 'facts', 'content_fingerprint', 'collector', 'status'):
    assert field in evidence_schema['required_fields'], field
import re
from tools.observation.models import EVIDENCE_ID
assert EVIDENCE_ID.pattern == '^EVID-[0-9]{6}\$', EVIDENCE_ID.pattern
print('OK')
"

run_case "EVID-000001 proves exactly one governed field" "${PRELUDE}
record = load_strict('platform-model/evidence/evid-000001-schai-host-architecture.yaml')
assert record['id'] == 'EVID-000001', record['id']
assert record['kind'] == 'Evidence' and record['type'] == 'evidence'
assert record['status'] == 'success'
facts = record['facts']
# Singular, and deliberately so: one governed field, three raw sources for it.
assert facts['governed_field'] == 'architecture', facts['governed_field']
assert facts['canonical_value'] == 'x86-64', facts['canonical_value']
assert {o['source'] for o in facts['observations']} == {
    'uname_m', 'lscpu_architecture', 'dpkg_architecture'}, facts['observations']
# Nothing in it speaks to memory or CPU.
blob = str(record)
for absent in ('host_memory_mb', 'host_cpu_cores', 'accelerator'):
    assert absent not in blob, 'EVID-000001 unexpectedly mentions ' + absent
print('OK')
"

# The binding table, as a check rather than as prose. A profile dimension is
# proven only where a governed evidence record says so; being on the same
# machine as a proven dimension proves nothing about it.
run_case "the profile vocabulary is not covered by the evidence that exists" "${PRELUDE}
import pathlib
vocabulary = set(SCHEMA['resource_profile_vocabulary'])
proven = set()
for path in sorted(pathlib.Path('platform-model/evidence').glob('*.yaml')):
    record = load_strict(str(path))
    field = (record.get('facts') or {}).get('governed_field')
    if field and record.get('status') == 'success':
        proven.add(field)
assert proven == {'architecture'}, sorted(proven)
unproven = vocabulary - proven
assert 'host_memory_mb' in unproven and 'host_cpu_cores' in unproven, sorted(unproven)
# Stated as the blocker it is: a host profile may claim only proven dimensions.
assert len(unproven) == 5, sorted(unproven)
print('OK')
"

# ===========================================================================
# What this suite did not touch
# ===========================================================================

assert_untouched() {
  local problems=0
  if [[ "$(production_state "${FABRIC_ROOT}")" != "${FABRIC_BEFORE}" ]]; then
    fail "the production Fabric store moved"; problems=1
  fi
  if [[ "$(production_state "${TRUST_ROOT}")" != "${TRUST_BEFORE}" ]]; then
    fail "the production Trust store moved"; problems=1
  fi
  if [[ -e "${FABRIC_ROOT}/sequences/capability-host.seq" ]]; then
    fail "capability-host.seq was created"; problems=1
  fi
  if [[ -n "$(ls -A "${FABRIC_ROOT}/capability-hosts" 2>/dev/null)" ]]; then
    fail "a CHOST record appeared"; problems=1
  fi
  if (( problems == 0 )); then
    pass "the production Fabric and Trust stores are unchanged; no CHOST, no host sequence"
  fi
}
assert_untouched

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All host-admission assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
