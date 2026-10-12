"""Result and output-tree collection for the ENG-0005 first adapter.

This is the component that reads bytes an adversary wrote, out of a directory
the adversary owns, while running as the privileged reader. Track-B Finding A
is exactly that hazard, so nothing here trusts a name: the output root arrives
as an already-open descriptor, every child is reached relative to it, and no
link is ever followed.

**The complete tree is the unit.** A result is admitted only out of a tree that
passed in full. Stopping at a valid ``result.json`` would mean the object one
directory along was never looked at, and beside the result is precisely where
something hostile would be put. A valid result inside a violating tree fails
the invocation.

**The terminal classification decides, and the bytes do not.** T13 establishes
whether the workload started, ended cleanly, and may be believed;
``read_result`` refuses unless it did. Result content is data throughout — it
selects no path, moves no bound, and reaches nothing that decided the outcome.
A capability cannot self-declare success.

**Three different failures, kept apart.** A hostile filesystem shape is
``output_tree_policy_violation``. A tree that was valid with no canonical
result in it is ``result_missing``. A result that failed its document contract
is ``result_invalid``. Collapsing them would report an attack on the privileged
reader as somebody's malformed JSON.

**Collection is neutral; trust is not.** ``collect`` returns an ``OutputTree``
that is untrusted whatever it holds and whatever the container did, which is
what lets a failed execution be collected for forensic handling elsewhere by
the same call. Only ``read_result`` can produce a ``TrustedResult``, and only
when every condition holds. There is no flag between them for a caller to
forget to read.

Nothing here mutates, deletes, executes, escalates, or reads a clock. It
enumerates and hashes, or it refuses.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §11.
"""

from __future__ import annotations

import dataclasses
import hashlib
from types import MappingProxyType
from typing import Any

from ...common.trusted_source import TraversalRefused, walk_tree
from . import canonical_json
from .canonical_json import CanonicalJSONError
from .lifecycle import TerminalClassification, TerminalDisposition
from .types import Classification

# Design §11. The five tree bounds are handed to the generic traversal
# primitive, which holds none of them: they are this component's policy, and
# this is the component that can say why they were chosen.
OUTPUT_TREE_MAX_DEPTH = 16
OUTPUT_TREE_MAX_ENTRIES = 256
OUTPUT_MAXIMUM_FILES = 32
OUTPUT_MAXIMUM_FILE_BYTES = 2 * 1024 * 1024
OUTPUT_MAXIMUM_TOTAL_BYTES = 16 * 1024 * 1024

# Exactly this name, exactly at the root of the tree. No case variation, no
# nested copy, and nothing a manifest or a payload gets to nominate.
RESULT_NAME = "result.json"
RESULT_MAXIMUM_BYTES = OUTPUT_MAXIMUM_FILE_BYTES


class OutputRefused(ValueError):
    """Output could not be collected, or could not be trusted.

    ``classification`` is the accepted §25 member when the refusal is about the
    output itself. It is ``None`` when the refusal is about the terminal state,
    because that failure already has a name — T13 gave it one — and inventing a
    result classification for it would report the wrong thing entirely.
    """

    def __init__(self, classification: Classification | None,
                 message: str) -> None:
        super().__init__(message)
        self.classification = classification


@dataclasses.dataclass(frozen=True)
class CollectedFile:
    """One regular file that satisfied every bound.

    Identity is the relative path, the exact byte count, and the digest of the
    bytes as they were read. No inode, no mode, and no timestamp: none of them
    is evidence of anything a later reader should rely on.
    """

    relative_path: str
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class OutputManifest:
    """The complete, deterministic description of one accepted output tree."""

    files: tuple[CollectedFile, ...]
    file_count: int
    total_bytes: int
    entry_count: int
    result_present: bool


@dataclasses.dataclass(frozen=True)
class OutputTree:
    """A structurally valid tree, and a structurally untrusted one.

    Reaching this type means the tree passed policy — not that the execution
    succeeded, and not that anything in it may be believed. It carries no
    ``trusted`` flag on purpose: a flag is something a caller can forget to
    read, and the type is not.
    """

    manifest: OutputManifest
    result_bytes: bytes | None


@dataclasses.dataclass(frozen=True)
class TrustedResult:
    """The one representation of a capability result that may be believed.

    It exists only where every §11 condition held, which is why it is a
    separate type rather than the same object in a better mood.
    """

    container_id: str
    document: Any
    manifest: OutputManifest


def _refuse_tree(error: TraversalRefused) -> OutputRefused:
    """Every generic traversal refusal is one execution classification.

    The traversal primitive reports depth, entries, types, and links in its own
    vocabulary and knows nothing about this adapter. Mapping happens here,
    where the specification's word for a hostile output tree lives.
    """
    return OutputRefused(
        Classification.OUTPUT_TREE_POLICY_VIOLATION,
        f"the output tree violates policy ({error.reason.value}): {error}")


def collect(out_fd: Any) -> OutputTree:
    """Every regular file beneath the verified output root, or refuse.

    The root is a descriptor because a pathname would be re-resolved against a
    directory the workload can still change. The whole tree is walked before
    anything is returned, and a single violation anywhere refuses the lot.

    This says nothing about whether the execution succeeded and asks nothing
    about it. The tree it returns is untrusted.
    """
    try:
        walked = walk_tree(
            out_fd,
            maximum_depth=OUTPUT_TREE_MAX_DEPTH,
            maximum_entries=OUTPUT_TREE_MAX_ENTRIES,
            maximum_files=OUTPUT_MAXIMUM_FILES,
            maximum_file_bytes=OUTPUT_MAXIMUM_FILE_BYTES,
            maximum_total_bytes=OUTPUT_MAXIMUM_TOTAL_BYTES,
        )
    except TraversalRefused as error:
        raise _refuse_tree(error) from None

    collected: list[CollectedFile] = []
    result_bytes: bytes | None = None
    for entry in walked.files:
        collected.append(CollectedFile(
            relative_path="/".join(entry.relative_path),
            size=entry.size,
            sha256=hashlib.sha256(entry.data).hexdigest()))
        # Root level and exact name. A nested `result.json` is an ordinary
        # file that happens to share a name, and stays one.
        if entry.relative_path == (RESULT_NAME,):
            result_bytes = entry.data

    manifest = OutputManifest(
        files=tuple(collected),
        file_count=len(collected),
        total_bytes=walked.total_bytes,
        entry_count=walked.entry_count,
        result_present=result_bytes is not None)
    return OutputTree(manifest=manifest, result_bytes=result_bytes)


def _require_permitted(terminal: Any) -> None:
    """Refuse unless the terminal state permits a trusted result.

    Every §11 condition is checked rather than the single gate flag. The flag
    is derived from the disposition and would normally agree with it, but this
    is the boundary where a result becomes believable, and a classification
    that disagreed with itself must not be the thing that decides.
    """
    if not isinstance(terminal, TerminalClassification):
        raise OutputRefused(
            None, "a terminal classification is required to permit a result")
    permitted = (terminal.may_collect_result
                 and terminal.disposition is TerminalDisposition.COMPLETED_ZERO
                 and terminal.started_proven
                 and terminal.exit_code_considered
                 and terminal.exit_code == 0
                 and terminal.classification is None)
    if not permitted:
        raise OutputRefused(
            None,
            "the terminal classification does not permit a trusted result "
            f"({terminal.outcome_class})")


def read_result(tree: Any, terminal: Any) -> TrustedResult:
    """The trusted result of one invocation, or refuse.

    Order matters. The terminal state is consulted first, so that bytes from a
    failed execution are never even parsed as a candidate result: a valid
    document can never overturn a failed lifecycle, and the way to guarantee
    that is not to let it into the decision.
    """
    if not isinstance(tree, OutputTree):
        raise OutputRefused(None, "a collected output tree is required")
    _require_permitted(terminal)

    if tree.result_bytes is None:
        raise OutputRefused(
            Classification.RESULT_MISSING,
            f"the output tree carries no root-level {RESULT_NAME}")

    try:
        document = canonical_json.parse(tree.result_bytes,
                                        maximum_bytes=RESULT_MAXIMUM_BYTES)
    except CanonicalJSONError as error:
        # Nothing is repaired and nothing is normalised. A document that does
        # not satisfy the grammar is refused as it stands.
        raise OutputRefused(
            Classification.RESULT_INVALID,
            f"{RESULT_NAME} is not a valid canonical result: {error}") from None

    return TrustedResult(container_id=terminal.container_id,
                         document=MappingProxyType(document),
                         manifest=tree.manifest)
