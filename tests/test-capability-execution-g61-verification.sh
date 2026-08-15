#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, milestone G6.1.
#
# G6.1 proves the whole privileged chain end to end and stops one step before
# container execution:
#
#   cschott -> the exact sudoers boundary -> root -> the authenticated CINV
#   handoff -> a real ExecutionProfile over sealed FD 3 -> descriptor closure ->
#   the ruled quota/project setup -> a permanent setgroups/setgid/setuid drop ->
#   verification of that drop -> no_new_privs -> a dedicated verification-only
#   worker running as kyri-capability -> the SAME worker-side profile and
#   handoff verification production uses -> a machine-readable success record ->
#   exit 0.
#
# NOTHING HERE IS LIVE. No sudoers is installed, no sudo is invoked, no /etc is
# touched, no authority namespace is read or written, no CIMP/CGEN/CINV is
# allocated, no transition is performed, no worker is executed, and no container
# runtime is invoked. Every privileged operation runs through the injected
# backend the T11 suite established; every governed root is a temporary tree.
#
# THE NON-EXECUTION PROOF IS STRUCTURAL, NOT A MOCK. The verification entrypoint
# does not import snapshot materialisation and does not bind create_argv, so the
# proof is that those names are absent and that a successful verification never
# loads the snapshot module at all. The poisons below exist to catch a future
# change that reintroduces reachability -- they are not what makes it true.
#
# G6 REMAINS CLOSED. The production worker still refuses for want of a bound
# runtime backend, the production sudoers grant is unchanged, and the
# verification grant provably cannot be used to reach either.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §7, §17
#   docs/superpowers/specs/2026-08-11-execution-transition-boundary.md  §3.2-§3.3
#   the G6.1 milestone

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERIFICATION="tools/capability/execution/verification.py"
IMAGE_STORE="tools/capability/execution/image_store.py"
VERIFY_POLICY="provisioning/execution/kyri-exec-verify.py"
VERIFY_WORKER="provisioning/execution/kyri-exec-verify-worker.py"
VERIFY_ENTRY="provisioning/execution/kyri-exec-verify-entrypoint.py"
VERIFY_SUDOERS="provisioning/execution/sudoers.d/kyri-exec-verify.example"
PROD_SUDOERS="provisioning/execution/sudoers.d/kyri-exec.example"
PROD_WORKER="provisioning/execution/kyri-exec-worker.py"
PROD_POLICY="provisioning/execution/kyri-exec-transition.py"
PROD_ACTION="provisioning/execution/kyri-exec-transition-action.py"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# ===========================================================================
# Live state, before and after
# ===========================================================================
# Compared rather than asserted absent. Absence only asks whether a gate has
# run; comparison asks the question this suite actually owes an answer to,
# which is whether IT changed anything.

PRODUCTION_PATHS=(
  /etc/sudoers.d/kyri-exec
  /etc/sudoers.d/kyri-exec-verify
  /usr/libexec/kyri-exec-transition
  /usr/libexec/kyri-exec-verify
  /usr/libexec/kyri-exec-worker.py
  /usr/libexec/kyri-exec-verify-worker.py
  /usr/lib/kyri/python
  /data/kyri/capability-handoff
  /var/lib/kyri/implementation-authority
)
snapshot_production() {
  python3 -c '
import json, os, sys
state = {}
for path in sys.argv[1:]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        state[path] = None
        continue
    except OSError:
        state[path] = "unreadable"
        continue
    state[path] = [info.st_mode, info.st_uid, info.st_gid, info.st_mtime_ns]
print(json.dumps(state, sort_keys=True))
' "$@"
}
PRODUCTION_BEFORE="$(snapshot_production "${PRODUCTION_PATHS[@]}")"

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

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "artifact present: $1"; else fail "required artifact missing: $1"; fi
}

# ===========================================================================
# A. The G6.1 artifacts
# ===========================================================================

assert_file "${VERIFICATION}"
assert_file "${IMAGE_STORE}"
assert_file "${VERIFY_POLICY}"
assert_file "${VERIFY_WORKER}"
assert_file "${VERIFY_ENTRY}"
assert_file "${VERIFY_SUDOERS}"

# Neither entrypoint may be executable in the repository: they are installed
# root-owned and read-only, and the interpreter is named by the transition.
for artifact in "${VERIFY_WORKER}" "${VERIFY_POLICY}"; do
  if [[ -x "${ROOT}/${artifact}" ]]; then
    fail "${artifact} is executable in the checkout"
  else
    pass "${artifact} carries no executable bit"
  fi
done

# ===========================================================================
# B. Structural non-execution, read off the source
# ===========================================================================

SCAN_PRELUDE="
import ast, pathlib, os, sys

ROOT = pathlib.Path('.')

def source(rel):
    return (ROOT / rel).read_text(encoding='utf-8')

def tree(rel):
    return ast.parse(source(rel))

def code_only(rel):
    '''The module with every docstring removed.

    These files explain at length what they must not do, so scanning the prose
    for forbidden tokens would fail them for describing themselves.
    '''
    parsed = tree(rel)
    for node in ast.walk(parsed):
        body = getattr(node, 'body', None)
        if not isinstance(body, list) or not body:
            continue
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \\
                and isinstance(first.value.value, str):
            body.pop(0)
            if not body:
                body.append(ast.Pass())
    ast.fix_missing_locations(parsed)
    return ast.unparse(parsed)

def comment_free(rel):
    '''Executable text only: no docstrings and no comment lines.'''
    return '\\n'.join(line for line in code_only(rel).splitlines()
                     if not line.strip().startswith('#'))
"

run_case "the verification driver imports no snapshot and binds no create_argv" "${SCAN_PRELUDE}
code = comment_free('${VERIFICATION}')
for banned in ('snapshot', 'create_argv', 'materialise', 'subprocess',
               'VerifiedExecution'):
    assert banned not in code, banned
print('OK')
"

run_case "the verification driver imports names from worker, never the module" "${SCAN_PRELUDE}
parsed = tree('${VERIFICATION}')
for node in ast.walk(parsed):
    if isinstance(node, ast.ImportFrom):
        # 'from .worker import X' is fine; 'from . import worker' binds the
        # module object and puts create_argv one attribute access away.
        for alias in node.names:
            assert alias.name != 'worker', 'the module object is bound'
    if isinstance(node, ast.Import):
        for alias in node.names:
            assert 'worker' not in alias.name, alias.name
imported = set()
for node in ast.walk(parsed):
    if isinstance(node, ast.ImportFrom) and node.module == 'worker':
        imported |= {alias.name for alias in node.names}
assert imported and 'verify_execution' in imported, imported
assert 'create_argv' not in imported
print('OK')
"

run_case "the record builder hard-codes no identity or schema value" "${SCAN_PRELUDE}
from tools.capability.execution.worker import WORKER_GID, WORKER_UID
from tools.capability.execution.profile import PROFILE_SCHEMA_VERSION
builders = [node for node in ast.walk(ast.parse(comment_free('${VERIFICATION}')))
            if isinstance(node, ast.FunctionDef)
            and node.name in ('execution_record', 'success_record')]
assert len(builders) == 2, [node.name for node in builders]
for builder in builders:
    # The record must derive these from the governed contracts. A literal here
    # would let the output agree with itself while disagreeing with the runtime.
    numbers = {node.value for node in ast.walk(builder)
               if isinstance(node, ast.Constant) and isinstance(node.value, int)
               and not isinstance(node.value, bool)}
    for governed in (WORKER_UID, WORKER_GID, PROFILE_SCHEMA_VERSION):
        assert governed not in numbers, (builder.name, governed)
    # and they must be read from somewhere, rather than simply omitted.
    names = {node.id for node in ast.walk(builder) if isinstance(node, ast.Name)}
    assert {'WORKER_UID', 'WORKER_GID'} <= names, builder.name
print('OK')
"

run_case "the verification worker entrypoint cannot reach execution" "${SCAN_PRELUDE}
code = comment_free('${VERIFY_WORKER}')
for banned in ('create_argv', 'snapshot', 'materialise', 'ExecutionBackend',
               'container', 'subprocess'):
    assert banned not in code, banned
# It reaches the library by named import, never by binding the worker module.
parsed = tree('${VERIFY_WORKER}')
for node in ast.walk(parsed):
    if isinstance(node, ast.ImportFrom):
        for alias in node.names:
            assert alias.name not in ('worker', 'snapshot'), alias.name
print('OK')
"

run_case "the verification worker has no shebang and names its interpreter" "${SCAN_PRELUDE}
text = source('${VERIFY_WORKER}')
assert not text.startswith('#!'), 'the verification worker carries a shebang'
assert '/usr/bin/python3' in text
assert '/usr/libexec/kyri-exec-verify-worker.py' in text
print('OK')
"

run_case "the image store runs no process and invokes no container runtime" "${SCAN_PRELUDE}
code = comment_free('${IMAGE_STORE}')
# The whole tools/capability package is asserted elsewhere to import no
# subprocess. This restates the consequence at the one file that would have had
# the strongest excuse to: presence is answered by reading the store, so
# 'podman_invoked: false' in the success record is literally true.
# Assembled rather than written out, so this suite does not contain the very
# literals it asserts are absent from the file under test.
for banned in ('subpro' + 'cess', 'os.sys' + 'tem', 'po' + 'pen', 'she' + 'll',
               'pod' + 'man', 'doc' + 'ker', 'ex' + 'ecv', 'sp' + 'awn',
               'cty' + 'pes', 'soc' + 'ket'):
    assert banned not in code, banned
parsed = ast.parse(code)
for node in ast.walk(parsed):
    if isinstance(node, ast.Import):
        for alias in node.names:
            assert alias.name in ('json', 'os', 'stat'), alias.name
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        assert node.func.attr not in ('system', 'popen', 'fork', 'execve'), node.func.attr
print('OK')
"

run_case "the image store reads one compiled-in location and nothing else" "${SCAN_PRELUDE}
from tools.capability.execution import image_store as S
assert S.GRAPHROOT_RELATIVE == ('.local', 'share', 'containers', 'storage')
assert S.IMAGE_INDEX == ('overlay-images', 'images.json')
assert S.HOME_VARIABLE == 'HOME'
assert S.MAXIMUM_INDEX_BYTES > 0
code = comment_free('${IMAGE_STORE}')
# Every component is opened no-follow and descriptor-relatively, so a replaced
# directory or a symlinked index is refused rather than followed.
assert 'O_NOFOLLOW' in code
assert code.count('dir_fd=') >= 2, code.count('dir_fd=')
# It reads the identity field and nothing that could be matched by name.
for banned in ('names', 'tags', 'digest', 'repository', 'latest'):
    assert banned not in code, banned
print('OK')
"

run_case "the image store refuses every uncertainty rather than answering absent" "${SCAN_PRELUDE}
import json
from tools.capability.execution.image_store import (
    ImageStoreUnreadable, RootlessImageStore)
WORK = os.environ['WORKDIR']
IMAGE = 'a' * 64

COUNTER = [0]

def home_for(entries, *, index=True):
    COUNTER[0] += 1
    base = os.path.join(WORK, 'store-%d' % COUNTER[0])
    graph = os.path.join(base, '.local', 'share', 'containers', 'storage',
                         'overlay-images')
    os.makedirs(graph)
    if index:
        with open(os.path.join(graph, 'images.json'), 'w', encoding='utf-8') as handle:
            handle.write(entries if isinstance(entries, str) else json.dumps(entries))
    return base

def store(entries, *, index=True, owner=None):
    return RootlessImageStore(
        home=home_for(entries, index=index),
        owner=os.geteuid() if owner is None else owner)

# The reference case, and the only one that answers at all. 'names' is present
# in the fixture precisely because the store must ignore it.
present = store([{'id': IMAGE, 'names': ['a-name-that-must-not-match']},
                 {'id': 'b' * 64}])
assert present.present(IMAGE) is True
assert present.present('c' * 64) is False

def refuses(what, probe=IMAGE):
    try:
        what.present(probe)
    except ImageStoreUnreadable:
        return True
    raise AssertionError('the store answered where it should have refused')

assert refuses(store([], index=False)), 'a store with no index answered'
assert refuses(RootlessImageStore(home=os.path.join(WORK, 'absent'))), \\
    'an absent store answered'
assert refuses(store('not json at all')), 'a malformed index answered'
assert refuses(store({'images': []})), 'an index that is not a list answered'
assert refuses(store([{'id': IMAGE}, 'not an image'])), \\
    'an index holding a non-image answered'
# Ruled: an unknown or malformed containers/storage representation is a
# refusal, never a record to be skipped past. Skipping one would be a
# heuristic -- 'that entry cannot have been the image I was asked about' -- and
# a store this process cannot fully read is a store it cannot answer from.
assert refuses(store([{'id': IMAGE}, {'names': ['no id at all']}])), \\
    'an index record with no id was skipped rather than refused'
assert refuses(store([{'id': IMAGE}, {'id': None}])), \\
    'an index record with a null id was skipped rather than refused'
assert refuses(store([{'id': IMAGE}, {'id': 12345}])), \\
    'an index record with a non-string id was skipped rather than refused'
assert refuses(store([{'id': IMAGE}, {'id': 'not-64-hex'}])), \\
    'an index record with a malformed id was skipped rather than refused'
assert refuses(store([{'id': IMAGE}, {'id': 'A' * 64}])), \\
    'an index record with an uppercase id was skipped rather than refused'
# And no fallback exists to consult anything else when the index cannot be read.
code = comment_free('${IMAGE_STORE}')
for banned in ('except Exception', 'fallback', 'best_effort', 'try:\\n        return False'):
    assert banned not in code, banned
# A store owned by somebody else is not this identity's store.
assert refuses(store([{'id': IMAGE}], owner=os.geteuid() + 1)), \\
    'a store owned by another identity answered'
# HOME is where the store is, so an absent HOME is an unidentifiable store.
os.environ.pop('HOME', None)
assert refuses(RootlessImageStore()), 'a store with no HOME answered'
# And the key itself is revalidated at this boundary, not only at the caller's.
for malformed in ('', 'A' * 64, 'a' * 63, 'sha256:' + 'a' * 64, None, 7):
    assert refuses(present, probe=malformed), malformed
print('OK')
"

run_case "the verification entrypoint selects its policy by compiled-in name" "${SCAN_PRELUDE}
parsed = tree('${VERIFY_ENTRY}')
assigned = {}
for node in parsed.body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) \\
            and isinstance(node.value, ast.Constant):
        assigned[node.targets[0].id] = node.value.value
assert assigned['POLICY_MODULE'] == 'kyri_exec_verify', assigned.get('POLICY_MODULE')
assert assigned['HELPER_PATH'] == '/usr/libexec/kyri-exec-verify'
assert assigned['RUNTIME_LIBRARY_ROOT'] == '/usr/lib/kyri/python'
code = comment_free('${VERIFY_ENTRY}')
# The production worker is not nameable from here, and there is no parser
# through which a caller could contribute a target.
assert 'kyri-exec-worker.py' not in code
assert 'kyri_exec_transition\\'' not in code.replace('kyri_exec_transition_action', 'X')
for banned in ('argparse', 'getopt', 'optparse', 'environ', 'getenv',
               'startswith(\\'--\\')'):
    assert banned not in code, banned
print('OK')
"

run_case "the verification entrypoint takes exactly one CINV and nothing else" "${SCAN_PRELUDE}
prod = comment_free('provisioning/execution/kyri-exec-transition-entrypoint.py')
verify = comment_free('${VERIFY_ENTRY}')
# The public interface is the production one, character for character on the
# shape: one argument, no options.
assert 'len(argv) != 2' in prod and 'len(argv) != 2' in verify
assert 'CINV-nnnnnn' in source('${VERIFY_ENTRY}')
print('OK')
"

run_case "the transition builder requires the target and defaults to nothing" "${SCAN_PRELUDE}
parsed = tree('${PROD_POLICY}')
builder = [node for node in ast.walk(parsed)
           if isinstance(node, ast.FunctionDef) and node.name == 'worker_argv']
assert len(builder) == 1
signature = builder[0].args
assert [arg.arg for arg in signature.kwonlyargs] == ['worker_script'], signature.kwonlyargs
# A default would silently restore the divergence this milestone removed.
assert signature.kw_defaults == [None], 'the worker target carries a default'
print('OK')
"

run_case "the privileged exec site acts on the policy it was given" "${SCAN_PRELUDE}
code = comment_free('${PROD_ACTION}')
assert 'worker_script=policy.worker_script' in code, \\
    'the exec site does not pass the decided target'
# and never reaches around it to the policy module's own constant
assert 'module.WORKER_SCRIPT' not in code
print('OK')
"

# ===========================================================================
# B2. The production boundary is unchanged
# ===========================================================================

run_case "the production worker still refuses for want of a runtime backend" "${SCAN_PRELUDE}
text = source('${PROD_WORKER}')
assert 'container execution is gated at G6' in text
code = comment_free('${PROD_WORKER}')
assert 'create_argv' not in code and 'verification' not in code
print('OK')
"

run_case "the production sudoers grant is one command and names no verify path" "${SCAN_PRELUDE}
text = source('${PROD_SUDOERS}')
rules = [line for line in text.splitlines()
         if line.strip() and not line.lstrip().startswith('#')]
assert len(rules) == 2, rules
assert rules[0].startswith('Cmnd_Alias KYRI_EXEC_TRANSITION =')
assert rules[0].endswith('/usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}\$')
assert rules[1] == 'cschott ALL=(root) NOPASSWD: KYRI_EXEC_TRANSITION'
assert 'kyri-exec-verify' not in text
print('OK')
"

run_case "the verification grant is one command over one absolute path" "${SCAN_PRELUDE}
text = source('${VERIFY_SUDOERS}')
rules = [line for line in text.splitlines()
         if line.strip() and not line.lstrip().startswith('#')]
assert len(rules) == 2, rules
assert rules[0].startswith('Cmnd_Alias KYRI_EXEC_VERIFY = sha256:'), rules[0]
assert rules[0].endswith('/usr/libexec/kyri-exec-verify ^CINV-[0-9]{6}\$'), rules[0]
assert rules[1] == 'cschott ALL=(root) NOPASSWD: KYRI_EXEC_VERIFY', rules[1]
print('OK')
"

run_case "the verification grant cannot reach the production execution path" "${SCAN_PRELUDE}
text = source('${VERIFY_SUDOERS}')
rules = ' '.join(line for line in text.splitlines()
                 if line.strip() and not line.lstrip().startswith('#'))
# Not the production helper, not the production worker, not an interpreter.
for banned in ('/usr/libexec/kyri-exec-transition',
               '/usr/libexec/kyri-exec-worker.py',
               '/usr/bin/python', '/bin/sh', '/bin/bash', 'ALL=(ALL)',
               'SETENV', 'env_keep', 'sudoedit', '*', 'NOEXEC', '!'):
    assert banned not in rules, banned
# The digest is a placeholder, never a real-looking value somebody ships.
assert 'REPLACE_WITH_INSTALLED_VERIFY_HELPER_DIGEST' in rules
# The prose has to state the property, because a reviewer reads the prose.
assert 'does NOT make /usr/libexec/kyri-exec-worker.py callable' in text
print('OK')
"

# ===========================================================================
# C. Structural non-execution, observed at runtime
# ===========================================================================

run_case "importing the verification driver never loads snapshot" "${SCAN_PRELUDE}
import subprocess
probe = 'import sys; import tools.capability.execution.verification as V; ' \\
        'print(\\'tools.capability.execution.snapshot\\' in sys.modules, ' \\
        'hasattr(V, \\'create_argv\\'), hasattr(V, \\'worker\\'))'
out = subprocess.run([sys.executable, '-c', probe], capture_output=True,
                     text=True, check=True).stdout.strip()
assert out == 'False False False', out
print('OK')
"

# --- the shared-chain fixtures ---------------------------------------------
# Lifted from the Pass 4A gate suite deliberately: the point of G6.1 is that
# verification runs the SAME chain, so it is exercised with the same material.

CHAIN_PRELUDE="${SCAN_PRELUDE}
import dataclasses, fcntl, hashlib, json, shutil, stat, tempfile

from tools.capability.execution import worker as W
from tools.capability.execution import profile as P
from tools.capability.execution import verification as V
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import Admission
from tools.capability.execution.package_contract import validate_package
from tools.capability.execution.payload import validate_payload
from tools.capability.execution.handoff import publish_handoff
from tools.capability.execution.backing_store import (
    verify_backing_store, ObservedFilesystem)

WORK = os.environ['WORKDIR']
UUID = '12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96'
IMAGE = 'a' * 64
PAYLOAD_BYTES = b'{\"operation\":\"sum\",\"arguments\":{\"count\":3}}'
PACKAGE_FILES = {
    'main.py': b'def run():\n    return {}\n',
    'helper.py': b'VALUE = 1\n',
}

# --- the poisons -------------------------------------------------------------
# Not the proof, and not a substitute for it. The absence of the imports above
# is what makes execution unreachable; these turn a future regression into a
# loud failure rather than a quiet capability.

class Detonator:
    def __init__(self, what):
        self.what = what
    def __getattr__(self, name):
        raise AssertionError('verification reached ' + self.what + '.' + name)

def poison():
    sys.modules['tools.capability.execution.snapshot'] = Detonator('snapshot')
    def forbidden(*args, **kwargs):
        raise AssertionError('verification reached create_argv')
    W.create_argv = forbidden
    W.PODMAN = '/nonexistent/podman-must-not-be-invoked'

def snapshot_untouched():
    module = sys.modules.get('tools.capability.execution.snapshot')
    return isinstance(module, Detonator)

def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)
    os.chmod(path, mode)

def admission(cimp='CIMP-000001', image=None, **overrides):
    fields = dict(
        cimp=cimp, oci_image_id=image if image else IMAGE,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)
    fields.update(overrides)
    return Admission(**fields)

def bindings(name, files=None, payload=None, entrypoint='main.py'):
    base = os.path.join(WORK, name + '-pkg')
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)
    for relative, body in (PACKAGE_FILES if files is None else files).items():
        write(os.path.join(base, relative), body)
    handle = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        package = validate_package(handle, entrypoint=entrypoint)
    finally:
        os.close(handle)
    path = os.path.join(WORK, name + '-payload.json')
    write(path, PAYLOAD_BYTES if payload is None else payload)
    fd = os.open(path, os.O_RDONLY)
    try:
        payload_binding = validate_payload(fd, schema_version=1)
    finally:
        os.close(fd)
    return base, package, payload_binding

def governed(name='g', cinv='CINV-000042', cimp='CIMP-000001', image=None,
             files=None, payload=None, entrypoint='main.py'):
    base, package, payload_binding = bindings(name, files, payload, entrypoint)
    binding = P.ProfileBinding(
        cinv=cinv, admission=admission(cimp, image),
        payload_digest=payload_binding.digest,
        package_digest=package.digest,
        package_entrypoint=package.entrypoint)
    return P.build_profile(binding), base, package, payload_binding

def published(name='h', cinv='CINV-000042', **kwargs):
    profile, base, package, payload_binding = governed(name, cinv=cinv, **kwargs)
    root_base = os.path.join(WORK, name + '-hand')
    if os.path.isdir(root_base):
        shutil.rmtree(root_base)
    os.makedirs(os.path.join(root_base, 'root'))
    write(os.path.join(root_base, 'backing-store.json'),
          serialise({'filesystem_uuid': UUID, 'filesystem_type': 'xfs',
                     'mount_point': '/data'}))
    cfg = os.open(os.path.join(root_base, 'backing-store.json'), os.O_RDONLY)
    rt = os.open(os.path.join(root_base, 'root'), os.O_RDONLY | os.O_DIRECTORY)
    try:
        anchor = verify_backing_store(cfg, rt, observed=ObservedFilesystem(
            filesystem_uuid=UUID, filesystem_type='xfs',
            mount_point='/data', device_name='/dev/sdb1'))
    finally:
        os.close(cfg); os.close(rt)
    artefact = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    try:
        publish_handoff(anchor, cinv, artefact, payload_binding, package,
                        profile=profile)
    finally:
        os.close(artefact)
    return profile, os.path.join(root_base, 'root')

class Images:
    '''The injected presence seam. Contains no Podman and no authority.'''

    UNSET = object()

    def __init__(self, present=(IMAGE,), error=None, answer=UNSET):
        self.asked = []
        self._present = tuple(present)
        self._error = error
        # A sentinel, not None: 'the store answered None' is one of the cases
        # that must be refused, and a default of None would make it untestable.
        self._answer = answer

    def present(self, oci_image_id):
        self.asked.append(oci_image_id)
        if self._error is not None:
            raise self._error
        if self._answer is not Images.UNSET:
            return self._answer
        return oci_image_id in self._present

def context(profile, cinv=None, cimp=None, digest=None):
    return W.require_launch_context(
        cinv=cinv or profile.cinv, cimp=cimp or profile.cimp,
        profile_digest=digest or P.fingerprint(profile).profile_digest)

def chain(profile, handoff_root, images=None, ctx=None):
    '''The shared chain, with execution poisoned.'''
    root_fd = os.open(handoff_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return W.verify_execution(
            ctx if ctx is not None else context(profile), profile,
            root_fd=root_fd, images=Images() if images is None else images)
    finally:
        os.close(root_fd)

def refused(profile, handoff_root, images=None, ctx=None):
    try:
        chain(profile, handoff_root, images, ctx)
    except W.WorkerRefused as error:
        assert snapshot_untouched(), 'a refusal loaded the snapshot module'
        return error
    raise AssertionError('the shared chain accepted material it must refuse')

def sealed(data, seals=None):
    '''An anonymous object holding exactly these bytes, sealed as ruled.'''
    fd = os.memfd_create('g61-profile', os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    os.write(fd, data)
    os.lseek(fd, 0, os.SEEK_SET)
    applied = W.REQUIRED_SEALS if seals is None else seals
    if applied:
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, applied)
    return fd

def substituted(profile, **changes):
    return dataclasses.replace(profile, **changes)

poison()
"

run_case "the shared chain accepts governed material without loading snapshot" "${CHAIN_PRELUDE}
profile, handoff = published('happy')
verified = chain(profile, handoff)
assert isinstance(verified, W.VerifiedExecution)
assert snapshot_untouched(), 'a successful verification loaded the snapshot module'
print('OK')
"

run_case "a successful verification yields the governed success record" "${CHAIN_PRELUDE}
profile, handoff = published('record')
chain(profile, handoff)
record = V.execution_record(context(profile), profile)
line = V.success_record(record)
assert snapshot_untouched()
document = json.loads(line)
assert document == {
    'cinv': 'CINV-000042',
    'cimp': 'CIMP-000001',
    'execution_gid': W.WORKER_GID,
    'execution_uid': W.WORKER_UID,
    'handoff_verified': True,
    'image_presence_probed': True,
    'podman_invoked': False,
    'profile_schema_version': P.PROFILE_SCHEMA_VERSION,
    'profile_sealed': True,
    'result': 'verified',
    'worker_mode': 'verification-only',
}, document
print('OK')
"

run_case "verify_only runs the transition self-checks before the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('order')
root_fd = os.open(handoff, os.O_RDONLY | os.O_DIRECTORY)
try:
    # This process is the coordinator, not the dropped worker, so the first
    # self-check must refuse -- and must refuse naming the governed identity
    # rather than anything about the profile.
    try:
        V.verify_only(context(profile), profile, root_fd=root_fd, images=Images())
    except W.WorkerRefused as error:
        assert 'uid drop' in str(error), error
        assert str(W.WORKER_UID) in str(error), error
    else:
        raise AssertionError('verify_only ran outside the execution identity')
finally:
    os.close(root_fd)
assert snapshot_untouched()
print('OK')
"

run_case "verify_only returns exactly the governed record and nothing else" "${CHAIN_PRELUDE}
profile, handoff = published('whole')
# The three self-checks are facts about the process the transition created, and
# only that process can satisfy them. They are stood in for here so the REST of
# verify_only -- the shared chain and the record it derives -- is exercised end
# to end with execution poisoned.
seen = []
V.require_dropped_credentials = lambda **kw: seen.append(('creds', kw))
V.require_descriptor_closure = lambda: seen.append('fds') or (0, 1, 2, 3)
V.require_no_new_privs = lambda: seen.append('nnp') or 1
root_fd = os.open(handoff, os.O_RDONLY | os.O_DIRECTORY)
try:
    record = V.verify_only(context(profile), profile, root_fd=root_fd,
                           images=Images())
finally:
    os.close(root_fd)
assert seen[0][0] == 'creds' and seen[0][1] == {'uid': W.WORKER_UID, 'gid': W.WORKER_GID}
assert seen[1] == 'fds' and seen[2] == 'nnp', seen
assert record == V.execution_record(context(profile), profile)
assert V.success_record(record)
assert snapshot_untouched(), 'a successful verify_only loaded the snapshot module'
print('OK')
"

run_case "the success record carries no material and no authority record" "${CHAIN_PRELUDE}
profile, handoff = published('quiet')
line = V.success_record(V.execution_record(context(profile), profile))
for secret in (profile.payload_digest, profile.package_digest,
               profile.package_entrypoint, profile.oci_image_id,
               PAYLOAD_BYTES.decode(), 'main.py', '/kyri/package',
               '/data/kyri', 'XDG_RUNTIME_DIR', 'HOME',
               P.fingerprint(profile).profile_digest):
    assert secret not in line, secret
# One line, canonical, sorted, and ASCII: a reader is entitled to compare bytes.
assert '\n' not in line
assert line == serialise(json.loads(line)).decode('ascii')
assert line.encode('ascii')
print('OK')
"

# ===========================================================================
# D. The privileged transition selects the verification worker
# ===========================================================================

TRANSITION_PRELUDE="
import dataclasses, hashlib, importlib.util, json, os, shutil, sys, tempfile

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

policy_mod = load('kyri_exec_transition', '${PROD_POLICY}')
action = load('kyri_exec_transition_action', '${PROD_ACTION}')
verify_mod = load('kyri_exec_verify', '${VERIFY_POLICY}')

WORK = os.environ['WORKDIR']
PROFILE_BYTES = b'{\"opaque\":\"the privileged layer never parses this\"}'
PROFILE_DIGEST = hashlib.sha256(PROFILE_BYTES).hexdigest()

def scene(cinv='CINV-000042'):
    base = tempfile.mkdtemp(dir=WORK)
    execution = os.path.join(base, 'execution', cinv)
    invocation = os.path.join(base, 'handoff', cinv)
    os.makedirs(execution)
    os.makedirs(invocation)
    published = os.path.join(invocation, policy_mod.PROFILE_NAME)
    with open(published, 'wb') as handle:
        handle.write(PROFILE_BYTES)
    os.chmod(published, 0o444)
    document = {
        'cinv': cinv, 'cimp': 'CIMP-000001', 'profile_digest': PROFILE_DIGEST,
        'handoff_root': policy_mod.HANDOFF_ROOT, 'profile_schema_version': 1,
        'commitment_digest': 'b' * 64, 'lifecycle_state': 'launch_authorized',
    }
    record = os.path.join(execution, policy_mod.LAUNCH_RECORD_NAME)
    with open(record, 'wb') as handle:
        handle.write(json.dumps(document).encode('utf-8'))
    os.chmod(record, 0o600)
    os.chmod(invocation, 0o555)
    return {policy_mod.EXECUTION_ROOT: os.path.join(base, 'execution'),
            policy_mod.HANDOFF_ROOT: os.path.join(base, 'handoff')}

class Recorder:
    '''Records what it was asked to do and performs none of it.'''

    def __init__(self, fail_at=None, uid=999, gid=987, groups=(987,), nnp=1,
                 roots=None):
        self.calls = []
        self.roots = scene() if roots is None else roots
        self._fail_at = fail_at
        self._uid, self._gid, self._groups = uid, gid, groups
        self._nnp = nnp
        self.dropped = False

    def _step(self, name, *detail):
        self.calls.append((name,) + detail)
        if self._fail_at == name:
            raise OSError(1, name + ' refused')

    def open_directory(self, path):
        target = self.roots.get(path)
        if target is None:
            raise OSError(2, 'no such governed root', path)
        return os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                       | os.O_DIRECTORY)

    def close_extra_descriptors(self, allowlist):
        self._step('close_extra_descriptors', tuple(allowlist))

    def setgroups(self, groups):
        self._step('setgroups', tuple(groups))

    def setgid(self, gid):
        self._step('setgid', gid)

    def setuid(self, uid):
        self._step('setuid', uid)
        self.dropped = True

    def credentials(self):
        if not self.dropped:
            return action.Credentials(0, 0, 0, 0, 0, 0, (0,))
        return action.Credentials(self._uid, self._uid, self._uid,
                                  self._gid, self._gid, self._gid,
                                  tuple(self._groups))

    def set_no_new_privs(self):
        self._step('set_no_new_privs')

    def get_no_new_privs(self):
        if self._fail_at == 'get_no_new_privs':
            raise OSError(1, 'refused')
        return self._nnp

    def execve(self, path, argv, environment):
        self.calls.append(('execve', path, tuple(argv), tuple(environment)))
        raise action.WorkerExecuted(path)

class Quota:
    DERIVE = object()

    def __init__(self, error=None, project=DERIVE):
        self._error = error
        self._project = project

    def project_id(self, cinv):
        return 1_000_000 + int(cinv[5:])

    def apply(self, cinv):
        if self._error is not None:
            raise self._error
        return (self.project_id(cinv) if self._project is Quota.DERIVE
                else self._project)

def executed(recorder):
    return [call for call in recorder.calls if call[0] == 'execve']

def run(policy, recorder, quota=None, root=True):
    try:
        launch = action.authenticate_launch(policy, backend=recorder)
    except policy_mod.TransitionRefused as error:
        return error
    try:
        action.perform_transition(policy, launch_authorisation=launch,
                                  backend=recorder,
                                  quota=Quota() if quota is None else quota,
                                  assume_root=root)
    except action.WorkerExecuted:
        return 'executed'
    except policy_mod.TransitionRefused as error:
        return error
"

run_case "the two policies differ in the worker target and in nothing else" "${TRANSITION_PRELUDE}
production = policy_mod.policy_for(['prog', 'CINV-000042'])
verification = verify_mod.policy_for(['prog', 'CINV-000042'])
differing = {field.name for field in dataclasses.fields(production)
             if getattr(production, field.name) != getattr(verification, field.name)}
assert differing == {'worker_script'}, differing
assert production.worker_script == '/usr/libexec/kyri-exec-worker.py'
assert verification.worker_script == '/usr/libexec/kyri-exec-verify-worker.py'
assert verify_mod.WORKER_SCRIPT == verification.worker_script
assert verify_mod.PRODUCTION_WORKER_SCRIPT == production.worker_script
print('OK')
"

run_case "the transition execs the verification worker with the ruled argv" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
recorder = Recorder()
assert run(policy, recorder) == 'executed'
calls = executed(recorder)
assert len(calls) == 1, calls
_, path, argv, environment = calls[0]
assert path == '/usr/bin/python3'
assert argv == ('/usr/bin/python3', '/usr/libexec/kyri-exec-verify-worker.py',
                'CINV-000042', 'CIMP-000001', PROFILE_DIGEST), argv
assert len(argv) == 5
assert environment == policy_mod.ENVIRONMENT
print('OK')
"

run_case "the production transition still execs the production worker" "${TRANSITION_PRELUDE}
policy = policy_mod.policy_for(['prog', 'CINV-000042'])
recorder = Recorder()
assert run(policy, recorder) == 'executed'
_, path, argv, _ = executed(recorder)[0]
assert argv[1] == '/usr/libexec/kyri-exec-worker.py', argv
print('OK')
"

run_case "the verification transition performs the production sequence exactly" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
recorder = Recorder()
assert run(policy, recorder) == 'executed'
names = [call[0] for call in recorder.calls]
assert names == ['close_extra_descriptors', 'setgroups', 'setgid', 'setuid',
                 'set_no_new_privs', 'execve'], names
assert ('setgroups', (987,)) in recorder.calls
assert ('setgid', 987) in recorder.calls
assert ('setuid', 999) in recorder.calls
assert ('close_extra_descriptors', (0, 1, 2, 3)) in recorder.calls
print('OK')
"

run_case "the argv builder refuses an ungoverned target and a forged record" "${TRANSITION_PRELUDE}
launch = action.authenticate_launch(verify_mod.policy_for(['p', 'CINV-000042']),
                                    backend=Recorder())
for target in ('/tmp/worker.py', 'kyri-exec-worker.py', '', '/usr/bin/python3',
               '../usr/libexec/kyri-exec-worker.py'):
    try:
        policy_mod.worker_argv(launch, worker_script=target)
    except policy_mod.TransitionRefused:
        continue
    raise AssertionError('the builder accepted ' + repr(target))

class Forged:
    cinv = 'CINV-000042'
    cimp = 'CIMP-000001'
    profile_digest = 'c' * 64

try:
    policy_mod.worker_argv(Forged(), worker_script=verify_mod.WORKER_SCRIPT)
except policy_mod.TransitionRefused:
    print('OK')
else:
    raise AssertionError('the builder accepted an unauthenticated record')
"

run_case "a verification policy cannot be derived from a substituted production" "${TRANSITION_PRELUDE}
original = policy_mod.WORKER_SCRIPT
policy_mod.WORKER_SCRIPT = '/usr/libexec/somebody-elses-worker.py'
try:
    verify_mod.policy_for(['prog', 'CINV-000042'])
except policy_mod.TransitionRefused as error:
    assert 'production worker' in str(error), error
else:
    raise AssertionError('a substituted production target was accepted')
finally:
    policy_mod.WORKER_SCRIPT = original
print('OK')
"

# --- the privileged entrypoint, against a fixture library root ---------------

ENTRY_PRELUDE="${TRANSITION_PRELUDE}
entry = load('kyri_exec_verify_entrypoint', '${VERIFY_ENTRY}')

def library(worker_script=None):
    '''A fixture /usr/lib/kyri/python holding the governed modules.

    The entrypoint refuses anything that resolves outside its compiled-in root,
    so exercising it at all means giving it a root -- a temporary one. Nothing
    is installed and no production path is read.
    '''
    root = tempfile.mkdtemp(dir=WORK)
    for name, path in (
            ('kyri_exec_transition', '${PROD_POLICY}'),
            ('kyri_exec_transition_action', '${PROD_ACTION}'),
            ('kyri_exec_quota', 'provisioning/execution/kyri-exec-quota.py'),
            ('kyri_exec_verify', '${VERIFY_POLICY}')):
        shutil.copyfile(path, os.path.join(root, name + '.py'))
    if worker_script is not None:
        target = os.path.join(root, 'kyri_exec_verify.py')
        text = open(target, encoding='utf-8').read().replace(
            'WORKER_SCRIPT = \"/usr/libexec/kyri-exec-verify-worker.py\"',
            'WORKER_SCRIPT = ' + repr(worker_script))
        open(target, 'w', encoding='utf-8').write(text)
    return root

def entrypoint(root, argv):
    for name in ('kyri_exec_transition', 'kyri_exec_transition_action',
                 'kyri_exec_quota', 'kyri_exec_verify'):
        sys.modules.pop(name, None)
    original = entry.RUNTIME_LIBRARY_ROOT
    entry.RUNTIME_LIBRARY_ROOT = root
    sys.path.insert(0, root)
    try:
        return entry.main(argv)
    except SystemExit as error:
        return str(error)
    finally:
        entry.RUNTIME_LIBRARY_ROOT = original
        sys.path.remove(root)
"

run_case "the entrypoint loads the verification policy and refuses malformed argv" "${ENTRY_PRELUDE}
root = library()
assert entrypoint(root, ['prog']) == entry.USAGE
assert entrypoint(root, ['prog', 'CINV-000042', 'extra']) == entry.USAGE
outcome = entrypoint(root, ['prog', 'CINV-12345'])
assert 'refused' in outcome, outcome
print('OK')
"

run_case "the entrypoint refuses a policy module that names the production worker" "${ENTRY_PRELUDE}
root = library(worker_script='/usr/libexec/kyri-exec-worker.py')
outcome = entrypoint(root, ['prog', 'CINV-000042'])
assert 'may not name the production worker' in outcome, outcome
print('OK')
"

run_case "the entrypoint refuses a library root that does not hold its policy" "${ENTRY_PRELUDE}
root = tempfile.mkdtemp(dir=WORK)
outcome = entrypoint(root, ['prog', 'CINV-000042'])
assert 'kyri_exec_verify is not installed' in outcome, outcome
print('OK')
"

run_case "a well-formed invocation stops before any privilege is spent" "${ENTRY_PRELUDE}
root = library()
# There is no authorised launch record for this CINV under the compiled-in
# execution root, which is the correct place for an unprivileged run of this
# suite to stop: nothing was authenticated, no privilege was spent, no
# credential changed, and no worker was executed.
outcome = entrypoint(root, ['prog', 'CINV-000042'])
assert outcome.startswith('refused:'), outcome
assert 'CINV-000042' in outcome or 'execution root' in outcome, outcome
for forbidden in ('executed', 'kyri-exec-worker.py'):
    assert forbidden not in outcome, outcome
print('OK')
"

# ===========================================================================
# E. The fail-closed matrix -- the transition side
# ===========================================================================

run_case "an unestablished quota prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
for quota in (Quota(error=OSError(1, 'no project')), Quota(project=7),
              Quota(project=None)):
    recorder = Recorder()
    outcome = run(policy, recorder, quota=quota)
    assert isinstance(outcome, policy_mod.TransitionRefused), outcome
    assert outcome.execution_excluded
    assert executed(recorder) == []
print('OK')
"

run_case "a wrong execution identity prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
for kwargs in ({'uid': 1000}, {'gid': 100}, {'uid': 0}, {'gid': 0},
               {'groups': (987, 27)}, {'groups': ()}):
    recorder = Recorder(**kwargs)
    outcome = run(policy, recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), (kwargs, outcome)
    assert executed(recorder) == [], kwargs
print('OK')
"

run_case "an incomplete credential drop prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
for step in ('setgroups', 'setgid', 'setuid'):
    recorder = Recorder(fail_at=step)
    outcome = run(policy, recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), outcome
    assert 'credential drop failed' in str(outcome), outcome
    assert executed(recorder) == []
print('OK')
"

run_case "a saved-set identity surviving the drop prevents the exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])

class Partial(Recorder):
    def credentials(self):
        if not self.dropped:
            return action.Credentials(0, 0, 0, 0, 0, 0, (0,))
        # real and effective dropped; saved still root.
        return action.Credentials(999, 999, 0, 987, 987, 987, (987,))

recorder = Partial()
outcome = run(policy, recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'privilege survived the drop' in str(outcome), outcome
assert executed(recorder) == []
print('OK')
"

run_case "no_new_privs failing to establish prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
for recorder in (Recorder(fail_at='set_no_new_privs'),
                 Recorder(fail_at='get_no_new_privs'),
                 Recorder(nnp=0)):
    outcome = run(policy, recorder)
    assert isinstance(outcome, policy_mod.TransitionRefused), outcome
    assert 'no_new_privs' in str(outcome), outcome
    assert executed(recorder) == []
print('OK')
"

run_case "a failed descriptor closure prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
recorder = Recorder(fail_at='close_extra_descriptors')
outcome = run(policy, recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'descriptor cleanup failed' in str(outcome), outcome
assert executed(recorder) == []
print('OK')
"

run_case "a transition without root prevents the verification exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000042'])
recorder = Recorder()
outcome = run(policy, recorder, root=False)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert executed(recorder) == []
print('OK')
"

run_case "an absent or unauthorised launch record prevents the exec" "${TRANSITION_PRELUDE}
policy = verify_mod.policy_for(['prog', 'CINV-000099'])
recorder = Recorder()
outcome = run(policy, recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert executed(recorder) == []

# A grammatically valid record naming the unallocated implementation.
roots = scene('CINV-000043')
record = os.path.join(roots[policy_mod.EXECUTION_ROOT], 'CINV-000043',
                      policy_mod.LAUNCH_RECORD_NAME)
document = json.loads(open(record, encoding='utf-8').read())
document['cimp'] = 'CIMP-000000'
open(record, 'w', encoding='utf-8').write(json.dumps(document))
recorder = Recorder(roots=roots)
outcome = run(verify_mod.policy_for(['prog', 'CINV-000043']), recorder)
assert isinstance(outcome, policy_mod.TransitionRefused), outcome
assert 'unallocated CIMP' in str(outcome), outcome
assert executed(recorder) == []
print('OK')
"

# ===========================================================================
# F. The fail-closed matrix -- the worker side
# ===========================================================================

run_case "a malformed launch context is refused before anything is derived" "${CHAIN_PRELUDE}
for cinv, cimp, digest in (
        (None, 'CIMP-000001', 'a' * 64),
        ('', 'CIMP-000001', 'a' * 64),
        ('CINV-12345', 'CIMP-000001', 'a' * 64),
        ('CINV-0000420', 'CIMP-000001', 'a' * 64),
        ('cinv-000042', 'CIMP-000001', 'a' * 64),
        ('CINV-000042', None, 'a' * 64),
        ('CINV-000042', 'CIMP-00001', 'a' * 64),
        ('CINV-000042', 'CIMP-000000', 'a' * 64),
        ('CINV-000042', 'CIMP-000001', 'A' * 64),
        ('CINV-000042', 'CIMP-000001', 'a' * 63),
        ('CINV-000042', 'CIMP-000001', 'sha256:' + 'a' * 64)):
    try:
        W.require_launch_context(cinv=cinv, cimp=cimp, profile_digest=digest)
    except W.WorkerRefused:
        continue
    raise AssertionError('accepted ' + repr((cinv, cimp, digest)))
print('OK')
"

run_case "an unsealed or partly sealed profile descriptor is refused" "${CHAIN_PRELUDE}
profile, handoff = published('seals')
body = P.canonical_profile(profile)
ctx = context(profile)

# Fully sealed: the reference case. Compared by fingerprint rather than by
# object equality -- canonicalisation sorts the profile's sets, so the parsed
# result is the same profile in the canonical order and not the same tuple
# ordering the builder happened to produce.
fd = sealed(body)
try:
    parsed = W.profile_from_descriptor(ctx, descriptor=fd)
    assert P.fingerprint(parsed) == P.fingerprint(profile)
    assert (parsed.cinv, parsed.cimp, parsed.oci_image_id) \\
        == (profile.cinv, profile.cimp, profile.oci_image_id)
finally:
    os.close(fd)

# No seals at all.
fd = sealed(body, seals=0)
try:
    W.profile_from_descriptor(ctx, descriptor=fd)
except W.WorkerRefused as error:
    assert 'mandatory seals' in str(error), error
else:
    raise AssertionError('an unsealed descriptor was accepted')
finally:
    os.close(fd)

# Each mandatory seal missing on its own.
for bit, name in ((W.F_SEAL_SEAL, 'SEAL'), (W.F_SEAL_SHRINK, 'SHRINK'),
                  (W.F_SEAL_GROW, 'GROW'), (W.F_SEAL_WRITE, 'WRITE')):
    fd = sealed(body, seals=W.REQUIRED_SEALS & ~bit)
    try:
        W.profile_from_descriptor(ctx, descriptor=fd)
    except W.WorkerRefused as error:
        assert 'mandatory seals' in str(error), (name, error)
    else:
        raise AssertionError('a descriptor missing F_SEAL_' + name + ' was accepted')
    finally:
        os.close(fd)
assert snapshot_untouched()
print('OK')
"

run_case "a descriptor that is not a sealable object at all is refused" "${CHAIN_PRELUDE}
profile, handoff = published('notseal')
ctx = context(profile)
path = os.path.join(WORK, 'plain-profile')
write(path, P.canonical_profile(profile))
fd = os.open(path, os.O_RDONLY)
try:
    W.profile_from_descriptor(ctx, descriptor=fd)
except W.WorkerRefused as error:
    assert 'sealed object' in str(error) or 'mandatory seals' in str(error), error
else:
    raise AssertionError('an ordinary file was accepted as the sealed profile')
finally:
    os.close(fd)

# A directory, and a closed descriptor number.
fd = os.open(WORK, os.O_RDONLY | os.O_DIRECTORY)
try:
    W.profile_from_descriptor(ctx, descriptor=fd)
except W.WorkerRefused:
    pass
else:
    raise AssertionError('a directory was accepted as the sealed profile')
finally:
    os.close(fd)
try:
    W.profile_from_descriptor(ctx, descriptor=4096)
except W.WorkerRefused:
    print('OK')
else:
    raise AssertionError('a closed descriptor was accepted')
"

run_case "sealed bytes that are not a governed profile are refused" "${CHAIN_PRELUDE}
profile, handoff = published('malformed')
ctx = context(profile)
body = P.canonical_profile(profile)
for corrupted in (b'', b'{}', b'not json at all', body[:-1], body + b' ',
                  b' ' + body, body.replace(b'\"cinv\"', b\"'cinv'\")):
    fd = sealed(corrupted)
    try:
        W.profile_from_descriptor(ctx, descriptor=fd)
    except W.WorkerRefused:
        continue
    finally:
        os.close(fd)
    raise AssertionError('malformed sealed bytes were accepted: ' + repr(corrupted[:40]))
assert snapshot_untouched()
print('OK')
"

run_case "a substituted profile on the sealed descriptor is refused" "${CHAIN_PRELUDE}
profile, handoff = published('subst')
other, _ = published('subst2', cinv='CINV-000043')
ctx = context(profile)
# Authentic, canonical, correctly sealed -- and a different invocation.
fd = sealed(P.canonical_profile(other))
try:
    W.profile_from_descriptor(ctx, descriptor=fd)
except W.WorkerRefused as error:
    assert 'does not match the authorised digest' in str(error), error
else:
    raise AssertionError('a substituted sealed profile was accepted')
finally:
    os.close(fd)
assert snapshot_untouched()
print('OK')
"

run_case "identity substitution is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('identity')
digest = P.fingerprint(profile).profile_digest

# Profile digest that does not describe this profile.
error = refused(profile, handoff, ctx=context(profile, digest='f' * 64))
assert 'authorised digest' in str(error), error

# Cross-CINV substitution: an authentic profile for another invocation.
other, other_handoff = published('identity2', cinv='CINV-000043')
error = refused(other, handoff, ctx=context(other))
assert error is not None

# A CINV in the context that the profile does not name.
mismatched = substituted(profile, cinv='CINV-000043')
error = refused(mismatched, handoff,
                ctx=W.require_launch_context(
                    cinv='CINV-000042', cimp=profile.cimp, profile_digest=digest))
assert error is not None

# A CIMP in the context that the profile does not name.
error = refused(profile, handoff,
                ctx=W.require_launch_context(
                    cinv=profile.cinv, cimp='CIMP-000009', profile_digest=digest))
assert 'different implementation' in str(error), error
print('OK')
"

run_case "policy substitution is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('policy')
governed_fields = P.governed_policy()
assert governed_fields, 'the governed policy is empty'
for field, value in list(governed_fields.items())[:8]:
    if isinstance(value, bool):
        replacement = not value
    elif isinstance(value, int):
        replacement = value + 1
    elif isinstance(value, str):
        replacement = value + '-substituted'
    else:
        continue
    hostile = substituted(profile, **{field: replacement})
    error = refused(hostile, handoff, ctx=context(profile))
    assert error is not None, field
print('OK')
"

run_case "a contract or schema mismatch is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('contract')
for field, value in (('adapter_identity', 'python-podman-v2'),
                     ('payload_schema_version', 99),
                     ('profile_schema_version', P.PROFILE_SCHEMA_VERSION + 1)):
    hostile = substituted(profile, **{field: value})
    error = refused(hostile, handoff,
                    ctx=context(profile,
                                digest=P.fingerprint(hostile).profile_digest))
    assert error is not None, field
print('OK')
"

run_case "an image absent from the identity's store is refused" "${CHAIN_PRELUDE}
profile, handoff = published('image')
error = refused(profile, handoff, images=Images(present=()))
assert 'not present in the execution' in str(error), error

# Present, but a different image: presence of something else is not presence.
error = refused(profile, handoff, images=Images(present=('b' * 64,)))
assert error is not None

# A store that cannot answer is not a store that answered 'absent'.
error = refused(profile, handoff, images=Images(error=OSError(2, 'no store')))
assert 'could not be consulted' in str(error), error
for answer in ('yes', 1, 0, None, [], object()):
    error = refused(profile, handoff, images=Images(answer=answer))
    assert 'no usable answer' in str(error), (answer, error)
print('OK')
"

run_case "an implementation/image mismatch is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('mismatch')
hostile = substituted(profile, oci_image_id='c' * 64)
error = refused(hostile, handoff,
                ctx=context(profile, digest=P.fingerprint(hostile).profile_digest),
                images=Images(present=(IMAGE,)))
assert error is not None
for malformed in ('', 'z' * 64, 'A' * 64, 'a' * 63, 'sha256:' + 'a' * 64):
    hostile = substituted(profile, oci_image_id=malformed)
    error = refused(hostile, handoff,
                    ctx=context(profile,
                                digest=P.fingerprint(hostile).profile_digest))
    assert error is not None, malformed
print('OK')
"

run_case "a payload commitment mismatch is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('payload')
target = os.path.join(handoff, profile.cinv, 'payload')
os.chmod(os.path.join(handoff, profile.cinv), 0o755)
os.chmod(target, 0o644)
with open(target, 'wb') as handle:
    handle.write(b'{\"operation\":\"sum\",\"arguments\":{\"count\":4}}')
os.chmod(target, 0o444)
os.chmod(os.path.join(handoff, profile.cinv), 0o555)
error = refused(profile, handoff)
assert 'not the committed payload' in str(error), error
print('OK')
"

run_case "a package commitment mismatch is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('package')
invocation = os.path.join(handoff, profile.cinv)
member = os.path.join(invocation, 'package', 'helper.py')
os.chmod(invocation, 0o755)
os.chmod(os.path.join(invocation, 'package'), 0o755)
os.chmod(member, 0o644)
with open(member, 'wb') as handle:
    handle.write(b'VALUE = 2\n')
os.chmod(member, 0o444)
os.chmod(os.path.join(invocation, 'package'), 0o555)
os.chmod(invocation, 0o555)
error = refused(profile, handoff)
assert 'not the committed package' in str(error), error
print('OK')
"

run_case "an unusable handoff is refused by the shared chain" "${CHAIN_PRELUDE}
profile, handoff = published('handoff')
empty = os.path.join(WORK, 'empty-handoff')
os.makedirs(empty, exist_ok=True)
error = refused(profile, empty)
assert error is not None
print('OK')
"

# ===========================================================================
# G. The transition's own claims, checked from the far side of execve
# ===========================================================================

run_case "the descriptor allowlist is the ruled one" "${CHAIN_PRELUDE}
assert V.EXPECTED_DESCRIPTORS == frozenset((0, 1, 2, W.PROFILE_FD))
assert W.PROFILE_FD == 3
print('OK')
"

# The three self-checks read this process, so they are exercised by arranging
# the process rather than by describing it.

descriptor_case() {
  local label="$1" expected="$2"
  shift 2
  local actual
  if actual="$(cd "${ROOT}" && "$@" 2>&1)"; then :; else :; fi
  if [[ "${actual}" == *"${expected}"* ]]; then
    pass "${label}"
  else
    fail "${label} -- expected ${expected}, got: ${actual}"
  fi
}

CLOSURE_PY='from tools.capability.execution import verification as V
try:
    print("held", V.require_descriptor_closure())
except Exception as error:
    print("refused:", error)'

descriptor_case "exactly descriptors 0, 1, 2 and 3 satisfy the closure check" \
  "held (0, 1, 2, 3)" \
  bash -c "python3 -c '${CLOSURE_PY}' 3</dev/null"

descriptor_case "an inherited descriptor beyond the allowlist is refused" \
  "descriptors survived the transition's closure: [7]" \
  bash -c "python3 -c '${CLOSURE_PY}' 3</dev/null 7</dev/null"

descriptor_case "a missing sealed profile descriptor is refused" \
  "the ruled descriptors are not present: [3]" \
  bash -c "python3 -c '${CLOSURE_PY}'"

NNP_PY='from tools.capability.execution import verification as V
try:
    print("nnp", V.require_no_new_privs())
except Exception as error:
    print("refused:", error)'

descriptor_case "no_new_privs is confirmed from the kernel, not from a claim" \
  "nnp 1" \
  bash -c "setpriv --no-new-privs python3 -c '${NNP_PY}'"

descriptor_case "a process without no_new_privs is refused" \
  "no_new_privs is '0', and execution requires 1" \
  bash -c "python3 -c '${NNP_PY}'"

run_case "the credential check requires a permanent drop to the ruled identity" "${CHAIN_PRELUDE}
# This process is the coordinator. Every component of the check must refuse it,
# and must refuse naming the identity the contract requires.
try:
    V.require_dropped_credentials(uid=W.WORKER_UID, gid=W.WORKER_GID)
except W.WorkerRefused as error:
    assert 'not permanent' in str(error), error
    assert str(W.WORKER_UID) in str(error), error
else:
    raise AssertionError('the credential check passed outside the worker identity')
# It reads the saved set, not only the effective identity.
assert 'getresuid' in comment_free('${VERIFICATION}')
assert 'getresgid' in comment_free('${VERIFICATION}')
assert 'getgroups' in comment_free('${VERIFICATION}')
print('OK')
"

# ===========================================================================
# H. The success record refuses everything that is not a success
# ===========================================================================

run_case "the success record refuses every deviation from the proof" "${CHAIN_PRELUDE}
profile, handoff = published('deviation')
good = V.execution_record(context(profile), profile)
assert V.success_record(good)

def rejects(**changes):
    record = dict(good)
    record.update(changes)
    try:
        V.success_record(record)
    except W.WorkerRefused:
        return True
    raise AssertionError('the record was emitted with ' + repr(changes))

assert rejects(result='refused')
assert rejects(result=None)
assert rejects(profile_sealed=False)
assert rejects(profile_sealed=1)
assert rejects(handoff_verified=False)
assert rejects(podman_invoked=True)
assert rejects(podman_invoked=0)
assert rejects(image_presence_probed=False)
assert rejects(worker_mode='production')
assert rejects(execution_uid=0)
assert rejects(execution_uid=1000)
assert rejects(execution_gid=0)
assert rejects(execution_uid=True)
assert rejects(profile_schema_version=P.PROFILE_SCHEMA_VERSION + 1)
assert rejects(cinv='CINV-1')
assert rejects(cimp=None)
# Nothing may be added, and material least of all.
assert rejects(payload=PAYLOAD_BYTES.decode())
assert rejects(oci_image_id=profile.oci_image_id)
assert rejects(anything='at all')
# Nothing may be dropped.
for name in list(good):
    partial = dict(good)
    del partial[name]
    try:
        V.success_record(partial)
    except W.WorkerRefused:
        continue
    raise AssertionError('the record was emitted without ' + name)
print('OK')
"

run_case "the record builder refuses inputs that did not pass the chain" "${CHAIN_PRELUDE}
profile, handoff = published('builder')
for context_value, profile_value in (
        (None, profile), ('CINV-000042', profile),
        (context(profile), None), (context(profile), {'cinv': 'CINV-000042'})):
    try:
        V.execution_record(context_value, profile_value)
    except W.WorkerRefused:
        continue
    raise AssertionError('the record builder accepted unvalidated input')
print('OK')
"

# ===========================================================================
# I. Nothing here is live
# ===========================================================================

run_case "this suite runs unprivileged and the G6.1B grant is not live" "${SCAN_PRELUDE}
assert os.getuid() != 0, 'this suite must not run privileged'
# The G6.1B marker, and the only one whose absence is still a statement. The
# grant is what makes the verification boundary reachable by anybody; the
# artifacts merely make it exist. So this is asserted unconditionally, and it
# is the assertion that says the first live crossing has not been authorised.
assert not os.path.exists('/etc/sudoers.d/kyri-exec-verify'), \\
    '/etc/sudoers.d/kyri-exec-verify exists; G6.1B is not live'
# The G6.1A artifacts. This suite runs both in CI, where that installation
# ceremony has not been performed, and on a host where it has, so presence is
# not the assertion -- coherence is. A partial set is the one state the
# transactional installer exists to prevent, and it is refused here rather than
# read as 'some of them happen to be missing'. Whether present bytes are the
# reviewed bytes belongs to 'install-generation-7.sh --verify-installed', which
# holds the reviewed commit; restating it here would be a second opinion.
installed = ('/usr/libexec/kyri-exec-verify',
             '/usr/libexec/kyri-exec-verify-worker.py',
             '/usr/lib/kyri/python/kyri_exec_verify.py',
             '/usr/lib/kyri/python/tools/capability/execution/verification.py')
present = tuple(marker for marker in installed if os.path.exists(marker))
assert len(present) in (0, len(installed)), \\
    'the G6.1A artifacts are partially installed: ' + repr(present)
# Present means installed by that ceremony, which published every one of them
# root-owned and read-only. An artifact this suite could write to would be one
# the boundary does not actually rest on.
for marker in present:
    assert os.stat(marker).st_uid == 0, marker + ' is not root-owned'
    assert not os.access(marker, os.W_OK), marker + ' is writable here'
# Roots from earlier gates keep the ownership those gates gave them, and this
# suite may write to none of them. The runtime library and the authority
# namespace are root-authored; the handoff and execution roots are the
# coordinator's by design, so root ownership is the wrong assertion there.
for namespace in ('/usr/lib/kyri/python', '/var/lib/kyri/implementation-authority'):
    if os.path.exists(namespace):
        assert os.stat(namespace).st_uid == 0, namespace + ' is not root-owned'
        assert not os.access(namespace, os.W_OK), namespace + ' is writable here'
print('OK')
"

run_case "this suite invokes no elevation, no transition, and no runtime" "${SCAN_PRELUDE}
text = pathlib.Path('tests/test-capability-execution-g61-verification.sh').read_text(encoding='utf-8')
body = '\n'.join(line for line in text.splitlines()
                 if not line.lstrip().startswith('#'))
# Assembled rather than written out, so this case does not contain the very
# tokens it asserts are absent from the file it is reading -- which is itself.
for banned in ('su' + 'do ', 'vis' + 'udo', 'pod' + 'man ', 'doc' + 'ker ',
               'systemd-tmp' + 'files', 'install -o ' + 'root',
               'chown ' + 'root', 'git ' + 'push', 'setca' + 'p'):
    assert banned not in body, banned
print('OK')
"

run_case "the G6.1 suite runs in local validation and in CI" "${SCAN_PRELUDE}
name = 'tests/test-capability-execution-g61-verification.sh'
assert name in source('tools/dev/run-validation.sh'), 'local validation omits it'
assert name in source('.github/workflows/ci.yml'), 'ci omits it'
print('OK')
"

PRODUCTION_AFTER="$(snapshot_production "${PRODUCTION_PATHS[@]}")"
if [[ "${PRODUCTION_BEFORE}" == "${PRODUCTION_AFTER}" ]]; then
  pass "no installed or governed path changed while this suite ran"
else
  fail "an installed or governed path changed: ${PRODUCTION_BEFORE} -> ${PRODUCTION_AFTER}"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution G6.1 verification validation passed.\n'
else
  printf 'Capability execution G6.1 verification validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
