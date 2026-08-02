"""Create occurrences, and derive them from evidence.

An occurrence is one thing that happened at one time. It is created here, cites
the record it came from, and is never modified afterwards.

Deriving from evidence is strictly read-only: the evidence store is opened,
read, and left byte-identical. Nothing in this module can write to it, and the
test suite asserts that after every derivation.
"""

from __future__ import annotations

from typing import Any

from tools.collectors.redaction import redact_text

from .models import ID_PATTERNS, Occurrence, require_timezone


class RecorderError(Exception):
    """An occurrence could not be recorded. Never contains a flagged value."""


def record_occurrence(*, occurrence_id: str, target: str, kind: str,
                      occurred_at: str, source: str, recorded_at: str,
                      detail: str = "") -> Occurrence:
    """Create one immutable occurrence.

    `occurred_at` is when the thing happened; `recorded_at` is when the
    platform noticed. Keeping them separate is what lets a late-arriving
    observation be placed correctly in history rather than at the moment it was
    processed.
    """
    pattern = ID_PATTERNS["occurrence"]
    if not pattern.match(str(occurrence_id)):
        raise ValueError(f"occurrence identifier '{occurrence_id}' is not valid")
    if not target:
        raise ValueError("an occurrence requires a target")
    if not kind:
        raise ValueError("an occurrence requires a kind")
    if not source:
        raise ValueError(
            "an occurrence must cite the record it was derived from; a temporal "
            "claim that names no source cannot be audited"
        )

    happened = require_timezone(occurred_at, "occurred_at")
    noticed = require_timezone(recorded_at, "recorded_at")

    # Detail is operator-facing prose that occasionally carries a URL with an
    # embedded credential. Redacted before it can reach an immutable record.
    safe_detail, _ = redact_text(str(detail or ""))

    return Occurrence(
        id=occurrence_id, target=str(target), kind=str(kind),
        occurred_at=happened, recorded_at=noticed, source=str(source),
        detail=safe_detail,
    )


def occurrences_from_evidence(evidence_store, *, target: str, kind: str,
                              recorded_at: str, id_prefix: str = "OCC",
                              start_index: int = 1) -> list[Occurrence]:
    """Derive one occurrence per evidence record, oldest first.

    Read-only. Identifiers are assigned positionally from `start_index` so a
    caller that is not persisting does not have to consume store sequence
    numbers; a caller that *is* persisting passes allocated identifiers by
    building occurrences itself.

    Failed and unavailable collections are excluded. A collector that could not
    look observed nothing, and recording that as something that happened would
    put an outage into the history of the target.
    """
    if evidence_store is None:
        raise RecorderError("an evidence store is required to derive occurrences")

    stamp = require_timezone(recorded_at, "recorded_at")

    records = [
        record for record in evidence_store.list_evidence(target)
        if str(record.get("status")) not in {"failed", "unavailable"}
        and record.get("collected_at")
    ]

    # Sorted by collection time then identifier, so two records sharing an
    # instant derive in a stable order rather than whatever the store returned.
    ordered = sorted(records, key=lambda r: (str(r.get("collected_at")), str(r.get("id"))))

    occurrences: list[Occurrence] = []
    for offset, record in enumerate(ordered):
        occurrences.append(record_occurrence(
            occurrence_id=f"{id_prefix}-{start_index + offset:06d}",
            target=target, kind=kind,
            occurred_at=str(record.get("collected_at")),
            source=str(record.get("id") or "unknown"),
            recorded_at=stamp,
        ))
    return occurrences
