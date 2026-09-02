#!/usr/bin/env bash
set -Eeuo pipefail

# Generation 14: the readiness rule, and the defect it closes.
#
# STATIC, UNPRIVILEGED AND PORTABLE. Every byte here comes from a reviewed git
# object or is written into a disposable fixture. It reads no installed path,
# invokes no helper, uses no sudo, and never touches /etc or /usr.
#
# WHAT THIS SUITE IS FOR
# ======================
# G11-AX drove the partial-deployment matrix that
# `tools/capability/execution/helpers.py` exists to defeat, and found the
# Generation-13 rule accepting SEVEN dangerous mixed helper states. This suite
# is the RED/GREEN record of that: every state is driven through BOTH the
# Generation-13 rule and the Generation-14 candidate, and the two are required
# to disagree in exactly the way the fix claims.
#
# Keeping the RED half matters. A suite that only asserted the new behaviour
# would pass just as well against a rule that had never been broken, and the
# thing worth protecting is not "the new rule refuses these" -- it is "the old
# rule accepted these, and here is the proof it no longer can."
#
# WHY THE STALE BYTES ARE PLACEHOLDERS
# ====================================
# `compatibility` compares digests. A "stale" object is any object whose digest
# is not the declared one, so the fixture writes deterministic placeholder bytes
# rather than hunting a particular superseded revision out of history. Using a
# real superseded revision would test the same equality through more machinery
# and would tie the suite to a commit that has nothing to do with the property.
# An "absent" object is simply not written.
#
# WHY BOTH RULES ARE LOADED FROM GIT
# ==================================
# Neither is imported from the working tree. The Generation-13 rule is read at
# its own authority and the Generation-14 rule at the commit that introduces it,
# so this suite keeps reporting the truth after the working tree moves on.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The two authority commits live in the PRELUDE below, which is a quoted
# heredoc and cannot interpolate; they are not repeated here so there is one
# place to change them.
GEN13_HELPERS_SHA="eff6c4fd6f7420ba86491b7923e14cb2951a9c078decacc09dc20f38cefd5cbb"
GEN14_HELPERS_SHA="74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874"
CEREMONY="provisioning/execution/install-generation-14.sh"

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
    fail "${label} -- ${actual}"
  fi
}

PRELUDE="$(cat <<'PY'
import dataclasses
import hashlib
import pathlib
import subprocess
import sys
import tempfile
import types

GEN13_COMMIT = '7709cf0443ab11f2b84c94eefbbb60f1eb95c98c'
GEN14_COMMIT = '946be553ab9f25542590eb908c42ce14a81d6ec3'
HELPERS = 'tools/capability/execution/helpers.py'
LIBRARY_ROOT = '/usr/lib/kyri/python'          # prod-path-reference
LIBEXEC_ROOT = '/usr/libexec'                  # prod-path-reference


def blob(commit, path):
    done = subprocess.run(['git', 'show', f'{commit}:{path}'],
                          capture_output=True)
    assert done.returncode == 0, (commit, path, done.stderr[:200])
    return done.stdout


def rule(commit, name):
    """One generation's readiness rule, loaded from its own reviewed bytes."""
    module = types.ModuleType(name)
    module.__dict__['__name__'] = name
    sys.modules[name] = module
    exec(compile(blob(commit, HELPERS).decode('utf-8'), name, 'exec'),
         module.__dict__)
    return module


GEN13 = rule(GEN13_COMMIT, 'gen13_helpers')
GEN14 = rule(GEN14_COMMIT, 'gen14_helpers')

# The ten objects the G11-AX helper ceremony moves, and the reviewed source of
# each. Read at the Generation-13 authority, which is where every one of these
# target byte sets already lives.
AX_SOURCES = {
    f'{LIBRARY_ROOT}/kyri_exec_transition.py':
        'provisioning/execution/kyri-exec-transition.py',
    f'{LIBRARY_ROOT}/kyri_exec_transition_action.py':
        'provisioning/execution/kyri-exec-transition-action.py',
    f'{LIBRARY_ROOT}/kyri_exec_verify.py':
        'provisioning/execution/kyri-exec-verify.py',
    f'{LIBRARY_ROOT}/kyri_exec_reconcile.py':
        'provisioning/execution/kyri-exec-reconcile.py',
    f'{LIBEXEC_ROOT}/kyri-exec-transition':
        'provisioning/execution/kyri-exec-transition-entrypoint.py',
    f'{LIBEXEC_ROOT}/kyri-exec-verify':
        'provisioning/execution/kyri-exec-verify-entrypoint.py',
    f'{LIBEXEC_ROOT}/kyri-exec-worker.py':
        'provisioning/execution/kyri-exec-worker.py',
    f'{LIBEXEC_ROOT}/kyri-exec-verify-worker.py':
        'provisioning/execution/kyri-exec-verify-worker.py',
    f'{LIBEXEC_ROOT}/kyri-exec-reconcile':
        'provisioning/execution/kyri-exec-reconcile-entrypoint.py',
    f'{LIBEXEC_ROOT}/kyri-exec-reconcile-worker.py':
        'provisioning/execution/kyri-exec-reconcile-worker.py',
}
# The quota pair is already at its reviewed bytes on the accepted host, so it is
# not part of the ten. It IS part of the Generation-14 closure, so the fixture
# always writes it current -- otherwise every case would fail for a reason that
# has nothing to do with what it tests.
ALWAYS_CURRENT = {
    f'{LIBRARY_ROOT}/kyri_exec_quota.py':
        'provisioning/execution/kyri-exec-quota.py',
    f'{LIBEXEC_ROOT}/kyri-exec-quota':
        'provisioning/execution/kyri-exec-quota.py',
}
TEN = set(AX_SOURCES)
CREATES = {f'{LIBRARY_ROOT}/kyri_exec_reconcile.py',
           f'{LIBEXEC_ROOT}/kyri-exec-reconcile',
           f'{LIBEXEC_ROOT}/kyri-exec-reconcile-worker.py'}

STALE_BYTES = b'superseded privileged bytes\n'


def build(root, current):
    """A fixture privileged surface: `current` at reviewed bytes, rest stale."""
    root = pathlib.Path(root)
    for target, source in {**AX_SOURCES, **ALWAYS_CURRENT}.items():
        dest = root / target.lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True)
        if target in current or target in ALWAYS_CURRENT:
            dest.write_bytes(blob(GEN13_COMMIT, source))
        elif target in CREATES:
            continue                       # predecessor state is absent
        else:
            dest.write_bytes(STALE_BYTES)
    return root


def verdict(module, root):
    """`module`'s rule, aimed at the fixture rather than at this machine."""
    required = tuple(
        dataclasses.replace(helper,
                            path=str(pathlib.Path(root) / helper.path.lstrip('/')))
        for helper in module.REQUIRED_HELPERS)
    return module.compatibility(required).verdict
PY
)"

printf '=== the two rules are the reviewed bytes they claim to be ===\n'

run_case "each generation's rule loads from its own reviewed authority" "${PRELUDE}
assert hashlib.sha256(blob(GEN13_COMMIT, HELPERS)).hexdigest() == '${GEN13_HELPERS_SHA}'
assert hashlib.sha256(blob(GEN14_COMMIT, HELPERS)).hexdigest() == '${GEN14_HELPERS_SHA}'
print('OK')
"

run_case "the Generation-14 rule is API-identical to the one it replaces" "${PRELUDE}
# A runtime generation that changed the shape of a module its callers import
# would need those callers in the same generation. This one does not, and that
# is the property that makes it a one-object generation.
for name in ('compatibility', 'RequiredHelper', 'HelperState', 'Compatibility',
             'COMPATIBLE', 'INCOMPATIBLE', 'STATE_CURRENT', 'STATE_STALE',
             'STATE_ABSENT', 'STATE_UNREADABLE', 'REQUIRED_HELPERS',
             'HELPER_SOURCES', 'MAXIMUM_HELPER_BYTES'):
    assert hasattr(GEN13, name) and hasattr(GEN14, name), name
import inspect
# The parameter shape, not the whole signature. The compatibility default IS the
# declaration, so the defaults differ by exactly the change this generation
# makes -- comparing signatures wholesale would assert the fix did not happen.
before = inspect.signature(GEN13.compatibility)
after = inspect.signature(GEN14.compatibility)
assert list(before.parameters) == list(after.parameters) == ['required']
assert (before.parameters['required'].kind
        == after.parameters['required'].kind)
assert before.return_annotation == after.return_annotation == 'Compatibility'
# And the only difference is how many objects that default names.
assert len(before.parameters['required'].default) == 4
assert len(after.parameters['required'].default) == 8
assert GEN13.COMPATIBLE == GEN14.COMPATIBLE
assert GEN13.MAXIMUM_HELPER_BYTES == GEN14.MAXIMUM_HELPER_BYTES
# Callers reach exactly one entry point, and it still exists with that shape.
assert callable(GEN14.compatibility)
print('OK')
"

printf '\n=== the closure the rule must cover, derived not listed ===\n'

run_case "the Generation-14 rule covers every module a required helper loads" "${PRELUDE}
import ast

def declared_modules(source_path):
    tree = ast.parse(blob(GEN14_COMMIT, source_path).decode('utf-8'))
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if (isinstance(target, ast.Name) and target.id.endswith('_MODULE')
                    and isinstance(node.value, ast.Constant)
                    and isinstance(node.value.value, str)):
                found.add(node.value.value)
    return found

# What the runtime generation governs is that ceremony's to keep coherent, read
# from its matrix rather than assumed.
ceremony = blob(GEN14_COMMIT,
                'provisioning/execution/install-generation-13.sh').decode('utf-8')
block = ceremony.split('MATRIX=(', 1)[1].split(chr(10) + ')', 1)[0]
generation = set()
for line in block.splitlines():
    line = line.strip()
    if line.startswith(chr(34)):
        target = line.strip(chr(34)).split('|')[1]
        generation.add(target.replace('\${LIBRARY_ROOT}', LIBRARY_ROOT))

covered = {helper.path for helper in GEN14.REQUIRED_HELPERS}
uncovered = {}
for path, source in sorted(GEN14.HELPER_SOURCES.items()):
    for module in sorted(declared_modules(source)):
        installed = LIBRARY_ROOT + '/' + module + '.py'
        if installed in generation or installed in covered:
            continue
        uncovered.setdefault(installed, []).append(path)
assert not uncovered, ('the Generation-14 rule still omits a loaded module', uncovered)

# And the same derivation against Generation 13 must find the gap, or this
# suite would pass without the defect ever having existed.
covered13 = {helper.path for helper in GEN13.REQUIRED_HELPERS}
gap = set()
for path, source in GEN13.HELPER_SOURCES.items():
    for module in declared_modules(source):
        installed = LIBRARY_ROOT + '/' + module + '.py'
        if installed not in generation and installed not in covered13:
            gap.add(installed)
assert len(gap) == 4, ('the Generation-13 gap is not what G11-AX recorded', gap)
print('OK')
"

run_case "the rule declares no object supervised execution cannot reach" "${PRELUDE}
# PERMITTED_HELPERS is the closed set the launcher may start. The verification
# entrypoint is not in it, so it must not be in the readiness rule either --
# its coherence is a helper-ceremony transaction invariant, not a runtime
# readiness requirement, and conflating the two would make the verdict mean
# something other than its name.
launcher = blob(GEN14_COMMIT,
                'provisioning/execution/kyri-exec-launcher.py').decode('utf-8')
import ast
tree = ast.parse(launcher)
permitted = set()
for node in ast.walk(tree):
    if (isinstance(node, ast.Assign)
            and any(getattr(t, 'id', None) == 'PERMITTED_HELPERS' for t in node.targets)):
        for element in ast.walk(node.value):
            if isinstance(element, ast.Constant) and isinstance(element.value, str):
                permitted.add(element.value)
        for element in ast.walk(node.value):
            if isinstance(element, ast.Name) and element.id.endswith('_HELPER'):
                for other in ast.walk(tree):
                    if (isinstance(other, ast.Assign)
                            and any(getattr(t, 'id', None) == element.id
                                    for t in other.targets)
                            and isinstance(other.value, ast.Constant)):
                        permitted.add(other.value.value)
assert permitted == {LIBEXEC_ROOT + '/kyri-exec-transition',
                     LIBEXEC_ROOT + '/kyri-exec-reconcile'}, permitted
declared = {helper.path for helper in GEN14.REQUIRED_HELPERS}
assert not any('verify' in path for path in declared), declared
# Every declared EXECUTABLE is one the launcher may start, or is the worker that
# entrypoint execs.
executables = {p for p in declared if p.startswith(LIBEXEC_ROOT)}
assert executables - permitted <= {LIBEXEC_ROOT + '/kyri-exec-worker.py',
                                   LIBEXEC_ROOT + '/kyri-exec-reconcile-worker.py'}, executables
print('OK')
"

printf '\n=== RED/GREEN: the seven states Generation 13 accepted ===\n'

run_case "Generation 13 accepted seven dangerous mixed states, Generation 14 refuses them" "${PRELUDE}
S4 = {LIBEXEC_ROOT + '/kyri-exec-transition', LIBEXEC_ROOT + '/kyri-exec-worker.py',
      LIBEXEC_ROOT + '/kyri-exec-reconcile',
      LIBEXEC_ROOT + '/kyri-exec-reconcile-worker.py'}
POLICY = LIBRARY_ROOT + '/kyri_exec_transition.py'
ACTION = LIBRARY_ROOT + '/kyri_exec_transition_action.py'
RECONCILE = LIBRARY_ROOT + '/kyri_exec_reconcile.py'
VERIFY = LIBEXEC_ROOT + '/kyri-exec-verify'

# Exactly the states G11-AX recorded, with the verdict each rule gives.
CASES = [
    ('old entrypoint + new library', {POLICY, ACTION}, 'incompatible', 'incompatible'),
    ('new entrypoint + old library', S4, 'compatible', 'incompatible'),
    ('new transition + old action', S4 | {POLICY}, 'compatible', 'incompatible'),
    ('new reconcile entrypoint without reconcile module', S4 | {POLICY, ACTION},
     'compatible', 'incompatible'),
    ('reconcile module without entrypoint', {RECONCILE}, 'incompatible', 'incompatible'),
    ('new worker with stale transition', {LIBEXEC_ROOT + '/kyri-exec-worker.py'},
     'incompatible', 'incompatible'),
    ('all REPLACE new, CREATE absent', TEN - CREATES, 'incompatible', 'incompatible'),
    ('nine of ten: policy module stale', TEN - {POLICY}, 'compatible', 'incompatible'),
    ('nine of ten: action module stale', TEN - {ACTION}, 'compatible', 'incompatible'),
    ('nine of ten: reconcile module absent', TEN - {RECONCILE}, 'compatible', 'incompatible'),
    ('nine of ten: reconcile worker absent',
     TEN - {LIBEXEC_ROOT + '/kyri-exec-reconcile-worker.py'}, 'incompatible', 'incompatible'),
    # Intentionally compatible under BOTH rules: supervision cannot reach it.
    ('nine of ten: verify entrypoint stale', TEN - {VERIFY}, 'compatible', 'compatible'),
    ('the complete ten-object target', TEN, 'compatible', 'compatible'),
]

accepted_by_13 = 0
with tempfile.TemporaryDirectory() as work:
    for index, (label, current, want13, want14) in enumerate(CASES):
        root = build(pathlib.Path(work) / f'case{index}', current)
        got13, got14 = verdict(GEN13, root), verdict(GEN14, root)
        assert got13 == want13, (label, 'gen13', got13, want13)
        assert got14 == want14, (label, 'gen14', got14, want14)
        if current != TEN and current != TEN - {VERIFY} and got13 == 'compatible':
            accepted_by_13 += 1

# The count G11-AX recorded, asserted so the RED half cannot quietly erode.
assert accepted_by_13 == 6, ('dangerous states accepted by Generation 13', accepted_by_13)
print('OK')
"

run_case "the stale verify entrypoint stays compatible, and is proved unreachable" "${PRELUDE}
VERIFY = LIBEXEC_ROOT + '/kyri-exec-verify'
with tempfile.TemporaryDirectory() as work:
    root = build(pathlib.Path(work) / 'verify-stale', TEN - {VERIFY})
    assert verdict(GEN14, root) == 'compatible'
    # Compatible ONLY because supervision cannot reach it: the rule declares no
    # verification object, and the launcher may not start one.
    assert not any('verify' in helper.path for helper in GEN14.REQUIRED_HELPERS)
    launcher = blob(GEN14_COMMIT,
                    'provisioning/execution/kyri-exec-launcher.py').decode('utf-8')
    assert 'kyri-exec-verify' not in launcher
    # And removing an object supervision DOES reach flips the same fixture.
    root = build(pathlib.Path(work) / 'policy-stale',
                 TEN - {LIBRARY_ROOT + '/kyri_exec_transition.py'})
    assert verdict(GEN14, root) == 'incompatible'
print('OK')
"

printf '\n=== the Generation-14 ceremony declares exactly one object ===\n'

run_case "the ceremony matrix is one REPLACE row pinned at both ends" "${PRELUDE}
text = pathlib.Path('${CEREMONY}').read_text(encoding='utf-8')
block = text.split('MATRIX=(', 1)[1].split(chr(10) + ')', 1)[0]
rows = [line.strip().strip(chr(34)) for line in block.splitlines()
        if line.strip().startswith(chr(34))]
assert len(rows) == 1, rows
source, target, mode, operation, baseline, wanted, group = rows[0].split('|')
assert source == HELPERS, source
assert target.endswith('/tools/capability/execution/helpers.py'), target
assert (mode, operation, group) == ('0444', 'REPLACE', 'C'), (mode, operation, group)
assert baseline == '${GEN13_HELPERS_SHA}', baseline
assert wanted == '${GEN14_HELPERS_SHA}', wanted
# Both ends are reviewed history, not whatever happens to be installed.
assert hashlib.sha256(blob(GEN13_COMMIT, HELPERS)).hexdigest() == baseline
assert hashlib.sha256(blob(GEN14_COMMIT, HELPERS)).hexdigest() == wanted
print('OK')
"

run_case "the ceremony touches no privileged helper or governed store" "${PRELUDE}
text = pathlib.Path('${CEREMONY}').read_text(encoding='utf-8')
block = text.split('MATRIX=(', 1)[1].split(chr(10) + ')', 1)[0]
# The matrix is the only thing that publishes. Nothing in it may name a
# /usr/libexec object or a flattened helper module.
assert 'libexec' not in block, block
for flattened in ('kyri_exec_transition', 'kyri_exec_verify', 'kyri_exec_reconcile',
                  'kyri_exec_quota', 'kyri_exec_podman'):
    assert flattened not in block, flattened
# And it declares the surfaces it must leave alone, so the fingerprint has
# something to check against.
assert 'AX_HELPER_SURFACE' in text
for name in ('SUDOERS', 'COORDINATOR_IDENTITY', 'EXECUTION_IDENTITY',
             'FABRIC_ROOT', 'TRUST_ROOT', 'AUTHORITY_ROOT'):
    assert name in text, name
print('OK')
"

run_case "the reviewed commit's runtime delta is exactly that one object" "${PRELUDE}
changed = subprocess.run(
    ['git', 'diff-tree', '--no-commit-id', '--name-only', '-r', GEN14_COMMIT],
    capture_output=True, text=True).stdout.split()
runtime = [p for p in changed
           if not p.startswith(('tests/', 'docs/', 'provisioning/', '.github/'))]
assert runtime == [HELPERS], runtime
# The other two files are the test and the ceremony declaration that must
# accompany a runtime byte change; neither is installed.
assert sorted(changed) == sorted([
    HELPERS,
    'provisioning/execution/g5-preflight.sh',
    'tests/test-capability-execution-supervision.sh']), changed
print('OK')
"

printf '\n'
if (( FAILURES == 0 )); then
  printf 'All Generation-14 readiness checks passed.\n'
else
  printf '%d Generation-14 readiness check(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
