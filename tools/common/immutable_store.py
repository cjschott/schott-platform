"""Append-only record storage, shared across layers.

The evidence, integrity, and experience stores each grew their own copy of this
write path. Each duplication was individually defensible — extending a released
store would have changed a layer the increment was told to leave alone — but
three copies of a correctness-critical routine is past the point where that
trade is worth making, and a fourth would be indefensible.

This is that routine, extracted once and parameterised by record kind. The
occurrence layer uses it. Migrating the existing three is deliberately *not*
done here: they are released or in review, and rewriting their storage during a
feature sprint would put the riskiest possible change in the least appropriate
place. The path is now available for that migration to happen on its own.

Guarantees, enforced here rather than by convention:

- **Explicit root.** Never defaults, and refuses a path inside a git repository
  unless a caller opts in, so generated records cannot land in tracked source.
- **Write once.** Writes go to a temp file and then `os.link` to the final
  name. `link` fails when the destination exists, which makes committing the
  write and refusing an overwrite the *same* atomic operation. `os.replace` is
  not used: it is equally atomic and it succeeds silently over an existing
  record.
- **No update, no delete.** Neither method exists. The only removal is cleanup
  of this module's own temp file after a failed write.
- **Monotonic identifiers.** Allocation holds an exclusive lock across the
  read-modify-write, and skips any identifier whose file already exists rather
  than assuming the sequence owns the name.
"""

from __future__ import annotations

import fcntl
import os
import re
from pathlib import Path
from typing import Any, Mapping

import yaml

DIR_MODE = 0o700
FILE_MODE = 0o600
MAX_SEQUENCE = 999_999


class StoreError(Exception):
    """A store operation was refused. Never contains a record value."""


def is_inside_git_repository(path: Path) -> bool:
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return True
    return False


class ImmutableStore:
    """Append-only storage rooted at an explicit directory.

    Subclasses declare their record kinds by supplying `record_dirs`,
    `id_patterns`, and `id_prefixes`; everything else is inherited.
    """

    # kind -> subdirectory name
    record_dirs: Mapping[str, str] = {}
    # kind -> compiled identifier pattern
    id_patterns: Mapping[str, re.Pattern] = {}
    # kind -> identifier prefix
    id_prefixes: Mapping[str, str] = {}
    # Extra directories to create beyond the record directories.
    extra_dirs: tuple[str, ...] = ("sequences",)

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False) -> None:
        if root is None or str(root).strip() == "":
            raise StoreError("a store root must be supplied explicitly")

        resolved = Path(root).expanduser().resolve()

        if not allow_repository_root and is_inside_git_repository(resolved):
            raise StoreError(
                "store root is inside a git repository; supply a dedicated data root "
                "or opt in explicitly for a test fixture"
            )

        self.root = resolved
        for name in (*self.record_dirs.values(), *self.extra_dirs):
            directory = self.root / name
            directory.mkdir(parents=True, exist_ok=True)
            try:
                directory.chmod(DIR_MODE)
            except OSError:
                # Best effort: some filesystems cannot express these modes, and
                # failing the write would be worse than a permissive one.
                pass

    # --- paths -------------------------------------------------------------

    def _directory(self, kind: str) -> Path:
        if kind not in self.record_dirs:
            raise StoreError(f"unknown record kind '{kind}'")
        return self.root / self.record_dirs[kind]

    def path_for(self, kind: str, identifier: str) -> Path:
        pattern = self.id_patterns.get(kind)
        if pattern and not pattern.match(str(identifier)):
            raise StoreError(f"identifier '{identifier}' is not valid for kind '{kind}'")
        return self._directory(kind) / f"{identifier}.yaml"

    # --- identifiers -------------------------------------------------------

    def allocate_id(self, kind: str) -> str:
        """Reserve the next identifier for a record kind."""
        if kind not in self.id_prefixes:
            raise StoreError(f"unknown record kind '{kind}'")
        prefix = self.id_prefixes[kind]
        sequence_file = self.root / "sequences" / f"{kind}.seq"

        handle = os.open(sequence_file, os.O_RDWR | os.O_CREAT, FILE_MODE)
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
            raw = os.read(handle, 64).decode("utf-8").strip()
            current = int(raw) if raw.isdigit() else 0

            candidate = current
            while True:
                candidate += 1
                if candidate > MAX_SEQUENCE:
                    raise StoreError(
                        f"{kind} sequence is exhausted; widening the identifier is a "
                        "deliberate decision, not an automatic rollover"
                    )
                identifier = f"{prefix}-{candidate:06d}"
                if kind in self.record_dirs and self.path_for(kind, identifier).exists():
                    # Something occupies this name. Skip it rather than reuse or
                    # overwrite a record this store did not create.
                    continue
                break

            os.lseek(handle, 0, os.SEEK_SET)
            os.truncate(handle, 0)
            os.write(handle, f"{candidate}\n".encode("utf-8"))
            os.fsync(handle)
            return identifier
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
            os.close(handle)

    # --- writing -----------------------------------------------------------

    def write_atomic(self, destination: Path, payload: dict[str, Any]) -> Path:
        """Write once, atomically, refusing to replace an existing record."""
        if destination.exists():
            raise StoreError(
                f"record '{destination.name}' already exists and is immutable"
            )

        text = yaml.safe_dump(payload, sort_keys=True, default_flow_style=False,
                              allow_unicode=True)
        # The temp file lives beside the destination so the link stays within
        # one filesystem, and carries .tmp so a leftover is obvious debris
        # rather than being mistaken for a record.
        temporary = destination.with_name(f".{destination.stem}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
        try:
            os.write(descriptor, text.encode("utf-8"))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        try:
            os.link(temporary, destination)
        except FileExistsError as error:
            temporary.unlink(missing_ok=True)  # remove our own temp, never a record
            raise StoreError(
                f"record '{destination.name}' already exists and is immutable"
            ) from error
        except OSError as error:
            temporary.unlink(missing_ok=True)  # remove our own temp, never a record
            raise StoreError(f"record '{destination.name}' could not be committed") from error
        finally:
            if temporary.exists():
                temporary.unlink(missing_ok=True)  # remove our own temp, never a record

        try:
            destination.chmod(FILE_MODE)
        except OSError:
            pass
        return destination

    def write_record(self, kind: str, record) -> Path:
        """Persist a record that exposes `id` and `to_dict()`."""
        return self.write_atomic(self.path_for(kind, record.id), record.to_dict())

    # --- reading -----------------------------------------------------------

    def read_record(self, kind: str, identifier: str) -> dict[str, Any]:
        path = self.path_for(kind, identifier)
        if not path.is_file():
            raise StoreError(f"record '{identifier}' does not exist")
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}

    def list_records(self, kind: str, target: str | None = None) -> list[dict[str, Any]]:
        """Return records, sorted by filename so ordering is deterministic."""
        records: list[dict[str, Any]] = []
        for path in sorted(self._directory(kind).glob("*.yaml")):
            record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            # A file that is not a mapping is not a record. Skipping keeps
            # listing usable; validate() is what reports it.
            if not isinstance(record, dict):
                continue
            if target is None or record.get("target") == target:
                records.append(record)
        return records

    # --- integrity ---------------------------------------------------------

    def validate(self) -> list[str]:
        """Return structural problems. Read-only; repairs nothing."""
        problems: list[str] = []
        for kind, directory in self.record_dirs.items():
            pattern = self.id_patterns.get(kind)
            for path in sorted((self.root / directory).glob("*.yaml")):
                record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
                if not isinstance(record, dict):
                    problems.append(f"{path.name}: file is not a record mapping")
                    continue
                identifier = str(record.get("id") or "")
                if pattern and not pattern.match(identifier):
                    problems.append(
                        f"{path.name}: id '{identifier}' does not match {pattern.pattern}")
                elif path.stem != identifier:
                    problems.append(f"{path.name}: filename does not match id '{identifier}'")
            for stray in sorted((self.root / directory).glob("*.tmp")):
                problems.append(f"{stray.name}: partial write left behind")
        return problems

    def counts(self) -> dict[str, int]:
        return {
            kind: len(list((self.root / directory).glob("*.yaml")))
            for kind, directory in self.record_dirs.items()
        }
