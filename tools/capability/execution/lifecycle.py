"""Container create, observe, start, and lifecycle reading for ENG-0005.

**Nothing here decides anything.** It creates through an injected backend,
reports the immutable identity, translates what Podman said into the accepted
observation shape, and starts only when the coordinator has said so. Whether
the observation is acceptable is the coordinator's judgement, made against the
T8 profile — this module never repairs, never adjusts, and never concludes a
difference is fine.

**Missing observations stay missing.** A field Podman did not report arrives as
``None`` and travels as ``None``. Filling it from the expected profile would
answer "did the runtime enforce this?" with "we asked it to", which is the one
answer that cannot be evidence.

**Exit code is not read before start is proven.** A container that never ran
reports exit 0, which is indistinguishable from success by exit code alone —
Track B observed exactly that. So the observation carries whether a start was
proven, and whether the exit code may be trusted at all.

**One create, one start, no retry.** A failure is reported and stops there.
Recreating would produce a second container for one identity, and re-starting
would be a second execution wearing the first one's authority.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §17.
"""

from __future__ import annotations

import dataclasses
import enum
from typing import Any, Sequence

from .profile import ObservedProfile
from .protocol import MessageKind, ProtocolViolation, Session
from .types import Classification, Mount

_HEX = frozenset("0123456789abcdef")


class LifecycleRefused(ValueError):
    """The container lifecycle will not proceed."""


@dataclasses.dataclass(frozen=True)
class LifecycleObservation:
    """What Podman reported about one container, with trust made explicit."""

    container_id: str
    state: str
    started_at: Any
    finished_at: Any
    exit_code: Any
    started_proven: bool
    exit_code_trustworthy: bool


def _require_container_id(value: Any) -> str:
    """The full 64-character identity, or refuse.

    A short display form is a convenience for humans, never authority: two
    containers can share a prefix, and the whole verification chain is anchored
    on this being unambiguous.
    """
    if not isinstance(value, str) or len(value) != 64 or set(value) - _HEX:
        raise LifecycleRefused("not a full 64-character container identity")
    return value


def create(backend: Any, argv: Sequence[str],
           environment: Sequence[tuple[str, str]]) -> str:
    """Create the container once and return its immutable identity."""
    try:
        container_id = backend.create(argv, environment)
    except OSError as error:
        raise LifecycleRefused(f"container creation failed: {error}") from None
    return _require_container_id(container_id)


def _mounts(reported: Any) -> Any:
    if reported is None:
        return None
    mounts = []
    for entry in reported:
        destination = entry.get("Destination")
        rw = entry.get("RW")
        if destination is None or rw is None:
            return None
        mounts.append(Mount(destination=destination, read_only=not rw,
                            source_kind=entry.get("Type", "bind")))
    return tuple(mounts)


def _user(reported: Any) -> tuple[Any, Any]:
    if not isinstance(reported, str) or ":" not in reported:
        return None, None
    uid, _, gid = reported.partition(":")
    try:
        return int(uid), int(gid)
    except ValueError:
        return None, None


def observe(backend: Any, container_id: str) -> ObservedProfile:
    """Translate Podman's report into the accepted observation shape.

    ``.get`` is used throughout on purpose: an absent key becomes ``None`` and
    fails verification, which is the behaviour required. Nothing is defaulted.
    """
    data = backend.inspect(_require_container_id(container_id))
    if not isinstance(data, dict):
        raise LifecycleRefused("the container inspection is not an object")

    execution_uid, execution_gid = _user(data.get("User"))
    capabilities = data.get("CapDrop")
    effective = data.get("EffectiveCaps")

    return ObservedProfile(
        # Podman container inspect reports `Image` as the immutable local
        # image ID the container was actually instantiated from. `ImageDigest`
        # is a registry manifest digest and `ImageName` is whatever mutable
        # reference was used at create, so neither is read: a retag or a
        # re-push must not be able to move the identity a container is
        # verified against. An absent `Image` stays absent and fails.
        oci_image_id=data.get("Image"),
        network=data.get("NetworkMode"),
        read_only_rootfs=data.get("ReadOnlyRootfs"),
        no_new_privileges=data.get("NoNewPrivileges"),
        dropped_capabilities=tuple(capabilities) if capabilities is not None else None,
        effective_capabilities=tuple(effective) if effective is not None else None,
        memory_bytes=data.get("Memory"),
        memory_swap_bytes=data.get("MemorySwap"),
        cpu_quota_us=data.get("CpuQuota"),
        cpu_period_us=data.get("CpuPeriod"),
        pids_limit=data.get("PidsLimit"),
        execution_uid=execution_uid,
        execution_gid=execution_gid,
        hostname=data.get("Hostname"),
        mounts=_mounts(data.get("Mounts")),
        devices=tuple(data["Devices"]) if data.get("Devices") is not None else None,
        sockets=tuple(data["Sockets"]) if data.get("Sockets") is not None else None,
        tmpfs_bytes=data.get("TmpfsSize"),
        tmpfs_mode=data.get("TmpfsMode"),
        tmpfs_options=tuple(data["TmpfsOptions"]) if data.get("TmpfsOptions") is not None else None,
        profile_schema_version=data.get("ProfileSchemaVersion"),
    )


def start_when_authorised(backend: Any, container_id: str, *,
                          session: Session) -> None:
    """Start the recorded container, and only on explicit authorisation.

    The session is the gate. A created container, a plausible-looking profile,
    or elapsed time authorise nothing, and the session itself refuses a second
    ``start_now``, so there is no second start to refuse here.
    """
    recorded = _require_container_id(container_id)
    message = session.expect(MessageKind.START_NOW)
    named = message.field_map().get("container_id")
    if named != recorded:
        raise LifecycleRefused(
            "the start authorisation names a different container")
    try:
        backend.start(recorded)
    except OSError as error:
        raise LifecycleRefused(f"container start failed: {error}") from None


def observe_lifecycle(backend: Any, container_id: str) -> LifecycleObservation:
    """Read lifecycle facts for exactly this container.

    Bound to the recorded identity in both directions: the query names it, and
    the reply must agree. A report about anything else is refused rather than
    reconciled.
    """
    recorded = _require_container_id(container_id)
    data = backend.lifecycle(recorded)
    if not isinstance(data, dict):
        raise LifecycleRefused("the lifecycle report is not an object")
    reported = data.get("container_id")
    if reported != recorded:
        raise LifecycleRefused("the lifecycle report names a different container")

    state = data.get("state")
    started_at = data.get("started_at")
    # A start is proven by the runtime saying so, never by an exit code being
    # present: `Created` with exit 0 is a container that never ran.
    started_proven = bool(started_at) and state not in (None, "created")
    return LifecycleObservation(
        container_id=recorded,
        state=state,
        started_at=started_at,
        finished_at=data.get("finished_at"),
        exit_code=data.get("exit_code"),
        started_proven=started_proven,
        exit_code_trustworthy=started_proven,
    )


# --- terminal classification (T13) ------------------------------------------

TIMEOUT_SECONDS = 30
GRACE_SECONDS = 2

# Bounded polling during the grace. A fixed number of attempts rather than an
# open loop: the grace is two seconds whatever the runtime does, and a loop
# that could outlast it would be a way to extend a timeout.
_GRACE_POLLS = 8

# The runtime words a lifecycle report may use. Anything else is not a state
# this adapter can reason about, and guessing would be worse than refusing.
_VALID_STATES = ("created", "running", "exited", "stopped", "paused", "unknown")
_TERMINAL_STATES = ("exited", "stopped")


class TerminalDisposition(enum.Enum):
    """What the lifecycle says happened, before any exit code is read."""

    NEVER_STARTED = "never_started"
    RUNNING = "running"
    COMPLETED_ZERO = "completed_zero"
    COMPLETED_NONZERO = "completed_nonzero"
    UNTRUSTWORTHY_EXIT = "untrustworthy_exit"
    TIMED_OUT = "timed_out"
    INTEGRITY_FAILURE = "integrity_failure"


# Each disposition maps to one released outcome class. Nothing new is invented:
# a launch that never ran is the adapter's failure, a capability that ran and
# exited nonzero is the provider's, and a container still running when asked
# has produced no terminal result at all.
_OUTCOME = {
    TerminalDisposition.NEVER_STARTED: "adapter-error",
    TerminalDisposition.RUNNING: "interrupted",
    TerminalDisposition.COMPLETED_ZERO: "completed",
    TerminalDisposition.COMPLETED_NONZERO: "provider-error",
    TerminalDisposition.UNTRUSTWORTHY_EXIT: "adapter-error",
    TerminalDisposition.TIMED_OUT: "timeout",
    TerminalDisposition.INTEGRITY_FAILURE: "adapter-error",
}


@dataclasses.dataclass(frozen=True)
class TerminalClassification:
    """What the lifecycle establishes, and what it permits next.

    ``succeeded`` is always ``False`` here, and deliberately so: T13 knows the
    workload exited cleanly, not that the invocation succeeded. That needs a
    valid result and a valid output tree, which the collector owns. Reporting
    success at this point would be reporting it one verification too early.
    """

    container_id: str
    disposition: TerminalDisposition
    outcome_class: str
    classification: Classification | None
    started_proven: bool
    exit_code_considered: bool
    exit_code: Any
    started_at: Any
    finished_at: Any
    may_collect_result: bool
    succeeded: bool


@dataclasses.dataclass(frozen=True)
class TerminationOutcome:
    """Whether the grace expired and a force kill was needed."""

    killed: bool


def _contradicted(observed: LifecycleObservation) -> bool:
    """Whether the report disagrees with itself.

    Only internal consistency is examined. Timestamps are compared as the
    equal-format strings the runtime reported, never parsed against a wall
    clock: whether the host's clock is correct is not a security question, and
    making it one would fail invocations for the wrong reason.
    """
    state = observed.state
    if state not in _VALID_STATES or state == "unknown":
        return True
    if observed.started_proven and observed.started_at is None:
        return True
    if state in _TERMINAL_STATES and (observed.finished_at is None
                                      or observed.exit_code is None):
        return True
    started, finished = observed.started_at, observed.finished_at
    if isinstance(started, str) and isinstance(finished, str) and finished < started:
        return True
    return False


def _disposition(observed: LifecycleObservation,
                 timed_out: bool) -> TerminalDisposition:
    # Timeout outranks everything. Once the threshold has fired the invocation
    # is a timeout, and a workload that exits during the grace has changed its
    # manners rather than its outcome.
    if timed_out:
        return TerminalDisposition.TIMED_OUT
    if _contradicted(observed):
        return TerminalDisposition.INTEGRITY_FAILURE
    if not observed.started_proven:
        return TerminalDisposition.NEVER_STARTED
    if not observed.exit_code_trustworthy:
        return TerminalDisposition.UNTRUSTWORTHY_EXIT
    if observed.state not in _TERMINAL_STATES:
        return TerminalDisposition.RUNNING
    if observed.exit_code == 0:
        return TerminalDisposition.COMPLETED_ZERO
    return TerminalDisposition.COMPLETED_NONZERO


def classify(observed: LifecycleObservation, *,
             timed_out: bool = False) -> TerminalClassification:
    """Interpret one lifecycle observation.

    The order is the point: whether the workload started is settled first, and
    only a proven start with trustworthy evidence allows the exit code to be
    read at all. `Created` with exit 0 is the case this exists for -- a
    container that never ran reports success by exit code alone.
    """
    if not isinstance(observed, LifecycleObservation):
        raise LifecycleRefused("a LifecycleObservation is required")

    disposition = _disposition(observed, timed_out)
    considered = disposition in (TerminalDisposition.COMPLETED_ZERO,
                                 TerminalDisposition.COMPLETED_NONZERO)
    classification = (Classification.EXECUTION_LIFECYCLE_INTEGRITY_FAILURE
                      if disposition is TerminalDisposition.INTEGRITY_FAILURE
                      else None)
    return TerminalClassification(
        container_id=observed.container_id,
        disposition=disposition,
        outcome_class=_OUTCOME[disposition],
        classification=classification,
        started_proven=bool(observed.started_proven) and not timed_out,
        exit_code_considered=considered,
        exit_code=observed.exit_code,
        started_at=observed.started_at,
        finished_at=observed.finished_at,
        may_collect_result=disposition is TerminalDisposition.COMPLETED_ZERO,
        succeeded=False,
    )


def timed_out(*, elapsed: float) -> bool:
    """Whether the accepted wall timeout has been reached."""
    return elapsed >= TIMEOUT_SECONDS


def terminate_after_timeout(backend: Any, container_id: str, *,
                            clock: Any) -> TerminationOutcome:
    """Ask the container to stop, then force it if the grace expires.

    Both actions name the recorded immutable identity and nothing else: not the
    deterministic name, not a label, not a process group. The grace is bounded
    by a fixed number of polls as well as by elapsed time, so nothing here can
    wait longer than the accepted two seconds.
    """
    recorded = _require_container_id(container_id)
    start = clock()
    backend.terminate(recorded)

    for _ in range(_GRACE_POLLS):
        if not backend.still_active(recorded):
            return TerminationOutcome(killed=False)
        if clock() - start >= GRACE_SECONDS:
            break

    if backend.still_active(recorded):
        backend.kill(recorded)
        return TerminationOutcome(killed=True)
    return TerminationOutcome(killed=False)
