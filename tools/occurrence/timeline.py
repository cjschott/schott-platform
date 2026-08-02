"""Build an ordered view of what happened.

A timeline is a chronology across kinds: restarts, deploys, and observations
read as one sequence rather than as several stores an operator has to reconcile
by hand.

Ordering is by `occurred_at` then identifier. The tiebreak is not cosmetic —
occurrences frequently share an instant, and without a deterministic secondary
sort two reads of the same history would disagree about their order, which
makes the timeline useless for exactly the incident review it exists for.
"""

from __future__ import annotations

from typing import Iterable

from .models import (
    ID_PATTERNS,
    Occurrence,
    Timeline,
    readonly,
    require_timezone,
)
from .series import interval_seconds


class TimelineError(Exception):
    """A timeline could not be built. Never contains an observed value."""


def build_timeline(occurrences: Iterable[Occurrence], *, timeline_id: str,
                   generated_at: str, target: str,
                   limit: int | None = None) -> Timeline:
    """Return occurrences in chronological order.

    Deterministic and order-independent: the input is sorted internally, so the
    same set always produces the same timeline.
    """
    pattern = ID_PATTERNS["timeline"]
    if not pattern.match(str(timeline_id)):
        raise TimelineError(f"timeline identifier '{timeline_id}' is not valid")

    stamp = require_timezone(generated_at, "generated_at")
    ordered = sorted(occurrences or [], key=lambda o: (o.occurred_at, o.id))

    if limit is not None and limit > 0:
        # Most recent entries, still in chronological order so a reader moves
        # through them in the same direction as the full timeline.
        ordered = ordered[-limit:]

    if not ordered:
        return Timeline(
            id=timeline_id, target=target, generated_at=stamp, entry_count=0,
        )

    entries = tuple(
        readonly({
            "id": occurrence.id,
            "kind": occurrence.kind,
            "occurred_at": occurrence.occurred_at,
            "source": occurrence.source,
        })
        for occurrence in ordered
    )

    earliest = ordered[0].occurred_at
    latest = ordered[-1].occurred_at

    return Timeline(
        id=timeline_id, target=target, generated_at=stamp,
        entry_count=len(entries), entries=entries,
        earliest=earliest, latest=latest,
        span_seconds=interval_seconds(earliest, latest),
        kinds=tuple(sorted({occurrence.kind for occurrence in ordered})),
    )
