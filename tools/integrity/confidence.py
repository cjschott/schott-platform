"""Confidence scoring for integrity analysis.

Every score carries its factors, weights, contributions, and a written reason
per factor. There are no opaque confidence values here: a bare number invites
a probabilistic reading, and the reason text is what makes the score
reviewable rather than merely reportable.

This is an engineering heuristic, not a probability. `0.7` does not mean a 70%
chance the twin matches; it means these factors produced `0.7`, and a human can
see why and disagree.

Out-of-range and missing factors raise rather than being clamped or defaulted.
A clamped value hides the bug that produced it, and a defaulted factor changes
the score without appearing in the explanation.
"""

from __future__ import annotations

from typing import Any, Mapping

from .models import IntegrityConfidence

# Weights total exactly 1.0, asserted here and in the test suite. A drifting
# weight table silently rescales every score ever reported.
FACTOR_WEIGHTS: dict[str, float] = {
    # How much of the snapshot could actually be compared. A conclusion drawn
    # from two facts out of fifty deserves less weight than a full comparison.
    "coverage": 0.30,
    # How current the knowledge behind the twin is.
    "knowledge_freshness": 0.25,
    # How much the underlying knowledge trusted itself.
    "knowledge_confidence": 0.25,
    # Whether the snapshot is a usable reference at all.
    "snapshot_integrity": 0.10,
    # Whether the comparison reached a determinate answer.
    "determinacy": 0.10,
}

FACTOR_REASONS: dict[str, str] = {
    "coverage": "Proportion of snapshot facts the twin could be compared against.",
    "knowledge_freshness": "How current the knowledge the twin was rebuilt from is.",
    "knowledge_confidence": "Confidence the observation layer reported for that knowledge.",
    "snapshot_integrity": "Whether the snapshot carries a fingerprint and a schema version.",
    "determinacy": "Whether the comparison reached a determinate answer rather than unknown.",
}


def _require_bounded(name: str, value: Any) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"confidence factor '{name}' must be numeric")
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise ValueError(f"confidence factor '{name}' must be between 0.0 and 1.0")
    return number


def compute_integrity_confidence(
    factors: Mapping[str, float],
    reasons: Mapping[str, str] | None = None,
) -> IntegrityConfidence:
    """Return the weighted mean with every input visible.

    Every factor must be supplied. A missing factor quietly defaulted would
    change the result without appearing in the explanation, which is exactly
    the opacity this design exists to avoid.
    """
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

    return IntegrityConfidence(
        overall=overall,
        factors=bounded,
        weights=dict(FACTOR_WEIGHTS),
        contributions=contributions,
        reasons=written,
    )


def coverage_score(comparable: int, total: int) -> float:
    """Proportion of snapshot facts the twin could be compared against.

    Zero comparable facts scores 0.0 rather than 1.0. An empty comparison is
    not a perfect one, and treating it as such is how a system reports
    confident agreement about nothing.
    """
    if total <= 0:
        return 0.0
    return max(0.0, min(1.0, comparable / float(total)))


def freshness_score(freshness: str) -> float:
    """Map a knowledge freshness state onto a bounded factor."""
    return {
        "current": 1.0,
        "aging": 0.6,
        "stale": 0.2,
        "unknown": 0.0,
    }.get(str(freshness), 0.0)
