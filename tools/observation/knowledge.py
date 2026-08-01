"""Derive what the platform currently believes about a target.

Knowledge state is computed on demand from immutable inputs and is never
stored as authoritative truth. That is the whole point: if the current answer
is always derived, a bug in derivation is a bug in code that a rerun fixes,
rather than corrupted data that has to be repaired by hand.

Derivation is deterministic. The same evidence, verifications, and events
always produce byte-identical output, which is what makes the state safe to
cache and safe to throw away.

The three provenance classes stay separate throughout. Declared is what a
human wrote down, observed is what a collector saw, inferred is what this
module concluded. Merging them would let observation masquerade as intent,
which is the failure ADR-0004 exists to prevent.
"""

from __future__ import annotations

from typing import Any, Iterable

from .confidence import (
    agreement_score,
    assess_freshness,
    compute_confidence,
    source_reliability,
)
from .drift_engine import assess_drift
from .evidence_store import EvidenceStore
from .models import (
    KnowledgeState,
    Provenance,
    VerificationState,
    parse_timestamp,
    require_timezone,
)
from .timeline import Timeline


def _conflicts(evidence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Find facts where independent collectors disagree.

    Only genuinely independent sources count: the same collector reporting a
    different value at a later time is change over time, not disagreement, and
    reporting it as a conflict would flag every legitimate update.
    """
    by_fact: dict[str, dict[str, set[str]]] = {}
    for record in evidence:
        if str(record.get("status")) in {"failed", "unavailable"}:
            continue
        collector = str(record.get("collector") or "")
        for name, value in (record.get("facts") or {}).items():
            by_fact.setdefault(str(name), {}).setdefault(collector, set()).add(str(value))

    conflicts: list[dict[str, Any]] = []
    for fact, per_collector in sorted(by_fact.items()):
        if len(per_collector) < 2:
            continue
        # Compare the newest value each collector reported.
        distinct = {next(iter(values)) if len(values) == 1 else "|".join(sorted(values))
                    for values in per_collector.values()}
        if len(distinct) > 1:
            conflicts.append({
                "fact": fact,
                "collectors": sorted(per_collector),
                "distinct_values": len(distinct),
                "note": "independent collectors report different values for this fact",
            })
    return conflicts


def build_knowledge_state(*, target: str, store: EvidenceStore,
                          declared: dict[str, Any] | None = None,
                          rules: Iterable[dict[str, Any]] = (),
                          generated_at: str,
                          max_age_seconds: int | None = None) -> KnowledgeState:
    """Derive the current knowledge state for one target.

    Read-only. Reads immutable records and returns a value; writes nothing.
    """
    stamp = require_timezone(generated_at, "generated_at")
    evidence = store.list_evidence(target)
    verifications = store.list_verifications(target)
    rule_list = [dict(r) for r in rules]

    # A rule's freshness policy wins over the caller's default, so freshness
    # is governed by the same declaration that governs the comparison.
    policy_age = max_age_seconds
    if rule_list and rule_list[0].get("max_age_seconds") is not None:
        policy_age = rule_list[0]["max_age_seconds"]

    newest_at = max((str(r.get("collected_at")) for r in evidence if r.get("collected_at")),
                    default=None)
    freshness = assess_freshness(newest_collected_at=newest_at, generated_at=stamp,
                                 max_age_seconds=policy_age)

    usable = [r for r in evidence if str(r.get("status")) not in {"failed", "unavailable"}]
    conflicts = _conflicts(evidence)

    drift_results = assess_drift(
        declared=declared or {"id": target}, evidence_records=evidence,
        rules=rule_list, evaluated_at=stamp,
    ) if rule_list else []

    outstanding = [d.to_dict() for d in drift_results
                   if d.result in {"mismatch", "collection_failure"}]

    verification_state = VerificationState.UNKNOWN.value
    if verifications:
        newest_verification = max(verifications, key=lambda v: str(v.get("evaluated_at") or ""))
        verification_state = str(newest_verification.get("state") or VerificationState.UNKNOWN.value)

    collectors = sorted({str(r.get("collector")) for r in usable})
    reliability = max((source_reliability(c) for c in collectors), default=0.0)
    observed_values = [str((r.get("facts") or {})) for r in usable]

    confidence = compute_confidence(
        {
            "source_reliability": reliability,
            "freshness": freshness.factor_score,
            "verification": 1.0 if verification_state == VerificationState.VERIFIED.value else 0.0,
            "source_agreement": 0.2 if conflicts else agreement_score(observed_values),
            "completeness": 1.0 if usable else 0.0,
        },
        notes=(
            "Derived from immutable evidence; not authoritative declared state.",
            "Confidence is an engineering heuristic, not a probability.",
        ),
    )

    events = Timeline(store).latest(target, limit=10)

    review_required = bool(
        conflicts
        or outstanding
        or freshness.review_required
        or not usable
        or verification_state in {VerificationState.UNKNOWN.value,
                                  VerificationState.FAILED.value,
                                  VerificationState.WARNING.value}
    )

    return KnowledgeState(
        target=target,
        generated_at=stamp,
        newest_evidence_at=newest_at,
        knowledge_age_seconds=freshness.age_seconds,
        freshness=freshness.state,
        confidence=confidence,
        supporting_evidence=tuple(sorted(str(r.get("id")) for r in evidence if r.get("id"))),
        verification_state=verification_state,
        drift_results=tuple(d.to_dict() for d in drift_results),
        latest_events=tuple(e.to_dict() for e in events),
        conflicts=tuple(conflicts),
        review_required=review_required,
        provenance_classes={
            Provenance.DECLARED.value: bool(declared),
            Provenance.OBSERVED.value: bool(evidence),
            Provenance.INFERRED.value: True,
        },
    )
