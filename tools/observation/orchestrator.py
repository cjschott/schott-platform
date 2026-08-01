"""The one place that turns observations into remembered evidence.

`process_collector_result` is the public operation. It consumes a
`CollectorResult` and never produces one: the orchestrator does not execute
collectors, import the registry, or reach a source. Merging those two
responsibilities would give the memory layer the blast radius of every plugin.

Lifecycle:

1. validate the collector result
2. build an observation
3. redact again
4. normalize
5. compute the canonical fingerprint
6. check for a duplicate
7. allocate and persist evidence when new
8. emit a refresh event when duplicate
9. verify against declared intent
10. assess drift
11. persist the verification and events
12. derive knowledge state
13. return an OrchestrationResult

It fails closed, and it fails *forward*: once evidence is persisted, a later
stage that cannot conclude never deletes it. The evidence survives and a
failure event is recorded instead, because the observation genuinely happened
and discarding it would lose a fact the platform paid to collect.
"""

from __future__ import annotations

from typing import Any, Iterable

from tools.collectors.models import CollectorResult

from .deduplicator import find_duplicate
from .drift_engine import assess_drift
from .evidence_builder import BuilderError, build_evidence_record, build_observation
from .evidence_store import EvidenceStore, StoreError
from .knowledge import build_knowledge_state
from .models import (
    EventType,
    KnowledgeEvent,
    OrchestrationResult,
    require_timezone,
)
from .timeline import Timeline, build_event
from .verifier import verify


class OrchestrationError(Exception):
    """Processing could not proceed. Messages are concise and secret-safe."""


class Orchestrator:
    """Coordinates evidence creation, verification, and event recording."""

    def __init__(self, store: EvidenceStore) -> None:
        self.store = store
        self.timeline = Timeline(store)

    def _event(self, *, target: str, event_type: str, occurred_at: str, explanation: str,
               evidence: Iterable[str] = (), verification: Iterable[str] = (),
               drift: Iterable[str] = (), confidence: float | None = None,
               knowledge_age_seconds: int | None = None) -> KnowledgeEvent:
        event = build_event(
            event_id=self.store.allocate_id("event"),
            target=target,
            event_type=event_type,
            occurred_at=occurred_at,
            explanation=explanation,
            evidence=evidence,
            verification=verification,
            drift=drift,
            confidence=confidence,
            knowledge_age_seconds=knowledge_age_seconds,
        )
        self.timeline.append(event)
        return event

    def process_collector_result(
        self,
        result: CollectorResult,
        *,
        declared: dict[str, Any] | None = None,
        rules: Iterable[dict[str, Any]] = (),
        evaluated_at: str | None = None,
    ) -> OrchestrationResult:
        """Ingest one collector result. Never mutates its input."""
        # --- 1-5: validate, build, redact, normalize, fingerprint ----------
        try:
            observation = build_observation(result)
        except BuilderError as error:
            raise OrchestrationError(f"collector result rejected: {error}") from error

        target = observation.target
        stamp = require_timezone(evaluated_at or observation.collected_at, "evaluated_at")
        rule_list = [dict(r) for r in rules]
        events: list[KnowledgeEvent] = []
        errors: list[str] = []

        events.append(self._event(
            target=target, event_type=EventType.OBSERVATION_RECEIVED.value,
            occurred_at=stamp,
            explanation=f"Observation from {observation.collector_id} accepted for {target}.",
        ))

        # --- 6: duplicate check -------------------------------------------
        duplicate_of = find_duplicate(observation, self.store.list_evidence(target))

        evidence_record = None
        if duplicate_of:
            # --- 8: refresh rather than duplicate --------------------------
            events.append(self._event(
                target=target, event_type=EventType.EVIDENCE_REFRESHED.value,
                occurred_at=stamp,
                explanation=(
                    f"Observation matched existing evidence {duplicate_of} exactly. "
                    "Freshness refreshed; no new evidence record was created."
                ),
                evidence=[duplicate_of],
            ))
        else:
            # --- 7: allocate and persist -----------------------------------
            evidence_id = self.store.allocate_id("evidence")
            evidence_record = build_evidence_record(
                observation, evidence_id=evidence_id, persisted_at=stamp)
            try:
                self.store.write_evidence(evidence_record)
            except StoreError as error:
                raise OrchestrationError(f"evidence could not be persisted: {error}") from error

            events.append(self._event(
                target=target, event_type=EventType.EVIDENCE_CREATED.value,
                occurred_at=stamp,
                explanation=f"Evidence {evidence_id} created for {target} from "
                            f"{observation.collector_id}.",
                evidence=[evidence_id],
            ))

            if evidence_record.collection_failed:
                events.append(self._event(
                    target=target, event_type=EventType.COLLECTION_FAILED.value,
                    occurred_at=stamp,
                    explanation=(
                        f"Collection failed for {target} (evidence: {evidence_id}). "
                        "This records the collection attempt and is not a statement "
                        "about the target's health."
                    ),
                    evidence=[evidence_id],
                ))

        # --- 9-11: verify, assess drift, persist --------------------------
        # From here on evidence is already durable. Anything that fails is
        # recorded as an error and an event; nothing rolls back a write.
        verification = None
        drift_results: tuple = ()
        known_evidence = self.store.list_evidence(target)

        try:
            verification = verify(
                declared=declared or {"id": target},
                evidence_records=known_evidence,
                rules=rule_list,
                evaluated_at=stamp,
                verification_id=self.store.allocate_id("verification"),
            )
            self.store.write_verification(verification)
            events.append(self._event(
                target=target, event_type=EventType.VERIFICATION_CREATED.value,
                occurred_at=stamp,
                explanation=f"Verification {verification.id} evaluated {target}: "
                            f"{verification.state}/{verification.result}.",
                evidence=list(verification.evidence),
                verification=[verification.id],
                confidence=verification.confidence.overall,
            ))

            if verification.result == "mismatch":
                events.append(self._event(
                    target=target, event_type=EventType.DRIFT_DETECTED.value,
                    occurred_at=stamp,
                    explanation=verification.explanation,
                    verification=[verification.id],
                    evidence=list(verification.evidence),
                ))
            if verification.result == "stale_evidence":
                events.append(self._event(
                    target=target, event_type=EventType.EVIDENCE_STALE.value,
                    occurred_at=stamp,
                    explanation=verification.explanation,
                    verification=[verification.id],
                    evidence=list(verification.evidence),
                ))
        except (StoreError, ValueError) as error:
            # Evidence stays. A failure here is a processing failure, not a
            # reason to discard an observation that genuinely happened.
            errors.append(f"verification could not be completed: {type(error).__name__}")
            events.append(self._event(
                target=target, event_type=EventType.REVIEW_REQUIRED.value,
                occurred_at=stamp,
                explanation=(
                    f"Verification could not be completed for {target}. Persisted "
                    "evidence is retained and requires review."
                ),
                evidence=[evidence_record.id] if evidence_record else [],
            ))

        if rule_list:
            try:
                drift_results = tuple(assess_drift(
                    declared=declared or {"id": target},
                    evidence_records=known_evidence,
                    rules=rule_list,
                    evaluated_at=stamp,
                ))
            except ValueError as error:
                errors.append(f"drift assessment could not be completed: {type(error).__name__}")

        # --- 12: derive knowledge state -----------------------------------
        knowledge_state = build_knowledge_state(
            target=target, store=self.store, declared=declared,
            rules=rule_list, generated_at=stamp,
        )
        events.append(self._event(
            target=target, event_type=EventType.KNOWLEDGE_STATE_GENERATED.value,
            occurred_at=stamp,
            explanation=f"Knowledge state derived for {target}: "
                        f"{knowledge_state.freshness}, {knowledge_state.verification_state}.",
            confidence=knowledge_state.confidence.overall,
            knowledge_age_seconds=knowledge_state.knowledge_age_seconds,
        ))

        # Indexes are derived and replaceable; rebuilding keeps them honest
        # without ever being the source of truth.
        self.store.rebuild_index()

        # --- 13 ------------------------------------------------------------
        return OrchestrationResult(
            target=target,
            evidence=evidence_record,
            duplicate_of=duplicate_of,
            verification=verification,
            drift=drift_results,
            events=tuple(events),
            knowledge_state=knowledge_state,
            errors=tuple(errors),
        )
