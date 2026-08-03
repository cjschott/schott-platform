"""Declaring that an external Operator Root Authority exists.

The critical distinction: Kyri may persist a declaration that an external root
exists, and Kyri must not establish the external identity itself. This module
records what a human verified out of band. It does not verify, does not
resolve, and does not guess.

There is no interactive prompt, no environment-variable identity, and no
implicit current user. A root authority that the platform could infer is a
chain terminating inside the thing it governs.

Only one active root exists per store in v0.9.3. A second is refused: two roots
is no root. Superseding the root is not implemented, and neither updating nor
deleting it is possible.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any

from .audit import AuditEventKind
from .errors import TrustError
from .models import (
    AuthorityType,
    OperatorRootAuthority,
    TrustAuditEvent,
    TrustEvidenceReference,
    TrustState,
    TrustVerificationDetails,
    VerificationMethod,
    reject_forbidden_keys,
)

REQUIRED_FIELDS = (
    "display_name", "external_identity_reference", "verification_method",
    "verification_details", "evidence_references", "created_at",
)

REQUIRED_DETAILS = (
    "subject_property", "observed_value_reference", "comparison_source",
    "performed_by", "performed_at",
)


def _parse_time(value: Any, name: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        raise TrustError(f"{name} must be an ISO 8601 timestamp") from None
    if parsed.tzinfo is None:
        raise TrustError(f"{name} must carry a timezone offset")
    return parsed


def load_root_declaration(name: str, approved_directory: str) -> dict[str, Any]:
    """Read a root declaration from an approved directory, or refuse.

    Containment is checked after full resolution, so a symlink pointing out of
    the directory is refused rather than followed.
    """
    import yaml

    approved = Path(approved_directory).expanduser().resolve(strict=False)
    candidate = (approved / name).resolve(strict=False)
    if candidate == approved or approved not in candidate.parents:
        raise TrustError(
            f"input file '{name}' resolves outside the approved directory")
    if not candidate.is_file():
        raise TrustError(f"input file '{name}' does not exist in the approved directory")

    try:
        data = yaml.safe_load(candidate.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise TrustError(
            f"input file '{name}' is not valid YAML ({type(error).__name__})") from None
    if not isinstance(data, dict):
        raise TrustError(f"input file '{name}' must contain a mapping")

    # Credential material is refused outright, and the value is never echoed.
    reject_forbidden_keys(data, f"root declaration '{name}'")

    for required in REQUIRED_FIELDS:
        if required not in data:
            raise TrustError(f"root declaration is missing required field '{required}'")

    details = data.get("verification_details")
    if not isinstance(details, dict):
        raise TrustError("verification_details must be a mapping")
    for required in REQUIRED_DETAILS:
        if not str(details.get(required) or "").strip():
            raise TrustError(f"verification detail '{required}' is required")

    references = data.get("evidence_references")
    if not isinstance(references, list) or not references:
        raise TrustError("at least one evidence reference is required")

    return data


def declare_root_authority(store, declaration: dict[str, Any]):
    """Persist the declaration that an external root authority exists.

    Fails closed when a root already exists. The existing root is not replaced,
    superseded, or merged: that is a decision this release does not implement.
    """
    existing = [a for a in store.all_records("authority")
                if a.get("authority_type") == AuthorityType.OPERATOR_ROOT.value
                and a.get("state") == TrustState.TRUSTED.value]
    if existing:
        raise TrustError(
            "an active operator-root authority already exists in this store; "
            "two roots is no root, and superseding the root is not implemented "
            "in v0.9.3"
        )

    method = str(declaration["verification_method"])
    if method not in {m.value for m in VerificationMethod}:
        raise TrustError(f"verification method '{method}' is not recognised")

    details_input = declaration["verification_details"]
    details = TrustVerificationDetails(
        subject_property=str(details_input["subject_property"]),
        observed_value_reference=str(details_input["observed_value_reference"]),
        comparison_source=str(details_input["comparison_source"]),
        performed_by=str(details_input["performed_by"]),
        performed_at=_parse_time(details_input["performed_at"], "performed_at"),
    )

    references: list[TrustEvidenceReference] = []
    for item in declaration["evidence_references"]:
        references.append(TrustEvidenceReference(
            evidence_id=store.allocate_id("evidence"),
            kind=str(item.get("kind", "attestation")),
            reference=str(item["reference"]),
            recorded_at=_parse_time(item.get("recorded_at", declaration["created_at"]),
                                    "recorded_at"),
        ))

    authority = OperatorRootAuthority(
        authority_id=store.allocate_id("authority"),
        authority_type=AuthorityType.OPERATOR_ROOT.value,
        display_name=str(declaration["display_name"]),
        external_identity_reference=str(declaration["external_identity_reference"]),
        verification_method=method,
        verification_details=details,
        evidence_references=tuple(references),
        created_at=_parse_time(declaration["created_at"], "created_at"),
        provenance=dict(declaration.get("provenance") or {}),
        state=TrustState.TRUSTED.value,
        lineage_id=store.allocate_id("lineage"),
    )

    for reference in references:
        store.write("evidence", reference)
    store.write("authority", authority)
    store.write("audit", TrustAuditEvent(
        audit_id=store.allocate_id("audit"),
        event_kind=AuditEventKind.ROOT_AUTHORITY_DECLARED.value,
        subject_id=authority.authority_id,
        lineage_id=authority.lineage_id,
        actor_authority_id=authority.authority_id,
        related_record_ids=tuple(r.evidence_id for r in references),
        occurred_at=authority.created_at,
        reason="an external operator root authority was declared out of band",
        provenance=dict(declaration.get("provenance") or {}),
    ))
    return authority
