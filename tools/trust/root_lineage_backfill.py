"""The one-time repair that records how the existing Operator Root was established.

The ceremony that declared `TAUTH-000001` ran against a write path that
allocated a lineage identifier for the authority and wrote no lineage record.
The authority and its declaration audit event both name `TLIN-000001`;
`lineages/` holds nothing for it. Fixing the write path repaired future
declarations and could not repair that one, because a second active root is
refused -- correctly -- so the ceremony cannot be re-run.

This module writes the missing record. It is not a migration framework and not
a repair tool: it performs exactly one repair, on exactly one shape of defect,
and refuses everything else.

**Nothing here is invented.** Every field of the lineage is read out of records
that already exist and are immutable -- the authority, its declaration audit
event, and its ceremony evidence. The only values an operator supplies are the
instant of the repair, who performed it, and why. If any source record is
missing, duplicated, or disagrees, the repair is refused rather than
reconstructed from a guess.

**Two records, and no others.** A `RootAuthorityLineage` and one audit event
recording that this repair happened. No authority, decision, record, evidence
or sequence value is written or amended, and the ceremony's own audit event is
left exactly as it was: that event records the ceremony, a later repair is a
later event, and it gets its own.

**No identifier is allocated for the lineage.** `TLIN-000001` was spent by the
ceremony; writing it now consumes nothing. Only the audit identifier is
allocated, and rehearsal predicts it instead.

Governed by docs/decisions/ADR-0014-root-establishment-lineage.md and specified
by docs/trust/root-lineage-backfill-plan.md.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .audit import AuditEventKind
from .errors import TrustError
from .models import (
    EXTERNAL_OPERATOR_CEREMONY,
    AuthorityType,
    RootAuthorityLineage,
    TrustAuditEvent,
    TrustState,
    require_aware,
    validate_root_lineage_record,
)

ROOT_LINEAGE_BACKFILLED = AuditEventKind.ROOT_LINEAGE_BACKFILLED.value

# Provenance on the repair event. `class` says this record exists because
# something was wrong, not because something was decided; `source` says a human
# approved it, because nothing in this platform could.
BACKFILL_PROVENANCE_CLASS = "repair"
BACKFILL_PROVENANCE_SOURCE = "operator-approved-backfill"


@dataclass(frozen=True)
class BackfillPlan:
    """Both records, fully constructed, before anything is written.

    Carries no methods on purpose. A plan that could act on a store would be a
    second write path beside `apply_root_lineage_backfill`.
    """

    lineage: RootAuthorityLineage
    audit_event: TrustAuditEvent
    writes_lineage: bool
    writes_audit: bool
    rehearsed: bool


def _sole_root(store) -> dict[str, Any]:
    """The one active operator root, or a refusal naming which way it failed."""
    roots = [a for a in store.all_records("authority")
             if a.get("authority_type") == AuthorityType.OPERATOR_ROOT.value
             and a.get("state") == TrustState.TRUSTED.value]
    if not roots:
        raise TrustError(
            "no active operator-root authority exists in this store; there is no "
            "root establishment to record")
    if len(roots) > 1:
        raise TrustError(
            f"{len(roots)} active operator-root authorities exist; two roots is no "
            "root, and this repair will not choose between them")
    return roots[0]


def _establishment_audit(store, authority_id: str, lineage_id: str) -> str:
    """The identifier of the event that recorded the ceremony.

    Located, never assumed. The lineage names the event that established it, and
    an establishment identifier the platform guessed would be a claim about a
    ceremony rather than a reference to its record.
    """
    events = [e for e in store.all_records("audit")
              if e.get("event_kind") == AuditEventKind.ROOT_AUTHORITY_DECLARED.value
              and e.get("subject_id") == authority_id
              and e.get("lineage_id") == lineage_id]
    if not events:
        raise TrustError(
            f"no 'root-authority-declared' audit event names {authority_id} and "
            f"lineage '{lineage_id}'; the establishment this record would cite has "
            "no event to point at")
    if len(events) > 1:
        raise TrustError(
            f"{len(events)} 'root-authority-declared' audit events name "
            f"{authority_id}; which one established it is not something to pick")
    return str(events[0].get("audit_id"))


def _ceremony_evidence(store, authority: dict[str, Any]) -> tuple[str, ...]:
    """The ceremony evidence identifiers, each proved to still exist and match.

    Stored order is kept. The authority already fixed the order in which the
    ceremony recorded its evidence, and re-sorting it here would be this module
    having an opinion about a record it does not own.
    """
    references = authority.get("evidence_references") or []
    if not isinstance(references, list) or not references:
        raise TrustError(
            f"{authority.get('authority_id')} carries no evidence references; a "
            "root establishment lineage requires at least one")
    identifiers: list[str] = []
    for reference in references:
        if not isinstance(reference, dict):
            raise TrustError(
                f"{authority.get('authority_id')} carries a malformed evidence "
                "reference")
        evidence_id = str(reference.get("evidence_id") or "")
        try:
            stored = store.read("evidence", evidence_id)
        except TrustError:
            raise TrustError(
                f"ceremony evidence '{evidence_id}' has no record in this store; "
                "the lineage would cite evidence that is not there") from None
        if dict(stored) != dict(reference):
            raise TrustError(
                f"ceremony evidence '{evidence_id}' does not match the reference "
                f"carried by {authority.get('authority_id')}; the store and the "
                "authority disagree about what was examined")
        identifiers.append(evidence_id)
    return tuple(identifiers)


def _existing_versions(store, lineage_id: str) -> list[dict[str, Any]]:
    return [record for record in store.all_records("lineage")
            if record.get("lineage_id") == lineage_id]


def _already_recorded(store, lineage_id: str) -> bool:
    return any(event.get("event_kind") == ROOT_LINEAGE_BACKFILLED
               and event.get("lineage_id") == lineage_id
               for event in store.all_records("audit"))


def plan_root_lineage_backfill(store, *, recorded_at: datetime, reason: str,
                               performed_by: str, rehearse: bool) -> BackfillPlan:
    """Construct both records and check every precondition. Writes nothing.

    `rehearse` predicts the audit identifier instead of allocating it, so a
    rehearsal spends nothing. Everything else -- every precondition, every
    reconstructed value, and the construction of both records -- is identical,
    because a rehearsal that ran a second algorithm would be answering a
    different question than the write.
    """
    operator = str(performed_by or "").strip()
    if not operator:
        raise TrustError(
            "performed_by is required; a repair to the root of trust records who "
            "performed it or it records nothing")
    if len(str(reason or "").split()) < 5:
        raise TrustError(
            "a backfill reason must be a written justification; 'the validator "
            "complained' is not a reason")
    require_aware(recorded_at, "recorded_at")

    authority = _sole_root(store)
    authority_id = str(authority.get("authority_id"))
    lineage_id = str(authority.get("lineage_id") or "")
    establishment_audit_id = _establishment_audit(store, authority_id, lineage_id)
    evidence_ids = _ceremony_evidence(store, authority)

    # Constructed from the ceremony records alone, so the same store always
    # yields the same lineage. Only `recorded_at` comes from outside, and only
    # because the repair happens at a different moment than the establishment --
    # which is why the model carries both fields.
    reconstructed = RootAuthorityLineage(
        lineage_id=lineage_id,
        version=1,
        authority_id=authority_id,
        subject_type=str(authority.get("authority_type")),
        establishment_origin=EXTERNAL_OPERATOR_CEREMONY,
        evidence_reference_ids=evidence_ids,
        establishment_audit_id=establishment_audit_id,
        current_state=str(authority.get("state")),
        established_at=_stored_instant(authority, "created_at"),
        recorded_at=recorded_at,
    )

    versions = _existing_versions(store, lineage_id)
    if len(versions) > 1:
        raise TrustError(
            f"lineage '{lineage_id}' already has {len(versions)} stored versions; "
            "this is a conflict nothing here resolves")

    writes_lineage = True
    lineage = reconstructed
    if versions:
        # Either the repair already ran, or it died between its two writes.
        # Both leave a record; only one of them leaves the store unattributed.
        lineage = _matching_or_conflict(versions[0], reconstructed, lineage_id)
        if _already_recorded(store, lineage_id):
            raise TrustError(
                f"lineage '{lineage_id}' already has a root establishment record "
                f"and a '{ROOT_LINEAGE_BACKFILLED}' event; this repair has already "
                "been performed and nothing here repeats it")
        writes_lineage = False

    audit_id = (store.peek_next_id("audit") if rehearse
                else store.allocate_id("audit"))
    audit_event = TrustAuditEvent(
        audit_id=audit_id,
        event_kind=ROOT_LINEAGE_BACKFILLED,
        subject_id=authority_id,
        lineage_id=lineage_id,
        actor_authority_id=authority_id,
        related_record_ids=(lineage.id, establishment_audit_id),
        occurred_at=recorded_at,
        reason=str(reason),
        provenance={"class": BACKFILL_PROVENANCE_CLASS,
                    "source": BACKFILL_PROVENANCE_SOURCE,
                    "performed_by": operator},
    )
    return BackfillPlan(lineage=lineage, audit_event=audit_event,
                        writes_lineage=writes_lineage, writes_audit=True,
                        rehearsed=bool(rehearse))


def _stored_instant(record: dict[str, Any], field_name: str) -> datetime:
    value = record.get(field_name)
    if isinstance(value, datetime):
        return require_aware(value, field_name)
    try:
        parsed = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        raise TrustError(
            f"{record.get('authority_id')}: {field_name} is not an ISO 8601 "
            "timestamp") from None
    return require_aware(parsed, field_name)


def _matching_or_conflict(stored: dict[str, Any], reconstructed: RootAuthorityLineage,
                          lineage_id: str) -> RootAuthorityLineage:
    """The stored record, if it is the one this repair would have written.

    `recorded_at` is taken from the stored record rather than compared: an
    interrupted repair is completed as the repair it already was, not reopened
    at whatever moment somebody noticed. Every other field is derived from
    immutable records, so any difference is a genuine disagreement.
    """
    try:
        existing = validate_root_lineage_record(stored, str(stored.get("id") or lineage_id))
    except TrustError as error:
        raise TrustError(
            f"lineage '{lineage_id}' already holds a record that is not a root "
            f"establishment ({error}); this is a conflict nothing here resolves"
        ) from None
    differences = [
        name for name in ("authority_id", "subject_type", "establishment_origin",
                          "establishment_audit_id", "current_state", "established_at",
                          "terminated")
        if getattr(existing, name) != getattr(reconstructed, name)
    ]
    if tuple(existing.evidence_reference_ids) != tuple(reconstructed.evidence_reference_ids):
        differences.append("evidence_reference_ids")
    if differences:
        raise TrustError(
            f"lineage '{lineage_id}' already holds a root establishment record "
            f"that conflicts with the ceremony on {', '.join(sorted(differences))}; "
            "nothing here rewrites it")
    return existing


def apply_root_lineage_backfill(store, plan: BackfillPlan) -> dict[str, Any]:
    """Write the planned records, lineage first.

    Ordering matters and cannot be atomic: this store has no transaction, and
    nothing in it deletes or rewrites. The audit event goes last because it
    records that the write happened -- writing it first would record an event
    that had not yet occurred.

    So the only partial state this can leave is a lineage record with no repair
    event: a store that validates cleanly but does not say who repaired it.
    That state is recoverable, and `plan_root_lineage_backfill` recovers it by
    completing the repair rather than repeating it. The reverse ordering would
    leave an event describing a record that does not exist, which no later write
    could make true.
    """
    if plan.rehearsed:
        raise TrustError(
            "this plan was built as a rehearsal and predicted its audit identifier "
            "rather than allocating one; writing it would claim an identifier "
            "nothing reserved")
    if plan.writes_lineage:
        store.write("lineage", plan.lineage)
    store.write("audit", plan.audit_event)
    return {
        "lineage_id": plan.lineage.lineage_id,
        "lineage_record_id": plan.lineage.id,
        "audit_id": plan.audit_event.audit_id,
        "authority_id": plan.lineage.authority_id,
        "wrote_lineage": plan.writes_lineage,
        "wrote_audit": plan.writes_audit,
    }
