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

from ..trust.identifiers import DECISION_ID, EVIDENCE_ID, LINEAGE_ID, RECORD_ID
from ..trust.models import TrustState
from ..trust.query import get_current_trust, get_trust_record
from .errors import FabricError

VERIFIED = "verified"
UNVERIFIED = "unverified"

# Every standing the released Trust Plane vocabulary defines. A value outside
# it is not interpreted and not downgraded: the response carrying it is
# refused as unreadable, because guessing what an unknown standing meant is
# how an unrecognised value becomes a permissive one.
KNOWN_STANDINGS = frozenset(state.value for state in TrustState)

# Standings a subject may actually be used in. Taken from the released
# vocabulary rather than restated as a policy of the Fabric's own.
USABLE_STANDINGS = frozenset({TrustState.TRUSTED.value, TrustState.RESTRICTED.value})

# Only a usable standing can age out, and expiry is the one change time makes.
# So a stored standing either survives unchanged or becomes expired -- every
# other pairing is one the released contract cannot yield.
EXPIRABLE_STANDINGS = frozenset({TrustState.TRUSTED.value, TrustState.RESTRICTED.value})

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


def _producible(stored: str, standing: str) -> bool:
    """Whether the released expiry contract can yield this pair of standings."""
    if standing == stored:
        return True
    return stored in EXPIRABLE_STANDINGS and standing == TrustState.EXPIRED.value


def _references(value: Any) -> tuple[str, ...] | None:
    """Evidence identities in order, or None when any is not a released one."""
    if not isinstance(value, (list, tuple)):
        return None
    for entry in value:
        # fullmatch, not match: the released patterns anchor with `$`, which
        # matches before a trailing newline, so an identity with one would
        # otherwise pass as the identity without it.
        if not isinstance(entry, str) or not EVIDENCE_ID.fullmatch(entry):
            return None
    return tuple(value)


def _incoherent(reported: Any, subject: str, instant: datetime) -> bool:
    """Whether the released response can be relied on at all.

    A standing is only as good as the record it came from. A response that
    reports somebody else's subject, a standing outside the released
    vocabulary, a `usable` flag that is not a flag, or authoritative
    identities that are partly missing is not a weaker answer -- it is not an
    answer, and treating it as one would grant standing nothing actually says.
    """
    if not isinstance(reported, dict):
        return True
    if reported.get("subject_id") != subject:
        return True

    standing = reported.get("effective_state")
    stored = reported.get("stored_state")
    if standing not in KNOWN_STANDINGS or stored not in KNOWN_STANDINGS:
        return True
    if not _producible(stored, standing):
        return True

    usable = reported.get("usable")
    if not isinstance(usable, bool):
        return True
    # The released flag is exactly membership of the usable set; a response
    # where they disagree cannot be interpreted either way.
    if usable != (standing in USABLE_STANDINGS):
        return True

    # Stated, not merely not-contradicted. A response that never says which
    # moment it describes cannot be checked against the moment that was asked
    # about, so an answer about any instant would pass as an answer about this
    # one.
    if reported.get("evaluated_at") != instant.isoformat():
        return True

    if _references(reported.get("evidence_reference_ids")) is None:
        return True

    reasons = reported.get("reasons")
    if not isinstance(reasons, (list, tuple)):
        return True
    if any(not isinstance(entry, str) for entry in reasons):
        return True

    # An identity is either absent or a released identifier. Present but
    # unrecognisable is neither absence nor a citation: 'arbitrary text' names
    # nothing the Trust Plane could have allocated.
    identities = []
    # The released evaluation carries the bare lineage identity; the versioned
    # form (TLIN-000001-v0001) names the lineage *record*, not the lineage.
    for name, pattern in (("lineage_id", LINEAGE_ID),
                          ("record_id", RECORD_ID),
                          ("decision_id", DECISION_ID)):
        value = reported.get(name)
        if value is None:
            identities.append(None)
            continue
        recognised = _identity(value, pattern)
        if recognised is None:
            return True
        identities.append(recognised)
    resolved = sum(1 for entry in identities if entry is not None)

    if standing == TrustState.UNKNOWN.value:
        # Absence cites nothing. A response naming a lineage, a record, or a
        # decision is describing something that exists and could not be read,
        # and calling that "no trust" would lose the difference. Absence also
        # has nothing stored: an unknown effective standing over a stored
        # grant is a record that failed to interpret, not a subject never found.
        if stored != TrustState.UNKNOWN.value:
            return True
        return resolved != 0

    # Every recognised standing rests on a record, so it cites all three.
    # A verified subject is verified by something nameable; an expired or
    # revoked one is refused on the strength of something equally nameable.
    return resolved != len(identities)


def _identity(value: Any, pattern) -> str | None:
    """A released identifier, exactly as written, or nothing.

    Matched against the released pattern rather than merely checked for
    content, and never trimmed or reshaped: an identity that needed correcting
    to match is not the identity that was reported.
    """
    return value if isinstance(value, str) and pattern.fullmatch(value) else None


def _require_record_identity(record_id: Any) -> str:
    """A trust record identity a caller supplies is a released identifier."""
    if not isinstance(record_id, str) or not RECORD_ID.fullmatch(record_id):
        raise FabricError(
            "a trust record identity must be a released record identifier")
    return record_id


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

    if _incoherent(reported, subject, instant):
        return _unverified(subject, instant, REASON_UNREADABLE)

    standing = reported["effective_state"]
    stored = reported["stored_state"]
    usable = reported["usable"]

    common = dict(
        subject_id=subject,
        standing=standing,
        stored_standing=stored,
        evaluated_at=instant.isoformat(),
        lineage_id=_identity(reported.get("lineage_id"), LINEAGE_ID),
        record_id=_identity(reported.get("record_id"), RECORD_ID),
        decision_id=_identity(reported.get("decision_id"), DECISION_ID),
        evidence_reference_ids=_references(reported.get("evidence_reference_ids")) or (),
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
    identifier = _require_record_identity(record_id)
    instant = _require_instant(evaluated_at)

    try:
        record = get_trust_record(store, identifier)
    except Exception:  # noqa: BLE001
        return _unverified(identifier, instant, REASON_UNAVAILABLE)

    if not isinstance(record, dict):
        return _unverified(identifier, instant, REASON_UNREADABLE)

    # The record that came back must be the record that was asked for. A
    # lookup that answers with a different record answers a different question.
    stored_identity = record.get("record_id")
    if (_identity(stored_identity, RECORD_ID) is None
            or stored_identity != identifier):
        return _unverified(identifier, instant, REASON_UNREADABLE)

    subject = record.get("subject_id")
    if not isinstance(subject, str) or not subject.strip():
        return _unverified(identifier, instant, REASON_UNREADABLE)

    return verify_subject(store, subject, evaluated_at=instant)
