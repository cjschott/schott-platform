#!/usr/bin/env bash
set -Eeuo pipefail

# The read-only preflight for governed Fabric writes.
#
# WHY THIS EXISTS. First governance is a permanent mutation, and a failure
# between allocation and publication burns an identifier -- an accepted,
# deliberate gap, but not one to discover by accident on the first crossing.
# There was no way to rehearse: every write subcommand went straight to a
# store constructor that provisions the store, so merely asking "would this
# work" created the store, the sequence, and the record.
#
# WHAT A PREFLIGHT MUST NOT DO is the whole content of these cases. The
# production store is opened read-only; the record is constructed against a
# throwaway store that is discarded; the identifier is predicted through the
# allocator's own rule without being taken.
#
# FIXTURE ONLY. Every case works in a temporary root. Nothing here touches
# /var/lib/kyri, and the suite proves it did not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPOSITORY}"

PRODUCTION_FABRIC=/var/lib/kyri/fabric
PRODUCTION_BEFORE="$([ -e "${PRODUCTION_FABRIC}" ] && echo present || echo absent)"

python3 - <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, ".")

from tools.fabric.store import FabricStore

failures = 0
def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        failures += 1
        print(f"FAIL: {description}", file=sys.stderr)

BODY = {
    "request_id": "preflight-1", "actor": "operator",
    "approving_authority": "operator", "recorded_at": "2026-08-20T09:00:00-05:00",
    "name": "probe capability", "description": "A probe.",
    "effect_class": "read-only", "contract_ids": [],
    "provenance": {"class": "declared"},
}

def world(body=None):
    tmp = Path(tempfile.mkdtemp())
    approved = tmp / "approved"; approved.mkdir()
    (approved / "body.json").write_text(json.dumps(BODY if body is None else body))
    return tmp, approved, tmp / "fabric"

def run(store_root, approved, *extra, name="body.json", uid=None, gid=None):
    argv = [sys.executable, "-m", "tools.fabric.cli", "declare-capability",
            "--store-root", str(store_root),
            "--expected-uid", str(os.getuid() if uid is None else uid),
            "--expected-gid", str(os.getgid() if gid is None else gid),
            "--input-file", name, "--approved-directory", str(approved), *extra]
    done = subprocess.run(argv, capture_output=True, text=True, cwd=".")
    return done.returncode, done.stdout, done.stderr

def state(root: Path):
    """Every path under root, with mode and content digest."""
    if not root.exists():
        return None
    out = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        digest = (hashlib.sha256(path.read_bytes()).hexdigest()
                  if path.is_file() and not path.is_symlink() else "")
        out[str(path.relative_to(root))] = (info.st_mode, info.st_uid, info.st_gid, digest)
    return out

# =========================================================================
# 1. absent store: preflight leaves it absent
# =========================================================================
tmp, approved, store_root = world()
code, out, err = run(store_root, approved, "--preflight")
report = json.loads(out) if out.strip() else {}
check(code == 0, f"preflight against an absent store succeeds ({code} {err[:80]})")
check(report.get("outcome") == "preflight", "the report names itself a preflight")
check(report.get("would_accept") is True, "it reports the write would be accepted")
check(report.get("mutated") is False, "it reports mutating nothing")
check(not store_root.exists(), "an absent store is still absent afterwards")
check(report.get("store_exists") is False, "the report says the store does not exist")
check(report.get("predicted_record_id") == "CAPDEF-0001",
      f"the predicted first identifier is CAPDEF-0001 ({report.get('predicted_record_id')})")
check(report.get("record_kind") == "capability-definition", "the record kind is reported")
check(report.get("destination_exists") is False, "the destination is reported absent")
for artefact in ("sequences", "capability-definitions",
                 "sequences/capability-definition.seq",
                 "sequences/request_identity.lock"):
    check(not (store_root / artefact).exists(), f"no {artefact} was created")
shutil.rmtree(tmp)

# Repeated preflight is still inert.
tmp, approved, store_root = world()
for _ in range(3):
    run(store_root, approved, "--preflight")
check(not store_root.exists(), "repeated preflight still creates nothing")
shutil.rmtree(tmp)

# =========================================================================
# 2. existing store: byte-identical afterwards
# =========================================================================
tmp, approved, store_root = world()
store = FabricStore(store_root, expected_uid=os.getuid(), expected_gid=os.getgid())
first = store.allocate_id("capability-definition")           # spend one
seq_path = store_root / "sequences" / "capability-definition.seq"
before = state(store_root)
before_seq = seq_path.read_text()
code, out, err = run(store_root, approved, "--preflight")
report = json.loads(out) if out.strip() else {}
check(code == 0, f"preflight against a populated store succeeds ({code} {err[:80]})")
check(state(store_root) == before, "the existing store is byte-identical afterwards")
check(seq_path.read_text() == before_seq,
      f"the sequence counter is unchanged ({before_seq.strip()})")
check(report.get("predicted_record_id") == "CAPDEF-0002",
      f"prediction follows the spent identifier ({report.get('predicted_record_id')})")
check(report.get("store_exists") is True, "the report says the store exists")
check(not list(store_root.rglob("*.tmp")), "no temporary artefact was created")
# The request-identity lock is created when the store is CONSTRUCTED, which the
# fixture above did -- so the property worth asserting is that preflight added
# no lock and touched none, which the byte-identical comparison already covers.
locks_before = {p for p in before if p.endswith(".lock")}
locks_after = {p for p in state(store_root) if p.endswith(".lock")}
check(locks_before == locks_after, "preflight created no additional lock file")
shutil.rmtree(tmp)

# Prediction skips an occupied record path exactly as the allocator does.
tmp, approved, store_root = world()
store = FabricStore(store_root, expected_uid=os.getuid(), expected_gid=os.getgid())
store.path_for("capability-definition", "CAPDEF-0001").write_text("occupied\n")
before = state(store_root)
code, out, _ = run(store_root, approved, "--preflight")
report = json.loads(out)
check(report.get("predicted_record_id") == "CAPDEF-0002",
      f"prediction skips an occupied name ({report.get('predicted_record_id')})")
check(state(store_root) == before, "skipping mutates nothing")
# and the allocator agrees with the prediction
check(store.allocate_id("capability-definition") == "CAPDEF-0002",
      "the allocator hands out exactly what preflight predicted")
shutil.rmtree(tmp)

# =========================================================================
# 3. refusals mutate nothing
# =========================================================================
for label, body, extra in (
        ("an invalid effect_class", dict(BODY, effect_class="telepathy"), ()),
        ("a missing required field", {k: v for k, v in BODY.items() if k != "name"}, ()),
        ("a malformed provenance", dict(BODY, provenance="not-a-mapping"), ()),
        ("a naive recorded_at", dict(BODY, recorded_at="2026-08-20T09:00:00"), ()),
):
    tmp, approved, store_root = world(body)
    code, out, err = run(store_root, approved, "--preflight", *extra)
    check(code != 0, f"{label} refuses ({code})")
    check(not store_root.exists(), f"{label} leaves the store absent")
    shutil.rmtree(tmp)

# A body outside the approved directory.
tmp, approved, store_root = world()
outside = tmp / "elsewhere"; outside.mkdir()
(outside / "body.json").write_text(json.dumps(BODY))
code, out, err = run(store_root, approved, "--preflight", name="../elsewhere/body.json")
check(code != 0, "a body resolving outside the approved directory refuses")
check(not store_root.exists(), "the escape attempt created no store")
shutil.rmtree(tmp)

# A store root inside a git repository.
code, out, err = run(Path(".").resolve() / "fabric-should-never-exist", approved,
                     "--preflight")
check(code != 0, "a store root inside a git repository refuses")
check(not (Path(".").resolve() / "fabric-should-never-exist").exists(),
      "the refused git-root store was not created")

# =========================================================================
# 4. the write path is unchanged
# =========================================================================
tmp, approved, store_root = world()
code, out, err = run(store_root, approved)                    # no --preflight
report = json.loads(out) if out.strip() else {}
check(code == 0 and report.get("outcome") == "accepted",
      f"the real write still succeeds ({code})")
check(report.get("record_id") == "CAPDEF-0001",
      f"the real write allocates CAPDEF-0001 ({report.get('record_id')})")
check(store.path_for is not None, "store API intact")
written = store_root / "capability-definitions" / "CAPDEF-0001.yaml"
check(written.exists(), "the record was written")
check((store_root / "sequences" / "capability-definition.seq").read_text().strip() == "1",
      "the sequence advanced to 1")

# Exact replay: same request id, same inputs.
code, out, _ = run(store_root, approved)
report = json.loads(out)
check(report.get("outcome") == "exact-replay", f"replay is reported ({report.get('outcome')})")
check(len(list((store_root / "capability-definitions").glob("*.yaml"))) == 1,
      "replay wrote no second record")

# Conflict: same request id, changed input.
(approved / "body.json").write_text(json.dumps(dict(BODY, name="different")))
code, out, _ = run(store_root, approved)
report = json.loads(out) if out.strip() else {}
check(report.get("outcome") not in ("accepted", "exact-replay"),
      f"a changed input under a reused request id conflicts ({report.get('outcome')})")
shutil.rmtree(tmp)

# Burn semantics: allocation is monotonic and never reuses.
tmp, approved, store_root = world()
store = FabricStore(store_root, expected_uid=os.getuid(), expected_gid=os.getgid())
spent = [store.allocate_id("capability-definition") for _ in range(3)]
check(spent == ["CAPDEF-0001", "CAPDEF-0002", "CAPDEF-0003"], f"allocation is monotonic ({spent})")
check(len(set(spent)) == 3, "no identifier is handed out twice")
check(not list((store_root / "capability-definitions").glob("*.yaml")),
      "allocation alone writes no record: a failed ceremony burns the identifier")
check(store.peek_next_id("capability-definition") == "CAPDEF-0004",
      "prediction continues past burned identifiers rather than reusing them")
shutil.rmtree(tmp)

# =========================================================================
# 5. structural boundaries
# =========================================================================
import inspect
from tools.fabric import cli as C
src = inspect.getsource(C.command_preflight)
check("open_for_read" in src or "for_read=True" in src,
      "preflight opens the production store read-only")
check("peek_next_id" in src, "preflight predicts through the shared primitive")
check("allocate_id" not in src, "preflight never allocates")
for token in ("sudo", "podman", "docker", "kyri-exec", "/mnt/kyri-root",
              "sudoers", "chmod", "chown"):
    check(token not in src, f"preflight never mentions {token}")

# The primitive lives on FabricStore, not on the shared base class: that base
# is an installed Generation-10 runtime object and changing it would open a
# generation. These assertions pin both properties.
peek = inspect.getsource(FabricStore.peek_next_id)
check("O_CREAT" not in peek and "flock" not in peek and "fsync" not in peek,
      "peek_next_id neither creates, locks, nor fsyncs")
check("_next_after" in peek and
      "_next_after" in inspect.getsource(FabricStore.allocate_id),
      "prediction and allocation share one identifier rule")
from tools.common import immutable_store as base
check(not hasattr(base.ImmutableStore, "peek_next_id"),
      "the installed shared base class is untouched by this change")
check("_next_after" not in inspect.getsource(base),
      "no installed runtime object carries the new identifier rule")

# Trust-requiring operations refuse rather than risk trust state.
tmp, approved, store_root = world()
done = subprocess.run(
    [sys.executable, "-m", "tools.fabric.cli", "admit-subject",
     "--store-root", str(store_root), "--expected-uid", str(os.getuid()),
     "--expected-gid", str(os.getgid()), "--input-file", "body.json",
     "--approved-directory", str(approved), "--trust-store-root", str(tmp / "trust"),
     "--preflight"], capture_output=True, text=True, cwd=".")
check(done.returncode != 0, "a trust-requiring operation refuses preflight")
check(not (tmp / "trust").exists(), "the refusal created no trust store")
check(not store_root.exists(), "the refusal created no fabric store")
shutil.rmtree(tmp)

print()
if failures:
    print(f"Fabric preflight validation FAILED: {failures}", file=sys.stderr)
    sys.exit(1)
print("Fabric preflight validation passed.")
PY
status=$?

PRODUCTION_AFTER="$([ -e "${PRODUCTION_FABRIC}" ] && echo present || echo absent)"
if [[ "${PRODUCTION_BEFORE}" != "${PRODUCTION_AFTER}" ]]; then
  printf 'FAIL: the suite changed %s (%s -> %s)\n' \
    "${PRODUCTION_FABRIC}" "${PRODUCTION_BEFORE}" "${PRODUCTION_AFTER}" >&2
  exit 1
fi
printf 'PASS: the production fabric store is still %s\n' "${PRODUCTION_AFTER}"
exit "${status}"
