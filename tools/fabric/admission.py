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
from .evidence import assemble_evidence, validate_record_evidence
from .identifiers import PREFIXES
from .models import EFFECT_CLASSES, RECORD_MODELS
from .request_identity import (
    REPLAY_CONFLICT, REPLAY_EXACT, compute_request_digest, replay_lookup,
    validate_request_id,
)
from .store import ID_WIDTHS
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

# Categories the part-2 operations add. Each names a condition that did not
# exist before instances and routes did; none replaces or widens one above.
REASON_PACKAGE_OWNER = "package-not-of-capability"
REASON_ADVERT_SUBJECT = "advertisement-not-of-subject"
REASON_ADVERT_CONTRACT = "advertisement-not-of-contract"
REASON_ADVERT_PACKAGE = "advertisement-not-of-package"
REASON_ADVERT_STALE = "advertisement-not-fresh"
REASON_ADMISSION_EXPIRED = "admission-window-expired"
REASON_EMPTY_SCOPE = "empty-effective-scope"
REASON_CLASSIFICATION = "data-classification-exceeds-ceiling"
REASON_NO_CANDIDATE = "no-declared-candidate"
REASON_DUPLICATE_CANDIDATE = "duplicate-candidate"
REASON_CANDIDATE_OWNER = "candidate-not-of-route"
REASON_ROUTE_VERSION = "invalid-route-version"
REASON_SUPERSEDES_SUBJECT = "supersedes-different-subject"

# The trust domain every capability package is decided in, per the accepted
# package schema. It is a constant of the contract, not a caller's choice.
PACKAGE_TRUST_DOMAIN = "capability-package"

# The domain a fabric host is a trust subject in, per the accepted host schema.
HOST_TRUST_DOMAIN = "fabric-node"

# The released Trust Plane scope vocabulary, read rather than restated. The
# Fabric defines no scope algebra of its own: the operator supplies the
# intersection, and this only asks what it permits.
SCOPE_CLASSIFICATIONS = "permitted_data_classifications"

# A C3 refusal that means the Trust Plane could not answer at all, rather than
# that it answered no.
TRUST_UNAVAILABLE = "trust-unavailable"

# A schema-valid identity of the right kind and width that C1 never allocates,
# because every sequence starts at 1. It exists only to prove that the exact
# evidence and record content are constructible *before* an identity is
# allocated. It is never returned, never written, and never persisted.
PROBE_IDS = {kind: f"{prefix}-{0:0{ID_WIDTHS[kind]}d}"
             for kind, prefix in PREFIXES.items()}


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


def _stored_instant(value: Any) -> datetime | None:
    """An instant read back off a stored record, or nothing at all.

    A stored timestamp arrives either already parsed or as its offset-carrying
    text. One without an offset is not a point in time, so it is reported as
    absent rather than placed in a zone nobody wrote down.
    """
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
        except ValueError:
            return None
    else:
        return None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        return None
    return parsed


def _verified_standing(trust_store, record_id: Any, evaluated_at: datetime,
                       domain: str):
    """One C3 answer about one subject, or C3's own refusal reported unchanged.

    The Fabric asks; it never reads a trust record and never forms a verdict.
    A refusal keeps the reason C3 gave it, so a caller can explain what
    happened without the Fabric restating a judgement it does not own.
    """
    verification = verify_trust_record(trust_store, record_id,
                                       evaluated_at=evaluated_at,
                                       expected_subject_type=domain)
    if verification.status == UNVERIFIED:
        reason = verification.reasons[0] if verification.reasons else REASON_UNRESOLVED
        _refuse(UNAVAILABLE if reason == TRUST_UNAVAILABLE else REFUSED, reason)
    return verification


def _no_self_governance(actor: Any, approving_authority: Any,
                        *identities: Any) -> None:
    """A machine governs nothing about itself, under any identity it has."""
    for identity in identities:
        if identity is not None and identity in (actor, approving_authority):
            _refuse(REFUSED, REASON_SELF_ADMISSION)


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


def _human_preflight(actor: Any, approving_authority: Any, *instants: Any) -> None:
    """The structure a human-authorised request must have to be a request.

    Named authority and real instants only. Everything checked here is checked
    before the request is identified, because a value of the wrong form does
    not describe a *different* request -- it describes none.
    """
    _human_authority(actor, approving_authority)
    for instant in instants:
        _aware(instant)


def _digestible(payload: Mapping[str, Any],
                instants: tuple[str, ...]) -> dict[str, Any]:
    """The authoritative payload in the form the released canonicaliser reads.

    Only the named timestamp fields become text, and only because the preflight
    has already proved each of them is a timezone-aware `datetime`. Converting
    by *type* instead would erase the difference between an instant and its own
    ISO rendering: the two would canonicalise identically, and a malformed
    request could borrow an accepted one's identity and be answered with its
    record. A `datetime` anywhere else is left alone, so the released
    canonicaliser refuses it as the unrepresentable value it is.
    """
    return {name: value.isoformat() if name in instants else value
            for name, value in payload.items()}


def _governed(store, *, operation: str, request_id: Any,
              payload: Mapping[str, Any], instants: tuple[str, ...], preflight,
              accept) -> OperationResult:
    """The operation boundary every governed acceptance shares.

    **The digest covers the whole operation.** Every caller-supplied
    authoritative input participates, including the optional ones supplied as
    nothing, so a reused request identity carrying any changed input is a
    conflict rather than a replay of an operation nobody submitted. Nothing
    else participates: not the request identity, not an allocated record
    identity, not a store, and not a resolved prerequisite, because none of
    those is what the caller asked for.

    **Structure is judged before identity.** The preflight runs first, so a
    request identity that cannot be validated, authority that is missing or
    prohibited, an instant that is not an instant, a window that closes before
    it opens, or a payload the released canonicaliser cannot represent is
    refused before the critical section is entered and before replay is
    classified at all. Answering a malformed request with a replay or a
    conflict would report on an operation nobody submitted, and there is
    nothing yet to serialise against either way.

    One acquisition of the critical section, taken before replay lookup and
    held through allocation and the accepted write.
    """
    supplied = request_id if isinstance(request_id, str) else ""
    try:
        identifier = validate_request_id(request_id)
        preflight()
        digest = compute_request_digest(operation, _digestible(payload, instants))
    except _Refusal as refusal:
        return OperationResult(refusal.outcome, supplied, reason=refusal.reason)
    except Exception:  # noqa: BLE001
        # Including whatever a hostile timestamp raises while being examined or
        # rendered. It is named as malformed content and never echoed.
        return OperationResult(INVALID, supplied, reason=REASON_CONTENT)

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


def _constructed(kind: str, identifier: str, evidence: Mapping[str, Any], build):
    """The complete record, or a controlled refusal naming malformed content.

    Freezing, conversion, evidence validation, and the model's own rules all
    run here, so a caller value that fails any of them is named as malformed
    content rather than raised. A raw exception would carry the rejected value,
    its type, a path, or an address out of the governed boundary.
    """
    try:
        record = build(identifier, evidence)
        validate_record_evidence(kind, record)
        record.to_dict()
    except _Refusal:
        raise
    except Exception:  # noqa: BLE001
        _refuse(INVALID, REASON_CONTENT)
    return record


def _commit(store, kind: str, evidence: Mapping[str, Any],
            build) -> tuple[str, str]:
    """Prove the record is constructible, then allocate through C1 and write.

    Allocation advances a persistent sequence, so nothing is allocated until
    the exact evidence and record content are known to be constructible.
    The proof is a construction against a probe identity of this kind and
    width -- the model's own rules applied to the real content, not a
    restatement of them -- which allocates nothing, writes nothing, and leaves
    nothing behind. Only then does C1 mint the identity the record will carry.
    """
    _constructed(kind, PROBE_IDS[kind], evidence, build)
    identifier = store.allocate_id(kind)
    record = _constructed(kind, identifier, evidence, build)
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
        _text(name, REASON_CONTENT)
        _text(description, REASON_CONTENT)
        _effect_class(effect_class)
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

    return _governed(store, operation="declare-capability", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at, "name": name,
                              "description": description,
                              "effect_class": effect_class,
                              "contract_ids": contract_ids,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at",),
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


def declare_contract(store, *, request_id: Any, actor: Any,
                     approving_authority: Any, recorded_at: Any,
                     capability_id: Any, contract_version: Any, effect_class: Any,
                     determinism_class: Any, request_shape: Any,
                     response_shape: Any, failure_modes: Any,
                     resource_requirements: Any, compatible_with: Any,
                     provenance: Any, description: Any = None) -> OperationResult:
    """Record a versioned interface against a declared capability."""
    def accept(identifier, digest):
        _text(contract_version, REASON_CONTENT)
        _effect_class(effect_class)
        _text(determinism_class, REASON_CONTENT)
        modes = _sequence(failure_modes)
        compatible = _sequence(compatible_with)
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
                           failure_modes=modes,
                           resource_requirements=resource_requirements,
                           compatible_with=compatible,
                           provenance=provenance, description=description,
                           evidence=carried))

    return _governed(store, operation="declare-contract", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_version": contract_version,
                              "effect_class": effect_class,
                              "determinism_class": determinism_class,
                              "request_shape": request_shape,
                              "response_shape": response_shape,
                              "failure_modes": failure_modes,
                              "resource_requirements": resource_requirements,
                              "compatible_with": compatible_with,
                              "provenance": provenance,
                              "description": description},
                     instants=("recorded_at",),
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


def declare_package(store, *, request_id: Any, actor: Any,
                    approving_authority: Any, recorded_at: Any, capability_id: Any,
                    contract_id: Any, satisfied_contract_versions: Any,
                    package_version: Any, artifact_reference: Any,
                    resource_requirements: Any, trust_domain: Any, provenance: Any,
                    description: Any = None) -> OperationResult:
    """Record a package claiming contract versions. Nothing is read or run."""
    def accept(identifier, digest):
        _text(package_version, REASON_CONTENT)
        _text(artifact_reference, REASON_CONTENT)
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

    return _governed(store, operation="declare-package", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "package_version": package_version,
                              "artifact_reference": artifact_reference,
                              "resource_requirements": resource_requirements,
                              "trust_domain": trust_domain,
                              "provenance": provenance,
                              "description": description},
                     instants=("recorded_at",),
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at),
                     accept=accept)


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
        _text(node_identity_reference, REASON_CONTENT)
        _text(location_class, REASON_CONTENT)
        _text(data_classification_ceiling, REASON_CONTENT)
        _text(availability_intent, REASON_CONTENT)
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

    return _governed(store, operation="admit-subject", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "evaluated_at": evaluated_at,
                              "node_identity_reference": node_identity_reference,
                              "fabric_node_trust_record_id":
                                  fabric_node_trust_record_id,
                              "verified_resource_profile":
                                  verified_resource_profile,
                              "verification_reference": verification_reference,
                              "location_class": location_class,
                              "data_classification_ceiling":
                                  data_classification_ceiling,
                              "availability_intent": availability_intent,
                              "provenance": provenance, "name": name,
                              "description": description},
                     instants=("recorded_at", "evaluated_at"),
                     preflight=lambda: _human_preflight(
                         actor, approving_authority, recorded_at, evaluated_at),
                     accept=accept)


# --- 6.3 Register an advertisement ------------------------------------------

def register_advertisement(store, *, request_id: Any, actor: Any, recorded_at: Any,
                           capability_host_id: Any, capability_package_id: Any,
                           contract_id: Any, satisfied_contract_versions: Any,
                           advertised_resource_profile: Any, observed_at: Any,
                           valid_until: Any, provenance: Any,
                           approving_authority: Any = None) -> OperationResult:
    """The subject's own claim. It grants nothing, including to itself."""
    def preflight():
        _text(actor, REASON_ACTOR)
        # No fresh human approval, and none accepted: recording one would make
        # a self-report into an approval. Refused on structure, so naming an
        # approver can never be mistaken for a differently-identified request.
        if approving_authority is not None:
            _refuse(REFUSED, REASON_UNEXPECTED_AUTHORITY)
        _aware(recorded_at)
        _aware(observed_at)
        _aware(valid_until)
        if valid_until <= observed_at:
            _refuse(REFUSED, REASON_WINDOW)

    def accept(identifier, digest):
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
                           observed_at=observed_at, valid_until=valid_until,
                           provenance=provenance, evidence=carried))

    # `approving_authority` is part of what was asked for even though the only
    # acceptable value is none: supplying one is a different request, refused
    # as `unexpected-approving-authority` rather than quietly identical.
    return _governed(store, operation="register-advertisement",
                     request_id=request_id,
                     payload={"actor": actor, "recorded_at": recorded_at,
                              "capability_host_id": capability_host_id,
                              "capability_package_id": capability_package_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "advertised_resource_profile":
                                  advertised_resource_profile,
                              "observed_at": observed_at,
                              "valid_until": valid_until,
                              "provenance": provenance,
                              "approving_authority": approving_authority},
                     instants=("recorded_at", "observed_at", "valid_until"),
                     preflight=preflight, accept=accept)


# --- 6.4 Admit an instance ---------------------------------------------------

def admit_instance(store, trust_store, *, request_id: Any, actor: Any,
                   approving_authority: Any, recorded_at: Any, evaluated_at: Any,
                   capability_id: Any, capability_package_id: Any,
                   capability_host_id: Any, contract_id: Any,
                   satisfied_contract_versions: Any,
                   verified_resource_profile: Any, admission_decision_id: Any,
                   package_trust_record_id: Any, host_trust_record_id: Any,
                   effective_scope: Any, admitted_at: Any, admitted_until: Any,
                   provenance: Any, advertisement_id: Any = None,
                   endpoint_reference: Any = None, supersedes: Any = None,
                   notes: Any = None) -> OperationResult:
    """Bind one package to one host for one contract. A human decides this.

    **A trust verdict alone never creates an instance**, and neither does an
    advertisement. Both are consulted; the decision is the operator's, and it
    is the approving authority on this record that makes the binding exist.

    Trust is composed by intersection and never inherited: the package is
    verified in `capability-package`, the host in `fabric-node`, separately,
    through C3 and nowhere else. Trusting one trusts nothing about the other.

    **Comparison is containment, and versions are declared.** The operator's
    verified profile is authoritative -- never the advertised one -- and no
    number here is ordered, no version string is interpreted, and no nearest
    compatible match is sought.

    Nothing about eligibility is computed or stored. These are the admission-
    time preconditions §6.4 requires; the derived verdict belongs to C5.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at, evaluated_at,
                         admitted_at, admitted_until)
        if admitted_until <= admitted_at:
            _refuse(REFUSED, REASON_WINDOW)
        _sequence(satisfied_contract_versions)
        _mapping(verified_resource_profile)
        _mapping(effective_scope)
        _mapping(provenance)

    def accept(identifier, digest):
        # 1. Content the operator supplied, before anything is dereferenced.
        _text(admission_decision_id, REASON_CONTENT)
        versions = _sequence(satisfied_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)
        profile = _mapping(verified_resource_profile)
        scope = _mapping(effective_scope)

        # 2. Every reference resolves before any relationship is read from it.
        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        package = _resolve(store, "capability-package", capability_package_id)
        host = _resolve(store, "capability-host", capability_host_id)
        advertisement = _resolve(store, "capability-advertisement", advertisement_id)
        node = host.get("node_identity_reference")

        # 3. No machine admits its own binding, under either identity it has.
        _no_self_governance(actor, approving_authority, node, capability_host_id)

        # 4. The four records must describe one binding, not four opinions.
        if package.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_PACKAGE_OWNER)
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)
        if package.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_PACKAGE_CONTRACT)
        if advertisement.get("capability_host_id") != capability_host_id:
            _refuse(REFUSED, REASON_ADVERT_SUBJECT)
        if advertisement.get("contract_id") != contract_id:
            _refuse(REFUSED, REASON_ADVERT_CONTRACT)
        if advertisement.get("capability_package_id") != capability_package_id:
            _refuse(REFUSED, REASON_ADVERT_PACKAGE)

        # 5. Declared versions only: set membership, twice, with no arithmetic.
        declared = tuple(package.get("satisfied_contract_versions") or ())
        advertised = tuple(advertisement.get("satisfied_contract_versions") or ())
        if any(version not in declared for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)
        if any(version not in advertised for version in versions):
            _refuse(REFUSED, REASON_VERSIONS)

        # 6. Both clocks the caller can be judged against, at the caller's own
        #    evaluation instant. Nothing here reads a system clock.
        observed = _stored_instant(advertisement.get("observed_at"))
        expires = _stored_instant(advertisement.get("valid_until"))
        if observed is None or expires is None:
            _refuse(REFUSED, REASON_ADVERT_STALE)
        if not observed <= evaluated_at < expires:
            _refuse(REFUSED, REASON_ADVERT_STALE)
        if evaluated_at >= admitted_until:
            _refuse(REFUSED, REASON_ADMISSION_EXPIRED)

        # 7. Trust, twice, in two domains, through C3 and nowhere else.
        package_standing = _verified_standing(
            trust_store, package_trust_record_id, evaluated_at,
            PACKAGE_TRUST_DOMAIN)
        host_standing = _verified_standing(
            trust_store, host_trust_record_id, evaluated_at, HOST_TRUST_DOMAIN)
        # Each verified subject must be the fabric subject it authorises. The
        # package's is its artifact reference, as the host's is its node
        # identity reference: the external identity the Trust Plane decided on,
        # never the Fabric's own record identifier.
        if package_standing.subject_id != package.get("artifact_reference"):
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)
        if host_standing.subject_id != node:
            _refuse(REFUSED, REASON_SUBJECT_MISMATCH)

        # 8. Containment against what the operator verified, never what the
        #    host claimed, and never an ordering of two numbers.
        verified = host.get("verified_resource_profile")
        if not isinstance(verified, Mapping) or dict(profile) != dict(verified):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)
        requirements = package.get("resource_requirements")
        if not isinstance(requirements, Mapping):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)
        if not _contained(requirements, verified):
            _refuse(REFUSED, REASON_RESOURCE_CLAIM)

        # 9. An empty intersection is a valid outcome, and it admits nothing.
        if not scope:
            _refuse(REFUSED, REASON_EMPTY_SCOPE)
        permitted = scope.get(SCOPE_CLASSIFICATIONS)
        if permitted is not None:
            if isinstance(permitted, str) or not isinstance(permitted, (list, tuple)):
                _refuse(INVALID, REASON_CONTENT)
            ceiling = host.get("data_classification_ceiling")
            for classification in permitted:
                # Containment, not ordering: the accepted vocabulary declares
                # no ranking of classifications, so none is inferred here.
                if classification != ceiling:
                    _refuse(REFUSED, REASON_CLASSIFICATION)

        references = [capability_id, contract_id, capability_package_id,
                      capability_host_id, advertisement_id]
        if supersedes is not None:
            # Migration destroys one binding and declares another; it never
            # repoints an instance, and the prior record is left as written.
            _resolve(store, "capability-instance", supersedes)
            references.append(supersedes)
        evidence = _evidence(
            "capability-instance", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession" if supersedes is not None
            else "instance-admission",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=tuple(references),
            trust_evidence_references=(package_trust_record_id,
                                       host_trust_record_id))
        return _commit(store, "capability-instance", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-instance"](
                           instance_id=allocated, capability_id=capability_id,
                           capability_package_id=capability_package_id,
                           capability_host_id=capability_host_id,
                           contract_id=contract_id,
                           satisfied_contract_versions=versions,
                           verified_resource_profile=profile,
                           admission_decision_id=admission_decision_id,
                           package_trust_record_id=package_trust_record_id,
                           host_trust_record_id=host_trust_record_id,
                           effective_scope=scope, admitted_at=admitted_at,
                           admitted_until=admitted_until,
                           advertisement_id=advertisement_id,
                           endpoint_reference=endpoint_reference,
                           supersedes=supersedes, provenance=provenance,
                           notes=notes, evidence=carried))

    return _governed(store, operation="admit-instance", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "evaluated_at": evaluated_at,
                              "capability_id": capability_id,
                              "capability_package_id": capability_package_id,
                              "capability_host_id": capability_host_id,
                              "contract_id": contract_id,
                              "satisfied_contract_versions":
                                  satisfied_contract_versions,
                              "verified_resource_profile":
                                  verified_resource_profile,
                              "admission_decision_id": admission_decision_id,
                              "package_trust_record_id": package_trust_record_id,
                              "host_trust_record_id": host_trust_record_id,
                              "effective_scope": effective_scope,
                              "admitted_at": admitted_at,
                              "admitted_until": admitted_until,
                              "advertisement_id": advertisement_id,
                              "endpoint_reference": endpoint_reference,
                              "provenance": provenance,
                              "supersedes": supersedes, "notes": notes},
                     instants=("recorded_at", "evaluated_at", "admitted_at",
                               "admitted_until"),
                     preflight=preflight, accept=accept)


# --- 6.5 Create or supersede a route -----------------------------------------

def create_route(store, *, request_id: Any, actor: Any, approving_authority: Any,
                 recorded_at: Any, capability_id: Any, contract_id: Any,
                 accepted_contract_versions: Any, locality: Any,
                 candidate_instances: Any, data_classification: Any,
                 route_version: Any, provenance: Any, description: Any = None,
                 overlap_window: Any = None, supersedes: Any = None,
                 notes: Any = None) -> OperationResult:
    """Declare which admitted instances may serve a request class, in order.

    **The order is written by a human and stored.** Nothing here derives it,
    and nothing here consults load, latency, success rate, health, or any
    other measurement -- a router that orders candidates by observed behaviour
    is deriving placement from reasoning.

    A route targets admitted instances only: targeting an advertisement would
    mean routing to a self-report. **Cutover is a route change**, so a new
    version is a new record naming the one it supersedes, and the prior route
    is left exactly as written rather than edited to point forward.

    This declares candidates. It selects nothing, excludes nothing, computes
    no eligibility, and writes no selection record.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at)
        _sequence(accepted_contract_versions)
        _sequence(candidate_instances)
        _mapping(provenance)

    def accept(identifier, digest):
        _text(locality, REASON_CONTENT)
        _text(data_classification, REASON_CONTENT)
        if (isinstance(route_version, bool) or not isinstance(route_version, int)
                or route_version < 1):
            _refuse(REFUSED, REASON_ROUTE_VERSION)
        versions = _sequence(accepted_contract_versions)
        if not versions:
            _refuse(REFUSED, REASON_VERSIONS)

        _resolve(store, "capability-definition", capability_id)
        contract = _resolve(store, "capability-contract", contract_id)
        if contract.get("capability_id") != capability_id:
            _refuse(REFUSED, REASON_CONTRACT_OWNER)

        if supersedes is not None:
            prior = _resolve(store, "capability-route", supersedes)
            if (prior.get("capability_id") != capability_id
                    or prior.get("contract_id") != contract_id):
                _refuse(REFUSED, REASON_SUPERSEDES_SUBJECT)
            previous = prior.get("route_version")
            if (isinstance(previous, bool) or not isinstance(previous, int)
                    or route_version <= previous):
                _refuse(REFUSED, REASON_ROUTE_VERSION)

        candidates = _sequence(candidate_instances)
        if not candidates:
            _refuse(REFUSED, REASON_NO_CANDIDATE)
        seen: list = []
        for candidate in candidates:
            # Compared by equality rather than hashed: a candidate the caller
            # supplied need not be hashable to be refused.
            if candidate in seen:
                _refuse(REFUSED, REASON_DUPLICATE_CANDIDATE)
            seen.append(candidate)
        for candidate in candidates:
            instance = _resolve(store, "capability-instance", candidate)
            if (instance.get("capability_id") != capability_id
                    or instance.get("contract_id") != contract_id):
                _refuse(REFUSED, REASON_CANDIDATE_OWNER)
        if overlap_window is not None:
            _mapping(overlap_window)

        references = [capability_id, contract_id, *candidates]
        if supersedes is not None:
            references.append(supersedes)
        evidence = _evidence(
            "capability-route", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession" if supersedes is not None
            else "route-change",
            recorded_at=recorded_at, request_id=identifier, request_digest=digest,
            causal_references=tuple(references))
        return _commit(store, "capability-route", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-route"](
                           route_id=allocated, route_version=route_version,
                           capability_id=capability_id, contract_id=contract_id,
                           accepted_contract_versions=versions,
                           locality=locality, candidate_instances=candidates,
                           data_classification=data_classification,
                           provenance=provenance, description=description,
                           overlap_window=overlap_window, supersedes=supersedes,
                           notes=notes, evidence=carried))

    # `candidate_instances` is authoritative in order, so it is digested in
    # order. `accepted_contract_versions` is a set by the released contract and
    # is ordered deterministically before digesting, as sets already are.
    return _governed(store, operation="create-route", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_id": capability_id,
                              "contract_id": contract_id,
                              "accepted_contract_versions":
                                  accepted_contract_versions,
                              "locality": locality,
                              "candidate_instances": candidate_instances,
                              "data_classification": data_classification,
                              "route_version": route_version,
                              "provenance": provenance,
                              "description": description,
                              "overlap_window": overlap_window,
                              "supersedes": supersedes, "notes": notes},
                     instants=("recorded_at",),
                     preflight=preflight, accept=accept)


# --- 6.6 Withdraw or retire a subject by decision ----------------------------

def withdraw_subject(store, *, request_id: Any, actor: Any,
                     approving_authority: Any, recorded_at: Any,
                     capability_host_id: Any, availability_intent: Any,
                     provenance: Any, notes: Any = None) -> OperationResult:
    """End a subject's availability by decision. Nothing is edited or deleted.

    **Withdrawal is a decision, not an event.** A host that fails, disappears,
    or stops advertising has changed no authoritative state; a host is removed
    from service because an operator said so, and `availability_intent` is
    where that is said.

    The successor supersedes the prior record and carries the same verified
    facts about the same machine. The prior record stays byte-identical and
    readable -- it is not edited to point at what replaced it, because a record
    that can be rewritten after the fact is not a history.

    **No trust is consulted and none is changed.** Withdrawing a host says
    nothing about whether it is trusted; that is the Trust Plane's to say, and
    the successor references the same trust record rather than restating it.
    """
    def preflight():
        _human_preflight(actor, approving_authority, recorded_at)
        _mapping(provenance)

    def accept(identifier, digest):
        _text(availability_intent, REASON_CONTENT)
        prior = _resolve(store, "capability-host", capability_host_id)
        node = prior.get("node_identity_reference")
        # A subject does not decide its own withdrawal any more than its own
        # admission.
        _no_self_governance(actor, approving_authority, node, capability_host_id)
        trust_reference = prior.get("fabric_node_trust_record_id")

        evidence = _evidence(
            "capability-host", actor=actor,
            approving_authority=approving_authority,
            reason_category="supersession", recorded_at=recorded_at,
            request_id=identifier, request_digest=digest,
            causal_references=(capability_host_id,),
            trust_evidence_references=(trust_reference,))
        return _commit(store, "capability-host", evidence,
                       lambda allocated, carried: RECORD_MODELS[
                           "capability-host"](
                           capability_host_id=allocated,
                           node_identity_reference=node,
                           fabric_node_trust_record_id=trust_reference,
                           verified_resource_profile=prior.get(
                               "verified_resource_profile"),
                           location_class=prior.get("location_class"),
                           data_classification_ceiling=prior.get(
                               "data_classification_ceiling"),
                           availability_intent=availability_intent,
                           provenance=provenance, name=prior.get("name"),
                           description=prior.get("description"),
                           verification_reference=prior.get(
                               "verification_reference"),
                           supersedes=capability_host_id, notes=notes,
                           evidence=carried))

    return _governed(store, operation="withdraw-subject", request_id=request_id,
                     payload={"actor": actor,
                              "approving_authority": approving_authority,
                              "recorded_at": recorded_at,
                              "capability_host_id": capability_host_id,
                              "availability_intent": availability_intent,
                              "provenance": provenance, "notes": notes},
                     instants=("recorded_at",),
                     preflight=preflight, accept=accept)
