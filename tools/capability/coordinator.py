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

from .evidence import STATUS_PREPARED, record_invocation
from .fabric_evidence import verify_selected_evidence
from .invocation_identity import bind, payload_digest
from .package_resolution import resolve_and_stage_package

# The one thing this can honestly say once preparation succeeds.
REASON_NO_ADAPTER = "no_authorised_adapter"


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
    decision = record_invocation(
        store, invocation_id=invocation_id, binding_digest=binding,
        payload_digest=payload_digest(payload), evidence=evidence, staged=staged,
        actor=actor, request_id=request_id, requested_at=requested_at)

    if decision.status == STATUS_PREPARED:
        if adapter is not None and execution_binding is not None:
            # The record above is already durable. What comes back is carried,
            # never reinterpreted: the outcome class was concluded by T13 and
            # copied through the adapter, and this module adds no judgement of
            # its own to it.
            outcome = adapter.execute(execution_binding)
            return type(decision)(
                decision.status, outcome.outcome_class,
                invocation_record_id=decision.invocation_record_id,
                result_record_id=decision.result_record_id,
                invocation_id=decision.invocation_id,
                binding_digest=decision.binding_digest,
                payload_digest=decision.payload_digest,
                artifact_digest=decision.artifact_digest,
                staged_path=decision.staged_path)
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
