"""The whole preparation, in order, ending where it must.

Bind, verify the governed decision, verify and stage the package, record the
decision durably — and then stop. **The absence of an adapter is architectural,
not an exception**: there is no registry to consult, no plugin path to scan, and
no import to attempt and fail. The refusal is a named state this module returns
because no execution mechanism has been authorised, and nothing here could
reach one if it had been.

**A preparation that succeeded is recorded as one.** The durable invocation
record says `execution-prepared`, and it stays that way: what is unavailable is
a separately authorised execution mechanism, not the preparation. Rewriting the
record to say refused would erase the distinction between work that was done
and work that could not be.

The identity is consumed all the same. Presenting it again is a replay of a
decision that was genuinely made.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from .errors import CapabilityError
from .evidence import (STATUS_PREFLIGHT, STATUS_PREPARED, record_invocation,
                       record_terminal_result)
from .fabric_evidence import verify_selected_evidence
from .invocation_identity import bind, payload_digest
from .package_resolution import resolve_and_stage_package

# The one thing this can honestly say once preparation succeeds.
REASON_NO_ADAPTER = "no_authorised_adapter"


def _bound_adapter_identity(adapter: Any, execution_binding: Any) -> Any:
    """The governed adapter identity for this invocation, or nothing.

    Execution needs both an authorised mechanism and a governed binding, so
    either being absent means nothing was authorised and the record says so
    with a null rather than with a name it did not earn.

    The name is read from the binding's own authenticated profile rather than
    from a module constant: the identity recorded is the identity that was
    actually bound, and `require_adapter_identity` still refuses anything
    outside the governed vocabulary.
    """
    if adapter is None or execution_binding is None:
        return None
    profile = getattr(execution_binding, "profile", None)
    return getattr(profile, "adapter_identity", None)


def _admitted_result_digest(outcome: Any) -> Any:
    """The digest of the result T14 admitted, as the adapter concluded it.

    **Read, not derived.** This used to walk the collector's manifest here,
    which made the coordinator a second reader of somebody else's evidence and
    a second opinion about which file was the result. The conclusion belongs to
    whatever performed the collection, so it is carried on the outcome and this
    only checks that what arrived is the released shape.

    It also has to be read rather than derived now that execution can happen
    across the privilege boundary: a supervised outcome carries the digest the
    worker reported and no manifest at all, because a manifest cannot cross a
    pipe and re-deriving one from output the coordinator cannot see would be
    inventing evidence.

    An absent digest is an absent digest. `record_terminal_result` refuses a
    success without one, so nothing here needs to guess.
    """
    digest = getattr(outcome, "result_digest", None)
    if digest is None:
        return None
    if not isinstance(digest, str) or not digest.startswith("sha256:") \
            or len(digest) != len("sha256:") + 64 \
            or set(digest[len("sha256:"):]) - set("0123456789abcdef"):
        raise CapabilityError(
            "the adapter reported a result digest that is not the released "
            "sha256:<64hex> form")
    return digest


def prepare_invocation(store, *, fabric_root: Any, fabric_expected_uid: Any,
                       fabric_expected_gid: Any, approved_artifact_root: Any,
                       trusted_source_uid: Any, staging_root: Any,
                       coordinator_uid: Any, selection_id: Any,
                       instance_id: Any, capability_package_id: Any,
                       operation: Any, trust_root: Any, invocation_id: Any,
                       payload: Any, actor: Any,
                       request_id: Any, requested_at: datetime,
                       adapter: Any = None, execution_binding: Any = None):
    """Prepare one governed invocation, and execute it only if it may be.

    Returns the durable decision. A `prepared` status carries
    `no_authorised_adapter` as its reason whenever execution is not available,
    and execution needs **both** an authorised mechanism and a governed
    binding: an adapter with nothing bound to it has nothing to run, and a
    binding with no adapter has nothing to run it. Either missing is the same
    honest refusal it has always been.

    The invocation record is committed before the adapter is reached, so a
    crash during execution leaves a decision that was durably made rather than
    one nobody can account for.
    """
    # The operator claims what they believe was selected; verification is what
    # decides whether the claim is true. A coordinator that read the instance
    # out of the selection and then "verified" it would be checking its own
    # arithmetic.
    evidence = verify_selected_evidence(
        fabric_root, expected_uid=fabric_expected_uid,
        expected_gid=fabric_expected_gid, selection_id=selection_id,
        instance_id=instance_id, capability_package_id=capability_package_id,
        operation=operation, trust_root=trust_root,
        evaluated_at=requested_at)
    staged = None
    if evidence.supported:
        staged = resolve_and_stage_package(
            evidence=evidence, approved_artifact_root=approved_artifact_root,
            trusted_source_uid=trusted_source_uid, staging_root=staging_root,
            coordinator_uid=coordinator_uid)

    # The binding covers what the caller claimed, so a refused claim binds to
    # the claim that was refused rather than to whatever the store happened to
    # hold.
    binding = bind(payload=payload, invocation_id=invocation_id,
                   selection_id=selection_id, instance_id=instance_id,
                   capability_package_id=capability_package_id,
                   operation=operation, actor=actor)
    # The execution mechanism, determined BEFORE the immutable record is
    # written and carried into it. Ordering is the whole point: once this is
    # durable the platform can no longer prove the adapter did not act, which
    # is what makes an invocation with no result honestly interrupted rather
    # than merely unexplained.
    #
    # Derived from the binding the runtime itself constructed, never from a
    # caller. Absent binding means no mechanism was authorised, and null is the
    # truthful record of that.
    adapter_identity = _bound_adapter_identity(adapter, execution_binding)

    decision = record_invocation(
        store, invocation_id=invocation_id, binding_digest=binding,
        payload_digest=payload_digest(payload), evidence=evidence, staged=staged,
        actor=actor, request_id=request_id, requested_at=requested_at,
        adapter_identity=adapter_identity)

    # A rehearsal's verdict is carried back exactly as it was reached. Naming
    # the missing adapter here would overwrite the reason the rehearsal computed
    # -- including a refusal it is reporting on purpose -- and the caller needs
    # that reason, not this module's opinion about what comes after it.
    if decision.status == STATUS_PREFLIGHT:
        return decision

    if decision.status == STATUS_PREPARED:
        if adapter is not None and execution_binding is not None:
            # The record above is already durable. What comes back is carried,
            # never reinterpreted: the outcome class was concluded by T13 and
            # copied through the adapter, and this module adds no judgement of
            # its own to it.
            outcome = adapter.execute(execution_binding)

            # The digest of the result that was actually ADMITTED, taken from
            # the collector's own manifest rather than recomputed here. Nothing
            # re-reads the output tree: T14 already decided what could be
            # believed, and hashing it a second time would be a second opinion.
            result_digest = _admitted_result_digest(outcome)

            # The terminal outcome, made durable. Until G11-AN nothing wrote
            # this, so every executed invocation left the same store state as
            # one that never ran.
            terminal = record_terminal_result(
                store, invocation_record_id=decision.invocation_record_id,
                outcome=outcome, result_digest=result_digest,
                result_artifact_reference=None, actor=actor,
                invocation_id=invocation_id, recorded_at=requested_at)
            return type(decision)(
                decision.status, terminal.reason or outcome.outcome_class,
                invocation_record_id=decision.invocation_record_id,
                result_record_id=terminal.result_record_id,
                invocation_id=decision.invocation_id,
                binding_digest=decision.binding_digest,
                payload_digest=decision.payload_digest,
                artifact_digest=decision.artifact_digest,
                staged_path=decision.staged_path,
                succeeded=terminal.succeeded,
                result_digest=terminal.result_digest,
                result_artifact_reference=terminal.result_artifact_reference)
        # Preparation succeeded. Execution has not been authorised, and this is
        # where the flow ends -- before any surface that could run anything.
        return type(decision)(
            decision.status, REASON_NO_ADAPTER,
            invocation_record_id=decision.invocation_record_id,
            result_record_id=decision.result_record_id,
            invocation_id=decision.invocation_id,
            binding_digest=decision.binding_digest,
            payload_digest=decision.payload_digest,
            artifact_digest=decision.artifact_digest,
            staged_path=decision.staged_path)
    return decision


def execute_supervised(store, *, invocation_record_id: Any, invocation_id: Any,
                       supervisor: Any, binding: Any, actor: Any,
                       recorded_at: datetime):
    """Supervise one already-authorised invocation and record its outcome.

    **This is not a second preparation.** `prepare_invocation` decided
    eligibility, staged the package and spent the identity; the launch bridge
    published the handoff and wrote the authorisation. All of that is durable
    before this is reachable, and re-running any of it here would either refuse
    as a replay or make a second decision about a question already answered.

    **The coordinator keeps result authority, and this is where it keeps it.**
    The supervisor drives the privileged execution and concludes facts; nothing
    on the far side of the boundary may write a Capability Runtime record, and
    the worker could not -- it has no store, no allocator and no path to one.
    What comes back is carried into `record_terminal_result` exactly as it
    arrived, which is the same call `prepare_invocation` makes for a locally
    executed adapter, for the same reason.

    **A refusal writes nothing.** A supervised execution that could not be
    concluded -- an untrusted conversation, a worker that stopped talking, a
    container whose disposal could not be proven -- leaves the invocation with
    no terminal result, which is precisely the state `recovery` enumerates and
    the readiness gate acts on. Writing an `adapter-error` result instead would
    close the question without answering it, and would take the invocation out
    of the one enumeration that could still resolve it.
    """
    if supervisor is None or binding is None:
        raise CapabilityError(
            "a supervised execution needs both a supervisor and a binding")
    outcome = supervisor.execute(binding)
    return record_terminal_result(
        store, invocation_record_id=invocation_record_id, outcome=outcome,
        result_digest=_admitted_result_digest(outcome),
        result_artifact_reference=None, actor=actor,
        invocation_id=invocation_id, recorded_at=recorded_at)
