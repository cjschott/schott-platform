"""Produce a human-readable reconstruction strategy.

This module recommends. It does not recover.

Every step is prose written for a person to read and decide on. There is
deliberately no command field, no script, no ordering primitive an executor
could consume, and no method that runs anything. That is not an oversight to be
fixed later: a structured, machine-readable action is one scheduler away from
being executed, and the moment this engine can act on its own conclusions, a
wrong conclusion becomes an outage rather than a bad suggestion.

The plan names what differs, what the snapshot recorded, and what a human might
consider. Deciding whether any of it is correct remains a human judgement.
"""

from __future__ import annotations

from typing import Any, Mapping

from .models import (
    ID_PATTERNS,
    field_of,
    IntegrityReport,
    IntegrityStatus,
    RecoveryPlan,
    RecoveryStatus,
    SnapshotRecord,
    require_timezone,
)


class PlanningError(Exception):
    """A plan could not be produced. Never contains a fact value."""


def _identifier(record: Any) -> str:
    return str(field_of(record, "id", "") or "")


def plan_recovery(*, report: IntegrityReport | Mapping[str, Any],
                  snapshot: SnapshotRecord | Mapping[str, Any],
                  plan_id: str, created_at: str) -> RecoveryPlan:
    """Return an advisory reconstruction strategy for an integrity report."""
    if report is None or snapshot is None:
        raise PlanningError("both an integrity report and a snapshot are required")

    pattern = ID_PATTERNS["recovery"]
    if not pattern.match(str(plan_id)):
        raise PlanningError(f"recovery plan identifier '{plan_id}' is not valid")

    stamp = require_timezone(created_at, "created_at")

    status = str(field_of(report, "status", "") or "")
    target = str(field_of(report, "target", "") or "")
    report_id = _identifier(report)
    snapshot_id = _identifier(snapshot)
    snapshot_label = str(field_of(snapshot, "label", "") or "")
    snapshot_created = str(field_of(snapshot, "created_at", "") or "")

    differences = list(field_of(report, "differences", ()) or ())
    confidence = field_of(report, "confidence", None)

    steps: list[dict[str, Any]] = []
    risks: list[str] = []

    if status == IntegrityStatus.MATCH.value:
        plan_status = RecoveryStatus.NO_ACTION_REQUIRED.value
        summary = (
            f"Twin matches snapshot {snapshot_id} for {target}. Nothing to reconstruct."
        )

    elif status == IntegrityStatus.INSUFFICIENT_EVIDENCE.value:
        plan_status = RecoveryStatus.INSUFFICIENT_EVIDENCE.value
        summary = (
            f"No reconstruction can be recommended for {target}: the twin held no "
            "facts, so nothing is known about the current state."
        )
        steps.append({
            "order": 1,
            "description": (
                "Collect fresh evidence for this target and rebuild the twin before "
                "drawing any conclusion. The absence of evidence is not a finding "
                "about the target."
            ),
        })
        risks.append(
            "Acting on this report would mean acting on no information at all."
        )

    elif status == IntegrityStatus.UNKNOWN.value:
        plan_status = RecoveryStatus.REVIEW_RECOMMENDED.value
        summary = (
            f"Snapshot {snapshot_id} and the current twin describe different facts "
            f"for {target}, so no comparison was possible."
        )
        steps.append({
            "order": 1,
            "description": (
                "Review whether the snapshot is still an appropriate reference for "
                "this target, or whether a newer snapshot should be taken from a "
                "state a human has confirmed is good."
            ),
        })
        risks.append(
            "A snapshot describing different facts may simply be out of date rather "
            "than indicating a problem."
        )

    else:
        # PARTIAL or DRIFT: there is something concrete to describe.
        plan_status = RecoveryStatus.RECONSTRUCTION_RECOMMENDED.value
        summary = (
            f"{len(differences)} fact(s) differ from snapshot {snapshot_id}"
            f"{f' ({snapshot_label})' if snapshot_label else ''} for {target}. "
            "The following is advisory and requires human approval."
        )
        steps.append({
            "order": 1,
            "description": (
                "Confirm the snapshot is a state a human agreed was good. A snapshot "
                f"taken at {snapshot_created} records what was observed then, not "
                "what ought to be true now."
            ),
        })
        steps.append({
            "order": 2,
            "description": (
                "Determine whether each difference below is an intended change or an "
                "unintended one. An intended change means the snapshot is stale and a "
                "new one should be taken; it does not mean anything should be reverted."
            ),
        })
        for index, difference in enumerate(differences, start=3):
            fact = str(difference.get("fact"))
            steps.append({
                "order": index,
                "description": (
                    f"Fact '{fact}': the snapshot recorded '{difference.get('snapshot_value')}' "
                    f"and the current twin reports '{difference.get('twin_value')}'. "
                    "Decide which is correct before changing anything."
                ),
            })
        steps.append({
            "order": len(differences) + 3,
            "description": (
                "If reconstruction is agreed, carry it out through the platform's "
                "normal change process with its usual review and rollback. This plan "
                "is not a change process and performs no part of one."
            ),
        })
        risks.extend([
            "A snapshot is a record of a past observation, not an authority on what "
            "the platform should be.",
            "Reverting an intended change is itself an incident; confirm intent "
            "before acting on any difference.",
        ])

    if status != IntegrityStatus.MATCH.value:
        risks.append(
            "This plan is advisory. Nothing here has been executed, and this engine "
            "has no mechanism to execute it."
        )

    return RecoveryPlan(
        id=plan_id,
        target=target,
        created_at=stamp,
        integrity_report=(report_id,) if report_id else (),
        target_snapshot=(snapshot_id,) if snapshot_id else (),
        status=plan_status,
        summary=summary,
        steps=tuple(steps),
        risks=tuple(risks),
        confidence=confidence if confidence is not None else None,
        advisory_only=True,
        approval_required=True,
    )
