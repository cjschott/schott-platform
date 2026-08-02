"""Create and store immutable operational snapshots.

A snapshot is a known-good reference point. It is written once and never
revised: a reference that can change after something cited it is not a
reference. A newer snapshot of the same target is a new record, and the older
one stays readable.

Snapshot creation is deterministic. The same knowledge and the same identifier
reproduce a byte-identical record, which is what makes a snapshot verifiable
rather than merely stored.

The store deliberately mirrors `tools/observation/evidence_store.py` rather
than extending it. Adding record kinds to the evidence store would change the
orchestration layer, which is out of scope for this increment; duplicating a
small, well-understood write path is the cheaper of the two risks.

Nothing here contacts a host, runs a command, or modifies the declared model.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
from typing import Any

import yaml

from .models import (
    ID_PATTERNS,
    ID_PREFIXES,
    SNAPSHOT_SCHEMA_VERSION,
    SnapshotRecord,
    readonly_facts,
    require_timezone,
)

SUBDIRECTORIES = ("snapshots", "twins", "reports", "plans", "sequences")

RECORD_DIRS = {
    "snapshot": "snapshots",
    "twin": "twins",
    "integrity": "reports",
    "recovery": "plans",
}

DIR_MODE = 0o700
FILE_MODE = 0o600
MAX_SEQUENCE = 999_999


class StoreError(Exception):
    """A store operation was refused. Never contains a record value."""


class SnapshotError(Exception):
    """A snapshot could not be created. Never contains a flagged value."""


def _is_inside_git_repository(path: Path) -> bool:
    for candidate in [path, *path.parents]:
        if (candidate / ".git").exists():
            return True
    return False


def fingerprint_facts(facts: dict[str, Any], *, target: str, schema_version: str) -> str:
    """Deterministic sha256 over the normalized snapshot payload.

    The target and schema version participate: the same facts about two
    different targets are not the same state, and a payload shape change must
    produce a different fingerprint rather than silently comparing equal.
    """
    payload = {
        "target": target,
        "schema_version": schema_version,
        "facts": {str(k): facts[k] for k in sorted(facts)},
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"),
                         default=str).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def create_snapshot(knowledge, evidence_store, *, snapshot_id: str,
                    created_at: str, label: str = "") -> SnapshotRecord:
    """Build an immutable snapshot from a derived knowledge state.

    The evidence store is required because a knowledge state cites evidence by
    identifier and does not carry the facts themselves. Reading them here keeps
    the observation package untouched: a snapshot is assembled from what the
    pipeline already recorded, never from anything this module invents.

    Reads and returns a record. It persists nothing — the caller decides
    whether a snapshot becomes durable, exactly as the orchestrator decides
    what becomes evidence.
    """
    if knowledge is None:
        raise SnapshotError("a knowledge state is required to create a snapshot")
    if evidence_store is None:
        raise SnapshotError("an evidence store is required to resolve knowledge facts")

    pattern = ID_PATTERNS["snapshot"]
    if not pattern.match(str(snapshot_id)):
        raise SnapshotError(f"snapshot identifier '{snapshot_id}' is not valid")

    stamp = require_timezone(created_at, "created_at")

    # Facts come from the knowledge state's supporting evidence, already
    # redacted by the observation pipeline. Nothing is invented here: a
    # snapshot records what was known, never what ought to be true.
    target = str(getattr(knowledge, "target", "") or "")
    if not target:
        raise SnapshotError("knowledge state has no target")
    facts = facts_from_evidence(evidence_store, target, knowledge)

    confidence = getattr(knowledge, "confidence", None)
    overall = getattr(confidence, "overall", None) if confidence is not None else None

    return SnapshotRecord(
        id=snapshot_id,
        target=target,
        created_at=stamp,
        label=str(label),
        facts=readonly_facts(facts),
        content_fingerprint=fingerprint_facts(
            facts, target=target, schema_version=SNAPSHOT_SCHEMA_VERSION),
        source_knowledge_generated_at=getattr(knowledge, "generated_at", None),
        supporting_evidence=tuple(getattr(knowledge, "supporting_evidence", ()) or ()),
        knowledge_confidence=round(overall, 4) if isinstance(overall, (int, float)) else None,
        schema_version=SNAPSHOT_SCHEMA_VERSION,
    )


def facts_from_evidence(evidence_store, target: str, knowledge=None) -> dict[str, Any]:
    """Collect the observed facts a knowledge state rests on.

    Reads only the evidence the knowledge state cites, so a snapshot reflects
    the conclusion it was taken from rather than everything the store happens
    to hold. Facts are taken as observed: none is derived, defaulted, or
    filled in, because a snapshot that invents a value is not a record of a
    known-good state.

    Evidence is applied oldest first, so the newest observation of a fact wins
    without any record being modified.
    """
    cited = set(getattr(knowledge, "supporting_evidence", ()) or ()) if knowledge else set()
    records = evidence_store.list_evidence(target)

    ordered = sorted(
        (r for r in records if not cited or str(r.get("id")) in cited),
        key=lambda r: (str(r.get("collected_at") or ""), str(r.get("id") or "")),
    )

    facts: dict[str, Any] = {}
    for record in ordered:
        # A failed collection learned nothing about the target; folding its
        # facts into a known-good snapshot would record an absence as a state.
        if str(record.get("status")) in {"failed", "unavailable"}:
            continue
        for name, value in (record.get("facts") or {}).items():
            facts[str(name)] = value
    return facts


class SnapshotStore:
    """Immutable storage for snapshots, reports, and plans."""

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False) -> None:
        if root is None or str(root).strip() == "":
            raise StoreError("a store root must be supplied explicitly")

        resolved = Path(root).expanduser().resolve()

        # A store inside the repository would put generated, disposable
        # artefacts alongside reviewed declared entities.
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
        """Reserve the next identifier, under an exclusive lock.

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
            # link() fails when the destination exists, so committing the write
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

    def write_snapshot(self, record: SnapshotRecord) -> Path:
        return self._write_atomic(self.path_for("snapshot", record.id), record.to_dict())

    def write_report(self, report) -> Path:
        return self._write_atomic(self.path_for("integrity", report.id), report.to_dict())

    def write_plan(self, plan) -> Path:
        return self._write_atomic(self.path_for("recovery", plan.id), plan.to_dict())

    def _load_all(self, kind: str, target: str | None) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for path in sorted(self._directory(kind).glob("*.yaml")):
            record = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            if not isinstance(record, dict):
                continue
            if target is None or record.get("target") == target:
                records.append(record)
        return records

    def list_snapshots(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("snapshot", target)

    def list_reports(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("integrity", target)

    def list_plans(self, target: str | None = None) -> list[dict[str, Any]]:
        return self._load_all("recovery", target)

    def read_snapshot(self, identifier: str) -> dict[str, Any]:
        path = self.path_for("snapshot", identifier)
        if not path.is_file():
            raise StoreError(f"snapshot '{identifier}' does not exist")
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}

    def latest_snapshot(self, target: str) -> dict[str, Any] | None:
        """The newest snapshot for a target. Older ones are never removed."""
        snapshots = self.list_snapshots(target)
        if not snapshots:
            return None
        return max(snapshots, key=lambda s: (str(s.get("created_at") or ""), str(s.get("id"))))

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
