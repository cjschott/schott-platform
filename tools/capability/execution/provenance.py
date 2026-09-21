"""Provenance correction of an administrative record, for the ENG-0005 adapter.

**The problem this exists for.** On 2026-09-20 a rehearsal harness drove
``capability abandon`` against production. The lifecycle effect it produced is
materially the one the design specifies -- ``CINV-000002`` is closed, one slot
was reclaimed, nothing was deleted or rewritten -- but ``CADM-000001`` records
``actor: primary-platform-operator`` for an action no operator took or approved.
The store therefore holds a true effect under an untrue attribution.

**Correcting provenance is not reversing an action.** Those are different
claims and this module never conflates them. The lifecycle stays exactly where
it is: nothing here writes a transition, touches capacity, allocates a result,
or reads the invocation's occupancy. What it writes is a second, separate,
append-only record which says *this particular claim, in that particular
record, is not truthful provenance, and the effect stands regardless*.

**The subject is never opened for writing.** The original ``CADM`` is read,
digested, and left byte-for-byte as it is. A correction that could edit its
subject would be an edit history, which is the mechanism this deliberately is
not: the disputed claim remains readable forever, alongside the finding about
it.

**It cannot reach a lifecycle claim.** ``CORRECTABLE_FIELDS`` is a closed set
containing provenance attributions only. ``state``, ``previous_state``,
``reason``, ``slot_released`` and ``result_record_id`` are not correctable here
by construction -- a dispute about *what happened* is not a dispute about *who
is recorded as having done it*, and allowing one verb to answer both would
recreate the force-transition that ADR-0015 refused.

**What it does not claim.** It does not ratify the original action, it does not
assert that an operator approved it, and it does not name a substitute actor. The
attribution is recorded as disputed and the initiator is named from a closed
vocabulary. Under the current design ``actor`` is an asserted string and not an
authenticated identity (see ADR-0016 §"What actor means"), so a correction can
only ever say which claim is not to be trusted.

Governed by ``docs/decisions/ADR-0016-provenance-correction-of-administrative-records.md``.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
from datetime import datetime
from typing import Any

from . import admin as admin_module
from . import canonical_json
from . import state as state_module
from .backing_store import RootDescriptor, target_fingerprint

# The claims this verb may dispute. Provenance attributions only, and today
# exactly one of them. A lifecycle claim is deliberately absent: see the module
# docstring.
FIELD_ACTOR = "actor"
CORRECTABLE_FIELDS = frozenset({FIELD_ACTOR})

# What is wrong with the claim. Closed, because "the audit is answerable only by
# reading prose" is the failure mode the administrative namespace already
# avoids everywhere else.
FINDING_NOT_AUTHORISED = "attribution-not-authorised"
FINDINGS = frozenset({FINDING_NOT_AUTHORISED})

# Who actually initiated the corrected action. Closed for the same reason, and
# `unknown` is a first-class answer rather than an invitation to guess.
INITIATOR_UNAUTHORISED_REHEARSAL = "unauthorised-rehearsal-harness"
INITIATOR_UNKNOWN = "unknown"
INITIATORS = frozenset({INITIATOR_UNAUTHORISED_REHEARSAL, INITIATOR_UNKNOWN})

# The effect of the corrected action is retained. This is the only value the
# field may take, and it is written out rather than implied so that a reader
# never has to infer it from the absence of something.
EFFECT_RETAINED = "retained"

PROVENANCE_CORRECTION = "provenance-correction"
CORRECTION_SCHEMA_VERSION = 1

_MAXIMUM_DETAIL_BYTES = 64 * 1024
_MAXIMUM_REFERENCES = 16
_MAXIMUM_REFERENCE_BYTES = 512

__all__ = ["ProvenanceError", "ProvenanceRefused", "Correction",
           "CORRECTABLE_FIELDS", "FIELD_ACTOR", "FINDINGS",
           "FINDING_NOT_AUTHORISED", "INITIATORS",
           "INITIATOR_UNAUTHORISED_REHEARSAL", "INITIATOR_UNKNOWN",
           "EFFECT_RETAINED", "PROVENANCE_CORRECTION", "correct_provenance",
           "existing_correction"]


class ProvenanceError(ValueError):
    """Base for every refusal this module makes."""


class ProvenanceRefused(ProvenanceError):
    """The correction was not permitted."""


@dataclasses.dataclass(frozen=True)
class Correction:
    """What one accepted provenance correction concluded."""

    cadm: str
    subject_cadm: str
    subject_member: str
    subject_digest: str
    cinv: str
    disputed_field: str
    disputed_value: str
    finding: str
    actual_initiator: str
    effect: str
    lifecycle_state: str
    resumed: bool
    target: dict[str, int]


def _text(value: Any, what: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ProvenanceRefused(f"{what} must be a non-empty string")
    return value


def _instant(value: Any) -> str:
    raw = _text(value, "recorded_at")
    try:
        parsed = datetime.fromisoformat(raw)
    except (TypeError, ValueError) as error:
        raise ProvenanceRefused(
            f"recorded_at is not an ISO-8601 instant ({error})") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ProvenanceRefused(
            "recorded_at carries no timezone offset; refusing to guess one")
    return raw


def _references(value: Any) -> tuple[str, ...]:
    """The evidence this correction points at, checked and ordered."""
    if value is None:
        return ()
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        raise ProvenanceRefused("evidence_references must be a list of strings")
    if len(value) > _MAXIMUM_REFERENCES:
        raise ProvenanceRefused(
            f"at most {_MAXIMUM_REFERENCES} evidence references are accepted")
    cleaned = []
    for item in value:
        reference = _text(item, "an evidence reference")
        if len(reference.encode("utf-8")) > _MAXIMUM_REFERENCE_BYTES:
            raise ProvenanceRefused("an evidence reference is too long")
        cleaned.append(reference)
    if len(set(cleaned)) != len(cleaned):
        raise ProvenanceRefused("the evidence references repeat")
    return tuple(sorted(cleaned))


def _members(root: RootDescriptor, cadm: str) -> dict[str, bytes]:
    """Every member of one administrative record, read-only.

    The record directory is opened for reading and nothing else: the subject of
    a correction is evidence, and evidence this verb could open for writing
    would be evidence nobody could rely on afterwards.
    """
    try:
        handle = admin_module._record_directory(root, cadm)
    except (FileNotFoundError, admin_module.AdminError):
        # The administrative namespace answers for itself, but a caller of this
        # verb should get this verb's vocabulary: the subject is not there.
        raise ProvenanceRefused(f"{cadm} is not a recorded CADM") from None
    try:
        names = sorted(os.listdir(handle))
        bodies: dict[str, bytes] = {}
        for name in names:
            try:
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                             dir_fd=handle)
            except (IsADirectoryError, OSError):
                continue
            try:
                body = os.read(fd, _MAXIMUM_DETAIL_BYTES + 1)
            finally:
                os.close(fd)
            if len(body) > _MAXIMUM_DETAIL_BYTES:
                raise ProvenanceRefused(f"{cadm}/{name} is larger than expected")
            bodies[name] = body
        return bodies
    finally:
        os.close(handle)


def _document(body: bytes, what: str) -> dict[str, Any]:
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ProvenanceRefused(f"{what} is unreadable") from None
    if not isinstance(parsed, dict):
        raise ProvenanceRefused(f"{what} is not a record")
    return parsed


def existing_correction(root: RootDescriptor, subject_cadm: str,
                        field: str) -> dict[str, Any] | None:
    """The durable correction of ``field`` in ``subject_cadm``, or nothing.

    Scanned from the records rather than indexed, for the reason the
    abandonment reader gives: an index is a second thing that can disagree with
    the evidence.
    """
    try:
        handle = os.open(admin_module.ADMIN_RECORDS,
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                         | os.O_DIRECTORY, dir_fd=root.fd)
    except FileNotFoundError:
        return None
    try:
        for name in sorted(os.listdir(handle)):
            try:
                record_fd = os.open(name,
                                    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                                    | os.O_DIRECTORY, dir_fd=handle)
            except (FileNotFoundError, NotADirectoryError, OSError):
                continue
            try:
                try:
                    fd = os.open(PROVENANCE_CORRECTION,
                                 os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 dir_fd=record_fd)
                except FileNotFoundError:
                    continue
                try:
                    body = os.read(fd, _MAXIMUM_DETAIL_BYTES + 1)
                finally:
                    os.close(fd)
            finally:
                os.close(record_fd)
            document = _document(body, f"the correction record in {name}")
            if (document.get("subject_cadm") == subject_cadm
                    and document.get("disputed_field") == field):
                return document
    finally:
        os.close(handle)
    return None


def _subject_member(members: dict[str, bytes], subject_cadm: str,
                    field: str) -> tuple[str, dict[str, Any], bytes]:
    """The one member of the subject that carries the disputed field.

    Exactly one, because a claim appearing twice is a record whose correction
    would be ambiguous -- and this verb refuses ambiguity rather than picking.
    """
    carrying = []
    for name, body in members.items():
        document = _document(body, f"{subject_cadm}/{name}")
        if field in document:
            carrying.append((name, document, body))
    if not carrying:
        raise ProvenanceRefused(
            f"no member of {subject_cadm} carries a {field!r} claim")
    if len(carrying) > 1:
        raise ProvenanceRefused(
            f"{field!r} appears in more than one member of {subject_cadm}: "
            f"{sorted(name for name, _, _ in carrying)}")
    return carrying[0]


def correct_provenance(*, execution_root: Any, subject_cadm: Any, cinv: Any,
                       disputed_field: Any, disputed_value: Any, finding: Any,
                       actual_initiator: Any, actor: Any, request_id: Any,
                       recorded_at: Any,
                       evidence_references: Any = None) -> Correction:
    """Record that one claim in an earlier `CADM` is not truthful provenance.

    Takes the `CINV` lock and nothing else. The capacity lock is deliberately
    **not** taken: a verb that touched occupancy would need it, and this one
    must never be able to.

    Idempotent where it is safe to be: repeating the identical accepted
    correction reports ``resumed`` and writes nothing. A correction that differs
    in any recorded field refuses, because two findings about one claim is a
    disagreement no reader could resolve.
    """
    if not isinstance(execution_root, RootDescriptor):
        raise ProvenanceRefused("execution_root must be a verified RootDescriptor")
    identity = state_module.validate_cinv(cinv)
    subject = _text(subject_cadm, "subject_cadm")
    if not admin_module._is_cadm(subject):
        raise ProvenanceRefused(f"{subject!r} is not a CADM identity")
    field = _text(disputed_field, "disputed_field")
    if field not in CORRECTABLE_FIELDS:
        raise ProvenanceRefused(
            f"{field!r} is not a correctable provenance claim; this verb "
            f"corrects {sorted(CORRECTABLE_FIELDS)} and no lifecycle claim")
    claimed = _text(disputed_value, "disputed_value")
    finding_text = _text(finding, "finding")
    if finding_text not in FINDINGS:
        raise ProvenanceRefused(f"{finding_text!r} is not a controlled finding")
    initiator = _text(actual_initiator, "actual_initiator")
    if initiator not in INITIATORS:
        raise ProvenanceRefused(f"{initiator!r} is not a controlled initiator")
    actor_text = _text(actor, "actor")
    request_text = _text(request_id, "request_id")
    recorded_text = _instant(recorded_at)
    references = _references(evidence_references)

    # What the mutator is actually about to write through, asked of the kernel.
    target = target_fingerprint(execution_root)

    locks = state_module._LockOrder()
    locks.acquire_cinv(identity, execution_root)
    try:
        members = _members(execution_root, subject)
        if not members:
            raise ProvenanceRefused(f"{subject} holds no members to correct")
        member_name, document, body = _subject_member(members, subject, field)

        held = document.get(field)
        if held != claimed:
            raise ProvenanceRefused(
                f"{subject}/{member_name} records {field} {held!r}, not "
                f"{claimed!r}; refusing to correct a claim that is not there")
        if document.get("cinv") not in (None, identity):
            raise ProvenanceRefused(
                f"{subject} is about {document.get('cinv')}, not {identity}")

        # The effect must still be standing. Correcting the provenance of an
        # effect that has since changed would describe a store that no longer
        # exists, so the subject's own lifecycle claim is checked against the
        # lifecycle now.
        current = state_module.current_state(execution_root, identity)
        if current is None:
            raise ProvenanceRefused(
                f"{identity} has no durable execution state")
        recorded_state = document.get("state")
        if recorded_state is not None and recorded_state != current.value:
            raise ProvenanceRefused(
                f"{subject} recorded state {recorded_state!r} and {identity} is "
                f"now {current.value!r}; the effect this would correct has "
                "changed")

        digest = hashlib.sha256(body).hexdigest()

        prior = existing_correction(execution_root, subject, field)
        if prior is not None:
            for key, value in (("subject_member", member_name),
                               ("subject_digest", digest),
                               ("cinv", identity),
                               ("disputed_value", claimed),
                               ("finding", finding_text),
                               ("actual_initiator", initiator),
                               ("actor", actor_text),
                               ("request_id", request_text),
                               ("recorded_at", recorded_text)):
                if prior.get(key) != value:
                    raise ProvenanceRefused(
                        f"{subject}/{field} is already corrected under "
                        f"different authority ({key} {prior.get(key)!r}, not "
                        f"{value!r})")
            return Correction(
                cadm=prior["cadm"], subject_cadm=subject,
                subject_member=member_name, subject_digest=digest,
                cinv=identity, disputed_field=field, disputed_value=claimed,
                finding=finding_text, actual_initiator=initiator,
                effect=EFFECT_RETAINED, lifecycle_state=current.value,
                resumed=True, target=target)

        # Intent, one attempt, outcome, each durable and create-once.
        cadm = admin_module.allocate_cadm(execution_root)
        if cadm == subject:
            raise ProvenanceRefused(f"{cadm} cannot correct itself")
        admin_module.record_intent(execution_root, cadm,
                                   admin_module.Verb.CORRECT_PROVENANCE,
                                   identity, None)

        detail = {
            "action_reversed": False,
            "actor": actor_text,
            "actual_initiator": initiator,
            "cadm": cadm,
            "causal_references": sorted({subject, identity}),
            "cinv": identity,
            "correction_schema_version": CORRECTION_SCHEMA_VERSION,
            "disputed_field": field,
            "disputed_value": claimed,
            "effect": EFFECT_RETAINED,
            "evidence_references": list(references),
            "finding": finding_text,
            "lifecycle_state": current.value,
            "lifecycle_unchanged": True,
            "recorded_at": recorded_text,
            "request_id": request_text,
            "slot_changed": False,
            "subject_cadm": subject,
            "subject_digest": digest,
            "subject_member": member_name,
        }
        handle = admin_module._record_directory(execution_root, cadm)
        try:
            admin_module._write_durable(PROVENANCE_CORRECTION,
                                        canonical_json.serialise(detail),
                                        handle)
        except FileExistsError:
            raise ProvenanceRefused(
                f"{cadm} already records a provenance correction") from None
        finally:
            os.close(handle)

        admin_module.record_outcome(execution_root, cadm,
                                    admin_module.RESULT_DONE)

        return Correction(
            cadm=cadm, subject_cadm=subject, subject_member=member_name,
            subject_digest=digest, cinv=identity, disputed_field=field,
            disputed_value=claimed, finding=finding_text,
            actual_initiator=initiator, effect=EFFECT_RETAINED,
            lifecycle_state=current.value, resumed=False, target=target)
    finally:
        locks.release_all()
