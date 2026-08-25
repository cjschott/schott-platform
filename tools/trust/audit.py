"""Audit event kinds for the Trust Plane runtime.

Every write emits one. Read-only evaluation emits none: an audit trail that
records questions as well as changes buries the changes.
"""

from __future__ import annotations

from enum import Enum


class AuditEventKind(str, Enum):
    ROOT_AUTHORITY_DECLARED = "root-authority-declared"
    TRUST_DECISION_CREATED = "trust-decision-created"
    TRUST_RECORD_CREATED = "trust-record-created"
    LINEAGE_CREATED = "lineage-created"
    LINEAGE_ADVANCED = "lineage-advanced"
    # A root establishment lineage recorded after the fact, because the
    # ceremony's write path omitted it. Distinct from LINEAGE_CREATED: that
    # event says a lineage began, this one says a record of one that had
    # already begun was finally written.
    ROOT_LINEAGE_BACKFILLED = "root-establishment-lineage-backfilled"
    SUBJECT_RESTRICTED = "subject-restricted"
    SUBJECT_QUARANTINED = "subject-quarantined"
    SUBJECT_REVOKED = "subject-revoked"
    SUBJECT_REJECTED = "subject-rejected"
    SUBJECT_EXPIRED_RECORDED = "subject-expired-recorded"


STATE_EVENT = {
    "restricted": AuditEventKind.SUBJECT_RESTRICTED,
    "quarantined": AuditEventKind.SUBJECT_QUARANTINED,
    "revoked": AuditEventKind.SUBJECT_REVOKED,
    "rejected": AuditEventKind.SUBJECT_REJECTED,
    "expired": AuditEventKind.SUBJECT_EXPIRED_RECORDED,
}
