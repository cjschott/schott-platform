"""Governed package validation for the ENG-0005 first adapter.

**Bounds are enforced while walking, not after.** A tree is refused the moment
it exceeds a limit, so an oversized package is never fully read into memory to
discover that it was oversized. The count, the aggregate, and the per-file size
all bind during enumeration.

**Only Python source and package-local data.** No native extension, no ELF, no
wheel, no interpreter, no executable helper — because the execution contract
runs one interpreter on one entrypoint, and anything else in the tree is either
unreachable or a way to reach something the contract never granted. An
executable mode bit is refused for the same reason: it is a request the
contract has no answer to.

**Nothing is followed.** Every entry is inspected with ``O_NOFOLLOW`` and
symlinks are refused rather than resolved, so a package cannot name its way out
of its own tree. Hard-linked members are refused too: an aliased inode means
the bytes validated here can be changed through a name this module never saw.

**The descriptor is the package.** Validation reads an already-open directory
descriptor and never resolves a package pathname, so replacing the tree's name
after it was opened changes nothing about what was validated.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §8.
"""

from __future__ import annotations

import dataclasses
import hashlib
import os
import stat

MAXIMUM_ENTRIES = 1024
MAXIMUM_AGGREGATE_BYTES = 64 * 1024 * 1024
MAXIMUM_FILE_BYTES = 16 * 1024 * 1024

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY

# Suffixes that name compiled or packaged native content. Checked alongside the
# content sniff below, because either one alone is trivially evaded.
_FORBIDDEN_SUFFIXES = (".so", ".pyd", ".dll", ".dylib", ".whl", ".egg", ".a",
                       ".o", ".pyc", ".pyo", ".zip", ".tar", ".gz")
_FORBIDDEN_MAGIC = (
    b"\x7fELF",              # ELF
    b"PK\x03\x04",           # zip, wheel, egg
    b"\xcf\xfa\xed\xfe",     # Mach-O
    b"MZ",                   # PE
    b"\x1f\x8b",             # gzip
    b"\x03\xf3\r\n",         # CPython bytecode
)
_EXECUTABLE_BITS = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH


class PackageError(ValueError):
    """Base for every refusal this module makes."""


class PackageBoundExceeded(PackageError):
    """The tree is larger than the governed package contract permits."""


class ForbiddenContent(PackageError):
    """The tree holds something the execution contract cannot run."""


class InvalidEntrypoint(PackageError):
    """The governed entrypoint is not one relative `.py` file in this tree."""


@dataclasses.dataclass(frozen=True)
class PackageEntry:
    """One validated regular file."""

    relative_path: str
    size: int
    digest: str


@dataclasses.dataclass(frozen=True)
class PackageBinding:
    """A validated package tree and the identity derived from it.

    ``digest`` covers the whole manifest — every path, size, and content digest
    in sorted order — so a package that gained, lost, or altered a file cannot
    present the same identity.
    """

    entries: tuple[PackageEntry, ...]
    entry_count: int
    aggregate_bytes: int
    entrypoint: str
    digest: str


class _Budget:
    """The bounds, spent as the walk proceeds."""

    def __init__(self) -> None:
        self.entries = 0
        self.aggregate = 0

    def count(self, relative: str) -> None:
        self.entries += 1
        if self.entries > MAXIMUM_ENTRIES:
            raise PackageBoundExceeded(
                f"more than {MAXIMUM_ENTRIES} package entries at {relative!r}")

    def add(self, size: int, relative: str) -> None:
        if size > MAXIMUM_FILE_BYTES:
            raise PackageBoundExceeded(
                f"{relative!r} is {size} bytes, over the "
                f"{MAXIMUM_FILE_BYTES} byte per-file bound")
        self.aggregate += size
        if self.aggregate > MAXIMUM_AGGREGATE_BYTES:
            raise PackageBoundExceeded(
                f"package exceeds {MAXIMUM_AGGREGATE_BYTES} aggregate bytes")


def _read_member(name: str, dir_fd: int, relative: str, budget: _Budget) -> bytes:
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        status = os.fstat(handle)
        if not stat.S_ISREG(status.st_mode):
            raise ForbiddenContent(f"{relative!r} is not a regular file")
        if status.st_nlink != 1:
            raise ForbiddenContent(
                f"{relative!r} is hard-linked: its bytes are reachable "
                "through a name this validation never saw")
        if status.st_mode & _EXECUTABLE_BITS:
            raise ForbiddenContent(f"{relative!r} is executable")
        budget.add(status.st_size, relative)
        chunks: list[bytes] = []
        remaining = MAXIMUM_FILE_BYTES + 1
        while remaining > 0:
            chunk = os.read(handle, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(handle)
    body = b"".join(chunks)
    if len(body) > MAXIMUM_FILE_BYTES:
        raise PackageBoundExceeded(f"{relative!r} exceeds the per-file bound")
    return body


def _check_content(relative: str, body: bytes) -> None:
    lowered = relative.lower()
    for suffix in _FORBIDDEN_SUFFIXES:
        if lowered.endswith(suffix):
            raise ForbiddenContent(
                f"{relative!r} has a forbidden suffix {suffix!r}")
    for magic in _FORBIDDEN_MAGIC:
        if body.startswith(magic):
            raise ForbiddenContent(
                f"{relative!r} begins with forbidden binary content")


def _walk(dir_fd: int, prefix: str, budget: _Budget,
          entries: list[PackageEntry]) -> None:
    with os.scandir(dir_fd) as listing:
        found = sorted(listing, key=lambda e: e.name)
    for entry in found:
        relative = f"{prefix}{entry.name}"
        budget.count(relative)
        if entry.is_symlink():
            raise ForbiddenContent(f"{relative!r} is a symlink")
        if entry.is_dir(follow_symlinks=False):
            child = os.open(entry.name, _DIR_FLAGS, dir_fd=dir_fd)
            try:
                _walk(child, f"{relative}/", budget, entries)
            finally:
                os.close(child)
            continue
        if not entry.is_file(follow_symlinks=False):
            raise ForbiddenContent(
                f"{relative!r} is neither a regular file nor a directory")
        body = _read_member(entry.name, dir_fd, relative, budget)
        _check_content(relative, body)
        entries.append(PackageEntry(
            relative_path=relative, size=len(body),
            digest=hashlib.sha256(body).hexdigest()))


def _validate_entrypoint(entrypoint: str, entries: tuple[PackageEntry, ...]) -> str:
    if not isinstance(entrypoint, str) or not entrypoint:
        raise InvalidEntrypoint("the entrypoint must be a relative path")
    if entrypoint.startswith("/"):
        raise InvalidEntrypoint("the entrypoint must not be absolute")
    if not entrypoint.endswith(".py"):
        raise InvalidEntrypoint("the entrypoint must be a .py file")
    parts = entrypoint.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise InvalidEntrypoint("the entrypoint must not contain traversal")
    if entrypoint not in {entry.relative_path for entry in entries}:
        raise InvalidEntrypoint(
            f"{entrypoint!r} is not a validated file in this package")
    return entrypoint


def validate_package(descriptor: int, *, entrypoint: str) -> PackageBinding:
    """Validate the package tree on ``descriptor`` and bind its identity.

    ``descriptor`` is an already-open directory descriptor: obtaining it safely
    is the caller's authority, and this module never learns a pathname it could
    reopen.
    """
    budget = _Budget()
    entries: list[PackageEntry] = []
    _walk(descriptor, "", budget, entries)
    ordered = tuple(sorted(entries, key=lambda e: e.relative_path))
    resolved = _validate_entrypoint(entrypoint, ordered)

    manifest = hashlib.sha256()
    for entry in ordered:
        manifest.update(entry.relative_path.encode("utf-8"))
        manifest.update(b"\0")
        manifest.update(str(entry.size).encode("ascii"))
        manifest.update(b"\0")
        manifest.update(entry.digest.encode("ascii"))
        manifest.update(b"\0")

    return PackageBinding(
        entries=ordered,
        entry_count=len(ordered),
        aggregate_bytes=budget.aggregate,
        entrypoint=resolved,
        digest=manifest.hexdigest(),
    )
