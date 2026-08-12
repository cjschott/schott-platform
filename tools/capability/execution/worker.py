"""The permanently unprivileged worker for the ENG-0005 first adapter.

**This module names Podman and invokes nothing.** It builds argv and verifies
the handoff; a backend does the talking, and no subprocess exists here at all.
Binding a real process to `/usr/bin/podman` is a later increment behind gate
G6, so the absence of `subprocess` is a property of this file rather than a
gap in it.

**Everything crossing into this worker is already narrow.** After the privilege
transition it receives one `CINV`, two environment variables, and descriptors
0, 1 and 2. Nothing else arrives, so nothing else can be trusted or misused —
the bind sources below are rebuilt from a compiled-in root and the validated
identity, not read from anything that travelled.

**Trust is re-established, not inherited.** The worker is a different process
from the one that published the handoff, and descriptor continuity cannot cross
`execve`. So it reopens the handoff no-follow, checks type and mode on every
component, and only then derives the pathname Podman needs. That pathname is an
argument derived from verified authority — it is not authority itself.

**`/proc/self/fd/N` is deliberately not used.** Podman resolves bind sources
through helper and runtime processes where `/proc/self` means something else,
and that behaviour is unvalidated here. A compiled-in path plus a fixed-grammar
identity is boring and checkable, which is the point.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §7, §12.
"""

from __future__ import annotations

import dataclasses
import os
import stat as stat_module
from typing import Any, Protocol, Sequence

from .package_contract import PackageBinding
from .types import ExecutionProfile

PODMAN = "/usr/bin/podman"
HANDOFF_ROOT = "/data/kyri/capability-handoff"

WORKER_UID = 999
WORKER_GID = 987

CONTAINER_UID = 1000
CONTAINER_GID = 1000

# Adapter-owned and complete. Rootless Podman resolves storage from
# $HOME/.local/share/containers/storage when XDG_DATA_HOME is unset -- the
# graphroot Track B provisioned -- and keeps runtime state in XDG_RUNTIME_DIR.
ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("HOME", "/data/kyri/capability"),
    ("XDG_RUNTIME_DIR", "/run/user/999"),
)

PACKAGE_DESTINATION = "/kyri/package"
PAYLOAD_DESTINATION = "/run/kyri/input/payload"
OUTPUT_DESTINATION = "/kyri/output"

PACKAGE_NAME = "package"
PAYLOAD_NAME = "payload"
OUTPUT_NAME = "out"

# The interpreter is adapter-owned; the script is the governed package's
# entrypoint, already validated and bound by the package contract.
CONTAINER_INTERPRETER = "/usr/bin/python3"

EXPECTED_MODES = {
    "invocation": 0o555,
    PACKAGE_NAME: 0o555,
    PAYLOAD_NAME: 0o444,
    OUTPUT_NAME: 0o700,
}

_DIGITS = frozenset("0123456789")
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY


class WorkerRefused(ValueError):
    """The worker will not proceed."""


class PodmanBackend(Protocol):
    """The only operations the worker may ask for.

    Deliberately not a generic runner: an ``invoke(command)`` seam would make
    every Podman subcommand reachable from worker logic, and the closed argv
    construction below would then guarantee nothing.
    """

    def create(self, argv: Sequence[str],
               environment: Sequence[tuple[str, str]]) -> str: ...

    def inspect(self, container_id: str) -> dict[str, Any]: ...

    def start(self, container_id: str) -> None: ...

    def lifecycle(self, container_id: str) -> dict[str, Any]: ...


@dataclasses.dataclass(frozen=True)
class HandoffSources:
    """The three verified bind sources, as Podman argument strings."""

    cinv: str
    package: str
    payload: str
    output: str


def require_worker_identity(*, uid: int, gid: int) -> None:
    """Confirm this is the execution identity, or refuse.

    Root is refused explicitly rather than incidentally: a worker running as
    root would drive rootless Podman into an entirely different storage tree
    and every later verification would be about the wrong container.
    """
    if uid == 0 or gid == 0:
        raise WorkerRefused("the worker must never run as root")
    if uid != WORKER_UID or gid != WORKER_GID:
        raise WorkerRefused(
            f"the worker must run as {WORKER_UID}:{WORKER_GID}, not {uid}:{gid}")


def _validate_cinv(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 11 \
            or not value.startswith("CINV-") or set(value[5:]) - _DIGITS:
        raise WorkerRefused(f"{value!r} is not a CINV identity")
    return value


def container_name(cinv: str) -> str:
    """The deterministic name, derived from the `CINV` and nothing else.

    No attempt suffix and no counter: the name is burned with the `CINV`, so a
    second attempt would need a second identity rather than a decorated name.
    """
    return f"kyri-{_validate_cinv(cinv)}"


def _check(name: str, dir_fd: int, *, directory: bool, mode: int) -> None:
    try:
        handle = os.open(name, _DIR_FLAGS if directory else _READ_FLAGS,
                         dir_fd=dir_fd)
    except FileNotFoundError:
        raise WorkerRefused(f"the handoff is missing {name!r}") from None
    except OSError as error:
        raise WorkerRefused(f"the handoff {name!r} is unusable: {error}") from None
    try:
        info = os.fstat(handle)
    finally:
        os.close(handle)
    expected = stat_module.S_ISDIR if directory else stat_module.S_ISREG
    if not expected(info.st_mode):
        raise WorkerRefused(f"the handoff {name!r} is the wrong object type")
    if stat_module.S_IMODE(info.st_mode) != mode:
        raise WorkerRefused(
            f"the handoff {name!r} has mode {oct(stat_module.S_IMODE(info.st_mode))}, "
            f"expected {oct(mode)}")


def verify_handoff(cinv: str, *, root_fd: int) -> HandoffSources:
    """Re-establish the handoff boundary and derive its bind sources.

    ``root_fd`` is an already-open descriptor for the handoff root. Everything
    below it is opened descriptor-relatively with ``O_NOFOLLOW``, so a replaced
    component is refused rather than followed.
    """
    validated = _validate_cinv(cinv)

    try:
        invocation = os.open(validated, _DIR_FLAGS, dir_fd=root_fd)
    except FileNotFoundError:
        raise WorkerRefused(f"no handoff published for {validated}") from None
    except OSError as error:
        raise WorkerRefused(f"the handoff for {validated} is unusable: {error}") from None
    try:
        info = os.fstat(invocation)
        if not stat_module.S_ISDIR(info.st_mode):
            raise WorkerRefused("the handoff invocation root is not a directory")
        if stat_module.S_IMODE(info.st_mode) != EXPECTED_MODES["invocation"]:
            raise WorkerRefused("the handoff invocation root has the wrong mode")
        _check(PACKAGE_NAME, invocation, directory=True,
               mode=EXPECTED_MODES[PACKAGE_NAME])
        _check(PAYLOAD_NAME, invocation, directory=False,
               mode=EXPECTED_MODES[PAYLOAD_NAME])
        _check(OUTPUT_NAME, invocation, directory=True,
               mode=EXPECTED_MODES[OUTPUT_NAME])
    finally:
        os.close(invocation)

    base = f"{HANDOFF_ROOT}/{validated}"
    return HandoffSources(
        cinv=validated,
        package=f"{base}/{PACKAGE_NAME}",
        payload=f"{base}/{PAYLOAD_NAME}",
        output=f"{base}/{OUTPUT_NAME}",
    )


def _container_script(package: PackageBinding) -> str:
    """The container-side path of the governed entrypoint.

    The package contract already proved the entrypoint is relative, `.py`,
    traversal-free, and present in the validated tree, so this does not
    re-validate it with a second, weaker scheme. The assertions below are
    defensive only: they restate the invariant at the boundary where a
    violation would become an argument, and would catch a `PackageBinding`
    that reached here without passing through that contract.
    """
    entrypoint = package.entrypoint
    if not isinstance(entrypoint, str) or not entrypoint:
        raise WorkerRefused("the package binding carries no entrypoint")
    if entrypoint.startswith("/") or not entrypoint.endswith(".py"):
        raise WorkerRefused("the bound entrypoint is not a relative .py path")
    if any(part in ("", ".", "..") for part in entrypoint.split("/")):
        raise WorkerRefused("the bound entrypoint is not traversal-free")
    return f"{PACKAGE_DESTINATION}/{entrypoint}"


def create_argv(profile: ExecutionProfile, sources: HandoffSources,
                package: PackageBinding) -> tuple[str, ...]:
    """The complete creation arguments, closed against everything else.

    Every security-critical control is stated explicitly even where Podman's
    default happens to match. A default is a decision somebody else can change;
    a flag is one this adapter owns.

    The three inputs stay separate because they are three different things:
    the profile is the sandbox, the sources are the verified bind mounts, and
    the package is the governed capability identity. Only the last carries an
    entrypoint, and it arrives already validated.
    """
    if not isinstance(profile, ExecutionProfile):
        raise WorkerRefused("a built ExecutionProfile is required")
    if not isinstance(sources, HandoffSources):
        raise WorkerRefused("verified HandoffSources are required")
    if not isinstance(package, PackageBinding):
        raise WorkerRefused("a validated PackageBinding is required")
    if profile.cinv != sources.cinv:
        raise WorkerRefused("the profile and handoff name different invocations")

    entrypoint = _container_script(package)
    return (
        PODMAN, "create",
        "--name", container_name(profile.cinv),
        "--network", profile.network,
        "--read-only",
        "--read-only-tmpfs=false",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--pids-limit", str(profile.pids_limit),
        "--memory", "256m",
        "--memory-swap", "256m",
        "--cpus", profile.cpus,
        "--hostname", profile.hostname,
        "--user", f"{CONTAINER_UID}:{CONTAINER_GID}",
        "--tmpfs", (f"/tmp:size=16m,mode=1777,"
                    + ",".join(profile.tmpfs_options)),
        "--mount", (f"type=bind,src={sources.package},"
                    f"dst={PACKAGE_DESTINATION},ro=true"),
        "--mount", (f"type=bind,src={sources.payload},"
                    f"dst={PAYLOAD_DESTINATION},ro=true"),
        "--mount", (f"type=bind,src={sources.output},"
                    f"dst={OUTPUT_DESTINATION},ro=false"),
        profile.image_digest,
        CONTAINER_INTERPRETER, entrypoint,
    )
