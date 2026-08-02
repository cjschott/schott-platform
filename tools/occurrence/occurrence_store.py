"""Append-only store for occurrences, series, patterns, and timelines.

Built on `tools/common/immutable_store.py` rather than by copying the write
path a fourth time. That base carries the atomic-link write, the overwrite
refusal, the locked sequence allocation, and the repository-root refusal; this
module only declares which record kinds exist.

There is no update method and no delete method, because the base provides
neither.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from tools.common.immutable_store import ImmutableStore, StoreError  # noqa: F401

from .models import ID_PATTERNS, ID_PREFIXES


class OccurrenceStore(ImmutableStore):
    """Immutable storage for temporal records."""

    record_dirs = {
        "occurrence": "occurrences",
        "series": "series",
        "pattern": "patterns",
        "timeline": "timelines",
    }
    id_patterns = ID_PATTERNS
    id_prefixes = ID_PREFIXES

    def write_occurrence(self, occurrence) -> Path:
        return self.write_record("occurrence", occurrence)

    def write_series(self, series) -> Path:
        return self.write_record("series", series)

    def write_pattern(self, pattern) -> Path:
        return self.write_record("pattern", pattern)

    def write_timeline(self, timeline) -> Path:
        return self.write_record("timeline", timeline)

    def list_occurrences(self, target: str | None = None) -> list[dict[str, Any]]:
        return self.list_records("occurrence", target)

    def list_series(self, target: str | None = None) -> list[dict[str, Any]]:
        return self.list_records("series", target)

    def latest_series(self, target: str, kind: str) -> dict[str, Any] | None:
        """The newest series for a kind. Older ones are never removed."""
        candidates = [s for s in self.list_series(target) if s.get("kind") == kind]
        if not candidates:
            return None
        return max(candidates,
                   key=lambda s: (str(s.get("generated_at") or ""), str(s.get("id"))))
