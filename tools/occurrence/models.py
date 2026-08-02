"""Data models for the Occurrence Timeline.

Standard-library dataclasses and enums only. Records are frozen: an occurrence
that can be re-dated after something cited it is not a record of when anything
happened.

Absent temporal measures are ``None``, never ``0``. A mean interval of zero
would mean everything happened at once; no mean interval means there was
nothing to measure. Collapsing them is how a system reports confident timing
about a single event.

See docs/decisions/ADR-0009-occurrence-timeline.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from types import MappingProxyType
from typing import Any, Mapping

OCCURRENCE_ID = re.compile(r"^OCC-[0-9]{6}$")
SERIES_ID = re.compile(r"^SERIES-[0-9]{6}$")
PATTERN_ID = re.compile(r"^PAT-[0-9]{6}$")
TIMELINE_ID = re.compile(r"^TL-[0-9]{6}$")

ID_PATTERNS = {
    "occurrence": OCCURRENCE_ID,
    "series": SERIES_ID,
    "pattern": PATTERN_ID,
    "timeline": TIMELINE_ID,
}

ID_PREFIXES = {
    "occurrence": "OCC",
    "series": "SERIES",
    "pattern": "PAT",
    "timeline": "TL",
}


class Recurrence(str, Enum):
    """How evenly spaced a series is.

    ``UNKNOWN`` and ``SINGLE`` are real answers. One event has no spacing, and
    no events have nothing to space; reporting either as ``REGULAR`` would
    claim a rhythm nobody observed.
    """

    REGULAR = "regular"
    IRREGULAR = "irregular"
    SINGLE = "single"
    UNKNOWN = "unknown"


class PatternKind(str, Enum):
    """The temporal shapes this engine can recognise.

    A closed vocabulary. Each is a statement about observed history, never
    about what comes next.
    """

    RECURRING = "recurring"
    BURST = "burst"
    ISOLATED = "isolated"
    ACCELERATING = "accelerating"
    DECELERATING = "decelerating"


def require_timezone(value: Any, label: str) -> str:
    """Return an ISO 8601 timestamp, rejecting naive and relative values.

    A time without a zone is not a point in time, and this whole layer is about
    points in time.
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


def readonly(mapping: Mapping[str, Any]) -> Mapping[str, Any]:
    """A mapping that cannot be written through."""
    return MappingProxyType(dict(sorted(mapping.items())))


def _round(value: float | None, places: int = 6) -> float | None:
    """Round for stable serialization, preserving None."""
    return None if value is None else round(float(value), places)


@dataclass(frozen=True)
class Occurrence:
    """One thing that happened, at one time.

    The atom of this layer. It cites the record it was derived from, so any
    temporal claim can be traced back to the evidence that produced it.
    """

    id: str
    target: str
    kind: str
    occurred_at: str
    recorded_at: str
    source: str
    detail: str = ""
    type: str = "occurrence"
    provenance: str = "observed"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "kind": self.kind,
            "occurred_at": self.occurred_at,
            "recorded_at": self.recorded_at,
            "source": self.source,
            "detail": self.detail,
            "provenance": self.provenance,
        }


@dataclass(frozen=True)
class TemporalConfidence:
    """A confidence score with every input visible."""

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
class OccurrenceSeries:
    """Every observed occurrence of one kind, for one target.

    Frequency here is a count over an observed span. It describes what was
    seen; it is not a rate expected to continue, and nothing in this layer
    treats it as one.
    """

    id: str
    target: str
    kind: str
    generated_at: str
    count: int
    occurrences: tuple[str, ...] = ()
    first_seen: str | None = None
    last_seen: str | None = None
    observation_span_seconds: int | None = None
    intervals_seconds: tuple[int, ...] | list[int] = ()
    mean_interval_seconds: float | None = None
    median_interval_seconds: float | None = None
    minimum_interval_seconds: int | None = None
    maximum_interval_seconds: int | None = None
    interval_deviation_seconds: float | None = None
    frequency_per_day: float | None = None
    recurrence: str = Recurrence.UNKNOWN.value
    recurrence_explanation: str = ""
    confidence: TemporalConfidence | None = None
    type: str = "occurrence-series"
    provenance: str = "derived"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "kind": self.kind,
            "generated_at": self.generated_at,
            "count": self.count,
            "occurrences": list(self.occurrences),
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "observation_span_seconds": self.observation_span_seconds,
            "intervals_seconds": list(self.intervals_seconds),
            "mean_interval_seconds": _round(self.mean_interval_seconds),
            "median_interval_seconds": _round(self.median_interval_seconds),
            "minimum_interval_seconds": self.minimum_interval_seconds,
            "maximum_interval_seconds": self.maximum_interval_seconds,
            "interval_deviation_seconds": _round(self.interval_deviation_seconds),
            "frequency_per_day": _round(self.frequency_per_day),
            "recurrence": self.recurrence,
            "recurrence_explanation": self.recurrence_explanation,
            "confidence": self.confidence.to_dict() if self.confidence else None,
            "provenance": self.provenance,
            "interpretation": "observed temporal history; not a prediction",
        }


@dataclass(frozen=True)
class Pattern:
    """A recognised temporal shape in a series.

    Every pattern is a statement about what was observed. None of them says
    anything about what will happen next, and the type has no field in which
    such a claim could be recorded.
    """

    id: str
    target: str
    kind: str
    detected_at: str
    series: tuple[str, ...]
    explanation: str
    occurrence_count: int = 0
    confidence: TemporalConfidence | None = None
    type: str = "pattern"
    provenance: str = "inferred"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "kind": self.kind,
            "detected_at": self.detected_at,
            "series": list(self.series),
            "occurrence_count": self.occurrence_count,
            "explanation": self.explanation,
            "confidence": self.confidence.to_dict() if self.confidence else None,
            "provenance": self.provenance,
            "interpretation": "describes observed history; makes no forward claim",
        }


@dataclass(frozen=True)
class Timeline:
    """An ordered view of occurrences for a target.

    Ordering is by time then identifier. The identifier tiebreak matters:
    occurrences can share an instant, and without a deterministic secondary
    sort two reads of the same history would disagree.
    """

    id: str
    target: str
    generated_at: str
    entry_count: int
    entries: tuple[Mapping[str, Any], ...] = ()
    earliest: str | None = None
    latest: str | None = None
    span_seconds: int | None = None
    kinds: tuple[str, ...] = ()
    type: str = "timeline"
    provenance: str = "derived"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "generated_at": self.generated_at,
            "entry_count": self.entry_count,
            "entries": [dict(e) for e in self.entries],
            "earliest": self.earliest,
            "latest": self.latest,
            "span_seconds": self.span_seconds,
            "kinds": list(self.kinds),
            "provenance": self.provenance,
            "interpretation": "a record of what happened, in order; not a forecast",
        }
