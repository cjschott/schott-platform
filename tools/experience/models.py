"""Data models for the Experience Engine.

Standard-library dataclasses and enums only.

Two properties are enforced by the types rather than by convention:

- **Records are frozen.** A profile or baseline that can be edited after
  something cited it is not a record of what was observed.
- **Absent statistics are ``None``, never ``0``.** A mean of zero and no mean
  at all are different claims, and collapsing them is how a system reports
  confident numbers about nothing.

See docs/decisions/ADR-0008-experience-engine.md.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from types import MappingProxyType
from typing import Any, Mapping

PROFILE_ID = re.compile(r"^EXP-[0-9]{6}$")
WINDOW_ID = re.compile(r"^WINDOW-[0-9]{6}$")
BASELINE_ID = re.compile(r"^BASE-[0-9]{6}$")

ID_PATTERNS = {
    "profile": PROFILE_ID,
    "window": WINDOW_ID,
    "baseline": BASELINE_ID,
}

ID_PREFIXES = {
    "profile": "EXP",
    "window": "WINDOW",
    "baseline": "BASE",
}

# The statistics a profile reports. Named here so a consumer can tell a missing
# field from a null one.
STATISTIC_FIELDS = (
    "sample_count", "minimum", "maximum", "mean", "median", "standard_deviation",
)


class Trend(str, Enum):
    """How a series moved across its window.

    ``UNKNOWN`` is a real answer, not a fallback. One sample cannot have a
    direction, and reporting it as ``STABLE`` would claim steadiness nobody
    observed.
    """

    STABLE = "stable"
    INCREASING = "increasing"
    DECREASING = "decreasing"
    VOLATILE = "volatile"
    UNKNOWN = "unknown"


class BaselineStatus(str, Enum):
    """How current behaviour compares against operational history.

    ``UNKNOWN`` and ``INSUFFICIENT_EVIDENCE`` exist so that "we have not
    watched this" and "we have barely watched this" are never reported as
    "this is abnormal".
    """

    EXPECTED = "EXPECTED"
    UNEXPECTED = "UNEXPECTED"
    UNKNOWN = "UNKNOWN"
    INSUFFICIENT_EVIDENCE = "INSUFFICIENT_EVIDENCE"


# Alias kept for callers that think in terms of behaviour rather than baselines.
BehaviourStatus = BaselineStatus


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


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def _readonly(mapping: Mapping[str, Any]) -> Mapping[str, Any]:
    """A mapping that cannot be written through.

    A frozen dataclass still exposes a mutable dict, so ``record.factors[k] = v``
    would silently succeed. Wrapping closes that hole.
    """
    return MappingProxyType(dict(sorted(mapping.items())))


def _round(value: float | None, places: int = 6) -> float | None:
    """Round for stable serialization, preserving None.

    None must survive: it means "not observed", and turning it into 0.0 would
    invent a statistic.
    """
    return None if value is None else round(float(value), places)


@dataclass(frozen=True)
class ExperienceWindow:
    """A bounded span of time a profile summarizes."""

    id: str
    label: str
    window_start: str
    window_end: str
    duration_seconds: int
    type: str = "experience-window"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "label": self.label,
            "window_start": self.window_start,
            "window_end": self.window_end,
            "duration_seconds": self.duration_seconds,
        }


@dataclass(frozen=True)
class ExperienceProfile:
    """A statistical summary of one metric over one window.

    Every numeric field is ``None`` when nothing was observed. These are
    statistics, not truths: a profile says what was seen, never what is
    correct.
    """

    id: str
    target: str
    metric: str
    generated_at: str
    window_label: str
    window_start: str
    window_end: str
    sample_count: int
    minimum: float | None = None
    maximum: float | None = None
    mean: float | None = None
    median: float | None = None
    standard_deviation: float | None = None
    trend: str = Trend.UNKNOWN.value
    trend_explanation: str = ""
    window: str | None = None
    type: str = "experience-profile"
    provenance: str = "derived"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "metric": self.metric,
            "generated_at": self.generated_at,
            "window": self.window,
            "window_label": self.window_label,
            "window_start": self.window_start,
            "window_end": self.window_end,
            "sample_count": self.sample_count,
            "minimum": _round(self.minimum),
            "maximum": _round(self.maximum),
            "mean": _round(self.mean),
            "median": _round(self.median),
            "standard_deviation": _round(self.standard_deviation),
            "trend": self.trend,
            "trend_explanation": self.trend_explanation,
            "provenance": self.provenance,
            "interpretation": "observed statistics; not a truth claim",
        }


@dataclass(frozen=True)
class ExperienceConfidence:
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
class OperationalBaseline:
    """What one or more windows say is typical for a metric.

    ``typical_value`` is ``None`` when there is nothing to summarize. A
    baseline never fabricates a typical value in order to have one.
    """

    id: str
    target: str
    metric: str
    generated_at: str
    typical_value: float | None
    tolerance: float | None
    sample_count: int
    profiles: tuple[str, ...] = ()
    windows: tuple[str, ...] = ()
    confidence: ExperienceConfidence | None = None
    trend: str = Trend.UNKNOWN.value
    review_required: bool = True
    type: str = "operational-baseline"
    provenance: str = "derived"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "type": self.type,
            "target": self.target,
            "metric": self.metric,
            "generated_at": self.generated_at,
            "typical_value": _round(self.typical_value),
            "tolerance": _round(self.tolerance),
            "sample_count": self.sample_count,
            "profiles": list(self.profiles),
            "windows": list(self.windows),
            "confidence": self.confidence.to_dict() if self.confidence else None,
            "trend": self.trend,
            "review_required": self.review_required,
            "provenance": self.provenance,
            "interpretation": "what has been observed; not what ought to be true",
        }


@dataclass(frozen=True)
class BehaviourAssessment:
    """How a current value compares against a baseline.

    Frozen and comparable, so two assessments of the same inputs are equal —
    which is how determinism is asserted.
    """

    status: str
    current_value: float | None
    typical_value: float | None
    difference: float | None
    tolerance: float | None
    baseline: str | None
    explanation: str
    confidence: ExperienceConfidence | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "current_value": _round(self.current_value),
            "typical_value": _round(self.typical_value),
            "difference": _round(self.difference),
            "tolerance": _round(self.tolerance),
            "baseline": self.baseline,
            "explanation": self.explanation,
            "confidence": self.confidence.to_dict() if self.confidence else None,
        }


def readonly(mapping: Mapping[str, Any]) -> Mapping[str, Any]:
    """Public helper so builders produce write-protected mappings."""
    return _readonly(mapping)
