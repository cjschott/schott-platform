"""Lineage resolution and validation.

A lineage is one subject's chain of decisions, terminating at exactly one
Operator Root Authority. Lineage records are append-only: advancing a lineage
writes a new version rather than editing the previous one, so the head is
whichever version is highest and every earlier state stays byte-identical.

That is why there is no "update lineage" function anywhere in this package.
The head is derived, not maintained.
"""

from __future__ import annotations

from typing import Any

from .errors import TrustError
from .transitions import TERMINAL


def lineage_versions(store, lineage_id: str) -> list[dict[str, Any]]:
    """Every version of one lineage, oldest first."""
    versions = [record for record in store.all_records("lineage")
                if record.get("lineage_id") == lineage_id]
    return sorted(versions, key=lambda record: int(record.get("version", 0)))


def lineage_head(store, lineage_id: str) -> dict[str, Any] | None:
    """The newest version of a lineage, or None when it does not exist."""
    versions = lineage_versions(store, lineage_id)
    return versions[-1] if versions else None


def subject_lineages(store, subject_id: str) -> list[dict[str, Any]]:
    """Every lineage head for a subject, oldest first.

    A subject has more than one lineage only after revocation or rejection,
    where later approval must start a new chain.
    """
    heads: dict[str, dict[str, Any]] = {}
    for record in store.all_records("lineage"):
        if record.get("subject_id") != subject_id:
            continue
        identifier = str(record.get("lineage_id"))
        current = heads.get(identifier)
        if current is None or int(record.get("version", 0)) > int(current.get("version", 0)):
            heads[identifier] = record
    return sorted(heads.values(), key=lambda record: str(record.get("created_at", "")))


def current_lineage(store, subject_id: str) -> dict[str, Any] | None:
    """The lineage that governs a subject now.

    The newest non-terminated lineage wins. When every lineage is terminated,
    the newest one is returned so the answer explains the termination rather
    than reporting the subject as unknown.
    """
    heads = subject_lineages(store, subject_id)
    if not heads:
        return None
    live = [head for head in heads if not head.get("terminated")]
    return (live or heads)[-1]


def validate_advance(store, head: dict[str, Any], subject_id: str,
                     subject_type: str) -> None:
    """Refuse an advance that would corrupt a lineage.

    Each of these is a way a chain could stop meaning what it says: a decision
    landing in someone else's lineage, a subject silently changing identity
    mid-chain, or a terminated lineage quietly coming back to life.
    """
    if head.get("subject_id") != subject_id:
        raise TrustError(
            f"decision subject '{subject_id}' does not match lineage subject "
            f"'{head.get('subject_id')}'; decisions cannot cross lineages"
        )
    if head.get("subject_type") != subject_type:
        raise TrustError(
            "a subject's type cannot change inside a lineage; a different kind of "
            "subject is a different subject"
        )
    if head.get("terminated"):
        raise TrustError(
            f"lineage '{head.get('lineage_id')}' is terminated ("
            f"{head.get('current_state')}); later approval requires a new lineage "
            "referencing this history"
        )
    if head.get("current_state") in TERMINAL:
        raise TrustError(
            f"lineage '{head.get('lineage_id')}' ended in "
            f"'{head.get('current_state')}' and cannot be advanced"
        )


def validate_supersession(store, decision_id: str, supersedes: str | None) -> None:
    """Refuse self-supersession and dangling or circular chains."""
    if supersedes is None:
        return
    if supersedes == decision_id:
        raise TrustError("a decision cannot supersede itself")

    seen = {decision_id}
    cursor = supersedes
    while cursor is not None:
        if cursor in seen:
            raise TrustError("supersession chain is circular")
        seen.add(cursor)
        try:
            record = store.read("decision", cursor)
        except Exception:
            raise TrustError(
                f"decision '{cursor}' referenced by supersedes does not exist") from None
        cursor = record.get("supersedes")
