"""Immutable data models for the Trust Plane runtime.

Every model is frozen. A trust record that can be edited is an audit trail that
can be rewritten after the fact, which is the one property an audit trail must
not have -- so change is supersession, and these types have no setter to reach
for when that feels inconvenient.

What these models cannot express is as deliberate as what they can. There is no
score field, no threshold, no executable action, no command text, and no field
capable of carrying a credential. Absent those fields, a later change that
wanted them would have to add one in review.

Timestamps must carry an offset. A time without a zone is not a point in time,
and every expiry answer depends on placing it.

See docs/decisions/ADR-0011-trust-plane.md.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from types import MappingProxyType
from typing import Any, Mapping

from .errors import TrustError
from .identifiers import (
    AUDIT_ID,
    AUTHORITY_ID,
    DECISION_ID,
    EVIDENCE_ID,
    LINEAGE_ID,
    RECORD_ID,
    SCOPE_ID,
)

# Values that would turn a bounded scope into an unbounded one. Refused as scope
# entries because "permitted_capabilities: [*]" reads like a restriction and
# behaves like none at all.
WILDCARD_VALUES = frozenset({"*", "**", "all", "any", ".*", "?"})

# Field names that would put credential material into a trust record. Refused
# wherever they appear: a record says a subject was verified, never how to
# authenticate as it.
SECRET_BEARING_KEYS = frozenset({
    "password", "passwd", "passphrase", "private_key", "private_key_content",
    "privatekey", "key_content", "key_material", "secret", "secret_key",
    "token", "api_key", "apikey", "bearer_token", "credential", "credentials",
    "certificate_content", "authorization",
})

# Field names that would make a record executable or scored. Neither belongs in
# a governance record.
FORBIDDEN_KEYS = frozenset({
    "command", "command_text", "argv", "shell", "script", "exec", "run",
    "trust_score", "score", "threshold", "confidence_threshold", "reputation",
    "trust_level_numeric", "auto_enroll", "auto_approve", "auto_renew",
    "trust_on_first_use",
})

# Who authorised a decision, from the released trust-decision schema. Named
# rather than free text so "who said yes" is answerable from the record.
APPROVAL_SOURCES = frozenset({
    "named-operator", "change-review-record", "offline-certificate-authority",
    "signed-release-artifact",
})

# Preserved explicitly rather than dropped: a value known to be unknown and a
# value nobody recorded are different facts.
UNKNOWN = "unknown"

# The two kinds of lineage, discriminated on the record so a reader never has to
# infer which one it is holding. ADR-0014.
#
# A subject-decision lineage records what the platform decided about a subject.
# A root-establishment lineage records that an authority was established outside
# the platform, by a ceremony, which no decision produced.
LINEAGE_TYPE_SUBJECT_DECISION = "subject-decision"
LINEAGE_TYPE_ROOT_ESTABLISHMENT = "root-establishment"
LINEAGE_TYPES = frozenset({LINEAGE_TYPE_SUBJECT_DECISION,
                           LINEAGE_TYPE_ROOT_ESTABLISHMENT})

# How a root came to exist. Named rather than free text: an origin the platform
# could assert about itself is not an external origin.
EXTERNAL_OPERATOR_CEREMONY = "external-operator-ceremony"
ESTABLISHMENT_ORIGINS = frozenset({EXTERNAL_OPERATOR_CEREMONY})


class TrustState(str, Enum):
    """Standing of one subject in one lineage.

    Unknown is the default and fails closed. Pending is operationally identical
    to Unknown: a state meaning "not yet trusted but usable" is trust on first
    use with a waiting period.
    """

    UNKNOWN = "unknown"
    PENDING = "pending"
    TRUSTED = "trusted"
    RESTRICTED = "restricted"
    QUARANTINED = "quarantined"
    REVOKED = "revoked"
    EXPIRED = "expired"
    REJECTED = "rejected"


class AuthorityType(str, Enum):
    """Who may decide.

    operator-root is the external terminating authority. Delegated authorities
    exist only because a recorded decision created them, and are not
    implemented in v0.9.3.
    """

    OPERATOR_ROOT = "operator-root"
    DELEGATED = "delegated"


class VerificationMethod(str, Enum):
    """How evidence was checked, from the ADR-0011 vocabulary.

    Named methods rather than free text: a fingerprint compared over a separate
    channel is a different quality of verification from one read off the
    connection being verified, and the record must tell them apart.
    """

    OUT_OF_BAND_FINGERPRINT = "out-of-band-fingerprint-comparison"
    OFFLINE_SIGNATURE = "offline-signature-verification"
    CHECKSUM_MANIFEST = "checksum-against-signed-manifest"
    HARDWARE_TOKEN = "hardware-token-attestation"
    OUT_OF_BAND_PHYSICAL = "out-of-band-physical-verification"
    REVIEWED_SOURCE_INSPECTION = "reviewed-source-inspection"


def require_aware(value: datetime, field_name: str) -> datetime:
    """Return the timestamp, or refuse a naive one."""
    if not isinstance(value, datetime):
        raise TrustError(f"{field_name} must be a datetime")
    if value.tzinfo is None or value.utcoffset() is None:
        raise TrustError(
            f"{field_name} must carry a timezone offset; a time without a zone "
            "is not a point in time"
        )
    return value


def reject_forbidden_keys(mapping: Mapping[str, Any], where: str) -> None:
    """Refuse credential, executable, or scored fields at any depth.

    The offending key is named and its value never is.
    """
    if isinstance(mapping, Mapping):
        for key, value in mapping.items():
            lowered = str(key).lower()
            if lowered in SECRET_BEARING_KEYS:
                raise TrustError(
                    f"{where} carries credential material at '{key}'; trust records "
                    "reference evidence, never store it"
                )
            if lowered in FORBIDDEN_KEYS:
                raise TrustError(
                    f"{where} carries a forbidden field '{key}'; trust records are "
                    "neither executable nor scored"
                )
            reject_forbidden_keys(value, where)
    elif isinstance(mapping, (list, tuple)):
        for item in mapping:
            reject_forbidden_keys(item, where)


def _encode(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, (list, tuple)):
        return [_encode(item) for item in value]
    if isinstance(value, (dict, MappingProxyType)):
        return {str(k): _encode(v) for k, v in sorted(value.items(), key=lambda i: str(i[0]))}
    if hasattr(value, "to_dict"):
        return value.to_dict()
    return value


def fingerprint_of(payload: Mapping[str, Any]) -> str:
    """A content fingerprint over the record, excluding the fingerprint itself.

    Deterministic: sorted keys, no whitespace, so the same content always
    produces the same value.
    """
    body = {k: v for k, v in payload.items() if k != "fingerprint"}
    encoded = json.dumps(_encode(body), sort_keys=True, separators=(",", ":")).encode("utf-8")
    return f"sha256:{hashlib.sha256(encoded).hexdigest()}"


def _match(pattern, value: str, name: str) -> str:
    if not pattern.match(str(value or "")):
        raise TrustError(f"{name} '{value}' does not match {pattern.pattern}")
    return value


@dataclass(frozen=True)
class TrustEvidenceReference:
    """What a decision rested on, by reference.

    Evidence identifies what was checked. It is not a place to store the thing
    itself, so there is no field for a value.
    """

    evidence_id: str
    kind: str
    reference: str
    recorded_at: datetime

    def __post_init__(self) -> None:
        _match(EVIDENCE_ID, self.evidence_id, "evidence_id")
        if not str(self.kind or "").strip():
            raise TrustError("evidence kind is required")
        if not str(self.reference or "").strip():
            raise TrustError("evidence reference is required")
        require_aware(self.recorded_at, "recorded_at")

    @property
    def id(self) -> str:
        return self.evidence_id

    def to_dict(self) -> dict[str, Any]:
        return {
            # `id` duplicates the specific key so the shared immutable store can
            # validate any record kind without knowing trust vocabulary.
            "id": self.evidence_id,
            "evidence_id": self.evidence_id,
            "kind": self.kind,
            "reference": self.reference,
            "recorded_at": self.recorded_at.isoformat(),
        }


@dataclass(frozen=True)
class TrustVerificationDetails:
    """The five things an out-of-band comparison must record.

    A method name alone says a check happened without saying what was checked,
    which is unreviewable a year later.
    """

    subject_property: str
    observed_value_reference: str
    comparison_source: str
    performed_by: str
    performed_at: datetime

    def __post_init__(self) -> None:
        for name in ("subject_property", "observed_value_reference",
                     "comparison_source", "performed_by"):
            if not str(getattr(self, name) or "").strip():
                raise TrustError(f"verification detail '{name}' is required")
        require_aware(self.performed_at, "performed_at")

    def to_dict(self) -> dict[str, Any]:
        return {
            "subject_property": self.subject_property,
            "observed_value_reference": self.observed_value_reference,
            "comparison_source": self.comparison_source,
            "performed_by": self.performed_by,
            "performed_at": self.performed_at.isoformat(),
        }


@dataclass(frozen=True)
class TrustScope:
    """What a grant permits, bounded on every dimension.

    Deny by default. A dimension the scope does not mention is denied rather
    than waved through, so an incomplete scope is restrictive rather than
    accidentally permissive.
    """

    scope_id: str
    subject_type: str
    permitted_capabilities: tuple[str, ...] = ()
    permitted_operations: tuple[str, ...] = ()
    permitted_data_classifications: tuple[str, ...] = ()
    permitted_targets: tuple[str, ...] = ()
    validity_start: datetime | None = None
    validity_end: datetime | None = None

    DIMENSIONS = ("permitted_capabilities", "permitted_operations",
                  "permitted_data_classifications", "permitted_targets")

    def __post_init__(self) -> None:
        _match(SCOPE_ID, self.scope_id, "scope_id")
        if not str(self.subject_type or "").strip():
            raise TrustError("scope subject_type is required")
        for name in self.DIMENSIONS:
            for value in getattr(self, name):
                text = str(value)
                if text.lower() in WILDCARD_VALUES:
                    raise TrustError(
                        f"scope value '{text}' in {name} is a wildcard; a scope that "
                        "matches everything is not a scope"
                    )
                if "*" in text or "?" in text:
                    raise TrustError(
                        f"scope value '{text}' in {name} contains a wildcard character; "
                        "pattern scopes are not permitted in v0.9.3"
                    )
        if self.validity_start is not None:
            require_aware(self.validity_start, "validity_start")
        if self.validity_end is not None:
            require_aware(self.validity_end, "validity_end")

    def is_empty(self) -> bool:
        return not any(getattr(self, name) for name in self.DIMENSIONS)

    def require_non_empty(self) -> "TrustScope":
        """Refuse a scope that bounds nothing.

        A restriction with no dimension set is a trusted record with a
        misleading label.
        """
        if self.is_empty():
            raise TrustError(
                "a restricted grant requires at least one explicit scope dimension; "
                "a scope that bounds nothing is not a restriction"
            )
        return self

    @property
    def id(self) -> str:
        return self.scope_id

    def to_dict(self) -> dict[str, Any]:
        return {
            "scope_id": self.scope_id,
            "subject_type": self.subject_type,
            "permitted_capabilities": list(self.permitted_capabilities),
            "permitted_operations": list(self.permitted_operations),
            "permitted_data_classifications": list(self.permitted_data_classifications),
            "permitted_targets": list(self.permitted_targets),
            "validity_start": self.validity_start.isoformat() if self.validity_start else None,
            "validity_end": self.validity_end.isoformat() if self.validity_end else None,
        }


@dataclass(frozen=True)
class OperatorRootAuthority:
    """A declaration that an external root authority exists.

    Kyri records that the root exists and what was verified about it. Kyri does
    not establish the identity: `external_identity_reference` is a reference
    resolved outside this platform, and there is no field for a key, a
    username, or an address.

    There is deliberately no `approved_by`. A root that approved itself is a
    chain terminating inside the thing it governs.
    """

    authority_id: str
    authority_type: str
    display_name: str
    external_identity_reference: str
    verification_method: str
    verification_details: TrustVerificationDetails
    evidence_references: tuple[TrustEvidenceReference, ...]
    created_at: datetime
    provenance: Mapping[str, Any]
    state: str
    lineage_id: str
    fingerprint: str = ""

    def __post_init__(self) -> None:
        _match(AUTHORITY_ID, self.authority_id, "authority_id")
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        if self.authority_type != AuthorityType.OPERATOR_ROOT.value:
            raise TrustError(
                f"authority_type '{self.authority_type}' is not supported in v0.9.3; "
                "only operator-root exists"
            )
        if not str(self.external_identity_reference or "").strip():
            raise TrustError("external_identity_reference is required")
        if self.verification_method not in {m.value for m in VerificationMethod}:
            raise TrustError(f"verification method '{self.verification_method}' is not recognised")
        if not self.evidence_references:
            raise TrustError("a root authority declaration requires at least one evidence reference")
        require_aware(self.created_at, "created_at")
        reject_forbidden_keys(dict(self.provenance or {}), "root authority provenance")
        if self.state != TrustState.TRUSTED.value:
            raise TrustError("a declared root authority is trusted or it is not a root")
        object.__setattr__(self, "provenance", MappingProxyType(dict(self.provenance or {})))
        if not self.fingerprint:
            object.__setattr__(self, "fingerprint", fingerprint_of(self._body()))

    def _body(self) -> dict[str, Any]:
        return {
            "authority_id": self.authority_id,
            "authority_type": self.authority_type,
            "display_name": self.display_name,
            "external_identity_reference": self.external_identity_reference,
            "verification_method": self.verification_method,
            "verification_details": self.verification_details.to_dict(),
            "evidence_references": [e.to_dict() for e in self.evidence_references],
            "created_at": self.created_at.isoformat(),
            "provenance": dict(self.provenance),
            "state": self.state,
            "lineage_id": self.lineage_id,
        }

    @property
    def id(self) -> str:
        return self.authority_id

    def to_dict(self) -> dict[str, Any]:
        payload = self._body()
        payload["id"] = self.id
        payload["fingerprint"] = self.fingerprint
        return payload


@dataclass(frozen=True)
class TrustRecord:
    """The standing of one subject, as of one decision."""

    record_id: str
    subject_id: str
    subject_type: str
    state: str
    lineage_id: str
    decision_id: str
    authority_id: str
    created_at: datetime
    scope: TrustScope | None = None
    expiration: datetime | None = None
    provenance: Mapping[str, Any] = field(default_factory=dict)
    fingerprint: str = ""
    subject_fingerprint: str = ""

    def __post_init__(self) -> None:
        _match(RECORD_ID, self.record_id, "record_id")
        if not self.subject_fingerprint:
            # Derived from the subject's identity and domain, not supplied: a
            # caller-chosen fingerprint could make two subjects look like one.
            digest = hashlib.sha256(
                f"{self.subject_type}\u0000{self.subject_id}".encode("utf-8")).hexdigest()
            object.__setattr__(self, "subject_fingerprint", f"sha256:{digest}")
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        _match(DECISION_ID, self.decision_id, "decision_id")
        _match(AUTHORITY_ID, self.authority_id, "authority_id")
        if self.state not in {s.value for s in TrustState}:
            raise TrustError(f"trust state '{self.state}' is not recognised")
        require_aware(self.created_at, "created_at")
        if self.expiration is not None:
            require_aware(self.expiration, "expiration")
        reject_forbidden_keys(dict(self.provenance or {}), "trust record provenance")
        object.__setattr__(self, "provenance", MappingProxyType(dict(self.provenance or {})))
        if not self.fingerprint:
            object.__setattr__(self, "fingerprint", fingerprint_of(self._body()))

    def _body(self) -> dict[str, Any]:
        return {
            "record_id": self.record_id,
            # Schema field names from the released v0.9.2 contract.
            "domain": self.subject_type,
            "subject_identifier": self.subject_id,
            "subject_fingerprint": self.subject_fingerprint,
            "trust_authority_id": self.authority_id,
            "expires_at": self.expiration.isoformat() if self.expiration else None,
            # Runtime attribute names, retained so a reader of either
            # vocabulary finds what they expect.
            "subject_id": self.subject_id,
            "subject_type": self.subject_type,
            "state": self.state,
            "lineage_id": self.lineage_id,
            "decision_id": self.decision_id,
            "authority_id": self.authority_id,
            "created_at": self.created_at.isoformat(),
            "scope": self.scope.to_dict() if self.scope else None,
            "expiration": self.expiration.isoformat() if self.expiration else None,
            "provenance": dict(self.provenance),
        }

    @property
    def id(self) -> str:
        return self.record_id

    def to_dict(self) -> dict[str, Any]:
        payload = self._body()
        payload["id"] = self.id
        payload["fingerprint"] = self.fingerprint
        return payload


@dataclass(frozen=True)
class TrustDecision:
    """One act of judgement, at one moment, by one authority.

    The only thing that can change a trust state, and it records everything
    needed to re-examine it later.
    """

    decision_id: str
    lineage_id: str
    subject_id: str
    previous_state: str
    requested_state: str
    actor_authority_id: str
    decided_at: datetime
    reason: str
    evidence_references: tuple[TrustEvidenceReference, ...]
    verification_method: str
    verification_details: TrustVerificationDetails
    approval_source: str = ""
    history_reference: str = ""
    trust_scope: TrustScope | None = None
    expiration: datetime | None = None
    supersedes: str | None = None
    revokes_record_id: str | None = None
    provenance: Mapping[str, Any] = field(default_factory=dict)
    decision_fingerprint: str = ""

    def __post_init__(self) -> None:
        _match(DECISION_ID, self.decision_id, "decision_id")
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        _match(AUTHORITY_ID, self.actor_authority_id, "actor_authority_id")
        for name in ("previous_state", "requested_state"):
            if getattr(self, name) not in {s.value for s in TrustState}:
                raise TrustError(f"{name} '{getattr(self, name)}' is not recognised")
        require_aware(self.decided_at, "decided_at")
        if len(str(self.reason or "").split()) < 5:
            raise TrustError(
                "a decision reason must be a written justification; "
                "'it was already there' is not a reason"
            )
        if not self.evidence_references:
            raise TrustError("a decision requires at least one evidence reference")
        if self.approval_source not in APPROVAL_SOURCES:
            raise TrustError(
                f"approval source '{self.approval_source}' is not recognised; "
                "who authorised a decision is one of its mandatory elements")
        if not str(self.history_reference or "").strip():
            raise TrustError(
                "history_reference is required; a decision that cannot be placed in "
                "its chain is not reviewable")
        if self.verification_method not in {m.value for m in VerificationMethod}:
            raise TrustError(f"verification method '{self.verification_method}' is not recognised")
        if self.expiration is not None:
            require_aware(self.expiration, "expiration")
            if self.expiration <= self.decided_at:
                raise TrustError("expiration must be after the moment of decision")
        if self.supersedes is not None:
            _match(DECISION_ID, self.supersedes, "supersedes")
            if self.supersedes == self.decision_id:
                raise TrustError("a decision cannot supersede itself")
        if self.revokes_record_id is not None:
            _match(RECORD_ID, self.revokes_record_id, "revokes_record_id")
        reject_forbidden_keys(dict(self.provenance or {}), "trust decision provenance")
        object.__setattr__(self, "provenance", MappingProxyType(dict(self.provenance or {})))
        if not self.decision_fingerprint:
            object.__setattr__(self, "decision_fingerprint", fingerprint_of(self._body()))

    def _body(self) -> dict[str, Any]:
        return {
            "decision_id": self.decision_id,
            "record_id": self.history_reference,
            "lineage_id": self.lineage_id,
            "subject_id": self.subject_id,
            "previous_state": self.previous_state,
            "requested_state": self.requested_state,
            # Schema field names from the released v0.9.2 contract. The
            # dataclass attribute names differ where the schema chose another
            # word; forking a second runtime vocabulary would leave two
            # descriptions of one record.
            "actor": self.actor_authority_id,
            "actor_authority_id": self.actor_authority_id,
            "decided_at": self.decided_at.isoformat(),
            "reason": self.reason,
            "evidence": [e.to_dict() for e in self.evidence_references],
            "approval_source": self.approval_source,
            "history_reference": self.history_reference,
            "verification_method": self.verification_method,
            "verification_details": self.verification_details.to_dict(),
            "scope": self.trust_scope.to_dict() if self.trust_scope else None,
            "resulting_state": self.requested_state,
            "expiration": self.expiration.isoformat() if self.expiration else None,
            "supersedes": self.supersedes,
            "revokes_record_id": self.revokes_record_id,
            "provenance": dict(self.provenance),
        }

    @property
    def id(self) -> str:
        return self.decision_id

    def to_dict(self) -> dict[str, Any]:
        payload = self._body()
        payload["id"] = self.id
        payload["decision_fingerprint"] = self.decision_fingerprint
        return payload


@dataclass(frozen=True)
class TrustLineage:
    """One subject's chain of decisions, terminating at one root authority.

    Lineage versions are append-only. Advancing a lineage writes a new version
    rather than editing the previous one, so the head is the highest version
    and every earlier state stays exactly as written.
    """

    lineage_id: str
    version: int
    subject_id: str
    subject_type: str
    root_authority_id: str
    first_decision_id: str
    current_decision_id: str
    prior_decision_ids: tuple[str, ...]
    current_state: str
    created_at: datetime
    last_changed_at: datetime
    terminated: bool = False
    termination_reason: str | None = None
    supersedes_lineage_id: str | None = None

    def __post_init__(self) -> None:
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        _match(AUTHORITY_ID, self.root_authority_id, "root_authority_id")
        _match(DECISION_ID, self.first_decision_id, "first_decision_id")
        _match(DECISION_ID, self.current_decision_id, "current_decision_id")
        if self.version < 1:
            raise TrustError("lineage version starts at 1")
        if self.current_state not in {s.value for s in TrustState}:
            raise TrustError(f"lineage state '{self.current_state}' is not recognised")
        require_aware(self.created_at, "created_at")
        require_aware(self.last_changed_at, "last_changed_at")
        if self.supersedes_lineage_id is not None:
            _match(LINEAGE_ID, self.supersedes_lineage_id, "supersedes_lineage_id")
            if self.supersedes_lineage_id == self.lineage_id:
                raise TrustError("a lineage cannot supersede itself")
        if self.current_decision_id in self.prior_decision_ids:
            raise TrustError("the current decision must not also appear as a prior decision")

    @property
    def lineage_type(self) -> str:
        """Constant discriminator. A property, so it cannot be passed a value."""
        return LINEAGE_TYPE_SUBJECT_DECISION

    @property
    def id(self) -> str:
        return f"{self.lineage_id}-v{self.version:04d}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "lineage_type": self.lineage_type,
            "lineage_id": self.lineage_id,
            "version": self.version,
            "subject_id": self.subject_id,
            "subject_type": self.subject_type,
            "root_authority_id": self.root_authority_id,
            "first_decision_id": self.first_decision_id,
            "current_decision_id": self.current_decision_id,
            "prior_decision_ids": list(self.prior_decision_ids),
            "current_state": self.current_state,
            "created_at": self.created_at.isoformat(),
            "last_changed_at": self.last_changed_at.isoformat(),
            "terminated": self.terminated,
            "termination_reason": self.termination_reason,
            "supersedes_lineage_id": self.supersedes_lineage_id,
        }


def lineage_type_of(record: Mapping[str, Any], where: str) -> str:
    """The discriminator on a stored lineage record, or a refusal.

    Missing and unrecognised values both fail closed. A lineage whose kind
    cannot be established is not a lineage to be guessed at: reading a root
    establishment as a decision chain, or the reverse, would misreport how a
    subject came to be trusted.
    """
    value = str((record or {}).get("lineage_type") or "").strip()
    if not value:
        raise TrustError(
            f"{where} carries no lineage_type; the kind of a lineage is recorded, "
            "never inferred"
        )
    if value not in LINEAGE_TYPES:
        raise TrustError(f"{where} carries an unrecognised lineage_type '{value}'")
    return value


@dataclass(frozen=True)
class RootAuthorityLineage:
    """How one Operator Root Authority came to exist.

    Not a decision chain. A root is established outside the platform by a human
    ceremony; nothing inside decided it, and `evaluator` refuses any decision
    whose subject is its own actor. So the decision identifiers `TrustLineage`
    requires cannot be supplied here truthfully.

    They are therefore **absent from this model rather than optional on it**. No
    code path can populate one, and a stored record carrying one is malformed
    rather than tolerated. There is no `root_authority_id` either: a root naming
    itself as its own terminating authority reads as self-approval, and this
    record makes no claim about who approved anything, because nobody did.

    Advancing a root establishment lineage is not defined in this release.
    """

    lineage_id: str
    version: int
    authority_id: str
    subject_type: str
    establishment_origin: str
    evidence_reference_ids: tuple[str, ...]
    establishment_audit_id: str
    current_state: str
    established_at: datetime
    recorded_at: datetime
    terminated: bool = False

    def __post_init__(self) -> None:
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        _match(AUTHORITY_ID, self.authority_id, "authority_id")
        _match(AUDIT_ID, self.establishment_audit_id, "establishment_audit_id")
        if self.version < 1:
            raise TrustError("lineage version starts at 1")
        if not str(self.subject_type or "").strip():
            raise TrustError("subject_type is required")
        if self.establishment_origin not in ESTABLISHMENT_ORIGINS:
            raise TrustError(
                f"establishment origin '{self.establishment_origin}' is not "
                "recognised; a root is established outside this platform"
            )
        if not self.evidence_reference_ids:
            raise TrustError(
                "a root establishment lineage requires at least one evidence reference")
        for evidence_id in self.evidence_reference_ids:
            _match(EVIDENCE_ID, evidence_id, "evidence_reference_ids")
        if self.current_state != TrustState.TRUSTED.value:
            raise TrustError(
                "a root establishment lineage records a trusted root or it is not "
                "a root establishment"
            )
        require_aware(self.established_at, "established_at")
        require_aware(self.recorded_at, "recorded_at")

    @property
    def lineage_type(self) -> str:
        """Constant discriminator. A property, so it cannot be passed a value."""
        return LINEAGE_TYPE_ROOT_ESTABLISHMENT

    @property
    def id(self) -> str:
        return f"{self.lineage_id}-v{self.version:04d}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "lineage_type": self.lineage_type,
            "lineage_id": self.lineage_id,
            "version": self.version,
            "authority_id": self.authority_id,
            "subject_type": self.subject_type,
            "establishment_origin": self.establishment_origin,
            "evidence_reference_ids": list(self.evidence_reference_ids),
            "establishment_audit_id": self.establishment_audit_id,
            "current_state": self.current_state,
            "established_at": self.established_at.isoformat(),
            "recorded_at": self.recorded_at.isoformat(),
            "terminated": self.terminated,
        }


# Exactly the keys a stored root establishment lineage may carry. Anything else
# is refused rather than ignored: a field nobody validates is a field that can
# claim anything.
ROOT_LINEAGE_KEYS = frozenset({
    "id", "lineage_type", "lineage_id", "version", "authority_id",
    "subject_type", "establishment_origin", "evidence_reference_ids",
    "establishment_audit_id", "current_state", "established_at", "recorded_at",
    "terminated",
})

# Named separately from the general unknown-key refusal so the message says why
# these in particular can never appear.
ROOT_LINEAGE_FORBIDDEN_KEYS = frozenset({
    "first_decision_id", "current_decision_id", "prior_decision_ids",
    "root_authority_id", "approved_by", "approval_source",
})


def validate_root_lineage_record(record: Mapping[str, Any], where: str) -> None:
    """Refuse a stored root establishment lineage that is not one."""
    kind = lineage_type_of(record, where)
    if kind != LINEAGE_TYPE_ROOT_ESTABLISHMENT:
        raise TrustError(
            f"{where} is a '{kind}' lineage, not a root establishment lineage")

    reject_forbidden_keys(record, where)

    present = set(record or {})
    for key in sorted(present & ROOT_LINEAGE_FORBIDDEN_KEYS):
        raise TrustError(
            f"{where} carries '{key}'; a root establishment records no decision "
            "and no approver, because nothing inside this platform made one"
        )
    for key in sorted(present - ROOT_LINEAGE_KEYS):
        raise TrustError(f"{where} carries an unrecognised field '{key}'")
    for key in sorted(ROOT_LINEAGE_KEYS - present - {"id", "terminated"}):
        raise TrustError(f"{where} is missing required field '{key}'")


@dataclass(frozen=True)
class TrustEvaluation:
    """A read-only answer about a subject at one moment.

    Carries both the stored state and the effective state. They differ only
    through expiry, and conflating them would report a grant as live after its
    boundary elapsed.
    """

    subject_id: str
    stored_state: str
    effective_state: str
    lineage_id: str | None
    evaluated_at: datetime
    scope: TrustScope | None = None
    record_id: str | None = None
    decision_id: str | None = None
    evidence_reference_ids: tuple[str, ...] = ()
    reasons: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        require_aware(self.evaluated_at, "evaluated_at")

    def to_dict(self) -> dict[str, Any]:
        return {
            "subject_id": self.subject_id,
            "stored_state": self.stored_state,
            "effective_state": self.effective_state,
            "lineage_id": self.lineage_id,
            "evaluated_at": self.evaluated_at.isoformat(),
            "scope": self.scope.to_dict() if self.scope else None,
            "record_id": self.record_id,
            "decision_id": self.decision_id,
            "evidence_reference_ids": list(self.evidence_reference_ids),
            "reasons": list(self.reasons),
        }


@dataclass(frozen=True)
class TrustAuditEvent:
    """An immutable record that something was written.

    Read-only evaluation emits none of these: an audit trail that records
    questions as well as changes buries the changes.
    """

    audit_id: str
    event_kind: str
    subject_id: str
    lineage_id: str
    actor_authority_id: str
    related_record_ids: tuple[str, ...]
    occurred_at: datetime
    reason: str
    provenance: Mapping[str, Any] = field(default_factory=dict)
    fingerprint: str = ""

    def __post_init__(self) -> None:
        _match(AUDIT_ID, self.audit_id, "audit_id")
        _match(LINEAGE_ID, self.lineage_id, "lineage_id")
        _match(AUTHORITY_ID, self.actor_authority_id, "actor_authority_id")
        require_aware(self.occurred_at, "occurred_at")
        reject_forbidden_keys(dict(self.provenance or {}), "audit provenance")
        object.__setattr__(self, "provenance", MappingProxyType(dict(self.provenance or {})))
        if not self.fingerprint:
            object.__setattr__(self, "fingerprint", fingerprint_of(self._body()))

    def _body(self) -> dict[str, Any]:
        return {
            "audit_id": self.audit_id,
            "event_kind": self.event_kind,
            "subject_id": self.subject_id,
            "lineage_id": self.lineage_id,
            "actor_authority_id": self.actor_authority_id,
            "related_record_ids": list(self.related_record_ids),
            "occurred_at": self.occurred_at.isoformat(),
            "reason": self.reason,
            "provenance": dict(self.provenance),
        }

    @property
    def id(self) -> str:
        return self.audit_id

    def to_dict(self) -> dict[str, Any]:
        payload = self._body()
        payload["id"] = self.id
        payload["fingerprint"] = self.fingerprint
        return payload
