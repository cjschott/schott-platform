"""Decide whether an observation is genuinely new.

A collector on a schedule reports the same thing over and over. Storing each
repetition as new evidence is honest and unusable: the signal drowns in
hundreds of identical records a day. Storing nothing loses the knowledge that
the fact was reconfirmed.

The resolution is that identical content refreshes freshness without creating
a second record, and anything else creates evidence.

Duplicate detection is scoped by target, collector, and fact namespace, and
keyed on the canonical fingerprint. It deliberately does **not** key on time:
two observations a week apart with identical content are the same fact
observed twice, and treating the timestamp as part of the identity would make
every observation unique and the whole mechanism pointless.
"""

from __future__ import annotations

from typing import Any, Iterable

from .models import Observation


def fact_namespace(facts: dict[str, Any]) -> tuple[str, ...]:
    """The sorted fact names an observation covers.

    Part of the duplicate scope because a collector reporting a different set
    of facts is describing a different slice of the target, even when the
    values it does report happen to match.
    """
    return tuple(sorted(str(name) for name in facts))


def duplicate_scope(observation: Observation) -> tuple[str, str, tuple[str, ...]]:
    """The scope within which two observations may be compared at all."""
    return (observation.target, observation.collector_id, fact_namespace(observation.facts))


def _record_scope(record: dict[str, Any]) -> tuple[str, str, tuple[str, ...]]:
    return (
        str(record.get("target") or ""),
        str(record.get("collector") or ""),
        fact_namespace(record.get("facts") or {}),
    )


def find_duplicate(observation: Observation,
                   existing: Iterable[dict[str, Any]]) -> str | None:
    """Return the identifier of matching evidence, or None.

    A match requires the same scope, the same fingerprint, and the same
    collection status. Status participates because a failed collection that
    reported the same partial facts as an earlier success is a different fact
    about the world, not a repetition of it.
    """
    scope = duplicate_scope(observation)
    for record in existing:
        if _record_scope(record) != scope:
            continue
        if str(record.get("status") or "") != observation.status:
            continue
        if str(record.get("content_fingerprint") or "") == observation.source_fingerprint:
            identifier = str(record.get("id") or "")
            if identifier:
                return identifier
    return None
