"""Normalization boundary between collection and evidence.

Normalization is deliberately separate from collection. A collector gathers
raw material in whatever shape its source produces; normalization decides what
is representable, rejects what is not, and produces a deterministic fingerprint.

Keeping them apart means a source-specific bug cannot smuggle an
unrepresentable or secret-bearing value into the evidence pipeline, and the
same normalization rules apply to every collector regardless of source.

This module writes no files, assigns no evidence identifier, and mutates no
canonical entity.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime
from typing import Any

from .models import SECRET_BEARING_KEYS, PERMITTED_SECRET_METADATA_KEYS, Observation

# Scalar types a fact value may take. Anything else — objects, callables,
# file handles — is rejected rather than coerced, because str() on an
# arbitrary object produces a plausible-looking value with no meaning.
SUPPORTED_TYPES = {
    str: "string",
    int: "integer",
    float: "float",
    bool: "boolean",
    type(None): "null",
}

UNKNOWN_SENTINEL = "unknown"


class NormalizationError(Exception):
    """A value or fact name could not be normalized.

    Messages name the offending key and never include its value.
    """


def _value_type(value: Any) -> str:
    # bool before int: bool is a subclass of int and would otherwise be typed
    # as integer.
    if isinstance(value, bool):
        return "boolean"
    for python_type, name in SUPPORTED_TYPES.items():
        if python_type is bool:
            continue
        if isinstance(value, python_type):
            return name
    if isinstance(value, (list, tuple)):
        return "list"
    if isinstance(value, dict):
        return "mapping"
    raise NormalizationError(
        f"unsupported value type '{type(value).__name__}' for a normalized fact"
    )


def _normalize_value(value: Any) -> Any:
    """Return a JSON-representable value with deterministic ordering."""
    if isinstance(value, bool) or value is None or isinstance(value, (str, int, float)):
        return value
    if isinstance(value, (list, tuple)):
        return [_normalize_value(item) for item in value]
    if isinstance(value, dict):
        # Sorted keys so the fingerprint does not depend on insertion order.
        return {str(k): _normalize_value(v) for k, v in sorted(value.items(), key=lambda kv: str(kv[0]))}
    raise NormalizationError(
        f"unsupported value type '{type(value).__name__}' for a normalized fact"
    )


def canonicalize_timestamp(value: Any) -> str:
    """Return an ISO 8601 timestamp, rejecting naive and relative values."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise NormalizationError("timestamp is missing timezone information")
        return value.isoformat()
    if not isinstance(value, str):
        raise NormalizationError("timestamp must be an ISO 8601 string")
    text = value.strip()
    if text.lower() in {"now", "today", "latest", "current", "recently"}:
        raise NormalizationError("relative time expressions are not valid timestamps")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise NormalizationError("timestamp is not valid ISO 8601") from error
    if parsed.tzinfo is None:
        raise NormalizationError("timestamp is missing timezone information")
    return parsed.isoformat()


def normalize_observations(
    facts: dict[str, Any],
    *,
    source: str,
    collected_at: str,
    sensitivity: str = "internal",
) -> list[Observation]:
    """Convert a flat mapping of facts into ordered Observations.

    Rejects secret-bearing fact names without echoing their values. Preserves
    an explicit `unknown` rather than dropping the fact: a missing key and a
    key known to be unknown are different facts.
    """
    if not isinstance(facts, dict):
        raise NormalizationError("facts must be a mapping of fact name to value")

    stamp = canonicalize_timestamp(collected_at)
    observations: list[Observation] = []

    # Sorted so output ordering is deterministic across runs and platforms.
    for name in sorted(facts, key=str):
        lowered = str(name).lower()
        if lowered in SECRET_BEARING_KEYS and lowered not in PERMITTED_SECRET_METADATA_KEYS:
            raise NormalizationError(
                f"fact name '{name}' is secret-bearing and must not be collected; "
                "record presence metadata instead (value withheld)"
            )

        raw = facts[name]
        value = UNKNOWN_SENTINEL if raw is UNKNOWN_SENTINEL else _normalize_value(raw)
        observations.append(
            Observation(
                fact=str(name),
                value=value,
                value_type=_value_type(raw),
                collected_at=stamp,
                source=source,
                sensitivity=sensitivity,
                redacted=False,
            )
        )

    return observations


def fingerprint_observations(observations: list[Observation]) -> str:
    """Return a sha256 fingerprint over normalized, redacted content.

    The fingerprint proves what was observed without republishing it. It is
    computed from normalized values only — raw source material is never
    fingerprinted, so a fingerprint can never be a hash of a secret.
    """
    payload = [
        {
            "fact": observation.fact,
            "value": observation.value,
            "value_type": observation.value_type,
            "collected_at": observation.collected_at,
        }
        for observation in sorted(observations, key=lambda item: item.fact)
    ]
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"
