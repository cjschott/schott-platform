"""Summarize every occurrence of one kind into a series.

First seen, last seen, intervals, frequency, and recurrence become first-class
here. All of it is arithmetic over timestamps that already happened.

Two rules govern the module, and both have tests:

- **Never invent a temporal measure.** One occurrence has no interval and no
  frequency; both are ``None``, not ``0``. A mean interval of zero would say
  everything happened at once.
- **Frequency describes the observed span, not the future.** It is a count
  divided by the period actually watched. Nothing treats it as a rate expected
  to continue.
"""

from __future__ import annotations

import math
from typing import Iterable, Sequence

from .confidence import (
    MINIMUM_SERIES_OCCURRENCES,
    age_score,
    compute_temporal_confidence,
    count_score,
    regularity_score,
    span_score,
)
from .models import (
    ID_PATTERNS,
    Occurrence,
    OccurrenceSeries,
    Recurrence,
    parse_timestamp,
    require_timezone,
)

SECONDS_PER_DAY = 86_400.0

# A series whose interval spread exceeds this fraction of its mean interval is
# irregular rather than regular. Named so the boundary is reviewable; it is an
# engineering convention, not a statistical threshold.
REGULARITY_COEFFICIENT = 0.25


class SeriesError(Exception):
    """A series could not be built. Never contains an observed value."""


def interval_seconds(earlier: str, later: str) -> int:
    """Whole seconds between two timestamps, in order."""
    return int((parse_timestamp(later) - parse_timestamp(earlier)).total_seconds())


def _population_deviation(values: Sequence[float]) -> float | None:
    """Population standard deviation, or None when there is nothing to spread.

    Population rather than sample: these are complete observations of a window,
    and the population form is defined for a single value where the sample form
    is not.
    """
    if not values:
        return None
    if len(values) == 1:
        return 0.0
    mean = sum(values) / len(values)
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return math.sqrt(variance)


def _median(values: Sequence[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    midpoint = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return float(ordered[midpoint])
    return (ordered[midpoint - 1] + ordered[midpoint]) / 2.0


def build_series(occurrences: Iterable[Occurrence], *, series_id: str,
                 generated_at: str, target: str, kind: str) -> OccurrenceSeries:
    """Summarize occurrences into a series.

    Deterministic and order-independent: occurrences are sorted internally by
    time then identifier, so the same set always produces the same series
    regardless of the order it arrived in.
    """
    pattern = ID_PATTERNS["series"]
    if not pattern.match(str(series_id)):
        raise SeriesError(f"series identifier '{series_id}' is not valid")

    stamp = require_timezone(generated_at, "generated_at")
    ordered = sorted(occurrences or [], key=lambda o: (o.occurred_at, o.id))

    if not ordered:
        # Nothing observed. Every temporal measure is null rather than zero:
        # an unobserved series and a series of instantaneous events are
        # different things, and only one of them is real here.
        confidence = compute_temporal_confidence(
            {"occurrence_count": 0.0, "observation_span": 0.0,
             "interval_regularity": 0.0, "data_age": 0.0},
            reasons={"occurrence_count": "No occurrences were observed."},
        )
        return OccurrenceSeries(
            id=series_id, target=target, kind=kind, generated_at=stamp, count=0,
            recurrence=Recurrence.UNKNOWN.value,
            recurrence_explanation=(
                "No occurrences were observed, so recurrence is unknown rather "
                "than regular."
            ),
            confidence=confidence,
        )

    first_seen = ordered[0].occurred_at
    last_seen = ordered[-1].occurred_at
    span = interval_seconds(first_seen, last_seen)

    intervals = [
        interval_seconds(a.occurred_at, b.occurred_at)
        for a, b in zip(ordered, ordered[1:])
    ]

    if intervals:
        mean_interval = sum(intervals) / len(intervals)
        median_interval = _median(intervals)
        minimum_interval = min(intervals)
        maximum_interval = max(intervals)
        deviation = _population_deviation([float(i) for i in intervals])
    else:
        mean_interval = median_interval = deviation = None
        minimum_interval = maximum_interval = None

    # Frequency over the observed span only. A single occurrence spans no time,
    # so it yields no frequency rather than an infinite or invented one.
    frequency = None
    if span > 0:
        frequency = len(ordered) / (span / SECONDS_PER_DAY)

    recurrence, explanation = _classify_recurrence(len(ordered), mean_interval, deviation)

    age = interval_seconds(last_seen, stamp) if stamp >= last_seen else 0
    confidence = compute_temporal_confidence(
        {
            "occurrence_count": count_score(len(ordered)),
            "observation_span": span_score(span),
            "interval_regularity": regularity_score(mean_interval, deviation),
            "data_age": age_score(age, span),
        },
        reasons={
            "occurrence_count": f"{len(ordered)} occurrence(s) observed.",
            "observation_span": f"Observations span {span}s.",
            "interval_regularity": (
                f"Interval spread is {deviation:.1f}s against a {mean_interval:.1f}s mean."
                if mean_interval and deviation is not None else
                "Too few intervals to assess regularity."
            ),
            "data_age": f"Newest occurrence is {age}s old.",
        },
    )

    return OccurrenceSeries(
        id=series_id, target=target, kind=kind, generated_at=stamp,
        count=len(ordered),
        occurrences=tuple(o.id for o in ordered),
        first_seen=first_seen, last_seen=last_seen,
        observation_span_seconds=span,
        intervals_seconds=intervals,
        mean_interval_seconds=mean_interval,
        median_interval_seconds=median_interval,
        minimum_interval_seconds=minimum_interval,
        maximum_interval_seconds=maximum_interval,
        interval_deviation_seconds=deviation,
        frequency_per_day=frequency,
        recurrence=recurrence,
        recurrence_explanation=explanation,
        confidence=confidence,
    )


def _classify_recurrence(count: int, mean_interval: float | None,
                         deviation: float | None) -> tuple[str, str]:
    """Classify spacing deterministically, and say why.

    The comparison is the coefficient of variation — spread relative to the
    mean gap — so a series of daily events and a series of yearly events are
    judged on consistency rather than on absolute size.
    """
    if count == 0:
        return (Recurrence.UNKNOWN.value,
                "No occurrences were observed, so recurrence is unknown.")
    if count == 1:
        return (Recurrence.SINGLE.value,
                "One occurrence was observed. A single event has no spacing, so "
                "no rhythm is claimed.")
    if count < MINIMUM_SERIES_OCCURRENCES:
        return (Recurrence.IRREGULAR.value,
                f"{count} occurrences give a single interval, which is not enough "
                "to establish a rhythm.")
    if not mean_interval or deviation is None or mean_interval <= 0:
        return (Recurrence.UNKNOWN.value,
                "Intervals could not be measured, so recurrence is unknown.")

    coefficient = deviation / mean_interval
    if coefficient <= REGULARITY_COEFFICIENT:
        return (Recurrence.REGULAR.value,
                f"Interval spread is {coefficient:.0%} of the mean gap, within the "
                f"{REGULARITY_COEFFICIENT:.0%} regularity threshold.")
    return (Recurrence.IRREGULAR.value,
            f"Interval spread is {coefficient:.0%} of the mean gap, above the "
            f"{REGULARITY_COEFFICIENT:.0%} regularity threshold.")
