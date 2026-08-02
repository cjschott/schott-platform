"""Command line interface for the Operational Integrity Engine.

Prints JSON to stdout and diagnostics to stderr.

Exit status:
    0  the operation succeeded
    1  the operation ran and failed
    2  invocation or configuration error

There is no execute command, no recover command, and no delete command. Their
absence is the interface guarantee: this tool can describe what it would take
to reconstruct a state, and it has no way to do it.

Both store roots are explicit and never defaulted. A default eventually
becomes a production path someone wrote to by accident.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.collectors.redaction import redact  # noqa: E402
from tools.observation.evidence_store import EvidenceStore, StoreError as EvidenceStoreError  # noqa: E402
from tools.observation.knowledge import build_knowledge_state  # noqa: E402
from tools.integrity.integrity_analyzer import analyze_integrity  # noqa: E402
from tools.integrity.recovery_planner import plan_recovery  # noqa: E402
from tools.integrity.snapshot_manager import (  # noqa: E402
    SnapshotStore, StoreError, create_snapshot,
)
from tools.integrity.twin_builder import build_twin  # noqa: E402

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INVOCATION_ERROR = 2


def _emit(payload) -> None:
    """Print deterministic JSON. Sorted keys so output is diffable."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _fail(message: str) -> int:
    print(f"ERROR {message}", file=sys.stderr)
    return EXIT_INVOCATION_ERROR


def _open_stores(args):
    if not args.store_root:
        raise ValueError("--store-root is required and has no default")
    if not args.evidence_root:
        raise ValueError("--evidence-root is required and has no default")
    return EvidenceStore(args.evidence_root), SnapshotStore(args.store_root)


def _knowledge_for(evidence_store, target: str, generated_at: str | None):
    stamp = generated_at or evidence_store.newest_evidence_time(target)
    if not stamp:
        raise ValueError(
            "no evidence exists for this target and no --generated-at was supplied"
        )
    return build_knowledge_state(target=target, store=evidence_store,
                                 declared=None, rules=(), generated_at=stamp)


def command_snapshot(args) -> int:
    try:
        evidence_store, snapshots = _open_stores(args)
        knowledge = _knowledge_for(evidence_store, args.target, args.generated_at)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    record = create_snapshot(knowledge, evidence_store,
                             snapshot_id=snapshots.allocate_id("snapshot"),
                             created_at=knowledge.generated_at, label=args.label or "")
    try:
        snapshots.write_snapshot(record)
    except StoreError as error:
        print(f"ERROR snapshot could not be persisted: {error}", file=sys.stderr)
        return EXIT_FAILED

    payload, _ = redact(record.to_dict())
    _emit(payload)
    return EXIT_OK


def command_twin(args) -> int:
    """Build a twin and print it. Nothing is stored: twins are disposable."""
    try:
        evidence_store, _ = _open_stores(args)
        knowledge = _knowledge_for(evidence_store, args.target, args.generated_at)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    twin = build_twin(knowledge, evidence_store, twin_id="TWIN-000001",
                      built_at=knowledge.generated_at)
    payload, _ = redact(twin.to_dict())
    _emit(payload)
    return EXIT_OK


def command_analyze(args) -> int:
    try:
        evidence_store, snapshots = _open_stores(args)
        knowledge = _knowledge_for(evidence_store, args.target, args.generated_at)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    reference = snapshots.read_snapshot(args.snapshot) if args.snapshot \
        else snapshots.latest_snapshot(args.target)
    if not reference:
        return _fail(f"no snapshot exists for {args.target}; take one first")

    twin = build_twin(knowledge, evidence_store, twin_id="TWIN-000001",
                      built_at=knowledge.generated_at)
    report = analyze_integrity(snapshot=reference, twin=twin,
                               evaluated_at=knowledge.generated_at,
                               report_id=snapshots.allocate_id("integrity"))
    if args.persist:
        try:
            snapshots.write_report(report)
        except StoreError as error:
            print(f"ERROR report could not be persisted: {error}", file=sys.stderr)
            return EXIT_FAILED

    payload, _ = redact(report.to_dict())
    _emit(payload)
    return EXIT_OK


def command_plan(args) -> int:
    """Produce an advisory recovery plan. Nothing is executed."""
    try:
        evidence_store, snapshots = _open_stores(args)
        knowledge = _knowledge_for(evidence_store, args.target, args.generated_at)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    reference = snapshots.read_snapshot(args.snapshot) if args.snapshot \
        else snapshots.latest_snapshot(args.target)
    if not reference:
        return _fail(f"no snapshot exists for {args.target}; take one first")

    twin = build_twin(knowledge, evidence_store, twin_id="TWIN-000001",
                      built_at=knowledge.generated_at)
    report = analyze_integrity(snapshot=reference, twin=twin,
                               evaluated_at=knowledge.generated_at,
                               report_id=snapshots.allocate_id("integrity"))
    plan = plan_recovery(report=report, snapshot=reference,
                         plan_id=snapshots.allocate_id("recovery"),
                         created_at=knowledge.generated_at)
    if args.persist:
        try:
            snapshots.write_plan(plan)
        except StoreError as error:
            print(f"ERROR plan could not be persisted: {error}", file=sys.stderr)
            return EXIT_FAILED

    payload, _ = redact(plan.to_dict())
    _emit(payload)
    return EXIT_OK


def command_validate_store(args) -> int:
    try:
        if not args.store_root:
            raise ValueError("--store-root is required and has no default")
        snapshots = SnapshotStore(args.store_root)
    except (ValueError, StoreError) as error:
        return _fail(str(error))

    problems = snapshots.validate()
    if problems:
        for problem in problems:
            print(f"ERROR {problem}", file=sys.stderr)
        _emit({"status": "invalid", "problems": problems, "counts": snapshots.counts()})
        return EXIT_FAILED
    _emit({"status": "ok", "counts": snapshots.counts()})
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.integrity.cli",
        description=(
            "Create immutable snapshots, rebuild disposable digital twins, compare "
            "them, and produce advisory recovery plans. Nothing here executes a "
            "recovery or modifies platform-model."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target_parser, *, needs_snapshot: bool = False):
        target_parser.add_argument("--target", required=True)
        target_parser.add_argument("--store-root", default=None,
                                   help="Explicit integrity data root. No default.")
        target_parser.add_argument("--evidence-root", default=None,
                                   help="Explicit observation store root. No default.")
        target_parser.add_argument("--generated-at", default=None,
                                   help="RFC 3339 timestamp with offset")
        if needs_snapshot:
            target_parser.add_argument("--snapshot", default=None,
                                       help="Snapshot id; defaults to the newest")
            target_parser.add_argument("--persist", action="store_true",
                                       help="Also write the record to the store")

    snapshot_parser = sub.add_parser("snapshot", help="Create an immutable snapshot")
    common(snapshot_parser)
    snapshot_parser.add_argument("--label", default=None,
                                 help="Human label, e.g. 'known-good after v0.7.0'")

    twin_parser = sub.add_parser("twin", help="Rebuild a disposable digital twin")
    common(twin_parser)

    analyze_parser = sub.add_parser("analyze", help="Compare a twin against a snapshot")
    common(analyze_parser, needs_snapshot=True)

    plan_parser = sub.add_parser("plan", help="Produce an advisory recovery plan")
    common(plan_parser, needs_snapshot=True)

    validate_parser = sub.add_parser("validate-store", help="Check store integrity")
    validate_parser.add_argument("--store-root", default=None)

    args = parser.parse_args(argv)

    handlers = {
        "snapshot": command_snapshot,
        "twin": command_twin,
        "analyze": command_analyze,
        "plan": command_plan,
        "validate-store": command_validate_store,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
