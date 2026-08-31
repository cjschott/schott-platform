"""The permanently unprivileged worker for the ENG-0005 first adapter.

**This module names Podman and invokes nothing.** It builds argv and verifies
the handoff; a backend does the talking, and no subprocess exists here at all.
Binding a real process to `/usr/bin/podman` is a later increment behind gate
G6, so the absence of `subprocess` is a property of this file rather than a
gap in it.

**Everything crossing into this worker is already narrow.** After the privilege
transition it receives one `CINV`, one `CIMP`, one profile digest, two
environment variables, and descriptors 0, 1, 2 and 3. Nothing else arrives, so
nothing else can be trusted or misused — the bind sources below are rebuilt
from a compiled-in root and the validated identity, not read from anything that
travelled.

**The profile arrives on a sealed descriptor and is verified, not trusted.**
It cannot be checked against itself: `profile.cimp` and the digest have to be
compared with values that did *not* come from the profile, which is why the
transition passes both in argv from a record it authenticated. The worker
cannot read that record — `…/execution/` is coordinator-owned — and must not
try. What it does instead is confirm the descriptor carries the mandatory
seals, read it once, require the bytes to be exactly canonical, recompute the
fingerprint, and require it to equal the digest it was told. The seals stop the
bytes changing; the digest is the actual authority.

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
import fcntl
import hashlib
import os
import stat as stat_module
from typing import Any, Protocol, Sequence

from .package_contract import PackageBinding, PackageError, validate_package
from .payload import PAYLOAD_MAXIMUM_BYTES, PAYLOAD_SCHEMA_VERSION
from .profile import (ADAPTER_IDENTITY, MAXIMUM_PROFILE_BYTES,
                      PROFILE_SCHEMA_VERSION, ProfileError, fingerprint,
                      parse_canonical_profile, verify_governed_policy)
from .types import ExecutionProfile

PODMAN = "/usr/bin/podman"
HANDOFF_ROOT = "/data/kyri/capability-handoff"

WORKER_UID = 999
WORKER_GID = 987

# The governed profile descriptor and the seals it must carry. Both are stated
# here rather than imported: the transition helper installs beneath a different
# root and this side of the boundary cannot import from it, so the constants
# are duplicated deliberately and the tests hold the two copies together.
PROFILE_FD = 3
F_SEAL_SEAL = 0x0001
F_SEAL_SHRINK = 0x0002
F_SEAL_GROW = 0x0004
F_SEAL_WRITE = 0x0008
REQUIRED_SEALS = F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE

CONTAINER_UID = 1000
CONTAINER_GID = 1000

# Adapter-owned and complete. Rootless Podman resolves storage from
# $HOME/.local/share/containers/storage when XDG_DATA_HOME is unset -- the
# graphroot Track B provisioned -- and keeps runtime state in XDG_RUNTIME_DIR.
ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("HOME", "/data/kyri/capability"),
    ("XDG_RUNTIME_DIR", "/run/user/999"),
)

# §9, added at the G4 review of 2026-08-12. The container's Python environment
# is adapter-owned and complete: inherited from nothing -- not the host process,
# not the payload, not the package, not the protocol -- and stated here as
# literals so there is no path by which any of them could contribute a value.
#
# `PYTHONDONTWRITEBYTECODE=1` is the load-bearing one. `/kyri/package` is
# mounted read-only, so an interpreter that tried to write `__pycache__` beside
# a module would fail on import of an ordinary capability rather than on
# anything hostile. The other three make execution reproducible: a fixed hash
# seed, UTF-8 regardless of the host's locale, and a locale that agrees with it.
#
# Sorted by key, because the argv this becomes is compared field by field
# against what Podman reports and a stable order is what makes that comparison
# a fact rather than a coincidence.
CONTAINER_ENVIRONMENT: tuple[tuple[str, str], ...] = (
    ("LC_ALL", "C.UTF-8"),
    ("PYTHONDONTWRITEBYTECODE", "1"),
    ("PYTHONHASHSEED", "0"),
    ("PYTHONUTF8", "1"),
)

PACKAGE_DESTINATION = "/kyri/package"
PAYLOAD_DESTINATION = "/run/kyri/input/payload"
OUTPUT_DESTINATION = "/kyri/output"

PACKAGE_NAME = "package"
PAYLOAD_NAME = "payload"
OUTPUT_NAME = "out"

# The interpreter is adapter-owned; the script is the governed package's
# entrypoint, already validated and bound by the package contract.
#
# `/usr/bin/python`, not `/usr/bin/python3`: corrected at the G4 image ruling of
# 2026-08-12. The minimal runtime base admitted for v1 has no shell and no
# package manager, and configures its interpreter at `/usr/bin/python`. Keeping
# the old name would have meant either carrying a package manager into the final
# image to create it or resolving it through a path the base does not define --
# deforming the sandbox to preserve a pathname. This is the container-side
# interpreter only; `WORKER_INTERPRETER` on the host is untouched.
CONTAINER_INTERPRETER = "/usr/bin/python"

EXPECTED_MODES = {
    "invocation": 0o555,
    PACKAGE_NAME: 0o555,
    PAYLOAD_NAME: 0o444,
    OUTPUT_NAME: 0o700,
}

_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")
UNALLOCATED_CIMP = "CIMP-000000"
# O_NONBLOCK is the generation-5 FIFO lesson applied on this side of the
# boundary. Opening a FIFO for reading blocks until a writer arrives, so a
# coordinator that replaced the payload with a named pipe would hang the worker
# before it reached the check that refuses it. Inert on the regular file this
# is supposed to be.
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
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


@dataclasses.dataclass(frozen=True)
class LaunchContext:
    """The governed identities the transition passed in argv.

    None of these came from the profile, and that is their entire purpose:
    checking a document against itself proves nothing, so the values it must
    agree with have to arrive from the record root authenticated.
    """

    cinv: str
    cimp: str
    profile_digest: str


def require_launch_context(*, cinv: Any, cimp: Any,
                           profile_digest: Any) -> LaunchContext:
    """The validated worker context, or refuse.

    Grammar only. Whether these identities are *authorised* was settled by the
    record root read; what is settled here is that they are well formed, so a
    malformed token never reaches a comparison, a path, or an argument.
    """
    validated = _validate_cinv(cinv)
    if not isinstance(cimp, str) or len(cimp) != 11 \
            or not cimp.startswith("CIMP-") or set(cimp[5:]) - _DIGITS:
        raise WorkerRefused(f"{cimp!r} is not a CIMP identity")
    if cimp == UNALLOCATED_CIMP:
        raise WorkerRefused("the unallocated CIMP names no implementation")
    if not isinstance(profile_digest, str) or len(profile_digest) != 64 \
            or set(profile_digest) - _HEX:
        raise WorkerRefused(
            f"{profile_digest!r} is not a 64-character lowercase hex digest")
    return LaunchContext(cinv=validated, cimp=cimp,
                         profile_digest=profile_digest)


def profile_from_descriptor(context: LaunchContext, *,
                            descriptor: int = PROFILE_FD) -> ExecutionProfile:
    """The governed profile from the sealed descriptor, or refuse.

    Read from the descriptor and nowhere else. There is no path here, no
    reopen, and no second source to prefer: the published file the transition
    authenticated stopped being authority the moment the sealed copy was
    verified, and consulting it again would reintroduce exactly the race the
    seal exists to close.

    ``pread`` rather than ``read`` so the result cannot depend on an inherited
    file offset — the offset is somebody else's state, and reading from it
    would make a correct object return the wrong bytes.
    """
    if not isinstance(context, LaunchContext):
        raise WorkerRefused("a validated LaunchContext is required")
    try:
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
    except OSError as error:
        raise WorkerRefused(
            f"the profile descriptor is not a sealed object: {error}") from None
    if seals & REQUIRED_SEALS != REQUIRED_SEALS:
        raise WorkerRefused(
            "the profile descriptor does not carry the mandatory seals")

    try:
        info = os.fstat(descriptor)
        body = os.pread(descriptor, MAXIMUM_PROFILE_BYTES + 1, 0)
    except OSError as error:
        raise WorkerRefused(
            f"the profile descriptor is unreadable: {error}") from None
    if not stat_module.S_ISREG(info.st_mode):
        raise WorkerRefused("the profile descriptor is not regular storage")
    if len(body) > MAXIMUM_PROFILE_BYTES or len(body) != info.st_size:
        raise WorkerRefused("the profile descriptor did not read back completely")

    try:
        profile = parse_canonical_profile(body)
    except ProfileError as error:
        raise WorkerRefused(f"the sealed profile is not governed: {error}") from None

    if fingerprint(profile).profile_digest != context.profile_digest:
        raise WorkerRefused(
            "the sealed profile does not match the authorised digest")
    if profile.cinv != context.cinv:
        raise WorkerRefused("the sealed profile names a different invocation")
    if profile.cimp != context.cimp:
        raise WorkerRefused("the sealed profile names a different implementation")
    if len(profile.oci_image_id) != 64 or set(profile.oci_image_id) - _HEX:
        raise WorkerRefused("the sealed profile carries a malformed image ID")
    return profile


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


class ImageStore(Protocol):
    """The one question the worker may ask about images.

    Deliberately not a listing, a resolver, or a client. Presence is not
    authority: the image identity was already decided by `CIMP` resolution
    against a namespace the coordinator cannot write, and this seam only
    reports whether that exact already-authorised identity exists locally.
    Anything wider -- a tag lookup, "latest", a repository name, a pull --
    would let the store choose what runs.
    """

    def present(self, oci_image_id: str) -> bool: ...


_VERIFIED = object()


class VerifiedExecution:
    """Proof that every gate condition held, and the only input create_argv takes.

    Not a plain dataclass, for the same reason `AuthenticatedLaunch` is not: a
    value that means "all seven conditions passed" must not be constructible by
    anything that did not run them.
    """

    __slots__ = ("profile", "sources", "entrypoint", "payload_bytes")

    def __init__(self, token: Any, *, profile: ExecutionProfile,
                 sources: "HandoffSources", entrypoint: str,
                 payload_bytes: bytes) -> None:
        if token is not _VERIFIED:
            raise WorkerRefused(
                "a verified execution is produced by verify_execution and "
                "cannot be constructed")
        object.__setattr__(self, "profile", profile)
        object.__setattr__(self, "sources", sources)
        object.__setattr__(self, "entrypoint", entrypoint)
        # Carried so the snapshot is written from bytes already verified rather
        # than from a reopened source: the reopen is the window.
        object.__setattr__(self, "payload_bytes", payload_bytes)

    def __setattr__(self, name: str, value: Any) -> None:
        raise WorkerRefused("the verified execution is immutable")

    def __delattr__(self, name: str) -> None:
        raise WorkerRefused("the verified execution is immutable")


def require_runtime_contract(profile: ExecutionProfile) -> None:
    """Confirm the profile names contracts this build implements, or refuse.

    Record integrity and runtime compatibility are different questions. A
    historical admission may be perfectly readable and still name an adapter or
    a schema this build does not implement; that is a refusal to execute, not a
    claim the record is corrupt. Refusing here is what stops readable history
    becoming an execution bypass.
    """
    if profile.adapter_identity != ADAPTER_IDENTITY:
        raise WorkerRefused(
            f"the profile names adapter {profile.adapter_identity!r}, and this "
            f"build implements {ADAPTER_IDENTITY!r}")
    if profile.payload_schema_version != PAYLOAD_SCHEMA_VERSION:
        raise WorkerRefused(
            f"the profile names payload schema {profile.payload_schema_version}, "
            f"and this build implements {PAYLOAD_SCHEMA_VERSION}")
    if profile.profile_schema_version != PROFILE_SCHEMA_VERSION:
        raise WorkerRefused(
            f"the profile names schema {profile.profile_schema_version}, and "
            f"this build executes only schema {PROFILE_SCHEMA_VERSION}")


def require_image_present(profile: ExecutionProfile, images: Any) -> None:
    """Confirm the authorised image exists locally, or refuse.

    The identity is not chosen here and cannot be: it arrives already bound by
    `CIMP` resolution, is required to be a bare 64-character lowercase hex
    local image ID, and is passed to the store unchanged. A store that raises,
    or that answers with anything other than a boolean, is refused rather than
    interpreted -- an unreadable store is not a present image.
    """
    identity = profile.oci_image_id
    if not isinstance(identity, str) or len(identity) != 64 \
            or set(identity) - _HEX:
        raise WorkerRefused("the profile carries a malformed image ID")
    try:
        answer = images.present(identity)
    except Exception as error:  # noqa: BLE001 -- any failure is a refusal
        raise WorkerRefused(
            f"the image store could not be consulted: {error}") from None
    if answer is not True and answer is not False:
        raise WorkerRefused("the image store gave no usable answer")
    if not answer:
        raise WorkerRefused(
            "the authorised image is not present in the execution identity's store")


def _verify_payload(profile: ExecutionProfile, invocation_fd: int) -> bytes:
    """Confirm the published payload is the committed bytes, and return them.

    The bytes are returned rather than discarded because the snapshot is
    written from exactly these — reopening the source to copy it would put back
    the window this whole verification exists to remove.
    """
    try:
        handle = os.open(PAYLOAD_NAME, _READ_FLAGS, dir_fd=invocation_fd)
    except OSError as error:
        raise WorkerRefused(f"the payload is unusable: {error}") from None
    try:
        info = os.fstat(handle)
        if not stat_module.S_ISREG(info.st_mode):
            raise WorkerRefused("the payload is not a regular file")
        if info.st_size > PAYLOAD_MAXIMUM_BYTES:
            raise WorkerRefused("the payload exceeds the governed bound")
        body = os.read(handle, PAYLOAD_MAXIMUM_BYTES + 1)
    except OSError as error:
        raise WorkerRefused(f"the payload could not be read: {error}") from None
    finally:
        os.close(handle)
    if len(body) > PAYLOAD_MAXIMUM_BYTES:
        raise WorkerRefused("the payload exceeds the governed bound")
    if hashlib.sha256(body).hexdigest() != profile.payload_digest:
        raise WorkerRefused("the published payload is not the committed payload")
    return body


def _verify_package(profile: ExecutionProfile, invocation_fd: int) -> str:
    """Confirm the published package is the committed tree, or refuse.

    Re-validated with the same contract that produced the commitment, so the
    publisher and the verifier cannot disagree about what the digest covers.
    That walk is descriptor-relative and refuses symlinks, hard links, special
    files, executables, and anything over the governed bounds, so this check
    also re-establishes the tree's shape rather than trusting the earlier one.
    """
    try:
        handle = os.open(PACKAGE_NAME, _DIR_FLAGS, dir_fd=invocation_fd)
    except OSError as error:
        raise WorkerRefused(f"the package is unusable: {error}") from None
    try:
        binding = validate_package(handle,
                                   entrypoint=profile.package_entrypoint)
    except PackageError as error:
        raise WorkerRefused(f"the published package is not governed: {error}") from None
    except OSError as error:
        raise WorkerRefused(f"the package could not be read: {error}") from None
    finally:
        os.close(handle)
    if binding.digest != profile.package_digest:
        raise WorkerRefused("the published package is not the committed package")
    return binding.entrypoint


def verify_execution(context: LaunchContext, profile: ExecutionProfile, *,
                     root_fd: int, images: Any) -> VerifiedExecution:
    """Run every gate condition, or refuse. The only route to ``create_argv``.

    One path, in one order, with no optional step and no way around it:
    identity binding, then governed policy, then runtime contracts, then image
    presence, then the payload and package commitments. Each is a refusal, and
    a refusal here means nothing was created.
    """
    if not isinstance(context, LaunchContext):
        raise WorkerRefused("a validated LaunchContext is required")
    if not isinstance(profile, ExecutionProfile):
        raise WorkerRefused("a built ExecutionProfile is required")

    # 1-2. Identity: the profile is the one the transition authenticated.
    if fingerprint(profile).profile_digest != context.profile_digest:
        raise WorkerRefused("the profile does not match the authorised digest")
    if profile.cinv != context.cinv:
        raise WorkerRefused("the profile names a different invocation")
    if profile.cimp != context.cimp:
        raise WorkerRefused("the profile names a different implementation")

    # 3. Policy: authenticated is not authorised.
    try:
        verify_governed_policy(profile)
    except ProfileError as error:
        raise WorkerRefused(f"the profile is not governed policy: {error}") from None

    # 5. Contracts this build implements.
    require_runtime_contract(profile)

    # 4. The authorised image, present locally.
    require_image_present(profile, images)

    # 6-7. The published material, against commitments that crossed sealed.
    sources = verify_handoff(profile.cinv, root_fd=root_fd)
    try:
        invocation = os.open(profile.cinv, _DIR_FLAGS, dir_fd=root_fd)
    except OSError as error:
        raise WorkerRefused(f"the handoff is unusable: {error}") from None
    try:
        payload_bytes = _verify_payload(profile, invocation)
        entrypoint = _verify_package(profile, invocation)
    finally:
        os.close(invocation)

    return VerifiedExecution(_VERIFIED, profile=profile, sources=sources,
                             entrypoint=entrypoint, payload_bytes=payload_bytes)


def _container_entrypoint(entrypoint: str) -> str:
    """The container-side path of the governed entrypoint.

    The gate already proved this entrypoint is the committed one and that it
    names a validated member of the verified tree, so this does not re-validate
    it with a second, weaker scheme. The assertions below are defensive only:
    they restate the invariant at the boundary where a violation would become
    an argument.
    """
    if not isinstance(entrypoint, str) or not entrypoint:
        raise WorkerRefused("the verified execution carries no entrypoint")
    if entrypoint.startswith("/") or not entrypoint.endswith(".py"):
        raise WorkerRefused("the bound entrypoint is not a relative .py path")
    if any(part in ("", ".", "..") for part in entrypoint.split("/")):
        raise WorkerRefused("the bound entrypoint is not traversal-free")
    return f"{PACKAGE_DESTINATION}/{entrypoint}"


def create_argv(snapshot: Any) -> tuple[str, ...]:
    """The complete creation arguments, closed against everything else.

    Every security-critical control is stated explicitly even where Podman's
    default happens to match. A default is a decision somebody else can change;
    a flag is one this adapter owns.

    **One input, and it is a proof.** The profile, the bind sources, and the
    entrypoint no longer arrive separately, because a caller able to supply
    them separately is a caller able to supply an unverified one. The snapshot
    produces this value or nothing does.

    **The input binds are the worker's snapshot, never the handoff.** The
    handoff is coordinator-owned, and a bind mount would keep exposing it for
    the container's whole lifetime. Only the writable output leaf still lives
    under the handoff, because it is already worker-owned and the `/data`
    project quota is what bounds it.
    """
    from .snapshot import SnapshotBinding

    if not isinstance(snapshot, SnapshotBinding):
        raise WorkerRefused("a materialised snapshot is required")
    profile = snapshot.profile
    if profile.cinv != snapshot.cinv:
        raise WorkerRefused("the profile and snapshot name different invocations")

    entrypoint = _container_entrypoint(snapshot.entrypoint)
    environment: tuple[str, ...] = tuple(
        argument
        for name, value in CONTAINER_ENVIRONMENT
        for argument in ("--env", f"{name}={value}"))
    return (
        PODMAN, "create",
        "--name", container_name(profile.cinv),
        "--network", profile.network,
        # `--network none` isolates the container; it says nothing about the
        # runtime, which resolves images on the host network before any
        # container exists. Under the default (`missing`) an absent image ID
        # would be read as a repository reference and fetched, so an image that
        # failed the store check could still arrive from a registry. The image
        # is governed by CIMP and must already be in the store or the
        # invocation refuses: there is no acquisition path, by policy and now
        # by flag.
        "--pull=never",
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
        *environment,
        "--mount", (f"type=bind,src={snapshot.package},"
                    f"dst={PACKAGE_DESTINATION},ro=true"),
        "--mount", (f"type=bind,src={snapshot.payload},"
                    f"dst={PAYLOAD_DESTINATION},ro=true"),
        "--mount", (f"type=bind,src={snapshot.output},"
                    f"dst={OUTPUT_DESTINATION},ro=false"),
        profile.oci_image_id,
        CONTAINER_INTERPRETER, entrypoint,
    )
