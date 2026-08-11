"""Canonical JSON for the ENG-0005 first adapter.

**Refuses; never repairs.** Every rule here exists for one reason: the bytes a
capability receives must be the bytes whose digest was bound to the invocation.
A parser that normalises, coerces, or collapses its input breaks that equality
quietly, and a quiet break is worse than a refusal because nothing downstream
can detect it.

So this module has no lenient mode and no fallback. Where JSON permits more
than the specification does — floats, exponents, ``NaN``, duplicate keys,
oversized integers, lone surrogates — the extra latitude is removed rather
than accommodated.

**Pure.** Bytes in, values out. No file, no clock, no environment, no process,
no identity generation. The caller supplies the bytes; obtaining them is
someone else's authority.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §10.
"""

from __future__ import annotations

import json
from typing import Any

INT64_MINIMUM = -9223372036854775808
INT64_MAXIMUM = 9223372036854775807

_SURROGATE_FIRST = 0xD800
_SURROGATE_LAST = 0xDFFF
_ASCII_DIGITS = frozenset("0123456789")


class CanonicalJSONError(ValueError):
    """Base for every refusal this module makes."""


class PayloadTooLarge(CanonicalJSONError):
    """Input exceeds the caller's byte bound."""


class DuplicateKey(CanonicalJSONError):
    """An object carried the same key twice, at any depth."""


class MalformedDocument(CanonicalJSONError):
    """Not exactly one JSON document whose top level is an object."""


class UnsupportedNumber(CanonicalJSONError):
    """A number outside the signed-64-bit integer grammar."""


class InvalidString(CanonicalJSONError):
    """A string that is not valid, canonical, UTF-8-representable text."""


def _reject_float(literal: str) -> Any:
    raise UnsupportedNumber(
        f"fractional and exponent numbers are not permitted: {literal!r}")


def _reject_constant(literal: str) -> Any:
    raise UnsupportedNumber(f"{literal!r} is not a permitted number")


def _integer(literal: str) -> int:
    """One canonical base-10 signed 64-bit integer, or refuse.

    The literal is checked rather than the parsed value, because ``-0`` and a
    leading zero both parse to something reasonable while meaning the document
    had more than one spelling for the same number.
    """
    digits = literal[1:] if literal.startswith("-") else literal
    if not digits or not set(digits) <= _ASCII_DIGITS:
        raise UnsupportedNumber(f"not a base-10 integer: {literal!r}")
    if len(digits) > 1 and digits[0] == "0":
        raise UnsupportedNumber(f"leading zero is not canonical: {literal!r}")
    if literal == "-0":
        raise UnsupportedNumber("negative zero is not canonical")
    value = int(literal)
    if value < INT64_MINIMUM or value > INT64_MAXIMUM:
        raise UnsupportedNumber(f"outside signed 64-bit range: {literal!r}")
    return value


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build one object, refusing a repeated key.

    Duplicate detection happens here, before the pairs become a dict, because
    a dict has already discarded the evidence: ``{"a":1,"a":1}`` and
    ``{"a":1}`` are indistinguishable once collapsed, and the first is a
    document nobody should have sent.
    """
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise DuplicateKey(f"duplicate key: {key!r}")
        seen.add(key)
    return dict(pairs)


def _check_text(text: str, *, what: str) -> None:
    for character in text:
        point = ord(character)
        if point == 0:
            raise InvalidString(f"U+0000 is not permitted in {what}")
        if _SURROGATE_FIRST <= point <= _SURROGATE_LAST:
            raise InvalidString(
                f"unpaired surrogate U+{point:04X} is not permitted in {what}")


def _check_decoded(value: Any) -> None:
    """Walk the decoded document, refusing text the grammar excludes.

    Done after decoding rather than over the raw bytes because ``\\u0000`` and
    a lone ``\\ud800`` are escapes: they are invisible in the input bytes and
    only exist once the escape has been resolved.
    """
    if isinstance(value, str):
        _check_text(value, what="a string")
    elif isinstance(value, dict):
        for key, item in value.items():
            _check_text(key, what="an object key")
            _check_decoded(item)
    elif isinstance(value, list):
        for item in value:
            _check_decoded(item)


def parse(data: bytes, *, maximum_bytes: int) -> dict[str, Any]:
    """One canonical JSON object from ``data``, or refuse.

    The bound is applied to the raw bytes before any parsing, so an oversized
    document is refused for being oversized rather than for whatever the
    parser happened to notice first.
    """
    if not isinstance(data, (bytes, bytearray)):
        raise MalformedDocument("input must be bytes")
    if len(data) > maximum_bytes:
        raise PayloadTooLarge(
            f"{len(data)} bytes exceeds the {maximum_bytes} byte bound")

    try:
        text = bytes(data).decode("utf-8")
    except UnicodeDecodeError as error:
        raise InvalidString(f"input is not valid UTF-8: {error}") from None

    try:
        value = json.loads(
            text,
            object_pairs_hook=_object,
            parse_float=_reject_float,
            parse_int=_integer,
            parse_constant=_reject_constant,
        )
    except CanonicalJSONError:
        raise
    except ValueError as error:
        raise MalformedDocument(f"not exactly one JSON document: {error}") from None

    if not isinstance(value, dict):
        raise MalformedDocument("the top level must be an object")

    _check_decoded(value)
    return value


def _encode(value: Any, out: list[str]) -> None:
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, str):
        _check_text(value, what="a string")
        out.append(json.dumps(value, ensure_ascii=False))
    elif isinstance(value, int):
        # bool is a subclass of int and is already handled above, so anything
        # reaching here is a real integer.
        if value < INT64_MINIMUM or value > INT64_MAXIMUM:
            raise UnsupportedNumber(f"outside signed 64-bit range: {value}")
        out.append(str(value))
    elif isinstance(value, dict):
        out.append("{")
        items = []
        for key, item in value.items():
            if not isinstance(key, str):
                raise MalformedDocument(f"object keys must be strings: {key!r}")
            _check_text(key, what="an object key")
            items.append((key.encode("utf-8"), key, item))
        for index, (_, key, item) in enumerate(sorted(items, key=lambda e: e[0])):
            if index:
                out.append(",")
            out.append(json.dumps(key, ensure_ascii=False))
            out.append(":")
            _encode(item, out)
        out.append("}")
    elif isinstance(value, list):
        out.append("[")
        for index, item in enumerate(value):
            if index:
                out.append(",")
            _encode(item, out)
        out.append("]")
    else:
        raise UnsupportedNumber(f"unsupported value: {value!r}")


def serialise(value: dict[str, Any]) -> bytes:
    """Canonical bytes for ``value``, or refuse.

    Ordering is by the UTF-8 bytes of each key. UTF-8 preserves code-point
    order so this cannot disagree with ordinal ordering; it is written against
    the bytes anyway, because the property the format needs is one nobody has
    to reason about the encoding to check.
    """
    if not isinstance(value, dict):
        raise MalformedDocument("the top level must be an object")
    out: list[str] = []
    _encode(value, out)
    return "".join(out).encode("utf-8")
