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
                      RESULT_FIELDS, RESULT_KIND,
                      INVOCATION_SCHEMA_VERSION, RESULT_SCHEMA_VERSION)
OUTCOME_CLASS_REFUSED = "refused"
from .execution.profile import ADAPTER_IDENTITY

STATUS_REPORTED = "reported"
STATUS_NOT_FOUND = "not-found"
STATUS_UNREADABLE = "store-unreadable"

FINDING_MALFORMED = "record-malformed"
FINDING_IDENTITY = "record-identity-mismatch"
FINDING_INTERRUPTED_REFUSAL = "refusal-without-result"
FINDING_ORPHAN_RESULT = "result-without-invocation"
FINDING_OUTCOME_MISMATCH = "result-outcome-mismatch"
# Execution authority was durably bound and no terminal outcome became durable.
# Design section 17: observable residue, never cleaned, never repaired. Named
# distinctly from the refusal case because they mean different things -- one is
# an execution nobody can account for, the other a decision that was never
# written down.
FINDING_INTERRUPTED_EXECUTION = "execution-interrupted"
# A result exists for an invocation that never authorised an execution.
FINDING_RESULT_WITHOUT_AUTHORITY = "result-without-execution-authority"
FINDING_DUPLICATE_IDENTITY = "duplicate-invocation-identity"
FINDING_RESIDUE = "partial-write-left-behind"

KIND_ORDER = (INVOCATION_KIND, RESULT_KIND)
_ID_FIELD = {INVOCATION_KIND: "invocation_record_id",
             RESULT_KIND: "capability_result_id"}
_FIELDS = {INVOCATION_KIND: INVOCATION_FIELDS, RESULT_KIND: RESULT_FIELDS}
_SCHEMA_VERSION = {INVOCATION_KIND: INVOCATION_SCHEMA_VERSION,
                   RESULT_KIND: RESULT_SCHEMA_VERSION}


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
    # Per kind, since G11-AN. The invocation record did not change and keeps
    # version 1; the result record gained the section 15 fields and is version
    # 2. One shared constant would have made a correct record of either kind
    # look malformed the moment the other moved.
    if record.get("schema_version") != _SCHEMA_VERSION[kind]:
        return FINDING_MALFORMED
    # A stored invocation may name only the governed execution mechanism, or
    # none. A record claiming a mechanism this build does not govern is not a
    # record whose meaning anybody reviewed.
    if kind == INVOCATION_KIND:
        bound = record.get("adapter_identity")
        if bound is not None and bound != ADAPTER_IDENTITY:
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
        # The execution mechanism this invocation durably bound, if any. A
        # record written before the field existed carries nothing, and nothing
        # is inferred from that: see the v1 branch below.
        adapter_identity = record.get("adapter_identity")
        legacy = record.get("schema_version") != INVOCATION_SCHEMA_VERSION

        if outcome == OUTCOME_PREPARED:
            # A prepared invocation WITH a terminal result is the ordinary
            # successful shape now that G6 is open: CINV is the immutable
            # pre-execution attempt record and stays `execution-prepared`,
            # while what the execution did lives in the CRES. Reporting that
            # pairing as a mismatch was correct only while nothing could
            # execute.
            #
            # A prepared invocation with NO result is deliberately still not
            # reported. Design section 17 calls that interrupted, but this
            # record cannot yet tell "execution was attempted and left no
            # result" from "no adapter was ever authorised, so nothing was
            # attempted" -- both write `execution-prepared` and nothing else.
            # Section 14 names an `adapter_identity` field on the invocation
            # record that would separate them; the implementation does not
            # carry it. Reporting every prepared invocation as interrupted
            # would relabel records that were never attempted, and guessing
            # from a clock is exactly what the doctrine forbids. See the
            # G11-AN report: this is the checkpoint's stop.
            #
            # What IS still a mismatch: a refusal result filed under a prepared
            # invocation, which is two records disagreeing about whether
            # anything was attempted, and more than one terminal result for a
            # single attempt.
            if len(linked) > 1:
                findings.append(f"{identity}: {FINDING_OUTCOME_MISMATCH}")
            elif any(entry.get("outcome_class") == OUTCOME_CLASS_REFUSED
                     for entry in linked):
                findings.append(f"{identity}: {FINDING_OUTCOME_MISMATCH}")
            elif linked and adapter_identity is None and not legacy:
                # A terminal result for an execution nobody authorised.
                findings.append(
                    f"{identity}: {FINDING_RESULT_WITHOUT_AUTHORITY}")
            elif not linked and adapter_identity is not None:
                # Section 17's case, now separable. Authority was bound and no
                # outcome is durable, so the adapter cannot be shown not to
                # have acted. Reported, never repaired, never replayed.
                findings.append(
                    f"{identity}: {FINDING_INTERRUPTED_EXECUTION}")
            # Prepared, nothing authorised, no result: sound. Nothing was
            # attempted, and a v1 record -- written before the field existed --
            # falls here too rather than being read as evidence of an attempt
            # it never recorded.
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
