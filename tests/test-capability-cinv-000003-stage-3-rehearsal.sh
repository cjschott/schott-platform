#!/usr/bin/env bash
set -Eeuo pipefail

# The CINV-000003 Stage 3 ceremony, rehearsed.
#
# HOST-ONLY. It reads the installed Generation-20 runtime and the governed
# stores. See tests/host-only.manifest.
#
# WHAT IS REHEARSED, AND WHAT IS NOT
# ==================================
# BLOCK B -- the gates -- runs WHOLE against fixtures. Every root it reads is a
# variable this suite substitutes, and it writes nothing.
#
# BLOCK C IS NEVER RUN. `execute` compiles in its runtime root and
# `supervised_binding` compiles in the execution root it reads the
# authorisation from; a substitution would redirect the gates and not the
# mutation, which is the 2026-09-20 incident. Its EFFECT is rehearsed at the
# API instead, by driving the real `ExecutionSupervisor` over the real protocol
# against a byte copy of the runtime.
#
# THE CONTAINER HALF IS NOT EXERCISED HERE, AND THAT IS STATED RATHER THAN
# GLOSSED. The governed execution image lives in the kyri-capability Podman
# store, which this account cannot read, and the exported OCI archive the
# end-to-end suite used is gone from /tmp. So the worker half is a scripted
# peer that speaks the released protocol through the released encoder, and what
# it proves is the coordinator's half: the conversation, the authority to
# start, the conclusion, the record, and every refusal path. The container
# itself -- podman argv, quota, privilege drop, no_new_privs -- is asserted
# from the released bytes below and is covered behaviourally by the transition
# and reconcile suites, not by this one.
#
# THE PAYLOAD IS REAL. The released package is run against the published
# canonical payload, so the expected result bytes are produced rather than
# predicted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh disable=SC1091
. "${SCRIPT_DIR}/lib/host-only.sh"
host_only_requires /data/kyri/capability-runtime /usr/lib/kyri/python \
                   /etc/kyri/backing-store.json /var/lib/kyri/fabric \
                   /data/kyri/capability-handoff/CINV-000003 \
                   /data/kyri/work/g11bcn/third-invoke.json

CEREMONY="${ROOT}/provisioning/execution/g11-bc-aa-cinv-000003-stage-3-ceremony.txt"
INSTALLED=/usr/lib/kyri/python                    # prod-path-reference
PRODUCTION=/data/kyri/capability-runtime          # prod-path-reference
PRODUCTION_FABRIC=/var/lib/kyri/fabric            # prod-path-reference
PRODUCTION_HANDOFF=/data/kyri/capability-handoff  # prod-path-reference
PAYLOAD=/data/kyri/work/g11bcn/third-invoke.json  # prod-path-reference

TARGET=CINV-000003
ARTIFACT_DIGEST=6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
PAYLOAD_DIGEST=591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3
RESULT_CHECKSUM=57b6b93ffd50cce4df4c8af4fd40d9b16494b884f666490257c66ff2dd274de1
RESULT_DIGEST=fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d -p /data/kyri g11bcaa-rehearsal.XXXXXX)"
trap 'chmod -R u+w "${WORK}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

aggregate() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }
PRODUCTION_BEFORE="$(aggregate "${PRODUCTION}")"
FABRIC_BEFORE="$(aggregate "${PRODUCTION_FABRIC}")"

# ===========================================================================
# 1. The Stage-3 contract, from the released bytes
# ===========================================================================

printf -- '--- the released contract ---\n'

contract="$( cd "${INSTALLED}" && python3 - <<'CONTRACTPY'
import inspect
import sys

sys.path.insert(0, ".")
from tools.capability import cli
from tools.capability.execution import worker

problems = []

verbs = next(a.choices for a in cli.build_parser()._actions
             if getattr(a, "choices", None))
flags = {o for a in verbs["execute"]._actions for o in a.option_strings}
required = {"--cinv", "--actor", "--recorded-at", "--expected-uid", "--expected-gid"}
if not required <= flags:
    problems.append(f"execute is missing {sorted(required - flags)}")
for forbidden in ("--adapter", "--backend", "--image", "--argv", "--binding",
                  "--store-root", "--force"):
    if forbidden in flags:
        problems.append(f"execute exposes {forbidden}")

source = inspect.getsource(cli.command_execute)
if "CAPABILITY_RUNTIME_ROOT" not in source:
    problems.append("command_execute does not resolve the compiled-in root")
if "EXIT_SUCCESS if terminal.succeeded else EXIT_DENIED" not in source:
    problems.append("the exit status is not the succeeded flag")
if '"result_recorded": False' not in source:
    problems.append("an unresolved supervision does not report result_recorded false")

argv_source = inspect.getsource(worker.create_argv)
for control in ('"--name", container_name(profile.cinv)', '"--pull=never"',
                '"--read-only"', '"--cap-drop", "ALL"',
                '"--security-opt", "no-new-privileges"',
                '"--network", profile.network'):
    if control not in argv_source:
        problems.append(f"create_argv does not state {control}")
if worker.container_name("CINV-000003") != "kyri-CINV-000003":
    problems.append("the container name is not derived from the CINV")

print("\n".join(problems) if problems else "clean")
CONTRACTPY
)"
if [[ "${contract}" == "clean" ]]; then
  pass "execute takes one CINV and no way to choose what runs; the container argv states every control"
else
  fail "the released contract is not what the ceremony assumes: ${contract}"
fi

# Stage 3 writes no lifecycle transition, and the journal proves it: every CMUT
# ever spent belongs to a Stage-2 authorisation or the abandonment.
journalled="$( cd "${PRODUCTION}/execution/mutations" && for d in CMUT-*; do
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["target_kind"])' "${d}/intent"
done | sort -u | tr '\n' ' ' )"
if [[ "${journalled}" == "execution-transition launch-authorisation " ]]; then
  pass "every mutation ever journalled is a transition or an authorisation: Stage 3 journals nothing"
else
  fail "the mutation journal holds kinds this contract does not expect: ${journalled}"
fi

# ===========================================================================
# 2. The payload, executed for real
# ===========================================================================
#
# The released package, run against the published canonical payload. No
# container: the file reads one mount and writes another, and both are
# ordinary paths. What this proves is the expected result BYTES, which the
# ceremony pins and the verdict must carry.

printf -- '\n--- the payload, through the released package ---\n'

PKG="${WORK}/package"
mkdir -p "${PKG}/input" "${PKG}/output"
cp "${PRODUCTION_HANDOFF}/${TARGET}/payload" "${PKG}/input/payload"
if ( cd "${WORK}" && python3 - "${PRODUCTION}/staging/tree-sha256-${ARTIFACT_DIGEST}/main.py" \
       "${PKG}/input/payload" "${PKG}/output/result.json" <<'RUNPKG'
import runpy
import sys

package, payload, result = sys.argv[1:4]
source = open(package).read()
# The governed mounts are module constants. Rebinding them is how the package
# is run outside a container without editing the file this suite is about.
source = source.replace('PAYLOAD_PATH = "/run/kyri/input/payload"',
                        f'PAYLOAD_PATH = {payload!r}')
source = source.replace('RESULT_PATH = "/kyri/output/result.json"',
                        f'RESULT_PATH = {result!r}')
namespace = {"__name__": "governed_package"}
exec(compile(source, package, "exec"), namespace)
raise SystemExit(namespace["main"]())
RUNPKG
); then
  pass "the released package accepts the published payload and exits 0"
else
  fail "the released package refused the published payload"
fi

if [[ -f "${PKG}/output/result.json" ]]; then
  produced="$(sha256sum "${PKG}/output/result.json" | cut -d' ' -f1)"
  if [[ "${produced}" == "${RESULT_DIGEST}" ]]; then
    pass "it produced exactly the pinned result: ${produced}"
  else
    fail "it produced ${produced}, not the pinned ${RESULT_DIGEST}"
  fi
  if grep -qF "\"checksum\":\"${RESULT_CHECKSUM}\"" "${PKG}/output/result.json"; then
    pass "the result carries the pinned checksum"
  else
    fail "the result checksum is not the pinned one"
  fi
  if grep -qF "\"payload_digest\":\"${PAYLOAD_DIGEST}\"" "${PKG}/output/result.json" \
     && grep -qF '"operation":"verify-execution-boundary"' "${PKG}/output/result.json"; then
    pass "it names the operation the capability performs, over the published payload"
  else
    fail "the result does not name the expected operation or payload"
  fi
  if [[ "$(stat -c '%s' "${PKG}/output/result.json")" == "281" ]]; then
    pass "the result is 281 bytes, as the ceremony states"
  else
    fail "the result is $(stat -c '%s' "${PKG}/output/result.json") bytes"
  fi
else
  fail "no result was written"
fi

# The historical failure class, reproduced: the payload CRES-000001 was refused
# for asked `execute`, and the capability performs `verify-execution-boundary`.
printf '{"operation":"execute","arguments":{}}' > "${PKG}/input/wrong-payload"
if ( cd "${WORK}" && python3 - "${PRODUCTION}/staging/tree-sha256-${ARTIFACT_DIGEST}/main.py" \
       "${PKG}/input/wrong-payload" "${PKG}/output/wrong-result.json" <<'RUNPKG'
import sys
package, payload, result = sys.argv[1:4]
source = open(package).read()
source = source.replace('PAYLOAD_PATH = "/run/kyri/input/payload"', f'PAYLOAD_PATH = {payload!r}')
source = source.replace('RESULT_PATH = "/kyri/output/result.json"', f'RESULT_PATH = {result!r}')
namespace = {"__name__": "governed_package"}
exec(compile(source, package, "exec"), namespace)
raise SystemExit(namespace["main"]())
RUNPKG
) 2>/dev/null; then
  fail "the package accepted a payload asking for an operation it does not perform"
else
  pass "G11-BC-I's class still refuses: a payload asking for 'execute' is refused, nonzero"
fi
if [[ ! -e "${PKG}/output/wrong-result.json" ]]; then
  pass "and a refusal writes no result, which is what provider-error means upstream"
else
  fail "a refused payload still wrote a result"
fi

# ===========================================================================
# 3. The coordinator half, driven for real
# ===========================================================================

printf -- '\n--- Stage 3 at the API, against a byte copy ---\n'

HARNESS="${WORK}/stage3.py"
cat > "${HARNESS}" <<'HARNESSPY'
"""Drive the released Stage-3 coordinator half against a fixture."""
import hashlib
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, "/usr/lib/kyri/python")
from tools.capability import cli
from tools.capability.store import CapabilityStore
from tools.capability.coordinator import execute_supervised
from tools.capability.execution import capacity as cap
from tools.capability.execution import state as sm
from tools.capability.execution.profile import parse_canonical_profile
from tools.capability.execution.protocol import Message, MessageKind, encode
from tools.capability.execution.supervision import (ExecutionSupervisor,
                                                    SupervisedBinding,
                                                    SupervisionRefused)

BASE, SCRIPT = sys.argv[1], sys.argv[2]
RUNTIME = os.path.join(BASE, "runtime")
HANDOFF = os.path.join(BASE, "handoff")
CINV = "CINV-000003"
CONTAINER = "0" * 64
RESULT_DIGEST = "fd2d58e99bae82f32ce320a3d3ac2a35b6e679b87432b2aedd9de1efa92cbad7"


def binding_from_fixture():
    """The binding `supervised_binding` would build, from the fixture's own
    authorisation and handoff. Built here because that function compiles in the
    production execution root -- which is exactly why BLOCK C is not
    rehearsable and this is."""
    record = json.loads(open(os.path.join(RUNTIME, "execution", CINV,
                                          "launch-authorisation")).read())
    profile_bytes = open(os.path.join(HANDOFF, CINV, "profile"), "rb").read()
    digest = hashlib.sha256(profile_bytes).hexdigest()
    if digest != record["profile_digest"]:
        raise SystemExit("the fixture profile does not match its authorisation")
    return SupervisedBinding(cinv=CINV,
                             profile=parse_canonical_profile(profile_bytes),
                             profile_digest=digest)


class ScriptedWorker:
    """A peer that speaks the released protocol through the released encoder.

    Hand-written frames would test this harness. These are built with
    `protocol.encode`, so a conversation the coordinator accepts here is one it
    would accept from the real worker.
    """

    def __init__(self, script, profile, profile_digest):
        self._script = script
        self._profile = profile
        self._profile_digest = profile_digest
        self.launched = False

    def launch(self, cinv):
        self.launched = True
        to_worker_r, to_worker_w = os.pipe()
        from_worker_r, from_worker_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(to_worker_w); os.close(from_worker_r)
            try:
                self._play(to_worker_r, from_worker_w)
            except BaseException:
                pass
            os._exit(0)
        os.close(to_worker_r); os.close(from_worker_w)

        class Child:
            def __init__(self):
                self._buffer = bytearray()

            def reader(self):
                while True:
                    index = self._buffer.find(b"\n")
                    if index >= 0:
                        frame = bytes(self._buffer[:index + 1])
                        del self._buffer[:index + 1]
                        return frame
                    chunk = os.read(from_worker_r, 4096)
                    if not chunk:
                        return None
                    self._buffer.extend(chunk)

            def writer(self, frame):
                os.write(to_worker_w, frame)

            def reap(self, timeout):
                _, status = os.waitpid(pid, 0)
                os.close(from_worker_r); os.close(to_worker_w)
                return status, True

        return Child()

    def _emit(self, fd, kind, **fields):
        os.write(fd, encode(Message(kind=kind, cinv=CINV,
                                    fields=tuple(sorted(fields.items())))))

    def _read_frame(self, fd):
        buffer = bytearray()
        while b"\n" not in buffer:
            chunk = os.read(fd, 4096)
            if not chunk:
                return None
            buffer.extend(chunk)
        return bytes(buffer)

    def _play(self, read_fd, write_fd):
        profile = self._profile
        script = self._script
        if script == "died-immediately":
            return
        self._emit(write_fd, MessageKind.CREATED, container_id=CONTAINER)
        verified = dict(container_id=CONTAINER,
                        profile_digest=self._profile_digest,
                        oci_image_id=profile.oci_image_id, cimp=profile.cimp,
                        profile_schema_version=profile.profile_schema_version,
                        execution_uid=profile.execution_uid,
                        execution_gid=profile.execution_gid)
        if script == "wrong-image":
            verified["oci_image_id"] = "9" * 64
        if script == "wrong-container":
            verified["container_id"] = "1" * 64
        self._emit(write_fd, MessageKind.VERIFIED_PROFILE, **verified)
        if script in ("wrong-image", "wrong-container"):
            return
        if self._read_frame(read_fd) is None:
            return
        if script == "died-after-start-authority":
            return
        self._emit(write_fd, MessageKind.STARTED, container_id=CONTAINER)
        terminal = dict(container_id=CONTAINER, lifecycle_state="exited",
                        outcome_class="completed", exit_code=0,
                        started_proven=True,
                        started_at="2026-09-21T09:00:00.000000000-05:00",
                        finished_at="2026-09-21T09:00:01.000000000-05:00")
        collected = dict(result_digest=RESULT_DIGEST,
                         output_manifest_digest=None,
                         stdout_truncated=False, stderr_truncated=False)
        if script == "provider-error":
            terminal.update(outcome_class="provider-error", exit_code=1)
            collected["result_digest"] = None
        elif script == "result-missing":
            collected["result_digest"] = None
        elif script == "timeout":
            terminal.update(outcome_class="timeout", exit_code=None,
                            lifecycle_state="stopped")
            collected["result_digest"] = None
        self._emit(write_fd, MessageKind.TERMINAL, **terminal)
        self._emit(write_fd, MessageKind.COLLECTED, **collected)
        # And stop: waiting for the coordinator to close would deadlock against
        # its own reap. A real worker exits when its work is done.


def proving_absence(cinv):
    return {"cinv": cinv, "final_absent": True}


def proving_nothing(cinv):
    return {"cinv": cinv, "final_absent": False}


binding = binding_from_fixture()
store = CapabilityStore(RUNTIME, expected_uid=1000, expected_gid=1000)
execution_root = cli._anchored(os.path.join(RUNTIME, "execution"))


def occupancy():
    return sum(1 for v in sm.all_states(execution_root).values()
               if v in cap.slot_holding_states())


def sequence(name):
    return open(os.path.join(RUNTIME, "sequences", name)).read().strip()


worker = ScriptedWorker(SCRIPT, binding.profile, binding.profile_digest)
supervisor = ExecutionSupervisor(
    launcher=worker,
    reconciler=proving_nothing if SCRIPT == "disposal-unproven" else proving_absence)

before = {"occupancy": occupancy(), "cres_seq": sequence("capability-result.seq"),
          "state": sm.all_states(execution_root)[CINV].value}
report = {"launched_before": worker.launched}
try:
    terminal = execute_supervised(
        store, invocation_record_id=CINV, invocation_id=CINV,
        supervisor=supervisor, binding=binding,
        actor="primary-platform-operator",
        recorded_at=datetime.fromisoformat("2026-09-21T09:00:02-05:00"))
except SupervisionRefused as refusal:
    trace = supervisor.trace
    report.update(status="unresolved", reason=str(refusal), result_recorded=False,
                  protocol_states=list(trace.states) if trace else [],
                  disposal_proven=bool(trace.disposal_proven) if trace else False)
except Exception as error:                                   # noqa: BLE001
    report.update(status="error", error=type(error).__name__, reason=str(error),
                  result_recorded=False)
else:
    report.update(status=terminal.status, reason=terminal.reason,
                  result_record_id=terminal.result_record_id,
                  succeeded=terminal.succeeded,
                  result_digest=terminal.result_digest,
                  result_recorded=terminal.result_record_id is not None)

report.update(launched=worker.launched,
              occupancy_before=before["occupancy"], occupancy_after=occupancy(),
              state_before=before["state"],
              state_after=sm.all_states(execution_root)[CINV].value,
              cres_seq_before=before["cres_seq"],
              cres_seq_after=sequence("capability-result.seq"),
              cinv_seq=sequence("capability-invocation.seq"))
print(json.dumps(report, indent=2, sort_keys=True))
execution_root.close()
HARNESSPY

build_fixture() {
  local base="$1"
  [[ -e "${base}" ]] && { chmod -R u+w "${base}"; rm -rf "${base}"; }
  mkdir -p "${base}/handoff" "${base}/work"
  cp -a "${PRODUCTION}" "${base}/runtime"
  cp -a "${PRODUCTION_FABRIC}" "${base}/fabric"
  cp -a "${PRODUCTION_HANDOFF}/${TARGET}" "${base}/handoff/${TARGET}"
  cp "${PAYLOAD}" "${base}/work/third-invoke.json"
  chmod 0600 "${base}/work/third-invoke.json"
  printf 'stage-3-observation\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\nno-target-container kyri-%s\n' \
    "${TARGET}" > "${base}/work/witness"
  chmod 0600 "${base}/work/witness"
}

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

FIX="${WORK}/fix"
build_fixture "${FIX}"
cp -a "${FIX}/runtime" "${FIX}/runtime.orig"
result="${WORK}/success.json"
if timeout 120 python3 "${HARNESS}" "${FIX}" success > "${result}" 2>&1; then
  pass "the supervised execution runs to completion against the byte copy"
else
  fail "the supervised execution failed: $(tail -3 "${result}" | tr '\n' ' ')"
  cat "${result}" >&2
fi

for key_want in "status=prepared" "reason=None" "result_record_id=CRES-000002" \
                "succeeded=True" "result_digest=sha256:${RESULT_DIGEST}" \
                "result_recorded=True" "launched=True" \
                "occupancy_before=2" "occupancy_after=2" \
                "state_before=launch_authorized" "state_after=launch_authorized" \
                "cres_seq_before=1" "cres_seq_after=2" "cinv_seq=3"; do
  key="${key_want%%=*}"; want="${key_want#*=}"
  got="$(field "${result}" "${key}")"
  if [[ "${got}" == "${want}" ]]; then
    pass "verdict ${key} = ${got}"
  else
    fail "verdict ${key} is ${got}, expected ${want}"
  fi
done

# ===========================================================================
# 4. The mutation, measured by content
# ===========================================================================

printf -- '\n--- the mutation, measured ---\n'
R="${FIX}/runtime"; O="${FIX}/runtime.orig"

# `diff` exits 1 when things differ, which is the case this measures; without
# the guard the assignment itself would end the suite under errexit.
changed="$( { diff -rq "${O}" "${R}" || true; } 2>&1 | sed "s#${FIX}/##g" | sort | tr '\n' '|')"
expected="Files runtime.orig/sequences/capability-result.seq and runtime/sequences/capability-result.seq differ|Only in runtime/capability-results: CRES-000002.yaml|"
if [[ "${changed}" == "${expected}" ]]; then
  pass "Stage 3 changed exactly two things: the new CRES and the result sequence"
else
  fail "Stage 3 changed: ${changed}"
fi

for pair in "capability_result_id: CRES-000002" "invocation_record_id: ${TARGET}" \
            "outcome_class: completed" "attempt_number: 1" "reason: null" \
            "result_digest: sha256:${RESULT_DIGEST}" \
            "result_artifact_reference: null" "schema_version: 2"; do
  if grep -qF -- "${pair}" "${R}/capability-results/CRES-000002.yaml"; then
    pass "CRES-000002 records ${pair}"
  else
    fail "CRES-000002 does not record ${pair}"
  fi
done

if [[ "$(cat "${R}/execution/cmut-counter")" == "$(cat "${O}/execution/cmut-counter")" ]]; then
  pass "no mutation was journalled: Stage 3 writes no lifecycle"
else
  fail "the mutation counter moved"
fi
if diff -r "${O}/execution/transitions" "${R}/execution/transitions" >/dev/null; then
  pass "the transition journal is byte-identical"
else
  fail "a transition was written"
fi
if diff -r "${O}/capability-invocations" "${R}/capability-invocations" >/dev/null \
   && diff -r "${O}/execution/admin-records" "${R}/execution/admin-records" >/dev/null; then
  pass "every CINV and CADM is byte-identical"
else
  fail "an immutable record changed"
fi
if [[ "$(sha256sum "${R}/capability-results/CRES-000001.yaml" | cut -d' ' -f1)" \
      == "18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d" ]]; then
  pass "CRES-000001 is byte-identical"
else
  fail "CRES-000001 changed"
fi

recon="${WORK}/recon"
[[ -e "${recon}" ]] && { chmod -R u+w "${recon}"; rm -rf "${recon}"; }
cp -a "${R}" "${recon}"; chmod -R u+w "${recon}"
rm -f "${recon}/capability-results/CRES-000002.yaml"
printf '1\n' > "${recon}/sequences/capability-result.seq"
a="$(find "${recon}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${recon}#X#" | sha256sum)"
b="$(find "${O}" -type f -print0 | sort -z | xargs -0 sha256sum | sed "s#${O}#X#" | sha256sum)"
if [[ "${a}" == "${b}" ]]; then
  pass "removing the CRES and rewinding the sequence reproduces the pre-Stage-3 store exactly"
else
  fail "the mutation was not exactly that"
fi

# ===========================================================================
# 5. Every other way it can end
# ===========================================================================

printf -- '\n--- the failure paths, at the API ---\n'

# name | script | expected status | records a result | expected reason fragment
PATHS=(
"the provider refused the payload|provider-error|prepared|yes|provider-error"
"the workload wrote nothing|result-missing|prepared|yes|result-missing"
"the execution timed out|timeout|prepared|yes|timeout"
"disposal could not be proven|disposal-unproven|unresolved|no|reconciliation did not prove the container absent"
"the worker verified another image|wrong-image|unresolved|no|the conversation could not be trusted"
"the worker changed container|wrong-container|unresolved|no|the conversation could not be trusted"
"the worker never spoke|died-immediately|unresolved|no|the worker ended the conversation"
"the worker died after being authorised to start|died-after-start-authority|unresolved|no|the worker ended the conversation"
)
for case in "${PATHS[@]}"; do
  IFS='|' read -r name script status records reason <<<"${case}"
  build_fixture "${FIX}"
  out="${WORK}/path.json"
  timeout 120 python3 "${HARNESS}" "${FIX}" "${script}" > "${out}" 2>&1 || true
  got_status="$(field "${out}" status)"
  if [[ "${got_status}" == "${status}" ]]; then
    pass "${name}: status ${got_status}"
  else
    fail "${name}: status ${got_status}, expected ${status}"
  fi
  if [[ "$(field "${out}" reason)" == *"${reason}"* ]]; then
    pass "${name}: reason names it (${reason})"
  else
    fail "${name}: reason is $(field "${out}" reason)"
  fi
  if [[ "${records}" == "yes" ]]; then
    if [[ -f "${FIX}/runtime/capability-results/CRES-000002.yaml" ]] \
       && [[ "$(field "${out}" succeeded)" == "False" ]]; then
      pass "${name}: a result is recorded and it does not claim success"
    else
      fail "${name}: expected a recorded, unsuccessful result"
    fi
  else
    if [[ ! -e "${FIX}/runtime/capability-results/CRES-000002.yaml" ]] \
       && [[ "$(field "${out}" result_recorded)" == "False" ]]; then
      pass "${name}: NOTHING was written; the invocation stays unresolved"
    else
      fail "${name}: a result was written for an unconcluded execution"
    fi
  fi
  if [[ "$(field "${out}" occupancy_after)" == "2" ]] \
     && [[ "$(field "${out}" state_after)" == "launch_authorized" ]]; then
    pass "${name}: lifecycle and occupancy unchanged"
  else
    fail "${name}: the lifecycle or occupancy moved"
  fi
done

# The duplicate-result gate, which runs BEFORE the privilege boundary.
printf -- '\n--- the duplicate-result gate ---\n'
build_fixture "${FIX}"
timeout 120 python3 "${HARNESS}" "${FIX}" success > "${WORK}/first.json" 2>&1 || true
out="${WORK}/second.json"
timeout 120 python3 "${HARNESS}" "${FIX}" success > "${out}" 2>&1 || true
if [[ "$(field "${out}" error)" == "TerminalResultExists" ]]; then
  pass "a second execution is refused because a terminal result already exists"
else
  fail "the second execution was not refused: $(field "${out}" status)"
fi
if [[ "$(field "${out}" launched)" == "False" ]]; then
  pass "and the refusal happened BEFORE the privilege boundary: nothing was launched"
else
  fail "the duplicate ran the workload before declining to record it"
fi
if [[ "$(field "${out}" cres_seq_after)" == "2" ]]; then
  pass "no second result identity was spent"
else
  fail "the refused repeat spent a sequence"
fi

# ===========================================================================
# 6. The ceremony's shape, and its gates
# ===========================================================================

printf -- '\n--- the ceremony, as written ---\n'

GATES="${WORK}/gates.sh"
awk "/^bash <<'GATES'\$/{on=1;next} /^GATES\$/{on=0} on" "${CEREMONY}" > "${GATES}"
STAGE3="${WORK}/stage3.sh"
awk "/^bash <<'STAGE3'\$/{on=1;next} /^STAGE3\$/{on=0} on" "${CEREMONY}" > "${STAGE3}"
for block in "${GATES}" "${STAGE3}"; do
  if [[ -s "${block}" ]]; then
    pass "$(basename "${block}" .sh) extracted whole ($(wc -l < "${block}") lines)"
  else
    fail "$(basename "${block}" .sh) could not be extracted"
    exit 1
  fi
done
if grep -q 'cli execute' "${GATES}"; then
  fail "BLOCK B can reach the mutation"
else
  pass "BLOCK B contains no execute: the gates cannot run anything"
fi
if [[ "$(grep -c 'tools.capability.cli execute' "${STAGE3}")" == "1" ]]; then
  pass "BLOCK C runs exactly one execute"
else
  fail "BLOCK C runs $(grep -c 'tools.capability.cli execute' "${STAGE3}") executes"
fi
if grep -q 'STOP: the supervision did not conclude' "${STAGE3}"; then
  pass "BLOCK C reads the JSON verdict before the exit status"
else
  fail "BLOCK C treats rc as the verdict"
fi
if grep -q 'stranded condition ADR-0015 names' "${STAGE3}"; then
  pass "BLOCK C says what the store will be left in"
else
  fail "BLOCK C does not state the stranded outcome"
fi

printf -- '\n--- the gates, against a fixture ---\n'
render_gates() {
  local base="$1" out="$2"
  sed \
    -e "s#^RUNTIME=/data/kyri/capability-runtime\$#RUNTIME=${base}/runtime#" \
    -e "s#^HANDOFF=/data/kyri/capability-handoff\$#HANDOFF=${base}/handoff#" \
    -e "s#^FABRIC=/var/lib/kyri/fabric\$#FABRIC=${base}/fabric#" \
    -e "s#^WITNESS=/data/kyri/work/g11bcaa-stage-3-witness\$#WITNESS=${base}/work/witness#" \
    -e "s#^PAYLOAD_ROOT=/data/kyri/work/g11bcn\$#PAYLOAD_ROOT=${base}/work#" \
    -e "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${base}/runtime")#" \
    -e "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${base}/fabric")#" \
    "${GATES}" > "${out}"
}

build_fixture "${FIX}"
rendered="${WORK}/rendered-gates.sh"
render_gates "${FIX}" "${rendered}"
if grep -qE "^(RUNTIME=${PRODUCTION}|FABRIC=${PRODUCTION_FABRIC}|HANDOFF=${PRODUCTION_HANDOFF})\$" "${rendered}"; then
  fail "a production root survived the substitution"
else
  pass "every root BLOCK B measures was substituted"
fi
if grep -q '^INSTALLED=/usr/lib/kyri/python$' "${rendered}" \
   && grep -q '^TRUST=/var/lib/kyri/trust$' "${rendered}"; then
  pass "the installed library and Trust still point at the real ones, which the block only reads"
else
  fail "the installed library or Trust was substituted away"
fi

out="${WORK}/gates.out"; status=0
( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
if (( status == 0 )); then
  pass "BLOCK B passes against an unmodified fixture"
else
  fail "BLOCK B refused a clean fixture: $(tail -3 "${out}" | tr '\n' ' ')"
fi
for expected in \
  'ok  observation' \
  'ok  current authority supported at' \
  'ok  sequences 3/1, cadm 000002, cmut 000000000010, 7 transitions, no CRES-000002' \
  'ok  the launch authorisation is the reviewed one, for CIMP-000001' \
  'ok  the published handoff is the reviewed one, with the reviewed modes' \
  'ok  CINV-000003 is launch_authorized and awaiting execution' \
  'ok  occupancy 2 of 2 -- Stage 3 reserves nothing and releases nothing' \
  'ALL GATES PASSED.'
do
  if grep -qF "${expected}" "${out}"; then
    pass "BLOCK B reports: ${expected}"
  else
    fail "BLOCK B did not report: ${expected}"
  fi
done

# ===========================================================================
# 7. The failure matrix
# ===========================================================================

printf -- '\n--- fail closed, by gate ---\n'

expire_advertisement() {
  chmod u+w "${FIX}/fabric/capability-advertisements/CADV-000007.yaml"
  python3 - "${FIX}/fabric/capability-advertisements/CADV-000007.yaml" <<'EXPIRE'
import sys
path = sys.argv[1]
body = open(path).read()
assert "2026-09-23T06:00:00-05:00" in body, "the advertisement does not carry the expected validity"
open(path, "w").write(body.replace("2026-09-23T06:00:00-05:00",
                                   "2026-09-19T06:00:00-05:00"))
EXPIRE
}
supersede_route() {
  local routes="${FIX}/fabric/capability-routes"
  chmod u+w "${routes}"; cp "${routes}/CROUTE-0006.yaml" "${routes}/CROUTE-0007.yaml"
  chmod u+w "${routes}/CROUTE-0007.yaml"
  python3 - "${routes}/CROUTE-0007.yaml" <<'ROUTE'
import sys
path = sys.argv[1]
body = open(path).read()
assert "route_id: CROUTE-0006" in body, "the copied route does not name CROUTE-0006"
body = body.replace("route_id: CROUTE-0006", "route_id: CROUTE-0007")
body = body.replace("supersedes: CROUTE-0005", "supersedes: CROUTE-0006")
open(path, "w").write(body)
ROUTE
}
change_selection() {
  local selection="${FIX}/fabric/capability-selections/CSEL-000004.yaml"
  chmod u+w "${selection}"
  python3 - "${selection}" <<'SELECT'
import sys
path = sys.argv[1]
body = open(path).read()
assert "selected_instance_id: CINST-000006" in body, "the selection does not name CINST-000006"
open(path, "w").write(body.replace("selected_instance_id: CINST-000006",
                                   "selected_instance_id: CINST-000005"))
SELECT
}
corrupt() { chmod u+w "$1"; printf 'x' >> "$1"; }
# A DIFFERENT lifecycle, not a broken one. Rewriting the state to `created`
# would make `reserved -> created` an edge the released vocabulary does not
# have, and `all_states` would raise -- a crash scoring as a refusal, which is
# the thing a failure matrix must never accept. `abandoned` IS reachable from
# `reserved`, so the chain stays valid, the journal still holds seven records,
# and the gate under test is the one that judges.
revert_lifecycle() {
  local transition="${FIX}/runtime/execution/transitions/CINV-000003.000002"
  chmod u+w "${transition}"
  python3 - "${transition}" <<'HOLD'
import sys
path = sys.argv[1]
body = open(path).read()
assert '"state":"launch_authorized"' in body, "the transition does not record launch_authorized"
open(path, "w").write(body.replace('"state":"launch_authorized"',
                                   '"state":"abandoned"'))
HOLD
}

SABOTAGE=(
"the installed runtime is not Generation 20|sed -i 's#^check_installed tools/capability/cli.py .*#check_installed tools/capability/cli.py 0000000000000000000000000000000000000000000000000000000000000000#' \"\${rendered}\"|not the reviewed Generation-20"
"the advertisement authority has expired|expire_advertisement; REFABRIC=1|the Fabric authority is not currently valid"
"current eligibility is false|change_selection; REFABRIC=1|the Fabric authority is not currently valid"
"the route has moved|supersede_route; REFABRIC=1|has been superseded and is no longer the route head"
"the Fabric baseline moved|corrupt \"\${FIX}/fabric/capability-routes/CROUTE-0006.yaml\"|the Fabric has moved"
"the runtime baseline moved|corrupt \"\${FIX}/runtime/execution/cadm-counter\"|the capability-runtime store has moved"
"CINV-000003 changed|corrupt \"\${FIX}/runtime/capability-invocations/CINV-000003.yaml\"; RERENDER=1|CINV-000003.yaml is"
"the lifecycle is not launch_authorized|revert_lifecycle; RERENDER=1|the lifecycle is"
"the launch-authorisation changed|corrupt \"\${FIX}/runtime/execution/CINV-000003/launch-authorisation\"; RERENDER=1|launch-authorisation is"
"the handoff payload changed|corrupt \"\${FIX}/handoff/CINV-000003/payload\"|payload is"
"the handoff profile changed|corrupt \"\${FIX}/handoff/CINV-000003/profile\"|profile is"
"the handoff output directory is missing|chmod u+w \"\${FIX}/handoff/CINV-000003\"; rmdir \"\${FIX}/handoff/CINV-000003/out\"|the handoff has no output directory"
"the payload changed|corrupt \"\${FIX}/work/third-invoke.json\"|third-invoke.json is"
"the staged tree changed|corrupt \"\${FIX}/runtime/staging/tree-sha256-\${ARTIFACT_DIGEST}/main.py\"; RERENDER=1|main.py is"
"a result already exists|cp \"\${FIX}/runtime/capability-results/CRES-000001.yaml\" \"\${FIX}/runtime/capability-results/CRES-000002.yaml\"; RERENDER=1|CRES-000002 exists"
"the result sequence moved|printf '2\\n' > \"\${FIX}/runtime/sequences/capability-result.seq\"; RERENDER=1|capability-result.seq is not 1"
"the invocation sequence moved|printf '9\\n' > \"\${FIX}/runtime/sequences/capability-invocation.seq\"; RERENDER=1|capability-invocation.seq is not 3"
"a lifecycle transition appeared|cp \"\${FIX}/runtime/execution/transitions/CINV-000003.000002\" \"\${FIX}/runtime/execution/transitions/CINV-000003.000003\"; RERENDER=1|the transition journal does not hold 7 records"
"the execution image is absent|printf 'stage-3-observation\\nno-target-container kyri-CINV-000003\\n' > \"\${FIX}/work/witness\"|does not record the expected execution image"
"a target container exists|printf 'stage-3-observation\\nimage 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190\\n' > \"\${FIX}/work/witness\"|does not record the absence of a kyri-CINV-000003 container"
"the witness is absent|rm -f \"\${FIX}/work/witness\"|run BLOCK A first"
"the witness is stale|touch -d '2 hours ago' \"\${FIX}/work/witness\"|re-run BLOCK A"
)

for case in "${SABOTAGE[@]}"; do
  IFS='|' read -r name breakage refusal <<<"${case}"
  build_fixture "${FIX}"
  render_gates "${FIX}" "${rendered}"
  RERENDER=0; REFABRIC=0
  eval "${breakage}"
  (( RERENDER == 1 )) && sed -i "s#^RUNTIME_BEFORE=.*#RUNTIME_BEFORE=$(aggregate "${FIX}/runtime")#" "${rendered}"
  (( REFABRIC == 1 )) && sed -i "s#^FABRIC_BEFORE=.*#FABRIC_BEFORE=$(aggregate "${FIX}/fabric")#" "${rendered}"

  out="${WORK}/sabotage.out"; status=0
  ( cd "${ROOT}" && bash "${rendered}" ) > "${out}" 2>&1 || status=$?
  if (( status != 0 )); then
    pass "${name}: BLOCK B exits nonzero"
  else
    fail "${name}: BLOCK B exited 0"
  fi
  if grep -qF -- "${refusal}" "${out}"; then
    pass "${name}: refuses for its own reason (${refusal})"
  else
    fail "${name}: refused, but not for its own reason: $(grep -m1 -E 'REFUSE' "${out}" || echo 'no refusal line')"
  fi
  if grep -q 'Traceback (most recent call last)' "${out}"; then
    fail "${name}: something crashed instead of judging its input"
  else
    pass "${name}: no traceback"
  fi
done

# ===========================================================================
# 8. Production, after everything
# ===========================================================================

printf -- '\n--- production untouched ---\n'
if [[ "$(aggregate "${PRODUCTION}")" == "${PRODUCTION_BEFORE}" ]]; then
  pass "the production runtime is byte-identical: ${PRODUCTION_BEFORE}"
else
  fail "THE PRODUCTION RUNTIME CHANGED"
fi
if [[ "$(aggregate "${PRODUCTION_FABRIC}")" == "${FABRIC_BEFORE}" ]]; then
  pass "the production Fabric is byte-identical"
else
  fail "THE PRODUCTION FABRIC CHANGED"
fi
if [[ ! -e "${PRODUCTION}/capability-results/CRES-000002.yaml" ]]; then
  pass "no CRES-000002 exists in production: the payload has not executed"
else
  fail "A PRODUCTION RESULT WAS WRITTEN"
fi
if [[ "$(cat "${PRODUCTION}/sequences/capability-result.seq")" == "1" ]]; then
  pass "the production result sequence is still 1"
else
  fail "the production result sequence moved"
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf 'CINV-000003 Stage 3 rehearsal passed.\n'
else
  printf 'CINV-000003 Stage 3 rehearsal FAILED: %d\n' "${FAILURES}" >&2
  exit 1
fi
