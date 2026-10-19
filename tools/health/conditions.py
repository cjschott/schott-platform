"""The Health condition grammar evaluator — ENG-0006-H3.

ADR-0019 defines a POLICY LANGUAGE. This module is its evaluator, and nothing
more: it compares one declared condition against supplied observations and
returns one of three outcomes. It concludes no health state, writes no record,
reads no clock, performs no I/O and reaches no other plane.

**Why this is not in `records.py`.** A record model answers "is this a
well-formed Health record"; an evaluator answers "did this declared condition
hold". Those are different questions with different authorities, and ENG-0006
adds two more evaluators after this one -- freshness (A4/H4) and hysteresis
(A5/H5). Keeping all three beside the six record families would produce a
module whose name described a third of its contents. ENG-0006-H3 shipped the
evaluator inside `records.py` only because the file allowlist of the day named
three modules and weakening a guard to obtain a pass is forbidden; ENG-0006-H3A
moved the allowlist instead, which is the correct order of operations.

Everything imported below comes from `records`, and `records` imports nothing
from here, so the dependency runs one way: an evaluator depends on the record
model, never the reverse.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal
from typing import Any, Mapping, Sequence

from . import errors as E
from .records import (AGGREGATIONS, CONDITION_OPERATORS, DIMENSION_UNITS,
                      HealthRecord, _decimal_text, _instant, _whole,
                      select_observations)

# --- the condition grammar evaluator — ENG-0006-H3 ----------------------
# ADR-0019 defines a POLICY LANGUAGE. This is its evaluator, and nothing more:
# it compares one declared condition against supplied observations and returns
# one of three outcomes. It concludes no health state, writes no record, reads
# no clock and reaches nothing.
#
# The three outcomes are deliberately not health states. "satisfied" means the
# declared condition held; turning that into `degraded` requires hysteresis
# (A5/H5) and the worst-dimension-wins combination (H10), which are other
# increments' authority. Conflating them here would let a single slow response
# degrade a subject, which is the thing ADR-0013 requires hysteresis to prevent.
CONDITION_OUTCOMES = ("satisfied", "not-satisfied", "unknown")

# Why an `unknown` is unknown. ADR-0013 requires that an `unknown` "must appear
# in every explanation of every selection that touched it" -- an unknown nobody
# can explain is indistinguishable from a healthy one at the moment the
# difference matters -- so the reason travels with the verdict.
UNKNOWN_REASONS = ("no-usable-observation", "below-minimum-samples",
                   "null-freshness-policy")

_COMPARISONS: Mapping[str, Any] = {
    "gt": lambda measured, threshold: measured > threshold,
    "ge": lambda measured, threshold: measured >= threshold,
    "lt": lambda measured, threshold: measured < threshold,
    "le": lambda measured, threshold: measured <= threshold,
    "eq": lambda measured, threshold: measured == threshold,
}

_CONDITION_FIELDS = ("operator", "value")
_AGGREGATION_FIELDS: Mapping[str, tuple[str, ...]] = {
    "instant": ("kind",),
    "windowed_count": ("kind", "window_seconds", "min_samples"),
}

_EVAL = "condition-evaluation"


class ConditionResult:
    """One condition verdict, frozen.

    Carries the observations the verdict rests on, so a caller can cite them
    and an operator can recompute the comparison by hand. ADR-0013 requires a
    health state to be reproducible from its cited evidence; a verdict that did
    not say what it looked at could not satisfy that.
    """

    __slots__ = ("_outcome", "_aggregation", "_observation_ids", "_count",
                 "_unknown_reason")

    def __init__(self, outcome: str, aggregation: str,
                 observation_ids: Sequence[str], count: Any,
                 unknown_reason: Any) -> None:
        object.__setattr__(self, "_outcome", outcome)
        object.__setattr__(self, "_aggregation", aggregation)
        object.__setattr__(self, "_observation_ids", tuple(observation_ids))
        object.__setattr__(self, "_count", count)
        object.__setattr__(self, "_unknown_reason", unknown_reason)

    def __setattr__(self, name: str, value: Any) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    def __delattr__(self, name: str) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    @property
    def outcome(self) -> str:
        return object.__getattribute__(self, "_outcome")

    @property
    def aggregation(self) -> str:
        return object.__getattribute__(self, "_aggregation")

    @property
    def observation_ids(self) -> tuple[str, ...]:
        return object.__getattribute__(self, "_observation_ids")

    @property
    def count(self) -> Any:
        return object.__getattribute__(self, "_count")

    @property
    def unknown_reason(self) -> Any:
        return object.__getattribute__(self, "_unknown_reason")

    def to_dict(self) -> dict[str, Any]:
        return {"outcome": self.outcome, "aggregation": self.aggregation,
                "observation_ids": list(self.observation_ids),
                "count": self.count, "unknown_reason": self.unknown_reason}

    def __repr__(self) -> str:
        # The verdict and its shape only. No measured value and no threshold:
        # a repr that printed them would put every supplied value into whatever
        # is logging, which is the rule the refusal messages already follow.
        return (f"<ConditionResult {self.outcome} {self.aggregation} "
                f"n={len(self.observation_ids)}>")


def _decimal_of(field: str, value: Any) -> Decimal:
    """A finite exact decimal, or a refusal. Never a binary float.

    `_decimal_text` already refuses a non-finite special and anything that is
    not a bare decimal string, and it refuses a `float` outright: accepting one
    would make `0.1` depend on representation, and a threshold that compares
    differently on two hosts is not deterministic.
    """
    return Decimal(_decimal_text(_EVAL, field, value))


def _condition_of(condition: Any) -> tuple[str, Decimal]:
    """Validate a structured condition. There is no expression string to parse.

    ADR-0019: conditions are structured declarations, and
    `condition_expression_strings: forbidden`. A string arriving here is
    refused as a malformed condition rather than parsed, because every token a
    parser accepted would be a threshold decision taken on an operator's
    behalf.
    """
    if not isinstance(condition, Mapping):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=_EVAL, field="condition",
                       detail="structured-condition")
    for field in _CONDITION_FIELDS:
        if field not in condition:
            raise E.refuse(E.MISSING_REQUIRED_FIELD, kind=_EVAL, field=field)
    for field in condition:
        if field not in _CONDITION_FIELDS:
            raise E.refuse(E.UNKNOWN_FIELD, kind=_EVAL, field="condition")
    operator = condition["operator"]
    if not isinstance(operator, str) or operator not in CONDITION_OPERATORS:
        raise E.refuse(E.OPERATOR_NOT_PERMITTED, kind=_EVAL, field="operator")
    return operator, _decimal_of("value", condition["value"])


def _aggregation_of(aggregation: Any) -> tuple[str, Any, Any]:
    """Validate a declared aggregation. Closed at two kinds.

    A percentile is refused by the same closed set that refuses a typo. ADR-0019
    excludes it because it is not expressible against an observation model whose
    record is one measurement at one moment, because "p95" is not one
    definition, and because hysteresis already provides the flap protection a
    percentile was reaching for.
    """
    if not isinstance(aggregation, Mapping):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=_EVAL, field="aggregation",
                       detail="structured-aggregation")
    if "kind" not in aggregation:
        raise E.refuse(E.MISSING_REQUIRED_FIELD, kind=_EVAL, field="kind")
    kind = aggregation["kind"]
    if not isinstance(kind, str) or kind not in AGGREGATIONS:
        raise E.refuse(E.AGGREGATION_NOT_PERMITTED, kind=_EVAL, field="kind")
    permitted = _AGGREGATION_FIELDS[kind]
    for field in permitted:
        if field not in aggregation:
            raise E.refuse(E.MISSING_REQUIRED_FIELD, kind=_EVAL, field=field)
    for field in aggregation:
        if field not in permitted:
            raise E.refuse(E.UNKNOWN_FIELD, kind=_EVAL, field="aggregation")
    if kind == "instant":
        return kind, None, None
    # Both continuity-shaped members are required and neither may be defaulted:
    # a defaulted window parameter is an unanswered configuration question
    # rendered as a confident assessment.
    window = _whole(_EVAL, "window_seconds", aggregation["window_seconds"],
                    minimum=1)
    samples = _whole(_EVAL, "min_samples", aggregation["min_samples"], minimum=1)
    return kind, window, samples


def _usable(observation: "HealthRecord", *, evaluated_at: datetime,
            policy_seconds: int) -> bool:
    """ADR-0019's usable observation, and the age bound that makes it honest.

    Collected, carrying a measurement, and within the declared freshness
    policy. An observation recorded AFTER the evaluation instant is excluded:
    evidence that did not exist when the assessment was made cannot support it,
    and the end-exclusive convention the grammar already declares for windows
    is reused rather than inventing a second rule. See Q-H3-2.
    """
    if observation.collection_status != "collected":
        return False
    age = (evaluated_at - datetime.fromisoformat(observation.observed_at)
           ).total_seconds()
    return 0 <= age <= policy_seconds


def evaluate_condition(*, dimension: Any, unit: Any, condition: Any,
                       aggregation: Any, freshness_policy_seconds: Any,
                       observations: Any, evaluated_at: Any) -> ConditionResult:
    """Evaluate one declared condition against observations. Deterministic.

    Every parameter is keyword-only and `evaluated_at` has no default, so the
    evaluation instant is always the caller's and an implicit "now" cannot be
    introduced by a call site. The same inputs produce the same verdict on any
    host and at any time, which is what ADR-0013 means by a health state being
    "a deterministic function of its cited observations and the envelope it was
    evaluated against".

    Returns `satisfied`, `not-satisfied`, or `unknown` -- never a health state.
    Refuses, rather than guessing, on a unit mismatch, an unsupported operator
    or aggregation, a malformed condition, or a non-decimal value.
    """
    if not isinstance(dimension, str) or dimension not in DIMENSION_UNITS:
        raise E.refuse(E.DIMENSION_NOT_DECLARED, kind=_EVAL, field="dimension")
    if unit != DIMENSION_UNITS[dimension]:
        raise E.refuse(E.UNIT_MISMATCH, kind=_EVAL, field="unit",
                       detail=dimension)
    operator, threshold = _condition_of(condition)
    kind, window_seconds, min_samples = _aggregation_of(aggregation)
    instant = datetime.fromisoformat(_instant(_EVAL, "evaluated_at", evaluated_at))
    selected = select_observations(observations, dimension, kind=_EVAL)

    # The Null Policy Rule. A null freshness policy is an unanswered
    # configuration question, and the absence of a declared limit must produce
    # an explicit "not assessable", never a favourable default. Treating null
    # as "no age bound" would silently default it to infinity.
    if freshness_policy_seconds is None:
        return ConditionResult("unknown", kind, (), None, "null-freshness-policy")
    policy = _whole(_EVAL, "freshness_policy_seconds", freshness_policy_seconds,
                    minimum=1)

    if kind == "instant":
        # The single NEWEST usable observation. Not the worst, and not an
        # average: averaging would need a rounding rule nobody declared.
        for observation in reversed(selected):
            if _usable(observation, evaluated_at=instant, policy_seconds=policy):
                measured = _decimal_of("measured_value",
                                       observation.measured_value)
                outcome = ("satisfied" if _COMPARISONS[operator](measured, threshold)
                           else "not-satisfied")
                return ConditionResult(outcome, kind,
                                       (observation.observation_id,), None, None)
        return ConditionResult("unknown", kind, (), None, "no-usable-observation")

    # windowed_count. Half-open, start-inclusive and end-exclusive, anchored at
    # the evaluation instant: [evaluated_at - window_seconds, evaluated_at).
    start = instant - timedelta(seconds=window_seconds)
    in_window = tuple(
        observation for observation in selected
        if start <= datetime.fromisoformat(observation.observed_at) < instant
        and _usable(observation, evaluated_at=instant, policy_seconds=policy))
    # Required, and never defaulted: one sample in an empty window is not a
    # verdict, so a thin window is unknown rather than a favourable reading.
    if len(in_window) < min_samples:
        return ConditionResult("unknown", kind,
                               tuple(o.observation_id for o in in_window),
                               None, "below-minimum-samples")
    # The comparison applies to the COUNT of qualifying observations in the
    # window, where qualifying is ADR-0019's usable. See Q-H3-1.
    count = len(in_window)
    outcome = ("satisfied" if _COMPARISONS[operator](Decimal(count), threshold)
               else "not-satisfied")
    return ConditionResult(outcome, kind,
                           tuple(o.observation_id for o in in_window),
                           count, None)
