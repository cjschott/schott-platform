"""Trust standing for the Fabric, through released Trust Plane interfaces only.

This adapter asks a question and reports the answer. It owns no verdict of its
own, and it is the Fabric's **only** route to trust standing: a component that
read trust records directly would be reimplementing evaluation, and two
implementations of "is this subject trusted" is one too many.

**It fails closed, always.** Absent, expired, revoked, malformed, unreadable,
and unavailable all resolve to the same answer — `unverified` — because a
system that distinguishes "no" from "could not tell" at the point of use will
eventually treat the second as a "yes". The standing the Trust Plane reported
is preserved alongside, so a caller can explain the refusal without acting on
it.

**It remembers nothing and asks once.** No stored verdict, no second attempt,
no clock of its own: the evaluation instant arrives from the caller, because an
adapter that read the time would answer a question nobody asked. Asking twice
after a failure would turn an unavailable Trust Plane into a slow one.

**A refusal says nothing it cannot say deterministically.** The reason is drawn
from a small controlled vocabulary rather than passed through from an
exception, so no address, path, or interpreter detail can reach a caller — or,
later, an accepted record.

This increment verifies. It admits nothing, computes no eligibility, chooses
nothing, and writes nowhere.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from ..trust.models import TrustState
from ..trust.query import get_current_trust, get_trust_record
from .errors import FabricError

VERIFIED = "verified"
UNVERIFIED = "unverified"

# Every standing the released Trust Plane vocabulary defines. A value outside
# it is not interpreted -- it is reported as unknown, which fails closed.
KNOWN_STANDINGS = frozenset(state.value for state in TrustState)

# Standings a subject may actually be used in. Taken from the released
# vocabulary rather than restated as a policy of the Fabric's own.
USABLE_STANDINGS = frozenset({TrustState.TRUSTED.value, TrustState.RESTRICTED.value})

# Controlled refusal vocabulary, for C4 and C5 to act on. Deterministic by
# construction: nothing here is derived from an exception or an object.
REASON_NO_STANDING = "no-trust-standing"
REASON_EXPIRED = "trust-expired"
REASON_REVOKED = "trust-revoked"
REASON_NOT_USABLE = "trust-not-usable"
REASON_UNREADABLE = "trust-unreadable"
REASON_UNAVAILABLE = "trust-unavailable"

UNVERIFIED_REASONS = (
    REASON_NO_STANDING,
    REASON_EXPIRED,
    REASON_REVOKED,
    REASON_NOT_USABLE,
    REASON_UNREADABLE,
    REASON_UNAVAILABLE,
)

_REASON_FOR_STANDING = {
    TrustState.UNKNOWN.value: REASON_NO_STANDING,
    TrustState.EXPIRED.value: REASON_EXPIRED,
    TrustState.REVOKED.value: REASON_REVOKED,
}


@dataclass(frozen=True)
class TrustVerification:
    """One read-only answer about one subject at one instant.

    Carries the effective standing and the stored standing separately, the way
    the Trust Plane reports them: they differ through expiry, and collapsing
    them would describe a lapsed grant as live.
    """

    subject_id: str
    status: str
    standing: str
    stored_standing: str
    evaluated_at: str
    lineage_id: str | None = None
    record_id: str | None = None
    decision_id: str | None = None
    evidence_reference_ids: tuple[str, ...] = ()
    reasons: tuple[str, ...] = ()

    @property
    def verified(self) -> bool:
        return self.status == VERIFIED

    def to_dict(self) -> dict[str, Any]:
        return {
            "subject_id": self.subject_id,
            "status": self.status,
            "standing": self.standing,
            "stored_standing": self.stored_standing,
            "evaluated_at": self.evaluated_at,
            "lineage_id": self.lineage_id,
            "record_id": self.record_id,
            "decision_id": self.decision_id,
            "evidence_reference_ids": list(self.evidence_reference_ids),
            "reasons": list(self.reasons),
        }


def _require_instant(evaluated_at: Any) -> datetime:
    """The evaluation moment is supplied, and it is a moment."""
    if not isinstance(evaluated_at, datetime):
        raise FabricError("evaluated_at must be supplied as a datetime")
    if evaluated_at.tzinfo is None or evaluated_at.tzinfo.utcoffset(evaluated_at) is None:
        raise FabricError("evaluated_at must carry a timezone offset")
    return evaluated_at


def _require_subject(subject_id: Any) -> str:
    if not isinstance(subject_id, str) or not subject_id.strip():
        raise FabricError("a subject identity must be supplied explicitly")
    return subject_id


def _standing(value: Any) -> str:
    """A standing the released vocabulary defines, or unknown."""
    return value if value in KNOWN_STANDINGS else TrustState.UNKNOWN.value


def _references(value: Any) -> tuple[str, ...]:
    """Evidence identities, preserved in order and never interpreted."""
    if not isinstance(value, (list, tuple)):
        return ()
    return tuple(entry for entry in value if isinstance(entry, str))


def _identity(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _unverified(subject_id: str, evaluated_at: datetime, reason: str,
                standing: str = TrustState.UNKNOWN.value,
                stored_standing: str | None = None) -> TrustVerification:
    return TrustVerification(
        subject_id=subject_id, status=UNVERIFIED, standing=standing,
        stored_standing=stored_standing if stored_standing is not None else standing,
        evaluated_at=evaluated_at.isoformat(), reasons=(reason,))


def verify_subject(store, subject_id: Any, *, evaluated_at: Any) -> TrustVerification:
    """What the Trust Plane says about this subject at this instant.

    Reads only. Asks the released query interface once and reports what came
    back; anything it cannot resolve is `unverified`, never assumed.
    """
    subject = _require_subject(subject_id)
    instant = _require_instant(evaluated_at)

    try:
        reported = get_current_trust(store, subject, evaluated_at=instant)
    except Exception:  # noqa: BLE001
        # Deliberately broad, and deliberately final. Anything the Trust Plane
        # could not answer is unverified, and the exception itself is not
        # reported: its text is not something a caller can depend on.
        return _unverified(subject, instant, REASON_UNAVAILABLE)

    if not isinstance(reported, dict):
        return _unverified(subject, instant, REASON_UNREADABLE)

    standing = _standing(reported.get("effective_state"))
    stored = _standing(reported.get("stored_state"))
    usable = reported.get("usable") is True and standing in USABLE_STANDINGS

    common = dict(
        subject_id=subject,
        standing=standing,
        stored_standing=stored,
        evaluated_at=instant.isoformat(),
        lineage_id=_identity(reported.get("lineage_id")),
        record_id=_identity(reported.get("record_id")),
        decision_id=_identity(reported.get("decision_id")),
        evidence_reference_ids=_references(reported.get("evidence_reference_ids")),
    )

    if usable:
        return TrustVerification(status=VERIFIED, **common)

    reason = _REASON_FOR_STANDING.get(standing, REASON_NOT_USABLE)
    return TrustVerification(status=UNVERIFIED, reasons=(reason,), **common)


def verify_trust_record(store, record_id: Any, *,
                        evaluated_at: Any) -> TrustVerification:
    """The same answer, reached from a trust record identity.

    Fabric records reference trust by record identity; the released query
    interface answers by subject. This resolves one to the other and asks the
    same question, so there is still only one route to standing.
    """
    identifier = _require_subject(record_id)
    instant = _require_instant(evaluated_at)

    try:
        record = get_trust_record(store, identifier)
    except Exception:  # noqa: BLE001
        return _unverified(identifier, instant, REASON_UNAVAILABLE)

    subject = record.get("subject_id") if isinstance(record, dict) else None
    if not isinstance(subject, str) or not subject.strip():
        return _unverified(identifier, instant, REASON_UNREADABLE)

    return verify_subject(store, subject, evaluated_at=instant)
