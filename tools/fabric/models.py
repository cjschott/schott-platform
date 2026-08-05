"""Immutable contract models for the eight accepted Fabric record types.

Every model is frozen. A fabric record that can be edited is a placement
history that can be rewritten after the fact, so change is supersession and
these types have no setter to reach for when that feels inconvenient.

What these models cannot express is as deliberate as what they can. There is no
score field, no weight, no command text, and no field capable of carrying a
credential. A stored record carrying one is refused rather than tolerated,
because a field the model does not know is a field nobody reviewed.

Timestamps must carry an offset. A time without a zone is not a point in time,
and every expiry answer depends on placing it.

Fields, identifier widths, and vocabularies come from the accepted schemas in
`platform-model/schemas/capability-*.schema.yaml` and from
docs/decisions/ADR-0012-distributed-capability-fabric.md.

This module is the contract layer only. It stores nothing, allocates nothing,
admits nothing, and chooses nothing.
"""

from __future__ import annotations

from dataclasses import dataclass, fields as dataclass_fields
from datetime import datetime
from types import MappingProxyType
from typing import Any, ClassVar, Mapping

from .errors import FabricError
from .identifiers import PATTERNS

# The api_version every accepted schema declares. A record that does not say
# which contract it was written against cannot be interpreted, and one written
# against a version this code does not know must not be guessed at.
SUPPORTED_SCHEMA_VERSION = "schott-platform/v1"

# Separate from determinism: a deterministic capability can still change the
# world, and a nondeterministic one need not. `side-effecting` is representable
# here and routable nowhere; whether a class may be routed is a routing
# question, and routing does not exist in this increment.
EFFECT_CLASSES = (
    "read-only",
    "computational",
    "content-generating",
    "side-effecting",
)


def _encode(value: Any) -> Any:
    """Deterministic, JSON-friendly form. Mappings sort; times carry offsets."""
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (list, tuple)):
        return [_encode(item) for item in value]
    if isinstance(value, (dict, MappingProxyType)):
        return {str(k): _encode(v) for k, v in sorted(value.items(), key=lambda i: str(i[0]))}
    return value


def _require_text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise FabricError(f"{name} is required")
    return value


def _require_identifier(value: Any, kind: str, name: str) -> str:
    pattern = PATTERNS[kind]
    if not isinstance(value, str) or not pattern.match(value):
        raise FabricError(f"{name} does not match {pattern.pattern}")
    return value


def _require_aware(value: Any, name: str) -> datetime:
    if not isinstance(value, datetime):
        raise FabricError(f"{name} must be a datetime")
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise FabricError(f"{name} must carry a timezone offset")
    return value


def _require_effect_class(value: Any) -> str:
    if value not in EFFECT_CLASSES:
        raise FabricError("effect_class must be one of the accepted classes")
    return value


def _parse_time(value: Any, name: str) -> datetime:
    if isinstance(value, datetime):
        return value
    if not isinstance(value, str):
        raise FabricError(f"{name} must be a datetime")
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        raise FabricError(f"{name} is not a readable timestamp") from None


class FabricRecord:
    """Shared serialisation and refusal behaviour.

    Subclasses declare their kind, which fields are timestamps, and which are
    ordered sequences. Everything else follows from the dataclass definition,
    so a field cannot be added to a model and forgotten by the reader.
    """

    kind: ClassVar[str] = ""
    _TIMESTAMPS: ClassVar[tuple[str, ...]] = ()
    _SEQUENCES: ClassVar[tuple[str, ...]] = ()

    def _freeze(self, *names: str) -> None:
        for name in names:
            value = getattr(self, name)
            object.__setattr__(self, name, MappingProxyType(dict(value or {})))

    def _freeze_evidence(self) -> None:
        """Evidence is a mapping or it is absent. Nothing else is accepted.

        Absent stays absent rather than becoming an empty mapping, so a record
        written before evidence existed serialises exactly as it always did.
        """
        if self.evidence is None:
            return
        if not isinstance(self.evidence, Mapping):
            raise FabricError("evidence must be a mapping")
        object.__setattr__(self, "evidence", MappingProxyType(dict(self.evidence)))

    def _seal(self) -> None:
        for name in self._SEQUENCES:
            object.__setattr__(self, name, tuple(getattr(self, name) or ()))

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schema_version": SUPPORTED_SCHEMA_VERSION,
            "kind": self.kind,
        }
        for spec in dataclass_fields(self):  # type: ignore[arg-type]
            value = getattr(self, spec.name)
            # An absent optional is absent, not a null. A reader should not have
            # to distinguish "not supplied" from "supplied as nothing".
            if value is None:
                continue
            payload[spec.name] = _encode(value)
        return payload

    @classmethod
    def from_dict(cls, payload: Mapping[str, Any]) -> "FabricRecord":
        if not isinstance(payload, Mapping):
            raise FabricError("a stored record must be a mapping")

        version = payload.get("schema_version")
        if version is None:
            raise FabricError("stored record declares no schema version")
        if version != SUPPORTED_SCHEMA_VERSION:
            raise FabricError("stored record declares an unsupported schema version")

        stored_kind = payload.get("kind")
        if stored_kind != cls.kind:
            raise FabricError("stored record declares a different record kind")

        known = {spec.name for spec in dataclass_fields(cls)}  # type: ignore[arg-type]
        unknown = sorted(set(payload) - known - {"schema_version", "kind"})
        if unknown:
            # Named, not echoed: a field name is safe to report, a value is not.
            raise FabricError(f"stored record carries unknown field(s): {', '.join(unknown)}")

        arguments: dict[str, Any] = {}
        for spec in dataclass_fields(cls):  # type: ignore[arg-type]
            if spec.name not in payload:
                continue
            value = payload[spec.name]
            if spec.name in cls._TIMESTAMPS:
                value = _parse_time(value, spec.name)
            elif spec.name in cls._SEQUENCES:
                value = tuple(value)
            arguments[spec.name] = value
        return cls(**arguments)


@dataclass(frozen=True)
class CapabilityDefinition(FabricRecord):
    """An abstract, named ability — the identity anchor of the fabric.

    Not the `CAP-0000` platform capability record: that one carries a maturity
    claim and nothing routes to it. These never share an identifier space.
    """

    capability_id: str
    name: str
    description: str
    effect_class: str
    contract_ids: tuple[str, ...]
    provenance: Mapping[str, Any]
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-definition"
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("contract_ids",)

    def __post_init__(self) -> None:
        _require_identifier(self.capability_id, self.kind, "capability_id")
        _require_text(self.name, "name")
        _require_text(self.description, "description")
        _require_effect_class(self.effect_class)
        self._seal()
        for contract_id in self.contract_ids:
            _require_identifier(contract_id, "capability-contract", "contract_ids entry")
        self._freeze("provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityContract(FabricRecord):
    """The versioned, testable interface a capability is reached through.

    Compatibility is declared in `compatible_with` and never inferred: the
    platform reads no meaning into a version number.
    """

    contract_id: str
    capability_id: str
    contract_version: str
    effect_class: str
    determinism_class: str
    request_shape: Mapping[str, Any]
    response_shape: Mapping[str, Any]
    failure_modes: tuple[str, ...]
    resource_requirements: Mapping[str, Any]
    compatible_with: tuple[str, ...]
    provenance: Mapping[str, Any]
    description: str | None = None
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-contract"
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("failure_modes", "compatible_with")

    def __post_init__(self) -> None:
        _require_identifier(self.contract_id, self.kind, "contract_id")
        _require_identifier(self.capability_id, "capability-definition", "capability_id")
        _require_text(self.contract_version, "contract_version")
        _require_effect_class(self.effect_class)
        _require_text(self.determinism_class, "determinism_class")
        self._seal()
        self._freeze("request_shape", "response_shape", "resource_requirements", "provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityPackage(FabricRecord):
    """The reviewable artefact implementing a contract.

    The trust subject in the `capability-package` domain. Trusting a package
    trusts no machine. The record references an artefact; it never embeds one.
    """

    capability_package_id: str
    capability_id: str
    contract_id: str
    satisfied_contract_versions: tuple[str, ...]
    package_version: str
    artifact_reference: str
    resource_requirements: Mapping[str, Any]
    trust_domain: str
    provenance: Mapping[str, Any]
    description: str | None = None
    manifest_reference: str | None = None
    signature_reference: str | None = None
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-package"
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("satisfied_contract_versions",)

    def __post_init__(self) -> None:
        _require_identifier(self.capability_package_id, self.kind, "capability_package_id")
        _require_identifier(self.capability_id, "capability-definition", "capability_id")
        _require_identifier(self.contract_id, "capability-contract", "contract_id")
        _require_text(self.package_version, "package_version")
        _require_text(self.artifact_reference, "artifact_reference")
        _require_text(self.trust_domain, "trust_domain")
        self._seal()
        self._freeze("resource_requirements", "provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityHost(FabricRecord):
    """A machine offering execution capacity — the `fabric-node` trust subject.

    The record says what the machine is and what it may ever see. It never says
    what it is allowed to run: that depends on the package as much as the
    machine, so it belongs to the instance.
    """

    capability_host_id: str
    node_identity_reference: str
    fabric_node_trust_record_id: str
    verified_resource_profile: Mapping[str, Any]
    location_class: str
    data_classification_ceiling: str
    availability_intent: str
    provenance: Mapping[str, Any]
    name: str | None = None
    description: str | None = None
    verification_reference: str | None = None
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-host"

    def __post_init__(self) -> None:
        _require_identifier(self.capability_host_id, self.kind, "capability_host_id")
        _require_text(self.node_identity_reference, "node_identity_reference")
        _require_text(self.fabric_node_trust_record_id, "fabric_node_trust_record_id")
        _require_text(self.location_class, "location_class")
        _require_text(self.data_classification_ceiling, "data_classification_ceiling")
        _require_text(self.availability_intent, "availability_intent")
        self._freeze("verified_resource_profile", "provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityAdvertisement(FabricRecord):
    """A host's self-report: a claim, never a grant.

    It confers no trust, creates no eligibility, and admits nothing — including
    itself. The profile here is *advertised*; the verified one lives on the
    host record, where it is visibly not a claim.
    """

    advertisement_id: str
    capability_host_id: str
    capability_package_id: str
    contract_id: str
    satisfied_contract_versions: tuple[str, ...]
    advertised_resource_profile: Mapping[str, Any]
    observed_at: datetime
    valid_until: datetime
    provenance: Mapping[str, Any]
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-advertisement"
    _TIMESTAMPS: ClassVar[tuple[str, ...]] = ("observed_at", "valid_until")
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("satisfied_contract_versions",)

    def __post_init__(self) -> None:
        _require_identifier(self.advertisement_id, self.kind, "advertisement_id")
        _require_identifier(self.capability_host_id, "capability-host", "capability_host_id")
        _require_identifier(
            self.capability_package_id, "capability-package", "capability_package_id")
        _require_identifier(self.contract_id, "capability-contract", "contract_id")
        _require_aware(self.observed_at, "observed_at")
        _require_aware(self.valid_until, "valid_until")
        self._seal()
        self._freeze("advertised_resource_profile", "provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityInstance(FabricRecord):
    """The admitted binding of one package to one host for one contract.

    Deliberately the fragile identity: it encodes "this code, on this machine",
    so it must be destroyed when either half changes rather than repointed.
    """

    instance_id: str
    capability_id: str
    capability_package_id: str
    capability_host_id: str
    contract_id: str
    satisfied_contract_versions: tuple[str, ...]
    verified_resource_profile: Mapping[str, Any]
    admission_decision_id: str
    package_trust_record_id: str
    host_trust_record_id: str
    effective_scope: Mapping[str, Any]
    admitted_at: datetime
    admitted_until: datetime
    provenance: Mapping[str, Any]
    advertisement_id: str | None = None
    endpoint_reference: str | None = None
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-instance"
    _TIMESTAMPS: ClassVar[tuple[str, ...]] = ("admitted_at", "admitted_until")
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("satisfied_contract_versions",)

    def __post_init__(self) -> None:
        _require_identifier(self.instance_id, self.kind, "instance_id")
        _require_identifier(self.capability_id, "capability-definition", "capability_id")
        _require_identifier(
            self.capability_package_id, "capability-package", "capability_package_id")
        _require_identifier(self.capability_host_id, "capability-host", "capability_host_id")
        _require_identifier(self.contract_id, "capability-contract", "contract_id")
        _require_text(self.admission_decision_id, "admission_decision_id")
        _require_text(self.package_trust_record_id, "package_trust_record_id")
        _require_text(self.host_trust_record_id, "host_trust_record_id")
        _require_aware(self.admitted_at, "admitted_at")
        _require_aware(self.admitted_until, "admitted_until")
        self._seal()
        self._freeze("verified_resource_profile", "effective_scope", "provenance")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilityRoute(FabricRecord):
    """The declared policy binding a request class to an ordered candidate list.

    The order is written by a human. Nothing here derives order from a
    measurement, and `locality` is enforced rather than advisory.
    """

    route_id: str
    route_version: int
    capability_id: str
    contract_id: str
    accepted_contract_versions: tuple[str, ...]
    locality: str
    candidate_instances: tuple[str, ...]
    data_classification: str
    provenance: Mapping[str, Any]
    description: str | None = None
    overlap_window: Mapping[str, Any] | None = None
    supersedes: str | None = None
    superseded_by: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-route"
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("accepted_contract_versions", "candidate_instances")

    def __post_init__(self) -> None:
        _require_identifier(self.route_id, self.kind, "route_id")
        if isinstance(self.route_version, bool) or not isinstance(self.route_version, int):
            raise FabricError("route_version must be an integer")
        if self.route_version < 1:
            raise FabricError("route_version starts at 1")
        _require_identifier(self.capability_id, "capability-definition", "capability_id")
        _require_identifier(self.contract_id, "capability-contract", "contract_id")
        _require_text(self.locality, "locality")
        _require_text(self.data_classification, "data_classification")
        self._seal()
        for instance_id in self.candidate_instances:
            _require_identifier(instance_id, "capability-instance", "candidate_instances entry")
        self._freeze("provenance")
        if self.overlap_window is not None:
            self._freeze("overlap_window")
        self._freeze_evidence()


@dataclass(frozen=True)
class CapabilitySelection(FabricRecord):
    """One recorded act of choosing — or of refusing.

    The record that answers "why did this run there?", and, because refusal is
    a first-class outcome, "why did nothing run?".
    """

    selection_id: str
    route_id: str
    route_version: int
    request_class: Mapping[str, Any]
    considered_candidates: tuple[str, ...]
    excluded_candidates: tuple[Any, ...]
    selected_instance_id: str | None
    selection_reason: str
    selected_at: datetime
    provenance: Mapping[str, Any]
    refusal_reason: str | None = None
    notes: str | None = None

    # Evidence rides the accepted record; there is no ninth record type.
    evidence: Mapping[str, Any] | None = None

    kind: ClassVar[str] = "capability-selection"
    _TIMESTAMPS: ClassVar[tuple[str, ...]] = ("selected_at",)
    _SEQUENCES: ClassVar[tuple[str, ...]] = ("considered_candidates", "excluded_candidates")

    def __post_init__(self) -> None:
        _require_identifier(self.selection_id, self.kind, "selection_id")
        _require_identifier(self.route_id, "capability-route", "route_id")
        if isinstance(self.route_version, bool) or not isinstance(self.route_version, int):
            raise FabricError("route_version must be an integer")
        _require_text(self.selection_reason, "selection_reason")
        _require_aware(self.selected_at, "selected_at")
        self._seal()
        for candidate in self.considered_candidates:
            _require_identifier(candidate, "capability-instance", "considered_candidates entry")
        # A refusal names no instance. Requiring one would make "nothing ran"
        # unrecordable, which is the outcome this record most needs to hold.
        if self.selected_instance_id is not None:
            _require_identifier(
                self.selected_instance_id, "capability-instance", "selected_instance_id")
        self._freeze("request_class", "provenance")
        self._freeze_evidence()


# Exactly eight. A ninth persistent record type is a new architectural
# decision, not an implementation detail, so the mapping is written out rather
# than discovered by scanning the module.
RECORD_MODELS: Mapping[str, type[FabricRecord]] = MappingProxyType({
    CapabilityDefinition.kind: CapabilityDefinition,
    CapabilityContract.kind: CapabilityContract,
    CapabilityPackage.kind: CapabilityPackage,
    CapabilityHost.kind: CapabilityHost,
    CapabilityAdvertisement.kind: CapabilityAdvertisement,
    CapabilityInstance.kind: CapabilityInstance,
    CapabilityRoute.kind: CapabilityRoute,
    CapabilitySelection.kind: CapabilitySelection,
})
