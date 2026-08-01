"""Confidence scoring and freshness assessment.

Confidence is a weighted arithmetic mean over five bounded factors. It is an
engineering heuristic with visible inputs, not a probability, and nothing here
should ever be presented as one — see
docs/standards/confidence-freshness-standard.md.

A weighted mean was chosen over anything more elaborate because it can be
explained to a human in one sentence, and because a more sophisticated model
would imply a precision the inputs do not support.

Out-of-range factor values raise rather than being clamped. Clamping hides the
bug that produced the bad value and produces a plausible-looking score from
nonsense input.
"""

from __future__ import annotations

from typing import Any

from .models import FreshnessAssessment, ConfidenceExplanation, FreshnessState, parse_timestamp

# Weights total exactly 1.0. Asserted here, in the standard, and in the tests,
# because a drifting weight table silently rescales every score ever reported.
FACTOR_WEIGHTS: dict[str, float] = {
    "source_reliability": 0.25,
    "freshness": 0.25,
    "verification": 0.25,
    "source_agreement": 0.15,
    "completeness": 0.10,
}

# How much a source type warrants trust on its own, before anything verifies
# it. A command run against the target outranks a human recollection; neither
# reaches 1.0, because no single unverified source should.
SOURCE_RELIABILITY: dict[str, float] = {
    "git-repository": 0.9,
    "configuration-render": 0.85,
    "command-output": 0.85,
    "file-inspection": 0.8,
    "api-response": 0.8,
    "health-check": 0.75,
    "backup-report": 0.7,
    "monitoring-query": 0.7,
    "manual-attestation": 0.5,
}

DEFAULT_SOURCE_RELIABILITY = 0.5

# Fraction of the policy maximum age beyond which evidence is "aging" but not
# yet stale. Named rather than inlined so the boundary is reviewable.
AGING_THRESHOLD = 0.5


def _require_bounded(name: str, value: Any) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"confidence factor '{name}' must be numeric")
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise ValueError(f"confidence factor '{name}' must be between 0.0 and 1.0")
    return number


def source_reliability(collector_or_source: str) -> float:
    return SOURCE_RELIABILITY.get(str(collector_or_source), DEFAULT_SOURCE_RELIABILITY)


def compute_confidence(factors: dict[str, float],
                       notes: tuple[str, ...] = ()) -> ConfidenceExplanation:
    """Return the weighted mean together with every input that produced it.

    Every factor must be supplied. A missing factor defaulted to something
    convenient would change the score without appearing in the explanation,
    which is exactly the opacity this design exists to avoid.
    """
    missing = sorted(set(FACTOR_WEIGHTS) - set(factors or {}))
    if missing:
        raise ValueError(f"missing confidence factors: {', '.join(missing)}")
    unexpected = sorted(set(factors) - set(FACTOR_WEIGHTS))
    if unexpected:
        raise ValueError(f"unknown confidence factors: {', '.join(unexpected)}")

    bounded = {name: _require_bounded(name, factors[name]) for name in FACTOR_WEIGHTS}
    overall = sum(bounded[name] * weight for name, weight in FACTOR_WEIGHTS.items())

    return ConfidenceExplanation(
        overall=overall,
        factors=bounded,
        weights=dict(FACTOR_WEIGHTS),
        notes=notes,
    )


def assess_freshness(*, newest_collected_at: str | None, generated_at: str,
                     max_age_seconds: int | None) -> FreshnessAssessment:
    """Classify how current the newest supporting evidence is.

    Two cases produce `unknown` rather than a confident-looking label:

    - No supporting evidence. The freshness of nothing is unknown, never
      stale; stale means "we looked, and it was long ago".
    - No freshness policy. Inventing a default maximum age would convert an
      unanswered configuration question into a fabricated assessment.

    Both set `review_required`, so the gap surfaces instead of hiding.
    """
    if newest_collected_at is None:
        return FreshnessAssessment(
            state=FreshnessState.UNKNOWN.value,
            age_seconds=None,
            max_age_seconds=max_age_seconds,
            factor_score=0.0,
            review_required=True,
            explanation="No supporting evidence exists, so freshness is unknown rather than stale.",
        )

    age = int((parse_timestamp(generated_at) - parse_timestamp(newest_collected_at)).total_seconds())
    # Clock skew can produce a small negative age; treat it as current rather
    # than reporting a nonsensical negative.
    age = max(age, 0)

    if max_age_seconds is None:
        return FreshnessAssessment(
            state=FreshnessState.UNKNOWN.value,
            age_seconds=age,
            max_age_seconds=None,
            factor_score=0.0,
            review_required=True,
            explanation=(
                f"Evidence is {age}s old, but no freshness policy is defined. "
                "No maximum age is assumed; define a policy to make this assessable."
            ),
        )

    if max_age_seconds <= 0:
        raise ValueError("max_age_seconds must be positive when supplied")

    ratio = age / float(max_age_seconds)
    if ratio > 1.0:
        state = FreshnessState.STALE.value
        score = 0.0
        detail = "older than the policy maximum"
    elif ratio > AGING_THRESHOLD:
        state = FreshnessState.AGING.value
        score = 1.0 - ratio
        detail = "past the warning threshold but within the policy maximum"
    else:
        state = FreshnessState.CURRENT.value
        score = 1.0 - ratio
        detail = "well within the policy maximum"

    return FreshnessAssessment(
        state=state,
        age_seconds=age,
        max_age_seconds=max_age_seconds,
        factor_score=max(0.0, min(1.0, score)),
        review_required=state == FreshnessState.STALE.value,
        explanation=f"Evidence is {age}s old against a {max_age_seconds}s policy: {detail}.",
    )


def agreement_score(values: list[Any]) -> float:
    """Score how well independent observations agree.

    A single source scores moderately rather than perfectly: one source cannot
    corroborate itself, and treating it as full agreement would let one
    collector's bug look like consensus.
    """
    if not values:
        return 0.0
    if len(values) == 1:
        return 0.6
    distinct = {str(v) for v in values}
    if len(distinct) == 1:
        return 1.0
    # Proportion holding the most common value, floored so total disagreement
    # is low but not zero — disagreement is still information.
    most_common = max(sum(1 for v in values if str(v) == d) for d in distinct)
    return max(0.2, most_common / len(values))
