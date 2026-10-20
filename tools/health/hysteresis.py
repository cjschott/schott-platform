"""The Health hysteresis and continuity evaluator — ENG-0006-H5.

Component A5 of the committed ENG-0006-D plan, and only A5: decide whether a
transition is recordable, and produce its proof. It writes no degradation
event, derives no health state, reads no clock, performs no I/O and reaches no
other plane.

**A gap is not a violation.** Two observations separated by a long gap do not
establish continuous threshold violation. That is the rule which makes a
duration hysteresis honest: without it a collector outage would manufacture
transitions, and it would do so most enthusiastically during a network
incident, when a monitor's findings are least reliable. ADR-0019 states it as
four conjunctive clauses over a candidate interval and three reset conditions,
and CHENV declares `gap_cause_affects_reset: false` -- a gap resets the
interval regardless of why it exists, so `collection_failure_implies_subject_
failure: false` is enforced arithmetically rather than by intention.

**Violation is decided by the condition evaluator, not re-implemented here.**
ENG-0006-D lists A3 among A5's upstream components, so each observation is
classified by calling the public `evaluate_condition` with that single
observation under `instant` aggregation: `satisfied` means usable and
violating, `not-satisfied` means usable and not violating, and `unknown` means
not usable. One audited comparison, no second copy of the decimal semantics,
and no private import across module boundaries.

**A transition that cannot show its hysteresis was satisfied is not
recordable.** CHDEG declares `unprovable_transition: refuse` and six required
proof fields. This module therefore produces a proof only when every one of
them can be established, and returns `unprovable` rather than a verdict when
no candidate interval exists at all.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from types import MappingProxyType
from typing import Any, Mapping

from . import errors as E
from .conditions import evaluate_condition
from .records import (DIMENSION_UNITS, HYSTERESIS_KINDS, _instant, _whole,
                      select_observations)

# Three outcomes. These are INTERNAL result labels and deliberately not schema
# values: no health state, degradation enum or freshness vocabulary contains
# them, and nothing here may introduce one.
HYSTERESIS_OUTCOMES = ("satisfied", "unsatisfied", "unprovable")

# Why a candidate interval failed a declared requirement. Closed, because a
# free-text reason is one an operator cannot act on consistently.
UNSATISFIED_REASONS = ("duration-not-met", "coverage-below-minimum-samples",
                       "gap-exceeds-maximum")

# Why no verdict could be reached at all.
UNPROVABLE_REASONS = ("no-candidate-interval", "null-freshness-policy",
                      "proof-incomplete")

# The four members every declared hysteresis must carry. No member has a
# default: a defaulted continuity parameter is an unanswered configuration
# question rendered as a confident assessment.
_HYSTERESIS_FIELDS = ("kind", "seconds", "max_gap_seconds", "min_samples")

_EVAL = "hysteresis-evaluation"


class HysteresisProof:
    """The CHDEG proof for one recordable transition, frozen.

    Carries exactly the six fields CHDEG requires plus the ordered supporting
    evidence, so an operator can recompute the verdict from this object and the
    cited observations without access to the evaluator. That is the test of
    reproducibility ADR-0019 sets, and the reason each declared parameter has a
    matching observed value beside it.
    """

    __slots__ = ("_hysteresis", "_satisfied_over_seconds", "_first", "_last",
                 "_sample_count", "_observed_max_gap_seconds", "_evidence")

    def __init__(self, hysteresis: Mapping[str, Any], satisfied_over_seconds: int,
                 first: str, last: str, sample_count: int,
                 observed_max_gap_seconds: int, evidence: tuple) -> None:
        object.__setattr__(self, "_hysteresis",
                           MappingProxyType(dict(hysteresis)))
        object.__setattr__(self, "_satisfied_over_seconds", satisfied_over_seconds)
        object.__setattr__(self, "_first", first)
        object.__setattr__(self, "_last", last)
        object.__setattr__(self, "_sample_count", sample_count)
        object.__setattr__(self, "_observed_max_gap_seconds",
                           observed_max_gap_seconds)
        object.__setattr__(self, "_evidence", tuple(evidence))

    def __setattr__(self, name: str, value: Any) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    def __delattr__(self, name: str) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    @property
    def hysteresis(self) -> Mapping[str, Any]:
        """The resolved declaration, quoted, so the event stays readable after
        the envelope is superseded."""
        return object.__getattribute__(self, "_hysteresis")

    @property
    def hysteresis_satisfied_over_seconds(self) -> int:
        return object.__getattribute__(self, "_satisfied_over_seconds")

    @property
    def hysteresis_first_observation_id(self) -> str:
        return object.__getattribute__(self, "_first")

    @property
    def hysteresis_last_observation_id(self) -> str:
        return object.__getattribute__(self, "_last")

    @property
    def hysteresis_sample_count(self) -> int:
        return object.__getattribute__(self, "_sample_count")

    @property
    def hysteresis_observed_max_gap_seconds(self) -> int:
        return object.__getattribute__(self, "_observed_max_gap_seconds")

    @property
    def derived_from_observation_ids(self) -> tuple:
        """The ordered interval, so the whole judgement is re-checkable."""
        return object.__getattribute__(self, "_evidence")

    def to_dict(self) -> dict[str, Any]:
        """Exactly the CHDEG proof field names. No name is invented here."""
        return {
            "hysteresis": dict(self.hysteresis),
            "hysteresis_satisfied_over_seconds":
                self.hysteresis_satisfied_over_seconds,
            "hysteresis_first_observation_id":
                self.hysteresis_first_observation_id,
            "hysteresis_last_observation_id":
                self.hysteresis_last_observation_id,
            "hysteresis_sample_count": self.hysteresis_sample_count,
            "hysteresis_observed_max_gap_seconds":
                self.hysteresis_observed_max_gap_seconds,
            "derived_from_observation_ids": list(self.derived_from_observation_ids),
        }

    def __repr__(self) -> str:
        # The shape only. No measured value appears in a proof repr.
        return (f"<HysteresisProof over={self.hysteresis_satisfied_over_seconds}s "
                f"n={self.hysteresis_sample_count}>")


class HysteresisResult:
    """One continuity verdict, frozen. A verdict, never a written record."""

    __slots__ = ("_outcome", "_reason", "_proof")

    def __init__(self, outcome: str, reason: Any, proof: Any) -> None:
        object.__setattr__(self, "_outcome", outcome)
        object.__setattr__(self, "_reason", reason)
        object.__setattr__(self, "_proof", proof)

    def __setattr__(self, name: str, value: Any) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    def __delattr__(self, name: str) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    @property
    def outcome(self) -> str:
        return object.__getattribute__(self, "_outcome")

    @property
    def reason(self) -> Any:
        return object.__getattribute__(self, "_reason")

    @property
    def proof(self) -> Any:
        """The CHDEG proof, present only when the outcome is `satisfied`."""
        return object.__getattribute__(self, "_proof")

    def to_dict(self) -> dict[str, Any]:
        return {"outcome": self.outcome, "reason": self.reason,
                "proof": None if self.proof is None else self.proof.to_dict()}

    def __repr__(self) -> str:
        return f"<HysteresisResult {self.outcome} {self.reason or ''}>".strip() + ">"


def _hysteresis_of(hysteresis: Any) -> Mapping[str, Any]:
    """Validate a declared hysteresis. One kind in v1, four required members.

    `occurrences` is refused by the same closed set that refuses a typo.
    ADR-0019 excludes it because "how often" is already expressible in the
    CONDITION through `windowed_count`, so supporting both would mean two proof
    shapes on the transition record and a discriminator, for a distinction
    already covered.
    """
    if not isinstance(hysteresis, Mapping):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=_EVAL,
                       field="hysteresis", detail="hysteresis")
    kind = hysteresis.get("kind")
    if not isinstance(kind, str) or kind not in HYSTERESIS_KINDS:
        raise E.refuse(E.HYSTERESIS_KIND_NOT_PERMITTED, kind=_EVAL, field="kind")
    if set(hysteresis) != set(_HYSTERESIS_FIELDS):
        raise E.refuse(E.DIMENSION_ENTRY_MALFORMED, kind=_EVAL,
                       field="hysteresis",
                       detail="kind-seconds-max_gap_seconds-min_samples")
    for member in ("seconds", "max_gap_seconds", "min_samples"):
        _whole(_EVAL, member, hysteresis[member], minimum=1)
    return MappingProxyType(dict(hysteresis))


def _classify(observation: Any, *, dimension: str, unit: str,
              condition: Mapping[str, Any], policy: int,
              evaluated_at: str) -> str:
    """`violating`, `clear`, or `unusable`, decided by the condition evaluator.

    Reuses the audited public entry point rather than re-implementing the
    comparison, so the exact-decimal semantics, the usability rule and the
    future-observation exclusion are all inherited rather than duplicated.
    """
    outcome = evaluate_condition(
        dimension=dimension, unit=unit, condition=condition,
        aggregation={"kind": "instant"}, freshness_policy_seconds=policy,
        observations=[observation], evaluated_at=evaluated_at).outcome
    if outcome == "satisfied":
        return "violating"
    if outcome == "not-satisfied":
        return "clear"
    return "unusable"


def evaluate_hysteresis(*, dimension: Any, unit: Any, condition: Any,
                        hysteresis: Any, freshness_policy_seconds: Any,
                        observations: Any,
                        evaluated_at: Any) -> HysteresisResult:
    """Decide whether the declared hysteresis is satisfied at a given instant.

    The candidate interval is `[t0, t1]` with `t1` the caller's evaluation
    instant and `t0` the first observation of the latest unbroken run of
    violating usable observations. Returns `satisfied` with a complete CHDEG
    proof, `unsatisfied` with the declared requirement that failed, or
    `unprovable` when no candidate interval exists.

    Every parameter is keyword-only and `evaluated_at` has no default, so the
    instant is always the caller's and an implicit "now" cannot be introduced
    by a call site.
    """
    if not isinstance(dimension, str) or dimension not in DIMENSION_UNITS:
        raise E.refuse(E.DIMENSION_NOT_DECLARED, kind=_EVAL, field="dimension")
    if unit != DIMENSION_UNITS[dimension]:
        raise E.refuse(E.UNIT_MISMATCH, kind=_EVAL, field="unit", detail=dimension)
    declared = _hysteresis_of(hysteresis)
    instant = datetime.fromisoformat(_instant(_EVAL, "evaluated_at", evaluated_at))
    selected = select_observations(observations, dimension, kind=_EVAL)

    # The Null Policy Rule. Without a declared policy there is no usability
    # bound, and defaulting one would convert an unanswered configuration
    # question into a confident-looking assessment. Continuity is then not
    # provable -- never satisfied.
    if freshness_policy_seconds is None:
        return HysteresisResult("unprovable", "null-freshness-policy", None)
    policy = _whole(_EVAL, "freshness_policy_seconds", freshness_policy_seconds,
                    minimum=1)

    seconds = declared["seconds"]
    max_gap = declared["max_gap_seconds"]
    min_samples = declared["min_samples"]

    # Classify every selected observation once. `condition` is validated by the
    # first call and refuses there, so a malformed condition never reaches the
    # continuity arithmetic.
    classified = [(observation,
                   _classify(observation, dimension=dimension, unit=unit,
                             condition=condition, policy=policy,
                             evaluated_at=evaluated_at))
                  for observation in selected]
    usable = [(observation, state) for observation, state in classified
              if state != "unusable"]

    # Walk back from the newest usable observation. The interval resets on a
    # non-violating usable observation and on a gap exceeding the maximum, so
    # walking backwards from the end finds the latest unbroken violating run
    # directly -- and a gap in USABLE observations is what a collection outage
    # produces, which is why its cause never enters this arithmetic.
    run: list = []
    boundary_gap: Any = None
    for observation, state in reversed(usable):
        moment = datetime.fromisoformat(observation.observed_at)
        if state != "violating":
            break
        if not run:
            boundary_gap = int((instant - moment).total_seconds())
        else:
            gap = int((datetime.fromisoformat(run[0].observed_at) - moment
                       ).total_seconds())
            if gap > max_gap:
                break
        run.insert(0, observation)

    if not run:
        # Nothing to prove: no violating usable observation reaches the end of
        # the interval, so there is no candidate interval to judge.
        return HysteresisResult("unprovable", "no-candidate-interval", None)

    # Clause 4's boundary leg. The `t0`-to-first leg is satisfied by
    # construction, because `t0` IS the first observation of the run -- see
    # Q-H5-2 in the ENG-0006-H5 report.
    if boundary_gap is not None and boundary_gap > max_gap:
        return HysteresisResult("unsatisfied", "gap-exceeds-maximum", None)

    moments = [datetime.fromisoformat(o.observed_at) for o in run]
    achieved = int((instant - moments[0]).total_seconds())
    gaps = [int((moments[i + 1] - moments[i]).total_seconds())
            for i in range(len(moments) - 1)]
    # The observed maximum includes the last-to-`t1` boundary gap, because
    # clause 4 tests that gap against the same declared maximum.
    observed_max_gap = max(gaps + [boundary_gap or 0])

    if achieved < seconds:
        return HysteresisResult("unsatisfied", "duration-not-met", None)
    if len(run) < min_samples:
        return HysteresisResult("unsatisfied", "coverage-below-minimum-samples",
                                None)
    if observed_max_gap > max_gap:
        return HysteresisResult("unsatisfied", "gap-exceeds-maximum", None)

    proof = HysteresisProof(
        hysteresis=declared, satisfied_over_seconds=achieved,
        first=run[0].observation_id, last=run[-1].observation_id,
        sample_count=len(run), observed_max_gap_seconds=observed_max_gap,
        evidence=tuple(o.observation_id for o in run))
    # A transition that cannot show its hysteresis was satisfied is not
    # recordable. Every CHDEG proof element is established above, so this guard
    # is unreachable in correct operation -- it is kept because it is the one
    # thing standing between a weakened proof builder and a fabricated
    # transition, and a mutation deleting any element is caught by it.
    established = proof.to_dict()
    for field in ("hysteresis", "hysteresis_satisfied_over_seconds",
                  "hysteresis_first_observation_id",
                  "hysteresis_last_observation_id", "hysteresis_sample_count",
                  "hysteresis_observed_max_gap_seconds",
                  "derived_from_observation_ids"):
        if established.get(field) in (None, "", [], {}):
            return HysteresisResult("unprovable", "proof-incomplete", None)
    return HysteresisResult("satisfied", None, proof)
