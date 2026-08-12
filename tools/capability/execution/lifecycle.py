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
from typing import Any, Sequence

from .profile import ObservedProfile
from .protocol import MessageKind, ProtocolViolation, Session
from .types import Mount

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
        image_digest=data.get("ImageDigest"),
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
