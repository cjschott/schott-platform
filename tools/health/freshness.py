"""The Health freshness evaluator — ENG-0006-H4.

Component A4 of the committed ENG-0006-D plan, and only A4: per-dimension
freshness, and the two-freshness separation. It answers "how current is the
evidence for this dimension, against the policy its envelope declared, at the
instant the caller names" — and nothing else. It derives no health state,
decides no eligibility, writes no record, reads no clock, performs no I/O and
reaches no other plane.

**The two freshnesses must not be confused.** CHSTATE declares
`stored_freshness: freshness-at-evaluated-at`,
`stored_freshness_authoritative_for_eligibility: false` and
`freshness_recomputed_at_use: true`. A label stored on a record is a historical
fact about what the evidence looked like when an assessment was made. Anything
deciding anything must RECOMPUTE from each observation's `observed_at` against
that dimension's declared policy and the caller's instant. This module
therefore never reads an observation's stored freshness field: if it did, a
stored `current` would remain operationally current forever and a dead
collector would freeze a favourable assessment.

**The Null Policy Rule is inherited exactly.** A dimension with no declared
policy is `unknown` with `review_required: true`, never a default maximum age:
inventing an age converts an unanswered configuration question into a
confident-looking assessment. The freshness of nothing is `unknown`, never
`stale` -- stale means "we looked and it was long ago", unknown means "we have
not looked".

**No aging threshold is invented.** The Confidence and Freshness Standard
defines `aging` as "past a warning threshold but still within the maximum", and
**no warning threshold is declared anywhere for Health**: the envelope declares
`freshness_policy_seconds` alone. Choosing one here -- even by copying another
plane's released constant -- would be exactly the defaulting the Null Policy
Rule forbids, applied to a second parameter. So the threshold is an explicit
caller input with no default, and while none is supplied `aging` is never
reported. See Q-H4-1 in the ENG-0006-H4 report.
"""

from __future__ import annotations

from datetime import datetime
from types import MappingProxyType
from typing import Any, Mapping

from . import errors as E
from .records import DIMENSION_UNITS, _instant, _whole, select_observations

# The four states, and no others. Declared by the Confidence and Freshness
# Standard and carried in both the CHOBS and CHSTATE `freshness` enums.
FRESHNESS_STATES = ("current", "aging", "stale", "unknown")

# Why a freshness is unknown. An unknown nobody can explain is indistinguishable
# from a current one at the moment the difference matters, so the cause travels
# with the label and names WHICH gap produced it.
FRESHNESS_UNKNOWN_REASONS = ("null-freshness-policy", "no-usable-observation")

_EVAL = "freshness-evaluation"


class FreshnessResult:
    """One dimension's freshness, frozen. Advisory, never a decision.

    A freshness label is not a health state and not an eligibility outcome.
    `stale` evidence contributes no subtraction and does not become `healthy`;
    ageing out of a problem is not the same as fixing it, in either direction.
    Those are ADR-0013's rules for the deriving layer, not this one's.
    """

    __slots__ = ("_state", "_age_seconds", "_policy_seconds",
                 "_aging_threshold_seconds", "_review_required", "_reason",
                 "_observation_id")

    def __init__(self, state: str, age_seconds: Any, policy_seconds: Any,
                 aging_threshold_seconds: Any, review_required: bool,
                 reason: Any, observation_id: Any) -> None:
        object.__setattr__(self, "_state", state)
        object.__setattr__(self, "_age_seconds", age_seconds)
        object.__setattr__(self, "_policy_seconds", policy_seconds)
        object.__setattr__(self, "_aging_threshold_seconds",
                           aging_threshold_seconds)
        object.__setattr__(self, "_review_required", review_required)
        object.__setattr__(self, "_reason", reason)
        object.__setattr__(self, "_observation_id", observation_id)

    def __setattr__(self, name: str, value: Any) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    def __delattr__(self, name: str) -> None:
        raise E.refuse(E.RECORD_IMMUTABLE, kind=_EVAL, field=name)

    @property
    def state(self) -> str:
        return object.__getattribute__(self, "_state")

    @property
    def age_seconds(self) -> Any:
        return object.__getattribute__(self, "_age_seconds")

    @property
    def policy_seconds(self) -> Any:
        return object.__getattribute__(self, "_policy_seconds")

    @property
    def aging_threshold_seconds(self) -> Any:
        return object.__getattribute__(self, "_aging_threshold_seconds")

    @property
    def review_required(self) -> bool:
        return object.__getattribute__(self, "_review_required")

    @property
    def reason(self) -> Any:
        return object.__getattribute__(self, "_reason")

    @property
    def observation_id(self) -> Any:
        """The observation the age was measured from, so it is re-checkable."""
        return object.__getattribute__(self, "_observation_id")

    def to_dict(self) -> dict[str, Any]:
        return {"state": self.state, "age_seconds": self.age_seconds,
                "policy_seconds": self.policy_seconds,
                "aging_threshold_seconds": self.aging_threshold_seconds,
                "review_required": self.review_required, "reason": self.reason,
                "observation_id": self.observation_id}

    def __repr__(self) -> str:
        # The label and its shape only. No measured value appears here, and the
        # age is a property of the clock rather than of the subject.
        return f"<FreshnessResult {self.state} age={self.age_seconds}>"


def _newest_collected(selected: tuple, instant: datetime) -> Any:
    """The newest observation that can carry an age, or None.

    Three exclusions, each with a reason:

    - **Not `collected`.** A failed or unavailable collection concluded nothing
      about the subject; it is evidence the collector failed. Letting it carry
      an age would mean a dead collector kept refreshing the clock, which is
      `collection_failure_implies_subject_failure: false` read backwards.
    - **Recorded after the evaluation instant.** Evidence that did not exist
      when the assessment was made cannot support it. This matches the
      exclusion the condition grammar already applies.
    - Nothing else. `selected` is already one dimension of one subject.

    The sequence arrives ordered by `observed_at` ascending with ties broken by
    identifier ascending, so "newest" is total and the scan runs backwards.
    """
    for observation in reversed(selected):
        if observation.collection_status != "collected":
            continue
        if datetime.fromisoformat(observation.observed_at) > instant:
            continue
        return observation
    return None


def evaluate_freshness(*, dimension: Any, freshness_policy_seconds: Any,
                       observations: Any, evaluated_at: Any,
                       aging_threshold_seconds: Any = None) -> FreshnessResult:
    """Classify one dimension's freshness at a caller-supplied instant.

    Every parameter is keyword-only and `evaluated_at` has no default, so the
    evaluation instant is always the caller's and an implicit "now" cannot be
    introduced by a call site. Identical inputs produce an identical label on
    any host and at any time.

    Returns `current`, `aging`, `stale` or `unknown`. Refuses, rather than
    guessing, on an undeclared dimension, a non-positive or non-integer policy,
    an aging threshold that is not strictly inside the policy, a naive
    evaluation instant, or an observation set that is not validated records of
    one subject.
    """
    if not isinstance(dimension, str) or dimension not in DIMENSION_UNITS:
        raise E.refuse(E.DIMENSION_NOT_DECLARED, kind=_EVAL, field="dimension")
    instant = datetime.fromisoformat(_instant(_EVAL, "evaluated_at", evaluated_at))
    selected = select_observations(observations, dimension, kind=_EVAL)

    policy: Any = None
    if freshness_policy_seconds is not None:
        policy = _whole(_EVAL, "freshness_policy_seconds",
                        freshness_policy_seconds, minimum=1)
    threshold: Any = None
    if aging_threshold_seconds is not None:
        threshold = _whole(_EVAL, "aging_threshold_seconds",
                           aging_threshold_seconds, minimum=1)
        # A threshold at or past the maximum describes no band at all, and a
        # threshold with no maximum to sit inside has nothing to be a fraction
        # of. Both are declarations that cannot mean what they say.
        if policy is None or threshold >= policy:
            raise E.refuse(E.CONDITIONAL_REQUIREMENT_UNMET, kind=_EVAL,
                           field="aging_threshold_seconds",
                           detail="inside-freshness-policy")

    newest = _newest_collected(selected, instant)
    age = None
    if newest is not None:
        age = int((instant - datetime.fromisoformat(newest.observed_at)
                   ).total_seconds())

    # The Null Policy Rule, and it is checked after the age so that the age is
    # still reported: the evidence exists and its age is a fact, even though no
    # policy makes it assessable. The flag is what turns the gap into pressure
    # to declare the policy rather than something to look past.
    if policy is None:
        return FreshnessResult("unknown", age, None, None, True,
                               "null-freshness-policy",
                               None if newest is None else newest.observation_id)

    # The freshness of nothing is unknown, never stale. No review flag: the
    # causes that carry one are enumerated as a null policy,
    # `insufficient-policy` and contradicting sources, and absent evidence is
    # none of those -- it is the default, inert state.
    if newest is None:
        return FreshnessResult("unknown", None, policy, threshold, False,
                               "no-usable-observation", None)

    if age > policy:
        state = "stale"
    elif threshold is not None and age > threshold:
        state = "aging"
    else:
        state = "current"
    return FreshnessResult(state, age, policy, threshold, False, None,
                           newest.observation_id)


def evaluate_envelope_freshness(*, dimensions: Any, observations: Any,
                                evaluated_at: Any,
                                aging_thresholds: Any = None) -> Mapping[str, FreshnessResult]:
    """One freshness per declared dimension. Never a collapsed score.

    Each dimension carries its own policy, so a subject may hold current
    latency evidence and stale availability evidence at once. Collapsing them
    to a single age would hide whichever dimension stopped reporting, which is
    the one worth knowing about -- so this returns a mapping and never a
    scalar, and a declared dimension with no evidence appears as `unknown`
    rather than being omitted.
    """
    if not isinstance(dimensions, Mapping):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=_EVAL, field="dimensions",
                       detail="mapping")
    if not dimensions:
        raise E.refuse(E.FIELD_EMPTY, kind=_EVAL, field="dimensions")
    if aging_thresholds is not None and not isinstance(aging_thresholds, Mapping):
        raise E.refuse(E.FIELD_TYPE_INVALID, kind=_EVAL,
                       field="aging_thresholds", detail="mapping")
    thresholds = aging_thresholds or {}
    for name in thresholds:
        if name not in dimensions:
            raise E.refuse(E.UNKNOWN_FIELD, kind=_EVAL, field="aging_thresholds")
    results = {}
    for name, policy in dimensions.items():
        # A null policy is permitted and produces unknown; anything else that is
        # not a positive whole number of seconds is refused by the per-dimension
        # evaluator rather than quietly skipped.
        results[name] = evaluate_freshness(
            dimension=name, freshness_policy_seconds=policy,
            observations=observations, evaluated_at=evaluated_at,
            aging_threshold_seconds=thresholds.get(name))
    return MappingProxyType(results)
