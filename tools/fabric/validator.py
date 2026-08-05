"""Structural and referential validation for stored Fabric records.

This reports. It repairs nothing, and it is authoritative for nothing.

**A finding is not an exception.** A store is validated precisely when
something in it may be wrong, so an unreadable file, an unknown schema
version, or an unparseable timestamp must come back as a described problem
rather than as a traceback. One bad record stopping the report would hide
every record after it, which is the opposite of what validation is for.

**Reconstruction is the test.** A record is valid when the accepted model for
its kind will rebuild it -- not when a key is present, and not when a filename
looks right. That keeps this module free of a second, drifting copy of the
schema rules, and it means a record refused here is refused for the same
reason the store would refuse it.

**Nothing here reaches the filesystem on its own.** Directories arrive already
guarded from `FabricStore`, so ownership, containment, and symlink refusal stay
where they were accepted. A symlink is reported, never followed, and a
temporary artefact is reported, never cleared: it is the evidence that a write
was interrupted.

Derived state -- the per-kind sequence files -- is reported and never touched.
A sequence that disagrees with the records is a fact worth surfacing, and
rewriting it to agree would erase the discrepancy rather than explain it.

This increment validates records. It adapts no trust, admits nothing, computes
no eligibility, chooses nothing, and presents nothing.
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping

import yaml

from .errors import FabricError
from .identifiers import ID_FIELDS
from .models import RECORD_MODELS

# Which fields point at which other record kind. Supersession is not listed:
# every kind supersedes its own kind, and that is handled uniformly below.
REFERENCES: Mapping[str, tuple[tuple[str, str], ...]] = MappingProxyType({
    "capability-definition": (
        ("contract_ids", "capability-contract"),
    ),
    "capability-contract": (
        ("capability_id", "capability-definition"),
    ),
    "capability-package": (
        ("capability_id", "capability-definition"),
        ("contract_id", "capability-contract"),
    ),
    "capability-host": (),
    "capability-advertisement": (
        ("capability_host_id", "capability-host"),
        ("capability_package_id", "capability-package"),
        ("contract_id", "capability-contract"),
    ),
    "capability-instance": (
        ("capability_id", "capability-definition"),
        ("capability_package_id", "capability-package"),
        ("capability_host_id", "capability-host"),
        ("contract_id", "capability-contract"),
        ("advertisement_id", "capability-advertisement"),
    ),
    "capability-route": (
        ("capability_id", "capability-definition"),
        ("contract_id", "capability-contract"),
        ("candidate_instances", "capability-instance"),
    ),
    "capability-selection": (
        ("route_id", "capability-route"),
        ("considered_candidates", "capability-instance"),
        ("selected_instance_id", "capability-instance"),
    ),
})

SUPERSESSION = ("supersedes", "superseded_by")


@dataclass(frozen=True)
class ValidationReport:
    """What validation found, and how much it looked at.

    Findings are sorted, so two runs over the same store are comparable
    byte for byte rather than merely equivalent.
    """

    findings: tuple[str, ...]
    counts: Mapping[str, int]


def _referenced(value: Any) -> tuple[str, ...]:
    """The identifiers a field points at. An absent reference points nowhere."""
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    if isinstance(value, (list, tuple)):
        return tuple(item for item in value if isinstance(item, str))
    return ()


def _sequence_number(identifier: str) -> int:
    tail = identifier.rsplit("-", 1)[-1]
    return int(tail) if tail.isdigit() else 0


def _read_entries(store, kind: str, findings: list[str]) -> tuple[list, int]:
    """Every entry in one record directory, guarded by the store.

    Returns the readable `.yaml` paths and the number of them. A directory the
    store refuses becomes a finding, because a refusal is a validation result
    and not a reason to abandon the other seven kinds.
    """
    try:
        directory = store._directory(kind)
        entries = sorted(directory.iterdir())
    except FabricError as error:
        findings.append(f"{store.record_dirs[kind]}: {error}")
        return [], 0
    except OSError as error:
        findings.append(f"{store.record_dirs[kind]}: could not be read ({error.strerror})")
        return [], 0

    records = []
    for entry in entries:
        if entry.is_symlink():
            findings.append(f"{entry.name}: is a symbolic link, not a record")
            continue
        if entry.suffix == ".tmp":
            findings.append(f"{entry.name}: partial write left behind")
            continue
        if entry.suffix != ".yaml":
            findings.append(f"{entry.name}: is not a record file")
            continue
        records.append(entry)
    return records, len(records)


def _load(path, findings: list[str]) -> Any:
    """The stored mapping, or None with the reason already recorded."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        findings.append(f"{path.name}: could not be read ({error.strerror})")
        return None
    try:
        payload = yaml.safe_load(text)
    except yaml.YAMLError:
        # The parser's own message quotes file content; the name is enough.
        findings.append(f"{path.name}: is not readable YAML")
        return None
    if not isinstance(payload, dict):
        findings.append(f"{path.name}: is not a record mapping")
        return None
    return payload


def validate_store(store) -> ValidationReport:
    """Report what is structurally wrong in a store. Repairs nothing.

    Every accepted kind is visited in a fixed order and every entry within it
    in sorted order, so the findings depend on the store's contents and on
    nothing else -- not on directory iteration order, and not on which problem
    happened to be met first.
    """
    findings: list[str] = []
    counts: dict[str, int] = {}
    reconstructed: dict[str, list[tuple[str, Any]]] = {}
    identifiers: dict[str, set[str]] = {}

    for kind in RECORD_MODELS:
        model = RECORD_MODELS[kind]
        field = ID_FIELDS[kind]
        paths, total = _read_entries(store, kind, findings)
        counts[kind] = total
        reconstructed[kind] = []
        identifiers[kind] = set()

        for path in paths:
            payload = _load(path, findings)
            if payload is None:
                continue
            try:
                record = model.from_dict(payload)
            except FabricError as error:
                findings.append(f"{path.name}: {error}")
                continue
            except (TypeError, ValueError) as error:
                # A model refuses through FabricError; anything else reaching
                # here is still a property of the stored record, not a crash.
                findings.append(f"{path.name}: could not be reconstructed ({error})")
                continue

            identifier = getattr(record, field)
            if identifier != path.stem:
                findings.append(
                    f"{path.name}: filename does not match {field} '{identifier}'")
                continue
            reconstructed[kind].append((path.name, record))
            identifiers[kind].add(identifier)

    # References are resolved only after every kind has been read, so a record
    # is never called dangling merely because its target was read later.
    for kind, entries in reconstructed.items():
        pointers = (*REFERENCES[kind], *((name, kind) for name in SUPERSESSION))
        for name, record in entries:
            for attribute, target_kind in pointers:
                for reference in _referenced(getattr(record, attribute, None)):
                    if reference not in identifiers[target_kind]:
                        findings.append(
                            f"{name}: {attribute} references {reference}, "
                            "which no stored record declares")

    findings.extend(_sequence_findings(store, identifiers))
    return ValidationReport(tuple(sorted(findings)), MappingProxyType(counts))


def _sequence_findings(store, identifiers: Mapping[str, set[str]]) -> list[str]:
    """Derived sequence state, reported and left exactly as found."""
    findings: list[str] = []
    try:
        directory = store._guard_path(store.root / "sequences", "sequence directory")
    except FabricError as error:
        return [f"sequences: {error}"]

    for kind in RECORD_MODELS:
        stored = identifiers.get(kind) or set()
        highest = max((_sequence_number(entry) for entry in stored), default=0)
        path = directory / f"{kind}.seq"
        name = path.name
        if path.is_symlink():
            findings.append(f"{name}: is a symbolic link, not a sequence file")
            continue
        try:
            raw = path.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            if highest:
                findings.append(
                    f"{name}: is absent although {highest} identifier(s) are in use")
            continue
        except OSError as error:
            findings.append(f"{name}: could not be read ({error.strerror})")
            continue
        if not raw.isdigit():
            findings.append(f"{name}: does not hold a sequence number")
            continue
        if int(raw) < highest:
            findings.append(
                f"{name}: is behind the stored records, which reach {highest}")
    return findings
