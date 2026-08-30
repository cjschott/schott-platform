#!/usr/bin/env python3
"""Adjudicate Semgrep findings against the reviewed exception registry.

Semgrep runs normally and reports everything it finds. This decides whether what
it found is exactly what a reviewer already looked at and accepted, and nothing
else. It is the gate, not Semgrep's own exit status, because `--error` cannot
express "this one finding, in this one place, for this one reason".

An exception matches a finding only when the rule id, the path, the line and the
current sha256 of the file all agree. So it cannot broaden by accident:

  - the same rule firing in a different file is unapproved;
  - a different rule firing in the same file is unapproved;
  - the finding moving to another line is unapproved;
  - the file changing at all invalidates the digest and the exception with it;
  - an exception matching nothing is a failure too, because a finding that has
    gone away must be removed deliberately rather than left to cover a future
    one;
  - a Semgrep error, or output this cannot parse, fails rather than passing
    quietly.

Usage:
    semgrep scan --config auto --json | tools/dev/check-semgrep-findings.py
    tools/dev/check-semgrep-findings.py --findings results.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REGISTRY = ".semgrep-exceptions.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_registry(root: Path) -> list[dict]:
    location = root / REGISTRY
    if not location.is_file():
        raise SystemExit(f"FAIL: {REGISTRY} is missing; there is nothing to adjudicate against")
    document = json.loads(location.read_text(encoding="utf-8"))
    entries = document.get("exceptions", [])
    required = {"rule", "path", "line", "sha256", "justification", "reviewed_in"}
    for entry in entries:
        missing = required - set(entry)
        if missing:
            raise SystemExit(f"FAIL: exception for {entry.get('path')} omits {sorted(missing)}")
        if not str(entry["justification"]).strip():
            raise SystemExit(f"FAIL: exception for {entry['path']} carries an empty justification")
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--findings", default="-",
                        help="Semgrep --json output; '-' reads stdin")
    parser.add_argument("--root", default=".")
    arguments = parser.parse_args()

    root = Path(arguments.root).resolve()
    raw = (sys.stdin.read() if arguments.findings == "-"
           else Path(arguments.findings).read_text(encoding="utf-8"))
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"FAIL: Semgrep output is not JSON ({error}); refusing to treat that as clean")
        return 1

    problems: list[str] = []

    # A Semgrep that errored has not scanned what it claims to have scanned.
    # Parse warnings are not that: they are Semgrep reporting a file it could not
    # fully read, which it downgrades to `warn` itself.
    for error in report.get("errors", []):
        if str(error.get("level", "")).lower() not in {"warn", "warning"}:
            problems.append(f"Semgrep reported a {error.get('level')} error: "
                            f"{error.get('type')} at {error.get('path')}")

    exceptions = load_registry(root)
    used = [0] * len(exceptions)
    findings = report.get("results", [])

    for finding in findings:
        rule = finding.get("check_id")
        path = finding.get("path")
        line = finding.get("start", {}).get("line")
        for index, entry in enumerate(exceptions):
            if entry["rule"] != rule or entry["path"] != path:
                continue
            if entry["line"] != line:
                problems.append(
                    f"{rule} in {path} moved to line {line}; the reviewed "
                    f"exception is for line {entry['line']}")
                used[index] += 1
                break
            target = root / path
            if not target.is_file():
                problems.append(f"{path} is approved but no longer exists")
                used[index] += 1
                break
            observed = digest(target)
            if observed != entry["sha256"]:
                problems.append(
                    f"{path} changed since the exception was reviewed "
                    f"(is {observed}, approved {entry['sha256']}); "
                    f"the finding must be reviewed again")
            used[index] += 1
            break
        else:
            problems.append(f"UNAPPROVED finding: {rule} in {path} line {line}")

    for index, entry in enumerate(exceptions):
        if used[index] == 0:
            problems.append(
                f"the reviewed exception for {entry['rule']} in {entry['path']} "
                f"matched no finding; remove it rather than leaving it to cover "
                f"a future one")
        elif used[index] > 1:
            problems.append(
                f"the reviewed exception for {entry['rule']} in {entry['path']} "
                f"matched {used[index]} findings; it approves exactly one")

    approved = sum(used)
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        print(f"\nSemgrep adjudication FAILED: {len(problems)} problem(s), "
              f"{len(findings)} finding(s)")
        return 1

    print(f"Semgrep: {len(findings)} finding(s), all {approved} reviewed and approved.")
    for entry in exceptions:
        print(f"  {entry['rule']}\n    {entry['path']}:{entry['line']} "
              f"({entry['reviewed_in']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
