"""The worker-owned invocation snapshot for the ENG-0005 first adapter.

**A check could not close this; only a copy could.** Pass 4A verifies the
payload and package against the authenticated profile, and that verification
protects nothing on its own: Podman resolves a *pathname*, and the pathname
pointed into a directory the coordinator owns. A bind mount is not a copy —
the container shares that tree for its whole lifetime — so the window was never
"verify then open", it was "verify then end of execution". Reproduced before
this module existed: the gate passed, the coordinator replaced the payload and
the entrypoint, and the bind sources still resolved to the replacements.

**So the worker materialises what it verified, somewhere the coordinator cannot
reach.** `/run/kyri/execution-material/` is `root:kyri-capability 0770` beneath
a `root:root` ancestry: the worker may create children, and the coordinator has
no write, no read, and no traverse. Every byte here is written by this process
into an object it created, so there is no descriptor anybody else retained and
no name anybody else can rename.

**The copy is safe because of what follows it, not because it is fast.** A
coordinator may mutate the source *while* the copy runs. That cannot be
prevented and is not worth pretending about, so both commitments are recomputed
over the finished snapshot and compared with the profile. A tree that moved
under the copy produces a mismatch and the invocation is refused. There is no
retry: against an adversary that can always mutate again, a retry loop is a
loop with no defined end.

**Mode tightening at the end is defence in depth and nothing more.** What
protects these bytes is that no coordinator-writable handle ever referred to
them and that the ancestry is not coordinator-mutable. A mode is what you set
when you already have the property, not how you get it.

**No privilege.** This runs as the execution identity, after the credential
drop. It creates directories and files, and it never chowns, never execs,
never reaches Podman, and never asks root for anything.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §14.5.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
import stat as stat_module
from typing import Any

from .package_contract import (MAXIMUM_AGGREGATE_BYTES, MAXIMUM_FILE_BYTES,
                               PackageError, validate_package)
from .payload import PAYLOAD_MAXIMUM_BYTES

# Compiled in, exactly like every other governed root. It is not a parameter,
# not an environment variable, and not a profile field: a snapshot root a
# caller could name is a snapshot root a caller could aim.
SNAPSHOT_ROOT = "/run/kyri/execution-material"

PAYLOAD_NAME = "payload"
PACKAGE_NAME = "package"

# The finished shape. Read-only and traversable by the owner, which is enough
# for Podman to resolve the bind sources as the execution identity.
SNAPSHOT_MODES = {
    "invocation": 0o500,
    "package": 0o500,
    "payload": 0o444,
    "member": 0o444,
    "staging": 0o700,
}

_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_READ_FLAGS = (os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
_CREATE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)
_CHUNK = 65536

_DIGITS = frozenset("0123456789")


class SnapshotRefused(ValueError):
    """The snapshot will not be created, or will not be trusted."""


_MATERIALISED = object()


class SnapshotBinding:
    """Proof that a snapshot exists and matches the authenticated commitments.

    Not a plain dataclass, for the same reason `VerifiedExecution` is not: this
    value is what `create_argv` turns into Podman bind sources, and a value
    meaning "these paths hold the committed material" must not be constructible
    by anything that did not put the material there and check it.

    Carries paths and commitments only — no descriptor and nothing writable.
    The only handoff path here is the writable output leaf, which §14.5 keeps
    where it is; the two *input* binds are the snapshot and nothing else.
    """

    __slots__ = ("cinv", "profile", "payload", "package", "output",
                 "entrypoint", "payload_digest", "package_digest")

    def __init__(self, token: Any, *, cinv: str, profile: Any, payload: str,
                 package: str, output: str, entrypoint: str,
                 payload_digest: str, package_digest: str) -> None:
        if token is not _MATERIALISED:
            raise SnapshotRefused(
                "a snapshot binding is produced by materialise and cannot be "
                "constructed")
        object.__setattr__(self, "cinv", cinv)
        object.__setattr__(self, "profile", profile)
        object.__setattr__(self, "payload", payload)
        object.__setattr__(self, "package", package)
        # The one handoff path that stays: the writable output leaf is already
        # worker-owned and the /data project quota is what bounds it, so moving
        # it would move the quota story for no gain.
        object.__setattr__(self, "output", output)
        object.__setattr__(self, "entrypoint", entrypoint)
        object.__setattr__(self, "payload_digest", payload_digest)
        object.__setattr__(self, "package_digest", package_digest)

    def __setattr__(self, name: str, value: Any) -> None:
        raise SnapshotRefused("the snapshot binding is immutable")

    def __delattr__(self, name: str) -> None:
        raise SnapshotRefused("the snapshot binding is immutable")


def _validate_cinv(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 11 \
            or not value.startswith("CINV-") or set(value[5:]) - _DIGITS:
        raise SnapshotRefused(f"{value!r} is not a CINV identity")
    return value


def open_snapshot_root() -> int:
    """The compiled-in snapshot root, opened no-follow, or refuse.

    The production opener. Tests pass their own descriptor instead, which is
    the same discipline every other governed root here uses: obtaining the
    descriptor safely is the caller's authority, and this module never learns a
    pathname it could aim somewhere else.
    """
    try:
        return os.open(SNAPSHOT_ROOT, _DIR_FLAGS)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot root is unusable: {error}. It is provisioned by "
            f"systemd-tmpfiles as a generation-6 host prerequisite") from None


def _allocate(cinv: str, snapshot_fd: int) -> int:
    """Create the per-`CINV` snapshot directory create-once, or refuse.

    A collision is lifecycle evidence: something already materialised for this
    identity, or a crash left residue. Either way it is refused rather than
    adopted, merged, repaired, or deleted — silently removing what somebody
    else put there is how a cleanup becomes an attack.
    """
    try:
        os.mkdir(cinv, SNAPSHOT_MODES["staging"], dir_fd=snapshot_fd)
    except FileExistsError:
        raise SnapshotRefused(
            f"a snapshot for {cinv} already exists and will not be replaced") from None
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot for {cinv} could not be created: {error}") from None
    try:
        return os.open(cinv, _DIR_FLAGS, dir_fd=snapshot_fd)
    except OSError as error:
        raise SnapshotRefused(
            f"the new snapshot for {cinv} is unusable: {error}") from None


def _write_member(name: str, body: bytes, dir_fd: int, mode: int) -> None:
    """Create one snapshot file exclusively and write it whole, or refuse."""
    try:
        handle = os.open(name, _CREATE_FLAGS, mode, dir_fd=dir_fd)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot member {name!r} could not be created: {error}") from None
    try:
        written = 0
        while written < len(body):
            step = os.write(handle, body[written:])
            if step <= 0:
                raise SnapshotRefused(
                    f"the snapshot member {name!r} stopped before the end")
            written += step
        os.fsync(handle)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot member {name!r} could not be written: {error}") from None
    finally:
        os.close(handle)


def _read_source_member(name: str, dir_fd: int, relative: str) -> bytes:
    """One package member, read from the source descriptor, or refuse.

    ``O_NOFOLLOW`` refuses a symlink and ``O_NONBLOCK`` refuses to wait on a
    FIFO — the generation-5 lesson, applied where the worker now opens objects
    a coordinator controls. The type is then checked before a byte is used.
    """
    try:
        handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    except OSError as error:
        raise SnapshotRefused(
            f"the package member {relative!r} is unusable: {error}") from None
    try:
        info = os.fstat(handle)
        if not stat_module.S_ISREG(info.st_mode):
            raise SnapshotRefused(
                f"the package member {relative!r} is not a regular file")
        if info.st_size > MAXIMUM_FILE_BYTES:
            raise SnapshotRefused(
                f"the package member {relative!r} exceeds the per-file bound")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(handle, _CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > MAXIMUM_FILE_BYTES:
                raise SnapshotRefused(
                    f"the package member {relative!r} exceeds the per-file bound")
            chunks.append(chunk)
    except OSError as error:
        raise SnapshotRefused(
            f"the package member {relative!r} could not be read: {error}") from None
    finally:
        os.close(handle)
    return b"".join(chunks)


def _copy_tree(source_fd: int, destination_fd: int, prefix: str,
               budget: list[int]) -> None:
    """Copy one package directory level, descriptor-relatively, or refuse.

    Nothing here resolves a pathname: every child is opened relative to the
    descriptor its parent was opened as, so replacing a directory name after
    the walk started redirects nothing. Only regular files and directories
    cross; a symlink, FIFO, socket, or device node is refused rather than
    copied, and the aggregate bound is spent as the walk proceeds.
    """
    with os.scandir(source_fd) as listing:
        entries = sorted(listing, key=lambda entry: entry.name)
    for entry in entries:
        relative = f"{prefix}{entry.name}"
        if entry.is_symlink():
            raise SnapshotRefused(f"the package member {relative!r} is a symlink")
        if entry.is_dir(follow_symlinks=False):
            try:
                os.mkdir(entry.name, SNAPSHOT_MODES["staging"],
                         dir_fd=destination_fd)
            except OSError as error:
                raise SnapshotRefused(
                    f"the snapshot directory {relative!r} could not be created: "
                    f"{error}") from None
            child_source = os.open(entry.name, _DIR_FLAGS, dir_fd=source_fd)
            try:
                child_destination = os.open(entry.name, _DIR_FLAGS,
                                            dir_fd=destination_fd)
                try:
                    _copy_tree(child_source, child_destination,
                               f"{relative}/", budget)
                finally:
                    os.close(child_destination)
            finally:
                os.close(child_source)
            continue
        if not entry.is_file(follow_symlinks=False):
            raise SnapshotRefused(
                f"the package member {relative!r} is neither a regular file "
                "nor a directory")
        body = _read_source_member(entry.name, source_fd, relative)
        budget[0] += len(body)
        if budget[0] > MAXIMUM_AGGREGATE_BYTES:
            raise SnapshotRefused(
                f"the package exceeds {MAXIMUM_AGGREGATE_BYTES} aggregate bytes")
        _write_member(entry.name, body, destination_fd, SNAPSHOT_MODES["member"])


def _tighten(cinv: str, invocation_fd: int, snapshot_fd: int) -> None:
    """Set the finished modes. Defence in depth, never the guarantee."""
    try:
        for base, _, _ in _walk_directories(invocation_fd, PACKAGE_NAME):
            os.chmod(base, SNAPSHOT_MODES["package"], dir_fd=invocation_fd,
                     follow_symlinks=False)
        os.chmod(cinv, SNAPSHOT_MODES["invocation"], dir_fd=snapshot_fd,
                 follow_symlinks=False)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot modes could not be set: {error}") from None


def _walk_directories(invocation_fd: int, name: str):
    """The package directory and its subdirectories, deepest first."""
    found = [name]
    pending = [name]
    while pending:
        current = pending.pop()
        handle = os.open(current, _DIR_FLAGS, dir_fd=invocation_fd)
        try:
            with os.scandir(handle) as listing:
                children = [entry.name for entry in listing
                            if entry.is_dir(follow_symlinks=False)]
        finally:
            os.close(handle)
        for child in children:
            path = f"{current}/{child}"
            found.append(path)
            pending.append(path)
    return [(path, None, None) for path in reversed(found)]


def materialise(verified: Any, *, handoff_fd: int,
                snapshot_fd: int) -> SnapshotBinding:
    """Copy verified invocation material into a worker-owned snapshot, or refuse.

    ``verified`` must be the Pass 4A gate result. Taking an ``ExecutionProfile``
    here, or a boolean, would make the snapshot a way around the gate rather
    than a step after it.

    The payload is written from the bytes the gate already read and verified,
    so its source is never reopened and there is no window to lose. The package
    is copied descriptor-relatively from the handoff, and then **both**
    commitments are recomputed over the snapshot and required to equal the
    authenticated profile — which is what makes the copy safe rather than the
    copy being quick.
    """
    # Imported here rather than at module scope: `worker` imports this module
    # for the snapshot paths it builds argv from, and a module-scope import in
    # both directions is a cycle.
    from .worker import VerifiedExecution

    if not isinstance(verified, VerifiedExecution):
        raise SnapshotRefused("a verified execution is required")
    profile = verified.profile
    cinv = _validate_cinv(profile.cinv)

    invocation_fd = _allocate(cinv, snapshot_fd)
    try:
        # The payload, from bytes already read and verified. No reopen.
        body = verified.payload_bytes
        if not isinstance(body, bytes) or len(body) > PAYLOAD_MAXIMUM_BYTES:
            raise SnapshotRefused("the verified payload bytes are not usable")
        _write_member(PAYLOAD_NAME, body, invocation_fd,
                      SNAPSHOT_MODES["payload"])

        # The package, copied descriptor-relatively from the handoff.
        try:
            source_invocation = os.open(cinv, _DIR_FLAGS, dir_fd=handoff_fd)
        except OSError as error:
            raise SnapshotRefused(
                f"the handoff for {cinv} is unusable: {error}") from None
        try:
            try:
                source_package = os.open(PACKAGE_NAME, _DIR_FLAGS,
                                         dir_fd=source_invocation)
            except OSError as error:
                raise SnapshotRefused(
                    f"the published package is unusable: {error}") from None
            try:
                os.mkdir(PACKAGE_NAME, SNAPSHOT_MODES["staging"],
                         dir_fd=invocation_fd)
                destination_package = os.open(PACKAGE_NAME, _DIR_FLAGS,
                                              dir_fd=invocation_fd)
                try:
                    _copy_tree(source_package, destination_package, "", [0])
                    os.fsync(destination_package)
                finally:
                    os.close(destination_package)
            finally:
                os.close(source_package)
        finally:
            os.close(source_invocation)
        os.fsync(invocation_fd)

        # Both commitments, recomputed over the snapshot. A source that moved
        # under the copy fails here, and fails the invocation with it.
        payload_digest = hashlib.sha256(
            _read_snapshot_payload(invocation_fd)).hexdigest()
        if payload_digest != profile.payload_digest:
            raise SnapshotRefused(
                "the snapshot payload does not match the authenticated commitment")

        try:
            check_fd = os.open(PACKAGE_NAME, _DIR_FLAGS, dir_fd=invocation_fd)
        except OSError as error:
            raise SnapshotRefused(
                f"the snapshot package is unusable: {error}") from None
        try:
            binding = validate_package(
                check_fd, entrypoint=profile.package_entrypoint)
        except PackageError as error:
            raise SnapshotRefused(
                f"the snapshot package is not governed: {error}") from None
        finally:
            os.close(check_fd)
        if binding.digest != profile.package_digest:
            raise SnapshotRefused(
                "the snapshot package does not match the authenticated commitment")

        _tighten(cinv, invocation_fd, snapshot_fd)
    except BaseException:
        # A refused snapshot leaves nothing behind that a later attempt could
        # mistake for material, and nothing a collision would have to explain.
        _remove(cinv, snapshot_fd)
        raise
    finally:
        os.close(invocation_fd)

    base = f"{SNAPSHOT_ROOT}/{cinv}"
    return SnapshotBinding(
        _MATERIALISED,
        cinv=cinv,
        profile=profile,
        payload=f"{base}/{PAYLOAD_NAME}",
        package=f"{base}/{PACKAGE_NAME}",
        output=verified.sources.output,
        entrypoint=binding.entrypoint,
        payload_digest=payload_digest,
        package_digest=binding.digest,
    )


def _read_snapshot_payload(invocation_fd: int) -> bytes:
    try:
        handle = os.open(PAYLOAD_NAME, _READ_FLAGS, dir_fd=invocation_fd)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot payload is unusable: {error}") from None
    try:
        return os.pread(handle, PAYLOAD_MAXIMUM_BYTES + 1, 0)
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot payload could not be read: {error}") from None
    finally:
        os.close(handle)


def _remove(cinv: str, snapshot_fd: int) -> None:
    """Remove a snapshot subtree the worker owns. Bounded to its own shape."""
    try:
        invocation = os.open(cinv, _DIR_FLAGS, dir_fd=snapshot_fd)
    except FileNotFoundError:
        return
    except OSError:
        return
    try:
        os.chmod(cinv, SNAPSHOT_MODES["staging"], dir_fd=snapshot_fd,
                 follow_symlinks=False)
        _empty(invocation)
    finally:
        os.close(invocation)
    try:
        os.rmdir(cinv, dir_fd=snapshot_fd)
    except OSError:
        pass


def _empty(dir_fd: int) -> None:
    with os.scandir(dir_fd) as listing:
        found = list(listing)
    for entry in found:
        if entry.is_dir(follow_symlinks=False):
            os.chmod(entry.name, SNAPSHOT_MODES["staging"], dir_fd=dir_fd,
                     follow_symlinks=False)
            child = os.open(entry.name, _DIR_FLAGS, dir_fd=dir_fd)
            try:
                _empty(child)
            finally:
                os.close(child)
            os.rmdir(entry.name, dir_fd=dir_fd)
        else:
            os.unlink(entry.name, dir_fd=dir_fd)


def discard(cinv: Any, *, snapshot_fd: int) -> None:
    """Remove this invocation's snapshot, or refuse.

    The worker owns its own snapshot and removes it; root gains no cleanup
    command and the coordinator cannot reach this tree at all. Absence is a
    refusal rather than a quiet success, for the reason handoff cleanup already
    holds: a removal that cannot see what it removed cannot claim it removed
    anything.
    """
    identity = _validate_cinv(cinv)
    try:
        os.stat(identity, dir_fd=snapshot_fd, follow_symlinks=False)
    except FileNotFoundError:
        raise SnapshotRefused(
            f"there is no snapshot for {identity} to discard") from None
    except OSError as error:
        raise SnapshotRefused(
            f"the snapshot for {identity} is unusable: {error}") from None
    _remove(identity, snapshot_fd)
    try:
        os.stat(identity, dir_fd=snapshot_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise SnapshotRefused(f"the snapshot for {identity} could not be removed")
