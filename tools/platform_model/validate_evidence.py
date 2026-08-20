#!/usr/bin/env python3
"""Validate evidence, verification, and drift-rule records against their schemas.

Read-only by construction. This tool opens repository files and prints findings.
It performs no network access, no SSH, no subprocess execution, no database
write, no model mutation, and no remediation.

Usage:
    python3 tools/platform_model/validate_evidence.py --root platform-model

Exit status:
    0  all records valid
    1  one or more validation errors
    2  the model root or a required schema could not be read

Secret handling: when a secret-bearing key is found, the key path is reported
and the value is never printed. An error message that echoes the secret it
objected to has leaked it into the CI log.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - reported, not crashed on
    print("ERROR: PyYAML is required. Install it with requirements-ci.txt.", file=sys.stderr)
    raise SystemExit(2)

# Directories holding records of each kind, relative to the model root.
RECORD_DIRS = {
    "evidence": "evidence",
    "verification": "verifications",
    "drift-rule": "drift-rules",
}
SCHEMA_FILES = {
    "evidence": "schemas/evidence.schema.yaml",
    "verification": "schemas/verification.schema.yaml",
    "drift-rule": "schemas/drift-rule.schema.yaml",
}

# Entity directories whose ids a record may reference.
ENTITY_DIRS = (
    "roles", "hosts", "services", "networks", "storage", "backup-policies",
)

# The repository root, so a sibling module resolves when this runs as a script.
# Same shape as validate_ontology.py and the collector tooling.
REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.platform_model import evidence_fingerprint  # noqa: E402

DURATION = re.compile(r"^[0-9]+(m|h|d)$")


class Findings:
    """Collects errors. Never stores or prints a flagged value."""

    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, location: str, message: str) -> None:
        self.errors.append(f"{location}: {message}")

    def report(self) -> int:
        for line in self.errors:
            print(f"ERROR {line}", file=sys.stderr)
        if self.errors:
            print(f"\nEvidence validation failed with {len(self.errors)} error(s).", file=sys.stderr)
            return 1
        print("Evidence validation passed.")
        return 0


def load_yaml(path: Path, findings: Findings):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001 - any parse failure is a finding
        findings.error(str(path), f"YAML parse error: {error}")
        return None


def parse_timestamp(value) -> tuple[bool, str]:
    """Return (ok, reason). Requires an explicit timezone: a time without a
    zone is not a point in time, and comparing it to anything is guesswork."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return False, "timestamp is missing timezone information"
        return True, ""
    if not isinstance(value, str):
        return False, "timestamp must be an RFC 3339 string"
    text = value.strip()
    if text.lower() in {"now", "today", "latest", "current", "recently"}:
        return False, "relative time expressions are not valid timestamps"
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return False, "timestamp is not valid ISO 8601"
    if parsed.tzinfo is None:
        return False, "timestamp is missing timezone information"
    return True, ""


def walk_keys(node, path=""):
    """Yield (dotted_path, key, value) for every mapping key, depth-first."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else str(key)
            yield here, str(key), value
            yield from walk_keys(value, here)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from walk_keys(value, f"{path}[{index}]")


def check_forbidden_keys(record, schema, location, findings) -> None:
    """Flag secret-bearing and action-bearing keys. Values are never printed."""
    secret_keys = {k.lower() for k in schema.get("forbidden_secret_keys") or []}
    permitted = {k.lower() for k in schema.get("permitted_secret_metadata_keys") or []}
    action_keys = {k.lower() for k in schema.get("forbidden_fields") or []}

    for dotted, key, _value in walk_keys(record):
        lowered = key.lower()
        if lowered in permitted:
            continue
        if lowered in secret_keys:
            findings.error(
                location,
                f"secret-bearing key '{dotted}' is not permitted "
                "(record presence, never the value); value withheld",
            )
        if lowered in action_keys:
            findings.error(
                location,
                f"high-impact action field '{dotted}' is not permitted; "
                "this layer detects and never remediates",
            )


def check_fingerprint(record, location, findings) -> None:
    """Recompute the semantic fingerprint and refuse a record that disagrees.

    Until this existed the field was decorative: a record could carry sixty-four
    zeroes, or keep a stale digest while its facts were edited, and validate
    clean. A digest nobody recomputes documents an intention rather than
    enforcing one.
    """
    declared = record.get("content_fingerprint")
    if not evidence_fingerprint.is_well_formed(declared):
        findings.error(
            location,
            "content_fingerprint must be 'sha256:' followed by 64 lowercase "
            f"hexadecimal characters, not {declared!r}",
        )
        return
    try:
        recomputed = evidence_fingerprint.fingerprint(record)
    except evidence_fingerprint.FingerprintError as error:
        findings.error(location, f"content_fingerprint cannot be recomputed: {error}")
        return
    if recomputed != declared:
        findings.error(
            location,
            f"content_fingerprint {declared} does not match the semantic content, "
            f"which fingerprints to {recomputed}",
        )


def check_common(record, schema, location, findings, kind) -> None:
    for field in schema.get("required_fields") or []:
        if field not in record:
            findings.error(location, f"missing required field '{field}'")

    for field, expected in (schema.get("constant_fields") or {}).items():
        if record.get(field) != expected:
            findings.error(location, f"field '{field}' must be '{expected}'")

    identifier = record.get("id")
    pattern = schema.get("id_pattern")
    if pattern and not (isinstance(identifier, str) and re.match(pattern, identifier)):
        findings.error(
            location,
            f"id '{identifier}' does not match the required pattern {pattern}",
        )

    for field, allowed in (schema.get("enums") or {}).items():
        if field == "provenance_class":
            continue
        if field in record and record[field] not in allowed:
            findings.error(
                location,
                f"field '{field}' value '{record[field]}' is not approved "
                f"(allowed: {', '.join(map(str, allowed))})",
            )

    for field in schema.get("timestamp_fields") or []:
        if field not in record:
            continue
        ok, reason = parse_timestamp(record[field])
        if not ok:
            findings.error(location, f"field '{field}': {reason}")

    requirements = schema.get("provenance_requirements") or {}
    if requirements:
        provenance = record.get("provenance")
        if not isinstance(provenance, dict):
            findings.error(location, "provenance block is missing or not a mapping")
        else:
            required_class = requirements.get("required_class")
            if required_class and provenance.get("class") != required_class:
                findings.error(
                    location,
                    f"provenance class must be '{required_class}' for {kind} records",
                )
            stamp = requirements.get("required_timestamp")
            if stamp:
                if not provenance.get(stamp):
                    findings.error(
                        location,
                        f"observed provenance requires '{stamp}'",
                    )
                else:
                    ok, reason = parse_timestamp(provenance[stamp])
                    if not ok:
                        findings.error(location, f"provenance.{stamp}: {reason}")
            reference = requirements.get("required_reference")
            if reference and not provenance.get(reference):
                findings.error(location, f"inferred provenance requires '{reference}'")

    for rule in schema.get("conditional_requirements") or []:
        field = rule.get("when_field")
        triggered = False
        if "when_value_in" in rule:
            triggered = record.get(field) in rule["when_value_in"]
        elif rule.get("when_value_is_null"):
            triggered = field in record and record.get(field) is None
        if not triggered:
            continue
        for needed in rule.get("require_fields") or []:
            if not record.get(needed):
                findings.error(
                    location,
                    f"field '{field}'='{record.get(field)}' requires '{needed}'",
                )
        for needed in rule.get("require_non_empty") or []:
            if not record.get(needed):
                findings.error(
                    location,
                    f"field '{field}'='{record.get(field)}' requires a non-empty '{needed}'",
                )
        for needed in rule.get("require_true") or []:
            if record.get(needed) is not True:
                findings.error(
                    location,
                    f"field '{field}'='{record.get(field)}' requires '{needed}' to be true",
                )

    check_forbidden_keys(record, schema, location, findings)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate evidence, verification, and drift-rule records.",
    )
    parser.add_argument("--root", required=True, help="Path to the platform-model root")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: model root not found: {root}", file=sys.stderr)
        return 2

    findings = Findings()

    schemas = {}
    for kind, relative in SCHEMA_FILES.items():
        path = root / relative
        if not path.is_file():
            print(f"ERROR: required schema missing: {path}", file=sys.stderr)
            return 2
        loaded = load_yaml(path, findings)
        if not isinstance(loaded, dict):
            print(f"ERROR: schema is not a mapping: {path}", file=sys.stderr)
            return 2
        schemas[kind] = loaded

    # Known entity ids, so record references can be resolved.
    entity_ids: set[str] = set()
    for directory in ENTITY_DIRS:
        for path in sorted((root / directory).glob("*.yaml")) if (root / directory).is_dir() else []:
            record = load_yaml(path, findings)
            if isinstance(record, dict) and record.get("id"):
                entity_ids.add(record["id"])

    evidence_ids: set[str] = set()
    seen_ids: dict[str, dict[str, Path]] = {kind: {} for kind in RECORD_DIRS}
    collected: dict[str, list[tuple[Path, dict]]] = {kind: [] for kind in RECORD_DIRS}

    for kind, directory in RECORD_DIRS.items():
        target = root / directory
        if not target.is_dir():
            continue
        for path in sorted(target.glob("*.yaml")):
            document = load_yaml(path, findings)
            if document is None:
                continue
            records = (
                document.get("drift_rules") or []
                if kind == "drift-rule" and isinstance(document, dict)
                else [document]
            )
            for record in records:
                if not isinstance(record, dict):
                    findings.error(str(path), "record is not a mapping")
                    continue
                collected[kind].append((path, record))
                identifier = record.get("id")
                if identifier:
                    if identifier in seen_ids[kind]:
                        findings.error(
                            str(path),
                            f"duplicate {kind} id '{identifier}' "
                            f"(also in {seen_ids[kind][identifier]})",
                        )
                    else:
                        seen_ids[kind][identifier] = path
                if kind == "evidence" and identifier:
                    evidence_ids.add(identifier)

    for kind, entries in collected.items():
        schema = schemas[kind]
        for path, record in entries:
            location = f"{path} [{record.get('id', '<no id>')}]"
            check_common(record, schema, location, findings, kind)

            if kind == "evidence":
                check_fingerprint(record, location, findings)

            for field in schema.get("entity_reference_fields") or []:
                value = record.get(field)
                if value and value not in entity_ids:
                    findings.error(location, f"field '{field}' does not resolve to a known entity: {value}")

            for field in schema.get("evidence_reference_fields") or []:
                for reference in record.get(field) or []:
                    if reference not in evidence_ids:
                        findings.error(
                            location,
                            f"evidence reference '{reference}' does not resolve to a known evidence record",
                        )

            if kind == "verification":
                restrictions = schema.get("state_result_restrictions") or {}
                limits = restrictions.get(record.get("state")) or {}
                if record.get("result") in (limits.get("forbidden_results") or []):
                    findings.error(
                        location,
                        f"state '{record.get('state')}' must not rest on result "
                        f"'{record.get('result')}'",
                    )

            if kind == "drift-rule":
                for field, banned in (schema.get("forbidden_values") or {}).items():
                    if record.get(field) in banned:
                        findings.error(
                            location,
                            f"field '{field}' value '{record.get(field)}' is forbidden; "
                            "remediation must never be automatic",
                        )
                for field in schema.get("boolean_fields") or []:
                    if field in record and not isinstance(record[field], bool):
                        findings.error(location, f"field '{field}' must be a boolean")
                age = record.get("evidence_max_age")
                if age is not None and not (isinstance(age, str) and DURATION.match(age)):
                    findings.error(
                        location,
                        f"evidence_max_age '{age}' must be null or match {DURATION.pattern}",
                    )

    return findings.report()


if __name__ == "__main__":
    raise SystemExit(main())
