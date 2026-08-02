#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the Occurrence Timeline.
#
# The platform already records what is true (evidence), what it believes
# (knowledge), whether that still matches a known-good state (integrity), and
# what is normal (experience). This layer records *when* things happened.
#
# It describes observed temporal relationships and nothing else. No prediction,
# no forecasting, no model, no probability. Every number is recomputable by
# hand from the occurrences it summarizes.
#
# Every store root is a temporary directory. This suite contacts no host, uses
# no SSH, starts no container, runs no subprocess against the platform, reads
# no secret, and writes nothing into the repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OCCURRENCE="tools/occurrence"
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
for module in __init__ models recorder series patterns timeline confidence \
              occurrence_store integration cli; do
  assert_file "${OCCURRENCE}/${module}.py"
done

# The shared immutable-store base. Introduced here so this package does not
# become a fourth hand-copied write path.
assert_file "tools/common/__init__.py"
assert_file "tools/common/immutable_store.py"

# --- Required governance ---------------------------------------------------
assert_file "docs/decisions/ADR-0009-occurrence-timeline.md"
assert_file "docs/occurrence/overview.md"

for schema in occurrence occurrence-series pattern timeline; do
  assert_file "platform-model/schemas/${schema}.schema.yaml"
done

# --- Identifier widths -----------------------------------------------------
assert_contains "platform-model/schemas/occurrence.schema.yaml" \
  "OCC-\[0-9\]\{6\}" "occurrence schema uses six-digit identifiers"
assert_contains "platform-model/schemas/occurrence-series.schema.yaml" \
  "SERIES-\[0-9\]\{6\}" "occurrence series schema uses six-digit identifiers"
assert_contains "platform-model/schemas/pattern.schema.yaml" \
  "PAT-\[0-9\]\{6\}" "pattern schema uses six-digit identifiers"
assert_contains "platform-model/schemas/timeline.schema.yaml" \
  "TL-\[0-9\]\{6\}" "timeline schema uses six-digit identifiers"

# --- No prediction, no learning, no probability ----------------------------
assert_absent_in "${OCCURRENCE}" \
  '(import[[:space:]]+(numpy|scipy|pandas|sklearn|torch|tensorflow|statsmodels)|from[[:space:]]+(numpy|scipy|pandas|sklearn|torch|tensorflow)[[:space:]]+import)' \
  "no occurrence code imports a machine-learning or numeric library"
assert_absent_in "${OCCURRENCE}" \
  '(def[[:space:]]+(predict|forecast|train|fit|learn|extrapolate)_?|\.predict\(|\.fit\(|neural|markov|bayes)' \
  "no occurrence code predicts, forecasts, trains, or fits a model"
assert_absent_in "${OCCURRENCE}" '(random\.|Random\(|uniform\(|gauss\(|probability_of|likelihood_of)' \
  "no occurrence code uses randomness or claims probability"
assert_absent_in "${OCCURRENCE}" \
  '(next_occurrence_at|expected_next|will_occur|projected_)' \
  "no occurrence code projects a future occurrence"

# --- Static safety ---------------------------------------------------------
assert_absent_in "${OCCURRENCE}" \
  '(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|telnetlib|smtplib)|from[[:space:]]+(socket|requests|urllib|paramiko|http)[[:space:]]+import)' \
  "no occurrence code imports a network or SSH module"
assert_absent_in "${OCCURRENCE}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\()' \
  "no occurrence code executes a subprocess"
assert_absent_in "${OCCURRENCE}" '(ssh|scp|sftp|rsync)[[:space:]]' \
  "no occurrence code references an SSH transport"
assert_absent_in "${OCCURRENCE}" \
  '(docker[[:space:]]+(ps|inspect|exec|run|start|stop|rm|logs)|compose[[:space:]]+(up|down|pull|build))' \
  "no occurrence code invokes a Docker runtime verb"
assert_absent_in "${OCCURRENCE}" "['\"][^'\"]*ai/\\.env['\"]" \
  "no occurrence code references ai/.env"
assert_absent_in "${OCCURRENCE}" \
  '(def[[:space:]]+(delete|remove|update|overwrite|edit)_(occurrence|series|pattern|timeline|record))' \
  "no occurrence record has a delete or update method"
assert_absent_in "${OCCURRENCE}" \
  '(def[[:space:]]+(remediate|execute|apply)_|auto_recover|auto_correct)' \
  "no occurrence code remediates or corrects anything"
assert_absent_in "${OCCURRENCE}" \
  "(open\\(['\"][^'\"]*platform-model[^'\"]*['\"],[[:space:]]*['\"][wax])" \
  "no occurrence code writes into platform-model"

# The dependency direction must stay acyclic: occurrence may read integrity and
# experience vocabulary, but neither may import occurrence.
assert_absent_in "tools/integrity" 'tools\.occurrence|from[[:space:]]+\.\.occurrence' \
  "operational integrity does not depend on the occurrence package"
assert_absent_in "tools/experience" 'tools\.occurrence|from[[:space:]]+\.\.occurrence' \
  "the experience engine does not depend on the occurrence package"

# --- Generated records must never be committed -----------------------------
if git -C "${ROOT}" ls-files 'platform-model/**/OCC-*' 'platform-model/**/SERIES-*' \
     'platform-model/**/PAT-*' 'platform-model/**/TL-*' | grep -q .; then
  fail "generated occurrence records must not be committed under platform-model"
else
  pass "no generated occurrence records are committed under platform-model"
fi

# --- CI and local validation wiring ----------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-occurrence-timeline\.sh' \
  "ci runs the occurrence timeline tests"
assert_contains "tools/dev/run-validation.sh" 'tests/test-occurrence-timeline\.sh' \
  "local validation runs the occurrence timeline suite"

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
CANARY = "CANARY-OCCURRENCE-MUST-NOT-APPEAR-2f8c"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.common.immutable_store import ImmutableStore, StoreError
    from tools.occurrence.models import (
        Occurrence, OccurrenceSeries, Pattern, Timeline,
        PatternKind, Recurrence,
    )
    from tools.occurrence.recorder import record_occurrence, occurrences_from_evidence
    from tools.occurrence.series import build_series, interval_seconds
    from tools.occurrence.patterns import detect_patterns
    from tools.occurrence.timeline import build_timeline
    from tools.occurrence.confidence import (
        FACTOR_WEIGHTS, compute_temporal_confidence,
    )
    from tools.occurrence.occurrence_store import OccurrenceStore
    from tools.occurrence.integration import temporal_context
    from tools.integrity.models import IntegrityStatus
    from tools.experience.models import BaselineStatus
    ok("occurrence modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"occurrence import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

TARGET = "SVC-0001"
KIND = "service-restart"
NOW = "2026-08-02T12:00:00-05:00"


def hours_ago(hours):
    from datetime import datetime, timedelta
    return (datetime.fromisoformat(NOW) - timedelta(hours=hours)).isoformat()


def occ(offset_hours, *, target=TARGET, kind=KIND, identifier=None, index=[0]):
    index[0] += 1
    return record_occurrence(
        occurrence_id=identifier or f"OCC-{index[0]:06d}",
        target=target, kind=kind, occurred_at=hours_ago(offset_hours),
        source="EVID-000001", recorded_at=NOW,
    )


# --- Occurrences are immutable and validated ------------------------------
first = occ(10, identifier="OCC-000001")
check(isinstance(first, Occurrence), "recorder returns an Occurrence")
check(first.id == "OCC-000001", "occurrences carry a six-digit identifier")
check(first.target == TARGET and first.kind == KIND,
      "an occurrence records its target and kind")
check(first.provenance == "observed", "occurrence provenance is observed")
check(first.source, "an occurrence names the record it came from")

try:
    first.occurred_at = NOW
    mutated = True
except Exception:  # noqa: BLE001
    mutated = False
check(not mutated, "an occurrence cannot be reassigned in place")

try:
    record_occurrence(occurrence_id="OCC-1", target=TARGET, kind=KIND,
                      occurred_at=hours_ago(1), source="EVID-000001", recorded_at=NOW)
    bad("a malformed occurrence identifier is rejected")
except ValueError:
    ok("a malformed occurrence identifier is rejected")

try:
    record_occurrence(occurrence_id="OCC-000009", target=TARGET, kind=KIND,
                      occurred_at="2026-08-02T12:00:00", source="EVID-000001",
                      recorded_at=NOW)
    bad("a naive occurrence timestamp is rejected")
except ValueError:
    ok("a naive occurrence timestamp is rejected")

# --- Series: first seen, last seen, intervals, frequency, recurrence -------
# Six restarts, exactly two hours apart.
regular = [occ(h) for h in (12, 10, 8, 6, 4, 2)]
series = build_series(regular, series_id="SERIES-000001", generated_at=NOW,
                      target=TARGET, kind=KIND)
check(isinstance(series, OccurrenceSeries), "series builder returns a series")
check(series.id == "SERIES-000001", "a series carries a six-digit identifier")
check(series.count == 6, "a series counts its occurrences")
check(series.first_seen == hours_ago(12), "a series records first seen")
check(series.last_seen == hours_ago(2), "a series records last seen")
check(series.intervals_seconds == [7200] * 5,
      "a series records the interval between consecutive occurrences")
check(series.mean_interval_seconds == 7200, "a series reports the mean interval")
check(series.median_interval_seconds == 7200, "a series reports the median interval")
check(series.minimum_interval_seconds == 7200, "a series reports the minimum interval")
check(series.maximum_interval_seconds == 7200, "a series reports the maximum interval")
check(series.recurrence == Recurrence.REGULAR.value,
      "evenly spaced occurrences are regular")
check(series.observation_span_seconds == 36000,
      "a series reports the span it observed")

# Frequency is derived, never invented.
check(series.frequency_per_day is not None and series.frequency_per_day > 0,
      "a series reports an observed frequency")

rebuilt = build_series(regular, series_id="SERIES-000001", generated_at=NOW,
                       target=TARGET, kind=KIND)
check(json.dumps(rebuilt.to_dict(), sort_keys=True) ==
      json.dumps(series.to_dict(), sort_keys=True),
      "series construction is deterministic")

shuffled = build_series(list(reversed(regular)), series_id="SERIES-000001",
                        generated_at=NOW, target=TARGET, kind=KIND)
check(json.dumps(shuffled.to_dict(), sort_keys=True) ==
      json.dumps(series.to_dict(), sort_keys=True),
      "series construction does not depend on input order")

# Irregular spacing must not be called regular.
irregular = [occ(h) for h in (48, 47, 46, 20, 3)]
irr = build_series(irregular, series_id="SERIES-000002", generated_at=NOW,
                   target=TARGET, kind=KIND)
check(irr.recurrence == Recurrence.IRREGULAR.value,
      "unevenly spaced occurrences are irregular")

# One occurrence has no interval, and no frequency may be invented from it.
single = build_series([occ(5)], series_id="SERIES-000003", generated_at=NOW,
                      target=TARGET, kind=KIND)
check(single.count == 1, "a single occurrence is counted")
check(single.intervals_seconds == [], "a single occurrence yields no intervals")
check(single.mean_interval_seconds is None,
      "a single occurrence yields no mean interval, not zero")
check(single.recurrence == Recurrence.SINGLE.value,
      "one occurrence is single, not regular")
check(single.frequency_per_day is None,
      "a single occurrence yields no frequency rather than an invented one")

# No occurrences at all: every temporal measure is null.
empty = build_series([], series_id="SERIES-000004", generated_at=NOW,
                     target=TARGET, kind=KIND)
check(empty.count == 0, "an empty series counts zero")
check(empty.recurrence == Recurrence.UNKNOWN.value,
      "an empty series has unknown recurrence, not regular")
for field in ("first_seen", "last_seen", "mean_interval_seconds",
              "median_interval_seconds", "frequency_per_day"):
    check(getattr(empty, field) is None,
          f"an empty series reports {field} as null, not zero")

check(interval_seconds(hours_ago(4), hours_ago(2)) == 7200,
      "interval calculation is exact")

# --- Patterns are deterministic and explainable ---------------------------
patterns = detect_patterns(series, pattern_id_prefix="PAT", generated_at=NOW)
check(isinstance(patterns, list), "pattern detection returns a list")
check(all(isinstance(p, Pattern) for p in patterns), "each result is a Pattern")
check(any(p.kind == PatternKind.RECURRING.value for p in patterns),
      "an evenly spaced series is recognised as recurring")
for pattern in patterns:
    check(isinstance(pattern.explanation, str) and pattern.explanation,
          f"pattern {pattern.kind} explains itself")
    check(pattern.series and series.id in pattern.series,
          f"pattern {pattern.kind} references the series it came from")
    check(pattern.id.startswith("PAT-") and len(pattern.id) == len("PAT-000001"),
          "pattern identifiers use six digits")

check(json.dumps([p.to_dict() for p in detect_patterns(series, pattern_id_prefix="PAT",
                                                       generated_at=NOW)], sort_keys=True) ==
      json.dumps([p.to_dict() for p in patterns], sort_keys=True),
      "pattern detection is deterministic")

# A burst: several occurrences close together after a long gap.
burst_series = build_series([occ(h) for h in (200, 3, 2.9, 2.8, 2.7)],
                            series_id="SERIES-000005", generated_at=NOW,
                            target=TARGET, kind=KIND)
burst_patterns = detect_patterns(burst_series, pattern_id_prefix="PAT", generated_at=NOW)
check(any(p.kind == PatternKind.BURST.value for p in burst_patterns),
      "clustered occurrences after a gap are recognised as a burst")

isolated = detect_patterns(single, pattern_id_prefix="PAT", generated_at=NOW)
check(any(p.kind == PatternKind.ISOLATED.value for p in isolated),
      "a single occurrence is recognised as isolated")

check(detect_patterns(empty, pattern_id_prefix="PAT", generated_at=NOW) == [],
      "an empty series yields no patterns rather than an invented one")

# Nothing may claim a future occurrence.
pattern_blob = json.dumps([p.to_dict() for p in patterns + burst_patterns], default=str).lower()
for forbidden in ("next expected", "will occur", "predicted", "forecast", "probability"):
    check(forbidden not in pattern_blob,
          f"patterns make no forward-looking claim ({forbidden})")

# --- Timeline is ordered and deterministic --------------------------------
mixed = [occ(5, kind="deploy"), occ(9, kind="service-restart"), occ(1, kind="deploy")]
timeline = build_timeline(mixed, timeline_id="TL-000001", generated_at=NOW,
                          target=TARGET)
check(isinstance(timeline, Timeline), "timeline builder returns a Timeline")
check(timeline.id == "TL-000001", "a timeline carries a six-digit identifier")
check([e["occurred_at"] for e in timeline.entries] ==
      sorted(e["occurred_at"] for e in timeline.entries),
      "timeline entries are ordered by time")
check(timeline.entry_count == 3, "a timeline counts its entries")
check(timeline.earliest and timeline.latest,
      "a timeline records its earliest and latest entry")

again = build_timeline(list(reversed(mixed)), timeline_id="TL-000001",
                       generated_at=NOW, target=TARGET)
check(json.dumps(again.to_dict(), sort_keys=True) ==
      json.dumps(timeline.to_dict(), sort_keys=True),
      "timeline construction is deterministic and order-independent")

# Ties break on identifier, so two occurrences at the same instant order stably.
same_instant = [
    record_occurrence(occurrence_id="OCC-000902", target=TARGET, kind="b",
                      occurred_at=hours_ago(3), source="EVID-000001", recorded_at=NOW),
    record_occurrence(occurrence_id="OCC-000901", target=TARGET, kind="a",
                      occurred_at=hours_ago(3), source="EVID-000001", recorded_at=NOW),
]
tie = build_timeline(same_instant, timeline_id="TL-000002", generated_at=NOW,
                     target=TARGET)
check([e["id"] for e in tie.entries] == ["OCC-000901", "OCC-000902"],
      "simultaneous occurrences order deterministically by identifier")

empty_timeline = build_timeline([], timeline_id="TL-000003", generated_at=NOW,
                                target=TARGET)
check(empty_timeline.entry_count == 0, "an empty timeline counts zero entries")
check(empty_timeline.earliest is None and empty_timeline.latest is None,
      "an empty timeline invents no boundaries")

# --- Confidence ------------------------------------------------------------
check(abs(sum(FACTOR_WEIGHTS.values()) - 1.0) < 1e-9, "temporal confidence weights total 1.0")
explanation = compute_temporal_confidence({name: 1.0 for name in FACTOR_WEIGHTS})
check(0.0 <= explanation.overall <= 1.0, "confidence is bounded between 0 and 1")
check(set(explanation.factors) == set(FACTOR_WEIGHTS),
      "the explanation lists every factor")
check(set(explanation.contributions) == set(FACTOR_WEIGHTS),
      "the explanation shows each factor's contribution")
check(all(isinstance(r, str) and r for r in explanation.reasons.values()),
      "every factor carries a written reason")
check(compute_temporal_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall ==
      compute_temporal_confidence({n: 0.5 for n in FACTOR_WEIGHTS}).overall,
      "confidence is deterministic")
check("probability" in explanation.to_dict()["interpretation"],
      "confidence states it is not a probability")
try:
    compute_temporal_confidence({n: 5.0 for n in FACTOR_WEIGHTS})
    bad("out-of-range confidence factors are rejected")
except ValueError:
    ok("out-of-range confidence factors are rejected")
try:
    compute_temporal_confidence({"occurrence_count": 1.0})
    bad("missing confidence factors are rejected")
except ValueError:
    ok("missing confidence factors are rejected")

check(series.confidence is not None, "a series carries confidence")
check(single.confidence.overall < series.confidence.overall,
      "a thinner series yields lower confidence")

# --- Store: immutable, atomic, explicit root ------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = OccurrenceStore(Path(tmp) / "occurrence-store")
    check(store.allocate_id("occurrence") == "OCC-000001",
          "occurrence identifiers start at OCC-000001")
    check(store.allocate_id("series") == "SERIES-000001",
          "series identifiers start at SERIES-000001")
    check(store.allocate_id("pattern") == "PAT-000001",
          "pattern identifiers start at PAT-000001")
    check(store.allocate_id("timeline") == "TL-000001",
          "timeline identifiers start at TL-000001")

    written = store.write_occurrence(first)
    check(written.name == "OCC-000001.yaml", "occurrence filenames match identifiers")
    mode = stat.S_IMODE(written.stat().st_mode)
    check(mode & 0o077 == 0, "occurrence records carry restrictive permissions")

    try:
        store.write_occurrence(first)
        bad("an existing occurrence cannot be overwritten")
    except StoreError:
        ok("an existing occurrence cannot be overwritten")

    leftovers = [p.name for p in written.parent.iterdir() if not p.name.endswith(".yaml")]
    check(not leftovers, "no partial writes are left behind")
    check(not store.validate(), "a freshly written store validates cleanly")
    check(isinstance(store, ImmutableStore),
          "the occurrence store reuses the shared immutable base")

for bad_root, label in ((root, "repository root"), (root / "platform-model", "platform-model")):
    try:
        OccurrenceStore(bad_root)
        bad(f"occurrence store refuses {label} as a store root")
    except StoreError:
        ok(f"occurrence store refuses {label} as a store root")

# --- Occurrences derive from real evidence --------------------------------
from tools.collectors.models import CollectorResult, Observation as CObs  # noqa: E402
from tools.observation.evidence_store import EvidenceStore  # noqa: E402
from tools.observation.orchestrator import Orchestrator  # noqa: E402

with tempfile.TemporaryDirectory() as tmp:
    evidence = EvidenceStore(Path(tmp) / "evidence-store")
    orchestrator = Orchestrator(evidence)
    for offset, value in ((6, "1"), (4, "2"), (2, "3")):
        stamp = hours_ago(offset)
        orchestrator.process_collector_result(
            CollectorResult(collector_id="host-metrics", target=TARGET, status="success",
                            started_at=stamp, completed_at=stamp,
                            observations=[CObs(fact="restart_count", value=value,
                                               value_type="string", collected_at=stamp,
                                               source="host-metrics")],
                            errors=[]),
            evaluated_at=stamp)

    derived = occurrences_from_evidence(evidence, target=TARGET, kind="observation",
                                        recorded_at=NOW, id_prefix="OCC")
    check(len(derived) == 3, "one occurrence is derived per evidence record")
    check(all(o.source.startswith("EVID-") for o in derived),
          "each derived occurrence cites the evidence it came from")
    check([o.occurred_at for o in derived] == sorted(o.occurred_at for o in derived),
          "derived occurrences are returned in chronological order")

    before = sorted((str(p), p.stat().st_size)
                    for p in (Path(tmp) / "evidence-store").rglob("*") if p.is_file())
    occurrences_from_evidence(evidence, target=TARGET, kind="observation",
                              recorded_at=NOW, id_prefix="OCC")
    after = sorted((str(p), p.stat().st_size)
                   for p in (Path(tmp) / "evidence-store").rglob("*") if p.is_file())
    check(before == after, "deriving occurrences never modifies evidence")

# --- Integration without circular dependency ------------------------------
context = temporal_context(series=series, patterns=patterns,
                           integrity_status=IntegrityStatus.DRIFT.value,
                           behaviour_status=BaselineStatus.UNEXPECTED.value)
check(context["integrity_status"] == IntegrityStatus.DRIFT.value,
      "temporal context preserves the integrity status")
check(context["behaviour_status"] == BaselineStatus.UNEXPECTED.value,
      "temporal context preserves the behaviour status")
check(context["recurrence"] == series.recurrence,
      "temporal context reports observed recurrence")
check("first_seen" in context and "last_seen" in context,
      "temporal context reports when this was first and last seen")
check(isinstance(context["explanation"], str) and context["explanation"],
      "temporal context explains itself")
check("advisory" in json.dumps(context).lower(),
      "temporal context states it is advisory")
check(context == temporal_context(series=series, patterns=patterns,
                                  integrity_status=IntegrityStatus.DRIFT.value,
                                  behaviour_status=BaselineStatus.UNEXPECTED.value),
      "temporal context is deterministic")

# A recurring drift is materially different from a first-time one, and the
# context must say which without predicting anything.
check("recurr" in context["explanation"].lower() or "seen" in context["explanation"].lower(),
      "temporal context distinguishes a repeat from a first occurrence")

# --- Frequency-weighting hook, unused in this release ---------------------
# The architecture must allow a future release to weight behaviour by
# occurrence frequency without breaking compatibility. The hook exists and is
# explicitly inert here.
check("frequency_per_day" in series.to_dict(),
      "a series exposes observed frequency for future weighting")
check(context.get("frequency_weighting") == "not-applied",
      "frequency weighting is available but explicitly not applied in v0.8.6")

# --- Secrets never reach an occurrence record -----------------------------
secret = record_occurrence(occurrence_id="OCC-000999", target=TARGET,
                           kind="service-restart",
                           occurred_at=hours_ago(1),
                           source="EVID-000001", recorded_at=NOW,
                           detail=f"https://user:{CANARY}@host/x")
blob = json.dumps(secret.to_dict(), default=str)
check(CANARY not in blob, "no secret value appears in an occurrence record")

# --- platform-model is never modified -------------------------------------
model_before = sorted((str(p.relative_to(root)), p.stat().st_size)
                      for p in (root / "platform-model").rglob("*") if p.is_file())
build_series(regular, series_id="SERIES-000009", generated_at=NOW, target=TARGET, kind=KIND)
detect_patterns(series, pattern_id_prefix="PAT", generated_at=NOW)
build_timeline(mixed, timeline_id="TL-000009", generated_at=NOW, target=TARGET)
model_after = sorted((str(p.relative_to(root)), p.stat().st_size)
                     for p in (root / "platform-model").rglob("*") if p.is_file())
check(model_before == model_after, "the occurrence engine never modifies platform-model")

# --- CLI --------------------------------------------------------------------
import subprocess  # noqa: E402 - the harness runs the CLI as a child


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.occurrence.cli", *args],
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
for command in ("record", "series", "patterns", "timeline"):
    check(command in command_names, f"cli exposes the {command} command")
for forbidden in ("predict", "forecast", "delete", "remediate", "update"):
    check(forbidden not in command_names, f"cli exposes no {forbidden} command")

# Store roots are explicit: a default is a production path awaiting a write.
cli("series", "--target", TARGET, "--kind", KIND, expect=2)

with tempfile.TemporaryDirectory() as tmp:
    evidence_root = str(Path(tmp) / "evidence-store")
    store_root = str(Path(tmp) / "occurrence-store")
    ev = EvidenceStore(Path(evidence_root))
    orch = Orchestrator(ev)
    for offset, value in ((6, "1"), (4, "2"), (2, "3")):
        stamp = hours_ago(offset)
        orch.process_collector_result(
            CollectorResult(collector_id="host-metrics", target=TARGET, status="success",
                            started_at=stamp, completed_at=stamp,
                            observations=[CObs(fact="restart_count", value=value,
                                               value_type="string", collected_at=stamp,
                                               source="host-metrics")],
                            errors=[]),
            evaluated_at=stamp)

    recorded = cli("record", "--target", TARGET, "--kind", "observation",
                   "--generated-at", NOW, "--evidence-root", evidence_root,
                   "--store-root", store_root, expect=0)
    check("OCC-" in recorded.stdout, "cli record reports occurrence identifiers")

    series_out = cli("series", "--target", TARGET, "--kind", "observation",
                     "--generated-at", NOW, "--evidence-root", evidence_root,
                     "--store-root", store_root, expect=0)
    series_payload = json.loads(series_out.stdout)
    check(series_payload.get("count") == 3, "cli series reports the occurrence count")
    check("first_seen" in series_payload and "last_seen" in series_payload,
          "cli series reports first and last seen")

    patterns_out = cli("patterns", "--target", TARGET, "--kind", "observation",
                       "--generated-at", NOW, "--evidence-root", evidence_root,
                       "--store-root", store_root, expect=0)
    json.loads(patterns_out.stdout)
    ok("cli patterns emits parseable JSON")

    timeline_out = cli("timeline", "--target", TARGET, "--kind", "observation",
                       "--generated-at", NOW, "--evidence-root", evidence_root,
                       "--store-root", store_root, expect=0)
    timeline_payload = json.loads(timeline_out.stdout)
    check(timeline_payload.get("entry_count") == 3, "cli timeline reports entry count")

    repeat = cli("timeline", "--target", TARGET, "--kind", "observation",
                 "--generated-at", NOW, "--evidence-root", evidence_root,
                 "--store-root", store_root)
    check(repeat.stdout == timeline_out.stdout, "cli timeline output is deterministic")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "occurrence timeline behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for the occurrence timeline tests.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nOccurrence timeline validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nOccurrence timeline validation passed.\n'
