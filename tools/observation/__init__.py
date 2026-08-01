"""Knowledge orchestration: immutable evidence and a derived knowledge state.

This package consumes `CollectorResult` objects and never produces them. It
assigns persistent identifiers, writes evidence exactly once, and derives
current knowledge rather than storing it.

See docs/decisions/ADR-0004-immutable-knowledge-timeline.md.
"""
