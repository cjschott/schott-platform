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

import contextlib
import contextvars

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .audit import STATE_EVENT, AuditEventKind
from .errors import TrustError
from .expiry import effective_state
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


def _record_for_decision(store, decision_id: str) -> dict[str, Any] | None:
    """The trust record a decision produced, or None."""
    for record in store.all_records("record"):
        if record.get("decision_id") == decision_id:
            return record
    return None


# Rehearsal. Set for the duration of one call and consulted at exactly the two
# points where a decision stops being reversible: identity allocation, and the
# write. Everything before those runs identically, so a rehearsal cannot answer
# a different question from the decision it rehearses.
_REHEARSING = contextvars.ContextVar("trust_rehearsing", default=False)


@contextlib.contextmanager
def rehearsing():
    """Run a decision as a rehearsal: validate fully, allocate and write nothing."""
    token = _REHEARSING.set(True)
    try:
        yield
    finally:
        _REHEARSING.reset(token)


class _Identities:
    """Identity allocation, or prediction where nothing may be spent.

    Under rehearsal the store's own `peek_next_id` answers, offset by how many
    of that kind this decision has already taken -- a decision citing two
    pieces of evidence would otherwise predict one identity twice. Outside a
    rehearsal this is the allocator and nothing else.
    """

    def __init__(self, store) -> None:
        self._store = store
        self._taken: dict[str, int] = {}

    def predict(self, kind: str) -> str:
        """What `take` would return, without consuming anything.

        Read-only in both modes, so a caller may compare an identity against
        what it is about to be given before anything is spent on refusing.
        """
        identifier = self._store.peek_next_id(kind)
        for _ in range(self._taken.get(kind, 0)):
            prefix, _, number = identifier.rpartition("-")
            identifier = f"{prefix}-{int(number) + 1:0{len(number)}d}"
        return identifier

    def take(self, kind: str) -> str:
        identifier = (self.predict(kind) if _REHEARSING.get()
                      else self._store.allocate_id(kind))
        self._taken[kind] = self._taken.get(kind, 0) + 1
        return identifier


def _cited_evidence(store, references, identities):
    """The evidence a decision cites, resolved rather than re-labelled.

    **A supplied identity is authoritative.** This path used to discard it and
    allocate a fresh one, so a decision citing `TEVID-000001` produced a durable
    record citing something else entirely -- the approved body and the record
    silently disagreed about which evidence was examined, and neither was wrong
    on its face.

    So a cited identity that already exists must **agree exactly** with the
    stored record, compared on the canonical representation the store writes
    rather than on raw bytes. Agreement means the citation stands and nothing is
    written; disagreement is refused. The stored record is never overwritten,
    superseded, repaired, or reinterpreted: one Trust Evidence identity has one
    canonical meaning, and a second meaning is a refusal rather than a version.

    A cited identity that does not exist is new evidence, and the store still
    owns identity -- but the allocation must be the identity that was cited.
    An operator who predicted an identity and got a different one silently
    recorded evidence nobody reviewed, which is the same defect wearing the
    other face.
    """
    resolved: list[TrustEvidenceReference] = []
    recorded: list[TrustEvidenceReference] = []
    for reference in references:
        cited = reference.evidence_id
        try:
            stored = store.read("evidence", cited)
        except Exception:  # noqa: BLE001
            stored = None
        if stored is not None:
            if dict(stored) != dict(reference.to_dict()):
                raise TrustError(
                    f"evidence '{cited}' already exists and does not match the "
                    "citation; one evidence identity has one meaning, and it is "
                    "not superseded, repaired, or reinterpreted here"
                )
            # Cited, not re-recorded. The identity already means this, and
            # writing it again would be an immutable store overwriting itself.
            resolved.append(reference)
            continue
        # Compared before anything is spent, so a citation naming an identity
        # the store is not about to hand out costs no sequence position.
        predicted = identities.predict("evidence")
        if predicted != cited:
            raise TrustError(
                f"evidence '{cited}' does not exist and the next evidence identity "
                f"is '{predicted}'; the citation is recorded as supplied or not at "
                "all, never silently under another identity"
            )
        allocated = identities.take("evidence")
        if allocated != cited:
            # Only reachable if another writer took the identity between the
            # prediction and the allocation. Fail closed: an identifier is spent
            # and nothing is written, which is a gap rather than a wrong record.
            raise TrustError(
                f"evidence identity '{cited}' was taken while this decision was "
                "being prepared; nothing was written"
            )
        fresh = TrustEvidenceReference(
            evidence_id=allocated, kind=reference.kind,
            reference=reference.reference, recorded_at=reference.recorded_at)
        resolved.append(fresh)
        recorded.append(fresh)
    return resolved, recorded


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
    approval_source: str = "named-operator",
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

    # The previous state is the state at the moment of decision, not the state
    # the record happens to store. Expiry is never written down -- it is derived
    # -- so reading the stored value here would make `expired` unreachable as a
    # previous state and leave renewal permanently refused as `trusted ->
    # trusted`, even though the transition table permits `expired -> trusted`.
    previous_state = TrustState.UNKNOWN.value
    if head is not None:
        stored_state = str(head.get("current_state"))
        head_record = _record_for_decision(store, str(head.get("current_decision_id")))
        deadline = None
        if head_record is not None and head_record.get("expiration"):
            try:
                deadline = datetime.fromisoformat(str(head_record.get("expiration")))
            except ValueError:
                deadline = None
        previous_state = effective_state(stored_state, deadline, decided_at)

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
            TrustState.TRUSTED.value, TrustState.RESTRICTED.value,
            TrustState.EXPIRED.value}:
        raise TrustError(
            "a rejection cannot follow a granted trust; withdrawing a grant is a "
            "revocation, and the two are permanently distinct in the history"
        )

    identities = _Identities(store)
    # Citations are resolved before any identity is spent, so a decision refused
    # for naming evidence it cannot name leaves no gap in a sequence behind it.
    stored_evidence, new_evidence = _cited_evidence(
        store, evidence_references, identities)

    decision_id = identities.take("decision")
    validate_supersession(store, decision_id, supersedes)

    resolved_lineage_id = (head.get("lineage_id") if head
                           else identities.take("lineage"))
    # Allocated before the decision so the decision can cite the record it
    # produces: a decision that cannot be placed in its chain is not reviewable.
    record_id = identities.take("record")

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
        approval_source=approval_source,
        history_reference=record_id,
        trust_scope=scope,
        expiration=expiration,
        supersedes=supersedes,
        revokes_record_id=revokes_record_id,
        provenance=dict(provenance or {}),
    )

    record = TrustRecord(
        record_id=record_id,
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
        audit_id=identities.take("audit"),
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

    if _REHEARSING.get():
        # Every rule above has run against the real store and every object has
        # been constructed, which is the whole answer a rehearsal can honestly
        # give. The write is the first act that cannot be taken back, so this
        # is where it stops -- and the outcome it returns carries the same
        # objects the decision would have written.
        return DecisionOutcome(decision=decision, record=record, lineage=lineage,
                               audit_event=audit_event)

    for reference in new_evidence:
        store.write("evidence", reference)
    store.write("decision", decision)
    store.write("record", record)
    store.write("lineage", lineage)
    store.write("audit", audit_event)

    return DecisionOutcome(decision=decision, record=record, lineage=lineage,
                           audit_event=audit_event)
