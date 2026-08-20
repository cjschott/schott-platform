"""The semantic fingerprint of a declarative platform-model Evidence record.

**One implementation, two consumers.** The S0 generator computes it and the
validator recomputes it. A digest whose producer and checker are separate
implementations is a digest that agrees until the day it does not, and the day
it does not is the day nobody can tell which side was right.

**What is fingerprinted is the evidentiary claim, not the record.** Six fields
and no others:

    schema_version  binds interpretation: a payload shape change must not
                    silently compare equal
    target          identical facts about two different hosts are not the same
                    evidence
    source_type     command output and a human attestation are different
                    authorities for the same sentence
    collector       who observed it is part of what was claimed
    status          a failed collection must not fingerprint-match a successful
                    one that happened to report the same facts
    facts           the normalized source material itself

**What is excluded is everything that is bookkeeping about the claim** — `id`,
`collected_at`, `provenance`, `retention`, `references`, `sensitivity`, and the
fingerprint field itself. Re-observing an unchanged machine must produce the
same semantic digest; if a timestamp participated, "has this evidence changed"
could never be answered by comparing two fingerprints.

**Canonical JSON, not YAML.** YAML has too many ways to write the same value,
so the digest is taken over a canonical JSON encoding: keys sorted, no
insignificant whitespace, non-ASCII emitted literally. Key order in the file
therefore cannot change the digest, and neither can indentation, quoting style,
or line wrapping.

**Nothing is coerced.** A value JSON cannot represent raises rather than being
stringified. A digest over `str(x)` is a digest over whatever `repr` happened
to do that release, which is not a commitment to anything.

Distinct from `tools/observation/evidence_builder.fingerprint`, which belongs
to the runtime observation plane and covers a different preimage over a
different record shape. Neither is a substitute for the other, and this module
does not import it.

Governed by ``platform-model/schemas/evidence.schema.yaml``.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Mapping

# The exact preimage, in the order the ruling states it. Serialisation sorts
# keys anyway; the tuple exists so the field set is readable as a list and a
# reviewer can compare it against the schema without reading the encoder.
PREIMAGE_FIELDS = ("schema_version", "target", "source_type", "collector",
                   "status", "facts")

# `api_version` is the record field that carries what the preimage calls
# `schema_version`: it is the declared contract that interprets the record, and
# every platform-model record already carries it. A separate `schema_version`
# field would be a second answer to one question.
SCHEMA_VERSION_FIELD = "api_version"

DIGEST_PREFIX = "sha256:"

_HEX = frozenset("0123456789abcdef")
_DIGEST_LENGTH = len(DIGEST_PREFIX) + 64


class FingerprintError(ValueError):
    """The record cannot be fingerprinted, and no digest is guessed for it."""


def preimage(record: Mapping[str, Any]) -> dict[str, Any]:
    """The six ruled fields, lifted from a record, or refuse.

    A missing field is refused rather than defaulted: a digest computed over an
    absent `target` would be a digest of a claim about nobody.
    """
    if not isinstance(record, Mapping):
        raise FingerprintError("an evidence record must be a mapping")
    built: dict[str, Any] = {}
    for name in PREIMAGE_FIELDS:
        source = SCHEMA_VERSION_FIELD if name == "schema_version" else name
        if source not in record:
            raise FingerprintError(f"the record carries no {source!r}")
        built[name] = record[source]
    return built


def canonical_bytes(record: Mapping[str, Any]) -> bytes:
    """The exact bytes the digest is taken over.

    Exposed because a reviewer checking a digest by hand needs to see the
    preimage, not be told about it.
    """
    try:
        encoded = json.dumps(preimage(record), sort_keys=True,
                             separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError) as error:
        # No `default=`: a value JSON cannot represent is a value nobody
        # reviewed the encoding of.
        raise FingerprintError(
            f"the semantic content is not JSON-representable: {error}") from None
    return encoded.encode("utf-8")


def fingerprint(record: Mapping[str, Any]) -> str:
    """The record's semantic fingerprint, as ``sha256:<64 lowercase hex>``."""
    return DIGEST_PREFIX + hashlib.sha256(canonical_bytes(record)).hexdigest()


def is_well_formed(value: Any) -> bool:
    """Whether a value is the rendered digest form. Lowercase only."""
    if not isinstance(value, str) or len(value) != _DIGEST_LENGTH:
        return False
    if not value.startswith(DIGEST_PREFIX):
        return False
    return all(character in _HEX for character in value[len(DIGEST_PREFIX):])
