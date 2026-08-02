"""Data models for the Operational Integrity Engine.

Standard-library dataclasses and enums only.

Two properties are enforced by the types rather than by convention:

- **Snapshots and twins are frozen.** A snapshot that can be edited is not a
  reference point, and a twin that can be edited by hand is no longer a
  reconstruction of knowledge — it is a guess wearing a reconstruction's name.
- **No model can carry an executable instruction.** A recovery plan holds
  prose. There is no command field, no script field, and no execute method,
  because a machine-readable action is one scheduler away from being run.

See docs/decisions/ADR-0007-operational-integrity-engine.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from types import MappingProxyType
from typing import Any, Mapping

SNAPSHOT_ID = re.compile(r"^SNAP-[0-9]{6}$")
TWIN_ID = re.compile(r"^TWIN-[0-9]{6}$")
INTEGRITY_ID = re.compile(r"^INTEG-[0-9]{6}$")
RECOVERY_ID = re.compile(r"^RECOV-[0-9]{6}$")

ID_PATTERNS = {
    "snapshot": SNAPSHOT_ID,
    "twin": TWIN_ID,
    "integrity": INTEGRITY_ID,
    "recovery": RECOVERY_ID,
}

ID_PREFIXES = {
    "snapshot": "SNAP",
    "twin": "TWIN",
    "integrity": "INTEG",
    "recovery": "RECOV",
}

# Bumped when the snapshot payload shape changes. A snapshot that does not
# record the shape it was written in cannot be safely compared years later.
SNAPSHOT_SCHEMA_VERSION = "1.0.0"


class IntegrityStatus(str, Enum):
    """The five conclusions an integrity comparison may reach.

    The last two exist so that "we cannot tell" is never reported as "it
    changed". Conflating them produces false drift on every gap in coverage,
    which trains operators to ignore drift reports.
    """

    MATCH = "MATCH"
    PARTIAL = "PARTIAL"
    DRIFT = "DRIFT"
    UNKNOWN = "UNKNOWN"
    INSUFFICIENT_EVIDENCE = "INSUFFICIENT_EVIDENCE"


class RecoveryStatus(str, Enum):
    NO_ACTION_REQUIRED = "no-action-required"
    REVIEW_RECOMMENDED = "review-recommended"
    RECONSTRUCTION_RECOMMENDED = "reconstruction-recommended"
    INSUFFICIENT_EVIDENCE = "insufficient-evidence"


def require_timezone(value: Any, label: str) -> str:
    """Return an ISO 8601 timestamp, rejecting naive and relative values."""
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


def _readonly(mapping: Mapping[str, Any]) -> Mapping[str, Any]:
    """Return a mapping that cannot be written through.

    A frozen dataclass still exposes a mutable dict, so `twin.facts[k] = v`
    would silently succeed. Wrapping it closes that hole.
    """
    return MappingProxyType(dict(sorted(mapping.items())))


@dataclass(frozen=True)
class SnapshotRecord:
    """An immutable representation of a known-good operational state.

    Never revised. A newer snapshot of the same target is a new record; the
    earlier one stays readable, because a reference point that can be edited
    after something cited it is not a reference point.
    """

    id: str
    target: str
    created_at: str
    label: str
    facts: Mapping[str, Any]
    content_fingerprint: str
    source_knowledge_generated_at: str | None = None
    supporting_evidence: tuple[str, ...] = ()
    knowledge_confidence: float | None = None
    schema_version: str = SNAPSHOT_SCHEMA_VERSION
    type: str = "snapshot"
    provenance: str = "derived"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "created_at": self.created_at,
            "label": self.label,
            "facts": dict(sorted(self.facts.items())),
            "content_fingerprint": self.content_fingerprint,
            "source_knowledge_generated_at": self.source_knowledge_generated_at,
            "supporting_evidence": list(self.supporting_evidence),
            "knowledge_confidence": self.knowledge_confidence,
            "schema_version": self.schema_version,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class DigitalTwin:
    """A disposable working reconstruction of current state.

    Rebuilt entirely from knowledge and never edited directly. Disposability is
    the point: if a twin is always rebuilt, a bug in reconstruction is a bug in
    code that a rerun fixes, rather than corrupted state to repair by hand.
    """

    id: str
    target: str
    built_at: str
    facts: Mapping[str, Any]
    content_fingerprint: str
    source_knowledge_target: str = ""
    source_knowledge_generated_at: str | None = None
    supporting_evidence: tuple[str, ...] = ()
    knowledge_confidence: float | None = None
    knowledge_freshness: str = "unknown"
    disposable: bool = True
    type: str = "digital-twin"
    provenance: str = "derived"

    def without_facts(self) -> "DigitalTwin":
        """Return a copy holding no facts.

        Used to represent a reconstruction that knowledge could not populate.
        A new object rather than a mutation, because twins are frozen.
        """
        return DigitalTwin(
            id=self.id, target=self.target, built_at=self.built_at,
            facts=_readonly({}), content_fingerprint=self.content_fingerprint,
            source_knowledge_target=self.source_knowledge_target,
            source_knowledge_generated_at=self.source_knowledge_generated_at,
            supporting_evidence=(), knowledge_confidence=self.knowledge_confidence,
            knowledge_freshness=self.knowledge_freshness, disposable=True,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "built_at": self.built_at,
            "facts": dict(sorted(self.facts.items())),
            "content_fingerprint": self.content_fingerprint,
            "source_knowledge_target": self.source_knowledge_target,
            "source_knowledge_generated_at": self.source_knowledge_generated_at,
            "supporting_evidence": list(self.supporting_evidence),
            "knowledge_confidence": self.knowledge_confidence,
            "knowledge_freshness": self.knowledge_freshness,
            "disposable": self.disposable,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class IntegrityConfidence:
    """A confidence score with every input visible.

    `reasons` is not decoration. A bare number invites probabilistic reading;
    a written reason per factor is what makes the score reviewable rather than
    merely reportable.
    """

    overall: float
    factors: Mapping[str, float]
    weights: Mapping[str, float]
    contributions: Mapping[str, float]
    reasons: Mapping[str, str]

    def to_dict(self) -> dict[str, Any]:
        return {
            "overall": round(self.overall, 4),
            "factors": {k: round(v, 4) for k, v in sorted(self.factors.items())},
            "weights": dict(sorted(self.weights.items())),
            "contributions": {k: round(v, 4) for k, v in sorted(self.contributions.items())},
            "reasons": dict(sorted(self.reasons.items())),
            "interpretation": "engineering heuristic, not a probability",
        }


@dataclass(frozen=True)
class IntegrityReport:
    """The result of comparing a twin against a snapshot."""

    id: str
    target: str
    evaluated_at: str
    snapshot: tuple[str, ...]
    twin: tuple[str, ...]
    status: str
    confidence: IntegrityConfidence
    differences: tuple[Mapping[str, Any], ...] = ()
    matched_facts: tuple[str, ...] = ()
    uncomparable_facts: tuple[str, ...] = ()
    explanation: str = ""
    review_required: bool = True
    type: str = "integrity-report"
    provenance: str = "inferred"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "evaluated_at": self.evaluated_at,
            "snapshot": list(self.snapshot),
            "twin": list(self.twin),
            "status": self.status,
            "confidence": self.confidence.to_dict(),
            "differences": [dict(d) for d in self.differences],
            "matched_facts": list(self.matched_facts),
            "uncomparable_facts": list(self.uncomparable_facts),
            "explanation": self.explanation,
            "review_required": self.review_required,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class RecoveryPlan:
    """A human-readable reconstruction strategy.

    Every step is prose. There is deliberately no command field, no script
    field, and no execute method — a structured action is one scheduler away
    from being run, and this engine never acts.
    """

    id: str
    target: str
    created_at: str
    integrity_report: tuple[str, ...]
    target_snapshot: tuple[str, ...]
    status: str
    summary: str
    steps: tuple[Mapping[str, Any], ...] = ()
    risks: tuple[str, ...] = ()
    confidence: IntegrityConfidence | None = None
    advisory_only: bool = True
    approval_required: bool = True
    type: str = "recovery-plan"
    provenance: str = "inferred"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "created_at": self.created_at,
            "integrity_report": list(self.integrity_report),
            "target_snapshot": list(self.target_snapshot),
            "status": self.status,
            "summary": self.summary,
            "steps": [dict(s) for s in self.steps],
            "risks": list(self.risks),
            "confidence": self.confidence.to_dict() if self.confidence else None,
            "advisory_only": self.advisory_only,
            "approval_required": self.approval_required,
            "provenance": self.provenance,
            "execution": "none; this plan is advisory and is never executed",
        }


def readonly_facts(mapping: Mapping[str, Any]) -> Mapping[str, Any]:
    """Public helper so builders produce write-protected fact mappings."""
    return _readonly(mapping)


def field_of(record: Any, name: str, default: Any = None) -> Any:
    """Read a field from either a dataclass record or its dict form.

    Deliberately not `getattr(x, n, None) or x.get(n)`: when the attribute
    exists but is empty — an empty tuple of differences, say — `or` falls
    through to the mapping branch and calls .get() on a dataclass, which
    raises. Presence is checked, not truthiness.
    """
    if record is None:
        return default
    if isinstance(record, Mapping):
        value = record.get(name, default)
        return default if value is None else value
    if hasattr(record, name):
        value = getattr(record, name)
        return default if value is None else value
    return default
