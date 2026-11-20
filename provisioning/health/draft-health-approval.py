#!/usr/bin/env python3
"""Draft one Health approval statement -- ENG-0006-H18. Unprivileged.

Run from the checkout, as the operator, never as root and never installed:

    python3 provisioning/health/draft-health-approval.py \\
        --envelope envelope.json --request-id REQ-0001 --operation initial \\
        --actor <name> --approving-authority <name> \\
        --approved-at 2026-11-20T09:00:00-06:00 > candidate.json

It writes the canonical statement bytes (no trailing newline) to stdout and
their SHA-256 to stderr, and refuses anything ingestion would refuse before
the store. Its output is agent-editable until it is published, so it is not
the review: the operator reads `candidate.json` with root-owned tools
(`python3 -I -m json.tool < candidate.json`), computes `sha256sum
candidate.json` themselves, and passes that digest to
`kyri-health-approve`, which refuses any other bytes.

The envelope is JSON, read with duplicate keys and non-integer numbers
refused. YAML is not accepted: its implicit typing is the hazard the
canonical statement exists to remove (preflight §9.2). Every statement member
is an argument; nothing is defaulted, not even the approval time.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.health.operator import DraftRefused, draft_statement  # noqa: E402


def _refuse_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key {key!r}")
        result[key] = value
    return result


def _refuse_number(text: str) -> Any:
    raise ValueError(f"non-integer number {text}; thresholds are strings")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Draft one Health approval statement.")
    parser.add_argument("--envelope", required=True,
                        help="JSON file holding the envelope content")
    for option in ("--request-id", "--operation", "--actor",
                   "--approving-authority", "--approved-at"):
        parser.add_argument(option, required=True)
    arguments = parser.parse_args(argv)

    try:
        envelope = json.loads(Path(arguments.envelope).read_text(encoding="utf-8"),
                              object_pairs_hook=_refuse_duplicates,
                              parse_float=_refuse_number,
                              parse_constant=_refuse_number)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        print(f"refused: the envelope is not readable JSON: {error}", file=sys.stderr)
        return 1
    if not isinstance(envelope, dict):
        print("refused: the envelope is not a JSON object", file=sys.stderr)
        return 1
    try:
        raw = draft_statement(envelope, request_id=arguments.request_id,
                              operation=arguments.operation, actor=arguments.actor,
                              approving_authority=arguments.approving_authority,
                              approved_at=arguments.approved_at)
    except DraftRefused as error:
        print(f"refused: {error.stage} {error}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()
    print(f"sha256 {hashlib.sha256(raw).hexdigest()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
