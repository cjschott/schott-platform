"""Read-only trust queries.

Nothing here writes, allocates an identifier, or emits an audit event. Asking
what is trusted must not change what is trusted, and an audit trail that
records questions as well as changes buries the changes.

Every answer distinguishes the stored state from the effective state. They
differ only through expiry, and conflating them would report a grant as live
after its boundary elapsed.

Every denial is explained. "Denied" with no reason is unusable during the
incident where it matters.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from .errors import TrustStoreError
from .expiry import effective_state
from .lineage import current_lineage, lineage_head, subject_lineages
from .models import (
    AuthorityType,
    TrustEvaluation,
    TrustScope,
    TrustState,
    require_aware,
)
from .scope import evaluate_activity, evaluate_scope
from .transitions import is_usable


def build_evaluation(*, subject_id: str, stored_state: str, effective_state: str,
                     scope: TrustScope | None, lineage_id: str | None,
                     evaluated_at: datetime, record_id: str | None = None,
                     decision_id: str | None = None,
                     evidence_reference_ids: tuple[str, ...] = (),
                     reasons: tuple[str, ...] = ()) -> TrustEvaluation:
    """Assemble an evaluation. Pure: reads nothing and writes nothing."""
    return TrustEvaluation(
        subject_id=subject_id, stored_state=stored_state,
        effective_state=effective_state, lineage_id=lineage_id,
        evaluated_at=evaluated_at, scope=scope, record_id=record_id,
        decision_id=decision_id, evidence_reference_ids=evidence_reference_ids,
        reasons=reasons)


def get_root_authority(store) -> dict[str, Any] | None:
    """The active operator root, or None when none has been declared."""
    roots = [a for a in store.all_records("authority")
             if a.get("authority_type") == AuthorityType.OPERATOR_ROOT.value
             and a.get("state") == TrustState.TRUSTED.value]
    return roots[0] if len(roots) == 1 else None


def get_trust_record(store, record_id: str) -> dict[str, Any]:
    return store.read("record", record_id)


def get_trust_decision(store, decision_id: str) -> dict[str, Any]:
    return store.read("decision", decision_id)


def get_lineage(store, lineage_id: str) -> dict[str, Any] | None:
    return lineage_head(store, lineage_id)


def _scope_from(record: dict[str, Any]) -> TrustScope | None:
    raw = record.get("scope")
    if not isinstance(raw, dict):
        return None

    def when(value):
        return datetime.fromisoformat(value) if value else None

    return TrustScope(
        scope_id=str(raw.get("scope_id")),
        subject_type=str(raw.get("subject_type")),
        permitted_capabilities=tuple(raw.get("permitted_capabilities") or ()),
        permitted_operations=tuple(raw.get("permitted_operations") or ()),
        permitted_data_classifications=tuple(
            raw.get("permitted_data_classifications") or ()),
        permitted_targets=tuple(raw.get("permitted_targets") or ()),
        validity_start=when(raw.get("validity_start")),
        validity_end=when(raw.get("validity_end")),
    )


def _record_for_decision(store, decision_id: str) -> dict[str, Any] | None:
    for record in store.all_records("record"):
        if record.get("decision_id") == decision_id:
            return record
    return None


def current_evaluation(store, subject_id: str, *,
                       evaluated_at: datetime) -> TrustEvaluation:
    """The subject's standing at an explicit moment.

    Fails closed: an absent subject, a lineage with no record, and a malformed
    record all evaluate to unknown with a written reason, never to a default.
    """
    require_aware(evaluated_at, "evaluated_at")

    head = current_lineage(store, subject_id)
    if head is None:
        return build_evaluation(
            subject_id=subject_id, stored_state=TrustState.UNKNOWN.value,
            effective_state=TrustState.UNKNOWN.value, scope=None, lineage_id=None,
            evaluated_at=evaluated_at,
            reasons=("no trust lineage exists for this subject; unknown fails closed",))

    record = _record_for_decision(store, str(head.get("current_decision_id")))
    if record is None:
        return build_evaluation(
            subject_id=subject_id, stored_state=TrustState.UNKNOWN.value,
            effective_state=TrustState.UNKNOWN.value, scope=None,
            lineage_id=str(head.get("lineage_id")), evaluated_at=evaluated_at,
            reasons=("the lineage head cites a decision with no trust record; "
                     "malformed state fails closed",))

    stored = str(record.get("state"))
    expiration = record.get("expiration")
    try:
        scope = _scope_from(record)
        deadline = datetime.fromisoformat(expiration) if expiration else None
        effective = effective_state(stored, deadline, evaluated_at)
    except Exception:
        return build_evaluation(
            subject_id=subject_id, stored_state=stored,
            effective_state=TrustState.UNKNOWN.value, scope=None,
            lineage_id=str(head.get("lineage_id")), evaluated_at=evaluated_at,
            record_id=str(record.get("record_id")),
            reasons=("the trust record could not be interpreted; malformed state "
                     "fails closed",))

    reasons: tuple[str, ...] = ()
    if effective != stored:
        reasons = (f"stored state '{stored}' is effectively '{effective}' at the "
                   "evaluation moment because the recorded expiration elapsed",)

    return build_evaluation(
        subject_id=subject_id, stored_state=stored, effective_state=effective,
        scope=scope, lineage_id=str(head.get("lineage_id")),
        evaluated_at=evaluated_at, record_id=str(record.get("record_id")),
        decision_id=str(head.get("current_decision_id")), reasons=reasons)


def get_current_trust(store, subject_id: str, *,
                      evaluated_at: datetime) -> dict[str, Any]:
    """A serialisable summary of a subject's standing."""
    evaluation = current_evaluation(store, subject_id, evaluated_at=evaluated_at)
    payload = evaluation.to_dict()
    payload["usable"] = is_usable(evaluation.effective_state)
    return payload


def list_subject_history(store, subject_id: str) -> list[dict[str, Any]]:
    """Every decision affecting a subject, oldest first.

    Ordered by decision time then identifier, so repeated calls return the same
    sequence and two decisions sharing a timestamp still order deterministically.
    """
    decisions = [d for d in store.all_records("decision")
                 if d.get("subject_id") == subject_id]
    return sorted(decisions, key=lambda d: (str(d.get("decided_at", "")),
                                            str(d.get("decision_id", ""))))


def evaluate_subject(store, subject_id: str, *, evaluated_at: datetime,
                     capability: str | None = None, operation: str | None = None,
                     data_classification: str | None = None,
                     target: str | None = None,
                     activity_kind: str = "normal") -> dict[str, Any]:
    """The full answer: state, activity, and scope, with every denial explained."""
    evaluation = current_evaluation(store, subject_id, evaluated_at=evaluated_at)
    activity = evaluate_activity(evaluation, activity_kind=activity_kind,
                                 operation_id=operation, evaluated_at=evaluated_at)
    scope_result = evaluate_scope(evaluation, capability=capability,
                                  operation=operation,
                                  data_classification=data_classification,
                                  target=target, evaluated_at=evaluated_at)

    denied_reasons = list(evaluation.reasons)
    denied_reasons += [r for r in activity.denied_reasons if r not in denied_reasons]
    if activity.allowed:
        denied_reasons += [r for r in scope_result.denied_reasons
                           if r not in denied_reasons]

    allowed = activity.allowed and scope_result.allowed
    return {
        "subject_id": subject_id,
        "stored_state": evaluation.stored_state,
        "effective_state": evaluation.effective_state,
        "usable": is_usable(evaluation.effective_state),
        "allowed": allowed,
        "denied_reasons": denied_reasons if not allowed else [],
        "lineage_id": evaluation.lineage_id,
        "record_id": evaluation.record_id,
        "decision_id": evaluation.decision_id,
        "activity": activity.to_dict(),
        "scope": scope_result.to_dict(),
        "evaluated_at": evaluated_at.isoformat(),
    }


def list_lineages(store, subject_id: str) -> list[dict[str, Any]]:
    """Every lineage head for a subject, oldest first."""
    return subject_lineages(store, subject_id)
