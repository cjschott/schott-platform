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

**Two different questions.** ``open_trusted_regular_file`` answers *this
directory is trusted — give me a file out of it safely*, and ownership is the
anchor. ``walk_tree`` answers the opposite one: *this directory is not trusted
at all — enumerate it without the enumeration becoming the attack.* There is no
expected uid there and no mode requirement, because the writer owns the tree;
requiring it to be owned by someone else would be a claim about a directory the
adversary controls. What is checked instead is structural, and the caller
supplies every bound. The module learns no policy; it is handed one.
"""

from __future__ import annotations

import dataclasses
import enum
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


# --- bounded traversal of an untrusted tree ---------------------------------


class EntryKind(enum.Enum):
    """What a directory entry is, decided from its mode and nothing else."""

    REGULAR = "regular"
    DIRECTORY = "directory"
    SYMLINK = "symlink"
    FIFO = "fifo"
    SOCKET = "socket"
    DEVICE = "device"
    UNKNOWN = "unknown"

    @property
    def traversable(self) -> bool:
        """Whether a tree may be built out of this kind of object."""
        return self in (EntryKind.REGULAR, EntryKind.DIRECTORY)

    @classmethod
    def of(cls, mode: int) -> "EntryKind":
        """The kind ``mode`` describes.

        Block and character devices are one answer rather than two: they differ
        in how the kernel reaches the driver, and not at all in being something
        a walk of a data tree must refuse. ``UNKNOWN`` is kept as a real member
        so that an object nobody anticipated is named rather than mistaken for
        the last branch of an ``if``.
        """
        if stat.S_ISREG(mode):
            return cls.REGULAR
        if stat.S_ISDIR(mode):
            return cls.DIRECTORY
        if stat.S_ISLNK(mode):
            return cls.SYMLINK
        if stat.S_ISFIFO(mode):
            return cls.FIFO
        if stat.S_ISSOCK(mode):
            return cls.SOCKET
        if stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
            return cls.DEVICE
        return cls.UNKNOWN


class TraversalReason(enum.Enum):
    """Why a walk stopped. Generic: no caller's vocabulary appears here."""

    INVALID_ROOT = "invalid_root"
    INVALID_NAME = "invalid_name"
    DEPTH_EXCEEDED = "depth_exceeded"
    ENTRY_LIMIT_EXCEEDED = "entry_limit_exceeded"
    FILE_LIMIT_EXCEEDED = "file_limit_exceeded"
    FILE_TOO_LARGE = "file_too_large"
    TOTAL_TOO_LARGE = "total_too_large"
    UNEXPECTED_OBJECT = "unexpected_object"
    LINK_ANOMALY = "link_anomaly"
    CROSSED_DEVICE = "crossed_device"
    RACED = "raced"
    UNREADABLE = "unreadable"


class TraversalRefused(TrustedSourceError):
    """A bounded walk refused, carrying the generic reason it refused for."""

    def __init__(self, reason: TraversalReason, message: str) -> None:
        super().__init__(message)
        self.reason = reason


@dataclasses.dataclass(frozen=True)
class WalkedFile:
    """One regular file that satisfied every bound, and its exact bytes."""

    relative_path: tuple[str, ...]
    size: int
    data: bytes


@dataclasses.dataclass(frozen=True)
class WalkedTree:
    """A complete tree that satisfied every bound.

    It exists only if the *whole* walk succeeded. There is no partial value and
    no "what we got before it went wrong": a caller handed a tree can rely on
    every entry in it having been examined, which is the property that lets it
    validate the complete tree before trusting any part of one.
    """

    files: tuple[WalkedFile, ...]
    directories: tuple[tuple[str, ...], ...]
    entry_count: int
    total_bytes: int


def _require_bound(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise TraversalRefused(
            TraversalReason.INVALID_ROOT,
            f"{name} must be supplied as a non-negative integer")
    return value


def _require_child_name(name: Any) -> str:
    """A single, stable path component, or refuse.

    The kernel will not hand back ``.``, ``..``, or an embedded separator, so
    this is checking that what arrived is what the kernel produces — a name
    carrying a separator did not come from a directory read.
    """
    if not isinstance(name, str) or not name or name in (".", ".."):
        raise TraversalRefused(TraversalReason.INVALID_NAME,
                               f"not a usable directory entry name: {name!r}")
    if "/" in name or "\0" in name:
        raise TraversalRefused(TraversalReason.INVALID_NAME,
                               f"a directory entry name may not be a path: {name!r}")
    return name


def _read_exactly(descriptor: int, ceiling: int) -> bytes:
    """At most ``ceiling`` bytes from an open descriptor.

    The ceiling is one byte past what the caller will accept, so a file that
    grew past the bound is detected by having more to give rather than by being
    asked how big it is a second time.
    """
    chunks: list[bytes] = []
    remaining = ceiling
    while remaining > 0:
        chunk = os.read(descriptor, min(65536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


class _Walk:
    """One traversal in progress. Holds the budgets, spends them once each."""

    def __init__(self, *, maximum_depth: int, maximum_entries: int,
                 maximum_files: int, maximum_file_bytes: int,
                 maximum_total_bytes: int, root_device: int) -> None:
        self.maximum_depth = maximum_depth
        self.maximum_entries = maximum_entries
        self.maximum_files = maximum_files
        self.maximum_file_bytes = maximum_file_bytes
        self.maximum_total_bytes = maximum_total_bytes
        self.root_device = root_device
        self.entries = 0
        self.total_bytes = 0
        self.files: list[WalkedFile] = []
        self.directories: list[tuple[str, ...]] = []

    def names(self, descriptor: int) -> list[str]:
        """The children of one directory, bounded and deterministically ordered.

        Enumeration stops one entry past the remaining budget rather than
        reading the directory out and counting afterwards: a directory with
        millions of children must cost the budget, not the memory. Ordering is
        by the UTF-8 bytes of each name, so the same tree walks the same way
        every time.
        """
        allowance = self.maximum_entries - self.entries + 1
        collected: list[str] = []
        with os.scandir(descriptor) as entries:
            for entry in entries:
                collected.append(_require_child_name(entry.name))
                if len(collected) >= allowance:
                    raise TraversalRefused(
                        TraversalReason.ENTRY_LIMIT_EXCEEDED,
                        f"more than {self.maximum_entries} entries")
        return sorted(collected, key=lambda name: name.encode("utf-8", "surrogateescape"))

    def describe(self, name: str, descriptor: int) -> os.stat_result:
        """What the entry is right now, without following it anywhere."""
        try:
            return os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        except OSError as error:
            raise TraversalRefused(
                TraversalReason.RACED,
                f"entry '{name}' could not be described: {error}") from None

    def file(self, name: str, descriptor: int, path: tuple[str, ...],
             described: os.stat_result) -> None:
        """Accept one regular file, or refuse before reading anything large."""
        if len(self.files) + 1 > self.maximum_files:
            raise TraversalRefused(
                TraversalReason.FILE_LIMIT_EXCEEDED,
                f"more than {self.maximum_files} regular files")

        try:
            handle = os.open(name, _OPEN_FLAGS, dir_fd=descriptor)
        except OSError as error:
            raise TraversalRefused(
                TraversalReason.RACED,
                f"entry '{name}' could not be opened as described: {error}") from None
        try:
            opened = os.fstat(handle)
            # The entry described and the object opened must be the same
            # object. Everything below is a statement about `handle`, and this
            # is what ties `handle` to what enumeration reported.
            if not stat.S_ISREG(opened.st_mode):
                raise TraversalRefused(
                    TraversalReason.RACED,
                    f"entry '{name}' stopped being a regular file")
            if (opened.st_ino != described.st_ino
                    or opened.st_dev != described.st_dev):
                raise TraversalRefused(
                    TraversalReason.RACED,
                    f"entry '{name}' is not the object that was described")
            if opened.st_nlink != 1:
                raise TraversalRefused(
                    TraversalReason.LINK_ANOMALY,
                    f"entry '{name}' carries more than one link to its bytes")
            if opened.st_size > self.maximum_file_bytes:
                raise TraversalRefused(
                    TraversalReason.FILE_TOO_LARGE,
                    f"entry '{name}' is larger than {self.maximum_file_bytes} bytes")
            if self.total_bytes + opened.st_size > self.maximum_total_bytes:
                raise TraversalRefused(
                    TraversalReason.TOTAL_TOO_LARGE,
                    f"the tree exceeds {self.maximum_total_bytes} bytes")

            data = _read_exactly(handle, self.maximum_file_bytes + 1)

            # Read one byte past the bound, so a file that grew after it was
            # measured is caught here rather than accepted at its old size.
            if len(data) > self.maximum_file_bytes:
                raise TraversalRefused(
                    TraversalReason.FILE_TOO_LARGE,
                    f"entry '{name}' grew beyond {self.maximum_file_bytes} bytes")

            settled = os.fstat(handle)
            if (len(data) != opened.st_size or settled.st_size != opened.st_size
                    or settled.st_ino != opened.st_ino
                    or settled.st_dev != opened.st_dev
                    or settled.st_nlink != 1):
                raise TraversalRefused(
                    TraversalReason.RACED,
                    f"entry '{name}' changed while it was being read")
        finally:
            os.close(handle)

        self.total_bytes += len(data)
        if self.total_bytes > self.maximum_total_bytes:
            raise TraversalRefused(
                TraversalReason.TOTAL_TOO_LARGE,
                f"the tree exceeds {self.maximum_total_bytes} bytes")
        self.files.append(WalkedFile(relative_path=path, size=len(data), data=data))

    def directory(self, name: str, descriptor: int, path: tuple[str, ...],
                  depth: int, described: os.stat_result) -> None:
        """Descend into one directory, anchored on its parent's descriptor."""
        try:
            child = os.open(name, _DIRECTORY_FLAGS, dir_fd=descriptor)
        except OSError as error:
            raise TraversalRefused(
                TraversalReason.RACED,
                f"entry '{name}' could not be opened as a directory: {error}") from None
        try:
            opened = os.fstat(child)
            if not stat.S_ISDIR(opened.st_mode):
                raise TraversalRefused(
                    TraversalReason.RACED,
                    f"entry '{name}' stopped being a directory")
            if (opened.st_ino != described.st_ino
                    or opened.st_dev != described.st_dev):
                raise TraversalRefused(
                    TraversalReason.RACED,
                    f"entry '{name}' is not the directory that was described")
            self.directories.append(path)
            self.level(child, path, depth)
        finally:
            os.close(child)

    def level(self, descriptor: int, path: tuple[str, ...], depth: int) -> None:
        """Walk one directory's children. Recursion is bounded by the depth."""
        for name in self.names(descriptor):
            child_depth = depth + 1
            self.entries += 1
            if self.entries > self.maximum_entries:
                raise TraversalRefused(
                    TraversalReason.ENTRY_LIMIT_EXCEEDED,
                    f"more than {self.maximum_entries} entries")
            if child_depth > self.maximum_depth:
                raise TraversalRefused(
                    TraversalReason.DEPTH_EXCEEDED,
                    f"an entry lies deeper than {self.maximum_depth}")

            described = self.describe(name, descriptor)
            # A different device beneath the root is a mount, and a mount is a
            # tree somebody else attached to this one.
            if described.st_dev != self.root_device:
                raise TraversalRefused(
                    TraversalReason.CROSSED_DEVICE,
                    f"entry '{name}' lies on a different filesystem")

            kind = EntryKind.of(described.st_mode)
            child_path = path + (name,)
            if kind is EntryKind.DIRECTORY:
                self.directory(name, descriptor, child_path, child_depth, described)
            elif kind is EntryKind.REGULAR:
                self.file(name, descriptor, child_path, described)
            else:
                raise TraversalRefused(
                    TraversalReason.UNEXPECTED_OBJECT,
                    f"entry '{name}' is a {kind.value} and cannot be part of a tree")


def walk_tree(root_fd: Any, *, maximum_depth: Any, maximum_entries: Any,
              maximum_files: Any, maximum_file_bytes: Any,
              maximum_total_bytes: Any) -> WalkedTree:
    """Every regular file beneath an already-open directory, or refuse.

    The root arrives as a descriptor because a name would be re-resolved on
    every use, and the whole point is that the tree beneath it is hostile: the
    directory that was checked and the directory that is walked must be the
    same one, and only a descriptor says so. Nothing here reopens the root, and
    the descriptor stays the caller's to close.

    Every bound is required and has no default. A default here would be this
    module holding a policy, and the policies that matter belong to the callers
    that can say why they chose them.

    The walk is complete or it is nothing. A refusal anywhere — one object of
    the wrong type, one file past a bound, one entry too deep — raises, and no
    partial tree is returned for a caller to be tempted by.
    """
    if not isinstance(root_fd, int) or isinstance(root_fd, bool):
        raise TraversalRefused(
            TraversalReason.INVALID_ROOT,
            "the root must be supplied as an already-open directory descriptor")
    bounds = {
        "maximum_depth": _require_bound(maximum_depth, "maximum_depth"),
        "maximum_entries": _require_bound(maximum_entries, "maximum_entries"),
        "maximum_files": _require_bound(maximum_files, "maximum_files"),
        "maximum_file_bytes": _require_bound(maximum_file_bytes, "maximum_file_bytes"),
        "maximum_total_bytes": _require_bound(maximum_total_bytes,
                                              "maximum_total_bytes"),
    }

    try:
        root = os.fstat(root_fd)
    except OSError as error:
        raise TraversalRefused(
            TraversalReason.INVALID_ROOT,
            f"the root descriptor could not be examined: {error}") from None
    if not stat.S_ISDIR(root.st_mode):
        raise TraversalRefused(TraversalReason.INVALID_ROOT,
                               "the root descriptor is not a directory")

    walk = _Walk(root_device=root.st_dev, **bounds)
    walk.level(root_fd, (), 0)
    return WalkedTree(files=tuple(walk.files),
                      directories=tuple(walk.directories),
                      entry_count=walk.entries,
                      total_bytes=walk.total_bytes)
