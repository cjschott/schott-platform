"""Controlled refusals for the Health record models.

**A refusal names what was wrong and never what was supplied.** Every message is
assembled from a code and a field name, both of which are drawn from closed sets
declared in this module. A rejected value is never interpolated, never repr'd and
never echoed, because the values that reach a record model are exactly the values
worth protecting: a credential pasted into the wrong field, a fingerprint, an
operator's note. A model that reported what it refused would publish the thing it
was defending through its own error path, and it would do so into whatever log is
reading at the time.

The codes are a **closed vocabulary**, not a convenience. An open set of refusal
reasons drifts into carrying diagnostic detail, and the first value to be
interpolated "just for debugging" is the one that leaks.
"""

from __future__ import annotations

# --- the closed refusal vocabulary ---------------------------------------
#
# One code per distinct way a payload can fail to be a record. Distinct rather
# than general, because an operator reading a refusal needs to know which
# correction to make: a missing field, an unknown field and a forbidden field
# call for three different actions, and collapsing them to "invalid record"
# would make the refusal unactionable.
UNKNOWN_RECORD_KIND = "unknown-record-kind"
PAYLOAD_NOT_A_MAPPING = "payload-not-a-mapping"
MISSING_REQUIRED_FIELD = "missing-required-field"
UNKNOWN_FIELD = "unknown-field"
FORBIDDEN_FIELD = "forbidden-field"
IDENTIFIER_MALFORMED = "identifier-malformed"
REFERENCE_MALFORMED = "reference-malformed"
ENUM_VALUE_NOT_PERMITTED = "enum-value-not-permitted"
SUBJECT_TYPE_NOT_PERMITTED = "subject-type-not-permitted"
FIELD_TYPE_INVALID = "field-type-invalid"
FIELD_EMPTY = "field-empty"
CONDITIONAL_REQUIREMENT_UNMET = "conditional-requirement-unmet"
MEASURED_VALUE_INCONSISTENT = "measured-value-inconsistent-with-collection-status"
DIMENSION_ENTRY_MALFORMED = "dimension-entry-malformed"
DIMENSION_NOT_DECLARED = "dimension-not-declared"
DIMENSION_SUBJECT_INCOMPATIBLE = "dimension-subject-incompatible"
UNIT_MISMATCH = "unit-mismatch"
OPERATOR_NOT_PERMITTED = "operator-not-permitted"
AGGREGATION_NOT_PERMITTED = "aggregation-not-permitted"
HYSTERESIS_KIND_NOT_PERMITTED = "hysteresis-kind-not-permitted"
TIMESTAMP_NOT_OFFSET_AWARE = "timestamp-not-offset-aware"
RECORD_IMMUTABLE = "record-immutable"

# --- ENG-0006-H2: subject identity and reference validation --------------
#
# ADR-0013: "A refusal names the mismatch from a controlled vocabulary and
# echoes no value." These are those classes. Each names a DIFFERENT way a
# citation can be false, because an operator reading one needs to know which
# correction to make: a foreign subject, a record nobody supplied, a record of
# the wrong family, and a record standing in for another are four distinct
# faults and collapsing them would make the refusal unactionable.
CROSS_SUBJECT_CITATION = "cross-subject-citation"
# Deliberately NOT "nonexistent-reference". This layer is given a record and
# the records it cites; it can know that a citation was not supplied, and it
# cannot know that the cited record does not exist anywhere. Naming it after
# what was actually observed keeps the refusal honest.
CITED_RECORD_NOT_SUPPLIED = "cited-record-not-supplied"
CITED_RECORD_KIND_MISMATCH = "cited-record-kind-mismatch"
CITED_RECORD_IDENTITY_MISMATCH = "cited-record-identity-mismatch"
CITATION_SET_MALFORMED = "citation-set-malformed"

CODES = frozenset({
    UNKNOWN_RECORD_KIND, PAYLOAD_NOT_A_MAPPING, MISSING_REQUIRED_FIELD,
    UNKNOWN_FIELD, FORBIDDEN_FIELD, IDENTIFIER_MALFORMED, REFERENCE_MALFORMED,
    ENUM_VALUE_NOT_PERMITTED, SUBJECT_TYPE_NOT_PERMITTED, FIELD_TYPE_INVALID,
    FIELD_EMPTY, CONDITIONAL_REQUIREMENT_UNMET, MEASURED_VALUE_INCONSISTENT,
    DIMENSION_ENTRY_MALFORMED, DIMENSION_NOT_DECLARED,
    DIMENSION_SUBJECT_INCOMPATIBLE, UNIT_MISMATCH, OPERATOR_NOT_PERMITTED,
    AGGREGATION_NOT_PERMITTED, HYSTERESIS_KIND_NOT_PERMITTED,
    TIMESTAMP_NOT_OFFSET_AWARE, RECORD_IMMUTABLE,
    CROSS_SUBJECT_CITATION, CITED_RECORD_NOT_SUPPLIED,
    CITED_RECORD_KIND_MISMATCH, CITED_RECORD_IDENTITY_MISMATCH,
    CITATION_SET_MALFORMED,
})


class HealthRecordError(Exception):
    """A refused Health record payload.

    Carries a `code` from the closed vocabulary above and, where one applies,
    the `kind` and `field` the refusal concerns. The rendered message is built
    from those three identifiers alone.
    """

    def __init__(self, code: str, *, kind: str | None = None,
                 field: str | None = None, detail: str | None = None) -> None:
        if code not in CODES:
            # A refusal with an undeclared code would be a refusal nobody can
            # act on, so this is itself refused rather than passed through.
            raise AssertionError("refusal code is not in the declared vocabulary")
        self.code = code
        self.kind = kind
        self.field = field
        # `detail` is for a FIELD NAME or another declared identifier only.
        # Never a supplied value. Callers in this package pass constants.
        self.detail = detail
        parts = [code]
        if kind is not None:
            parts.append(f"kind={kind}")
        if field is not None:
            parts.append(f"field={field}")
        if detail is not None:
            parts.append(f"detail={detail}")
        super().__init__(" ".join(parts))


def refuse(code: str, *, kind: str | None = None, field: str | None = None,
           detail: str | None = None) -> "HealthRecordError":
    """Build a refusal. Returned rather than raised so a caller reads as
    `raise refuse(...)`, which keeps the raise visible at the call site."""
    return HealthRecordError(code, kind=kind, field=field, detail=detail)
