#!/usr/bin/env bash
set -Eeuo pipefail

# ENG-0005 G11-AB. `invoke --preflight`: rehearse one invocation, mutate nothing.
#
# G11-AA established the cost of not having this. The invoke path writes before
# it can report: constructing the store creates directories, staging publishes a
# tree, and `record_invocation` allocates and writes a `CINV` -- and it does all
# of that *before* the adapter is reached. So the only way an operator could
# discover whether an invocation would be accepted was to spend CINV-000001
# finding out, and a refused first attempt consumed CINV-000001 and CRES-000001
# permanently. That was proved, not argued: a staging-root permission mistake in
# a fixture rehearsal burned both identities.
#
# Every other governed write in this platform already has a rehearsal.
# `declare-package --preflight` opens the store through `open_for_read`, runs the
# real operation under `admission.rehearsing()`, predicts the identifier with
# `peek_next_id`, and stops at the first irreversible act. This suite pins the
# same contract onto the capability plane rather than inventing a second one.
#
# The rehearsal must answer the same question the write answers. A preflight
# with its own copy of the rules would agree until it did not, so the real
# `prepare_invocation` runs here -- same evidence verification, same current
# eligibility, same scope gate, same package resolution -- and is stopped at the
# two points where it stops being reversible.
#
# FIXTURE ONLY. Nothing here reads or writes a production store, stages into a
# production root, allocates a production identity, or reaches a helper.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"

PRODUCTION_PATHS=(/var/lib/kyri /data/kyri/capability-runtime /usr/lib/kyri/python)
BEFORE="$(mktemp)"; AFTER="$(mktemp)"
trap 'rm -f "${BEFORE}" "${AFTER}"' EXIT
snapshot_production() {
  local path
  for path in "${PRODUCTION_PATHS[@]}"; do
    [[ -e "${path}" ]] || continue
    # `|| true`: these roots carry directories this account may not descend
    # into, and a snapshot that dies on EACCES proves nothing about the parts it
    # could read.
    ( cd "${path}" && find . -mindepth 1 -printf '%y %m %s %p\n' 2>/dev/null | sort ) || true
  done
}
snapshot_production > "${BEFORE}"

python3 - <<'PYTHON'
import json, os, subprocess, sys
import yaml
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, ".")
sys.dont_write_bytecode = True

FAILURES = []


def check(condition, label):
    print(("PASS: " if condition else "FAIL: ") + label)
    if not condition:
        FAILURES.append(label)


CT = timezone(timedelta(hours=-5))
UID, GID = os.getuid(), os.getgid()


def manifest(root: Path):
    """Every durable thing under a tree: name, type, mode, size and bytes."""
    state = {}
    for path in sorted(Path(root).rglob("*")):
        relative = str(path.relative_to(root))
        entry = path.lstat()
        if path.is_dir() and not path.is_symlink():
            state[relative] = ("dir", entry.st_mode)
        else:
            state[relative] = ("file", entry.st_mode, entry.st_size,
                               path.read_bytes())
    return state


def governed_instant(fabric: Path, instance_id: str) -> str:
    """An instant inside the fixture's OWN admission and advertisement windows.

    The suite used to evaluate at `datetime.now()`. That made every semantic
    assertion depend on a lease the reviewer deliberately allows to expire: on
    2026-08-30T16:19:19-05:00 the production window closed and six assertions
    began failing for a reason that had nothing to do with what they test.

    The instant is DERIVED from the records the fixture actually holds, not
    pinned to a literal. Both windows are half-open, so the intersection is
    `[max(admitted_at, observed_at), min(admitted_until, valid_until))` and its
    midpoint is strictly inside. That is stable under renewal -- a future
    CADV-000004/CINST-000003 with different windows yields a different instant
    and the same verdicts -- and it never consults the clock.

    G11-AG's bound guarantees the intersection is exactly the admission window
    for any binding written from now on, but the midpoint is computed rather
    than assumed so this holds for the historical shape too.
    """
    instance = yaml.safe_load(
        (fabric / "capability-instances" / f"{instance_id}.yaml")
        .read_text(encoding="utf-8"))
    advertisement = yaml.safe_load(
        (fabric / "capability-advertisements"
         / f"{instance['advertisement_id']}.yaml").read_text(encoding="utf-8"))
    opens = max(datetime.fromisoformat(instance["admitted_at"]),
                datetime.fromisoformat(advertisement["observed_at"]))
    closes = min(datetime.fromisoformat(instance["admitted_until"]),
                 datetime.fromisoformat(advertisement["valid_until"]))
    if not opens < closes:
        raise SystemExit(
            f"the fixture's {instance_id} has no live interval: "
            f"[{opens.isoformat()}, {closes.isoformat()})")
    return (opens + (closes - opens) / 2).isoformat()


def fixture(base: Path):
    """A production-shaped fixture: Fabric, Trust, artifacts, payload, roots."""
    import shutil
    for name in ("fabric", "trust", "artifacts"):
        source = Path("/var/lib/kyri") / name
        if not source.is_dir():
            return None
        shutil.copytree(source, base / name)
    for path in (base / "artifacts",):
        for entry in path.rglob("*"):
            entry.chmod(0o755 if entry.is_dir() else 0o644)
        path.chmod(0o755)
    payload = base / "payload"
    payload.mkdir(mode=0o755)
    (payload / "payload.json").write_text('{"operation":"execute"}')
    (payload / "payload.json").chmod(0o644)
    store = base / "store"; store.mkdir(mode=0o700)
    staging = base / "staging"; staging.mkdir(mode=0o700)
    return {"fabric": base / "fabric", "trust": base / "trust",
            "artifacts": base / "artifacts", "payload": payload,
            "store": store, "staging": staging,
            "instant": governed_instant(base / "fabric", "CINST-000002")}


def run(paths, *extra, operation="execute", instant=None,
        identity="g11ab-preflight-suite"):
    """The released CLI, exactly as an operator would reach it."""
    # Derived from the fixture, never from the clock -- see governed_instant.
    at = instant or paths["instant"]
    argv = [sys.executable, "-m", "tools.capability.cli", "invoke",
            "--store-root", str(paths["store"]),
            "--expected-uid", str(UID), "--expected-gid", str(GID),
            "--fabric-root", str(paths["fabric"]),
            "--fabric-expected-uid", str(UID), "--fabric-expected-gid", str(GID),
            "--approved-artifact-root", str(paths["artifacts"]),
            "--trusted-source-uid", str(UID),
            "--staging-root", str(paths["staging"]),
            "--coordinator-uid", str(UID),
            "--approved-payload-root", str(paths["payload"]),
            "--payload-source-uid", str(UID),
            "--payload-file", "payload.json",
            "--invocation-id", identity,
            "--selection-id", "CSEL-000001",
            "--instance-id", "CINST-000002",
            "--package-id", "CPKG-0001",
            "--operation", operation,
            "--trust-store-root", str(paths["trust"]),
            "--actor", "primary-platform-operator",
            "--request-id", "g11ab-preflight-suite",
            "--requested-at", at, *extra]
    done = subprocess.run(argv, capture_output=True, text=True,
                          env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    try:
        body = json.loads(done.stdout)
    except json.JSONDecodeError:
        body = None
    return done.returncode, body, done.stderr


print("=" * 74)
print("PART 1 — the cost this exists to remove")
print("=" * 74)

with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    if paths is None:
        print("SKIP: no production Fabric to shape a fixture from")
    else:
        # A real invocation that cannot stage still spends both identities.
        paths["staging"].chmod(0o777)
        status, body, _ = run(paths)
        check(body is not None and body.get("status") == "refused",
              f"a real invoke that cannot stage is refused ({body and body.get('reason')})")
        check(body is not None and body.get("invocation_record_id") == "CINV-000001",
              "and it has already spent CINV-000001")
        check(body is not None and body.get("result_record_id") == "CRES-000001",
              "and CRES-000001 with it")

print()
print("=" * 74)
print("PART 2 — the rehearsal predicts, and writes nothing")
print("=" * 74)

with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    if paths is None:
        print("SKIP: no production Fabric to shape a fixture from")
    else:
        base = Path(tmp)
        before = manifest(base)
        status, body, stderr = run(paths, "--preflight")

        check(body is not None,
              f"--preflight is accepted and reports a plan (exit {status}: {stderr[:90]})")
        if body is not None:
            check(body.get("outcome") == "preflight",
                  f"the outcome names itself a rehearsal ({body.get('outcome')})")
            check(body.get("would_accept") is True,
                  f"a currently eligible binding would be accepted "
                  f"({body.get('would_accept')}, {body.get('would_refuse_reason')})")
            check(body.get("predicted_invocation_record_id") == "CINV-000001",
                  f"it predicts CINV-000001 against an absent sequence "
                  f"({body.get('predicted_invocation_record_id')})")
            check(body.get("selection_id") == "CSEL-000001"
                  and body.get("instance_id") == "CINST-000002",
                  "it names the selection and the instance it verified")
            check(body.get("operation") == "execute",
                  f"it names the operation ({body.get('operation')})")
            check(body.get("capability_package_id") == "CPKG-0001",
                  "it names the package")
            check(isinstance(body.get("binding_digest"), str)
                  and body["binding_digest"].startswith("sha256:"),
                  "it reports the binding digest the write would record")
            check(isinstance(body.get("package_tree_sha256"), str)
                  and body["package_tree_sha256"].startswith("sha256:"),
                  "it reports the package tree digest without publishing it")
            check(body.get("current_eligibility") is True,
                  "it reports current eligibility as its own field")
            check(body.get("scope_permits_operation") is True,
                  "it reports the scope gate as its own field")
            check(body.get("adapter_authorised") is False,
                  f"it reports honestly that no adapter is authorised "
                  f"({body.get('adapter_authorised')})")
            check(body.get("execution_backend") is not None,
                  f"it names the backend the implementation declares "
                  f"({body.get('execution_backend')})")
            check(body.get("execution_image_available") is False,
                  f"it reports whether the governed image is present "
                  f"({body.get('execution_image_available')})")
            check(body.get("privileged_helper_required") is True,
                  "it reports that a privileged helper would be required")

        after = manifest(base)
        differing = sorted(set(before) ^ set(after)) + \
            sorted(k for k in set(before) & set(after) if before[k] != after[k])
        check(not differing,
              f"the fixture tree is byte-identical after the rehearsal "
              f"({len(differing)} differing: {differing[:4]})")
        check(not (paths["store"] / "capability-invocations").exists()
              or not any((paths["store"] / "capability-invocations").iterdir()),
              "no invocation record was written")
        check(not (paths["store"] / "sequences" / "capability-invocation.seq").exists(),
              "the invocation sequence was not created or advanced")
        check(not any(paths["staging"].iterdir()),
              "nothing was staged")

print()
print("=" * 74)
print("PART 3 — the rehearsal answers the same question as the write")
print("=" * 74)

with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    if paths is None:
        print("SKIP: no production Fabric to shape a fixture from")
    else:
        # G11-X: a refused operation is refused identically in rehearsal.
        _, denied, _ = run(paths, "--preflight", operation="delete")
        check(denied is not None and denied.get("would_accept") is False,
              "an operation outside the admitted scope would be refused")
        check(denied is not None
              and denied.get("would_refuse_reason") == "operation-not-permitted-by-scope",
              f"and the rehearsal names the scope refusal "
              f"({denied and denied.get('would_refuse_reason')})")
        check(denied is not None and denied.get("scope_permits_operation") is False,
              "and reports the scope gate as failed")

        # G11-Y: an instant past the admission window is refused identically.
        expired = datetime(2027, 1, 1, 12, 0, 0, tzinfo=CT).isoformat()
        _, stale, _ = run(paths, "--preflight", instant=expired)
        check(stale is not None and stale.get("would_accept") is False,
              "an instant past the admission window would be refused")
        check(stale is not None and stale.get("current_eligibility") is False,
              "and the rehearsal reports current eligibility as failed")

        # And none of the refusals wrote either.
        check(not (paths["store"] / "sequences" / "capability-invocation.seq").exists(),
              "a refused rehearsal still allocates nothing")

print()
print("=" * 74)
print("PART 4 — prediction is a prediction, and the write still allocates")
print("=" * 74)

with TemporaryDirectory() as tmp:
    paths = fixture(Path(tmp))
    if paths is None:
        print("SKIP: no production Fabric to shape a fixture from")
    else:
        _, first, _ = run(paths, "--preflight")
        _, second, _ = run(paths, "--preflight")
        check(first is not None and second is not None
              and first.get("predicted_invocation_record_id")
              == second.get("predicted_invocation_record_id") == "CINV-000001",
              "repeated rehearsals predict the same identifier, having spent none")

        status, real, _ = run(paths)
        check(real is not None and real.get("invocation_record_id") == "CINV-000001",
              "the real write then takes the identifier that was predicted")
        check(real is not None and real.get("status") == "prepared",
              f"and reaches the same conclusion the rehearsal reported "
              f"({real and real.get('status')}/{real and real.get('reason')})")

        # A fresh caller identity: the sequence has moved, so the prediction does.
        _, after_write, _ = run(paths, "--preflight", identity="g11ab-second")
        check(after_write is not None
              and after_write.get("predicted_invocation_record_id") == "CINV-000002",
              f"a rehearsal after the write predicts the next identifier "
              f"({after_write and after_write.get('predicted_invocation_record_id')})")

        # The same caller identity is a replay, and the rehearsal says so
        # rather than predicting an identifier the write would never allocate.
        _, replay, _ = run(paths, "--preflight")
        check(replay is not None and replay.get("would_accept") is False,
              "re-rehearsing a consumed identity would not be accepted")
        check(replay is not None and replay.get("would_refuse_reason") == "invocation_identity_consumed",
              f"and is named a replay of a decision already made "
              f"({replay and replay.get('would_refuse_reason')})")
        check(replay is not None
              and replay.get("predicted_invocation_record_id") == "CINV-000001",
              "and points at the record that identity already has")

print()
if FAILURES:
    print(f"{len(FAILURES)} assertion(s) failed.", file=sys.stderr)
    sys.exit(1)
print("All invoke-preflight assertions passed.")
PYTHON
status=$?

snapshot_production > "${AFTER}"
if diff -q "${BEFORE}" "${AFTER}" >/dev/null; then
  printf 'PASS: %s\n' "no production path changed while this suite ran"
else
  printf 'FAIL: %s\n' "a production path changed while this suite ran" >&2
  status=1
fi

exit "${status}"
