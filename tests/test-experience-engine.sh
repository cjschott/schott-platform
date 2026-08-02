#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the Experience Engine.
#
# The engine summarizes observed history so the platform can answer "what is
# normal?" — a different question from "what is true?", which evidence already
# answers. It never predicts, and it holds no model of any kind.
#
# Every store root is a temporary directory. This suite contacts no host, uses
# no SSH, starts no container, runs no subprocess, reads no secret, and writes
# nothing into the repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXPERIENCE="tools/experience"
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

assert_absent_in() {
  local target="$1" pattern="$2" description="$3" matches
  if [[ ! -e "${ROOT}/${target}" ]]; then
    fail "${description} (missing ${target})"
    return
  fi
  matches="$(grep -rIniE -e "${pattern}" "${ROOT}/${target}" || true)"
  if [[ -z "${matches}" ]]; then
    pass "${description}"
  else
    fail "${description}; found: $(printf '%s' "${matches}" | head -2 | tr '\n' ' ')"
  fi
}

# --- Required modules ------------------------------------------------------
for module in __init__ models statistics windows profile_builder baseline \
              confidence experience_store integration cli; do
  assert_file "${EXPERIENCE}/${module}.py"
done

# --- Required governance ---------------------------------------------------
assert_file "docs/decisions/ADR-0008-experience-engine.md"
assert_file "docs/experience/overview.md"

for schema in experience-profile experience-window operational-baseline; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- Identifier widths -----------------------------------------------------
assert_contains "platform-model/schemas/experience-profile.schema.yaml" \
  "EXP-\[0-9\]\{6\}" "experience profile schema uses six-digit identifiers"
assert_contains "platform-model/schemas/experience-window.schema.yaml" \
  "WINDOW-\[0-9\]\{6\}" "experience window schema uses six-digit identifiers"
assert_contains "platform-model/schemas/operational-baseline.schema.yaml" \
  "BASE-\[0-9\]\{6\}" "operational baseline schema uses six-digit identifiers"

# --- No machine learning ---------------------------------------------------
# The exclusion is a decision, not an omission. These names would each pull in
# a non-deterministic, unexplainable component.
assert_absent_in "${EXPERIENCE}" \
  '(import[[:space:]]+(numpy|scipy|pandas|sklearn|torch|tensorflow|statsmodels)|from[[:space:]]+(numpy|scipy|pandas|sklearn|torch|tensorflow)[[:space:]]+import)' \
  "no experience code imports a machine-learning or numeric library"
assert_absent_in "${EXPERIENCE}" \
  '(def[[:space:]]+(predict|forecast|train|fit|learn)_?|\.predict\(|\.fit\(|neural|regression_model)' \
  "no experience code predicts, forecasts, trains, or fits a model"
assert_absent_in "${EXPERIENCE}" '(random\.|Random\(|uniform\(|gauss\()' \
  "no experience code uses randomness"

# --- Static safety ---------------------------------------------------------
assert_absent_in "${EXPERIENCE}" \
  '(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|telnetlib|smtplib)|from[[:space:]]+(socket|requests|urllib|paramiko|http)[[:space:]]+import)' \
  "no experience code imports a network or SSH module"
assert_absent_in "${EXPERIENCE}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\()' \
  "no experience code executes a subprocess"
assert_absent_in "${EXPERIENCE}" '(ssh|scp|sftp|rsync)[[:space:]]' \
  "no experience code references an SSH transport"
assert_absent_in "${EXPERIENCE}" \
  '(docker[[:space:]]+(ps|inspect|exec|run|start|stop|rm|logs)|compose[[:space:]]+(up|down|pull|build))' \
  "no experience code invokes a Docker runtime verb"
assert_absent_in "${EXPERIENCE}" "['\"][^'\"]*ai/\\.env['\"]" \
  "no experience code references ai/.env"

# Immutable records: no update, no delete, no automatic baseline replacement.
assert_absent_in "${EXPERIENCE}" \
  '(def[[:space:]]+(delete|remove|update|overwrite|edit)_(profile|window|baseline|record))' \
  "no experience record has a delete or update method"
assert_absent_in "${EXPERIENCE}" \
  '(auto_update_baseline|replace_baseline|def[[:space:]]+promote_baseline)' \
  "no experience code replaces a baseline automatically"
assert_absent_in "${EXPERIENCE}" \
  '(def[[:space:]]+(remediate|execute|apply)_|auto_recover|auto_correct)' \
  "no experience code remediates or corrects anything"

# The engine reads knowledge and evidence; it never writes to either.
assert_absent_in "${EXPERIENCE}" \
  '(write_evidence|write_verification|write_event|\.process_collector_result\()' \
  "no experience code writes evidence or drives the orchestrator"
assert_absent_in "${EXPERIENCE}" \
  "(open\\(['\"][^'\"]*platform-model[^'\"]*['\"],[[:space:]]*['\"][wax])" \
  "no experience code writes into platform-model"

# --- Generated records must never be committed -----------------------------
if git -C "${ROOT}" ls-files 'platform-model/**/EXP-*' 'platform-model/**/WINDOW-*' \
     'platform-model/**/BASE-*' | grep -q .; then
  fail "generated experience records must not be committed under platform-model"
else
  pass "no generated experience records are committed under platform-model"
fi

# --- CI wiring -------------------------------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-experience-engine\.sh' \
  "ci runs the experience engine tests"

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
CANARY = "CANARY-EXPERIENCE-MUST-NOT-APPEAR-5b1d"


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
    from tools.experience.models import (
        BaselineStatus, BehaviourStatus, ExperienceProfile, ExperienceWindow,
        OperationalBaseline, Trend,
    )
    from tools.experience.statistics import summarize_samples, detect_trend
    from tools.experience.windows import WINDOW_PRESETS, resolve_window
    from tools.experience.profile_builder import build_profile, collect_samples
    from tools.experience.baseline import build_baseline, classify_behaviour
    from tools.experience.confidence import (
        FACTOR_WEIGHTS, compute_experience_confidence,
    )
    from tools.experience.experience_store import ExperienceStore, StoreError
    from tools.experience.integration import combined_assessment
    from tools.integrity.models import IntegrityStatus
    ok("experience modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"experience import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

TARGET = "HOST-0001"
METRIC = "cpu_utilization"
NOW = "2026-08-02T12:00:00-05:00"


def hours_ago(hours):
    from datetime import datetime, timedelta
    return (datetime.fromisoformat(NOW) - timedelta(hours=hours)).isoformat()


def seed_history(tmp, samples, *, target=TARGET, metric=METRIC):
    """Push real observations through the v0.7.0 pipeline, oldest first."""
    store = EvidenceStore(Path(tmp) / "evidence-store")
    orchestrator = Orchestrator(store)
    for offset_hours, value in samples:
        stamp = hours_ago(offset_hours)
        result = CollectorResult(
            collector_id="host-metrics", target=target, status="success",
            started_at=stamp, completed_at=stamp,
            observations=[CObs(fact=metric, value=value, value_type="string",
                               collected_at=stamp, source="host-metrics")],
            errors=[],
        )
        orchestrator.process_collector_result(result, evaluated_at=stamp)
    return store


# --- Statistics are exact and deterministic -------------------------------
summary = summarize_samples([1.0, 2.0, 3.0, 4.0, 100.0])
check(summary["sample_count"] == 5, "summary reports the sample count")
check(summary["minimum"] == 1.0, "summary reports the minimum")
check(summary["maximum"] == 100.0, "summary reports the maximum")
check(abs(summary["mean"] - 22.0) < 1e-9, "summary computes the mean exactly")
check(summary["median"] == 3.0, "summary computes the median for an odd count")
check(summarize_samples([1.0, 3.0])["median"] == 2.0,
      "summary averages the middle pair for an even count")
# Population standard deviation of [1,2,3,4,100] is 38.72983...
check(abs(summary["standard_deviation"] - 38.729834) < 1e-5,
      "summary computes the standard deviation exactly")
check(summarize_samples([5.0])["standard_deviation"] == 0.0,
      "a single sample has zero deviation rather than an error")
check(summarize_samples([1.0, 2.0]) == summarize_samples([1.0, 2.0]),
      "statistics are deterministic")
check(summarize_samples([2.0, 1.0]) == summarize_samples([1.0, 2.0]),
      "statistics do not depend on input order")

# Never invent statistics: no samples means no numbers.
empty = summarize_samples([])
check(empty["sample_count"] == 0, "an empty sample set reports zero samples")
for field in ("minimum", "maximum", "mean", "median", "standard_deviation"):
    check(empty[field] is None, f"an empty sample set reports {field} as null, not zero")

# --- Trend detection is deterministic and explainable ---------------------
check(detect_trend([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])["trend"] == Trend.INCREASING.value,
      "a rising series is increasing")
check(detect_trend([6.0, 5.0, 4.0, 3.0, 2.0, 1.0])["trend"] == Trend.DECREASING.value,
      "a falling series is decreasing")
check(detect_trend([5.0, 5.0, 5.0, 5.0, 5.0, 5.0])["trend"] == Trend.STABLE.value,
      "a flat series is stable")
check(detect_trend([1.0, 99.0, 2.0, 98.0, 3.0, 97.0])["trend"] == Trend.VOLATILE.value,
      "a wildly swinging series is volatile")
check(detect_trend([])["trend"] == Trend.UNKNOWN.value,
      "no samples yields an unknown trend, not stable")
check(detect_trend([5.0])["trend"] == Trend.UNKNOWN.value,
      "a single sample yields an unknown trend")
check(isinstance(detect_trend([1.0, 2.0, 3.0, 4.0])["explanation"], str)
      and detect_trend([1.0, 2.0, 3.0, 4.0])["explanation"],
      "trend detection explains itself")
check(detect_trend([1.0, 2.0, 3.0]) == detect_trend([1.0, 2.0, 3.0]),
      "trend detection is deterministic")

# --- Windows ---------------------------------------------------------------
for preset in ("24h", "7d", "30d"):
    check(preset in WINDOW_PRESETS, f"the {preset} rolling window preset exists")

window = resolve_window("24h", now=NOW)
check(isinstance(window, ExperienceWindow), "resolving a preset returns a window")
check(window.window_end == NOW, "a window ends at the supplied time")
check(window.duration_seconds == 86400, "the 24h window spans one day")
check(resolve_window("7d", now=NOW).duration_seconds == 604800,
      "the 7d window spans seven days")
check(resolve_window("30d", now=NOW).duration_seconds == 2592000,
      "the 30d window spans thirty days")

custom = resolve_window("custom", now=NOW, duration_seconds=3600)
check(custom.duration_seconds == 3600, "a custom window honours its duration")
check(custom.label == "custom", "a custom window is labelled custom")
try:
    resolve_window("custom", now=NOW)
    bad("a custom window without a duration is rejected")
except ValueError:
    ok("a custom window without a duration is rejected")
try:
    resolve_window("fortnight", now=NOW)
    bad("an unknown window preset is rejected")
except ValueError:
    ok("an unknown window preset is rejected")

check(resolve_window("24h", now=NOW) == resolve_window("24h", now=NOW),
      "window resolution is deterministic")

# --- Profiles summarize real observed history -----------------------------
with tempfile.TemporaryDirectory() as tmp:
    # Twelve hourly observations inside the window, one far outside it.
    history = [(hour, float(25 + (hour % 5))) for hour in range(1, 13)]
    history.append((400, 999.0))
    store = seed_history(tmp, history)

    profile = build_profile(store, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id="EXP-000001", generated_at=NOW)
    check(isinstance(profile, ExperienceProfile), "profile builder returns a profile")
    check(profile.id == "EXP-000001", "profiles carry a six-digit identifier")
    check(profile.metric == METRIC, "profiles record the metric they summarize")
    check(profile.sample_count == 12,
          "a profile counts only samples inside its window")
    check(profile.window_start and profile.window_end,
          "a profile records its window boundaries")
    check(profile.maximum is not None and profile.maximum < 999.0,
          "samples outside the window are excluded from the statistics")
    check(profile.trend in {t.value for t in Trend}, "a profile records an approved trend")
    check(profile.provenance == "derived", "profiles are derived, not observed")

    rebuilt = build_profile(store, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id="EXP-000001", generated_at=NOW)
    check(json.dumps(rebuilt.to_dict(), sort_keys=True) ==
          json.dumps(profile.to_dict(), sort_keys=True),
          "profile construction is deterministic")

    # A metric nothing observed must not be invented.
    absent = build_profile(store, target=TARGET, metric="never_collected",
                           window=resolve_window("24h", now=NOW),
                           profile_id="EXP-000002", generated_at=NOW)
    check(absent.sample_count == 0, "an unobserved metric yields no samples")
    check(absent.mean is None, "an unobserved metric yields no mean rather than zero")
    check(absent.trend == Trend.UNKNOWN.value, "an unobserved metric has an unknown trend")

    samples = collect_samples(store, target=TARGET, metric=METRIC,
                              window=resolve_window("24h", now=NOW))
    check(len(samples) == 12, "sample collection respects the window")
    check(samples == sorted(samples, key=lambda s: s[0]),
          "samples are returned in chronological order")

# --- Store: immutable, atomic, explicit root ------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = ExperienceStore(Path(tmp) / "experience-store")
    check(store.allocate_id("profile") == "EXP-000001",
          "profile identifiers start at EXP-000001")
    check(store.allocate_id("window") == "WINDOW-000001",
          "window identifiers start at WINDOW-000001")
    check(store.allocate_id("baseline") == "BASE-000001",
          "baseline identifiers start at BASE-000001")

    history = [(hour, float(20 + hour)) for hour in range(1, 6)]
    evidence = seed_history(tmp, history)
    profile = build_profile(evidence, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id="EXP-000100", generated_at=NOW)
    path = store.write_profile(profile)
    check(path.name == "EXP-000100.yaml", "profile filenames match identifiers")
    mode = stat.S_IMODE(path.stat().st_mode)
    check(mode & 0o077 == 0, "experience records carry restrictive permissions")

    try:
        store.write_profile(profile)
        bad("an existing profile cannot be overwritten")
    except StoreError:
        ok("an existing profile cannot be overwritten")

    leftovers = [p.name for p in path.parent.iterdir() if not p.name.endswith(".yaml")]
    check(not leftovers, "no partial writes are left behind")
    check(not store.validate(), "a freshly written store validates cleanly")

for bad_root, label in ((root, "repository root"), (root / "platform-model", "platform-model")):
    try:
        ExperienceStore(bad_root)
        bad(f"experience store refuses {label} as a store root")
    except StoreError:
        ok(f"experience store refuses {label} as a store root")

# --- Confidence ------------------------------------------------------------
check(abs(sum(FACTOR_WEIGHTS.values()) - 1.0) < 1e-9, "experience confidence weights total 1.0")
check(set(FACTOR_WEIGHTS) == {"coverage", "sample_quality", "window_size", "data_age"},
      "confidence uses exactly the four documented factors")
explanation = compute_experience_confidence({name: 1.0 for name in FACTOR_WEIGHTS})
check(0.0 <= explanation.overall <= 1.0, "confidence is bounded between 0 and 1")
check(set(explanation.contributions) == set(FACTOR_WEIGHTS),
      "confidence reports each factor's contribution")
check(all(isinstance(reason, str) and reason for reason in explanation.reasons.values()),
      "every confidence factor carries a written reason")
check(compute_experience_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall ==
      compute_experience_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall,
      "confidence is deterministic")
try:
    compute_experience_confidence({n: 2.0 for n in FACTOR_WEIGHTS})
    bad("out-of-range confidence factors are rejected")
except ValueError:
    ok("out-of-range confidence factors are rejected")
try:
    compute_experience_confidence({"coverage": 1.0})
    bad("missing confidence factors are rejected")
except ValueError:
    ok("missing confidence factors are rejected")

# --- Baselines -------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    # A steady history around 27%.
    history = [(hour, float(27 + ((hour % 3) - 1))) for hour in range(1, 25)]
    evidence = seed_history(tmp, history)
    profile = build_profile(evidence, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id="EXP-000200", generated_at=NOW)

    baseline = build_baseline([profile], baseline_id="BASE-000001",
                              generated_at=NOW, target=TARGET, metric=METRIC)
    check(isinstance(baseline, OperationalBaseline), "baseline builder returns a baseline")
    check(baseline.id == "BASE-000001", "baselines carry a six-digit identifier")
    check(baseline.typical_value is not None, "a baseline reports a typical value")
    check(baseline.sample_count == profile.sample_count,
          "a baseline reports the samples behind it")
    check(baseline.confidence is not None, "a baseline carries confidence")
    check(set(baseline.confidence.factors) == set(FACTOR_WEIGHTS),
          "baseline confidence reports every factor")
    check(baseline.windows and profile.id in baseline.profiles,
          "a baseline references the profiles it summarizes")

    rebuilt = build_baseline([profile], baseline_id="BASE-000001",
                             generated_at=NOW, target=TARGET, metric=METRIC)
    check(json.dumps(rebuilt.to_dict(), sort_keys=True) ==
          json.dumps(baseline.to_dict(), sort_keys=True),
          "baseline construction is deterministic")

    # 29% against a typical 27% is expected; 98% is not.
    near = classify_behaviour(baseline, current_value=29.0)
    check(near.status == BaselineStatus.EXPECTED.value,
          "a value close to typical is EXPECTED")
    check(near.difference is not None, "the assessment reports the difference")
    check(isinstance(near.explanation, str) and near.explanation,
          "the assessment explains itself")

    far = classify_behaviour(baseline, current_value=98.0)
    check(far.status == BaselineStatus.UNEXPECTED.value,
          "a value far from typical is UNEXPECTED")
    check(far.difference is not None and far.difference > 0,
          "an unexpected assessment reports how far from typical it is")
    check(str(baseline.id) in far.explanation,
          "the assessment names the baseline it compared against")

    check(classify_behaviour(baseline, current_value=29.0) ==
          classify_behaviour(baseline, current_value=29.0),
          "classification is deterministic")

# --- The rules that keep this honest --------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    # No observations at all.
    empty_store = EvidenceStore(Path(tmp) / "evidence-store")
    empty_profile = build_profile(empty_store, target=TARGET, metric=METRIC,
                                  window=resolve_window("24h", now=NOW),
                                  profile_id="EXP-000300", generated_at=NOW)
    empty_baseline = build_baseline([empty_profile], baseline_id="BASE-000300",
                                    generated_at=NOW, target=TARGET, metric=METRIC)
    verdict = classify_behaviour(empty_baseline, current_value=98.0)
    check(verdict.status == BaselineStatus.UNKNOWN.value,
          "missing observations produce UNKNOWN, never UNEXPECTED")
    check(verdict.status != BaselineStatus.UNEXPECTED.value,
          "an absence of history is never abnormal behaviour")
    check(empty_baseline.typical_value is None,
          "a baseline with no samples invents no typical value")

with tempfile.TemporaryDirectory() as tmp:
    # A single observation is not enough to call anything abnormal.
    evidence = seed_history(tmp, [(1, 27.0)])
    thin_profile = build_profile(evidence, target=TARGET, metric=METRIC,
                                 window=resolve_window("24h", now=NOW),
                                 profile_id="EXP-000301", generated_at=NOW)
    thin_baseline = build_baseline([thin_profile], baseline_id="BASE-000301",
                                   generated_at=NOW, target=TARGET, metric=METRIC)
    thin = classify_behaviour(thin_baseline, current_value=98.0)
    check(thin.status == BaselineStatus.INSUFFICIENT_EVIDENCE.value,
          "a low sample count produces INSUFFICIENT_EVIDENCE, not UNEXPECTED")
    check(thin.status != BaselineStatus.UNEXPECTED.value,
          "a thin history never makes a system abnormal")
    check(thin_baseline.confidence.overall < 0.9,
          "a thin history yields low confidence")

# A value with nothing to compare against stays unknown.
unknown_verdict = classify_behaviour(None, current_value=50.0)
check(unknown_verdict.status == BaselineStatus.UNKNOWN.value,
      "no baseline at all yields UNKNOWN")

# --- Integration with Operational Integrity -------------------------------
# Two independent axes: MATCH compares against a snapshot, EXPECTED compares
# against operational history. Both may hold at once.
for integrity, behaviour, expected_priority in (
    (IntegrityStatus.MATCH.value, BaselineStatus.EXPECTED.value, "none"),
    (IntegrityStatus.MATCH.value, BaselineStatus.UNEXPECTED.value, "investigate"),
    (IntegrityStatus.DRIFT.value, BaselineStatus.EXPECTED.value, "review"),
    (IntegrityStatus.DRIFT.value, BaselineStatus.UNEXPECTED.value, "high"),
):
    combined = combined_assessment(integrity_status=integrity, behaviour_status=behaviour)
    check(combined["integrity_status"] == integrity,
          f"combined assessment preserves integrity status {integrity}")
    check(combined["behaviour_status"] == behaviour,
          f"combined assessment preserves behaviour status {behaviour}")
    check(combined["priority"] == expected_priority,
          f"{integrity} + {behaviour} has priority '{expected_priority}'")
    check(isinstance(combined["explanation"], str) and combined["explanation"],
          f"{integrity} + {behaviour} is explained")

check(combined_assessment(integrity_status=IntegrityStatus.MATCH.value,
                          behaviour_status=BaselineStatus.EXPECTED.value)
      != combined_assessment(integrity_status=IntegrityStatus.MATCH.value,
                             behaviour_status=BaselineStatus.UNEXPECTED.value),
      "EXPECTED is not equivalent to MATCH")

unknown_combined = combined_assessment(
    integrity_status=IntegrityStatus.MATCH.value,
    behaviour_status=BaselineStatus.UNKNOWN.value)
check(unknown_combined["priority"] != "high",
      "an unknown behaviour status never escalates on its own")

# --- Secrets never reach an experience record -----------------------------
with tempfile.TemporaryDirectory() as tmp:
    evidence = seed_history(tmp, [(1, 27.0), (2, 28.0)])
    secret_store = EvidenceStore(Path(tmp) / "evidence-store")
    orchestrator = Orchestrator(secret_store)
    stamp = hours_ago(1)
    orchestrator.process_collector_result(
        CollectorResult(collector_id="host-metrics", target=TARGET, status="success",
                        started_at=stamp, completed_at=stamp,
                        observations=[CObs(fact="remote_url",
                                           value=f"https://u:{CANARY}@h/x.git",
                                           value_type="string", collected_at=stamp,
                                           source="host-metrics")],
                        errors=[]),
        evaluated_at=stamp)

    store = ExperienceStore(Path(tmp) / "experience-store")
    profile = build_profile(secret_store, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id=store.allocate_id("profile"), generated_at=NOW)
    store.write_profile(profile)
    baseline = build_baseline([profile], baseline_id=store.allocate_id("baseline"),
                              generated_at=NOW, target=TARGET, metric=METRIC)
    blob = json.dumps({"profile": profile.to_dict(), "baseline": baseline.to_dict()},
                      default=str)
    check(CANARY not in blob, "no secret value appears in an experience record")
    on_disk = "\n".join(p.read_text() for p in (Path(tmp) / "experience-store").rglob("*.yaml"))
    check(CANARY not in on_disk, "no secret value is persisted to the experience store")

# --- Knowledge and evidence are never modified ----------------------------
with tempfile.TemporaryDirectory() as tmp:
    evidence = seed_history(tmp, [(hour, float(20 + hour)) for hour in range(1, 6)])
    before = sorted((str(p), p.stat().st_size)
                    for p in (Path(tmp) / "evidence-store").rglob("*") if p.is_file())
    store = ExperienceStore(Path(tmp) / "experience-store")
    profile = build_profile(evidence, target=TARGET, metric=METRIC,
                            window=resolve_window("24h", now=NOW),
                            profile_id=store.allocate_id("profile"), generated_at=NOW)
    build_baseline([profile], baseline_id=store.allocate_id("baseline"),
                   generated_at=NOW, target=TARGET, metric=METRIC)
    after = sorted((str(p), p.stat().st_size)
                   for p in (Path(tmp) / "evidence-store").rglob("*") if p.is_file())
    check(before == after, "the experience engine never modifies evidence")

    model_before = sorted((str(p.relative_to(root)), p.stat().st_size)
                          for p in (root / "platform-model").rglob("*") if p.is_file())
    model_after = sorted((str(p.relative_to(root)), p.stat().st_size)
                         for p in (root / "platform-model").rglob("*") if p.is_file())
    check(model_before == model_after, "the experience engine never modifies platform-model")

# --- CLI --------------------------------------------------------------------
import subprocess  # noqa: E402 - the harness runs the CLI as a child


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.experience.cli", *args],
                          capture_output=True, text=True, cwd=str(root),
                          env={**os.environ, "PYTHONPATH": str(root)})
    if expect is not None:
        check(proc.returncode == expect,
              f"cli {args[0]} exits {expect} (got {proc.returncode})")
    return proc


help_proc = cli("--help")
import re as _re  # noqa: E402
choices = _re.search(r"\{([a-z,\-]+)\}", help_proc.stdout)
command_names = set(choices.group(1).split(",")) if choices else set()
for command in ("build", "summarize", "compare", "explain"):
    check(command in command_names, f"cli exposes the {command} command")
for forbidden in ("predict", "forecast", "train", "delete", "remediate"):
    check(forbidden not in command_names, f"cli exposes no {forbidden} command")

# Store roots are explicit: a default is a production path waiting for a write.
cli("build", "--target", TARGET, "--metric", METRIC, expect=2)

with tempfile.TemporaryDirectory() as tmp:
    evidence = seed_history(tmp, [(hour, float(25 + (hour % 4))) for hour in range(1, 13)])
    store_root = str(Path(tmp) / "experience-store")
    evidence_root = str(Path(tmp) / "evidence-store")

    built = cli("build", "--target", TARGET, "--metric", METRIC, "--window", "24h",
                "--generated-at", NOW, "--evidence-root", evidence_root,
                "--store-root", store_root, expect=0)
    check("EXP-" in built.stdout, "cli build reports the profile identifier")
    parsed = json.loads(built.stdout)
    check(parsed.get("metric") == METRIC, "cli build emits deterministic JSON")

    summarized = cli("summarize", "--target", TARGET, "--metric", METRIC,
                     "--window", "24h", "--generated-at", NOW,
                     "--evidence-root", evidence_root, "--store-root", store_root,
                     expect=0)
    summary_payload = json.loads(summarized.stdout)
    check("typical_value" in summary_payload, "cli summarize reports a typical value")

    compared = cli("compare", "--target", TARGET, "--metric", METRIC, "--window", "24h",
                   "--current-value", "27.5", "--generated-at", NOW,
                   "--evidence-root", evidence_root, "--store-root", store_root,
                   expect=0)
    compare_payload = json.loads(compared.stdout)
    check(compare_payload.get("status") in {s.value for s in BaselineStatus},
          "cli compare reports an approved status")

    explained = cli("explain", "--target", TARGET, "--metric", METRIC, "--window", "24h",
                    "--current-value", "27.5", "--generated-at", NOW,
                    "--evidence-root", evidence_root, "--store-root", store_root,
                    expect=0)
    explain_payload = json.loads(explained.stdout)
    for section in ("statistics", "confidence", "explanation"):
        check(section in explain_payload, f"cli explain reports {section}")
    check(explain_payload["confidence"].get("interpretation"),
          "cli explain states how confidence should be read")

    # Determinism at the interface, not just in the library.
    repeat = cli("explain", "--target", TARGET, "--metric", METRIC, "--window", "24h",
                 "--current-value", "27.5", "--generated-at", NOW,
                 "--evidence-root", evidence_root, "--store-root", store_root)
    check(repeat.stdout == explained.stdout, "cli explain output is deterministic")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "experience engine behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the experience engine tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nExperience engine validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nExperience engine validation passed.\n'
