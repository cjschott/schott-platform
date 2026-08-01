"""Data models for the knowledge orchestrator.

Standard-library dataclasses and enums only. These types define what the
orchestration layer may record and — as importantly — what it has no way to
record. There is no field for a command, no field for a remediation action,
and no field capable of carrying a raw secret value.

Evidence, verification, and event records are frozen. A record that can be
edited after it has been cited is not immutable, and ADR-0004 depends on
immutability being a property of the type rather than a convention.

See docs/decisions/ADR-0004-immutable-knowledge-timeline.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any

EVIDENCE_ID = re.compile(r"^EVID-[0-9]{6}$")
VERIFICATION_ID = re.compile(r"^VER-[0-9]{6}$")
EVENT_ID = re.compile(r"^MEM-[0-9]{6}$")
OBSERVATION_ID = re.compile(r"^OBS-[0-9]{6}$")

# Identifier width is six digits for records the platform generates, and stays
# at four for records a human authors. Generated records accumulate per
# collection; authored ones accumulate per decision.
ID_PATTERNS = {
    "evidence": EVIDENCE_ID,
    "verification": VERIFICATION_ID,
    "event": EVENT_ID,
    "observation": OBSERVATION_ID,
}

ID_PREFIXES = {
    "evidence": "EVID",
    "verification": "VER",
    "event": "MEM",
    "observation": "OBS",
}


class EventType(str, Enum):
    """The closed vocabulary from docs/standards/knowledge-event-standard.md.

    Closed deliberately: an open-ended event vocabulary forces every consumer
    to handle types it has never seen.
    """

    OBSERVATION_RECEIVED = "observation-received"
    EVIDENCE_CREATED = "evidence-created"
    EVIDENCE_REFRESHED = "evidence-refreshed"
    VERIFICATION_CREATED = "verification-created"
    DRIFT_DETECTED = "drift-detected"
    DRIFT_CLEARED = "drift-cleared"
    EVIDENCE_STALE = "evidence-stale"
    COLLECTION_FAILED = "collection-failed"
    REVIEW_REQUIRED = "review-required"
    KNOWLEDGE_STATE_GENERATED = "knowledge-state-generated"


class FreshnessState(str, Enum):
    CURRENT = "current"
    AGING = "aging"
    STALE = "stale"
    UNKNOWN = "unknown"


class VerificationState(str, Enum):
    UNKNOWN = "unknown"
    PENDING = "pending"
    VERIFIED = "verified"
    WARNING = "warning"
    DRIFT = "drift"
    FAILED = "failed"
    UNSUPPORTED = "unsupported"


class DriftResult(str, Enum):
    """Result types shared with docs/standards/verification-drift-standard.md.

    `missing_observation`, `stale_evidence`, and `collection_failure` exist so
    that "we did not look", "we looked a long time ago", and "we tried and
    failed" are never reported as "reality diverged".
    """

    MATCH = "match"
    MISMATCH = "mismatch"
    MISSING_OBSERVATION = "missing_observation"
    STALE_EVIDENCE = "stale_evidence"
    UNSUPPORTED = "unsupported"
    COLLECTION_FAILURE = "collection_failure"


class Provenance(str, Enum):
    DECLARED = "declared"
    OBSERVED = "observed"
    INFERRED = "inferred"


APPROVED_SEVERITIES = ("info", "low", "medium", "high", "critical")


def require_timezone(value: Any, label: str) -> str:
    """Return an ISO 8601 timestamp, rejecting naive and relative values.

    A time without a zone is not a point in time, so every comparison against
    it is guesswork. Rejecting is safer than assuming local.
    """
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise ValueError(f"{label} must carry timezone information")
        return value.isoformat()
    if not isinstance(value, str):
        raise ValueError(f"{label} must be an ISO 8601 string")
    text = value.strip()
    if text.lower() in {"now", "today", "latest", "current", "recently"}:
        raise ValueError(f"{label} must not be a relative time expression")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} is not valid ISO 8601") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must carry timezone information")
    return text


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


@dataclass(frozen=True)
class Observation:
    """A validated, redacted, normalized collection result.

    This is the boundary type between collection and evidence. It carries no
    identifier: identity is assigned only after validation succeeds, so a
    rejected observation never consumes a sequence number.
    """

    collector_id: str
    target: str
    collected_at: str
    status: str
    facts: dict[str, Any]
    errors: tuple[dict[str, Any], ...] = ()
    source_fingerprint: str = ""
    provenance: str = Provenance.OBSERVED.value

    def validation_errors(self) -> list[str]:
        problems: list[str] = []
        if not self.collector_id:
            problems.append("collector_id is required")
        if not self.target:
            problems.append("target is required")
        try:
            require_timezone(self.collected_at, "collected_at")
        except ValueError as error:
            problems.append(str(error))
        if self.provenance != Provenance.OBSERVED.value:
            problems.append("observation provenance must be 'observed'")
        return problems


@dataclass(frozen=True)
class EvidenceRecord:
    """One immutable observation, given a persistent identifier.

    Frozen because a record whose content can change after it has been cited
    breaks every conclusion that referenced it. Corrections supersede via the
    `supersedes` field; they never edit.
    """

    id: str
    target: str
    collector: str
    collected_at: str
    persisted_at: str
    status: str
    facts: dict[str, Any]
    content_fingerprint: str
    errors: tuple[dict[str, Any], ...] = ()
    type: str = "evidence"
    sensitivity: str = "internal"
    redaction: str = "applied"
    provenance: str = Provenance.OBSERVED.value
    supersedes: str | None = None
    references: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "collector": self.collector,
            "collected_at": self.collected_at,
            "persisted_at": self.persisted_at,
            "status": self.status,
            "facts": dict(sorted(self.facts.items())),
            "errors": [dict(sorted(e.items())) for e in self.errors],
            "content_fingerprint": self.content_fingerprint,
            "sensitivity": self.sensitivity,
            "redaction": self.redaction,
            "provenance": self.provenance,
            "supersedes": self.supersedes,
            "references": list(self.references),
        }

    @property
    def collection_failed(self) -> bool:
        """True when the collection failed. Says nothing about the target."""
        return self.status in {"failed", "unavailable"}


@dataclass(frozen=True)
class ConfidenceExplanation:
    """A confidence score with every input visible.

    The breakdown is not decoration. A bare number between zero and one invites
    probabilistic reading, and the factor list is what makes it legible as
    reasoning instead.
    """

    overall: float
    factors: dict[str, float]
    weights: dict[str, float]
    notes: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "overall": round(self.overall, 4),
            "factors": {k: round(v, 4) for k, v in sorted(self.factors.items())},
            "weights": {k: v for k, v in sorted(self.weights.items())},
            "contributions": {
                k: round(self.factors[k] * self.weights[k], 4)
                for k in sorted(self.factors)
                if k in self.weights
            },
            "notes": list(self.notes),
            "interpretation": "engineering heuristic, not a probability",
        }


@dataclass(frozen=True)
class FreshnessAssessment:
    """How current the supporting evidence is, and whether that is knowable."""

    state: str
    age_seconds: int | None
    max_age_seconds: int | None
    factor_score: float
    review_required: bool
    explanation: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "age_seconds": self.age_seconds,
            "max_age_seconds": self.max_age_seconds,
            "factor_score": round(self.factor_score, 4),
            "review_required": self.review_required,
            "explanation": self.explanation,
        }


@dataclass(frozen=True)
class VerificationRecord:
    """The read-only result of comparing declared intent against evidence."""

    id: str
    target: str
    evaluated_at: str
    evidence: tuple[str, ...]
    state: str
    result: str
    severity: str
    explanation: str
    confidence: ConfidenceExplanation
    freshness: FreshnessAssessment
    approval_required: bool = False
    rule: str | None = None
    type: str = "verification"
    provenance: str = Provenance.INFERRED.value

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "rule": self.rule,
            "evaluated_at": self.evaluated_at,
            "evidence": list(self.evidence),
            "state": self.state,
            "result": self.result,
            "severity": self.severity,
            "explanation": self.explanation,
            "confidence": self.confidence.to_dict(),
            "freshness": self.freshness.to_dict(),
            "approval_required": self.approval_required,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class DriftAssessment:
    """One rule's conclusion about one target.

    `recommended_action` is advisory prose for a human. There is deliberately
    no structured action field: a machine-readable action is one scheduler away
    from being executed.
    """

    rule: str
    target: str
    result: str
    severity: str
    explanation: str
    evidence: tuple[str, ...] = ()
    approval_required: bool = False
    recommended_action: str = "No action. Advisory only; review before acting."
    provenance: str = Provenance.INFERRED.value

    def to_dict(self) -> dict[str, Any]:
        return {
            "rule": self.rule,
            "target": self.target,
            "result": self.result,
            "severity": self.severity,
            "explanation": self.explanation,
            "evidence": list(self.evidence),
            "approval_required": self.approval_required,
            "recommended_action": self.recommended_action,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class KnowledgeEvent:
    """An append-only record that something happened to platform knowledge."""

    id: str
    target: str
    event_type: str
    occurred_at: str
    explanation: str
    evidence: tuple[str, ...] = ()
    verification: tuple[str, ...] = ()
    drift: tuple[str, ...] = ()
    confidence: float | None = None
    knowledge_age_seconds: int | None = None
    type: str = "knowledge-event"
    provenance: str = Provenance.INFERRED.value

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "event_type": self.event_type,
            "occurred_at": self.occurred_at,
            "evidence": list(self.evidence),
            "verification": list(self.verification),
            "drift": list(self.drift),
            "explanation": self.explanation,
            "confidence": None if self.confidence is None else round(self.confidence, 4),
            "knowledge_age_seconds": self.knowledge_age_seconds,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class KnowledgeState:
    """What the platform currently believes about one target.

    Derived on demand and never stored as authoritative truth. Two runs over
    the same immutable inputs produce identical output, which is what makes a
    derivation bug a code bug rather than corrupted data.
    """

    target: str
    generated_at: str
    newest_evidence_at: str | None
    knowledge_age_seconds: int | None
    freshness: str
    confidence: ConfidenceExplanation
    supporting_evidence: tuple[str, ...] = ()
    verification_state: str = VerificationState.UNKNOWN.value
    drift_results: tuple[dict[str, Any], ...] = ()
    latest_events: tuple[dict[str, Any], ...] = ()
    conflicts: tuple[dict[str, Any], ...] = ()
    review_required: bool = True
    provenance_classes: dict[str, bool] = field(
        default_factory=lambda: {"declared": False, "observed": False, "inferred": False}
    )

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target,
            "generated_at": self.generated_at,
            "newest_evidence_at": self.newest_evidence_at,
            "knowledge_age_seconds": self.knowledge_age_seconds,
            "freshness": self.freshness,
            "confidence": self.confidence.to_dict(),
            "supporting_evidence": list(self.supporting_evidence),
            "verification_state": self.verification_state,
            "drift_results": [dict(d) for d in self.drift_results],
            "latest_events": [dict(e) for e in self.latest_events],
            "conflicts": [dict(c) for c in self.conflicts],
            "review_required": self.review_required,
            "provenance_classes": dict(sorted(self.provenance_classes.items())),
            "derivation": "derived on demand; not authoritative declared state",
        }


@dataclass(frozen=True)
class OrchestrationResult:
    """Everything one ingestion produced.

    `evidence` is None for a duplicate observation, in which case
    `duplicate_of` names the record the content matched.
    """

    target: str
    evidence: EvidenceRecord | None = None
    duplicate_of: str | None = None
    verification: VerificationRecord | None = None
    drift: tuple[DriftAssessment, ...] = ()
    events: tuple[KnowledgeEvent, ...] = ()
    knowledge_state: KnowledgeState | None = None
    errors: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "target": self.target,
            "evidence": self.evidence.to_dict() if self.evidence else None,
            "duplicate_of": self.duplicate_of,
            "verification": self.verification.to_dict() if self.verification else None,
            "drift": [d.to_dict() for d in self.drift],
            "events": [e.to_dict() for e in self.events],
            "knowledge_state": self.knowledge_state.to_dict() if self.knowledge_state else None,
            "errors": list(self.errors),
        }
