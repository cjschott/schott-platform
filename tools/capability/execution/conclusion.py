"""Governed post-execution lifecycle conclusion for the ENG-0005 first adapter.

**The problem this exists for.** A supervised execution records its terminal
result and stops. The lifecycle journal is written by ``authorise_launch``
before the privilege boundary is crossed, and the states past
``launch_authorized`` are worker-side protocol states that exist on the wire and
never in the journal. G11-BC-I established that as specified behaviour. What it
did not state is the consequence: **every successful supervised execution
strands at ``launch_authorized`` holding an execution slot for ever**, because
``released`` is reachable only through states nothing writes.

Measured, not inferred. The only lifecycle states the released package writes
anywhere are ``launch_authorized``, ``cleaned``, ``released`` and ``abandoned``;
reachability from ``launch_authorized`` through states that can actually be
written yields exactly one destination, ``abandoned``.

**Why the normal chain cannot be used.** G11-BC-AD tried it first: journal the
progression the coordinator drove, then let ``cleanup`` and ``capacity.release``
finish. ``cleanup`` records ``cleaned`` only after the per-`CINV` handoff
subtree is gone, and §13 transfers the output leaf to the execution identity --
``out`` ends up owned by the execution principal and mode ``0700``, while this
side of the boundary is the coordinator. The numbers are a fact about a
deployment and are deliberately not written down here; what matters is that the
owner is not the coordinator. It cannot open the leaf, empty it or remove it,
released ``cleanup`` refuses
with ``CleanupIncomplete: directory 'out' could not be opened``, and nothing in
the released system -- privileged or otherwise -- removes that leaf. So
``cleaned`` is structurally unreachable for every supervised invocation, and
claiming it would make the one record that says "the runtime is finished with
this" untrue.

**What this is instead.** ``CONCLUDED``: the execution ran, concluded, and its
terminal result is durable -- and the cleanup progression did not run. It is
terminal, it holds no execution slot, and it is neither ``released`` nor
``abandoned``. It does not claim the classification, collection and cleaning
``released`` claims. It does not decline to say what happened, which is what
``abandoned`` does. It says the execution completed and points at the record
that proves it.

**Why not ``abandoned``.** The supervised path strands every success, so reusing
the exceptional closure for them would make ``abandoned`` the normal end of the
happy path and destroy the property ADR-0015 exists to create: that a stranded
invocation is distinguishable from a completed one for ever.

**Observation versus reconstruction.** Inline, this closes an execution the same
process just supervised. Administratively -- for an invocation that executed
under a generation which kept no trace -- the closure rests on the durable
terminal result alone, and the evidence records which kind of claim was made.
The reconstruction is licensed by the supervision invariant: a supervised
execution that cannot prove its container is gone returns no terminal outcome at
all, so a terminal `CRES` is itself proof the container was created, ran,
concluded and was disposed of. It is not a substitute for observation, and the
operator ceremony still observes the container plane first.

**No execution evidence is invented.** This writes no result, of any outcome,
and refuses an invocation that has none -- closing one would take it out of the
recovery enumeration that could still resolve it. It reaches no container,
removes nothing, and carries no destruction authority.

**The handoff subtree is left in place, and that is recorded.** Nothing here
pretends it was cleaned. Removing it needs an authority this operation does not
have and should not acquire; the residue is stated in the evidence so a later
reader knows it is there.

Governed by ``docs/decisions/ADR-0017-post-execution-lifecycle-conclusion.md``.
"""

from __future__ import annotations

import dataclasses
import json
import os
from datetime import datetime
from typing import Any

from ..errors import CapabilityError
from ..identifiers import ID_FIELDS
from ..records import INVOCATION_KIND, RESULT_KIND
from . import admin as admin_module
from . import canonical_json
from . import state as state_module
from .backing_store import RootDescriptor
from .types import LifecycleState

CONCLUSION = "conclusion"
CONCLUSION_SCHEMA_VERSION = 1

_MAXIMUM_DETAIL_BYTES = 8192

#: The only state a conclusion may close. A supervised invocation is never left
#: anywhere else: the states past `launch_authorized` are worker-side protocol
#: states that exist on the wire and never in this journal.
STARTABLE_STATE = LifecycleState.LAUNCH_AUTHORIZED

#: How the progression was arrived at. Recorded, never assumed by a reader.
DERIVATION_OBSERVED = "observed"
DERIVATION_RECONSTRUCTED = "reconstructed"
DERIVATIONS = frozenset({DERIVATION_OBSERVED, DERIVATION_RECONSTRUCTED})


class ConclusionError(ValueError):
    """A conclusion could not be performed."""


class ConclusionRefused(ConclusionError):
    """A conclusion was refused before anything was written."""


@dataclasses.dataclass(frozen=True)
class Conclusion:
    """What a conclusion did, or found already done."""

    cinv: str
    cadm: str | None
    previous_state: str
    state: str
    result_record_id: str
    derivation: str
    handoff_retained: bool
    slot_released: bool
    resumed: bool


def _text(value: Any, what: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConclusionRefused(f"{what} must be a non-empty string")
    return value


def _instant(value: Any) -> str:
    """An ISO-8601 instant carrying an offset, or refuse.

    A naive timestamp is refused rather than assumed to be local: an
    administrative record whose instant means different things to different
    readers is not evidence.
    """
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise ConclusionRefused("recorded_at must carry a timezone offset")
        return value.isoformat()
    text = _text(value, "recorded_at")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        raise ConclusionRefused(
            f"recorded_at is not an ISO-8601 instant: {text!r}") from None
    if parsed.tzinfo is None:
        raise ConclusionRefused("recorded_at must carry a timezone offset")
    return parsed.isoformat()


def _terminal_result(store: Any, cinv: str) -> str | None:
    """The identity of this invocation's terminal result, or nothing.

    Read from the store rather than accepted from the caller: which result
    belongs to which invocation is not a caller's claim to make. The identity
    field is taken from the released map rather than named here, because a
    plausible-looking guess would surface as "this invocation has no result",
    which is also what an invocation with genuinely none looks like.
    """
    try:
        records = list(store.list_records(RESULT_KIND))
    except Exception as error:  # noqa: BLE001
        raise ConclusionRefused(
            f"the result records are unreadable ({error})") from None
    identity_field = ID_FIELDS[RESULT_KIND]
    found = [record.get(identity_field) for record in records
             if isinstance(record, dict)
             and record.get("invocation_record_id") == cinv]
    if any(value is None for value in found):
        raise ConclusionRefused(
            f"a result record bound to {cinv} carries no {identity_field}")
    if len(found) > 1:
        raise ConclusionRefused(
            f"{cinv} has more than one terminal result: {sorted(found)}")
    return found[0] if found else None


def _read_member(name: str, dir_fd: int) -> bytes:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                 dir_fd=dir_fd)
    try:
        return os.read(fd, _MAXIMUM_DETAIL_BYTES + 1)[:_MAXIMUM_DETAIL_BYTES]
    finally:
        os.close(fd)


def existing_conclusion(root: RootDescriptor, cinv: str) -> dict[str, Any] | None:
    """The durable conclusion detail for ``cinv``, or nothing.

    Scanned from the administrative records rather than kept in an index: an
    index would be a second thing that could disagree with the evidence.
    """
    state_module.validate_cinv(cinv)
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
                    body = _read_member(CONCLUSION, record_fd)
                except FileNotFoundError:
                    continue
            finally:
                os.close(record_fd)
            try:
                document = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                raise ConclusionRefused(
                    f"the conclusion record in {name} is unreadable") from None
            if isinstance(document, dict) and document.get("cinv") == cinv:
                return document
    finally:
        os.close(handle)
    return None


def _write_detail(root: RootDescriptor, cadm: str, document: dict) -> None:
    handle = admin_module._record_directory(root, cadm)
    try:
        admin_module._write_durable(CONCLUSION,
                                    canonical_json.serialise(document), handle)
    except FileExistsError:
        raise ConclusionRefused(
            f"{cadm} already records a conclusion") from None
    finally:
        os.close(handle)


def _conflict(existing: dict[str, Any], proposed: dict[str, Any]) -> str | None:
    """Which recorded field a repeat disagrees on, or nothing.

    Compared field by field rather than by whole-document equality so the
    refusal can say *what* differs. A second authority for the same closure is a
    decision nobody made, and an operator seeing this needs to know which part
    of it is new.
    """
    for field in ("actor", "request_id", "recorded_at", "result_record_id",
                  "previous_state", "derivation"):
        if existing.get(field) != proposed.get(field):
            return field
    return None


def conclude(*, store: Any, execution_root: Any, cinv: Any, actor: Any,
             request_id: Any, recorded_at: Any,
             derivation: Any = DERIVATION_RECONSTRUCTED) -> Conclusion:
    """Close one executed invocation, or refuse.

    One transition, ``launch_authorized -> concluded``, taken under the capacity
    lock and then the `CINV` lock in that order -- the order ``reserve`` takes,
    because two actors deciding occupancy from the same read is what the order
    exists to prevent. The slot is released by that transition: occupancy is
    counted from committed lifecycle records, so there is no second step to
    forget, to repeat, or to race.

    Idempotent where it is safe to be: repeating the identical accepted
    conclusion reports ``resumed`` and writes nothing. A request differing in
    any recorded field is refused, because a second authority for the same
    closure is a decision nobody made.
    """
    if not isinstance(execution_root, RootDescriptor):
        raise ConclusionRefused(
            "execution_root must be a verified RootDescriptor")
    identity = state_module.validate_cinv(cinv)
    actor_text = _text(actor, "actor")
    request_text = _text(request_id, "request_id")
    recorded_text = _instant(recorded_at)
    derivation_text = _text(derivation, "derivation")
    if derivation_text not in DERIVATIONS:
        raise ConclusionRefused(
            f"{derivation_text!r} is not a recorded derivation")

    # The invocation must exist. Read, never reconstructed.
    try:
        store.read_record(INVOCATION_KIND, identity)
    except CapabilityError as error:
        raise ConclusionRefused(
            f"{identity} is not a readable invocation: {error}") from None

    # THE RESULT IS THE AUTHORITY FOR THIS WHOLE OPERATION.
    #
    # `concluded` asserts the execution ran and concluded, and the only thing
    # licensing that is a terminal result from the supervised path. An
    # invocation without one cannot be concluded -- and must not be. It is
    # exactly what the recovery enumeration and the readiness gate are built to
    # find, and closing it here would take it out of the one surface that could
    # still resolve it.
    result_record_id = _terminal_result(store, identity)
    if result_record_id is None:
        raise ConclusionRefused(
            f"{identity} has no terminal result; conclusion closes an "
            f"execution that happened, and recovery answers one that did not")

    locks = state_module._LockOrder()
    locks.acquire_capacity(execution_root)
    try:
        locks.acquire_cinv(identity, execution_root)

        current = state_module.current_state(execution_root, identity)
        if current is None:
            raise ConclusionRefused(f"{identity} has no execution state")

        existing = existing_conclusion(execution_root, identity)

        if current is LifecycleState.CONCLUDED:
            # Already closed. Resume only if this is the same decision.
            if existing is None:
                raise ConclusionRefused(
                    f"{identity} is concluded with no conclusion record; the "
                    f"lifecycle and the evidence disagree")
            proposed = {"actor": actor_text, "request_id": request_text,
                        "recorded_at": recorded_text,
                        "result_record_id": result_record_id,
                        "previous_state": existing.get("previous_state"),
                        "derivation": derivation_text}
            differing = _conflict(existing, proposed)
            if differing is not None:
                raise ConclusionRefused(
                    f"{identity} is already concluded and this request differs "
                    f"in {differing}")
            return Conclusion(
                cinv=identity, cadm=existing.get("cadm"),
                previous_state=str(existing.get("previous_state")),
                state=LifecycleState.CONCLUDED.value,
                result_record_id=str(result_record_id),
                derivation=str(existing.get("derivation")),
                handoff_retained=bool(existing.get("handoff_retained")),
                slot_released=False, resumed=True)

        # A conclusion record present while the lifecycle says otherwise is a
        # disagreement, not a resume: the evidence claims a closure the journal
        # does not carry.
        if existing is not None:
            raise ConclusionRefused(
                f"{identity} carries a conclusion record while it is "
                f"{current.value}; the lifecycle and the evidence disagree")

        if current is not STARTABLE_STATE:
            raise ConclusionRefused(
                f"{identity} is {current.value}, and a conclusion closes an "
                f"invocation at {STARTABLE_STATE.value}")

        previous_state = current.value

        # Intent, one attempt, outcome -- in that order, each durable and
        # create-once, which is the convention the administrative namespace
        # already holds every mutating verb to.
        cadm = admin_module.allocate_cadm(execution_root)
        admin_module.record_intent(execution_root, cadm,
                                   admin_module.Verb.CONCLUDE, identity, None)

        _write_detail(execution_root, cadm, {
            "actor": actor_text,
            "cadm": cadm,
            "cinv": identity,
            "conclusion_schema_version": CONCLUSION_SCHEMA_VERSION,
            "derivation": derivation_text,
            # Stated rather than implied. §13 gave the output leaf to the
            # execution identity and nothing released can remove it, so the
            # subtree is still on disk and a later reader is told so.
            "handoff_retained": True,
            "previous_state": previous_state,
            "recorded_at": recorded_text,
            "request_id": request_text,
            "result_record_id": result_record_id,
            "slot_released": True,
            "state": LifecycleState.CONCLUDED.value,
        })

        # The slot is released BY this transition: occupancy is counted from
        # committed lifecycle records, so there is no second step to forget.
        state_module.transition_locked(execution_root, identity, current,
                                       LifecycleState.CONCLUDED)

        admin_module.record_outcome(execution_root, cadm,
                                    admin_module.RESULT_DONE)

        return Conclusion(
            cinv=identity, cadm=cadm, previous_state=previous_state,
            state=LifecycleState.CONCLUDED.value,
            result_record_id=str(result_record_id),
            derivation=derivation_text, handoff_retained=True,
            slot_released=True, resumed=False)
    finally:
        locks.release_all()
