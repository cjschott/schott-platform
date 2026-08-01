"""Compare declared intent against collected evidence.

Deterministic and read-only. It reads a declared entity and a set of evidence
records and returns a VerificationRecord. It writes nothing, changes nothing,
and has no path that could act on what it finds.

Three distinctions carry most of the weight, and all three exist to stop the
platform reporting alarm when it has learned nothing:

- **Missing evidence is not drift.** Never having looked is not a finding.
- **Collection failure is not service failure.** A collector that could not
  look has learned nothing about the target's health.
- **Stale evidence is not mismatch.** Old evidence is weak evidence, not
  contrary evidence, and it can never support a `verified` state.

Explanations always name the supporting evidence identifiers. A conclusion
that cites nothing cannot be audited, and an unauditable conclusion is
indistinguishable from a guess.
"""

from __future__ import annotations

from typing import Any, Iterable

from .confidence import (
    agreement_score,
    assess_freshness,
    compute_confidence,
    source_reliability,
)
from .models import (
    DriftResult,
    EvidenceRecord,
    FreshnessAssessment,
    FreshnessState,
    VerificationRecord,
    VerificationState,
    require_timezone,
)

# Sources that describe what a human said rather than what a machine saw.
# Evidence from these alone cannot reach a verified state.
ATTESTATION_SOURCES = frozenset({"manual-attestation"})


def _as_dict(record: Any) -> dict[str, Any]:
    return record.to_dict() if isinstance(record, EvidenceRecord) else dict(record)


def _newest(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    dated = [r for r in records if r.get("collected_at")]
    return max(dated, key=lambda r: str(r["collected_at"])) if dated else None


def verify(*, declared: dict[str, Any], evidence_records: Iterable[Any],
           rules: Iterable[dict[str, Any]], evaluated_at: str,
           verification_id: str) -> VerificationRecord:
    """Return one verification for a target.

    A single record is produced covering the applicable rules, so a caller
    always has one answer per evaluation rather than having to reconcile
    several partial ones.
    """
    stamp = require_timezone(evaluated_at, "evaluated_at")
    records = [_as_dict(r) for r in evidence_records]
    rule_list = [dict(r) for r in rules]
    target = str((declared or {}).get("id") or (records[0].get("target") if records else "unknown"))
    evidence_ids = tuple(str(r.get("id")) for r in records if r.get("id"))
    rule_id = str(rule_list[0].get("id")) if rule_list else None
    max_age = rule_list[0].get("max_age_seconds") if rule_list else None

    newest = _newest(records)
    freshness = assess_freshness(
        newest_collected_at=str(newest["collected_at"]) if newest else None,
        generated_at=stamp,
        max_age_seconds=max_age,
    )

    def build(state: str, result: str, severity: str, explanation: str,
              factors: dict[str, float], approval: bool = False) -> VerificationRecord:
        return VerificationRecord(
            id=verification_id,
            target=target,
            evaluated_at=stamp,
            evidence=evidence_ids,
            state=state,
            result=result,
            severity=severity,
            explanation=explanation,
            confidence=compute_confidence(factors),
            freshness=freshness,
            approval_required=approval,
            rule=rule_id,
        )

    # --- nothing to go on --------------------------------------------------
    if not records:
        return build(
            VerificationState.UNKNOWN.value,
            DriftResult.MISSING_OBSERVATION.value,
            "info",
            f"No evidence exists for {target}. This is an absence of observation, "
            "not a detected difference.",
            {"source_reliability": 0.0, "freshness": 0.0, "verification": 0.0,
             "source_agreement": 0.0, "completeness": 0.0},
        )

    # --- the collection itself failed -------------------------------------
    failed = [r for r in records if str(r.get("status")) in {"failed", "unavailable"}]
    usable = [r for r in records if str(r.get("status")) not in {"failed", "unavailable"}]
    if failed and not usable:
        ids = ", ".join(str(r.get("id")) for r in failed)
        return build(
            VerificationState.FAILED.value,
            DriftResult.COLLECTION_FAILURE.value,
            "medium",
            f"Collection failed for {target} (evidence: {ids}). This describes the "
            "collection attempt and is not a statement about the target's health.",
            {"source_reliability": 0.0, "freshness": freshness.factor_score,
             "verification": 0.0, "source_agreement": 0.0, "completeness": 0.0},
        )

    if not rule_list:
        ids = ", ".join(evidence_ids)
        return build(
            VerificationState.PENDING.value,
            DriftResult.UNSUPPORTED.value,
            "info",
            f"Evidence exists for {target} (evidence: {ids}) but no rule applies to it.",
            {"source_reliability": source_reliability(str(usable[0].get("collector"))),
             "freshness": freshness.factor_score, "verification": 0.0,
             "source_agreement": agreement_score([1]), "completeness": 0.5},
        )

    rule = rule_list[0]
    fact_name = str(rule.get("fact") or "")
    declared_field = str(rule.get("declared_field") or fact_name)
    severity = str(rule.get("severity") or "medium")

    observed_values = [r.get("facts", {}).get(fact_name) for r in usable
                       if fact_name in (r.get("facts") or {})]
    supporting = [str(r.get("id")) for r in usable if fact_name in (r.get("facts") or {})]

    # --- the rule cannot be evaluated -------------------------------------
    if declared_field not in (declared or {}):
        ids = ", ".join(evidence_ids)
        return build(
            VerificationState.UNSUPPORTED.value,
            DriftResult.UNSUPPORTED.value,
            "info",
            f"Rule {rule_id} references declared field '{declared_field}', which "
            f"{target} does not declare (evidence: {ids}). Nothing can be concluded.",
            {"source_reliability": source_reliability(str(usable[0].get("collector"))),
             "freshness": freshness.factor_score, "verification": 0.0,
             "source_agreement": agreement_score(observed_values), "completeness": 0.0},
        )

    if not observed_values:
        ids = ", ".join(evidence_ids)
        return build(
            VerificationState.UNKNOWN.value,
            DriftResult.MISSING_OBSERVATION.value,
            "info",
            f"No evidence reports '{fact_name}' for {target} (evidence: {ids}). "
            "Nothing observed this fact, so no difference has been detected.",
            {"source_reliability": source_reliability(str(usable[0].get("collector"))),
             "freshness": freshness.factor_score, "verification": 0.0,
             "source_agreement": 0.0, "completeness": 0.0},
        )

    declared_value = (declared or {}).get(declared_field)
    matches = [v for v in observed_values if str(v) == str(declared_value)]
    ids = ", ".join(supporting)
    factors = {
        "source_reliability": source_reliability(str(usable[0].get("collector"))),
        "freshness": freshness.factor_score,
        "verification": 1.0,
        "source_agreement": agreement_score(observed_values),
        "completeness": 1.0,
    }

    # --- stale evidence cannot conclude anything --------------------------
    if freshness.state == FreshnessState.STALE.value:
        return build(
            VerificationState.WARNING.value,
            DriftResult.STALE_EVIDENCE.value,
            "low",
            f"Evidence for {target} is stale ({freshness.age_seconds}s old, evidence: {ids}). "
            "Old evidence is weak evidence, not contrary evidence, so this is neither "
            "verified nor drift.",
            {**factors, "verification": 0.0},
        )

    if len(matches) == len(observed_values):
        state = VerificationState.VERIFIED.value
        result = DriftResult.MATCH.value
        explanation = (
            f"Declared '{declared_field}' matches every observation of '{fact_name}' "
            f"for {target} (evidence: {ids})."
        )
        # A human saying something is true is evidence, not proof. Attestation
        # alone stays pending until something machine-observed agrees.
        if all(str(r.get("collector")) in ATTESTATION_SOURCES for r in usable):
            state = VerificationState.PENDING.value
            explanation += (
                " Support is human attestation only, which cannot independently "
                "establish a verified state."
            )
            factors["verification"] = 0.0
        return build(state, result, "info", explanation, factors)

    return build(
        VerificationState.DRIFT.value,
        DriftResult.MISMATCH.value,
        severity,
        f"Declared '{declared_field}' does not match observed '{fact_name}' for "
        f"{target} (evidence: {ids}). Advisory only; no action has been taken.",
        factors,
        approval=severity in {"high", "critical"},
    )
