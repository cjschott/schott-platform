"""Build operational baselines and classify current behaviour against them.

A baseline says what has been *typical*. It never says what is *correct*. That
distinction is the whole reason this layer is separate from evidence: 98% CPU
being unusual is a statement about history, not a fault.

Three rules keep the classification honest, and each has a test:

- **Missing observations are ``UNKNOWN``, never ``UNEXPECTED``.** Never having
  watched something is not evidence that it is misbehaving.
- **A thin history is ``INSUFFICIENT_EVIDENCE``, never ``UNEXPECTED``.** Two
  samples cannot establish what normal looks like.
- **Nothing is invented.** A baseline with no samples has no typical value.

Baselines are never replaced automatically. A newer baseline is a new record;
choosing which one represents normal is a human decision.
"""

from __future__ import annotations

from typing import Iterable, Sequence

from .confidence import (
    MINIMUM_USABLE_SAMPLES,
    compute_experience_confidence,
    coverage_score,
    data_age_score,
    sample_quality_score,
    window_size_score,
)
from .models import (
    BaselineStatus,
    BehaviourAssessment,
    ExperienceProfile,
    OperationalBaseline,
    Trend,
    parse_timestamp,
    require_timezone,
)

# How many standard deviations from typical a value may sit and still be
# ordinary. Named so the boundary is reviewable; three sigma is a conventional
# engineering choice, not a statistical claim about a distribution nobody has
# verified is normal.
TOLERANCE_SIGMA = 3.0

# The floor for tolerance, as a fraction of the typical value. Without it a
# perfectly steady metric would have zero tolerance and every reading would be
# unexpected the moment it moved at all.
MINIMUM_TOLERANCE_RATIO = 0.10


class BaselineError(Exception):
    """A baseline could not be built. Never contains an observed value."""


def build_baseline(profiles: Sequence[ExperienceProfile] | Iterable[ExperienceProfile],
                   *, baseline_id: str, generated_at: str, target: str,
                   metric: str) -> OperationalBaseline:
    """Summarize one or more profiles into what is typical.

    Deterministic: identical profiles and identifier produce an identical
    baseline.
    """
    profile_list = list(profiles or [])
    stamp = require_timezone(generated_at, "generated_at")

    contributing = [p for p in profile_list if p.sample_count > 0 and p.mean is not None]
    total_samples = sum(p.sample_count for p in profile_list)

    if not contributing:
        # No typical value is invented. A baseline that reports 0.0 because it
        # observed nothing is indistinguishable from one that observed zero.
        confidence = compute_experience_confidence(
            {"coverage": 0.0, "sample_quality": 0.0, "window_size": 0.0, "data_age": 0.0},
            reasons={
                "sample_quality": "No samples were observed, so nothing is summarized.",
                "coverage": "The window contains no observations.",
            },
        )
        return OperationalBaseline(
            id=baseline_id, target=target, metric=metric, generated_at=stamp,
            typical_value=None, tolerance=None, sample_count=0,
            profiles=tuple(p.id for p in profile_list),
            windows=tuple(p.window_label for p in profile_list),
            confidence=confidence, trend=Trend.UNKNOWN.value, review_required=True,
        )

    # Weighted by sample count so a window holding more observations carries
    # more of the answer. The median of each profile is preferred over its mean
    # because a single spike should not move what "typical" means.
    weighted_total = sum((p.median if p.median is not None else p.mean) * p.sample_count
                         for p in contributing)
    typical = weighted_total / sum(p.sample_count for p in contributing)

    deviations = [p.standard_deviation for p in contributing if p.standard_deviation is not None]
    spread = max(deviations) if deviations else 0.0
    tolerance = max(TOLERANCE_SIGMA * spread, abs(typical) * MINIMUM_TOLERANCE_RATIO)

    window_seconds = _window_seconds(contributing)
    observed_span = _observed_span_seconds(contributing)
    age_seconds = _newest_age_seconds(contributing, stamp)

    confidence = compute_experience_confidence(
        {
            "coverage": coverage_score(observed_span, window_seconds),
            "sample_quality": sample_quality_score(total_samples),
            "window_size": window_size_score(window_seconds),
            "data_age": data_age_score(age_seconds, window_seconds),
        },
        reasons={
            "sample_quality": f"{total_samples} sample(s) across {len(contributing)} window(s).",
            "coverage": f"Observations span {int(observed_span)}s of a {int(window_seconds)}s window.",
            "data_age": (f"Newest observation is {int(age_seconds)}s old."
                         if age_seconds is not None else "No observation age is known."),
        },
    )

    trends = {p.trend for p in contributing}
    trend = trends.pop() if len(trends) == 1 else Trend.UNKNOWN.value

    return OperationalBaseline(
        id=baseline_id, target=target, metric=metric, generated_at=stamp,
        typical_value=typical, tolerance=tolerance, sample_count=total_samples,
        profiles=tuple(p.id for p in profile_list),
        windows=tuple(p.window_label for p in profile_list),
        confidence=confidence, trend=trend,
        # Review is required whenever the history is too thin to lean on.
        review_required=total_samples < MINIMUM_USABLE_SAMPLES,
    )


def _window_seconds(profiles: Sequence[ExperienceProfile]) -> float:
    spans = []
    for profile in profiles:
        try:
            spans.append((parse_timestamp(profile.window_end)
                          - parse_timestamp(profile.window_start)).total_seconds())
        except (ValueError, TypeError):
            continue
    return max(spans) if spans else 0.0


def _observed_span_seconds(profiles: Sequence[ExperienceProfile]) -> float:
    # Approximated by the widest window that actually produced samples. This is
    # deliberately coarse and is described as coverage, not as a measurement of
    # sampling density.
    return _window_seconds([p for p in profiles if p.sample_count > 0])


def _newest_age_seconds(profiles: Sequence[ExperienceProfile], now: str) -> float | None:
    ends = []
    for profile in profiles:
        try:
            ends.append(parse_timestamp(profile.window_end))
        except (ValueError, TypeError):
            continue
    if not ends:
        return None
    return max(0.0, (parse_timestamp(now) - max(ends)).total_seconds())


def classify_behaviour(baseline: OperationalBaseline | None, *,
                       current_value: float | None) -> BehaviourAssessment:
    """Compare a current value against what has been typical.

    Returns ``EXPECTED``, ``UNEXPECTED``, ``UNKNOWN``, or
    ``INSUFFICIENT_EVIDENCE``. The last two are not failure modes — they are
    honest answers, and reporting either as ``UNEXPECTED`` would manufacture an
    alarm out of an absence of watching.
    """
    if baseline is None:
        return BehaviourAssessment(
            status=BaselineStatus.UNKNOWN.value,
            current_value=current_value, typical_value=None, difference=None,
            tolerance=None, baseline=None,
            explanation=(
                "No baseline exists for this metric, so nothing is known about what "
                "is normal. This is an absence of history, not abnormal behaviour."
            ),
        )

    if baseline.typical_value is None or baseline.sample_count == 0:
        return BehaviourAssessment(
            status=BaselineStatus.UNKNOWN.value,
            current_value=current_value, typical_value=None, difference=None,
            tolerance=None, baseline=baseline.id,
            explanation=(
                f"Baseline {baseline.id} summarizes no observations, so there is no "
                "typical value to compare against. Missing observations are not "
                "unexpected behaviour."
            ),
            confidence=baseline.confidence,
        )

    if baseline.sample_count < MINIMUM_USABLE_SAMPLES:
        return BehaviourAssessment(
            status=BaselineStatus.INSUFFICIENT_EVIDENCE.value,
            current_value=current_value, typical_value=baseline.typical_value,
            difference=None, tolerance=baseline.tolerance, baseline=baseline.id,
            explanation=(
                f"Baseline {baseline.id} rests on {baseline.sample_count} sample(s), "
                f"fewer than the {MINIMUM_USABLE_SAMPLES} needed to characterise normal "
                "behaviour. A thin history does not make a system abnormal."
            ),
            confidence=baseline.confidence,
        )

    if current_value is None:
        return BehaviourAssessment(
            status=BaselineStatus.UNKNOWN.value,
            current_value=None, typical_value=baseline.typical_value,
            difference=None, tolerance=baseline.tolerance, baseline=baseline.id,
            explanation=(
                f"No current value was observed for comparison against baseline "
                f"{baseline.id}, so behaviour is unknown rather than unexpected."
            ),
            confidence=baseline.confidence,
        )

    difference = abs(float(current_value) - baseline.typical_value)
    tolerance = baseline.tolerance if baseline.tolerance is not None else 0.0
    within = difference <= tolerance

    status = BaselineStatus.EXPECTED.value if within else BaselineStatus.UNEXPECTED.value
    verdict = "within" if within else "outside"
    explanation = (
        f"Current value {float(current_value):.4g} differs from the typical "
        f"{baseline.typical_value:.4g} by {difference:.4g}, which is {verdict} the "
        f"tolerance of {tolerance:.4g} derived from baseline {baseline.id} "
        f"({baseline.sample_count} sample(s)). "
        + ("This describes what has been observed, not what is correct."
           if within else
           "This is a statement about operational history, not a fault.")
    )

    return BehaviourAssessment(
        status=status, current_value=float(current_value),
        typical_value=baseline.typical_value, difference=difference,
        tolerance=tolerance, baseline=baseline.id, explanation=explanation,
        confidence=baseline.confidence,
    )
