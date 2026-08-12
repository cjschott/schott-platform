"""Administrative reconciliation and CADM for the ENG-0005 first adapter.

This is the component an operator drives, which makes it the one most worth
widening. So it is built to bind existing operations rather than to own new
ones: every verb below reaches something T15 or T16 already implemented, under
that operation's own limits and its own failure vocabulary. There is no shell,
no Podman argv, no caller path, no caller-supplied identity, no repair, and no
force. **Administrative authority equals the authority of what it dispatches,
and never more.**

**The verb set is closed and short.** Thirteen mutating verbs and one
inspection, exactly §20's list. A generic delete or cleanup verb would make
every narrowing above it decorative, so none exists and the suite asserts the
whole set rather than sampling it.

**Intent, one attempt, outcome — in that order, each durable, each
create-once.** A crash between intent and outcome leaves
`intent-with-unknown-outcome`, which is reported and never resolved by this
module. Replay is the failure mode this ordering exists to prevent: a second
attempt under the first authorisation would be an operator decision nobody
made. A retry is a fresh authentication and a fresh `CADM`.

**Destruction is narrower than discovery.** It may target only an immutable
container ID already durably bound to the condition being reconciled, read from
the create-once binding record rather than accepted from the caller — an
identity handed in is an identity that cannot be checked. A name never
substitutes, an unstable collision carries no destruction authority at all, and
a target that has disappeared is recorded absent rather than retargeted at
whatever occupies the name now.

**Corruption blocks mutation globally, and inspection survives it.** An
unexpected object or a malformed record stops allocation and dispatch
everywhere, because the namespace that records what was done is the one thing
that cannot be partly trusted. Inspection stays available at any time, is
read-only, allocates no `CADM`, and commits its audit event before it will emit
a summary — a look that left no trace is a look that can be denied.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md``
§17 and §20.
"""

from __future__ import annotations

import dataclasses
import enum
import hashlib
import os
from typing import Any

from . import canonical_json
from . import cleanup as cleanup_module
from . import quarantine as quarantine_module
from . import state as state_module
from .backing_store import RootDescriptor
from .mutation import Mutation, MutationTarget, TargetKind
from .types import Classification

CADM_COUNTER = "cadm-counter"
ADMIN_RECORDS = "admin-records"
INSPECTION_AUDIT = "inspection-audit"
BINDINGS = "state"

INTENT = "intent"
OUTCOME = "outcome"
RECONCILIATIONS = "reconciliations"

RECORD_SCHEMA_VERSION = 1
BINDING_SCHEMA_VERSION = 1

_COUNTER_DIGITS = 6
_MAXIMUM_ORDINAL = 10 ** _COUNTER_DIGITS - 1
_SEQUENCE_DIGITS = 6
_MAXIMUM_SEQUENCE = 10 ** _SEQUENCE_DIGITS - 1
_DIGITS = frozenset("0123456789")
_HEX = frozenset("0123456789abcdef")

MAXIMUM_SCAN_ENTRIES = 10_000
MAXIMUM_SUMMARY_BYTES = 2 * 1024 * 1024
MAXIMUM_RECORD_BYTES = 64 * 1024

# The conditions a binding may be made for. Destruction is permitted only where
# the condition itself admits it, which is how "unstable collisions have no Kyri
# destruction authority" survives contact with an operator in a hurry.
CONDITION_EXECUTION = "execution"
CONDITION_COLLISION_STABLE = "container_name_collision_stable"
CONDITION_COLLISION_UNSTABLE = "container_name_collision_unstable"
CONDITION_START_UNKNOWN = "start_outcome_unknown"
CONDITION_LIFECYCLE_FAILURE = "lifecycle_integrity_failure"
CONDITION_STATE_LOST = "state_lost"

RESULT_DONE = "done"
RESULT_ABSENT = "target-absent"
RESULT_REFUSED = "refused"

_READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY
_CREATE_FLAGS = (os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC)


@enum.unique
class Verb(enum.Enum):
    """The closed §20 set. Nothing generic, and nothing added."""

    RETAIN = "retain"
    DESTROY = "destroy"
    RETAIN_RESIDUE = "retain-residue"
    RETRY_CLEANUP = "retry-cleanup"
    RETAIN_COLLISION = "retain-collision"
    DESTROY_COLLISION = "destroy-collision"
    RETAIN_START_UNKNOWN = "retain-start-unknown"
    DESTROY_START_UNKNOWN = "destroy-start-unknown"
    RETAIN_LIFECYCLE_FAILURE = "retain-lifecycle-failure"
    DESTROY_LIFECYCLE_FAILURE = "destroy-lifecycle-failure"
    ACKNOWLEDGE_STATE_LOST = "acknowledge-state-lost"
    RETAIN_QUARANTINE_INCOMPLETE = "retain-quarantine-incomplete"
    RETAIN_QUARANTINE_RESIDUE = "retain-quarantine-residue"
    INSPECT_ADMIN_INTEGRITY = "inspect-admin-integrity"


# Which verb may destroy, and the one condition each may destroy under. A verb
# absent from this mapping has no destruction authority whatsoever, and a verb
# present in it still refuses a binding made for a different condition.
_DESTROYS_UNDER = {
    Verb.DESTROY: CONDITION_EXECUTION,
    Verb.DESTROY_COLLISION: CONDITION_COLLISION_STABLE,
    Verb.DESTROY_START_UNKNOWN: CONDITION_START_UNKNOWN,
    Verb.DESTROY_LIFECYCLE_FAILURE: CONDITION_LIFECYCLE_FAILURE,
}


def is_mutating(verb: Any) -> bool:
    """Whether the verb needs a `CADM`. Only inspection does not."""
    if not isinstance(verb, Verb):
        raise AdminRefused("a Verb is required")
    return verb is not Verb.INSPECT_ADMIN_INTEGRITY


class AdminError(ValueError):
    """Base for every refusal this module makes."""

    classification: Classification | None = None


class AdminRefused(AdminError):
    """The request is not one administration may act on.

    No classification: an operator asking for something the verb does not
    permit has made a decision that was refused, which is not a condition the
    recorded state is in.
    """


class AdminIntegrityFailure(AdminError):
    """The administrative namespace cannot be trusted."""

    classification = Classification.ADMINISTRATIVE_RECORD_INTEGRITY_FAILURE


class AdminUnexpectedObject(AdminError):
    """Something that is not an administrative record is in the namespace."""

    classification = Classification.ADMINISTRATIVE_RECORD_UNEXPECTED_OBJECT


class AdminScanLimitExceeded(AdminError):
    """The namespace is larger than inspection may examine."""

    classification = Classification.ADMINISTRATIVE_INTEGRITY_SCAN_LIMIT_EXCEEDED


class AdminFindingsTruncated(AdminError):
    """The summary would exceed its canonical bound."""

    classification = Classification.ADMINISTRATIVE_INTEGRITY_FINDINGS_TRUNCATED


class InspectionAuditCommitFailed(AdminError):
    """The audit event did not commit, so the summary is withheld."""

    classification = Classification.INSPECTION_AUDIT_COMMIT_FAILED


@dataclasses.dataclass(frozen=True)
class Authorisation:
    """What the interactive-authenticated helper presents for one verb.

    Granted for exactly one verb. Carrying the verb rather than a general
    "authenticated" flag is what stops an authentication for `retain` from
    being spent on `destroy`.
    """

    verb: Verb
    operator: str


@dataclasses.dataclass(frozen=True)
class BoundTarget:
    """An immutable identity already durably bound to a condition."""

    cinv: str
    container_id: str | None
    condition: str


@dataclasses.dataclass(frozen=True)
class AdminContext:
    """The verified roots and the injected backend a dispatch may reach.

    A verb can touch nothing that is not in here, which is why the roots are
    descriptors that were verified elsewhere and never names assembled now.
    """

    root: RootDescriptor
    handoff: Any = None
    store: Any = None
    backend: Any = None


@dataclasses.dataclass(frozen=True)
class AdminOutcome:
    """What one administrative attempt did, and under which `CADM`."""

    cadm: str
    verb: Verb
    cinv: str
    target: str | None
    result: str
    classification: Classification | None


@dataclasses.dataclass(frozen=True)
class Summary:
    """A read-only, metadata-only view of the administrative namespace."""

    records: tuple[str, ...]
    entries_scanned: int
    unknown_outcomes: tuple[str, ...]
    classification: Classification | None
    blocked: bool


def _require_root(root: Any, what: str = "root") -> RootDescriptor:
    if not isinstance(root, RootDescriptor):
        raise AdminRefused(f"{what} must be a verified RootDescriptor")
    return root


def _is_cadm(name: str) -> bool:
    return (len(name) == 11 and name.startswith("CADM-")
            and set(name[5:]) <= _DIGITS)


def _cadm_for(ordinal: int) -> str:
    return f"CADM-{ordinal:0{_COUNTER_DIGITS}d}"


def _read_file(name: str, dir_fd: int, maximum: int) -> bytes:
    handle = os.open(name, _READ_FLAGS, dir_fd=dir_fd)
    try:
        status = os.fstat(handle)
        if not (status.st_mode & 0o170000) == 0o100000:
            raise AdminIntegrityFailure(f"{name} is not a regular file")
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
        raise AdminIntegrityFailure(f"{name} exceeds {maximum} bytes")
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


def _open_records(root: RootDescriptor) -> int:
    try:
        return os.open(ADMIN_RECORDS, _DIR_FLAGS, dir_fd=root.fd)
    except OSError as error:
        raise AdminIntegrityFailure(
            f"the administrative namespace is unusable: {error}") from None


def _scan_records(root: RootDescriptor) -> tuple[tuple[str, ...], int]:
    """Every `CADM` in the namespace, ordered, with every entry counted.

    Counts what is there rather than what belongs there: an unexpected object
    still consumes the ceiling, because the work of looking at it was still
    done and a ceiling that ignored it would not bound anything.
    """
    base = _open_records(root)
    names: list[str] = []
    scanned = 0
    try:
        with os.scandir(base) as entries:
            for entry in entries:
                scanned += 1
                if scanned > MAXIMUM_SCAN_ENTRIES:
                    raise AdminScanLimitExceeded(
                        f"more than {MAXIMUM_SCAN_ENTRIES} administrative entries")
                if not entry.is_dir(follow_symlinks=False):
                    raise AdminUnexpectedObject(
                        f"{entry.name} is not an administrative record directory")
                if not _is_cadm(entry.name):
                    raise AdminIntegrityFailure(
                        f"{entry.name} is not a CADM record")
                names.append(entry.name)
    finally:
        os.close(base)
    return tuple(sorted(names)), scanned


def _require_healthy(root: RootDescriptor) -> tuple[str, ...]:
    """Refuse every mutation while the namespace cannot be trusted."""
    names, _ = _scan_records(root)
    return names


def _read_counter(root: RootDescriptor) -> int:
    try:
        body = _read_file(CADM_COUNTER, root.fd, 64)
    except FileNotFoundError:
        raise AdminIntegrityFailure(
            "the CADM counter is absent and cannot be created at runtime"
        ) from None
    except OSError as error:
        raise AdminIntegrityFailure(
            f"the CADM counter is unreadable: {error}") from None
    if len(body) != _COUNTER_DIGITS + 1 or not body.endswith(b"\n"):
        raise AdminIntegrityFailure(
            f"the CADM counter is not {_COUNTER_DIGITS} digits and a newline")
    digits = body[:_COUNTER_DIGITS].decode("ascii", errors="replace")
    if set(digits) - _DIGITS:
        raise AdminIntegrityFailure(
            f"the CADM counter is not {_COUNTER_DIGITS} ASCII digits")
    return int(digits)


def allocate_cadm(root: Any) -> str:
    """Allocate the next `CADM`, or refuse.

    The counter is provisioned and never created here: a runtime that could
    bootstrap its own allocator could also restart it, and a restarted
    allocator hands out an identity that already means something. Gaps are
    permanent for the same reason — a reused number is a record that overwrites
    a decision somebody made.
    """
    verified = _require_root(root)
    recorded = _require_healthy(verified)

    current = _read_counter(verified)
    highest = max((int(name[5:]) for name in recorded), default=0)
    if current < highest:
        raise AdminIntegrityFailure(
            f"the CADM counter stands at {current} behind recorded {highest}: "
            "rollback")
    if current >= _MAXIMUM_ORDINAL:
        raise AdminRefused("the CADM allocator is exhausted")

    nxt = current + 1
    verified.reverify()
    body = f"{nxt:0{_COUNTER_DIGITS}d}\n".encode("ascii")
    temporary = f".{CADM_COUNTER}.{nxt:06d}"
    _write_durable(temporary, body, verified.fd)
    os.rename(temporary, CADM_COUNTER,
              src_dir_fd=verified.fd, dst_dir_fd=verified.fd)
    os.fsync(verified.fd)
    return _cadm_for(nxt)


def _record_directory(root: RootDescriptor, cadm: str, *,
                      create: bool = False) -> int:
    base = _open_records(root)
    try:
        if create:
            try:
                os.mkdir(cadm, 0o700, dir_fd=base)
            except FileExistsError:
                pass
            os.fsync(base)
        try:
            return os.open(cadm, _DIR_FLAGS, dir_fd=base)
        except OSError as error:
            raise AdminRefused(f"{cadm} has no administrative record: {error}") from None
    finally:
        os.close(base)


def record_intent(root: Any, cadm: Any, verb: Any, cinv: Any,
                  target: Any) -> None:
    """Durably record what is about to be attempted, exactly once."""
    verified = _require_root(root)
    if not isinstance(cadm, str) or not _is_cadm(cadm):
        raise AdminRefused(f"{cadm!r} is not a CADM identity")
    if not isinstance(verb, Verb):
        raise AdminRefused("a Verb is required")
    identity = state_module.validate_cinv(cinv)
    if target is not None and (not isinstance(target, str)
                               or len(target) != 64 or set(target) - _HEX):
        raise AdminRefused("a target must be a full immutable container identity")

    verified.reverify()
    handle = _record_directory(verified, cadm, create=True)
    try:
        _write_durable(INTENT, canonical_json.serialise({
            "cadm": cadm,
            "schema_version": RECORD_SCHEMA_VERSION,
            "verb": verb.value,
            "cinv": identity,
            "target": target,
        }), handle)
    except FileExistsError:
        raise AdminRefused(f"{cadm} already records an intent") from None
    finally:
        os.close(handle)


def record_outcome(root: Any, cadm: Any, result: Any, *,
                   classification: Any = None) -> None:
    """Durably record what happened, exactly once."""
    verified = _require_root(root)
    if not isinstance(cadm, str) or not _is_cadm(cadm):
        raise AdminRefused(f"{cadm!r} is not a CADM identity")
    if not isinstance(result, str) or not result:
        raise AdminRefused("an outcome result must be a non-empty string")
    if classification is not None and not isinstance(classification, Classification):
        raise AdminRefused("a classification must be a Classification")

    verified.reverify()
    handle = _record_directory(verified, cadm)
    try:
        _write_durable(OUTCOME, canonical_json.serialise({
            "cadm": cadm,
            "schema_version": RECORD_SCHEMA_VERSION,
            "result": result,
            "classification": None if classification is None else classification.value,
        }), handle)
    except FileExistsError:
        raise AdminRefused(f"{cadm} already records an outcome") from None
    finally:
        os.close(handle)


def record_reconciliation(root: Any, cadm: Any, note: Any) -> str:
    """Append one create-once reconciliation entry, and return its sequence.

    The sequence is derived from the entries that exist, not from a counter
    somebody keeps: a mutable per-`CADM` counter would be a second thing that
    could roll back, and it would disagree with the records at exactly the
    moment the records matter.
    """
    verified = _require_root(root)
    if not isinstance(cadm, str) or not _is_cadm(cadm):
        raise AdminRefused(f"{cadm!r} is not a CADM identity")
    if not isinstance(note, str) or not note:
        raise AdminRefused("a reconciliation note must be a non-empty string")

    verified.reverify()
    record = _record_directory(verified, cadm)
    try:
        try:
            os.mkdir(RECONCILIATIONS, 0o700, dir_fd=record)
        except FileExistsError:
            pass
        os.fsync(record)
        holder = os.open(RECONCILIATIONS, _DIR_FLAGS, dir_fd=record)
        try:
            highest = 0
            with os.scandir(holder) as entries:
                for entry in entries:
                    if (len(entry.name) != _SEQUENCE_DIGITS
                            or set(entry.name) - _DIGITS):
                        raise AdminIntegrityFailure(
                            f"{entry.name} is not a reconciliation sequence")
                    highest = max(highest, int(entry.name))
            if highest >= _MAXIMUM_SEQUENCE:
                raise AdminRefused(f"{cadm} has exhausted its reconciliations")
            sequence = f"{highest + 1:0{_SEQUENCE_DIGITS}d}"
            _write_durable(sequence, canonical_json.serialise({
                "cadm": cadm,
                "schema_version": RECORD_SCHEMA_VERSION,
                "sequence": sequence,
                "note": note,
            }), holder)
            return sequence
        finally:
            os.close(holder)
    finally:
        os.close(record)


def unknown_outcomes(root: Any) -> tuple[str, ...]:
    """Every `CADM` with an intent and no outcome.

    Reported and left alone. Resolving one would mean deciding what the
    side effect did without having seen it, and the whole point of recording
    the intent first was to be able to say honestly that nobody knows.
    """
    verified = _require_root(root)
    names = _require_healthy(verified)
    unknown: list[str] = []
    for name in names:
        handle = _record_directory(verified, name)
        try:
            entries = set(os.listdir(handle))
        finally:
            os.close(handle)
        if INTENT in entries and OUTCOME not in entries:
            unknown.append(name)
    return tuple(unknown)


def read_binding(root: Any, cinv: Any) -> BoundTarget | None:
    """The immutable identity durably bound to ``cinv``, or ``None``.

    Read rather than accepted. §20 permits destroying only an object already
    durably bound to the condition, and an identity supplied by the caller is
    exactly the thing that claim cannot be checked against.
    """
    verified = _require_root(root)
    identity = state_module.validate_cinv(cinv)
    try:
        base = os.open(BINDINGS, _DIR_FLAGS, dir_fd=verified.fd)
    except OSError as error:
        raise AdminIntegrityFailure(
            f"the binding namespace is unusable: {error}") from None
    try:
        body = _read_file(identity, base, MAXIMUM_RECORD_BYTES)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise AdminIntegrityFailure(
            f"the {identity} binding is unreadable: {error}") from None
    finally:
        os.close(base)

    try:
        record = canonical_json.parse(body, maximum_bytes=MAXIMUM_RECORD_BYTES)
    except canonical_json.CanonicalJSONError as error:
        raise AdminIntegrityFailure(
            f"the {identity} binding is not canonical: {error}") from None
    if record.get("cinv") != identity:
        raise AdminIntegrityFailure(
            f"the {identity} binding names a different invocation")
    container_id = record.get("container_id")
    if container_id is not None and (not isinstance(container_id, str)
                                     or len(container_id) != 64
                                     or set(container_id) - _HEX):
        raise AdminIntegrityFailure(
            f"the {identity} binding carries no full immutable identity")
    condition = record.get("condition")
    if not isinstance(condition, str) or not condition:
        raise AdminIntegrityFailure(f"the {identity} binding names no condition")
    return BoundTarget(cinv=identity, container_id=container_id,
                       condition=condition)


def _already_destroyed(root: RootDescriptor, cinv: str) -> bool:
    """Whether a destroying attempt for ``cinv`` already reached an outcome.

    One condition gets one destruction. A second attempt would either destroy
    something that is not the bound object any more, or record a second answer
    to a question that already has one. `retry-cleanup` is deliberately not
    subject to this — §19 grants it unlimited retries because each is a fresh
    authenticated decision and its side effect is idempotent.
    """
    for cadm in _require_healthy(root):
        handle = _record_directory(root, cadm)
        try:
            entries = set(os.listdir(handle))
            if INTENT not in entries or OUTCOME not in entries:
                continue
            intent = canonical_json.parse(
                _read_file(INTENT, handle, MAXIMUM_RECORD_BYTES),
                maximum_bytes=MAXIMUM_RECORD_BYTES)
            outcome = canonical_json.parse(
                _read_file(OUTCOME, handle, MAXIMUM_RECORD_BYTES),
                maximum_bytes=MAXIMUM_RECORD_BYTES)
        except canonical_json.CanonicalJSONError as error:
            raise AdminIntegrityFailure(
                f"{cadm} is not canonical: {error}") from None
        finally:
            os.close(handle)
        if (intent.get("cinv") == cinv
                and intent.get("verb") in {v.value for v in _DESTROYS_UNDER}
                and outcome.get("result") in (RESULT_DONE, RESULT_ABSENT)):
            return True
    return False


def _destroy(context: AdminContext, verb: Verb, binding: BoundTarget | None) -> str:
    """The one bounded side-effect a destroying verb authorises."""
    required = _DESTROYS_UNDER[verb]
    if binding is None:
        raise AdminRefused(
            f"{verb.value} has no durably bound target to destroy")
    if binding.condition != required:
        raise AdminRefused(
            f"{verb.value} may destroy only under {required}, and the binding "
            f"records {binding.condition}")
    if binding.container_id is None:
        raise AdminRefused(
            f"{verb.value} has no immutable identity bound to the condition")
    if context.backend is None:
        raise AdminRefused("no destruction backend was supplied")

    try:
        context.backend.destroy(binding.container_id)
    except LookupError:
        # Gone since authorisation. Recorded as absent, and emphatically not
        # retargeted: whatever holds that name now was created by somebody
        # else, for something else.
        return RESULT_ABSENT
    return RESULT_DONE


def _retry_cleanup(context: AdminContext, cinv: str) -> tuple[str, Any]:
    """Run T16's cleanup exactly as T16 runs it.

    No larger limits and no force mode: the operation is imported rather than
    reimplemented, so there is nowhere for a wider variant to live.
    """
    if context.handoff is None:
        raise AdminRefused("no handoff root was supplied")
    try:
        cleanup_module.cleanup(context.root, context.handoff, cinv)
    except cleanup_module.CleanupError as error:
        return RESULT_REFUSED, error.classification
    return RESULT_DONE, None


def _quarantine(context: AdminContext, verb: Verb, cinv: str) -> tuple[str, Any]:
    if context.store is None:
        raise AdminRefused("no quarantine store was supplied")
    reservation = quarantine_module.QuarantineReservation(
        cinv=cinv, reserved_bytes=quarantine_module.RESERVATION_BYTES)
    operation = (quarantine_module.seal_incomplete
                 if verb is Verb.RETAIN_QUARANTINE_INCOMPLETE
                 else quarantine_module.retain_residue)
    try:
        operation(context.root, context.store, reservation)
    except quarantine_module.QuarantineError as error:
        return RESULT_REFUSED, error.classification
    return RESULT_DONE, None


def perform(context: Any, authorisation: Any, cinv: Any) -> AdminOutcome:
    """Dispatch one authenticated administrative verb.

    Intent is durable before the attempt and the outcome is durable after it,
    with exactly one attempt in between. There is no parameter here for a
    container identity, a path, or a limit, and that absence is the design:
    everything the verb may touch it reaches through an operation that already
    knows its own bounds.
    """
    if not isinstance(context, AdminContext):
        raise AdminRefused("an AdminContext is required")
    if not isinstance(authorisation, Authorisation):
        raise AdminRefused("an interactive authorisation is required")
    verified = _require_root(context.root)
    identity = state_module.validate_cinv(cinv)
    verb = authorisation.verb
    if not isinstance(verb, Verb):
        raise AdminRefused("an authorisation must name a Verb")
    if not is_mutating(verb):
        raise AdminRefused(
            "inspect-admin-integrity is not dispatched as a mutation")

    _require_healthy(verified)
    binding = read_binding(verified, identity)

    target = None
    if verb in _DESTROYS_UNDER:
        # Validated before the CADM is spent, so a refusal does not consume an
        # identity and does not leave an intent nobody can resolve.
        if binding is None or binding.condition != _DESTROYS_UNDER[verb]:
            raise AdminRefused(
                f"{verb.value} has no target durably bound to its condition")
        if _already_destroyed(verified, identity):
            raise AdminRefused(
                f"{identity} already carries a closed destruction outcome")
        target = binding.container_id

    cadm = allocate_cadm(verified)
    record_intent(verified, cadm, verb, identity, target)

    classification: Any = None
    if verb in _DESTROYS_UNDER:
        result = _destroy(context, verb, binding)
    elif verb is Verb.RETRY_CLEANUP:
        result, classification = _retry_cleanup(context, identity)
    elif verb in (Verb.RETAIN_QUARANTINE_INCOMPLETE,
                  Verb.RETAIN_QUARANTINE_RESIDUE):
        result, classification = _quarantine(context, verb, identity)
    else:
        # Every remaining verb is a recorded decision to leave something as it
        # is. The record is the whole of the effect, and deliberately so.
        result = RESULT_DONE

    record_outcome(verified, cadm, result, classification=classification)
    return AdminOutcome(cadm=cadm, verb=verb, cinv=identity, target=target,
                        result=result, classification=classification)


class Audit:
    """The bounded durable audit event inspection writes before it speaks."""

    def commit(self, root: RootDescriptor, body: bytes) -> str:
        base = os.open(INSPECTION_AUDIT, _DIR_FLAGS, dir_fd=root.fd)
        try:
            highest = 0
            with os.scandir(base) as entries:
                for entry in entries:
                    if len(entry.name) != _SEQUENCE_DIGITS \
                            or set(entry.name) - _DIGITS:
                        raise AdminIntegrityFailure(
                            f"{entry.name} is not an audit event")
                    highest = max(highest, int(entry.name))
            if highest >= _MAXIMUM_SEQUENCE:
                raise AdminRefused("the inspection audit namespace is exhausted")
            name = f"{highest + 1:0{_SEQUENCE_DIGITS}d}"
            _write_durable(name, body, base)
            return name
        finally:
            os.close(base)


def inspect_admin_integrity(root: Any, *, audit: Any) -> Summary:
    """Examine the administrative namespace, read-only, and report.

    Available at any time, including while mutation is blocked — a namespace
    nobody may write is exactly the one somebody needs to look at. It allocates
    no `CADM`, repairs nothing, and takes no filter, offset, or cursor: a
    partial view of an integrity question is worse than none, because it looks
    like an answer.

    The audit event commits first. If it cannot, the summary is withheld
    entirely rather than emitted unlogged.
    """
    verified = _require_root(root)

    classification: Classification | None = None
    records: tuple[str, ...] = ()
    scanned = 0
    unknown: tuple[str, ...] = ()
    try:
        records, scanned = _scan_records(verified)
        unknown = unknown_outcomes(verified)
    except AdminError as error:
        classification = error.classification

    body = canonical_json.serialise({
        "schema_version": RECORD_SCHEMA_VERSION,
        "entries_scanned": scanned,
        "records": list(records),
        "unknown_outcomes": list(unknown),
        "classification": None if classification is None else classification.value,
    })
    if len(body) > MAXIMUM_SUMMARY_BYTES:
        classification = Classification.ADMINISTRATIVE_INTEGRITY_FINDINGS_TRUNCATED
        body = canonical_json.serialise({
            "schema_version": RECORD_SCHEMA_VERSION,
            "entries_scanned": scanned,
            "records": [],
            "unknown_outcomes": [],
            "classification": classification.value,
        })

    try:
        audit.commit(verified, body)
    except AdminError:
        raise
    except Exception as error:  # noqa: BLE001
        raise InspectionAuditCommitFailed(
            f"the inspection audit did not commit: {error}") from None

    return Summary(records=records, entries_scanned=scanned,
                   unknown_outcomes=unknown, classification=classification,
                   blocked=classification is not None)
