"""Deterministic descriptive statistics.

Standard library only. No numeric library, no model, no randomness — every
function here is a closed-form summary of numbers that were already observed,
and the same input always produces the same output.

Two rules govern everything in this module:

- **Never invent a statistic.** With no samples every measure is ``None``, not
  ``0``. A mean of zero and no mean at all are different claims.
- **Never imply more precision than the samples support.** One sample has no
  deviation and no direction; both are reported as such rather than as zero
  and stable.
"""

from __future__ import annotations

import math
from typing import Any, Iterable, Sequence

from .models import Trend

# Below this many samples a direction cannot be claimed. Two points make a
# line through noise, which is not a trend.
MINIMUM_TREND_SAMPLES = 3

# A series whose direction reverses on more than this fraction of its steps is
# volatile rather than directional. Named so the boundary is reviewable.
#
# Direction changes rather than total spread: a clean ramp from 1 to 100 has an
# enormous spread and is perfectly directional, so spread alone would call
# every steady climb "volatile" and hide exactly the trend worth seeing.
VOLATILITY_REVERSAL_RATIO = 0.5

# Relative change between the first and second half below which a series is
# called stable rather than moving.
STABILITY_RATIO = 0.05


def _numeric(samples: Iterable[Any]) -> list[float]:
    """Keep only values that are genuinely numeric.

    A value that cannot be parsed is dropped rather than coerced: guessing
    what a non-numeric reading meant would put a fabricated number into a
    summary that looks measured.
    """
    values: list[float] = []
    for sample in samples:
        if isinstance(sample, bool):
            continue
        if isinstance(sample, (int, float)):
            values.append(float(sample))
            continue
        if isinstance(sample, str):
            try:
                values.append(float(sample.strip()))
            except ValueError:
                continue
    return values


def population_standard_deviation(values: Sequence[float]) -> float | None:
    """Population standard deviation.

    Population rather than sample: these are complete observations of a window,
    not a sample drawn from a larger set, and the population form is defined
    for a single value where the sample form is not.
    """
    if not values:
        return None
    if len(values) == 1:
        return 0.0
    mean = sum(values) / len(values)
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return math.sqrt(variance)


def median(values: Sequence[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return ordered[midpoint]
    return (ordered[midpoint - 1] + ordered[midpoint]) / 2.0


def summarize_samples(samples: Iterable[Any]) -> dict[str, Any]:
    """Return the descriptive statistics for a set of samples.

    Order-independent: sorting happens internally, so the same multiset always
    produces the same summary.
    """
    values = _numeric(samples)

    if not values:
        # Every measure is null. Reporting zeros here would let an unobserved
        # metric look like a metric that was measured at zero.
        return {
            "sample_count": 0,
            "minimum": None,
            "maximum": None,
            "mean": None,
            "median": None,
            "standard_deviation": None,
        }

    return {
        "sample_count": len(values),
        "minimum": min(values),
        "maximum": max(values),
        "mean": sum(values) / len(values),
        "median": median(values),
        "standard_deviation": population_standard_deviation(values),
    }


def detect_trend(samples: Iterable[Any]) -> dict[str, Any]:
    """Classify the direction of a chronologically ordered series.

    Deterministic and explainable by construction: the series is split in half,
    the halves' means are compared, and spread decides whether the movement is
    directional or merely noisy. No fitting, no smoothing, no model.

    Callers must pass samples oldest first; this function does not reorder
    them, because reordering would destroy the direction it is measuring.
    """
    values = _numeric(samples)

    if len(values) < MINIMUM_TREND_SAMPLES:
        return {
            "trend": Trend.UNKNOWN.value,
            "explanation": (
                f"{len(values)} sample(s) is fewer than the {MINIMUM_TREND_SAMPLES} "
                "needed to claim a direction, so the trend is unknown rather than stable."
            ),
        }

    mean = sum(values) / len(values)
    scale = abs(mean) if abs(mean) > 1e-9 else 1.0

    # Volatility is judged first, by counting how often the series reverses
    # direction. A series that flips back and forth has no useful direction
    # even when its halves happen to differ.
    deltas = [b - a for a, b in zip(values, values[1:])]
    signs = [1 if delta > 0 else (-1 if delta < 0 else 0) for delta in deltas]
    moving = [sign for sign in signs if sign != 0]

    if not moving:
        return {
            "trend": Trend.STABLE.value,
            "explanation": (
                f"All {len(values)} samples are identical, so the series is stable."
            ),
        }

    # Amplitude gates volatility. A metric wobbling between 26% and 28% around
    # a mean of 27 reverses on every step and is plainly steady; calling that
    # volatile would bury real instability under routine noise.
    deviation = population_standard_deviation(values) or 0.0
    relative_spread = deviation / scale
    if relative_spread <= STABILITY_RATIO:
        return {
            "trend": Trend.STABLE.value,
            "explanation": (
                f"Spread is {relative_spread:.2%} of the mean, within the "
                f"{STABILITY_RATIO:.0%} stability threshold, so the series is steady."
            ),
        }

    reversals = sum(1 for a, b in zip(moving, moving[1:]) if a != b)
    comparisons = max(len(moving) - 1, 1)
    reversal_ratio = reversals / comparisons
    if reversal_ratio > VOLATILITY_REVERSAL_RATIO:
        return {
            "trend": Trend.VOLATILE.value,
            "explanation": (
                f"The series reverses direction on {reversals} of {comparisons} step(s) "
                f"({reversal_ratio:.0%}), above the {VOLATILITY_REVERSAL_RATIO:.0%} "
                "threshold, so no direction is claimed."
            ),
        }

    midpoint = len(values) // 2
    first_half = values[:midpoint]
    second_half = values[midpoint:] if len(values) % 2 == 0 else values[midpoint + 1:]
    if not first_half or not second_half:
        return {
            "trend": Trend.UNKNOWN.value,
            "explanation": "The series could not be split into two comparable halves.",
        }

    first_mean = sum(first_half) / len(first_half)
    second_mean = sum(second_half) / len(second_half)
    change = second_mean - first_mean
    relative = abs(change) / scale

    if relative <= STABILITY_RATIO:
        return {
            "trend": Trend.STABLE.value,
            "explanation": (
                f"The second half's mean differs from the first by {relative:.2%}, "
                f"within the {STABILITY_RATIO:.0%} stability threshold."
            ),
        }

    direction = Trend.INCREASING.value if change > 0 else Trend.DECREASING.value
    return {
        "trend": direction,
        "explanation": (
            f"The second half's mean ({second_mean:.4g}) differs from the first "
            f"({first_mean:.4g}) by {relative:.2%}, above the {STABILITY_RATIO:.0%} "
            f"stability threshold, so the series is {direction}."
        ),
    }
