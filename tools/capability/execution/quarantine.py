"""Bounded forensic quarantine for the ENG-0005 first adapter.

Failed or untrusted output may be kept as evidence, and evidence is all it can
ever be. What is copied here cannot become a capability result, cannot reach
Fabric, Trust, or Health, and cannot feed anything automated. The one direction
that exists is output into quarantine; nothing in this module can name the type
a trusted result is made of.

**The reservation is the admission.** Sixteen mebibytes are reserved durably
before a byte is copied, and the whole reservation is held until a terminal
record commits. Actual usage never reduces it as it is consumed: a reservation
that shrank would let a second collection in on space the first one is still
entitled to, and the disk would then fill during the collection rather than
before it. Admission measures physical free space again every time, under the
quarantine lock, because free space is a fact about the host and not about what
this runtime last believed.

**No deletion, anywhere, in v1.** Not on failure, not on refusal, not as
cleanup. A namespace that was written stays written; the operator disposes of
it. That is why this module cannot unlink, and why the escape hatch for a tree
that will not seal is to declare it opaque residue rather than to remove it.

**Create-once throughout.** A collection into an existing namespace is refused
rather than resumed, appended to, or overwritten. A crash before the manifest
therefore leaves a namespace that reads as ``incomplete`` and stays that way
until an operator disposes of it — which is the whole point of
``quarantine_collection_incomplete``: it is a condition, not a retry.

**One hostile-tree contract.** Traversal reuses the T14 bounds through the same
audited primitive rather than a second geometry (reviewer ruling, 2026-08-12),
so the path exercised rarely cannot rot away from the path exercised often.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§15 and §23.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
from typing import Any, Callable

from ...common.trusted_source import TraversalRefused, walk_tree
from . import canonical_json
from . import state as state_module
from .backing_store import RootDescriptor
from .collector import (OUTPUT_MAXIMUM_FILE_BYTES, OUTPUT_MAXIMUM_FILES,
                        OUTPUT_MAXIMUM_TOTAL_BYTES, OUTPUT_TREE_MAX_DEPTH,
                        OUTPUT_TREE_MAX_ENTRIES, CollectedFile)
from .mutation import Mutation, MutationTarget, TargetKind
from .state import QUARANTINE_LOCK, _LockOrder
from .types import Classification

# The structural bounds are T14's, taken from T14 rather than restated, so the
# two paths cannot drift into two contracts.
QUARANTINE_MAX_DEPTH = OUTPUT_TREE_MAX_DEPTH
QUARANTINE_MAX_ENTRIES = OUTPUT_TREE_MAX_ENTRIES
QUARANTINE_MAX_FILES = OUTPUT_MAXIMUM_FILES
QUARANTINE_MAX_FILE_BYTES = OUTPUT_MAXIMUM_FILE_BYTES
QUARANTINE_MAX_TOTAL_BYTES = OUTPUT_MAXIMUM_TOTAL_BYTES

# §15. Each active collection reserves this much, and preserves a physical
# floor beneath it so quarantine can never be the thing that fills the disk.
RESERVATION_BYTES = 16 * 1024 * 1024
RESERVE_FLOOR_BYTES = 1024 ** 3
RESERVE_DIVISOR = 20  # five percent, as integer arithmetic

RESERVATIONS_DIRECTORY = "quarantine-reservations"
RELEASES_DIRECTORY = "quarantine-releases"

DATA_DIRECTORY = "data"
MANIFEST_NAME = "manifest"
RESIDUE_NAME = "residue"
MANIFEST_SCHEMA_VERSION = 1

ABSENT = "absent"
INCOMPLETE = "incomplete"
SEALED = "sealed"
RESIDUE = "residue"

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC


class QuarantineError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class QuarantineRefused(QuarantineError):
    """Admission or sequence refused.

    Carries no classification on purpose. Being told no by admission, or asking
    to seal something twice, is not a condition the evidence is in — and
    borrowing an evidence classification for it would report a caller's mistake
    as a state of the stored bytes.
    """


class QuarantineCollectionIncomplete(QuarantineError):
    """Collection did not complete, and will not be resumed."""

    classification = Classification.QUARANTINE_COLLECTION_INCOMPLETE


class QuarantineIncompleteIntegrityFailure(QuarantineError):
    """A partial namespace cannot be sealed as validated evidence."""

    classification = Classification.QUARANTINE_INCOMPLETE_INTEGRITY_FAILURE


@dataclasses.dataclass(frozen=True)
class FilesystemSpace:
    """What the host says about the filesystem holding the quarantine root."""

    free_bytes: int
    total_bytes: int


@dataclasses.dataclass(frozen=True)
class QuarantineReservation:
    """One durable logical reservation, for one `CINV`."""

    cinv: str
    reserved_bytes: int


@dataclasses.dataclass(frozen=True)
class QuarantineManifest:
    """The terminal description of one sealed quarantine namespace.

    Deliberately not a result, not convertible into one, and carrying nothing a
    downstream automated step could act on: paths, sizes, and digests.
    """

    files: tuple[CollectedFile, ...]
    file_count: int
    total_bytes: int
    entry_count: int


def _require_root(root: Any, what: str) -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise QuarantineRefused(f"{what} must be a verified RootDescriptor")
    return root


def _require_reservation(reservation: Any) -> QuarantineReservation:
    if not isinstance(reservation, QuarantineReservation):
        raise QuarantineRefused("a QuarantineReservation is required")
    state_module.validate_cinv(reservation.cinv)
    return reservation


def physical_space(root: RootDescriptor) -> FilesystemSpace:
    """Measure the filesystem under a verified root.

    The one function here that asks the host anything. Kept separate so that
    admission is arithmetic over a value taken under the lock, rather than a
    decision entangled with the measurement.
    """
    _require_root(root, "root")
    status = os.statvfs(root.fd)
    return FilesystemSpace(free_bytes=status.f_bavail * status.f_frsize,
                           total_bytes=status.f_blocks * status.f_frsize)


def required_reserve(total_bytes: int) -> int:
    """The physical reserve §15 requires for a filesystem of this size.

    A flat gibibyte is too little on a large filesystem and five percent is too
    little on a small one, so the floor and the fraction are both applied and
    the larger wins.
    """
    if not isinstance(total_bytes, int) or isinstance(total_bytes, bool) \
            or total_bytes < 0:
        raise QuarantineRefused("a filesystem size must be a non-negative integer")
    return RESERVATION_BYTES + max(RESERVE_FLOOR_BYTES,
                                   total_bytes // RESERVE_DIVISOR)


def _names(root: RootDescriptor, directory: str) -> set[str]:
    try:
        handle = os.open(directory, _DIR_FLAGS, dir_fd=root.fd)
    except OSError as error:
        raise QuarantineRefused(
            f"the {directory} namespace is unusable: {error}") from None
    try:
        with os.scandir(handle) as entries:
            return {entry.name for entry in entries}
    finally:
        os.close(handle)


def outstanding_reservations(root: RootDescriptor) -> int:
    """Bytes currently reserved and not yet released.

    Counted from durable records, never from a cached number: a count that
    survived only in memory would be wrong exactly when it mattered, which is
    after a crash.
    """
    _require_root(root, "root")
    held = _names(root, RESERVATIONS_DIRECTORY) - _names(root, RELEASES_DIRECTORY)
    return RESERVATION_BYTES * len(held)


def _record(root: RootDescriptor, kind: TargetKind, cinv: str,
            schema_type: str, body: dict[str, Any]) -> None:
    encoded = canonical_json.serialise(body)
    mutation = Mutation(root)
    cmut = mutation.begin(MutationTarget(kind=kind, name=cinv),
                          schema_type=schema_type,
                          expected_sha256=hashlib.sha256(encoded).hexdigest())
    mutation.install(cmut, encoded)
    mutation.commit(cmut)


def admit(root: Any, store: Any, cinv: Any, *,
          space: Callable[[], FilesystemSpace]) -> QuarantineReservation:
    """Reserve space for one quarantine collection, or refuse.

    The whole decision happens under the quarantine lock: measure, subtract what
    other reservations are still entitled to, compare against the reserve, and
    commit. A caller told yes has a durable reservation by the time the lock
    drops, so two admissions cannot both be sized against the same free bytes.
    """
    _require_root(root, "root")
    _require_root(store, "store")
    state_module.validate_cinv(cinv)

    locks = _LockOrder()
    locks.acquire_quarantine(root)
    try:
        if cinv in _names(root, RESERVATIONS_DIRECTORY):
            raise QuarantineRefused(f"{cinv} already holds a quarantine reservation")

        measured = space()
        if not isinstance(measured, FilesystemSpace):
            raise QuarantineRefused("the space seam did not report a FilesystemSpace")
        reserve = required_reserve(measured.total_bytes)
        available = measured.free_bytes - outstanding_reservations(root)
        if available < reserve:
            raise QuarantineRefused(
                f"admitting {cinv} would leave {available} bytes against a "
                f"required physical reserve of {reserve}")

        _record(root, TargetKind.QUARANTINE_RESERVATION, cinv,
                "quarantine-reservation",
                {"cinv": cinv, "schema_version": MANIFEST_SCHEMA_VERSION,
                 "reserved_bytes": RESERVATION_BYTES})
        return QuarantineReservation(cinv=cinv, reserved_bytes=RESERVATION_BYTES)
    finally:
        locks.release_all()


def _namespace_fd(store: RootDescriptor, cinv: str) -> int | None:
    try:
        return os.open(cinv, _DIR_FLAGS, dir_fd=store.fd)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise QuarantineRefused(
            f"the {cinv} quarantine namespace is unusable: {error}") from None


def _present(name: str, dir_fd: int) -> bool:
    try:
        os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def condition(store: Any, cinv: Any) -> str:
    """What state the stored namespace for ``cinv`` is in.

    Read from what is durably there and nothing else. A namespace with bytes
    and no terminal record is ``incomplete``, which is a condition an operator
    resolves rather than something this module retries.
    """
    _require_root(store, "store")
    state_module.validate_cinv(cinv)
    handle = _namespace_fd(store, cinv)
    if handle is None:
        return ABSENT
    try:
        if _present(RESIDUE_NAME, handle):
            return RESIDUE
        if _present(MANIFEST_NAME, handle):
            return SEALED
        return INCOMPLETE
    finally:
        os.close(handle)


def _make_directory(name: str, dir_fd: int) -> int:
    os.mkdir(name, 0o700, dir_fd=dir_fd)
    os.fsync(dir_fd)
    return os.open(name, _DIR_FLAGS, dir_fd=dir_fd)


def _open_or_make(name: str, dir_fd: int) -> int:
    try:
        return _make_directory(name, dir_fd)
    except FileExistsError:
        return os.open(name, _DIR_FLAGS, dir_fd=dir_fd)


def _write_file(name: str, body: bytes, dir_fd: int) -> None:
    handle = os.open(name, _CREATE_FLAGS, 0o600, dir_fd=dir_fd)
    try:
        written = 0
        while written < len(body):
            written += os.write(handle, body[written:])
        os.fsync(handle)
    finally:
        os.close(handle)
    os.fsync(dir_fd)


def _store_file(data_fd: int, parts: tuple[str, ...], body: bytes) -> None:
    """Write one file at its relative path, creating the directories under it.

    Descriptor-relative the whole way down. The components come from a walk
    this process performed, never from a name anything else supplied.
    """
    current = os.dup(data_fd)
    try:
        for component in parts[:-1]:
            nested = _open_or_make(component, current)
            os.close(current)
            current = nested
        _write_file(parts[-1], body, current)
    finally:
        os.close(current)


def _walk(descriptor: int, refusal: type[QuarantineError]) -> Any:
    try:
        return walk_tree(descriptor,
                         maximum_depth=QUARANTINE_MAX_DEPTH,
                         maximum_entries=QUARANTINE_MAX_ENTRIES,
                         maximum_files=QUARANTINE_MAX_FILES,
                         maximum_file_bytes=QUARANTINE_MAX_FILE_BYTES,
                         maximum_total_bytes=QUARANTINE_MAX_TOTAL_BYTES)
    except TraversalRefused as error:
        raise refusal(
            f"the tree violates policy ({error.reason.value}): {error}") from None


def _manifest_of(walked: Any) -> QuarantineManifest:
    files = tuple(
        CollectedFile(relative_path="/".join(entry.relative_path),
                      size=entry.size,
                      sha256=hashlib.sha256(entry.data).hexdigest())
        for entry in walked.files)
    return QuarantineManifest(files=files, file_count=len(files),
                              total_bytes=walked.total_bytes,
                              entry_count=walked.entry_count)


def _require_held(root: RootDescriptor, cinv: str) -> None:
    if cinv not in _names(root, RESERVATIONS_DIRECTORY):
        raise QuarantineRefused(f"{cinv} holds no quarantine reservation")
    if cinv in _names(root, RELEASES_DIRECTORY):
        raise QuarantineRefused(f"the {cinv} reservation is already released")


def collect(root: Any, store: Any, reservation: Any,
            out_fd: Any) -> QuarantineManifest:
    """Copy one output tree into quarantine, or refuse.

    The tree is validated in full before a byte is written, so a hostile object
    anywhere in it means nothing is stored at all. An existing namespace is
    refused rather than resumed: a partial collection is evidence of a crash,
    and writing more into it would destroy the only thing it can still tell
    anyone.
    """
    _require_root(root, "root")
    _require_root(store, "store")
    held = _require_reservation(reservation)
    _require_held(root, held.cinv)

    if condition(store, held.cinv) is not ABSENT:
        raise QuarantineRefused(
            f"the {held.cinv} quarantine namespace already exists; there is no "
            "resume, append, or overwrite")

    walked = _walk(out_fd, QuarantineCollectionIncomplete)

    namespace = _make_directory(held.cinv, store.fd)
    try:
        data = _make_directory(DATA_DIRECTORY, namespace)
        try:
            for entry in walked.files:
                _store_file(data, entry.relative_path, entry.data)
        finally:
            os.close(data)
    finally:
        os.close(namespace)

    store.reverify()
    return _manifest_of(walked)


def _seal(root: RootDescriptor, store: RootDescriptor,
          reservation: QuarantineReservation,
          manifest: QuarantineManifest) -> None:
    body = canonical_json.serialise({
        "cinv": reservation.cinv,
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "file_count": manifest.file_count,
        "total_bytes": manifest.total_bytes,
        "entry_count": manifest.entry_count,
        "files": [{"relative_path": entry.relative_path,
                   "size": entry.size,
                   "sha256": entry.sha256} for entry in manifest.files],
    })
    handle = os.open(reservation.cinv, _DIR_FLAGS, dir_fd=store.fd)
    try:
        _write_file(MANIFEST_NAME, body, handle)
    finally:
        os.close(handle)
    store.reverify()
    # Only now, with the terminal record durable, may the reservation go.
    _record(root, TargetKind.QUARANTINE_RELEASE, reservation.cinv,
            "quarantine-release",
            {"cinv": reservation.cinv,
             "schema_version": MANIFEST_SCHEMA_VERSION,
             "released_bytes": RESERVATION_BYTES})


def seal(root: Any, store: Any, reservation: Any, manifest: Any) -> None:
    """Commit the terminal record for a completed collection, or refuse."""
    _require_root(root, "root")
    _require_root(store, "store")
    held = _require_reservation(reservation)
    if not isinstance(manifest, QuarantineManifest):
        raise QuarantineRefused("a QuarantineManifest is required")
    _require_held(root, held.cinv)
    if condition(store, held.cinv) is not INCOMPLETE:
        raise QuarantineRefused(
            f"the {held.cinv} namespace is {condition(store, held.cinv)} and "
            "cannot be sealed")
    _seal(root, store, held, manifest)


def seal_incomplete(root: Any, store: Any, reservation: Any) -> QuarantineManifest:
    """Seal a partial namespace, or refuse it as unsealable.

    The disposition behind `retain-quarantine-incomplete`. What is on disk is
    re-examined against the same structural contract a fresh collection meets;
    anything outside it cannot be described honestly as validated evidence, and
    the operator's remaining move is residue.
    """
    _require_root(root, "root")
    _require_root(store, "store")
    held = _require_reservation(reservation)
    _require_held(root, held.cinv)
    if condition(store, held.cinv) is not INCOMPLETE:
        raise QuarantineRefused(
            f"the {held.cinv} namespace is {condition(store, held.cinv)} and "
            "cannot be sealed")

    namespace = os.open(held.cinv, _DIR_FLAGS, dir_fd=store.fd)
    try:
        data = os.open(DATA_DIRECTORY, _DIR_FLAGS, dir_fd=namespace)
    except OSError as error:
        os.close(namespace)
        raise QuarantineIncompleteIntegrityFailure(
            f"the {held.cinv} namespace has no readable data: {error}") from None
    try:
        walked = _walk(data, QuarantineIncompleteIntegrityFailure)
    finally:
        os.close(data)
        os.close(namespace)

    manifest = _manifest_of(walked)
    _seal(root, store, held, manifest)
    return manifest


def retain_residue(root: Any, store: Any, reservation: Any) -> None:
    """Declare the namespace opaque operator-managed residue.

    The disposition behind `retain-quarantine-residue`, and the last v1 move.
    No manifest, no further enumeration, and nothing removed — the bytes stay
    exactly where they are and the operator owns them from here. The logical
    reservation may go because physical free space accounts for the retained
    bytes on its own from now on.
    """
    _require_root(root, "root")
    _require_root(store, "store")
    held = _require_reservation(reservation)
    _require_held(root, held.cinv)
    if condition(store, held.cinv) is not INCOMPLETE:
        raise QuarantineRefused(
            f"the {held.cinv} namespace is {condition(store, held.cinv)} and "
            "cannot become residue")

    body = canonical_json.serialise({
        "cinv": held.cinv,
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "enumerated": False,
    })
    handle = os.open(held.cinv, _DIR_FLAGS, dir_fd=store.fd)
    try:
        _write_file(RESIDUE_NAME, body, handle)
    finally:
        os.close(handle)
    store.reverify()
    _record(root, TargetKind.QUARANTINE_RELEASE, held.cinv,
            "quarantine-release",
            {"cinv": held.cinv, "schema_version": MANIFEST_SCHEMA_VERSION,
             "released_bytes": RESERVATION_BYTES})
