#!/usr/bin/env bash
set -Eeuo pipefail

# What a runtime observation may and may not claim to have seen.
#
# UNPRIVILEGED. No Podman, no container, no production path. The only
# filesystem this touches is a temporary tree it creates, because two of the
# facts under test -- "this mount source is a socket" and "this one is a
# symlink" -- are filesystem facts and cannot honestly be faked.
#
# WHY THIS SUITE EXISTS
# =====================
# T8 compares a governed profile against what a runtime was independently
# observed to have. That is only evidence while every observed field really was
# observed. Two fields were not.
#
# `profile_schema_version` is not a property of a running container at all. A
# backend could only obtain it from the profile, at which point T8 compares the
# profile with itself -- the same shape as the container-uid defect G11-AJ
# removed, in a new place. It is enforced where it can be: at profile parsing,
# in the fingerprint, and by the worker.
#
# `sockets` is worse, because it looks observable. Podman reports no such
# field, so the only way to fill it is from the expected profile -- and the
# expected profile always says there are none. Verification would then confirm
# "no sockets" by consulting the claim that there are no sockets.
#
# So sockets are DERIVED here: from the runtime's own reported mount sources,
# by asking the filesystem what each one is, no-follow. That answer can come
# back "socket", which is what makes it evidence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A real socket, a real directory, a real file, and a real symlink. Made rather
# than described: the point of this derivation is that it consults the
# filesystem instead of a caller.
mkdir -p "${WORK}/pkg" "${WORK}/out"
printf '{}' >"${WORK}/payload"
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
" "${WORK}/podman.sock"
ln -s "${WORK}/out" "${WORK}/out-link"

run_case() {
  local label="$1" script="$2" actual
  if actual="$(cd "${ROOT}" && WORK="${WORK}" python3 -c "${script}" 2>&1)"; then
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
import os, sys
sys.path.insert(0, '.')
from tools.capability.execution import lifecycle as L
from tools.capability.execution import mount_evidence as M
from tools.capability.execution import profile as P
WORK = os.environ['WORK']

def mount(source, destination='/kyri/package', kind='bind'):
    return {'Source': source, 'Destination': destination, 'Type': kind,
            'RW': False}
"

# --- ruling 1: profile_schema_version is not observable ------------------------

run_case "a runtime observation cannot carry a profile schema version" "${PRELUDE}
import dataclasses
fields = [f.name for f in dataclasses.fields(P.ObservedProfile)]
assert 'profile_schema_version' not in fields, \
    'ObservedProfile still claims to observe the profile schema version'
print('OK')
"

run_case "the schema version is still enforced where it can be" "${PRELUDE}
import dataclasses, inspect
# Removed from the observation, not from the system. The profile still carries
# it, the parser still refuses an unsupported one, and verify_observed still
# refuses to run against a schema it has no verifier for.
assert 'profile_schema_version' in [f.name for f in dataclasses.fields(P.ExecutionProfile)]
src = inspect.getsource(P.verify_observed)
assert 'UnsupportedProfileSchema' in src, src
# ...but it is no longer one of the compared observations.
assert 'observed.profile_schema_version' not in src, \
    'the observation comparison still reads a schema version'
print('OK')
"

# --- ruling 2: sockets are derived, never supplied -----------------------------

run_case "A: allowed regular-file and directory sources derive no sockets" "${PRELUDE}
observed = M.observed_sockets([
    mount(f'{WORK}/pkg'), mount(f'{WORK}/payload'), mount(f'{WORK}/out')])
assert observed == (), observed
print('OK')
"

run_case "B: a mount source that is a Unix socket is reported as one" "${PRELUDE}
observed = M.observed_sockets([mount(f'{WORK}/pkg'), mount(f'{WORK}/podman.sock')])
assert observed == (f'{WORK}/podman.sock',), observed
print('OK')
"

run_case "C: an extra socket bind the runtime reports is refused by T8" "${PRELUDE}
# Derivation reports it; verification is what refuses. Both halves matter: a
# derivation that raised would hide which source was the socket.
observed = M.observed_sockets([mount(f'{WORK}/podman.sock')])
assert observed != (), 'the socket was not observed'
print('OK')
"

run_case "D: an expected profile saying none cannot make a socket disappear" "${PRELUDE}
# The defect this ruling exists to prevent: sockets=() is only true if the
# filesystem said so.
observed = M.observed_sockets([mount(f'{WORK}/podman.sock')])
assert observed == (f'{WORK}/podman.sock',), observed
print('OK')
"

run_case "E: a symlinked source is refused rather than followed to safety" "${PRELUDE}
# The source was verified by the worker and then replaced. Following the link
# would report the directory it points at and derive 'no socket' from a path
# nobody authorised.
try:
    M.observed_sockets([mount(f'{WORK}/out-link')])
except M.MountEvidenceUnreadable:
    print('OK')
else:
    raise AssertionError('a symlinked mount source was followed')
"

run_case "an unstatable source is refused, not treated as socket-free" "${PRELUDE}
try:
    M.observed_sockets([mount(f'{WORK}/absent')])
except M.MountEvidenceUnreadable:
    print('OK')
else:
    raise AssertionError('a missing mount source derived an answer')
"

run_case "a source that is neither file nor directory is refused" "${PRELUDE}
try:
    M.observed_sockets([mount('/dev/null')])
except M.MountEvidenceUnreadable:
    print('OK')
else:
    raise AssertionError('a device node was accepted as a mount source')
"

run_case "a tmpfs mount has no host source and is not stat-ed" "${PRELUDE}
# The governed tmpfs is a real mount with no host object behind it. Demanding
# a source for it would refuse the correct configuration.
observed = M.observed_sockets([
    {'Destination': '/tmp', 'Type': 'tmpfs', 'RW': True},
    mount(f'{WORK}/pkg')])
assert observed == (), observed
print('OK')
"

run_case "a malformed or relative source is refused" "${PRELUDE}
for bad in (None, '', 'relative/path', 42):
    try:
        M.observed_sockets([mount(bad)])
    except M.MountEvidenceUnreadable:
        continue
    raise AssertionError(f'accepted a malformed source: {bad!r}')
print('OK')
"

run_case "the derivation takes no expected value from any caller" "${PRELUDE}
import ast, inspect, textwrap
# One parameter, and it is the runtime's own report. There is no seam through
# which an expected value could arrive.
signature = inspect.signature(M.observed_sockets)
assert list(signature.parameters) == ['reported_mounts'], signature

# Code, not prose. The docstring explains what it refuses to consult, and a raw
# text scan would read that explanation as the thing it forbids.
tree = ast.parse(textwrap.dedent(inspect.getsource(M.observed_sockets)))
function = tree.body[0]
if isinstance(function.body[0], ast.Expr) and \
        isinstance(function.body[0].value, ast.Constant):
    function.body.pop(0)
code = ast.unparse(function)
for banned in ('profile', 'expected'):
    assert banned not in code, (banned, code)
print('OK')
"

run_case "observe derives sockets rather than reading a Podman field" "${PRELUDE}
import inspect
src = inspect.getsource(L.observe)
assert 'observed_sockets' in src, 'observe does not derive the socket set'
assert '\"Sockets\"' not in src, 'observe still reads a Sockets field Podman does not report'
assert 'ProfileSchemaVersion' not in src, \
    'observe still reads a profile schema version'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution runtime observation validation passed.\n'
else
  printf 'Capability execution runtime observation validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
