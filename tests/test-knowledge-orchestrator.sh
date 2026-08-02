#!/usr/bin/env bash
set -Eeuo pipefail

# Behavioural and static validation for the knowledge orchestrator.
#
# Behavioural tests are the primary safety evidence: they build temporary store
# roots and assert what the orchestrator actually does with real inputs. Static
# greps are a secondary net, because a grep can be evaded and a behavioural
# assertion is much harder to satisfy accidentally.
#
# This script contacts no host, uses no SSH, inspects no running container,
# calls no Docker runtime API, and writes nothing into the repository. Every
# store root it creates lives in a temporary directory and is removed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS="tools/observation"
FAILURES=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_file() {
  if [[ -f "${ROOT}/$1" ]]; then pass "file exists: $1"; else fail "required file missing: $1"; fi
}

assert_dir() {
  if [[ -d "${ROOT}/$1" ]]; then pass "directory exists: $1"; else fail "required directory missing: $1"; fi
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
for module in __init__ models orchestrator evidence_builder evidence_store \
              deduplicator verifier drift_engine confidence timeline knowledge cli; do
  assert_file "${OBS}/${module}.py"
done

# --- Required documents ----------------------------------------------------
assert_file "docs/decisions/ADR-0004-immutable-knowledge-timeline.md"
assert_file "docs/standards/knowledge-event-standard.md"
assert_file "docs/standards/confidence-freshness-standard.md"
for doc in overview evidence-store timeline confidence-and-freshness knowledge-state; do
  assert_file "docs/observation/${doc}.md"
done

# --- Required schemas and model directories --------------------------------
assert_file "platform-model/schemas/observation.schema.yaml"
assert_file "platform-model/schemas/knowledge-event.schema.yaml"
assert_file "platform-model/schemas/knowledge-state.schema.yaml"
assert_file "platform-model/knowledge-events/README.md"
assert_file "platform-model/observations/README.md"
assert_dir "platform-model/knowledge-events"
assert_dir "platform-model/observations"

# --- Six-digit identifier widths -------------------------------------------
assert_contains "platform-model/schemas/evidence.schema.yaml" \
  "EVID-\[0-9\]\{6\}" "evidence schema uses six-digit identifiers"
assert_contains "platform-model/schemas/verification.schema.yaml" \
  "VER-\[0-9\]\{6\}" "verification schema uses six-digit identifiers"
assert_contains "platform-model/schemas/knowledge-event.schema.yaml" \
  "MEM-\[0-9\]\{6\}" "knowledge event schema uses six-digit identifiers"

# Four-digit identifiers that must NOT be widened.
assert_contains "platform-model/schemas/capability.schema.yaml" \
  "CAP-\[0-9\]\{4\}" "capability identifiers remain four digits"
assert_contains "platform-model/schemas/drift-rule.schema.yaml" \
  "DRIFT-\[0-9\]\{4\}" "drift-rule identifiers remain four digits"

# --- Static safety ---------------------------------------------------------
# The observation package is pure computation over local files. It has no
# reason to open a socket, run a command, or reach a host.
assert_absent_in "${OBS}" \
  '(import[[:space:]]+(socket|requests|urllib|http\.client|paramiko|ftplib|telnetlib|smtplib)|from[[:space:]]+(socket|requests|urllib|paramiko|http)[[:space:]]+import)' \
  "no observation code imports a network or SSH module"
assert_absent_in "${OBS}" \
  '(import[[:space:]]+subprocess|from[[:space:]]+subprocess[[:space:]]+import|subprocess\.[a-zA-Z_]|os\.system\(|os\.popen\()' \
  "no observation code executes a subprocess"
assert_absent_in "${OBS}" '(ssh|scp|sftp|rsync)[[:space:]]' \
  "no observation code references an SSH transport"
assert_absent_in "${OBS}" \
  '(docker[[:space:]]+(ps|inspect|exec|run|start|stop|rm|logs)\b|compose[[:space:]]+(up|down|pull|build|run|exec)\b)' \
  "no observation code invokes a Docker runtime verb"
assert_absent_in "${OBS}" "['\"][^'\"]*ai/\\.env['\"]" \
  "no observation code references ai/.env"

# Immutability: no update and no delete API exists in v0.7.0.
assert_absent_in "${OBS}" \
  '(def[[:space:]]+(delete|remove|purge|update|overwrite|edit)_(evidence|verification|event|record))' \
  "no evidence delete or update method exists"
assert_absent_in "${OBS}" '(shutil\.rmtree|os\.remove\(|os\.removedirs\()' \
  "no observation code removes a directory tree or an arbitrary path"

# Temp-file cleanup during an atomic write is legitimate; deleting a persisted
# record is not. Rather than exempting a whole file, require every deletion
# call site to be annotated as temp cleanup, so a record deletion cannot be
# added without also removing the annotation.
undeclared_unlinks="$(grep -rInE '\.unlink\(' "${ROOT}/${OBS}" | grep -viE 'temp' || true)"
if [[ -z "${undeclared_unlinks}" ]]; then
  pass "every deletion call site is temp-file cleanup, never record deletion"
else
  fail "deletion outside temp-file cleanup: $(printf '%s' "${undeclared_unlinks}" | head -2 | tr '\n' ' ')"
fi

# No remediation anywhere in the package.
assert_absent_in "${OBS}" \
  '(def[[:space:]]+remediate|\.remediate\(|remediation_command|auto_remediate|apply_fix|def[[:space:]]+repair)' \
  "no observation code contains a remediation path"

# The orchestrator must never run a collector: that would merge two trust
# boundaries the architecture deliberately separates.
assert_absent_in "${OBS}" \
  '(from[[:space:]]+tools\.collectors\.registry|build_default_registry|\.execute\(context)' \
  "orchestrator never executes a collector"

# platform-model is read-only to this package.
assert_absent_in "${OBS}" \
  "(open\\(['\"][^'\"]*platform-model[^'\"]*['\"],[[:space:]]*['\"][wax]|platform-model[^'\"]*['\"]\\)\\.write_text)" \
  "no observation code writes into platform-model"

# --- Generated runtime records must never be committed ---------------------
if git -C "${ROOT}" ls-files 'platform-model/evidence/EVID-*' 'platform-model/verifications/VER-*' \
     'platform-model/knowledge-events/MEM-*' 'platform-model/observations/OBS-*' | grep -q .; then
  fail "generated runtime records must not be committed under platform-model"
else
  pass "no generated runtime records are committed under platform-model"
fi

# --- CI wiring -------------------------------------------------------------
assert_contains ".github/workflows/ci.yml" 'bash tests/test-knowledge-orchestrator\.sh' \
  "ci runs the knowledge orchestrator tests"

# --- Behavioural validation ------------------------------------------------
if python3 -c 'import yaml' >/dev/null 2>&1; then
  PY_OUTPUT="$(python3 - "${ROOT}" <<'PY' 2>&1 || true
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
os.chdir(root)

failures = 0
CANARY = "CANARY-SECRET-MUST-NOT-APPEAR-7b2e"


def ok(message):
    print(f"PASS: {message}")


def bad(message):
    global failures
    failures += 1
    print(f"FAIL: {message}")


def check(condition, message):
    ok(message) if condition else bad(message)


try:
    from tools.collectors.models import CollectorError, CollectorResult, Observation as CObs
    from tools.observation.models import (
        ConfidenceExplanation, DriftAssessment, EvidenceRecord, FreshnessAssessment,
        KnowledgeEvent, KnowledgeState, Observation, OrchestrationResult, VerificationRecord,
        EventType, FreshnessState,
    )
    from tools.observation.evidence_store import EvidenceStore, StoreError
    from tools.observation.evidence_builder import build_observation, build_evidence_record
    from tools.observation.deduplicator import duplicate_scope, find_duplicate
    from tools.observation.confidence import (
        FACTOR_WEIGHTS, assess_freshness, compute_confidence,
    )
    from tools.observation.verifier import verify
    from tools.observation.drift_engine import assess_drift
    from tools.observation.timeline import Timeline
    from tools.observation.knowledge import build_knowledge_state
    from tools.observation.orchestrator import Orchestrator
    ok("observation modules import cleanly")
except Exception as error:  # noqa: BLE001
    bad(f"observation import failed: {type(error).__name__}: {error}")
    print(f"__FAILURES__={failures}")
    raise SystemExit(0)

STAMP = "2026-08-01T09:00:00-05:00"
LATER = "2026-08-01T10:00:00-05:00"


def result(facts, *, target="REPO-0001", collector="git-repository",
           status="success", collected=STAMP, errors=()):
    return CollectorResult(
        collector_id=collector,
        target=target,
        status=status,
        started_at=collected,
        completed_at=collected,
        observations=[
            CObs(fact=k, value=v, value_type="string", collected_at=collected,
                 source=collector)
            for k, v in sorted(facts.items())
        ],
        errors=list(errors),
    )


def store_in(tmp, **kwargs):
    return EvidenceStore(Path(tmp) / "store", **kwargs)


# --- Evidence persistence --------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)

    first = orch.process_collector_result(result({"branch": "main"}))
    check(first.evidence is not None and first.evidence.id == "EVID-000001",
          "first observation creates EVID-000001")
    check(first.evidence.id.count("0") >= 5 and len(first.evidence.id) == len("EVID-000001"),
          "evidence identifiers use six digits")

    second = orch.process_collector_result(result({"branch": "develop"}))
    check(second.evidence is not None and second.evidence.id == "EVID-000002",
          "second distinct observation creates EVID-000002")

    dup = orch.process_collector_result(result({"branch": "develop"}, collected=LATER))
    check(dup.evidence is None and dup.duplicate_of == "EVID-000002",
          "duplicate observation does not create new evidence")
    check(any(e.event_type == "evidence-refreshed" for e in dup.events),
          "duplicate creates an evidence-refreshed event")

    ids = [p.name for p in (Path(tmp) / "store" / "evidence").glob("EVID-*.yaml")]
    check(sorted(ids) == ["EVID-000001.yaml", "EVID-000002.yaml"],
          "evidence filenames match identifiers")

    # Immutability: writing an existing record must be refused outright.
    try:
        store.write_evidence(first.evidence)
        bad("existing evidence cannot be overwritten")
    except StoreError:
        ok("existing evidence cannot be overwritten")

    # The refused overwrite must not have altered the stored bytes.
    payload = (Path(tmp) / "store" / "evidence" / "EVID-000001.yaml").read_text()
    check("EVID-000001" in payload and "branch" in payload,
          "refused overwrite leaves the original record intact")

    # No partial artefacts survive a completed write.
    leftovers = [p.name for p in (Path(tmp) / "store" / "evidence").iterdir()
                 if not p.name.endswith(".yaml")]
    check(not leftovers, "no partial or temporary files are left behind")

    mode = stat.S_IMODE((Path(tmp) / "store" / "evidence" / "EVID-000001.yaml").stat().st_mode)
    check(mode & 0o077 == 0, "evidence files carry restrictive permissions")

# Sequence allocation: rapid successive allocations never collide, and an
# existing sequence is continued rather than restarted.
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    allocated = [store.allocate_id("evidence") for _ in range(50)]
    check(len(set(allocated)) == 50, "rapid allocations return unique identifiers")
    check(allocated[0] == "EVID-000001" and allocated[-1] == "EVID-000050",
          "sequence allocation is monotonic")

    reopened = store_in(tmp)
    check(reopened.allocate_id("evidence") == "EVID-000051",
          "an existing sequence is continued, not restarted")

    # A pre-existing file at the next identifier must not be clobbered: the
    # allocator has to skip it rather than assume the sequence owns the name.
    (Path(tmp) / "store" / "evidence" / "EVID-000052.yaml").write_text("placeholder\n")
    nxt = reopened.allocate_id("evidence")
    check(nxt != "EVID-000052", "sequence collision with an existing file is skipped")
    check((Path(tmp) / "store" / "evidence" / "EVID-000052.yaml").read_text() == "placeholder\n",
          "collision handling never overwrites the colliding file")

# Store roots must be explicit and must never be the repository.
with tempfile.TemporaryDirectory() as tmp:
    for bad_root, label in ((root, "repository root"),
                            (root / "platform-model", "platform-model")):
        try:
            EvidenceStore(bad_root)
            bad(f"store refuses {label} as a store root")
        except StoreError:
            ok(f"store refuses {label} as a store root")
    # Opt-in is exercised against a synthetic repository, never the real one:
    # constructing a store creates directories, and a test that pointed at
    # platform-model would scatter them through tracked source on every run.
    synthetic = Path(tmp) / "synthetic-repo"
    (synthetic / ".git").mkdir(parents=True)
    try:
        EvidenceStore(synthetic / "store", allow_repository_root=True)
        ok("a test fixture may explicitly opt in to a repository path")
    except StoreError:
        bad("a test fixture may explicitly opt in to a repository path")
    try:
        EvidenceStore(synthetic / "store")
        bad("a repository path is refused without the explicit opt-in")
    except StoreError:
        ok("a repository path is refused without the explicit opt-in")

# --- Deduplication ---------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    orch.process_collector_result(result({"branch": "main"}))

    other_collector = orch.process_collector_result(
        result({"branch": "main"}, collector="configuration-render"))
    check(other_collector.evidence is not None,
          "the same facts from a different collector create independent evidence")

    other_target = orch.process_collector_result(result({"branch": "main"}, target="SVC-0001"))
    check(other_target.evidence is not None,
          "the same facts for a different target create independent evidence")

    failed = orch.process_collector_result(
        result({"branch": "main"}, status="failed",
               errors=[CollectorError(category="unreachable", summary="source unavailable")]))
    check(failed.evidence is not None,
          "a failed result is not a duplicate of a successful one")

    # Deduplication must not key on time alone.
    same = orch.process_collector_result(result({"branch": "main"}, collected=LATER))
    check(same.evidence is None, "a later timestamp alone does not create new evidence")

# --- Confidence and freshness ----------------------------------------------
check(abs(sum(FACTOR_WEIGHTS.values()) - 1.0) < 1e-9, "confidence weights total 1.0")
check(set(FACTOR_WEIGHTS) == {"source_reliability", "freshness", "verification",
                              "source_agreement", "completeness"},
      "confidence uses exactly the five documented factors")

explanation = compute_confidence({
    "source_reliability": 0.8, "freshness": 1.0, "verification": 1.0,
    "source_agreement": 1.0, "completeness": 1.0,
})
check(isinstance(explanation, ConfidenceExplanation), "confidence returns an explanation")
check(0.0 <= explanation.overall <= 1.0, "confidence is bounded between 0 and 1")
check(all(0.0 <= v <= 1.0 for v in explanation.factors.values()),
      "every confidence factor is bounded between 0 and 1")
check(set(explanation.weights) == set(FACTOR_WEIGHTS),
      "the explanation lists every factor and its weight")
check(compute_confidence({k: 0.5 for k in FACTOR_WEIGHTS}).overall ==
      compute_confidence({k: 0.5 for k in FACTOR_WEIGHTS}).overall,
      "confidence is deterministic")

try:
    compute_confidence({"source_reliability": 1.4, "freshness": 1.0, "verification": 1.0,
                        "source_agreement": 1.0, "completeness": 1.0})
    bad("out-of-range factor values are rejected")
except ValueError:
    ok("out-of-range factor values are rejected")

fresh = assess_freshness(newest_collected_at=STAMP, generated_at=STAMP,
                         max_age_seconds=3600)
check(fresh.state == "current", "recent evidence is current")
stale = assess_freshness(newest_collected_at=STAMP,
                         generated_at="2026-08-05T09:00:00-05:00", max_age_seconds=3600)
check(stale.state == "stale", "old evidence is stale")
check(stale.factor_score < fresh.factor_score, "stale evidence lowers the freshness factor")
unknown = assess_freshness(newest_collected_at=STAMP, generated_at=LATER, max_age_seconds=None)
check(unknown.state == "unknown" and unknown.review_required,
      "a null freshness policy produces unknown and requires review")
missing = assess_freshness(newest_collected_at=None, generated_at=STAMP, max_age_seconds=3600)
check(missing.state == "unknown" and missing.review_required,
      "absent evidence produces unknown freshness, not stale")
check(assess_freshness(newest_collected_at=STAMP, generated_at=LATER,
                       max_age_seconds=3600).age_seconds == 3600,
      "knowledge age is elapsed time from the newest supporting evidence")

# A human attestation on its own must not reach the top of the scale.
attested = compute_confidence({
    "source_reliability": 0.5, "freshness": 1.0, "verification": 0.0,
    "source_agreement": 0.5, "completeness": 1.0,
})
check(attested.overall < 0.9, "manual attestation alone cannot produce maximum confidence")

# --- Verification ----------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    declared = {"id": "REPO-0001", "branch": "main"}
    rules = [{"id": "DRIFT-0001", "fact": "branch", "declared_field": "branch",
              "severity": "medium", "max_age_seconds": 86400}]

    good = orch.process_collector_result(result({"branch": "main"}),
                                         declared=declared, rules=rules,
                                         evaluated_at=STAMP)
    check(good.verification is not None and good.verification.id == "VER-000001",
          "verification identifiers use six digits starting at VER-000001")
    check(good.verification.state == "verified" and good.verification.result == "match",
          "matching evidence produces a verified match")
    check(good.evidence.id in good.verification.evidence,
          "verification references its supporting evidence identifier")
    check(good.evidence.id in good.verification.explanation,
          "the explanation names the supporting evidence identifier")

    mismatch = orch.process_collector_result(result({"branch": "hotfix"}),
                                             declared=declared, rules=rules,
                                             evaluated_at=STAMP)
    check(mismatch.verification.result == "mismatch" and mismatch.verification.state == "drift",
          "contradictory evidence produces drift")

    # No evidence at all is unknown, never drift.
    empty = verify(declared=declared, evidence_records=[], rules=rules,
                   evaluated_at=STAMP, verification_id="VER-000900")
    check(empty.state in {"unknown", "pending"} and empty.result == "missing_observation",
          "missing evidence produces unknown, not drift")

    # A failed collection is verified in a store of its own. Verification
    # considers every known record for a target, so mixing a failure into a
    # store that already holds successes would exercise the success path.
    with tempfile.TemporaryDirectory() as fail_tmp:
        fail_store = store_in(fail_tmp)
        failed = Orchestrator(fail_store).process_collector_result(
            result({"branch": "main"}, status="failed",
                   errors=[CollectorError(category="unreachable", summary="source unavailable")]),
            declared=declared, rules=rules, evaluated_at=STAMP)
        check(failed.verification.result == "collection_failure",
              "failed collection produces collection_failure")
        check(failed.verification.state != "drift",
              "collection failure is not reported as service failure")
        check(failed.evidence is not None,
              "a failed collection still produces evidence that it could not look")
        check(any(e.event_type == "collection-failed" for e in failed.events),
              "a failed collection records a collection-failed event")

    stale_rules = [dict(rules[0], max_age_seconds=1)]
    stale_v = verify(declared=declared,
                     evidence_records=[good.evidence], rules=stale_rules,
                     evaluated_at="2026-08-09T09:00:00-05:00",
                     verification_id="VER-000901")
    check(stale_v.state != "verified" and stale_v.result == "stale_evidence",
          "stale evidence cannot produce a verified state")

# --- Drift -----------------------------------------------------------------
declared = {"id": "REPO-0001", "branch": "main"}
rules = [{"id": "DRIFT-0001", "fact": "branch", "declared_field": "branch",
          "severity": "critical", "max_age_seconds": 86400}]
ev = build_evidence_record(
    build_observation(result({"branch": "hotfix"})), evidence_id="EVID-000777",
    persisted_at=STAMP)
drifts = assess_drift(declared=declared, evidence_records=[ev], rules=rules,
                      evaluated_at=STAMP)
check(len(drifts) == 1 and drifts[0].result == "mismatch", "drift engine reports mismatch")
check(drifts[0].approval_required, "critical drift findings require approval")
check("EVID-000777" in drifts[0].evidence, "drift results reference supporting evidence")
check(drifts[0].rule == "DRIFT-0001", "drift results reference the originating rule")
check(isinstance(drifts[0].recommended_action, str) and drifts[0].recommended_action,
      "drift results carry advisory prose only")

no_ev = assess_drift(declared=declared, evidence_records=[], rules=rules, evaluated_at=STAMP)
check(no_ev[0].result == "missing_observation", "missing evidence is not mismatch")
unsupported = assess_drift(declared=declared, evidence_records=[ev],
                           rules=[{"id": "DRIFT-0002", "fact": "nonexistent",
                                   "declared_field": "nonexistent", "severity": "low"}],
                           evaluated_at=STAMP)
check(unsupported[0].result in {"unsupported", "missing_observation"},
      "a rule with no matching fact is unsupported, not mismatch")
stale_drift = assess_drift(declared=declared, evidence_records=[ev],
                           rules=[dict(rules[0], max_age_seconds=1)],
                           evaluated_at="2026-08-09T09:00:00-05:00")
check(stale_drift[0].result == "stale_evidence", "stale evidence is not mismatch")

failed_ev = build_evidence_record(
    build_observation(result({"branch": "main"}, status="failed",
                             errors=[CollectorError(category="unreachable", summary="down")])),
    evidence_id="EVID-000778", persisted_at=STAMP)
fail_drift = assess_drift(declared=declared, evidence_records=[failed_ev], rules=rules,
                          evaluated_at=STAMP)
check(fail_drift[0].result == "collection_failure", "collection failure is its own result type")

# --- Evidence builder immutability -----------------------------------------
source = result({"branch": "main"})
before = json.dumps([[o.fact, o.value] for o in source.observations], sort_keys=True)
obs = build_observation(source)
record = build_evidence_record(obs, evidence_id="EVID-000999", persisted_at=STAMP)
after = json.dumps([[o.fact, o.value] for o in source.observations], sort_keys=True)
check(before == after, "CollectorResult is unchanged after orchestration")
check(source.content_fingerprint == "", "orchestration does not write back into the collector result")
check(record.provenance == "observed", "evidence provenance is observed")
check(record.type == "evidence", "evidence records declare their type")
check(record.content_fingerprint.startswith("sha256:"), "evidence fingerprints are sha256")
check(build_evidence_record(build_observation(result({"branch": "main"})),
                            evidence_id="EVID-000999",
                            persisted_at=STAMP).content_fingerprint ==
      record.content_fingerprint,
      "evidence fingerprints are deterministic")
check(build_observation(result({"branch": "other"})).source_fingerprint !=
      obs.source_fingerprint,
      "different content produces a different fingerprint")

# --- Timeline --------------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    orch.process_collector_result(result({"branch": "main"}))
    orch.process_collector_result(result({"branch": "main"}, collected=LATER))
    orch.process_collector_result(result({"branch": "next"}, collected=LATER))

    timeline = Timeline(store)
    events = timeline.query(target="REPO-0001")
    check(len(events) >= 3, "timeline preserves all historical events")
    check(events == sorted(events, key=lambda e: (e.occurred_at, e.id)),
          "timeline is ordered by occurred_at then identifier")
    check([e.id for e in Timeline(store).query(target="REPO-0001")] == [e.id for e in events],
          "repeated timeline queries return the same order")
    check(all(e.target == "REPO-0001" for e in events), "timeline queries filter by target")
    check(any(e.event_type == "evidence-created" for e in events),
          "timeline records evidence creation")
    check(any(e.event_type == "evidence-refreshed" for e in events),
          "timeline records a refresh for a duplicate observation")

    first_ids = [e.id for e in events]
    orch.process_collector_result(result({"branch": "final"}, collected=LATER))
    later_ids = [e.id for e in Timeline(store).query(target="REPO-0001")]
    check(later_ids[:len(first_ids)] == first_ids, "timeline is append-only")
    check(len(later_ids) > len(first_ids), "appending preserves earlier events")
    check(all(i.startswith("MEM-") and len(i) == len("MEM-000001") for i in later_ids),
          "knowledge event identifiers use six digits")

# --- Knowledge state -------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    declared = {"id": "REPO-0001", "branch": "main"}
    rules = [{"id": "DRIFT-0001", "fact": "branch", "declared_field": "branch",
              "severity": "medium", "max_age_seconds": 86400}]
    outcome = orch.process_collector_result(result({"branch": "main"}), declared=declared,
                                            rules=rules, evaluated_at=STAMP)
    state = outcome.knowledge_state
    check(isinstance(state, KnowledgeState), "orchestration returns a derived knowledge state")
    check(state.newest_evidence_at == STAMP, "knowledge state reports the newest evidence time")
    check(state.knowledge_age_seconds is not None, "knowledge state reports knowledge age")
    check(state.freshness in {"current", "aging", "stale", "unknown"},
          "knowledge state reports an approved freshness state")
    check(0.0 <= state.confidence.overall <= 1.0, "knowledge state reports bounded confidence")
    check(outcome.evidence.id in state.supporting_evidence,
          "knowledge state references supporting evidence identifiers")
    check(state.verification_state == "verified", "knowledge state reports verification state")

    rebuilt = build_knowledge_state(target="REPO-0001", store=store, declared=declared,
                                    rules=rules, generated_at=STAMP)
    again = build_knowledge_state(target="REPO-0001", store=store, declared=declared,
                                  rules=rules, generated_at=STAMP)
    check(json.dumps(rebuilt.to_dict(), sort_keys=True) ==
          json.dumps(again.to_dict(), sort_keys=True),
          "knowledge state rebuilds deterministically")
    check(rebuilt.provenance_classes == {"declared": True, "observed": True, "inferred": True},
          "knowledge state keeps declared, observed, and inferred distinct")
    check(not list((Path(tmp) / "store" / "state").glob("*.yaml")),
          "knowledge state is not persisted as authoritative truth")

    conflict = orch.process_collector_result(
        result({"branch": "conflicting"}, collector="configuration-render"),
        declared=declared, rules=rules, evaluated_at=STAMP)
    conflicted = build_knowledge_state(target="REPO-0001", store=store, declared=declared,
                                       rules=rules, generated_at=STAMP)
    check(conflicted.conflicts, "knowledge state reports conflicting evidence")
    check(conflicted.drift_results, "knowledge state reports outstanding drift")
    check(conflicted.review_required, "conflicting evidence requires review")

# --- Orchestrator resilience -----------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    # A rule referencing a declared field that does not exist must not destroy
    # evidence that was already persisted.
    outcome = orch.process_collector_result(
        result({"branch": "main"}), declared={"id": "REPO-0001"},
        rules=[{"id": "DRIFT-0003", "fact": "branch", "declared_field": "absent",
                "severity": "low"}], evaluated_at=STAMP)
    check(outcome.evidence is not None, "evidence survives a verification that cannot conclude")
    check((Path(tmp) / "store" / "evidence" / f"{outcome.evidence.id}.yaml").is_file(),
          "persisted evidence is preserved when later stages cannot conclude")

    # Canonical entities are untouched by orchestration.
    declared_input = {"id": "REPO-0001", "branch": "main"}
    snapshot = json.dumps(declared_input, sort_keys=True)
    orch.process_collector_result(result({"branch": "other"}), declared=declared_input,
                                  rules=[], evaluated_at=STAMP)
    check(json.dumps(declared_input, sort_keys=True) == snapshot,
          "declared platform entities are never modified")

# --- Secret safety ---------------------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    store = store_in(tmp)
    orch = Orchestrator(store)
    outcome = orch.process_collector_result(
        result({"remote_url": f"https://user:{CANARY}@git.example.invalid/x.git",
                "note": f"token={CANARY}"}))
    blob = json.dumps(outcome.to_dict(), default=str)
    check(CANARY not in blob, "no secret value appears in an orchestration result")
    check(CANARY not in outcome.evidence.content_fingerprint,
          "no secret value reaches an evidence fingerprint")
    on_disk = "\n".join(p.read_text() for p in (Path(tmp) / "store").rglob("*.yaml"))
    check(CANARY not in on_disk, "no secret value is persisted to the store")
    idx = "\n".join(p.read_text() for p in (Path(tmp) / "store" / "indexes").rglob("*"))
    check(CANARY not in idx, "no secret value appears in an index")

    try:
        store.write_evidence(build_evidence_record(
            build_observation(result({"password": CANARY})),
            evidence_id="EVID-009999", persisted_at=STAMP))
        secret_blob = "\n".join(p.read_text() for p in (Path(tmp) / "store").rglob("*.yaml"))
        check(CANARY not in secret_blob, "a secret-bearing fact never reaches disk")
    except Exception as error:  # noqa: BLE001
        check(CANARY not in str(error), "rejection of a secret-bearing fact never echoes the value")

# --- CLI -------------------------------------------------------------------
import subprocess  # noqa: E402 - the test harness may run the CLI as a child


def cli(*args, expect=None):
    proc = subprocess.run([sys.executable, "-m", "tools.observation.cli", *args],
                          capture_output=True, text=True, cwd=str(root),
                          env={**os.environ, "PYTHONPATH": str(root)})
    if expect is not None:
        check(proc.returncode == expect,
              f"cli {args[0]} exits {expect} (got {proc.returncode})")
    return proc


with tempfile.TemporaryDirectory() as tmp:
    tmp_path = Path(tmp)
    store_root = tmp_path / "store"
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    payload = {
        "collector_id": "git-repository", "target": "REPO-0001", "status": "success",
        "started_at": STAMP, "completed_at": STAMP,
        "observations": [{"fact": "branch", "value": "main", "value_type": "string",
                          "collected_at": STAMP, "source": "git-repository"}],
        "errors": [],
    }
    (inbox / "result.json").write_text(json.dumps(payload), encoding="utf-8")

    proc = cli("ingest", "--collector-result", "result.json", "--input-dir", str(inbox),
               "--store-root", str(store_root), expect=0)
    check("EVID-000001" in proc.stdout, "cli ingest reports the allocated evidence identifier")

    dup_proc = cli("ingest", "--collector-result", "result.json", "--input-dir", str(inbox),
                   "--store-root", str(store_root), expect=0)
    check("evidence-refreshed" in dup_proc.stdout, "cli duplicate ingest reports a refresh")
    check("EVID-000002" not in dup_proc.stdout, "cli duplicate ingest creates no new evidence")

    tl = cli("timeline", "--target", "REPO-0001", "--store-root", str(store_root), expect=0)
    check("MEM-000001" in tl.stdout, "cli timeline lists knowledge events")

    kn = cli("knowledge", "--target", "REPO-0001", "--store-root", str(store_root), expect=0)
    parsed = json.loads(kn.stdout)
    check(parsed.get("target") == "REPO-0001", "cli knowledge emits JSON for the target")
    check("confidence" in parsed and "freshness" in parsed,
          "cli knowledge reports confidence and freshness")

    vs = cli("validate-store", "--store-root", str(store_root), expect=0)
    check("ok" in vs.stdout, "cli validate-store reports a healthy store")

    # Invocation errors exit 2, not 1.
    cli("ingest", "--collector-result", "missing.json", "--input-dir", str(inbox),
        "--store-root", str(store_root), expect=2)
    cli("timeline", "--target", "REPO-0001", expect=2)

    # Symlink escape must be refused.
    outside = tmp_path / "outside.json"
    outside.write_text(json.dumps(payload), encoding="utf-8")
    (inbox / "escape.json").symlink_to(outside)
    escape = cli("ingest", "--collector-result", "escape.json", "--input-dir", str(inbox),
                 "--store-root", str(store_root), expect=2)
    check("escape" in (escape.stderr + escape.stdout).lower(),
          "cli refuses a symlink escaping the approved input directory")

    # A traversal path is refused for the same reason.
    cli("ingest", "--collector-result", "../outside.json", "--input-dir", str(inbox),
        "--store-root", str(store_root), expect=2)

    help_proc = cli("--help")
    check("ingest" in help_proc.stdout and "timeline" in help_proc.stdout,
          "cli help lists the approved commands")
    for forbidden in ("delete", "remove", "remediate", "apply"):
        check(forbidden not in help_proc.stdout.lower().split("positional")[-1].split("options")[0],
              f"cli exposes no {forbidden} command")

    # platform-model must be untouched by any CLI run. Compared before and
    # after rather than against a clean tree, so an unrelated in-flight edit
    # cannot masquerade as a CLI side effect — or hide one.
    def model_snapshot():
        return sorted(
            (str(p.relative_to(root)), p.stat().st_size)
            for p in (root / "platform-model").rglob("*") if p.is_file()
        )

    before_model = model_snapshot()
    cli("timeline", "--target", "REPO-0001", "--store-root", str(store_root), expect=0)
    cli("knowledge", "--target", "REPO-0001", "--store-root", str(store_root), expect=0)
    cli("ingest", "--collector-result", "result.json", "--input-dir", str(inbox),
        "--store-root", str(store_root), expect=0)
    check(model_snapshot() == before_model, "cli runs leave platform-model unmodified")

print(f"__FAILURES__={failures}")
PY
)"
  printf '%s\n' "${PY_OUTPUT}" | grep -v '^__FAILURES__=' || true
  PY_FAILURES="$(printf '%s\n' "${PY_OUTPUT}" | sed -n 's/^__FAILURES__=//p' | tail -1)"
  if [[ -z "${PY_FAILURES}" ]]; then
    fail "knowledge orchestrator behavioural validation did not report a result"
  else
    FAILURES=$((FAILURES + PY_FAILURES))
  fi
else
  printf 'ERROR PyYAML is required for %s and is not importable.\n' "$(basename "${BASH_SOURCE[0]}")" >&2
  printf 'A skipped behavioural block must never report success, so this is a failure.\n' >&2
  printf 'Install the pinned version:\n\n' >&2
  printf '    python3 -m pip install --require-hashes -r requirements-ci.txt\n\n' >&2
  exit 1
fi

if [[ "${FAILURES}" -gt 0 ]]; then
  printf '\nKnowledge orchestrator validation failed with %d error(s).\n' "${FAILURES}" >&2
  exit 1
fi

printf '\nKnowledge orchestrator validation passed.\n'
