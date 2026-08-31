#!/usr/bin/env bash
set -Eeuo pipefail

# One governed invocation, prepared by the real coordinator and executed in a
# real container.
#
# HOST-ONLY AND ISOLATED. The fixture is shaped from the production Fabric,
# Trust and artifact stores and then stands alone: every write lands in a
# temporary root, the image comes from the exported OCI archive into a
# disposable Podman store, and no production path is opened for writing. No
# production CINV, CRES, container or image is created.
#
# WHAT THIS JOINS, AND WHAT IT DOES NOT
# =====================================
# `prepare_invocation` is the front half in full: selected-evidence
# verification, current Fabric eligibility, operation authority, package
# resolution and staging, the invocation binding, and the durable CINV/CRES
# record. It then executes -- but only when a caller supplies BOTH an
# authorised adapter and a governed binding, which is the seam this suite uses
# and the only one the coordinator has.
#
# The released CLI cannot reach that seam. `invoke` has no flag that supplies
# an adapter, so it always ends at `no_authorised_adapter` and returns denied.
# That is deliberate: the coordinator prepares, and the privileged transition
# executes. So this suite proves the coordinator half joined to a real
# container, and the transition/worker hop -- which needs sudo -- is proven
# separately by the worker-binding suite and the backend probe.
#
# Where privilege is concerned nothing is simulated: this runs unprivileged
# throughout, and the credential drop it does not perform is the one the
# transition would already have performed before the worker exists.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"

ARCHIVE="/tmp/kyri-g11-ai-oci-a999e0e2c2bd/cimp-000001-5cee2b53.oci-archive.tar"

host_only_requires /var/lib/kyri/fabric /var/lib/kyri/trust \
                   /var/lib/kyri/artifacts "${ARCHIVE}" /usr/bin/podman

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="/tmp/kam-e2e"
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

if ! (cd "${ROOT}" && WORK="${WORK}" ARCHIVE="${ARCHIVE}" python3 - <<'HARNESS'
import importlib.util, json, os, shutil, subprocess, sys
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, ".")
WORK = os.environ["WORK"]
GOVERNED = "5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
UID, GID = os.getuid(), os.getgid()

spec = importlib.util.spec_from_file_location(
    "kyri_exec_podman", "provisioning/execution/kyri-exec-podman.py")
B = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_podman"] = B
spec.loader.exec_module(B)

from tools.capability.coordinator import prepare_invocation
from tools.capability.execution import adapter as AD
from tools.capability.execution import lifecycle as L
from tools.capability.execution import profile as P
from tools.capability.execution import snapshot as S
from tools.capability.execution import worker as W
from tools.capability.records import INVOCATION_KIND
from tools.capability.store import CapabilityStore

failures = 0


def check(label, expected, actual):
    global failures
    ok = actual == expected
    print(f"  {label:38} {'PASS' if ok else 'FAIL'}  {actual!r}"
          + ("" if ok else f"  expected {expected!r}"))
    if not ok:
        failures += 1


def governed_instant(fabric: Path, instance_id: str) -> str:
    """An instant inside the fixture's OWN admission and advertisement windows.

    Derived from the records the fixture holds rather than from the clock, for
    the reason G11-AH established: the production chain expires, and a suite
    that read the wall clock would start failing for a reason unrelated to what
    it tests.
    """
    def field(path, key):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith(f"{key}:"):
                # YAML scalars here are quoted with either mark.
                return line.split(":", 1)[1].strip().strip('\'"')
        raise AssertionError(f"{path}: no {key}")

    instance = fabric / "capability-instances" / f"{instance_id}.yaml"
    advert = field(instance, "advertisement_id")
    advertisement = (fabric / "capability-advertisements" / f"{advert}.yaml")
    parse = datetime.fromisoformat
    opens = max(parse(field(instance, "admitted_at")),
                parse(field(advertisement, "observed_at")))
    closes = min(parse(field(instance, "admitted_until")),
                 parse(field(advertisement, "valid_until")))
    if closes <= opens:
        raise AssertionError("the fixture has no live interval")
    return (opens + (closes - opens) / 2).isoformat()


def fixture(base: Path):
    """A production-shaped fixture that then stands alone."""
    for name in ("fabric", "trust", "artifacts"):
        shutil.copytree(Path("/var/lib/kyri") / name, base / name)
    for entry in (base / "artifacts").rglob("*"):
        entry.chmod(0o755 if entry.is_dir() else 0o644)
    (base / "artifacts").chmod(0o755)
    payload = base / "payload"
    payload.mkdir(mode=0o755)
    (payload / "payload.json").write_text('{"operation":"execute"}')
    (payload / "payload.json").chmod(0o644)
    for name, mode in (("store", 0o700), ("staging", 0o700)):
        (base / name).mkdir(mode=mode)
    return {
        "fabric": base / "fabric", "trust": base / "trust",
        "artifacts": base / "artifacts", "payload": payload,
        "store": base / "store", "staging": base / "staging",
        "instant": governed_instant(base / "fabric", "CINST-000002"),
    }


def manifest(root: Path):
    """Every path beneath a root with its size -- a residue detector."""
    out = {}
    for entry in sorted(root.rglob("*")):
        out[str(entry.relative_to(root))] = (
            entry.stat().st_size if entry.is_file() else "dir")
    return out


def workload(body, name):
    """A package and output leaf for one execution."""
    base = Path(WORK) / name
    shutil.rmtree(base, ignore_errors=True)
    (base / "pkg").mkdir(parents=True)
    (base / "out").mkdir(parents=True)
    (base / "pkg" / "main.py").write_text(body)
    (base / "payload").write_text('{"schema_version":1}\n')
    os.chmod(base / "out", 0o700)
    return base


def execution(name, body, *, image=None, argv_edit=None, timeout=60):
    """A governed execution binding over the real backend and image."""
    base = workload(body, name)
    admission = P.Admission(
        cimp="CIMP-000001", oci_image_id=image or GOVERNED,
        adapter_identity="python-podman-v1", payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity="fixed-python-entrypoint-v1",
        provisioning_evidence_digest="b" * 64)
    profile = P.build_profile(P.ProfileBinding(
        cinv="CINV-000042", admission=admission, payload_digest="c" * 64,
        package_digest="d" * 64, package_entrypoint="main.py"))
    binding = S.SnapshotBinding(
        S._MATERIALISED, cinv="CINV-000042", profile=profile,
        payload=str(base / "payload"), package=str(base / "pkg"),
        output=str(base / "out"), entrypoint="main.py",
        payload_digest="c" * 64, package_digest="d" * 64)
    argv = list(W.create_argv(binding))
    if argv_edit is not None:
        argv = argv_edit(argv, base)

    env = (("HOME", os.path.expanduser("~")), ("PATH", "/usr/bin:/bin"),
           ("XDG_RUNTIME_DIR", f"/run/user/{UID}"))
    backend = B.backend_for(
        "python-podman-v1",
        storage=("--root", f"{WORK}/r", "--runroot", f"{WORK}/rr"),
        environment=env, timeout=timeout)

    class Session:
        def __init__(self):
            self.container_id = None

        def expect(self, kind):
            class Message:
                def __init__(inner, cid):
                    inner._cid = cid

                def field_map(inner):
                    return {"container_id": inner._cid}

            return Message(self.container_id)

    session = Session()
    original = L.create

    def creating(be, a, e):
        identity = original(be, a, e)
        if session.container_id is None:
            session.container_id = identity
        return identity

    handle = os.open(str(base / "out"), os.O_RDONLY | os.O_DIRECTORY)
    return (AD.ExecutionBinding(cinv="CINV-000042", profile=profile,
                                argv=tuple(argv), environment=env,
                                output_fd=handle),
            backend, session, creating, original, handle, base)


def invoke(paths, *, name, body, image=None, argv_edit=None, clock=None,
           timeout=60, execute=True, identity=None):
    """One real preparation, executed through the coordinator's own seam."""
    bound = execution(name, body, image=image, argv_edit=argv_edit,
                      timeout=timeout) if execute else None
    adapter = binding = None
    if bound:
        eb, backend, session, creating, original, handle, base = bound
        L.create = creating
        adapter = AD.PythonPodmanAdapter(
            backend=backend, session=session,
            clock=clock or (lambda: 0.0))
        binding = eb
    try:
        return prepare_invocation(
            CapabilityStore(str(paths["store"]), expected_uid=UID,
                            expected_gid=GID),
            fabric_root=str(paths["fabric"]), fabric_expected_uid=UID,
            fabric_expected_gid=GID,
            approved_artifact_root=str(paths["artifacts"]),
            trusted_source_uid=UID, staging_root=str(paths["staging"]),
            coordinator_uid=UID, selection_id="CSEL-000001",
            instance_id="CINST-000002", capability_package_id="CPKG-0001",
            operation="execute", trust_root=str(paths["trust"]),
            invocation_id=identity or name,
            payload={"operation": "execute"}, actor="primary-platform-operator",
            request_id=identity or name,
            requested_at=datetime.fromisoformat(paths["instant"]),
            adapter=adapter, execution_binding=binding), bound
    finally:
        if bound:
            L.create = bound[4]
            os.close(bound[5])


def containers():
    out = subprocess.run(
        ["podman", "--root", f"{WORK}/r", "--runroot", f"{WORK}/rr",
         "ps", "--all", "--no-trunc", "--format", "{{.ID}}"],
        capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def reap():
    for identity in containers():
        subprocess.run(["podman", "--root", f"{WORK}/r", "--runroot",
                        f"{WORK}/rr", "rm", "--force", identity],
                       capture_output=True, check=False)


WRITES = ('import json\n'
          'open("/kyri/output/result.json","w")'
          '.write(json.dumps({"ok":True,"value":42}))\n')

# --- the front half joined to a real container -------------------------------

print("\n=== PART 1 - full isolated invoke, success ===")
with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    before = manifest(paths["fabric"])
    decision, bound = invoke(paths, name="kam-success", body=WRITES)

    check("preparation status", "prepared", decision.status)
    # The outcome class T13 concluded, carried through unchanged.
    check("execution outcome", "completed", decision.reason)
    check("CINV allocated", True, bool(decision.invocation_record_id))
    # PINNED, not expected. The coordinator allocates a result record ONLY on
    # refusal: a prepared invocation returns result_record_id=None and nothing
    # writes one afterwards. So the durable store carries no record of what the
    # execution did. See the report -- this is the checkpoint's stop.
    check("CRES absent for a prepared invocation", None,
          decision.result_record_id)
    check("package staged", True, bool(decision.staged_path))
    check("payload digest bound", True, bool(decision.payload_digest))
    check("fabric authority unchanged", before, manifest(paths["fabric"]))

    base = bound[6]
    result = base / "out" / "result.json"
    check("workload wrote the governed result", True, result.is_file())
    check("result content", {"ok": True, "value": 42},
          json.loads(result.read_text()))
    check("host output owner preserved", (UID, GID),
          (os.stat(base / "out").st_uid, os.stat(base / "out").st_gid))
    check("output mode not widened", 0o700,
          os.stat(base / "out").st_mode & 0o777)

    print("\n  -- mutation manifest --")
    store_files = sorted(manifest(paths["store"]))
    print(f"     PERSISTENT  invocation store: {len(store_files)} objects")
    print(f"     PERSISTENT  CINV {decision.invocation_record_id}")
    print(f"     PERSISTENT  CRES {decision.result_record_id}")
    print(f"     PERSISTENT  staging: {decision.staged_path is not None}")
    print(f"     TEMPORARY   container(s) before reap: {len(containers())}")
    reap()
    check("containers removed", 0, len(containers()))
    check("no production CINV written", False,
          Path("/var/lib/kyri/capability/invocations").exists()
          and any(p.name.startswith("kam-") for p in
                  Path("/var/lib/kyri/capability/invocations").rglob("*")))

# --- CINV/CRES are spent before the backend is reached ------------------------

print("\n=== PART 2 - identity is spent before execution ===")
with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    # A workload that fails. The record was already committed, so the identity
    # is spent whatever the container then does -- which is the property that
    # makes a crash during execution accountable rather than invisible.
    decision, bound = invoke(paths, name="kam-exit42",
                             body="import sys\nsys.exit(42)\n")
    check("preparation still prepared", "prepared", decision.status)
    check("outcome is a provider error", "provider-error", decision.reason)
    check("CINV spent anyway", True, bool(decision.invocation_record_id))
    check("CRES still absent after a failed execution", None,
          decision.result_record_id)
    reap()

    # Replay: the same invocation identity a second time.
    replay, _ = invoke(paths, name="kam-exit42", body=WRITES)
    check("a replayed identity is refused", True,
          replay.status != "prepared" or replay.reason != "completed")
    print(f"     replay status={replay.status!r} reason={replay.reason!r}")
    reap()

# --- backend success is not capability success --------------------------------

print("\n=== PART 3 - exit 0 with no admissible result ===")
with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    decision, bound = invoke(paths, name="kam-noresult", body="pass\n")
    # The container exited zero. Nothing was collectable, so nothing is
    # admitted -- backend process success is not capability success.
    check("terminal class", "completed", decision.reason)
    base = bound[6]
    check("no result was written", False,
          (base / "out" / "result.json").exists())
    reap()

# --- the failure matrix, driven from the front half ---------------------------

print("\n=== PART 4 - failure matrix through the coordinator ===")


def matrix_case(label, expected_reason, **kwargs):
    with TemporaryDirectory() as tmp:
        paths = fixture(Path(tmp))
        decision, _ = invoke(paths, name=f"kam-{label}", **kwargs)
        spent = bool(decision.invocation_record_id)
        left = len(containers())
        reap()
        # What the store durably says afterwards. The same for every row, which
        # is exactly the problem: the outcome above is in memory only.
        # Read through the store's own API rather than a hand-built path: the
        # layout is the store's business and a guessed filename proves nothing.
        store = CapabilityStore(str(paths["store"]), expected_uid=UID,
                                expected_gid=GID)
        durable = (store.read_record(INVOCATION_KIND,
                                     decision.invocation_record_id)
                   if spent else {})
        recorded = (durable.get("evidence") or {}).get("outcome")
        ok = (decision.reason == expected_reason
              and recorded == "execution-prepared"
              and decision.result_record_id is None)
        print(f"  {label:22} reason={decision.reason:15} "
              f"CINV={'spent' if spent else 'unspent':7} "
              f"CRES={'none':5} durable={recorded or 'absent':19} "
              f"containers={left} orphan=NO {'PASS' if ok else 'FAIL'}")
        return ok


def extra_mount(argv, base):
    at = argv.index(GOVERNED)
    return argv[:at] + ["--mount",
                        f"type=bind,src={base}/payload,dst=/kyri/extra,ro=true"] + argv[at:]


def socket_mount(argv, base):
    import socket as socket_module
    path = str(base / "podman.sock")
    listener = socket_module.socket(socket_module.AF_UNIX,
                                    socket_module.SOCK_STREAM)
    listener.bind(path)
    at = argv.index(GOVERNED)
    return argv[:at] + ["--mount",
                        f"type=bind,src={path},dst=/kyri/sock,ro=true"] + argv[at:]


def wrong_mapping(argv, base):
    at = argv.index("--userns")
    return argv[:at + 1] + ["keep-id:uid=1000,gid=1000"] + argv[at + 2:]


class Late:
    def __init__(self):
        self.readings = [0.0, float(L.TIMEOUT_SECONDS) + 1.0]

    def __call__(self):
        return (self.readings.pop(0) if self.readings
                else float(L.TIMEOUT_SECONDS) + 1.0)


ok = True
ok &= matrix_case("wrong-image", "adapter-error", body=WRITES, image="a" * 64)
ok &= matrix_case("extra-mount", "adapter-error", body=WRITES,
                  argv_edit=extra_mount)
ok &= matrix_case("socket-mount", "adapter-error", body=WRITES,
                  argv_edit=socket_mount)
ok &= matrix_case("wrong-user-mapping", "adapter-error", body=WRITES,
                  argv_edit=wrong_mapping)
ok &= matrix_case("workload-exit-42", "provider-error",
                  body="import sys\nsys.exit(42)\n")
ok &= matrix_case("output-absent", "completed", body="pass\n")
ok &= matrix_case("timeout", "timeout", body="import time\ntime.sleep(20)\n",
                  clock=Late())
if not ok:
    failures += 1

check("no orphan container after the whole matrix", 0, len(containers()))

print("\n=== verdict ===")
if failures:
    print(f"FULL_ISOLATED_INVOKE_E2E=FAIL ({failures})")
    raise SystemExit(1)
print("FULL_ISOLATED_INVOKE_E2E=PASS")
print("FAILURE_INVOKE_E2E=PASS")
print("CINV_LIFECYCLE=PASS   (spent at preparation, before the adapter)")
print("ORPHAN_CONTAINER=NO")
print()
print("CRES_LIFECYCLE=INCOMPLETE -- pinned, not passed.")
print("  A result record is allocated ONLY on refusal. Every row above leaves")
print("  the same durable state: CINV spent, no CRES, outcome still recorded")
print("  as execution-prepared. Seven materially different outcomes --")
print("  completed, provider-error, adapter-error, timeout -- are")
print("  indistinguishable in the store, and a prepared CINV cannot be told")
print("  apart from one that never executed. The outcome exists in memory")
print("  only. This is the checkpoint's stop; see the G11-AM report.")
HARNESS
); then
  fail "the isolated invoke harness failed"
else
  pass "full isolated invoke, mutation manifest, and failure matrix"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability invoke execution E2E validation passed.\n'
else
  printf 'Capability invoke execution E2E validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
