"""Reading the Capability Runtime's own records, and repairing none of them.

Read-only by contract. Inspection reports what is stored; validation reports
what disagrees. Neither reruns a decision, allocates an identity, or edits a
record — a validator that repairs is a validator whose findings you cannot
trust, because the evidence changed while it looked.

**A prepared invocation with no result is sound.** No execution was attempted,
so there is no result to persist. Only a *refused* invocation is required to
carry one, and a refused invocation missing it is evidence of interruption
rather than of a decision nobody made.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from .errors import CapabilityError
from .evidence import OUTCOME_PREPARED, OUTCOME_REFUSED
from .records import (INVOCATION_FIELDS, INVOCATION_KIND, RECORD_SCHEMA_VERSION,
                      RESULT_FIELDS, RESULT_KIND)

STATUS_REPORTED = "reported"
STATUS_NOT_FOUND = "not-found"
STATUS_UNREADABLE = "store-unreadable"

FINDING_MALFORMED = "record-malformed"
FINDING_IDENTITY = "record-identity-mismatch"
FINDING_INTERRUPTED_REFUSAL = "refusal-without-result"
FINDING_ORPHAN_RESULT = "result-without-invocation"
FINDING_OUTCOME_MISMATCH = "result-outcome-mismatch"
FINDING_DUPLICATE_IDENTITY = "duplicate-invocation-identity"
FINDING_RESIDUE = "partial-write-left-behind"

KIND_ORDER = (INVOCATION_KIND, RESULT_KIND)
_ID_FIELD = {INVOCATION_KIND: "invocation_record_id",
             RESULT_KIND: "capability_result_id"}
_FIELDS = {INVOCATION_KIND: INVOCATION_FIELDS, RESULT_KIND: RESULT_FIELDS}


@dataclass(frozen=True)
class Report:
    status: str
    findings: tuple[str, ...] = ()
    records: tuple[Mapping[str, Any], ...] = ()


def _shape(kind: str, record: Any) -> str | None:
    if not isinstance(record, Mapping):
        return FINDING_MALFORMED
    if set(record) != set(_FIELDS[kind]):
        return FINDING_MALFORMED
    if record.get("kind") != kind:
        return FINDING_MALFORMED
    if record.get("schema_version") != RECORD_SCHEMA_VERSION:
        return FINDING_MALFORMED
    identity = record.get(_ID_FIELD[kind])
    if not isinstance(identity, str) or not identity:
        return FINDING_IDENTITY
    return None


def inspect_records(store, *, kind: Any = None, identifier: Any = None) -> Report:
    """The stored records that match, in a canonical order.

    Reports them as they are stored. Whether they are sound is validation's
    question, asked separately, so a caller reading a damaged store still sees
    what is actually in it.
    """
    if kind is not None and kind not in KIND_ORDER:
        raise CapabilityError(f"unknown record kind '{kind}'")

    found: list[Mapping[str, Any]] = []
    for walked in (KIND_ORDER if kind is None else (kind,)):
        field = _ID_FIELD[walked]
        for record in store.list_records(walked):
            if not isinstance(record, Mapping):
                continue
            if identifier is not None and record.get(field) != identifier:
                continue
            found.append(record)
    found.sort(key=lambda entry: str(entry.get(_ID_FIELD[entry.get("kind", "")], "")))
    if identifier is not None and not found:
        return Report(STATUS_NOT_FOUND)
    return Report(STATUS_REPORTED, (), tuple(found))


def validate_store(store) -> Report:
    """Structural and relational problems, in deterministic order.

    Reports; repairs nothing, removes nothing, and rewrites nothing.
    """
    findings: list[str] = []
    invocations: dict[str, Mapping[str, Any]] = {}
    by_opaque: dict[str, list[str]] = {}

    for record in store.list_records(INVOCATION_KIND):
        problem = _shape(INVOCATION_KIND, record)
        if problem is not None:
            findings.append(f"{INVOCATION_KIND}: {problem}")
            continue
        identity = record["invocation_record_id"]
        invocations[identity] = record
        opaque = record.get("invocation_id")
        if isinstance(opaque, str):
            by_opaque.setdefault(opaque, []).append(identity)

    results: dict[str, list[Mapping[str, Any]]] = {}
    for record in store.list_records(RESULT_KIND):
        problem = _shape(RESULT_KIND, record)
        if problem is not None:
            findings.append(f"{RESULT_KIND}: {problem}")
            continue
        linked = record.get("invocation_record_id")
        if not isinstance(linked, str) or linked not in invocations:
            findings.append(
                f"{record['capability_result_id']}: {FINDING_ORPHAN_RESULT}")
            continue
        results.setdefault(linked, []).append(record)

    for identity, record in sorted(invocations.items()):
        evidence = record.get("evidence")
        outcome = evidence.get("outcome") if isinstance(evidence, Mapping) else None
        linked = results.get(identity, [])
        if outcome == OUTCOME_PREPARED:
            # Sound: no execution was attempted, so there is no result.
            if linked:
                findings.append(f"{identity}: {FINDING_OUTCOME_MISMATCH}")
        elif outcome == OUTCOME_REFUSED:
            if not linked:
                findings.append(f"{identity}: {FINDING_INTERRUPTED_REFUSAL}")
        else:
            findings.append(f"{identity}: {FINDING_MALFORMED}")

    for opaque, identities in sorted(by_opaque.items()):
        if len(identities) > 1:
            findings.append(f"{opaque}: {FINDING_DUPLICATE_IDENTITY}")

    for kind in KIND_ORDER:
        directory = store.root / store.record_dirs[kind]
        if directory.is_dir():
            for stray in sorted(directory.glob(".*.tmp")):
                findings.append(f"{stray.name}: {FINDING_RESIDUE}")

    return Report(STATUS_REPORTED, tuple(sorted(findings)))
