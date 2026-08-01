"""Append-only knowledge event timeline.

Events are written through the store, which refuses to overwrite, so
append-only is enforced by the storage layer rather than by this module's good
behaviour. There is no rewrite path and no delete path here because there is
none underneath either.

Ordering is by `occurred_at` then identifier. The identifier tiebreak is not
cosmetic: two events can legitimately share a timestamp, and without a
deterministic secondary sort the timeline reorders between runs and no two
queries agree.

A timeline is a record of what happened. **The latest event is not the
authoritative declared state** — the most recent thing that happened may well
be a collection failure. See docs/standards/knowledge-event-standard.md.
"""

from __future__ import annotations

from typing import Any, Iterable

from .evidence_store import EvidenceStore
from .models import EventType, KnowledgeEvent, require_timezone

APPROVED_EVENT_TYPES = frozenset(item.value for item in EventType)


class TimelineError(Exception):
    """An event could not be recorded. Never contains a secret value."""


def build_event(*, event_id: str, target: str, event_type: str, occurred_at: str,
                explanation: str, evidence: Iterable[str] = (),
                verification: Iterable[str] = (), drift: Iterable[str] = (),
                confidence: float | None = None,
                knowledge_age_seconds: int | None = None) -> KnowledgeEvent:
    """Construct an event, rejecting any type outside the approved vocabulary."""
    if event_type not in APPROVED_EVENT_TYPES:
        raise TimelineError(
            f"event type '{event_type}' is not in the approved vocabulary; "
            "extend the knowledge event standard first"
        )
    return KnowledgeEvent(
        id=event_id,
        target=str(target),
        event_type=event_type,
        occurred_at=require_timezone(occurred_at, "occurred_at"),
        explanation=str(explanation),
        evidence=tuple(str(e) for e in evidence),
        verification=tuple(str(v) for v in verification),
        drift=tuple(str(d) for d in drift),
        confidence=confidence,
        knowledge_age_seconds=knowledge_age_seconds,
    )


class Timeline:
    """Query and append knowledge events for a store."""

    def __init__(self, store: EvidenceStore) -> None:
        self.store = store

    def append(self, event: KnowledgeEvent) -> KnowledgeEvent:
        """Persist one event. The store refuses to replace an existing record."""
        if event.event_type not in APPROVED_EVENT_TYPES:
            raise TimelineError(f"event type '{event.event_type}' is not approved")
        self.store.write_event(event)
        return event

    def query(self, target: str | None = None) -> list[KnowledgeEvent]:
        """Return events sorted by occurred_at, then identifier."""
        records = self.store.list_events(target)
        events = [
            KnowledgeEvent(
                id=str(r.get("id") or ""),
                target=str(r.get("target") or ""),
                event_type=str(r.get("event_type") or ""),
                occurred_at=str(r.get("occurred_at") or ""),
                explanation=str(r.get("explanation") or ""),
                evidence=tuple(r.get("evidence") or ()),
                verification=tuple(r.get("verification") or ()),
                drift=tuple(r.get("drift") or ()),
                confidence=r.get("confidence"),
                knowledge_age_seconds=r.get("knowledge_age_seconds"),
            )
            for r in records
        ]
        return sorted(events, key=lambda e: (e.occurred_at, e.id))

    def latest(self, target: str, limit: int = 10) -> list[KnowledgeEvent]:
        """Return the most recent events, newest last.

        Ordering is preserved rather than reversed so a caller rendering the
        list reads it in the same direction as the full timeline.
        """
        events = self.query(target)
        return events[-limit:] if limit and limit > 0 else events
