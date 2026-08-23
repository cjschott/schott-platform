"""The result content the boundary-verification capability may return.

``collector.py`` is the authority for the result *envelope*: that a root-level
``result.json`` exists, that it parses as canonical JSON, and that it is within
bounds. It deliberately says nothing about what is inside, because the inside
belongs to whichever capability produced it. This module is the authority for
one capability's inside, and nothing else.

**It exists so a contract can reference it.** A capability contract that merely
listed the keys it expected would be a permanent, immutable, unexecuted copy of
a schema — a claim of enforcement no code performs. The contract names this
module instead, and this module performs the check.

**Closed, exactly as the payload schema is.** The field set is exhaustive: a
key not named here is refused rather than ignored, so a result cannot carry
data the contract never agreed to, and a future field name cannot quietly
change meaning.

**It validates a decoded document and nothing else.** No descriptor, no path,
no bytes, no clock. The caller has already decided the envelope was
believable — ``collector.read_result`` is the only thing that can — and hands
over what it decoded. Re-parsing here would make this a second opinion about
the envelope, which is precisely the duplication the split avoids.

**Well-formed is not true.** That a result says it hashed a payload is not
evidence that it did. Whether the digest matches what was actually mounted is
the caller's comparison against its own governed record; this module only
guarantees the fields are present, governed, and readable enough to compare.

Governed by ``platform-model/schemas/capability-contract.schema.yaml``
(``response_shape_parts``).
"""

from __future__ import annotations

from typing import Any, Mapping

# The schema name and version a capability contract's `response_shape.content`
# references. Exported so the reference and the enforcement are the same fact
# written once.
RESULT_CONTENT_SCHEMA = "kyri-execution-verification-result"
RESULT_CONTENT_SCHEMA_VERSION = 1

# The capability this content belongs to, spelled exactly as the permanent
# capability definition spells it. A result claiming to be some other
# capability's is refused rather than accepted and mislabelled: the whole point
# of the verification record is that it says what was actually proven.
#
# The `kyri-` prefix is part of the governed name, not decoration. A result
# naming the unprefixed spelling names no capability the Fabric governs, so it
# could never be matched to the definition it claims to be evidence for -- and
# an authority that accepted the near-miss would be certifying results about a
# capability that does not exist.
VERIFICATION_CAPABILITY = "kyri-execution-boundary-verification"

# The one operation this release verifies. A closed vocabulary rather than free
# text, so the field cannot carry a command, a path, or a shell fragment.
OPERATIONS = ("verify-execution-boundary",)

_SHA256_LENGTH = 64
_HEX = frozenset("0123456789abcdef")


class ResultContentError(ValueError):
    """The document is not a governed verification result."""


def _require_digest(value: Any, name: str) -> str:
    """Lowercase hex SHA-256, unprefixed. Nothing is normalised.

    A digest that had to be recased to be recognised was not the digest that
    was written, and accepting both spellings would make two different strings
    compare equal in one place and unequal everywhere else.
    """
    if not isinstance(value, str) or len(value) != _SHA256_LENGTH:
        raise ResultContentError(f"{name} must be a hex SHA-256 digest")
    if not set(value) <= _HEX:
        raise ResultContentError(f"{name} must be lowercase hexadecimal")
    return value


def validate_result_content(document: Any) -> Mapping[str, Any]:
    """The document as a governed verification result, or refuse.

    ``document`` is what ``collector.read_result`` already decoded. Returned
    unchanged on success: this reports whether the content is governed, and
    never repairs, completes, or rewrites it.
    """
    if not isinstance(document, Mapping):
        raise ResultContentError("a verification result must be an object")

    expected = {"capability", "result_schema_version", "operation",
                "payload_digest", "checksum"}
    present = set(document)
    missing = sorted(expected - present)
    if missing:
        raise ResultContentError(
            f"missing required field(s): {', '.join(missing)}")
    unknown = sorted(present - expected)
    if unknown:
        # Named, not echoed. A field name is safe to report; a value written by
        # the workload is not.
        raise ResultContentError(f"unknown field(s): {', '.join(unknown)}")

    if document["capability"] != VERIFICATION_CAPABILITY:
        raise ResultContentError("capability is not this verification capability")

    version = document["result_schema_version"]
    # `bool` is an `int` in Python, so `True` would otherwise pass as version 1.
    if isinstance(version, bool) or version != RESULT_CONTENT_SCHEMA_VERSION:
        raise ResultContentError(
            f"result_schema_version must be {RESULT_CONTENT_SCHEMA_VERSION}")

    if document["operation"] not in OPERATIONS:
        raise ResultContentError("operation is not a governed operation")

    _require_digest(document["payload_digest"], "payload_digest")
    _require_digest(document["checksum"], "checksum")
    return document
