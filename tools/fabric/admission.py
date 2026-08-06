"""The first governed acceptances: declaration, subject admission, advertisement.

Five operation classes, one shape. Each validates what the caller supplied,
derives its request digest, enters `request_critical_section` **once**, resolves
replay inside it, and holds it through allocation and the accepted write. The
replay helper never enters it, so nesting is impossible by construction.

**A refusal writes nothing.** Not a queued record, not a pending one, not a
partial one. An advertisement from an unadmitted subject is *"not a pending
record -- it is not a record at all"*, and the same is true of every other
refusal here: prerequisites are resolved before an identity is allocated, so
there is nothing to undo.

**Authority differs by operation, and the difference is the point.** Declaring
and admitting are human decisions and record an approving operator. Publishing
an advertisement is not: the admitted subject acts as itself, and an approving
operator is *refused* rather than ignored, because recording one would turn a
self-report into an approval.

**Trust is reached only through C3.** No trust record is read here, no trust
verdict is formed here, and nothing here writes trust state in either
direction. A refusal keeps C3's own reason rather than restating it.

**Comparison is containment, never interpretation.** The accepted package
schema says resources are *"declared in the same controlled vocabulary a host
uses to describe itself, so that matching is containment rather than
interpretation"*. So an advertised claim must be contained by what the operator
verified; nothing here orders a memory size or ranks an accelerator class.

This increment declares, admits, and records claims. It admits no instance,
creates no route, computes no eligibility, and chooses nothing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from .errors import FabricError
from .evidence import assemble_evidence
from .models import EFFECT_CLASSES, RECORD_MODELS
from .request_identity import (
    REPLAY_CONFLICT, REPLAY_EXACT, compute_request_digest, replay_lookup,
    validate_request_id,
)
from .trust_adapter import UNVERIFIED, verify_trust_record

# Outcomes. `accepted` and `exact-replay` are the only two that leave a record.
ACCEPTED = "accepted"
EXACT_REPLAY = "exact-replay"
REFUSED = "refused"
INVALID = "invalid"
NOT_FOUND = "not-found"
CONFLICT = "conflict"
UNAVAILABLE = "unavailable"

# Controlled refusal categories. A caller acts on these; none is derived from
# an exception, a path, or a rejected value.
REASON_CONFLICT = "request_identity_conflict"
REASON_ACTOR = "missing-actor"
REASON_AUTHORITY = "missing-approving-authority"
REASON_UNEXPECTED_AUTHORITY = "unexpected-approving-authority"
REASON_NOT_SUBJECT = "actor-is-not-the-subject"
REASON_SELF_ADMISSION = "self-admission"
REASON_EFFECT_CLASS = "unknown-effect-class"
REASON_TRUST_DOMAIN = "unknown-trust-domain"
REASON_UNRESOLVED = "unresolved-reference"
REASON_CONTRACT_OWNER = "contract-not-of-capability"
REASON_PACKAGE_CONTRACT = "contract-not-of-package"
REASON_VERSIONS = "versions-not-declared"
REASON_RESOURCE_CLAIM = "resource-claim-not-verified"
REASON_WINDOW = "invalid-validity-window"
REASON_NAIVE_INSTANT = "timestamp-carries-no-offset"
REASON_SUBJECT_MISMATCH = "trust-subject-mismatch"
REASON_UNVERIFIED_PROFILE = "resource-profile-not-verified-out-of-band"
REASON_CONTENT = "malformed-operation-content"

# The trust domain every capability package is decided in, per the accepted
# package schema. It is a constant of the contract, not a caller's choice.
PACKAGE_TRUST_DOMAIN = "capability-package"

# The domain a fabric host is a trust subject in, per the accepted host schema.
HOST_TRUST_DOMAIN = "fabric-node"

# A C3 refusal that means the Trust Plane could not answer at all, rather than
# that it answered no.
TRUST_UNAVAILABLE = "trust-unavailable"


@dataclass(frozen=True)
class OperationResult:
    """What one governed operation did. Immutable, and never persisted."""

    outcome: str
    request_id: str
    request_digest: str | None = None
    record_kind: str | None = None
    record_id: str | None = None
    reason: str | None = None

    @property
    def accepted(self) -> bool:
        return self.outcome == ACCEPTED

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome,
            "request_id": self.request_id,
            "request_digest": self.request_digest,
            "record_kind": self.record_kind,
            "record_id": self.record_id,
            "reason": self.reason,
        }


class _Refusal(Exception):
    """Internal: a governed refusal, carrying its outcome and category."""

    def __init__(self, outcome: str, reason: str) -> None:
        super().__init__(reason)
        self.outcome = outcome
        self.reason = reason


def _refuse(outcome: str, reason: str) -> None:
    raise _Refusal(outcome, reason)


def _text(value: Any, reason: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _refuse(INVALID, reason)
    return value


def _aware(value: Any, reason: str = REASON_NAIVE_INSTANT) -> datetime:
    if not isinstance(value, datetime):
        _refuse(INVALID, reason)
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        _refuse(INVALID, reason)
    return value


def _mapping(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        _refuse(INVALID, REASON_CONTENT)
    return value


def _sequence(value: Any) -> tuple:
    if isinstance(value, str) or not isinstance(value, (list, tuple)):
        _refuse(INVALID, REASON_CONTENT)
    return tuple(value)


def _human_authority(actor: Any, approving_authority: Any) -> tuple[str, str]:
    """A human-authorised operation names who acted and who approved."""
    _text(actor, REASON_ACTOR)
    _text(approving_authority, REASON_AUTHORITY)
    return actor, approving_authority


def _effect_class(value: Any) -> str:
    # Exactly one released class. Not trimmed, not recased: an effect class
    # that had to be corrected to be recognised was not declared.
    if value not in EFFECT_CLASSES:
        _refuse(REFUSED, REASON_EFFECT_CLASS)
    return value


def _resolve(store, kind: str, identifier: Any) -> Mapping[str, Any]:
    """The referenced record, or a deterministic not-found refusal."""
    if not isinstance(identifier, str) or not identifier.strip():
        _refuse(NOT_FOUND, REASON_UNRESOLVED)
    try:
        return store.read_record(kind, identifier)
    except FabricError:
        _refuse(NOT_FOUND, REASON_UNRESOLVED)
    except Exception:  # noqa: BLE001
        # A reference that cannot be read is a reference that did not resolve.
        _refuse(NOT_FOUND, REASON_UNRESOLVED)


def _contained(claim: Mapping[str, Any], verified: Mapping[str, Any]) -> bool:
    """Containment, not interpretation.

    Every claimed dimension must be one the operator verified, with the value
    the operator verified. Ordering a memory size here would be the
    interpretation the accepted vocabulary rules out, and a dimension nobody
    verified is a claim about something nobody looked at.
    """
    for name, value in claim.items():
        if name not in verified or verified[name] != value:
            return False
    return True


def _governed(store, *, operation: str, request_id: Any, inputs: Mapping[str, Any],
              accept) -> OperationResult:
    """The operation boundary every governed acceptance shares.

    One acquisition of the critical section, taken before replay lookup and
    held through allocation and the accepted write.
    """
    identifier = validate_request_id(request_id)
    digest = compute_request_digest(operation, inputs)

    with store.request_critical_section(identifier):
        replay = replay_lookup(store, identifier, digest)
        if replay.status == REPLAY_EXACT:
            return OperationResult(EXACT_REPLAY, identifier, digest,
                                   replay.record_kind, replay.record_id)
        if replay.status == REPLAY_CONFLICT:
            return OperationResult(CONFLICT, identifier, digest,
                                   reason=REASON_CONFLICT)
        try:
            kind, record_id = accept(identifier, digest)
        except _Refusal as refusal:
            return OperationResult(refusal.outcome, identifier, digest,
                                   reason=refusal.reason)
        return OperationResult(ACCEPTED, identifier, digest, kind, record_id)


def _commit(store, kind: str, evidence: Mapping[str, Any],
            build) -> tuple[str, str]:
    """Allocate through C1, construct the model, and write through C1."""
    identifier = store.allocate_id(kind)
    try:
        record = build(identifier, evidence)
    except FabricError:
        _refuse(INVALID, REASON_CONTENT)
    store.write(kind, record)
    return kind, identifier


def _evidence(kind: str, *, actor: str, approving_authority: str | None,
              reason_category: str, recorded_at: datetime, request_id: str,
              request_digest: str, causal_references=(),
              trust_evidence_references=()) -> Mapping[str, Any]:
    try:
        return assemble_evidence(
            kind, actor=actor, approving_authority=approving_authority,
            reason_category=reason_category, recorded_at=recorded_at,
            request_id=request_id, request_digest=request_digest,
            causal_references=tuple(causal_references),
            trust_evidence_references=tuple(trust_evidence_references))
    except FabricError:
        _refuse(INVALID, REASON_CONTENT)


# --- 6.1 Declare capability, contract, or package ---------------------------

def declare_capability(store, *, request_id: Any, actor: Any,
                       approving_authority: Any, recorded_at: Any, name: Any,
                       description: Any, effect_class: Any, contract_ids: Any,
                       provenance: Any, notes: Any = None) -> OperationResult:
    """Record an abstract ability. Declaration confers nothing."""
    def accept(identifier, digest):
        _human_authority(actor, approving_authority)
        _text(name, REASON_CONTENT)
        _text(description, REASON_CONTENT)
        _effect_class(effect_class)
        _aware(recorded_at)
        _mapping(provenance)
        references = _sequence(contract_ids)
        for reference in references:
            _resolve(store, "capability-contract", reference)
        evidence = _evidence(
            "capability-definition", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=references)
        return _commit(store, "capability-definition", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-definition"](
                           capability_id=allocated, name=name,
                           description=description, effect_class=effect_class,
                           contract_ids=references, provenance=provenance,
                           notes=notes, evidence=carried))

    return _guarded(store, "declare-capability", request_id, accept, {
        "name": name, "description": description, "effect_class": effect_class,
        "contract_ids": list(contract_ids) if isinstance(
            contract_ids, (list, tuple)) else contract_ids})


def declare_contract(store, *, request_id: Any, actor: Any,
                     approving_authority: Any, recorded_at: Any,
                     capability_id: Any, contract_version: Any, effect_class: Any,
                     determinism_class: Any, request_shape: Any,
                     response_shape: Any, failure_modes: Any,
                     resource_requirements: Any, compatible_with: Any,
                     provenance: Any, description: Any = None) -> OperationResult:
    """Record a versioned interface against a declared capability."""
    def accept(identifier, digest):
        _human_authority(actor, approving_authority)
        _text(contract_version, REASON_CONTENT)
        _effect_class(effect_class)
        _text(determinism_class, REASON_CONTENT)
        _aware(recorded_at)
        _resolve(store, "capability-definition", capability_id)
        evidence = _evidence(
            "capability-contract", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=(capability_id,))
        return _commit(store, "capability-contract", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-contract"](
                           contract_id=allocated, capability_id=capability_id,
                           contract_version=contract_version,
                           effect_class=effect_class,
                           determinism_class=determinism_class,
                           request_shape=request_shape,
                           response_shape=response_shape,
                           failure_modes=_sequence(failure_modes),
                           resource_requirements=resource_requirements,
                           compatible_with=_sequence(compatible_with),
                           provenance=provenance, description=description,
                           evidence=carried))

    return _guarded(store, "declare-contract", request_id, accept, {
        "capability_id": capability_id, "contract_version": contract_version,
        "effect_class": effect_class, "determinism_class": determinism_class})


def declare_package(store, *, request_id: Any, actor: Any,
                    approving_authority: Any, recorded_at: Any, capability_id: Any,
                    contract_id: Any, satisfied_contract_versions: Any,
                    package_version: Any, artifact_reference: Any,
                    resource_requirements: Any, trust_domain: Any, provenance: Any,
                    description: Any = None) -> OperationResult:
    """Record a package claiming contract versions. Nothing is read or run."""
    def accept(identifier, digest):
        _human_authority(actor, approving_authority)
        _text(package_version, REASON_CONTENT)
        _text(artifact_reference, REASON_CONTENT)
        _aware(recorded_at)
        if trust_domain != PACKAGE_TRUST_DOMAIN:
            _refuse(REFUSED, REASON_TRUST_DOMAIN)
        versions = _sequence(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)
        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        # One package implements one definition against one contract.
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)
        # Explicit, never inferred from a version string.
        if contract.get("contract_version") not in versions:
            _refuse(REFUSED, REASON_VERSIONS)
        evidence = _evidence(
            "capability-package", actor=actor,
            approving_authority=approving_authority, reason_category="declaration",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=(capability_id, contract_id))
        return _commit(store, "capability-package", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-package"](
                           capability_package_id=allocated,
                           capability_id=capability_id, contract_id=contract_id,
                           satisfied_contract_versions=versions,
                           package_version=package_version,
                           artifact_reference=artifact_reference,
                           resource_requirements=resource_requirements,
                           trust_domain=trust_domain, provenance=provenance,
                           description=description, evidence=carried))

    return _guarded(store, "declare-package", request_id, accept, {
        "capability_id": capability_id, "contract_id": contract_id,
        "package_version": package_version,
        "artifact_reference": artifact_reference,
        "satisfied_contract_versions": list(satisfied_contract_versions)
        if isinstance(satisfied_contract_versions, (list, tuple))
        else satisfied_contract_versions})


# --- 6.2 Admit a subject (host) to the fabric -------------------------------

def admit_subject(store, trust_store, *, request_id: Any, actor: Any,
                  approving_authority: Any, recorded_at: Any, evaluated_at: Any,
                  node_identity_reference: Any, fabric_node_trust_record_id: Any,
                  verified_resource_profile: Any, verification_reference: Any,
                  location_class: Any, data_classification_ceiling: Any,
                  availability_intent: Any, provenance: Any,
                  name: Any = None, description: Any = None) -> OperationResult:
    """Make a machine a fabric participant. There is no automatic path."""
    def accept(identifier, digest):
        _human_authority(actor, approving_authority)
        _text(node_identity_reference, REASON_CONTENT)
        _text(location_class, REASON_CONTENT)
        _text(data_classification_ceiling, REASON_CONTENT)
        _text(availability_intent, REASON_CONTENT)
        _aware(recorded_at)
        _aware(evaluated_at)
        profile = _mapping(verified_resource_profile)
        # Verified out of band, and provably so. A profile with nothing
        # recording how it was obtained cannot be distinguished from one copied
        # off an advertisement, which §6.2 rejects.
        _text(verification_reference, REASON_UNVERIFIED_PROFILE)
        # A subject cannot approve its own admission.
        if (actor == node_identity_reference
                or approving_authority == node_identity_reference):
            _refuse(REFUSED, REASON_SELF_ADMISSION)

        verification = verify_trust_record(
            trust_store, fabric_node_trust_record_id, evaluated_at=evaluated_at,
            expected_subject_type=HOST_TRUST_DOMAIN)
        if verification.status == UNVERIFIED:
            reason = verification.reasons[0] if verification.reasons else REASON_UNRESOLVED
            _refuse(UNAVAILABLE if reason == TRUST_UNAVAILABLE else REFUSED, reason)
        # The verified subject must be the machine being admitted.
        if verification.subject_id != node_identity_reference:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)

        evidence = _evidence(
            "capability-host", actor=actor,
            approving_authority=approving_authority,
            reason_category="subject-admission", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            trust_evidence_references=(fabric_node_trust_record_id,))
        return _commit(store, "capability-host", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-host"](
                           capability_host_id=allocated,
                           node_identity_reference=node_identity_reference,
                           fabric_node_trust_record_id=fabric_node_trust_record_id,
                           verified_resource_profile=profile,
                           location_class=location_class,
                           data_classification_ceiling=data_classification_ceiling,
                           availability_intent=availability_intent,
                           provenance=provenance, name=name,
                           description=description,
                           verification_reference=verification_reference,
                           evidence=carried))

    return _guarded(store, "admit-subject", request_id, accept, {
        "node_identity_reference": node_identity_reference,
        "fabric_node_trust_record_id": fabric_node_trust_record_id,
        "location_class": location_class,
        "data_classification_ceiling": data_classification_ceiling,
        "availability_intent": availability_intent})


# --- 6.3 Register an advertisement ------------------------------------------

def register_advertisement(store, *, request_id: Any, actor: Any, recorded_at: Any,
                           capability_host_id: Any, capability_package_id: Any,
                           contract_id: Any, satisfied_contract_versions: Any,
                           advertised_resource_profile: Any, observed_at: Any,
                           valid_until: Any, provenance: Any,
                           approving_authority: Any = None) -> OperationResult:
    """The subject's own claim. It grants nothing, including to itself."""
    def accept(identifier, digest):
        _text(actor, REASON_ACTOR)
        # No fresh human approval, and none accepted: recording one would make
        # a self-report into an approval.
        if approving_authority is not None:
            _refuse(REFUSED, REASON_UNEXPECTED_AUTHORITY)
        _aware(recorded_at)
        observed = _aware(observed_at)
        until = _aware(valid_until)
        if until <= observed:
            _refuse(REFUSED, REASON_WINDOW)
        claim = _mapping(advertised_resource_profile)
        versions = _sequence(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)

        host = _resolve(store, "capability-host", capability_host_id)
        # A host may advertise only itself.
        if actor != capability_host_id:
            _refuse(REFUSED, REASON_NOT_SUBJECT)

        package = _resolve(store, "capability-package", capability_package_id)
        _resolve(store, "capability-contract", contract_id)
        if package.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_PACKAGE_CONTRACT)
        # Explicit declarations only: no range, no upgrade, no inference.
        declared = tuple(package.get("satisfied_contract_versions") or ())
        if any(version not in declared for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)
        # Containment against what the operator verified.
        if not _contained(claim, host.get("verified_resource_profile") or {}):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)

        evidence = _evidence(
            "capability-advertisement", actor=actor, approving_authority=None,
            reason_category="advertisement-registration", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=(capability_host_id, capability_package_id,
                               contract_id))
        return _commit(store, "capability-advertisement", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-advertisement"](
                           advertisement_id=allocated,
                           capability_host_id=capability_host_id,
                           capability_package_id=capability_package_id,
                           contract_id=contract_id,
                           satisfied_contract_versions=versions,
                           advertised_resource_profile=claim,
                           observed_at=observed, valid_until=until,
                           provenance=provenance, evidence=carried))

    return _guarded(store, "register-advertisement", request_id, accept, {
        "capability_host_id": capability_host_id,
        "capability_package_id": capability_package_id,
        "contract_id": contract_id,
        "satisfied_contract_versions": list(satisfied_contract_versions)
        if isinstance(satisfied_contract_versions, (list, tuple))
        else satisfied_contract_versions,
        "advertised_resource_profile": advertised_resource_profile
        if isinstance(advertised_resource_profile, Mapping) else None,
        "observed_at": observed_at.isoformat()
        if isinstance(observed_at, datetime) else None,
        "valid_until": valid_until.isoformat()
        if isinstance(valid_until, datetime) else None})


def _guarded(store, operation: str, request_id: Any, accept,
             inputs: Mapping[str, Any]) -> OperationResult:
    """Validate the request identity and digest inputs, then run the boundary.

    A malformed identity or an uncanonicalisable input is refused before the
    critical section is entered: there is nothing yet to serialise against.
    """
    try:
        identifier = validate_request_id(request_id)
        digest_inputs = {name: value for name, value in inputs.items()}
        compute_request_digest(operation, digest_inputs)
    except FabricError:
        supplied = request_id if isinstance(request_id, str) else ""
        return OperationResult(INVALID, supplied, reason=REASON_CONTENT)
    return _governed(store, operation=operation, request_id=identifier,
                     inputs=digest_inputs, accept=accept)
