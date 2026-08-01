"""Convert a CollectorResult into an immutable EvidenceRecord.

Two properties matter here more than anything else.

First, the input is never mutated. A collector result that came back changed
from orchestration would mean the observation and the record of it had drifted
apart, and no later reader could tell which was original.

Second, redaction runs again. The collectors already redact, and this layer
redacts anyway: defence in depth costs one function call, and the alternative
is that a single collector bug writes a credential into an immutable record
that by design can never be edited.

The identifier is allocated by the caller and passed in, and only after
validation has succeeded — a rejected observation must not consume a sequence
number it will never use.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from tools.collectors.models import CollectorResult
from tools.collectors.redaction import redact, redact_text

from .models import Observation, EvidenceRecord, Provenance, require_timezone


class BuilderError(Exception):
    """An observation could not be built. Never contains a flagged value."""


def _canonical(payload: Any) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)


def fingerprint(facts: dict[str, Any], *, collector_id: str, status: str,
                errors: tuple[dict[str, Any], ...] = ()) -> str:
    """Return a deterministic sha256 over redacted, normalized content.

    Errors participate only after redaction, and status participates at all,
    so a failed collection can never fingerprint-match a successful one that
    happened to report the same facts.
    """
    payload = {
        "collector_id": collector_id,
        "status": status,
        "facts": facts,
        "errors": [dict(sorted(e.items())) for e in errors],
    }
    encoded = _canonical(payload).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def build_observation(result: CollectorResult) -> Observation:
    """Validate, redact, and normalize a collector result.

    Returns a new object; `result` is left exactly as it was passed in.
    """
    if not isinstance(result, CollectorResult):
        raise BuilderError("expected a CollectorResult")
    if not result.target:
        raise BuilderError("collector result has no target")
    if not result.collector_id:
        raise BuilderError("collector result has no collector_id")

    collected_at = require_timezone(result.completed_at or result.started_at, "collected_at")

    # Build a fresh facts mapping rather than reaching into the result's
    # observation objects, so nothing in the source is touched.
    raw_facts: dict[str, Any] = {}
    for observation in result.observations:
        raw_facts[str(observation.fact)] = observation.value

    try:
        facts, _ = redact(raw_facts)
    except Exception as error:  # noqa: BLE001 - message must not carry the value
        raise BuilderError(f"facts could not be safely redacted: {type(error).__name__}") from error

    errors: list[dict[str, Any]] = []
    for entry in result.errors:
        summary, _ = redact_text(str(getattr(entry, "summary", "")))
        errors.append({
            "category": str(getattr(entry, "category", "internal")),
            "summary": summary,
            "retryable": bool(getattr(entry, "retryable", False)),
        })

    observation = Observation(
        collector_id=str(result.collector_id),
        target=str(result.target),
        collected_at=collected_at,
        status=str(result.status),
        facts=facts,
        errors=tuple(errors),
        source_fingerprint=fingerprint(facts, collector_id=str(result.collector_id),
                                       status=str(result.status), errors=tuple(errors)),
        provenance=Provenance.OBSERVED.value,
    )

    problems = observation.validation_errors()
    if problems:
        raise BuilderError("; ".join(problems))
    return observation


def build_evidence_record(observation: Observation, *, evidence_id: str,
                          persisted_at: str, supersedes: str | None = None,
                          sensitivity: str = "internal") -> EvidenceRecord:
    """Wrap a validated observation as an immutable record.

    The record keeps the collection status verbatim. A failed collection still
    produces evidence — evidence that the platform could not look, which is a
    fact worth recording and is not a claim about the target's health.
    """
    if not isinstance(observation, Observation):
        raise BuilderError("expected an Observation")

    return EvidenceRecord(
        id=evidence_id,
        target=observation.target,
        collector=observation.collector_id,
        collected_at=observation.collected_at,
        persisted_at=require_timezone(persisted_at, "persisted_at"),
        status=observation.status,
        facts=dict(observation.facts),
        errors=tuple(observation.errors),
        content_fingerprint=observation.source_fingerprint,
        sensitivity=sensitivity,
        redaction="applied",
        provenance=Provenance.OBSERVED.value,
        supersedes=supersedes,
    )
