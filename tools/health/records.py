"""Immutable, schema-conformant Health record models — ENG-0006-H1.

**This is a representation layer and nothing else.** It parses a mapping into a
frozen record, refuses anything that is not one, and serialises back. There is
no store, no sequence allocation, no evaluation of a condition, no freshness
calculation, no hysteresis judgement, no state derivation, no ingestion, no
network and no subprocess. Those are later increments with their own gates, and
the reason they are absent here is that a Health record foundation has to be
trustworthy before the platform gains any Health authority at all.

**Health enforces its own required fields.** The Fabric's record reader refuses
unknown keys and never checks for missing ones, which is safe there because its
dataclass defaults carry the meaning. That omission is deliberately *not* copied:
a Health record with a field absent is refused, because an absent field in this
plane is an absent assertion, and the layer's whole purpose is to avoid asserting
what it does not know.

**The declarative specs below mirror the committed schemas.** They are declared
in code rather than read from YAML at import time, so the model has no runtime
file dependency; the behavioural suite uses the schemas as its oracle and
compares this module against them, which is what keeps the two from drifting.

**Immutability is deep and covers retained references.** A caller who keeps a
reference to the mapping or list it supplied cannot change what the record says
afterwards, and `to_dict()` hands back a fresh structure rather than the
record's own.
"""

from __future__ import annotations

import re
from datetime import datetime
from decimal import Decimal, InvalidOperation
from types import MappingProxyType
from typing import Any, Mapping, Sequence

from . import errors as E

# --- identifier patterns, per family -------------------------------------
PATTERNS: Mapping[str, re.Pattern[str]] = {
    "capability-health-envelope": re.compile(r"^CHENV-[0-9]{4}$"),
    "capability-heartbeat": re.compile(r"^CHBEAT-[0-9]{6}$"),
    "capability-health-observation": re.compile(r"^CHOBS-[0-9]{6}$"),
    "capability-health-state": re.compile(r"^CHSTATE-[0-9]{6}$"),
    "capability-degradation-event": re.compile(r"^CHDEG-[0-9]{6}$"),
    "capability-health-recommendation": re.compile(r"^CHREC-[0-9]{6}$"),
}

# --- closed vocabularies -------------------------------------------------
SUBJECT_TYPES = ("capability-instance", "capability-host")

HEALTH_STATES = ("unknown", "unmonitored", "insufficient-policy", "healthy",
                 "degraded", "unavailable", "withheld")

RECOMMENDATIONS = ("investigate", "review-envelope", "verify-observation-source",
                   "consider-manual-drain")

COLLECTION_STATUSES = ("collected", "failed", "unavailable")

FRESHNESS = ("current", "aging", "stale", "unknown")

EVALUATIONS = ("worst-dimension-wins",)

CONDITION_OPERATORS = ("gt", "ge", "lt", "le", "eq")

AGGREGATIONS = ("instant", "windowed_count")

HYSTERESIS_KINDS = ("duration",)

# Exactly one unit per dimension. A mismatch is refused and never converted:
# implicit conversion is how two readings of the same limit disagree silently.
DIMENSION_UNITS: Mapping[str, str] = {
    "availability": "boolean",
    "heartbeat-freshness": "seconds",
    "transport-health": "boolean",
    "latency": "milliseconds",
    "queue-depth": "items",
    "success-count": "count",
    "failure-count": "count",
    "cpu-utilization": "percent",
    "memory-utilization": "percent",
    "gpu-utilization": "percent",
    "vram-utilization": "percent",
    "storage-pressure": "percent",
    "collector-freshness": "seconds",
}

DIMENSIONS = tuple(DIMENSION_UNITS)

# Which subjects each dimension may describe. A package is absent from every
# one: it is not a running thing, so an availability or latency claim about one
# would describe something that does not run.
DIMENSION_SUBJECTS: Mapping[str, tuple[str, ...]] = {
    name: ("capability-instance", "capability-host") for name in DIMENSIONS
}


# --- deep freeze ---------------------------------------------------------
def _frozen(value: Any) -> Any:
    """Freeze all the way down.

    A proxy around a mutable list would leave a frozen record editable through
    its own contents, so mappings become read-only proxies and sequences become
    tuples, recursively. The convention is the platform's; the implementation is
    local, because importing it would make this plane depend on another.
    """
    if isinstance(value, Mapping):
        return MappingProxyType({key: _frozen(item) for key, item in value.items()})
    if isinstance(value, (list, tuple)):
        return tuple(_frozen(item) for item in value)
    return value


def _thawed(value: Any) -> Any:
    """A fresh mutable structure, for serialisation."""
    if isinstance(value, Mapping):
        return {key: _thawed(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_thawed(item) for item in value]
    return value


# --- field validators ----------------------------------------------------
# Each takes the kind, the field name and the value, and either returns the
# value or raises a refusal naming the code and the field. None of them ever
# places the value in the refusal.

def _text(kind: str, field: str, value: Any) -> str:
    if not isinstance(value, str):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="string")
    if not value.strip():
        raise E.refuse(E.FIELD_EMPTY, kind=kind, field=field)
    return value


def _boolean(kind: str, field: str, value: Any) -> bool:
    # `isinstance(True, int)` is true in Python, so booleans are checked before
    # integers everywhere in this module and integers exclude them explicitly.
    if not isinstance(value, bool):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="boolean")
    return value


def _whole(kind: str, field: str, value: Any, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="integer")
    if value < minimum:
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail=f"integer-at-least-{minimum}")
    return value


def _mapping(kind: str, field: str, value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="mapping")
    if not value:
        raise E.refuse(E.FIELD_EMPTY, kind=kind, field=field)
    return value


def _member(kind: str, field: str, value: Any, permitted: Sequence[str],
            *, code: str = E.ENUM_VALUE_NOT_PERMITTED) -> str:
    if not isinstance(value, str) or value not in permitted:
        raise E.refuse(code, kind=kind, field=field)
    return value


def _identifier(kind: str, field: str, value: Any, family: str,
                *, code: str = E.IDENTIFIER_MALFORMED) -> str:
    if not isinstance(value, str) or not PATTERNS[family].match(value):
        raise E.refuse(code, kind=kind, field=field, detail=family)
    return value


def _instant(kind: str, field: str, value: Any) -> str:
    """An offset-aware timestamp string denoting a valid instant.

    **No canonical string grammar is imposed**, because none is declared. The
    standards that require RFC 3339 scope themselves to directories this plane's
    records do not live in, and the entity-lifecycle standard — the widest of
    them — says explicitly that it does not define runtime health. So the
    contract is offset awareness and the spelling is not constrained: the basic
    ISO form and a week date are accepted alongside the extended form, and each
    denotes a real moment with a real offset.

    An instant with no offset is not a moment: the same string means different
    moments on two hosts, and a record that cannot be ordered against another
    cannot support an audit. The Fabric refuses a naive evaluation instant for
    the same reason.

    The value is returned unchanged. Nothing here normalises, reformats or
    canonicalises a timestamp, so a record reads back exactly as it was written.
    """
    if not isinstance(value, str):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="instant")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise E.refuse(E.TIMESTAMP_NOT_OFFSET_AWARE, kind=kind, field=field) from None
    if parsed.tzinfo is None or parsed.tzinfo.utcoffset(parsed) is None:
        raise E.refuse(E.TIMESTAMP_NOT_OFFSET_AWARE, kind=kind, field=field)
    return value


# A bare decimal numeral, and nothing else. Optional sign, digits with an
# optional fractional part (or a leading point), and an optional exponent.
#
# `Decimal()` alone is NOT this grammar. It also accepts the IEEE specials
# `NaN`, `sNaN` and `Infinity` in several spellings, surrounding whitespace, and
# Python's underscore digit separators -- none of which is a decimal string, and
# the specials are not decimal VALUES at all.
# Matched with `fullmatch`, and deliberately NOT with `^...$`: in Python `$`
# also matches just before a trailing newline, so `"1\n"` would have passed an
# anchored `match()` and reached the store as a threshold with a newline in it.
_DECIMAL_TEXT = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?")


def _decimal_text(kind: str, field: str, value: Any) -> str:
    """A FINITE decimal written as a bare decimal string, compared exactly.

    Not a binary float: `0.1` must not depend on representation, and a threshold
    that compares differently on two hosts is not deterministic.

    **And not a non-finite special.** A threshold of `NaN` or `Infinity` passes
    `Decimal()` and then destroys the thing a threshold is for. Under the default
    decimal context every comparison against `NaN` *raises* rather than returning
    a verdict, so the evaluator would fail instead of deciding; and a threshold of
    `Infinity` is violated either always or never, whatever was measured. In both
    cases the dimension looks governed and can produce no honest finding -- which
    is the favourable default ADR-0013 forbids ("the absence of a policy produces
    an explicit 'not defined', never a favourable default";
    `absent_threshold_never_means: healthy`), wearing a declared policy's clothes.

    No precision, magnitude or range restriction is imposed: none is declared
    anywhere, and inventing one would narrow what an operator may write down. A
    four-hundred-digit limit is accepted, and so is `1e999999` -- a `Decimal`
    carries its exponent rather than converting, so that value is finite. An
    exponent large enough that `Decimal` itself will not construct the value
    raises at construction and is refused as malformed syntax.
    """
    if not isinstance(value, str):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="decimal-string")
    if not _DECIMAL_TEXT.fullmatch(value):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="decimal-string")
    try:
        parsed = Decimal(value)
    except InvalidOperation:
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="decimal-string") from None
    # Defence in depth, and currently unreachable: the grammar above already
    # excludes every spelling of a special, and a grammar-conforming string
    # either constructs finite or raises above. This gate is kept so the
    # finiteness guarantee is stated where it is relied on, rather than left
    # as a property inferred from a regular expression.
    if not parsed.is_finite():
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field,
                       detail="finite-decimal")
    return value


def _id_sequence(kind: str, field: str, value: Any, family: str) -> tuple[str, ...]:
    if isinstance(value, (str, bytes)) or not isinstance(value, Sequence):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=kind, field=field, detail="sequence")
    if not value:
        raise E.refuse(E.FIELD_EMPTY, kind=kind, field=field)
    return tuple(_identifier(kind, field, item, family, code=E.REFERENCE_MALFORMED)
                 for item in value)


def _condition(kind: str, field: str, value: Any) -> Mapping[str, Any]:
    """A structured condition. There is no expression string to parse.

    A free-text predicate would need a grammar nobody declared, and every token
    such a parser accepted would be a threshold decision taken on an operator's
    behalf.
    """
    if not isinstance(value, Mapping):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="structured-condition")
    present = set(value)
    if present != {"operator", "value"}:
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="operator-and-value")
    _member(kind, field, value.get("operator"), CONDITION_OPERATORS,
            code=E.OPERATOR_NOT_PERMITTED)
    _decimal_text(kind, field, value.get("value"))
    return value


def _aggregation(kind: str, field: str, value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="aggregation")
    which = value.get("kind")
    _member(kind, field, which, AGGREGATIONS, code=E.AGGREGATION_NOT_PERMITTED)
    if which == "instant":
        if set(value) != {"kind"}:
            raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                           detail="instant-takes-no-parameter")
    else:
        if set(value) != {"kind", "window_seconds", "min_samples"}:
            raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                           detail="window_seconds-and-min_samples")
        _whole(kind, field, value.get("window_seconds"), minimum=1)
        # One sample in an empty window is not a verdict, so a minimum is
        # declared rather than defaulted.
        _whole(kind, field, value.get("min_samples"), minimum=1)
    return value


def _hysteresis(kind: str, field: str, value: Any) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="hysteresis")
    _member(kind, field, value.get("kind"), HYSTERESIS_KINDS,
            code=E.HYSTERESIS_KIND_NOT_PERMITTED)
    if set(value) != {"kind", "seconds", "max_gap_seconds", "min_samples"}:
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="kind-seconds-max_gap_seconds-min_samples")
    # Neither continuity member has a default. A defaulted one would be an
    # unanswered configuration question rendered as a confident assessment.
    _whole(kind, field, value.get("seconds"), minimum=1)
    _whole(kind, field, value.get("max_gap_seconds"), minimum=1)
    _whole(kind, field, value.get("min_samples"), minimum=1)
    return value


def _dimension_entry(kind: str, name: Any, entry: Any) -> Mapping[str, Any]:
    field = "dimensions"
    if not isinstance(name, str) or name not in DIMENSION_UNITS:
        raise E.refuse(E.DIMENSION_NOT_DECLARED, kind=kind, field=field)
    if not isinstance(entry, Mapping):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="mapping")
    expected = {"dimension", "unit", "aggregation", "entry_condition",
                "exit_condition", "hysteresis", "freshness_policy_seconds"}
    present = set(entry)
    missing = expected - present
    if missing:
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="missing-" + "-".join(sorted(missing)))
    if present - expected:
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="undeclared-member")
    declared = _member(kind, field, entry.get("dimension"), DIMENSIONS,
                       code=E.DIMENSION_NOT_DECLARED)
    if declared != name:
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=kind, field=field,
                       detail="dimension-key-disagrees-with-member")
    if entry.get("unit") != DIMENSION_UNITS[declared]:
        raise E.refuse(E.UNIT_MISMATCH, kind=kind, field=field, detail=declared)
    _aggregation(kind, field, entry.get("aggregation"))
    _condition(kind, field, entry.get("entry_condition"))
    _condition(kind, field, entry.get("exit_condition"))
    _hysteresis(kind, field, entry.get("hysteresis"))
    policy = entry.get("freshness_policy_seconds")
    # Null is permitted and produces freshness: unknown, per the Null Policy
    # Rule. It must never be defaulted to a number.
    if policy is not None:
        _whole(kind, field, policy, minimum=1)
    return entry


def _dimensions(kind: str, field: str, value: Any) -> Mapping[str, Any]:
    mapped = _mapping(kind, field, value)
    for name, entry in mapped.items():
        _dimension_entry(kind, name, entry)
    return mapped


# --- the record ----------------------------------------------------------
class HealthRecord:
    """One frozen Health record.

    Attributes are read through normal access; assignment is refused. The
    payload is validated in full before any attribute exists, so a refused
    payload produces no object at all rather than a partly-built one.
    """

    __slots__ = ("_kind", "_fields")

    def __init__(self, kind: str, fields: Mapping[str, Any]) -> None:
        object.__setattr__(self, "_kind", kind)
        object.__setattr__(self, "_fields", _frozen(dict(fields)))

    # --- immutability ---
    def __setattr__(self, name: str, value: Any) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=self._kind, field=name)

    def __delattr__(self, name: str) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=self._kind, field=name)

    def __getattr__(self, name: str) -> Any:
        try:
            return object.__getattribute__(self, "_fields")[name]
        except KeyError:
            raise AttributeError(name) from None

    @property
    def kind(self) -> str:
        return object.__getattribute__(self, "_kind")

    def to_dict(self) -> dict[str, Any]:
        """A fresh, fully mutable copy. Mutating it cannot reach the record."""
        return _thawed(dict(object.__getattribute__(self, "_fields")))

    def __eq__(self, other: Any) -> bool:
        if not isinstance(other, HealthRecord):
            return NotImplemented
        return self.kind == other.kind and self.to_dict() == other.to_dict()

    def __hash__(self) -> int:
        return hash((self.kind, tuple(sorted(self.to_dict()))))

    def __repr__(self) -> str:
        # The identifier only. A repr that printed the fields would put every
        # supplied value into whatever is logging.
        identity = object.__getattribute__(self, "_fields").get(
            IDENTITY_FIELD[self.kind], "")
        return f"<HealthRecord {self.kind} {identity}>"


# --- per-family specification -------------------------------------------
# kind -> (identity field, required fields, conditionally required, optional,
#          forbidden)
IDENTITY_FIELD: Mapping[str, str] = {
    "capability-health-envelope": "envelope_id",
    "capability-health-observation": "observation_id",
    "capability-health-state": "state_id",
    "capability-degradation-event": "event_id",
    "capability-health-recommendation": "recommendation_id",
    "capability-heartbeat": "heartbeat_id",
}

REQUIRED: Mapping[str, tuple[str, ...]] = {
    "capability-health-envelope": (
        "envelope_id", "envelope_version", "subject_type", "subject_id",
        "dimensions", "evaluation", "provenance"),
    "capability-health-observation": (
        "observation_id", "subject_type", "subject_id", "dimension",
        "measured_value", "unit", "observed_at", "collector_id",
        "source_fingerprint", "collection_status", "provenance"),
    "capability-health-state": (
        "state_id", "subject_type", "subject_id", "state", "envelope_id",
        "envelope_version", "derived_from_observation_ids", "freshness",
        "reason", "evaluated_at", "provenance"),
    "capability-degradation-event": (
        "event_id", "subject_type", "subject_id", "from_state", "to_state",
        "dimension", "entry_condition", "observed_at",
        "derived_from_observation_ids", "provenance", "hysteresis",
        "hysteresis_satisfied_over_seconds", "hysteresis_first_observation_id",
        "hysteresis_last_observation_id", "hysteresis_sample_count",
        "hysteresis_observed_max_gap_seconds"),
    "capability-health-recommendation": (
        "recommendation_id", "subject_type", "subject_id", "recommendation",
        "reason", "derived_from_state_id", "created_at", "review_required",
        "advisory_only", "provenance"),
    "capability-heartbeat": (
        "heartbeat_id", "subject_type", "subject_id", "observed_at",
        "received_at", "epoch", "sequence", "provenance"),
}

CONDITIONAL: Mapping[str, tuple[str, ...]] = {
    "capability-health-state": ("review_required",),
}

OPTIONAL: Mapping[str, tuple[str, ...]] = {
    "capability-health-envelope": (
        "description", "review_due_at", "supersedes", "superseded_by", "notes"),
    "capability-health-observation": (
        "collection_error", "freshness", "sample_window_seconds", "notes"),
    "capability-health-state": (
        "dimension_results", "supersedes", "superseded_by", "notes"),
    "capability-degradation-event": ("exit_condition", "envelope_id", "notes"),
    "capability-health-recommendation": (
        "derived_from_event_id", "acknowledged_at", "acknowledged_by", "notes"),
    "capability-heartbeat": ("reported_uptime_seconds", "notes"),
}

FORBIDDEN: Mapping[str, tuple[str, ...]] = {
    "capability-health-envelope": (
        "learned_threshold", "auto_threshold", "baseline_threshold",
        "derived_threshold", "anomaly_model", "anomaly_score", "forecast",
        "predicted_limit", "health_score", "trust_state", "command"),
    "capability-health-observation": (
        "source", "health_state", "verdict", "conclusion", "assessment",
        "trust_state", "eligibility", "predicted_value", "forecast",
        "anomaly_score", "health_score", "recommendation", "command", "argv"),
    "capability-health-state": (
        "health_score", "trust_state", "trust_score", "predicted_state",
        "forecast", "anomaly_score", "auto_drain", "auto_quarantine",
        "auto_reroute", "auto_remediate", "command"),
    "capability-degradation-event": (
        "predicted_failure", "forecast", "time_to_failure", "probability",
        "anomaly_score", "health_score", "trust_state", "auto_drain",
        "auto_quarantine", "auto_reroute", "auto_remediate", "command"),
    "capability-health-recommendation": (
        "quarantine", "revoke", "trust", "approve", "broaden_scope", "reroute",
        "restart", "stop", "kill", "repair", "remediate", "remediation",
        "execution_target", "action_payload", "command", "argv", "script",
        "shell", "auto_execute", "auto_apply", "auto_drain", "auto_quarantine",
        "execute_at", "route_id", "selection_id", "trust_state",
        "trust_decision_id", "mutates_route", "mutates_trust_state",
        "health_score"),
    "capability-heartbeat": (
        "health_state", "trust_state", "trusted", "eligibility", "admitted",
        "route_id", "priority", "health_score", "token", "secret",
        "credential", "command"),
}

KINDS = tuple(REQUIRED)


# --- per-family field validation ----------------------------------------
def _validate_envelope(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "envelope_id", p["envelope_id"], kind)
    _whole(kind, "envelope_version", p["envelope_version"], minimum=1)
    _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
            code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    _dimensions(kind, "dimensions", p["dimensions"])
    _member(kind, "evaluation", p["evaluation"], EVALUATIONS)
    _mapping(kind, "provenance", p["provenance"])
    for field in ("description", "notes", "supersedes", "superseded_by"):
        if p.get(field) is not None:
            _text(kind, field, p[field])
    if p.get("review_due_at") is not None:
        _instant(kind, "review_due_at", p["review_due_at"])


def _validate_observation(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "observation_id", p["observation_id"], kind)
    subject_type = _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
                           code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    dimension = _member(kind, "dimension", p["dimension"], DIMENSIONS,
                        code=E.DIMENSION_NOT_DECLARED)
    if subject_type not in DIMENSION_SUBJECTS[dimension]:
        raise E.refuse(E.DIMENSION_SUBJECT_INCOMPATIBLE, kind=kind,
                       field="dimension", detail=dimension)
    if p["unit"] != DIMENSION_UNITS[dimension]:
        raise E.refuse(E.UNIT_MISMATCH, kind=kind, field="unit", detail=dimension)
    _instant(kind, "observed_at", p["observed_at"])
    _text(kind, "collector_id", p["collector_id"])
    _text(kind, "source_fingerprint", p["source_fingerprint"])
    status = _member(kind, "collection_status", p["collection_status"],
                     COLLECTION_STATUSES)
    # A failed collection has NO measurement. Recording a zero would be
    # inventing one, and a monitor that invented a value would manufacture
    # findings out of its own outages.
    measured = p["measured_value"]
    if status == "collected":
        if measured is None:
            raise E.refuse(E.MEASURED_VALUE_INCONSISTENT, kind=kind,
                           field="measured_value", detail="collected")
    elif measured is not None:
        raise E.refuse(E.MEASURED_VALUE_INCONSISTENT, kind=kind,
                       field="measured_value", detail=status)
    _mapping(kind, "provenance", p["provenance"])
    if p.get("freshness") is not None:
        _member(kind, "freshness", p["freshness"], FRESHNESS)
    if p.get("sample_window_seconds") is not None:
        _whole(kind, "sample_window_seconds", p["sample_window_seconds"], minimum=1)
    for field in ("collection_error", "notes"):
        if p.get(field) is not None:
            _text(kind, field, p[field])


def _validate_state(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "state_id", p["state_id"], kind)
    _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
            code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    state = _member(kind, "state", p["state"], HEALTH_STATES)
    _identifier(kind, "envelope_id", p["envelope_id"],
                "capability-health-envelope", code=E.REFERENCE_MALFORMED)
    _whole(kind, "envelope_version", p["envelope_version"], minimum=1)
    _id_sequence(kind, "derived_from_observation_ids",
                 p["derived_from_observation_ids"], "capability-health-observation")
    _member(kind, "freshness", p["freshness"], FRESHNESS)
    _text(kind, "reason", p["reason"])
    _instant(kind, "evaluated_at", p["evaluated_at"])
    _mapping(kind, "provenance", p["provenance"])
    # The Null Policy Rule's flag. Only ONE leg of its declared condition is
    # decidable from this record alone -- `insufficient-policy` -- and that leg
    # is enforced. The other two legs ("arising from a null freshness policy"
    # and "from contradicting sources") are properties of the envelope and the
    # observations, which this layer does not hold, so they are left to the
    # deriving increment rather than guessed at here.
    flag = p.get("review_required")
    if flag is not None:
        _boolean(kind, "review_required", flag)
    if state == "insufficient-policy" and flag is not True:
        raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                       field="review_required", detail="insufficient-policy")
    if p.get("dimension_results") is not None:
        _mapping(kind, "dimension_results", p["dimension_results"])
    for field in ("supersedes", "superseded_by", "notes"):
        if p.get(field) is not None:
            _text(kind, field, p[field])


def _validate_event(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "event_id", p["event_id"], kind)
    _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
            code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    _member(kind, "from_state", p["from_state"], HEALTH_STATES)
    _member(kind, "to_state", p["to_state"], HEALTH_STATES)
    _member(kind, "dimension", p["dimension"], DIMENSIONS,
            code=E.DIMENSION_NOT_DECLARED)
    _condition(kind, "entry_condition", p["entry_condition"])
    _instant(kind, "observed_at", p["observed_at"])
    _id_sequence(kind, "derived_from_observation_ids",
                 p["derived_from_observation_ids"], "capability-health-observation")
    _mapping(kind, "provenance", p["provenance"])
    # The hysteresis proof. Every declared parameter has a matching OBSERVED
    # value beside it, so an operator can recompute the verdict from this record
    # and the cited observations without the evaluator. A transition that cannot
    # show its hysteresis was satisfied is not recordable.
    _hysteresis(kind, "hysteresis", p["hysteresis"])
    _whole(kind, "hysteresis_satisfied_over_seconds",
           p["hysteresis_satisfied_over_seconds"], minimum=1)
    _identifier(kind, "hysteresis_first_observation_id",
                p["hysteresis_first_observation_id"],
                "capability-health-observation", code=E.REFERENCE_MALFORMED)
    _identifier(kind, "hysteresis_last_observation_id",
                p["hysteresis_last_observation_id"],
                "capability-health-observation", code=E.REFERENCE_MALFORMED)
    _whole(kind, "hysteresis_sample_count", p["hysteresis_sample_count"], minimum=1)
    _whole(kind, "hysteresis_observed_max_gap_seconds",
           p["hysteresis_observed_max_gap_seconds"], minimum=0)
    if p.get("exit_condition") is not None:
        _condition(kind, "exit_condition", p["exit_condition"])
    if p.get("envelope_id") is not None:
        _identifier(kind, "envelope_id", p["envelope_id"],
                    "capability-health-envelope", code=E.REFERENCE_MALFORMED)
    if p.get("notes") is not None:
        _text(kind, "notes", p["notes"])


def _validate_recommendation(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "recommendation_id", p["recommendation_id"], kind)
    _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
            code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    # Closed, not merely enumerated. An open list is one change away from
    # containing `restart`, and the argument for adding it will be made during
    # an incident.
    _member(kind, "recommendation", p["recommendation"], RECOMMENDATIONS)
    _text(kind, "reason", p["reason"])
    _identifier(kind, "derived_from_state_id", p["derived_from_state_id"],
                "capability-health-state", code=E.REFERENCE_MALFORMED)
    _instant(kind, "created_at", p["created_at"])
    # Carried on the record rather than assumed from the record type, so a
    # consumer reading one recommendation in isolation still knows it is advice.
    if _boolean(kind, "review_required", p["review_required"]) is not True:
        raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                       field="review_required", detail="advisory-record")
    if _boolean(kind, "advisory_only", p["advisory_only"]) is not True:
        raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=kind,
                       field="advisory_only", detail="advisory-record")
    _mapping(kind, "provenance", p["provenance"])
    if p.get("derived_from_event_id") is not None:
        _identifier(kind, "derived_from_event_id", p["derived_from_event_id"],
                    "capability-degradation-event", code=E.REFERENCE_MALFORMED)
    if p.get("acknowledged_at") is not None:
        _instant(kind, "acknowledged_at", p["acknowledged_at"])
    for field in ("acknowledged_by", "notes"):
        if p.get(field) is not None:
            _text(kind, field, p[field])


def _validate_heartbeat(kind: str, p: Mapping[str, Any]) -> None:
    _identifier(kind, "heartbeat_id", p["heartbeat_id"], kind)
    _member(kind, "subject_type", p["subject_type"], SUBJECT_TYPES,
            code=E.SUBJECT_TYPE_NOT_PERMITTED)
    _text(kind, "subject_id", p["subject_id"])
    # `observed_at` is the subject's claim. `received_at` is authored by this
    # plane. Only the second may ever drive a freshness judgement -- a subject
    # that chose the number deciding its own liveness would be certifying
    # itself -- and no such judgement happens in this layer at all.
    _instant(kind, "observed_at", p["observed_at"])
    _instant(kind, "received_at", p["received_at"])
    _whole(kind, "epoch", p["epoch"], minimum=0)
    _whole(kind, "sequence", p["sequence"], minimum=0)
    _mapping(kind, "provenance", p["provenance"])
    if p.get("reported_uptime_seconds") is not None:
        _whole(kind, "reported_uptime_seconds", p["reported_uptime_seconds"],
               minimum=0)
    if p.get("notes") is not None:
        _text(kind, "notes", p["notes"])


VALIDATORS = {
    "capability-health-envelope": _validate_envelope,
    "capability-health-observation": _validate_observation,
    "capability-health-state": _validate_state,
    "capability-degradation-event": _validate_event,
    "capability-health-recommendation": _validate_recommendation,
    "capability-heartbeat": _validate_heartbeat,
}


# --- the entry point -----------------------------------------------------
def parse(kind: Any, payload: Any) -> HealthRecord:
    """Validate a payload in full, then return a frozen record.

    Nothing is constructed until every check has passed, so a refused payload
    leaves no object behind. A partly-valid record would be the most dangerous
    thing this module could produce: it would carry some assertions that were
    checked and some that were not, and nothing downstream could tell which.
    """
    if not isinstance(kind, str) or kind not in REQUIRED:
        raise E.refuse(E.UNKNOWN_RECORD_KIND)
    if not isinstance(payload, Mapping):
        raise E.refuse(E.PAYLOAD_NOT_A_MAPPING, kind=kind)

    present = set(payload)
    declared = (set(REQUIRED[kind]) | set(CONDITIONAL.get(kind, ()))
                | set(OPTIONAL.get(kind, ())))

    # Forbidden before unknown: a forbidden field is a named architectural
    # prohibition and deserves its own refusal, not "unrecognised".
    for field in FORBIDDEN[kind]:
        if field in present:
            raise E.refuse(E.FORBIDDEN_FIELD, kind=kind, field=field)
    for field in sorted(present - declared):
        raise E.refuse(E.UNKNOWN_FIELD, kind=kind, field=field)
    for field in REQUIRED[kind]:
        if field not in present:
            raise E.refuse(E.MISSING_REQUIRED_FIELD, kind=kind, field=field)

    VALIDATORS[kind](kind, payload)

    # An absent optional serialises as absent rather than as a null, so a
    # record that never carried one reads back exactly as it was written.
    fields = {field: payload[field] for field in REQUIRED[kind]}
    for field in (*CONDITIONAL.get(kind, ()), *OPTIONAL.get(kind, ())):
        if payload.get(field) is not None:
            fields[field] = payload[field]
    return HealthRecord(kind, fields)


# ===========================================================================
# ENG-0006-H2 — subject identity and reference validation
# ===========================================================================
#
# ONE RULE, from ADR-0013's referential-integrity section: a record's subject
# must equal the subject of every record it cites.
#
# "Identifier format is **not** sufficient to validate a citation. A state
# citing another subject's observations is well-formed, correctly typed, and
# false -- and it is the cheapest route to a forged positive claim, because
# every individual record passes inspection while the relationship between them
# lies."
#
# WHAT THIS LAYER IS GIVEN, AND WHAT IT THEREFORE KNOWS.
#
# The input is a record plus **the records it cites, supplied by the caller**.
# There is no store, no network, no resolution from persistence, and no identity
# authority anywhere in this module. So:
#
#   * A citation whose record was not supplied is REFUSED, not skipped -- a
#     validator that quietly passed an unresolvable citation would validate
#     nothing. The class is `cited-record-not-supplied`, because "not supplied"
#     is what was observed; claiming the record does not exist would be an
#     assertion this layer has no basis for.
#   * A well-formed identifier is never treated as proof that the named entity
#     exists, was authenticated, is trusted, is available, is eligible, or is
#     healthy. This compares subjects. That is all it does.
#   * Nothing is fabricated, aliased, normalised or substituted. A supplied
#     record standing in for another is refused rather than used.
#
# Subject TYPE and subject IDENTIFIER are separate assertions and are compared
# separately, so `CINST-000007` as an instance and `CINST-000007` as a host are
# different subjects and citing one from the other is refused.

# kind -> field -> (cited kind, the field holds a sequence)
#
# Read against the schemas: these are exactly the fields on which one Health
# record names another. The three families that cite nothing are present with
# empty maps rather than absent, so a caller asking about them gets an answer
# instead of a lookup failure.
CITATIONS: Mapping[str, Mapping[str, tuple[str, bool]]] = {
    "capability-health-envelope": {},
    "capability-heartbeat": {},
    "capability-health-observation": {},
    "capability-health-state": {
        "derived_from_observation_ids": ("capability-health-observation", True),
        "envelope_id": ("capability-health-envelope", False),
    },
    "capability-degradation-event": {
        "derived_from_observation_ids": ("capability-health-observation", True),
        "hysteresis_first_observation_id": ("capability-health-observation", False),
        "hysteresis_last_observation_id": ("capability-health-observation", False),
        "envelope_id": ("capability-health-envelope", False),
    },
    "capability-health-recommendation": {
        "derived_from_state_id": ("capability-health-state", False),
        "derived_from_event_id": ("capability-degradation-event", False),
    },
}


def citations_of(kind: Any) -> Mapping[str, str]:
    """Which fields of `kind` name another Health record, and of which family.

    Returned read-only, so a caller cannot edit the declaration it just asked
    about.
    """
    if not isinstance(kind, str) or kind not in CITATIONS:
        raise E.refuse(E.UNKNOWN_RECORD_KIND)
    return MappingProxyType(
        {field: cited for field, (cited, _) in CITATIONS[kind].items()})


def _subject_of(record: "HealthRecord") -> tuple[str, str]:
    return (record.subject_type, record.subject_id)


def validate_citations(record: Any, cited: Any) -> None:
    """Refuse unless every record `record` cites was supplied and shares its subject.

    `cited` maps an identifier to the parsed record supplied under it. Records
    in it that `record` does not cite are permitted and ignored: a caller
    passing a whole working set is doing nothing wrong, and refusing extra
    context would make the function harder to use without making it safer.

    Faults are checked in a fixed order -- not supplied, wrong family, wrong
    identity, foreign subject -- so the same inputs always produce the same
    refusal. Nothing here chooses the most favourable reading of an ambiguous
    input; there is no ambiguity to resolve, because the citation set is keyed
    by the identifier the record names.

    Returns None on success and mutates nothing. Raises `HealthRecordError`
    naming the mismatch class, never the value that caused it.
    """
    if not isinstance(record, HealthRecord):
        raise E.refuse(E.FIELD_TYPE_INVALID, detail="parsed-health-record")
    kind = record.kind
    if kind not in CITATIONS:
        raise E.refuse(E.UNKNOWN_RECORD_KIND, kind=kind)
    if not isinstance(cited, Mapping):
        raise E.refuse(E.CITATION_SET_MALFORMED, kind=kind, detail="mapping")
    for key, supplied in cited.items():
        if not isinstance(key, str) or not isinstance(supplied, HealthRecord):
            raise E.refuse(E.CITATION_SET_MALFORMED, kind=kind,
                           detail="identifier-to-parsed-record")

    subject = _subject_of(record)
    for field, (cited_kind, is_sequence) in CITATIONS[kind].items():
        value = getattr(record, field, None)
        if value is None:
            # The record cites nothing in this slot. An optional citation that
            # is absent requires nothing to be supplied for it; only a citation
            # the record actually makes has to resolve.
            continue
        identifiers = tuple(value) if is_sequence else (value,)
        for identifier in identifiers:
            supplied = cited.get(identifier)
            if supplied is None:
                raise E.refuse(E.CITED_RECORD_NOT_SUPPLIED, kind=kind,
                               field=field, detail=cited_kind)
            # Family before identity: a record of the wrong family is a more
            # fundamental fault than one standing in for another, and an
            # operator reading the refusal needs the more fundamental one named.
            if supplied.kind != cited_kind:
                raise E.refuse(E.CITED_RECORD_KIND_MISMATCH, kind=kind,
                               field=field, detail=cited_kind)
            if getattr(supplied, IDENTITY_FIELD[supplied.kind]) != identifier:
                raise E.refuse(E.CITED_RECORD_IDENTITY_MISMATCH, kind=kind,
                               field=field, detail=cited_kind)
            if _subject_of(supplied) != subject:
                # Which of the two assertions differs is a class, not a value,
                # so naming it leaks nothing and saves an operator a comparison.
                which = ("subject-type"
                         if supplied.subject_type != record.subject_type
                         else "subject-id")
                raise E.refuse(E.CROSS_SUBJECT_CITATION, kind=kind,
                               field=field, detail=which)
