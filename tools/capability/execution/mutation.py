"""The CMUT durability substrate for the ENG-0005 first adapter.

**One CMUT authorises at most one installation attempt.** That is the whole
design. An interrupted mutation can be *learned about* — recovery can prove the
committed bytes are present, or prove they are absent — but it is never
replayed, because a replay is a second attempt wearing the first one's
authority. Retrying is a new CMUT, allocated by whoever still has the right to
ask.

**The foundational layer is exempt from itself.** CMUT records protect
higher-level mutations; nothing allocates a CMUT to protect the CMUT counter,
intent, or outcome. Recursive identities would need their own recovery, which
would need identities, and so on. These records use strict create-once
semantics and exact-byte commitments instead.

**Exact bytes or nothing.** Recovery succeeds only when the installed target
hashes to the digest committed *before* installation began. A different but
perfectly valid record is an integrity failure, not a near-miss: it means
something other than this mutation wrote there, and no field-by-field
comparison can make that safe.

**No pathname is authority.** Targets are closed identities, every child name
is constructed here from canonical grammar, and every operation is
descriptor-relative with ``O_NOFOLLOW``.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §21.
"""

from __future__ import annotations

import dataclasses
import enum
import hashlib
import os
from typing import Any

from . import canonical_json
from .backing_store import RootDescriptor
from .types import Classification

CMUT_COUNTER = "cmut-counter"
FIRST_CMUT = "CMUT-000000000001"

_MUTATIONS = "mutations"
_STATE = "state"
_INTENT = "intent"
_OUTCOME = "outcome"

_COUNTER_DIGITS = 12
_MAXIMUM_ORDINAL = 10 ** _COUNTER_DIGITS - 1
_MAXIMUM_RECORD_BYTES = 2 * 1024 * 1024
_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)


class MutationError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class MutationJournalIntegrityFailure(MutationError):
    """Foundational CMUT state cannot be trusted."""

    classification = Classification.MUTATION_JOURNAL_INTEGRITY_FAILURE


class CounterExhausted(MutationError):
    """The allocator reached its last identity.

    Not a journal integrity failure: the journal is intact, there is simply
    nothing left to allocate. It fails closed rather than wrapping, because a
    wrapped identity would silently alias a mutation that already happened.
    """


class AlreadyInstalled(MutationError):
    """This CMUT has already spent its single installation attempt."""


@enum.unique
class TargetKind(enum.Enum):
    """The closed set of things a mutation may install."""

    EXECUTION_STATE = "execution-state"


_TARGET_DIRECTORY = {TargetKind.EXECUTION_STATE: _STATE}


def _is_cinv(name: str) -> bool:
    return (len(name) == 11 and name.startswith("CINV-")
            and set(name[5:]) <= _DIGITS)


_TARGET_GRAMMAR = {TargetKind.EXECUTION_STATE: _is_cinv}


@dataclasses.dataclass(frozen=True)
class MutationTarget:
    """A closed target identity.

    Not a path and not convertible to one by a caller. The kind selects a
    directory this module knows, and the name must satisfy that kind's
    grammar — so traversal, absolute paths, and unvalidated components are
    rejected at construction rather than sanitised later.
    """

    kind: TargetKind
    name: str

    def __post_init__(self) -> None:
        if not isinstance(self.kind, TargetKind):
            raise ValueError("target kind must be a TargetKind")
        grammar = _TARGET_GRAMMAR[self.kind]
        if not isinstance(self.name, str) or not grammar(self.name):
            raise ValueError(f"{self.name!r} is not a valid {self.kind.value} name")

    @property
    def directory(self) -> str:
        return _TARGET_DIRECTORY[self.kind]


@dataclasses.dataclass(frozen=True)
class UnknownOutcome:
    """An intent with no outcome, and what recovery could prove about it.

    ``proven`` records whether the question was actually answered. Absence is
    only reported when absence is demonstrable; anything ambiguous raises
    instead of arriving here with a guess attached.
    """

    cmut: str
    target_kind: str
    target_name: str
    expected_sha256: str
    installed: bool
    proven: bool


def _is_cmut(name: str) -> bool:
    return (len(name) == 17 and name.startswith("CMUT-")
            and set(name[5:]) <= _DIGITS)


def _cmut_for(ordinal: int) -> str:
    return f"CMUT-{ordinal:012d}"


def _read_file(name: str, dir_fd: int, maximum: int) -> bytes:
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise MutationJournalIntegrityFailure(f"{name} is not a regular file")
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
        raise MutationJournalIntegrityFailure(f"{name} exceeds {maximum} bytes")
    return body


def _write_durable(name: str, body: bytes, dir_fd: int) -> None:
    """Create ``name`` exactly once, durably.

    ``O_EXCL`` is what makes create-once real: a second attempt fails in the
    kernel rather than in a check that could race.
    """
    handle = os.open(name, _CREATE_FLAGS, 0o600, dir_fd=dir_fd)
    try:
        written = 0
        while written < len(body):
            written += os.write(handle, body[written:])
        os.fsync(handle)
    finally:
        os.close(handle)
    os.fsync(dir_fd)


def _parse(body: bytes, what: str) -> dict[str, Any]:
    try:
        return canonical_json.parse(body, maximum_bytes=_MAXIMUM_RECORD_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise MutationJournalIntegrityFailure(
            f"{what} is not canonical: {error}") from None


def _open_dir(name: str, dir_fd: int) -> int:
    return os.open(name, _DIR_FLAGS, dir_fd=dir_fd)


class Mutation:
    """Durable, at-most-once installation of one canonical target."""

    def __init__(self, root: RootDescriptor) -> None:
        self._root = root

    # -- allocator ---------------------------------------------------------

    def _read_counter(self) -> int:
        try:
            body = _read_file(CMUT_COUNTER, self._root.fd, 64)
        except FileNotFoundError:
            raise MutationJournalIntegrityFailure(
                "the CMUT counter is absent and cannot be created at runtime"
            ) from None
        except OSError as error:
            raise MutationJournalIntegrityFailure(
                f"the CMUT counter is unreadable: {error}") from None
        if len(body) != _COUNTER_DIGITS + 1 or not body.endswith(b"\n"):
            raise MutationJournalIntegrityFailure(
                "the CMUT counter is not 12 digits followed by a newline")
        digits = body[:_COUNTER_DIGITS].decode("ascii", errors="replace")
        if set(digits) - _DIGITS:
            raise MutationJournalIntegrityFailure(
                "the CMUT counter is not 12 ASCII digits")
        return int(digits)

    def _highest_recorded(self) -> int:
        """The largest CMUT that demonstrably exists on disk.

        Used as a rollback witness: a counter standing below a mutation that
        already happened would hand out an identity twice.
        """
        highest = 0
        try:
            base = _open_dir(_MUTATIONS, self._root.fd)
        except FileNotFoundError:
            return 0
        try:
            with os.scandir(base) as entries:
                for entry in entries:
                    if not _is_cmut(entry.name):
                        raise MutationJournalIntegrityFailure(
                            f"{entry.name} is not a CMUT record")
                    highest = max(highest, int(entry.name[5:]))
        finally:
            os.close(base)
        return highest

    def _allocate(self) -> str:
        current = self._read_counter()
        recorded = self._highest_recorded()
        if current < recorded:
            raise MutationJournalIntegrityFailure(
                f"the CMUT counter stands at {current} behind recorded "
                f"{recorded}: rollback")
        if current >= _MAXIMUM_ORDINAL:
            raise CounterExhausted("the CMUT allocator is exhausted")

        nxt = current + 1
        body = f"{nxt:0{_COUNTER_DIGITS}d}\n".encode("ascii")
        temporary = f".{CMUT_COUNTER}.{nxt:012d}"
        _write_durable(temporary, body, self._root.fd)
        os.rename(temporary, CMUT_COUNTER,
                  src_dir_fd=self._root.fd, dst_dir_fd=self._root.fd)
        os.fsync(self._root.fd)
        return _cmut_for(nxt)

    # -- protocol ----------------------------------------------------------

    def _write_intent(self, cmut: str, target: MutationTarget,
                      schema_type: str, expected_sha256: str) -> None:
        base = _open_dir(_MUTATIONS, self._root.fd)
        try:
            try:
                os.mkdir(cmut, 0o700, dir_fd=base)
            except FileExistsError:
                pass
            os.fsync(base)
            handle = _open_dir(cmut, base)
            try:
                _write_durable(_INTENT, canonical_json.serialise({
                    "cmut": cmut,
                    "target_kind": target.kind.value,
                    "target_name": target.name,
                    "schema_type": schema_type,
                    "expected_sha256": expected_sha256,
                }), handle)
            finally:
                os.close(handle)
        finally:
            os.close(base)

    def begin(self, target: MutationTarget, *, schema_type: str,
              expected_sha256: str) -> str:
        """Allocate a CMUT and durably record the intent.

        The byte commitment exists on disk before any installation begins,
        which is what lets recovery later distinguish "our bytes" from "some
        bytes".
        """
        if not isinstance(target, MutationTarget):
            raise MutationError("target must be a MutationTarget")
        if len(expected_sha256) != 64 or set(expected_sha256) - _HEX:
            raise MutationError("expected_sha256 must be a SHA-256 hex digest")
        self._root.reverify()
        cmut = self._allocate()
        self._write_intent(cmut, target, schema_type, expected_sha256)
        return cmut

    def _intent(self, cmut: str) -> dict[str, Any]:
        base = _open_dir(_MUTATIONS, self._root.fd)
        try:
            handle = _open_dir(cmut, base)
            try:
                return _parse(_read_file(_INTENT, handle, _MAXIMUM_RECORD_BYTES),
                              f"{cmut} intent")
            finally:
                os.close(handle)
        finally:
            os.close(base)

    def install(self, cmut: str, body: bytes) -> None:
        """The single installation attempt this CMUT authorises."""
        if not _is_cmut(cmut):
            raise MutationError(f"{cmut!r} is not a CMUT identity")
        intent = self._intent(cmut)
        if hashlib.sha256(body).hexdigest() != intent["expected_sha256"]:
            raise MutationJournalIntegrityFailure(
                f"{cmut} bytes do not match the committed digest")

        self._root.reverify()
        kind = TargetKind(intent["target_kind"])
        target = MutationTarget(kind=kind, name=intent["target_name"])
        directory = _open_dir(target.directory, self._root.fd)
        try:
            temporary = f".{target.name}.{cmut}"
            try:
                _write_durable(temporary, body, directory)
            except FileExistsError:
                raise AlreadyInstalled(
                    f"{cmut} already attempted installation") from None
            try:
                os.stat(target.name, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                os.unlink(temporary, dir_fd=directory)
                raise AlreadyInstalled(f"{target.name} is already installed")
            os.rename(temporary, target.name,
                      src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            os.close(directory)
        self._root.reverify()

    def commit(self, cmut: str) -> None:
        """Record the immutable outcome, completing the mutation."""
        if not _is_cmut(cmut):
            raise MutationError(f"{cmut!r} is not a CMUT identity")
        self._root.reverify()
        base = _open_dir(_MUTATIONS, self._root.fd)
        try:
            handle = _open_dir(cmut, base)
            try:
                _write_durable(_OUTCOME, canonical_json.serialise({
                    "cmut": cmut, "installed": True,
                }), handle)
            finally:
                os.close(handle)
        finally:
            os.close(base)

    # -- recovery ----------------------------------------------------------

    @staticmethod
    def recover(root_fd: int) -> tuple[UnknownOutcome, ...]:
        """Every intent with no outcome, and what can be proven about it.

        Observation only. Nothing here installs, repairs, or replays; a caller
        that wants the mutation to happen must allocate a new CMUT.
        """
        unknown: list[UnknownOutcome] = []
        try:
            base = _open_dir(_MUTATIONS, root_fd)
        except FileNotFoundError:
            return ()
        try:
            names = []
            with os.scandir(base) as entries:
                for entry in entries:
                    if not _is_cmut(entry.name):
                        raise MutationJournalIntegrityFailure(
                            f"{entry.name} is not a CMUT record")
                    names.append(entry.name)
            for cmut in sorted(names):
                handle = _open_dir(cmut, base)
                try:
                    intent = _parse(
                        _read_file(_INTENT, handle, _MAXIMUM_RECORD_BYTES),
                        f"{cmut} intent")
                    try:
                        os.stat(_OUTCOME, dir_fd=handle, follow_symlinks=False)
                    except FileNotFoundError:
                        pass
                    else:
                        continue
                finally:
                    os.close(handle)

                for field in ("cmut", "target_kind", "target_name",
                              "schema_type", "expected_sha256"):
                    if field not in intent:
                        raise MutationJournalIntegrityFailure(
                            f"{cmut} intent is missing {field!r}")
                if intent["cmut"] != cmut:
                    raise MutationJournalIntegrityFailure(
                        f"{cmut} intent declares {intent['cmut']!r}")

                try:
                    kind = TargetKind(intent["target_kind"])
                    target = MutationTarget(kind=kind, name=intent["target_name"])
                except ValueError as error:
                    raise MutationJournalIntegrityFailure(
                        f"{cmut} intent names an invalid target: {error}") from None

                installed = Mutation._probe(root_fd, target,
                                            intent["expected_sha256"], cmut)
                unknown.append(UnknownOutcome(
                    cmut=cmut,
                    target_kind=intent["target_kind"],
                    target_name=intent["target_name"],
                    expected_sha256=intent["expected_sha256"],
                    installed=installed,
                    proven=True,
                ))
        finally:
            os.close(base)
        return tuple(unknown)

    @staticmethod
    def _probe(root_fd: int, target: MutationTarget, expected: str,
               cmut: str) -> bool:
        directory = _open_dir(target.directory, root_fd)
        try:
            try:
                body = _read_file(target.name, directory, _MAXIMUM_RECORD_BYTES)
            except FileNotFoundError:
                return False
        finally:
            os.close(directory)
        if hashlib.sha256(body).hexdigest() != expected:
            raise MutationJournalIntegrityFailure(
                f"{cmut} target holds bytes other than the committed digest")
        _parse(body, f"{cmut} target")
        return True
