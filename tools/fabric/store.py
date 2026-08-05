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

import os
import stat
from pathlib import Path
from typing import Any, Mapping

from ..common.immutable_store import DIR_MODE, ImmutableStore, StoreError
from .errors import FabricError
from .identifiers import PATTERNS, PREFIXES

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

    def allocate_id(self, kind: str) -> str:
        if kind not in self.id_prefixes:
            raise FabricError(f"unknown record kind '{kind}'")
        sequences = self._guard_path(self.root / "sequences", "sequence directory")
        self._guard_path(sequences / f"{kind}.seq", f"sequence file for '{kind}'")
        try:
            return super().allocate_id(kind)
        except StoreError as error:
            raise FabricError(str(error)) from None

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
        try:
            return self.write_atomic(self.path_for(kind, record.id), record.to_dict())
        except StoreError as error:
            raise FabricError(str(error)) from None

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
