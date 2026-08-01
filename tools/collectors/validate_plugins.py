#!/usr/bin/env python3
"""Validate collector plugin manifests and framework safety properties.

Read-only. Opens repository files, imports the declared plugin modules to
confirm they implement the contract, and reports findings. It performs no
network access, no subprocess execution, no filesystem write, and no
remediation.

Usage:
    python3 tools/collectors/validate_plugins.py --root .

Exit status:
    0  all plugins valid
    1  one or more validation failures
    2  invocation or configuration error

Secret handling: a manifest field that looks secret-bearing is reported by
field name with its value withheld. An error message that echoes the secret it
objected to has leaked it into the CI log.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required. Install it with requirements-ci.txt.", file=sys.stderr)
    raise SystemExit(2)

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.collectors.base import CollectorPlugin  # noqa: E402
from tools.collectors.models import (  # noqa: E402
    APPROVED_PERMISSIONS,
    APPROVED_SOURCE_TYPES,
    FORBIDDEN_PERMISSIONS,
    SECRET_BEARING_KEYS,
    PERMITTED_SECRET_METADATA_KEYS,
    CollectionContext,
)
from tools.collectors.plugins.example.collector import ExampleSyntheticCollector  # noqa: E402
from tools.collectors.registry import CollectorRegistry  # noqa: E402

COLLECTOR_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

REQUIRED_MANIFEST_FIELDS = (
    "id", "name", "version", "source_type", "description", "capabilities",
    "supported_targets", "permissions", "network_access", "subprocess_access",
    "filesystem_access", "secret_requirements", "output_contract", "lifecycle",
    "provenance",
)

# Registered plugin classes. Explicit, not discovered: a plugin that appears by
# being dropped on disk is a plugin nobody reviewed.
KNOWN_PLUGINS = {"example-synthetic": ExampleSyntheticCollector}


class Findings:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, location: str, message: str) -> None:
        self.errors.append(f"{location}: {message}")

    def report(self) -> int:
        for line in self.errors:
            print(f"ERROR {line}", file=sys.stderr)
        if self.errors:
            print(f"\nCollector plugin validation failed with {len(self.errors)} error(s).", file=sys.stderr)
            return 1
        print("Collector plugin validation passed.")
        return 0


def check_manifest(path: Path, manifest: dict, capability_ids: set[str], findings: Findings, seen: dict) -> None:
    location = str(path)

    for field in REQUIRED_MANIFEST_FIELDS:
        if field not in manifest:
            findings.error(location, f"missing required manifest field '{field}'")

    identifier = manifest.get("id", "")
    if not COLLECTOR_ID.match(str(identifier)):
        findings.error(location, f"collector id '{identifier}' must be lowercase kebab-case")
    if identifier in seen:
        findings.error(location, f"duplicate collector id '{identifier}' (also in {seen[identifier]})")
    else:
        seen[identifier] = path

    source_type = manifest.get("source_type")
    if source_type not in APPROVED_SOURCE_TYPES:
        findings.error(location, f"source_type '{source_type}' is not an approved evidence source type")

    for permission in manifest.get("permissions") or []:
        if permission in FORBIDDEN_PERMISSIONS:
            findings.error(
                location,
                f"permission '{permission}' is forbidden; it lies outside the collector trust boundary",
            )
        elif permission not in APPROVED_PERMISSIONS:
            findings.error(location, f"permission '{permission}' is not approved")

    for flag in ("network_access", "subprocess_access", "filesystem_access"):
        if manifest.get(flag) is not False:
            findings.error(location, f"'{flag}' must be false in this increment")

    for capability in manifest.get("capabilities") or []:
        if capability_ids and capability not in capability_ids:
            findings.error(location, f"capability reference '{capability}' does not resolve")

    # Secret-bearing manifest keys. The value is never printed.
    def walk(node, prefix=""):
        if isinstance(node, dict):
            for key, value in node.items():
                dotted = f"{prefix}.{key}" if prefix else str(key)
                lowered = str(key).lower()
                if lowered in SECRET_BEARING_KEYS and lowered not in PERMITTED_SECRET_METADATA_KEYS:
                    findings.error(
                        location,
                        f"manifest key '{dotted}' is secret-bearing and must not appear; value withheld",
                    )
                walk(value, dotted)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{prefix}[{index}]")

    walk(manifest)


def check_framework_safety(root: Path, findings: Findings) -> None:
    """Assert the framework has no persistence or remediation path."""
    tree = root / "tools" / "collectors"
    if not tree.is_dir():
        findings.error(str(tree), "collector framework directory is missing")
        return

    banned = {
        "dynamic import": re.compile(r"\b(importlib|__import__)\s*\(|\beval\s*\(|\bexec\s*\("),
        "evidence persistence": re.compile(r"EVID-\d|write_evidence|persist_evidence"),
        "remediation": re.compile(r"def\s+remediate|remediation_command|auto_remediate|apply_fix"),
    }
    for path in sorted(tree.rglob("*.py")):
        # This module is the scanner: it necessarily contains the patterns it
        # searches for. Its own network/subprocess/write safety is asserted by
        # tests/test-collector-framework.sh, which still covers this file.
        if path.name == "validate_plugins.py":
            continue
        text = path.read_text(encoding="utf-8")
        for label, pattern in banned.items():
            if pattern.search(text):
                findings.error(str(path), f"{label} construct is not permitted in the collector framework")


def check_example_determinism(findings: Findings) -> None:
    """The example plugin must refuse non-synthetic use and be deterministic."""
    plugin = ExampleSyntheticCollector()

    non_synthetic = CollectionContext(
        target="HOST-0001", declared={}, requested_facts=("attested_hostname",),
        collected_at="2026-08-01T09:00:00-05:00", synthetic=False,
    )
    result = plugin.execute(non_synthetic)
    if not result.is_terminal_failure():
        findings.error("example-synthetic", "plugin did not refuse non-synthetic execution")

    synthetic = CollectionContext(
        target="HOST-0001", declared={}, requested_facts=("attested_hostname",),
        collected_at="2026-08-01T09:00:00-05:00", synthetic=True,
    )
    first = plugin.execute(synthetic)
    second = plugin.execute(synthetic)
    if first.status != "success":
        findings.error("example-synthetic", f"synthetic execution did not succeed: {first.status}")
    if first.content_fingerprint != second.content_fingerprint:
        findings.error("example-synthetic", "plugin output is not deterministic")
    if getattr(first, "evidence_id", None) is not None:
        findings.error("example-synthetic", "collector result must not carry an evidence identifier")


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate collector plugins.")
    parser.add_argument("--root", required=True, help="Repository root")
    args = parser.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: root not found: {root}", file=sys.stderr)
        return 2

    plugin_root = root / "tools" / "collectors" / "plugins"
    if not plugin_root.is_dir():
        print(f"ERROR: plugin directory not found: {plugin_root}", file=sys.stderr)
        return 2

    findings = Findings()

    capability_ids: set[str] = set()
    capability_dir = root / "platform-model" / "capabilities"
    if capability_dir.is_dir():
        for path in sorted(capability_dir.glob("*.yaml")):
            try:
                record = yaml.safe_load(path.read_text(encoding="utf-8"))
            except Exception as error:  # noqa: BLE001
                findings.error(str(path), f"YAML parse error: {error}")
                continue
            if isinstance(record, dict) and record.get("id"):
                capability_ids.add(record["id"])

    seen: dict = {}
    manifests = sorted(plugin_root.rglob("manifest.yaml"))
    if not manifests:
        findings.error(str(plugin_root), "no plugin manifests found")

    for path in manifests:
        try:
            manifest = yaml.safe_load(path.read_text(encoding="utf-8"))
        except Exception as error:  # noqa: BLE001
            findings.error(str(path), f"YAML parse error: {error}")
            continue
        if not isinstance(manifest, dict):
            findings.error(str(path), "manifest is not a mapping")
            continue
        check_manifest(path, manifest, capability_ids, findings, seen)

        identifier = manifest.get("id")
        plugin_class = KNOWN_PLUGINS.get(identifier)
        if plugin_class is None:
            findings.error(
                str(path),
                f"plugin '{identifier}' is not explicitly registered in the validator's known set",
            )
        elif not issubclass(plugin_class, CollectorPlugin):
            findings.error(str(path), f"plugin '{identifier}' does not implement CollectorPlugin")

    check_framework_safety(root, findings)
    check_example_determinism(findings)

    # Registry must reject a duplicate registration.
    registry = CollectorRegistry()
    registry.register(ExampleSyntheticCollector)
    try:
        registry.register(ExampleSyntheticCollector)
        findings.error("registry", "registry accepted a duplicate collector id")
    except Exception:  # noqa: BLE001 - expected rejection
        pass

    return findings.report()


if __name__ == "__main__":
    raise SystemExit(main())
