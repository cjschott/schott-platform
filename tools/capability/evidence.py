"""Deciding an invocation once, durably, under one lock.

One opaque `invocation_id`, one authoritative binding, for ever. Establishing
that is a single serialized act: looking the identity up outside the lock and
writing inside it is a race with a different shape, not a smaller one, and so
is deciding inside the lock and publishing after it. **Lookup, comparison,
allocation, and publication all happen in one critical section**, and the
section is the Capability Runtime's own — the Fabric's request lock governs a
different plane and is never touched here.

**A refused invocation consumes its identity.** That is deliberate, and it
follows the specification: going forward after a failure means a new
`invocation_id`, not another attempt at the old one. So a refusal writes its
invocation record too, and the identity is spent.

**A record states its own outcome.** The invocation record carries the decision
it recorded, so a refusal interrupted before its result record still reads as
a refusal. Inferring what happened from which files exist is how an invocation
nobody approved comes to look approved.

**Lookup is a scan of immutable records, not an index.** An index would be
mutable state that has to be right about immutable state, and a lookup that
disagrees with the records is worse than a slow one. Every candidate is
validated before it is believed, and two authoritative records for one identity
are corruption rather than a question about which to prefer.

Nothing here executes. It records that a preparation was decided, and the
adapter that would act on it does not exist.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from .errors import CapabilityError
from .rehearsal import is_rehearsing
from .invocation_identity import (CONFLICT, CONSUMED, compare_binding,
                                  validate_invocation_id)
from .records import (INVOCATION_FIELDS, INVOCATION_KIND, RECORD_SCHEMA_VERSION,
                      RESULT_SCHEMA_VERSION, REASON_RESULT_MISSING,
                      OUTCOME_CLASSES,
                      RESULT_FIELDS, RESULT_KIND)

STATUS_PREPARED = "prepared"
# What a rehearsal returns. Never written to a record: no record is written.
STATUS_PREFLIGHT = "preflight"
STATUS_REFUSED = "refused"
STATUS_CONSUMED = "consumed"
STATUS_CONFLICT = "conflict"

# What an invocation record says about itself, written with it.
OUTCOME_PREPARED = "execution-prepared"
OUTCOME_REFUSED = "refused"

OUTCOME_CLASS_REFUSED = "refused"

REASON_INVOCATION_INPUT = "invocation-input-invalid"
REASON_CORRUPT_EVIDENCE = "invocation-evidence-corrupt"

_DIGEST_PREFIX = "sha256:"
_DIGEST_LENGTH = len(_DIGEST_PREFIX) + 64
_HEX = frozenset("0123456789abcdef")


@dataclass(frozen=True)
class InvocationDecision:
    """The durable decision, and the records that carry it."""

    status: str
    reason: str | None = None
    invocation_record_id: str | None = None
    result_record_id: str | None = None
    invocation_id: str | None = None
    binding_digest: str | None = None
    payload_digest: str | None = None
    artifact_digest: str | None = None
    staged_path: str | None = None
    # Whether a governed result was ADMITTED, which is not the same question as
    # whether the process finished. `outcome_class` answers the second; a
    # capability that exits zero and writes nothing is `completed` and did not
    # succeed.
    #
    # `None` where no adapter ran: a preparation that never reached execution
    # did not fail, and `False` would be a claim about a run that never
    # happened. Only an actual execution outcome sets True or False.
    succeeded: bool | None = None
    result_digest: str | None = None
    result_artifact_reference: str | None = None


def _digest_shaped(value: Any) -> bool:
    if not isinstance(value, str) or len(value) != _DIGEST_LENGTH:
        return False
    if value[:len(_DIGEST_PREFIX)] != _DIGEST_PREFIX:
        return False
    return all(character in _HEX for character in value[len(_DIGEST_PREFIX):])


def _sound(record: Any) -> bool:
    """Whether a stored invocation record may be believed.

    Every candidate is checked before it is trusted. A record that is malformed
    is not evidence of anything, and quietly skipping it would let a damaged
    store answer a question about identity with silence.
    """
    if not isinstance(record, Mapping):
        return False
    if set(record) != set(INVOCATION_FIELDS):
        return False
    if record.get("kind") != INVOCATION_KIND:
        return False
    if record.get("schema_version") != RECORD_SCHEMA_VERSION:
        return False
    for field in ("invocation_record_id", "invocation_id", "actor"):
        value = record.get(field)
        if not isinstance(value, str) or not value:
            return False
    if not _digest_shaped(record.get("binding_digest")):
        return False
    if not _digest_shaped(record.get("payload_digest")):
        return False
    evidence = record.get("evidence")
    if not isinstance(evidence, Mapping) or not evidence.get("outcome"):
        return False
    return True


def _existing(store, invocation_id: str):
    """The one authoritative record for this identity, or a refusal reason.

    Returns `(record, reason)`. A scan rather than an index: the records are
    the authority, and nothing derived is allowed to disagree with them.
    """
    try:
        stored = store.list_records(INVOCATION_KIND)
    except CapabilityError:
        return None, REASON_CORRUPT_EVIDENCE

    matched = []
    for record in stored:
        if not _sound(record):
            # A malformed record anywhere in the namespace is refused rather
            # than stepped over: an identity question answered from a damaged
            # store is not an answer.
            return None, REASON_CORRUPT_EVIDENCE
        if record["invocation_id"] == invocation_id:
            matched.append(record)

    if not matched:
        return None, None
    if len(matched) > 1:
        return None, REASON_CORRUPT_EVIDENCE
    return matched[0], None


def _invocation_body(identity: str, *, invocation_id: str, request_id: Any,
                     evidence, staged, actor: str, payload_digest: str,
                     binding_digest: str, requested_at: datetime,
                     outcome: str) -> dict[str, Any]:
    return {
        "invocation_record_id": identity,
        "invocation_id": invocation_id,
        "request_id": request_id,
        "selection_id": evidence.selection_id,
        "instance_id": evidence.instance_id,
        "capability_package_id": evidence.capability_package_id,
        "contract_id": evidence.contract_id,
        "capability_id": evidence.capability_id,
        "operation": evidence.operation,
        "actor": actor,
        "payload_digest": payload_digest,
        "binding_digest": binding_digest,
        "effect_class": evidence.effect_class,
        "artifact_digest": staged.package_tree_sha256 if staged is not None else None,
        "staged_path": staged.staged_path if staged is not None else None,
        "requested_at": requested_at,
        "kind": INVOCATION_KIND,
        "schema_version": RECORD_SCHEMA_VERSION,
        "evidence": {"actor": actor, "outcome": outcome,
                     "request_id": request_id,
                     "selection_id": evidence.selection_id},
    }


def _result_body(identity: str, *, invocation_record_id: str, reason: Any,
                 recorded_at: datetime, actor: str,
                 outcome_class: str = OUTCOME_CLASS_REFUSED,
                 result_digest: Any = None,
                 result_artifact_reference: Any = None,
                 started_at: Any = None, ended_at: Any = None,
                 outcome: str = OUTCOME_REFUSED) -> dict[str, Any]:
    """One result record, in the section 15 shape.

    A pre-execution refusal has no `started_at`: nothing started. Encoding that
    as null rather than as the recording instant keeps "when the work ran" and
    "when we wrote this down" distinct, which is the whole reason both exist.
    """
    return {
        "capability_result_id": identity,
        "invocation_record_id": invocation_record_id,
        "attempt_number": 1,
        "outcome_class": outcome_class,
        "reason": reason,
        "result_digest": result_digest,
        "result_artifact_reference": result_artifact_reference,
        "started_at": started_at,
        "ended_at": ended_at,
        "recorded_at": recorded_at,
        "kind": RESULT_KIND,
        "schema_version": RESULT_SCHEMA_VERSION,
        "evidence": {"actor": actor, "outcome": outcome},
    }


def require_execution_success(value: Any) -> bool:
    """The adapter's admission verdict, or refuse.

    Fails closed on anything that is not exactly a boolean. A missing or
    oddly-typed `succeeded` is not evidence that a result was admitted, and
    defaulting it either way would answer a question nobody asked -- which is
    how `completed` came to read as success in the first place.
    """
    if value is not True and value is not False:
        raise CapabilityError(
            "the adapter outcome does not carry a usable success verdict")
    return value


def record_terminal_result(store, *, invocation_record_id: Any, outcome: Any,
                           result_digest: Any = None,
                           result_artifact_reference: Any = None,
                           actor: Any = "unknown",
                           invocation_id: Any = None,
                           recorded_at: datetime | None = None) -> InvocationDecision:
    """Persist the terminal outcome of one execution attempt.

    **It records conclusions and reaches none.** The outcome class was decided
    by T13, the admission verdict by T14, and the digest by whatever collected
    the result. Nothing here reruns the adapter, re-reads an exit code,
    reinterprets output, or revisits eligibility.

    **It never touches the invocation record.** CINV is the immutable
    pre-execution attempt evidence, written before the adapter precisely so a
    crash mid-flight is still attributable. Recording completion by editing it
    would destroy the property that makes it worth having.

    **An undescribable pair is refused rather than written.** A success with no
    digest, or a failure carrying one, is not an outcome anybody reached, and a
    record of it would be worse than none.
    """
    admitted = require_execution_success(getattr(outcome, "succeeded", None))
    outcome_class = getattr(outcome, "outcome_class", None)
    if outcome_class not in OUTCOME_CLASSES:
        raise CapabilityError(
            f"the outcome class {outcome_class!r} is not a released one")

    if admitted:
        if not _digest_shaped(result_digest):
            raise CapabilityError(
                "an admitted result must carry a governed result digest")
        reason = None
    else:
        if result_digest is not None or result_artifact_reference is not None:
            raise CapabilityError(
                "a result that was not admitted may not carry a digest or a "
                "reference")
        # The governed name for what went wrong. `completed` with nothing
        # admitted is the case that used to read as success, so it gets the
        # one reason added for it; every other class already names itself.
        reason = (REASON_RESULT_MISSING if outcome_class == "completed"
                  else outcome_class)

    # Supplied, never read from a clock here. This module records conclusions
    # and the instant a record was written is the caller's fact, the same way
    # `requested_at` already is on the refusal path.
    if recorded_at is None:
        raise CapabilityError("a terminal result must be recorded at an instant")

    terminal = getattr(outcome, "terminal", None)
    started_at = getattr(terminal, "started_at", None)
    ended_at = getattr(terminal, "finished_at", None)

    # Serialised, and entered only now. The invocation critical section is the
    # store's own -- not the Fabric's -- and it is deliberately NOT held across
    # the execution: a capability that runs for its full timeout must not block
    # every other invocation-identity operation for that long.
    with store.invocation_critical_section(invocation_id or invocation_record_id):
        for existing in store.list_records(RESULT_KIND):
            if (existing.get("invocation_record_id") == invocation_record_id
                    and existing.get("attempt_number") == 1):
                raise CapabilityError(
                    f"a terminal result already exists for "
                    f"{invocation_record_id}; this adapter performs one attempt")
        identity = store.allocate_id(RESULT_KIND)
        store.write_atomic(
            store.path_for(RESULT_KIND, identity),
            _result_body(identity, invocation_record_id=invocation_record_id,
                         reason=reason, recorded_at=recorded_at,
                         actor=actor, outcome_class=outcome_class,
                         result_digest=result_digest if admitted else None,
                         result_artifact_reference=(
                             result_artifact_reference if admitted else None),
                         started_at=started_at, ended_at=ended_at,
                         outcome=outcome_class))
    return InvocationDecision(
        STATUS_PREPARED, reason, invocation_record_id=invocation_record_id,
        result_record_id=identity, succeeded=admitted,
        result_digest=result_digest if admitted else None,
        result_artifact_reference=(
            result_artifact_reference if admitted else None))


def record_invocation(store, *, invocation_id: Any, binding_digest: Any,
                      payload_digest: Any, evidence, staged, actor: Any,
                      request_id: Any, requested_at: datetime) -> InvocationDecision:
    """Decide this invocation once, and record the decision durably.

    A prepared decision means the invocation was verified and recorded. **It is
    not an execution and it is not permission to execute** — no adapter exists,
    and nothing here could reach one.
    """
    # Input that cannot form the authoritative key records nothing: there is no
    # identity to record it against.
    try:
        identity = validate_invocation_id(invocation_id)
    except CapabilityError:
        return InvocationDecision(STATUS_REFUSED, REASON_INVOCATION_INPUT)
    if not _digest_shaped(binding_digest) or not _digest_shaped(payload_digest):
        return InvocationDecision(STATUS_REFUSED, REASON_INVOCATION_INPUT)
    if not isinstance(actor, str) or not actor:
        return InvocationDecision(STATUS_REFUSED, REASON_INVOCATION_INPUT)
    if not isinstance(requested_at, datetime) or requested_at.tzinfo is None:
        return InvocationDecision(STATUS_REFUSED, REASON_INVOCATION_INPUT)

    # A rehearsal stops here. Everything above ran -- the identity is validated,
    # the digests are shaped, the actor and instant are checked -- and the two
    # conclusions the write would reach are computed below from the same
    # evidence and the same staging result. What does not happen is the critical
    # section, the allocation, and the write.
    #
    # The prior-record lookup still runs, because "this identity has already
    # been consumed" is one of the answers a rehearsal owes the operator.
    if is_rehearsing():
        prior, problem = _existing(store, identity)
        if problem is not None:
            return InvocationDecision(STATUS_PREFLIGHT, problem,
                                      invocation_id=identity)
        if prior is not None:
            verdict = compare_binding(prior["binding_digest"], binding_digest)
            return InvocationDecision(
                STATUS_PREFLIGHT,
                CONSUMED if verdict == CONSUMED else CONFLICT,
                invocation_record_id=prior["invocation_record_id"],
                invocation_id=identity,
                binding_digest=prior["binding_digest"],
                payload_digest=prior["payload_digest"],
                artifact_digest=prior.get("artifact_digest"),
                staged_path=prior.get("staged_path"))
        refusal = None
        if not evidence.supported:
            refusal = evidence.reason
        elif staged is None or not staged.supported:
            refusal = staged.reason if staged is not None else REASON_INVOCATION_INPUT
        return InvocationDecision(
            STATUS_PREFLIGHT, refusal,
            invocation_record_id=store.peek_next_id(INVOCATION_KIND),
            invocation_id=identity, binding_digest=binding_digest,
            payload_digest=payload_digest,
            artifact_digest=None if refusal is not None else staged.package_tree_sha256,
            staged_path=None if refusal is not None else staged.staged_path)

    # One section, entered once. Lookup, comparison, allocation, and both
    # writes happen inside it, because a decision published outside the lock
    # that established it was never serialised at all.
    with store.invocation_critical_section(identity):
        prior, problem = _existing(store, identity)
        if problem is not None:
            return InvocationDecision(STATUS_REFUSED, problem)

        if prior is not None:
            verdict = compare_binding(prior["binding_digest"], binding_digest)
            status = STATUS_CONSUMED if verdict == CONSUMED else STATUS_CONFLICT
            reason = CONSUMED if verdict == CONSUMED else CONFLICT
            return InvocationDecision(
                status, reason,
                invocation_record_id=prior["invocation_record_id"],
                invocation_id=identity,
                binding_digest=prior["binding_digest"],
                payload_digest=prior["payload_digest"],
                artifact_digest=prior.get("artifact_digest"),
                staged_path=prior.get("staged_path"))

        refusal = None
        if not evidence.supported:
            refusal = evidence.reason
        elif staged is None or not staged.supported:
            refusal = staged.reason if staged is not None else REASON_INVOCATION_INPUT

        outcome = OUTCOME_REFUSED if refusal is not None else OUTCOME_PREPARED
        record_id = store.allocate_id(INVOCATION_KIND)
        store.write_atomic(
            store.path_for(INVOCATION_KIND, record_id),
            _invocation_body(record_id, invocation_id=identity,
                             request_id=request_id, evidence=evidence,
                             staged=staged if refusal is None else None,
                             actor=actor, payload_digest=payload_digest,
                             binding_digest=binding_digest,
                             requested_at=requested_at, outcome=outcome))

        if refusal is None:
            return InvocationDecision(
                STATUS_PREPARED, None, invocation_record_id=record_id,
                invocation_id=identity, binding_digest=binding_digest,
                payload_digest=payload_digest,
                artifact_digest=staged.package_tree_sha256,
                staged_path=staged.staged_path)

        result_id = store.allocate_id(RESULT_KIND)
        store.write_atomic(
            store.path_for(RESULT_KIND, result_id),
            _result_body(result_id, invocation_record_id=record_id,
                         reason=refusal, recorded_at=requested_at, actor=actor))
        return InvocationDecision(
            STATUS_REFUSED, refusal, invocation_record_id=record_id,
            result_record_id=result_id, invocation_id=identity,
            binding_digest=binding_digest, payload_digest=payload_digest)
