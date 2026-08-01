"""Append-only store for evidence, verifications, and knowledge events.

Every write is atomic and refuses to clobber. The pattern is write-to-temp
then `os.link` to the final name: `link` fails if the destination exists, so
refusing an overwrite and committing the write are the same atomic operation.
`os.replace` was rejected precisely because it succeeds silently over an
existing record.

There is no update method and no delete method in v0.7.0. Their absence is the
immutability guarantee — a store that can rewrite a record breaks every
conclusion that cited it.

The store root is always explicit. It never defaults, and it refuses to sit
inside a git repository unless a caller opts in, so a stray invocation cannot
scatter generated records through tracked source.

See docs/decisions/ADR-0004-immutable-knowledge-timeline.md.
"""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
from typing import Any, Iterable

import yaml

from .models import (
    ID_PATTERNS,
    ID_PREFIXES,
    EvidenceRecord,
    KnowledgeEvent,
    VerificationRecord,
)

# Directories created under an explicit store root.
SUBDIRECTORIES = ("evidence", "verifications", "events", "indexes", "state", "sequences")

RECORD_DIRS = {
    "evidence": "evidence",
    "verification": "verifications",
    "event": "events",
}

DIR_MODE = 0o700
FILE_MODE = 0o600

# A sequence will not be advanced past this without a deliberate review: six
# digits is a capacity decision, and silently rolling over would reuse ids.
MAX_SEQUENCE = 999_999


class StoreError(Exception):
    """A store operation was refused. Never contains a record value."""


def _is_inside_git_repository(path: Path) -> bool:
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return True
    return False


class EvidenceStore:
    """Immutable record storage rooted at an explicit directory."""

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False) -> None:
        if root is None or str(root).strip() == "":
            raise StoreError("a store root must be supplied explicitly")

        resolved = Path(root).expanduser().resolve()

        # Refusing a repository path is what stops generated runtime records
        # from being committed alongside declared model entities.
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
                # Permission tightening is best-effort: some filesystems do not
                # support it, and failing the write would be worse than a
                # permissive mode on a platform that cannot express one.
                pass

    # --- paths -------------------------------------------------------------

    def _directory(self, kind: str) -> Path:
        if kind not in RECORD_DIRS:
            raise StoreError(f"unknown record kind '{kind}'")
        return self.root / RECORD_DIRS[kind]

    def path_for(self, kind: str, identifier: str) -> Path:
        """Return the record path. Filenames always match identifiers."""
        pattern = ID_PATTERNS.get(kind)
        if pattern and not pattern.match(str(identifier)):
            raise StoreError(f"identifier '{identifier}' is not valid for kind '{kind}'")
        return self._directory(kind) / f"{identifier}.yaml"

    # --- identifier allocation --------------------------------------------

    def allocate_id(self, kind: str) -> str:
        """Reserve the next identifier for a record kind.

        Held under an exclusive lock on the sequence file, so two processes on
        this host cannot receive the same number. An identifier whose record
        path already exists is skipped rather than handed out: assuming the
        sequence owns a filename is how a store silently overwrites a record it
        did not know about.
        """
        if kind not in ID_PREFIXES:
            raise StoreError(f"unknown record kind '{kind}'")
        prefix = ID_PREFIXES[kind]
        sequence_file = self.root / "sequences" / f"{kind}.seq"

        # Opened O_CREAT so the first allocation creates the file, and locked
        # for the whole read-modify-write so the increment is not racy.
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
                if kind in RECORD_DIRS and self.path_for(kind, identifier).exists():
                    # Something occupies this name. Skip it and keep the
                    # sequence moving forward; never reuse or overwrite.
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

    def _write_atomic(self, destination: Path, payload: dict[str, Any]) -> Path:
        """Write once, atomically, refusing to replace an existing record."""
        if destination.exists():
            raise StoreError(
                f"record '{destination.name}' already exists and is immutable; "
                "evidence is never overwritten"
            )

        text = yaml.safe_dump(
            payload, sort_keys=True, default_flow_style=False, allow_unicode=True
        )

        # The temporary file lives beside the destination so the link below
        # stays within one filesystem, and carries a .tmp suffix so a leftover
        # is obvious rather than mistaken for a record.
        temporary = destination.with_name(f".{destination.stem}.tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, FILE_MODE)
        try:
            os.write(descriptor, text.encode("utf-8"))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        try:
            # link() fails if the destination exists, so committing the write
            # and refusing an overwrite are one atomic step.
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

    def write_evidence(self, record: EvidenceRecord) -> Path:
        return self._write_atomic(self.path_for("evidence", record.id), record.to_dict())

    def write_verification(self, record: VerificationRecord) -> Path:
        return self._write_atomic(self.path_for("verification", record.id), record.to_dict())

    def write_event(self, event: KnowledgeEvent) -> Path:
        return self._write_atomic(self.path_for("event", event.id), event.to_dict())

    # --- reading -----------------------------------------------------------

    def read(self, kind: str, identifier: str) -> dict[str, Any]:
        path = self.path_for(kind, identifier)
        if not path.is_file():
            raise StoreError(f"record '{identifier}' does not exist")
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}

    def read_evidence(self, identifier: str) -> dict[str, Any]:
        return self.read("evidence", identifier)

    def read_verification(self, identifier: str) -> dict[str, Any]:
        return self.read("verification", identifier)

    def read_event(self, identifier: str) -> dict[str, Any]:
        return self.read("event", identifier)

    def _load_all(self, kind: str, target: str | None) -> list[dict[str, Any]]:
        directory = self._directory(kind)
        records: list[dict[str, Any]] = []
        # Sorted by filename so listing order is deterministic and matches
        # allocation order for zero-padded identifiers.
        for path in sorted(directory.glob("*.yaml")):
            record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            # A file that is not a mapping is not a record. Skipping it here
            # keeps listing usable; validate() is what reports it as a problem.
            if not isinstance(record, dict):
                continue
            if target is None or record.get("target") == target:
                records.append(record)
        return records

    def list_evidence(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("evidence", target)

    def list_verifications(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("verification", target)

    def list_events(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("event", target)

    # --- derived artefacts -------------------------------------------------

    def rebuild_index(self) -> Path:
        """Rebuild the by-target index from immutable records.

        Indexes are derived and replaceable, so this one may be overwritten
        where a record may not. Anything it holds can be recomputed from the
        records themselves.
        """
        index: dict[str, dict[str, list[str]]] = {}
        for kind in ("evidence", "verification", "event"):
            for record in self._load_all(kind, None):
                target = str(record.get("target") or "unknown")
                bucket = index.setdefault(target, {"evidence": [], "verification": [], "event": []})
                identifier = str(record.get("id") or "")
                if identifier:
                    bucket[kind].append(identifier)

        payload = {
            "kind": "derived-index",
            "note": "rebuildable from immutable records; not authoritative",
            "targets": {t: {k: sorted(v) for k, v in sorted(b.items())}
                        for t, b in sorted(index.items())},
        }
        path = self.root / "indexes" / "by-target.yaml"
        text = yaml.safe_dump(payload, sort_keys=True, default_flow_style=False)
        # Derived output only: replaced wholesale rather than appended to.
        path.write_text(text, encoding="utf-8")
        try:
            path.chmod(FILE_MODE)
        except OSError:
            pass
        return path

    def newest_evidence_time(self, target: str) -> str | None:
        stamps = [r.get("collected_at") for r in self.list_evidence(target) if r.get("collected_at")]
        return max(stamps) if stamps else None

    # --- integrity ---------------------------------------------------------

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
                if not record.get("target"):
                    problems.append(f"{path.name}: target is missing")
            leftovers = sorted(p.name for p in (self.root / directory).glob("*.tmp"))
            for name in leftovers:
                problems.append(f"{name}: partial write left behind")
        return problems

    def counts(self) -> dict[str, int]:
        return {
            kind: len(list((self.root / directory).glob("*.yaml")))
            for kind, directory in RECORD_DIRS.items()
        }
