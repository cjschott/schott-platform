"""Read-only consumption of canonical CIMP/CGEN provisioning authority.

**This module validates; it never provisions.** It allocates no identifier,
admits no image, retires nothing, repairs nothing, and writes nothing. Its only
output is validated data describing which implementations are eligible for new
authorisation — deciding to execute is somebody else's job.

**Integrity is global, and deliberately unforgiving.** An unsound provisioning
namespace yields no authorisation at all: there is no partial-good-subset, no
per-CIMP ignore, and no salvage mode. A namespace that cannot be fully
substantiated is one whose contents nobody can vouch for, and vouching for the
readable half of it would be exactly the wrong instinct.

**The manifest is not authority.** Every authority-set entry must be
substantiated by the underlying immutable records, by exact digest. A manifest
that lists a CIMP no record supports, or omits one that exists on disk, is a
disagreement about what was admitted — and a disagreement is a refusal.

**The root is a descriptor, never a pathname.** The caller establishes the
trusted root and hands it over; every enumeration and read below is
descriptor-relative with ``O_NOFOLLOW``, so replacing the root path mid-flight
cannot redirect a validation already under way.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §5.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
from typing import Any

from . import canonical_json
from .types import Classification

MAXIMUM_SCAN_ENTRIES = 10_000
MAXIMUM_SUMMARY_BYTES = 2 * 1024 * 1024
MAXIMUM_RECORD_BYTES = 2 * 1024 * 1024
MAXIMUM_AUTHORITY_SET_ENTRIES = 10_000

GENESIS_CGEN = "CGEN-000000000000"

_IMPLEMENTATIONS = "implementations"
_GENERATIONS = "generations"
_CURRENT_GENERATION = "current-generation"
_ADMISSION = "admission"
_RETIREMENT = "retirement"
_AUTHORITY_SET = "authority-set"
_GENERATION = "generation"

_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY


class ImplementationAuthorityError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class IntegrityFailure(ImplementationAuthorityError):
    """The canonical namespace cannot be fully substantiated.

    Carries how many entries were scanned so a caller can tell a small
    corruption from a namespace that was still being walked when it failed.
    """

    classification = Classification.IMPLEMENTATION_AUTHORITY_INTEGRITY_FAILURE

    def __init__(self, message: str, *, entries_scanned: int = 0) -> None:
        super().__init__(message)
        self.entries_scanned = entries_scanned


class ScanLimitExceeded(IntegrityFailure):
    """More directory entries than the ceiling permits.

    A subclass of integrity failure because the specification says it implies
    one: a namespace too large to bound is a namespace nobody has validated.
    """

    classification = Classification.IMPLEMENTATION_AUTHORITY_SCAN_LIMIT_EXCEEDED


class FindingsTruncated(IntegrityFailure):
    """More integrity findings than the summary bound permits."""

    classification = Classification.IMPLEMENTATION_AUTHORITY_FINDINGS_TRUNCATED


class RetiredImplementation(ImplementationAuthorityError):
    """Valid, permanently retired, and therefore not bindable.

    Deliberately not an integrity failure and deliberately carrying no
    classification: retirement is correct provisioning state, not corruption.
    """


class UnknownImplementation(ImplementationAuthorityError):
    """No such CIMP in the validated authority set."""


@dataclasses.dataclass(frozen=True)
class Admission:
    """One immutable implementation contract, as admitted."""

    cimp: str
    # The immutable local image ID -- Podman `image inspect .Id` -- as bare
    # lowercase hex with no algorithm prefix. Deliberately not a manifest
    # digest: `.Digest`, `.RepoDigests`, and a container's `.ImageDigest` all
    # describe how an image arrived rather than what it contains, are absent
    # for a locally built image, and all arrive `sha256:`-prefixed. Requiring
    # the bare form therefore makes every one of them structurally
    # unrepresentable here rather than merely discouraged.
    oci_image_id: str
    adapter_identity: str
    payload_schema_version: int
    execution_profile_schema_version: int
    argv_contract_identity: str
    provisioning_evidence_digest: str


@dataclasses.dataclass(frozen=True)
class AuthoritySetEntry:
    """One authority-set row, substantiated against the underlying records."""

    cimp: str
    admission_digest: str
    retirement_digest: str | None


@dataclasses.dataclass(frozen=True)
class Generation:
    """A validated snapshot of one published generation.

    Never independent authority. It records the exact `CGEN` and
    generation-record digest it was derived from precisely so a caller can
    revalidate against canonical `current-generation` at the authorisation
    boundary, and discard the whole snapshot on any mismatch.
    """

    cgen: str
    generation_digest: str
    authority_set_digest: str
    predecessor_cgen: str | None
    predecessor_generation_digest: str | None
    entries: tuple[AuthoritySetEntry, ...]
    eligible_cimps: tuple[str, ...]


class _Scan:
    """The bounded budget shared by one validation.

    Entries and findings are counted together because both ceilings protect the
    same thing: a validation that cannot finish within known bounds has not
    validated anything.
    """

    def __init__(self) -> None:
        self.entries = 0
        self.findings: list[str] = []
        self.findings_bytes = 0

    def count(self) -> None:
        self.entries += 1
        if self.entries > MAXIMUM_SCAN_ENTRIES:
            raise ScanLimitExceeded(
                f"more than {MAXIMUM_SCAN_ENTRIES} directory entries",
                entries_scanned=self.entries)

    def find(self, message: str) -> None:
        self.findings.append(message)
        self.findings_bytes += len(message.encode("utf-8")) + 1
        if self.findings_bytes > MAXIMUM_SUMMARY_BYTES:
            raise FindingsTruncated(
                f"integrity summary exceeded {MAXIMUM_SUMMARY_BYTES} bytes",
                entries_scanned=self.entries)

    def settle(self) -> None:
        if self.findings:
            raise IntegrityFailure(
                "; ".join(self.findings[:16]), entries_scanned=self.entries)


def _is_cimp(name: str) -> bool:
    return (len(name) == 11 and name.startswith("CIMP-")
            and set(name[5:]) <= _DIGITS)


def _is_cgen(name: str) -> bool:
    return (len(name) == 17 and name.startswith("CGEN-")
            and set(name[5:]) <= _DIGITS)


def _is_digest(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and set(value) <= _HEX


def _open_dir(name: str, dir_fd: int) -> int:
    return os.open(name, _DIR_FLAGS, dir_fd=dir_fd)


def _read_record(name: str, dir_fd: int) -> bytes:
    """One canonical regular file, read no-follow and bounded.

    ``O_NOFOLLOW`` refuses a symlink at open time rather than after resolving
    it, so a replaced record is never read even once.
    """
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise IntegrityFailure(f"{name} is not a regular file")
        chunks: list[bytes] = []
        remaining = MAXIMUM_RECORD_BYTES + 1
        while remaining > 0:
            chunk = os.read(handle, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(handle)
    body = b"".join(chunks)
    if len(body) > MAXIMUM_RECORD_BYTES:
        raise IntegrityFailure(f"{name} exceeds {MAXIMUM_RECORD_BYTES} bytes")
    return body


def _parse(body: bytes, what: str) -> dict[str, Any]:
    try:
        return canonical_json.parse(body, maximum_bytes=MAXIMUM_RECORD_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise IntegrityFailure(f"{what} is not canonical: {error}") from None


def _closed(document: dict[str, Any], fields: dict[str, Any], what: str) -> None:
    for name in document:
        if name not in fields:
            raise IntegrityFailure(f"{what} carries unknown field {name!r}")
    for name, kind in fields.items():
        if name not in document:
            raise IntegrityFailure(f"{what} is missing {name!r}")
        value = document[name]
        optional = isinstance(kind, tuple) and type(None) in kind
        if value is None and optional:
            continue
        expected = kind[0] if isinstance(kind, tuple) else kind
        if expected is int and isinstance(value, bool):
            raise IntegrityFailure(f"{what} field {name!r} must be an integer")
        if not isinstance(value, expected):
            raise IntegrityFailure(f"{what} field {name!r} has the wrong type")


def _admission(body: bytes, cimp: str) -> Admission:
    document = _parse(body, f"{cimp} admission")
    _closed(document, {
        "cimp": str,
        "oci_image_id": str,
        "adapter_identity": str,
        "payload_schema_version": int,
        "execution_profile_schema_version": int,
        "argv_contract_identity": str,
        "provisioning_evidence_digest": str,
    }, f"{cimp} admission")
    if document["cimp"] != cimp:
        raise IntegrityFailure(
            f"admission at {cimp} declares {document['cimp']!r}")
    if not _is_digest(document["oci_image_id"]):
        raise IntegrityFailure(
            f"{cimp} admission has a malformed local image ID")
    if not _is_digest(document["provisioning_evidence_digest"]):
        raise IntegrityFailure(
            f"{cimp} admission has a malformed evidence commitment")
    return Admission(
        cimp=cimp,
        oci_image_id=document["oci_image_id"],
        adapter_identity=document["adapter_identity"],
        payload_schema_version=document["payload_schema_version"],
        execution_profile_schema_version=document[
            "execution_profile_schema_version"],
        argv_contract_identity=document["argv_contract_identity"],
        provisioning_evidence_digest=document["provisioning_evidence_digest"],
    )


def _retirement(body: bytes, cimp: str) -> None:
    document = _parse(body, f"{cimp} retirement")
    _closed(document, {"cimp": str}, f"{cimp} retirement")
    if document["cimp"] != cimp:
        raise IntegrityFailure(
            f"retirement at {cimp} declares {document['cimp']!r}")


def _scan_implementations(root_fd: int, scan: _Scan) -> dict[str, dict[str, bytes]]:
    """Every CIMP directory and its records, with everything else recorded.

    Every entry counts against the ceiling, parsed or not: a namespace full of
    junk is exactly the case a ceiling that only counted valid records would
    miss.
    """
    found: dict[str, dict[str, bytes]] = {}
    try:
        base = _open_dir(_IMPLEMENTATIONS, root_fd)
    except OSError as error:
        raise IntegrityFailure(
            f"{_IMPLEMENTATIONS} is unreadable: {error}") from None
    try:
        with os.scandir(base) as entries:
            for entry in entries:
                scan.count()
                if entry.is_symlink():
                    scan.find(f"{_IMPLEMENTATIONS}/{entry.name} is a symlink")
                    continue
                if not entry.is_dir(follow_symlinks=False):
                    scan.find(f"{_IMPLEMENTATIONS}/{entry.name} is not a directory")
                    continue
                if not _is_cimp(entry.name):
                    scan.find(f"{_IMPLEMENTATIONS}/{entry.name} is not a CIMP")
                    continue
                found[entry.name] = _scan_one(base, entry.name, scan)
    finally:
        os.close(base)
    return found


def _scan_one(base_fd: int, cimp: str, scan: _Scan) -> dict[str, bytes]:
    records: dict[str, bytes] = {}
    handle = _open_dir(cimp, base_fd)
    try:
        with os.scandir(handle) as entries:
            for entry in entries:
                scan.count()
                if entry.is_symlink():
                    scan.find(f"{cimp}/{entry.name} is a symlink")
                    continue
                if entry.name not in (_ADMISSION, _RETIREMENT):
                    scan.find(f"{cimp}/{entry.name} is unexpected")
                    continue
                if not entry.is_file(follow_symlinks=False):
                    scan.find(f"{cimp}/{entry.name} is not a regular file")
                    continue
                records[entry.name] = _read_record(entry.name, handle)
    finally:
        os.close(handle)
    if _ADMISSION not in records:
        scan.find(f"{cimp} has no admission record")
    return records


def _authority_set(body: bytes) -> tuple[AuthoritySetEntry, ...]:
    document = _parse(body, "authority-set")
    _closed(document, {"entries": list}, "authority-set")
    rows = document["entries"]
    if len(rows) > MAXIMUM_AUTHORITY_SET_ENTRIES:
        raise IntegrityFailure(
            f"authority-set exceeds {MAXIMUM_AUTHORITY_SET_ENTRIES} entries")
    entries: list[AuthoritySetEntry] = []
    previous = -1
    for row in rows:
        if not isinstance(row, dict):
            raise IntegrityFailure("authority-set entry is not an object")
        _closed(row, {
            "cimp": str,
            "admission": str,
            "retirement": (str, type(None)),
        }, "authority-set entry")
        cimp = row["cimp"]
        if not _is_cimp(cimp):
            raise IntegrityFailure(f"authority-set names {cimp!r}")
        ordinal = int(cimp[5:])
        if ordinal <= previous:
            raise IntegrityFailure(
                "authority-set is not ordered by numeric CIMP, or repeats one")
        previous = ordinal
        if not _is_digest(row["admission"]):
            raise IntegrityFailure(f"{cimp} admission digest is malformed")
        retirement = row["retirement"]
        if retirement is not None and not _is_digest(retirement):
            raise IntegrityFailure(f"{cimp} retirement digest is malformed")
        entries.append(AuthoritySetEntry(
            cimp=cimp, admission_digest=row["admission"],
            retirement_digest=retirement))
    return tuple(entries)


def current_generation(root_fd: int) -> Generation:
    """Validate the published generation under ``root_fd`` and snapshot it.

    Every record is read through the descriptor, every digest is checked
    against the bytes actually on disk, and every authority-set row is
    substantiated by the underlying records. Anything short of complete
    agreement raises rather than returning a partial view.
    """
    scan = _Scan()

    pointer = _parse(_read_record(_CURRENT_GENERATION, root_fd),
                     _CURRENT_GENERATION)
    _closed(pointer, {"cgen": str, "generation_digest": str},
            _CURRENT_GENERATION)
    cgen = pointer["cgen"]
    if not _is_cgen(cgen):
        raise IntegrityFailure(f"current-generation names {cgen!r}")
    if not _is_digest(pointer["generation_digest"]):
        raise IntegrityFailure("current-generation digest is malformed")

    generations = _open_dir(_GENERATIONS, root_fd)
    try:
        published = _open_dir(cgen, generations)
        try:
            generation_body = _read_record(_GENERATION, published)
            authority_body = _read_record(_AUTHORITY_SET, published)
        finally:
            os.close(published)
    except OSError as error:
        raise IntegrityFailure(f"generation {cgen} is unreadable: {error}") from None
    finally:
        os.close(generations)

    generation_digest = hashlib.sha256(generation_body).hexdigest()
    if generation_digest != pointer["generation_digest"]:
        raise IntegrityFailure(
            "generation record does not match the current-generation digest")

    record = _parse(generation_body, "generation")
    _closed(record, {
        "cgen": str,
        "predecessor_cgen": (str, type(None)),
        "predecessor_generation_digest": (str, type(None)),
        "authority_set_digest": str,
    }, "generation")
    if record["cgen"] != cgen:
        raise IntegrityFailure(
            f"generation at {cgen} declares {record['cgen']!r}")

    predecessor = record["predecessor_cgen"]
    predecessor_digest = record["predecessor_generation_digest"]
    if cgen == GENESIS_CGEN:
        if predecessor is not None or predecessor_digest is not None:
            raise IntegrityFailure("genesis carries a predecessor")
    else:
        if predecessor is None or predecessor_digest is None:
            raise IntegrityFailure(
                f"{cgen} is not genesis but carries no predecessor")
        if not _is_cgen(predecessor) or not _is_digest(predecessor_digest):
            raise IntegrityFailure(f"{cgen} has a malformed predecessor")

    if hashlib.sha256(authority_body).hexdigest() != record["authority_set_digest"]:
        raise IntegrityFailure(
            "authority-set does not match the digest the generation binds")

    entries = _authority_set(authority_body)
    found = _scan_implementations(root_fd, scan)

    listed = {entry.cimp for entry in entries}
    for name in sorted(set(found) - listed):
        scan.find(f"{name} exists on disk but is absent from the authority-set")

    eligible: list[str] = []
    for entry in entries:
        records = found.get(entry.cimp)
        if records is None:
            scan.find(f"{entry.cimp} is in the authority-set but has no records")
            continue
        admission_body = records.get(_ADMISSION)
        if admission_body is None:
            continue
        if hashlib.sha256(admission_body).hexdigest() != entry.admission_digest:
            scan.find(f"{entry.cimp} admission digest disagrees with the authority-set")
            continue
        _admission(admission_body, entry.cimp)
        retirement_body = records.get(_RETIREMENT)
        if entry.retirement_digest is None:
            if retirement_body is not None:
                scan.find(f"{entry.cimp} is retired on disk but not in the authority-set")
                continue
            eligible.append(entry.cimp)
            continue
        if retirement_body is None:
            scan.find(f"{entry.cimp} is retired in the authority-set but has no record")
            continue
        if hashlib.sha256(retirement_body).hexdigest() != entry.retirement_digest:
            scan.find(f"{entry.cimp} retirement digest disagrees with the authority-set")
            continue
        _retirement(retirement_body, entry.cimp)

    scan.settle()

    return Generation(
        cgen=cgen,
        generation_digest=generation_digest,
        authority_set_digest=record["authority_set_digest"],
        predecessor_cgen=predecessor,
        predecessor_generation_digest=predecessor_digest,
        entries=entries,
        eligible_cimps=tuple(eligible),
    )


def resolve_implementation(root_fd: int, cimp: str, *,
                           generation: Generation) -> Admission:
    """The admitted contract for ``cimp``, if it may still be bound.

    Re-reads the admission through the descriptor and re-checks its digest
    against the snapshot rather than trusting the snapshot alone, so a record
    changed since validation is caught here too.
    """
    if not _is_cimp(cimp):
        raise ImplementationAuthorityError(f"{cimp!r} is not a CIMP identity")

    entry = next((e for e in generation.entries if e.cimp == cimp), None)
    if entry is None:
        raise UnknownImplementation(f"{cimp} is not in the authority-set")
    if entry.retirement_digest is not None:
        raise RetiredImplementation(f"{cimp} is retired and cannot be bound")

    base = _open_dir(_IMPLEMENTATIONS, root_fd)
    try:
        handle = _open_dir(cimp, base)
        try:
            body = _read_record(_ADMISSION, handle)
        finally:
            os.close(handle)
    finally:
        os.close(base)

    if hashlib.sha256(body).hexdigest() != entry.admission_digest:
        raise IntegrityFailure(f"{cimp} admission changed since validation")
    return _admission(body, cimp)
