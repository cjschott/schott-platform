"""The coordinator↔worker protocol for the ENG-0005 first adapter.

**Messages are data, and the schema is why.** The coordinator never executes,
evaluates, imports, or shells anything a worker sends — but that promise would
be worth little as a rule, so it is a structure instead. No message schema has
a field capable of carrying an executable, an argv list, a runtime flag, a
mount, a network mode, a device, an environment map, an image selector, or a
host path. There is nothing to misuse rather than a rule against misusing it.

**Every string field is either a fixed grammar or a closed vocabulary.** No
field accepts arbitrary text, so a path, a command, or a shell fragment has
nowhere to ride even as an unused value.

**Well-formed is not authorised.** A container ID that decodes cleanly is still
untrusted data. This module decides only whether a message is *legal here*;
whether to believe it belongs to the lifecycle logic that owns the durable
state, and that logic re-verifies everything against T8.

**Ordering is enumerated, never inferred.** The session's transitions are
written out rather than derived from declaration order, so a new kind cannot
silently become legal somewhere, and a message that is correct in one state is
refused in another.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §3.1.
"""

from __future__ import annotations

import dataclasses
import enum
from typing import Any, Iterable

from . import canonical_json
from .types import Classification, UnknownClassification

PROTOCOL_VERSION = 1
MAXIMUM_MESSAGE_BYTES = 64 * 1024

_DELIMITER = b"\n"
_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")
_MAXIMUM_DETAIL = 256


class ProtocolError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class ProtocolViolation(ProtocolError):
    """Any breach of the protocol contract.

    Deliberately one type. A malformed frame, an unknown kind, a bad identity,
    and an out-of-order message all mean the same thing to a caller — the
    conversation cannot be trusted — and the specification gives them one
    classification.
    """

    classification = Classification.EXECUTION_PROTOCOL_VIOLATION


@enum.unique
class MessageKind(enum.Enum):
    """The eight kinds §3.1 names, and no others."""

    # Worker to coordinator.
    CREATED = "created"
    VERIFIED_PROFILE = "verified_profile"
    STARTED = "started"
    TERMINAL = "terminal"
    COLLECTED = "collected"
    ERROR = "error"
    # Coordinator to worker.
    START_NOW = "start_now"
    ABORT = "abort"


@enum.unique
class SessionState(enum.Enum):
    """Where a conversation has got to."""

    START = "start"
    CREATED = "created"
    PROFILE_VERIFIED = "profile_verified"
    START_SENT = "start_sent"
    STARTED = "started"
    TERMINAL = "terminal"
    COLLECTED = "collected"
    ENDED = "ended"


def _is_cinv(value: Any) -> bool:
    return (isinstance(value, str) and len(value) == 11
            and value.startswith("CINV-") and set(value[5:]) <= _DIGITS)


def _is_cimp(value: Any) -> bool:
    return (isinstance(value, str) and len(value) == 11
            and value.startswith("CIMP-") and set(value[5:]) <= _DIGITS)


def _is_container_id(value: Any) -> bool:
    # Podman's full 64-character hex identity. The short form is a display
    # convenience and is never an identity here.
    return isinstance(value, str) and len(value) == 64 and set(value) <= _HEX


def _is_oci_image_id(value: Any) -> bool:
    """The immutable local image ID, bare lowercase hex and nothing else.

    A `sha256:` prefix is refused rather than tolerated: every value that
    carries one is a manifest digest or a repository reference, none of which
    identifies the local bytes Podman will run.
    """
    return isinstance(value, str) and len(value) == 64 and set(value) <= _HEX


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and set(value) <= _HEX


def _is_version(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_uid(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _is_bool(value: Any) -> bool:
    return isinstance(value, bool)


def _is_exit_code(value: Any) -> bool:
    return value is None or (isinstance(value, int)
                             and not isinstance(value, bool))


def _is_lifecycle_word(value: Any) -> bool:
    # A closed vocabulary of runtime lifecycle words, not free text.
    return value in ("created", "running", "exited", "stopped", "paused",
                     "unknown")


def _is_classification(value: Any) -> bool:
    """A detail must name a specified classification, never free-form prose."""
    if not isinstance(value, str):
        return False
    try:
        Classification.of(value)
    except UnknownClassification:
        return False
    return True


def _is_optional_sha256(value: Any) -> bool:
    return value is None or _is_sha256(value)


# The outcome classes a worker can reach, which is deliberately NARROWER than
# the released set. T13 maps every lifecycle disposition onto exactly these
# five; `refused`, `cancelled` and `serialisation-failure` are conclusions
# reached elsewhere and are not the worker's to claim, so there is no field
# value here that could carry one.
#
# Restated rather than imported because this module takes `canonical_json` and
# `types` on purpose -- a protocol that pulled in the lifecycle layer would make
# the wire format depend on it. The two copies are held together by test, the
# discipline `PROFILE_FD` already gets.
_OUTCOME_CLASSES = frozenset({
    "adapter-error", "completed", "interrupted", "provider-error", "timeout"})


def _is_outcome_class(value: Any) -> bool:
    """One outcome class a worker may report, from a closed vocabulary."""
    return value in _OUTCOME_CLASSES


def _is_timestamp(value: Any) -> bool:
    """RFC3339 as the runtime reports it, or nothing.

    A fixed grammar rather than free text, for the reason every other string
    field here has one: a field that accepts arbitrary text is somewhere a path
    or a command could ride even as an unused value. Absence is legal because a
    container that never started has no start time to report.

    Checked positionally rather than parsed. Turning this into a datetime would
    put a clock library in a module that must stay pure, and would answer a
    question nobody asked -- the coordinator carries the runtime's own words
    into the durable record, it does not reinterpret them.
    """
    if value is None:
        return True
    if not isinstance(value, str) or not 20 <= len(value) <= 35:
        return False
    if (value[4], value[7], value[10], value[13], value[16]) != (
            "-", "-", "T", ":", ":"):
        return False
    for start, stop in ((0, 4), (5, 7), (8, 10), (11, 13), (14, 16), (17, 19)):
        if not set(value[start:stop]) <= _DIGITS:
            return False
    tail = value[19:]
    if tail.startswith("."):
        fraction = tail[1:]
        digits = 0
        while digits < len(fraction) and fraction[digits] in _DIGITS:
            digits += 1
        if not 1 <= digits <= 9:
            return False
        tail = fraction[digits:]
    if tail == "Z":
        return True
    if len(tail) == 6 and tail[0] in "+-" and tail[3] == ":":
        return set(tail[1:3]) <= _DIGITS and set(tail[4:6]) <= _DIGITS
    return False


# Every field each kind carries, with its validator. The absence of anything
# command-shaped here is the guarantee, not a comment about it.
MESSAGE_SCHEMAS: dict[MessageKind, dict[str, Any]] = {
    MessageKind.CREATED: {"container_id": _is_container_id},
    MessageKind.VERIFIED_PROFILE: {
        "container_id": _is_container_id,
        "profile_digest": _is_sha256,
        "oci_image_id": _is_oci_image_id,
        "cimp": _is_cimp,
        "profile_schema_version": _is_version,
        "execution_uid": _is_uid,
        "execution_gid": _is_uid,
    },
    MessageKind.START_NOW: {"container_id": _is_container_id},
    MessageKind.STARTED: {"container_id": _is_container_id},
    MessageKind.TERMINAL: {
        "container_id": _is_container_id,
        "lifecycle_state": _is_lifecycle_word,
        "exit_code": _is_exit_code,
        "started_proven": _is_bool,
        # T13's conclusion, carried rather than re-derived. The coordinator has
        # no observation to classify and the mapping from lifecycle words to an
        # outcome class already exists once, in the module that owns it; a
        # supervisor that recomputed it from the two facts below would be a
        # second opinion that could not see `timed_out` at all.
        "outcome_class": _is_outcome_class,
        # The runtime's own words about when the workload ran, carried so the
        # durable result can state it. The coordinator never observes the
        # container, so if these did not travel the record could only say
        # "sometime". Absence is legal: a container that never started has no
        # start time.
        "started_at": _is_timestamp,
        "finished_at": _is_timestamp,
    },
    MessageKind.COLLECTED: {
        "result_digest": _is_optional_sha256,
        "output_manifest_digest": _is_optional_sha256,
        "stdout_truncated": _is_bool,
        "stderr_truncated": _is_bool,
    },
    MessageKind.ERROR: {"detail": _is_classification},
    MessageKind.ABORT: {"detail": _is_classification},
}

# The conversation, enumerated. Written out so a new kind cannot become legal
# somewhere by accident, and so no ordering is inferred from enum position.
_TRANSITIONS: dict[SessionState, dict[MessageKind, SessionState]] = {
    SessionState.START: {MessageKind.CREATED: SessionState.CREATED},
    SessionState.CREATED: {
        MessageKind.VERIFIED_PROFILE: SessionState.PROFILE_VERIFIED},
    SessionState.PROFILE_VERIFIED: {
        MessageKind.START_NOW: SessionState.START_SENT},
    SessionState.START_SENT: {MessageKind.STARTED: SessionState.STARTED},
    SessionState.STARTED: {MessageKind.TERMINAL: SessionState.TERMINAL},
    SessionState.TERMINAL: {MessageKind.COLLECTED: SessionState.COLLECTED},
    SessionState.COLLECTED: {},
    SessionState.ENDED: {},
}

# Either side may end the conversation at any point before it is finished.
# Nothing follows: there is no resumption, and no retry lives here.
_TERMINATING = (MessageKind.ERROR, MessageKind.ABORT)
_MAY_TERMINATE = (SessionState.START, SessionState.CREATED,
                  SessionState.PROFILE_VERIFIED, SessionState.START_SENT,
                  SessionState.STARTED, SessionState.TERMINAL)


@dataclasses.dataclass(frozen=True)
class Message:
    """One protocol message, immutable in every part.

    ``fields`` is a tuple of pairs rather than a mapping so the value cannot be
    edited after validation and cannot carry an unordered surprise into the
    canonical encoding.
    """

    kind: MessageKind
    cinv: str
    fields: tuple[tuple[str, Any], ...]

    def __post_init__(self) -> None:
        # One canonical in-memory form, so two messages carrying the same
        # values are equal however they were constructed. Without this,
        # identity would quietly depend on the order a caller happened to
        # write the fields in, and a decoded message would never equal the
        # one that produced it.
        object.__setattr__(self, "fields",
                           tuple(sorted(self.fields, key=lambda pair: pair[0])))

    def field_map(self) -> dict[str, Any]:
        """A fresh mapping for reading. Mutating it changes nothing."""
        return dict(self.fields)


def _validate(kind: MessageKind, cinv: str,
              values: dict[str, Any]) -> tuple[tuple[str, Any], ...]:
    if not _is_cinv(cinv):
        raise ProtocolViolation("cinv is not a canonical CINV identity")
    schema = MESSAGE_SCHEMAS[kind]
    for name in values:
        if name not in schema:
            raise ProtocolViolation(f"unknown field {name!r}")
    ordered: list[tuple[str, Any]] = []
    for name in sorted(schema):
        if name not in values:
            raise ProtocolViolation(f"missing field {name!r}")
        value = values[name]
        if not schema[name](value):
            raise ProtocolViolation(f"field {name!r} is not valid")
        ordered.append((name, value))
    return tuple(ordered)


def encode(message: Message) -> bytes:
    """One canonical, newline-terminated frame.

    Field order in the source cannot reach the bytes: the schema's own sorted
    field list is used, and canonical JSON sorts keys regardless.
    """
    if not isinstance(message, Message):
        raise ProtocolViolation("not a Message")
    if not isinstance(message.kind, MessageKind):
        raise ProtocolViolation("unknown message kind")
    fields = _validate(message.kind, message.cinv, dict(message.fields))
    body: dict[str, Any] = {
        "protocol_version": PROTOCOL_VERSION,
        "kind": message.kind.value,
        "cinv": message.cinv,
    }
    body.update(dict(fields))
    frame = canonical_json.serialise(body) + _DELIMITER
    if len(frame) > MAXIMUM_MESSAGE_BYTES:
        raise ProtocolViolation(
            f"encoded frame is {len(frame)} bytes, over the "
            f"{MAXIMUM_MESSAGE_BYTES} byte bound")
    return frame


def decode(line: bytes) -> Message:
    """One frame into a validated immutable message, or refuse.

    The size bound is applied to the raw frame before any parsing, so an
    oversized message is refused for being oversized rather than for whatever
    the parser happened to notice first.
    """
    if not isinstance(line, (bytes, bytearray)):
        raise ProtocolViolation("frame must be bytes")
    if len(line) > MAXIMUM_MESSAGE_BYTES:
        raise ProtocolViolation(
            f"frame is {len(line)} bytes, over the "
            f"{MAXIMUM_MESSAGE_BYTES} byte bound")
    raw = bytes(line)
    if not raw.endswith(_DELIMITER):
        raise ProtocolViolation("frame is not newline-terminated")
    body_bytes = raw[:-1]
    if _DELIMITER in body_bytes:
        raise ProtocolViolation("frame carries more than one message")
    if not body_bytes:
        raise ProtocolViolation("frame is empty")

    try:
        document = canonical_json.parse(
            body_bytes, maximum_bytes=MAXIMUM_MESSAGE_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise ProtocolViolation(f"frame is not one canonical object: "
                                f"{type(error).__name__}") from None

    for required in ("protocol_version", "kind", "cinv"):
        if required not in document:
            raise ProtocolViolation(f"missing field {required!r}")
    if document["protocol_version"] != PROTOCOL_VERSION:
        raise ProtocolViolation(
            f"unsupported protocol version; this build speaks "
            f"{PROTOCOL_VERSION} only")
    try:
        kind = MessageKind(document["kind"])
    except (ValueError, TypeError):
        raise ProtocolViolation("unknown message kind") from None

    values = {name: value for name, value in document.items()
              if name not in ("protocol_version", "kind", "cinv")}
    fields = _validate(kind, document["cinv"], values)
    return Message(kind=kind, cinv=document["cinv"], fields=fields)


class ProtocolEnded(ProtocolError):
    """The peer stopped talking before the conversation finished.

    Deliberately **not** a `ProtocolViolation`, and deliberately carrying no
    classification. A worker that was killed did not breach the contract; it
    died, and calling that a protocol violation would file a process death
    under the same heading as a malformed frame. They need different responses:
    a violation is concluded, a death leaves the container's fate unknown and is
    exactly what reconciliation exists for.
    """


class Channel:
    """One live conversation, driven from either side of the boundary.

    **It still owns no descriptor.** `Session` takes frames rather than a file
    for a stated reason -- reading them is somebody else's authority, and
    keeping this module pure is what lets the ordering rules be tested without a
    process on the other end. That holds here: the two collaborators are a
    callable that yields the next frame (or ``None`` at end of stream) and a
    callable that accepts one encoded frame. Where those come from is the
    caller's business.

    **One state machine governs both directions.** The worker sends `created`
    where the coordinator expects it, and the coordinator sends `start_now`
    where the worker expects it, so the same transition table is walked from
    both ends. Two tables would be two chances to disagree about what the
    conversation is.

    **Bound to one invocation.** Every message names a `CINV` and a message
    naming another is refused. `Session` never checked that because it replayed
    frames somebody had already chosen; a live channel is reading whatever
    arrives, and "well-formed" was never "belongs to this conversation".
    """

    __slots__ = ("_cinv", "_reader", "_writer", "_state")

    def __init__(self, cinv: str, *, reader: Any = None,
                 writer: Any = None) -> None:
        if not _is_cinv(cinv):
            raise ProtocolViolation("a channel is bound to a canonical CINV")
        self._cinv = cinv
        self._reader = reader
        self._writer = writer
        self._state = SessionState.START

    @property
    def cinv(self) -> str:
        return self._cinv

    @property
    def state(self) -> SessionState:
        return self._state

    def _advance(self, kind: MessageKind) -> None:
        """Walk the one table, or refuse. Shared by both directions."""
        if kind in _TERMINATING:
            if self._state not in _MAY_TERMINATE:
                raise ProtocolViolation(
                    f"{kind.value} is not legal in state {self._state.value}")
            self._state = SessionState.ENDED
            return
        allowed = _TRANSITIONS[self._state]
        if kind not in allowed:
            raise ProtocolViolation(
                f"{kind.value} is not legal in state {self._state.value}")
        self._state = allowed[kind]

    def send(self, kind: MessageKind, **fields: Any) -> Message:
        """Encode, hand to the writer, and advance -- or refuse and send nothing.

        Legality is decided before the bytes exist. A frame that would be
        illegal here is never written, so the peer cannot receive a message this
        side has already decided was out of order.
        """
        if self._writer is None:
            raise ProtocolViolation("this channel cannot send")
        if not isinstance(kind, MessageKind):
            raise ProtocolViolation("kind must be a MessageKind")
        frame = encode(Message(kind=kind, cinv=self._cinv,
                               fields=tuple(fields.items())))
        self._advance(kind)
        self._writer(frame)
        return decode(frame)

    def receive(self) -> Message:
        """The next message, if anything it could be is legal here.

        Unlike `expect`, this does not pre-commit to one kind, because a live
        reader does not get to choose what arrives. What it refuses is anything
        the current state does not permit -- which includes `started` before
        `start_now` and a second `terminal` -- while still admitting the two
        terminating kinds, since either side may end the conversation.

        End of stream raises `ProtocolEnded` rather than a violation. The
        difference is the whole reason the type exists.
        """
        if self._reader is None:
            raise ProtocolViolation("this channel cannot receive")
        frame = self._reader()
        if frame is None:
            raise ProtocolEnded(
                f"the peer ended the conversation in state {self._state.value}")
        message = decode(frame)
        if message.cinv != self._cinv:
            raise ProtocolViolation(
                f"message names {message.cinv}, not {self._cinv}")
        self._advance(message.kind)
        return message

    def expect(self, kind: MessageKind) -> Message:
        """`receive`, refusing anything that is not ``kind``.

        Kept because the lifecycle's start gate takes a session and asks it for
        exactly `start_now`; a channel is a session that can also talk back.
        """
        if not isinstance(kind, MessageKind):
            raise ProtocolViolation("expected kind must be a MessageKind")
        before = self._state
        message = self.receive()
        if message.kind is not kind:
            raise ProtocolViolation(
                f"expected {kind.value} in state {before.value}, "
                f"received {message.kind.value}")
        return message


class Session:
    """One conversation, replayed over already-read frames.

    Deliberately takes frames rather than a descriptor: reading them is
    somebody else's authority, and keeping this pure means the ordering rules
    can be tested without a process on the other end.
    """

    def __init__(self, frames: Iterable[bytes]) -> None:
        self._frames = list(frames)
        self._index = 0
        self._state = SessionState.START

    @property
    def state(self) -> SessionState:
        return self._state

    def expect(self, kind: MessageKind) -> Message:
        """The next frame, if it is ``kind`` and ``kind`` is legal here.

        Both conditions matter. A caller expecting the wrong thing has lost
        track of the conversation, and a message arriving in the wrong state
        means the other side has — neither is safe to continue from.
        """
        if not isinstance(kind, MessageKind):
            raise ProtocolViolation("expected kind must be a MessageKind")
        if self._index >= len(self._frames):
            raise ProtocolViolation(
                f"expected {kind.value} but the conversation ended")

        message = decode(self._frames[self._index])
        if message.kind is not kind:
            raise ProtocolViolation(
                f"expected {kind.value}, received {message.kind.value}")

        if kind in _TERMINATING:
            if self._state not in _MAY_TERMINATE:
                raise ProtocolViolation(
                    f"{kind.value} is not legal in state {self._state.value}")
            nxt = SessionState.ENDED
        else:
            allowed = _TRANSITIONS[self._state]
            if kind not in allowed:
                raise ProtocolViolation(
                    f"{kind.value} is not legal in state {self._state.value}")
            nxt = allowed[kind]

        self._index += 1
        self._state = nxt
        return message
