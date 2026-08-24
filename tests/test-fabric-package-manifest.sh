#!/usr/bin/env bash
set -Eeuo pipefail

# `manifest_reference`, from the approved decision body to the staged tree.
#
# THE CONTRADICTION THIS SUITE EXISTS FOR. Four committed authorities agree
# that a capability package carries a `manifest_reference`:
#
#   tools/fabric/models.py             CapabilityPackage declares the field
#   platform-model/…/capability-package.schema.yaml   lists it as optional
#   tools/capability/fabric_evidence.py               reads it off the record
#   tools/capability/package_resolution.py            refuses without it
#
# and one -- `tools/fabric/admission.py declare_package` -- cannot receive it.
# The CLI splats the approved decision body straight into the operation, so a
# body carrying the field is an unusable invocation and a body omitting it
# produces a permanent, immutable record that the released resolver can never
# stage. Every package the governed admission API could produce was therefore
# unresolvable, and no test said so.
#
# WHAT IS *NOT* CHANGED, AND WHY. Design §8 rules the split deliberately:
# "MUST NOT execute a `CPKG` carrying no `manifest_reference`. `CPKG` makes it
# optional; execution does not." So the schema keeps the field optional, the
# resolver keeps refusing its absence, and the correction is confined to the
# one surface that could not express what the other four already agreed on.
#
# WHAT THIS SUITE DOES. Builds throwaway Fabric stores, artifact roots and
# staging roots under a temporary directory, drives the real released CLI and
# admission path, and stages a real tree. It touches no production store, opens
# no governance path, allocates no production identifier, contacts no container
# runtime, and reads the repository's committed verification package only to
# copy it into a fixture.
#
# Governed by:
#   docs/superpowers/specs/2026-08-10-capability-runtime-design.md  (§7, §8)
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

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
import inspect, json, os, shutil, subprocess, sys
from dataclasses import fields as dataclass_fields
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.dont_write_bytecode = True

from tools.fabric import admission as A
from tools.fabric.models import CapabilityPackage, RECORD_MODELS
from tools.fabric.store import FabricStore
from tools.fabric.inspection import inspect_records
from tools.capability import fabric_evidence as FE
from tools.capability import package_resolution as PR
from tools.fabric.inspection import STATUS_REPORTED

UID = os.geteuid()
GID = os.getegid()
STAMP = datetime(2026, 8, 24, 9, 0, 0, tzinfo=timezone(timedelta(hours=-5)))
OPERATOR = 'operator:cschott'
PROV = {'class': 'declared', 'source': 'operator'}

REQUEST_SHAPE = {'authority': 'tools/capability/execution/payload.py',
                 'schema': 'kyri-execution-payload', 'schema_version': 1}
RESPONSE_SHAPE = {
    'envelope': {'authority': 'tools/capability/execution/collector.py',
                 'schema': 'kyri-execution-result-envelope',
                 'schema_version': 1},
    'content': {'authority': 'tools/capability/execution/result_content.py',
                'schema': 'kyri-execution-verification-result',
                'schema_version': 1},
}

TREE_RELATIVE = 'verified/1.0.0'
TREE_REFERENCE = 'tree:' + TREE_RELATIVE
MANIFEST_RELATIVE = 'verified/1.0.0.manifest.json'
MANIFEST_REFERENCE = 'file:' + MANIFEST_RELATIVE
COMMITTED_TREE = 'packages/kyri-execution-boundary-verification/1.0.0'


def store_at(base):
    return FabricStore(Path(base) / 'fabric', expected_uid=UID, expected_gid=GID)


def seed(store):
    '''One capability and one contract, so a package has something to name.'''
    cap = A.declare_capability(
        store, request_id='req-cap', actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        name='kyri-execution-boundary-verification', description='fixture',
        effect_class='computational', contract_ids=(), provenance=dict(PROV))
    assert cap.outcome == A.ACCEPTED, cap.to_dict()
    con = A.declare_contract(
        store, request_id='req-con', actor=OPERATOR,
        approving_authority=OPERATOR, recorded_at=STAMP,
        capability_id=cap.record_id, contract_version='1.0.0',
        effect_class='computational', determinism_class='deterministic',
        request_shape=dict(REQUEST_SHAPE), response_shape=dict(RESPONSE_SHAPE),
        failure_modes=('adapter-error',), resource_requirements={},
        compatible_with=(), provenance=dict(PROV), description='fixture')
    assert con.outcome == A.ACCEPTED, con.to_dict()
    return cap.record_id, con.record_id


def package_body(capability_id, contract_id, request_id='req-pkg', **overrides):
    body = dict(request_id=request_id, actor=OPERATOR,
                approving_authority=OPERATOR, recorded_at=STAMP,
                capability_id=capability_id, contract_id=contract_id,
                satisfied_contract_versions=('1.0.0',), package_version='1.0.0',
                artifact_reference=TREE_REFERENCE, resource_requirements={},
                trust_domain='capability-package', provenance=dict(PROV),
                description='fixture')
    body.update(overrides)
    return body


def stored(store, identifier):
    '''The durable record as it was written, read back off the disk.'''
    assert store.path_for('capability-package', identifier).exists()
    report = inspect_records(store.root, expected_uid=UID, expected_gid=GID,
                             kind='capability-package', identifier=identifier)
    assert report.status == STATUS_REPORTED, report
    assert len(report.records) == 1, report.records
    return report.records[0]


def artifact_root(base, *, manifest=None, tree_source=None):
    '''A trusted artifact root holding the tree and, beside it, the manifest.'''
    root = Path(base) / 'approved-artifacts'
    (root / 'verified').mkdir(mode=0o755, parents=True)
    # Set after creation, not trusted to mkdir: parents=True applies the
    # process umask, and a group-writable component is a component someone else
    # can swap -- which the trusted-source primitive refuses, correctly.
    os.chmod(base, 0o755)
    os.chmod(root, 0o755)
    os.chmod(root / 'verified', 0o755)
    shutil.copytree(tree_source or (Path('${ROOT}') / COMMITTED_TREE),
                    root / TREE_RELATIVE)
    for path in sorted((root / TREE_RELATIVE).rglob('*')):
        os.chmod(path, 0o644 if path.is_file() else 0o755)
    os.chmod(root / TREE_RELATIVE, 0o755)
    if manifest is not None:
        (root / MANIFEST_RELATIVE).write_text(json.dumps(manifest),
                                              encoding='utf-8')
        os.chmod(root / MANIFEST_RELATIVE, 0o644)
    return root


def commitment(tree):
    from tools.capability.execution.package_contract import inspect_package
    handle = os.open(tree, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                     | os.O_DIRECTORY)
    try:
        return 'sha256:' + inspect_package(handle).digest
    finally:
        os.close(handle)


def staging_root(base):
    root = Path(base) / 'staging'
    root.mkdir(mode=0o700)
    return root


class Evidence:
    '''Exactly what fabric_evidence hands the resolver, and nothing more.'''

    def __init__(self, record, **overrides):
        self.capability_package_id = record.get('capability_package_id')
        self.contract_id = record.get('contract_id')
        self.capability_id = record.get('capability_id')
        self.artifact_reference = record.get('artifact_reference')
        self.manifest_reference = record.get('manifest_reference')
        for name, value in overrides.items():
            setattr(self, name, value)
"

# ===========================================================================
# 1-3. What the other four authorities already agree on
# ===========================================================================

run_case "CapabilityPackage declares manifest_reference" "${PRELUDE}
names = {spec.name for spec in dataclass_fields(CapabilityPackage)}
assert 'manifest_reference' in names, sorted(names)
assert RECORD_MODELS['capability-package'] is CapabilityPackage
print('OK')
"

run_case "package resolution requires manifest_reference and refuses its absence" "${PRELUDE}
with TemporaryDirectory() as tmp:
    record = {'capability_package_id': 'CPKG-0001', 'contract_id': 'CCON-0001',
              'capability_id': 'CAPDEF-0001',
              'artifact_reference': TREE_REFERENCE}
    outcome = PR.resolve_and_stage_package(
        evidence=Evidence(record), approved_artifact_root=artifact_root(tmp),
        trusted_source_uid=UID, staging_root=staging_root(tmp),
        coordinator_uid=UID)
assert outcome.supported is False, outcome
assert outcome.reason == PR.REASON_MANIFEST_ABSENT, outcome.reason
assert outcome.reason == 'manifest-reference-absent', outcome.reason
print('OK')
"

run_case "fabric evidence consumes manifest_reference off the record" "${PRELUDE}
names = {spec.name for spec in dataclass_fields(FE.EvidenceVerdict)}
assert 'manifest_reference' in names, sorted(names)
source = Path('tools/capability/fabric_evidence.py').read_text(encoding='utf-8')
assert 'manifest_reference=_text(package, \"manifest_reference\")' in source, \
    'the evidence verdict no longer reads the field off the package record'
print('OK')
"

# ===========================================================================
# 4-5. The surface that could not express it, and what that cost
# ===========================================================================

run_case "declare_package can receive manifest_reference" "${PRELUDE}
signature = inspect.signature(A.declare_package)
assert 'manifest_reference' in signature.parameters, sorted(signature.parameters)
parameter = signature.parameters['manifest_reference']
assert parameter.kind is inspect.Parameter.KEYWORD_ONLY, parameter.kind
assert parameter.default is None, parameter.default
print('OK')
"

run_case "an approved decision body carrying manifest_reference is accepted" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id, manifest_reference=MANIFEST_REFERENCE))
assert result.outcome == A.ACCEPTED, result.to_dict()
assert result.record_id == 'CPKG-0001', result.record_id
print('OK')
"

run_case "the field reaches the durable record and survives read-back" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id, manifest_reference=MANIFEST_REFERENCE))
    written = store.path_for('capability-package', result.record_id).read_text(
        encoding='utf-8')
    record = stored(store, result.record_id)
    reconstructed = CapabilityPackage.from_dict(dict(record))
assert 'manifest_reference: ' + MANIFEST_REFERENCE in written, written
assert record['manifest_reference'] == MANIFEST_REFERENCE, record
assert reconstructed.manifest_reference == MANIFEST_REFERENCE
print('OK')
"

# ===========================================================================
# The whole thread: body -> CLI -> admission -> record -> evidence -> staging
# ===========================================================================
# Driven through the released CLI as an operator drives it, not by calling the
# admission function directly: the approved-directory reader and the body splat
# are part of the surface that was broken.

run_case "the released CLI carries the field from an approved decision body" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    approved = Path(tmp) / 'approved'
    approved.mkdir(mode=0o755)
    body = package_body(capability_id, contract_id,
                        request_id='req-cli-pkg',
                        manifest_reference=MANIFEST_REFERENCE)
    body['recorded_at'] = STAMP.isoformat()
    body['satisfied_contract_versions'] = list(body['satisfied_contract_versions'])
    (approved / 'cpkg.json').write_text(json.dumps(body), encoding='utf-8')

    argv = ['-m', 'tools.fabric.cli', 'declare-package',
            '--store-root', str(store.root), '--expected-uid', str(UID),
            '--expected-gid', str(GID), '--input-file', 'cpkg.json',
            '--approved-directory', str(approved)]
    rehearsal = subprocess.run([sys.executable] + argv + ['--preflight'],
                               capture_output=True, text=True, check=False)
    assert rehearsal.returncode == 0, rehearsal.stdout + rehearsal.stderr
    predicted = json.loads(rehearsal.stdout)
    assert predicted['would_accept'] is True, predicted
    assert predicted['mutated'] is False, predicted
    assert predicted['predicted_record_id'] == 'CPKG-0001', predicted

    written = subprocess.run([sys.executable] + argv, capture_output=True,
                             text=True, check=False)
    assert written.returncode == 0, written.stdout + written.stderr
    accepted = json.loads(written.stdout)
assert accepted['outcome'] == 'accepted', accepted
assert accepted['record_id'] == predicted['predicted_record_id'], accepted
assert accepted['request_digest'] == predicted['request_digest'], accepted
print('OK')
"

run_case "a package declared with a manifest stages through the released resolver" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    root = artifact_root(tmp)
    digest = commitment(root / TREE_RELATIVE)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id, manifest_reference=MANIFEST_REFERENCE))
    record = stored(store, result.record_id)
    (root / MANIFEST_RELATIVE).write_text(json.dumps({
        'schema_version': PR.MANIFEST_SCHEMA_VERSION,
        'capability_package_id': record['capability_package_id'],
        'contract_id': record['contract_id'],
        'capability_id': record['capability_id'],
        'artifact_reference': record['artifact_reference'],
        'package_tree_sha256': digest}), encoding='utf-8')
    os.chmod(root / MANIFEST_RELATIVE, 0o644)
    outcome = PR.resolve_and_stage_package(
        evidence=Evidence(record), approved_artifact_root=root,
        trusted_source_uid=UID, staging_root=staging_root(tmp),
        coordinator_uid=UID)
    assert outcome.supported is True, outcome
    assert outcome.reason is None, outcome.reason
    assert outcome.package_tree_sha256 == digest, outcome.package_tree_sha256
    assert outcome.capability_package_id == record['capability_package_id']
    assert Path(outcome.staged_path).is_dir(), outcome.staged_path
print('OK')
"

# ===========================================================================
# Fail-closed: nothing defaulted, inferred, fabricated, or silently omitted
# ===========================================================================

# The design rules the split: the record may omit it, execution may not. So a
# package declared without one is still accepted and still unstageable, and
# neither the record nor the resolver pretends otherwise.
run_case "an omitted manifest is absent from the record, not written as null" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    result = A.declare_package(store, **package_body(capability_id, contract_id))
    assert result.outcome == A.ACCEPTED, result.to_dict()
    written = store.path_for('capability-package', result.record_id).read_text(
        encoding='utf-8')
    record = stored(store, result.record_id)
    assert 'manifest_reference' not in written, written
    assert 'manifest_reference' not in record, sorted(record)
    outcome = PR.resolve_and_stage_package(
        evidence=Evidence(record), approved_artifact_root=artifact_root(tmp),
        trusted_source_uid=UID, staging_root=staging_root(tmp),
        coordinator_uid=UID)
assert outcome.reason == PR.REASON_MANIFEST_ABSENT, outcome.reason
print('OK')
"

# The reference is carried, never composed. Checked over the module's string
# literals rather than its raw text, because 'verified_resource_profile: Any'
# contains 'file:' and a text scan would report the parameter list as a forgery.
run_case "admission never synthesises a manifest reference" "${PRELUDE}
import ast
tree = ast.parse(Path('tools/fabric/admission.py').read_text(encoding='utf-8'))
for node in ast.walk(tree):
    if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
        continue
    for scheme in ('file:', 'tree:'):
        assert not node.value.startswith(scheme), \
            'admission composes a reference literal: ' + node.value
    for fragment in ('.manifest', 'manifest.json'):
        assert fragment not in node.value, \
            'admission names a manifest artefact: ' + node.value
print('OK')
"

run_case "a supplied manifest reference that is not text is refused" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    for bad in ('', '   ', 0, 1, True, False, [], {}, ('file:m.json',)):
        result = A.declare_package(store, **package_body(
            capability_id, contract_id, request_id='req-bad',
            manifest_reference=bad))
        assert result.outcome == A.INVALID, (bad, result.to_dict())
        assert result.reason == A.REASON_CONTENT, (bad, result.reason)
    assert store.peek_next_id('capability-package') == 'CPKG-0001', \
        'a refused declaration spent an identifier'
    assert not any(store.path_for('capability-package', 'CPKG-0001').parent.iterdir())
print('OK')
"

# The digest covers every authoritative input, including the ones supplied as
# nothing. Two requests that differ only in the manifest are different requests.
run_case "the manifest reference participates in the request digest" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    without = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-a'))
    with_one = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-b',
        manifest_reference=MANIFEST_REFERENCE))
    other = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-c',
        manifest_reference='file:verified/other.manifest.json'))
digests = {without.request_digest, with_one.request_digest, other.request_digest}
assert len(digests) == 3, digests
print('OK')
"

run_case "reusing a request identity with a changed manifest conflicts" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    first = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-same',
        manifest_reference=MANIFEST_REFERENCE))
    assert first.outcome == A.ACCEPTED, first.to_dict()
    replay = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-same',
        manifest_reference=MANIFEST_REFERENCE))
    assert replay.outcome == A.EXACT_REPLAY, replay.to_dict()
    assert replay.record_id == first.record_id, replay.to_dict()
    changed = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-same',
        manifest_reference='file:verified/other.manifest.json'))
    assert changed.outcome == A.CONFLICT, changed.to_dict()
    assert store.peek_next_id('capability-package') == 'CPKG-0002', \
        'the conflict spent an identifier'
print('OK')
"

# ===========================================================================
# The identifier / manifest ordering the ceremony needs
# ===========================================================================
# The manifest must name the CPKG identity, and the CPKG record must name the
# manifest. Neither can be authored after the other unless the identifier can
# be predicted before it is spent. The released preflight predicts it, reading
# only -- and the prediction is proven against what allocation actually handed
# out, because prediction is not reservation.

run_case "the next identifier is predictable read-only and matches allocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    predicted = reader.peek_next_id('capability-package')
    assert predicted == 'CPKG-0001', predicted
    sequences = Path(store.root) / 'sequences'
    assert not (sequences / 'capability-package.seq').exists(), \
        'peeking created the sequence'
    again = reader.peek_next_id('capability-package')
    assert again == predicted, (predicted, again)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id,
        manifest_reference='file:verified/' + predicted + '.manifest.json'))
    assert result.record_id == predicted, (predicted, result.record_id)
    assert (sequences / 'capability-package.seq').read_text().strip() == '1'
print('OK')
"

run_case "a rehearsal predicts and refuses to spend the sequence" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    with A.rehearsing():
        outcome = A.declare_package(reader, **package_body(
            capability_id, contract_id,
            manifest_reference=MANIFEST_REFERENCE))
    assert outcome.outcome == A.PREFLIGHT, outcome.to_dict()
    assert outcome.record_id is None, outcome.to_dict()
    assert not (Path(store.root) / 'sequences'
                / 'capability-package.seq').exists(), 'the rehearsal allocated'
    assert not any(store.path_for('capability-package', 'CPKG-0001').parent.iterdir())
print('OK')
"

# A manifest naming an identifier the write did not hand out fails closed at
# resolution rather than being repaired, which is what makes a wrong prediction
# a wasted identifier and never a wrong execution.
run_case "a manifest naming another identifier is refused at resolution" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    root = artifact_root(tmp)
    digest = commitment(root / TREE_RELATIVE)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id, manifest_reference=MANIFEST_REFERENCE))
    record = stored(store, result.record_id)
    (root / MANIFEST_RELATIVE).write_text(json.dumps({
        'schema_version': PR.MANIFEST_SCHEMA_VERSION,
        'capability_package_id': 'CPKG-0009',
        'contract_id': record['contract_id'],
        'capability_id': record['capability_id'],
        'artifact_reference': record['artifact_reference'],
        'package_tree_sha256': digest}), encoding='utf-8')
    os.chmod(root / MANIFEST_RELATIVE, 0o644)
    outcome = PR.resolve_and_stage_package(
        evidence=Evidence(record), approved_artifact_root=root,
        trusted_source_uid=UID, staging_root=staging_root(tmp),
        coordinator_uid=UID)
assert outcome.supported is False, outcome
assert outcome.reason == PR.REASON_MANIFEST_IDENTITY, outcome.reason
print('OK')
"

# ===========================================================================
# The predicted-identity precondition
# ===========================================================================
# Prediction is not reservation, so between the peek and the write another
# caller may take the identifier the frozen manifest names. Declaration must
# refuse at the protected allocation boundary rather than write an immutable
# record that references a manifest for a different package -- a contradiction
# staging would find, but only after the record exists for ever.
#
# The field is a PRECONDITION, not an assignment. It does not name the record,
# does not reserve anything, and is never inferred from `manifest_reference`:
# admission opens no file and parses no manifest, so it cannot know what a
# manifest claims. The store stays the sole allocator.

run_case "declare_package can receive an expected package identity" "${PRELUDE}
signature = inspect.signature(A.declare_package)
parameter = signature.parameters.get('expected_capability_package_id')
assert parameter is not None, sorted(signature.parameters)
assert parameter.kind is inspect.Parameter.KEYWORD_ONLY, parameter.kind
assert parameter.default is None, parameter.default
print('OK')
"

run_case "a matching expectation is accepted and allocates exactly it" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    predicted = reader.peek_next_id('capability-package')
    result = A.declare_package(store, **package_body(
        capability_id, contract_id, manifest_reference=MANIFEST_REFERENCE,
        expected_capability_package_id=predicted))
    assert result.outcome == A.ACCEPTED, result.to_dict()
    assert result.record_id == predicted, (predicted, result.record_id)
    record = stored(store, result.record_id)
    assert record['capability_package_id'] == predicted, record
print('OK')
"

# The race, driven as two real declarations against one store rather than by
# editing the sequence: the second caller is what makes the first caller's
# prediction stale, and that is the condition being tested.
run_case "a prediction another writer consumed refuses before allocation" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    predicted = reader.peek_next_id('capability-package')

    # Another writer takes it first.
    stolen = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-other-writer'))
    assert stolen.outcome == A.ACCEPTED, stolen.to_dict()
    assert stolen.record_id == predicted, stolen.to_dict()

    sequence = Path(store.root) / 'sequences' / 'capability-package.seq'
    before = sequence.read_text(encoding='utf-8')
    ours = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-ours',
        manifest_reference=MANIFEST_REFERENCE,
        expected_capability_package_id=predicted))

    assert ours.outcome == A.REFUSED, ours.to_dict()
    assert ours.reason == 'predicted-identity-moved', ours.reason
    assert ours.reason == A.REASON_PREDICTED_IDENTITY, ours.reason
    assert ours.record_id is None, ours.to_dict()
    # Nothing spent and nothing written: the refusal happens at the boundary,
    # not after it.
    assert sequence.read_text(encoding='utf-8') == before, 'the sequence moved'
    assert reader.peek_next_id('capability-package') == 'CPKG-0002'
    assert not store.path_for('capability-package', 'CPKG-0002').exists()
    written = sorted(p.name for p in
                     store.path_for('capability-package', 'CPKG-0001').parent.iterdir())
    assert written == ['CPKG-0001.yaml'], written
print('OK')
"

# The refusal is about the caller's expectation, never about a manifest:
# admission cannot inspect one, so it must not name one.
run_case "the refusal reason names the prediction, not the manifest" "${PRELUDE}
assert A.REASON_PREDICTED_IDENTITY == 'predicted-identity-moved', \
    A.REASON_PREDICTED_IDENTITY
assert 'manifest' not in A.REASON_PREDICTED_IDENTITY
assert A.REASON_PREDICTED_IDENTITY != PR.REASON_MANIFEST_IDENTITY
print('OK')
"

run_case "a malformed expected identity refuses without allocating" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    sequence = Path(store.root) / 'sequences' / 'capability-package.seq'
    for bad in ('', 'CPKG-1', 'CPKG-00001', 'cpkg-0001', 'CPKG0001',
                'CCON-0001', 'CAPDEF-0001', ' CPKG-0001', 'CPKG-0001 ',
                0, 1, True, [], {}):
        result = A.declare_package(store, **package_body(
            capability_id, contract_id, request_id='req-bad',
            expected_capability_package_id=bad))
        assert result.outcome == A.INVALID, (bad, result.to_dict())
        assert result.reason == A.REASON_CONTENT, (bad, result.reason)
        assert not sequence.exists(), 'a malformed expectation spent an identifier'
    assert store.peek_next_id('capability-package') == 'CPKG-0001'
print('OK')
"

run_case "an omitted expectation preserves the existing generic behaviour" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    first = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-one'))
    second = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-two'))
    assert first.outcome == A.ACCEPTED and first.record_id == 'CPKG-0001'
    assert second.outcome == A.ACCEPTED and second.record_id == 'CPKG-0002'
    record = stored(store, second.record_id)
    assert 'expected_capability_package_id' not in record, sorted(record)
print('OK')
"

# A precondition is not record content. It governed whether the write happened;
# it is not something the package claims about itself afterwards.
run_case "the expectation is never written into the record" "${PRELUDE}
names = {spec.name for spec in dataclass_fields(CapabilityPackage)}
assert 'expected_capability_package_id' not in names, sorted(names)
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    result = A.declare_package(store, **package_body(
        capability_id, contract_id,
        expected_capability_package_id='CPKG-0001'))
    written = store.path_for('capability-package', result.record_id).read_text(
        encoding='utf-8')
assert 'expected_capability_package_id' not in written, written
print('OK')
"

run_case "the expectation participates in the request digest" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    without = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-a'))
    with_one = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-b',
        expected_capability_package_id='CPKG-0002'))
    other = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-c',
        expected_capability_package_id='CPKG-0003'))
assert with_one.outcome == A.ACCEPTED, with_one.to_dict()
assert other.outcome == A.ACCEPTED, other.to_dict()
digests = {without.request_digest, with_one.request_digest, other.request_digest}
assert len(digests) == 3, digests
print('OK')
"

run_case "an identical resubmission is still an exact replay" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    body = package_body(capability_id, contract_id, request_id='req-same',
                        manifest_reference=MANIFEST_REFERENCE,
                        expected_capability_package_id='CPKG-0001')
    first = A.declare_package(store, **body)
    assert first.outcome == A.ACCEPTED, first.to_dict()
    assert first.record_id == 'CPKG-0001', first.to_dict()
    again = A.declare_package(store, **dict(body))
    assert again.outcome == A.EXACT_REPLAY, again.to_dict()
    assert again.record_id == first.record_id, again.to_dict()
    assert again.request_digest == first.request_digest, again.to_dict()
    assert store.peek_next_id('capability-package') == 'CPKG-0002', \
        'the replay allocated'
print('OK')
"

# The expectation is never silently refreshed. Reusing one request identity
# with a different expectation is a different request, and says so.
run_case "the same request identity with a changed expectation conflicts" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    first = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-same',
        expected_capability_package_id='CPKG-0001'))
    assert first.outcome == A.ACCEPTED, first.to_dict()
    changed = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-same',
        expected_capability_package_id='CPKG-0002'))
assert changed.outcome == A.CONFLICT, changed.to_dict()
assert changed.reason == A.REASON_CONFLICT, changed.reason
print('OK')
"

# After losing a race the operator re-freezes against the new prediction and
# submits it as a new request. That is a fresh declaration, not a rewrite.
run_case "a refreshed expectation under a new request identity is evaluated afresh" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    predicted = reader.peek_next_id('capability-package')
    A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-other-writer'))
    lost = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-first-attempt',
        expected_capability_package_id=predicted))
    assert lost.outcome == A.REFUSED, lost.to_dict()

    refreshed = reader.peek_next_id('capability-package')
    assert refreshed != predicted, (predicted, refreshed)
    retried = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-second-attempt',
        expected_capability_package_id=refreshed))
    assert retried.outcome == A.ACCEPTED, retried.to_dict()
    assert retried.record_id == refreshed, retried.to_dict()
    assert retried.request_digest != lost.request_digest
print('OK')
"

# A rehearsal answers the same question without spending anything, so an
# operator can see a stale prediction before submitting the real write.
run_case "a rehearsal reports a stale prediction and allocates nothing" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-other-writer'))
    reader = FabricStore.open_for_read(store.root, expected_uid=UID,
                                       expected_gid=GID)
    sequence = Path(store.root) / 'sequences' / 'capability-package.seq'
    before = sequence.read_text(encoding='utf-8')
    with A.rehearsing():
        stale = A.declare_package(reader, **package_body(
            capability_id, contract_id, request_id='req-rehearsal',
            expected_capability_package_id='CPKG-0001'))
        fresh = A.declare_package(reader, **package_body(
            capability_id, contract_id, request_id='req-rehearsal',
            expected_capability_package_id='CPKG-0002'))
    assert stale.outcome == A.REFUSED, stale.to_dict()
    assert stale.reason == A.REASON_PREDICTED_IDENTITY, stale.reason
    assert fresh.outcome == A.PREFLIGHT, fresh.to_dict()
    assert fresh.record_id is None, fresh.to_dict()
    assert sequence.read_text(encoding='utf-8') == before, 'the rehearsal allocated'
print('OK')
"

# Nothing about the manifest reaches this decision. Admission opens no file,
# so it cannot read a manifest, and it must not appear to have.
run_case "admission opens nothing and infers no manifest identity" "${PRELUDE}
import ast
source = Path('tools/fabric/admission.py').read_text(encoding='utf-8')
tree = ast.parse(source)
opened = []
for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        name = node.func.attr if isinstance(node.func, ast.Attribute) else (
            node.func.id if isinstance(node.func, ast.Name) else None)
        if name in ('open', 'fdopen', 'read_text', 'read_bytes', 'loads',
                    'load', 'listdir', 'scandir', 'glob', 'rglob'):
            opened.append(name)
assert not opened, 'admission reads: ' + ', '.join(sorted(set(opened)))
for module in ('json', 'pathlib', 'os', 'io'):
    assert not any(
        (isinstance(n, ast.Import) and any(a.name.split('.')[0] == module
                                           for a in n.names))
        or (isinstance(n, ast.ImportFrom) and (n.module or '').split('.')[0] == module)
        for n in ast.walk(tree)), 'admission imports ' + module
print('OK')
"

run_case "the expectation is never derived from the manifest reference" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    # A manifest reference whose spelling names CPKG-0009 changes nothing:
    # the expectation is what the caller stated, and only that.
    result = A.declare_package(store, **package_body(
        capability_id, contract_id,
        manifest_reference='file:verified/CPKG-0009.manifest.json',
        expected_capability_package_id='CPKG-0001'))
    assert result.outcome == A.ACCEPTED, result.to_dict()
    assert result.record_id == 'CPKG-0001', result.to_dict()
    record = stored(store, result.record_id)
    assert record['manifest_reference'] == 'file:verified/CPKG-0009.manifest.json'
print('OK')
"

# Nothing is held between the peek and the write. Two peeks with no write in
# between still report the same identifier, and it is still available.
run_case "an expectation reserves nothing" "${PRELUDE}
with TemporaryDirectory() as tmp:
    store = store_at(tmp)
    capability_id, contract_id = seed(store)
    with A.rehearsing():
        rehearsed = A.declare_package(
            FabricStore.open_for_read(store.root, expected_uid=UID,
                                      expected_gid=GID),
            **package_body(capability_id, contract_id,
                           request_id='req-rehearsal',
                           expected_capability_package_id='CPKG-0001'))
    assert rehearsed.outcome == A.PREFLIGHT, rehearsed.to_dict()
    # A different caller, naming no expectation, still gets CPKG-0001.
    other = A.declare_package(store, **package_body(
        capability_id, contract_id, request_id='req-other-writer'))
assert other.record_id == 'CPKG-0001', other.to_dict()
print('OK')
"

# ===========================================================================
# Manifest location: a sibling, never a member
# ===========================================================================

run_case "the manifest reference satisfies the file grammar, not the tree one" "${PRELUDE}
assert PR._relative_from_reference(MANIFEST_REFERENCE, PR._FILE_SCHEME) \
    == MANIFEST_RELATIVE
assert PR._relative_from_reference(MANIFEST_REFERENCE, PR._TREE_SCHEME) is None
for outside in ('file:/etc/passwd', 'file:../escape.json', 'file:', 'file: x',
                'verified/1.0.0.manifest.json'):
    assert PR._relative_from_reference(outside, PR._FILE_SCHEME) is None, outside
print('OK')
"

# Placing the manifest inside the tree is not a style choice: the manifest
# carries the tree commitment, so a manifest under the tree would have to
# contain a digest taken over its own bytes.
run_case "a manifest inside the package tree cannot commit to that tree" "${PRELUDE}
with TemporaryDirectory() as tmp:
    root = artifact_root(tmp)
    tree = root / TREE_RELATIVE
    before = commitment(tree)
    (tree / 'inside.manifest.json').write_text(json.dumps({
        'schema_version': PR.MANIFEST_SCHEMA_VERSION,
        'capability_package_id': 'CPKG-0001', 'contract_id': 'CCON-0001',
        'capability_id': 'CAPDEF-0001', 'artifact_reference': TREE_REFERENCE,
        'package_tree_sha256': before}), encoding='utf-8')
    os.chmod(tree / 'inside.manifest.json', 0o644)
    after = commitment(tree)
assert after != before, 'adding the manifest did not move the commitment'
print('OK')
"

run_case "the manifest sits beside the tree, never beneath it" "${PRELUDE}
assert not MANIFEST_RELATIVE.startswith(TREE_RELATIVE + '/'), MANIFEST_RELATIVE
assert Path(MANIFEST_RELATIVE).parent == Path(TREE_RELATIVE).parent
print('OK')
"

# ===========================================================================
# The accepted split stays accepted
# ===========================================================================

assert_schema_split() {
  local report
  report="$(cd "${ROOT}" && python3 - <<'SCHEMAPY'
import sys
sys.dont_write_bytecode = True
from tools.common.yaml_strict import load_strict

schema = load_strict("platform-model/schemas/capability-package.schema.yaml")
findings = []
required = schema.get("required_fields") or []
optional = schema.get("optional_fields") or []
if "manifest_reference" not in optional:
    findings.append("manifest_reference left optional_fields")
if "manifest_reference" in required:
    findings.append("manifest_reference became a required field")
if "artifact_reference" not in required:
    findings.append("artifact_reference left required_fields")
print("\n".join(findings) if findings else "clean")
SCHEMAPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "the schema keeps manifest_reference optional, as design §8 rules"
  else
    fail "schema split moved: ${report}"
  fi
}

assert_schema_split

# Matched on the ruling's own prose rather than on a paraphrase, and without
# the markup around it: the sentences below are why the schema stays optional
# and why the resolver keeps refusing, so a suite that stopped finding them is
# a suite asserting against an authority that moved.
assert_design_authority() {
  local spec="${ROOT}/docs/superpowers/specs/2026-08-10-capability-runtime-design.md"
  if grep -q "makes it$" "${spec}" \
     && grep -q "optional; execution does not" "${spec}" \
     && grep -q "MUST NOT be synthesised" "${spec}"; then
    pass "the design still rules the optional-record / mandatory-execution split"
  else
    fail "the design authority for the manifest split moved"
  fi
}

assert_design_authority

# ===========================================================================
# What this suite did not touch
# ===========================================================================

assert_no_production_write() {
  local sequences="/var/lib/kyri/fabric/sequences"    # prod-path-reference
  local packages="/var/lib/kyri/fabric/capability-packages"
  if [[ -e "${sequences}/capability-package.seq" ]]; then
    fail "the production capability-package sequence exists"
  else
    pass "the production capability-package sequence is still absent"
  fi
  if [[ -d "${packages}" ]] && [[ -n "$(ls -A "${packages}" 2>/dev/null)" ]]; then
    fail "the production package namespace is no longer unspent"
  else
    pass "the production package namespace is still unspent"
  fi
}

assert_no_production_write

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All package-manifest assertions passed.\n'
else
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
