"""Confidence scoring for experience baselines.

Every score carries its factors, weights, contributions, and a written reason
per factor. Confidence here answers "how much history is this built on?", not
"how likely is this correct".

It is an engineering heuristic and never a probability. A baseline built on
four samples from three days ago is weak in a way a number alone does not
convey, so the reasons are part of the output rather than documentation.

Out-of-range and missing factors raise rather than being clamped or defaulted.
"""

from __future__ import annotations

from typing import Any, Mapping

from .models import ExperienceConfidence

# Weights total exactly 1.0, asserted here and in the test suite.
FACTOR_WEIGHTS: dict[str, float] = {
    # How much of the window actually contains observations. A 30-day window
    # holding one afternoon of data describes an afternoon.
    "coverage": 0.30,
    # How many samples the summary rests on.
    "sample_quality": 0.30,
    # Whether the window is long enough to describe "normal" at all.
    "window_size": 0.20,
    # How recent the newest observation is. Old history describes an old system.
    "data_age": 0.20,
}

FACTOR_REASONS: dict[str, str] = {
    "coverage": "Proportion of the window that actually contains observations.",
    "sample_quality": "How many samples the statistics rest on.",
    "window_size": "Whether the window is long enough to characterise normal behaviour.",
    "data_age": "How recent the newest observation in the window is.",
}

# The sample count at which sample_quality reaches full marks. Below it the
# factor scales linearly. Named so the boundary is reviewable rather than
# buried in an expression.
SAMPLE_QUALITY_TARGET = 30

# Below this many samples no behavioural conclusion is drawn at all.
MINIMUM_USABLE_SAMPLES = 3


def _require_bounded(name: str, value: Any) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"confidence factor '{name}' must be numeric")
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise ValueError(f"confidence factor '{name}' must be between 0.0 and 1.0")
    return number


def compute_experience_confidence(
    factors: Mapping[str, float],
    reasons: Mapping[str, str] | None = None,
) -> ExperienceConfidence:
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

    return ExperienceConfidence(
        overall=overall,
        factors=bounded,
        weights=dict(FACTOR_WEIGHTS),
        contributions=contributions,
        reasons=written,
    )


def sample_quality_score(sample_count: int) -> float:
    """Scale sample count onto a bounded factor.

    Zero samples scores 0.0, not 1.0. An empty summary is not a perfect one.
    """
    if sample_count <= 0:
        return 0.0
    return max(0.0, min(1.0, sample_count / float(SAMPLE_QUALITY_TARGET)))


def coverage_score(observed_span_seconds: float, window_seconds: float) -> float:
    """Proportion of the window that actually contains observations."""
    if window_seconds <= 0:
        return 0.0
    return max(0.0, min(1.0, observed_span_seconds / float(window_seconds)))


def window_size_score(window_seconds: float) -> float:
    """Whether the window is long enough to describe normal behaviour.

    A day is the shortest span this platform treats as characterising normal;
    a month is full marks. Between them the score scales linearly.
    """
    day = 86_400.0
    month = 2_592_000.0
    if window_seconds <= 0:
        return 0.0
    if window_seconds >= month:
        return 1.0
    if window_seconds <= day:
        return 0.3
    return 0.3 + 0.7 * ((window_seconds - day) / (month - day))


def data_age_score(age_seconds: float | None, window_seconds: float) -> float:
    """How recent the newest observation is, relative to the window.

    ``None`` means nothing was observed, which scores 0.0 — an absence of data
    is not fresh data.
    """
    if age_seconds is None or window_seconds <= 0:
        return 0.0
    if age_seconds <= 0:
        return 1.0
    return max(0.0, min(1.0, 1.0 - (age_seconds / float(window_seconds))))
