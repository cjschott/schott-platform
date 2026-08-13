"""Payload validation and identity for the ENG-0005 first adapter.

**T3 establishes payload identity, and it is authoritative.** The digest bound
here is `SHA-256` over the *canonical* bytes — not the source spelling, not a
pathname, not a later copy. T7 will prove the handoff copy still matches this
digest; it does not get to redefine what the payload is.

Taking the digest over canonical bytes rather than source bytes is the point.
Two documents that differ only in whitespace or key order are the same governed
payload, so they must bind identically; two that differ in value are different,
so they must not. Digesting the source spelling would make an invocation's
identity depend on how its JSON happened to be formatted.

**Descriptor-only, by construction.** The caller opens the payload — obtaining
it safely is the caller's authority — and hands over a descriptor. This module
has no way to name, resolve, reopen, or follow a pathname, so replacing or
unlinking the source after the open cannot change the bytes read or the digest
computed. That is not a promise about how the code is written; it is enforced
by the module importing no path surface at all.

**Reads are bounded before they are measured.** At most the accepted maximum
plus one byte is ever pulled from the descriptor, so an oversized payload is
refused without first being brought into memory.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §10.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
from typing import Any

from . import canonical_json

PAYLOAD_MAXIMUM_BYTES = 2 * 1024 * 1024

_READ_CHUNK = 65536


class PayloadError(ValueError):
    """Base for every refusal this module makes."""


class SchemaViolation(PayloadError):
    """The document does not satisfy its governed closed schema."""


class UnsupportedSchemaVersion(PayloadError):
    """No governed schema is defined for the requested version."""


@dataclasses.dataclass(frozen=True)
class _Field:
    """One declared field. Optionality is explicit; there is no default."""

    kind: type | tuple[type, ...]
    required: bool
    nested: "_Schema | None" = None


@dataclasses.dataclass(frozen=True)
class _Schema:
    """A closed object schema.

    Closed means the field set is exhaustive: anything not named here is
    refused rather than ignored. Ignoring an unknown field would let a payload
    carry data the governed contract never agreed to, and would let a future
    field name silently change meaning.
    """

    fields: dict[str, _Field]


# The governed schema registry. Versions are selected by capability authority
# through the call, never by the payload, so this maps an integer the caller
# already had the right to choose.
# The governed payload schema this build implements. Exported so admission
# commits a constant rather than an operator's integer: a payload schema is a
# contract between the coordinator and the capability, and an admission that
# named a version nobody implements would be admitted and then unusable.
PAYLOAD_SCHEMA_VERSION = 1

_SCHEMAS: dict[int, _Schema] = {
    1: _Schema(fields={
        "operation": _Field(kind=str, required=True),
        "arguments": _Field(
            kind=dict,
            required=True,
            nested=_Schema(fields={
                "count": _Field(kind=int, required=True),
                "label": _Field(kind=str, required=False),
            }),
        ),
        "note": _Field(kind=str, required=False),
    }),
}


@dataclasses.dataclass(frozen=True)
class PayloadBinding:
    """One validated payload and the identity derived from it.

    Carries the decoded document for later validation to read, the canonical
    bytes that will be mounted, and the digest that binds them. Deliberately
    carries no pathname: nothing downstream should be able to reopen a source.
    """

    document: dict[str, Any]
    canonical_bytes: bytes
    digest: str
    schema_version: int


def _read_bounded(descriptor: int, maximum_bytes: int) -> bytes:
    """At most ``maximum_bytes + 1`` bytes from ``descriptor``.

    One byte past the limit is read on purpose: it is the cheapest way to tell
    "exactly at the bound" from "over the bound" without reading the rest of
    whatever the descriptor refers to.
    """
    chunks: list[bytes] = []
    remaining = maximum_bytes + 1
    while remaining > 0:
        chunk = os.read(descriptor, min(_READ_CHUNK, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _validate_object(value: Any, schema: _Schema, path: str) -> None:
    if not isinstance(value, dict):
        raise SchemaViolation(f"{path or 'payload'} must be an object")

    for name in value:
        if name not in schema.fields:
            raise SchemaViolation(
                f"unknown field {name!r} in {path or 'payload'}")

    for name, field in schema.fields.items():
        if name not in value:
            if field.required:
                raise SchemaViolation(
                    f"missing required field {name!r} in {path or 'payload'}")
            continue
        item = value[name]
        # bool is a subclass of int, so an int field would otherwise accept
        # true. A boolean is not a count.
        if field.kind is int and isinstance(item, bool):
            raise SchemaViolation(
                f"field {name!r} in {path or 'payload'} must be an integer")
        if not isinstance(item, field.kind):
            raise SchemaViolation(
                f"field {name!r} in {path or 'payload'} has the wrong type")
        if field.nested is not None:
            _validate_object(item, field.nested,
                             f"{path}.{name}" if path else name)


def validate_payload(descriptor: int, *, schema_version: int) -> PayloadBinding:
    """Validate the payload on ``descriptor`` and bind its identity.

    ``schema_version`` comes from governed capability authority. The payload
    has no say in it: the schema is closed, so a ``schema_version`` key inside
    the document is simply an unknown field and is refused.
    """
    schema = _SCHEMAS.get(schema_version)
    if schema is None:
        raise UnsupportedSchemaVersion(
            f"no governed schema for version {schema_version!r}")

    source = _read_bounded(descriptor, PAYLOAD_MAXIMUM_BYTES)

    document = canonical_json.parse(source, maximum_bytes=PAYLOAD_MAXIMUM_BYTES)
    _validate_object(document, schema, "")

    canonical_bytes = canonical_json.serialise(document)
    if len(canonical_bytes) > PAYLOAD_MAXIMUM_BYTES:
        raise canonical_json.PayloadTooLarge(
            f"canonical form is {len(canonical_bytes)} bytes, over the "
            f"{PAYLOAD_MAXIMUM_BYTES} byte bound")

    return PayloadBinding(
        document=document,
        canonical_bytes=canonical_bytes,
        digest=hashlib.sha256(canonical_bytes).hexdigest(),
        schema_version=schema_version,
    )
