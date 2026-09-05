#!/usr/bin/env bash
set -Eeuo pipefail

# One governed execution, supervised end to end, against a real container.
#
# HOST-ONLY AND ISOLATED. The image comes from the exported OCI archive into a
# disposable Podman store; every container is created and removed there. No
# production path is opened, no production CINV or CRES is created, no sudo is
# used and no privileged helper is invoked.
#
# WHAT IS REAL HERE, AND WHAT IS NOT
# ==================================
# Real: the supervisor, the protocol over inherited pipe descriptors, the
# adapter, the Podman backend, the container, the workload, the reconciler, and
# a SIGKILL that cannot be trapped.
#
# Not real: the privilege drop. The worker half runs in a forked child as this
# same unprivileged user, because dropping to the execution identity needs root
# and would drive rootless Podman into the production graphroot. What the
# transition would have done before the worker exists is proven separately, by
# the reconcile-entrypoint suite and the transition-action suite.
#
# THE ACCEPTANCE TEST
# ===================
# G11-AP proved by experiment that killing the client does not stop the
# container. G11-AQ built the governed operation that removes it. G11-AS made
# that operation reachable across the privilege boundary. This is the first
# suite where the whole chain runs: a worker is killed mid-execution, the
# supervisor notices the conversation ended, reconciliation proves the container
# gone, and the invocation stays interrupted with no result invented for it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"

ARCHIVE="/tmp/kyri-g11-ai-oci-a999e0e2c2bd/cimp-000001-5cee2b53.oci-archive.tar"
host_only_requires "${ARCHIVE}" /usr/bin/podman

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="/tmp/kat-sup"
podman unshare rm -rf "${WORK}" 2>/dev/null || true
mkdir -p "${WORK}/r" "${WORK}/rr"
cleanup() {
  podman --root "${WORK}/r" --runroot "${WORK}/rr" rm --all --force \
    >/dev/null 2>&1 || true
  podman unshare rm -rf "${WORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '=== isolated import ===\n'
podman --root "${WORK}/r" --runroot "${WORK}/rr" load -i "${ARCHIVE}" 2>&1 | tail -1

if ! (cd "${ROOT}" && WORK="${WORK}" python3 - <<'HARNESS'
import hashlib
import importlib.util
import json
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, ".")
WORK = os.environ["WORK"]
GOVERNED = "5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
STORAGE = ("--root", f"{WORK}/r", "--runroot", f"{WORK}/rr")
UID, GID = os.getuid(), os.getgid()

from tools.capability.execution import adapter as AD
from tools.capability.execution import profile as P
from tools.capability.execution import protocol as PR
from tools.capability.execution import recovery as RC
from tools.capability.execution import supervision as SV
from tools.capability.execution import worker as W
from tools.capability.execution.implementation_authority import Admission


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


B = load("kyri_exec_podman", "provisioning/execution/kyri-exec-podman.py")
R = load("kyri_exec_reconcile", "provisioning/execution/kyri-exec-reconcile.py")

failures = 0


def check(label, expected, actual):
    global failures
    ok = actual == expected
    print(f"  {label:44} {'PASS' if ok else 'FAIL'}  {actual!r}"
          + ("" if ok else f"  expected {expected!r}"))
    if not ok:
        failures += 1


ENVIRONMENT = (("HOME", os.path.expanduser("~")), ("PATH", "/usr/bin:/bin"),
               ("XDG_RUNTIME_DIR", f"/run/user/{UID}"))


def backend(timeout=60):
    return B.backend_for("python-podman-v1", storage=STORAGE,
                         environment=ENVIRONMENT, timeout=timeout)


def governed_profile(cinv):
    admission = Admission(
        cimp="CIMP-000001", oci_image_id=GOVERNED,
        adapter_identity="python-podman-v1", payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity="fixed-python-entrypoint-v1",
        provisioning_evidence_digest="b" * 64)
    return P.build_profile(P.ProfileBinding(
        cinv=cinv, admission=admission, payload_digest="c" * 64,
        package_digest="d" * 64, package_entrypoint="main.py"))


def workload(cinv, body):
    """One package tree, exactly as the snapshot would have materialised it."""
    base = Path(WORK) / cinv
    for part in ("pkg", "out", "payload"):
        (base / part).mkdir(parents=True, exist_ok=True)
    (base / "pkg" / "main.py").write_text(body, encoding="utf-8")
    payload = base / "payload-file"
    payload.write_text(json.dumps({"operation": "execute"}), encoding="utf-8")
    return base


def worker_child(cinv, body, *, timeout=60):
    """The worker half, in a forked child, speaking the real protocol.

    It runs the production adapter over a real Podman backend and a real
    container. What it does not do is drop privilege -- that needs root, and a
    real drop would open the production graphroot.
    """
    base = workload(cinv, body)
    to_child_r, to_child_w = os.pipe()
    from_child_r, from_child_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        status = 0
        try:
            os.close(to_child_w)
            os.close(from_child_r)
            profile = governed_profile(cinv)
            from tools.capability.execution import snapshot as S
            binding = S.SnapshotBinding(
                S._MATERIALISED, cinv=cinv, profile=profile,
                payload=str(base / "payload-file"), package=str(base / "pkg"),
                output=str(base / "out"), entrypoint="main.py",
                payload_digest="c" * 64, package_digest="d" * 64)
            channel = PR.Channel(
                cinv,
                reader=_frames(to_child_r),
                writer=lambda frame: os.write(from_child_w, frame))
            handle = os.open(str(base / "out"), os.O_RDONLY | os.O_DIRECTORY)
            execution = AD.ExecutionBinding(
                cinv=cinv, profile=profile,
                profile_digest=hashlib.sha256(
                    P.canonical_profile(profile)).hexdigest(),
                argv=W.create_argv(binding), environment=ENVIRONMENT,
                output_fd=handle)
            AD.PythonPodmanAdapter(backend=backend(timeout), session=channel,
                                   clock=time.monotonic).execute(execution)
        except BaseException:  # noqa: BLE001 - the child reports by exiting
            status = 1
        finally:
            os._exit(status)
    os.close(to_child_r)
    os.close(from_child_w)
    return pid, from_child_r, to_child_w, base


def _frames(descriptor):
    buffered = bytearray()

    def nxt():
        while True:
            index = buffered.find(b"\n")
            if index >= 0:
                frame = bytes(buffered[:index + 1])
                del buffered[:index + 1]
                return frame
            chunk = os.read(descriptor, 4096)
            if not chunk:
                return None
            buffered.extend(chunk)

    return nxt


class Child:
    """The launched worker, as the supervisor's launcher contract sees it.

    ``kill_when_started`` reproduces G11-AP's experiment exactly: the
    coordinator grants the start, the worker attaches to the container, and the
    worker is then SIGKILLed while the workload is still running. It is done
    from here rather than inside the worker because `backend.start` attaches --
    it does not return until the workload has finished, so there is no moment
    inside the worker where the container is running and the worker holds
    control.
    """

    def __init__(self, pid, read_fd, write_fd, kill_when_started=False):
        self.pid, self._in, self._out = pid, read_fd, write_fd
        self._kill = kill_when_started
        self._buffer = bytearray()

    def reader(self):
        while True:
            index = self._buffer.find(b"\n")
            if index >= 0:
                frame = bytes(self._buffer[:index + 1])
                del self._buffer[:index + 1]
                return frame
            chunk = os.read(self._in, 4096)
            if not chunk:
                return None
            self._buffer.extend(chunk)

    def writer(self, frame):
        os.write(self._out, frame)
        if self._kill:
            # Long enough for the container to be genuinely running, which is
            # the state the orphan has to be left in for this to prove
            # anything. Confirmed below rather than assumed.
            time.sleep(3.0)
            os.kill(self.pid, signal.SIGKILL)

    def reap(self, timeout):
        for descriptor in (self._in, self._out):
            try:
                os.close(descriptor)
            except OSError:
                pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return status, True
            time.sleep(0.02)
        os.kill(self.pid, signal.SIGKILL)
        return os.waitpid(self.pid, 0)[1], False


class Launcher:
    """The one process seam, standing in for `sudo kyri-exec-transition`."""

    def __init__(self, body, **options):
        self.body, self.options = body, options
        self.launched = []

    def launch(self, cinv):
        self.launched.append(cinv)
        kill = self.options.pop("kill_when_started", False)
        pid, read_fd, write_fd, _ = worker_child(cinv, self.body, **self.options)
        return Child(pid, read_fd, write_fd, kill_when_started=kill)


def reconciler(*, refuse=False):
    """The governed reconciliation, standing in for the privileged helper.

    The helper cannot be invoked -- it is not installed and there is no sudoers
    grant -- so the module it would exec after dropping privilege is driven
    directly, against the same disposable store. That is the same seam G11-AQ
    proved the operation through.
    """
    calls = []

    def call(cinv):
        calls.append(cinv)
        if refuse:
            raise OSError("the reconciliation helper is not installed")
        return R.reconcile(cinv, backend=backend())

    call.calls = calls
    return call


def state(name):
    import subprocess
    done = subprocess.run(
        ["podman", *STORAGE, "inspect", "--type", "container", "--format",
         "{{.State.Status}}", name], capture_output=True, text=True, check=False)
    return done.stdout.strip() if done.returncode == 0 else "absent"


def supervise(cinv, body, *, refuse_cleanup=False, **options):
    launcher = Launcher(body, **options)
    clean = reconciler(refuse=refuse_cleanup)
    supervisor = SV.ExecutionSupervisor(launcher=launcher, reconciler=clean)
    try:
        return supervisor.execute(SV.SupervisedBinding(
            cinv=cinv, profile=governed_profile(cinv),
            profile_digest=hashlib.sha256(
                P.canonical_profile(governed_profile(cinv))).hexdigest())), \
            None, supervisor, clean
    except SV.SupervisionRefused as refusal:
        return None, refusal, supervisor, clean


RESULT = ("import json, pathlib\n"
          "pathlib.Path('/kyri/output/result.json').write_text("
          "json.dumps({'schema_version': 1, 'status': 'ok'}))\n")
SLEEPER = "import time\ntime.sleep(120)\n"

# --- PART 1: a supervised success, end to end --------------------------------

print("\n=== PART 1 - supervised success against a real container ===")
outcome, refusal, supervisor, clean = supervise("CINV-000042", RESULT)
check("no refusal", None, refusal)
if outcome is not None:
    check("outcome class", "completed", outcome.outcome_class)
    check("succeeded", True, outcome.succeeded)
    check("result digest carried", True,
          isinstance(outcome.result_digest, str)
          and outcome.result_digest.startswith("sha256:"))
    check("started proven", True, outcome.started_proven)
    check("the coordinator holds no output tree", None, outcome.output)
trace = supervisor.trace
check("protocol reached collected", "collected", trace.states[-1])
check("worker reaped", True, trace.worker_reaped)
check("disposal proven", True, trace.disposal_proven)
check("container absent afterwards", "absent", state("kyri-CINV-000042"))
check("reconciliation ran for this CINV", ["CINV-000042"], clean.calls)

# --- PART 2: exit zero with no result ----------------------------------------

print("\n=== PART 2 - a workload that produces nothing ===")
outcome, refusal, supervisor, clean = supervise("CINV-000043", "pass\n")
check("no refusal", None, refusal)
if outcome is not None:
    check("outcome class", "completed", outcome.outcome_class)
    check("succeeded", False, outcome.succeeded)
    check("no digest", None, outcome.result_digest)
check("container absent afterwards", "absent", state("kyri-CINV-000043"))

# --- PART 3: the worker is killed mid-execution ------------------------------

print("\n=== PART 3 - the worker is SIGKILLed while the container runs ===")
outcome, refusal, supervisor, clean = supervise(
    "CINV-000044", SLEEPER, kill_when_started=True)
check("no outcome was concluded", None, outcome)
check("the supervisor refused", True, refusal is not None)
# Death carries no claim about the workload. It is not a terminal state and is
# never classified as one.
check("no classification was invented", None,
      refusal.classification if refusal else "missing")
check("the conversation did not complete", False,
      supervisor.trace.protocol_complete)
check("the worker was reaped", True, supervisor.trace.worker_reaped)
check("reconciliation was invoked for the exact CINV", ["CINV-000044"],
      clean.calls)
check("the orphan was proven absent", True, supervisor.trace.disposal_proven)
check("no container survives", "absent", state("kyri-CINV-000044"))
report = supervisor.trace.reconciled
check("reconciliation stopped a running container", "stopped-and-removed",
      report.get("outcome") if isinstance(report, dict) else report)
check("container identity was verified before removal", True,
      report.get("container_identity_verified") if isinstance(report, dict)
      else None)

# --- PART 4: reconciliation cannot prove absence -----------------------------

print("\n=== PART 4 - cleanup that cannot be proven is not claimed ===")
outcome, refusal, supervisor, clean = supervise(
    "CINV-000045", RESULT, refuse_cleanup=True)
check("no outcome was concluded", None, outcome)
check("the supervisor refused", True, refusal is not None)
check("disposal not proven", False, supervisor.trace.disposal_proven)
# The conversation itself was fine -- the workload ran and produced a result --
# and it still yields no terminal record, because a result beside a container
# nobody looked for is the one thing this boundary exists to prevent.
check("the conversation completed", True, supervisor.trace.protocol_complete)
leftover = state("kyri-CINV-000045")
check("the container is still there to be found", True, leftover != "absent")

# --- PART 5: the readiness gate finds it -------------------------------------

print("\n=== PART 5 - the unresolved invocation blocks readiness ===")


class Store:
    """The two record kinds, as the coordinator would have written them."""

    def __init__(self, invocations, results):
        self._records = {"capability-invocation": invocations,
                         "capability-result": results}

    def list_records(self, kind):
        return list(self._records.get(kind, ()))


unresolved = Store(
    [{"invocation_record_id": "CINV-000045", "invocation_id": "CINV-000045",
      "adapter_identity": "python-podman-v1"}], [])
blocked = RC.execution_safety(unresolved, reconciler=reconciler(refuse=True))
check("readiness while the container state is unknown", RC.NOT_READY,
      blocked.state)
check("the unresolved invocation is named", ["CINV-000045"],
      [f.invocation_id for f in blocked.unresolved])
check("it is reported interrupted", True,
      all(f.interrupted for f in blocked.unresolved))

# Now let the real reconciler resolve it, exactly as an operator recovery would.
resolved = RC.execution_safety(unresolved, reconciler=reconciler())
check("readiness after recovery", RC.READY, resolved.state)
check("the container really is gone", "absent", state("kyri-CINV-000045"))
check("no result was synthesised", [], unresolved.list_records(
    "capability-result"))

# A second pass is harmless: absence is success and nothing changes.
again = RC.execution_safety(unresolved, reconciler=reconciler())
check("a second recovery pass stays ready", RC.READY, again.state)
check("and reports it as already absent", ["absent"],
      [f.disposition for f in RC.reconcile_unresolved(
          unresolved, reconciler=reconciler())])

# --- PART 6: the supervised orphan, which PART 5 could not have found ---------
#
# PART 5 uses `adapter_identity`, which only a locally executed adapter writes.
# THE SUPERVISED PATH NEVER WRITES IT: `command_invoke` passes no adapter and
# no execution binding, and `CINV` is immutable afterwards. G11-BB found the
# consequence in production -- an invocation that reached `launch_authorized`
# and lost supervision was invisible to the surface built to find it, so a real
# orphan would have been reported as nothing to see.
#
# This part is that exact shape: a null adapter identity, a real lifecycle
# journal, and a real container left running.

print("\n=== PART 6 - a supervised orphan is discovered from lifecycle authority ===")

from tools.capability.execution import capacity as CAP
from tools.capability.execution import state as ST
from tools.capability.execution.backing_store import (
    ObservedFilesystem, verify_backing_store)
from tools.capability.execution.canonical_json import serialise as _serialise
from tools.capability.execution.mutation import CMUT_COUNTER
from tools.capability.execution.types import LifecycleState

SUPERVISED = "CINV-000046"
_UUID = "12774bf1-cf2a-4c8c-ba19-42fd9a8a0a96"

_exec_base = Path(WORK) / "execution-authority"
for _sub in ("root/mutations", "root/state", "root/" + ST.TRANSITIONS_DIRECTORY,
             "root/" + CAP.LOCKS_DIRECTORY):
    (_exec_base / _sub).mkdir(parents=True, exist_ok=True)
(_exec_base / "backing-store.json").write_bytes(_serialise(
    {"filesystem_uuid": _UUID, "filesystem_type": "xfs",
     "mount_point": "/data"}))
(_exec_base / "root" / CMUT_COUNTER).write_bytes(b"000000000000\n")

_cfg = os.open(str(_exec_base / "backing-store.json"), os.O_RDONLY)
_rt = os.open(str(_exec_base / "root"), os.O_RDONLY | os.O_DIRECTORY)
try:
    EXEC_ROOT = verify_backing_store(_cfg, _rt, observed=ObservedFilesystem(
        filesystem_uuid=_UUID, filesystem_type="xfs",
        mount_point="/data", device_name="/dev/sdb1"))
finally:
    os.close(_cfg)
    os.close(_rt)

# The journal the coordinator writes before the privileged boundary is crossed.
CAP.reserve(EXEC_ROOT, SUPERVISED)
ST.transition(EXEC_ROOT, SUPERVISED, LifecycleState.RESERVED,
              LifecycleState.LAUNCH_AUTHORIZED)
check("the journal reached launch_authorized",
      LifecycleState.LAUNCH_AUTHORIZED, ST.all_states(EXEC_ROOT)[SUPERVISED])

# A real orphan: the worker is killed while its container runs.
supervise(SUPERVISED, SLEEPER, kill_when_started=True,
          refuse_cleanup=True)
check("a real container was left behind", True,
      state(f"kyri-{SUPERVISED}") != "absent")

supervised_store = Store(
    [{"invocation_record_id": SUPERVISED, "invocation_id": SUPERVISED,
      "adapter_identity": None}], [])

# The defect, pinned: without the journal this orphan is invisible.
check("without lifecycle authority the orphan is invisible", (),
      RC.unresolved_invocations(supervised_store))

found = RC.unresolved_invocations(supervised_store, execution_root=EXEC_ROOT)
check("with lifecycle authority it is discovered", [SUPERVISED],
      [item.invocation_id for item in found])
check("and it is discovered by state, not adapter identity",
      ("launch_authorized", None),
      (found[0].lifecycle_state, found[0].adapter_identity))

# Readiness must not become true until disposal is proven.
blocked6 = RC.execution_safety(supervised_store, reconciler=reconciler(refuse=True),
                               execution_root=EXEC_ROOT)
check("readiness stays refused while disposal is unproven", RC.NOT_READY,
      blocked6.state)
check("the container is still running at that point", True,
      state(f"kyri-{SUPERVISED}") != "absent")

# Governed reconciliation only -- no manual podman action anywhere in this part.
recovered = RC.execution_safety(supervised_store, reconciler=reconciler(),
                                execution_root=EXEC_ROOT)
check("readiness after governed reconciliation", RC.READY, recovered.state)
check("the orphan was stopped and removed", "absent",
      state(f"kyri-{SUPERVISED}"))
check("no result was synthesised for it", [],
      supervised_store.list_records("capability-result"))

# A merely prepared invocation -- reserved, never launch-authorised -- is not
# unresolved: capacity was taken, but no container could exist.
PREPARED = "CINV-000047"
CAP.reserve(EXEC_ROOT, PREPARED)
prepared_store = Store(
    [{"invocation_record_id": PREPARED, "invocation_id": PREPARED,
      "adapter_identity": None}], [])
check("a reserved-only invocation is not unresolved", (),
      RC.unresolved_invocations(prepared_store, execution_root=EXEC_ROOT))

print("\n=== verdict ===")
if failures:
    print(f"SUPERVISED_E2E=FAIL ({failures})")
    raise SystemExit(1)
print("SUPERVISED_SUCCESS=PASS")
print("WORKER_SIGKILL_ORPHAN_RECOVERED=PASS")
print("ORPHAN_CONTAINER=NO")
print("RECONCILIATION_FAILURE_FAILS_CLOSED=YES")
print("SERVICE_READINESS_GATE=PASS")
print("INTERRUPTED_CRES_CREATED=NO")
HARNESS
); then
  fail "the supervised execution harness failed"
else
  pass "supervised success, no-result, worker death, unproven cleanup, readiness"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability supervised execution E2E validation passed.\n'
else
  printf 'Capability supervised execution E2E validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
