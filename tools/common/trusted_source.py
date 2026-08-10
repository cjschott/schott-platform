"""Opening a file you did not write, from a directory you are trusting.

Containment answers *is this name inside that directory?* — necessary, and not
sufficient. Between resolving a name and opening it, whoever can write the
directory gets a turn: the path validated and the file opened need not be the
same file. Every check performed against a pathname is a check against
something that may no longer be there.

So this opens **once**, refusing to follow a link on the final component, and
then asks the **descriptor** what it got. Regular file, expected owner, not
writable by group or other, and — when the caller requires it — exactly one
link. `fstat` on the open descriptor, never a second look at the path. The
caller then reads from that descriptor, and whatever happens to the name
afterwards is somebody else's story.

**Trust is in the directory, and it is checked rather than assumed.** The
approved root and every component beneath it must be a real directory, owned by
the supplied trusted UID, and not group- or world-writable. Read and traverse
for group and other are fine where operation needs them; write is not, because
a writable component is a component someone else can swap.

**The trusted UID is supplied, never inferred.** Not from the running process,
not from the file's own owner, not from the environment. A default owner is
whoever happens to be running, which is exactly the assumption this exists to
remove.

**Portability, stated rather than implied.** The directory walk uses `openat`
with a directory descriptor and `O_NOFOLLOW`, which is POSIX in shape and
Linux in practice; this platform is Linux and this module claims nothing
beyond it. On a system without those semantics it would need rewriting, not
reconfiguring.

Nothing here writes. It creates no file and no directory, changes no mode and
no owner, renames nothing, truncates nothing, and removes nothing. It opens
for reading, or it refuses.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path, PurePosixPath
from typing import Any

# Read-only, close on exec, and never follow a link on the component being
# opened. The last is the point: a link here is the substitution this refuses.
#
# `O_NONBLOCK` is not about speed. Opening a FIFO for reading blocks until a
# writer arrives, so without it a named pipe planted in the directory would
# hang the caller for ever rather than being refused as the wrong file type.
# On a regular file it changes nothing.
_OPEN_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY


class TrustedSourceError(Exception):
    """A trusted source file could not be opened as required."""


def _require_uid(expected_uid: Any) -> int:
    if not isinstance(expected_uid, int) or isinstance(expected_uid, bool):
        raise TrustedSourceError(
            "an expected trusted source uid must be supplied as an integer")
    return expected_uid


def _relative_parts(name: Any) -> tuple[str, ...]:
    """The components of a relative name, or a refusal.

    Absolute names, traversal, and the current directory are refused here
    rather than resolved: a name that has to be argued with is a name that gets
    argued with differently by the next reader.
    """
    if not isinstance(name, str) or not name.strip():
        raise TrustedSourceError("a relative name must be supplied")
    candidate = PurePosixPath(name)
    if candidate.is_absolute():
        raise TrustedSourceError("a trusted source name must be relative")
    parts = tuple(part for part in candidate.parts if part not in ("", "."))
    if not parts:
        raise TrustedSourceError("a trusted source name must name a file")
    if any(part == ".." for part in parts):
        raise TrustedSourceError("a trusted source name may not traverse upward")
    return parts


def _check_directory(descriptor: int, expected_uid: int, description: str) -> None:
    entry = os.fstat(descriptor)
    if not stat.S_ISDIR(entry.st_mode):
        raise TrustedSourceError(f"{description} is not a directory")
    if entry.st_uid != expected_uid:
        raise TrustedSourceError(f"{description} is not owned by the trusted uid")
    if entry.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise TrustedSourceError(f"{description} is writable beyond its owner")


def open_trusted_regular_file(approved_root: Path | str, name: Any, *,
                              expected_uid: Any,
                              require_single_link: bool = False,
                              maximum_bytes: int | None = None,
                              refuse_oversize: bool = False) -> int:
    """An open descriptor for one regular file beneath a trusted root.

    The caller owns the descriptor and must close it. Every property this
    promises is checked on that descriptor, so the file the caller reads is the
    file that was checked.

    `require_single_link` refuses a file with a second hard link — a second name
    for the same bytes, outside the directory whose permissions were just
    verified. `maximum_bytes` with `refuse_oversize` refuses before reading
    anything, so an oversized file is never partially consumed.
    """
    uid = _require_uid(expected_uid)
    parts = _relative_parts(name)

    root = Path(approved_root)
    if not root.is_absolute():
        root = root.resolve(strict=False)

    # The root is opened the same way every component is: without following a
    # link, then interrogated through its descriptor.
    try:
        current = os.open(root, _DIRECTORY_FLAGS)
    except OSError as error:
        raise TrustedSourceError(
            "the approved root could not be opened as a directory") from error

    opened: int | None = None
    try:
        _check_directory(current, uid, "the approved root")

        # Walk component by component with openat, so no intermediate name is
        # ever resolved by a second traversal of the whole path.
        for component in parts[:-1]:
            try:
                nested = os.open(component, _DIRECTORY_FLAGS, dir_fd=current)
            except OSError as error:
                raise TrustedSourceError(
                    f"path component '{component}' is not a usable directory") from error
            os.close(current)
            current = nested
            _check_directory(current, uid, f"path component '{component}'")

        try:
            opened = os.open(parts[-1], _OPEN_FLAGS, dir_fd=current)
        except OSError as error:
            raise TrustedSourceError(
                "the trusted source file could not be opened") from error

        entry = os.fstat(opened)
        if not stat.S_ISREG(entry.st_mode):
            raise TrustedSourceError("the trusted source is not a regular file")
        if entry.st_uid != uid:
            raise TrustedSourceError(
                "the trusted source is not owned by the trusted uid")
        if entry.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise TrustedSourceError(
                "the trusted source is writable beyond its owner")
        if require_single_link and entry.st_nlink != 1:
            raise TrustedSourceError(
                "the trusted source carries more than one link to its bytes")
        if (refuse_oversize and maximum_bytes is not None
                and entry.st_size > maximum_bytes):
            raise TrustedSourceError(
                "the trusted source is larger than the supplied bound")
    except BaseException:
        if opened is not None:
            os.close(opened)
        raise
    finally:
        os.close(current)

    return opened
