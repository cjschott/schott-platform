"""Append-only filesystem storage for Health records.

ENG-0006-H6, covering B1 (the store and its filesystem boundary) and B2
(identifier allocation and widths) of the committed ENG-0006-D plan.

This module adds no write path. `tools.common.immutable_store` already owns
one -- write-once via `os.link`, flock'd monotonic allocation, no update and
no delete method -- and ENG-0006-D names it as the declared base precisely so
the Health plane does not grow a fourth copy of a correctness-critical
routine. What is added here is the part that is genuinely Health-specific:

- **Six closed families.** The directory layout is derived from the record
  model's own `KINDS`, so the store cannot describe a family the model does
  not define, and a seventh family cannot appear in one place only.
- **Identity by family.** The shared base reads `record.id`. A Health record
  has no `id`: each family names its identifier after itself. Both the write
  path and validation are overridden to read the declared identity field, and
  because those field names are unique per family, the identity field doubles
  as the check that a record was handed to the right kind.
- **A name is not a line.** `path_for` fullmatches the committed identifier
  pattern instead of matching it. `$` also matches immediately before a
  trailing newline, so `match` on a `^...$` pattern accepts
  `'CHOBS-000001\\n'` -- which the record model admits today -- and would turn
  it into a filename carrying a newline.
- **Refusing a root rather than following it.** Symlinked roots, another
  plane's storage, and the production Health root are refused before anything
  is created.

What this module deliberately does NOT do: it does not create
`/var/lib/kyri/health`, it does not read a clock, and it does not decide when
a record should be written. Those belong to H18, to the caller, and to the
evaluators respectively.
"""

from __future__ import annotations

import fcntl
import os
import stat
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping

import yaml

from ..common.immutable_store import FILE_MODE, ImmutableStore, StoreError
from .records import IDENTITY_FIELD, KINDS, PATTERNS

__all__ = ["HealthStore", "HealthStoreError", "ID_PREFIXES", "ID_WIDTHS",
           "RECORD_DIRS"]

# One exception, not two that mean the same thing. Everything added here
# raises what the shared write path already raises, so a caller wrapping a
# store operation has a single type to catch.
HealthStoreError = StoreError

# Derived from the record model rather than restated, so the store cannot name
# a family the model does not define. ADR-0013's six: CHENV, CHOBS, CHSTATE,
# CHDEG, CHREC, CHBEAT.
RECORD_DIRS: Mapping[str, str] = {kind: f"{kind}s" for kind in KINDS}

ID_PREFIXES: Mapping[str, str] = {
    "capability-health-envelope": "CHENV",
    "capability-health-observation": "CHOBS",
    "capability-health-state": "CHSTATE",
    "capability-degradation-event": "CHDEG",
    "capability-health-recommendation": "CHREC",
    "capability-heartbeat": "CHBEAT",
}

# CHENV is four digits; the other five are six. This is the committed schema's
# distinction, not a convenience -- an envelope is authored, and the other
# families are produced by collection. The widths are restated here because
# the base needs them as data; that they still agree with the schema is
# asserted by the suite, which allocates one identifier per family and
# fullmatches it against the family's own committed pattern.
ID_WIDTHS: Mapping[str, int] = {
    "capability-health-envelope": 4,
    "capability-health-observation": 6,
    "capability-health-state": 6,
    "capability-degradation-event": 6,
    "capability-health-recommendation": 6,
    "capability-heartbeat": 6,
}

# Production roots, named here so they can be REFUSED. H6 provisions nothing:
# the Health root is created by H18 under operator control, and the Fabric and
# Trust roots belong to other planes and are not this store's to open at all.
PRODUCTION_ROOT = Path("/var/lib/kyri/health")        # prod-path-reference
FOREIGN_PLANE_ROOTS = (
    Path("/var/lib/kyri/fabric"),                     # prod-path-reference
    Path("/var/lib/kyri/trust"),                      # prod-path-reference
)


class HealthStore(ImmutableStore):
    """The append-only Health record store."""

    record_dirs = RECORD_DIRS
    id_patterns = PATTERNS
    id_prefixes = ID_PREFIXES
    id_widths = ID_WIDTHS
    extra_dirs = ("sequences",)
    # A pre-existing `.tmp` artefact is someone else's interrupted write. With
    # O_EXCL, creating the temporary and refusing an existing one are the same
    # atomic operation, so the artefact is never truncated by the gap between
    # checking and opening.
    exclusive_temporary_create = True

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False,
                 initialize: bool = True) -> None:
        vetted = self._vetted_root(root, initialize=initialize)
        super().__init__(vetted, allow_repository_root=allow_repository_root,
                         initialize=initialize)
        self._section_held = False
        if initialize:
            for name in (*self.record_dirs.values(), *self.extra_dirs):
                self._vetted_directory(self.root / name, name)
            # ENG-0006-H7a. The lock belongs to the store's layout, not to an
            # operation: created lazily, the first refused ingestion on a fresh
            # store would add a file, and a refusal must change nothing.
            os.close(self._open_request_lock())

    # --- roots and directories ---------------------------------------------

    @staticmethod
    def _vetted_root(root: Path | str, *, initialize: bool) -> Path:
        if root is None or str(root).strip() == "":
            raise StoreError("a store root must be supplied explicitly")
        given = Path(root).expanduser()
        # Refused, not followed. Resolving a symlinked root would report the
        # target as the root, which is how a store ends up writing somewhere
        # nobody named -- and the check must precede resolution, because
        # resolution is what destroys the evidence.
        if given.is_symlink():
            raise StoreError(
                f"store root '{given}' is a symbolic link; supply a real directory")
        resolved = given.resolve()
        for plane in FOREIGN_PLANE_ROOTS:
            if resolved.is_relative_to(plane):
                raise StoreError(
                    f"store root '{resolved}' is inside another plane's storage "
                    f"at '{plane}'")
        # Reading a production store that an operator has already created is
        # legitimate; CREATING one is not. The refusal is therefore tied to
        # provisioning, so a future read-only adapter is not locked out.
        if initialize and resolved.is_relative_to(PRODUCTION_ROOT):
            raise StoreError(
                f"refusing to provision the production Health root "
                f"'{PRODUCTION_ROOT}'; it is created under operator control, "
                "not by a library call")
        return resolved

    @staticmethod
    def _vetted_directory(directory: Path, name: str) -> Path:
        if directory.is_symlink():
            raise StoreError(
                f"'{name}' is a symbolic link, not a store directory")
        if directory.exists() and not directory.is_dir():
            raise StoreError(f"'{name}' exists and is not a directory")
        return directory

    def _directory(self, kind: str) -> Path:
        return self._vetted_directory(super()._directory(kind),
                                      self.record_dirs[kind])

    def path_for(self, kind: str, identifier: Any) -> Path:
        pattern = self.id_patterns.get(kind)
        if pattern is None:
            raise StoreError(f"unknown record kind '{kind}'")
        # fullmatch, NOT match. `$` also matches immediately before a trailing
        # newline, so `match` on a `^...$` pattern accepts 'CHOBS-000001\n'.
        # Fullmatching is also what makes containment structural rather than
        # checked: a pattern of a fixed prefix and digits cannot express '/'
        # or '..', so no identifier that passes can leave its directory.
        if not isinstance(identifier, str) or pattern.fullmatch(identifier) is None:
            raise StoreError(
                f"identifier {identifier!r} is not valid for kind '{kind}'")
        path = self._directory(kind) / f"{identifier}.yaml"
        # A symlink occupying a record name is refused rather than skipped or
        # written through. The base skips an occupied name during allocation,
        # which is right for a record this store did not create; a symlink
        # inside a 0700 directory is not a record, and hiding it would be
        # worse than refusing.
        if path.is_symlink():
            raise StoreError(
                f"record path for {identifier!r} is a symbolic link")
        return path

    # --- the store-wide critical section (ENG-0006-H7a) ---------------------

    def _open_request_lock(self) -> int:
        """The one lock file, opened without following a link, then checked.

        Never read, never written, never deleted. Checked through the
        descriptor rather than the path, so the file checked is the file held.
        """
        sequences = self._vetted_directory(self.root / "sequences", "sequences")
        try:
            handle = os.open(sequences / "request_identity.lock",
                             os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
                             | os.O_NONBLOCK, FILE_MODE)
        except OSError as error:
            # ELOOP for a symlink in the lock's place; anything else is equally
            # a lock this store cannot vouch for.
            raise StoreError("the request identity lock could not be opened "
                             "as a regular file") from error
        try:
            entry = os.fstat(handle)
            if not stat.S_ISREG(entry.st_mode):
                raise StoreError("the request identity lock is not a regular file")
            if entry.st_uid != os.geteuid():
                raise StoreError(
                    "the request identity lock is not owned by the store's user")
            if entry.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                raise StoreError(
                    "the request identity lock is writable beyond its owner")
        except BaseException:
            os.close(handle)
            raise
        return handle

    def _test_sync_point(self, phase: str, request_id: str) -> None:
        """Named point a coordinating test can observe. Production no-op.

        The Fabric's seam, restated: a deterministic two-caller test needs a
        positive signal that a caller reached a phase, not an inference from
        elapsed time. This writes nothing, holds nothing and returns nothing.
        """

    @contextmanager
    def request_critical_section(self, request_id: str) -> Iterator[None]:
        """Serialise replay lookup, subject checks, allocation, write and readback.

        The pattern of `tools/fabric/store.py`, restated here because Health may
        not import the Fabric. **Store-global**: one `flock` on
        `sequences/request_identity.lock` for every envelope write, whatever its
        request identity; `request_id` never names the lock and is passed only
        so contention is reported against the request that waited.

        **Not reentrant, and refused rather than hung.** An `flock` on a fresh
        descriptor blocks against the same process's own hold, so a second
        entry through this store object while it holds the section is refused.
        One store object serves one governed operation at a time; concurrent
        callers use their own store objects, as separate processes do.

        **Advisory.** `flock` serialises cooperating writers only. A process
        that writes the store directly is not stopped by it; that is detection,
        at ingestion of the same subject and by H7b's `verify`, not prevention.
        """
        if self._section_held:
            raise StoreError("the request critical section is not reentrant")
        handle = self._open_request_lock()
        try:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                # Fires only when someone else actually holds the lock, so a
                # test waits on a positive event rather than on elapsed time.
                self._test_sync_point("lock_contended", request_id)
                fcntl.flock(handle, fcntl.LOCK_EX)
            self._section_held = True
            try:
                yield
            finally:
                self._section_held = False
                # Released however the section ends: a refusal and a traceback
                # both leave the next caller able to proceed. A killed process
                # releases it when the kernel closes the descriptor.
                fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)

    # --- writing -----------------------------------------------------------

    def identifier_of(self, kind: str, record: Any) -> str:
        """The record's declared identity field.

        The base reads `record.id`, which raises on a Health record: the six
        families each name their identifier after themselves. Because those
        names are unique per family, reading the declared one is also what
        refuses a record handed to the wrong kind.
        """
        field = IDENTITY_FIELD.get(kind)
        if field is None:
            raise StoreError(f"unknown record kind '{kind}'")
        try:
            return getattr(record, field)
        except AttributeError as error:
            raise StoreError(
                f"record carries no '{field}', so it is not a {kind}") from error

    def write_record(self, kind: str, record) -> Path:
        """Persist a Health record under its own identity field."""
        destination = self.path_for(kind, self.identifier_of(kind, record))
        return self.write_atomic(destination, record.to_dict())

    # --- serialisation without a write (ENG-0006-H7a) ----------------------

    @staticmethod
    def render_record(record) -> str:
        """The exact text `write_record` would persist for `record`.

        The options are `ImmutableStore.write_atomic`'s, restated because the
        shared write path is not changed by this increment; the store suite
        proves the rendered text equals the committed file byte for byte.
        """
        return yaml.safe_dump(record.to_dict(), sort_keys=True,
                              default_flow_style=False, allow_unicode=True)

    @classmethod
    def preview_readback(cls, record) -> Any:
        """What reading `record` back would return, computed without writing.

        Lets ingestion prove a record survives the store's serialisation before
        an identifier is allocated, so an unstable record is refused while the
        refusal still costs nothing.
        """
        return yaml.safe_load(cls.render_record(record))

    def scan_records(self, kind: str) -> list[tuple[str, Any]]:
        """Every record file of `kind` as (stem, payload), sorted by name.

        Unlike `list_records`, nothing is skipped: a file that is not readable
        as a YAML mapping is returned with payload `None`, because a caller
        deciding what a subject already has must not mistake an unreadable
        record for an absent one. Symbolic links count as unreadable.
        """
        found: list[tuple[str, Any]] = []
        for path in sorted(self._directory(kind).glob("*.yaml")):
            if path.is_symlink():
                found.append((path.stem, None))
                continue
            try:
                payload = yaml.safe_load(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, yaml.YAMLError):
                payload = None
            found.append((path.stem, payload if isinstance(payload, dict) else None))
        return found

    # --- integrity ---------------------------------------------------------

    def validate(self) -> list[str]:
        """Return structural problems. Read-only; repairs nothing.

        Overridden because the base reads `record.get("id")`, which no Health
        record carries: against this store it would report every correct
        record as broken and every identity mismatch as the same problem.
        """
        problems: list[str] = []
        for kind, directory in self.record_dirs.items():
            pattern = self.id_patterns[kind]
            field = IDENTITY_FIELD[kind]
            base = self.root / directory
            if base.is_symlink():
                problems.append(f"{directory}: record directory is a symbolic link")
                continue
            for path in sorted(base.glob("*.yaml")):
                if path.is_symlink():
                    problems.append(f"{path.name}: record file is a symbolic link")
                    continue
                try:
                    record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
                except yaml.YAMLError:
                    # A corrupt file is a finding to report, not an exception
                    # to raise: one unreadable record must not cost the
                    # operator the report on all the others.
                    problems.append(f"{path.name}: file is not readable as YAML")
                    continue
                if not isinstance(record, dict):
                    problems.append(f"{path.name}: file is not a record mapping")
                    continue
                identifier = str(record.get(field) or "")
                if pattern.fullmatch(identifier) is None:
                    problems.append(
                        f"{path.name}: {field} '{identifier}' does not match "
                        f"{pattern.pattern}")
                elif path.stem != identifier:
                    problems.append(
                        f"{path.name}: filename does not match {field} '{identifier}'")
            for stray in sorted(base.glob("*.tmp")):
                problems.append(f"{stray.name}: partial write left behind")
        return problems
