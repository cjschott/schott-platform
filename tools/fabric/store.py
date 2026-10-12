"""Append-only storage for Fabric Runtime records — the only physical writer.

Built on tools/common/immutable_store.py rather than growing another copy of
the write path. What this layer adds is refusal.

**Ownership is supplied, never inferred.** A store is opened with an explicit
`expected_uid` and `expected_gid` from its composition root. There is no
default and no lookup, because a store that decides for itself who should own
its records will always agree with whoever is running it — including whoever
should not be. A path whose owner disagrees is refused and reported. Nothing
here calls `chown`: repairing ownership would erase the evidence that it was
wrong.

**Paths are inspected before they are followed.** `Path.exists()` is never used
as a security check: it follows symlinks and answers `False` for a broken one,
which is exactly the case that must refuse. Every path is `lstat`ed unresolved
first, then resolved and required to stay inside the root.

**A pre-existing temporary artefact is evidence, not debris to clear.** It is
what an interrupted write leaves behind, so a write that finds one refuses
rather than truncating it. `O_EXCL` closes the gap between checking and
opening, and the only temporary this code will ever unlink is one this
invocation exclusively created.

This increment stores records. It admits nothing, evaluates nothing, chooses
nothing, and repairs nothing.
"""

from __future__ import annotations

import fcntl
import os
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping

from ..common.immutable_store import (DIR_MODE, FILE_MODE, MAX_SEQUENCE,
                                      ImmutableStore,
                                      StoreError)
from .errors import FabricError
from .evidence import validate_record_evidence
from .identifiers import ID_FIELDS, PATTERNS, PREFIXES

# Four digits for the records an operator writes deliberately, six for the ones
# a running fabric produces. Taken from the accepted schemas.
ID_WIDTHS = {
    "capability-definition": 4,
    "capability-contract": 4,
    "capability-package": 4,
    "capability-host": 4,
    "capability-route": 4,
    "capability-advertisement": 6,
    "capability-instance": 6,
    "capability-selection": 6,
}

RECORD_DIRS = {
    "capability-definition": "capability-definitions",
    "capability-contract": "capability-contracts",
    "capability-package": "capability-packages",
    "capability-host": "capability-hosts",
    "capability-advertisement": "capability-advertisements",
    "capability-instance": "capability-instances",
    "capability-route": "capability-routes",
    "capability-selection": "capability-selections",
}


class FabricStore(ImmutableStore):
    """The Fabric store, rooted at an explicit directory outside the repository."""

    record_dirs = dict(RECORD_DIRS)
    id_patterns = dict(PATTERNS)
    id_prefixes = dict(PREFIXES)
    id_widths = dict(ID_WIDTHS)
    extra_dirs = ("sequences",)
    # A pre-existing temporary artefact is refused rather than truncated.
    exclusive_temporary_create = True

    def __init__(self, root: Path | str, *, expected_uid: int, expected_gid: int,
                 allow_repository_root: bool = False) -> None:
        if root is None or str(root).strip() == "":
            raise FabricError("a store root must be supplied explicitly")
        if not isinstance(expected_uid, int) or isinstance(expected_uid, bool):
            raise FabricError("expected_uid must be supplied as an integer")
        if not isinstance(expected_gid, int) or isinstance(expected_gid, bool):
            raise FabricError("expected_gid must be supplied as an integer")

        # Assigned before super().__init__(), which calls
        # _create_directories() through this class -- the override would
        # otherwise read attributes that do not exist yet.
        self._expected_uid = expected_uid
        self._expected_gid = expected_gid

        supplied = Path(root).expanduser()
        # Inspected unresolved, before super() resolves it away. A root that is
        # a symlink -- including a broken one -- must refuse rather than
        # silently become whatever it points at.
        self._reject_link(supplied, "store root")
        if str(supplied) == os.sep:
            raise FabricError("the filesystem root is not a store root")

        try:
            super().__init__(root, allow_repository_root=allow_repository_root)
        except StoreError as error:
            raise FabricError(str(error)) from None

    # --- ownership and containment ------------------------------------------

    @property
    def expected_uid(self) -> int:
        return self._expected_uid

    @property
    def expected_gid(self) -> int:
        return self._expected_gid

    def _reject_link(self, path: Path, description: str) -> None:
        """Refuse a symlink using the unresolved path, before anything follows it."""
        try:
            entry = path.lstat()
        except FileNotFoundError:
            return
        except OSError as error:
            raise FabricError(f"{description} could not be inspected") from error
        if stat.S_ISLNK(entry.st_mode):
            raise FabricError(f"{description} is a symbolic link")

    def _require_ownership(self, path: Path, description: str) -> None:
        """Compare a real inode's owner with the supplied values. Never repairs."""
        try:
            entry = path.lstat()
        except FileNotFoundError:
            return
        except OSError as error:
            raise FabricError(f"{description} could not be inspected") from error
        if entry.st_uid != self._expected_uid or entry.st_gid != self._expected_gid:
            raise FabricError(f"{description} is not owned by the supplied uid/gid")

    def _guard_path(self, path: Path, description: str) -> Path:
        """Refuse a link or an escape, then return the contained path.

        Order matters. The link check runs on the unresolved path and on every
        unresolved parent up to the root, because resolving first would follow
        the link this check exists to catch.
        """
        candidate = Path(path)
        unresolved = [candidate, *candidate.parents]
        for entry in unresolved:
            if entry == self.root or self.root in entry.parents:
                self._reject_link(entry, f"{description} path component")

        resolved = candidate.resolve(strict=False)
        if resolved != self.root and self.root not in resolved.parents:
            raise FabricError(f"{description} resolves outside the store root")
        self._require_ownership(candidate, description)
        return candidate

    def _create_directories(self) -> None:
        """Verify what exists; create only what does not.

        The inherited body calls mkdir(exist_ok=True) and then chmod on every
        directory, including ones that already exist -- which silently corrects
        a mode this store is supposed to refuse. This verifies first and
        corrects nothing.
        """
        self._reject_link(self.root, "store root")
        self._require_ownership(self.root, "store root")

        for name in (*self.record_dirs.values(), *self.extra_dirs):
            directory = self.root / name
            self._reject_link(directory, f"record directory '{name}'")
            if directory.exists():
                self._require_ownership(directory, f"record directory '{name}'")
                mode = stat.S_IMODE(directory.lstat().st_mode)
                if mode != DIR_MODE:
                    raise FabricError(
                        f"record directory '{name}' has mode {oct(mode)}, not {oct(DIR_MODE)}")
                continue

            # Creating means becoming the owner. If this process is not the
            # expected owner, the created path would be wrong the instant it
            # existed, so refuse before creating anything.
            if os.geteuid() != self._expected_uid or os.getegid() != self._expected_gid:
                raise FabricError(
                    "the running process does not match the supplied uid/gid")
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(DIR_MODE)
            self._require_ownership(directory, f"record directory '{name}'")

        # The request identity lock belongs to the store's layout, not to any
        # operation. Created lazily it would mean the first governed refusal on
        # a fresh store adds a file and moves a directory's timestamp -- a
        # refusal that changed the store, which is exactly what a refusal must
        # never do. Created here, every later entry disturbs nothing at all.
        os.close(self._open_request_lock())

    def _open_request_lock(self) -> int:
        """The one lock file, guarded and opened. Never read, never written."""
        sequences = self._guard_path(self.root / "sequences", "sequence directory")
        lock_path = self._guard_path(sequences / "request_identity.lock",
                                     "request identity lock")
        handle = os.open(lock_path, os.O_RDWR | os.O_CREAT, FILE_MODE)
        self._require_ownership(lock_path, "request identity lock")
        return handle

    @classmethod
    def open_for_read(cls, root: Path | str, *, expected_uid: int, expected_gid: int,
                      allow_repository_root: bool = False) -> "FabricStore":
        """Open without creating any part of the store.

        An absent store is reported as absent, never built and then described.
        """
        store = cls.__new__(cls)
        if root is None or str(root).strip() == "":
            raise FabricError("a store root must be supplied explicitly")
        if not isinstance(expected_uid, int) or isinstance(expected_uid, bool):
            raise FabricError("expected_uid must be supplied as an integer")
        if not isinstance(expected_gid, int) or isinstance(expected_gid, bool):
            raise FabricError("expected_gid must be supplied as an integer")
        store._expected_uid = expected_uid
        store._expected_gid = expected_gid

        supplied = Path(root).expanduser()
        store._reject_link(supplied, "store root")
        try:
            ImmutableStore.__init__(
                store, root, allow_repository_root=allow_repository_root,
                initialize=False)
        except StoreError as error:
            raise FabricError(str(error)) from None
        store._require_ownership(store.root, "store root")
        return store

    def _test_sync_point(self, phase: str, request_id: str) -> None:
        """Named point a coordinating test can observe. Production no-op.

        A deterministic two-caller test needs a positive signal that a caller
        reached a particular phase. Inferring it from elapsed time, or from an
        event that failed to arrive, proves nothing -- so the seam is named and
        does nothing rather than being simulated from outside.

        This writes nothing, holds nothing, and returns nothing. A coordinating
        test overrides it; production never notices it is there.
        """

    @contextmanager
    def request_critical_section(self, request_id: str) -> Iterator[None]:
        """Serialise replay lookup, allocation, and the accepted write.

        Without this, two callers presenting one request identity both observe
        "not found" on replay lookup and both commit, so one request identity
        yields two records -- or two records for contradictory digests. The
        section closes that window: whoever holds it decides, and the other
        caller reads the decision that was made rather than a store that had
        not made it yet.

        **The section is store-global.** Every governed write request for one
        Fabric store serialises through this single C1-owned lock, whatever
        request identity it carries. `request_id` is **never used to derive the
        lock file's identity** -- it is passed only so contention can be
        reported against the request that waited. A per-request name would be
        an unbounded set of files derived from caller-supplied text, and the
        request identity is opaque: nothing here parses it. Contention is brief
        -- the section spans a lookup, an allocation, and one atomic write --
        so a single lock costs less than the names it avoids.

        Distinct request identities stay logically independent under this lock:
        they allocate their own identities, neither is treated as a replay of
        the other, and neither overwrites the other. What they do not get is
        simultaneous entry, which nothing in the accepted contract requires.

        **The section is not reentrant.** It is an `fcntl.flock` on a fresh
        descriptor, so a second acquisition on the same thread blocks against
        the first and hangs the store for every later caller. The authorised
        acquisition owners are the **C4 and C6 operation boundaries**, and each
        enters **at most once per governed operation**: the replay helper in
        `request_identity.py` assumes the boundary already holds it and never
        enters, and no governed operation invokes another. A caller holding
        this section must not invoke another governed operation.

        The non-blocking attempt first is what makes contention observable:
        the seam fires only when someone is actually held, so a test waits on
        a positive event rather than on elapsed time. The blocking acquisition
        that follows is the one that matters.
        """
        handle = self._open_request_lock()
        try:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                self._test_sync_point("lock_contended", request_id)
                fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                # Released on the way out however this section ends: a refusal
                # and a traceback both leave the next caller able to proceed.
                fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)

    # --- guarded inherited surface ------------------------------------------

    def _directory(self, kind: str) -> Path:
        try:
            directory = super()._directory(kind)
        except StoreError as error:
            raise FabricError(str(error)) from None
        return self._guard_path(directory, f"record directory for '{kind}'")

    def path_for(self, kind: str, identifier: str) -> Path:
        # Inherited identifier validation first: a traversing identifier is not
        # a valid identifier, and should be refused as one.
        try:
            destination = super().path_for(kind, identifier)
        except StoreError as error:
            raise FabricError(str(error)) from None
        return self._guard_path(destination, f"record '{identifier}'")

    def _next_after(self, kind: str, current: int) -> tuple[int, str]:
        """The identifier that follows `current`, skipping occupied names.

        The one place the Fabric identifier rule lives. `allocate_id` and
        `peek_next_id` both call it, so a prediction cannot disagree with what
        allocation would actually hand out -- which is the whole point of being
        able to predict one before a permanent governance write.

        Deliberately here rather than on the shared base class: that class is
        an installed Generation-10 runtime object, and changing it would open a
        generation. The Fabric plane is not installed, so the rule lives where
        both of its consumers already are.
        """
        prefix = self.id_prefixes[kind]
        width = self.id_widths.get(kind, 6)
        # A kind cannot outgrow its own width. Rolling over would reuse a name.
        kind_maximum = min(10 ** width - 1, MAX_SEQUENCE)
        candidate = current
        while True:
            candidate += 1
            if candidate > kind_maximum:
                raise FabricError(
                    f"{kind} sequence is exhausted; widening the identifier is a "
                    "deliberate decision, not an automatic rollover")
            identifier = f"{prefix}-{candidate:0{width}d}"
            if kind in self.record_dirs and self.path_for(kind, identifier).exists():
                # Something occupies this name. Skip it rather than reuse or
                # overwrite a record this store did not create.
                continue
            return candidate, identifier

    def _sequence_value(self, kind: str) -> int:
        """The sequence's current value, creating nothing.

        An absent sequence file reads as zero rather than being created, so
        asking what comes next never provisions the thing being asked about.
        """
        try:
            raw = (self.root / "sequences" / f"{kind}.seq").read_text(
                encoding="utf-8").strip()
        except (FileNotFoundError, NotADirectoryError, OSError):
            return 0
        return int(raw) if raw.isdigit() else 0

    def peek_next_id(self, kind: str) -> str:
        """The identifier `allocate_id` would return, without spending it.

        Reads. Never opens the sequence for writing, never creates it, never
        takes the lock, and advances nothing: a prediction that consumed the
        thing it predicted would be an allocation wearing a different name.

        It is a prediction, not a reservation. Between peeking and allocating
        another caller may take the identifier, which is why the write path
        allocates for itself rather than being handed this value.
        """
        if kind not in self.id_prefixes:
            raise FabricError(f"unknown record kind '{kind}'")
        return self._next_after(kind, self._sequence_value(kind))[1]

    def allocate_id(self, kind: str) -> str:
        """Reserve the next identifier, through the same rule `peek` reports.

        The locked read-modify-write is the base class's protocol, restated
        here only so that the candidate rule above is the single one both
        allocation and prediction use.
        """
        if kind not in self.id_prefixes:
            raise FabricError(f"unknown record kind '{kind}'")
        sequences = self._guard_path(self.root / "sequences", "sequence directory")
        sequence_file = self._guard_path(sequences / f"{kind}.seq",
                                         f"sequence file for '{kind}'")
        try:
            handle = os.open(sequence_file, os.O_RDWR | os.O_CREAT, FILE_MODE)
        except OSError as error:
            raise FabricError(str(error)) from None
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
            raw = os.read(handle, 64).decode("utf-8").strip()
            current = int(raw) if raw.isdigit() else 0
            candidate, identifier = self._next_after(kind, current)
            os.lseek(handle, 0, os.SEEK_SET)
            os.truncate(handle, 0)
            os.write(handle, f"{candidate}\n".encode("utf-8"))
            os.fsync(handle)
            return identifier
        except StoreError as error:
            raise FabricError(str(error)) from None
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
            os.close(handle)

    def write_atomic(self, destination: Path, payload: Mapping[str, Any]) -> Path:
        guarded = self._guard_path(Path(destination), "record destination")
        temporary = guarded.with_name(f".{guarded.stem}.tmp")
        self._guard_path(temporary, "temporary artefact")
        # Refuse before delegating. O_EXCL below would refuse too, but saying
        # so here keeps the reason precise and leaves the artefact untouched.
        try:
            temporary.lstat()
        except FileNotFoundError:
            pass
        else:
            raise FabricError(
                f"temporary artefact for '{guarded.name}' already exists")
        try:
            return super().write_atomic(guarded, dict(payload))
        except StoreError as error:
            raise FabricError(str(error)) from None

    def write(self, kind: str, record) -> Path:
        """Persist a record, identified by the field its kind names.

        The inherited body reads `record.id`, which is right for the Trust
        Plane and wrong here: no accepted fabric record carries one. The
        identity field is looked up in `identifiers.py` rather than inferred
        from the object, so a record that is not what it claims to be is
        refused instead of persisted under a guessed name.

        **C1 owns the final persistence boundary.** C4 and C6 decide whether a
        governed action is authorised; this decides nothing. But nothing may
        reach the filesystem without complete, applicable evidence, so the
        invariant is checked here -- before allocation, before any temporary
        artefact, before any sequence moves -- rather than trusted to whoever
        called. A second entry point that skipped it would make the invariant
        advisory.
        """
        if kind not in ID_FIELDS:
            raise FabricError(f"unknown record kind '{kind}'")
        if getattr(record, "kind", None) != kind:
            raise FabricError(f"a '{kind}' record was not supplied")
        validate_record_evidence(kind, record)
        identifier = getattr(record, ID_FIELDS[kind])
        try:
            return self.write_atomic(self.path_for(kind, identifier), record.to_dict())
        except StoreError as error:
            raise FabricError(str(error)) from None

    def write_record(self, kind: str, record) -> Path:
        """The inherited name, reaching the same guarded path."""
        return self.write(kind, record)

    def read_record(self, kind: str, identifier: str) -> dict[str, Any]:
        # path_for guards the exact record before anything reads it.
        self.path_for(kind, identifier)
        try:
            return super().read_record(kind, identifier)
        except StoreError as error:
            raise FabricError(str(error)) from None

    def list_records(self, kind: str, target: str | None = None) -> list[dict[str, Any]]:
        directory = self._directory(kind)
        for entry in sorted(directory.glob("*.yaml")):
            self._guard_path(entry, f"record '{entry.name}'")
        try:
            return super().list_records(kind, target)
        except StoreError as error:
            raise FabricError(str(error)) from None

    def validate(self) -> list[str]:
        """Structural problems, in a deterministic order. Repairs nothing."""
        for kind in self.record_dirs:
            directory = self._directory(kind)
            for entry in sorted(directory.iterdir()):
                self._guard_path(entry, f"record '{entry.name}'")
        try:
            return sorted(super().validate())
        except StoreError as error:
            raise FabricError(str(error)) from None

    def counts(self) -> dict[str, int]:
        for kind in self.record_dirs:
            directory = self._directory(kind)
            for entry in sorted(directory.glob("*.yaml")):
                self._guard_path(entry, f"record '{entry.name}'")
        try:
            return super().counts()
        except StoreError as error:
            raise FabricError(str(error)) from None
