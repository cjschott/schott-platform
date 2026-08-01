"""Classify the difference between declared intent and observed evidence.

Produces DriftAssessment records and nothing else. It never edits a canonical
entity, never writes to the model, and has no remediation path — the closest
it comes to an action is a sentence of advisory prose for a human to read.

The result vocabulary exists so that four different situations stay
distinguishable instead of collapsing into "mismatch":

- `missing_observation` — nothing looked at this fact
- `stale_evidence` — something looked, but long ago
- `collection_failure` — something tried to look and could not
- `unsupported` — no rule can evaluate this

Collapsing any of these into `mismatch` produces false drift on every
collection outage, which trains operators to ignore drift reports entirely.
That is a worse failure than missing a real one.
"""

from __future__ import annotations

from typing import Any, Iterable

from .confidence import assess_freshness
from .models import (
    APPROVED_SEVERITIES,
    DriftAssessment,
    DriftResult,
    EvidenceRecord,
    FreshnessState,
    require_timezone,
)

ADVISORY_SUFFIX = "Advisory only; review before acting. No action has been taken."


def _as_dict(record: Any) -> dict[str, Any]:
    return record.to_dict() if isinstance(record, EvidenceRecord) else dict(record)


def assess_drift(*, declared: dict[str, Any], evidence_records: Iterable[Any],
                 rules: Iterable[dict[str, Any]], evaluated_at: str) -> list[DriftAssessment]:
    """Return one assessment per rule, in the order the rules were supplied."""
    stamp = require_timezone(evaluated_at, "evaluated_at")
    records = [_as_dict(r) for r in evidence_records]
    target = str((declared or {}).get("id") or (records[0].get("target") if records else "unknown"))

    assessments: list[DriftAssessment] = []
    for rule in rules:
        rule = dict(rule)
        rule_id = str(rule.get("id") or "UNKNOWN")
        fact_name = str(rule.get("fact") or "")
        declared_field = str(rule.get("declared_field") or fact_name)
        severity = str(rule.get("severity") or "medium")
        if severity not in APPROVED_SEVERITIES:
            severity = "medium"
        max_age = rule.get("max_age_seconds")

        relevant = [r for r in records if fact_name in (r.get("facts") or {})]
        failed = [r for r in records if str(r.get("status")) in {"failed", "unavailable"}]
        usable = [r for r in relevant if str(r.get("status")) not in {"failed", "unavailable"}]
        all_ids = tuple(str(r.get("id")) for r in records if r.get("id"))

        def make(result: str, explanation: str, evidence: tuple[str, ...],
                 approval: bool = False, sev: str = severity) -> DriftAssessment:
            return DriftAssessment(
                rule=rule_id,
                target=target,
                result=result,
                severity=sev,
                explanation=explanation,
                evidence=evidence,
                approval_required=approval,
                recommended_action=f"{explanation.split('.')[0]}. {ADVISORY_SUFFIX}",
            )

        # Order matters: a failed collection is reported as a failure even
        # when a rule would otherwise be unevaluable, because the collection
        # problem is the more actionable fact.
        if failed and not usable:
            ids = ", ".join(str(r.get("id")) for r in failed)
            assessments.append(make(
                DriftResult.COLLECTION_FAILURE.value,
                f"Collection failed for {target} (evidence: {ids}), so rule {rule_id} "
                "could not be evaluated. This describes the collection, not the target",
                tuple(str(r.get("id")) for r in failed),
                sev="medium",
            ))
            continue

        if declared_field not in (declared or {}):
            assessments.append(make(
                DriftResult.UNSUPPORTED.value,
                f"Rule {rule_id} references declared field '{declared_field}', which "
                f"{target} does not declare, so nothing can be concluded",
                all_ids,
                sev="info",
            ))
            continue

        if not usable:
            assessments.append(make(
                DriftResult.MISSING_OBSERVATION.value,
                f"No evidence reports '{fact_name}' for {target}, so rule {rule_id} has "
                "nothing to compare. Absence of observation is not a detected difference",
                all_ids,
                sev="info",
            ))
            continue

        supporting = tuple(str(r.get("id")) for r in usable if r.get("id"))
        newest = max(usable, key=lambda r: str(r.get("collected_at") or ""))
        freshness = assess_freshness(
            newest_collected_at=str(newest.get("collected_at")),
            generated_at=stamp,
            max_age_seconds=max_age,
        )

        if freshness.state == FreshnessState.STALE.value:
            assessments.append(make(
                DriftResult.STALE_EVIDENCE.value,
                f"Evidence for '{fact_name}' on {target} is {freshness.age_seconds}s old and "
                "exceeds its policy maximum, so it is too weak to conclude either way",
                supporting,
                sev="low",
            ))
            continue

        declared_value = (declared or {}).get(declared_field)
        observed = [r.get("facts", {}).get(fact_name) for r in usable]
        if all(str(v) == str(declared_value) for v in observed):
            assessments.append(make(
                DriftResult.MATCH.value,
                f"Observed '{fact_name}' matches declared '{declared_field}' on {target}",
                supporting,
                sev="info",
            ))
            continue

        assessments.append(make(
            DriftResult.MISMATCH.value,
            f"Observed '{fact_name}' differs from declared '{declared_field}' on {target}",
            supporting,
            approval=severity in {"high", "critical"},
        ))

    return assessments
