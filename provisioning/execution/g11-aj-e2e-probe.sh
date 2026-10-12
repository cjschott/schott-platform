#!/usr/bin/env bash
set -Eeuo pipefail

# The isolated end-to-end: the real governed argv, the real governed image, and
# the whole output round trip.
#
# ISOLATED. The image comes from the exported OCI archive and is loaded into a
# disposable root/runroot. No production Podman storage is opened, no Fabric or
# Trust record is read or written, and no production invocation exists.
#
# THE ARGV IS NOT TYPED HERE. It is produced by `worker.create_argv` and
# executed as produced, with only `--root`/`--runroot` spliced in after the
# binary so the isolated store is used instead of the worker's own. Typing the
# flags out would test this script's idea of the contract rather than the
# contract, which is how G11-AI.2 came to hold a `--user` that disagreed with
# the admitted image for the whole of Track B.
#
# WHAT IT PROVES, and each is a thing that was untrue or unknown before:
#
#   - the container runs as the governed identity 65532:65532;
#   - the uid/gid map binds that identity to the invoking worker, which is what
#     `Config.User` cannot show because it merely echoes the request;
#   - a worker-owned 0700 output directory is writable from inside, with no
#     chown, no U=true, and no widened mode;
#   - the host directory's ownership and mode are unchanged afterwards;
#   - the result is owned by the worker and can be read and hashed by it;
#   - the effective environment is exactly the nine declared variables. A tenth
#     fails: an image rebuild or a Podman upgrade that adds one must be caught
#     rather than absorbed.
#
# Usage:
#   bash provisioning/execution/g11-aj-e2e-probe.sh ARCHIVE [WORKDIR]

GOVERNED_IMAGE="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190"
REPOSITORY="${REPOSITORY:-/opt/schott-platform}"

die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s ===\n' "$*"; }

ARCHIVE="${1:-}"
# Podman caps runroot at 50 characters, so these are short rather than
# descriptive.
WORK="${2:-/tmp/kaj-e2e}"

[ -n "$ARCHIVE" ] || die "usage: $0 ARCHIVE [WORKDIR]"
[ -f "$ARCHIVE" ] || die "the archive ${ARCHIVE} is not a file"
[ "${#WORK}" -le 40 ] || die "WORKDIR must be short: podman caps runroot at 50 characters"
case "$WORK" in
    /data/kyri/capability*) die "the probe must not run against production storage" ;;
esac

FAILURES=0
check() {
    local field="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        printf '  %-26s PASS  %s\n' "$field" "$actual"
    else
        printf '  %-26s FAIL  expected %s, got %s\n' "$field" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

podman unshare rm -rf "$WORK" 2>/dev/null || true
mkdir -p "${WORK}/r" "${WORK}/rr" "${WORK}/pkg" "${WORK}/out"
PODMAN=(podman --root "${WORK}/r" --runroot "${WORK}/rr")

# The fixture capability. Owned by this harness: the probe reports facts and
# never takes a command from the package or the operator.
cat >"${WORK}/pkg/main.py" <<'CAPABILITY'
import json, os, sys
stat = os.stat("/kyri/output")
record = {
    "uid": os.getuid(), "gid": os.getgid(),
    "cwd": os.getcwd(), "exe": sys.executable,
    "version": sys.version.split()[0], "argv": sys.argv,
    "out_uid": stat.st_uid, "out_gid": stat.st_gid,
    "out_mode": oct(stat.st_mode & 0o777),
    "package_writable": os.access("/kyri/package", os.W_OK),
    "root_writable": os.access("/", os.W_OK),
    "tmp_writable": os.access("/tmp", os.W_OK),
    "env": dict(sorted(os.environ.items())),
}
with open("/kyri/output/result.json", "w") as handle:
    json.dump(record, handle, indent=1, sort_keys=True)
CAPABILITY
printf '{"schema_version":1}\n' >"${WORK}/payload"

# The governed output leaf as the snapshot materialises it: worker-owned, 0700,
# not widened for the container's benefit.
chmod 700 "${WORK}/out"

note "archive and isolated import"
sha256sum "$ARCHIVE"
"${PODMAN[@]}" load -i "$ARCHIVE" 2>&1 | tail -1
imported="$("${PODMAN[@]}" images --all --no-trunc --format '{{.ID}}' | sed 's/^sha256://')"
check "isolated image id" "$GOVERNED_IMAGE" "$imported"

note "the governed argv, as create_argv produces it"
python3 - "$WORK" >"${WORK}/argv.json" <<'BUILD'
import json, sys
sys.path.insert(0, sys.argv[2] if len(sys.argv) > 2 else ".")
from tools.capability.execution import profile as P, snapshot as S, worker as W
work = sys.argv[1]
admission = P.Admission(
    cimp="CIMP-000001",
    oci_image_id="5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190",
    adapter_identity="python-podman-v1", payload_schema_version=1,
    execution_profile_schema_version=P.PROFILE_SCHEMA_VERSION,
    argv_contract_identity="fixed-python-entrypoint-v1",
    provisioning_evidence_digest="b" * 64)
profile = P.build_profile(P.ProfileBinding(
    cinv="CINV-000042", admission=admission, payload_digest="c" * 64,
    package_digest="d" * 64, package_entrypoint="main.py"))
binding = S.SnapshotBinding(
    S._MATERIALISED, cinv="CINV-000042", profile=profile,
    payload=f"{work}/payload", package=f"{work}/pkg", output=f"{work}/out",
    entrypoint="main.py", payload_digest="c" * 64, package_digest="d" * 64)
json.dump(list(W.create_argv(binding)), sys.stdout)
BUILD
python3 -c "
import json,sys
print(' '.join(json.load(open(sys.argv[1]))))" "${WORK}/argv.json" | fold -w 100 -s | sed 's/^/  /'

note "host before"
before="$(stat -c '%u:%g:%a' "${WORK}/out")"
printf '  out dir: %s\n' "$before"

note "create"
container="$(python3 -c "
import json, subprocess, sys
argv = json.load(open(sys.argv[1]))
argv[1:1] = ['--root', sys.argv[2], '--runroot', sys.argv[3]]
print(subprocess.run(argv, capture_output=True, text=True,
                     check=True).stdout.strip())
" "${WORK}/argv.json" "${WORK}/r" "${WORK}/rr")"
printf '  container: %s\n' "$container"
[ "${#container}" -eq 64 ] || die "the container identity is not 64 characters"

note "what the runtime established"
"${PODMAN[@]}" inspect "$container" >"${WORK}/inspect.json"
observed="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))[0]
m = (d['HostConfig'].get('IDMappings') or {})
print(d['Config']['User'])
print(d['Image'])
print(','.join(m.get('UidMap') or []))
print(','.join(m.get('GidMap') or []))
" "${WORK}/inspect.json")"
check "Config.User" "65532:65532" "$(printf '%s' "$observed" | sed -n 1p)"
check "image" "$GOVERNED_IMAGE" "$(printf '%s' "$observed" | sed -n 2p)"
# The entry that proves the identity is the worker rather than a subordinate id
# that shares its number. Config.User cannot distinguish those.
case "$(printf '%s' "$observed" | sed -n 3p)" in
    *65532:0:1*) printf '  %-26s PASS  contains 65532:0:1\n' "uid map" ;;
    *) printf '  %-26s FAIL  %s\n' "uid map" "$(printf '%s' "$observed" | sed -n 3p)"
       FAILURES=$((FAILURES + 1)) ;;
esac
case "$(printf '%s' "$observed" | sed -n 4p)" in
    *65532:0:1*) printf '  %-26s PASS  contains 65532:0:1\n' "gid map" ;;
    *) printf '  %-26s FAIL  %s\n' "gid map" "$(printf '%s' "$observed" | sed -n 4p)"
       FAILURES=$((FAILURES + 1)) ;;
esac

note "start"
"${PODMAN[@]}" start -a "$container" 2>&1 | sed 's/^/  /'
state="$("${PODMAN[@]}" inspect --format '{{.State.Status}}:{{.State.ExitCode}}' "$container")"
check "terminal state" "exited:0" "$state"

note "host after"
after="$(stat -c '%u:%g:%a' "${WORK}/out")"
check "output dir unchanged" "$before" "$after"
[ -f "${WORK}/out/result.json" ] || die "the workload produced no governed output"
printf '  result: %s\n' "$(stat -c 'uid=%u gid=%g mode=%a size=%s' "${WORK}/out/result.json")"
check "result owned by worker" "$(id -u):$(id -g)" \
    "$(stat -c '%u:%g' "${WORK}/out/result.json")"
printf '  worker sha256: %s\n' \
    "$(sha256sum <"${WORK}/out/result.json" | cut -d' ' -f1)"

note "workload facts"
if ! python3 - "${WORK}/out/result.json" "$REPOSITORY" <<'VERIFY'
import json, sys
sys.path.insert(0, sys.argv[2])
from tools.capability.execution import worker as W
from tools.capability.execution import profile as P

record = json.load(open(sys.argv[1]))
failures = 0

def check(field, expected, actual):
    global failures
    ok = actual == expected
    print(f"  {field:26} {'PASS' if ok else 'FAIL'}  {actual!r}"
          + ("" if ok else f"  expected {expected!r}"))
    if not ok:
        failures += 1

check("workload uid", P.EXECUTION_UID, record["uid"])
check("workload gid", P.EXECUTION_GID, record["gid"])
check("interpreter", W.CONTAINER_INTERPRETER, record["exe"])
check("argv", ["/kyri/package/main.py"], record["argv"])
check("working directory", "/", record["cwd"])
check("output visible as governed", P.EXECUTION_UID, record["out_uid"])
check("output mode not widened", "0o700", record["out_mode"])
check("package read-only", False, record["package_writable"])
check("rootfs read-only", False, record["root_writable"])
check("governed tmpfs writable", True, record["tmp_writable"])

# The closed environment. Declared and observed must agree exactly: a tenth
# variable is a failure, not a curiosity.
declared = {name: value for name, value, _, _ in W.CONTAINER_EFFECTIVE_ENVIRONMENT}
observed = record["env"]
check("environment size", len(declared), len(observed))
extra = sorted(set(observed) - set(declared))
absent = sorted(set(declared) - set(observed))
check("undeclared variables", [], extra)
check("declared but absent", [], absent)
for name in sorted(set(declared) & set(observed)):
    if declared[name] != observed[name]:
        print(f"  {name:26} FAIL  {observed[name]!r} != {declared[name]!r}")
        failures += 1

raise SystemExit(1 if failures else 0)
VERIFY
then
    FAILURES=$((FAILURES + 1))
fi

note "lifecycle cleanup"
"${PODMAN[@]}" rm -f "$container" >/dev/null
remaining="$("${PODMAN[@]}" ps --all --no-trunc --format '{{.ID}}' | wc -l)"
check "containers remaining" "0" "$remaining"

note "verdict"
if [ "$FAILURES" -ne 0 ]; then
    die "${FAILURES} isolated end-to-end checks failed"
fi
printf 'ISOLATED_E2E=PASS\n'
printf 'CONTAINER_IDENTITY=65532:65532\n'
printf 'HOST_OUTPUT_OWNER_PRESERVED=YES\n'
printf 'CONTAINER_OUTPUT_WRITABLE=YES\n'
printf 'WORKER_OUTPUT_COLLECTABLE=YES\n'
printf 'OUTPUT_CHOWN_REQUIRED=NO\n'
printf 'CLOSED_ENVIRONMENT=PASS\n'
