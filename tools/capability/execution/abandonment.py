"""Governed administrative abandonment for the ENG-0005 first adapter.

**The problem this exists for.** An invocation that reached
``launch_authorized`` and never went further holds an execution slot for ever.
The lifecycle reaches ``released`` only from ``cleaned``, ``recover`` writes
nothing, and no administrative verb repairs or forces. Two such invocations
hold both slots, and every later invocation is refused with
``CapacityExhausted`` before it mutates anything. G11-BC-U found this in
production.

**What was rejected.** Raising ``MAXIMUM_SLOTS`` would remove the control
rather than the defect. Editing lifecycle records by hand would forge the one
history the runtime trusts. Reinterpreting ``launch_authorized`` as
``released`` would make an unfinished execution indistinguishable from a
finished one. None of those is done here, and ``MAXIMUM_SLOTS`` is unchanged.

**What this is instead.** ``ABANDONED`` is a first-class exceptional closure:
the invocation was permanently administratively closed **without asserting that
the normal execution and cleanup lifecycle completed**. It is terminal, it
holds no execution slot, and it is not ``released``. The difference between the
two is the whole value of the state, so nothing here ever reports one as the
other.

**No execution evidence is invented.** Abandonment writes no result. An
invocation that never produced one still has none afterwards, because a
fabricated success or failure would answer a question nobody asked and would
close it against the recovery enumeration that could still have found it. Where
a terminal result already exists it is preserved untouched and referenced.

**The slot is released by the transition, not by a second step.** Capacity is
counted from committed lifecycle records, so an invocation that is ``abandoned``
stops holding a slot the moment that record is durable. There is no separate
release to forget, to repeat, or to race.

**Narrow by construction.** Only ``reserved`` and ``launch_authorized`` may be
abandoned, and they are the two states the coordinator wrote before handing
anything over. From ``created`` onwards a container provably exists on the far
side of the privilege drop; closing those administratively would strand it, and
container reconciliation is what the §20 verbs already have authority for.

Governed by ``docs/decisions/ADR-0015-governed-administrative-abandonment.md``.
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
from .backing_store import RootDescriptor, target_fingerprint
from .types import LifecycleState

# The two controlled reason categories, closed. A free-form reason would make
# the audit answerable only by reading prose, and the two production cases are
# genuinely different questions.
#
#   TERMINAL_RESULT_STRANDED       a terminal result exists and the lifecycle
#                                  never advanced, so capacity stayed held for
#                                  an invocation that was already answered.
#   HISTORICAL_INCOMPLETE_EXECUTION  no terminal result exists and the historical
#                                  invocation cannot safely resume.
REASON_TERMINAL_RESULT_STRANDED = "terminal-result-lifecycle-stranded"
REASON_HISTORICAL_INCOMPLETE_EXECUTION = "historical-incomplete-execution"

REASONS = frozenset({REASON_TERMINAL_RESULT_STRANDED,
                     REASON_HISTORICAL_INCOMPLETE_EXECUTION})

# Whether each reason asserts that a terminal result exists. Checked against
# what the store actually holds, so a category cannot be used to describe a
# situation that is not the one in front of the operator.
_REASON_REQUIRES_RESULT = {
    REASON_TERMINAL_RESULT_STRANDED: True,
    REASON_HISTORICAL_INCOMPLETE_EXECUTION: False,
}

ELIGIBLE_SOURCE_STATES = frozenset({
    LifecycleState.RESERVED,
    LifecycleState.LAUNCH_AUTHORIZED,
})

ABANDONMENT = "abandonment"
ABANDONMENT_SCHEMA_VERSION = 1
_MAXIMUM_DETAIL_BYTES = 64 * 1024

__all__ = ["AbandonmentError", "AbandonmentRefused", "Abandonment",
           "REASON_TERMINAL_RESULT_STRANDED",
           "REASON_HISTORICAL_INCOMPLETE_EXECUTION", "REASONS",
           "ELIGIBLE_SOURCE_STATES", "ABANDONMENT", "abandon",
           "existing_abandonment"]


class AbandonmentError(ValueError):
    """Base for every refusal this module makes."""


class AbandonmentRefused(AbandonmentError):
    """The abandonment was not permitted."""


@dataclasses.dataclass(frozen=True)
class Abandonment:
    """What one accepted abandonment concluded."""

    cinv: str
    cadm: str
    previous_state: str
    state: str
    actor: str
    request_id: str
    recorded_at: str
    reason: str
    result_record_id: str | None
    slot_released: bool
    resumed: bool
    # G11-BC-Y. Which object this was actually written through, asked of the
    # kernel rather than inferred from the path a caller typed. A rehearsal
    # that proves its gates against one store while the mutator resolves
    # another is the incident this field exists to make impossible to miss.
    target: dict[str, int]


def _text(value: Any, what: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AbandonmentRefused(f"{what} must be a non-empty string")
    return value


def _instant(value: Any) -> str:
    raw = _text(value, "recorded_at")
    try:
        parsed = datetime.fromisoformat(raw)
    except (TypeError, ValueError) as error:
        raise AbandonmentRefused(
            f"recorded_at is not an ISO-8601 instant ({error})") from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise AbandonmentRefused(
            "recorded_at carries no timezone offset; refusing to guess one")
    return raw


def _terminal_result(store: Any, cinv: str) -> str | None:
    """The identity of this invocation's terminal result, or nothing.

    Read from the store rather than accepted from the caller: which result
    belongs to which invocation is not a caller's claim to make.
    """
    try:
        records = list(store.list_records(RESULT_KIND))
    except Exception as error:  # noqa: BLE001
        raise AbandonmentRefused(
            f"the result records are unreadable ({error})") from None
    # The identity field is read from the released map rather than named here.
    # There is no universal `id`: a result carries `capability_result_id`, and
    # a plausible-looking guess at that name is a bug this module would report
    # as "the invocation has no terminal result" -- which is the dangerous
    # direction, because it is also what an invocation with genuinely no result
    # looks like.
    identity_field = ID_FIELDS[RESULT_KIND]
    found = [record.get(identity_field) for record in records
             if isinstance(record, dict)
             and record.get("invocation_record_id") == cinv]
    if any(value is None for value in found):
        raise AbandonmentRefused(
            f"a result record bound to {cinv} carries no {identity_field}")
    if len(found) > 1:
        raise AbandonmentRefused(
            f"{cinv} has more than one terminal result: {sorted(found)}")
    return found[0] if found else None


def existing_abandonment(root: RootDescriptor, cinv: str) -> dict[str, Any] | None:
    """The durable abandonment detail for ``cinv``, or nothing.

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
        names = sorted(os.listdir(handle))
        for name in names:
            try:
                record_fd = os.open(name,
                                    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
                                    | os.O_DIRECTORY, dir_fd=handle)
            except (FileNotFoundError, NotADirectoryError, OSError):
                continue
            try:
                try:
                    body = _read_member(ABANDONMENT, record_fd)
                except FileNotFoundError:
                    continue
            finally:
                os.close(record_fd)
            try:
                document = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                raise AbandonmentRefused(
                    f"the abandonment record in {name} is unreadable") from None
            if isinstance(document, dict) and document.get("cinv") == cinv:
                return document
    finally:
        os.close(handle)
    return None


def _read_member(name: str, dir_fd: int) -> bytes:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                 dir_fd=dir_fd)
    try:
        return os.read(fd, _MAXIMUM_DETAIL_BYTES + 1)[:_MAXIMUM_DETAIL_BYTES]
    finally:
        os.close(fd)


def _write_detail(root: RootDescriptor, cadm: str, document: dict) -> None:
    handle = admin_module._record_directory(root, cadm)
    try:
        admin_module._write_durable(ABANDONMENT,
                                    canonical_json.serialise(document), handle)
    except FileExistsError:
        raise AbandonmentRefused(
            f"{cadm} already records an abandonment") from None
    finally:
        os.close(handle)


def abandon(*, store: Any, execution_root: Any, cinv: Any, actor: Any,
            request_id: Any, recorded_at: Any, reason: Any) -> Abandonment:
    """Permanently close one stuck invocation, or refuse.

    The whole decision happens under the capacity lock and then the `CINV`
    lock, in that order -- the same order ``capacity.reserve`` takes, because
    two actors deciding occupancy from the same read is exactly what the lock
    order exists to prevent.

    Idempotent where it is safe to be: repeating the identical accepted
    abandonment reports ``resumed`` and writes nothing. A request that differs
    in any recorded field refuses, because a second authority for the same
    closure is a decision nobody made.
    """
    if not isinstance(execution_root, RootDescriptor):
        raise AbandonmentRefused("execution_root must be a verified RootDescriptor")
    identity = state_module.validate_cinv(cinv)
    actor_text = _text(actor, "actor")
    request_text = _text(request_id, "request_id")
    recorded_text = _instant(recorded_at)
    reason_text = _text(reason, "reason")
    if reason_text not in REASONS:
        raise AbandonmentRefused(
            f"{reason_text!r} is not a controlled abandonment reason")

    # The invocation must exist. Read, never reconstructed.
    try:
        record = store.read_record(INVOCATION_KIND, identity)
    except CapabilityError as error:
        raise AbandonmentRefused(
            f"{identity} is not a readable invocation: {error}") from None
    if not isinstance(record, dict):
        raise AbandonmentRefused(f"{identity} did not read back as a record")

    result_record_id = _terminal_result(store, identity)
    if _REASON_REQUIRES_RESULT[reason_text] and result_record_id is None:
        raise AbandonmentRefused(
            f"{reason_text} asserts a terminal result and {identity} has none")
    if not _REASON_REQUIRES_RESULT[reason_text] and result_record_id is not None:
        raise AbandonmentRefused(
            f"{reason_text} asserts no terminal result and {identity} has "
            f"{result_record_id}")

    target = target_fingerprint(execution_root)

    locks = state_module._LockOrder()
    locks.acquire_capacity(execution_root)
    try:
        locks.acquire_cinv(identity, execution_root)

        current = state_module.current_state(execution_root, identity)
        if current is None:
            raise AbandonmentRefused(
                f"{identity} has no durable execution state to close")

        prior = existing_abandonment(execution_root, identity)

        if current is LifecycleState.ABANDONED:
            # Already closed. The only accepted repeat is the identical one.
            if prior is None:
                raise AbandonmentRefused(
                    f"{identity} is abandoned with no administrative record")
            for key, value in (("actor", actor_text),
                               ("request_id", request_text),
                               ("recorded_at", recorded_text),
                               ("reason", reason_text),
                               ("result_record_id", result_record_id)):
                if prior.get(key) != value:
                    raise AbandonmentRefused(
                        f"{identity} is already abandoned under different "
                        f"authority ({key} {prior.get(key)!r}, not {value!r})")
            return Abandonment(
                cinv=identity, cadm=prior["cadm"],
                previous_state=prior["previous_state"], state=prior["state"],
                actor=actor_text, request_id=request_text,
                recorded_at=recorded_text, reason=reason_text,
                result_record_id=result_record_id, slot_released=False,
                resumed=True, target=target)

        if prior is not None:
            raise AbandonmentRefused(
                f"{identity} carries an abandonment record but is "
                f"{current.value}; the lifecycle and the evidence disagree")

        if current not in ELIGIBLE_SOURCE_STATES:
            raise AbandonmentRefused(
                f"{identity} is {current.value} and is not administratively "
                "abandonable; only reserved and launch_authorized are")

        # Intent, one attempt, outcome -- in that order, each durable and
        # create-once, which is the convention the administrative namespace
        # already holds every mutating verb to.
        cadm = admin_module.allocate_cadm(execution_root)
        admin_module.record_intent(execution_root, cadm,
                                   admin_module.Verb.ABANDON, identity, None)

        detail = {
            "abandonment_schema_version": ABANDONMENT_SCHEMA_VERSION,
            "actor": actor_text,
            "cadm": cadm,
            "causal_references": sorted(
                {identity} | ({result_record_id} if result_record_id else set())),
            "cinv": identity,
            "previous_state": current.value,
            "reason": reason_text,
            "recorded_at": recorded_text,
            "request_id": request_text,
            "result_record_id": result_record_id,
            "slot_released": True,
            "state": LifecycleState.ABANDONED.value,
        }
        _write_detail(execution_root, cadm, detail)

        # The slot is released BY this transition: occupancy is counted from
        # committed lifecycle records, so there is no second step to forget.
        state_module.transition_locked(execution_root, identity, current,
                                       LifecycleState.ABANDONED)

        admin_module.record_outcome(execution_root, cadm,
                                    admin_module.RESULT_DONE)

        return Abandonment(
            cinv=identity, cadm=cadm, previous_state=current.value,
            state=LifecycleState.ABANDONED.value, actor=actor_text,
            request_id=request_text, recorded_at=recorded_text,
            reason=reason_text, result_record_id=result_record_id,
            slot_released=True, resumed=False, target=target)
    finally:
        locks.release_all()
