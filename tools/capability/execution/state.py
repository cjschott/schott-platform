"""Execution lifecycle state for the ENG-0005 first adapter.

**State is append-only, and that follows from the substrate.**
``Mutation.install`` is create-once by design, so a single mutable file per
`CINV` is impossible. Each transition is therefore its own immutable record and
the current state is the last record of a validated contiguous chain — which is
also how the rest of the runtime stores anything that matters.

**The chain is validated, never summarised.** Reading a state means reading
every record for that `CINV`, checking the sequence is contiguous from one, and
checking each record's declared predecessor is the state the previous record
left behind. A gap, a contradiction, or an unexpected object is a refusal.
Picking the newest record and moving on would turn a corrupted history into a
confident answer.

**The relation is closed and linear.** Transitions are enumerated from the
specification rather than inferred from enum order, so "any state may advance
to any later member" is never true by accident.

**Nothing here writes.** Every authority-bearing mutation goes through the T5
CMUT substrate; this module composes canonical bytes and hands them over.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §16.
"""

from __future__ import annotations

import fcntl
import hashlib
import os
from typing import Any

from . import canonical_json
from .backing_store import RootDescriptor
from .mutation import Mutation, MutationTarget, TargetKind
from .types import LifecycleState

TRANSITIONS_DIRECTORY = "transitions"
LOCKS_DIRECTORY = "locks"
CAPACITY_LOCK = "capacity"
QUARANTINE_LOCK = "quarantine-capacity"
STATE_SCHEMA_VERSION = 1

_LOCK_FLAGS = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC

_MAXIMUM_RECORD_BYTES = 64 * 1024
_MAXIMUM_SEQUENCE = 999_999
_DIGITS = frozenset("0123456789")

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# The transition relation, enumerated from the specification's §16 lifecycle.
# Written out rather than derived from enum order so that adding a state to the
# vocabulary does not silently create new legal transitions.
_ALLOWED: dict[LifecycleState, frozenset[LifecycleState]] = {
    LifecycleState.RESERVED: frozenset({LifecycleState.LAUNCH_AUTHORIZED}),
    LifecycleState.LAUNCH_AUTHORIZED: frozenset({LifecycleState.CREATED}),
    LifecycleState.CREATED: frozenset({LifecycleState.CONTAINER_VERIFIED}),
    LifecycleState.CONTAINER_VERIFIED: frozenset({LifecycleState.START_AUTHORIZED}),
    LifecycleState.START_AUTHORIZED: frozenset({LifecycleState.STARTED}),
    LifecycleState.STARTED: frozenset({LifecycleState.RUNNING}),
    LifecycleState.RUNNING: frozenset({LifecycleState.TERMINAL}),
    LifecycleState.TERMINAL: frozenset({LifecycleState.CLASSIFIED}),
    LifecycleState.CLASSIFIED: frozenset({LifecycleState.COLLECTED}),
    LifecycleState.COLLECTED: frozenset({LifecycleState.CLEANED}),
    LifecycleState.CLEANED: frozenset({LifecycleState.RELEASED}),
    LifecycleState.RELEASED: frozenset(),
}


class ExecutionStateError(ValueError):
    """Base for every refusal this module makes."""


class InvalidCinv(ExecutionStateError):
    """Not a canonical `CINV` identity."""


class InvalidTransition(ExecutionStateError):
    """The requested transition is not in the closed relation."""


class StateIntegrityFailure(ExecutionStateError):
    """The recorded history cannot be read as written."""


class AlreadyConsumed(ExecutionStateError):
    """This `CINV` already has durable state and cannot be reserved again."""


class LockOrderViolation(ExecutionStateError):
    """A capacity lock was requested while a `CINV` lock was held."""


class _LockOrder:
    """Advisory locks, held in the one permitted order.

    Lives here rather than beside capacity because the per-`CINV` lock protects
    a state transition, and a transition must be able to take it without
    depending on the capacity layer. The order rule still spans both, so it is
    enforced here where both kinds are acquired.

    The locks coordinate live actors and carry no durable authority: their files
    may be created by anyone, may contain anything, and may be left behind by a
    crash without meaning a thing. Only the kernel lock serialises.
    """

    # What this *process* holds, across every instance. `flock` serialises
    # actors, and an instance only knows its own history, so an order taken by
    # two instances in one process would satisfy both and still be an
    # inversion. The order rule is about the process, so the record is too.
    _process_held: set[str] = set()

    def __init__(self) -> None:
        self._held: list[tuple[str, int]] = []

    @property
    def holds_cinv(self) -> bool:
        return any(name not in (CAPACITY_LOCK, QUARANTINE_LOCK)
                   for name in _LockOrder._process_held)

    def _acquire(self, root: RootDescriptor, name: str) -> None:
        base = os.open(LOCKS_DIRECTORY, _DIR_FLAGS, dir_fd=root.fd)
        try:
            handle = os.open(name, _LOCK_FLAGS, 0o600, dir_fd=base)
        finally:
            os.close(base)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
        except BaseException:
            os.close(handle)
            raise
        self._take(name, handle)

    def _take(self, name: str, handle: int) -> None:
        self._held.append((name, handle))
        _LockOrder._process_held.add(name)

    def acquire_capacity(self, root: RootDescriptor | None = None) -> None:
        if self.holds_cinv:
            raise LockOrderViolation(
                "the capacity lock must be taken before any CINV lock")
        if QUARANTINE_LOCK in _LockOrder._process_held:
            raise LockOrderViolation(
                "the quarantine lock may not be held while taking another lock")
        if root is not None:
            self._acquire(root, CAPACITY_LOCK)
        else:
            self._take(CAPACITY_LOCK, -1)

    def acquire_quarantine(self, root: RootDescriptor | None = None) -> None:
        """Take the quarantine-capacity lock, and only on its own.

        §23 lists this lock but fixes an order only for global capacity before
        per-`CINV`. Rather than invent a position for a third kind, this
        refuses to nest with either: quarantine admission is a decision about
        the filesystem, taken by a caller holding nothing else. An increment
        that genuinely needs the nesting has found a specification question,
        and should get an answer rather than an ordering chosen here.
        """
        if _LockOrder._process_held:
            raise LockOrderViolation(
                "the quarantine lock may not be taken while another lock is held")
        if root is not None:
            self._acquire(root, QUARANTINE_LOCK)
        else:
            self._take(QUARANTINE_LOCK, -1)

    def acquire_cinv(self, cinv: str, root: RootDescriptor | None = None) -> None:
        if QUARANTINE_LOCK in _LockOrder._process_held:
            raise LockOrderViolation(
                "the quarantine lock may not be held while taking another lock")
        if root is not None:
            self._acquire(root, cinv)
        else:
            self._take(cinv, -1)

    def release_all(self) -> None:
        while self._held:
            name, handle = self._held.pop()
            _LockOrder._process_held.discard(name)
            if handle >= 0:
                try:
                    fcntl.flock(handle, fcntl.LOCK_UN)
                finally:
                    os.close(handle)


def validate_cinv(cinv: Any) -> str:
    """The identity, or refuse.

    This is the only value that becomes a filesystem component, so it is
    checked totally rather than sanitised. The caller-supplied opaque
    ``invocation_id`` never reaches here.
    """
    if not isinstance(cinv, str) or len(cinv) != 11 \
            or not cinv.startswith("CINV-") or set(cinv[5:]) - _DIGITS:
        raise InvalidCinv(f"{cinv!r} is not a CINV identity")
    return cinv


def _require_root(root: Any) -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise ExecutionStateError("root must be a verified RootDescriptor")
    return root


def _read_record(name: str, dir_fd: int) -> bytes:
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise StateIntegrityFailure(f"{name} is not a regular file")
        chunks: list[bytes] = []
        remaining = _MAXIMUM_RECORD_BYTES + 1
        while remaining > 0:
            chunk = os.read(handle, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(handle)
    body = b"".join(chunks)
    if len(body) > _MAXIMUM_RECORD_BYTES:
        raise StateIntegrityFailure(f"{name} exceeds {_MAXIMUM_RECORD_BYTES} bytes")
    return body


def _split(name: str) -> tuple[str, int] | None:
    if len(name) != 18 or name[11] != ".":
        return None
    cinv, sequence = name[:11], name[12:]
    if not cinv.startswith("CINV-") or set(cinv[5:]) - _DIGITS:
        return None
    if len(sequence) != 6 or set(sequence) - _DIGITS:
        return None
    return cinv, int(sequence)


def _scan(root: RootDescriptor) -> dict[str, dict[int, bytes]]:
    """Every transition record, grouped by `CINV`.

    An unexpected object anywhere in the namespace fails the whole read: this
    directory is closed, so something that does not belong in it means the
    history is not the history anyone intended.
    """
    grouped: dict[str, dict[int, bytes]] = {}
    base = os.open(TRANSITIONS_DIRECTORY, _DIR_FLAGS, dir_fd=root.fd)
    try:
        with os.scandir(base) as entries:
            for entry in entries:
                if entry.is_symlink():
                    raise StateIntegrityFailure(f"{entry.name} is a symlink")
                if not entry.is_file(follow_symlinks=False):
                    raise StateIntegrityFailure(f"{entry.name} is not a regular file")
                parsed = _split(entry.name)
                if parsed is None:
                    raise StateIntegrityFailure(
                        f"{entry.name} is not a transition record")
                cinv, sequence = parsed
                if sequence in grouped.setdefault(cinv, {}):
                    raise StateIntegrityFailure(f"{entry.name} is duplicated")
                grouped[cinv][sequence] = _read_record(entry.name, base)
    finally:
        os.close(base)
    return grouped


def _decode(body: bytes, cinv: str, sequence: int) -> dict[str, Any]:
    try:
        document = canonical_json.parse(body, maximum_bytes=_MAXIMUM_RECORD_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise StateIntegrityFailure(
            f"{cinv}.{sequence:06d} is not canonical: {error}") from None
    expected = {"cinv", "schema_version", "sequence", "previous", "state"}
    if set(document) != expected:
        raise StateIntegrityFailure(
            f"{cinv}.{sequence:06d} has the wrong field set")
    if document["cinv"] != cinv or document["sequence"] != sequence:
        raise StateIntegrityFailure(
            f"{cinv}.{sequence:06d} declares a different identity")
    if document["schema_version"] != STATE_SCHEMA_VERSION:
        raise StateIntegrityFailure(
            f"{cinv}.{sequence:06d} has an unsupported schema version")
    return document


def _resolve(records: dict[int, bytes], cinv: str) -> tuple[LifecycleState, int]:
    """Walk the chain from sequence one, or refuse."""
    previous: LifecycleState | None = None
    for sequence in range(1, len(records) + 1):
        if sequence not in records:
            raise StateIntegrityFailure(
                f"{cinv} transition chain has a gap at {sequence}")
        document = _decode(records[sequence], cinv, sequence)
        declared = document["previous"]
        if previous is None:
            if declared is not None:
                raise StateIntegrityFailure(
                    f"{cinv} first record declares a predecessor")
        else:
            if declared != previous.value:
                raise StateIntegrityFailure(
                    f"{cinv}.{sequence:06d} declares predecessor {declared!r}, "
                    f"but the chain left {previous.value!r}")
        try:
            state = LifecycleState(document["state"])
        except ValueError:
            raise StateIntegrityFailure(
                f"{cinv}.{sequence:06d} names an unknown state") from None
        if previous is not None and state not in _ALLOWED[previous]:
            raise StateIntegrityFailure(
                f"{cinv} records an illegal transition {previous.value} -> {state.value}")
        previous = state
    if previous is None:
        raise StateIntegrityFailure(f"{cinv} has no records")
    return previous, len(records)


def current_state(root: RootDescriptor, cinv: str) -> LifecycleState | None:
    """The validated current state, or ``None`` if this `CINV` has none."""
    _require_root(root)
    validate_cinv(cinv)
    records = _scan(root).get(cinv)
    if not records:
        return None
    state, _ = _resolve(records, cinv)
    return state


def all_states(root: RootDescriptor) -> dict[str, LifecycleState]:
    """Every known `CINV` and its validated current state."""
    _require_root(root)
    return {cinv: _resolve(records, cinv)[0]
            for cinv, records in _scan(root).items()}


def _commit(root: RootDescriptor, cinv: str, previous: LifecycleState | None,
            state: LifecycleState, sequence: int) -> None:
    if sequence > _MAXIMUM_SEQUENCE:
        raise StateIntegrityFailure(f"{cinv} exceeded its transition budget")
    body = canonical_json.serialise({
        "cinv": cinv,
        "schema_version": STATE_SCHEMA_VERSION,
        "sequence": sequence,
        "previous": None if previous is None else previous.value,
        "state": state.value,
    })
    target = MutationTarget(kind=TargetKind.EXECUTION_TRANSITION,
                            name=f"{cinv}.{sequence:06d}")
    mutation = Mutation(root)
    cmut = mutation.begin(target, schema_type="execution-transition",
                          expected_sha256=hashlib.sha256(body).hexdigest())
    mutation.install(cmut, body)
    mutation.commit(cmut)


def open_state_locked(root: RootDescriptor, cinv: str) -> None:
    """Commit the first record for ``cinv``. The caller holds its `CINV` lock.

    Separate from ``transition`` because opening a history has no predecessor
    to validate, and folding the two together would mean the transition path
    had to tolerate a missing chain — which is exactly the tolerance that lets
    a corrupted history look like a new one.
    """
    _require_root(root)
    validate_cinv(cinv)
    if _scan(root).get(cinv):
        raise AlreadyConsumed(f"{cinv} already has durable execution state")
    _commit(root, cinv, None, LifecycleState.RESERVED, 1)


def transition_locked(root: RootDescriptor, cinv: str, frm: LifecycleState,
                      to: LifecycleState) -> None:
    """``transition`` without acquiring the `CINV` lock.

    For callers that already hold it. Split out because ``flock`` is not
    reentrant across separate opens: a release path that holds the lock and
    then called the locking variant would deadlock against itself.
    """
    _require_root(root)
    validate_cinv(cinv)
    if not isinstance(frm, LifecycleState) or not isinstance(to, LifecycleState):
        raise InvalidTransition("states must be LifecycleState members")

    records = _scan(root).get(cinv)
    if not records:
        raise InvalidTransition(f"{cinv} has no execution state")
    state, count = _resolve(records, cinv)
    if state is not frm:
        raise InvalidTransition(
            f"{cinv} is {state.value}, not {frm.value}")
    if to not in _ALLOWED[frm]:
        raise InvalidTransition(
            f"{frm.value} -> {to.value} is not a permitted transition")
    _commit(root, cinv, frm, to, count + 1)


def transition(root: RootDescriptor, cinv: str, frm: LifecycleState,
               to: LifecycleState) -> None:
    """Advance ``cinv`` from ``frm`` to ``to``, or refuse.

    The `CINV` lock spans the whole decision — read, validate, decide, commit —
    so two actors cannot both read the same valid predecessor and both act on
    it. ``frm`` is checked against the recorded state rather than assumed: a
    caller with the wrong predecessor has raced someone, and saying so is more
    useful than quietly applying the transition to whatever is there now.
    """
    _require_root(root)
    validate_cinv(cinv)
    locks = _LockOrder()
    locks.acquire_cinv(cinv, root)
    try:
        transition_locked(root, cinv, frm, to)
    finally:
        locks.release_all()
