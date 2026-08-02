"""Remote read-only collection.

Remote collectors observe. They never administer.

Every module here is bounded by that one distinction. A collector names an
operation identifier; the catalog owns the argv. No command text crosses a
public API, no shell is ever invoked, and host-key verification cannot be
turned off.

See docs/decisions/ADR-0010-remote-read-only-collection.md.
"""
