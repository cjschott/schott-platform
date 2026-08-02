"""Creating trust decisions.

A decision is the only thing that can change a trust state. Creating one
persists four immutable records — the decision, the resulting trust record, a
new lineage version, and an audit event — and edits nothing that already
exists.

Every refusal here is a refusal to write. The checks run before anything
touches the store, so a rejected decision leaves no partial trace: there is no
half-written lineage advance to reconcile afterwards.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .audit import STATE_EVENT, AuditEventKind
from .errors import TrustError
from .lineage import current_lineage, lineage_head, validate_advance, validate_supersession
from .models import (
    AuthorityType,
    TrustAuditEvent,
    TrustDecision,
    TrustEvidenceReference,
    TrustLineage,
    TrustRecord,
    TrustScope,
    TrustState,
    TrustVerificationDetails,
    require_aware,
)
from .transitions import evaluate_transition, is_terminal


@dataclass(frozen=True)
class DecisionOutcome:
    """Everything one decision wrote."""

    decision: TrustDecision
    record: TrustRecord
    lineage: TrustLineage
    audit_event: TrustAuditEvent

    def to_dict(self) -> dict[str, Any]:
        return {
            "decision": self.decision.to_dict(),
            "record": self.record.to_dict(),
            "lineage": self.lineage.to_dict(),
            "audit_event": self.audit_event.to_dict(),
        }


def _active_root(store) -> dict[str, Any]:
    roots = [a for a in store.all_records("authority")
             if a.get("authority_type") == AuthorityType.OPERATOR_ROOT.value
             and a.get("state") == TrustState.TRUSTED.value]
    if not roots:
        raise TrustError(
            "no active operator-root authority exists in this store; every trust "
            "chain must terminate at an external root, and none has been declared"
        )
    if len(roots) > 1:
        raise TrustError("more than one active operator-root authority exists")
    return roots[0]


def create_decision(
    store,
    *,
    subject_id: str,
    subject_type: str,
    requested_state: str,
    actor_authority_id: str,
    decided_at: datetime,
    reason: str,
    evidence_references: tuple[TrustEvidenceReference, ...],
    verification_method: str,
    verification_details: TrustVerificationDetails,
    scope: TrustScope | None = None,
    expiration: datetime | None = None,
    supersedes: str | None = None,
    revokes_record_id: str | None = None,
    lineage_id: str | None = None,
    supersedes_lineage_id: str | None = None,
    provenance: dict[str, Any] | None = None,
) -> DecisionOutcome:
    """Record one act of judgement, or refuse and write nothing."""
    require_aware(decided_at, "decided_at")

    root = _active_root(store)
    if actor_authority_id != root.get("authority_id"):
        raise TrustError(
            f"authority '{actor_authority_id}' is not the active operator root; "
            "delegated authorities are not implemented in v0.9.3"
        )

    # An authority approving itself is a chain terminating inside the thing it
    # governs.
    if subject_id == actor_authority_id:
        raise TrustError(
            "an authority cannot approve itself; something outside must establish it"
        )

    if requested_state not in {s.value for s in TrustState}:
        raise TrustError(f"requested state '{requested_state}' is not recognised")

    # Resolve the lineage this decision belongs to.
    head: dict[str, Any] | None = None
    if lineage_id is not None:
        head = lineage_head(store, lineage_id)
        if head is None:
            raise TrustError(f"lineage '{lineage_id}' does not exist")
    elif supersedes_lineage_id is None:
        head = current_lineage(store, subject_id)
        if head is not None and (head.get("terminated") or
                                 is_terminal(str(head.get("current_state")))):
            raise TrustError(
                f"the current lineage for '{subject_id}' ended in "
                f"'{head.get('current_state')}'; later approval requires a new "
                "lineage, supplied explicitly via supersedes_lineage_id"
            )

    previous_state = str(head.get("current_state")) if head else TrustState.UNKNOWN.value

    if head is not None:
        validate_advance(store, head, subject_id, subject_type)

    outcome = evaluate_transition(previous_state, requested_state, by_decision=True)
    if not outcome.allowed:
        raise TrustError(
            f"transition '{previous_state}' -> '{requested_state}' is refused: "
            f"{outcome.governing_rule}"
        )

    if requested_state == TrustState.RESTRICTED.value:
        if scope is None:
            raise TrustError(
                "a restricted grant requires an explicit scope; a restriction that "
                "bounds nothing is a trusted record with a misleading label"
            )
        scope.require_non_empty()

    if requested_state == TrustState.REVOKED.value and revokes_record_id is None:
        raise TrustError(
            "a revocation must name the record whose trust it withdraws")

    if requested_state == TrustState.REJECTED.value and previous_state in {
            TrustState.TRUSTED.value, TrustState.RESTRICTED.value}:
        raise TrustError(
            "a rejection cannot follow a granted trust; withdrawing a grant is a "
            "revocation, and the two are permanently distinct in the history"
        )

    decision_id = store.allocate_id("decision")
    validate_supersession(store, decision_id, supersedes)

    stored_evidence: list[TrustEvidenceReference] = []
    for reference in evidence_references:
        stored_evidence.append(TrustEvidenceReference(
            evidence_id=store.allocate_id("evidence"),
            kind=reference.kind,
            reference=reference.reference,
            recorded_at=reference.recorded_at,
        ))

    resolved_lineage_id = (head.get("lineage_id") if head
                           else store.allocate_id("lineage"))

    decision = TrustDecision(
        decision_id=decision_id,
        lineage_id=resolved_lineage_id,
        subject_id=subject_id,
        previous_state=previous_state,
        requested_state=requested_state,
        actor_authority_id=actor_authority_id,
        decided_at=decided_at,
        reason=reason,
        evidence_references=tuple(stored_evidence),
        verification_method=verification_method,
        verification_details=verification_details,
        trust_scope=scope,
        expiration=expiration,
        supersedes=supersedes,
        revokes_record_id=revokes_record_id,
        provenance=dict(provenance or {}),
    )

    record = TrustRecord(
        record_id=store.allocate_id("record"),
        subject_id=subject_id,
        subject_type=subject_type,
        state=requested_state,
        lineage_id=resolved_lineage_id,
        decision_id=decision_id,
        authority_id=actor_authority_id,
        created_at=decided_at,
        scope=scope,
        expiration=expiration,
        provenance=dict(provenance or {}),
    )

    terminal = is_terminal(requested_state)
    if head is None:
        lineage = TrustLineage(
            lineage_id=resolved_lineage_id, version=1,
            subject_id=subject_id, subject_type=subject_type,
            root_authority_id=str(root.get("authority_id")),
            first_decision_id=decision_id, current_decision_id=decision_id,
            prior_decision_ids=(), current_state=requested_state,
            created_at=decided_at, last_changed_at=decided_at,
            terminated=terminal,
            termination_reason=outcome.governing_rule if terminal else None,
            supersedes_lineage_id=supersedes_lineage_id,
        )
        lineage_event = AuditEventKind.LINEAGE_CREATED
    else:
        priors = tuple(head.get("prior_decision_ids") or ()) + (
            str(head.get("current_decision_id")),)
        lineage = TrustLineage(
            lineage_id=resolved_lineage_id,
            version=int(head.get("version", 1)) + 1,
            subject_id=subject_id, subject_type=subject_type,
            root_authority_id=str(head.get("root_authority_id")),
            first_decision_id=str(head.get("first_decision_id")),
            current_decision_id=decision_id, prior_decision_ids=priors,
            current_state=requested_state,
            created_at=datetime.fromisoformat(str(head.get("created_at"))),
            last_changed_at=decided_at, terminated=terminal,
            termination_reason=outcome.governing_rule if terminal else None,
            supersedes_lineage_id=head.get("supersedes_lineage_id"),
        )
        lineage_event = AuditEventKind.LINEAGE_ADVANCED

    event_kind = STATE_EVENT.get(requested_state, AuditEventKind.TRUST_DECISION_CREATED)
    audit_event = TrustAuditEvent(
        audit_id=store.allocate_id("audit"),
        event_kind=AuditEventKind.TRUST_DECISION_CREATED.value,
        subject_id=subject_id,
        lineage_id=resolved_lineage_id,
        actor_authority_id=actor_authority_id,
        related_record_ids=(decision_id, record.record_id, lineage.id,
                            lineage_event.value, event_kind.value),
        occurred_at=decided_at,
        reason=reason,
        provenance=dict(provenance or {}),
    )

    for reference in stored_evidence:
        store.write("evidence", reference)
    store.write("decision", decision)
    store.write("record", record)
    store.write("lineage", lineage)
    store.write("audit", audit_event)

    return DecisionOutcome(decision=decision, record=record, lineage=lineage,
                           audit_event=audit_event)
