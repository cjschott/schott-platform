"""YAML loading that refuses duplicate mapping keys.

A standard YAML loader silently keeps only the last value for a repeated key.
For configuration that is a nuisance; for a controlled vocabulary it is a
correctness failure. The platform ontology carried three ``SUPERSEDES``
definitions, two of which disappeared during parsing, and every reader
downstream believed a vocabulary the file did not declare. Nothing noticed,
because nothing could.

This module is the reusable helper for anywhere that must not be lied to:

    from tools.common.yaml_strict import load_strict, DuplicateKeyError

    try:
        document = load_strict(path)
    except DuplicateKeyError as error:
        ...  # error names the file, the key, and the line

It fails closed. There is no permissive mode and no flag to allow duplicates
whose values happen to match: a loader that permits harmless duplicates has to
decide what harmless means, and it will eventually decide wrongly.

Repeated key *names* in sibling mappings are not duplicates. Only a key
repeated within one mapping is.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

__all__ = ["DuplicateKeyError", "UniqueKeyLoader", "load_strict", "loads_strict"]


class DuplicateKeyError(ValueError):
    """Raised when one mapping declares the same key twice.

    Carries the source, key, and line separately as well as in the message, so
    a caller can report them without parsing prose.
    """

    def __init__(self, key: Any, source: str, line: int, first_line: int) -> None:
        self.key = key
        self.source = source
        self.line = line
        self.first_line = first_line
        super().__init__(
            f"{source}: duplicate mapping key {key!r} at line {line} "
            f"(first declared at line {first_line}); "
            f"a standard loader would silently keep only the last value"
        )


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects a key repeated within a single mapping.

    Subclasses SafeLoader rather than FullLoader or UnsafeLoader: strictness
    about duplicates is no reason to give up strictness about construction.
    """

    # The source name is attached per-load so the error can identify the file.
    _strict_source: str = "<yaml>"

    def construct_mapping(self, node, deep: bool = False):  # noqa: ANN001
        seen: dict[Any, int] = {}
        for key_node, _value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            # An unhashable key is already a YAML error; let the base class
            # produce its own, better-worded complaint about it.
            try:
                previous = seen.get(key)
            except TypeError:
                continue
            line = key_node.start_mark.line + 1
            if previous is not None:
                raise DuplicateKeyError(
                    key=key,
                    source=getattr(self, "_strict_source", "<yaml>"),
                    line=line,
                    first_line=previous,
                )
            seen[key] = line
        return super().construct_mapping(node, deep=deep)


def _load(text: str, source: str) -> Any:
    loader = UniqueKeyLoader(text)
    loader._strict_source = source  # noqa: SLF001 - the loader is ours
    try:
        return loader.get_single_data()
    finally:
        loader.dispose()


def loads_strict(text: str, source: str = "<string>") -> Any:
    """Parse YAML text, refusing duplicate mapping keys.

    ``source`` appears in the error message; pass a filename when one exists.
    """
    return _load(text, source)


def load_strict(path: str | Path) -> Any:
    """Parse a YAML file, refusing duplicate mapping keys.

    The path is reported in the error, because a duplicate-key failure in CI
    without a filename is a hunt rather than a finding.
    """
    path = Path(path)
    return _load(path.read_text(encoding="utf-8"), str(path))
