"""Compare a digital twin against an immutable snapshot.

Deterministic and read-only. It reads two records and returns a report; it
writes nothing and changes nothing.

The classification exists to keep four different situations distinguishable:

- ``MATCH``                  every comparable fact agrees
- ``PARTIAL``                some agree, some differ
- ``DRIFT``                  every comparable fact differs
- ``UNKNOWN``                nothing could be compared, because the snapshot
                             and twin describe different facts
- ``INSUFFICIENT_EVIDENCE``  the twin holds no facts at all

The last two are the important ones. Reporting "we could not tell" as DRIFT
produces a false alarm on every gap in coverage, and an operator who has been
paged for a coverage gap three times stops reading drift reports. Keeping them
separate is what makes a DRIFT report worth acting on.
"""

from __future__ import annotations

from typing import Any, Mapping

from .confidence import (
    compute_integrity_confidence,
    coverage_score,
    freshness_score,
)
from .models import (
    ID_PATTERNS,
    field_of,
    DigitalTwin,
    IntegrityReport,
    IntegrityStatus,
    SnapshotRecord,
    require_timezone,
)


class AnalysisError(Exception):
    """A comparison could not be performed. Never contains a fact value."""


def _as_facts(record: Any) -> dict[str, Any]:
    return dict(field_of(record, "facts", {}) or {})


def _identifier(record: Any) -> str:
    return str(field_of(record, "id", "") or "")


def analyze_integrity(*, snapshot: SnapshotRecord | Mapping[str, Any],
                      twin: DigitalTwin | Mapping[str, Any],
                      evaluated_at: str, report_id: str) -> IntegrityReport:
    """Compare a twin against a snapshot and classify the result."""
    if snapshot is None or twin is None:
        raise AnalysisError("both a snapshot and a twin are required")

    pattern = ID_PATTERNS["integrity"]
    if not pattern.match(str(report_id)):
        raise AnalysisError(f"integrity report identifier '{report_id}' is not valid")

    stamp = require_timezone(evaluated_at, "evaluated_at")

    snapshot_facts = _as_facts(snapshot)
    twin_facts = _as_facts(twin)
    snapshot_id = _identifier(snapshot)
    twin_id = _identifier(twin)
    target = str(field_of(snapshot, "target", "") or "")

    comparable = sorted(set(snapshot_facts) & set(twin_facts))
    matched: list[str] = []
    differences: list[dict[str, Any]] = []

    for name in comparable:
        if str(snapshot_facts[name]) == str(twin_facts[name]):
            matched.append(name)
        else:
            differences.append({
                "fact": name,
                "snapshot_value": snapshot_facts[name],
                "twin_value": twin_facts[name],
            })

    # Facts one side holds and the other does not. These are not differences —
    # nothing was compared — so they are reported separately.
    uncomparable = sorted(set(snapshot_facts) ^ set(twin_facts))

    freshness = str(field_of(twin, "knowledge_freshness", "unknown") or "unknown")
    knowledge_confidence = field_of(twin, "knowledge_confidence", None)
    fingerprint = str(field_of(snapshot, "content_fingerprint", "") or "")

    # --- classify ----------------------------------------------------------
    if not twin_facts:
        status = IntegrityStatus.INSUFFICIENT_EVIDENCE.value
        explanation = (
            f"The twin for {target} holds no facts, so nothing could be compared "
            f"against snapshot {snapshot_id}. This is an absence of evidence, not "
            "a detected change."
        )
    elif not comparable:
        status = IntegrityStatus.UNKNOWN.value
        explanation = (
            f"Snapshot {snapshot_id} and twin {twin_id} share no facts, so the "
            "comparison is undetermined. Nothing here indicates a change."
        )
    elif not differences:
        status = IntegrityStatus.MATCH.value
        explanation = (
            f"All {len(matched)} comparable fact(s) in twin {twin_id} agree with "
            f"snapshot {snapshot_id}."
        )
    elif not matched:
        status = IntegrityStatus.DRIFT.value
        explanation = (
            f"Every comparable fact ({len(differences)}) differs between snapshot "
            f"{snapshot_id} and twin {twin_id}. Advisory only; no action has been taken."
        )
    else:
        status = IntegrityStatus.PARTIAL.value
        explanation = (
            f"{len(matched)} fact(s) agree and {len(differences)} differ between "
            f"snapshot {snapshot_id} and twin {twin_id}. Advisory only; no action "
            "has been taken."
        )

    determinate = status in {IntegrityStatus.MATCH.value,
                             IntegrityStatus.PARTIAL.value,
                             IntegrityStatus.DRIFT.value}

    confidence = compute_integrity_confidence(
        {
            "coverage": coverage_score(len(comparable), len(snapshot_facts)),
            "knowledge_freshness": freshness_score(freshness),
            "knowledge_confidence": float(knowledge_confidence)
            if isinstance(knowledge_confidence, (int, float)) else 0.0,
            "snapshot_integrity": 1.0 if fingerprint.startswith("sha256:") else 0.0,
            "determinacy": 1.0 if determinate else 0.0,
        },
        reasons={
            "coverage": f"{len(comparable)} of {len(snapshot_facts)} snapshot fact(s) were comparable.",
            "knowledge_freshness": f"Twin knowledge freshness is '{freshness}'.",
            "determinacy": f"Comparison result is '{status}'.",
        },
    )

    if uncomparable:
        explanation += (
            f" {len(uncomparable)} fact(s) existed on only one side and were not"
            " compared."
        )

    return IntegrityReport(
        id=report_id,
        target=target,
        evaluated_at=stamp,
        snapshot=(snapshot_id,) if snapshot_id else (),
        twin=(twin_id,) if twin_id else (),
        status=status,
        confidence=confidence,
        differences=tuple(differences),
        matched_facts=tuple(matched),
        uncomparable_facts=tuple(uncomparable),
        explanation=explanation,
        # Anything other than a clean match warrants a human read. The bias is
        # deliberate: a needless review costs minutes, a missed drift costs more.
        review_required=status != IntegrityStatus.MATCH.value,
    )
