"""Recognise temporal shapes in a series.

Every pattern here is a statement about observed history. None says anything
about what happens next, and the model carries no field in which such a claim
could be recorded.

Detection is deterministic and explainable by construction: each rule is a
comparison between measured quantities, and each pattern carries the sentence
that justifies it. There is no fitting, no smoothing, and no model.

The distinction that matters: a series being *recurring* means it has recurred,
not that it will. Presenting the first as the second is the single easiest way
for a descriptive system to start making promises it cannot keep.
"""

from __future__ import annotations

from .models import ID_PATTERNS, OccurrenceSeries, Pattern, PatternKind, Recurrence

# A gap this many times the median interval separates a burst from the history
# before it. Named so the boundary is reviewable.
BURST_GAP_MULTIPLE = 5.0

# Minimum occurrences packed after that gap before it is called a burst.
BURST_MINIMUM_EVENTS = 3

# Relative change between the first and second half of the intervals above
# which the spacing is called accelerating or decelerating.
RATE_CHANGE_RATIO = 0.5


def detect_patterns(series: OccurrenceSeries, *, pattern_id_prefix: str = "PAT",
                    generated_at: str | None = None,
                    start_index: int = 1) -> list[Pattern]:
    """Return the patterns a series exhibits, in a deterministic order.

    An empty series yields no patterns. Inventing one would be the clearest
    possible case of describing something nobody observed.
    """
    if series is None or series.count == 0:
        return []

    stamp = generated_at or series.generated_at
    found: list[tuple[str, str]] = []

    intervals = [float(i) for i in (series.intervals_seconds or [])]

    # --- isolated ----------------------------------------------------------
    if series.count == 1:
        found.append((
            PatternKind.ISOLATED.value,
            f"One occurrence of '{series.kind}' was observed, at "
            f"{series.first_seen}. A single event has no spacing and no rhythm.",
        ))

    # --- recurring ---------------------------------------------------------
    if series.recurrence == Recurrence.REGULAR.value and series.mean_interval_seconds:
        found.append((
            PatternKind.RECURRING.value,
            f"{series.count} occurrences of '{series.kind}' are evenly spaced, "
            f"averaging {series.mean_interval_seconds:.0f}s apart. "
            f"{series.recurrence_explanation} This describes what has recurred, "
            "not what will.",
        ))

    # --- burst -------------------------------------------------------------
    # A long quiet period followed by several closely packed events. Judged
    # against the median gap so one enormous outlier does not define "long".
    if len(intervals) >= BURST_MINIMUM_EVENTS and series.median_interval_seconds:
        median = float(series.median_interval_seconds)
        if median > 0:
            longest = max(intervals)
            gap_index = intervals.index(longest)
            after = intervals[gap_index + 1:]
            if (longest >= BURST_GAP_MULTIPLE * median
                    and len(after) >= BURST_MINIMUM_EVENTS - 1
                    and all(value <= median for value in after)):
                found.append((
                    PatternKind.BURST.value,
                    f"A gap of {longest:.0f}s — more than {BURST_GAP_MULTIPLE:g}x the "
                    f"{median:.0f}s median — is followed by {len(after) + 1} occurrences "
                    f"no further apart than the median. The occurrences after the "
                    "gap are clustered.",
                ))

    # --- accelerating / decelerating --------------------------------------
    # Compares the mean gap of the first half against the second. A shrinking
    # gap means events came closer together over the observed period; it says
    # nothing about whether they continue to.
    if len(intervals) >= 4:
        midpoint = len(intervals) // 2
        first_half = intervals[:midpoint]
        second_half = intervals[midpoint:]
        first_mean = sum(first_half) / len(first_half)
        second_mean = sum(second_half) / len(second_half)
        if first_mean > 0:
            change = (second_mean - first_mean) / first_mean
            if change <= -RATE_CHANGE_RATIO:
                found.append((
                    PatternKind.ACCELERATING.value,
                    f"The mean gap fell from {first_mean:.0f}s to {second_mean:.0f}s "
                    f"({abs(change):.0%}) across the observed period. Occurrences came "
                    "closer together over the history recorded.",
                ))
            elif change >= RATE_CHANGE_RATIO:
                found.append((
                    PatternKind.DECELERATING.value,
                    f"The mean gap rose from {first_mean:.0f}s to {second_mean:.0f}s "
                    f"({change:.0%}) across the observed period. Occurrences spread "
                    "further apart over the history recorded.",
                ))

    id_pattern = ID_PATTERNS["pattern"]
    patterns: list[Pattern] = []
    for offset, (kind, explanation) in enumerate(found):
        identifier = f"{pattern_id_prefix}-{start_index + offset:06d}"
        if not id_pattern.match(identifier):
            raise ValueError(f"pattern identifier '{identifier}' is not valid")
        patterns.append(Pattern(
            id=identifier, target=series.target, kind=kind, detected_at=stamp,
            series=(series.id,), explanation=explanation,
            occurrence_count=series.count, confidence=series.confidence,
        ))
    return patterns
