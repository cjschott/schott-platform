#!/usr/bin/env bash
set -Eeuo pipefail

# G11-B: the installed Capability Runtime must satisfy its Fabric dependency
# from the installed surface, not from a repository checkout that happens to be
# on the host.
#
# THE DEFECT. Generation 10 installs `tools/capability/fabric_evidence.py`,
# which imports `..fabric.inspection`. `tools/fabric` is not installed, so on a
# host without /opt/schott-platform the installed runtime cannot import its own
# coordinator or CLI. It has been borrowing a checkout, and nothing in the
# installed surface said so.
#
# WHAT THIS SUITE PROVES.
#
#   RED     the currently installed surface cannot resolve the dependency when
#           the repository is off sys.path -- reproduced against a copy, never
#           against the installed tree.
#   GREEN   a disposable root built from the Generation-11 surface resolves it,
#           and the Capability->Fabric path runs far enough to prove the
#           closure is real rather than merely importable.
#   CONTROL removing one required module from that root fails, for the reason
#           it should fail for and no other.
#
# ISOLATION IS THE POINT. The child interpreter runs with `-S` and `-E`, an
# emptied PYTHONPATH, and a `sys.path` rebuilt to exactly one entry. Every
# resolved module's `__file__` is then asserted to live under the disposable
# root. A suite that proved imports work while quietly leaving the checkout
# reachable would prove nothing at all.
#
# FIXTURE ONLY. Copies out of the installed tree and the repository into a
# temporary directory. It installs nothing, modifies no installed object, and
# touches no production authority.
#
# Governed by:
#   provisioning/execution/generation-11-surface.sh
#   docs/decisions/ADR-0012-distributed-capability-fabric.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

INSTALLED_ROOT="/usr/lib/kyri/python"                    # prod-path-reference
PRODUCTION_FABRIC="/var/lib/kyri/fabric"                 # prod-path-reference
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
INSTALLED_BEFORE="$(production_state "${INSTALLED_ROOT}")"
FABRIC_BEFORE="$(production_state "${PRODUCTION_FABRIC}")"

if [[ ! -d "${INSTALLED_ROOT}/tools/capability" ]]; then
  printf 'SKIP: no installed Capability Runtime on this host\n'
  exit 0
fi

# shellcheck source=provisioning/execution/generation-11-surface.sh
LIBRARY_ROOT="/usr/lib/kyri/python" \
  source "${REPOSITORY}/provisioning/execution/generation-11-surface.sh"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "${WORK}" >/dev/null 2>&1 || true; rm -rf "${WORK}"' EXIT

# --- the surface declaration agrees with the reviewed source -----------------

DIGEST_PROBLEMS=0
for row in "${GENERATION_11_MATRIX[@]}"; do
  src="$(generation_11_field "${row}" 0)"
  want="$(generation_11_field "${row}" 4)"
  if [[ ! -f "${REPOSITORY}/${src}" ]]; then
    fail "surface names ${src}, which is not in the repository"; DIGEST_PROBLEMS=1; continue
  fi
  got="$(sha256sum "${REPOSITORY}/${src}" | cut -d' ' -f1)"
  [[ "${got}" == "${want}" ]] || {
    fail "surface digest for ${src} is ${want} but the source is ${got}"
    DIGEST_PROBLEMS=1; }
done
(( DIGEST_PROBLEMS == 0 )) && \
  pass "every Generation-11 row pins the digest of the reviewed source"

for excluded in "${GENERATION_11_EXCLUDED[@]}"; do
  named=0
  for row in "${GENERATION_11_MATRIX[@]}"; do
    [[ "$(generation_11_field "${row}" 0)" == "${excluded}" ]] && named=1
  done
  (( named == 0 )) || fail "${excluded} is installed but was ruled out of the closure"
done
pass "the governed write path is not part of the installation surface"

# --- build a disposable root -------------------------------------------------

build_root() {
  local root="$1" skip="${2:-}"
  mkdir -p "${root}"
  # Generation 10, exactly as installed.
  ( cd "${INSTALLED_ROOT}" && find . -name '*.py' -not -path '*__pycache__*' -print0 ) \
    | ( cd "${INSTALLED_ROOT}" && xargs -0 -I{} cp --parents {} "${root}/" )
  # Installed objects arrive 0444, and since Generation 11 was installed that
  # copy already carries tools/fabric -- so the overlay below writes over
  # read-only files instead of creating them. Make the fixture writable rather
  # than copying onto a mode nobody chose here.
  chmod -R u+w "${root}"
  # Generation 11, exactly as declared.
  for row in "${GENERATION_11_MATRIX[@]}"; do
    local src target
    src="$(generation_11_field "${row}" 0)"
    target="${root}/${src}"
    if [[ "${src}" == "${skip}" ]]; then
      # A skipped module must be REMOVED, not merely left un-overlaid. Before
      # Generation 11 was installed, declining to copy it was enough because
      # nothing else supplied it; now the installed copy above does, and a
      # control that left the module in place would assert nothing at all.
      rm -f "${target}"
      continue
    fi
    mkdir -p "$(dirname "${target}")"
    cp "${REPOSITORY}/${src}" "${target}"
  done
}

# The child never sees the repository. `-E` drops PYTHONPATH and every other
# PYTHON* variable, the child runs from `/` so the implicit script directory
# cannot be the checkout, and `sys.path` is then filtered: the disposable root
# is the only non-system entry, and any path that could reach a source checkout
# is removed outright.
#
# The standard library and dist-packages stay. Isolating those too would not be
# a stricter test, it would be a different one -- the installed runtime is
# entitled to the system Python and to PyYAML, and an interpreter that cannot
# import `importlib` proves nothing about a Fabric dependency.
isolated() {
  local root="$1" script="$2"
  ( unset PYTHONPATH
    cd /
    python3 -E -c "
import sys
sys.path = ['${root}'] + [
    p for p in sys.path
    if p and 'schott-platform' not in p and not p.startswith('/opt')]
${script}
" 2>&1 )
}

GEN10_ROOT="${WORK}/gen10"
build_root "${GEN10_ROOT}"
# Undo Generation 11 so this root is exactly what is installed today.
rm -rf "${GEN10_ROOT}/tools/fabric"

GEN11_ROOT="${WORK}/gen11"
build_root "${GEN11_ROOT}"

# --- RED: the installed surface, reproduced, cannot resolve the dependency ---

for module in tools.capability.fabric_evidence tools.capability.coordinator \
              tools.capability.cli; do
  out="$(isolated "${GEN10_ROOT}" "
import importlib
try:
    importlib.import_module('${module}')
    print('IMPORTED')
except ModuleNotFoundError as error:
    print(f'ModuleNotFoundError: {error}')
")"
  if [[ "${out}" == *"No module named 'tools.fabric'"* ]]; then
    pass "as installed, ${module} cannot resolve tools.fabric without the checkout"
  else
    fail "as installed, ${module} reported ${out} rather than the missing dependency"
  fi
done

# --- GREEN: the Generation-11 root resolves it, from itself ------------------

for module in tools.capability.fabric_evidence tools.capability.coordinator \
              tools.capability.cli tools.fabric.inspection; do
  out="$(isolated "${GEN11_ROOT}" "
import importlib
m = importlib.import_module('${module}')
print('IMPORTED', m.__file__)
")"
  if [[ "${out}" == IMPORTED* ]]; then
    pass "under the Generation-11 surface, ${module} imports"
  else
    fail "under the Generation-11 surface, ${module} failed: ${out}"
  fi
done

# Every resolved module must have come from the disposable root. This is the
# assertion that makes the rest mean anything.
out="$(isolated "${GEN11_ROOT}" "
import importlib, sys
importlib.import_module('tools.capability.coordinator')
strays = sorted(
    name for name, module in sys.modules.items()
    if name.startswith('tools')
    and getattr(module, '__file__', None)
    and not module.__file__.startswith('${GEN11_ROOT}'))
print('STRAYS', strays)
print('LOADED', len([n for n in sys.modules if n.startswith('tools')]))
")"
if [[ "${out}" == *"STRAYS []"* ]]; then
  pass "no tools module resolved from outside the disposable root"
else
  fail "modules resolved from outside the root: ${out}"
fi
printf '  %s\n' "$(printf '%s' "${out}" | grep '^LOADED' || true)"

# The checkout is genuinely unreachable, not merely unused.
out="$(isolated "${GEN11_ROOT}" "
import sys
print('REPO_ON_PATH', any('schott-platform' in p for p in sys.path))
print('PATH', sys.path)
")"
if [[ "${out}" == *"REPO_ON_PATH False"* ]]; then
  pass "the repository is not on the isolated interpreter's path"
else
  fail "the isolated interpreter could still reach the repository: ${out}"
fi

# --- GREEN: the dependency path actually runs --------------------------------
#
# Importing proves the module resolves. Running the Capability->Fabric call
# against a real store proves the closure is complete: a missing transitive
# dependency would surface here rather than at import.

out="$(isolated "${GEN11_ROOT}" "
import os, tempfile, pathlib
from datetime import datetime, timedelta, timezone
from tools.capability.fabric_evidence import verify_selected_evidence
from tools.fabric.inspection import STATUS_REPORTED, inspect_records
from tools.fabric.store import FabricStore

root = pathlib.Path(tempfile.mkdtemp()) / 'fabric'
FabricStore(root, expected_uid=os.geteuid(), expected_gid=os.getegid())

# C8 read-only inspection: the exact call the Capability Runtime reaches for.
report = inspect_records(str(root), expected_uid=os.geteuid(),
                         expected_gid=os.getegid())
print('STATUS', report.status == STATUS_REPORTED)

# And the Capability-side consumer, run end to end. An empty store cannot
# satisfy it, so the verdict is a refusal -- which is the point: a refusal is a
# result, and reaching one means every transitive import resolved.
verdict = verify_selected_evidence(
    str(root), expected_uid=os.geteuid(), expected_gid=os.getegid(),
    selection_id='CSEL-000001', instance_id='CINST-000001',
    capability_package_id='CPKG-0001',
    evaluated_at=datetime(2026, 8, 26, 9, 0, tzinfo=timezone(timedelta(hours=-5))))
print('VERIFY_RAN', verdict is not None)
print('VERDICT', type(verdict).__name__)
")"
if [[ "${out}" == *"STATUS True"* && "${out}" == *"VERIFY_RAN True"* ]]; then
  pass "the Capability to Fabric path executes from the installed surface alone"
else
  fail "the dependency path did not execute: ${out}"
fi

# --- CONTROL: remove one required module -------------------------------------

CONTROL_ROOT="${WORK}/control"
build_root "${CONTROL_ROOT}" "tools/fabric/models.py"
out="$(isolated "${CONTROL_ROOT}" "
import importlib
try:
    importlib.import_module('tools.capability.fabric_evidence')
    print('IMPORTED')
except ModuleNotFoundError as error:
    print(f'ModuleNotFoundError: {error}')
")"
if [[ "${out}" == *"No module named 'tools.fabric.models'"* ]]; then
  pass "removing one required module fails, naming exactly that module"
else
  fail "the negative control failed for the wrong reason: ${out}"
fi

# --- the suite touched nothing -----------------------------------------------

printf '\n'
if [[ "$(production_state "${INSTALLED_ROOT}")" != "${INSTALLED_BEFORE}" ]]; then
  fail "the installed runtime was modified"
elif [[ "$(production_state "${PRODUCTION_FABRIC}")" != "${FABRIC_BEFORE}" ]]; then
  fail "the production Fabric store was modified"
else
  pass "the installed runtime and the production Fabric store are unchanged"
fi

printf '\n'
if (( FAILURES )); then
  printf '%d assertion(s) failed.\n' "${FAILURES}" >&2
  exit 1
fi
printf 'All installed-closure assertions passed.\n'
