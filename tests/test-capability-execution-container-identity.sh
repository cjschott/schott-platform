#!/usr/bin/env bash
set -Eeuo pipefail

# The governed container identity, and the chain that has to agree about it.
#
# STATIC AND UNPRIVILEGED. No Podman, no container, no store, no production
# path. Every observation is a fixture.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AI.2 found the runtime launching workloads as container uid 1000 while
# the admitted image CIMP-000001 declares 65532:65532. The value 1000 was true
# of the Track B alpine image and was never revisited when the Chainguard image
# was admitted.
#
# The reason it survived is the part worth testing. Every layer agreed:
# `profile.EXECUTION_UID` said 1000, `worker.CONTAINER_UID` said 1000, the argv
# requested 1000, Podman reported 1000, and T8 compared 1000 against 1000 and
# passed. A system that checks itself proves only that it is consistent, and
# consistency with the wrong number is what this is for.
#
# So two properties are pinned, and they are different properties:
#
#   1. The identity is STATED ONCE. Two constants that happen to be equal today
#      are the mechanism that produced the defect, not a defence against it.
#   2. T8 verifies something Podman was not told. `Config.User` is an echo of
#      the request -- it reads 65532:65532 even when the mapping is absent and
#      the workload cannot write -- so verifying it proves nothing. The uid/gid
#      MAP is a kernel fact the request does not determine, and that is what
#      must be checked.
#
# The mapping values here were derived from the installed Podman 4.9.3 against
# the real governed image, not invented.

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
import sys
sys.path.insert(0, '.')
from pathlib import Path
from tools.capability.execution import profile as P
from tools.capability.execution import worker as W
from tools.capability.execution import lifecycle as L
"

# --- the identity, and where it is allowed to be stated ------------------------

run_case "the governed container identity is the admitted image's user" "${PRELUDE}
# The G5 ceremony checks the built image's default user as an admission
# CONTRACT. That contract and the runtime constant were never tied together,
# which is exactly how they came to disagree.
text = Path('provisioning/execution/g5-ceremony.sh').read_text(encoding='utf-8')
line = [l for l in text.splitlines() if l.startswith('IMAGE_EXPECT_USER=')]
assert len(line) == 1, line
contract = line[0].split('=', 1)[1].strip().strip('\"')
assert contract == f'{P.EXECUTION_UID}:{P.EXECUTION_GID}', (contract,
    P.EXECUTION_UID, P.EXECUTION_GID)
print('OK')
"

run_case "the container identity is non-root and is the image's, not the host's" "${PRELUDE}
assert P.EXECUTION_UID == 65532, P.EXECUTION_UID
assert P.EXECUTION_GID == 65532, P.EXECUTION_GID
# The host execution identity is a different thing and must not be conflated.
assert P.EXECUTION_UID != W.WORKER_UID, 'container and host identity collapsed'
assert P.EXECUTION_GID != W.WORKER_GID, 'container and host identity collapsed'
assert P.EXECUTION_UID != 0 and P.EXECUTION_GID != 0
print('OK')
"

run_case "the identity is stated once, not copied into the worker" "${PRELUDE}
# Two constants that agree today are the mechanism that produced the defect.
# The worker must derive the value, not restate it.
assert W.CONTAINER_UID is P.EXECUTION_UID or W.CONTAINER_UID == P.EXECUTION_UID
source = Path('tools/capability/execution/worker.py').read_text(encoding='utf-8')
body = [l for l in source.splitlines()
        if l.startswith('CONTAINER_UID') or l.startswith('CONTAINER_GID')]
for line in body:
    assert '65532' not in line, ('the worker restates the identity as a literal', line)
print('OK')
"

# --- the argv ------------------------------------------------------------------

run_case "the argv requests the governed identity and its mapping" "${PRELUDE}
import ast
# Code, not prose. The worker's comments explain why U=true is rejected, and a
# raw text scan would read that explanation as the thing it forbids -- the same
# mistake the pull-policy assertion made before G11-AI.
code = ast.unparse(ast.parse(
    Path('tools/capability/execution/worker.py').read_text(encoding='utf-8')))
argv = W.create_argv.__doc__ is not None
assert '--userns' in code, 'the argv carries no user namespace mapping'
# Derived from the installed Podman: keep-id maps the invoking user to a chosen
# container id, which is what makes a worker-owned 0700 output directory
# writable by the governed container identity without any chown.
assert 'keep-id' in code, 'the mapping is not keep-id'
# U=true chowns the host directory to a subordinate uid the worker cannot then
# read. Rejected as architecture, not merely unused.
assert 'U=true' not in code, 'the argv uses U=true'
assert f'--user' in code
print('OK')
"

# --- T8 must verify something the request did not determine --------------------

# The Phase 7 mutation matrix. Each case breaks the agreement at exactly one
# point in the chain and requires a refusal, because the defect this replaces
# was three layers agreeing with each other and none of them with the image.
MUTATION_PRELUDE="${PRELUDE}
from tools.capability.execution.profile import (
    Admission, ProfileBinding, build_profile, identity_mapping,
    PROFILE_SCHEMA_VERSION)

def governed_profile():
    admission = Admission(
        cimp='CIMP-000001', oci_image_id='a' * 64,
        adapter_identity='python-podman-v1', payload_schema_version=1,
        execution_profile_schema_version=PROFILE_SCHEMA_VERSION,
        argv_contract_identity='fixed-python-entrypoint-v1',
        provisioning_evidence_digest='b' * 64)
    return build_profile(ProfileBinding(
        cinv='CINV-000042', admission=admission, payload_digest='c' * 64,
        package_digest='d' * 64, package_entrypoint='main.py'))

def observation(p, **overrides):
    base = dict(
        oci_image_id=p.oci_image_id, network=p.network,
        read_only_rootfs=p.read_only_rootfs,
        no_new_privileges=p.no_new_privileges,
        dropped_capabilities=p.dropped_capabilities, effective_capabilities=(),
        memory_bytes=p.memory_bytes, memory_swap_bytes=p.memory_swap_bytes,
        cpu_quota_us=p.cpu_quota_us, cpu_period_us=p.cpu_period_us,
        pids_limit=p.pids_limit, execution_uid=p.execution_uid,
        execution_gid=p.execution_gid, hostname=p.hostname, mounts=p.mounts,
        devices=p.devices, sockets=(), tmpfs_bytes=p.tmpfs_bytes,
        tmpfs_mode=p.tmpfs_mode, tmpfs_options=p.tmpfs_options,
        uid_map=(identity_mapping(p.execution_uid),),
        gid_map=(identity_mapping(p.execution_gid),))
    base.update(overrides)
    return P.ObservedProfile(**base)

def refuses(**overrides):
    p = governed_profile()
    try:
        P.verify_observed(p, observation(p, **overrides))
    except P.ProfileMismatch:
        return True
    return False
"

run_case "a correctly mapped observation verifies" "${MUTATION_PRELUDE}
p = governed_profile()
P.verify_observed(p, observation(p))
print('OK')
"

run_case "an observed identity differing from the profile is refused" "${MUTATION_PRELUDE}
# argv/runtime says 1000 while the profile says the governed identity.
assert refuses(execution_uid=1000), 'a wrong observed uid verified'
assert refuses(execution_gid=1000), 'a wrong observed gid verified'
print('OK')
"

run_case "a correct User with no namespace mapping is refused" "${MUTATION_PRELUDE}
# The exact shape of the G11-AI.2 default-mapping run: Podman echoed
# User=65532:65532 and the workload still could not write its output.
assert refuses(uid_map=None, gid_map=None), 'an unmapped container verified'
assert refuses(uid_map=()), 'an empty uid map verified'
print('OK')
"

run_case "a mapping that binds the wrong id is refused" "${MUTATION_PRELUDE}
# keep-id:uid=1000 while --user asked for the governed identity. Observed in
# the isolated experiments as out_uid=1000 and WRITE_DENIED.
assert refuses(uid_map=(identity_mapping(1000),)), 'a wrong uid mapping verified'
# The gid case is the one a write test cannot catch: a 0700 directory owned by
# the right uid is writable regardless of the gid mapping, so that experiment
# reported WRITE_OK. Only the map distinguishes it.
assert refuses(gid_map=(identity_mapping(1000),)), 'a wrong gid mapping verified'
print('OK')
"

run_case "a mapping to a subordinate id rather than the worker is refused" "${MUTATION_PRELUDE}
# '65532:0:1' binds the container id to the invoking user. '65532:165531:1'
# binds it to a subordinate id that merely shares the number, which is what a
# U=true style arrangement produces -- writable inside, uncollectable outside.
assert refuses(uid_map=('65532:165531:1',)), 'a subordinate mapping verified'
print('OK')
"

run_case "an absent identity mapping is refused even when User reads correctly" "${PRELUDE}
# The case that matters. Podman reports Config.User as whatever was requested,
# so it read 65532:65532 in all four experiments -- including the one where the
# mapping was absent entirely and the workload could not write its result.
# Verifying the echo would have passed every broken configuration.
import inspect
fields = [f.name for f in __import__('dataclasses').fields(P.ObservedProfile)]
assert 'uid_map' in fields, 'the observation carries no uid mapping to verify'
assert 'gid_map' in fields, 'the observation carries no gid mapping to verify'
src = inspect.getsource(P.verify_observed)
assert 'uid_map' in src and 'gid_map' in src, \
    'T8 does not verify the identity mapping'
print('OK')
"

run_case "the lifecycle observation reports the mapping the runtime established" "${PRELUDE}
import inspect
src = inspect.getsource(L.observe)
assert 'UidMap' in src and 'GidMap' in src, src
print('OK')
"

# --- the closed environment ----------------------------------------------------

run_case "the effective environment is declared in full, with its sources" "${PRELUDE}
declared = W.CONTAINER_EFFECTIVE_ENVIRONMENT
# Nine, observed from the governed image running under the governed argv. Six
# would be the answer from reading the image config and this module; the other
# three come from Podman and appear in neither.
assert len(declared) == 9, len(declared)
names = [n for n, _, _, _ in declared]
assert names == sorted(names), 'the declaration is not sorted'
assert len(set(names)) == len(names), 'the declaration repeats a name'
sources = {s for _, _, s, _ in declared}
assert sources == {'IMAGE', 'ADAPTER', 'RUNTIME'}, sources
for name, value, source, rule in declared:
    assert rule in ('REQUIRED', 'GOVERNED'), (name, rule)
    assert isinstance(value, str) and value, name
# The three Podman contributes are the ones no amount of reading finds.
runtime = {n for n, _, s, _ in declared if s == 'RUNTIME'}
assert runtime == {'HOME', 'HOSTNAME', 'container'}, runtime
print('OK')
"

run_case "the declaration and the adapter's own set cannot disagree" "${PRELUDE}
adapter = tuple(sorted((n, v) for n, v, s, _ in W.CONTAINER_EFFECTIVE_ENVIRONMENT
                       if s == 'ADAPTER'))
assert adapter == tuple(sorted(W.CONTAINER_ENVIRONMENT)), (adapter,
    W.CONTAINER_ENVIRONMENT)
# HOSTNAME is the governed one, not a second spelling of it.
declared = dict((n, v) for n, v, _, _ in W.CONTAINER_EFFECTIVE_ENVIRONMENT)
assert declared['HOSTNAME'] == P.HOSTNAME, declared['HOSTNAME']
print('OK')
"

run_case "the environment no longer claims to be inherited from nothing" "${PRELUDE}
# The claim was false and unchecked: it described what the adapter contributes,
# not what the workload sees, and survived to G11-AF because nothing had ever
# read the environment of a running container.
source = Path('tools/capability/execution/worker.py').read_text(encoding='utf-8')
assert 'inherited from nothing --' not in source, \
    'the stale environment claim is still stated as fact'
print('OK')
"

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution container identity validation passed.\n'
else
  printf 'Capability execution container identity validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
