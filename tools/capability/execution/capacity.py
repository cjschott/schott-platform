"""Global execution capacity for the ENG-0005 first adapter.

**Two slots, no queue.** A third request is refused rather than parked. A queue
would need an owner, an ordering, an expiry, and a story about what happens
when the queued work is no longer wanted — none of which this runtime has, and
inventing them quietly is worse than saying no.

**Capacity is counted, never inferred.** The count comes from committed
lifecycle records and nothing else: not process counts, not container counts,
not file ages, not timestamps, and not the existence of a lock file. Every one
of those can be true while the durable authority says otherwise, and the
durable authority is the one that survives a crash.

**A slot is consumed when `reserved` is durable, and freed when `released`
is.** Not when a caller asks, not when a process disappears, and not when
something looks old. There is no lease and no expiry, which is why
``SlotReservation`` carries no timestamp — a slot that could be reclaimed by
the clock would be a slot two executions could hold.

**Lock order is global capacity, then per-`CINV`, and inversion raises.**
The capacity lock is the serialisation boundary for the whole count; the `CINV`
lock spans read, validate, decide, and commit, so two actors cannot read the
same valid state and both act on it.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §23.
"""

from __future__ import annotations

from typing import Any

from . import state as state_module
from .backing_store import RootDescriptor
from .state import (  # re-exported: the order rule spans both lock kinds
    CAPACITY_LOCK, LOCKS_DIRECTORY, LockOrderViolation, _LockOrder)
from .types import Classification, LifecycleState, SlotReservation

MAXIMUM_SLOTS = 2

# Every state except RELEASED holds its slot. Quarantine and reconciliation
# conditions live inside this range deliberately: a slot stays held until the
# invocation is finished with, which is what makes two stuck quarantines able
# to halt new execution rather than silently oversubscribing the host.
CAPACITY_CONSUMING_STATES = tuple(
    s for s in LifecycleState if s is not LifecycleState.RELEASED)

__all__ = ["MAXIMUM_SLOTS", "CAPACITY_CONSUMING_STATES", "LOCKS_DIRECTORY",
           "CAPACITY_LOCK", "LockOrderViolation", "CapacityError",
           "CapacityExhausted", "reserve", "release"]


class CapacityError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class CapacityExhausted(CapacityError):
    """Both slots are held by capacity-consuming executions."""

    classification = Classification.EXECUTION_CAPACITY_EXHAUSTED


def _require_root(root: Any) -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise state_module.ExecutionStateError(
            "root must be a verified RootDescriptor")
    return root


def _consuming(root: RootDescriptor) -> dict[str, LifecycleState]:
    consuming = CAPACITY_CONSUMING_STATES
    return {cinv: value for cinv, value in state_module.all_states(root).items()
            if value in consuming}


def reserve(root: RootDescriptor, cinv: str) -> SlotReservation:
    """Take one slot for ``cinv``, or refuse.

    The whole decision — count, conflict check, and commit — happens under both
    locks, so a caller that is told yes has already had its ``reserved`` record
    made durable by the time the locks drop.
    """
    _require_root(root)
    state_module.validate_cinv(cinv)

    locks = _LockOrder()
    locks.acquire_capacity(root)
    try:
        locks.acquire_cinv(cinv, root)
        held = _consuming(root)
        if cinv in state_module.all_states(root):
            raise state_module.AlreadyConsumed(
                f"{cinv} already has durable execution state")
        if len(held) >= MAXIMUM_SLOTS:
            raise CapacityExhausted(
                f"all {MAXIMUM_SLOTS} execution slots are held")
        occupied = {index for index, _ in enumerate(sorted(held))}
        slot_index = next(i for i in range(MAXIMUM_SLOTS) if i not in occupied)
        state_module.open_state_locked(root, cinv)
        return SlotReservation(cinv=cinv, slot_index=slot_index)
    finally:
        locks.release_all()


def release(root: RootDescriptor, reservation: SlotReservation) -> None:
    """Free the slot held by ``reservation``, or refuse.

    Only a lifecycle that has reached ``cleaned`` may release. Nothing else
    frees a slot: not a vanished process, not a missing container, not an
    elapsed timeout, and not a caller simply asking.
    """
    _require_root(root)
    if not isinstance(reservation, SlotReservation):
        raise CapacityError("reservation must be a SlotReservation")
    cinv = state_module.validate_cinv(reservation.cinv)

    locks = _LockOrder()
    locks.acquire_capacity(root)
    try:
        locks.acquire_cinv(cinv, root)
        current = state_module.current_state(root, cinv)
        if current is None:
            raise state_module.InvalidTransition(
                f"{cinv} has no execution state to release")
        state_module.transition_locked(root, cinv, current,
                                       LifecycleState.RELEASED)
    finally:
        locks.release_all()
