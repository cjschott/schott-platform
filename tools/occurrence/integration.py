"""Add temporal context to an integrity and behaviour assessment.

Three layers now say something about a target:

- **Operational Integrity** — does this match the snapshot we confirmed good?
- **Experience** — is this normal for this system?
- **Occurrence Timeline** — has this happened before, and how often?

The third changes how the first two read. `DRIFT + UNEXPECTED` occurring for
the first time is a different situation from the same pair recurring every
Tuesday for a month, and only temporal history can tell them apart.

This lives in the occurrence package on purpose. Occurrence already reads
integrity and experience vocabulary; making either depend on occurrence would
create a cycle and make the older, more conservative layers depend on the
newest one. The test suite asserts that neither imports this package.

Nothing here predicts. "Has recurred eleven times" is a fact about the past;
this module never converts it into an expectation about the future.
"""

from __future__ import annotations

from typing import Any, Sequence

from .models import OccurrenceSeries, Pattern, Recurrence

# Whether occurrence frequency is used to weight behavioural assessment.
#
# The Experience Engine deliberately uses distinct retained evidence in v0.8.5,
# which under-weights a steady metric relative to a varying one. Occurrence
# frequency is the missing input, and it is exposed here so a later release can
# apply it — but applying it would change how every existing baseline reads, so
# it is inert in this release and says so in its own output.
FREQUENCY_WEIGHTING = "not-applied"


def temporal_context(*, series: OccurrenceSeries | None,
                     patterns: Sequence[Pattern] = (),
                     integrity_status: str | None = None,
                     behaviour_status: str | None = None) -> dict[str, Any]:
    """Return the temporal reading alongside the other two axes.

    Deterministic: the same inputs always produce the same dictionary.
    """
    pattern_kinds = sorted({p.kind for p in (patterns or [])})

    if series is None or series.count == 0:
        return {
            "integrity_status": integrity_status,
            "behaviour_status": behaviour_status,
            "recurrence": Recurrence.UNKNOWN.value,
            "occurrence_count": 0,
            "first_seen": None,
            "last_seen": None,
            "frequency_per_day": None,
            "patterns": pattern_kinds,
            "explanation": (
                "No occurrences of this kind have been recorded, so there is no "
                "temporal history to draw on. Never having seen something is not "
                "evidence that it is new — it may simply never have been recorded."
            ),
            "frequency_weighting": FREQUENCY_WEIGHTING,
            "action": "advisory only; nothing is executed",
            "interpretation": "describes observed history; makes no forward claim",
        }

    first_time = series.count == 1
    if first_time:
        history = (
            f"This is the only recorded occurrence of '{series.kind}' for "
            f"{series.target}, seen at {series.first_seen}. Nothing similar has "
            "been recorded before it."
        )
    else:
        history = (
            f"'{series.kind}' has recurred {series.count} times for {series.target}, "
            f"first seen {series.first_seen} and last seen {series.last_seen}. "
            f"Spacing is {series.recurrence}."
        )

    if integrity_status or behaviour_status:
        history += (
            f" The integrity comparison reported {integrity_status or 'nothing'} and "
            f"the behavioural comparison reported {behaviour_status or 'nothing'}. "
        )
        if not first_time:
            history += (
                "Because this has happened before, the current reading is a repeat "
                "rather than a first occurrence — which is a statement about what "
                "has been recorded, not about what will happen next."
            )
        else:
            history += (
                "Because nothing like it has been recorded before, there is no "
                "temporal history to compare it against."
            )

    return {
        "integrity_status": integrity_status,
        "behaviour_status": behaviour_status,
        "recurrence": series.recurrence,
        "occurrence_count": series.count,
        "first_seen": series.first_seen,
        "last_seen": series.last_seen,
        "frequency_per_day": (round(series.frequency_per_day, 6)
                              if series.frequency_per_day is not None else None),
        "patterns": pattern_kinds,
        "explanation": history,
        "frequency_weighting": FREQUENCY_WEIGHTING,
        "action": "advisory only; nothing is executed",
        "interpretation": "describes observed history; makes no forward claim",
    }
