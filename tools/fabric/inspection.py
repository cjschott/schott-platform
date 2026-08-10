"""Read-only inspection and validation of a Fabric store.

This is C8. It looks, and it reports. It opens a store for read, exposes what
C2 already found, and adds the handling C2 has no way to reach: a root that is
not there, a root that cannot be opened, a filter that names nothing.

**Not one byte, under any input.** An absent store is reported as absent rather
than built and then described. A malformed record is described rather than
mended. Temp residue is named as the evidence of an interrupted write and left
exactly where it lies -- inspection that tidies up what it finds destroys the
only account of what happened, and an operator arriving afterwards has nothing
to read.

**It replaces nothing.** C2 owns the findings and the counts; this exposes
them. A second copy of the validation rules here would drift from the first,
and two answers to "is this store sound" is one too many.

**Empty is not absent.** A store with no records is a valid store that has been
used for nothing; a store root that does not exist is a different fact, and an
operator needs to tell them apart before deciding what to do next.

Reports are deterministic: the eight accepted kinds in the order the model
declares them, records in identifier order within each, and findings in the
order C2 sorted them. Nothing here reads a clock, a source of chance, or the
order the filesystem happened to hand back.

See the accepted specification §4 C8 and §8 operations 11 and 12, and the
ENG-0002 read-only store contract this applies to the Fabric.
"""

from __future__ import annotations

from dataclasses import dataclass
import pathlib
from types import MappingProxyType
from typing import Any, Mapping

from .errors import FabricError
from .identifiers import ID_FIELDS, PATTERNS
from .models import RECORD_MODELS
from .store import FabricStore
from .validator import validate_store as validate_records

# The eight accepted kinds, in the order the model declares them. Written out
# there rather than discovered by scanning, so a report walks them in an order
# that is reviewed rather than incidental.
KIND_ORDER = tuple(RECORD_MODELS)

# What a report is. `reported` means the store was read and the report
# describes it -- including the store that turned out to be empty, which is a
# description and not a problem.
STATUS_REPORTED = "reported"
STATUS_ABSENT = "absent"
STATUS_UNREADABLE = "unreadable"
STATUS_NOT_FOUND = "not-found"
STATUS_INVALID = "invalid"

# Controlled reasons. Nothing here is derived from an exception: a message
# written for a log is not something a caller can depend on, and it can carry a
# path or a rejected value out of the boundary.
REASON_ABSENT = "store-root-absent"
REASON_UNREADABLE = "store-root-unreadable"
REASON_UNUSABLE_ROOT = "store-root-not-supplied"
REASON_UNKNOWN_KIND = "unknown-record-kind"
REASON_MALFORMED_IDENTITY = "malformed-record-identity"
REASON_NOT_FOUND = "record-not-found"

# One entry that could not be read is a finding, not a reason to abandon the
# rest: a single bad file hiding every record after it is the opposite of what
# looking at a store is for.
UNREADABLE_ENTRY = "could not be read"


@dataclass(frozen=True)
class StoreReport:
    """What validation found, and how much it looked at."""

    status: str
    root: str
    reason: str | None
    findings: tuple[str, ...]
    counts: Mapping[str, int]

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "root": self.root,
            "reason": self.reason,
            "findings": list(self.findings),
            "counts": dict(self.counts),
        }


@dataclass(frozen=True)
class RecordReport:
    """The records that matched, exactly as they are stored."""

    status: str
    root: str
    reason: str | None
    records: tuple[Mapping[str, Any], ...]
    findings: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "root": self.root,
            "reason": self.reason,
            "records": [dict(record) for record in self.records],
            "findings": list(self.findings),
        }


def _named(root: Any) -> str:
    """The root as the caller named it, for the report to echo back."""
    return "" if root is None else str(root)


def _opened(root: Any, expected_uid: Any, expected_gid: Any):
    """The store opened for read, or the reason it could not be.

    Absence is established before anything tries to open, so an absent root is
    reported as absent rather than as a failure to read something that was
    never there. `open_for_read` initialises nothing either way.
    """
    if root is None or not str(root).strip():
        return None, STATUS_INVALID, REASON_UNUSABLE_ROOT

    supplied = pathlib.Path(str(root)).expanduser()
    try:
        # Not `exists()`: that follows a link, and a link is a different fact
        # from a directory. The store refuses one; absence is the other.
        supplied.lstat()
    except OSError:
        return None, STATUS_ABSENT, REASON_ABSENT

    try:
        store = FabricStore.open_for_read(supplied, expected_uid=expected_uid,
                                          expected_gid=expected_gid)
    except Exception:  # noqa: BLE001
        # Deliberately broad and deliberately final: ownership, containment, a
        # link, a root inside a repository, or an unusable identity all mean
        # the same thing to a reader, and the message is not reported.
        return None, STATUS_UNREADABLE, REASON_UNREADABLE
    return store, STATUS_REPORTED, None


def validate_store(root: Any, *, expected_uid: Any,
                   expected_gid: Any) -> StoreReport:
    """Report what is structurally wrong in the store at this root.

    Repairs nothing, creates nothing, and returns the same report every time
    for the same store. What it adds to C2 is the answer for a root C2 can
    never be handed: one that is absent, or that cannot be opened at all.
    """
    store, status, reason = _opened(root, expected_uid, expected_gid)
    if store is None:
        return StoreReport(status, _named(root), reason, (),
                           MappingProxyType({}))
    try:
        report = validate_records(store)
    except Exception:  # noqa: BLE001
        return StoreReport(STATUS_UNREADABLE, _named(root), REASON_UNREADABLE,
                           (), MappingProxyType({}))
    # Counted in the declared order, and every kind present even at zero: a
    # kind missing from the counts would read as a kind nobody looked at.
    counts = {kind: report.counts.get(kind, 0) for kind in KIND_ORDER}
    return StoreReport(STATUS_REPORTED, _named(root), None,
                       tuple(report.findings), MappingProxyType(counts))


def inspect_records(root: Any, *, expected_uid: Any, expected_gid: Any,
                    kind: Any = None, identifier: Any = None) -> RecordReport:
    """The stored records that match, in a canonical order.

    Reports them as they are stored. Judging whether a record is sound is
    validation's question, asked separately, so a caller reading a damaged
    store still sees what is actually in it.
    """
    if kind is not None and kind not in RECORD_MODELS:
        return RecordReport(STATUS_INVALID, _named(root), REASON_UNKNOWN_KIND,
                            (), ())
    if identifier is not None:
        if kind is None:
            return RecordReport(STATUS_INVALID, _named(root),
                                REASON_UNKNOWN_KIND, (), ())
        if (not isinstance(identifier, str)
                or not PATTERNS[kind].fullmatch(identifier)):
            return RecordReport(STATUS_INVALID, _named(root),
                                REASON_MALFORMED_IDENTITY, (), ())

    store, status, reason = _opened(root, expected_uid, expected_gid)
    if store is None:
        return RecordReport(status, _named(root), reason, (), ())

    records: list[Mapping[str, Any]] = []
    findings: list[str] = []
    for walked in (KIND_ORDER if kind is None else (kind,)):
        field = ID_FIELDS[walked]
        try:
            entries = list(store.list_records(walked))
        except Exception:  # noqa: BLE001
            findings.append(f"{walked}: {UNREADABLE_ENTRY}")
            continue
        matched = [entry for entry in entries
                   if isinstance(entry, Mapping)
                   and isinstance(entry.get(field), str)
                   and (identifier is None or entry.get(field) == identifier)]
        # Sorted by the identity the record carries, never by the order the
        # directory was walked.
        records.extend(sorted(matched, key=lambda entry: entry[field]))

    if identifier is not None and not records:
        return RecordReport(STATUS_NOT_FOUND, _named(root), REASON_NOT_FOUND,
                            (), tuple(sorted(findings)))
    return RecordReport(STATUS_REPORTED, _named(root), None,
                        tuple(records), tuple(sorted(findings)))
