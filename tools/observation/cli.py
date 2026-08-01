"""Command line interface for the knowledge orchestrator.

Prints JSON to stdout and diagnostics to stderr.

Exit status:
    0  the operation succeeded
    1  the operation ran and failed
    2  invocation or configuration error

Two paths are always explicit and never defaulted. The store root has no
default because a default would eventually be a production path someone
invoked by accident. The input file must live inside a caller-approved
directory, resolved with symlinks followed, so neither traversal nor a symlink
can reach a file the caller did not approve.

There is no delete command, no update command, and no remediation command.
Their absence is the interface guarantee.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.collectors.models import (  # noqa: E402
    CollectorError, CollectorResult, Observation as CollectedObservation,
)
from tools.observation.evidence_store import EvidenceStore, StoreError  # noqa: E402
from tools.observation.knowledge import build_knowledge_state  # noqa: E402
from tools.observation.orchestrator import Orchestrator, OrchestrationError  # noqa: E402
from tools.observation.timeline import Timeline  # noqa: E402
from tools.collectors.redaction import redact  # noqa: E402

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INVOCATION_ERROR = 2


def _emit(payload) -> None:
    """Print deterministic JSON. Sorted keys so output is diffable and stable."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _fail(message: str) -> int:
    print(f"ERROR {message}", file=sys.stderr)
    return EXIT_INVOCATION_ERROR


def _resolve_input(path_argument: str, approved_directory: str) -> Path:
    """Resolve an input file, requiring it to stay inside the approved directory.

    resolve() follows symlinks, so a link pointing outside fails the same
    containment check as ordinary traversal.
    """
    approved = Path(approved_directory).expanduser().resolve()
    if not approved.is_dir():
        raise ValueError("approved input directory does not exist")

    candidate = Path(path_argument)
    resolved = (approved / candidate).resolve() if not candidate.is_absolute() else candidate.resolve()

    if not str(resolved).startswith(str(approved) + "/") and resolved != approved:
        raise ValueError("input file escapes the approved input directory")
    if not resolved.is_file():
        raise ValueError("input file does not exist")
    return resolved


def _load_collector_result(path: Path) -> CollectorResult:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("collector result file must contain a JSON object")

    for field in ("collector_id", "target", "status"):
        if not payload.get(field):
            raise ValueError(f"collector result is missing '{field}'")

    observations = [
        CollectedObservation(
            fact=str(item.get("fact")),
            value=item.get("value"),
            value_type=str(item.get("value_type") or "string"),
            collected_at=str(item.get("collected_at") or payload.get("completed_at") or ""),
            source=str(item.get("source") or payload.get("collector_id")),
            sensitivity=str(item.get("sensitivity") or "internal"),
        )
        for item in (payload.get("observations") or [])
    ]
    errors = [
        CollectorError(
            category=str(item.get("category") or "internal"),
            summary=str(item.get("summary") or ""),
            retryable=bool(item.get("retryable", False)),
        )
        for item in (payload.get("errors") or [])
    ]

    return CollectorResult(
        collector_id=str(payload["collector_id"]),
        target=str(payload["target"]),
        status=str(payload["status"]),
        started_at=str(payload.get("started_at") or payload.get("completed_at") or ""),
        completed_at=str(payload.get("completed_at") or payload.get("started_at") or ""),
        observations=observations,
        errors=errors,
    )


def _load_json_option(path_argument: str | None, label: str):
    if not path_argument:
        return None
    path = Path(path_argument).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"{label} file does not exist")
    return json.loads(path.read_text(encoding="utf-8"))


def _open_store(root: str | None) -> EvidenceStore:
    if not root:
        # No default: a default store root is a production path waiting to be
        # written to by an invocation nobody reviewed.
        raise ValueError("--store-root is required and has no default")
    return EvidenceStore(root)


def command_ingest(args) -> int:
    try:
        store = _open_store(args.store_root)
        source = _resolve_input(args.collector_result, args.input_dir or ".")
        result = _load_collector_result(source)
        declared = _load_json_option(args.declared, "declared entity")
        rules = _load_json_option(args.rules, "rules") or []
    except (ValueError, json.JSONDecodeError, OSError, StoreError) as error:
        return _fail(f"ingest input rejected: {error}")

    try:
        outcome = Orchestrator(store).process_collector_result(
            result, declared=declared, rules=rules, evaluated_at=args.evaluated_at)
    except OrchestrationError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return EXIT_FAILED

    # Belt and braces: the pipeline redacts at source, but this is the last
    # point before output reaches a terminal or a log.
    payload, _ = redact(outcome.to_dict())
    _emit(payload)
    return EXIT_FAILED if outcome.errors else EXIT_OK


def command_timeline(args) -> int:
    try:
        store = _open_store(args.store_root)
    except (ValueError, StoreError) as error:
        return _fail(str(error))
    events = Timeline(store).query(target=args.target)
    payload, _ = redact([event.to_dict() for event in events])
    _emit(payload)
    return EXIT_OK


def command_knowledge(args) -> int:
    try:
        store = _open_store(args.store_root)
        declared = _load_json_option(args.declared, "declared entity")
        rules = _load_json_option(args.rules, "rules") or []
    except (ValueError, json.JSONDecodeError, OSError, StoreError) as error:
        return _fail(str(error))

    generated_at = args.generated_at or store.newest_evidence_time(args.target)
    if not generated_at:
        return _fail("no evidence exists for this target and no --generated-at was supplied")

    state = build_knowledge_state(target=args.target, store=store, declared=declared,
                                  rules=rules, generated_at=generated_at)
    payload, _ = redact(state.to_dict())
    _emit(payload)
    return EXIT_OK


def command_verify(args) -> int:
    """Re-evaluate stored evidence without ingesting anything new."""
    try:
        store = _open_store(args.store_root)
        declared = _load_json_option(args.declared, "declared entity")
        rules = _load_json_option(args.rules, "rules") or []
    except (ValueError, json.JSONDecodeError, OSError, StoreError) as error:
        return _fail(str(error))

    from tools.observation.verifier import verify as verify_target

    evidence = store.list_evidence(args.target)
    generated_at = args.evaluated_at or store.newest_evidence_time(args.target)
    if not generated_at:
        return _fail("no evidence exists for this target and no --evaluated-at was supplied")

    record = verify_target(
        declared=declared or {"id": args.target},
        evidence_records=evidence,
        rules=rules,
        evaluated_at=generated_at,
        verification_id=store.allocate_id("verification"),
    )
    try:
        store.write_verification(record)
    except StoreError as error:
        print(f"ERROR verification could not be persisted: {error}", file=sys.stderr)
        return EXIT_FAILED

    payload, _ = redact(record.to_dict())
    _emit(payload)
    return EXIT_OK


def command_validate_store(args) -> int:
    try:
        store = _open_store(args.store_root)
    except (ValueError, StoreError) as error:
        return _fail(str(error))

    problems = store.validate()
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        _emit({"status": "invalid", "problems": problems, "counts": store.counts()})
        return EXIT_FAILED
    _emit({"status": "ok", "counts": store.counts()})
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.observation.cli",
        description=(
            "Ingest collector results into an immutable evidence store and query "
            "derived knowledge. Read-only with respect to platform-model; no "
            "delete, update, or remediation command exists."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_store_root(target_parser, require_target: bool = False):
        target_parser.add_argument("--store-root", default=None,
                                   help="Explicit data root. Required; there is no default.")
        if require_target:
            target_parser.add_argument("--target", required=True)
        target_parser.add_argument("--declared", default=None,
                                   help="JSON file holding the declared entity")
        target_parser.add_argument("--rules", default=None,
                                   help="JSON file holding applicable rules")

    ingest = sub.add_parser("ingest", help="Ingest a collector result JSON file")
    add_store_root(ingest)
    ingest.add_argument("--collector-result", required=True,
                        help="JSON file inside --input-dir")
    ingest.add_argument("--input-dir", default=None,
                        help="Directory the collector result must stay inside")
    ingest.add_argument("--evaluated-at", default=None,
                        help="RFC 3339 timestamp with offset, supplied by the caller")

    timeline = sub.add_parser("timeline", help="List knowledge events for a target")
    add_store_root(timeline, require_target=True)

    knowledge = sub.add_parser("knowledge", help="Derive knowledge state for a target")
    add_store_root(knowledge, require_target=True)
    knowledge.add_argument("--generated-at", default=None)

    verify_parser = sub.add_parser("verify", help="Re-evaluate stored evidence for a target")
    add_store_root(verify_parser, require_target=True)
    verify_parser.add_argument("--evaluated-at", default=None)

    validate = sub.add_parser("validate-store", help="Check store structural integrity")
    add_store_root(validate)

    args = parser.parse_args(argv)

    handlers = {
        "ingest": command_ingest,
        "timeline": command_timeline,
        "knowledge": command_knowledge,
        "verify": command_verify,
        "validate-store": command_validate_store,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
