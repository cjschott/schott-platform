"""Verifying that a claimed invocation matches an already-governed decision.

The authority bridge, and it crosses in one direction only. **The Fabric
decides; this verifies.** It begins from the selection a caller claims and
confirms that the authoritative records say what the caller says they say. It
never searches for an instance that would work, never ranks anything, and never
reaches a conclusion the Fabric has not already reached.

**The direction matters more than anything else here.** A reader that started
from a capability and looked for a suitable instance would be selecting — a
second selection system, downstream of the first, with none of its governance.
So the chain is walked from the claimed `selection_id` outward, every edge is
an equality check against a named identity, and a refusal is a refusal. There
is no fallback, because a fallback is a choice.

**These are guards over facts, not eligibility.** Whether an instance *should*
be selectable is C5's question and was answered before the `CSEL` existed.
What is asked here is narrower: does this instance still say it is admitted,
is its window open at the instant supplied, does the package the caller claims
match the one the instance binds, and is the contract's effect class one that
may execute at all. Facts, compared.

**And one question C5 was never asked.** A selection names a binding for a
request class; it does not name an action, and no `CSEL` carries one. So the
concrete operation arrives here with the invocation and is checked against the
`effective_scope` the binding was admitted under, together with the capability,
the classification the selection recorded, and the node identity the host
declares. Admission proved the envelope against no particular request. This
proves one particular request is inside it.

**Fabric is consumed through C8's read-only inspection surface and nothing
else.** Admission, selection, eligibility, and the trust adapter are not
imported, and they are not reachable from what is: nothing here can mutate a
record, allocate an identifier, or take the Fabric's request lock. Trust is
never called — the standing this needs was decided before the binding was
governed, and rides on the records as evidence. The ENG-0006 plane is never
consulted either: it does not exist, and a runtime that guessed at
availability would be scheduling.

This module reads. It prepares nothing, resolves no artefact, and **executes
nothing**.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from ..fabric.inspection import (STATUS_REPORTED, inspect_records)
from .errors import CapabilityError

SELECTION = "capability-selection"
INSTANCE = "capability-instance"
PACKAGE = "capability-package"
CONTRACT = "capability-contract"
DEFINITION = "capability-definition"
HOST = "capability-host"

# The four dimensions the admitted binding's `effective_scope` bounds. Every
# one is checked here against the concrete request, because admission composed
# the envelope and this is where a concrete action is claimed to fit inside it.
SCOPE_CAPABILITIES = "permitted_capabilities"
SCOPE_OPERATIONS = "permitted_operations"
SCOPE_CLASSIFICATIONS = "permitted_data_classifications"
SCOPE_TARGETS = "permitted_targets"
SCOPE_DIMENSIONS = (SCOPE_CAPABILITIES, SCOPE_OPERATIONS,
                    SCOPE_CLASSIFICATIONS, SCOPE_TARGETS)

# The only lifecycle state a binding may be executed from. `withdrawn` and
# `retired` are the released non-routable states, and a superseded record is
# not the head of its chain whatever it says about itself.
ADMITTED = "admitted"

# Effect classes that may execute. `side-effecting` is representable and
# unroutable by ADR-0012, and enabling it needs an ADR, not a flag.
EXECUTABLE_EFFECT_CLASSES = frozenset(
    {"read-only", "computational", "content-generating"})

REASON_UNREADABLE = "fabric-store-unreadable"
REASON_SELECTION_ABSENT = "selection-not-found"
REASON_SELECTION_REFUSED = "selection-recorded-no-instance"
REASON_INSTANCE_MISMATCH = "claimed-instance-not-selected"
REASON_INSTANCE_ABSENT = "instance-not-found"
REASON_PACKAGE_MISMATCH = "claimed-package-not-bound"
REASON_PACKAGE_ABSENT = "package-not-found"
REASON_CONTRACT_ABSENT = "contract-not-found"
REASON_CAPABILITY_ABSENT = "capability-not-found"
REASON_INCOHERENT = "record-chain-incoherent"
REASON_NOT_ADMITTED = "instance-not-admitted"
REASON_SUPERSEDED = "instance-superseded"
REASON_WINDOW = "admission-window-not-open"
REASON_EFFECT_CLASS = "effect-class-not-executable"
REASON_HOST_ABSENT = "host-not-found"
# One reason per dimension, deliberately. Collapsing them would tell an
# operator that something about the request was out of scope without saying
# which thing, and the four are cleared in four different places.
REASON_OPERATION_ABSENT = "operation-not-supplied"
REASON_OPERATION = "operation-not-permitted-by-scope"
REASON_CAPABILITY_SCOPE = "capability-not-permitted-by-scope"
REASON_CLASSIFICATION_SCOPE = "classification-not-permitted-by-scope"
REASON_TARGET_SCOPE = "target-not-permitted-by-scope"
REASON_SCOPE = "invalid-effective-scope"


@dataclass(frozen=True)
class EvidenceVerdict:
    """What the authoritative records support, and nothing more.

    Carries the verified identities and the package metadata the resolution
    increment will need. It carries no path, no command, no environment, and
    no adapter, because none of those is a fact the Fabric recorded.
    """

    supported: bool
    reason: str | None = None
    selection_id: str | None = None
    instance_id: str | None = None
    capability_package_id: str | None = None
    contract_id: str | None = None
    capability_id: str | None = None
    effect_class: str | None = None
    artifact_reference: str | None = None
    manifest_reference: str | None = None
    # The action this invocation asked for, and the node it was judged
    # against. Carried so the durable record can say what was authorised
    # rather than leaving a reader to assume it.
    operation: str | None = None
    target_node_identity: str | None = None


def _refused(reason: str) -> EvidenceVerdict:
    return EvidenceVerdict(False, reason)


def _text(record: Mapping[str, Any], field: str) -> str | None:
    value = record.get(field)
    return value if isinstance(value, str) and value else None


def _one(root: Any, expected_uid: Any, expected_gid: Any, kind: str,
         identifier: Any, absent: str) -> tuple[Mapping[str, Any] | None, str | None]:
    """One record, named exactly, or the reason there is not one.

    Named exactly: this asks for an identity, never for a list to choose from.
    """
    report = inspect_records(root, expected_uid=expected_uid,
                             expected_gid=expected_gid, kind=kind,
                             identifier=identifier)
    if report.status != STATUS_REPORTED:
        # An unusable store and a missing record are different refusals, and
        # collapsing them would report a broken store as an absent decision.
        if report.reason in ("store-root-absent", "store-root-unreadable",
                             "store-root-not-supplied"):
            return None, REASON_UNREADABLE
        return None, absent
    if len(report.records) != 1:
        return None, absent
    record = report.records[0]
    if not isinstance(record, Mapping):
        return None, absent
    return record, None


def _usable(value: Any) -> str | None:
    """Bounded text that names something, or nothing at all.

    Absent and unusable are the same answer: neither names an operation, and
    nothing is trimmed or repaired, because a value that had to be corrected
    to match is not the value that was supplied.
    """
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        return None
    return value


def _scope(instance: Mapping[str, Any]) -> dict[str, tuple[str, ...]] | None:
    """The binding's four bounded dimensions, or nothing if unreadable.

    A dimension the record leaves out bounds nothing and therefore permits
    nothing, so an incomplete scope is refused rather than read as permissive.
    Absence is not permission -- the same rule the composition at admission
    already applies.
    """
    scope = instance.get("effective_scope")
    if not isinstance(scope, Mapping):
        return None
    bounded: dict[str, tuple[str, ...]] = {}
    for dimension in SCOPE_DIMENSIONS:
        members = scope.get(dimension)
        if not isinstance(members, (list, tuple)):
            return None
        if any(not isinstance(member, str) for member in members):
            return None
        bounded[dimension] = tuple(members)
    return bounded


def _window_open(instance: Mapping[str, Any], instant: datetime) -> bool:
    """The admission window, as recorded, containing the supplied instant."""
    opened = _text(instance, "admitted_at")
    expires = _text(instance, "admitted_until")
    if opened is None or expires is None:
        return False
    try:
        start = datetime.fromisoformat(opened)
        end = datetime.fromisoformat(expires)
    except ValueError:
        # An unreadable window is not an open one. It is named as malformed
        # content and never guessed at.
        return False
    if start.tzinfo is None or end.tzinfo is None:
        return False
    return start <= instant < end


def verify_selected_evidence(fabric_root: Any, *, expected_uid: Any,
                             expected_gid: Any, selection_id: Any,
                             instance_id: Any, capability_package_id: Any,
                             operation: Any, evaluated_at: datetime) -> EvidenceVerdict:
    """Does authoritative Fabric evidence support preparing this exact claim?

    A supported verdict means the records agree with the caller about what was
    selected, that the binding is still executable as recorded, and that the
    concrete action being requested falls inside the scope the binding was
    admitted under. **It does not mean anything ran, and it is not permission
    to run** — the increments that resolve, verify, and stage an artefact come
    after it, and no adapter exists to run anything at all.

    **`operation` is per-invocation authority and is required.** Selection
    answered which binding serves a request class; it did not answer what
    action is being asked for now, and a `CSEL` carries no operation to read
    one from. So it is named by the caller and checked here, and it is never
    defaulted or inferred — not from the contract's effect class, not from the
    package, and not from the adapter. Inferring it would authorise by
    omission, which is the one thing an authority boundary may not do.
    """
    if not isinstance(evaluated_at, datetime) or evaluated_at.tzinfo is None:
        raise CapabilityError("evaluated_at must be supplied with a timezone offset")

    # Before any record is read: a request that names no action cannot be
    # judged against a scope, and guessing which action was meant is the
    # inference this boundary exists to refuse.
    requested = _usable(operation)
    if requested is None:
        return _refused(REASON_OPERATION_ABSENT)

    selection, missing = _one(fabric_root, expected_uid, expected_gid,
                              SELECTION, selection_id, REASON_SELECTION_ABSENT)
    if missing is not None:
        return _refused(missing)

    # The selection names the instance. The caller does not get to.
    selected = _text(selection, "selected_instance_id")
    if selected is None:
        return _refused(REASON_SELECTION_REFUSED)
    if selected != instance_id:
        return _refused(REASON_INSTANCE_MISMATCH)

    instance, missing = _one(fabric_root, expected_uid, expected_gid,
                             INSTANCE, selected, REASON_INSTANCE_ABSENT)
    if missing is not None:
        return _refused(missing)

    if _text(instance, "superseded_by") is not None:
        return _refused(REASON_SUPERSEDED)
    if _text(instance, "lifecycle_state") != ADMITTED:
        return _refused(REASON_NOT_ADMITTED)
    if not _window_open(instance, evaluated_at):
        return _refused(REASON_WINDOW)

    # --- the concrete request, inside the admitted envelope ------------------
    #
    # Admission composed this scope by intersecting the package grant, the host
    # grant, and the operator's admission scope, and refused an empty result.
    # That established what *may* be asked for. What follows establishes that
    # what *is* being asked for is one of those things. Both are needed: the
    # envelope was proved once, against no particular request.
    #
    # Placed before the package and contract are resolved so the cheapest
    # governed refusal wins, and so a request outside scope never reaches a
    # staging decision.
    scope = _scope(instance)
    if scope is None:
        return _refused(REASON_SCOPE)

    capability_claimed = _text(instance, "capability_id")
    if capability_claimed is None:
        return _refused(REASON_INCOHERENT)
    if capability_claimed not in scope[SCOPE_CAPABILITIES]:
        return _refused(REASON_CAPABILITY_SCOPE)

    if requested not in scope[SCOPE_OPERATIONS]:
        return _refused(REASON_OPERATION)

    # The classification comes from the governed request class the selection
    # already recorded, never from the caller: a caller able to name it would
    # be able to name a narrower one than the request it is actually making.
    asked = selection.get("request_class")
    classification = (_text(asked, "data_classification")
                      if isinstance(asked, Mapping) else None)
    if classification is None:
        return _refused(REASON_INCOHERENT)
    if classification not in scope[SCOPE_CLASSIFICATIONS]:
        return _refused(REASON_CLASSIFICATION_SCOPE)

    # The target is the node identity the host declares, resolved from the
    # host the binding names. `permitted_targets` holds node identities, so
    # comparing the `CHOST` identifier would compare the wrong thing and pass
    # for the wrong reason.
    host_id = _text(instance, "capability_host_id")
    if host_id is None:
        return _refused(REASON_INCOHERENT)
    host, missing = _one(fabric_root, expected_uid, expected_gid,
                         HOST, host_id, REASON_HOST_ABSENT)
    if missing is not None:
        return _refused(missing)
    node = _text(host, "node_identity_reference")
    if node is None:
        return _refused(REASON_INCOHERENT)
    if node not in scope[SCOPE_TARGETS]:
        return _refused(REASON_TARGET_SCOPE)

    bound_package = _text(instance, "capability_package_id")
    if bound_package is None:
        return _refused(REASON_INCOHERENT)
    if bound_package != capability_package_id:
        return _refused(REASON_PACKAGE_MISMATCH)

    package, missing = _one(fabric_root, expected_uid, expected_gid,
                            PACKAGE, bound_package, REASON_PACKAGE_ABSENT)
    if missing is not None:
        return _refused(missing)

    contract_id = _text(instance, "contract_id")
    if contract_id is None:
        return _refused(REASON_INCOHERENT)
    contract, missing = _one(fabric_root, expected_uid, expected_gid,
                             CONTRACT, contract_id, REASON_CONTRACT_ABSENT)
    if missing is not None:
        return _refused(missing)

    # Every edge is an equality against a named identity. A package bound to
    # another contract, or a contract bound to another capability, is an
    # incoherent chain rather than a chain with an interesting alternative.
    if _text(package, "contract_id") != contract_id:
        return _refused(REASON_INCOHERENT)

    capability_id = _text(instance, "capability_id")
    if capability_id is None or _text(contract, "capability_id") != capability_id:
        return _refused(REASON_INCOHERENT)

    definition, missing = _one(fabric_root, expected_uid, expected_gid,
                               DEFINITION, capability_id, REASON_CAPABILITY_ABSENT)
    if missing is not None:
        return _refused(missing)
    if _text(definition, "capability_id") != capability_id:
        return _refused(REASON_INCOHERENT)

    # Read from the contract, never supplied and never inferred from the
    # definition, so a contract cannot be executed under another's class.
    effect_class = _text(contract, "effect_class")
    if effect_class not in EXECUTABLE_EFFECT_CLASSES:
        return _refused(REASON_EFFECT_CLASS)

    return EvidenceVerdict(
        True, None,
        selection_id=_text(selection, "selection_id"),
        instance_id=selected,
        capability_package_id=bound_package,
        contract_id=contract_id,
        capability_id=capability_id,
        effect_class=effect_class,
        artifact_reference=_text(package, "artifact_reference"),
        manifest_reference=_text(package, "manifest_reference"),
        operation=requested,
        target_node_identity=node,
    )
