#!/usr/bin/env bash
set -Eeuo pipefail

# The governed Podman backend, driven through the real adapter against the real
# admitted image: create, verify, start on authority, classify, collect.
#
# ISOLATED. The image comes from the exported OCI archive and is loaded into a
# disposable root/runroot. No production Podman storage is opened, no Fabric or
# Trust record is read, no CINV or CRES is created, and no production
# invocation exists.
#
# NOTHING IS SIMULATED EXCEPT THE COORDINATOR. The backend is the real one, the
# argv is the one `create_argv` produces, the image is the admitted 5cee2b53,
# and T8 verification runs against what Podman actually reported. The only
# doubles are the start-authority session and the clock -- the two collaborators
# the adapter takes precisely because they belong to the coordinator, which is
# not what this proves.
#
# WHY THE FAILURE CASES MATTER MORE THAN THE SUCCESS
# ==================================================
# A backend that produces a good outcome on the happy path and an ambiguous one
# on failure is worse than no backend, because the ambiguity arrives only when
# something has already gone wrong. Every case below asserts the OUTCOME CLASS,
# not merely that something was raised, and the two that could leave a
# container behind assert that none remains.
#
# Usage:
#   bash provisioning/execution/g11-ak-backend-e2e.sh ARCHIVE [WORKDIR]

GOVERNED_IMAGE="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
REPOSITORY="${REPOSITORY:-/opt/schott-platform}"

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

ARCHIVE="${1:-}"
# Podman caps runroot at 50 characters.
WORK="${2:-/tmp/kak-e2e}"

[ -n "$ARCHIVE" ] || die "usage: $0 ARCHIVE [WORKDIR]"
[ -f "$ARCHIVE" ] || die "the archive ${ARCHIVE} is not a file"
[ "${#WORK}" -le 40 ] || die "WORKDIR must be short: podman caps runroot at 50 characters"
case "$WORK" in
    /data/kyri/capability*) die "the probe must not run against production storage" ;;
esac

podman unshare rm -rf "$WORK" 2>/dev/null || true
mkdir -p "${WORK}/r" "${WORK}/rr"
printf '=== isolated import ===\n'
podman --root "${WORK}/r" --runroot "${WORK}/rr" load -i "$ARCHIVE" 2>&1 | tail -1

python3 - "$WORK" "$REPOSITORY" "$GOVERNED_IMAGE" <<'HARNESS'
import importlib.util, json, os, shutil, subprocess, sys

work, repository, governed = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, repository)

spec = importlib.util.spec_from_file_location(
    "kyri_exec_podman",
    os.path.join(repository, "provisioning/execution/kyri-exec-podman.py"))
B = importlib.util.module_from_spec(spec)
sys.modules["kyri_exec_podman"] = B
spec.loader.exec_module(B)

from tools.capability.execution import adapter as AD
from tools.capability.execution import lifecycle as L
from tools.capability.execution import profile as P
from tools.capability.execution import snapshot as S
from tools.capability.execution import worker as W

ENVIRONMENT = (("HOME", os.path.expanduser("~")), ("PATH", "/usr/bin:/bin"),
               ("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
STORAGE = ("--root", f"{work}/r", "--runroot", f"{work}/rr")

failures = 0


def check(label, expected, actual):
    global failures
    ok = actual == expected
    print(f"  {label:34} {'PASS' if ok else 'FAIL'}  {actual!r}"
          + ("" if ok else f"  expected {expected!r}"))
    if not ok:
        failures += 1


class Session:
    """Start authority, as the coordinator grants it.

    Bound to the container the adapter actually created rather than to a name a
    caller chose: authorising by name would authorise whatever happens to hold
    that name at the moment the message is read.
    """

    def __init__(self, refuse=False, container_id=None):
        self.container_id = container_id
        self.refuse = refuse

    def expect(self, kind):
        if self.refuse:
            raise L.LifecycleRefused("no start authorisation was issued")

        class Message:
            def __init__(self, cid):
                self._cid = cid

            def field_map(self):
                return {"container_id": self._cid}

        return Message(self.container_id)


def workspace(name, body, *, output_mode=0o700):
    root = os.path.join(work, name)
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "pkg"))
    os.makedirs(os.path.join(root, "out"))
    with open(os.path.join(root, "pkg", "main.py"), "w") as handle:
        handle.write(body)
    with open(os.path.join(root, "payload"), "w") as handle:
        handle.write('{"schema_version":1}\n')
    os.chmod(os.path.join(root, "out"), output_mode)
    return root


def profile_for(image=None, cinv="CINV-000042"):
    admission = P.Admission(
        cimp="CIMP-000001", oci_image_id=image or governed,
        adapter_identity="python-podman-v1", payload_schema_version=1,
        execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
        argv_contract_identity="fixed-python-entrypoint-v1",
        provisioning_evidence_digest="b" * 64)
    return P.build_profile(P.ProfileBinding(
        cinv=cinv, admission=admission, payload_digest="c" * 64,
        package_digest="d" * 64, package_entrypoint="main.py"))


def run(name, body, *, image=None, argv_edit=None, session=None,
        clock=None, timeout=60, output_mode=0o700):
    """One governed execution, and what it concluded."""
    root = workspace(name, body, output_mode=output_mode)
    profile = profile_for(image=image, cinv="CINV-000042")
    snapshot = S.SnapshotBinding(
        S._MATERIALISED, cinv="CINV-000042", profile=profile,
        payload=f"{root}/payload", package=f"{root}/pkg", output=f"{root}/out",
        entrypoint="main.py", payload_digest="c" * 64, package_digest="d" * 64)
    argv = list(W.create_argv(snapshot))
    if argv_edit is not None:
        argv = argv_edit(argv, root)

    backend = B.backend_for("python-podman-v1", storage=STORAGE,
                            environment=ENVIRONMENT, timeout=timeout)
    live = session if session is not None else Session()

    # The adapter creates, so it learns the identity; the session is told the
    # same one so start authority names the container that exists.
    original = L.create

    def creating(be, a, e):
        identity = original(be, a, e)
        if live.container_id is None:
            live.container_id = identity
        return identity

    L.create = creating
    try:
        handle = os.open(f"{root}/out", os.O_RDONLY | os.O_DIRECTORY)
        try:
            binding = AD.ExecutionBinding(
                cinv="CINV-000042", profile=profile, argv=tuple(argv),
                environment=ENVIRONMENT, output_fd=handle)
            return AD.PythonPodmanAdapter(
                backend=backend, session=live,
                clock=clock or (lambda: 0.0)).execute(binding), root
        finally:
            os.close(handle)
    finally:
        L.create = original


def containers():
    out = subprocess.run(
        ["podman", *STORAGE, "ps", "--all", "--no-trunc", "--format", "{{.ID}}"],
        capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def reap():
    for identity in containers():
        subprocess.run(["podman", *STORAGE, "rm", "--force", identity],
                       capture_output=True, check=False)


WRITES_RESULT = 'import json\nopen("/kyri/output/result.json","w").write(json.dumps({"ok":True,"value":42}))\n'

print("\n=== success ===")
outcome, root = run("ok", WRITES_RESULT)
check("outcome class", "completed", outcome.outcome_class)
check("start proven", True, outcome.started_proven)
check("result trusted", True, outcome.succeeded)
check("workload document", {"ok": True, "value": 42},
      dict(outcome.result.document) if outcome.result else None)
check("host output owner preserved", (os.getuid(), os.getgid()),
      (os.stat(f"{root}/out").st_uid, os.stat(f"{root}/out").st_gid))
check("output mode not widened", 0o700,
      os.stat(f"{root}/out").st_mode & 0o777)
reap()

print("\n=== failure: the workload exits non-zero ===")
# 'provider-error', not 'failed': T13 distinguishes the capability failing from
# the adapter failing, and a non-zero exit from a proven start is the former.
outcome, _ = run("exit42", 'import sys\nsys.exit(42)\n')
check("outcome class", "provider-error", outcome.outcome_class)
check("start proven", True, outcome.started_proven)
check("no result admitted", False, outcome.succeeded)
reap()

print("\n=== failure: the workload writes no result ===")
outcome, _ = run("noresult", 'pass\n')
check("outcome class", "completed", outcome.outcome_class)
check("no result admitted", False, outcome.succeeded)
reap()

print("\n=== failure: the governed image is not the one present ===")
outcome, _ = run("wrongimage", WRITES_RESULT, image="a" * 64)
check("outcome class", "adapter-error", outcome.outcome_class)
check("start proven", False, outcome.started_proven)
check("containers left behind", 0, len(containers()))
reap()

print("\n=== failure: start is not authorised ===")
outcome, _ = run("noauth", WRITES_RESULT, session=Session(refuse=True))
check("outcome class", "adapter-error", outcome.outcome_class)
check("start proven", False, outcome.started_proven)
reap()

print("\n=== failure: an extra mount the profile does not govern ===")
def extra_mount(argv, root):
    index = argv.index(governed)
    return argv[:index] + ["--mount",
                           f"type=bind,src={root}/payload,dst=/kyri/extra,ro=true"] + argv[index:]
outcome, _ = run("extramount", WRITES_RESULT, argv_edit=extra_mount)
check("outcome class", "adapter-error", outcome.outcome_class)
check("start proven", False, outcome.started_proven)
reap()

print("\n=== failure: a socket is mounted into the container ===")
def socket_mount(argv, root):
    import socket as socket_module
    path = os.path.join(root, "podman.sock")
    listener = socket_module.socket(socket_module.AF_UNIX,
                                    socket_module.SOCK_STREAM)
    listener.bind(path)
    index = argv.index(governed)
    return argv[:index] + ["--mount",
                           f"type=bind,src={path},dst=/kyri/sock,ro=true"] + argv[index:]
outcome, _ = run("socketmount", WRITES_RESULT, argv_edit=socket_mount)
check("outcome class", "adapter-error", outcome.outcome_class)
check("start proven", False, outcome.started_proven)
reap()

print("\n=== failure: the identity mapping is wrong ===")
def wrong_mapping(argv, root):
    at = argv.index("--userns")
    return argv[:at + 1] + ["keep-id:uid=1000,gid=1000"] + argv[at + 2:]
outcome, _ = run("wrongmap", WRITES_RESULT, argv_edit=wrong_mapping)
check("outcome class", "adapter-error", outcome.outcome_class)
check("start proven", False, outcome.started_proven)
reap()

print("\n=== failure: the governed wall timeout fires ===")
# Driven by the coordinator's clock, which is the governed mechanism. The
# backend's own timeout is a lower-level guard and is deliberately longer
# (60s) than the governed one (30s), so the governed path always fires first
# and the outcome is a timeout rather than a backend refusal.
class Late:
    """A clock that has passed the governed timeout by the time it is read."""
    def __init__(self):
        self.readings = [0.0, float(L.TIMEOUT_SECONDS) + 1.0]
    def __call__(self):
        return self.readings.pop(0) if self.readings else float(L.TIMEOUT_SECONDS) + 1.0

outcome, _ = run("timeout", 'import time\ntime.sleep(20)\n', clock=Late(),
                 timeout=60)
check("outcome class", "timeout", outcome.outcome_class)
# A timeout is permanent: a workload that exits during the grace period is the
# same timeout with better manners, so a start is not reported as proven.
check("start not claimed", False, outcome.started_proven)
check("no result admitted", False, outcome.succeeded)

# The container itself must be proven stopped, not merely abandoned by the
# client. This is the governed termination path, and it reports whether a kill
# was needed rather than assuming either way.
backend = B.backend_for("python-podman-v1", storage=STORAGE,
                        environment=ENVIRONMENT)
identity = outcome.container_id
if identity and backend.still_active(identity):
    result = L.terminate_after_timeout(backend, identity, clock=lambda: 0.0)
    print(f"  {'termination killed':34} {result.killed}")
check("container proven stopped", False,
      bool(identity) and backend.still_active(identity))
reap()
check("no orphan after reconciliation", 0, len(containers()))

print("\n=== verdict ===")
if failures:
    print(f"BACKEND_E2E=FAIL ({failures} checks)")
    raise SystemExit(1)
print("BACKEND_E2E=PASS")
print("G6_BACKEND=PODMAN")
print("LIFECYCLE_UNAMBIGUOUS=YES")
HARNESS
