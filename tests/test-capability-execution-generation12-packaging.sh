#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-Z. Generation-12 packaging: the closure, and the runtime it makes.
#
# Generation 11 computed its import closure from one root and kept the rule
# inside its own installer. When ENG-0005 G11-Y made the invocation boundary
# reach C5 eligibility and the Trust read path, that closure went stale and
# nothing said so -- the installed runtime would have resolved those imports
# only because /opt/schott-platform happened to be on `sys.path`, which is the
# exact defect Generation 11 was written to close.
#
# So this suite asks three questions and keeps asking them:
#
#   1. is the Generation-11 surface genuinely insufficient for current source?
#      (a historical fact, pinned so the reason for Generation 12 stays legible)
#   2. does the Generation-12 surface close the import graph from the roots the
#      runtime is actually entered through?
#   3. does a runtime materialised from that surface alone actually import and
#      behave -- with nothing resolving from the checkout?
#
# The third matters most. A closure can look complete on paper while every
# import silently falls back to the repository.
#
# Nothing here reads or writes a production path, installs anything, stages a
# package, or reaches an adapter.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

INSTALLER=provisioning/execution/install-generation-12.sh
LIBRARY_ROOT=/usr/lib/kyri/python

# PART 1 derives the Generation-11 surface from what is installed now, and the
# later parts compare the packaged surface against it. Both need the installed
# Generation-12 runtime; a runner has none, and reporting "0 of 19 rows at their
# target digests" there would say nothing about the package.
# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires "${LIBRARY_ROOT}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
BEFORE="$(mktemp)"; AFTER="$(mktemp)"
INSTALLED_BEFORE="$(mktemp)"; INSTALLED_AFTER="$(mktemp)"
trap 'rm -f "${BEFORE}" "${AFTER}" "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}"' EXIT
[[ -d "${PRODUCTION_FABRIC}" ]] && \
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${BEFORE}"
[[ -d "${LIBRARY_ROOT}" ]] && \
  ( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "${INSTALLED_BEFORE}"

python3 - "${ROOT}" "${INSTALLER}" "${LIBRARY_ROOT}" <<'PYTHON'
import hashlib, os, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT, INSTALLER, LIBRARY_ROOT = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(ROOT, "tools", "dev"))
import runtime_closure  # noqa: E402

FAILURES = []


def check(condition, label):
    print(("PASS: " if condition else "FAIL: ") + label)
    if not condition:
        FAILURES.append(label)


def installer_array(name):
    """One bash array from the installer, read without executing it."""
    text = Path(ROOT, INSTALLER).read_text()
    start = text.index(f"{name}=(\n")
    end = text.index("\n)", start)
    return [line.strip().strip('"')
            for line in text[start + len(name) + 2:end].split("\n")
            if line.strip() and not line.lstrip().startswith("#")]


def installer_value(name):
    for line in Path(ROOT, INSTALLER).read_text().split("\n"):
        if line.startswith(f"{name}="):
            return line.split("=", 1)[1].strip().strip('"')
    raise AssertionError(name)


MATRIX = [row.split("|") for row in installer_array("MATRIX")]
ROOTS = installer_array("CLOSURE_ROOTS")
EXCLUDED = installer_array("EXCLUDED")
COMMIT = installer_value("COMMIT")
BASELINE_N = int(installer_value("EXPECTED_LIBRARY_FILES_BASELINE"))
TARGET_N = int(installer_value("EXPECTED_LIBRARY_FILES_TARGET"))


def materialise(commit, into):
    """The reviewed tree, plus the flattened privileged helpers."""
    into = Path(into)
    into.mkdir(parents=True, exist_ok=True)
    tar = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", commit,
                          "tools", "provisioning/execution"],
                         capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(into)], input=tar, check=True)
    for helper in ("quota", "transition", "transition-action", "verify"):
        src = into / "provisioning" / "execution" / f"kyri-exec-{helper}.py"
        shutil.copy2(src, into / f"kyri_exec_{helper.replace('-', '_')}.py")
    return into


installed = sorted(
    str(p.relative_to(LIBRARY_ROOT))
    for p in Path(LIBRARY_ROOT).rglob("*.py")
    if "__pycache__" not in p.parts)

# Until G11-Z2 the live host WAS Generation 11, so this suite read the
# installed tree and called it the Generation-11 surface. Generation 12 is
# installed now and that shorthand is false: the live tree is the target, not
# the baseline. The Generation-11 surface is therefore derived from the
# generation being installed -- what is installed now, less the pathnames this
# generation creates -- which is exactly what the predecessor held.
#
# That derivation is only sound while the live host is the generation this
# suite pins, so that is asserted first. On Generation 13 this fails saying so,
# rather than reporting a mystifying object count.
def digest_of(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


at_target = sum(1 for row in MATRIX
                if (Path(LIBRARY_ROOT) / row[0]).is_file()
                and digest_of(Path(LIBRARY_ROOT) / row[0]) == row[5])
check(at_target == len(MATRIX),
      f"the live host is the Generation 12 this suite pins "
      f"({at_target}/{len(MATRIX)} declared rows at their target digests)")

created_here = {row[0] for row in MATRIX if row[3] == "CREATE"}
gen11_surface = sorted(set(installed) - created_here)

print("=" * 74)
print("PART 1 — the Generation-11 surface no longer closes the graph")
print("=" * 74)

with tempfile.TemporaryDirectory() as tmp:
    tree = materialise(COMMIT, Path(tmp) / "src")
    closure = runtime_closure.compute(str(tree), ROOTS)
    reachable = set(closure["files"])
    missing_from_gen11 = sorted(reachable - set(gen11_surface))

    check(bool(missing_from_gen11),
          f"the Generation-11 surface is missing reachable modules "
          f"({len(missing_from_gen11)})")
    # The families that made Generation 11 stale, named so the reason survives.
    for expected in ("tools/fabric/eligibility.py", "tools/fabric/trust_adapter.py",
                     "tools/fabric/resources.py", "tools/trust/store.py",
                     "tools/trust/query.py", "tools/trust/scope.py"):
        check(expected in missing_from_gen11,
              f"Generation 11 does not install the now-reachable {expected}")
    check(len(gen11_surface) == BASELINE_N,
          f"the Generation-11 surface is {BASELINE_N} objects "
          f"(got {len(gen11_surface)})")
    check(len(installed) == TARGET_N,
          f"the live installed runtime is the Generation-12 {TARGET_N} objects "
          f"(got {len(installed)})")
    check(closure["external"] == ["yaml"],
          f"the runtime reaches exactly one third-party dependency "
          f"({closure['external']})")

print()
print("=" * 74)
print("PART 2 — the Generation-12 surface closes it")
print("=" * 74)

declared = [row[0] for row in MATRIX]
packaged = sorted(set(installed) | set(declared))

check(len(packaged) == TARGET_N,
      f"the packaged surface is {TARGET_N} objects (got {len(packaged)})")
check(set(reachable) <= set(packaged),
      f"every reachable module is packaged "
      f"(missing: {sorted(set(reachable) - set(packaged))})")
check(set(declared) <= set(reachable),
      f"every declared row is required by the closure "
      f"(surplus: {sorted(set(declared) - set(reachable))})")
check(not (set(installed) - set(packaged)),
      "nothing installed is dropped by this generation")

# The packaged modules the closure does not reach are support modules earlier
# generations installed for their own entry points. They are named, so a new one
# appearing is a decision somebody has to make rather than a silent addition.
SUPPORT = {
    "tools/capability/execution/adapter.py",
    "tools/capability/execution/admin.py",
    "tools/capability/execution/cleanup.py",
    "tools/capability/execution/collector.py",
    "tools/capability/execution/image_store.py",
    "tools/capability/execution/lifecycle.py",
    "tools/capability/execution/protocol.py",
    "tools/capability/execution/quarantine.py",
    "tools/capability/execution/quota.py",
    "tools/capability/execution/verification.py",
    "tools/common/yaml_strict.py",
}
unexplained = sorted(set(packaged) - set(reachable) - SUPPORT)
check(not unexplained,
      f"every packaged module is either reachable or a declared support module "
      f"({unexplained})")

for banned in EXCLUDED:
    check(banned not in packaged, f"the decision surface {banned} is not packaged")
    check(banned not in reachable,
          f"the decision surface {banned} is not even reachable from the roots")

print()
print("=" * 74)
print("PART 3 — an isolated runtime, imported from the package alone")
print("=" * 74)

with tempfile.TemporaryDirectory() as tmp:
    tree = materialise(COMMIT, Path(tmp) / "src")
    lib = Path(tmp) / "lib"
    for rel in packaged:
        source = tree / rel
        if not source.is_file():
            # Only the two deliberately-excluded helpers may lag the reviewed
            # commit; everything else must be present in it.
            check(rel.startswith("kyri_exec_"),
                  f"{rel} is present in the reviewed commit")
            source = Path(LIBRARY_ROOT) / rel
        destination = lib / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    count = sum(1 for _ in lib.rglob("*.py"))
    check(count == TARGET_N,
          f"the isolated runtime holds {TARGET_N} objects (got {count})")

    probe = r'''
import sys, json
lib = sys.argv[1]
# The isolated root first, and the repository removed from consideration
# entirely: a closure can look complete while every import quietly resolves
# from a checkout. The interpreter's own paths stay so the standard library and
# the one packaged third-party dependency still resolve.
sys.path[:] = [lib] + [p for p in sys.path if p and "schott-platform" not in p]
import importlib
names = ["tools.capability.cli", "tools.capability.coordinator",
         "tools.capability.fabric_evidence", "tools.fabric.eligibility",
         "tools.fabric.trust_adapter", "tools.fabric.resources",
         "tools.trust.store", "tools.trust.query", "tools.trust.scope",
         "tools.capability.execution.authorisation",
         "tools.capability.execution.launch",
         "tools.capability.execution.worker"]
loaded = {}
for name in names:
    module = importlib.import_module(name)
    loaded[name] = getattr(module, "__file__", None)
strays = sorted(n for n, f in loaded.items()
                if not f or not f.startswith(lib))
print(json.dumps({"loaded": sorted(loaded), "strays": strays,
                  "repo_on_path": [p for p in sys.path if "schott-platform" in p]}))
'''
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent",
                   "PYTHONDONTWRITEBYTECODE": "1"}
    result = subprocess.run([sys.executable, "-c", probe, str(lib)],
                            capture_output=True, text=True, cwd="/", env=environment)
    check(result.returncode == 0,
          f"the isolated runtime imports cleanly ({result.stderr.strip()[:300]})")
    if result.returncode == 0:
        import json as _json
        report = _json.loads(result.stdout)
        check(len(report["loaded"]) == 12,
              f"every probed module imported ({len(report['loaded'])}/12)")
        check(not report["strays"],
              f"every module resolved from the isolated package "
              f"({report['strays']})")
        check(not report["repo_on_path"],
              f"the repository was not on sys.path ({report['repo_on_path']})")

print()
print("=" * 74)
print("PART 4 — the packaged runtime carries the behaviour it was built for")
print("=" * 74)

# Repository tests prove the source is right. This proves the PACKAGE is: the
# code under test is imported from the isolated tree, so a module left out of
# the closure fails here rather than on a production host.
with tempfile.TemporaryDirectory() as tmp:
    tree = materialise(COMMIT, Path(tmp) / "src")
    lib = Path(tmp) / "lib"
    for rel in packaged:
        source = tree / rel
        if not source.is_file():
            source = Path(LIBRARY_ROOT) / rel
        destination = lib / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    behaviour = r"""
import inspect, json, sys
lib = sys.argv[1]
sys.path[:] = [lib] + [p for p in sys.path if p and "schott-platform" not in p]
from tools.capability.fabric_evidence import verify_selected_evidence
from tools.capability import coordinator, invocation_identity, records
from tools.fabric.eligibility import evaluate_eligibility

signature = inspect.signature(verify_selected_evidence)
result = {
    "source_file": inspect.getsourcefile(verify_selected_evidence),
    "operation_required": ("operation" in signature.parameters
        and signature.parameters["operation"].default is inspect.Parameter.empty),
    "trust_root_required": ("trust_root" in signature.parameters
        and signature.parameters["trust_root"].default is inspect.Parameter.empty),
    "coordinator_operation": "operation" in inspect.signature(
        coordinator.prepare_invocation).parameters,
    "coordinator_trust_root": "trust_root" in inspect.signature(
        coordinator.prepare_invocation).parameters,
    "bind_operation": "operation" in inspect.signature(
        invocation_identity.bind).parameters,
    "record_operation": "operation" in records.INVOCATION_FIELDS,
    "calls_engine": "evaluate_eligibility" in inspect.getsource(
        sys.modules["tools.capability.fabric_evidence"]),
    "reader_surface": sorted(m for m in dir(
        sys.modules["tools.capability.fabric_evidence"]._FabricReader)
        if not m.startswith("_")),
    "trust_reader_surface": sorted(m for m in dir(
        sys.modules["tools.capability.fabric_evidence"]._TrustReader)
        if not m.startswith("_")),
}
# An absent operation must refuse before any record is read, so this needs no
# fixture: the refusal is reached before the store is touched.
from datetime import datetime, timedelta, timezone
verdict = verify_selected_evidence(
    "/nonexistent", expected_uid=0, expected_gid=0, selection_id="CSEL-000001",
    instance_id="CINST-000001", capability_package_id="CPKG-0001",
    operation=None, trust_root="/nonexistent",
    evaluated_at=datetime(2026, 8, 29, tzinfo=timezone(timedelta(hours=-5))))
result["absent_operation_reason"] = verdict.reason
result["absent_operation_supported"] = verdict.supported
print(json.dumps(result))
"""
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent",
                   "PYTHONDONTWRITEBYTECODE": "1"}
    outcome = subprocess.run([sys.executable, "-c", behaviour, str(lib)],
                             capture_output=True, text=True, cwd="/", env=environment)
    check(outcome.returncode == 0,
          f"the packaged runtime answers behavioural questions "
          f"({outcome.stderr.strip()[:300]})")
    if outcome.returncode == 0:
        import json as _json
        got = _json.loads(outcome.stdout)
        check(got["source_file"].startswith(str(lib)),
              f"the code under test came from the package ({got['source_file']})")
        check(got["operation_required"],
              "G11-X: the packaged boundary requires an operation with no default")
        check(got["bind_operation"] and got["record_operation"],
              "G11-X: the operation is bound to the invocation digest and the record")
        check(got["coordinator_operation"] and got["coordinator_trust_root"],
              "the packaged coordinator threads both new inputs")
        check(got["trust_root_required"],
              "G11-Y: the packaged boundary requires a trust root with no default")
        check(got["calls_engine"],
              "G11-Y: the packaged boundary calls the released eligibility engine")
        check(got["reader_surface"] == ["list_records", "read_record"],
              f"G11-Y: the packaged fabric reader is exactly two reads "
              f"({got['reader_surface']})")
        check(got["trust_reader_surface"] == ["all_records", "read"],
              f"G11-Y: the packaged trust reader is exactly two reads "
              f"({got['trust_reader_surface']})")
        check(not got["absent_operation_supported"]
              and got["absent_operation_reason"] == "operation-not-supplied",
              f"G11-X: the packaged boundary refuses an absent operation "
              f"({got['absent_operation_reason']})")

print()
if FAILURES:
    print(f"FAILURES: {len(FAILURES)}")
    for item in FAILURES:
        print(f"  - {item}")
    sys.exit(1)
print("Generation-12 packaging validation passed.")
PYTHON
status=$?

if [[ -d "${PRODUCTION_FABRIC}" ]]; then
  ( cd "${PRODUCTION_FABRIC}" && find . -mindepth 1 -printf '%y %m %s %p\n' | sort ) > "${AFTER}"
  if diff -q "${BEFORE}" "${AFTER}" >/dev/null; then
    printf 'PASS: %s\n' "no production path changed while this suite ran"
  else
    printf 'FAIL: %s\n' "a production path changed" >&2; status=1
  fi
fi
if [[ -d "${LIBRARY_ROOT}" ]]; then
  ( cd "${LIBRARY_ROOT}" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "${INSTALLED_AFTER}"
  if diff -q "${INSTALLED_BEFORE}" "${INSTALLED_AFTER}" >/dev/null; then
    printf 'PASS: %s\n' "the installed runtime was not modified"
  else
    printf 'FAIL: %s\n' "the installed runtime changed" >&2; status=1
  fi
fi

exit "${status}"
