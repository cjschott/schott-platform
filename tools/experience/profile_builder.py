"""Build experience profiles from observed history.

A profile summarizes one metric over one window. It reads evidence and writes
nothing: the evidence store is opened read-only in every sense that matters,
and no method here can modify a record.

Nothing is invented. A metric nothing observed produces a profile with zero
samples and null statistics, not a profile full of zeros — those are different
claims, and only one of them is true.
"""

from __future__ import annotations

from typing import Any

from .models import ExperienceProfile, ExperienceWindow, Trend, require_timezone
from .statistics import detect_trend, summarize_samples
from .windows import contains


class ProfileError(Exception):
    """A profile could not be built. Never contains an observed value."""


def collect_samples(evidence_store, *, target: str, metric: str,
                    window: ExperienceWindow) -> list[tuple[str, Any]]:
    """Return (timestamp, value) pairs for a metric inside a window.

    Chronological, oldest first, because trend detection measures direction and
    reordering would destroy it.

    Failed and unavailable collections are excluded. A collector that could not
    look observed nothing, and folding its record into a statistical summary
    would let an outage look like a measurement.
    """
    if evidence_store is None:
        raise ProfileError("an evidence store is required to collect samples")

    samples: list[tuple[str, Any]] = []
    for record in evidence_store.list_evidence(target):
        if str(record.get("status")) in {"failed", "unavailable"}:
            continue
        collected_at = str(record.get("collected_at") or "")
        if not collected_at or not contains(window, collected_at):
            continue
        facts = record.get("facts") or {}
        if metric not in facts:
            continue
        samples.append((collected_at, facts[metric]))

    # Sorted by timestamp then value, so two samples sharing a timestamp order
    # deterministically rather than by whatever the store returned.
    return sorted(samples, key=lambda item: (item[0], str(item[1])))


def build_profile(evidence_store, *, target: str, metric: str,
                  window: ExperienceWindow, profile_id: str,
                  generated_at: str) -> ExperienceProfile:
    """Summarize one metric over one window.

    Deterministic: identical history, window, and identifier produce an
    identical profile.
    """
    if not target:
        raise ProfileError("a target is required")
    if not metric:
        raise ProfileError("a metric is required")

    stamp = require_timezone(generated_at, "generated_at")

    samples = collect_samples(evidence_store, target=target, metric=metric, window=window)
    values = [value for _, value in samples]

    statistics = summarize_samples(values)
    trend = detect_trend(values)

    return ExperienceProfile(
        id=profile_id,
        target=target,
        metric=metric,
        generated_at=stamp,
        window=window.id or None,
        window_label=window.label,
        window_start=window.window_start,
        window_end=window.window_end,
        sample_count=statistics["sample_count"],
        minimum=statistics["minimum"],
        maximum=statistics["maximum"],
        mean=statistics["mean"],
        median=statistics["median"],
        standard_deviation=statistics["standard_deviation"],
        trend=trend["trend"] or Trend.UNKNOWN.value,
        trend_explanation=trend["explanation"],
    )
