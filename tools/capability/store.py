"""Append-only storage for Capability Runtime records — a second plane.

The Fabric store records what may exist. This one records what was attempted.
They are deliberately separate: the Fabric's eight record kinds are an
invariant its validator and inspection surface enforce, and execution evidence
that lived there would be a ninth. So this store owns its own root, its own
identifier space, its own sequences, and its own lock, and it writes no Fabric
record ever.

**It carries no authority.** Nothing written here governs, selects, or trusts
anything. A record is evidence that an invocation was prepared or refused —
never evidence that it was permitted. Authority arrives from the Fabric
decision upstream and does not flow back.

**Ownership is supplied, never inferred**, and paths are inspected before they
are followed — the released discipline, applied again rather than reinvented.
A path whose owner disagrees is refused and reported; nothing here calls
`chown`, because repairing ownership erases the evidence that it was wrong.

**A pre-existing temporary artefact is evidence, not debris.** It is what an
interrupted write leaves behind, so a write that finds one refuses rather than
truncating it.

This increment stores records. It prepares nothing, verifies nothing, resolves
nothing, and **executes nothing** — there is no adapter here, and no path
through this module reaches one.
"""

from __future__ import annotations

import fcntl
import os
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping

import yaml

from ..common.containment import contained_path
from ..common.immutable_store import (DIR_MODE, FILE_MODE, MAX_SEQUENCE, ImmutableStore,
                                      StoreError)
from .errors import CapabilityError
from .identifiers import ID_FIELDS, ID_WIDTHS, PATTERNS, PREFIXES, RECORD_DIRS


class CapabilityStore(ImmutableStore):
    """The Capability Runtime store, rooted at an explicit directory."""

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
            raise CapabilityError("a store root must be supplied explicitly")
        if not isinstance(expected_uid, int) or isinstance(expected_uid, bool):
            raise CapabilityError("expected_uid must be supplied as an integer")
        if not isinstance(expected_gid, int) or isinstance(expected_gid, bool):
            raise CapabilityError("expected_gid must be supplied as an integer")
        self._expected_uid = expected_uid
        self._expected_gid = expected_gid

        supplied = Path(root).expanduser()
        self._reject_link(supplied, "store root")
        try:
            super().__init__(root, allow_repository_root=allow_repository_root)
        except StoreError as error:
            raise CapabilityError(str(error)) from None

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
            raise CapabilityError(f"{description} could not be inspected") from error
        if stat.S_ISLNK(entry.st_mode):
            raise CapabilityError(f"{description} is a symbolic link")

    def _require_ownership(self, path: Path, description: str) -> None:
        """Compare a real inode's owner with the supplied values. Never repairs."""
        try:
            entry = path.lstat()
        except FileNotFoundError:
            return
        except OSError as error:
            raise CapabilityError(f"{description} could not be inspected") from error
        if entry.st_uid != self._expected_uid or entry.st_gid != self._expected_gid:
            raise CapabilityError(f"{description} is not owned by the supplied uid/gid")

    def _guard_path(self, path: Path, description: str) -> Path:
        """Refuse a link or an escape, then return the contained path.

        Order matters. The link check runs on the unresolved path and on every
        unresolved parent up to the root, because resolving first would follow
        the link this check exists to catch. Containment itself is the shared
        primitive's question, asked once and answered the same way everywhere.
        """
        candidate = Path(path)
        for entry in (candidate, *candidate.parents):
            if entry == self.root or self.root in entry.parents:
                self._reject_link(entry, f"{description} path component")

        if candidate != self.root:
            relative = os.path.relpath(str(candidate), str(self.root))
            if contained_path(self.root, relative) is None:
                raise CapabilityError(f"{description} resolves outside the store root")
        self._require_ownership(candidate, description)
        return candidate

    def _create_directories(self) -> None:
        """Verify what exists; create only what does not.

        The inherited body chmods directories that already exist, which would
        silently correct a mode this store is supposed to refuse.
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
                    raise CapabilityError(
                        f"record directory '{name}' has mode {oct(mode)}, not {oct(DIR_MODE)}")
                continue

            # Creating means becoming the owner. If this process is not the
            # expected owner, the created path would be wrong the instant it
            # existed, so refuse before creating anything.
            if os.geteuid() != self._expected_uid or os.getegid() != self._expected_gid:
                raise CapabilityError(
                    "the running process does not match the supplied uid/gid")
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(DIR_MODE)
            self._require_ownership(directory, f"record directory '{name}'")

        # The invocation identity lock belongs to the store's layout, not to
        # any operation. Created here, a refusal that merely enters the section
        # cannot be the thing that first changes the store.
        os.close(self._open_invocation_lock())

    def _open_invocation_lock(self) -> int:
        """The one lock file, guarded and opened. Never read, never written."""
        sequences = self._guard_path(self.root / "sequences", "sequence directory")
        lock_path = self._guard_path(sequences / "invocation_identity.lock",
                                     "invocation identity lock")
        handle = os.open(lock_path, os.O_RDWR | os.O_CREAT, FILE_MODE)
        self._require_ownership(lock_path, "invocation identity lock")
        return handle

    @classmethod
    def open_for_read(cls, root: Path | str, *, expected_uid: int, expected_gid: int,
                      allow_repository_root: bool = False) -> "CapabilityStore":
        """Open without creating any part of the store.

        An absent store is reported as absent, never built and then described.
        """
        store = cls.__new__(cls)
        if root is None or str(root).strip() == "":
            raise CapabilityError("a store root must be supplied explicitly")
        if not isinstance(expected_uid, int) or isinstance(expected_uid, bool):
            raise CapabilityError("expected_uid must be supplied as an integer")
        if not isinstance(expected_gid, int) or isinstance(expected_gid, bool):
            raise CapabilityError("expected_gid must be supplied as an integer")
        store._expected_uid = expected_uid
        store._expected_gid = expected_gid

        supplied = Path(root).expanduser()
        store._reject_link(supplied, "store root")
        try:
            ImmutableStore.__init__(
                store, root, allow_repository_root=allow_repository_root,
                initialize=False)
        except StoreError as error:
            raise CapabilityError(str(error)) from None
        store._require_ownership(store.root, "store root")
        return store

    @contextmanager
    def invocation_critical_section(self, invocation_id: str) -> Iterator[None]:
        """Serialise invocation-identity lookup, allocation, and the write.

        Its own lock, in its own store. The Fabric's request lock governs
        governed decisions and is store-global and non-reentrant; borrowing it
        here would let a Capability Runtime operation block every Fabric write
        in an unrelated plane. Nothing in this module touches it.

        One lock file, not one per invocation. `invocation_id` is opaque and
        caller-supplied, so deriving a filename from it would put caller text
        into a path; it is taken here only so a coordinating test can observe
        which invocation waited.
        """
        handle = self._open_invocation_lock()
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                # Released however this section ends: a refusal and a traceback
                # both leave the next caller able to proceed.
                fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)

    # --- guarded inherited surface ------------------------------------------

    def _directory(self, kind: str) -> Path:
        try:
            directory = super()._directory(kind)
        except StoreError as error:
            raise CapabilityError(str(error)) from None
        return self._guard_path(directory, f"record directory for '{kind}'")

    def path_for(self, kind: str, identifier: str) -> Path:
        # Inherited identifier validation first: a traversing identifier is not
        # a valid identifier, and should be refused as one.
        try:
            destination = super().path_for(kind, identifier)
        except StoreError as error:
            raise CapabilityError(str(error)) from None
        return self._guard_path(destination, f"record '{identifier}'")

    def peek_next_id(self, kind: str) -> str:
        """The identifier `allocate_id` would return, without spending it.

        Reads only. It never opens the sequence for writing, never creates it,
        never takes the lock, and advances nothing: a prediction that consumed
        the thing it predicted would be an allocation wearing a different name.

        The candidate rule is the base class's -- next value, skipping any name
        a record already occupies -- restated here rather than shared, because
        `tools.common.immutable_store` is an installed Generation-10 object and
        reaching into it to add a read-only helper would open a generation for a
        plane that does not need one. The Fabric store made the same call for
        the same reason.

        It is a prediction, not a reservation. Another caller may take it in
        between, which is why the write path allocates for itself.
        """
        if kind not in self.id_prefixes:
            raise CapabilityError(f"unknown record kind '{kind}'")
        prefix = self.id_prefixes[kind]
        width = self.id_widths.get(kind, 6)
        kind_maximum = min(10 ** width - 1, MAX_SEQUENCE)
        try:
            raw = (self.root / "sequences" / f"{kind}.seq").read_text(
                encoding="utf-8").strip()
        except OSError:
            # An absent sequence reads as zero rather than being created, so
            # asking what comes next never provisions the thing being asked
            # about.
            raw = ""
        candidate = int(raw) if raw.isdigit() else 0
        while True:
            candidate += 1
            if candidate > kind_maximum:
                raise CapabilityError(
                    f"{kind} sequence is exhausted; widening the identifier is a "
                    "deliberate decision, not an automatic rollover")
            identifier = f"{prefix}-{candidate:0{width}d}"
            if kind in self.record_dirs and self.path_for(kind, identifier).exists():
                continue
            return identifier

    def allocate_id(self, kind: str) -> str:
        if kind not in self.id_prefixes:
            raise CapabilityError(f"unknown record kind '{kind}'")
        sequences = self._guard_path(self.root / "sequences", "sequence directory")
        self._guard_path(sequences / f"{kind}.seq", f"sequence file for '{kind}'")
        try:
            return super().allocate_id(kind)
        except StoreError as error:
            raise CapabilityError(str(error)) from None

    def write_atomic(self, destination: Path, payload: Mapping[str, Any]) -> Path:
        guarded = self._guard_path(Path(destination), "record destination")
        temporary = guarded.with_name(f".{guarded.stem}.tmp")
        self._guard_path(temporary, "temporary artefact")
        if guarded.exists():
            raise CapabilityError(f"record '{guarded.name}' already exists")
        try:
            return super().write_atomic(guarded, dict(payload))
        except StoreError as error:
            raise CapabilityError(str(error)) from None

    def read_record(self, kind: str, identifier: str) -> dict[str, Any]:
        """One record, read only if it is coherently one.

        A malformed record is refused rather than yielding a partial value: a
        caller that receives half a record cannot tell which half it got.
        """
        path = self.path_for(kind, identifier)
        try:
            entry = path.lstat()
        except FileNotFoundError:
            raise CapabilityError(f"record '{identifier}' does not exist") from None
        except OSError as error:
            raise CapabilityError(f"record '{identifier}' could not be inspected") from error
        if not stat.S_ISREG(entry.st_mode):
            raise CapabilityError(f"record '{identifier}' is not a regular file")

        try:
            record = yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError):
            raise CapabilityError(f"record '{identifier}' is not readable") from None
        if not isinstance(record, dict):
            raise CapabilityError(f"record '{identifier}' does not carry a mapping")
        if str(record.get(ID_FIELDS[kind]) or "") != identifier:
            raise CapabilityError(
                f"record '{identifier}' carries an identity that is not its own")
        return record

    def validate(self) -> list[str]:
        """Structural problems, in deterministic order. Repairs nothing.

        The inherited body reads a universal `id` field and globs `*.tmp`;
        neither matches this store, whose kinds name their own identity field
        and whose temporaries are hidden siblings.
        """
        problems: list[str] = []
        for kind in sorted(self.record_dirs):
            directory = self.root / self.record_dirs[kind]
            pattern = self.id_patterns.get(kind)
            field = ID_FIELDS[kind]
            if not directory.is_dir():
                problems.append(f"{self.record_dirs[kind]}: record directory is missing")
                continue
            for path in sorted(directory.glob("*.yaml")):
                try:
                    record = yaml.safe_load(path.read_text(encoding="utf-8"))
                except (OSError, yaml.YAMLError):
                    problems.append(f"{path.name}: file is not readable")
                    continue
                if not isinstance(record, dict):
                    problems.append(f"{path.name}: file is not a record mapping")
                    continue
                identifier = str(record.get(field) or "")
                if pattern and not pattern.match(identifier):
                    problems.append(
                        f"{path.name}: {field} '{identifier}' does not match {pattern.pattern}")
                elif path.stem != identifier:
                    problems.append(
                        f"{path.name}: filename does not match {field} '{identifier}'")
            for stray in sorted(directory.glob(".*.tmp")):
                problems.append(f"{stray.name}: partial write left behind")
        return problems
