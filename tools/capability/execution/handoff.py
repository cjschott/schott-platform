"""Immutable per-invocation handoff publication for the ENG-0005 first adapter.

**Copy, never hard link.** Execution-visible data must have a lifetime and a
permission story separable from the canonical source; an aliased inode gives it
neither, and an ``unlink`` on the execution side would touch the canonical
object's link count. Every published byte is copied from an already-open
descriptor, so the canonical source is never reopened by name.

**Anchored at both ends.** The source is a descriptor and so is the
destination, so replacing either pathname after the fact redirects nothing:
bytes are read through the descriptor that was validated and written through
the root that was verified.

**Published, then proved.** Bytes are staged, fsynced, and re-read through a
no-follow descriptor to confirm they hash to what was bound, and only then
installed by rename. A successful write count is not identity, and treating it
as identity is how a truncated or substituted file becomes authoritative.

**Nothing is replaced.** An existing per-`CINV` handoff is a refusal, not a
target: it means something already published there, and deleting, overwriting,
merging with, or adopting it would all be guesses about work nobody can see.

**Modes are declared here; ownership is not.** This module creates the
structure with the accepted §13 modes and never chowns anything. Transferring
the writable leaf to the execution identity is the privileged transition's job,
and doing it here would need authority this module must not have.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §13, §14.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
import stat
from typing import Any

from .backing_store import RootDescriptor
from .package_contract import PackageBinding
from .payload import PayloadBinding
from .profile import ExecutionProfile, canonical_profile, fingerprint

PACKAGE_DIRECTORY = "package"
PAYLOAD_NAME = "payload"
OUTPUT_DIRECTORY = "out"

# The governed execution profile, published with the rest of the handoff.
#
# **Publication material, not authority.** These are the canonical bytes the
# privileged transition will later authenticate and copy into a sealed
# root-authored object; this file stays coordinator-owned and coordinator-
# replaceable, and nothing consumes it yet. It must never be read directly as
# execution authority -- that transport is a separate increment. The name is a
# constant precisely so no caller can aim publication anywhere else.
PROFILE_NAME = "profile"

# The accepted §13 matrix. The invocation subtree and its package are readable
# and traversable but not writable; the payload is read-only; the output leaf is
# the one writable place, and the transition helper hands it to the execution
# identity later.
HANDOFF_MODES = {
    "invocation": 0o555,
    "package": 0o555,
    "package_file": 0o444,
    "payload": 0o444,
    "profile": 0o444,
    "output": 0o700,
    "staging": 0o700,
}

_DIGITS = frozenset("0123456789")
_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)


class HandoffError(ValueError):
    """Base for every refusal this module makes."""


class HandoffTargetExists(HandoffError):
    """A per-`CINV` handoff already exists and will not be replaced."""


class HandoffIdentityMismatch(HandoffError):
    """Published bytes do not hash to what was bound."""


@dataclasses.dataclass(frozen=True)
class HandoffBinding:
    """What was published, and proof of what it was."""

    cinv: str
    package_digest: str
    payload_digest: str
    profile_digest: str
    entrypoint: str
    entry_count: int


def _validate_cinv(cinv: Any) -> str:
    if not isinstance(cinv, str) or len(cinv) != 11 \
            or not cinv.startswith("CINV-") or set(cinv[5:]) - _DIGITS:
        raise HandoffError(f"{cinv!r} is not a CINV identity")
    return cinv


def _require_root(root: Any) -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise HandoffError("root must be a verified RootDescriptor")
    return root


def _write_member(name: str, body: bytes, dir_fd: int, mode: int,
                  digest: str) -> None:
    """Create one file, durably, and prove it holds the bound bytes."""
    handle = os.open(name, _CREATE_FLAGS, mode, dir_fd=dir_fd)
    try:
        written = 0
        while written < len(body):
            written += os.write(handle, body[written:])
        os.fsync(handle)
    finally:
        os.close(handle)

    verify = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        chunks: list[bytes] = []
        while True:
            chunk = os.read(verify, 65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(verify)
    if hashlib.sha256(b"".join(chunks)).hexdigest() != digest:
        raise HandoffIdentityMismatch(
            f"{name!r} does not hash to the bound digest after publication")


def _read_source(relative: str, artefact_fd: int) -> bytes:
    """One package member, read through the validated source descriptor."""
    parts = relative.split("/")
    current = artefact_fd
    opened: list[int] = []
    try:
        for component in parts[:-1]:
            current = os.open(component, _DIR_FLAGS, dir_fd=current)
            opened.append(current)
        handle = os.open(parts[-1], _READ_FLAGS, dir_fd=current)
        try:
            status = os.fstat(handle)
            if not stat.S_ISREG(status.st_mode):
                raise HandoffError(f"{relative!r} is no longer a regular file")
            chunks: list[bytes] = []
            while True:
                chunk = os.read(handle, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(handle)
    finally:
        for handle in reversed(opened):
            os.close(handle)
    return b"".join(chunks)


def _publish_package(staging_fd: int, artefact_fd: int,
                     package: PackageBinding) -> None:
    directory = os.open(PACKAGE_DIRECTORY, _DIR_FLAGS, dir_fd=staging_fd)
    try:
        made: dict[str, int] = {"": directory}
        for entry in package.entries:
            parts = entry.relative_path.split("/")
            parent = directory
            walked = ""
            for component in parts[:-1]:
                walked = f"{walked}{component}/"
                if walked not in made:
                    os.mkdir(component, HANDOFF_MODES["staging"], dir_fd=parent)
                    made[walked] = os.open(component, _DIR_FLAGS, dir_fd=parent)
                parent = made[walked]
            body = _read_source(entry.relative_path, artefact_fd)
            if hashlib.sha256(body).hexdigest() != entry.digest:
                raise HandoffIdentityMismatch(
                    f"{entry.relative_path!r} changed since validation")
            _write_member(parts[-1], body, parent,
                          HANDOFF_MODES["package_file"], entry.digest)
        for key in sorted(made, key=len, reverse=True):
            handle = made[key]
            os.fsync(handle)
            if key:
                os.close(handle)
    finally:
        os.close(directory)


def _manifest_digest(package: PackageBinding) -> str:
    manifest = hashlib.sha256()
    for entry in sorted(package.entries, key=lambda e: e.relative_path):
        manifest.update(entry.relative_path.encode("utf-8"))
        manifest.update(b"\0")
        manifest.update(str(entry.size).encode("ascii"))
        manifest.update(b"\0")
        manifest.update(entry.digest.encode("ascii"))
        manifest.update(b"\0")
    return manifest.hexdigest()


def _remove_staging(name: str, root_fd: int) -> None:
    """Best-effort removal of a staging tree that never became authoritative.

    Bounded to the internally derived staging name and its known shape: there
    is no recursive delete here, because a recursive delete rooted at anything
    a caller influenced is the wrong tool to own.
    """
    try:
        staging = os.open(name, _DIR_FLAGS, dir_fd=root_fd)
    except FileNotFoundError:
        return
    try:
        _empty(staging)
    finally:
        os.close(staging)
    try:
        os.rmdir(name, dir_fd=root_fd)
    except OSError:
        pass


def _empty(dir_fd: int) -> None:
    with os.scandir(dir_fd) as listing:
        found = list(listing)
    for entry in found:
        if entry.is_dir(follow_symlinks=False):
            child = os.open(entry.name, _DIR_FLAGS, dir_fd=dir_fd)
            try:
                _empty(child)
            finally:
                os.close(child)
            os.rmdir(entry.name, dir_fd=dir_fd)
        else:
            os.unlink(entry.name, dir_fd=dir_fd)


def publish_handoff(root: RootDescriptor, cinv: str, artefact_fd: int,
                    payload: PayloadBinding, package: PackageBinding,
                    *, profile: ExecutionProfile) -> HandoffBinding:
    """Publish the immutable handoff for ``cinv``, or refuse.

    Everything is built under an internally derived staging name and installed
    with one rename, so a partially written tree can never be mistaken for a
    handoff. Nothing existing is replaced.

    ``profile`` is the governed profile the accepted authority-resolution path
    produced. It is serialised here through the one canonical encoder and
    nothing about execution policy is reconstructed or reinterpreted: this
    module publishes bytes somebody else authored.
    """
    _require_root(root)
    _validate_cinv(cinv)
    if not isinstance(payload, PayloadBinding):
        raise HandoffError("payload must be a PayloadBinding")
    if not isinstance(package, PackageBinding):
        raise HandoffError("package must be a PackageBinding")
    if not isinstance(profile, ExecutionProfile):
        raise HandoffError("profile must be an ExecutionProfile")
    if _manifest_digest(package) != package.digest:
        raise HandoffIdentityMismatch(
            "the package binding does not match its own manifest")

    # The profile must name the invocation it is being published for.
    # Publishing one invocation's policy under another's name would make the
    # handoff say something its author never decided.
    if profile.cinv != cinv:
        raise HandoffIdentityMismatch(
            f"the profile names {profile.cinv} and the handoff is for {cinv}")

    # The commitments must name exactly the material in this staged snapshot.
    # A profile committing to A while B is published would be a handoff that
    # reports success and hands the worker something it must then refuse --
    # and the whole point of carrying the commitments in the profile is that
    # they are derived here, from what is actually being written, rather than
    # accepted from a caller.
    if profile.payload_digest != payload.digest:
        raise HandoffIdentityMismatch(
            "the profile commits to a different payload than the one published")
    if profile.package_digest != package.digest:
        raise HandoffIdentityMismatch(
            "the profile commits to a different package than the one published")
    if profile.package_entrypoint != package.entrypoint:
        raise HandoffIdentityMismatch(
            "the profile commits to a different entrypoint than the package binds")

    profile_bytes = canonical_profile(profile)
    profile_digest = hashlib.sha256(profile_bytes).hexdigest()
    # Derived here, never accepted from a caller, and checked against the
    # commitment the rest of the runtime already uses. A second digest over
    # the same profile would be a second answer to one question.
    if profile_digest != fingerprint(profile).profile_digest:
        raise HandoffIdentityMismatch(
            "the canonical profile does not hash to its own fingerprint")

    root.reverify()

    try:
        os.stat(cinv, dir_fd=root.fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise HandoffTargetExists(f"{cinv} already has a published handoff")

    staging = f".{cinv}.staging"
    try:
        os.mkdir(staging, HANDOFF_MODES["staging"], dir_fd=root.fd)
    except FileExistsError:
        raise HandoffTargetExists(
            f"a staging tree for {cinv} already exists") from None

    try:
        staging_fd = os.open(staging, _DIR_FLAGS, dir_fd=root.fd)
        try:
            os.mkdir(PACKAGE_DIRECTORY, HANDOFF_MODES["staging"],
                     dir_fd=staging_fd)
            os.mkdir(OUTPUT_DIRECTORY, HANDOFF_MODES["output"],
                     dir_fd=staging_fd)
            _publish_package(staging_fd, artefact_fd, package)
            _write_member(PAYLOAD_NAME, payload.canonical_bytes, staging_fd,
                          HANDOFF_MODES["payload"], payload.digest)
            _write_member(PROFILE_NAME, profile_bytes, staging_fd,
                          HANDOFF_MODES["profile"], profile_digest)
            os.chmod(PACKAGE_DIRECTORY, HANDOFF_MODES["package"],
                     dir_fd=staging_fd, follow_symlinks=False)
            os.fsync(staging_fd)
        finally:
            os.close(staging_fd)

        os.chmod(staging, HANDOFF_MODES["invocation"], dir_fd=root.fd,
                 follow_symlinks=False)
        os.rename(staging, cinv, src_dir_fd=root.fd, dst_dir_fd=root.fd)
        os.fsync(root.fd)
    except BaseException:
        _remove_staging(staging, root.fd)
        raise

    root.reverify()
    return HandoffBinding(
        cinv=cinv,
        package_digest=package.digest,
        payload_digest=payload.digest,
        profile_digest=profile_digest,
        entrypoint=package.entrypoint,
        entry_count=package.entry_count,
    )
