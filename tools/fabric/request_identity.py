"""Request identity, its canonical digest, and replay lookup without a ledger.

**Record identity and request identity are different things.** The store
allocates record identity; the caller supplies request identity. This module
derives **only** `request_digest`, and never `request_id` — a value the Fabric
minted could not distinguish a resubmission from a fresh submission, which is
the one thing request identity exists to do.

`request_id` is **opaque**. It carries no timestamp, no UUID requirement, no
sequence, and no readable format, so nothing here parses it. It is validated
only as far as safety requires: bounded length, characters that are safe to
store and to compare, and constant-time comparison.

**The digest convention is reused, not invented.** SHA-256 over canonical JSON
with sorted keys and stable separators, rendered `sha256:`-prefixed, exactly as
`tools/observation/evidence_builder.py` and `tools/integrity/snapshot_manager.py`
already do. No new cryptographic algorithm appears here. Participating fields
are named in the payload so semantically distinct inputs cannot collide, and
the canonicalisation and digest versions are part of the payload so an unknown
one fails closed rather than being guessed at.

**Replay resolution reads the eight accepted record types and nothing else.**
There is no request ledger, no replay ledger, and no ninth record class: the
`request_id` and `request_digest` that prove a request was accepted live on the
record whose existence they justify.

**This helper never enters `request_critical_section()`.** It assumes the
accepted operation boundary already holds it. Acquiring it here would nest
inside that boundary and deadlock the moment increment 12 makes the context a
real lock.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from collections.abc import Mapping
from typing import Any, NamedTuple

from .errors import FabricError
from .identifiers import ID_FIELDS

# Versioned as part of the operation contract. An unknown version fails closed.
SUPPORTED_CANONICALISATION = "fabric-canonical/v1"
SUPPORTED_DIGEST = "sha256"

# Long enough for any opaque token a caller reasonably mints, short enough that
# it cannot be used to smuggle a payload into a record.
REQUEST_ID_MAX_LENGTH = 200

DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")

# Inputs the accepted schemas define as sets rather than sequences. Their order
# is not authoritative, so it must not reach the digest.
UNORDERED_INPUTS = frozenset({
    "contract_ids",
    "satisfied_contract_versions",
    "accepted_contract_versions",
    "compatible_with",
    "failure_modes",
})

# Named by the specification as outside the canonicalisation boundary. They may
# arrive with a request; they never affect what the request *is*.
EXCLUDED_INPUTS = frozenset({
    "transport", "transport_metadata", "peer",
    "arrival_time", "received_at",
    "correlation_id", "log_correlation_id", "trace_id",
    "record_id", "record_identity",
})

REPLAY_NEW = "new"
REPLAY_EXACT = "exact_replay"
# The specification's error category, used verbatim so a refusal is nameable.
REPLAY_CONFLICT = "request_identity_conflict"


class ReplayOutcome(NamedTuple):
    """What a request identity means against the records that already exist."""

    status: str
    record_kind: str | None = None
    record_id: str | None = None


def validate_request_id(request_id: Any) -> str:
    """Return the caller's value unchanged, or refuse it.

    Nothing here interprets the value. The rules are safety rules only: it must
    be text, bounded, and free of characters that would be unsafe to store in a
    record or to compare in constant time.
    """
    if not isinstance(request_id, str):
        raise FabricError("request_id must be supplied as text")
    if not request_id or len(request_id) > REQUEST_ID_MAX_LENGTH:
        raise FabricError(
            f"request_id must be 1 to {REQUEST_ID_MAX_LENGTH} characters")
    # Printable ASCII without space: safe to store in YAML, safe to log, and
    # comparable in constant time. The value itself is never echoed.
    if not all("!" <= character <= "~" for character in request_id):
        raise FabricError("request_id carries a character that is not safe to store")
    return request_id


def validate_request_digest(request_digest: Any) -> str:
    """Refuse anything that is not the released `sha256:` convention."""
    if not isinstance(request_digest, str) or not DIGEST_PATTERN.match(request_digest):
        raise FabricError("request_digest is not a supported sha256 digest")
    return request_digest


def _canonical_inputs(inputs: Mapping[str, Any]) -> dict[str, Any]:
    """Authoritative inputs only, with unordered sets ordered deterministically."""
    canonical: dict[str, Any] = {}
    for name in sorted(inputs):
        if name in EXCLUDED_INPUTS:
            continue
        value = inputs[name]
        if name in UNORDERED_INPUTS and isinstance(value, (list, tuple)):
            # Ordered here so that a caller's ordering cannot change identity,
            # not to normalise the value: the members themselves are untouched.
            canonical[name] = sorted(value, key=str)
        elif isinstance(value, tuple):
            canonical[name] = list(value)
        else:
            canonical[name] = value
    return canonical


def compute_request_digest(operation: Any, authoritative_inputs: Any, *,
                           canonicalisation: str = SUPPORTED_CANONICALISATION,
                           digest: str = SUPPORTED_DIGEST) -> str:
    """The deterministic digest of one governed operation's authoritative inputs."""
    if canonicalisation != SUPPORTED_CANONICALISATION:
        raise FabricError("unsupported canonicalisation version")
    if digest != SUPPORTED_DIGEST:
        raise FabricError("unsupported digest version")
    if not isinstance(operation, str) or not operation.strip():
        raise FabricError("an operation type is required")
    if not isinstance(authoritative_inputs, Mapping):
        raise FabricError("authoritative inputs must be a mapping")

    payload = {
        "canonicalisation": canonicalisation,
        "digest": digest,
        "operation": operation,
        "inputs": _canonical_inputs(authoritative_inputs),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                         default=str).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def _same(left: Any, right: Any) -> bool:
    """Constant-time equality that refuses rather than raising on odd input."""
    if not isinstance(left, str) or not isinstance(right, str):
        return False
    try:
        return hmac.compare_digest(left, right)
    except TypeError:
        return False


def replay_lookup(store, request_id: Any, request_digest: Any) -> ReplayOutcome:
    """What this request identity means against the accepted records.

    The caller is expected to already hold `request_critical_section(request_id)`
    for the whole operation. This never enters it.

    Reads only. Allocates no identity, writes nothing, and consults no ledger --
    the evidence it searches lives on the eight accepted record types.
    """
    identifier = validate_request_id(request_id)
    digest = validate_request_digest(request_digest)

    for kind in store.record_dirs:
        for record in store.list_records(kind):
            evidence = record.get("evidence")
            if not isinstance(evidence, Mapping):
                continue
            if not _same(evidence.get("request_id"), identifier):
                continue
            original = record.get(ID_FIELDS[kind])
            if _same(evidence.get("request_digest"), digest):
                return ReplayOutcome(REPLAY_EXACT, kind, original)
            # Same accepted request identity, different authoritative inputs.
            # Nothing is written and the original is left exactly as it is.
            return ReplayOutcome(REPLAY_CONFLICT, kind, original)

    # Named for a coordinating test, and a no-op in production.
    store._test_sync_point("after_replay_miss", identifier)
    return ReplayOutcome(REPLAY_NEW)
