#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the Operational Integrity Engine.
#
# The engine reconstructs a disposable digital twin from knowledge and compares
# it against an immutable snapshot. Nothing here recovers anything: a recovery
# plan is prose for a human to read, and this suite asserts that no execution
# path exists.
#
# Every store root is a temporary directory. This suite contacts no host, uses
# no SSH, starts no container, reads no secret, and writes nothing into the
# repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INTEGRITY="tools/integrity"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_contains() {
  if [[ -f "${ROOT}/$1" ]] && grep -Eq "$2" "${ROOT}/$1"; then
    pass "$3"
  else
    fail "$3 (expected /$2/ in $1)"
  fi
}

# assert_absent_in <target> <pattern> <description> [exclude-glob]
assert_absent_in() {
  local target="$1" pattern="$2" description="$3" exclude="${4:-}" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  if [[ -n "${exclude}" ]]; then
    matches="$(grep -rIniE --exclude="${exclude}" -e "${pattern}" "${ROOT}/${target}" || true)"
  else
    matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  fi
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required modules ------------------------------------------------------
for module in __init__ models snapshot_manager twin_builder integrity_analyzer \
              confidence recovery_planner cli; do
  assert_file "${INTEGRITY}/${module}.py"
done

# --- Required governance ---------------------------------------------------
assert_file "docs/decisions/ADR-0007-operational-integrity-engine.md"
assert_file "docs/integrity/overview.md"

for schema in snapshot digital-twin integrity-report recovery-plan; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- Identifier widths -----------------------------------------------------
# Generated records use six digits, matching the v0.7.0 decision.
assert_contains "platform-model/schemas/snapshot.schema.yaml" \
  "SNAP-\[0-9\]\{6\}" "snapshot schema uses six-digit identifiers"
assert_contains "platform-model/schemas/digital-twin.schema.yaml" \
  "TWIN-\[0-9\]\{6\}" "digital twin schema uses six-digit identifiers"
assert_contains "platform-model/schemas/integrity-report.schema.yaml" \
  "INTEG-\[0-9\]\{6\}" "integrity report schema uses six-digit identifiers"
assert_contains "platform-model/schemas/recovery-plan.schema.yaml" \
  "RECOV-\[0-9\]\{6\}" "recovery plan schema uses six-digit identifiers"

# --- Static safety ---------------------------------------------------------
assert_absent_in "${INTEGRITY}" \
  '(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|telnetlib|smtplib)|from[[:space:]]+(socket|requests|urllib|paramiko|http)[[:space:]]+import)' \
  "no integrity code imports a network or SSH module"
assert_absent_in "${INTEGRITY}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\()' \
  "no integrity code executes a subprocess"
assert_absent_in "${INTEGRITY}" '(ssh|scp|sftp|rsync)[[:space:]]' \
  "no integrity code references an SSH transport"
assert_absent_in "${INTEGRITY}" \
  '(docker[[:space:]]+(ps|inspect|exec|run|start|stop|rm|logs)|compose[[:space:]]+(up|down|pull|build))' \
  "no integrity code invokes a Docker runtime verb"
assert_absent_in "${INTEGRITY}" "['\"][^'\"]*ai/\\.env['\"]" \
  "no integrity code references ai/.env"

# Recovery is advisory. No execution path may exist, at any severity.
assert_absent_in "${INTEGRITY}" \
  '(def[[:space:]]+(execute|apply|perform|run)_(recovery|plan|step)|\.execute_recovery\(|auto_recover|def[[:space:]]+remediate)' \
  "no integrity code can execute a recovery plan"
assert_absent_in "${INTEGRITY}" \
  '(def[[:space:]]+(delete|remove|update|overwrite|edit)_(snapshot|record))' \
  "no snapshot delete or update method exists"

# Snapshots and the declared model are read-only to this package.
assert_absent_in "${INTEGRITY}" \
  "(open\\(['\"][^'\"]*platform-model[^'\"]*['\"],[[:space:]]*['\"][wax]|platform-model[^'\"]*['\"]\\)\\.write_text)" \
  "no integrity code writes into platform-model"

# --- Generated records must never be committed -----------------------------
if git -C "${ROOT}" ls-files 'platform-model/**/SNAP-*' 'platform-model/**/TWIN-*' \
     'platform-model/**/INTEG-*' 'platform-model/**/RECOV-*' | grep -q .; then
  fail "generated integrity records must not be committed under platform-model"
else
  pass "no generated integrity records are committed under platform-model"
fi

# --- CI wiring -------------------------------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-operational-integrity\.sh' \
  "ci runs the operational integrity tests"

# --- Behavioural validation ------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import json
import os
import stat
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0
CANARY = "CANARY-INTEGRITY-MUST-NOT-APPEAR-3c7f"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.collectors.models import CollectorResult, Observation as CObs
    from tools.observation.evidence_store import EvidenceStore
    from tools.observation.orchestrator import Orchestrator
    from tools.integrity.models import (
        DigitalTwin, IntegrityConfidence, IntegrityReport, IntegrityStatus,
        RecoveryPlan, SnapshotRecord,
    )
    from tools.integrity.snapshot_manager import SnapshotStore, StoreError, create_snapshot
    from tools.integrity.twin_builder import build_twin
    from tools.integrity.integrity_analyzer import analyze_integrity
    from tools.integrity.confidence import FACTOR_WEIGHTS, compute_integrity_confidence
    from tools.integrity.recovery_planner import plan_recovery
    ok("integrity modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"integrity import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = "2026-08-02T09:00:00-05:00"
LATER = "2026-08-02T11:00:00-05:00"
TARGET = "REPO-0001"


def collector_result(facts, *, target=TARGET, collector="git-repository",
                     status="success", collected=STAMP):
    return CollectorResult(
        collector_id=collector, target=target, status=status,
        started_at=collected, completed_at=collected,
        observations=[
            CObs(fact=k, value=v, value_type="string", collected_at=collected,
                 source=collector)
            for k, v in sorted(facts.items())
        ],
        errors=[],
    )


def seeded_knowledge(tmp, facts, *, collected=STAMP):
    """Build real knowledge through the v0.7.0 pipeline, then return it."""
    store = EvidenceStore(Path(tmp) / "evidence-store")
    orchestrator = Orchestrator(store)
    outcome = orchestrator.process_collector_result(
        collector_result(facts, collected=collected), evaluated_at=collected)
    return outcome.knowledge_state, store


# --- Snapshots are immutable, deterministic, fingerprinted ----------------
with tempfile.TemporaryDirectory() as tmp:
    knowledge, _ = seeded_knowledge(tmp, {"branch": "main", "tracked_files": "164"})
    snapshots = SnapshotStore(Path(tmp) / "integrity-store")

    first = create_snapshot(knowledge, snapshot_id=snapshots.allocate_id("snapshot"),
                            created_at=STAMP, label="known-good")
    check(first.id == "SNAP-000001", "first snapshot receives SNAP-000001")
    check(len(first.id) == len("SNAP-000001"), "snapshot identifiers use six digits")
    check(first.content_fingerprint.startswith("sha256:"), "snapshots are fingerprinted")
    check(first.schema_version, "snapshots record a schema version")

    snapshots.write_snapshot(first)
    path = Path(tmp) / "integrity-store" / "snapshots" / "SNAP-000001.yaml"
    check(path.is_file(), "snapshot filenames match identifiers")
    mode = stat.S_IMODE(path.stat().st_mode)
    check(mode & 0o077 == 0, "snapshot files carry restrictive permissions")

    try:
        snapshots.write_snapshot(first)
        bad("an existing snapshot cannot be overwritten")
    except StoreError:
        ok("an existing snapshot cannot be overwritten")

    payload = path.read_text()
    check("SNAP-000001" in payload and "branch" in payload,
          "a refused overwrite leaves the original snapshot intact")
    leftovers = [p.name for p in path.parent.iterdir() if not p.name.endswith(".yaml")]
    check(not leftovers, "no partial snapshot writes are left behind")

    # Determinism: the same knowledge and the same identifier reproduce byte
    # for byte. A snapshot that cannot be reproduced cannot be trusted as a
    # reference point.
    again = create_snapshot(knowledge, snapshot_id="SNAP-000001",
                            created_at=STAMP, label="known-good")
    check(json.dumps(again.to_dict(), sort_keys=True) ==
          json.dumps(first.to_dict(), sort_keys=True),
          "snapshot creation is deterministic and reproducible")
    check(again.content_fingerprint == first.content_fingerprint,
          "identical knowledge produces an identical fingerprint")

    # Different knowledge must produce a different fingerprint.
    other_knowledge, _ = seeded_knowledge(tmp + "/x" if False else tmp, {"branch": "main"})
    changed = create_snapshot(other_knowledge, snapshot_id="SNAP-000002",
                              created_at=STAMP, label="other")
    check(changed.content_fingerprint != first.content_fingerprint,
          "different knowledge produces a different fingerprint")

    # Versioned: a second snapshot of the same target supersedes nothing and
    # both remain readable.
    second = create_snapshot(knowledge, snapshot_id=snapshots.allocate_id("snapshot"),
                             created_at=LATER, label="later")
    snapshots.write_snapshot(second)
    listed = [s["id"] for s in snapshots.list_snapshots(TARGET)]
    check(len(listed) >= 2 and "SNAP-000001" in listed,
          "earlier snapshots remain readable after a newer one is written")
    check(snapshots.latest_snapshot(TARGET)["id"] == second.id,
          "the newest snapshot is identifiable without deleting older ones")

# --- Twins are rebuilt from knowledge, disposable, deterministic ----------
with tempfile.TemporaryDirectory() as tmp:
    knowledge, _ = seeded_knowledge(tmp, {"branch": "main", "tracked_files": "164"})

    twin = build_twin(knowledge, twin_id="TWIN-000001", built_at=STAMP)
    check(isinstance(twin, DigitalTwin), "twin builder returns a DigitalTwin")
    check(twin.id.startswith("TWIN-") and len(twin.id) == len("TWIN-000001"),
          "twin identifiers use six digits")
    check(twin.disposable is True, "twins declare themselves disposable")
    check(twin.source_knowledge_target == TARGET, "twins record the knowledge they came from")

    rebuilt = build_twin(knowledge, twin_id="TWIN-000001", built_at=STAMP)
    check(json.dumps(rebuilt.to_dict(), sort_keys=True) ==
          json.dumps(twin.to_dict(), sort_keys=True),
          "twin rebuild is deterministic")

    # Never edited directly: the type must reject mutation.
    try:
        twin.facts["branch"] = "tampered"
        mutated = twin.facts.get("branch") == "tampered"
    except Exception:  # noqa: BLE001 - any refusal is acceptable
        mutated = False
    check(not mutated, "a twin's facts cannot be edited in place")

    try:
        object.__setattr__  # noqa: B018 - existence probe only
        twin.id = "TWIN-999999"
        frozen = False
    except Exception:  # noqa: BLE001
        frozen = True
    check(frozen, "a twin's fields are frozen against direct assignment")

# --- Integrity analysis classifies all five states ------------------------
with tempfile.TemporaryDirectory() as tmp:
    baseline_knowledge, _ = seeded_knowledge(tmp, {"branch": "main", "tracked_files": "164"})
    snapshot = create_snapshot(baseline_knowledge, snapshot_id="SNAP-000010",
                               created_at=STAMP, label="baseline")

    identical = build_twin(baseline_knowledge, twin_id="TWIN-000010", built_at=LATER)
    report = analyze_integrity(snapshot=snapshot, twin=identical, evaluated_at=LATER,
                               report_id="INTEG-000001")
    check(isinstance(report, IntegrityReport), "analyzer returns an IntegrityReport")
    check(report.status == IntegrityStatus.MATCH.value,
          "an unchanged twin reports MATCH")
    check(report.id == "INTEG-000001", "integrity reports carry an identifier")
    check(snapshot.id in report.snapshot and identical.id in report.twin,
          "the report references both the snapshot and the twin it compared")
    check(not report.differences, "a matching report lists no differences")

for observed, expected, label in (
    ({"branch": "main", "tracked_files": "165"}, "PARTIAL", "one changed fact of two"),
    ({"branch": "hotfix", "tracked_files": "999"}, "DRIFT", "every fact changed"),
):
    with tempfile.TemporaryDirectory() as tmp:
        base_knowledge, _ = seeded_knowledge(tmp, {"branch": "main", "tracked_files": "164"})
        snapshot = create_snapshot(base_knowledge, snapshot_id="SNAP-000011",
                                   created_at=STAMP, label="baseline")
    with tempfile.TemporaryDirectory() as tmp2:
        now_knowledge, _ = seeded_knowledge(tmp2, observed, collected=LATER)
        twin = build_twin(now_knowledge, twin_id="TWIN-000011", built_at=LATER)
    report = analyze_integrity(snapshot=snapshot, twin=twin, evaluated_at=LATER,
                               report_id="INTEG-000002")
    check(report.status == expected, f"{label} reports {expected}")
    check(report.differences, f"{expected} lists the differing facts")
    for difference in report.differences:
        check("fact" in difference and "snapshot_value" in difference
              and "twin_value" in difference,
              f"{expected} differences name the fact and both values")
        break

# A twin with no facts cannot support any conclusion.
with tempfile.TemporaryDirectory() as tmp:
    base_knowledge, _ = seeded_knowledge(tmp, {"branch": "main"})
    snapshot = create_snapshot(base_knowledge, snapshot_id="SNAP-000012",
                               created_at=STAMP, label="baseline")
    empty_twin = build_twin(base_knowledge, twin_id="TWIN-000012", built_at=LATER)
    empty_twin = empty_twin.without_facts()
    report = analyze_integrity(snapshot=snapshot, twin=empty_twin, evaluated_at=LATER,
                               report_id="INTEG-000003")
    check(report.status == IntegrityStatus.INSUFFICIENT_EVIDENCE.value,
          "a twin with no facts reports INSUFFICIENT_EVIDENCE")
    check(report.status != IntegrityStatus.DRIFT.value,
          "absent evidence is never reported as drift")

# Facts the snapshot never captured are UNKNOWN, not drift.
with tempfile.TemporaryDirectory() as tmp:
    base_knowledge, _ = seeded_knowledge(tmp, {"branch": "main"})
    snapshot = create_snapshot(base_knowledge, snapshot_id="SNAP-000013",
                               created_at=STAMP, label="baseline")
with tempfile.TemporaryDirectory() as tmp2:
    wider_knowledge, _ = seeded_knowledge(tmp2, {"unrelated_fact": "value"}, collected=LATER)
    wider_twin = build_twin(wider_knowledge, twin_id="TWIN-000013", built_at=LATER)
report = analyze_integrity(snapshot=snapshot, twin=wider_twin, evaluated_at=LATER,
                           report_id="INTEG-000004")
check(report.status == IntegrityStatus.UNKNOWN.value,
      "facts absent from the snapshot report UNKNOWN")
check(report.status != IntegrityStatus.DRIFT.value,
      "an uncomparable fact is never reported as drift")

# --- Confidence is fully explained ----------------------------------------
check(abs(sum(FACTOR_WEIGHTS.values()) - 1.0) < 1e-9, "integrity confidence weights total 1.0")
explanation = compute_integrity_confidence({name: 1.0 for name in FACTOR_WEIGHTS})
check(isinstance(explanation, IntegrityConfidence), "confidence returns an explanation object")
check(0.0 <= explanation.overall <= 1.0, "confidence is bounded between 0 and 1")
check(set(explanation.factors) == set(FACTOR_WEIGHTS),
      "the explanation lists every factor")
check(set(explanation.weights) == set(FACTOR_WEIGHTS),
      "the explanation lists every weight")
check(explanation.contributions and
      set(explanation.contributions) == set(FACTOR_WEIGHTS),
      "the explanation shows each factor's contribution")
check(all(isinstance(reason, str) and reason for reason in explanation.reasons.values()),
      "every factor carries a written reason")
check(compute_integrity_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall ==
      compute_integrity_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall,
      "confidence is deterministic")
try:
    compute_integrity_confidence({n: 1.5 for n in FACTOR_WEIGHTS})
    bad("out-of-range confidence factors are rejected")
except ValueError:
    ok("out-of-range confidence factors are rejected")
try:
    compute_integrity_confidence({"coverage": 1.0})
    bad("missing confidence factors are rejected")
except ValueError:
    ok("missing confidence factors are rejected")

# --- Recovery plans are advisory only -------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    base_knowledge, _ = seeded_knowledge(tmp, {"branch": "main", "tracked_files": "164"})
    snapshot = create_snapshot(base_knowledge, snapshot_id="SNAP-000020",
                               created_at=STAMP, label="baseline")
with tempfile.TemporaryDirectory() as tmp2:
    drift_knowledge, _ = seeded_knowledge(tmp2, {"branch": "hotfix", "tracked_files": "1"},
                                          collected=LATER)
    drift_twin = build_twin(drift_knowledge, twin_id="TWIN-000020", built_at=LATER)

drift_report = analyze_integrity(snapshot=snapshot, twin=drift_twin, evaluated_at=LATER,
                                 report_id="INTEG-000020")
plan = plan_recovery(report=drift_report, snapshot=snapshot, plan_id="RECOV-000001",
                     created_at=LATER)
check(isinstance(plan, RecoveryPlan), "planner returns a RecoveryPlan")
check(plan.id == "RECOV-000001", "recovery plans carry an identifier")
check(plan.advisory_only is True, "recovery plans declare themselves advisory")
check(plan.approval_required is True, "recovery plans require human approval")
check(plan.steps, "a drift report produces recovery steps")
check(all(isinstance(step.get("description"), str) and step.get("description")
          for step in plan.steps),
      "every recovery step is written prose")
check(drift_report.id in plan.integrity_report,
      "the plan references the report that motivated it")
check(snapshot.id in plan.target_snapshot,
      "the plan references the snapshot it would restore toward")

# Steps must not be machine-executable instructions.
plan_blob = json.dumps(plan.to_dict(), default=str).lower()
for forbidden in ("subprocess", "os.system", "shell=true", "docker run",
                  "systemctl", "rm -rf", "command"):
    check(forbidden not in plan_blob,
          f"recovery plan carries no executable field ({forbidden})")
check(not hasattr(plan, "execute"), "a recovery plan has no execute method")

# A matching report needs no recovery.
match_plan = plan_recovery(report=report, snapshot=snapshot, plan_id="RECOV-000002",
                           created_at=LATER)
check(not match_plan.steps or match_plan.status == "no-action-required",
      "a report with nothing to recover produces no recovery steps")

# --- Secrets never reach a snapshot, twin, report, or plan ----------------
with tempfile.TemporaryDirectory() as tmp:
    secret_knowledge, _ = seeded_knowledge(
        tmp, {"remote_url": f"https://user:{CANARY}@git.example.invalid/x.git"})
    snapshots = SnapshotStore(Path(tmp) / "integrity-store")
    secret_snapshot = create_snapshot(secret_knowledge,
                                      snapshot_id=snapshots.allocate_id("snapshot"),
                                      created_at=STAMP, label="secret-probe")
    snapshots.write_snapshot(secret_snapshot)
    secret_twin = build_twin(secret_knowledge, twin_id="TWIN-000099", built_at=STAMP)
    secret_report = analyze_integrity(snapshot=secret_snapshot, twin=secret_twin,
                                      evaluated_at=STAMP, report_id="INTEG-000099")
    secret_plan = plan_recovery(report=secret_report, snapshot=secret_snapshot,
                                plan_id="RECOV-000099", created_at=STAMP)

    blob = json.dumps({
        "snapshot": secret_snapshot.to_dict(),
        "twin": secret_twin.to_dict(),
        "report": secret_report.to_dict(),
        "plan": secret_plan.to_dict(),
    }, default=str)
    check(CANARY not in blob, "no secret value appears in any integrity artefact")
    check(CANARY not in secret_snapshot.content_fingerprint,
          "no secret value reaches a snapshot fingerprint")
    on_disk = "\n".join(p.read_text() for p in (Path(tmp) / "integrity-store").rglob("*.yaml"))
    check(CANARY not in on_disk, "no secret value is persisted to the integrity store")

# --- Store roots must be explicit ------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    for bad_root, label in ((root, "repository root"),
                            (root / "platform-model", "platform-model")):
        try:
            SnapshotStore(bad_root)
            bad(f"snapshot store refuses {label} as a store root")
        except StoreError:
            ok(f"snapshot store refuses {label} as a store root")

# --- The declared model is never modified ---------------------------------
with tempfile.TemporaryDirectory() as tmp:
    before = sorted((str(p.relative_to(root)), p.stat().st_size)
                    for p in (root / "platform-model").rglob("*") if p.is_file())
    knowledge, _ = seeded_knowledge(tmp, {"branch": "main"})
    snapshots = SnapshotStore(Path(tmp) / "integrity-store")
    snap = create_snapshot(knowledge, snapshot_id=snapshots.allocate_id("snapshot"),
                           created_at=STAMP, label="model-probe")
    snapshots.write_snapshot(snap)
    twin = build_twin(knowledge, twin_id="TWIN-000100", built_at=STAMP)
    rep = analyze_integrity(snapshot=snap, twin=twin, evaluated_at=STAMP,
                            report_id="INTEG-000100")
    plan_recovery(report=rep, snapshot=snap, plan_id="RECOV-000100", created_at=STAMP)
    after = sorted((str(p.relative_to(root)), p.stat().st_size)
                   for p in (root / "platform-model").rglob("*") if p.is_file())
    check(before == after, "the integrity engine never modifies platform-model")

# --- CLI --------------------------------------------------------------------
import subprocess  # noqa: E402 - the harness runs the CLI as a child


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.integrity.cli", *args],
                          capture_output=True, text=True, cwd=str(root),
                          env={**os.environ, "PYTHONPATH": str(root)})
    if expect is not None:
        check(proc.returncode == expect,
              f"cli {args[0]} exits {expect} (got {proc.returncode})")
    return proc


help_proc = cli("--help")
for command in ("snapshot", "twin", "analyze", "plan"):
    check(command in help_proc.stdout, f"cli exposes the {command} command")
for forbidden in ("execute", "recover", "apply", "delete"):
    body = help_proc.stdout.lower().split("positional")[-1].split("options")[0]
    check(forbidden not in body, f"cli exposes no {forbidden} command")

# The store root has no default: a default is a production path waiting for an
# accidental write.
cli("snapshot", "--target", TARGET, expect=2)

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "operational integrity behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the operational integrity tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nOperational integrity validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nOperational integrity validation passed.\n'
