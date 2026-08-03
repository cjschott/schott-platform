#!/usr/bin/env python3
"""Validate ontology YAML with a duplicate-key-rejecting loader.

The ontology is a controlled vocabulary. A repeated mapping key there is not a
style problem: the earlier definition disappears during parsing, and every
reader downstream believes a vocabulary the file does not declare. The
relationship catalog carried three ``SUPERSEDES`` definitions and only the last
one existed as far as any consumer was concerned.

Repository-only. Reads files and reports findings. No network access, no SSH,
no subprocess, no filesystem write, and no model mutation.

Usage:
    python3 tools/platform_model/validate_ontology.py --root platform-model
    python3 tools/platform_model/validate_ontology.py --root . --all-tracked

``--all-tracked`` sweeps every YAML file under the root rather than the
ontology directory alone. The ontology is where duplicates were found; it is
not where there is any reason to believe they are confined.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.common.yaml_strict import DuplicateKeyError, load_strict  # noqa: E402


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default="platform-model",
        help="Directory to validate (default: platform-model)",
    )
    parser.add_argument(
        "--all-tracked",
        action="store_true",
        help="Validate every YAML file under the root, not only ontology/",
    )
    return parser.parse_args(argv)


def targets(root: Path, all_tracked: bool) -> list[Path]:
    if all_tracked:
        return sorted(p for p in root.rglob("*.yaml") if p.is_file())
    ontology = root / "ontology"
    if not ontology.is_dir():
        # Tolerate being pointed at the ontology directory itself.
        ontology = root
    return sorted(p for p in ontology.glob("*.yaml") if p.is_file())


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = Path(args.root).resolve()

    if not root.is_dir():
        print(f"ERROR root is not a directory: {root}", file=sys.stderr)
        return 2

    paths = targets(root, args.all_tracked)
    if not paths:
        # Silence here would read as success. It is not: it means the validator
        # checked nothing, which is the state a validator must never report as
        # passing.
        print(f"ERROR no YAML files found under {root}", file=sys.stderr)
        return 2

    failures = 0
    for path in paths:
        try:
            load_strict(path)
        except DuplicateKeyError as error:
            failures += 1
            print(f"FAIL {error}", file=sys.stderr)
        except Exception as error:  # noqa: BLE001 - report any parse failure
            failures += 1
            print(f"FAIL {path}: {error}", file=sys.stderr)

    if failures:
        print(
            f"\n{failures} file(s) rejected. A duplicate mapping key silently "
            f"discards the earlier definition; remove or merge it.",
            file=sys.stderr,
        )
        return 1

    print(f"  ok       {len(paths)} YAML file(s) parsed with no duplicate keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
