"""Append-only storage for Trust Plane runtime records.

Built on tools/common/immutable_store.py rather than growing a fifth copy of
the write path. That module already guarantees what this layer needs most: an
explicit root, refusal of a root inside a git repository, write-once commit via
os.link so committing and refusing an overwrite are the same atomic operation,
locked monotonic identifier allocation, and the absence of any update or delete
method.

Nothing here adds a way to change a record. Validation reports problems and
repairs none of them: a malformed record can only be superseded, which is why
validation is a command rather than an afterthought.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ..common.immutable_store import ImmutableStore, StoreError
from .errors import TrustStoreError
from .identifiers import LINEAGE_ID, LINEAGE_VERSION_ID, PATTERNS, PREFIXES


class TrustStore(ImmutableStore):
    """The trust store, rooted at an explicit directory outside the repository."""

    record_dirs = {
        "authority": "authorities",
        "record": "records",
        "decision": "decisions",
        "evidence": "evidence-references",
        "lineage": "lineages",
        "audit": "audit",
    }
    id_patterns = dict(PATTERNS)
    id_prefixes = dict(PREFIXES)
    # `indexes` holds append-only pointers; nothing in it is ever rewritten.
    extra_dirs = ("sequences", "indexes")

    def __init__(self, root: Path | str, *, allow_repository_root: bool = False) -> None:
        try:
            super().__init__(root, allow_repository_root=allow_repository_root)
        except StoreError as error:
            raise TrustStoreError(str(error)) from None

    def path_for(self, kind: str, identifier: str) -> Path:
        """Resolve a record path.

        Lineage records are versioned, so a lineage file is named
        `TLIN-000001-v0001` while the identifier allocated for a new lineage is
        the unversioned `TLIN-000001`. Both forms are accepted here: allocation
        checks whether a name is free, and writing uses the versioned name.
        """
        if kind == "lineage":
            text = str(identifier)
            if not (LINEAGE_ID.match(text) or LINEAGE_VERSION_ID.match(text)):
                raise TrustStoreError(
                    f"identifier '{identifier}' is not a valid lineage identifier")
            return self._directory(kind) / f"{text}.yaml"
        return super().path_for(kind, identifier)

    def write(self, kind: str, record) -> Path:
        try:
            return self.write_atomic(self.path_for(kind, record.id), record.to_dict())
        except StoreError as error:
            raise TrustStoreError(str(error)) from None

    def read(self, kind: str, identifier: str) -> dict[str, Any]:
        try:
            return self.read_record(kind, identifier)
        except StoreError as error:
            raise TrustStoreError(str(error)) from None

    def all_records(self, kind: str) -> list[dict[str, Any]]:
        return self.list_records(kind)

    # --- integrity ---------------------------------------------------------

    def validate(self) -> list[str]:
        """Structural problems, in a deterministic order. Repairs nothing."""
        problems: list[str] = list(super().validate())

        authorities = self.all_records("authority")
        active_roots = [a for a in authorities
                        if a.get("authority_type") == "operator-root"
                        and a.get("state") == "trusted"]
        if len(active_roots) > 1:
            problems.append(
                f"{len(active_roots)} active operator-root authorities exist; "
                "two roots is no root"
            )

        known_authorities = {a.get("authority_id") for a in authorities}
        decisions = {d.get("decision_id"): d for d in self.all_records("decision")}
        lineage_ids = {l.get("lineage_id") for l in self.all_records("lineage")}

        for identifier, decision in sorted(decisions.items(), key=lambda i: str(i[0])):
            if decision.get("actor_authority_id") not in known_authorities:
                problems.append(f"{identifier}: actor authority does not resolve")
            if decision.get("lineage_id") not in lineage_ids:
                problems.append(f"{identifier}: decision has no lineage")
            supersedes = decision.get("supersedes")
            if supersedes and supersedes not in decisions:
                problems.append(f"{identifier}: supersedes an unknown decision")
            if supersedes == identifier:
                problems.append(f"{identifier}: decision supersedes itself")

        seen_ids: set[str] = set()
        for kind in self.record_dirs:
            for record in self.all_records(kind):
                identifier = str(record.get("id") or record.get(f"{kind}_id") or "")
                if identifier and identifier in seen_ids:
                    problems.append(f"{identifier}: duplicate identifier across the store")
                seen_ids.add(identifier)

        for record in self.all_records("record"):
            if record.get("lineage_id") not in lineage_ids:
                problems.append(f"{record.get('record_id')}: record has no lineage")
            if record.get("decision_id") not in decisions:
                problems.append(f"{record.get('record_id')}: record cites an unknown decision")

        # Hidden temp files are debris from a failed write, not records.
        for stray in sorted(self.root.rglob(".*.tmp")):
            problems.append(f"{stray.name}: partial write left behind")

        return sorted(problems)
