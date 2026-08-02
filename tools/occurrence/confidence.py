"""Confidence scoring for temporal claims.

Answers "how much observed history is this built on?", not "how likely is this
to continue". It is an engineering heuristic with visible inputs and is never a
probability — a series of three restarts two hours apart is a fact about six
hours, not a claim about tomorrow.

Out-of-range and missing factors raise rather than being clamped or defaulted:
clamping hides the bug that produced the value, and a defaulted factor changes
the score without appearing in the explanation.
"""

from __future__ import annotations

from typing import Any, Mapping

from .models import TemporalConfidence

# Weights total exactly 1.0, asserted here and in the test suite.
FACTOR_WEIGHTS: dict[str, float] = {
    # How many occurrences the summary rests on. Two events make one interval,
    # which is not yet a rhythm.
    "occurrence_count": 0.35,
    # How long the observation window actually spans. Six restarts in a minute
    # describe a minute.
    "observation_span": 0.25,
    # How consistent the intervals are. Consistency raises confidence in the
    # description, not in any continuation of it.
    "interval_regularity": 0.20,
    # How recent the newest occurrence is. Old history describes an old system.
    "data_age": 0.20,
}

FACTOR_REASONS: dict[str, str] = {
    "occurrence_count": "How many occurrences the temporal summary rests on.",
    "observation_span": "How long a period the occurrences actually cover.",
    "interval_regularity": "How consistent the gaps between occurrences are.",
    "data_age": "How recent the newest occurrence is.",
}

# The count at which occurrence_count reaches full marks. Below it the factor
# scales linearly. Named so the boundary is reviewable.
COUNT_TARGET = 20

# The span at which observation_span reaches full marks: thirty days.
SPAN_TARGET_SECONDS = 2_592_000

# Below this many occurrences no rhythm is claimed at all.
MINIMUM_SERIES_OCCURRENCES = 3


def _require_bounded(name: str, value: Any) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"confidence factor '{name}' must be numeric")
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise ValueError(f"confidence factor '{name}' must be between 0.0 and 1.0")
    return number


def compute_temporal_confidence(
    factors: Mapping[str, float],
    reasons: Mapping[str, str] | None = None,
) -> TemporalConfidence:
    """Return the weighted mean with every input visible."""
    missing = sorted(set(FACTOR_WEIGHTS) - set(factors or {}))
    if missing:
        raise ValueError(f"missing confidence factors: {', '.join(missing)}")
    unexpected = sorted(set(factors) - set(FACTOR_WEIGHTS))
    if unexpected:
        raise ValueError(f"unknown confidence factors: {', '.join(unexpected)}")

    bounded = {name: _require_bounded(name, factors[name]) for name in FACTOR_WEIGHTS}
    contributions = {name: bounded[name] * weight for name, weight in FACTOR_WEIGHTS.items()}
    overall = sum(contributions.values())

    written = dict(FACTOR_REASONS)
    for name, text in (reasons or {}).items():
        if name in written and text:
            written[name] = str(text)

    return TemporalConfidence(
        overall=overall,
        factors=bounded,
        weights=dict(FACTOR_WEIGHTS),
        contributions=contributions,
        reasons=written,
    )


def count_score(count: int) -> float:
    """Scale occurrence count onto a bounded factor.

    Zero occurrences scores 0.0, not 1.0. An empty history is not a complete
    one.
    """
    if count <= 0:
        return 0.0
    return max(0.0, min(1.0, count / float(COUNT_TARGET)))


def span_score(span_seconds: int | None) -> float:
    """Scale the observed span onto a bounded factor."""
    if not span_seconds or span_seconds <= 0:
        return 0.0
    return max(0.0, min(1.0, span_seconds / float(SPAN_TARGET_SECONDS)))


def regularity_score(mean_interval: float | None, deviation: float | None) -> float:
    """How consistent the intervals are, as a bounded factor.

    Uses the coefficient of variation: deviation relative to the mean. With
    fewer than two intervals there is nothing to compare, which scores 0.0
    rather than perfect — an unmeasurable rhythm is not a perfect one.
    """
    if mean_interval is None or deviation is None or mean_interval <= 0:
        return 0.0
    coefficient = deviation / mean_interval
    return max(0.0, min(1.0, 1.0 - coefficient))


def age_score(age_seconds: float | None, span_seconds: int | None) -> float:
    """How recent the newest occurrence is, relative to the observed span.

    ``None`` means nothing was observed, which scores 0.0 — an absence of
    history is not recent history.
    """
    if age_seconds is None or not span_seconds or span_seconds <= 0:
        return 0.0
    if age_seconds <= 0:
        return 1.0
    return max(0.0, min(1.0, 1.0 - (age_seconds / float(span_seconds))))
