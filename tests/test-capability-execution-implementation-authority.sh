#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural validation for the ENG-0005 first adapter, increment T4.
#
# T4 is the read-only consumer of canonical CIMP/CGEN provisioning authority.
# It validates, it does not provision: no CIMP or CGEN allocation, no image
# admission, no retirement, no repair, no mutation of any provisioning record,
# no Podman, no Fabric, no CINV, and NO EXECUTION.
#
# THE AUTHORITY ROOT IS A DESCRIPTOR. The caller establishes the trusted root
# and hands it over; T4 never resolves or reopens a root pathname, so replacing
# the root path mid-validation cannot redirect it.
#
# INTEGRITY IS GLOBAL. An unsound namespace yields no authorisation at all --
# there is no partial-good-subset, no per-CIMP ignore, and no repair. The tests
# below prove the absence of a salvage path, not merely the presence of an
# error.
#
# Governed by:
#   docs/superpowers/specs/2026-08-11-first-adapter-design.md  §5
#   docs/superpowers/plans/2026-08-11-eng-0005-first-adapter-implementation.md  T4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_file "tools/capability/execution/implementation_authority.py"

# ===========================================================================
# The T4 authority backstop
# ===========================================================================
# T4 may enumerate and read; it may not mutate, execute, or allocate. Read
# operations are permitted because bounded validation requires them, so the
# scan names the specific mutation and authority surfaces instead.

assert_read_only_authority() {
  local report
  report="$(python3 - "${ROOT}" <<'SCANPY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / "tools/capability/execution/implementation_authority.py"

FORBIDDEN_IMPORTS = {
    "subprocess", "multiprocessing", "importlib", "runpy", "ctypes",
    "socket", "http", "urllib", "requests", "asyncio", "docker", "podman",
    "pty", "shlex", "time", "datetime", "random", "secrets", "tempfile",
    "shutil", "glob", "logging", "pathlib",
}
# Mutation of provisioning state, in every spelling.
FORBIDDEN_CALLS = {
    "write", "truncate", "rename", "replace", "unlink", "remove", "rmdir",
    "mkdir", "makedirs", "chmod", "chown", "link", "symlink", "utime",
    "system", "popen", "exec", "eval", "compile", "__import__", "getenv",
    "putenv", "now", "today", "monotonic", "uuid1", "uuid4", "normalize",
    "readlink", "realpath", "abspath", "expanduser", "chdir",
}
FORBIDDEN_TEXT = ("podman", "docker", "sudo", "runuser", "systemd", "/proc/")

if not target.is_file():
    print("module-absent")
    raise SystemExit(0)

findings = []
rel = target.relative_to(root)
tree = ast.parse(target.read_text(encoding="utf-8"))

for node in ast.walk(tree):
    body = getattr(node, "body", None)
    if not isinstance(body, list) or not body:
        continue
    if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
        continue
    first = body[0]
    if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) \
            and isinstance(first.value.value, str):
        body.pop(0)
        if not body:
            body.append(ast.Pass())
ast.fix_missing_locations(tree)

stripped = ast.unparse(tree).lower()
for token in FORBIDDEN_TEXT:
    if token in stripped:
        findings.append(f"{rel}: forbidden token in code: {token}")

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if alias.name.split(".")[0] in FORBIDDEN_IMPORTS:
                findings.append(f"{rel}: forbidden import: {alias.name}")
    elif isinstance(node, ast.ImportFrom):
        name = node.module or ""
        if name.split(".")[0] in FORBIDDEN_IMPORTS:
            findings.append(f"{rel}: forbidden import-from: {name}")
    elif isinstance(node, ast.Call):
        func = node.func
        attr = getattr(func, "attr", None) or getattr(func, "id", None)
        if attr in FORBIDDEN_CALLS:
            findings.append(f"{rel}: forbidden call: {attr}")

# Only descriptor-relative read surfaces are permitted from os.
permitted_os = {
    "open", "read", "close", "fstat", "scandir", "stat", "O_RDONLY",
    "O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC",
}
for node in ast.walk(tree):
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
            and node.value.id == "os" and node.attr not in permitted_os:
        findings.append(f"{rel}: unpermitted os surface: os.{node.attr}")

# os.open must always carry O_NOFOLLOW and always be descriptor-relative.
# Flags are usually a module-level constant, so resolve those first rather than
# only accepting the literal spelled out at the call site.
nofollow_names = set()
for node in tree.body:
    if isinstance(node, ast.Assign) and "O_NOFOLLOW" in ast.unparse(node.value):
        for target in node.targets:
            if isinstance(target, ast.Name):
                nofollow_names.add(target.id)

for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr == "open" \
                and isinstance(func.value, ast.Name) and func.value.id == "os":
            flags = ast.unparse(node.args[1]) if len(node.args) > 1 else ""
            safe = "O_NOFOLLOW" in flags or any(
                name in flags for name in nofollow_names)
            if not safe:
                findings.append(f"{rel}: os.open without O_NOFOLLOW ({flags})")
            if not any(kw.arg == "dir_fd" for kw in node.keywords):
                findings.append(f"{rel}: os.open without dir_fd")

print("\n".join(findings) if findings else "clean")
SCANPY
)"
  if [[ "${report}" == "clean" ]]; then
    pass "T4 is read-only and descriptor-relative: no mutation, execution, or path authority"
  else
    fail "T4 authority backstop found: ${report}"
  fi
}

assert_read_only_authority

# ===========================================================================
# Behaviour
# ===========================================================================

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

# The fixture builder writes canonical provisioning trees. It uses the
# production canonical serialiser so the fixtures are canonical by
# construction rather than by hand-formatting.
PRELUDE="
import hashlib, os, shutil
from tools.capability.execution.canonical_json import serialise
from tools.capability.execution.implementation_authority import (
    current_generation, resolve_implementation,
    ImplementationAuthorityError, IntegrityFailure, ScanLimitExceeded,
    FindingsTruncated, RetiredImplementation, UnknownImplementation,
    Generation, Admission, MAXIMUM_SCAN_ENTRIES, MAXIMUM_SUMMARY_BYTES)
from tools.capability.execution.types import Classification
WORK = os.environ['WORKDIR']
GENESIS = 'CGEN-000000000000'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as handle:
        handle.write(data)

def admission_body(cimp, oci=None):
    return {
        'cimp': cimp,
        'oci_digest': oci or ('sha256:' + 'a' * 64),
        'adapter_identity': 'python-podman-v1',
        'payload_schema_version': 1,
        'execution_profile_schema_version': 1,
        'argv_contract_identity': 'fixed-python-entrypoint-v1',
        'provisioning_evidence_digest': 'b' * 64,
    }

def build(name, cimps=('CIMP-000001',), retired=(), cgen=GENESIS,
          predecessor=None, predecessor_digest=None):
    root = os.path.join(WORK, name)
    if os.path.isdir(root):
        shutil.rmtree(root)
    entries = []
    for cimp in cimps:
        adm = serialise(admission_body(cimp))
        write(os.path.join(root, 'implementations', cimp, 'admission'), adm)
        ret_digest = None
        if cimp in retired:
            ret = serialise({'cimp': cimp})
            write(os.path.join(root, 'implementations', cimp, 'retirement'), ret)
            ret_digest = sha(ret)
        entries.append({'cimp': cimp, 'admission': sha(adm), 'retirement': ret_digest})
    # Real provisioning publishes entries ordered by numeric CIMP; the fixture
    # does the same so the ordering test measures T4's output determinism
    # rather than the order the fixture happened to be written in.
    entries.sort(key=lambda row: row['cimp'])
    aset = serialise({'entries': entries})
    write(os.path.join(root, 'generations', cgen, 'authority-set'), aset)
    gen = serialise({
        'cgen': cgen,
        'predecessor_cgen': predecessor,
        'predecessor_generation_digest': predecessor_digest,
        'authority_set_digest': sha(aset),
    })
    write(os.path.join(root, 'generations', cgen, 'generation'), gen)
    write(os.path.join(root, 'current-generation'),
          serialise({'cgen': cgen, 'generation_digest': sha(gen)}))
    return root

def open_root(root):
    return os.open(root, os.O_RDONLY | os.O_DIRECTORY)

def load(root):
    fd = open_root(root)
    try:
        return current_generation(fd)
    finally:
        os.close(fd)

def refuses(root, expect=IntegrityFailure):
    fd = open_root(root)
    try:
        current_generation(fd)
    except expect:
        return True
    except Exception as error:
        raise AssertionError(f'wrong error: {type(error).__name__}: {error}')
    finally:
        os.close(fd)
    return False
"

# --- valid authority -------------------------------------------------------

run_case "valid genesis authority validates" "${PRELUDE}
generation = load(build('ok'))
assert isinstance(generation, Generation)
assert generation.cgen == GENESIS
assert generation.predecessor_cgen is None
print('OK')
"

run_case "a valid active CIMP resolves to its bound contract" "${PRELUDE}
root = build('active')
generation = load(root)
fd = open_root(root)
admission = resolve_implementation(fd, 'CIMP-000001', generation=generation)
os.close(fd)
assert isinstance(admission, Admission)
assert admission.cimp == 'CIMP-000001'
assert admission.oci_digest == 'sha256:' + 'a' * 64
assert admission.adapter_identity == 'python-podman-v1'
assert admission.payload_schema_version == 1
assert admission.execution_profile_schema_version == 1
assert admission.argv_contract_identity == 'fixed-python-entrypoint-v1'
print('OK')
"

run_case "eligibility is returned as data, not as execution authority" "${PRELUDE}
generation = load(build('elig', cimps=('CIMP-000001', 'CIMP-000002'), retired=('CIMP-000002',)))
assert generation.eligible_cimps == ('CIMP-000001',), generation.eligible_cimps
assert [e.cimp for e in generation.entries] == ['CIMP-000001', 'CIMP-000002']
print('OK')
"

# --- retirement ------------------------------------------------------------

run_case "a retired CIMP is refused for new binding" "${PRELUDE}
root = build('ret', cimps=('CIMP-000001',), retired=('CIMP-000001',))
generation = load(root)
assert generation.eligible_cimps == ()
fd = open_root(root)
try:
    resolve_implementation(fd, 'CIMP-000001', generation=generation)
except RetiredImplementation:
    print('OK')
else:
    raise AssertionError('retired CIMP was bound')
finally:
    os.close(fd)
"

run_case "a retired CIMP stays in the authority set -- history is not dropped" "${PRELUDE}
generation = load(build('hist', cimps=('CIMP-000001', 'CIMP-000002'), retired=('CIMP-000002',)))
assert len(generation.entries) == 2
retired = [e for e in generation.entries if e.cimp == 'CIMP-000002'][0]
assert retired.retirement_digest is not None
print('OK')
"

run_case "an unknown CIMP is refused" "${PRELUDE}
root = build('unk')
generation = load(root)
fd = open_root(root)
try:
    resolve_implementation(fd, 'CIMP-999999', generation=generation)
except UnknownImplementation:
    print('OK')
else:
    raise AssertionError('unknown CIMP resolved')
finally:
    os.close(fd)
"

# --- grammar ---------------------------------------------------------------

run_case "identifier grammars are enforced" "${PRELUDE}
root = build('gram')
generation = load(root)
fd = open_root(root)
for bad in ('CIMP-00001', 'CIMP-0000001', 'cimp-000001', 'CIMP-00000a', '', '../x'):
    try:
        resolve_implementation(fd, bad, generation=generation)
    except ImplementationAuthorityError:
        continue
    os.close(fd)
    raise AssertionError(f'accepted {bad!r}')
os.close(fd)
assert refuses(build('badcgen', cgen='CGEN-00000000000'))
print('OK')
"

run_case "only genesis may carry null predecessor values" "${PRELUDE}
# A non-genesis generation with null predecessors is unverifiable history.
assert refuses(build('nullpred', cgen='CGEN-000000000001'))
print('OK')
"

# --- digest binding --------------------------------------------------------

run_case "authority-set digest mismatch fails closed" "${PRELUDE}
root = build('asetdig')
path = os.path.join(root, 'generations', GENESIS, 'authority-set')
with open(path, 'rb') as handle:
    body = handle.read()
write(path, body.replace(b'\"a\" * 64', b'x') if False else body + b' ')
assert refuses(root)
print('OK')
"

run_case "generation-record digest mismatch fails closed" "${PRELUDE}
root = build('gendig')
path = os.path.join(root, 'generations', GENESIS, 'generation')
with open(path, 'rb') as handle:
    body = handle.read()
write(path, body + b' ')
assert refuses(root)
print('OK')
"

run_case "admission digest disagreeing with the authority set fails closed" "${PRELUDE}
root = build('admdig')
path = os.path.join(root, 'implementations', 'CIMP-000001', 'admission')
write(path, serialise(admission_body('CIMP-000001', oci='sha256:' + 'c' * 64)))
assert refuses(root)
print('OK')
"

run_case "retirement digest disagreeing with the authority set fails closed" "${PRELUDE}
root = build('retdig', cimps=('CIMP-000001',), retired=('CIMP-000001',))
write(os.path.join(root, 'implementations', 'CIMP-000001', 'retirement'),
      serialise({'cimp': 'CIMP-000001', 'extra': 'x'}))
assert refuses(root)
print('OK')
"

# --- identity agreement ----------------------------------------------------

run_case "admission identity must match its canonical location" "${PRELUDE}
root = build('admid')
body = serialise(admission_body('CIMP-000002'))
write(os.path.join(root, 'implementations', 'CIMP-000001', 'admission'), body)
entries = [{'cimp': 'CIMP-000001', 'admission': sha(body), 'retirement': None}]
aset = serialise({'entries': entries})
write(os.path.join(root, 'generations', GENESIS, 'authority-set'), aset)
gen = serialise({'cgen': GENESIS, 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

run_case "retirement identity must match its canonical location" "${PRELUDE}
root = build('retid', cimps=('CIMP-000001',), retired=('CIMP-000001',))
body = serialise({'cimp': 'CIMP-000002'})
write(os.path.join(root, 'implementations', 'CIMP-000001', 'retirement'), body)
entries = [{'cimp': 'CIMP-000001', 'admission': sha(
    serialise(admission_body('CIMP-000001'))), 'retirement': sha(body)}]
aset = serialise({'entries': entries})
write(os.path.join(root, 'generations', GENESIS, 'authority-set'), aset)
gen = serialise({'cgen': GENESIS, 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

run_case "current-generation must name the generation it points at" "${PRELUDE}
root = build('curgen')
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': 'd' * 64}))
assert refuses(root)
print('OK')
"

run_case "generation record must name its own location" "${PRELUDE}
root = build('genloc')
aset_path = os.path.join(root, 'generations', GENESIS, 'authority-set')
with open(aset_path, 'rb') as handle:
    aset = handle.read()
gen = serialise({'cgen': 'CGEN-000000000009', 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

# --- substantiation --------------------------------------------------------

run_case "the manifest is not independent authority: a listed CIMP must exist" "${PRELUDE}
root = build('ghost')
shutil.rmtree(os.path.join(root, 'implementations', 'CIMP-000001'))
assert refuses(root)
print('OK')
"

run_case "an on-disk CIMP absent from the manifest fails closed" "${PRELUDE}
root = build('extra')
write(os.path.join(root, 'implementations', 'CIMP-000002', 'admission'),
      serialise(admission_body('CIMP-000002')))
assert refuses(root)
print('OK')
"

run_case "authority-set ordering must be by numeric CIMP" "${PRELUDE}
root = build('order', cimps=('CIMP-000001', 'CIMP-000002'))
a1 = serialise(admission_body('CIMP-000001'))
a2 = serialise(admission_body('CIMP-000002'))
entries = [{'cimp': 'CIMP-000002', 'admission': sha(a2), 'retirement': None},
           {'cimp': 'CIMP-000001', 'admission': sha(a1), 'retirement': None}]
aset = serialise({'entries': entries})
write(os.path.join(root, 'generations', GENESIS, 'authority-set'), aset)
gen = serialise({'cgen': GENESIS, 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

run_case "duplicate CIMP entries fail closed" "${PRELUDE}
root = build('dup')
a1 = serialise(admission_body('CIMP-000001'))
entries = [{'cimp': 'CIMP-000001', 'admission': sha(a1), 'retirement': None},
           {'cimp': 'CIMP-000001', 'admission': sha(a1), 'retirement': None}]
aset = serialise({'entries': entries})
write(os.path.join(root, 'generations', GENESIS, 'authority-set'), aset)
gen = serialise({'cgen': GENESIS, 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

# --- malformed records -----------------------------------------------------

run_case "a malformed canonical CIMP record fails closed" "${PRELUDE}
root = build('malc')
write(os.path.join(root, 'implementations', 'CIMP-000001', 'admission'), b'{not json')
assert refuses(root)
print('OK')
"

run_case "a malformed generation record fails closed" "${PRELUDE}
root = build('malg')
write(os.path.join(root, 'generations', GENESIS, 'generation'), b'[]')
assert refuses(root)
print('OK')
"

run_case "an admission with an unknown field fails closed" "${PRELUDE}
root = build('unkfield')
body = admission_body('CIMP-000001')
body['extra'] = 'x'
data = serialise(body)
write(os.path.join(root, 'implementations', 'CIMP-000001', 'admission'), data)
entries = [{'cimp': 'CIMP-000001', 'admission': sha(data), 'retirement': None}]
aset = serialise({'entries': entries})
write(os.path.join(root, 'generations', GENESIS, 'authority-set'), aset)
gen = serialise({'cgen': GENESIS, 'predecessor_cgen': None,
                 'predecessor_generation_digest': None,
                 'authority_set_digest': sha(aset)})
write(os.path.join(root, 'generations', GENESIS, 'generation'), gen)
write(os.path.join(root, 'current-generation'),
      serialise({'cgen': GENESIS, 'generation_digest': sha(gen)}))
assert refuses(root)
print('OK')
"

# --- unexpected objects and symlinks ---------------------------------------

run_case "an unexpected object in the implementations namespace fails closed" "${PRELUDE}
root = build('unexp')
write(os.path.join(root, 'implementations', 'stray.tmp'), b'x')
assert refuses(root)
print('OK')
"

run_case "an unexpected object inside a CIMP directory fails closed" "${PRELUDE}
root = build('unexp2')
write(os.path.join(root, 'implementations', 'CIMP-000001', 'notes'), b'x')
assert refuses(root)
print('OK')
"

run_case "a symlinked CIMP directory is refused, not followed" "${PRELUDE}
root = build('symdir')
target = os.path.join(WORK, 'symdir-elsewhere', 'CIMP-000002')
os.makedirs(target, exist_ok=True)
with open(os.path.join(target, 'admission'), 'wb') as handle:
    handle.write(serialise(admission_body('CIMP-000002')))
os.symlink(target, os.path.join(root, 'implementations', 'CIMP-000002'))
assert refuses(root)
print('OK')
"

run_case "a symlinked record file is refused, not followed" "${PRELUDE}
root = build('symfile')
path = os.path.join(root, 'implementations', 'CIMP-000001', 'admission')
elsewhere = os.path.join(WORK, 'symfile-target')
with open(elsewhere, 'wb') as handle:
    handle.write(serialise(admission_body('CIMP-000001')))
os.remove(path)
os.symlink(elsewhere, path)
assert refuses(root)
print('OK')
"

# --- scan and summary bounds ------------------------------------------------

run_case "the scan ceiling is 10,000 and the summary bound is 2 MiB" "${PRELUDE}
assert MAXIMUM_SCAN_ENTRIES == 10000, MAXIMUM_SCAN_ENTRIES
assert MAXIMUM_SUMMARY_BYTES == 2 * 1024 * 1024, MAXIMUM_SUMMARY_BYTES
print('OK')
"

run_case "every encountered entry counts, not only parsed CIMP records" "${PRELUDE}
root = build('counting')
# Junk names that will never parse as a CIMP still consume the ceiling.
base = os.path.join(root, 'implementations')
for index in range(50):
    write(os.path.join(base, f'junk-{index}'), b'x')
fd = open_root(root)
try:
    current_generation(fd)
except IntegrityFailure as error:
    assert error.entries_scanned >= 51, error.entries_scanned
    print('OK')
finally:
    os.close(fd)
"

run_case "entry 10,001 fails closed with the scan-limit classification" "${PRELUDE}
root = build('ceiling')
base = os.path.join(root, 'implementations')
for index in range(MAXIMUM_SCAN_ENTRIES + 1):
    with open(os.path.join(base, f'e{index:06d}'), 'wb') as handle:
        handle.write(b'')
fd = open_root(root)
try:
    current_generation(fd)
except ScanLimitExceeded as error:
    assert error.classification is Classification.IMPLEMENTATION_AUTHORITY_SCAN_LIMIT_EXCEEDED
    assert error.entries_scanned <= MAXIMUM_SCAN_ENTRIES + 1, error.entries_scanned
    print('OK')
else:
    raise AssertionError('the scan ceiling did not fail closed')
finally:
    os.close(fd)
"

run_case "scan-limit and findings-truncated both imply integrity failure" "${PRELUDE}
assert issubclass(ScanLimitExceeded, IntegrityFailure)
assert issubclass(FindingsTruncated, IntegrityFailure)
assert IntegrityFailure.classification is Classification.IMPLEMENTATION_AUTHORITY_INTEGRITY_FAILURE
assert FindingsTruncated.classification is Classification.IMPLEMENTATION_AUTHORITY_FINDINGS_TRUNCATED
print('OK')
"

run_case "an oversize findings summary is truncated-classified, not emitted" "${PRELUDE}
root = build('summary')
base = os.path.join(root, 'implementations')
# Long unexpected names: each produces a finding, and the summary outgrows its
# bound well before the scan ceiling is reached.
name = 'z' * 200
for index in range(9000):
    with open(os.path.join(base, f'{name}{index:05d}'), 'wb') as handle:
        handle.write(b'')
fd = open_root(root)
try:
    current_generation(fd)
except FindingsTruncated as error:
    assert error.classification is Classification.IMPLEMENTATION_AUTHORITY_FINDINGS_TRUNCATED
    print('OK')
except ScanLimitExceeded:
    raise AssertionError('scan ceiling hit before the summary bound')
finally:
    os.close(fd)
"

# --- no salvage path --------------------------------------------------------

run_case "there is no partial-good-subset after corruption" "${PRELUDE}
root = build('subset', cimps=('CIMP-000001', 'CIMP-000002'))
write(os.path.join(root, 'implementations', 'CIMP-000002', 'admission'), b'{bad')
fd = open_root(root)
try:
    current_generation(fd)
except IntegrityFailure:
    pass
else:
    os.close(fd)
    raise AssertionError('a corrupt namespace still produced a generation')
os.close(fd)
# And the good CIMP is not reachable by any other route.
import tools.capability.execution.implementation_authority as module
public = [n for n in dir(module) if not n.startswith('_')]
for banned in ('ignore', 'skip', 'partial', 'salvage', 'repair', 'force'):
    assert not any(banned in n.lower() for n in public), (banned, public)
print('OK')
"

run_case "no provisioning record is mutated by validation" "${PRELUDE}
root = build('nomut')
before = {}
for base, _, names in os.walk(root):
    for name in names:
        p = os.path.join(base, name)
        with open(p, 'rb') as handle:
            before[p] = (sha(handle.read()), os.stat(p).st_mtime_ns)
load(root)
after = {}
for base, _, names in os.walk(root):
    for name in names:
        p = os.path.join(base, name)
        with open(p, 'rb') as handle:
            after[p] = (sha(handle.read()), os.stat(p).st_mtime_ns)
assert before == after, 'validation mutated provisioning state'
print('OK')
"

# --- descriptor discipline -------------------------------------------------

run_case "the authority root is a descriptor, not a pathname" "${PRELUDE}
import inspect
assert list(inspect.signature(current_generation).parameters) == ['root_fd']
params = list(inspect.signature(resolve_implementation).parameters)
assert params == ['root_fd', 'cimp', 'generation'], params
print('OK')
"

run_case "replacing the root path cannot redirect a descriptor-anchored validation" "${PRELUDE}
good = build('anchor-good')
evil = build('anchor-evil')
write(os.path.join(evil, 'implementations', 'CIMP-000001', 'admission'),
      serialise(admission_body('CIMP-000001', oci='sha256:' + 'e' * 64)))
fd = open_root(good)
# The name now refers to a different tree entirely.
moved = os.path.join(WORK, 'anchor-good-moved')
os.rename(good, moved)
os.rename(evil, good)
try:
    generation = current_generation(fd)
    admission = resolve_implementation(fd, 'CIMP-000001', generation=generation)
    assert admission.oci_digest == 'sha256:' + 'a' * 64, admission.oci_digest
    print('OK')
finally:
    os.close(fd)
"

# --- determinism -----------------------------------------------------------

run_case "validated results are deterministically ordered" "${PRELUDE}
root = build('det', cimps=('CIMP-000003', 'CIMP-000001', 'CIMP-000002'))
a = [e.cimp for e in load(root).entries]
b = [e.cimp for e in load(root).entries]
assert a == b == ['CIMP-000001', 'CIMP-000002', 'CIMP-000003'], a
print('OK')
"

run_case "the generation snapshot is frozen and records its own digest" "${PRELUDE}
root = build('snap')
generation = load(root)
assert len(generation.generation_digest) == 64
try:
    generation.cgen = 'CGEN-000000000009'
except Exception:
    print('OK')
else:
    raise AssertionError('the snapshot was mutated')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution T4 implementation-authority validation passed.\n'
else
  printf 'Capability execution T4 implementation-authority validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
