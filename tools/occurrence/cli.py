"""Command line interface for the Occurrence Timeline.

Prints deterministic JSON to stdout and diagnostics to stderr.

Exit status:
    0  the operation succeeded
    1  the operation ran and failed
    2  invocation or configuration error

Commands:
    record     derive occurrences from evidence
    series     summarize occurrences into a series
    patterns   report the temporal shapes a series exhibits
    timeline   list occurrences in chronological order

There is no predict, forecast, update, or delete command. Their absence is the
interface guarantee: this tool reports what happened and when.

Both roots are explicit and never defaulted. A default eventually becomes a
production path someone wrote to by accident.
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
from tools.common.immutable_store import StoreError  # noqa: E402
from tools.observation.evidence_store import (  # noqa: E402
    EvidenceStore, StoreError as EvidenceStoreError,
)
from tools.occurrence.occurrence_store import OccurrenceStore  # noqa: E402
from tools.occurrence.patterns import detect_patterns  # noqa: E402
from tools.occurrence.recorder import occurrences_from_evidence  # noqa: E402
from tools.occurrence.series import build_series  # noqa: E402
from tools.occurrence.timeline import build_timeline  # noqa: E402

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INVOCATION_ERROR = 2

# Identifiers used when a command is not persisting. A read-only query must not
# advance a store sequence as a side effect, or two identical queries would
# return different output.
UNPERSISTED_SERIES_ID = "SERIES-000000"
UNPERSISTED_TIMELINE_ID = "TL-000000"


def _emit(payload) -> None:
    """Print deterministic JSON. Sorted keys so output is diffable and stable."""
    print(json.dumps(payload, indent=2, sort_keys=True, default=str))


def _fail(message: str) -> int:
    print(f"ERROR {message}", file=sys.stderr)
    return EXIT_INVOCATION_ERROR


def _open(args):
    if not args.store_root:
        raise ValueError("--store-root is required and has no default")
    if not args.evidence_root:
        raise ValueError("--evidence-root is required and has no default")
    return EvidenceStore(args.evidence_root), OccurrenceStore(args.store_root)


def _generated_at(args, evidence_store) -> str:
    stamp = args.generated_at or evidence_store.newest_evidence_time(args.target)
    if not stamp:
        raise ValueError(
            "no evidence exists for this target and no --generated-at was supplied"
        )
    return stamp


def _derive(args, evidence_store, stamp):
    return occurrences_from_evidence(
        evidence_store, target=args.target, kind=args.kind, recorded_at=stamp)


def command_record(args) -> int:
    try:
        evidence_store, occurrence_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        occurrences = _derive(args, evidence_store, stamp)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    if args.persist:
        # Identifiers are allocated only when a record is actually kept.
        persisted = []
        for occurrence in occurrences:
            identifier = occurrence_store.allocate_id("occurrence")
            from tools.occurrence.recorder import record_occurrence
            stored = record_occurrence(
                occurrence_id=identifier, target=occurrence.target,
                kind=occurrence.kind, occurred_at=occurrence.occurred_at,
                source=occurrence.source, recorded_at=occurrence.recorded_at,
                detail=occurrence.detail)
            try:
                occurrence_store.write_occurrence(stored)
            except StoreError as error:
                print(f"ERROR occurrence could not be persisted: {error}", file=sys.stderr)
                return EXIT_FAILED
            persisted.append(stored)
        occurrences = persisted

    payload, _ = redact([o.to_dict() for o in occurrences])
    _emit(payload)
    return EXIT_OK


def command_series(args) -> int:
    try:
        evidence_store, occurrence_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        occurrences = _derive(args, evidence_store, stamp)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    series_id = occurrence_store.allocate_id("series") if args.persist \
        else UNPERSISTED_SERIES_ID
    series = build_series(occurrences, series_id=series_id, generated_at=stamp,
                          target=args.target, kind=args.kind)
    if args.persist:
        try:
            occurrence_store.write_series(series)
        except StoreError as error:
            print(f"ERROR series could not be persisted: {error}", file=sys.stderr)
            return EXIT_FAILED

    payload, _ = redact(series.to_dict())
    _emit(payload)
    return EXIT_OK


def command_patterns(args) -> int:
    try:
        evidence_store, occurrence_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        occurrences = _derive(args, evidence_store, stamp)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    series = build_series(occurrences, series_id=UNPERSISTED_SERIES_ID,
                          generated_at=stamp, target=args.target, kind=args.kind)
    patterns = detect_patterns(series, pattern_id_prefix="PAT", generated_at=stamp)

    payload, _ = redact([p.to_dict() for p in patterns])
    _emit(payload)
    return EXIT_OK


def command_timeline(args) -> int:
    try:
        evidence_store, occurrence_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        occurrences = _derive(args, evidence_store, stamp)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    timeline_id = occurrence_store.allocate_id("timeline") if args.persist \
        else UNPERSISTED_TIMELINE_ID
    timeline = build_timeline(occurrences, timeline_id=timeline_id,
                              generated_at=stamp, target=args.target,
                              limit=args.limit)
    if args.persist:
        try:
            occurrence_store.write_timeline(timeline)
        except StoreError as error:
            print(f"ERROR timeline could not be persisted: {error}", file=sys.stderr)
            return EXIT_FAILED

    payload, _ = redact(timeline.to_dict())
    _emit(payload)
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.occurrence.cli",
        description=(
            "Record when things happened and summarize their temporal history. "
            "Describes observed occurrences only: nothing here predicts, "
            "forecasts, or acts."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target_parser, *, with_limit: bool = False):
        target_parser.add_argument("--target", required=True)
        target_parser.add_argument("--kind", required=True,
                                   help="What kind of thing happened")
        target_parser.add_argument("--store-root", default=None,
                                   help="Explicit occurrence data root. No default.")
        target_parser.add_argument("--evidence-root", default=None,
                                   help="Explicit observation store root. No default.")
        target_parser.add_argument("--generated-at", default=None,
                                   help="RFC 3339 timestamp with offset")
        target_parser.add_argument("--persist", action="store_true",
                                   help="Also write the records to the store")
        if with_limit:
            target_parser.add_argument("--limit", type=int, default=None,
                                       help="Most recent N entries")

    common(sub.add_parser("record", help="Derive occurrences from evidence"))
    common(sub.add_parser("series", help="Summarize occurrences into a series"))
    common(sub.add_parser("patterns", help="Report observed temporal shapes"))
    common(sub.add_parser("timeline", help="List occurrences in order"), with_limit=True)

    args = parser.parse_args(argv)
    if not hasattr(args, "limit"):
        args.limit = None

    handlers = {
        "record": command_record,
        "series": command_series,
        "patterns": command_patterns,
        "timeline": command_timeline,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
