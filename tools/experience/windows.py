"""Rolling windows over observed history.

A window is a bounded span of time. Profiles summarize one window, and a
baseline summarizes one or more.

Windows are resolved from an explicit `now` rather than read from the clock.
Reading the clock inside the engine would make every profile irreproducible:
the same command run twice would summarize two different spans and quietly
disagree with itself.
"""

from __future__ import annotations

from datetime import timedelta

from .models import ExperienceWindow, parse_timestamp, require_timezone

# The supported rolling windows, in seconds. `custom` carries no duration of
# its own — the caller must supply one, because a default would be an invented
# span presented as a chosen one.
WINDOW_PRESETS: dict[str, int | None] = {
    "24h": 86_400,
    "7d": 604_800,
    "30d": 2_592_000,
    "custom": None,
}


def resolve_window(label: str, *, now: str, duration_seconds: int | None = None,
                   window_id: str | None = None) -> ExperienceWindow:
    """Return the window a label denotes, ending at `now`.

    Deterministic: the same label and the same `now` always produce the same
    window.
    """
    if label not in WINDOW_PRESETS:
        supported = ", ".join(sorted(WINDOW_PRESETS))
        raise ValueError(f"unknown window '{label}'; supported windows are {supported}")

    end = require_timezone(now, "now")

    if label == "custom":
        if duration_seconds is None:
            raise ValueError(
                "a custom window requires an explicit duration_seconds; no default "
                "is assumed because an invented span would look like a chosen one"
            )
        duration = int(duration_seconds)
    else:
        duration = int(WINDOW_PRESETS[label])
        if duration_seconds is not None and int(duration_seconds) != duration:
            raise ValueError(
                f"window '{label}' has a fixed duration of {duration}s; pass "
                "'custom' to choose a different span"
            )

    if duration <= 0:
        raise ValueError("window duration must be positive")

    start = (parse_timestamp(end) - timedelta(seconds=duration)).isoformat()

    return ExperienceWindow(
        id=window_id or "",
        label=label,
        window_start=start,
        window_end=end,
        duration_seconds=duration,
    )


def contains(window: ExperienceWindow, timestamp: str) -> bool:
    """True when a timestamp falls inside the window.

    The start is inclusive and the end is inclusive, so a sample taken exactly
    at `now` is counted rather than silently dropped.
    """
    try:
        moment = parse_timestamp(timestamp)
    except (ValueError, TypeError):
        return False
    return parse_timestamp(window.window_start) <= moment <= parse_timestamp(window.window_end)
