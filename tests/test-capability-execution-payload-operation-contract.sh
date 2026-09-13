#!/usr/bin/env bash
set -Eeuo pipefail

# The two `operation` vocabularies, and the gap between them.
#
# UNPRIVILEGED AND HOST-INDEPENDENT. Reads the committed package and the
# committed platform modules; writes only inside a temporary directory. No
# store, no Fabric, no handoff, no container, no sudo.
#
# WHAT THIS IS FOR
# ================
# CINV-000002 executed cleanly and returned `provider-error`. The cause was one
# field. `operation` is spelled in two closed vocabularies that share no member:
#
#   Fabric scope   `execute`                   CINST permitted_operations,
#                                              checked by fabric_evidence
#   capability     `verify-execution-boundary` result_content.OPERATIONS,
#                                              checked by the package itself
#
# The governed payload for CINV-000002 carried the Fabric verb in the field the
# capability reads. The coordinator admitted it -- its payload schema types
# `operation` as free text -- and the capability refused it four days later,
# inside the container, having already spent an invocation identity.
#
# So the cases below prove three separate things, and the third is the one that
# matters for the next ceremony:
#
#   * the exact defective bytes still refuse, and produce no result
#   * the same document with the capability's verb succeeds
#   * the coordinator ACCEPTS the defective document, so it is not and never
#     was the enforcement point

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE="${ROOT}/packages/kyri-execution-boundary-verification/1.0.0/main.py"

# The governed package as the manifest names it. Read from the manifest rather
# than restated, so a package revision cannot leave this suite testing bytes
# nobody ships.
MANIFEST="${ROOT}/packages/kyri-execution-boundary-verification/1.0.0.manifest.json"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

[[ -f "${PACKAGE}" ]] || { printf 'the governed package is missing\n' >&2; exit 1; }
[[ -f "${MANIFEST}" ]] || { printf 'the package manifest is missing\n' >&2; exit 1; }

run_case() {                                  # <description> <python program>
  local description="$1" program="$2"
  if OUTPUT="$(cd "${ROOT}" && python3 -c "${program}" 2>&1)"; then
    pass "${description}"
  else
    fail "${description}: ${OUTPUT}"
  fi
}

# The defective payload, exactly as CINV-000002 carried it. Stated as the
# reviewed document rather than read from the production handoff: this suite
# runs on machines that have no handoff, and the digest assertion below is what
# ties the two together.
DEFECTIVE_PAYLOAD_SHA256="e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c"

PRELUDE="
import json, hashlib, importlib.util, os, sys
from pathlib import Path
from tempfile import TemporaryDirectory
sys.path.insert(0, '${ROOT}')
from tools.capability.execution import canonical_json, payload as payload_mod
from tools.capability.execution import result_content

DEFECTIVE = {
    'arguments': {'count': 1,
                  'label': 'g11bb2-second-controlled-production-invoke'},
    'note': ('ENG-0005 G11-BB2: the second controlled production invocation, '
             'CINV-000002, on the CADV-000005 / CINST-000004 / CROUTE-0004 / '
             'CSEL-000003 chain.'),
    'operation': 'execute',
}

def entry_module():
    # Bytecode writes are disabled FIRST. A __pycache__ beside the entrypoint is
    # a compiled member the package contract refuses, so loading the entrypoint
    # would change the tree digest of the very artifact under test -- and the
    # verification-package suite, which pins that digest, would go red for a
    # reason that has nothing to do with it. The container disables them too,
    # with PYTHONDONTWRITEBYTECODE, which is what makes the read-only package
    # mount viable.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('governed_entry', '${PACKAGE}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def scene(tmp, body):
    payload_path = os.path.join(tmp, 'payload')
    Path(payload_path).write_bytes(body)
    output = os.path.join(tmp, 'out')
    os.mkdir(output)
    return payload_path, os.path.join(output, 'result.json')
"

# ===========================================================================
# A. the bytes are the bytes CINV-000002 carried
# ===========================================================================

run_case "the reviewed defective document canonicalises to the governed CINV-000002 payload digest" "${PRELUDE}
body = canonical_json.serialise(DEFECTIVE)
digest = hashlib.sha256(body).hexdigest()
assert digest == '${DEFECTIVE_PAYLOAD_SHA256}', digest
assert len(body) == 254, len(body)
"

run_case "the package under test is the one the manifest governs" "${PRELUDE}
manifest = json.loads(Path('${MANIFEST}').read_text())
assert manifest['capability_id'] == 'CAPDEF-0001', manifest['capability_id']
assert manifest['artifact_reference'].endswith('kyri-execution-boundary-verification/1.0.0')
"

# ===========================================================================
# B. RED -- the defect, reproduced
# ===========================================================================

run_case "RED: the governed package refuses the exact CINV-000002 payload" "${PRELUDE}
module = entry_module()
body = canonical_json.serialise(DEFECTIVE)
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp, body)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused as error:
        message = str(error)
    else:
        raise AssertionError('the defective payload was accepted')
    assert message == ('the payload requests an operation this capability '
                       'does not perform'), message
    # The refusal writes nothing. An empty out/ is the CONSEQUENCE of this,
    # not an independent failure -- which is what production observed.
    assert not Path(result_path).exists()
    assert os.listdir(os.path.dirname(result_path)) == []
"

run_case "RED: the process reports the refusal as exit 1, not as a crash" "${PRELUDE}
module = entry_module()
body = canonical_json.serialise(DEFECTIVE)
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp, body)
    module.PAYLOAD_PATH = payload_path
    module.RESULT_PATH = result_path
    assert module.main() == 1
"

# ===========================================================================
# C. GREEN -- the one field, corrected
# ===========================================================================

run_case "GREEN: the same document with the capability's operation succeeds" "${PRELUDE}
module = entry_module()
corrected = dict(DEFECTIVE)
corrected['operation'] = 'verify-execution-boundary'
body = canonical_json.serialise(corrected)
with TemporaryDirectory() as tmp:
    payload_path, result_path = scene(tmp, body)
    module.PAYLOAD_PATH = payload_path
    module.RESULT_PATH = result_path
    assert module.main() == 0
    document = json.loads(Path(result_path).read_bytes())
    # It is not enough that a file appeared: the collector admits a result only
    # if it satisfies the governed content schema, so that is what is checked.
    result_content.validate_result_content(document)
    assert document['payload_digest'] == hashlib.sha256(body).hexdigest()
"

run_case "GREEN: only the operation changed -- everything else is the reviewed document" "${PRELUDE}
corrected = dict(DEFECTIVE)
corrected['operation'] = 'verify-execution-boundary'
differing = [k for k in set(DEFECTIVE) | set(corrected)
             if DEFECTIVE.get(k) != corrected.get(k)]
assert differing == ['operation'], differing
"

# ===========================================================================
# D. the vocabularies, and where each is enforced
# ===========================================================================

run_case "the Fabric verb is not a governed capability operation" "${PRELUDE}
assert 'execute' not in result_content.OPERATIONS, result_content.OPERATIONS
assert result_content.OPERATIONS == ('verify-execution-boundary',)
"

# The finding, stated as a test rather than as a warning in a report. If a
# future release DOES constrain the payload's operation, this fails and the
# next author has to decide deliberately -- which is the point.
run_case "the coordinator's payload schema accepts the defective operation, so it is not the enforcement point" "${PRELUDE}
body = canonical_json.serialise(DEFECTIVE)
with TemporaryDirectory() as tmp:
    path = os.path.join(tmp, 'payload')
    Path(path).write_bytes(body)
    fd = os.open(path, os.O_RDONLY)
    try:
        binding = payload_mod.validate_payload(
            fd, schema_version=payload_mod.PAYLOAD_SCHEMA_VERSION)
    finally:
        os.close(fd)
assert binding.document['operation'] == 'execute'
assert binding.digest == '${DEFECTIVE_PAYLOAD_SHA256}', binding.digest
"

run_case "the capability is the only thing that refuses it" "${PRELUDE}
module = entry_module()
# Both halves in one case, because the gap is the pair and not either half:
# admitted at the coordinator, refused inside the container.
body = canonical_json.serialise(DEFECTIVE)
with TemporaryDirectory() as tmp:
    path = os.path.join(tmp, 'payload')
    Path(path).write_bytes(body)
    fd = os.open(path, os.O_RDONLY)
    try:
        payload_mod.validate_payload(
            fd, schema_version=payload_mod.PAYLOAD_SCHEMA_VERSION)
    finally:
        os.close(fd)
    payload_path, result_path = scene(tmp, body)
    try:
        module.verify(payload_path, result_path)
    except module.VerificationRefused:
        pass
    else:
        raise AssertionError('nothing refused the defective payload')
"

# ===========================================================================
# E. this suite left the governed tree alone
# ===========================================================================
#
# Not a formality: an earlier draft of this file loaded the entrypoint without
# disabling bytecode and wrote a __pycache__ into the governed package, which
# changed its tree digest and turned the verification-package suite red. A test
# that mutates the artifact it is testing is worse than no test.
if [[ -z "$(find "${ROOT}/packages" -name '__pycache__' -o -name '*.pyc' 2>/dev/null)" ]]; then
  pass "the governed package tree carries no compiled member after this suite ran"
else
  fail "this suite wrote bytecode into the governed package tree: $(find "${ROOT}/packages" -name '__pycache__' -o -name '*.pyc' | tr '\n' ' ')"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'Payload operation contract validation passed.\n'
else
  printf 'Payload operation contract validation FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
