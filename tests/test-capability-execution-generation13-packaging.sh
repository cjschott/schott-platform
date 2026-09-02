#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-AU. What Generation 13 packages, and whether the packaged bytes
# are a working runtime.
#
# The installer suite proves the transaction is safe. This one proves the thing
# it installs is right: that the declared surface is exactly the import closure
# of the production entry roots, that the matrix agrees with the live host
# object by object, and that the installed tree runs the supervised execution
# path with the repository removed from the interpreter's reach.
#
# THE LAST PART IS THE ONE THAT MATTERS MOST. A packaging test that imported the
# checkout would pass on a package missing a module, because the checkout has
# every module. Every import below resolves from the fixture library root and is
# asserted to.
#
# FIXTURE ONLY. Nothing here reads or writes a production path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

CEREMONY="${REPOSITORY}/provisioning/execution/install-generation-13.sh"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires_pinned_checkout "${CEREMONY}"

LIBRARY_ROOT=/usr/lib/kyri/python
host_only_requires "${LIBRARY_ROOT}"

WORK="$(mktemp -d)"
FAILURES=0
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${REPOSITORY}" && WORKDIR="${WORK}" python3 -c "${script}" 2>&1)"; then
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
import hashlib, importlib.util, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

CEREMONY = Path('provisioning/execution/install-generation-13.sh')
TEXT = CEREMONY.read_text(encoding='utf-8')
LIBRARY_ROOT = Path('/usr/lib/kyri/python')

def scalar(name):
    found = re.search(rf'^{name}=\"?([^\"\\n]*)\"?\$', TEXT, re.M)
    assert found, name
    return found.group(1)

COMMIT = scalar('COMMIT')
GEN12_COMMIT = scalar('GEN12_COMMIT')
BASELINE_N = int(scalar('EXPECTED_LIBRARY_FILES_BASELINE'))
TARGET_N = int(scalar('EXPECTED_LIBRARY_FILES_TARGET'))

def rows():
    block = TEXT.split('MATRIX=(', 1)[1].split('\\n)', 1)[0]
    out = []
    for line in block.splitlines():
        line = line.strip()
        if not line.startswith('\"'):
            continue
        source, target, mode, op, base, want, group = line.strip('\"').split('|')
        out.append({'source': source,
                    'target': target.replace('\${LIBRARY_ROOT}/', ''),
                    'mode': mode, 'op': op, 'base': base, 'want': want,
                    'group': group})
    return out

ROWS = rows()

def array(name):
    block = TEXT.split(name + '=(', 1)[1].split('\\n)', 1)[0]
    return [line.strip().strip('\"') for line in block.splitlines()
            if line.strip().startswith('\"')]

def blob_digest(commit, path):
    done = subprocess.run(['git', 'show', f'{commit}:{path}'], capture_output=True)
    return hashlib.sha256(done.stdout).hexdigest() if done.returncode == 0 else None

def installed_digest(relative):
    target = LIBRARY_ROOT / relative
    return hashlib.sha256(target.read_bytes()).hexdigest() if target.exists() else None

def closure(commit):
    spec = importlib.util.spec_from_file_location('rc', 'tools/dev/runtime_closure.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    staging = Path(tempfile.mkdtemp())
    tar = subprocess.run(['git', 'archive', '--format=tar', commit,
                          'tools', 'provisioning/execution'],
                         capture_output=True, check=True).stdout
    subprocess.run(['tar', '-x', '-C', str(staging)], input=tar, check=True)
    for name, source in module.FLATTENED.items():
        if (staging / source).exists():
            shutil.copy2(staging / source, staging / (name + '.py'))
    roots = array('CLOSURE_ROOTS')
    result = module.compute(str(staging), roots)
    shutil.rmtree(staging)
    return sorted(result['files']), roots
"

# --- the surface is the closure, and the closure is computed --------------------

run_case "the declared surface is exactly what the import graph requires" "${PRELUDE}
files, roots = closure(COMMIT)
declared = {row['target'] for row in ROWS}
installed = {str(p.relative_to(LIBRARY_ROOT)) for p in LIBRARY_ROOT.rglob('*.py')
             if '__pycache__' not in p.parts}
entrypoints = {entry.split('|')[0] for entry in array('ENTRYPOINT_OBJECTS')}

# Nothing declared that the graph does not need. A matrix row the closure does
# not require widens the installed runtime for no stated reason.
surplus = declared - set(files)
assert not surplus, ('the matrix declares objects the closure does not need', surplus)

# And nothing the graph needs that no ceremony provides.
missing = set(files) - declared - installed - entrypoints
assert not missing, ('the closure needs objects nobody provides', missing)

# The two modules G11-AT had to fix at the source rather than whitelist. They
# are here because the graph reaches them, and the assertion is that the graph
# does -- not that somebody remembered to list them.
for reached in ('tools/capability/execution/supervision.py',
                'tools/capability/execution/recovery.py',
                'kyri_exec_launcher.py', 'kyri_exec_podman.py'):
    assert reached in files, (reached, 'is not reachable from the entry roots')
print('OK')
"

run_case "the entry roots are the surfaces the runtime is really entered through" "${PRELUDE}
files, roots = closure(COMMIT)
assert set(roots) == {
    'tools.capability.cli', 'tools.capability.execution.worker',
    'kyri_exec_worker', 'kyri_exec_transition', 'kyri_exec_transition_action',
    'kyri_exec_verify', 'kyri_exec_quota'}, roots
# The worker entrypoint is a root whose own object lives outside the library
# root. That is why the Podman backend enters the graph naturally, and it is
# why the object itself is not a matrix row.
entrypoints = {entry.split('|')[0] for entry in array('ENTRYPOINT_OBJECTS')}
assert entrypoints == {'kyri_exec_worker.py'}, entrypoints
assert 'kyri_exec_worker.py' not in {row['target'] for row in ROWS}
print('OK')
"

# --- the matrix against the live host -------------------------------------------

run_case "the live host is wholly at one of the two declared generations" "${PRELUDE}
# Once the generation is installed on production the host is the SUCCESSOR, not
# the predecessor, and a row's baseline is no longer what is on disk. What stays
# true either way -- and is the property that matters -- is that every object is
# at exactly one of its two declared states, and that all of them agree.
#
# A THIRD state appears once a LATER generation supersedes one of these rows.
# Generation 14 replaced helpers.py, so that object is now at neither this
# generation's baseline nor its target, and it is not drift: it is a row this
# generation no longer has the last word on. The successor's own matrix is read
# for that, so the exception is derived rather than named here -- which is the
# same fix the Generation-12 packaging suite needed when Generation 13 landed.
def superseded_by_successor():
    # Relative: every case runs from the repository root.
    successor = Path('provisioning/execution/install-generation-14.sh')
    if not successor.is_file():
        return {}
    text = successor.read_text(encoding='utf-8')
    block = text.split('MATRIX=(', 1)[1].split(chr(10) + ')', 1)[0]
    out = {}
    for line in block.splitlines():
        line = line.strip()
        if not line.startswith(chr(34)):
            continue
        _, target, _, operation, _, want, _ = line.strip(chr(34)).split('|')
        if operation == 'REPLACE':
            # chr(36) so bash does not expand this before python sees it: the
            # matrix text carries the literal placeholder, not its value.
            out[target.replace(chr(36) + '{LIBRARY_ROOT}/', '')] = want
    return out

SUPERSEDED = superseded_by_successor()

at_base, at_target, superseded, unknown = [], [], [], []
for row in ROWS:
    have = installed_digest(row['target'])
    if row['target'] in SUPERSEDED and have == SUPERSEDED[row['target']]:
        superseded.append(row['target'])
    elif have == row['want']:
        at_target.append(row['target'])
    elif (row['op'] == 'CREATE' and have is None) or have == row['base']:
        at_base.append(row['target'])
    else:
        unknown.append((row['target'], have))
assert not unknown, ('objects in neither declared state', unknown)
# A superseded row is counted with the target side: reaching the successor's
# bytes means this generation's target was installed and then moved past.
at_target.extend(superseded)
assert not (at_base and at_target), \
    ('the host is split between generations', len(at_base), len(at_target))
assert len(at_base) + len(at_target) == len(ROWS)
print('OK')
"

run_case "every row's target is the byte the reviewed authority carries" "${PRELUDE}
for row in ROWS:
    want = blob_digest(COMMIT, row['source'])
    assert want is not None, (row['source'], 'absent at the reviewed authority')
    assert want == row['want'], (row['source'], want, row['want'])
    assert row['mode'] == '0444', row
print('OK')
"

run_case "the declared counts are the matrix's own, not typed in" "${PRELUDE}
installed = [p for p in LIBRARY_ROOT.rglob('*.py') if '__pycache__' not in p.parts]
creates = [row for row in ROWS if row['op'] == 'CREATE']
# The arithmetic is the matrix's own and holds whatever the host is at.
assert BASELINE_N + len(creates) == TARGET_N, (BASELINE_N, len(creates), TARGET_N)
# And the host is at one of the two counts, never between them -- offset by the
# flattened privileged helper modules the G11-AX ceremony creates into this same
# directory. Those are not runtime objects; they simply live beside them, so the
# absolute count moved by one the day that ceremony ran without a single runtime
# object changing. Read from that ceremony's matrix rather than named here.
def helper_creates():
    ceremony = Path('provisioning/execution/install-g11-ax-helpers.sh')
    if not ceremony.is_file():
        return 0
    block = ceremony.read_text(encoding='utf-8').split(
        'MATRIX=(', 1)[1].split(chr(10) + ')', 1)[0]
    total = 0
    for line in block.splitlines():
        line = line.strip()
        if not line.startswith(chr(34)):
            continue
        fields = line.strip(chr(34)).split('|')
        if fields[3] == 'CREATE' and chr(36) + '{LIBRARY_ROOT}/' in fields[1]:
            total += 1
    return total

offset = helper_creates()
assert len(installed) in (BASELINE_N + offset, TARGET_N + offset), \
    (len(installed), BASELINE_N, TARGET_N, offset)
# And the operations are only the two this transaction implements.
assert {row['op'] for row in ROWS} == {'CREATE', 'REPLACE'}, {row['op'] for row in ROWS}
print(f'OK' if len(ROWS) == 21 else f'unexpected row count {len(ROWS)}')
"

run_case "the reviewed authority is an ancestor and carries every byte" "${PRELUDE}
import subprocess
assert subprocess.run(['git', 'merge-base', '--is-ancestor', COMMIT, 'HEAD']).returncode == 0
assert subprocess.run(['git', 'merge-base', '--is-ancestor', GEN12_COMMIT, COMMIT]).returncode == 0
# The authority is pinned, not a moving reference.
assert len(COMMIT) == 40 and set(COMMIT) <= set('0123456789abcdef'), COMMIT
assert 'HEAD' not in TEXT.split('MATRIX=(')[0].split('COMMIT=')[1][:80]
print('OK')
"

# --- coherence groups ------------------------------------------------------------

run_case "every changing object belongs to a declared coherence group" "${PRELUDE}
groups = {}
for row in ROWS:
    groups.setdefault(row['group'], []).append(row['target'])
assert set(groups) == {'A', 'B', 'C'}, sorted(groups)

# The three splits that would be dangerous, and the group each pairing must
# share. A supervisor installed without its result writer would execute real
# workloads and record them under a contract that predates the outcome it
# reports; a worker without its backend fails where it matters most.
def group_of(target):
    for row in ROWS:
        if row['target'] == target:
            return row['group']
    raise AssertionError(target)

assert group_of('tools/capability/execution/worker.py') == \\
       group_of('kyri_exec_podman.py'), 'the worker and its backend are separable'
assert group_of('tools/capability/execution/supervision.py') == \\
       group_of('kyri_exec_launcher.py'), 'the supervisor and its launcher are separable'
assert group_of('tools/capability/records.py') == \\
       group_of('tools/capability/coordinator.py'), 'the result contract is split'
assert group_of('tools/capability/execution/recovery.py') == \\
       group_of('tools/capability/execution/helpers.py'), 'recovery and readiness are split'
print('OK')
"

# --- the privileged surface is somebody else's -----------------------------------

run_case "no matrix row names a helper, a grant or a deployment identity" "${PRELUDE}
helper_library = set(array('EXCLUDED_HELPER_LIBRARY'))
assert helper_library == {'kyri_exec_transition.py', 'kyri_exec_transition_action.py',
                          'kyri_exec_verify.py', 'kyri_exec_quota.py'}, helper_library
targets = {row['target'] for row in ROWS}
assert not (targets & helper_library), targets & helper_library
for forbidden in ('sudoers', 'coordinator-identity.json', 'execution-identity.json',
                  '/usr/libexec/'):
    for row in ROWS:
        assert forbidden not in row['target'], (row['target'], forbidden)
# The decision surfaces stay out of the installed runtime entirely.
excluded = set(array('EXCLUDED'))
assert 'tools/trust/gateway.py' in excluded and 'tools/fabric/admission.py' in excluded
for name in excluded:
    assert not (LIBRARY_ROOT / name).exists(), (name, 'is installed')
print('OK')
"

# --- the installed tree is a working runtime -------------------------------------

# A Generation-12 root, reconstructed from reviewed data, then installed.
#
# This used to copy the live library and install on top. That was true until
# the generation was installed on production, at which point the fixture
# started at Generation 13 and the install became a no-op that wrote no
# evidence. A baseline is reviewed data, so it is rebuilt from reviewed data.
GEN12_COMMIT="$(sed -n 's/^GEN12_COMMIT="\(.*\)"$/\1/p' "${CEREMONY}" | head -1)"

matrix_rows() {
  sed -n '/^MATRIX=(/,/^)/p' "${CEREMONY}" | sed -n 's/^"\(.*\)"$/\1/p'
}
row_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }
row_target() {
  local target; target="$(row_field "$1" 2)"
  printf '%s' "${target#\$\{LIBRARY_ROOT\}/}"
}

gen12_blob() {
  local source="$1" wanted="$2" commit
  if [[ "$(git -C "${REPOSITORY}" show "${GEN12_COMMIT}:${source}" 2>/dev/null \
             | sha256sum | cut -d' ' -f1)" == "${wanted}" ]]; then
    git -C "${REPOSITORY}" show "${GEN12_COMMIT}:${source}"
    return 0
  fi
  while IFS= read -r commit; do
    if [[ "$(git -C "${REPOSITORY}" show "${commit}:${source}" 2>/dev/null \
               | sha256sum | cut -d' ' -f1)" == "${wanted}" ]]; then
      git -C "${REPOSITORY}" show "${commit}:${source}"
      return 0
    fi
  done < <(git -C "${REPOSITORY}" log --format=%H -- "${source}")
  return 1
}

build_gen12_root() {
  local root="$1"
  rm -rf "${root}"
  mkdir -p "${root}${LIBRARY_ROOT}" "${root}/root" "${root}/etc/sudoers.d" \
           "${root}/usr/libexec" "${root}/etc/kyri"
  ( cd "${LIBRARY_ROOT}" && find . -type f -name '*.py' -not -path '*__pycache__*' -print0 ) \
    | ( cd "${LIBRARY_ROOT}" && xargs -0 -I{} cp --parents {} "${root}${LIBRARY_ROOT}/" )

  local row target source base
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    target="${root}${LIBRARY_ROOT}/$(row_target "${row}")"
    source="$(row_field "${row}" 1)"
    base="$(row_field "${row}" 5)"
    if [[ "$(row_field "${row}" 4)" == "CREATE" ]]; then
      rm -f "${target}"
      continue
    fi
    mkdir -p "$(dirname "${target}")"
    rm -f "${target}"
    gen12_blob "${source}" "${base}" > "${target}" || return 1
    [[ "$(sha256sum "${target}" | cut -d' ' -f1)" == "${base}" ]] || return 1
    chmod 0444 "${target}"
  done < <(matrix_rows)
  return 0
}

build_installed() {
  local root="$1"
  build_gen12_root "${root}" || return 1
  ( cd "${root}${LIBRARY_ROOT}" && find . -type f -name '*.py' -print0 | sort -z \
      | xargs -0 sha256sum ) \
    | sed "s#  \\./#  ${LIBRARY_ROOT}/#" > "${root}/root/kyri-gen12-library-digests.txt"
  printf 'state COMMITTED\n' > "${root}/root/kyri-gen12-helper-digests.txt"
  ( cd "${REPOSITORY}" && bash "${CEREMONY}" --fixture "${root}" --install ) \
    > "${root}/install.log" 2>&1
}

INSTALLED="${WORK}/gen13"
if build_installed "${INSTALLED}"; then
  pass "a Generation-13 tree was installed into the fixture"
else
  fail "the fixture install failed: $(tail -4 "${INSTALLED}/install.log")"
fi
FIXTURE_LIB="${INSTALLED}${LIBRARY_ROOT}"

installed_case() {
  local label="$1" script="$2" actual
  # The repository is removed from the interpreter's reach, and the working
  # directory with it: a packaging test that could fall back to the checkout
  # would pass on a package missing a module.
  if actual="$(cd / && FIXTURE_LIB="${FIXTURE_LIB}" REPOSITORY="${REPOSITORY}" \
                GEN13_EVIDENCE="${INSTALLED}/root/kyri-gen13-helper-digests.txt" \
                python3 -c "${script}" 2>&1)"; then
    if [[ "${actual}" == "OK" ]]; then pass "${label}"; else fail "${label} -- got: ${actual}"; fi
  else
    fail "${label} -- raised: ${actual}"
  fi
}

INSTALLED_PRELUDE="
import os, sys
ROOT = os.environ['FIXTURE_LIB']
REPO = os.environ['REPOSITORY']
sys.path = [p for p in sys.path
            if not os.path.realpath(p or '.').startswith(os.path.realpath(REPO))]
sys.path.insert(0, ROOT)

def from_package(module):
    where = os.path.realpath(module.__file__)
    assert where.startswith(os.path.realpath(ROOT) + os.sep), \\
        (module.__name__, where, 'resolved outside the installed package')
    return module
"

installed_case "every production entry root imports from the installed package" "${INSTALLED_PRELUDE}
import tools.capability.cli as cli
from tools.capability.execution import worker, adapter, lifecycle, protocol
from tools.capability.execution import supervision, recovery, helpers, identity
import kyri_exec_podman, kyri_exec_launcher
for module in (cli, worker, adapter, lifecycle, protocol, supervision, recovery,
               helpers, identity, kyri_exec_podman, kyri_exec_launcher):
    from_package(module)
print('OK')
"

installed_case "the released interface offers the supervised verbs" "${INSTALLED_PRELUDE}
import tools.capability.cli as cli
from_package(cli)
verbs = sorted([a for a in cli.build_parser()._subparsers._group_actions][0].choices)
assert verbs == ['authorise-launch', 'execute', 'inspect', 'invoke', 'recover',
                 'validate'], verbs
print('OK')
"

installed_case "the supervisor drives the protocol from installed bytes" "${INSTALLED_PRELUDE}
from tools.capability.execution import protocol as PR
from tools.capability.execution import supervision as SV
from tools.capability.execution import profile as P
from tools.capability.execution.implementation_authority import Admission
for module in (PR, SV, P):
    from_package(module)

CINV, CID, IMAGE = 'CINV-000042', 'a' * 64, 'b' * 64
admission = Admission(cimp='CIMP-000001', oci_image_id=IMAGE,
                      adapter_identity='python-podman-v1', payload_schema_version=1,
                      execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
                      argv_contract_identity='fixed-python-entrypoint-v1',
                      provisioning_evidence_digest='b' * 64)
profile = P.build_profile(P.ProfileBinding(
    cinv=CINV, admission=admission, payload_digest='c' * 64,
    package_digest='d' * 64, package_entrypoint='main.py'))
DIGEST = 'e' * 64

def frame(kind, **fields):
    return PR.encode(PR.Message(kind=kind, cinv=CINV, fields=tuple(fields.items())))

script = [
    frame(PR.MessageKind.CREATED, container_id=CID),
    frame(PR.MessageKind.VERIFIED_PROFILE, container_id=CID, profile_digest=DIGEST,
          oci_image_id=IMAGE, cimp=profile.cimp,
          profile_schema_version=profile.profile_schema_version,
          execution_uid=profile.execution_uid, execution_gid=profile.execution_gid),
    frame(PR.MessageKind.STARTED, container_id=CID),
    frame(PR.MessageKind.TERMINAL, container_id=CID, lifecycle_state='exited',
          outcome_class='completed', exit_code=0, started_proven=True,
          started_at='2026-09-01T06:00:00Z', finished_at='2026-09-01T06:00:01Z'),
    frame(PR.MessageKind.COLLECTED, result_digest='f' * 64,
          output_manifest_digest=None, stdout_truncated=False, stderr_truncated=False),
]

class Child:
    def __init__(self):
        self.pending = list(script)
        self.sent = []
        self.reaped = False

    def reader(self):
        # A plain queue is enough and is what the real channel looks like from
        # here: the supervisor is synchronous, so it cannot read past the point
        # it has to send, and the ordering is the protocol's to enforce.
        return self.pending.pop(0) if self.pending else None

    def writer(self, item):
        self.sent.append(item)

    def reap(self, timeout):
        self.reaped = True
        return 0, True

class Launcher:
    def __init__(self):
        self.child = Child()
    def launch(self, cinv):
        return self.child

calls = []
def reconciler(cinv):
    calls.append(cinv)
    return {'invocation_id': cinv, 'outcome': 'absent', 'prior_state': None,
            'container_identity_verified': True, 'final_absent': True, 'reason': None}

launcher = Launcher()
supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=reconciler)
outcome = supervisor.execute(SV.SupervisedBinding(
    cinv=CINV, profile=profile, profile_digest=DIGEST))
assert outcome.outcome_class == 'completed', outcome.outcome_class
assert outcome.succeeded is True
assert outcome.result_digest == 'sha256:' + 'f' * 64
assert calls == [CINV], calls
assert launcher.child.reaped is True
assert supervisor.trace.disposal_proven is True
assert len(launcher.child.sent) == 1, 'the coordinator sent more than start_now'
print('OK')
"

installed_case "start authority and worker death behave from installed bytes" "${INSTALLED_PRELUDE}
from tools.capability.execution import protocol as PR
from tools.capability.execution import supervision as SV
from tools.capability.execution import profile as P
from tools.capability.execution.implementation_authority import Admission
from_package(SV)

CINV, CID = 'CINV-000042', 'a' * 64
admission = Admission(cimp='CIMP-000001', oci_image_id='b' * 64,
                      adapter_identity='python-podman-v1', payload_schema_version=1,
                      execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
                      argv_contract_identity='fixed-python-entrypoint-v1',
                      provisioning_evidence_digest='b' * 64)
profile = P.build_profile(P.ProfileBinding(
    cinv=CINV, admission=admission, payload_digest='c' * 64,
    package_digest='d' * 64, package_entrypoint='main.py'))

def frame(kind, **fields):
    return PR.encode(PR.Message(kind=kind, cinv=CINV, fields=tuple(fields.items())))

class Child:
    def __init__(self, frames):
        self.frames = list(frames); self.sent = []; self.reaped = False
    def reader(self):
        return self.frames.pop(0) if self.frames else None
    def writer(self, item):
        self.sent.append(item)
    def reap(self, timeout):
        self.reaped = True
        return 9, True

class Launcher:
    def __init__(self, frames): self.child = Child(frames)
    def launch(self, cinv): return self.child

calls = []
def reconciler(cinv):
    calls.append(cinv)
    return {'invocation_id': cinv, 'outcome': 'stopped-and-removed',
            'prior_state': 'running', 'container_identity_verified': True,
            'final_absent': True, 'reason': None}

# A worker that announces a start it was never granted is refused by the
# protocol's own table, and reconciliation still runs.
launcher = Launcher([frame(PR.MessageKind.STARTED, container_id=CID)])
supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=reconciler)
try:
    supervisor.execute(SV.SupervisedBinding(cinv=CINV, profile=profile,
                                            profile_digest='e' * 64))
except SV.SupervisionRefused:
    pass
else:
    raise AssertionError('a start before authority was accepted')
assert calls == [CINV], calls
assert supervisor.trace.worker_reaped is True

# And a worker that stops talking is a death, never an outcome.
calls.clear()
launcher = Launcher([frame(PR.MessageKind.CREATED, container_id=CID)])
supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=reconciler)
try:
    supervisor.execute(SV.SupervisedBinding(cinv=CINV, profile=profile,
                                            profile_digest='e' * 64))
except SV.SupervisionRefused as refusal:
    assert refusal.classification is None, refusal.classification
else:
    raise AssertionError('end of stream produced an outcome')
assert calls == [CINV], calls
assert supervisor.trace.disposal_proven is True
print('OK')
"

installed_case "recovery and the execution-safety gate work from installed bytes" "${INSTALLED_PRELUDE}
from tools.capability.execution import recovery as RC
from_package(RC)

class Store:
    def __init__(self, invocations, results):
        self._records = {'capability-invocation': invocations,
                         'capability-result': results}
    def list_records(self, kind):
        return list(self._records.get(kind, ()))

store = Store([{'invocation_record_id': 'CINV-000001',
                'invocation_id': 'CINV-000001',
                'adapter_identity': 'python-podman-v1'}], [])

def absent(cinv):
    return {'invocation_id': cinv, 'outcome': 'absent', 'final_absent': True,
            'container_identity_verified': True, 'prior_state': None, 'reason': None}

def unresolved(cinv):
    raise OSError('the reconciliation helper is not installed')

assert RC.execution_safety(store, reconciler=absent).state == RC.READY
blocked = RC.execution_safety(store, reconciler=unresolved)
assert blocked.state == RC.NOT_READY
assert [f.invocation_id for f in blocked.unresolved] == ['CINV-000001']
assert all(f.interrupted for f in blocked.unresolved)
assert store.list_records('capability-result') == [], 'recovery wrote a result'
print('OK')
"

installed_case "the invoke boundary still enforces G11-X and G11-Y" "${INSTALLED_PRELUDE}
from tools.capability import fabric_evidence as FE
from_package(FE)
# G11-X: the per-invocation operation and scope refusals, read as declared
# constants rather than as text. A module that merely mentioned them in a
# comment would satisfy a substring search and refuse nothing.
declared = {name: getattr(FE, name) for name in dir(FE) if name.startswith('REASON_')}
for name in ('REASON_OPERATION', 'REASON_OPERATION_ABSENT', 'REASON_CAPABILITY_SCOPE',
             'REASON_CLASSIFICATION_SCOPE', 'REASON_TARGET_SCOPE', 'REASON_SCOPE'):
    assert name in declared, (name, sorted(declared))
    assert isinstance(declared[name], str) and declared[name], name
# G11-Y: current eligibility is revalidated at the invocation instant, asserted
# from the call graph of the installed bytes.
import ast
tree = ast.parse(open(FE.__file__, encoding='utf-8').read())
called = {getattr(n.func, 'attr', None) or getattr(n.func, 'id', None)
          for n in ast.walk(tree) if isinstance(n, ast.Call)}
assert 'evaluate_eligibility' in called, 'the boundary no longer asks C5 for eligibility'
classes = {n.name for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
assert {'_FabricReader', '_TrustReader'} <= classes, classes
for name in ('REASON_INELIGIBLE', 'REASON_SUPERSEDED', 'REASON_NOT_ADMITTED'):
    assert name in declared, name
# And the decision surfaces the runtime may never reach are absent.
import importlib
for forbidden in ('tools.trust.gateway', 'tools.trust.evaluator', 'tools.fabric.admission'):
    try:
        importlib.import_module(forbidden)
    except ImportError:
        continue
    raise AssertionError(f'{forbidden} is importable from the installed package')
print('OK')
"

installed_case "helper compatibility reports the installed helper set truthfully" "${INSTALLED_PRELUDE}
from tools.capability.execution import helpers as H
from_package(H)
verdict = H.compatibility()
# The fixture carries no helper at all, so every required object is absent and
# the verdict is incompatible. That is the honest answer for a host that has the
# runtime and not the ceremony that follows it.
assert verdict.verdict in (H.COMPATIBLE, H.INCOMPATIBLE)
assert {h.path for h in verdict.helpers} == {
    '/usr/libexec/kyri-exec-transition', '/usr/libexec/kyri-exec-worker.py',
    '/usr/libexec/kyri-exec-reconcile', '/usr/libexec/kyri-exec-reconcile-worker.py'}
for helper in verdict.helpers:
    assert helper.state in (H.STATE_CURRENT, H.STATE_STALE, H.STATE_ABSENT,
                            H.STATE_UNREADABLE), helper
print('OK')
"

# --- which ceremony has to come first, demonstrated -----------------------------
#
# The helper ceremony installs a worker entrypoint that imports the Podman
# backend, and the backend is a Generation-13 object. So the order is not a
# preference: a host given the new helpers before this generation has a worker
# that cannot resolve what it imports. Shown against two fixtures rather than
# argued.

# A Generation-12 root and nothing else. Built the same way as the one the
# install starts from -- from reviewed data -- because copying the live library
# would compare Generation 13 against itself once the generation is installed.
GEN12_ONLY="${WORK}/gen12-only"
build_gen12_root "${GEN12_ONLY}" \
  || fail "the Generation-12-only fixture could not be built"

order_case() {
  local label="$1" root="$2" expect="$3" actual
  actual="$(cd / && python3 - "${root}${LIBRARY_ROOT}" <<'ORDERPY'
import os, sys
root = sys.argv[1]
sys.path = [p for p in sys.path
            if not os.path.realpath(p or ".").startswith("/opt/schott-platform")]
sys.path.insert(0, root)
try:
    import kyri_exec_podman            # noqa: F401 - the worker's own import
    import kyri_exec_launcher          # noqa: F401 - the coordinator's
except ImportError:
    print("unresolvable")
else:
    print("resolvable")
ORDERPY
)"
  if [[ "${actual}" == "${expect}" ]]; then
    pass "${label}"
  else
    fail "${label} -- expected ${expect}, got ${actual}"
  fi
}

order_case "at Generation 12 the worker's backend and the launcher are unresolvable" \
  "${GEN12_ONLY}" "unresolvable"
order_case "at Generation 13 both resolve, so the helper ceremony comes after" \
  "${INSTALLED}" "resolvable"

run_case "the objects the new helpers import are this generation's to install" "${PRELUDE}
# Stated from the matrix rather than from the demonstration above, so the two
# have to agree: if either the backend or the launcher ever moved to the helper
# ceremony, this would fail and the ordering argument would have to be re-made.
targets = {row['target'] for row in ROWS}
assert 'kyri_exec_podman.py' in targets, targets
assert 'kyri_exec_launcher.py' in targets, targets
# And the worker entrypoint that imports the backend is NOT this ceremony's.
helper_library = set(array('EXCLUDED_HELPER_LIBRARY'))
entrypoints = {entry.split('|')[0] for entry in array('ENTRYPOINT_OBJECTS')}
assert 'kyri_exec_worker.py' in entrypoints
assert not (targets & (helper_library | entrypoints))
print('OK')
"

# --- the evidence records what this runtime expects beside it -------------------

if grep -q '^expects_coordinator_identity /etc/kyri/coordinator-identity.json$' \
     "${INSTALLED}/root/kyri-gen13-helper-digests.txt" \
   && grep -q '^expects_execution_identity /etc/kyri/execution-identity.json$' \
     "${INSTALLED}/root/kyri-gen13-helper-digests.txt" \
   && [[ "$(grep -c '^expects_helper ' "${INSTALLED}/root/kyri-gen13-helper-digests.txt")" == "4" ]]; then
  pass "the evidence records the deployment this runtime expects beside it"
else
  fail "the evidence does not record the expected compatible set"
fi

installed_case "the recorded expectation is the runtime's own declaration" "${INSTALLED_PRELUDE}
from tools.capability.execution import helpers as H
from_package(H)
recorded = {}
with open(os.environ['GEN13_EVIDENCE'], encoding='utf-8') as handle:
    for line in handle:
        if line.startswith('expects_helper '):
            _, path, digest = line.split()
            recorded[path] = digest
declared = {helper.path: helper.digest for helper in H.REQUIRED_HELPERS}
assert recorded == declared, (recorded, declared)
# The record is auditable evidence, not a second decision: what refuses at
# execution time is the module, and this is what it said when it was installed.
assert len(recorded) == 4, recorded
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Generation-13 packaging validation passed.\n'
else
  printf 'Generation-13 packaging validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
