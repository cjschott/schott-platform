"""Reconstruct a disposable digital twin from current knowledge.

A twin is a working representation of what the platform believes right now. It
is rebuilt entirely from knowledge, never edited directly, and thrown away.

Disposability is the design, not a limitation. If a twin is always rebuilt
from immutable inputs, then a reconstruction bug is a bug in code that a rerun
fixes, rather than corrupted state somebody has to repair by hand. That is the
same reasoning ADR-0004 applies to knowledge state, applied one layer up.

The rebuild is deterministic: identical knowledge and an identical identifier
produce a byte-identical twin. Without that, comparing a twin to a snapshot
would measure the reconstruction as much as the platform.
"""

from __future__ import annotations

from typing import Any

from .models import (
    ID_PATTERNS,
    SNAPSHOT_SCHEMA_VERSION,
    DigitalTwin,
    readonly_facts,
    require_timezone,
)
from .snapshot_manager import facts_from_evidence, fingerprint_facts


class TwinError(Exception):
    """A twin could not be reconstructed. Never contains a flagged value."""


def build_twin(knowledge, evidence_store, *, twin_id: str, built_at: str) -> DigitalTwin:
    """Reconstruct a twin for the knowledge state's target.

    Reads knowledge and the evidence it cites; writes nothing. The twin is
    returned rather than stored, because a twin that outlives the moment it
    describes is no longer a reconstruction of current knowledge.
    """
    if knowledge is None:
        raise TwinError("a knowledge state is required to build a twin")
    if evidence_store is None:
        raise TwinError("an evidence store is required to resolve knowledge facts")

    pattern = ID_PATTERNS["twin"]
    if not pattern.match(str(twin_id)):
        raise TwinError(f"twin identifier '{twin_id}' is not valid")

    stamp = require_timezone(built_at, "built_at")

    target = str(getattr(knowledge, "target", "") or "")
    if not target:
        raise TwinError("knowledge state has no target")

    # Exactly the same resolution a snapshot uses. Comparing a twin built one
    # way against a snapshot built another would measure the difference between
    # the two builders, not the difference between two states.
    facts: dict[str, Any] = facts_from_evidence(evidence_store, target, knowledge)

    confidence = getattr(knowledge, "confidence", None)
    overall = getattr(confidence, "overall", None) if confidence is not None else None

    return DigitalTwin(
        id=twin_id,
        target=target,
        built_at=stamp,
        facts=readonly_facts(facts),
        content_fingerprint=fingerprint_facts(
            facts, target=target, schema_version=SNAPSHOT_SCHEMA_VERSION),
        source_knowledge_target=target,
        source_knowledge_generated_at=getattr(knowledge, "generated_at", None),
        supporting_evidence=tuple(getattr(knowledge, "supporting_evidence", ()) or ()),
        knowledge_confidence=round(overall, 4) if isinstance(overall, (int, float)) else None,
        knowledge_freshness=str(getattr(knowledge, "freshness", "unknown")),
        disposable=True,
    )
