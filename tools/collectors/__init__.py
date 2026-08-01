"""Collector framework for the Schott Platform evidence pipeline.

Read-only by construction. Nothing in this package opens a network socket,
spawns a subprocess, writes a file, mutates a canonical platform entity,
assigns an evidence identifier, or performs remediation.

See docs/standards/collector-plugin-standard.md and
docs/decisions/ADR-0002-evidence-first-architecture.md.
"""
