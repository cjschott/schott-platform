"""Binding one execution payload to one invocation, and nothing else.

A Fabric selection governs a request **class** — a capability, a contract, a
set of accepted versions, a data classification, a locality. Two entirely
different payloads of one class produce byte-identical governance. So a caller
holding a valid selection for one payload would, without this layer, hold a
valid selection for any payload of that shape. Binding is what closes that.

**The digest covers the payload and the values that place it.** A digest over
payload bytes alone would still be re-presentable under a different selection,
a different instance, or a different actor; covering the binding as well means
a payload proves which decision it belongs to, not merely what it says.

**Canonicalisation refuses rather than approximates.** Anything whose textual
representation is a matter of opinion — a float, a set, a non-string key, an
object nobody wrote a rule for — is refused. A canonical form with one
implementation-defined corner is a canonical form that disagrees with itself
across versions, and a digest that disagrees is worse than no digest.

**An `invocation_id` is opaque and is never parsed.** It is validated only as
far as safety requires: bounded, printable, comparable as bytes. Nothing here
reads structure into it, because an identity the runtime interprets is an
identity the runtime can be wrong about.

This layer is pure. It reads no record, opens no store, holds no lock, writes
nothing, reads no clock, consults no ambient state, and **executes nothing**.
Everything it needs arrives as an argument.
"""

from __future__ import annotations

import hashlib
import hmac
import json
from typing import Any, Mapping

from .errors import CapabilityError

# The released bound for a caller-supplied identity, matching the Fabric's.
INVOCATION_ID_MAX_LENGTH = 200

# Printable ASCII, space excluded: safe to store, to log, and to compare, and
# narrow enough that an identity cannot smuggle a control character anywhere.
_SAFE_FIRST = "!"
_SAFE_LAST = "~"

_HEX = frozenset("0123456789abcdef")
_DIGEST_PREFIX = "sha256:"
_DIGEST_LENGTH = len(_DIGEST_PREFIX) + 64

# The three answers to "have I seen this identity before, and with what?".
CONSUMED = "invocation_identity_consumed"
CONFLICT = "invocation_identity_conflict"
DISTINCT = "invocation_identity_distinct"

# The fields that place a payload. Ordered for the reader; the canonical form
# sorts them itself, so this order carries no weight.
BINDING_FIELDS = ("invocation_id", "selection_id", "instance_id",
                  "capability_package_id", "operation", "actor")


def _safe_text(value: Any, name: str) -> str:
    """Bounded, printable, non-empty text. Never parsed, only checked."""
    if not isinstance(value, str):
        raise CapabilityError(f"{name} must be supplied as text")
    if not value or len(value) > INVOCATION_ID_MAX_LENGTH:
        raise CapabilityError(
            f"{name} must be 1 to {INVOCATION_ID_MAX_LENGTH} characters")
    for character in value:
        if not _SAFE_FIRST <= character <= _SAFE_LAST:
            raise CapabilityError(
                f"{name} carries a character that is not safe to store")
    return value


def validate_invocation_id(invocation_id: Any) -> str:
    """The caller's identity, returned unchanged, or refused.

    Opaque by contract: this checks that the value is safe to hold and to
    compare, and reads nothing into its shape.
    """
    return _safe_text(invocation_id, "invocation_id")


def _checked(value: Any, path: str) -> Any:
    """The payload, proven to be made only of forms with one representation."""
    # Order matters: a bool is an int in Python, and `true` is not `1`.
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        return value
    if isinstance(value, float):
        raise CapabilityError(
            f"payload{path} carries a floating-point value, which has no single "
            "canonical representation")
    if isinstance(value, Mapping):
        checked = {}
        for key, member in value.items():
            if not isinstance(key, str):
                raise CapabilityError(
                    f"payload{path} carries a mapping key that is not text")
            checked[key] = _checked(member, f"{path}[{key!r}]")
        return checked
    if isinstance(value, list):
        return [_checked(member, f"{path}[{index}]")
                for index, member in enumerate(value)]
    raise CapabilityError(
        f"payload{path} carries a value of a kind with no canonical form")


def canonical_bytes(payload: Any) -> bytes:
    """The one byte string this payload canonicalises to.

    UTF-8 JSON, keys sorted by code point, no insignificant whitespace, no
    trailing newline, non-ASCII emitted literally rather than escaped.
    """
    checked = _checked(payload, "")
    try:
        text = json.dumps(checked, ensure_ascii=False, sort_keys=True,
                          allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError):
        raise CapabilityError("payload has no canonical representation") from None
    return text.encode("utf-8")


def payload_digest(payload: Any) -> str:
    """The payload's digest alone, in the released `sha256:<hex>` form."""
    return f"{_DIGEST_PREFIX}{hashlib.sha256(canonical_bytes(payload)).hexdigest()}"


def bind(*, payload: Any, invocation_id: Any, selection_id: Any,
         instance_id: Any, capability_package_id: Any, operation: Any,
         actor: Any) -> str:
    """One digest over the payload and the decision it belongs to.

    The binding is canonicalised as a named mapping, so a field's value cannot
    be mistaken for another field's: moving text across the boundary changes
    the canonical bytes rather than sliding past unnoticed.

    The operation is covered because it is caller-controlled authority. A
    binding that omitted it could be checked as one action and presented as
    another, and the digest would agree with both.
    """
    supplied = {
        "invocation_id": validate_invocation_id(invocation_id),
        "selection_id": _safe_text(selection_id, "selection_id"),
        "instance_id": _safe_text(instance_id, "instance_id"),
        "capability_package_id": _safe_text(capability_package_id,
                                            "capability_package_id"),
        "operation": _safe_text(operation, "operation"),
        "actor": _safe_text(actor, "actor"),
        "payload": _checked(payload, ""),
    }
    return f"{_DIGEST_PREFIX}{hashlib.sha256(canonical_bytes(supplied)).hexdigest()}"


def _validated_digest(value: Any, name: str) -> str:
    """A digest in the released form, checked without being parsed."""
    if not isinstance(value, str) or len(value) != _DIGEST_LENGTH:
        raise CapabilityError(f"{name} is not a sha256 digest")
    if value[:len(_DIGEST_PREFIX)] != _DIGEST_PREFIX:
        raise CapabilityError(f"{name} is not a sha256 digest")
    for character in value[len(_DIGEST_PREFIX):]:
        if character not in _HEX:
            raise CapabilityError(f"{name} is not a sha256 digest")
    return value


def compare_binding(stored: Any, presented: Any) -> str:
    """What a repeated invocation identity means, as a pure comparison.

    `None` for `stored` means the identity has not been seen. **Whether it has
    been seen is a question about durable evidence, and answering it belongs to
    the increment that owns that evidence** — this decides only what the two
    bindings imply once both are in hand.
    """
    checked = _validated_digest(presented, "presented binding")
    if stored is None:
        return DISTINCT
    # Constant-time: the comparison says whether two digests match and nothing
    # about where they first differ.
    if hmac.compare_digest(_validated_digest(stored, "stored binding"), checked):
        return CONSUMED
    return CONFLICT
