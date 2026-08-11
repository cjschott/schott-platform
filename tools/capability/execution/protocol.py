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


def _is_oci_digest(value: Any) -> bool:
    return (isinstance(value, str) and value.startswith("sha256:")
            and len(value) == 71 and set(value[7:]) <= _HEX)


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


# Every field each kind carries, with its validator. The absence of anything
# command-shaped here is the guarantee, not a comment about it.
MESSAGE_SCHEMAS: dict[MessageKind, dict[str, Any]] = {
    MessageKind.CREATED: {"container_id": _is_container_id},
    MessageKind.VERIFIED_PROFILE: {
        "container_id": _is_container_id,
        "profile_digest": _is_sha256,
        "image_digest": _is_oci_digest,
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
