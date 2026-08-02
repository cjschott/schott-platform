"""Command line interface for the Experience Engine.

Prints deterministic JSON to stdout and diagnostics to stderr.

Exit status:
    0  the operation succeeded
    1  the operation ran and failed
    2  invocation or configuration error

Commands:
    build       summarize one metric over one window into a profile
    summarize   derive a baseline from profiles
    compare     classify a current value against a baseline
    explain     show every number and the reasoning behind it

There is no predict, forecast, or train command, and no delete. Their absence
is the interface guarantee: this tool summarizes what happened and nothing else.

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
from tools.observation.evidence_store import (  # noqa: E402
    EvidenceStore, StoreError as EvidenceStoreError,
)
from tools.experience.baseline import build_baseline, classify_behaviour  # noqa: E402
from tools.experience.experience_store import ExperienceStore, StoreError  # noqa: E402
from tools.experience.profile_builder import build_profile  # noqa: E402
from tools.experience.windows import resolve_window  # noqa: E402

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_INVOCATION_ERROR = 2


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
    return EvidenceStore(args.evidence_root), ExperienceStore(args.store_root)


def _generated_at(args, evidence_store) -> str:
    stamp = args.generated_at or evidence_store.newest_evidence_time(args.target)
    if not stamp:
        raise ValueError(
            "no evidence exists for this target and no --generated-at was supplied"
        )
    return stamp


# Identifiers are only consumed when a record is actually kept. A read-only
# command that allocated one would advance the sequence as a side effect and
# make two identical queries return different output.
UNPERSISTED_PROFILE_ID = "EXP-000000"
UNPERSISTED_BASELINE_ID = "BASE-000000"


def _profile_for(args, evidence_store, experience_store, stamp, *, persist: bool):
    window = resolve_window(args.window, now=stamp,
                            duration_seconds=args.duration_seconds)
    profile_id = experience_store.allocate_id("profile") if persist \
        else UNPERSISTED_PROFILE_ID
    profile = build_profile(
        evidence_store, target=args.target, metric=args.metric, window=window,
        profile_id=profile_id, generated_at=stamp)
    if persist:
        experience_store.write_profile(profile)
    return profile


def _baseline_for(args, profile, experience_store, stamp, *, persist: bool):
    baseline_id = experience_store.allocate_id("baseline") if persist \
        else UNPERSISTED_BASELINE_ID
    baseline = build_baseline(
        [profile], baseline_id=baseline_id,
        generated_at=stamp, target=args.target, metric=args.metric)
    if persist:
        experience_store.write_baseline(baseline)
    return baseline


def command_build(args) -> int:
    try:
        evidence_store, experience_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        profile = _profile_for(args, evidence_store, experience_store, stamp,
                               persist=args.persist)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    payload, _ = redact(profile.to_dict())
    _emit(payload)
    return EXIT_OK


def command_summarize(args) -> int:
    try:
        evidence_store, experience_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        profile = _profile_for(args, evidence_store, experience_store, stamp,
                               persist=args.persist)
        baseline = _baseline_for(args, profile, experience_store, stamp,
                                 persist=args.persist)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    payload, _ = redact(baseline.to_dict())
    _emit(payload)
    return EXIT_OK


def command_compare(args) -> int:
    try:
        evidence_store, experience_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        profile = _profile_for(args, evidence_store, experience_store, stamp,
                               persist=args.persist)
        baseline = _baseline_for(args, profile, experience_store, stamp,
                                 persist=args.persist)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    assessment = classify_behaviour(baseline, current_value=args.current_value)
    payload, _ = redact(assessment.to_dict())
    _emit(payload)
    return EXIT_OK


def command_explain(args) -> int:
    """Show every number and the reasoning behind it.

    The point of this command is that no figure in the output is unexplained.
    """
    try:
        evidence_store, experience_store = _open(args)
        stamp = _generated_at(args, evidence_store)
        profile = _profile_for(args, evidence_store, experience_store, stamp,
                               persist=args.persist)
        baseline = _baseline_for(args, profile, experience_store, stamp,
                                 persist=args.persist)
    except (ValueError, StoreError, EvidenceStoreError, OSError) as error:
        return _fail(str(error))

    assessment = classify_behaviour(baseline, current_value=args.current_value)

    payload, _ = redact({
        "target": args.target,
        "metric": args.metric,
        "window": {
            "label": profile.window_label,
            "window_start": profile.window_start,
            "window_end": profile.window_end,
        },
        "statistics": {
            "sample_count": profile.sample_count,
            "minimum": profile.minimum,
            "maximum": profile.maximum,
            "mean": profile.mean,
            "median": profile.median,
            "standard_deviation": profile.standard_deviation,
            "trend": profile.trend,
            "trend_explanation": profile.trend_explanation,
        },
        "baseline": {
            "id": baseline.id,
            "typical_value": baseline.typical_value,
            "tolerance": baseline.tolerance,
            "sample_count": baseline.sample_count,
        },
        "assessment": assessment.to_dict(),
        "confidence": (baseline.confidence.to_dict() if baseline.confidence else None),
        "explanation": assessment.explanation,
        "interpretation": (
            "These are observed statistics, not a truth claim and not a prediction."
        ),
    })
    _emit(payload)
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.experience.cli",
        description=(
            "Summarize observed history into experience profiles and operational "
            "baselines, and compare current values against them. Statistics only: "
            "nothing here predicts, learns, or acts."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def common(target_parser, *, needs_value: bool = False):
        target_parser.add_argument("--target", required=True)
        target_parser.add_argument("--metric", required=True)
        target_parser.add_argument("--window", default="24h",
                                   help="24h, 7d, 30d, or custom")
        target_parser.add_argument("--duration-seconds", type=int, default=None,
                                   dest="duration_seconds",
                                   help="Required when --window is custom")
        target_parser.add_argument("--store-root", default=None,
                                   help="Explicit experience data root. No default.")
        target_parser.add_argument("--evidence-root", default=None,
                                   help="Explicit observation store root. No default.")
        target_parser.add_argument("--generated-at", default=None,
                                   help="RFC 3339 timestamp with offset")
        target_parser.add_argument("--persist", action="store_true",
                                   help="Also write the records to the store")
        if needs_value:
            target_parser.add_argument("--current-value", type=float, default=None,
                                       dest="current_value",
                                       help="The value to compare against history")

    common(sub.add_parser("build", help="Summarize a metric into an experience profile"))
    common(sub.add_parser("summarize", help="Derive an operational baseline"))
    common(sub.add_parser("compare", help="Classify a current value against history"),
           needs_value=True)
    common(sub.add_parser("explain", help="Show every number and the reasoning"),
           needs_value=True)

    args = parser.parse_args(argv)
    if not hasattr(args, "current_value"):
        args.current_value = None

    handlers = {
        "build": command_build,
        "summarize": command_summarize,
        "compare": command_compare,
        "explain": command_explain,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
