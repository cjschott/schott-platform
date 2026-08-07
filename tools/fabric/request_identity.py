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
from dataclasses import dataclass
from typing import Any, NamedTuple

from .errors import FabricError
from .identifiers import ID_FIELDS
from .models import deep_freeze

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
    """What a request identity means against the records that already exist.

    `outcome` carries the original accepted result, deeply frozen. Returning a
    status and an identity alone would make the caller re-read the store to
    learn what was decided, which is not returning the original outcome.
    A conflict carries none: there is no original outcome to report.
    """

    status: str
    record_kind: str | None = None
    record_id: str | None = None
    outcome: Mapping[str, Any] | None = None


def _accepted_outcome(kind: str, record: Mapping[str, Any]) -> Mapping[str, Any]:
    """The original result, reconstructed from the record's own fields.

    A selection's outcome is not stored as a separate field -- it is readable
    from what the selection says. A chosen instance means selected; no chosen
    instance and no candidate considered means there was nothing to choose
    from; no chosen instance with candidates means every one was excluded.
    """
    identifier = record.get(ID_FIELDS[kind])
    if kind != "capability-selection":
        return deep_freeze({"outcome": "recorded", "record_id": identifier})

    chosen = record.get("selected_instance_id")
    considered = record.get("considered_candidates") or ()
    if chosen:
        name = "selected"
    elif not considered:
        name = "no-candidate"
    else:
        name = "refused"
    return deep_freeze({
        "outcome": name,
        "record_id": identifier,
        "selected_instance_id": chosen,
        "refusal_reason": record.get("refusal_reason"),
        "selection_reason": record.get("selection_reason"),
        "route_id": record.get("route_id"),
        "route_version": record.get("route_version"),
        "considered_candidates": tuple(considered),
    })


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


_INFINITY = float("inf")


def _require_canonical(value: Any) -> None:
    """Only values the released convention can represent deterministically."""
    if value is None or isinstance(value, (str, bool)):
        return
    if isinstance(value, int):
        return
    if isinstance(value, float):
        if value != value or value == _INFINITY or value == -_INFINITY:
            raise FabricError("authoritative inputs carry a non-finite number")
        return
    if isinstance(value, Mapping):
        for key, item in value.items():
            if not isinstance(key, str):
                raise FabricError("authoritative inputs carry a non-string mapping key")
            _require_canonical(item)
        return
    if isinstance(value, (list, tuple)):
        for item in value:
            _require_canonical(item)
        return
    # Named by type, never echoed: the value itself may be anything.
    raise FabricError(
        f"authoritative inputs carry an unsupported value of type '{type(value).__name__}'")


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

    for key in authoritative_inputs:
        if not isinstance(key, str):
            raise FabricError("authoritative inputs carry a non-string mapping key")

    canonical = _canonical_inputs(authoritative_inputs)
    _require_canonical(canonical)

    payload = {
        "canonicalisation": canonicalisation,
        "digest": digest,
        "operation": operation,
        "inputs": canonical,
    }
    try:
        # No `default=`: a value this encoder cannot represent must be refused,
        # not rendered. `str()` on an arbitrary object embeds its memory
        # address, so the same input would digest differently in one process
        # and across two, and a datetime would collide with its own text form.
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                             allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        raise FabricError(
            "authoritative inputs carry a value that cannot be canonicalised") from None
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
                return ReplayOutcome(REPLAY_EXACT, kind, original,
                                     _accepted_outcome(kind, record))
            # Same accepted request identity, different authoritative inputs.
            # Nothing is written, the original is left exactly as it is, and no
            # outcome is reported -- this request never had one.
            return ReplayOutcome(REPLAY_CONFLICT, kind, original)

    # Named for a coordinating test, and a no-op in production.
    store._test_sync_point("after_replay_miss", identifier)
    return ReplayOutcome(REPLAY_NEW)


# --- Prepare once, hash once -------------------------------------------------
#
# Everything above is the accepted convention and is unchanged. What follows is
# a separate, narrower route for the governed operations added later, and it is
# not a drop-in replacement for the helper above: it accepts less.
#
# **Caller content is visited exactly once.** `compute_request_digest` walks a
# caller's containers to validate them and again to encode them. A container
# that answers differently on the second walk would be hashed as something
# nobody validated, so here one visit validates and materialises at the same
# time, and the encoder only ever sees the materialised copy.
#
# **Ordering never runs `__str__` on a caller's object.** Unordered dimensions
# admit exact text only, so their order comes from the value itself. A subclass
# may carry a `__str__` that disagrees with the value encoded, and ordering by
# it would mean hashing one thing having ordered by another.

_PREPARATION = object()


@dataclass(frozen=True)
class _PreparedRequestDigestInput:
    """The exact bytes that will be hashed, and nothing else.

    It holds no caller-owned container, so nothing can change between
    preparation and hashing. The operation and both versions live *inside* the
    bytes, exactly as the accepted payload carries them, so there is no second
    copy of them able to disagree with what was encoded.

    Neither this type nor the token guarding it is a security boundary: code
    running in this process that reaches for private names can do anything at
    all, including replacing the hash. It is an accident guard, and it keeps
    canonical bytes off every supported signature.
    """

    _token: object
    _canonical_bytes: bytes

    def __post_init__(self) -> None:
        if self._token is not _PREPARATION:
            raise FabricError("a prepared request input is created only by preparation")
        if type(self._canonical_bytes) is not bytes:
            raise FabricError("a prepared request input carries no canonical bytes")


def _materialised(value: Any) -> Any:
    """One caller value, validated as it is copied, in a single visit.

    The accepted grammar decides what is representable; this decides only who
    owns the result afterwards, so the encoder never reaches a caller's
    container. Text, numbers, and `None` are immutable and are kept as they
    are; a mapping or a sequence becomes a plain one this module owns.
    """
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if value != value or value == _INFINITY or value == -_INFINITY:
            raise FabricError("authoritative inputs carry a non-finite number")
        return value
    if isinstance(value, dict):
        copied: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise FabricError("authoritative inputs carry a non-string mapping key")
            copied[key] = _materialised(item)
        return copied
    if isinstance(value, (list, tuple)):
        return [_materialised(item) for item in value]
    # Named by type, never echoed: the value itself may be anything.
    raise FabricError(
        f"authoritative inputs carry an unsupported value of type '{type(value).__name__}'")


def _materialised_inputs(inputs: Mapping[str, Any]) -> dict[str, Any]:
    """Authoritative inputs, owned here, with unordered sets ordered by value."""
    canonical: dict[str, Any] = {}
    for name in sorted(inputs):
        if name in EXCLUDED_INPUTS:
            continue
        value = inputs[name]
        if name in UNORDERED_INPUTS and isinstance(value, (list, tuple)):
            members: list[str] = []
            for member in value:
                if type(member) is not str:
                    raise FabricError(
                        "an unordered authoritative input carries a member of type "
                        f"'{type(member).__name__}'")
                members.append(member)
            # Ordered by the text itself. Nothing here calls `__str__`.
            canonical[name] = sorted(members)
        else:
            canonical[name] = _materialised(value)
    return canonical


def _prepare_request_digest_input(operation: Any, authoritative_inputs: Any, *,
                                  canonicalisation_version: str,
                                  digest_version: str) -> _PreparedRequestDigestInput:
    """Validate and encode in one pass. Allocates nothing and reads nothing."""
    if canonicalisation_version != SUPPORTED_CANONICALISATION:
        raise FabricError("unsupported canonicalisation version")
    if digest_version != SUPPORTED_DIGEST:
        raise FabricError("unsupported digest version")
    if not isinstance(operation, str) or not operation.strip():
        raise FabricError("an operation type is required")
    if not isinstance(authoritative_inputs, Mapping):
        raise FabricError("authoritative inputs must be a mapping")
    for key in authoritative_inputs:
        if not isinstance(key, str):
            raise FabricError("authoritative inputs carry a non-string mapping key")

    payload = {
        "canonicalisation": canonicalisation_version,
        "digest": digest_version,
        "operation": operation,
        "inputs": _materialised_inputs(authoritative_inputs),
    }
    try:
        # The same encoder the accepted convention uses, over a payload this
        # module built. No `default=`: a value it cannot represent is refused.
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                             allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        raise FabricError(
            "authoritative inputs carry a value that cannot be canonicalised") from None
    return _PreparedRequestDigestInput(_PREPARATION, encoded)


def _hash_prepared_request_digest(prepared: Any) -> str:
    """`sha256:` over bytes already prepared. No caller value is examined.

    The provenance checks are exact rather than permissive: a subclass is a
    different type, and an object that merely looks prepared is refused rather
    than hashed. These paths are unreachable from the operation boundary, which
    hashes only what it just prepared; they exist so misuse is loud.
    """
    if type(prepared) is not _PreparedRequestDigestInput:
        raise FabricError("a prepared request input is required")
    if prepared._token is not _PREPARATION:
        raise FabricError("a prepared request input is created only by preparation")
    if type(prepared._canonical_bytes) is not bytes:
        raise FabricError("a prepared request input carries no canonical bytes")
    return f"sha256:{hashlib.sha256(prepared._canonical_bytes).hexdigest()}"


def prepare_and_compute_request_digest(
        operation: Any, authoritative_inputs: Any, *,
        canonicalisation_version: str = SUPPORTED_CANONICALISATION,
        digest_version: str = SUPPORTED_DIGEST) -> str:
    """Prepare, then hash. Takes authoritative inputs and never takes bytes.

    The prepared representation never leaves this module, so nothing outside it
    can supply or alter what gets hashed, and hashing cannot begin until
    preparation has completed. Anything a caller's container raises on the way
    is named as uncanonicalisable content rather than propagated: an internal
    fault is indistinguishable from a hostile one here, and the ambiguous case
    must fail closed rather than be reported as success.
    """
    try:
        prepared = _prepare_request_digest_input(
            operation, authoritative_inputs,
            canonicalisation_version=canonicalisation_version,
            digest_version=digest_version)
        return _hash_prepared_request_digest(prepared)
    except FabricError:
        raise
    except Exception:  # noqa: BLE001
        raise FabricError(
            "authoritative inputs could not be canonicalised") from None
