"""Provisioned backing-store verification for the ENG-0005 first adapter.

**Verifies against a descriptor, not a pathname.** A pathname that pointed at
the right filesystem one instant ago proves nothing about where the next write
will land. The caller opens the runtime root, this module binds the *device the
open descriptor actually sits on*, and every later mutation is anchored to that
descriptor — so renaming the root away mid-transaction redirects nothing.

**Config is provisioned, never generated.** The runtime cannot create, repair,
or regenerate the backing-store configuration, and it never accepts "whatever
filesystem is here now" as authority. A malformed config is a refusal, not a
prompt to write a fresh one.

**One runtime limitation, stated rather than hidden.** Python offers no way to
obtain a filesystem UUID from a directory descriptor — ``os.fstat`` gives
``st_dev`` and ``os.statvfs`` gives no UUID. The UUID, type, and mount facts are
therefore observed by the caller, which already holds that authority, and
passed in as an immutable value. What this module contributes is that the
*descriptor's own* device identity is captured and becomes the anchor, so the
caller's claim cannot silently relocate the transaction.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §22.
"""

from __future__ import annotations

import dataclasses
import os
from typing import Any

from . import canonical_json
from .types import Classification

MAXIMUM_CONFIG_BYTES = 64 * 1024

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


class BackingStoreError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class BackingStoreMismatch(BackingStoreError):
    """The observed filesystem is not the provisioned one."""

    classification = Classification.QUARANTINE_BACKING_STORE_MISMATCH


class BackingStoreConfigIntegrityFailure(BackingStoreError):
    """The provisioned configuration cannot be read as written."""

    classification = (
        Classification.QUARANTINE_BACKING_STORE_CONFIG_INTEGRITY_FAILURE)


@dataclasses.dataclass(frozen=True)
class ObservedFilesystem:
    """Host facts the caller observed about the filesystem under the root.

    ``device_name`` is carried for diagnostics and is **never** compared: device
    names are assigned by the kernel in discovery order and change across
    reboots, so failing on one would reject a correct host for a cosmetic
    reason.
    """

    filesystem_uuid: str
    filesystem_type: str
    mount_point: str
    device_name: str


@dataclasses.dataclass(frozen=True)
class RootDescriptor:
    """A verified root, anchored to a descriptor this object owns.

    Holds a duplicate of the caller's descriptor so the verified root survives
    the caller closing theirs. ``path`` is deliberately absent: nothing here
    should ever be able to reopen by name.
    """

    fd: int
    st_dev: int
    filesystem_uuid: str
    filesystem_type: str
    mount_point: str
    device_name: str

    def close(self) -> None:
        os.close(self.fd)

    def reverify(self) -> None:
        """Confirm the descriptor still sits on the device it was verified on.

        Called before a mutation is accepted as authoritative. A changed
        ``st_dev`` means the object under this descriptor is no longer the one
        that was verified, and nothing written through it can be trusted.
        """
        if os.fstat(self.fd).st_dev != self.st_dev:
            raise BackingStoreMismatch(
                "the verified root descriptor changed device")


def _read_config(config_fd: int) -> bytes:
    status = os.fstat(config_fd)
    if not (status.st_mode & 0o170000) == 0o100000:
        raise BackingStoreConfigIntegrityFailure(
            "the backing-store config is not a regular file")
    chunks: list[bytes] = []
    remaining = MAXIMUM_CONFIG_BYTES + 1
    while remaining > 0:
        chunk = os.read(config_fd, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    body = b"".join(chunks)
    if len(body) > MAXIMUM_CONFIG_BYTES:
        raise BackingStoreConfigIntegrityFailure(
            f"the backing-store config exceeds {MAXIMUM_CONFIG_BYTES} bytes")
    return body


def _parse_config(body: bytes) -> dict[str, Any]:
    try:
        document = canonical_json.parse(body, maximum_bytes=MAXIMUM_CONFIG_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise BackingStoreConfigIntegrityFailure(
            f"the backing-store config is not canonical: {error}") from None

    fields = {"filesystem_uuid", "filesystem_type", "mount_point"}
    for name in document:
        if name not in fields:
            raise BackingStoreConfigIntegrityFailure(
                f"the backing-store config carries unknown field {name!r}")
    for name in fields:
        if name not in document:
            raise BackingStoreConfigIntegrityFailure(
                f"the backing-store config is missing {name!r}")
        if not isinstance(document[name], str) or not document[name]:
            raise BackingStoreConfigIntegrityFailure(
                f"the backing-store config field {name!r} is not a string")
    return document


def verify_backing_store(config_fd: int, root_fd: int, *,
                         observed: ObservedFilesystem) -> RootDescriptor:
    """Verify the provisioned backing store and anchor the root descriptor.

    The returned descriptor owns a duplicate of ``root_fd``; the caller keeps
    ownership of everything it passed in and this function closes nothing it
    did not open.
    """
    document = _parse_config(_read_config(config_fd))

    if observed.filesystem_uuid != document["filesystem_uuid"]:
        raise BackingStoreMismatch(
            "filesystem UUID does not match the provisioned backing store")
    if observed.filesystem_type != document["filesystem_type"]:
        raise BackingStoreMismatch(
            "filesystem type does not match the provisioned backing store")
    if observed.mount_point != document["mount_point"]:
        raise BackingStoreMismatch(
            "mount relationship does not match the provisioned backing store")

    status = os.fstat(root_fd)
    if not (status.st_mode & 0o170000) == 0o040000:
        raise BackingStoreMismatch("the runtime root is not a directory")

    duplicate = os.dup(root_fd)
    return RootDescriptor(
        fd=duplicate,
        st_dev=status.st_dev,
        filesystem_uuid=document["filesystem_uuid"],
        filesystem_type=document["filesystem_type"],
        mount_point=document["mount_point"],
        device_name=observed.device_name,
    )
