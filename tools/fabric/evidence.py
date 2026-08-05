"""Evidence assembly for accepted Fabric records.

**There is no Fabric audit record.** ADR-0012 accepts eight record types and
claims completeness from them, so a generic audit-event record would be a
ninth. Evidence therefore rides the record whose existence it justifies, and
this module owns no record class of its own and persists nothing.

**Nothing here reads a clock.** The timestamp is caller-supplied and must carry
a timezone offset. A layer that stamped its own time would record when it ran
rather than when the governed decision was made, and the two are not the same
fact.

**Trust evidence is referenced, never restated.** Only trust record identities
appear. Copying a trust standing into a Fabric record would create a second,
staler answer to a question the Trust Plane already owns.

**An advertisement names no approving operator.** It is the one governed write
a human does not approve individually: the admitted subject publishes its own
claim, as itself. Recording an approver would turn a self-report into an
approval, so one is refused rather than accepted and ignored.

A record whose evidence cannot be assembled or validated is **not written** --
the governed action is refused rather than committed without the evidence that
justifies it.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime
from typing import Any

from .errors import FabricError
from .identifiers import ID_FIELDS, PATTERNS
from .request_identity import validate_request_digest, validate_request_id

# Named categories, drawn from the governed operations and outcomes the
# specification enumerates. A reason outside this vocabulary is refused rather
# than recorded as free text.
REASON_CATEGORIES = (
    "declaration",
    "subject-admission",
    "advertisement-registration",
    "instance-admission",
    "route-change",
    "supersession",
    "withdrawal",
    "retirement",
    "selection",
    "selection-refusal",
    "no-candidate",
)

# The subject publishes its own advertisement, acting as itself.
SELF_AUTHORED_KINDS = ("capability-advertisement",)

EVIDENCE_FIELDS = (
    "actor",
    "approving_authority",
    "causal_references",
    "trust_evidence_references",
    "reason_category",
    "recorded_at",
    "request_id",
    "request_digest",
)


def _require_text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FabricError(f"evidence {name} is required")
    return value


def _require_references(value: Any, name: str) -> tuple[str, ...]:
    # A bare string is a common slip and would silently become a sequence of
    # characters, so it is refused rather than accepted.
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        raise FabricError(f"evidence {name} must be a sequence of identifiers")
    for entry in value:
        if not isinstance(entry, str) or not entry.strip():
            raise FabricError(f"evidence {name} carries an empty reference")
    return tuple(value)


def _validate(kind: str, evidence: Any) -> None:
    """Refuse anything that is not complete, well-formed evidence for `kind`."""
    if kind not in ID_FIELDS:
        raise FabricError(f"unknown record kind '{kind}'")
    if not isinstance(evidence, Mapping):
        raise FabricError("evidence must be a mapping")

    supplied = set(evidence)
    missing = sorted(set(EVIDENCE_FIELDS) - supplied)
    if missing:
        # Named, not echoed: a field name is safe to report, a value is not.
        raise FabricError(f"evidence is missing required field(s): {', '.join(missing)}")
    unknown = sorted(supplied - set(EVIDENCE_FIELDS))
    if unknown:
        raise FabricError(f"evidence carries unknown field(s): {', '.join(unknown)}")

    _require_text(evidence["actor"], "actor")

    authority = evidence["approving_authority"]
    if kind in SELF_AUTHORED_KINDS:
        if authority is not None:
            raise FabricError(
                f"a '{kind}' is published by its subject and names no approving authority")
    else:
        _require_text(authority, "approving_authority")

    for reference in _require_references(evidence["causal_references"],
                                         "causal_references"):
        if not any(pattern.match(reference) for pattern in PATTERNS.values()):
            raise FabricError("evidence causal_references carries a value that "
                              "is not a fabric record identity")
    # Trust identities are referenced, never interpreted: the Fabric asserts
    # nothing about their shape beyond their being usable references.
    _require_references(evidence["trust_evidence_references"],
                        "trust_evidence_references")

    if evidence["reason_category"] not in REASON_CATEGORIES:
        raise FabricError("evidence reason_category is not a named category")

    stamp = evidence["recorded_at"]
    if not isinstance(stamp, str) or not stamp.strip():
        raise FabricError("evidence recorded_at is required")
    try:
        recorded = datetime.fromisoformat(stamp)
    except ValueError:
        raise FabricError("evidence recorded_at is not a readable timestamp") from None
    if recorded.tzinfo is None or recorded.tzinfo.utcoffset(recorded) is None:
        raise FabricError("evidence recorded_at must carry a timezone offset")

    validate_request_id(evidence["request_id"])
    validate_request_digest(evidence["request_digest"])


def assemble_evidence(kind: str, *, actor: Any, reason_category: Any,
                      recorded_at: Any, request_id: Any, request_digest: Any,
                      approving_authority: Any = None,
                      causal_references: Any = (),
                      trust_evidence_references: Any = ()) -> dict[str, Any]:
    """Build the evidence an accepted record must carry, or refuse.

    The caller's inputs are copied, never mutated, and the timestamp must
    arrive as a timezone-aware datetime: accepting text here would let an
    offset-free string through as though it were an instant.
    """
    if not isinstance(recorded_at, datetime):
        raise FabricError("evidence recorded_at must be supplied as a datetime")
    if recorded_at.tzinfo is None or recorded_at.tzinfo.utcoffset(recorded_at) is None:
        raise FabricError("evidence recorded_at must carry a timezone offset")

    evidence: dict[str, Any] = {
        "actor": actor,
        "approving_authority": approving_authority,
        "causal_references": (list(causal_references)
                              if isinstance(causal_references, (list, tuple))
                              else causal_references),
        "trust_evidence_references": (list(trust_evidence_references)
                                      if isinstance(trust_evidence_references, (list, tuple))
                                      else trust_evidence_references),
        "reason_category": reason_category,
        "recorded_at": recorded_at.isoformat(),
        "request_id": request_id,
        "request_digest": request_digest,
    }
    _validate(kind, evidence)
    return evidence


def validate_record_evidence(kind: str, evidence: Any) -> None:
    """Refuse a record whose evidence is absent, incomplete, or malformed."""
    if evidence is None:
        raise FabricError(f"a '{kind}' record carries no evidence")
    _validate(kind, evidence)
