"""Per-invocation cleanup and admin-mediated recovery for ENG-0005.

**Deletion is the whole of this module's authority, and it is narrow.** The one
thing it can remove is the per-`CINV` subtree beneath a verified handoff root,
derived internally from an identity it validated. No caller supplies a path, no
recursive fallback is rooted anywhere else, and nothing here can create, write,
rename, chmod, or chown. A module that could both delete and create could
rebuild what it destroyed, and then "what happened" would have two answers.

**Only directories are ever opened.** Everything else — regular file, symlink,
FIFO, socket, device, or something nobody anticipated — is unlinked by name
relative to its parent's descriptor. ``unlink`` removes the link and never what
it points at, so a symlink planted in the output is removed rather than
followed, and rather than stopping cleanup: refusing on one would let the most
ordinary hostile artefact there is permanently consume one of two slots.

**Post-order, streaming, and bounded.** Children go before parents, or the
parent's removal fails and the tree half-survives for no reason. Depth 32 and
8,192 entries bound the deletion *work* — deliberately larger than the §11 and
§15 acceptance limits, because those govern output that might be trusted while
this governs residue that has already broken them. Nothing paginates and
nothing resumes from a cursor.

**Ambiguity fails closed, always toward preserving.** A missing root, a
substituted object, a type that changed under the walk, a bound exceeded: each
raises ``execution_cleanup_incomplete``, the lifecycle stays where it was, the
slot stays held, and whatever remains is left exactly as it is. Absence is
never read as success — cleanup that cannot prove it finished did not finish,
and `retain-residue` exists for the case where it never will.

**Recovery decides nothing and does nothing.** It reports what durable state
says and what §18 makes of a *fresh* observation the caller supplies. It
performs no retry, contacts no runtime, and stores no observation, because a
cached observation is a claim about a moment that has passed.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§18 and §19.
"""

from __future__ import annotations

import dataclasses
import os
import stat
from typing import Any

from . import state as state_module
from .backing_store import RootDescriptor
from .types import Classification, LifecycleState

# §19, ruled 2026-08-12. Deletion-work bounds, not acceptance bounds.
CLEANUP_MAX_DEPTH = 32
CLEANUP_MAX_ENTRIES = 8192

# Cleanup is the step between evidence being durable and the slot being freed.
# Reaching `collected` is what makes the evidence durable; releasing the slot
# is T7's, and doing it here would let one failure both lose the evidence and
# hand the slot to the next execution.
CLEANUP_FROM = LifecycleState.COLLECTED
CLEANUP_TO = LifecycleState.CLEANED

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY


class CleanupError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class CleanupRefused(CleanupError):
    """The request itself is not one cleanup may act on.

    Carries no classification. A caller asking to clean an invocation whose
    evidence is not yet durable has made a sequencing mistake, and reporting it
    as `execution_cleanup_incomplete` would describe the invocation as having a
    problem it does not have.
    """


class CleanupIncomplete(CleanupError):
    """Cleanup began and could not prove it finished."""

    classification = Classification.EXECUTION_CLEANUP_INCOMPLETE


@dataclasses.dataclass(frozen=True)
class Observation:
    """What the administrative helper saw, at the moment it was asked.

    Supplied per call and never stored. Defaults describe the least-informed
    view — nothing seen, nothing matched — so an observation that omits a field
    cannot accidentally assert something favourable about it.
    """

    container_present: bool = False
    candidate_matches: bool | None = None
    ambiguous: bool = False
    runtime_state: str | None = None
    started_proven: bool = False
    contradictory: bool = False
    mutation_freeze: bool = False


@dataclasses.dataclass(frozen=True)
class Finding:
    """One invocation's recovery position. A report, never an instruction."""

    cinv: str
    state: LifecycleState
    classification: Classification | None
    disposition: str | None
    requires_observation: bool


class _Budget:
    """The deletion work this run is allowed to do, spent once per entry."""

    def __init__(self) -> None:
        self.entries = 0

    def spend(self) -> None:
        self.entries += 1
        if self.entries > CLEANUP_MAX_ENTRIES:
            raise CleanupIncomplete(
                f"more than {CLEANUP_MAX_ENTRIES} entries beneath the subtree")

    @property
    def remaining(self) -> int:
        return CLEANUP_MAX_ENTRIES - self.entries


def _require_root(root: Any, what: str) -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise CleanupRefused(f"{what} must be a verified RootDescriptor")
    return root


def _names(descriptor: int, budget: _Budget) -> list[str]:
    """One directory's children, bounded and deterministically ordered.

    Enumeration stops one past the remaining budget rather than reading a
    directory out and counting afterwards, so a directory with millions of
    children costs the budget rather than the memory.
    """
    allowance = budget.remaining + 1
    collected: list[str] = []
    with os.scandir(descriptor) as entries:
        for entry in entries:
            name = entry.name
            if not name or name in (".", "..") or "/" in name or "\0" in name:
                raise CleanupIncomplete(f"unusable directory entry name: {name!r}")
            collected.append(name)
            if len(collected) >= allowance:
                raise CleanupIncomplete(
                    f"more than {CLEANUP_MAX_ENTRIES} entries beneath the subtree")
    return sorted(collected, key=lambda value: value.encode("utf-8", "surrogateescape"))


def _remove_children(descriptor: int, depth: int, device: int,
                     budget: _Budget) -> None:
    """Empty one directory, depth-first and child-before-parent."""
    for name in _names(descriptor, budget):
        budget.spend()

        try:
            described = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        except OSError as error:
            raise CleanupIncomplete(
                f"entry '{name}' could not be described: {error}") from None
        if described.st_dev != device:
            raise CleanupIncomplete(
                f"entry '{name}' lies on a different filesystem")

        if not stat.S_ISDIR(described.st_mode):
            # Everything that is not a directory is removed by name. The link
            # goes; whatever it may have pointed at is not this module's to
            # touch and is never opened.
            try:
                os.unlink(name, dir_fd=descriptor)
            except OSError as error:
                raise CleanupIncomplete(
                    f"entry '{name}' could not be removed: {error}") from None
            continue

        if depth + 1 > CLEANUP_MAX_DEPTH:
            raise CleanupIncomplete(
                f"an entry lies deeper than {CLEANUP_MAX_DEPTH}")

        try:
            child = os.open(name, _DIR_FLAGS, dir_fd=descriptor)
        except OSError as error:
            raise CleanupIncomplete(
                f"directory '{name}' could not be opened as described: {error}"
            ) from None
        try:
            opened = os.fstat(child)
            if not stat.S_ISDIR(opened.st_mode):
                raise CleanupIncomplete(f"'{name}' stopped being a directory")
            if (opened.st_ino != described.st_ino
                    or opened.st_dev != described.st_dev):
                raise CleanupIncomplete(
                    f"'{name}' is not the directory that was described")
            _remove_children(child, depth + 1, device, budget)
        finally:
            os.close(child)

        try:
            os.rmdir(name, dir_fd=descriptor)
        except OSError as error:
            raise CleanupIncomplete(
                f"directory '{name}' could not be removed: {error}") from None


def cleanup(root: Any, handoff: Any, cinv: Any) -> None:
    """Remove the per-`CINV` handoff subtree and record `cleaned`, or refuse.

    The subtree is derived here from a validated identity beneath a verified
    root; no pathname crosses the boundary in either direction. The lifecycle
    record is committed only after the whole tree is gone, so a cleanup that
    could not finish leaves an invocation that still says it needs cleaning.
    """
    _require_root(root, "root")
    handoff_root = _require_root(handoff, "handoff")
    identity = state_module.validate_cinv(cinv)

    current = state_module.current_state(root, identity)
    if current is not CLEANUP_FROM:
        raise CleanupRefused(
            f"{identity} is {None if current is None else current.value}, and "
            f"cleanup runs only from {CLEANUP_FROM.value}")

    try:
        subtree = os.open(identity, _DIR_FLAGS, dir_fd=handoff_root.fd)
    except OSError as error:
        # Absence included, and deliberately. Cleanup that cannot see what it
        # was asked to remove cannot prove it removed it, and the `cleaned`
        # record is a claim that it did.
        raise CleanupIncomplete(
            f"the {identity} handoff subtree could not be opened: {error}") from None

    budget = _Budget()
    try:
        opened = os.fstat(subtree)
        if not stat.S_ISDIR(opened.st_mode):
            raise CleanupIncomplete(f"the {identity} handoff root is not a directory")
        _remove_children(subtree, 0, opened.st_dev, budget)
    finally:
        os.close(subtree)

    try:
        os.rmdir(identity, dir_fd=handoff_root.fd)
    except OSError as error:
        raise CleanupIncomplete(
            f"the {identity} handoff root could not be removed: {error}") from None

    handoff_root.reverify()
    state_module.transition(root, identity, CLEANUP_FROM, CLEANUP_TO)


# --- recovery (§18) ---------------------------------------------------------

_STATE_LOST = (Classification.EXECUTION_STATE_LOST, "acknowledge-state-lost")
_FROZEN_LOST = (Classification.EXECUTION_STATE_LOST_DURING_MUTATION_FREEZE,
                "acknowledge-state-lost")


def classify_recovery(cinv: Any, current: Any,
                      observation: Any) -> Finding:
    """The §18 row for one invocation, given a fresh observation.

    ``None`` for the observation is not "assume the best": it produces a
    finding that says an observation is required, because every row below turns
    on something only the administrative helper can see.
    """
    identity = state_module.validate_cinv(cinv)
    if not isinstance(current, LifecycleState):
        raise CleanupRefused("a LifecycleState is required")

    if observation is None:
        return Finding(cinv=identity, state=current, classification=None,
                       disposition=None, requires_observation=True)
    if not isinstance(observation, Observation):
        raise CleanupRefused("an Observation is required")

    classification: Classification | None = None
    disposition: str | None = None

    if observation.contradictory:
        classification = Classification.EXECUTION_LIFECYCLE_INTEGRITY_FAILURE
        disposition = "retain-lifecycle-failure"
    elif not observation.container_present:
        # Absence after the runtime authoritatively had one is state lost, and
        # absence during a mutation freeze is its own row because the freeze
        # changes what a later reconciliation may conclude.
        classification, disposition = (_FROZEN_LOST if observation.mutation_freeze
                                       else _STATE_LOST)
    elif current is LifecycleState.LAUNCH_AUTHORIZED:
        if observation.ambiguous or observation.candidate_matches is False:
            classification = Classification.EXECUTION_IDENTITY_MISMATCH
            disposition = "retain"
        elif observation.candidate_matches is None:
            classification, disposition = _STATE_LOST
        # A candidate matching the complete fingerprint is adopted and the
        # invocation continues, which §18 spells with no classification at all.
    elif current is LifecycleState.START_AUTHORIZED:
        if observation.runtime_state == "created":
            classification = Classification.EXECUTION_START_OUTCOME_UNKNOWN
            disposition = "retain-start-unknown"
        elif observation.runtime_state == "running":
            classification = Classification.START_RECONCILED_RUNNING
        elif observation.started_proven:
            classification = Classification.START_RECONCILED_TERMINAL

    return Finding(cinv=identity, state=current, classification=classification,
                   disposition=disposition, requires_observation=False)


def recover(root: Any, observations: Any = None) -> tuple[Finding, ...]:
    """Report the recovery position of every known invocation.

    Reads durable state, reports, and stops. It advances no lifecycle, removes
    nothing, retries nothing, and reaches no runtime: every observation it uses
    was handed to it by the caller that just took it.
    """
    _require_root(root, "root")
    supplied = {} if observations is None else dict(observations)
    return tuple(
        classify_recovery(cinv, current, supplied.get(cinv))
        for cinv, current in sorted(state_module.all_states(root).items()))
