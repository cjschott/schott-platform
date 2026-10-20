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

from pathlib import Path
from typing import Any, Mapping

import yaml

from ..common.immutable_store import ImmutableStore, StoreError
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
        if initialize:
            for name in (*self.record_dirs.values(), *self.extra_dirs):
                self._vetted_directory(self.root / name, name)

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
