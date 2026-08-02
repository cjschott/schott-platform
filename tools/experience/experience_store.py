"""Append-only store for experience profiles, windows, and baselines.

Mirrors the write path used by the evidence and integrity stores: temp file,
then ``os.link`` to the final name, so committing the write and refusing an
overwrite are the same atomic operation.

This is the third copy of that pattern in the codebase. It is duplicated rather
than shared because extending either existing store with new record kinds would
change a layer this increment is meant to leave alone — but three copies is
past the point where duplication is the cheaper risk, and consolidating them
into one reusable immutable-store module is recorded as follow-up work in
ADR-0008.

There is no update method and no delete method. New observations create newer
records; nothing is ever revised.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
from typing import Any

import yaml

from .models import ID_PATTERNS, ID_PREFIXES

SUBDIRECTORIES = ("profiles", "windows", "baselines", "sequences")

RECORD_DIRS = {
    "profile": "profiles",
    "window": "windows",
    "baseline": "baselines",
}

DIR_MODE = 0o700
FILE_MODE = 0o600
MAX_SEQUENCE = 999_999


class StoreError(Exception):
    """A store operation was refused. Never contains an observed value."""


def _is_inside_git_repository(path: Path) -> bool:
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return True
    return False


class ExperienceStore:
    """Immutable storage for experience records."""

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False) -> None:
        if root is None or str(root).strip() == "":
            raise StoreError("a store root must be supplied explicitly")

        resolved = Path(root).expanduser().resolve()

        # Generated statistics under version control would sit beside reviewed
        # declared entities and invite the assumption they carry equal weight.
        if not allow_repository_root and _is_inside_git_repository(resolved):
            raise StoreError(
                "store root is inside a git repository; supply a dedicated data root "
                "or opt in explicitly for a test fixture"
            )

        self.root = resolved
        for name in SUBDIRECTORIES:
            directory = self.root / name
            directory.mkdir(parents=True, exist_ok=True)
            try:
                directory.chmod(DIR_MODE)
            except OSError:
                # Best effort: some filesystems cannot express these modes, and
                # failing the write would be worse than a permissive one.
                pass

    def _directory(self, kind: str) -> Path:
        if kind not in RECORD_DIRS:
            raise StoreError(f"unknown record kind '{kind}'")
        return self.root / RECORD_DIRS[kind]

    def path_for(self, kind: str, identifier: str) -> Path:
        pattern = ID_PATTERNS.get(kind)
        if pattern and not pattern.match(str(identifier)):
            raise StoreError(f"identifier '{identifier}' is not valid for kind '{kind}'")
        return self._directory(kind) / f"{identifier}.yaml"

    def allocate_id(self, kind: str) -> str:
        """Reserve the next identifier under an exclusive lock.

        An identifier whose file already exists is skipped rather than handed
        out: assuming the sequence owns a filename is how a store overwrites a
        record it did not know about.
        """
        if kind not in ID_PREFIXES:
            raise StoreError(f"unknown record kind '{kind}'")
        prefix = ID_PREFIXES[kind]
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
                if self.path_for(kind, identifier).exists():
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

    def _write_atomic(self, destination: Path, payload: dict[str, Any]) -> Path:
        """Write once, atomically, refusing to replace an existing record."""
        if destination.exists():
            raise StoreError(
                f"record '{destination.name}' already exists and is immutable"
            )

        text = yaml.safe_dump(payload, sort_keys=True, default_flow_style=False,
                              allow_unicode=True)
        temporary = destination.with_name(f".{destination.stem}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
        try:
            os.write(descriptor, text.encode("utf-8"))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        try:
            # link() fails when the destination exists, making the commit and
            # the overwrite refusal one atomic step.
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

    def write_profile(self, profile) -> Path:
        return self._write_atomic(self.path_for("profile", profile.id), profile.to_dict())

    def write_window(self, window) -> Path:
        return self._write_atomic(self.path_for("window", window.id), window.to_dict())

    def write_baseline(self, baseline) -> Path:
        return self._write_atomic(self.path_for("baseline", baseline.id), baseline.to_dict())

    def _load_all(self, kind: str, target: str | None) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for path in sorted(self._directory(kind).glob("*.yaml")):
            record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            if not isinstance(record, dict):
                continue
            if target is None or record.get("target") == target:
                records.append(record)
        return records

    def list_profiles(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("profile", target)

    def list_baselines(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("baseline", target)

    def latest_baseline(self, target: str, metric: str) -> dict[str, Any] | None:
        """The newest baseline for a metric. Older ones are never removed."""
        candidates = [b for b in self.list_baselines(target) if b.get("metric") == metric]
        if not candidates:
            return None
        return max(candidates, key=lambda b: (str(b.get("generated_at") or ""), str(b.get("id"))))

    def validate(self) -> list[str]:
        """Return structural problems. Read-only; repairs nothing."""
        problems: list[str] = []
        for kind, directory in RECORD_DIRS.items():
            pattern = ID_PATTERNS[kind]
            for path in sorted((self.root / directory).glob("*.yaml")):
                record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
                if not isinstance(record, dict):
                    problems.append(f"{path.name}: file is not a record mapping")
                    continue
                identifier = str(record.get("id") or "")
                if not pattern.match(identifier):
                    problems.append(f"{path.name}: id '{identifier}' does not match {pattern.pattern}")
                elif path.stem != identifier:
                    problems.append(f"{path.name}: filename does not match id '{identifier}'")
            for stray in sorted((self.root / directory).glob("*.tmp")):
                problems.append(f"{stray.name}: partial write left behind")
        return problems

    def counts(self) -> dict[str, int]:
        return {
            kind: len(list((self.root / directory).glob("*.yaml")))
            for kind, directory in RECORD_DIRS.items()
        }
