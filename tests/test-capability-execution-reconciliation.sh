#!/usr/bin/env bash
set -Eeuo pipefail

# Governed reconciliation of one execution container, and the orphan it exists
# to recover.
#
# HOST-ONLY AND ISOLATED. Real containers are created from the exported OCI
# archive into a disposable Podman store. No production storage is opened, no
# production helper is invoked, and no sudo is used: the reconciler is driven
# directly here, which models the operation running as `kyri-capability` after
# the privilege drop the future helper performs.
#
# WHY THIS SUITE EXISTS
# =====================
# G11-AP proved by experiment that `podman start --attach` attaches a client
# and killing that client does not stop the container. So a worker taking
# SIGKILL mid-execution leaves its container RUNNING, a `finally` clause cannot
# help, and the coordinator has no Podman authority and must not gain any.
# Without a governed reconciliation operation, "worker death leaves no orphan"
# is a promise the platform cannot keep.
#
# PART 1 REPRODUCES THE ORPHAN. It is the defect proof and it runs first, so
# the recovery in part 2 is demonstrably recovering something real rather than
# asserting against a container that was never a problem.
#
# NAME IS NOT IDENTITY. Reconciliation stops and removes what it finds, so it
# requires the governed label the runtime wrote as well as the derived name.
# The negative cases are the ones that matter: a container holding the right
# name with the wrong label must survive untouched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=tests/lib/host-only.sh
. "${SCRIPT_DIR}/lib/host-only.sh"

ARCHIVE="/tmp/kyri-g11-ai-oci-a999e0e2c2bd/cimp-000001-5cee2b53.oci-archive.tar"
host_only_requires "${ARCHIVE}" /usr/bin/podman

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

WORK="/tmp/kaq-rec"
podman unshare rm -rf "${WORK}" 2>/dev/null || true
mkdir -p "${WORK}/r" "${WORK}/rr" "${WORK}/pkg" "${WORK}/out"
cleanup() {
  podman --root "${WORK}/r" --runroot "${WORK}/rr" rm --all --force \
    >/dev/null 2>&1 || true
  podman unshare rm -rf "${WORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '=== isolated import ===\n'
podman --root "${WORK}/r" --runroot "${WORK}/rr" load -i "${ARCHIVE}" 2>&1 | tail -1

if ! (cd "${ROOT}" && WORK="${WORK}" python3 - <<'HARNESS'
import importlib.util, os, signal, subprocess, sys, time

sys.path.insert(0, ".")
WORK = os.environ["WORK"]
GOVERNED = "5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
STORAGE = ["--root", f"{WORK}/r", "--runroot", f"{WORK}/rr"]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


B = load("kyri_exec_podman", "provisioning/execution/kyri-exec-podman.py")
R = load("kyri_exec_reconcile", "provisioning/execution/kyri-exec-reconcile.py")
from tools.capability.execution import worker as W

failures = 0


def check(label, expected, actual):
    global failures
    ok = actual == expected
    print(f"  {label:36} {'PASS' if ok else 'FAIL'}  {actual!r}"
          + ("" if ok else f"  expected {expected!r}"))
    if not ok:
        failures += 1


def podman(*args, check_rc=True):
    return subprocess.run(["podman", *STORAGE, *args], capture_output=True,
                          text=True, check=check_rc)


def backend():
    return B.backend_for(
        "python-podman-v1", storage=tuple(STORAGE),
        environment=(("HOME", os.path.expanduser("~")), ("PATH", "/usr/bin:/bin"),
                     ("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")))


def create(cinv, body, *, label=None, name=None):
    """One governed container, created the way the runtime creates them."""
    os.makedirs(f"{WORK}/pkg", exist_ok=True)
    with open(f"{WORK}/pkg/main.py", "w") as handle:
        handle.write(body)
    labelled = cinv if label is None else label
    podman("create", "--name", name or W.container_name(cinv),
           "--label", f"{W.INVOCATION_LABEL}={labelled}",
           "--network", "none", "--pull=never", "--read-only",
           "--read-only-tmpfs=false", "--cap-drop", "ALL",
           "--security-opt", "no-new-privileges", "--pids-limit", "64",
           "--user", "65532:65532",
           "--userns", "keep-id:uid=65532,gid=65532",
           "--tmpfs", "/tmp:size=16m,mode=1777",
           "--mount", f"type=bind,src={WORK}/pkg,dst=/kyri/package,ro=true",
           GOVERNED, "/usr/bin/python", "/kyri/package/main.py")


def state(name):
    done = podman("inspect", "--type", "container", "--format",
                  "{{.State.Status}}", name, check_rc=False)
    return done.stdout.strip() if done.returncode == 0 else "absent"


def reap():
    podman("rm", "--all", "--force", check_rc=False)


SLEEPER = "import time\ntime.sleep(120)\n"

# --- part 1: the orphan, reproduced -------------------------------------------

print("\n=== PART 1 - the defect: worker death leaves a running container ===")
CINV = "CINV-000042"
create(CINV, SLEEPER)
name = W.container_name(CINV)
check("deterministic name", "kyri-CINV-000042", name)

# The worker's own call: start --attach. Killed with SIGKILL, which is the one
# signal a worker cannot trap and therefore the case cleanup cannot cover.
client = subprocess.Popen(["podman", *STORAGE, "start", "--attach", name],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 20
while time.monotonic() < deadline and state(name) != "running":
    time.sleep(0.2)
check("container running before the kill", "running", state(name))

os.kill(client.pid, signal.SIGKILL)
client.wait()
time.sleep(1.5)
check("worker client is dead", True, client.poll() is not None)
check("container SURVIVES worker death", "running", state(name))
print("     ^ this is the G11-AP defect, reproduced")

# --- part 2: reconciliation recovers it ---------------------------------------

print("\n=== PART 2 - governed reconciliation ===")
report = R.reconcile(CINV, backend=backend())
check("outcome", R.OUTCOME_STOPPED_AND_REMOVED, report["outcome"])
check("prior state", "running", report["prior_state"])
check("identity verified", True, report["container_identity_verified"])
check("final absent", True, report["final_absent"])
check("container really is absent", "absent", state(name))
check("no reason on success", None, report["reason"])

# --- idempotence ---------------------------------------------------------------

print("\n=== PART 3 - idempotence ===")
again = R.reconcile(CINV, backend=backend())
check("second run is already-absent", R.OUTCOME_ABSENT, again["outcome"])
check("still absent", True, again["final_absent"])

print("\n  -- an exited container --")
create(CINV, "pass\n")
podman("start", name, check_rc=False)
deadline = time.monotonic() + 20
while time.monotonic() < deadline and state(name) == "running":
    time.sleep(0.2)
exited = R.reconcile(CINV, backend=backend())
check("outcome", R.OUTCOME_REMOVED_EXITED, exited["outcome"])
check("container absent", "absent", state(name))

# --- the negative matrix: identity is not the name ------------------------------

print("\n=== PART 4 - name is not identity ===")

print("\n  -- right name, wrong label --")
create(CINV, SLEEPER, label="CINV-999999")
refused = R.reconcile(CINV, backend=backend())
check("outcome", R.OUTCOME_REFUSED, refused["outcome"])
check("container UNTOUCHED", "created", state(name))
check("identity not verified", False, refused["container_identity_verified"])
check("reason names the mismatch", True,
      "labelled for" in (refused["reason"] or ""))
reap()

print("\n  -- right name, no label at all --")
podman("create", "--name", name, "--network", "none", "--pull=never",
       GOVERNED, "/usr/bin/python", "-c", "pass")
unlabelled = R.reconcile(CINV, backend=backend())
check("outcome", R.OUTCOME_REFUSED, unlabelled["outcome"])
check("container UNTOUCHED", "created", state(name))
reap()

print("\n  -- a container for a different invocation is not touched --")
create("CINV-000043", SLEEPER)
other = W.container_name("CINV-000043")
elsewhere = R.reconcile(CINV, backend=backend())
check("outcome for the absent CINV", R.OUTCOME_ABSENT, elsewhere["outcome"])
check("the other container survives", "created", state(other))
reap()

print("\n=== PART 5 - the input is one CINV and nothing else ===")
for bad in ("cinv-000042", "CINV-00042", "CINV-0000042", "kyri-CINV-000042",
            "CINV-000042 ", "../CINV-000042", "CINV-000042; rm -rf /",
            "", None, 42, ["CINV-000042"]):
    try:
        R.validate_cinv(bad)
    except R.ReconciliationRefused:
        continue
    print(f"  FAIL  accepted {bad!r}")
    failures += 1
print("  every malformed identity refused")

# A container name a caller composed cannot reach the backend either.
for bad in ("kyri-CINV-00042", "podman", "kyri-", "kyri-CINV-abcdef", "../x"):
    try:
        B._require_container_name(bad)
    except B.PodmanBackendRefused:
        continue
    print(f"  FAIL  backend accepted name {bad!r}")
    failures += 1
print("  every ungoverned container name refused")

print("\n=== verdict ===")
if failures:
    print(f"RECONCILIATION=FAIL ({failures})")
    raise SystemExit(1)
print("WORKER_SIGKILL_ORPHAN_RECOVERED=PASS")
print("RECONCILIATION_IDEMPOTENT=YES")
print("CONTAINER_LABEL_BOUND=YES")
HARNESS
); then
  fail "the reconciliation harness failed"
else
  pass "orphan reproduction, reconciliation, idempotence, and identity refusals"
fi

printf '\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  printf 'Capability execution reconciliation validation passed.\n'
else
  printf 'Capability execution reconciliation validation FAILED: %s\n' "${FAILURES}" >&2
  exit 1
fi
