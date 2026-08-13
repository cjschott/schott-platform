"""Offline bootstrap primitives for the implementation-authority namespace.

**Operator tooling, never runtime.** These primitives allocate governed
identifiers and publish immutable authority. The adapter is a read-only
consumer that never allocates a `CIMP` or `CGEN` and has no repair authority,
so nothing on the execution path imports this module — a boundary the suite
enforces by scanning the runtime sources rather than by asking anyone to
remember it.

**Descriptor-relative, and free of production paths.** Every entry point takes
an already-opened directory descriptor. The absolute mapping —
`implementation-authority` and its control sibling — belongs to operator
integration and to the runbook, not to code: a path literal here would be one
more thing that has to agree with the host, and it would let this module be
pointed at production by accident.

**Counters are provisioned, never bootstrapped by whoever needs one.** An
allocator that could create itself could also restart itself, and a restarted
allocator hands out an identity that already means something. The format
follows the platform's existing counter precedent exactly — zero-padded ASCII
digits and a newline, incremented durably before the caller ever sees the
value, so a caller that dies holding an identifier cannot hand the same number
out twice. Gaps are permanent and expected.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§5, §5.1–§5.7.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import os
from typing import Iterator

from tools.capability.execution import canonical_json

# Control namespace, relative to the control root descriptor.
CIMP_COUNTER = "cimp-counter"
CGEN_COUNTER = "cgen-counter"
LIFECYCLE_LOCK = "implementation-lifecycle"
STAGING = "staging"

# Published namespace, relative to the authority root descriptor.
IMPLEMENTATIONS = "implementations"
GENERATIONS = "generations"
CURRENT_GENERATION = "current-generation"
GENERATION = "generation"
AUTHORITY_SET = "authority-set"

GENESIS_CGEN = "CGEN-000000000000"

CIMP_DIGITS = 6
CGEN_DIGITS = 12

_DIGITS = frozenset("0123456789")

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
_LOCK_FLAGS = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC

_COUNTER_MAXIMUM_BYTES = 64


class BootstrapError(ValueError):
    """Base for every refusal these primitives make."""


class ControlStateError(BootstrapError):
    """The operator control namespace is absent, malformed, or unsafe."""


class LockUnavailable(BootstrapError):
    """Another offline mutation already holds the lifecycle lock."""


class AlreadyInitialised(BootstrapError):
    """The published namespace already carries authority material.

    Deliberately distinct from a corruption error: genesis refusing because
    somebody already published is a correct outcome, not a finding about the
    namespace being unsound.
    """


class AllocatorExhausted(BootstrapError):
    """The counter has reached the last identifier its width can express."""


def _read_regular(name: str, dir_fd: int, maximum: int) -> bytes:
    """One regular file, opened no-follow and bounded.

    ``O_NOFOLLOW`` refuses a symlink at open rather than after resolving it, so
    a substituted control object is never read even once.
    """
    try:
        handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    except FileNotFoundError:
        raise
    except OSError as error:
        raise ControlStateError(f"{name} is unreadable: {error}") from None
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise ControlStateError(f"{name} is not a regular file")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(handle, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    finally:
        os.close(handle)
    body = b"".join(chunks)
    if len(body) > maximum:
        raise ControlStateError(f"{name} exceeds {maximum} bytes")
    return body


def _write_durable(name: str, body: bytes, dir_fd: int, mode: int = 0o600) -> None:
    """Create ``name`` exactly once, durably.

    ``O_EXCL`` is what makes create-once real: a second attempt fails in the
    kernel rather than in a check that could race with one.
    """
    handle = os.open(name, _CREATE_FLAGS, mode, dir_fd=dir_fd)
    try:
        written = 0
        while written < len(body):
            written += os.write(handle, body[written:])
        os.fsync(handle)
    finally:
        os.close(handle)
    os.fsync(dir_fd)


def _read_counter(name: str, digits: int, dir_fd: int) -> int:
    try:
        body = _read_regular(name, dir_fd, _COUNTER_MAXIMUM_BYTES)
    except FileNotFoundError:
        raise ControlStateError(
            f"{name} is absent and is never created on demand") from None
    if len(body) != digits + 1 or not body.endswith(b"\n"):
        raise ControlStateError(f"{name} is not {digits} digits and a newline")
    text = body[:digits].decode("ascii", errors="replace")
    if set(text) - _DIGITS:
        raise ControlStateError(f"{name} is not {digits} ASCII digits")
    return int(text)


def _advance(name: str, digits: int, dir_fd: int) -> int:
    """Increment the counter durably and return the new ordinal.

    The counter is persisted **before** the caller sees the value, which is
    what burns an identifier: a caller that dies between this returning and the
    identifier being used leaves a permanent gap rather than a number that gets
    handed out again.
    """
    current = _read_counter(name, digits, dir_fd)
    maximum = 10 ** digits - 1
    if current >= maximum:
        raise AllocatorExhausted(f"{name} is exhausted at {current}")
    nxt = current + 1
    temporary = f".{name}.{nxt:0{digits}d}"
    with contextlib.suppress(FileNotFoundError):
        os.unlink(temporary, dir_fd=dir_fd)
    _write_durable(temporary, f"{nxt:0{digits}d}\n".encode("ascii"), dir_fd)
    os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    os.fsync(dir_fd)
    return nxt


def provision_control_state(control_fd: int) -> None:
    """Create the counters and the staging root, exactly once.

    Both counters start at zero so that the first allocation returns ordinal
    one. That is also what keeps ``CIMP-000000`` and ``CGEN-000000000000``
    unreachable from the allocators: they are never emitted and then filtered,
    they are simply never produced.
    """
    for name, digits in ((CIMP_COUNTER, CIMP_DIGITS), (CGEN_COUNTER, CGEN_DIGITS)):
        try:
            _write_durable(name, f"{0:0{digits}d}\n".encode("ascii"), control_fd)
        except FileExistsError:
            raise ControlStateError(
                f"{name} already exists; a counter is never re-provisioned "
                "over a live one") from None
    try:
        os.mkdir(STAGING, 0o700, dir_fd=control_fd)
    except FileExistsError:
        raise ControlStateError(f"{STAGING} already exists") from None
    os.fsync(control_fd)


def allocate_cimp(control_fd: int) -> str:
    """The next governed `CIMP`, or refuse."""
    return f"CIMP-{_advance(CIMP_COUNTER, CIMP_DIGITS, control_fd):0{CIMP_DIGITS}d}"


def allocate_cgen(control_fd: int) -> str:
    """The next governed normal `CGEN`, or refuse.

    Genesis is a ceremony rather than an allocation, so this never returns it
    and never consults the published namespace to decide what comes next.
    """
    return f"CGEN-{_advance(CGEN_COUNTER, CGEN_DIGITS, control_fd):0{CGEN_DIGITS}d}"


@contextlib.contextmanager
def implementation_lifecycle_lock(control_fd: int) -> Iterator[None]:
    """Serialise offline authority mutation, or refuse immediately.

    Non-blocking on purpose. An operator ceremony that quietly waited on
    another one would look like a slow command and finish in an order nobody
    chose; refusing says which of the two is already running.

    Runtime readers never take this. They rely on immutable published objects
    and one atomic pointer, so there is no ordering to establish against the
    coordinator's capacity and quarantine locks — those live under a different
    root and are never held by this process.
    """
    try:
        handle = os.open(LIFECYCLE_LOCK, _LOCK_FLAGS, 0o600, dir_fd=control_fd)
    except OSError as error:
        raise ControlStateError(
            f"the {LIFECYCLE_LOCK} lock is unusable: {error}") from None
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise ControlStateError(f"{LIFECYCLE_LOCK} is not a regular file")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise LockUnavailable(
                "another offline authority mutation holds "
                f"{LIFECYCLE_LOCK}") from None
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        os.close(handle)


def _require_absent(name: str, dir_fd: int) -> None:
    """Refuse if anything at all occupies ``name``.

    ``os.lstat`` rather than ``os.path.exists`` so a dangling symlink counts as
    occupied: the question is whether somebody has already put something here,
    not whether it resolves.
    """
    try:
        os.lstat(name, dir_fd=dir_fd)
    except FileNotFoundError:
        return
    raise AlreadyInitialised(f"{name} already exists")


def _empty_directory(name: str, dir_fd: int) -> None:
    """Create ``name`` if absent; require it present, real, and empty."""
    try:
        os.mkdir(name, 0o750, dir_fd=dir_fd)
        os.fsync(dir_fd)
        return
    except FileExistsError:
        pass
    status = os.lstat(name, dir_fd=dir_fd)
    if (status.st_mode & 0o170000) != 0o040000:
        raise BootstrapError(f"{name} is not a directory")
    handle = os.open(name, _DIR_FLAGS, dir_fd=dir_fd)
    try:
        with os.scandir(handle) as entries:
            for entry in entries:
                raise AlreadyInitialised(f"{name} already carries {entry.name}")
    finally:
        os.close(handle)


def _require_clean_staging(control_fd: int) -> int:
    """The staging root, open and empty, or refuse.

    Residue means an earlier ceremony was interrupted. It is never removed
    here: discarding somebody else's unfinished work is an explicit recovery
    action, not something a routine primitive does on the way past.
    """
    try:
        handle = os.open(STAGING, _DIR_FLAGS, dir_fd=control_fd)
    except FileNotFoundError:
        raise ControlStateError(f"{STAGING} is absent") from None
    except OSError as error:
        raise ControlStateError(f"{STAGING} is unusable: {error}") from None
    try:
        with os.scandir(handle) as entries:
            for entry in entries:
                os.close(handle)
                raise BootstrapError(
                    f"{STAGING} carries unresolved material ({entry.name}); "
                    "an explicit recovery action must dispose of it first")
    except BootstrapError:
        raise
    except OSError as error:
        os.close(handle)
        raise ControlStateError(f"{STAGING} is unreadable: {error}") from None
    return handle


def initialise_genesis(authority_fd: int, control_fd: int) -> str:
    """Publish the genesis generation with an empty authority set.

    Genesis is explicit because the alternative is a runtime that decides an
    absent namespace means an empty one. Those are different facts: an
    uninitialised host has never been provisioned, and a genesis namespace has
    been provisioned and admits nothing. Only the second may be read as
    authority, and only an operator may create it.

    Nothing here interprets authority. The ceremony builds the records, stages
    them, publishes them, and then asks the **normal reader** whether the
    result is valid — so a genesis the runtime would reject cannot be reported
    as successful.
    """
    # Imported here rather than at module scope so the runtime reader is used
    # exactly as the runtime uses it, and so this module's own import graph
    # cannot be mistaken for the execution path's.
    from tools.capability.execution.implementation_authority import (
        NamespaceState, current_generation)

    with implementation_lifecycle_lock(control_fd):
        # Control state must be sound before anything is written, and reading
        # both counters is how that is proven rather than assumed.
        _read_counter(CIMP_COUNTER, CIMP_DIGITS, control_fd)
        _read_counter(CGEN_COUNTER, CGEN_DIGITS, control_fd)

        _require_absent(CURRENT_GENERATION, authority_fd)
        _empty_directory(IMPLEMENTATIONS, authority_fd)
        _empty_directory(GENERATIONS, authority_fd)
        staging_fd = _require_clean_staging(control_fd)
        try:
            authority_set = canonical_json.serialise({"entries": []})
            generation = canonical_json.serialise({
                "cgen": GENESIS_CGEN,
                "predecessor_cgen": None,
                "predecessor_generation_digest": None,
                "authority_set_digest": hashlib.sha256(authority_set).hexdigest(),
            })

            os.mkdir(GENESIS_CGEN, 0o750, dir_fd=staging_fd)
            staged_fd = os.open(GENESIS_CGEN, _DIR_FLAGS, dir_fd=staging_fd)
            try:
                _write_durable(AUTHORITY_SET, authority_set, staged_fd, 0o440)
                _write_durable(GENERATION, generation, staged_fd, 0o440)
                # Read the staged bytes back before publishing them, so what
                # becomes immutable is what was verified rather than what was
                # intended.
                if _read_regular(AUTHORITY_SET, staged_fd, 4096) != authority_set:
                    raise BootstrapError("the staged authority set did not verify")
                if _read_regular(GENERATION, staged_fd, 4096) != generation:
                    raise BootstrapError("the staged generation did not verify")
            finally:
                os.close(staged_fd)

            generations_fd = os.open(GENERATIONS, _DIR_FLAGS, dir_fd=authority_fd)
            try:
                os.rename(GENESIS_CGEN, GENESIS_CGEN,
                          src_dir_fd=staging_fd, dst_dir_fd=generations_fd)
                os.fsync(generations_fd)
            finally:
                os.close(generations_fd)
        finally:
            os.close(staging_fd)

        pointer = canonical_json.serialise({
            "cgen": GENESIS_CGEN,
            "generation_digest": hashlib.sha256(generation).hexdigest(),
        })
        temporary = f".{CURRENT_GENERATION}.genesis"
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary, dir_fd=authority_fd)
        _write_durable(temporary, pointer, authority_fd, 0o440)
        os.rename(temporary, CURRENT_GENERATION,
                  src_dir_fd=authority_fd, dst_dir_fd=authority_fd)
        os.fsync(authority_fd)

        published = current_generation(authority_fd)
        if published.cgen != GENESIS_CGEN:
            raise BootstrapError(f"genesis published {published.cgen}")
        if published.state is not NamespaceState.VALID:
            raise BootstrapError(f"genesis is not valid: {published.state}")
        if published.pending or published.entries or published.eligible_cimps:
            raise BootstrapError("genesis published a non-empty authority set")
        return GENESIS_CGEN
