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

# The subject publishes its own advertisement, acting as itself. Naming an
# approving operator would turn a self-report into an approval, so one is
# refused rather than accepted and ignored.
SELF_AUTHORED_KINDS = ("capability-advertisement",)

# A selection is a deterministic read plus its own record. No human operator
# approves it either, so naming one would describe a derived choice as an
# approved decision.
DERIVED_KINDS = ("capability-selection",)

# Neither is a human-authorised mutation, so neither names an approving
# authority. The rule is a refusal, not an omission: evidence that records an
# approver nobody gave is worse than evidence that records none.
UNAPPROVED_KINDS = SELF_AUTHORED_KINDS + DERIVED_KINDS

# A selection's outcome is not a stored field -- the accepted schema has none.
# It is readable from what the selection says, and the reason category the
# specification already requires names exactly these three.
OUTCOME_CATEGORIES = {
    "selected": "selection",
    "refused": "selection-refusal",
    "no-candidate": "no-candidate",
}

# The record field naming the subject that must be the acting identity.
ACTOR_SUBJECT_FIELDS = {"capability-advertisement": "capability_host_id"}

# The record fields carrying the Trust Plane records a kind relies on. Evidence
# must reference them; it never restates what they say.
TRUST_REFERENCE_FIELDS = {
    "capability-host": ("fabric_node_trust_record_id",),
    "capability-instance": ("package_trust_record_id", "host_trust_record_id"),
}

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
    """Refuse anything that is not complete, well-formed evidence for `kind`.

    Shape only. Applicability that depends on the record's own fields is
    checked by `_validate_applicability`, which can see them.
    """
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
    if kind in UNAPPROVED_KINDS:
        if authority is not None:
            raise FabricError(
                f"a '{kind}' is not a human-authorised mutation "
                "and names no approving authority")
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


def _named_instances(entry: Any) -> set[str]:
    """The candidate identities an exclusion entry names.

    An entry may be the identifier itself or a mapping carrying it alongside a
    reason. Values are matched against the accepted instance pattern rather
    than against a guessed key name.
    """
    pattern = PATTERNS["capability-instance"]
    if isinstance(entry, str):
        return {entry} if pattern.match(entry) else set()
    if isinstance(entry, Mapping):
        return {value for value in entry.values()
                if isinstance(value, str) and pattern.match(value)}
    return set()


def _require_selection_outcome(record, evidence: Mapping[str, Any]) -> None:
    """The three outcomes are mutually exclusive, and the record must say which.

    Nothing is guessed: a chosen instance means selected, no chosen instance
    with candidates considered means every one was excluded, and no chosen
    instance with none considered means there was nothing to choose from. The
    reason category has to agree, so a contradiction cannot be persisted and
    then faithfully replayed as though it were a decision.
    """
    chosen = record.selected_instance_id
    considered = tuple(record.considered_candidates or ())
    excluded = tuple(record.excluded_candidates or ())
    refusal = record.refusal_reason
    category = evidence["reason_category"]

    if chosen is not None:
        outcome = "selected"
        if refusal is not None:
            raise FabricError("a selected outcome carries no refusal reason")
        if chosen not in considered:
            raise FabricError("a selected instance must be among those considered")
    elif considered:
        outcome = "refused"
        if not isinstance(refusal, str) or not refusal.strip():
            raise FabricError("a refused outcome must carry its refusal reason")
    else:
        outcome = "no-candidate"
        if excluded:
            raise FabricError(
                "a no-candidate outcome excludes no candidate, having considered none")

    if category != OUTCOME_CATEGORIES[outcome]:
        raise FabricError(
            f"a '{outcome}' selection must be recorded as "
            f"'{OUTCOME_CATEGORIES[outcome]}'")

    # Every candidate that was considered and not chosen needs its exclusion
    # reason: a record naming only the winner documents the outcome and hides
    # the decision.
    unselected = set(considered) - ({chosen} if chosen is not None else set())
    named: set[str] = set()
    for entry in excluded:
        named |= _named_instances(entry)
    missing = sorted(unselected - named)
    if missing:
        raise FabricError(
            f"a selection must record an exclusion reason for {', '.join(missing)}")


def _validate_applicability(kind: str, record, evidence: Mapping[str, Any]) -> None:
    """Rules that can only be judged against the complete record.

    Nothing here is duplicated into the evidence: supersession and trust
    references are read from the fields the record already carries, and the
    evidence is required to agree with them.
    """
    subject_field = ACTOR_SUBJECT_FIELDS.get(kind)
    if subject_field is not None:
        subject = getattr(record, subject_field, None)
        if not isinstance(subject, str) or subject not in evidence["actor"]:
            raise FabricError(
                f"a '{kind}' must be published by the subject it advertises")

    # Symmetric on purpose. Checking only when the reason category announces
    # supersession would let a record that supersedes another hide the fact by
    # declaring some other reason.
    prior = getattr(record, "supersedes", None)
    declared = evidence["reason_category"] == "supersession"
    if declared or prior is not None:
        if not isinstance(prior, str) or not prior:
            raise FabricError(
                "a superseding record must name the record it supersedes")
        if not declared:
            raise FabricError(
                "a record that supersedes another must declare the supersession "
                "reason category")
        if prior not in tuple(evidence["causal_references"]):
            raise FabricError(
                "a superseding record's evidence must reference the record it supersedes")

    if kind == "capability-selection":
        _require_selection_outcome(record, evidence)

    references = tuple(evidence["trust_evidence_references"])
    for field in TRUST_REFERENCE_FIELDS.get(kind, ()):
        relied_on = getattr(record, field, None)
        if not isinstance(relied_on, str) or not relied_on:
            raise FabricError(f"a '{kind}' must carry {field}")
        if relied_on not in references:
            raise FabricError(
                f"a '{kind}' must reference the trust record named by {field}")


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


def validate_record_evidence(kind: str, record) -> None:
    """Refuse a record whose evidence is absent, incomplete, or inapplicable.

    Takes the complete record, not an isolated mapping: whether a prior-record
    reference or a trust reference is required is a property of the record, and
    a validator that cannot see the record would have to guess.
    """
    if kind not in ID_FIELDS:
        raise FabricError(f"unknown record kind '{kind}'")
    evidence = getattr(record, "evidence", None)
    if evidence is None:
        raise FabricError(f"a '{kind}' record carries no evidence")
    _validate(kind, evidence)
    _validate_applicability(kind, record, evidence)
